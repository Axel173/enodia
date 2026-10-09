#!/bin/sh
# transport-hy2.sh — плагин ТРАНСПОРТА Hysteria2 (несущая xtun поверх общего mark-core).
#
# ИДЕЯ (как у xray-transport.sh — это его близкий клон). «Сменить протокол» = перенаправить
# default в table 1000 на xtun (несущую несёт hysteria2-клиент). Вся ОБЩАЯ маркировка
# (fwmark 0x1, ipset enodia_list/iplist_set, ip rule pref 99, цепочки VPN_EXCLUDE/VPN_FORCE,
# домены) НЕ трогается — Hysteria2 несёт ровно то же, что нёс awg/xray. Оркестратор
# (transport.sh) решает, какой транспорт поднять; плагин отвечает ТОЛЬКО за свою несущую.
#
# ПОЧЕМУ переиспользуем hev/xtun и socks 10808 (как xray): у hysteria2-клиента есть и
# нативный TUN-режим, но мы НАМЕРЕННО идём через тот же tun2socks-слой (hev-socks5-tunnel),
# что и xray — это уже проверенная на железе несущая, единый xtun и единый socks-порт. Для
# hev безразлично, КТО слушает 127.0.0.1:10808 (xray или hysteria) → hev.yaml общий, меняется
# лишь локальный socks-сервер. hysteria2 = userspace QUIC поверх UDP (спец-модулей ядра нет).
#
# ФЛЕШ (важно): hysteria2 ставится ВМЕСТО xray, не третьим — /data 20 МБ не держит оба
# альт-бинаря (см. заметку hysteria2-feasibility). На роутере: awg + ОДИН из {xray|hy2}.
# hev/xtun — общий слой для любого из альтов.
#
# БЕЗОПАСНОСТЬ. Всё держится на ip rule fwmark→table 1000. Если xtun исчезнет (hev/hysteria
# умер) — маршрут уходит с устройством, table 1000 пустеет, fwmark-трафик падает в main →
# НАПРЯМУЮ (fail-open, не блэкхол). awg0 при hy2 НЕ опускаем (тёплый резерв). Ребут = сброс
# к awg (heal). Управление/SSH (br-lan, main) от транспорта не зависят.
#
# ГРАБЛИ (как у xray): на роутере НЕТ nohup/setsid → демоны через start-stop-daemon -b; есть
# полноценный curl (--socks5-hostname) для health-пробы. Клиент hysteria запускается БЕЗ
# субкоманды run (client — режим по умолчанию): `hysteria -c <config>`.
#
# Использование:
#   transport-hy2.sh up        — активировать Hysteria2-транспорт (весь дом)
#   transport-hy2.sh down      — ЧИСТО отпустить несущую → fail-open в прямой (релинквиш)
#   transport-hy2.sh status    — показать состояние
#   transport-hy2.sh health    — здоровье транспорта (для watchdog): 0 здоров / 1 нет
#   transport-hy2.sh failover  — перебор hy2-резервов внутри транспорта

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# Нет ipt-lib.sh с `ipt_top` (частичное обновление) ⇒ прежнее «первым в цепочку», байт-в-байт.
command -v ipt_top >/dev/null 2>&1 || ipt_top() { _itc=$1; shift; iptables -C "$_itc" "$@" 2>/dev/null || iptables -I "$_itc" 1 "$@"; }
command -v ct_flush >/dev/null 2>&1 || ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
# Где лежит бинарь (store-lib.sh): без накопителя — прежний путь байт-в-байт. Шим на случай
# установки без lib.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Ожидание СТАРТА демона (daemon-lib.sh). Фиксированный срок мерил не то: он подобран под флеш
# (1.4 ГБ/с) и заведомо мал для накопителя (замер 448 КБ/с ⇒ 8-МБ бинарь читается 18 с) — исправный
# демон объявлялся мёртвым и убивался. Владелец судит по ЖИЗНИ ПРОЦЕССА, потолок берёт от носителя.
# Нет файла (частичный apply-scripts) — шим повторяет ПРЕЖНИЙ путь: фиксированный срок и никакого
# различения «умер»/«жив, но не готов».
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
# «VPN выключен вручную — несущую не берёт никто» (carrier_barred/carrier_run, разбор в daemon-lib.sh). Нет — прежний путь.
command -v carrier_barred >/dev/null 2>&1 || carrier_barred() { return 1; }
command -v carrier_run >/dev/null 2>&1 || carrier_run() { shift; "$@"; }
command -v daemon_wait_port >/dev/null 2>&1 || daemon_wait_port() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0; sleep 1; _dwi=$((_dwi+1)); done
    netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0
    DAEMON_WAIT_WHY="не появился за $3 с"; return 1; }
command -v daemon_wait_dev >/dev/null 2>&1 || daemon_wait_dev() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do ip link show "$4" >/dev/null 2>&1 && return 0; sleep 1; _dwi=$((_dwi+1)); done
    ip link show "$4" >/dev/null 2>&1 && return 0
    DAEMON_WAIT_WHY="не появился за $3 с"; return 1; }
TABLE=1000
TUN=xtun
SOCKS_ADDR=127.0.0.1
SOCKS_PORT=10808                             # ТОТ ЖЕ порт, что у xray → общий hev.yaml несёт оба
HY2=$(bin_path hysteria)
HEV=$(bin_path hev)
HY2_YAML="$ENODIA_STATE/hysteria.yaml"       # активный конфиг (генерит меню; socks5.listen ОБЯЗАН быть 127.0.0.1:10808)
SEED_CONF="/etc/dnsmasq.d/02-altserver.conf" # локальный dnsmasq-ответ server-host->IP (демон резолвит имя сам)
HEV_YAML="$ENODIA_DIR/hev.yaml"
HY2_PID=/tmp/enodia-hysteria.pid
HEV_PID=/tmp/enodia-hev.pid
HY2_LOG=/tmp/enodia-hysteria.log
HEV_LOG=/tmp/enodia-hev.log
TRANSPORT_FLAG="$ENODIA_STATE/.transport"
SWITCH_LOCK=/tmp/enodia-switching.lock       # ручной switch (панель/меню) держит его → авто-failover прерывается (Fix C 2026-07-09)
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"
APPLY_BYPASS="$ENODIA_DIR/apply-bypass.sh"
DNS1=1.1.1.1
DNS2=8.8.8.8
FWMARK=0x1

log() { echo "[hy2-transport] $*"; }
notify_event() { [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

# ВАЖНО: пустой/0-байтовый пидфайл = НЕ жив. На busybox `kill -0 ""` возвращает 0 (успех) →
# наивная проверка `kill -0 "$(cat pid)"` дала бы ЛОЖНЫЙ «процесс жив» на пустом пидфайле
# (бывает при оборванной записи start-stop-daemon -m) → start_daemons НЕ перезапустил бы демон.
proc_alive() { p=$(cat "$1" 2>/dev/null | tr -d ' \r\n'); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
# «Порт слушает» ≠ «слушает НАШ демон»: уходящая hysteria держит бинд ещё несколько секунд, а
# чужой демон (осиротевший xray/ciadpi после свопа альта) — сколько угодно. Проверка по одному
# netstat рапортовала бы успех, хотя наша hysteria не забиндила и умерла, а трафик пошёл бы через
# ЧУЖОЙ socks (egress чужого сервера при «всё ок» в панели). Владельца сверяет ОДНА реализация на
# проект — slot_socks_is_ours (slot-tun-lib.sh; держатель не определился = считаем наш).
socks_ours() { slot_socks_is_ours "$SOCKS_PORT" "$HY2_PID"; }

# ---- резолв сервера по имени (анти-FATAL на старте) ----
# ЗАЧЕМ: пользователь даёт конфиг как удобно — почти всегда server ПО ИМЕНИ (ссылка
# hy2://…@host…). hysteria резолвит это имя ОДИН раз при старте через системный resolver
# (dnsmasq → 1.1.1.1, а он в iplist_set → маркирован в туннель, который ещё НЕ поднят) и при
# ЛЮБОЙ осечке падает FATAL без ретрая → несущая молча не встаёт («поставилось, но VPN нет»).
# resolve_ipv4/is_ipv4 живут в dns-lib.sh — ОДНОЙ копией на все три несущие (была продублирована
# сюда и в xray-transport.sh «зеркалом», awg нужна та же). Грабли busybox-резолва и порядок
# «dnsmasq → DoH» описаны там же.
# Сорсим ТОЛЬКО под `[ -f ]`: провалившийся `.` в ash — фатальная ошибка спецбилтина, шелл выходит
# НА МЕСТЕ и МОЛЧА (rc=2). Библиотека не опциональна (без резолва endpoint'а несущая не встанет) —
# отказываем честно, с причиной.
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; else
    echo "[hy2] нет $ENODIA_DIR/dns-lib.sh — обновите установку (панель → «Обновление» или переустановка с компьютера)" >&2; exit 1
fi
# Шим на ДРЕЙФ ДЕПЛОЯ (dns-lib.sh есть, но старый — без seed_host_clear): без него снятие сида
# вылетело бы «command not found» и `address=/host/IP` пережил бы релинквиш. Логика та же —
# сносим ОБЕ копии сниппета (/etc и живую /tmp), см. разбор в dns-lib.sh.
command -v seed_host_clear >/dev/null 2>&1 || seed_host_clear() { rm -f "$1" "/tmp/dnsmasq.d/${1##*/}" 2>/dev/null; }
# Общий примитив «внешний IPv4» (ip-lib.sh): IP-литерал-проба, DNS-free — чинит пустой egress на
# ядре 4.4 (hostname api.ipify.org там молча пустел). Шим на случай частичной установки без lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
# Слой шифрованного DNS (doh-lib.sh): при включённом DoH перехватывает установку upstream
# (dnsmasq→127.0.0.1#5053 + :443 резолвера в туннель). ВЫКЛ (дефолт) → doh_apply_dns даёт 1,
# работает прежний путь байт-в-байт. Шим на случай установки без lib (DoH просто недоступен).
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
command -v doh_apply_dns >/dev/null 2>&1 || doh_apply_dns() { return 1; }
# Наш upstream dnsmasq пишет ОДИН владелец (doh-lib.sh, разбор там). Нет библиотеки — прежняя пара «записать + рестарт».
command -v dns_upstream_put >/dev/null 2>&1 || dns_upstream_put() { mkdir -p /etc/dnsmasq.d; { echo no-resolv; for _dus in "$@"; do echo "server=$_dus"; done; } > /etc/dnsmasq.d/00-upstream.conf; /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }
# Язык письма/события о hy2-failover — панельный pref lang (деф. ru). Шим на случай установки без файла.
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
# Отметка «несущую только что подняли» (clock-lib.sh) — грейс сторожу: демоны стартуют быстрее,
# чем поднимается egress, и тик в этом зазоре красил живой канал в SUSPECT. Шим = прежнее
# поведение (грейса нет). [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v carrier_up_mark >/dev/null 2>&1 || carrier_up_mark() { return 0; }
# Кладёт ответ для server-host в ЛОКАЛЬНЫЙ dnsmasq (address=/host/IP), чтобы демон резолвил имя
# САМ (нативно, как обычный клиент) и получал ответ мгновенно ЛОКАЛЬНО — без upstream-запроса в
# ещё-не-поднятый туннель. Конфиг hysteria НЕ трогаем (остаётся ПО ИМЕНИ — источник истины; SNI
# берётся из него же демоном). Резолвим на КАЖДЫЙ старт → смена IP сервера подхватится. $SEED_CONF —
# ИЗОЛИРОВАННЫЙ файл (создаём/удаляем ТОЛЬКО его, общие файлы не правим; директива address= с
# валидным IP не может уронить dnsmasq) → положить интернет не способно. Возврат 1 = host не
# зарезолвлен -> ЧЕСТНО не поднимаемся (демон по имени упал бы FATAL; оркестратор/установщик
# скажут «несущая не встала», а не «всё ок»; трафик при этом fail-open в прямой).
# Сам сев (резолв + address=/host/IP + рестарт dnsmasq + ожидание ответа) живёт в
# dns-lib.sh::seed_host_dns — ОДНОЙ копией на hy2/xray и их доп-выходы (у слота свой seed-файл).
# Здесь остаётся hy2-специфика: вытащить `server:` из YAML (и отрезать :port).
# $1 — файл конфига (деф. боевой $HY2_YAML); параметр нужен доп-выходам (Ф3).
hy2_server_host() {
    _h=$(grep -E '^[[:space:]]*server:' "${1:-$HY2_YAML}" 2>/dev/null | head -1 | sed 's/^[[:space:]]*server:[[:space:]]*//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')
    echo "${_h%:*}"                                      # отрезать :port
}
seed_server_dns() {
    [ -s "$HY2_YAML" ] || { log "нет $HY2_YAML"; return 1; }
    _host=$(hy2_server_host)
    [ -n "$_host" ] || { log "не нашёл server в $HY2_YAML"; return 1; }
    seed_host_dns "$_host" "$SEED_CONF"
}

# ---- анти-петля: endpoint своего VPS мимо маркировки ----------------------
# IP endpoint'а hy2-сервера: сперва из сида (точный IP, который пойдёт в QUIC-dial),
# фолбэк — server из конфига, если он сразу IP. Только IPv4 (iplist_set = cidr4).
# $1 — seed-файл (деф. боевой), $2 — конфиг (деф. боевой): параметры для доп-выходов (Ф3).
hy2_endpoint_ip() {
    _ip=$(sed -n 's%^address=/[^/]*/%%p' "${1:-$SEED_CONF}" 2>/dev/null | head -1)
    [ -n "$_ip" ] && { echo "$_ip"; return 0; }
    _h=$(hy2_server_host "${2:-$HY2_YAML}")
    echo "$_h" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && echo "$_h"
}
# Исключить endpoint hy2-сервера из маркировки (иначе свои же пакеты к VPS, если его
# IP в iplist_set, заворачиваются в xtun = петля). Зовём ДО постановки default->xtun.
exclude_endpoint() {
    ep=$(hy2_endpoint_ip)
    [ -n "$ep" ] || { log "endpoint hy2 не определён — пропуск анти-петли"; return 0; }
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-set "$ep" >/dev/null 2>&1
    log "endpoint $ep исключён из маркировки (анти-петля)"
}

# ---- DNS ------------------------------------------------------------------
# В hy2-режиме внутренний Amnezia-DNS (172.29.x dev awg0) ненадёжен (awg0 = тёплый резерв,
# при заблокированном awg мёртв) → ведём DNS НЕЗАВИСИМО: публичный резолвер, принудительно
# маркированный в туннель (уйдёт в xtun→hysteria, не утечёт). Зеркало set_xray_dns.
set_hy2_dns() {
    # DoH ВКЛ → резолв через локальный прокси в туннель; ВЫКЛ → ниже как было. DOH_APPLY_NOTE — слово
    # библиотеки о том, что резолвер пришлось увести МИМО ещё не везущей несущей (см. doh_apply_dns).
    if doh_apply_dns tunnel; then [ -n "${DOH_APPLY_NOTE:-}" ] && log "DoH: $DOH_APPLY_NOTE"; return 0; fi
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -C OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null || \
            iptables -t mangle -A OUTPUT -d "$d" -j MARK --set-mark $FWMARK
    done
    dns_upstream_put "$DNS1" "$DNS2"
}
# Прямой DNS (релинквиш / прямой режим): публичный резолвер БЕЗ маркировки в туннель.
set_direct_dns() {
    # Своя туннельная марка снимается ДО ветки DoH (зеркало xray): её вешал set_hy2_dns, и в
    # прямом режиме она не нужна никому. Прежний порядок при включённом «Шифрованном DNS»
    # оставлял `mangle OUTPUT -d 1.1.1.1/8.8.8.8 -j MARK 0x1` жить после релинквиша.
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -D OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null
    done
    doh_apply_dns direct && return 0    # DoH ВКЛ (или авто-режим прямых) → резолв через локальный прокси; иначе → ниже как было
    dns_upstream_put "$DNS1" "$DNS2"
}

# ---- демоны ---------------------------------------------------------------
# Запуск hysteria в фоне С ЗАХВАТОМ вывода в $HY2_LOG. ЗАЧЕМ: у hysteria2-клиента НЕТ опции
# «писать лог в файл» (он пишет в stderr), а start-stop-daemon -b при демонизации уводит
# stdio демона в /dev/null → причина сбоя (socks не поднялся: кривой сервер/sni/auth/порт)
# была НЕВИДНА — tail "$HY2_LOG" и в start_daemons, и в диагностике установщика выдавал пусто
# (из-за этого установка падала «без ошибки»). Обёртка `sh -c 'exec … >>log 2>&1'`
# переоткрывает stdout/stderr УЖЕ ПОСЛЕ демонизации (внутри sh, до exec) → лог пишется;
# exec сохраняет PID для pidfile. -x /bin/sh безопасен: дедуп у нас на proc_alive (по
# пидфайлу), а -K в stop/restart матчит по -p, не по -x.
spawn_hysteria() {
    : > "$HY2_LOG" 2>/dev/null || true
    seed_server_dns || return 1            # посеять server-host->IP в локальный dnsmasq; 1 = не зарезолвили
    start-stop-daemon -S -b -m -p "$HY2_PID" -x /bin/sh -- -c "exec '$HY2' -c '$HY2_YAML' >>'$HY2_LOG' 2>&1"
}

# Освободить socks-порт, если его держит ЧУЖОЙ процесс. ЗАЧЕМ: hysteria и xray
# делят ОДИН socks 10808 и общий hev → провайдер socks должен быть РОВНО один.
# При свопе альта (reinstall hy2<->xray) старый демон остаётся ЖИВ (purge-alt
# убирает лишь файл-бинарь, не процесс) и держит порт → наша hysteria не забиндит
# и молча умрёт ("bind: address already in use"), а netstat увидит ЧУЖОГО
# слушателя → start_daemons вернул бы ЛОЖНЫЙ успех, hev пошёл бы через старый
# протокол (egress чужого сервера, не нашего). Поэтому перед стартом бьём чужого.
free_foreign_socks() {
    own=$(cat "$HY2_PID" 2>/dev/null | tr -d ' \r\n')
    holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$SOCKS_PORT " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$holder" in ''|*[!0-9]*) return 0 ;; esac   # никто не слушает / pid не распарсился
    [ "$holder" = "$own" ] && return 0                 # уже наша hysteria
    log "socks $SOCKS_PORT держит чужой pid $holder — освобождаю (своп альта/рестарт)"
    kill "$holder" 2>/dev/null
    i=0; while [ $i -lt 5 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || break; sleep 1; i=$((i+1)); done
}
start_daemons() {
    [ -x "$HY2" ] || { log "НЕТ бинаря $HY2 — поставьте его в панели: «Компоненты»"; return 1; }
    [ -x "$HEV" ] || { log "НЕТ бинаря $HEV"; return 1; }
    [ -s "$HY2_YAML" ] || { log "НЕТ конфига $HY2_YAML — добавьте hy2-конфиг (меню)"; return 1; }
    [ -s "$HEV_YAML" ] || { log "НЕТ $HEV_YAML"; return 1; }

    free_foreign_socks   # выгнать оставшийся xray/чужой демон с порта 10808
    if ! proc_alive "$HY2_PID"; then
        log "запускаю hysteria…"
        spawn_hysteria || { log "hysteria не запущена: не удалось зарезолвить server-host. Лог:"; tail -n 15 "$HY2_LOG" 2>/dev/null; return 1; }
    fi
    # ВНИМАНИЕ: socks открывается ТОЛЬКО ПОСЛЕ установления QUIC-сессии с сервером, а у
    # hysteria2 (UDP/QUIC) на цензурируемых/throttle-сетях хендшейк бывает медленным — на
    # живом железе замерено от ~1с до ~17с (DPI по UDP 443 заставляет QUIC ретраить). Раньше
    # ждали 8с → при медленном коннекте socks не успевал, start_daemons возвращал 1, cmd_up
    # делал stop_daemons, и установщик под set -e обрывался ДО регистрации cron. Ждём до 25с
    # (запас к наблюдавшимся 15-17с). Здоровье/перебор резервов потом стерегёт watchdog.
    # Эти 25 с — СРОК ДЛЯ ФЛЕША: на накопителе к хендшейку добавляется чтение 5.2-МБ бинаря
    # (замер 448 КБ/с = 12 с), и потолок поднимает сам daemon-lib.sh — по НОСИТЕЛЮ бинаря
    # (bin_on_store), а не по каталогу: в раскладке «всё на накопителе» каталог бинарей и есть
    # накопитель, и вопрос «в хранилище ли он» отвечает «нет» про файл на флешке.
    if ! daemon_wait_port "$HY2_PID" hysteria 25 "$SOCKS_ADDR" "$SOCKS_PORT"; then
        log "hysteria не слушает $SOCKS_PORT: $DAEMON_WAIT_WHY (socks5.listen в конфиге обязан быть $SOCKS_ADDR:$SOCKS_PORT). Лог:"; tail -n 15 "$HY2_LOG" 2>/dev/null
        return 1
    fi
    socks_ours || { log "socks $SOCKS_PORT держит ЧУЖОЙ демон — наша hysteria не забиндила (несущую поверх чужого socks не поднимаю)"; return 1; }
    if ! proc_alive "$HEV_PID"; then
        log "запускаю hev (tun2socks)…"
        start-stop-daemon -S -b -m -p "$HEV_PID" -x "$HEV" -- "$HEV_YAML"
    fi
    daemon_wait_dev "$HEV_PID" hev 6 "$TUN" || {
        log "tun $TUN не создан: $DAEMON_WAIT_WHY. Лог hev:"; tail -n 15 "$HEV_LOG" 2>/dev/null; return 1; }
    return 0
}
stop_daemons() {
    # hev — с ожиданием смерти (slot-tun-lib.sh::hev_stop): за `down` в смене транспорта и в перезапуске сразу идёт `up` с новым hev
    # на тот же TUN. Нет слоя — прежний путь.
    if command -v hev_stop >/dev/null 2>&1; then hev_stop "$HEV_PID"; else start-stop-daemon -K -p "$HEV_PID" 2>/dev/null; fi
    start-stop-daemon -K -p "$HY2_PID" 2>/dev/null
    ip link del "$TUN" 2>/dev/null
    # Пидфайлы чистим СРАЗУ (как slot_stop_daemons): busybox start-stop-daemon -K их не убирает,
    # а по stale-пидфайлу proc_alive однажды попадёт в ПЕРЕИСПОЛЬЗОВАННЫЙ системой pid и решит
    # «демон жив» — start_daemons тогда его не поднимет, а несущей нет.
    rm -f "$HEV_PID" "$HY2_PID" 2>/dev/null
}

# Перезапустить ТОЛЬКО hysteria с текущим $HY2_YAML (hev/xtun не трогаем — тот же socks-порт).
# Для перебора hy2-резервов: меняем конфиг и поднимаем hysteria заново. 0 — socks снова слушает;
# 1 — не поднялась; 2 — server-host НЕ РЕЗОЛВИТСЯ (несущую не трогали) — код для cmd_failover.
restart_hy2() {
    # Резолв кандидата ДО остановки живой hysteria — зеркало restart_xray: seed_host_dns ретраит
    # до 6 раз, и всё это время демон был бы уже убит ради кандидата, который может не встать
    # вовсе (минуты «интернет есть/нет» на каждом проходе пула). Повторный сев в spawn_hysteria
    # бесплатен — seed_host_dns идемпотентен (dns-lib.sh).
    seed_server_dns || { log "restart_hy2: server-host не резолвится — несущую не трогаю"; return 2; }
    # ГОНКА РЕСТАРТА (поймана на ciadpi слота, dev43; здесь ТОТ ЖЕ класс, см. разбор в
    # xray-transport.sh::restart_xray). Ждём РЕАЛЬНОЙ смерти демона, убираем пидфайл (иначе
    # start-stop-daemon -S по нему найдёт живого и не стартует вовсе), добиваем держателя порта,
    # и лишь потом спавним; успех = «порт слушает И держит НАШ pid», а не просто «кто-то слушает».
    start-stop-daemon -K -p "$HY2_PID" 2>/dev/null
    i=0; while [ $i -lt 6 ] && proc_alive "$HY2_PID"; do sleep 1; i=$((i+1)); done
    rm -f "$HY2_PID" 2>/dev/null
    free_foreign_socks
    spawn_hysteria || { log "restart_hy2: резолв server-host не удался"; return 1; }
    # QUIC-хендшейк бывает ~15-17 с (см. start_daemons); на накопителе потолок поднимет daemon-lib.
    daemon_wait_port "$HY2_PID" hysteria 25 "$SOCKS_ADDR" "$SOCKS_PORT" || { log "restart_hy2: $DAEMON_WAIT_WHY"; return 1; }
    socks_ours
}

# Перебор hy2-резервов ВНУТРИ транспорта (зеркало cmd_failover из xray-transport.sh).
# Перебирает $ENODIA_STATE/hy2-configs/*.yaml (кроме активного) по алфавиту, встаёт на первый,
# прошедший health (egress-проба). hev/xtun не трогаем — рестартим лишь hysteria.
# Возврат: 0 — встали на рабочий hy2-резерв (.hy2-active обновлён); 1 — ни один не поднялся
# (вызывающий watchdog эскалирует: cross→awg или прямой режим).
cmd_failover() {
    [ -e "$SWITCH_LOCK" ] && { log "hy2-failover: идёт ручной switch (lock) — не перебираю"; return 1; }
    # Путь клиентов через hev мёртв, и перезапуск hev не помог — сменой сервера не вылечить (разбор — xray-transport.sh cmd_failover).
    if command -v hev_path_dead >/dev/null 2>&1 && hev_path_dead main; then
        log "hy2-failover: путь клиентов через hev мёртв и перезапуск hev не помог — серверы не перебираю, эскалация у сторожа"; return 1; fi
    # ГАРД активности hysteria. РАНЬШЕ бросали при отсутствии xtun — но xtun-устройство tun2socks
    # НЕПОСТОЯННО: смерть общего hev уносит xtun с собой (table 1000 пустеет). Это и есть отказ
    # несущей, ради которого нужна ФАЗА 0 → старый гард отсекал починку РАНЬШЕ, чем она стартовала
    # (зеркало бага xray-transport.sh, железо 2026-07-09). Теперь при отсутствии xtun отличаем
    # «hysteria вовсе не активна» от «несущая умерла» по единой истине .transport.
    if ! ip link show "$TUN" >/dev/null 2>&1; then
        [ "$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')" = hy2 ] || {
            log "hy2-failover: нет $TUN и транспорт не hy2 — hysteria не активна"; return 1; }
        log "hy2-failover: нет $TUN, но транспорт=hy2 — несущая (hev) умерла, иду в ФАЗУ 0"
    fi
    cur=$(cat "$ENODIA_STATE/.hy2-active" 2>/dev/null | tr -d ' \r\n')

    # Уже здоров? Ни чинить, ни перебирать нечего (разовая осечка сама прошла).
    if cmd_health; then log "hy2-failover: транспорт уже здоров — нечего делать"; return 0; fi

    # ФАЗА 0 — ПОЧИНКА ОБЩЕЙ НЕСУЩЕЙ (hev/xtun/socks), а НЕ перебор серверов. Зеркало
    # xray-transport.sh (hev общий на xray/hy2): смерть hev маскировалась под «сервер мёртв»,
    # и failover впустую перебирал ВСЕ конфиги (инцидент 2026-07-09). Чиним на месте: снимаем
    # осиротевший xtun, start_daemons поднимает hysteria+hev, apply_hy2_routing возвращает default→xtun.
    plumbing_down=0
    proc_alive "$HY2_PID" || plumbing_down=1
    proc_alive "$HEV_PID" || plumbing_down=1
    netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || plumbing_down=1
    if [ "$plumbing_down" = 1 ]; then
        log "hy2-failover: несущая (hysteria/hev/socks) мертва → ЧИНЮ на месте, серверы НЕ перебираю"
        proc_alive "$HEV_PID" || { start-stop-daemon -K -p "$HEV_PID" 2>/dev/null; ip link del "$TUN" 2>/dev/null; }
        if start_daemons; then
            apply_hy2_routing
            ct_flush
            if cmd_health; then
                log "hy2-failover: несущая восстановлена на текущем сервере ${cur:-?} — перебор не понадобился"
                return 0
            fi
        fi
        log "hy2-failover: починка несущей не помогла — перехожу к перебору серверов"
    fi

    tried=""; dns_dead=0; _hfwl=0
    # Аплинк пропал посреди перебора — прерываем; спрашиваем, только если он был жив НА СТАРТЕ (разбор — зеркало в
    # xray-transport.sh::cmd_failover: молчащая уже на старте проба = перебор вслепую, обрывать его ею нельзя).
    _hfw=0
    command -v wan_probe_ok >/dev/null 2>&1 && command -v wan_recheck >/dev/null 2>&1 && wan_probe_ok && _hfw=1
    for f in "$ENODIA_STATE"/hy2-configs/*.yaml; do
        [ -f "$f" ] || continue
        [ -e "$SWITCH_LOCK" ] && { log "hy2-failover: ручной switch (lock) в процессе — прерываю перебор"; return 1; }
        # VPN выключили вручную посреди перебора — дальше не пробуем (зеркало xray-transport.sh).
        carrier_barred && { log "hy2-failover: VPN выключили вручную — прерываю перебор"; break; }
        name=$(basename "$f" .yaml)
        [ "$name" = "$cur" ] && continue       # текущий (дохлый) пропускаем
        # DNS мёртв (см. restart_hy2 код 2) ⇒ сервер ПО ИМЕНИ не поднимется ничем — пропускаем,
        # не тратя 6 ретраев резолва на каждого. Кандидат по голому IP резолва не требует.
        if [ "$dns_dead" = 1 ] && ! is_ipv4 "$(hy2_server_host "$f")"; then
            log "hy2-failover: пропускаю $name — сервер задан именем, а DNS сейчас мёртв"
            continue
        fi
        log "hy2-failover: пробую $name…"
        # Провал cp (нет места на /data, битый файл) НЕ должен переписывать .hy2-active: реестр
        # соврал бы про активный сервер, а поднимался бы прежний конфиг.
        cp "$f" "$HY2_YAML" || { log "hy2-failover: не удалось положить конфиг $name — пропускаю"; continue; }
        chmod 600 "$HY2_YAML"
        echo "$name" > "$ENODIA_STATE/.hy2-active"
        restart_hy2; rc=$?
        [ "$rc" = 2 ] && { dns_dead=1; log "hy2-failover: $name не резолвится — DNS мёртв (upstream заперт в несущей)"; }
        if [ "$rc" = 0 ] && cmd_health; then
            exclude_endpoint        # анти-петля: endpoint нового резерва мимо маркировки
            ct_flush
            ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8)
            log "hy2-failover OK: встал на $name (egress ${ip:-?})"
            if [ "$(nf_lang)" = en ]; then
                notify_event "hy2-failover-ok" 1800 "BE7000: Hysteria2 failover -> $name" \
"Hysteria2 server ${cur:-?} stopped responding. The router switched to a backup
hy2 config: $name — VPN works again. External IP: ${ip:-unknown}.

Change manually: panel :8088 -> the VPN card -> pick the hy2 server."
            else
                notify_event "hy2-failover-ok" 1800 "BE7000: Hysteria2-failover -> $name" \
"Hysteria2-сервер ${cur:-?} перестал отвечать. Роутер переключился на резервный
hy2-конфиг: $name — VPN снова работает. Внешний IP: ${ip:-неизвестен}.

Сменить вручную: панель :8088 -> карточка VPN -> выбрать hy2-сервер."
            fi
            return 0
        fi
        tried="$tried $name"
        if [ "$_hfw" = 1 ] && ! wan_probe_ok && ! wan_recheck; then
            _hfwl=1; log "hy2-failover: интернет через WAN пропал посреди перебора — прерываю (недостижим любой сервер)"; break
        fi
    done
    # Ни один резерв не встал → вернём исходный активный, чтобы down/мониторинг шли по нему.
    if [ -n "$tried" ] && [ -n "$cur" ] && [ -f "$ENODIA_STATE/hy2-configs/$cur.yaml" ]; then
        cp "$ENODIA_STATE/hy2-configs/$cur.yaml" "$HY2_YAML" && chmod 600 "$HY2_YAML"
        echo "$cur" > "$ENODIA_STATE/.hy2-active"
        carrier_barred || restart_hy2 || true
    fi
    carrier_barred && { log "hy2-failover: перебор прерван — VPN выключен вручную, несущую не поднимаю"; return 1; }
    if [ "$_hfwl" = 1 ]; then
        log "hy2-failover: перебор прерван — нет интернета от провайдера (пробовал:$tried); несущая на ${cur:-текущем}"
    else
        log "hy2-failover FAIL: ни один резерв не поднялся (пробовал:${tried:- нет})"
    fi
    return 1
}

# ---- маршрутизация (xtun-слой поверх общих правил) ------------------------
apply_hy2_routing() {
    ip link set "$TUN" up 2>/dev/null
    ipt_top FORWARD -o "$TUN" -j ACCEPT
    ipt_top FORWARD -i "$TUN" -j ACCEPT
    ip route replace default dev "$TUN" table "$TABLE"
}

# ============================================================
cmd_up() {
    if ! start_daemons; then
        log "запуск не удался — несущая не поднята (оркестратор решит, что дальше)"
        stop_daemons
        return 1
    fi
    exclude_endpoint        # анти-петля: endpoint мимо маркировки ДО постановки default->xtun
    apply_hy2_routing
    set_hy2_dns
    echo hy2 > "$TRANSPORT_FLAG"
    # Сброс watchdog-состояния: ручная смена транспорта = новый «эпизод» для авто-failover.
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    carrier_up_mark         # грейс сторожу: демоны стартовали, но egress поднимается ещё секунды (clock-lib.sh)
    # Отметка «путь через hev мёртв» (slot-tun-lib.sh) — про ПРЕЖНЮЮ несущую: она общая на xray/hy2/byedpi, и без снятия до получаса
    # отказывала бы перебору только что поднятого транспорта (ревью с.93, круг 3). Свежий путь судит следующий health тика.
    if command -v hev_dead_clear >/dev/null 2>&1; then hev_dead_clear main; fi
    ct_flush
    log "транспорт = HYSTERIA2 (default table $TABLE -> $TUN). Общие правила сохранены."
    cmd_status
}

cmd_down() {
    # ЧИСТЫЙ РЕЛИНКВИШ (симметрично transport-awg/xray down): отпускаем ТОЛЬКО свою несущую
    # (xtun) → fail-open в прямой. НЕ решаем, что поднять следом, и НЕ трогаем .transport —
    # это забота ОРКЕСТРАТОРА (transport.sh switch <name>).
    stop_daemons
    iptables -D FORWARD -o "$TUN" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$TUN" -j ACCEPT 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null || true
    seed_host_clear "$SEED_CONF"           # снять сид server-host — ОБЕ копии, /etc и живую /tmp; снятое отмечено ⇒ set_direct_dns ниже перезапустит dnsmasq и при том же upstream
    set_direct_dns
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    ct_flush
    log "Hysteria2-несущая снята (релинквиш) -> прямой режим (fail-open). Следующий транспорт ставит оркестратор."
}

cmd_status() {
    # ФАКТ ФЛАГА, а не догадка (разбор — в transport-byedpi.sh cmd_status): `t=awg` печатало
    # «транспорт: awg» там, где транспорта нет вовсе. Сравнение ниже пусто ≠ hy2 — не меняется.
    t=; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    echo "=== транспорт: ${t:-(флаг пуст — транспорт не выбран)} ==="
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default   # raw-print: сырой вывод человеку в `status`, вердикта тут нет
    echo "--- демоны ---"
    proc_alive "$HY2_PID" && echo "hysteria: pid $(cat $HY2_PID) жив" || echo "hysteria: не запущен"
    proc_alive "$HEV_PID" && echo "hev:      pid $(cat $HEV_PID) жив" || echo "hev:      не запущен"
    echo "--- tun $TUN ---"; ip -o link show "$TUN" 2>/dev/null || echo "нет"
    echo "--- socks $SOCKS_PORT ---"; netstat -ltn 2>/dev/null | grep "$SOCKS_PORT" || echo "не слушает"
    if [ "$t" = hy2 ]; then
        echo "--- egress через hysteria socks ---"
        probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8; echo
    fi
    echo "--- awg0 (тёплый резерв) ---"; ip link show awg0 >/dev/null 2>&1 && echo "поднят" || echo "нет"
}

# health для watchdog: 0 = здоров ИЛИ транспорт не hy2; 1 = hy2 нездоров.
cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    [ "$t" = hy2 ] || return 0
    proc_alive "$HY2_PID" || { log "health: hysteria не жив"; return 1; }
    proc_alive "$HEV_PID" || { log "health: hev не жив"; return 1; }
    ip link show "$TUN" >/dev/null 2>&1 || { log "health: нет $TUN"; return 1; }
    ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8)
    [ -n "$ip" ] || { log "health: проба egress пуста"; return 1; }
    # Сервер жив — а путь КЛИЕНТОВ (TUN → hev → socks)? Мимо hev проба выше не видит залипшего hev (разбор и лечение —
    # slot-tun-lib.sh::hev_path_check). Нет функции (старый слой) — как раньше.
    command -v hev_path_check >/dev/null 2>&1 || return 0
    hev_path_check apply_hy2_routing
}

# ============================================================
# hy2-СЛОТ (доп-выход мульти-транспорта, Ф3) ----------------------------------------------
# Зеркало xray-слота (см. подробный разбор в xray-transport.sh): ВТОРОЙ инстанс hysteria со
# своим сервером + свой hev → свой xtunN → своя table 100N. Отличие только в конфиге: у
# hysteria это YAML, и слоту переписываем `socks5.listen` на порт слота (у xray — JSON-инбаунд).
# Логи hysteria пишет в stderr → перехватываем обёрткой sh -c (как основной путь).
# БЕЗ DNS-сеттера (dnsmasq ведёт ОСНОВНОЙ транспорт) и БЕЗ MASQUERADE (tun2socks терминирует).
# Под `[ -f ]`: провалившийся `.` убил бы весь плагин (вместе с ОСНОВНОЙ несущей) из-за отсутствия
# слотового слоя. Нет файла ⇒ деградация по контракту: слот-вербы отвечают «не умею» (код 2).
if [ -f "$ENODIA_DIR/slot-tun-lib.sh" ]; then . "$ENODIA_DIR/slot-tun-lib.sh"; else SLOT_LIB_MISSING=1; fi
slot_lib_ok() { [ -z "$SLOT_LIB_MISSING" ] && return 0
    echo "[hy2] слот-слой недоступен: нет $ENODIA_DIR/slot-tun-lib.sh — обновите скрипты" >&2; return 1; }
# Сверка «порт держит НАШ pid» нужна и ОСНОВНОМУ пути (socks_ours в шапке), а единственная
# реализация живёт в слот-слое. Нет библиотеки (старая установка) → шим «считаем наш»:
# диагностики нет, зато прежнее поведение основной несущей сохраняется байт-в-байт.
command -v slot_socks_is_ours >/dev/null 2>&1 || slot_socks_is_ours() { return 0; }
slot_srcconf()  { echo "$ENODIA_STATE/hy2-configs/$1.yaml"; }   # $1 = имя конфига
slot_conf()     { echo "$ENODIA_STATE/hysteria-s$1.yaml"; }
slot_hy2_pid()  { echo "/tmp/enodia-hysteria-s$1.pid"; }
slot_hy2_log()  { echo "/tmp/enodia-hysteria-s$1.log"; }
slot_seed()     { echo "/etc/dnsmasq.d/02-altserver-s$1.conf"; }

# Копия конфига под слот: socks5.listen 10808 → порт слота (боевой socks не трогаем).
slot_gen_conf() {   # $1 = id ; $2 = имя конфига
    _id="$1"; _src=$(slot_srcconf "$2"); _dst=$(slot_conf "$_id"); _port=$(slot_socks_port "$_id")
    [ -s "$_src" ] || { log "слот №$_id: нет конфига $_src"; return 1; }
    sed -e "s/127\.0\.0\.1:10808/127.0.0.1:$_port/" "$_src" > "$_dst" 2>/dev/null
    [ -s "$_dst" ] || { log "слот №$_id: не удалось подготовить конфиг"; return 1; }
    chmod 600 "$_dst" 2>/dev/null
    # Порт обязан попасть в конфиг: с чужим (10808) listen слот сел бы на ОСНОВНОЙ socks —
    # трафик выхода пошёл бы через основной сервер, а панель рапортовала бы «ок».
    grep -q "127.0.0.1:$_port" "$_dst" || { log "слот №$_id: в конфиге нет socks5.listen 127.0.0.1:10808 — не могу выделить порт слоту"; return 1; }
    return 0
}

slot_start_daemons() {   # $1 = id ; $2 = имя конфига
    [ -x "$HY2" ] || { log "слот №$1: НЕТ бинаря $HY2"; return 1; }
    [ -x "$HEV" ] || { log "слот №$1: НЕТ бинаря hev"; return 1; }
    _id="$1"; _port=$(slot_socks_port "$_id")
    slot_gen_conf "$_id" "$2" || return 1
    _h=$(hy2_server_host "$(slot_conf "$_id")")
    [ -n "$_h" ] || { log "слот №$_id: не нашёл server в конфиге"; return 1; }
    seed_host_dns "$_h" "$(slot_seed "$_id")" || return 1   # без резолва hysteria упала бы FATAL
    slot_free_socks "$_id" "$(slot_hy2_pid "$_id")"
    if ! proc_alive "$(slot_hy2_pid "$_id")"; then
        log "слот №$_id: запускаю hysteria на socks :$_port (конфиг $2)…"
        : > "$(slot_hy2_log "$_id")" 2>/dev/null || true
        start-stop-daemon -S -b -m -p "$(slot_hy2_pid "$_id")" -x /bin/sh -- -c "exec '$HY2' -c '$(slot_conf "$_id")' >>'$(slot_hy2_log "$_id")' 2>&1"
    fi
    if ! slot_wait_socks "$_port" "$(slot_hy2_pid "$_id")" hysteria 25; then
        log "слот №$_id: hysteria не слушает :$_port ($DAEMON_WAIT_WHY). Лог:"; tail -n 15 "$(slot_hy2_log "$_id")" 2>/dev/null
        return 1
    fi
    slot_hev_up "$_id"          # hev + ожидание xtunN (общий слой)
}
slot_stop_daemons() {   # $1 = id
    _id="$1"
    slot_hev_down "$_id"
    start-stop-daemon -K -p "$(slot_hy2_pid "$_id")" 2>/dev/null
    rm -f "$(slot_hy2_pid "$_id")" 2>/dev/null
}

# Анти-петля выхода: IP сервера слота мимо маркировки (аддитивный per-slot стор, Ф2).
slot_exclude_endpoint() {   # $1 = id
    _id="$1"
    _ep=$(hy2_endpoint_ip "$(slot_seed "$_id")" "$(slot_conf "$_id")")
    [ -n "$_ep" ] || { log "слот №$_id: endpoint не определён — пропуск анти-петли"; return 0; }
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "$_ep" >/dev/null 2>&1
    log "слот №$_id: endpoint $_ep исключён из маркировки (анти-петля)"
}

# Контракт слота (transport.sh _slot_dispatch): slot-up <id> <cfg> / slot-down <id> / slot-health <id>.
cmd_slot_up() {   # $1 = id ; $2 = имя конфига
    _id="$1"; _cfg="$2"
    case "$_id" in [2-7]) ;; *) log "слот: id = 2..7"; return 1 ;; esac
    [ -n "$_cfg" ] && [ "$_cfg" != "-" ] || { log "слот №$_id: не задан конфиг сервера"; return 1; }
    if ! slot_start_daemons "$_id" "$_cfg"; then
        log "слот №$_id: hy2-несущая не поднялась -> выход живёт по fallback-политике (mark-core)"
        slot_stop_daemons "$_id"
        return 1
    fi
    slot_exclude_endpoint "$_id"
    slot_apply_routing "$_id"
    ct_flush
    log "слот №$_id: hy2-несущая $(slot_tun "$_id") в table $(slot_table "$_id") (конфиг $_cfg)"
    return 0
}
cmd_slot_down() {   # $1 = id
    _id="$1"
    case "$_id" in [2-7]) ;; *) log "слот: id = 2..7"; return 1 ;; esac
    slot_remove_routing "$_id"
    slot_stop_daemons "$_id"
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "" >/dev/null 2>&1
    rm -f "$(slot_hev_yaml "$_id")" "$(slot_conf "$_id")" 2>/dev/null
    if seed_host_clear "$(slot_seed "$_id")"; then  # ОБЕ копии; HUP конфиг НЕ перечитывает — нужен рестарт
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
        rm -f "${DNS_RELOAD_MARK:-/tmp/enodia-dns-reload}" 2>/dev/null   # перезапустили сами — отметка снятого сида исполнена
    fi
    ct_flush
    log "слот №$_id: hy2-несущая снята"
    return 0
}
# Здоровье выхода для watchdog: 0 = жив, 1 = просел (смерть VPS видна только egress-пробой).
cmd_slot_health() {   # $1 = id
    _id="$1"
    case "$_id" in [2-7]) ;; *) return 1 ;; esac
    proc_alive "$(slot_hy2_pid "$_id")" || { log "слот №$_id health: hysteria не жива"; return 1; }
    proc_alive "$(slot_hev_pid "$_id")" || { log "слот №$_id health: hev не жив"; return 1; }
    ip link show "$(slot_tun "$_id")" >/dev/null 2>&1 || { log "слот №$_id health: нет $(slot_tun "$_id")"; return 1; }
    _ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$(slot_socks_port "$_id")" 8)
    [ -n "$_ip" ] || { log "слот №$_id health: проба egress пуста"; return 1; }
    # Сервер жив — а путь клиентов выхода через его hev? (slot-tun-lib.sh::slot_hev_path_check; нет функции — как раньше)
    command -v slot_hev_path_check >/dev/null 2>&1 || return 0
    slot_hev_path_check "$_id"
}

case "$1" in
    # Берущие несущую — через carrier_run (daemon-lib.sh), см. xray-transport.sh.
    up)       carrier_run cmd_down cmd_up ;;
    down)     cmd_down ;;
    cold)     : ;;                        # тёплого резерва нет: демонов гасит сам `down` (stop_daemons)
    status)   cmd_status ;;
    health)   carrier_run cmd_down cmd_health ;;   # залипший hev перезапускает на месте (hev_path_check) — берёт несущую
    failover) carrier_run cmd_down cmd_failover ;;
    # DNS активной несущей (DoH toggle/смена резолвера) — через doh_apply_dns. При выключенном VPN — прямой, как после `down`.
    dns)      if carrier_barred; then set_direct_dns; else set_hy2_dns; fi ;;
    # Слот-вербы ОПЦИОНАЛЬНЫ: нет слот-слоя → код 2 «не умею», основная несущая не страдает.
    slot-up)     slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_up "$2" "$3" ;;   # доп-выход (Ф3): 2-я hysteria + hev + xtunN в table 100N
    slot-down)   slot_lib_ok || exit 2; cmd_slot_down "$2" ;;      # доп-выход: снять несущую слота (-> fallback-политика mark-core)
    slot-health) slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_health "$2" ;;   # доп-выход: жив ли (watchdog); залипший hev выхода перезапускает — берёт несущую
    slot-iface)  slot_lib_ok || exit 2; slot_tun "$2" ;;           # имя несущей слота — учёту трафика (владелец имени один: slot-tun-lib.sh)
    *) echo "usage: $0 up|down|cold|status|health|failover|dns|slot-up <id> <cfg>|slot-down <id>|slot-health <id>|slot-iface <id>"; exit 2 ;;
esac
