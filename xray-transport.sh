#!/bin/sh
# xray-transport.sh — переключение ТРАНСПОРТА VPN между AmneziaWG (awg0) и Xray (xtun).
#
# ИДЕЯ. «Сменить протокол» = перенаправить default в table 1000 с awg0 на xtun (и
# обратно). Вся ОБЩАЯ маркировка (fwmark 0x1, ipset enodia_list/iplist_set, ip rule pref 99,
# цепочки VPN_EXCLUDE/VPN_FORCE, домены) НЕ трогается — Xray несёт ровно то же, что нёс
# awg. Это слой ПОВЕРХ split-route.sh: активация xray накладывает xtun-маршрут, откат —
# идемпотентный split-route.sh возвращает default dev awg0.
#
# tun2socks (hev-socks5-tunnel) создаёт TUN xtun и форвардит в локальный socks Xray
# (127.0.0.1:10808); Xray-аутбаунд — VLESS/Reality на VPS. tun2socks ТЕРМИНИРУЕТ
# соединение на роутере → MASQUERADE для xtun НЕ нужен (исходящее к VPS идёт от роутера).
#
# БЕЗОПАСНОСТЬ. Всё держится на ip rule fwmark→table 1000. Если xtun исчезнет (hev умер) —
# маршрут уходит с устройством, table 1000 пустеет, fwmark-трафик падает в main → НАПРЯМУЮ
# (fail-open, не блэкхол). awg0 при xray НЕ опускаем (тёплый резерв). Ребут = сброс к awg
# (heal). Управление/SSH (br-lan, main) от транспорта не зависят.
#
# ГРАБЛИ (доказано в тестовой обвязке): на роутере НЕТ nohup/setsid → демоны через
# start-stop-daemon -b; есть полноценный curl (с --socks5-hostname) для health-пробы.
#
# Использование:
#   xray-transport.sh up        — активировать Xray-транспорт (весь дом)
#   xray-transport.sh down      — вернуть AmneziaWG-транспорт
#   xray-transport.sh status    — показать состояние
#   xray-transport.sh health    — проверить здоровье xray-транспорта (для watchdog):
#                                 код 0 = здоров / транспорт не xray; 1 = xray нездоров

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
# Где лежит бинарь (store-lib.sh). Без внешнего накопителя — прежний путь БАЙТ-В-БАЙТ; при
# оффлоаде тяжёлый xray живёт на накопителе, а мелкий hev может остаться на флеше — bin_path
# судит по факту, отдельного реестра «что где» нет. Шим на случай установки без lib.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Ожидание СТАРТА демона (daemon-lib.sh). Фиксированный срок мерил не то: 8 с верны для флеша
# (1.4 ГБ/с) и заведомо малы для накопителя (замер 448 КБ/с ⇒ 8-МБ xray читается 18 с) — исправный
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
SOCKS_PORT=10808
XRAY=$(bin_path xray)
HEV=$(bin_path hev)
XRAY_JSON="$ENODIA_STATE/xray.json"
HEV_YAML="$ENODIA_DIR/hev.yaml"
XRAY_PID=/tmp/enodia-xray.pid
HEV_PID=/tmp/enodia-hev.pid
XRAY_LOG=/tmp/xray.log
HEV_LOG=/tmp/enodia-hev.log
TRANSPORT_FLAG="$ENODIA_STATE/.transport"
SWITCH_LOCK=/tmp/enodia-switching.lock       # ручной switch (панель/меню) держит его → авто-failover прерывается (Fix C 2026-07-09)
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"
APPLY_BYPASS="$ENODIA_DIR/apply-bypass.sh"
SEED_CONF="/etc/dnsmasq.d/02-altserver.conf" # локальный dnsmasq-ответ server-host->IP (демон резолвит имя сам)
DNS1=1.1.1.1
DNS2=8.8.8.8
FWMARK=0x1

log() { echo "[xray-transport] $*"; }
notify_event() { [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

# ВАЖНО: пустой/0-байтовый пидфайл = НЕ жив. На busybox `kill -0 ""` возвращает 0 (успех) →
# наивная проверка `kill -0 "$(cat pid)"` дала бы ЛОЖНЫЙ «процесс жив» на пустом пидфайле
# (бывает при оборванной записи start-stop-daemon -m) → start_daemons НЕ перезапустил бы демон.
proc_alive() { p=$(cat "$1" 2>/dev/null | tr -d ' \r\n'); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
# «Порт слушает» ≠ «слушает НАШ демон»: уходящий предшественник держит бинд ещё несколько секунд,
# а чужой (осиротевшая hysteria/ciadpi после свопа альта) — сколько угодно. Проверка по одному
# netstat рапортовала бы успех, хотя наш xray не забиндил и умер, а трафик пошёл бы через ЧУЖОЙ
# socks (egress чужого сервера при «всё ок» в панели). Владельца сверяет ОДНА реализация на
# проект — slot_socks_is_ours (slot-tun-lib.sh, параметризована портом+пидфайлом; держатель не
# определился = считаем наш, из-за отсутствия netstat -p рабочий путь не роняем).
socks_ours() { slot_socks_is_ours "$SOCKS_PORT" "$XRAY_PID"; }

# ---- резолв сервера по имени (анти-FATAL на старте) ----
# ЗАЧЕМ: xray-конфиг почти всегда задаёт address ПО ИМЕНИ (vless://…@host…). xray
# резолвит это имя при старте через системный resolver (dnsmasq -> 1.1.1.1, а он в
# iplist_set -> маркирован в туннель, который ещё НЕ поднят) -> dial fails.
# resolve_ipv4/is_ipv4 живут в dns-lib.sh — ОДНОЙ копией на все три несущие (была
# продублирована сюда и в transport-hy2.sh «зеркалом», awg нужна та же; расхождение копий
# = вопрос времени). Грабли busybox-резолва и порядок «dnsmasq → DoH» описаны там же.
# Сорсим ТОЛЬКО под `[ -f ]`: провалившийся `.` в ash — фатальная ошибка спецбилтина, шелл выходит
# НА МЕСТЕ и МОЛЧА (rc=2, `|| true` не спасает). Библиотека здесь не опциональна — без резолва
# endpoint'а несущая не поднимется вовсе, поэтому отказываем ЧЕСТНО, а не умираем без слова.
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; else
    echo "[xray] нет $ENODIA_DIR/dns-lib.sh — обновите установку (панель → «Обновление» или переустановка с компьютера)" >&2; exit 1
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
# Язык письма/события о xray-failover — панельный pref lang (деф. ru). Шим на случай установки без файла.
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
# Отметка «несущую только что подняли» (clock-lib.sh) — грейс сторожу: демоны стартуют быстрее,
# чем поднимается egress, и тик в этом зазоре красил живой канал в SUSPECT. Шим = прежнее
# поведение (грейса нет). [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v carrier_up_mark >/dev/null 2>&1 || carrier_up_mark() { return 0; }
# Имя/IP сервера ИЗ АУТБАУНДА xray.json (vless vnext.address / vmess / ss servers). НЕ «первый
# address во всём файле»: dns/routing-секция тоже содержит "address" (напр. "dns":{"servers":
# [{"address":"8.8.8.8"}]}), и если она идёт РАНЬШЕ outbounds — старый парс брал DNS-резолвер
# → seed не ставился, реальный сервер резолвился через ещё-не-поднятый туннель (бутстрап-FATAL),
# а exclude_endpoint исключал НЕ ТОТ IP → реальный endpoint оставался в iplist_set = петля.
# Сужаем до части файла ПОСЛЕ "outbounds" (конфиг сводим в одну строку — работает и для
# мультистрочного, и для минифицированного JSON). Нет "outbounds" → фолбэк на прежнее поведение.
# $1 — файл конфига (деф. боевой $XRAY_JSON); параметр нужен доп-выходам (Ф3): у слота свой
# xray-s<id>.json, а парс сервера обязан быть ОДНОЙ реализацией (иначе копия разойдётся —
# ровно тот случай, из-за которого resolve_ipv4 вынесен в dns-lib.sh).
xray_server_host() {
    { tr -d '\r\n' < "${1:-$XRAY_JSON}" 2>/dev/null; } \
        | sed 's/.*"outbounds"/"outbounds"/' \
        | grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/'
}
# Кладёт ответ для server-host в ЛОКАЛЬНЫЙ dnsmasq (address=/host/IP) — демон резолвит
# имя сам, мгновенно локально, не уходя в ещё-не-поднятый туннель. Конфиг НЕ трогаем
# (имя остаётся; SNI берётся из него же). $SEED_CONF — изолированный файл. Возврат 1 =
# не зарезолвили -> честно не поднимаемся (иначе xray молча падал бы dial-ом).
# Сам сев (резолв + address=/host/IP + перезапуск dnsmasq + ожидание ответа) живёт в
# dns-lib.sh::seed_host_dns — ОДНОЙ копией на xray/hy2 и их доп-выходы (у слота свой seed-файл).
seed_server_dns() {
    [ -s "$XRAY_JSON" ] || { log "нет $XRAY_JSON"; return 1; }
    _h=$(xray_server_host)
    [ -n "$_h" ] || { log "не нашёл address в $XRAY_JSON"; return 1; }
    seed_host_dns "$_h" "$SEED_CONF"
}

# ---- анти-петля: endpoint своего VPS мимо маркировки ----------------------
# IP endpoint'а xray-сервера: сперва из сида (точный IP, который пойдёт в dial),
# фолбэк — address из конфига, если он сразу IP. Только IPv4 (iplist_set = cidr4).
# $1 — seed-файл (деф. боевой), $2 — конфиг (деф. боевой): параметры для доп-выходов (Ф3).
xray_endpoint_ip() {
    _ip=$(sed -n 's%^address=/[^/]*/%%p' "${1:-$SEED_CONF}" 2>/dev/null | head -1)
    [ -n "$_ip" ] && { echo "$_ip"; return 0; }
    _h=$(xray_server_host "${2:-$XRAY_JSON}")
    echo "$_h" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && echo "$_h"
}
# Исключить endpoint xray-сервера из маркировки (иначе свои же пакеты к VPS, если его
# IP в iplist_set, заворачиваются в xtun = петля). Зовём ДО постановки default->xtun.
exclude_endpoint() {
    ep=$(xray_endpoint_ip)
    [ -n "$ep" ] || { log "endpoint xray не определён — пропуск анти-петли"; return 0; }
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-set "$ep" >/dev/null 2>&1
    log "endpoint $ep исключён из маркировки (анти-петля)"
}

# ---- DNS ------------------------------------------------------------------
# В xray-режиме внутренний Amnezia-DNS (172.29.x dev awg0) ненадёжен (при
# заблокированном awg awg0 мёртв) → ведём DNS НЕЗАВИСИМО: публичный резолвер,
# принудительно маркированный в туннель (уйдёт в xtun→xray, не утечёт).
set_xray_dns() {
    # DoH ВКЛ → резолв через локальный прокси в туннель; ВЫКЛ → ниже как было. DOH_APPLY_NOTE — слово
    # библиотеки о том, что резолвер пришлось увести МИМО ещё не везущей несущей (см. doh_apply_dns).
    if doh_apply_dns tunnel; then [ -n "${DOH_APPLY_NOTE:-}" ] && log "DoH: $DOH_APPLY_NOTE"; return 0; fi
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -C OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null || \
            iptables -t mangle -A OUTPUT -d "$d" -j MARK --set-mark $FWMARK
    done
    dns_upstream_put "$DNS1" "$DNS2"
}
# Прямой DNS (релинквиш / прямой режим): публичный резолвер БЕЗ маркировки в туннель
# (туннеля нет → к 1.1.1.1/8.8.8.8 надо идти мимо). Снимаем и OUTPUT-mark, что вешал
# set_xray_dns. Зеркало DNS-части switch-vpn.sh safety_off, но для xray (нет awg0/awg.conf).
set_direct_dns() {
    # Снятие СВОЕЙ туннельной марки идёт ДО ветки DoH: она наша (её вешал set_xray_dns), и в
    # прямом режиме не нужна НИКОМУ — ни с DoH, ни без. Раньше выход по `doh_apply_dns` случался
    # раньше этих строк ⇒ при включённом «Шифрованном DNS» релинквиш оставлял `mangle OUTPUT -d
    # 1.1.1.1/8.8.8.8 -j MARK 0x1` жить дальше: роутер-локальные пакеты к этим адресам продолжали
    # метиться в table 1000 (у byedpi это xtun→ciadpi — DNS/пробы под десинком без нужды).
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -D OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null
    done
    doh_apply_dns direct && return 0    # DoH ВКЛ (или авто-режим прямых) → резолв через локальный прокси; иначе → ниже как было
    dns_upstream_put "$DNS1" "$DNS2"
}

# Погасить access-лог в УЖЕ ЛЕЖАЩЕМ конфиге. ЗАЧЕМ отдельным шагом, а не только в генераторах
# (panel.js/subs-update.sh уже пишут "none"): конфиг живёт на /data и переживает обновление
# скриптов — у того, кто установился раньше, внутри остаётся путь /tmp/xray-access.log, и демон
# продолжает лить в ОЗУ ~15 МБ/сут (замер 29.08.2026: 5.5 МБ за 9 ч). Правим ЖИВОЙ конфиг перед
# каждым стартом: место единственное, через которое проходят все пути подъёма (boot, switch,
# failover, смена сервера). Идемпотентно И ДЁШЕВО: без совпадения файла не касаемся вовсе —
# /data смонтирован sync, лишняя запись тут стоит износа флеша. Пишем через `cat >`, а не mv:
# у конфига права 600, а mv принёс бы права ВРЕМЕННОГО файла.
access_off() {   # $1 = json-конфиг xray; $2 = "keep" — накопленный лог НЕ удалять (демон может быть жив)
    ACCESS_FIXED=0
    [ -f "$1" ] || return 0
    _aold=$(sed -n 's#.*"access"[[:space:]]*:[[:space:]]*"\(/tmp/[^"]*\)".*#\1#p' "$1" 2>/dev/null | head -n1)
    [ -n "$_aold" ] || return 0
    # umask в ПОДОБОЛОЧКЕ: у конфига права 600, потому что в нём креды сервера, и временная
    # копия обязана быть такой же. Перенаправление создаёт файл ДО того, как успел бы сработать
    # chmod, — значит право отбирать надо ЗАРАНЕЕ, а не после.
    ( umask 077; sed 's#\("access"[[:space:]]*:[[:space:]]*\)"/tmp/[^"]*"#\1"none"#' "$1" > "$1.acc" ) 2>/dev/null
    if [ -s "$1.acc" ] && cat "$1.acc" > "$1" 2>/dev/null; then
        ACCESS_FIXED=1
        log "в конфиге $(basename "$1") погашен access-лог xray ($_aold рос в ОЗУ)"
        # Накопленное освобождаем ЗДЕСЬ ЖЕ, но ТОЛЬКО ПОСЛЕ удачной правки: демон в этот момент
        # не жив (нас зовут только из spawn_xray). Правка не удалась — файл ОСТАВЛЯЕМ: он ещё
        # нужен демону, который сейчас поднимется со СТАРЫМ конфигом и продолжит в него писать.
        # …А из access-purge (обновление кода) демон КАК РАЗ ЖИВ и пишет в этот файл: удалить его
        # там значило бы отобрать inode у живого писателя — место не вернулось бы, а лог рос бы
        # НЕВИДИМЫМ. Поэтому такой вызывающий просит "keep" и чистит лог сам, когда демон умрёт.
        [ "$2" = keep ] || rm -f "$_aold" 2>/dev/null
    fi
    rm -f "$1.acc" 2>/dev/null
    return 0
}

# Прогнать access_off по ВСЕМУ, что лежит: активный конфиг + весь каталог xray-configs/.
# ЗАЧЕМ отдельным вербом, если spawn_xray и так лечит активный: конфиги живут на /data и
# переживают обновление кода, а лечится РОВНО тот, который сейчас поднимают. У тестера с
# подпиской их 137, и путь /tmp/xray-access.log лежал во ВСЕХ (замер 31.08.2026) — значит
# при каждом failover-переборе кандидат приезжал с путём и лечился уже на месте, лишней
# записью на смонтированный sync-ом флеш, а любой НОВЫЙ путь подъёма, забывший позвать
# access_off, снова потёк бы в ОЗУ по 15 МБ/сут. Дешевле починить хранилище один раз.
# Зовут нас те, кто раскладывает код: install.sh (ПК/мастер) и gh-update.sh после удачного
# apply-scripts (обновление из панели) — больше некому, обновление пофайловое и install.sh
# по нему не приезжает. Демон при этом МОЖЕТ БЫТЬ ЖИВ ⇒ "keep": накопленный лог не трогаем.
cmd_access_purge() {
    _apn=0; _apt=0
    for _apf in "$XRAY_JSON" "$ENODIA_STATE"/xray-configs/*.json; do
        [ -f "$_apf" ] || continue          # пустой каталог ⇒ glob приедет литералом
        _apt=$((_apt+1))
        access_off "$_apf" keep
        if [ "$ACCESS_FIXED" = 1 ]; then _apn=$((_apn+1)); fi
    done
    log "access-purge: просмотрено конфигов $_apt, вычищено $_apn"
    return 0
}

# ---- демоны ---------------------------------------------------------------
# Запуск xray в фоне С ЗАХВАТОМ вывода в $XRAY_LOG. ЗАЧЕМ: start-stop-daemon -b при
# демонизации уводит stdio демона в /dev/null → если xray-конфиг не задаёт лог-файл, причина
# сбоя (socks не поднялся: кривой сервер/sni/ключи/порт) была НЕВИДНА — tail "$XRAY_LOG" и в
# start_daemons, и в диагностике установщика выдавал пусто. Обёртка `sh -c 'exec … >>log 2>&1'`
# переоткрывает stdout/stderr УЖЕ ПОСЛЕ демонизации (внутри sh, до exec) → лог пишется; exec
# сохраняет PID для pidfile. -x /bin/sh безопасен: дедуп на proc_alive (по пидфайлу), а -K в
# stop/restart матчит по -p, не по -x.
spawn_xray() {
    : > "$XRAY_LOG" 2>/dev/null || true
    access_off "$XRAY_JSON"                # старый конфиг мог нести /tmp/xray-access.log
    seed_server_dns || return 1            # посеять server-host->IP в локальный dnsmasq; 1 = не зарезолвили
    start-stop-daemon -S -b -m -p "$XRAY_PID" -x /bin/sh -- -c "exec '$XRAY' run -c '$XRAY_JSON' >>'$XRAY_LOG' 2>&1"
}

# Освободить socks-порт, если его держит ЧУЖОЙ процесс. ЗАЧЕМ: xray и hysteria
# делят ОДИН socks 10808 и общий hev → провайдер socks должен быть РОВНО один.
# При свопе альта (reinstall xray<->hy2) старый демон остаётся ЖИВ (purge-alt
# убирает лишь файл-бинарь, не процесс) и держит порт → наш xray не забиндит и
# молча умрёт ("bind: address already in use"), а netstat увидит ЧУЖОГО слушателя
# → start_daemons вернул бы ЛОЖНЫЙ успех, hev пошёл бы через старый протокол
# (egress чужого сервера, не нашего). Поэтому перед стартом бьём чужого держателя.
free_foreign_socks() {
    own=$(cat "$XRAY_PID" 2>/dev/null | tr -d ' \r\n')
    holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$SOCKS_PORT " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$holder" in ''|*[!0-9]*) return 0 ;; esac   # никто не слушает / pid не распарсился
    [ "$holder" = "$own" ] && return 0                 # уже наш xray
    log "socks $SOCKS_PORT держит чужой pid $holder — освобождаю (своп альта/рестарт)"
    kill "$holder" 2>/dev/null
    i=0; while [ $i -lt 5 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || break; sleep 1; i=$((i+1)); done
}
start_daemons() {
    [ -x "$XRAY" ] || { log "НЕТ бинаря $XRAY — поставьте его в панели: «Компоненты»"; return 1; }
    [ -x "$HEV" ]  || { log "НЕТ бинаря $HEV"; return 1; }
    [ -s "$XRAY_JSON" ] || { log "НЕТ конфига $XRAY_JSON — добавьте xray-конфиг (меню)"; return 1; }
    [ -s "$HEV_YAML" ]  || { log "НЕТ $HEV_YAML"; return 1; }

    free_foreign_socks   # выгнать оставшийся hysteria/чужой демон с порта 10808
    if ! proc_alive "$XRAY_PID"; then
        log "запускаю xray…"
        spawn_xray || { log "xray не запущен: не удалось зарезолвить server-host. Лог:"; tail -n 15 "$XRAY_LOG" 2>/dev/null; return 1; }
    fi
    # Ждём порт, ПОКА ЖИВ ПРОЦЕСС (daemon-lib.sh): 8 с — срок для флеша, на накопителе владелец
    # поднимет потолок сам. Труп же не ждём вовсе — отказ приходит сразу и НАЗЫВАЕТ причину.
    if ! daemon_wait_port "$XRAY_PID" xray 8 "$SOCKS_ADDR" "$SOCKS_PORT"; then
        log "xray не слушает $SOCKS_PORT: $DAEMON_WAIT_WHY. Лог:"; tail -n 15 "$XRAY_LOG" 2>/dev/null
        return 1
    fi
    socks_ours || { log "socks $SOCKS_PORT держит ЧУЖОЙ демон — наш xray не забиндил (несущую поверх чужого socks не поднимаю)"; return 1; }
    if ! proc_alive "$HEV_PID"; then
        log "запускаю hev (tun2socks)…"
        start-stop-daemon -S -b -m -p "$HEV_PID" -x "$HEV" -- "$HEV_YAML"
    fi
    daemon_wait_dev "$HEV_PID" hev 6 "$TUN" || {
        log "tun $TUN не создан: $DAEMON_WAIT_WHY. Лог hev:"; tail -n 15 "$HEV_LOG" 2>/dev/null; return 1; }
    return 0
}
stop_daemons() {
    start-stop-daemon -K -p "$HEV_PID"  2>/dev/null
    start-stop-daemon -K -p "$XRAY_PID" 2>/dev/null
    ip link del "$TUN" 2>/dev/null
    # Пидфайлы чистим СРАЗУ (как slot_stop_daemons/slot_hev_down): busybox start-stop-daemon -K
    # их не убирает, а по stale-пидфайлу proc_alive рано или поздно попадёт в ПЕРЕИСПОЛЬЗОВАННЫЙ
    # системой pid и решит «демон жив» — start_daemons его тогда не поднимет, а несущей нет.
    rm -f "$HEV_PID" "$XRAY_PID" 2>/dev/null
}

# Перезапустить ТОЛЬКО xray с текущим $XRAY_JSON (hev/xtun не трогаем — тот же
# socks-порт). Для перебора xray-резервов: меняем конфиг и поднимаем xray заново.
# Возврат: 0 — socks снова слушает; 1 — не поднялся; 2 — server-host НЕ РЕЗОЛВИТСЯ (несущую при
# этом НЕ трогали, см. ниже) — код нужен cmd_failover, чтобы отличить «сервер мёртв» от «DNS мёртв».
restart_xray() {
    # Резолв кандидата ДО остановки живого демона. ЗАЧЕМ: seed_host_dns ретраит до 6 раз (десятки
    # секунд), и всё это время старый xray был бы уже убит — маркированный трафик в чёрную дыру
    # РАДИ КАНДИДАТА, который может вовсе не подняться. Порядок «убить → резолвить» стоил юзеру
    # (лог 01.08.2026) минут мигания «интернет есть/нет» на каждом проходе пула. Повторный
    # seed_server_dns внутри spawn_xray бесплатен — сев идемпотентен (dns-lib.sh).
    seed_server_dns || { log "restart_xray: server-host не резолвится — несущую не трогаю"; return 2; }
    # ГОНКА РЕСТАРТА (поймана на ciadpi слота, dev43; здесь ТОТ ЖЕ класс). Демон умирает по
    # SIGTERM не мгновенно, а бинд отпускает ещё позже. Прежний порядок «убить → подождать
    # освобождения порта (4 с) → спавнить → порт слушает = успех» давал ЛОЖНЫЙ УСПЕХ двумя путями:
    #   * порт ещё занят — новый xray не забиндил и молча вышел, а netstat видел СТАРОГО;
    #   * пидфайл не убран — start-stop-daemon -S находит по нему ЖИВОЙ процесс и не стартует вовсе.
    # Цена: failover рапортовал «встал на резерв N», .xray-active переписан, egress-проба прошла
    # через ещё живого предшественника — а через миг транспорта нет вовсе (до тика сторожа).
    # Порядок как в restart_byedpi: ждём РЕАЛЬНОЙ смерти, убираем пидфайл, добиваем держателя
    # порта (своего пидфайла уже нет ⇒ он «чужой»), спавним, успех = «слушает И это НАШ pid».
    start-stop-daemon -K -p "$XRAY_PID" 2>/dev/null
    i=0; while [ $i -lt 6 ] && proc_alive "$XRAY_PID"; do sleep 1; i=$((i+1)); done
    rm -f "$XRAY_PID" 2>/dev/null
    free_foreign_socks
    spawn_xray || { log "restart_xray: резолв server-host не удался"; return 1; }
    daemon_wait_port "$XRAY_PID" xray 8 "$SOCKS_ADDR" "$SOCKS_PORT" || { log "restart_xray: $DAEMON_WAIT_WHY"; return 1; }
    socks_ours
}

# health с прогревочным повтором: ПО ОДНОМУ на кандидата, и не больше XRAY_WARM_TRIES на прогон.
# ЗАЧЕМ: проба egress идёт сразу после подъёма демона, а свежий outbound ХОЛОДНЫЙ — первое
# соединение несёт полное рукопожатие (Reality/TLS) до сервера. На железе 01.09.2026 перебор
# объявил «ни один резерв не поднялся», хотя тот же конфиг в тот же час отвечал 3/3 за 1.3 с через
# временный инстанс; цена ошибки несимметрична — роутер уходит cross на ДРУГОЙ транспорт.
# ПОЧЕМУ БЮДЖЕТ ОГРАНИЧЕН: повтор стоит целого таймаута на КАЖДОМ мёртвом кандидате, а конфигов
# бывает десятки (история «перебирал 60 конфигов») — потолок обязан быть в секундах, не в минутах.
# ПОЧЕМУ НЕ ОДИН НА ПРОГОН (первая редакция 03.09.2026): единственный повтор доставался ПЕРВОМУ ЖЕ
# мёртвому кандидату, и живой-но-холодный резерв следом шёл с одной пробой, то есть объявлялся
# мёртвым ровно по той причине, от которой повтор и заводили (железо 05.09.2026: повтор ушёл AMS3,
# KZ повезло с первой пробы — а не повезло бы, роутер ушёл бы cross при рабочем резерве). Теперь
# повтор есть у КАЖДОГО кандидата, пока не кончится бюджет прогона (три × 8 с пробы = +24 с в худшем
# случае); дальше кандидаты идут с одной пробой, как прежде. Стенд local/xray-warm-budget-test.sh.
XRAY_WARM_TRIES=${XRAY_WARM_TRIES:-3}
health_warm() {
    cmd_health && return 0
    [ "${WARM_LEFT:-0}" -gt 0 ] 2>/dev/null || return 1
    WARM_LEFT=$((WARM_LEFT - 1))
    log "health: первая проба пуста — даю прогревочный повтор (холодный outbound; в бюджете прогона осталось $WARM_LEFT)"
    cmd_health
}

# Перебор xray-резервов ВНУТРИ xray-транспорта (зеркало do_failover из switch-vpn).
# Перебирает $ENODIA_STATE/xray-configs/*.json (кроме активного) по алфавиту, встаёт на
# первый, прошедший health (egress-проба). hev/xtun не трогаем — рестартим лишь xray.
# Возврат: 0 — встали на рабочий xray-резерв (.xray-active обновлён); 1 — ни один не
# поднялся (вызывающий watchdog эскалирует: cross→awg или прямой режим).
cmd_failover() {
    [ -e "$SWITCH_LOCK" ] && { log "xray-failover: идёт ручной switch (lock) — не перебираю"; return 1; }
    # Путь клиентов через hev мёртв, и перезапуск hev не помог (slot-tun-lib.sh::hev_path_dead) — сменой сервера его не вылечить, а
    # «уже здоров» ниже (socks-проба) крутило бы лестницу по кругу, не доходя до cross и прямого режима (ревью с.93, круг 2).
    if command -v hev_path_dead >/dev/null 2>&1 && hev_path_dead main; then
        log "xray-failover: путь клиентов через hev мёртв и перезапуск hev не помог — серверы не перебираю, эскалация у сторожа"; return 1; fi
    WARM_LEFT=$XRAY_WARM_TRIES   # бюджет прогревочных повторов health на ВЕСЬ прогон (см. health_warm)
    # ГАРД активности xray. РАНЬШЕ бросали при отсутствии xtun — но xtun-устройство tun2socks
    # НЕПОСТОЯННО: смерть hev уносит xtun с собой (table 1000 пустеет). Это и есть отказ несущей,
    # ради которого нужна ФАЗА 0 → старый гард отсекал починку РАНЬШЕ, чем она стартовала
    # (железо 2026-07-09: kill -9 hev → xtun ABSENT → failover бросал «xray не активен» rc=1,
    # ФАЗА 0 не выполнялась). Теперь при отсутствии xtun отличаем «xray вовсе не активен» от
    # «несущая умерла» по единой истине .transport (устройство как признак активности ненадёжно).
    if ! ip link show "$TUN" >/dev/null 2>&1; then
        [ "$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')" = xray ] || {
            log "xray-failover: нет $TUN и транспорт не xray — xray не активен"; return 1; }
        log "xray-failover: нет $TUN, но транспорт=xray — несущая (hev) умерла, иду в ФАЗУ 0"
    fi
    cur=$(cat "$ENODIA_STATE/.xray-active" 2>/dev/null | tr -d ' \r\n')

    # Уже здоров? Ни чинить, ни перебирать нечего (watchdog иногда зовёт failover после разовой
    # осечки, которая уже сама прошла) — не трогаем рабочий транспорт.
    if cmd_health; then log "xray-failover: транспорт уже здоров — нечего делать"; return 0; fi

    # ФАЗА 0 — ПОЧИНКА ОБЩЕЙ НЕСУЩЕЙ, а НЕ перебор серверов. hev (tun2socks/xtun) и socks 10808
    # ОБЩИЕ для всех xray-конфигов: если умер hev/сокет, health не пройдёт НИ ОДИН сервер (проба
    # egress идёт через socks→xray, но пакеты в интернет несёт hev). Прежде это маскировалось под
    # «сервер мёртв», и failover бесполезно перебирал ВСЕ конфиги (инцидент 2026-07-09: ~60 штук,
    # в логе на каждом «health: hev не жив», внешний IP уехал на случайный чужой сервер). Чиним
    # несущую НА МЕСТЕ: если умер hev — снимаем осиротевший xtun, start_daemons поднимает xray+hev
    # заново, apply_xray_routing возвращает default→xtun (маршрут исчез вместе с рестартнутым xtun).
    plumbing_down=0
    proc_alive "$XRAY_PID" || plumbing_down=1
    proc_alive "$HEV_PID"  || plumbing_down=1
    netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || plumbing_down=1
    if [ "$plumbing_down" = 1 ]; then
        log "xray-failover: несущая (xray/hev/socks) мертва → ЧИНЮ на месте, серверы НЕ перебираю"
        proc_alive "$HEV_PID" || { start-stop-daemon -K -p "$HEV_PID" 2>/dev/null; ip link del "$TUN" 2>/dev/null; }
        if start_daemons; then
            apply_xray_routing
            ct_flush
            if health_warm; then
                log "xray-failover: несущая восстановлена на текущем сервере ${cur:-?} — перебор серверов не понадобился"
                return 0
            fi
        fi
        log "xray-failover: починка несущей не помогла — перехожу к перебору серверов"
    fi

    tried=""; dns_dead=0; _xfwl=0
    # АПЛИНК ПРОПАЛ ПОСРЕДИ ПЕРЕБОРА — дальше перебирать незачем: недостижим ЛЮБОЙ сервер, а свип у подписок идёт десятками
    # конфигов (BE7000 02.10.2026: ~70 кандидатов, 20 минут при лёгшем провайдере). Спрашиваем после КАЖДОГО промаха —
    # при живом WAN проба стоит доли секунды против ~17 с на кандидата. Но ТОЛЬКО если аплинк был жив НА СТАРТЕ: молчит проба
    # уже здесь ⇒ перебор идёт вслепую (контрольный свип сторожа на случай пробы, которую режет провайдер), и обрывать его ею
    # же — значит обрывать всегда. Нет владельца (старая ip-lib) — не спрашиваем вовсе, как раньше.
    _xfw=0
    command -v wan_probe_ok >/dev/null 2>&1 && command -v wan_recheck >/dev/null 2>&1 && wan_probe_ok && _xfw=1
    for f in "$ENODIA_STATE"/xray-configs/*.json; do
        [ -f "$f" ] || continue
        [ -e "$SWITCH_LOCK" ] && { log "xray-failover: ручной switch (lock) в процессе — прерываю перебор"; return 1; }
        # VPN выключили вручную посреди перебора — дальше не пробуем: каждый кандидат поднимал бы демон при «выключенном» VPN.
        # Конфиг возвращаем исходный (ниже), демон не поднимаем; поднятое снимет обёртка верба (carrier_run).
        carrier_barred && { log "xray-failover: VPN выключили вручную — прерываю перебор"; break; }
        name=$(basename "$f" .json)
        [ "$name" = "$cur" ] && continue       # текущий (дохлый) пропускаем
        # DNS признан мёртвым на прошлом кандидате ⇒ сервер ПО ИМЕНИ не поднимется НИКАКОЙ:
        # upstream dnsmasq заперт в снятой несущей, WAN-DoH тоже промолчал. Пробовать такого
        # кандидата = 6 ретраев резолва впустую (ровно из этого складывались «минуты мигания»).
        # А вот кандидат по ГОЛОМУ IP резолва не требует — его перебор продолжаем.
        if [ "$dns_dead" = 1 ] && ! is_ipv4 "$(xray_server_host "$f")"; then
            log "xray-failover: пропускаю $name — сервер задан именем, а DNS сейчас мёртв"
            continue
        fi
        log "xray-failover: пробую $name…"
        # Провал cp (нет места на /data, битый файл) НЕ должен переписывать .xray-active: реестр
        # соврал бы про активный сервер, а поднимался бы прежний конфиг.
        cp "$f" "$XRAY_JSON" || { log "xray-failover: не удалось положить конфиг $name — пропускаю"; continue; }
        chmod 600 "$XRAY_JSON"
        echo "$name" > "$ENODIA_STATE/.xray-active"
        restart_xray; rc=$?
        [ "$rc" = 2 ] && { dns_dead=1; log "xray-failover: $name не резолвится — DNS мёртв (upstream заперт в несущей)"; }
        if [ "$rc" = 0 ] && health_warm; then
            exclude_endpoint        # анти-петля: endpoint нового резерва мимо маркировки
            ct_flush
            ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8)
            log "xray-failover OK: встал на $name (egress ${ip:-?})"
            if [ "$(nf_lang)" = en ]; then
                notify_event "xray-failover-ok" 1800 "BE7000: Xray failover -> $name" \
"Xray server ${cur:-?} stopped responding. The router switched to a backup
xray config: $name — VPN works again. External IP: ${ip:-unknown}.

Change manually: panel :8088 -> the VPN card -> pick the xray server."
            else
                notify_event "xray-failover-ok" 1800 "BE7000: Xray-failover -> $name" \
"Xray-сервер ${cur:-?} перестал отвечать. Роутер переключился на резервный
xray-конфиг: $name — VPN снова работает. Внешний IP: ${ip:-неизвестен}.

Сменить вручную: панель :8088 -> карточка VPN -> выбрать xray-сервер."
            fi
            return 0
        fi
        tried="$tried $name"
        if [ "$_xfw" = 1 ] && ! wan_probe_ok && ! wan_recheck; then
            _xfwl=1; log "xray-failover: интернет через WAN пропал посреди перебора — прерываю (недостижим любой сервер)"; break
        fi
    done
    # Ни один резерв не встал. Если мы что-то пробовали (xray.json уже перезаписан
    # дохлым кандидатом) — вернём исходный активный, чтобы down/мониторинг шли по нему.
    # Если резервов не было вовсе ($tried пуст) — xray.json не трогали, рестарт не нужен.
    if [ -n "$tried" ] && [ -n "$cur" ] && [ -f "$ENODIA_STATE/xray-configs/$cur.json" ]; then
        cp "$ENODIA_STATE/xray-configs/$cur.json" "$XRAY_JSON" && chmod 600 "$XRAY_JSON"
        echo "$cur" > "$ENODIA_STATE/.xray-active"
        carrier_barred || restart_xray || true
    fi
    carrier_barred && { log "xray-failover: перебор прерван — VPN выключен вручную, несущую не поднимаю"; return 1; }
    # Формулировка РАЗНАЯ на два разных исхода. «FAIL: ни один резерв не поднялся (пробовал: нет)»
    # обвиняло перебор там, где перебирать было нечего: у человека ОДИН сервер, и в логе каждые
    # две минуты появлялась строка про несуществующие резервы — она уводила разбор в сторону от
    # настоящей причины (умирает сама несущая). Пустой список — это не провал перебора, а его
    # отсутствие, и сказать надо ровно это.
    if [ "$_xfwl" = 1 ]; then
        log "xray-failover: перебор прерван — нет интернета от провайдера (пробовал:$tried); несущая на ${cur:-текущем}"
    elif [ -z "$tried" ]; then
        log "xray-failover: резервных конфигов нет — переключаться некуда, несущая осталась на ${cur:-текущем}"
    else
        log "xray-failover FAIL: ни один резерв не поднялся (пробовал:$tried)"
    fi
    return 1
}

# ---- маршрутизация (xtun-слой поверх общих правил) ------------------------
apply_xray_routing() {
    ip link set "$TUN" up 2>/dev/null
    # FORWARD ACCEPT для xtun (как у awg0; filter FORWARD policy = DROP)
    ipt_top FORWARD -o "$TUN" -j ACCEPT
    ipt_top FORWARD -i "$TUN" -j ACCEPT
    # СВАП дефолта в боевой таблице: awg0 -> xtun (маркировку/ip rule НЕ трогаем)
    ip route replace default dev "$TUN" table "$TABLE"
}

# ============================================================
cmd_up() {
    if ! start_daemons; then
        log "запуск не удался — остаюсь на awg"
        stop_daemons
        return 1
    fi
    exclude_endpoint        # анти-петля: endpoint мимо маркировки ДО постановки default->xtun
    apply_xray_routing
    set_xray_dns
    echo xray > "$TRANSPORT_FLAG"
    # Сброс watchdog-состояния: ручная смена транспорта = новый «эпизод» для
    # авто-failover (иначе старый XSTATE=FAILED/флаг-эпизод подавили бы перебор).
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    carrier_up_mark         # грейс сторожу: демоны стартовали, но egress поднимается ещё секунды (clock-lib.sh)
    # Отметка «путь через hev мёртв» (slot-tun-lib.sh) — про ПРЕЖНЮЮ несущую: она общая на xray/hy2/byedpi, и без снятия до получаса
    # отказывала бы перебору только что поднятого транспорта (ревью с.93, круг 3). Свежий путь судит следующий health тика.
    if command -v hev_dead_clear >/dev/null 2>&1; then hev_dead_clear main; fi
    ct_flush
    log "транспорт = XRAY (default table $TABLE -> $TUN). Общие правила сохранены."
    cmd_status
}

cmd_down() {
    # ЧИСТЫЙ РЕЛИНКВИШ (симметрично transport-awg.sh down): отпускаем ТОЛЬКО свою несущую
    # (xtun) -> fail-open в прямой. НЕ решаем, что поднять следом, и НЕ трогаем .transport —
    # это забота ОРКЕСТРАТОРА (transport.sh switch <name>). stop_daemons удаляет xtun -> его
    # default в table $TABLE исчезает с устройством -> fwmark-трафик уходит в main (ПРЯМОЙ).
    # DNS -> публичный напрямую (туннеля нет). Маркировку (mark-core) НЕ трогаем — общая.
    stop_daemons
    iptables -D FORWARD -o "$TUN" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$TUN" -j ACCEPT 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null || true
    seed_host_clear "$SEED_CONF"           # снять сид server-host — ОБЕ копии, /etc и живую /tmp; снятое отмечено ⇒ set_direct_dns ниже перезапустит dnsmasq и при том же upstream
    set_direct_dns
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    ct_flush
    log "Xray-несущая снята (релинквиш) -> прямой режим (fail-open). Следующий транспорт ставит оркестратор."
}

cmd_status() {
    # ФАКТ ФЛАГА, а не догадка (разбор — в transport-byedpi.sh cmd_status): `t=awg` печатало
    # «транспорт: awg» там, где транспорта нет вовсе. Сравнение ниже пусто ≠ xray — не меняется.
    t=; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    echo "=== транспорт: ${t:-(флаг пуст — транспорт не выбран)} ==="
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default   # raw-print: сырой вывод человеку в `status`, вердикта тут нет
    echo "--- демоны ---"
    proc_alive "$XRAY_PID" && echo "xray: pid $(cat $XRAY_PID) жив" || echo "xray: не запущен"
    proc_alive "$HEV_PID"  && echo "hev:  pid $(cat $HEV_PID) жив"  || echo "hev:  не запущен"
    echo "--- tun $TUN ---"; ip -o link show "$TUN" 2>/dev/null || echo "нет"
    echo "--- socks $SOCKS_PORT ---"; netstat -ltn 2>/dev/null | grep "$SOCKS_PORT" || echo "не слушает"
    if [ "$t" = xray ]; then
        echo "--- egress через xray socks ---"
        probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8; echo
    fi
    echo "--- awg0 (тёплый резерв) ---"; ip link show awg0 >/dev/null 2>&1 && echo "поднят" || echo "нет"
}

# health для watchdog: 0 = здоров ИЛИ транспорт не xray; 1 = xray нездоров.
cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    [ "$t" = xray ] || return 0
    proc_alive "$XRAY_PID" || { log "health: xray не жив"; return 1; }
    proc_alive "$HEV_PID"  || { log "health: hev не жив"; return 1; }
    ip link show "$TUN" >/dev/null 2>&1 || { log "health: нет $TUN"; return 1; }
    # проба реального выхода через прокси (детектит смерть VPS / блок Reality)
    ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8)
    [ -n "$ip" ] || { log "health: проба egress пуста"; return 1; }
    # Сервер жив — а путь КЛИЕНТОВ (TUN → hev → socks)? Мимо hev проба выше не видит залипшего hev (разбор и лечение —
    # slot-tun-lib.sh::hev_path_check). Нет функции (старый слой) — как раньше.
    command -v hev_path_check >/dev/null 2>&1 || return 0
    hev_path_check apply_xray_routing
}

# ============================================================
# xray-СЛОТ (доп-выход мульти-транспорта, Ф3) ---------------------------------------------
# Дизайн: заметки разработки «мультитранспорт-дизайн». «Выход» = ВТОРОЙ xray-инстанс со своим
# сервером рядом с основным транспортом: группа/гео едет через него, остальное — основным.
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ ПРОЦЕСС, а не «один xray с N инбаундами» (как прикидывал дизайн). Слияние
# требовало бы правки JSON на busybox (нет jq): вставить инбаунд, ПЕРЕТЕГИРОВАТЬ чужой аутбаунд
# и дописать routing-правило в пользовательский конфиг. Любая нестандартная форма конфига
# (а их пользователь приносит из подписок пачками) ломала бы РАБОЧИЙ основной транспорт —
# цена отказа несопоставима с экономией ~20 МБ RAM (на BE7000 свободно ~225 МБ; BE3600 с его
# 176 МБ доп-выходы и так не обещаем). Второй инстанс полностью изолирован: свой конфиг-файл,
# свой socks, свой лог, свой pid — падение слота не трогает основную несущую.
#
# Отличия от основного xray-пути:
#   * конфиг — КОПИЯ xray-configs/<cfg>.json с переписанным socks-инбаундом (10808 → порт слота)
#     и лог-путями (тот же приём, что в xray-test.sh — проверенный на железе);
#   * свой сид server-host (02-altserver-s<id>.conf) — снимается независимо от основного;
#   * анти-петля — endpoint СЛОТА через apply-bypass endpoint-slot-set (аддитивно, Ф2);
#   * БЕЗ DNS-сеттера (один dnsmasq ведёт ОСНОВНОЙ транспорт, дизайн §DNS) и БЕЗ MASQUERADE
#     (tun2socks терминирует). Марку 0xN и ip rule → table 100N ставит mark-core.
# Общий per-slot слой (порт/tun/table/hev/маршруты) — slot-tun-lib.sh (одна копия на 3 плагина).
# Под `[ -f ]`: провалившийся `.` убил бы весь плагин, включая ОСНОВНУЮ несущую, из-за отсутствия
# СЛОТОВОГО слоя. Нет файла ⇒ деградируем ровно по контракту плагинов: слот-вербы отвечают «не умею»
# (код 2), и слот живёт по своей fallback-политике, а основной транспорт работает как ни в чём не бывало.
if [ -f "$ENODIA_DIR/slot-tun-lib.sh" ]; then . "$ENODIA_DIR/slot-tun-lib.sh"; else SLOT_LIB_MISSING=1; fi
slot_lib_ok() { [ -z "$SLOT_LIB_MISSING" ] && return 0
    echo "[xray] слот-слой недоступен: нет $ENODIA_DIR/slot-tun-lib.sh — обновите скрипты" >&2; return 1; }
# Сверка «порт держит НАШ pid» нужна и ОСНОВНОМУ пути (socks_ours в шапке), а единственная
# реализация живёт в слот-слое. Нет библиотеки (старая установка) → шим «считаем наш»:
# диагностики нет, зато прежнее поведение основной несущей сохраняется байт-в-байт.
command -v slot_socks_is_ours >/dev/null 2>&1 || slot_socks_is_ours() { return 0; }
slot_srcconf()  { echo "$ENODIA_STATE/xray-configs/$1.json"; }   # $1 = имя конфига
slot_conf()     { echo "$ENODIA_STATE/xray-s$1.json"; }
slot_xray_pid() { echo "/tmp/enodia-xray-s$1.pid"; }
slot_xray_log() { echo "/tmp/xray-s$1.log"; }
slot_seed()     { echo "/etc/dnsmasq.d/02-altserver-s$1.conf"; }

# Копия конфига под слот: socks-инбаунд 10808 → порт слота, лог-пути → per-slot (не затираем
# боевой /tmp/xray.log и не пересекаемся с тест-инстансами xray-test.sh). Access-лог у слота
# гасим («none»), как и у основного: второй инстанс писал в ОЗУ ВТОРУЮ такую же простыню.
slot_gen_conf() {   # $1 = id ; $2 = имя конфига ; 0 = готов
    _id="$1"; _src=$(slot_srcconf "$2"); _dst=$(slot_conf "$_id"); _port=$(slot_socks_port "$_id")
    [ -s "$_src" ] || { log "слот №$_id: нет конфига $_src"; return 1; }
    sed -e "s/\"port\"[[:space:]]*:[[:space:]]*10808/\"port\": $_port/" \
        -e "s#/tmp/xray-access.log#none#g" \
        -e "s#/tmp/xray\.log#$(slot_xray_log "$_id")#g" \
        "$_src" > "$_dst" 2>/dev/null
    [ -s "$_dst" ] || { log "слот №$_id: не удалось подготовить конфиг"; return 1; }
    chmod 600 "$_dst" 2>/dev/null
    # Порт обязан реально попасть в конфиг: конфиг с чужим (10808) инбаундом увёл бы слот на
    # ОСНОВНОЙ socks — трафик выхода пошёл бы через основной сервер, а панель рапортовала «ок».
    grep -q "$_port" "$_dst" || { log "слот №$_id: в конфиге не найден socks-инбаунд 10808 — не могу выделить порт слоту"; return 1; }
    return 0
}

slot_start_daemons() {   # $1 = id ; $2 = имя конфига
    [ -x "$XRAY" ] || { log "слот №$1: НЕТ бинаря $XRAY"; return 1; }
    [ -x "$HEV" ]  || { log "слот №$1: НЕТ бинаря hev"; return 1; }
    _id="$1"; _port=$(slot_socks_port "$_id")
    slot_gen_conf "$_id" "$2" || return 1
    _h=$(xray_server_host "$(slot_conf "$_id")")
    [ -n "$_h" ] || { log "слот №$_id: не нашёл address в конфиге"; return 1; }
    seed_host_dns "$_h" "$(slot_seed "$_id")" || return 1     # без резолва демон упал бы dial-ом
    slot_free_socks "$_id" "$(slot_xray_pid "$_id")"
    if ! proc_alive "$(slot_xray_pid "$_id")"; then
        log "слот №$_id: запускаю xray на socks :$_port (конфиг $2)…"
        : > "$(slot_xray_log "$_id")" 2>/dev/null || true
        start-stop-daemon -S -b -m -p "$(slot_xray_pid "$_id")" -x /bin/sh -- -c "exec '$XRAY' run -c '$(slot_conf "$_id")' >>'$(slot_xray_log "$_id")' 2>&1"
    fi
    if ! slot_wait_socks "$_port" "$(slot_xray_pid "$_id")" xray; then
        log "слот №$_id: xray не слушает :$_port ($DAEMON_WAIT_WHY). Лог:"; tail -n 15 "$(slot_xray_log "$_id")" 2>/dev/null
        return 1
    fi
    slot_hev_up "$_id"          # hev + ожидание xtunN (общий слой)
}
slot_stop_daemons() {   # $1 = id
    _id="$1"
    slot_hev_down "$_id"
    start-stop-daemon -K -p "$(slot_xray_pid "$_id")" 2>/dev/null
    rm -f "$(slot_xray_pid "$_id")" 2>/dev/null
}

# Анти-петля выхода: IP сервера слота — мимо маркировки (иначе свои же пакеты к VPS, если его
# IP в iplist_set/слот-сете, завернутся в туннель = петля). Аддитивный per-slot стор (Ф2).
slot_exclude_endpoint() {   # $1 = id
    _id="$1"
    _ep=$(xray_endpoint_ip "$(slot_seed "$_id")" "$(slot_conf "$_id")")
    [ -n "$_ep" ] || { log "слот №$_id: endpoint не определён — пропуск анти-петли"; return 0; }
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "$_ep" >/dev/null 2>&1
    log "слот №$_id: endpoint $_ep исключён из маркировки (анти-петля)"
}

# Контракт слота (transport.sh _slot_dispatch): slot-up <id> <cfg> / slot-down <id> /
# slot-health <id>. Идемпотентно — watchdog зовёт slot-up повторно для reup.
cmd_slot_up() {   # $1 = id ; $2 = имя конфига
    _id="$1"; _cfg="$2"
    case "$_id" in 2|3|4) ;; *) log "слот: id = 2..4"; return 1 ;; esac
    [ -n "$_cfg" ] && [ "$_cfg" != "-" ] || { log "слот №$_id: не задан конфиг сервера"; return 1; }
    if ! slot_start_daemons "$_id" "$_cfg"; then
        log "слот №$_id: xray-несущая не поднялась -> выход живёт по fallback-политике (mark-core)"
        slot_stop_daemons "$_id"
        return 1
    fi
    slot_exclude_endpoint "$_id"    # ДО постановки default->xtunN
    slot_apply_routing "$_id"
    ct_flush
    log "слот №$_id: xray-несущая $(slot_tun "$_id") в table $(slot_table "$_id") (конфиг $_cfg)"
    return 0
}
cmd_slot_down() {   # $1 = id
    _id="$1"
    case "$_id" in 2|3|4) ;; *) log "слот: id = 2..4"; return 1 ;; esac
    slot_remove_routing "$_id"
    slot_stop_daemons "$_id"
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "" >/dev/null 2>&1   # снять анти-петлю слота
    rm -f "$(slot_hev_yaml "$_id")" "$(slot_conf "$_id")" 2>/dev/null
    # Сид сервера слота больше не нужен: убираем ОБЕ копии файла и перечитываем dnsmasq (HUP
    # конфиг НЕ перечитывает — без рестарта address=/host/IP жил бы до рестарта демона).
    if seed_host_clear "$(slot_seed "$_id")"; then
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
        rm -f "${DNS_RELOAD_MARK:-/tmp/enodia-dns-reload}" 2>/dev/null   # перезапустили сами — отметка снятого сида исполнена
    fi
    ct_flush
    log "слот №$_id: xray-несущая снята"
    return 0
}
# Здоровье выхода для watchdog: 0 = жив, 1 = просел. Проба реального выхода (как у основного
# health): смерть VPS/блок Reality процессом и tun'ом не видна — только egress-пробой.
cmd_slot_health() {   # $1 = id
    _id="$1"
    case "$_id" in 2|3|4) ;; *) return 1 ;; esac
    proc_alive "$(slot_xray_pid "$_id")" || { log "слот №$_id health: xray не жив"; return 1; }
    proc_alive "$(slot_hev_pid "$_id")"  || { log "слот №$_id health: hev не жив"; return 1; }
    ip link show "$(slot_tun "$_id")" >/dev/null 2>&1 || { log "слот №$_id health: нет $(slot_tun "$_id")"; return 1; }
    _ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$(slot_socks_port "$_id")" 8)
    [ -n "$_ip" ] || { log "слот №$_id health: проба egress пуста"; return 1; }
    # Сервер жив — а путь клиентов выхода через его hev? (slot-tun-lib.sh::slot_hev_path_check; нет функции — как раньше)
    command -v slot_hev_path_check >/dev/null 2>&1 || return 0
    slot_hev_path_check "$_id"
}

case "$1" in
    # Вербы, которые БЕРУТ несущую, — через carrier_run (daemon-lib.sh): при выключенном вручную VPN отказ, а выключение, пришедшее
    # по ходу, отпускает поднятое (снятие — тот же `down`, что зовёт `vpn-toggle off`).
    up)       carrier_run cmd_down cmd_up ;;
    down)     cmd_down ;;
    cold)     : ;;                        # тёплого резерва нет: демонов гасит сам `down` (stop_daemons)
    status)   cmd_status ;;
    health)   carrier_run cmd_down cmd_health ;;   # залипший hev перезапускает на месте (hev_path_check) — берёт несущую
    failover) carrier_run cmd_down cmd_failover ;;
    # DNS активной несущей (DoH toggle/смена резолвера) — через doh_apply_dns. При выключенном VPN — прямой, как после `down`.
    dns)      if carrier_barred; then set_direct_dns; else set_xray_dns; fi ;;
    access-purge) cmd_access_purge ;;  # разовая чистка ХРАНИЛИЩА конфигов от пути access-лога (зовут install.sh и gh-update.sh)
    # Слот-вербы ОПЦИОНАЛЬНЫ по контракту: нет слот-слоя → код 2 «не умею» (оркестратор оставит
    # выход на fallback), а не тихая смерть шелла на провалившемся `.`.
    slot-up)     slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_up "$2" "$3" ;;   # доп-выход (Ф3): 2-й xray + hev + xtunN в table 100N
    slot-down)   slot_lib_ok || exit 2; cmd_slot_down "$2" ;;      # доп-выход: снять несущую слота (-> fallback-политика mark-core)
    slot-health) slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_health "$2" ;;   # доп-выход: жив ли (watchdog); залипший hev выхода перезапускает — берёт несущую
    slot-iface)  slot_lib_ok || exit 2; slot_tun "$2" ;;           # имя несущей слота — учёту трафика (владелец имени один: slot-tun-lib.sh)
    *) echo "usage: $0 up|down|cold|status|health|failover|dns|access-purge|slot-up <id> <cfg>|slot-down <id>|slot-health <id>|slot-iface <id>"; exit 2 ;;
esac
