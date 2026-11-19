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
command -v ct_flush_slot >/dev/null 2>&1 || ct_flush_slot()   { ct_flush; }   # no scoped flush in an old ct-lib — the global one, as before
command -v ct_flush_route >/dev/null 2>&1 || ct_flush_route() { ct_flush; }
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
# lbl_commit_out — a config is replaced whole or not at all (access_off; C135): `cat tmp > config` truncated the config FIRST, and
# a full partition left the server's config empty (review s.136, L9).
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi
command -v lbl_commit_out >/dev/null 2>&1 || lbl_commit_out() { _lcf=$1; shift; "$@" > "$_lcf.$$.new" && mv -f "$_lcf.$$.new" "$_lcf" && return 0; rm -f "$_lcf.$$.new"; return 1; }   # write-blind: the shim of a missing library is the old line
# «VPN выключен вручную — несущую не берёт никто» (carrier_barred/carrier_run, разбор в daemon-lib.sh). Нет — прежний путь.
command -v carrier_barred >/dev/null 2>&1 || carrier_barred() { return 1; }
command -v carrier_run >/dev/null 2>&1 || carrier_run() { shift; "$@"; }
command -v daemon_log_fresh >/dev/null 2>&1 || daemon_log_fresh() { : > "$1" 2>/dev/null || true; }   # the old start: the log afresh, no `.prev`
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
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
command -v carrier_up_mark >/dev/null 2>&1 || carrier_up_mark() { return 0; }
# Whole-profile readers share the importer's endpoint schema.
if [ -f "$ENODIA_DIR/xray-profile-lib.sh" ]; then . "$ENODIA_DIR/xray-profile-lib.sh"; fi
command -v xp_pool >/dev/null 2>&1 || xp_pool() { return 1; }
command -v daemon_xray_ready >/dev/null 2>&1 || daemon_xray_ready() { return 0; }
# Bypass, seeding and the road all read the same endpoint set.
xray_server_host() { xp_members "${1:-$XRAY_JSON}" hosts; }
cmd_endpoint() { [ -f "$1" ] && xp_members "$1" endpoints; }
xray_dns_available() { [ -n "$(xp_members "$1" usable)" ]; }
seed_server_dns() {
    _xsd_hosts=$(xray_server_host "${1:-$XRAY_JSON}")
    [ -n "$_xsd_hosts" ] || { log "не найден адрес прокси-сервера"; return 1; }
    seed_hosts_dns "$_xsd_hosts" "${2-$SEED_CONF}" "${3:-}"
}
xray_endpoint_ip() { xp_members "${2:-$XRAY_JSON}" ips "${1:-$SEED_CONF}"; }
# Исключить endpoint xray-сервера из маркировки (иначе свои же пакеты к VPS, если его
# IP в iplist_set, заворачиваются в xtun = петля). Зовём ДО постановки default->xtun.
exclude_endpoint() {
    xray_endpoints ready ''
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

# Apply the profile owner's log boundary before any main-daemon launch.
access_off() {   # <config> [owned SOCKS port]
    ACCESS_FIXED=0
    [ -f "$1" ] || return 1
    _a_config=$(xp_runtime "$1" "${2:-}" "$XRAY_LOG") || return 1
    [ -n "$_a_config" ] || return 1
    [ "$_a_config" != "$(cat "$1")" ] || return 0
    ( umask 077; lbl_commit_out "$1" printf '%s\n' "$_a_config" ) || return 1
    ACCESS_FIXED=1
}

# The only reserved legacy access path. Check live descriptors before unlink
# so upgrade-time purge can leave a running predecessor's log alone.
access_retire() {
    _art=/tmp/xray-access.log
    [ -f "$_art" ] && [ ! -L "$_art" ] || return 0
    _ari=$(stat -c '%d:%i' "$_art" 2>/dev/null) || return 0
    stat -L -c '%d:%i' /proc/[0-9]*/fd/* 2>/dev/null | grep -Fxq "$_ari" && return 0
    rm -f "$_art" 2>/dev/null || :
}
access_retire_after_start() {
    [ -n "${ENODIA_SWITCH_HOLDER:-}" ] &&
        [ "$(cat "$SWITCH_LOCK" 2>/dev/null)" = "$ENODIA_SWITCH_HOLDER" ] && access_retire
    return 0
}

cmd_access_purge() {
    # A caller already holding the switch lock can run the migration directly.
    if [ -z "${ENODIA_SWITCH_HOLDER:-}" ] ||
        [ "$(cat "$SWITCH_LOCK" 2>/dev/null)" != "$ENODIA_SWITCH_HOLDER" ]; then
        command -v switch_hold >/dev/null 2>&1 && switch_hold "$SWITCH_LOCK" 3 || return 0
        trap 'rm -f "$SWITCH_LOCK"' EXIT
        trap 'exit 1' HUP INT TERM
    fi
    _apn=0; _apt=0
    for _apf in "$XRAY_JSON" "$ENODIA_STATE"/xray-configs/*.json; do
        [ -f "$_apf" ] && [ ! -L "$_apf" ] || continue
        _apt=$((_apt+1))
        if access_off "$_apf" && [ "$ACCESS_FIXED" = 1 ]; then _apn=$((_apn+1)); fi
    done
    access_retire
    log "access-purge: просмотрено конфигов $_apt, вычищено $_apn"
}

# ---- демоны ---------------------------------------------------------------
# Запуск xray в фоне С ЗАХВАТОМ вывода в $XRAY_LOG. ЗАЧЕМ: start-stop-daemon -b при
# демонизации уводит stdio демона в /dev/null → если xray-конфиг не задаёт лог-файл, причина
# сбоя (socks не поднялся: кривой сервер/sni/ключи/порт) была НЕВИДНА — tail "$XRAY_LOG" и в
# start_daemons, и в диагностике установщика выдавал пусто. Обёртка `sh -c 'exec … >>log 2>&1'`
# переоткрывает stdout/stderr УЖЕ ПОСЛЕ демонизации (внутри sh, до exec) → лог пишется; exec
# сохраняет PID для pidfile. -x /bin/sh безопасен: дедуп на proc_alive (по пидфайлу), а -K в
# stop/restart матчит по -p, не по -x.
# The Go heap ceiling (GOMEMLIMIT), one for every Go daemon of the tunnel: its ONLY owner is net-tune.sh (.go-memlimit; why a
# ceiling at all — that file's header). xray had none until 26.10.2026 (a 384-MB BE6500 was reported at 93–99% RAM with it —
# what ate it, not measured). The FORM is
# filtered here, next to the launch (net-tune.sh's reader contract): a word other than the variable would become the command and
# the daemon would not start at all. Prints `env GOMEMLIMIT=<N>MiB ` or nothing — then the launch line is the old one byte for byte.
xray_go_cap() {
    _xgc=$(sh "$ENODIA_DIR/net-tune.sh" memlimit-env 2>/dev/null | grep -E '^GOMEMLIMIT=[0-9]+MiB$')
    [ -n "$_xgc" ] && printf 'env %s ' "$_xgc"
    return 0
}
# Endpoint lifecycle belongs to startup, not its callers. Every terminal state
# replaces the complete set: ready=current, stopped/failed=empty. A failed main
# raise from another transport restores that still-active carrier's set.
xray_endpoints() {   # begin|stage|ready|abort|clear <slot id, empty for main>
    _xet_event=$1; _xet_slot=$2; _xet_key=""; _xet_hold=""; _xet_hosts=""
    case "$_xet_event" in
        begin)
            _xet_record=$(cat "$ENODIA_STATE/.endpoint-bypass${2:+-s$2}" 2>/dev/null)
            _xet_before=$(printf '%s\n' "$_xet_record" | lbl_endpoint_ips)
            _xet_fallback=''; _xet_old_key=''; _xet_old_hosts=''
            if [ -z "$2" ] && [ "$(cat "$TRANSPORT_FLAG" 2>/dev/null)" != xray ]; then
                _xet_fallback=$_xet_before
                _xet_old_key=$(printf '%s\n' "$_xet_record" | lbl_endpoint_key)
                _xet_old_hosts=$(printf '%s\n' "$_xet_record" | lbl_endpoint_hosts)
            fi
            return 0 ;;
        stage|ready)
            if [ -n "$2" ]; then
                _xet_new=$(xray_endpoint_ip "$(slot_seed "$2")" "$(slot_conf "$2")")
                _xet_hosts=$(xray_server_host "$(slot_conf "$2")")
                _xet_key=${3:-${_xer_config:-}}
            else
                _xet_new=$(xray_endpoint_ip)
                _xet_hosts=$(xray_server_host)
                _xet_key=$(head -n1 "$ENODIA_STATE/.xray-active" 2>/dev/null)
            fi
            _xet_key=${_xet_key:+xray/$_xet_key}
            [ "$_xet_event" != stage ] || _xet_hold=${_xet_before:-} ;;
        abort) _xet_new=${_xet_fallback:-}; _xet_key=${_xet_old_key:-}; _xet_hosts=${_xet_old_hosts:-} ;;
        clear) _xet_new='' ;;
        *) return 1 ;;
    esac
    carrier_endpoint "$_xet_slot" "$_xet_new" "$_xet_key" "$_xet_hold" "$_xet_hosts"
}

xray_endpoint_run() {   # <slot> <stop function> <start function> [args...]
    _xer_slot=$1; _xer_stop=$2; shift 2
    _xer_config=${3:-}
    xray_endpoints begin "$_xer_slot" || return 1
    "$@"; _xer_rc=$?
    if [ "$_xer_rc" = 0 ]; then
        xray_endpoints ready "$_xer_slot" && return 0
        _xer_rc=1
    fi
    "$_xer_stop" ${_xer_slot:+"$_xer_slot"}
    xray_endpoints abort "$_xer_slot"
    return "$_xer_rc"
}
spawn_xray() {
    daemon_log_fresh "$XRAY_LOG"
    access_off "$XRAY_JSON" "$SOCKS_PORT" || return 1
    XRAY_OWNS_SEED=1
    [ "${1:-}" = seeded ] || seed_server_dns || return 1
    xray_endpoints stage '' || return 1
    start-stop-daemon -S -b -m -p "$XRAY_PID" -x /bin/sh -- -c "XRAY_LOCATION_ASSET='$(xp_asset_dir "$XRAY")' exec $(xray_go_cap)'$XRAY' run -c '$XRAY_JSON' >>'$XRAY_LOG' 2>&1"
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
    xray_endpoint_run '' stop_daemons start_daemons_impl
}
start_daemons_impl() {
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
    daemon_xray_ready "$XRAY_PID" "$XRAY_JSON" "$SOCKS_PORT" || { log "$DAEMON_WAIT_WHY"; return 1; }
    socks_ours || { log "socks $SOCKS_PORT держит ЧУЖОЙ демон — наш xray не забиндил (несущую поверх чужого socks не поднимаю)"; return 1; }
    access_retire_after_start
    if ! proc_alive "$HEV_PID"; then
        log "запускаю hev (tun2socks)…"
        start-stop-daemon -S -b -m -p "$HEV_PID" -x "$HEV" -- "$HEV_YAML"
    fi
    daemon_wait_dev "$HEV_PID" hev 6 "$TUN" || {
        log "tun $TUN не создан: $DAEMON_WAIT_WHY. Лог hev:"; tail -n 15 "$HEV_LOG" 2>/dev/null; return 1; }
    return 0
}
stop_xray() {
    start-stop-daemon -K -p "$XRAY_PID" 2>/dev/null
    rm -f "$XRAY_PID" "$XRAY_PID.pool-ready" 2>/dev/null
    seed_host_retire "$SEED_CONF" "${_xfr_retire:-}"
    xray_endpoints clear ''
}
stop_daemons() {
    # hev — с ожиданием смерти (slot-tun-lib.sh::hev_stop): за `down` в смене транспорта и в перезапуске сразу идёт `up` с новым hev
    # на тот же TUN. Нет слоя — прежний путь.
    if command -v hev_stop >/dev/null 2>&1; then hev_stop "$HEV_PID"; else start-stop-daemon -K -p "$HEV_PID" 2>/dev/null; fi
    start-stop-daemon -K -p "$XRAY_PID" 2>/dev/null
    ip link del "$TUN" 2>/dev/null
    # Пидфайлы чистим СРАЗУ (как slot_stop_daemons/slot_hev_down): busybox start-stop-daemon -K
    # их не убирает, а по stale-пидфайлу proc_alive рано или поздно попадёт в ПЕРЕИСПОЛЬЗОВАННЫЙ
    # системой pid и решит «демон жив» — start_daemons его тогда не поднимет, а несущей нет.
    rm -f "$HEV_PID" "$XRAY_PID" "$XRAY_PID.pool-ready" 2>/dev/null
    if [ "${XRAY_OWNS_SEED:-}" = 1 ] || [ "$(cat "$TRANSPORT_FLAG" 2>/dev/null)" = xray ] || [ "${1:-}" = defer ]; then
        seed_host_retire "$SEED_CONF" "${1:-}"
    fi
    xray_endpoints clear ''
}

# Перезапустить ТОЛЬКО xray с текущим $XRAY_JSON (hev/xtun не трогаем — тот же
# socks-порт). Для перебора xray-резервов: меняем конфиг и поднимаем xray заново.
# Возврат: 0 — socks снова слушает; 1 — не поднялся; 2 — server-host НЕ РЕЗОЛВИТСЯ (несущую при
# этом НЕ трогали, см. ниже) — код нужен cmd_failover, чтобы отличить «сервер мёртв» от «DNS мёртв».
restart_xray() {   # [config, name (empty if restored), seed retire mode]
    # Resolve the candidate without changing the live road inputs. Publish
    # the resolved rows only after the old daemon has stopped.
    local _xfr_rows="" _xfr_retire=${3:-}
    if [ "$#" -gt 0 ]; then
        set -- "$1" "$2"
        _xfr_rows=$(seed_server_dns "$1" "") && [ -n "$_xfr_rows" ]
    else
        seed_server_dns
    fi || {
        log "restart_xray: server-host не резолвится — несущую не трогаю"
        proc_alive "$XRAY_PID" || xray_endpoints clear ''
        return 2
    }
    xray_endpoint_run '' stop_xray restart_xray_impl "$@" "$_xfr_rows"
}
restart_xray_impl() {
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
    rm -f "$XRAY_PID" "$XRAY_PID.pool-ready" 2>/dev/null
    free_foreign_socks
    if [ "$#" -eq 3 ]; then
        if [ -n "$2" ]; then
            ( umask 077; lbl_commit_out "$XRAY_JSON" cat "$1" ) || return 1
            printf '%s\n' "$2" > "$ENODIA_STATE/.xray-active" || return 1
        fi
        seed_server_dns "$XRAY_JSON" "$SEED_CONF" "$3" || return 1
    fi
    spawn_xray seeded || { log "restart_xray: резолв server-host не удался"; return 1; }
    daemon_wait_port "$XRAY_PID" xray 8 "$SOCKS_ADDR" "$SOCKS_PORT" || { log "restart_xray: $DAEMON_WAIT_WHY"; return 1; }
    daemon_xray_ready "$XRAY_PID" "$XRAY_JSON" "$SOCKS_PORT" || return 1
    socks_ours || return 1
    access_retire_after_start
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
    local DNS_SEED_DEADLINE=$(($(uptime_s) + 12))

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
            ct_flush_route "$FWMARK" "$TABLE"   # the server changed, the transport did not: only the flows riding table $TABLE (ct-lib.sh)
            if health_warm; then
                log "xray-failover: несущая восстановлена на текущем сервере ${cur:-?} — перебор серверов не понадобился"
                return 0
            fi
        fi
        log "xray-failover: починка несущей не помогла — перехожу к перебору серверов"
    fi

    tried=""; dns_dead=0; _xfwl=0; _xfr_touched=0
    # АПЛИНК ПРОПАЛ ПОСРЕДИ ПЕРЕБОРА — дальше перебирать незачем: недостижим ЛЮБОЙ сервер, а свип у подписок идёт десятками
    # конфигов (BE7000 02.10.2026: ~70 кандидатов, 20 минут при лёгшем провайдере). Спрашиваем после КАЖДОГО промаха —
    # при живом WAN проба стоит доли секунды против ~17 с на кандидата. Но ТОЛЬКО если аплинк был жив НА СТАРТЕ: молчит проба
    # уже здесь ⇒ перебор идёт вслепую (контрольный свип сторожа на случай пробы, которую режет провайдер), и обрывать его ею
    # же — значит обрывать всегда. Нет владельца (старая ip-lib) — не спрашиваем вовсе, как раньше.
    _xfw=0
    command -v wan_probe_ok >/dev/null 2>&1 && command -v wan_recheck >/dev/null 2>&1 && wan_probe_ok && _xfw=1
    for f in "$ENODIA_STATE"/xray-configs/*.json; do
        [ -f "$f" ] || continue
        if [ -e "$SWITCH_LOCK" ]; then
            [ "$_xfr_touched" = 0 ] || seed_dns_reload_pending
            log "xray-failover: ручной switch (lock) в процессе — прерываю перебор"; return 1
        fi
        # VPN выключили вручную посреди перебора — дальше не пробуем: каждый кандидат поднимал бы демон при «выключенном» VPN.
        # Конфиг возвращаем исходный (ниже), демон не поднимаем; поднятое снимет обёртка верба (carrier_run).
        carrier_barred && { log "xray-failover: VPN выключили вручную — прерываю перебор"; break; }
        name=$(basename "$f" .json)
        [ "$name" = "$cur" ] && continue       # текущий (дохлый) пропускаем
        # DNS признан мёртвым на прошлом кандидате ⇒ сервер ПО ИМЕНИ не поднимется НИКАКОЙ:
        # upstream dnsmasq заперт в снятой несущей, WAN-DoH тоже промолчал. Пробовать такого
        # кандидата = 6 ретраев резолва впустую (ровно из этого складывались «минуты мигания»).
        # А вот кандидат по ГОЛОМУ IP резолва не требует — его перебор продолжаем.
        if [ "$dns_dead" = 1 ] && ! xray_dns_available "$f"; then
            log "xray-failover: пропускаю $name — сервер задан именем, а DNS сейчас мёртв"
            continue
        fi
        log "xray-failover: пробую $name…"
        restart_xray "$f" "$name" defer; rc=$?
        [ "$rc" = 2 ] || _xfr_touched=1
        [ "$rc" = 2 ] && { dns_dead=1; log "xray-failover: $name не резолвится — DNS мёртв (upstream заперт в несущей)"; }
        if [ "$rc" = 0 ] && health_warm; then
            seed_dns_reload_pending   # A literal winner can have no new seed to publish.
            ct_flush_route "$FWMARK" "$TABLE"
            ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" "$XRAY_EGRESS_TIMEOUT")
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
    if [ "$_xfr_touched" = 1 ] && [ -n "$cur" ] && [ -f "$ENODIA_STATE/xray-configs/$cur.json" ]; then
        f="$ENODIA_STATE/xray-configs/$cur.json"
        # Restore the selection before DNS can refuse a restart. B's publication still owns its live route.
        if ( umask 077; lbl_commit_out "$XRAY_JSON" cat "$f" ) && printf '%s\n' "$cur" > "$ENODIA_STATE/.xray-active"; then
            carrier_barred || restart_xray "$XRAY_JSON" ''
        fi
    fi
    [ "$_xfr_touched" = 0 ] || seed_dns_reload_pending
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
        return 1
    fi
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
    stop_daemons defer
    iptables -D FORWARD -o "$TUN" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$TUN" -j ACCEPT 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null || true
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
    if xp_pool "$XRAY_JSON"; then
        echo "profile: $(xp_members "$XRAY_JSON" endpoints | wc -l) proxy endpoints (health is SOCKS egress)"
    fi
    echo "--- демоны ---"
    proc_alive "$XRAY_PID" && echo "xray: pid $(cat $XRAY_PID) жив" || echo "xray: не запущен"
    proc_alive "$HEV_PID"  && echo "hev:  pid $(cat $HEV_PID) жив"  || echo "hev:  не запущен"
    echo "--- tun $TUN ---"; ip -o link show "$TUN" 2>/dev/null || echo "нет"
    echo "--- socks $SOCKS_PORT ---"; netstat -ltn 2>/dev/null | grep "$SOCKS_PORT" || echo "не слушает"
    if [ "$t" = xray ]; then
        echo "--- egress через xray socks ---"
        if daemon_xray_ready "$XRAY_PID" "$XRAY_JSON" "$SOCKS_PORT"; then
            probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8; echo
        else echo "$DAEMON_WAIT_WHY"; fi
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
    daemon_xray_ready "$XRAY_PID" "$XRAY_JSON" "$SOCKS_PORT" || return 1
    # проба реального выхода через прокси (детектит смерть VPS / блок Reality)
    ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" "$XRAY_EGRESS_TIMEOUT")
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
    xp_runtime "$_src" "$_port" "$(slot_xray_log "$_id")" > "$_dst" 2>/dev/null || return 1
    [ -s "$_dst" ] || { log "слот №$_id: не удалось подготовить конфиг"; return 1; }
    chmod 600 "$_dst" 2>/dev/null

    return 0
}

slot_start_daemons() {   # $1 = id ; $2 = имя конфига
    xray_endpoint_run "$1" slot_stop_daemons slot_start_daemons_impl "$1" "$2"
}
slot_start_daemons_impl() {   # $1 = id ; $2 = config name
    [ -x "$XRAY" ] || { log "слот №$1: НЕТ бинаря $XRAY"; return 1; }
    [ -x "$HEV" ]  || { log "слот №$1: НЕТ бинаря hev"; return 1; }
    _id="$1"; _port=$(slot_socks_port "$_id")
    # A warm process still dials the runtime profile it started with.
    if ! proc_alive "$(slot_xray_pid "$_id")"; then slot_gen_conf "$_id" "$2" || return 1; fi
    seed_server_dns "$(slot_conf "$_id")" "$(slot_seed "$_id")" || return 1
    xray_endpoints stage "$_id" || return 1
    slot_free_socks "$_id" "$(slot_xray_pid "$_id")"
    if ! proc_alive "$(slot_xray_pid "$_id")"; then
        log "слот №$_id: запускаю xray на socks :$_port (конфиг $2)…"
        daemon_log_fresh "$(slot_xray_log "$_id")"
        start-stop-daemon -S -b -m -p "$(slot_xray_pid "$_id")" -x /bin/sh -- -c "XRAY_LOCATION_ASSET='$(xp_asset_dir "$XRAY")' exec $(xray_go_cap)'$XRAY' run -c '$(slot_conf "$_id")' >>'$(slot_xray_log "$_id")' 2>&1" || return 1
    fi
    if ! slot_wait_socks "$_port" "$(slot_xray_pid "$_id")" xray; then
        log "слот №$_id: xray не слушает :$_port ($DAEMON_WAIT_WHY). Лог:"; tail -n 15 "$(slot_xray_log "$_id")" 2>/dev/null
        return 1
    fi
    daemon_xray_ready "$(slot_xray_pid "$_id")" "$(slot_conf "$_id")" "$_port" || return 1
    slot_hev_up "$_id"          # hev + ожидание xtunN (общий слой)
}
slot_stop_daemons() {   # $1 = id
    _id="$1"
    slot_hev_down "$_id"
    start-stop-daemon -K -p "$(slot_xray_pid "$_id")" 2>/dev/null
    rm -f "$(slot_xray_pid "$_id")" "$(slot_xray_pid "$_id").pool-ready" 2>/dev/null
    seed_host_retire "$(slot_seed "$_id")"
    xray_endpoints clear "$_id"
}

# Анти-петля выхода: IP сервера слота — мимо маркировки (иначе свои же пакеты к VPS, если его
# IP в iplist_set/слот-сете, завернутся в туннель = петля). Аддитивный per-slot стор (Ф2).
slot_exclude_endpoint() {   # $1 = id
    xray_endpoints ready "$1"
}

# Контракт слота (transport.sh _slot_dispatch): slot-up <id> <cfg> / slot-down <id> /
# slot-health <id>. Идемпотентно — watchdog зовёт slot-up повторно для reup.
cmd_slot_up() {   # $1 = id ; $2 = имя конфига
    _id="$1"; _cfg="$2"
    case "$_id" in [2-7]) ;; *) log "слот: id = 2..7"; return 1 ;; esac
    [ -n "$_cfg" ] && [ "$_cfg" != "-" ] || { log "слот №$_id: не задан конфиг сервера"; return 1; }
    if ! slot_start_daemons "$_id" "$_cfg"; then
        log "слот №$_id: xray-несущая не поднялась -> выход живёт по fallback-политике (mark-core)"
        return 1
    fi
    slot_apply_routing "$_id"
    ct_flush_slot "$_id"   # only this exit's flows (ct-lib.sh)
    log "слот №$_id: xray-несущая $(slot_tun "$_id") в table $(slot_table "$_id") (конфиг $_cfg)"
    return 0
}
cmd_slot_down() {   # $1 = id
    _id="$1"
    case "$_id" in [2-7]) ;; *) log "слот: id = 2..7"; return 1 ;; esac
    slot_remove_routing "$_id"
    slot_stop_daemons "$_id"
    rm -f "$(slot_hev_yaml "$_id")" "$(slot_conf "$_id")" 2>/dev/null
    ct_flush_slot "$_id"
    log "слот №$_id: xray-несущая снята"
    return 0
}
# Здоровье выхода для watchdog: 0 = жив, 1 = просел. Проба реального выхода (как у основного
# health): смерть VPS/блок Reality процессом и tun'ом не видна — только egress-пробой.
cmd_slot_health() {   # $1 = id
    _id="$1"
    case "$_id" in [2-7]) ;; *) return 1 ;; esac
    proc_alive "$(slot_xray_pid "$_id")" || { log "слот №$_id health: xray не жив"; return 1; }
    proc_alive "$(slot_hev_pid "$_id")"  || { log "слот №$_id health: hev не жив"; return 1; }
    ip link show "$(slot_tun "$_id")" >/dev/null 2>&1 || { log "слот №$_id health: нет $(slot_tun "$_id")"; return 1; }
    daemon_xray_ready "$(slot_xray_pid "$_id")" "$(slot_conf "$_id")" "$(slot_socks_port "$_id")" || return 1
    _ip=$(probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$(slot_socks_port "$_id")" "$XRAY_EGRESS_TIMEOUT")
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
    endpoint) cmd_endpoint "$2" ;;    # «host⇥port» the router dials for config $2 (a chain's relay) — cgi-bin/ping
    # The server list's rows cache (xray-profile-lib.sh::xp_meta_rows) filled ahead of the first «Серверы»: heal starts it in the
    # background after a boot and an update (RAM is empty, a new library is a new key) — else that first list waits ~0.3 s a profile.
    # ONE FILL AT A TIME IS THE VERB'S OWN: boot heal and a replay can both start it before either writes a pidfile (review 2;
    # round 1 found the pidfile check blind too). A live holder — this one gives up after the lock's few seconds of asking.
    meta-warm) _mwl=${XP_META_WARM_LOCK:-/tmp/enodia-xray-meta-warm.lock}
               lbl_lock_take "$_mwl" 'xray-transport\.sh meta-warm' || exit 0
               trap 'lbl_lock_drop "$_mwl"' EXIT; trap 'exit 1' HUP INT TERM PIPE
               set --; for _mw in "$ENODIA_STATE"/xray-configs/*.json; do [ -f "$_mw" ] && set -- "$@" "$_mw"; done
               xp_meta_rows "$@" >/dev/null ;;
    # Слот-вербы ОПЦИОНАЛЬНЫ по контракту: нет слот-слоя → код 2 «не умею» (оркестратор оставит
    # выход на fallback), а не тихая смерть шелла на провалившемся `.`.
    slot-up)     slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_up "$2" "$3" ;;   # доп-выход (Ф3): 2-й xray + hev + xtunN в table 100N
    slot-down)   slot_lib_ok || exit 2; cmd_slot_down "$2" ;;      # доп-выход: снять несущую слота (-> fallback-политика mark-core)
    slot-health) slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_health "$2" ;;   # доп-выход: жив ли (watchdog); залипший hev выхода перезапускает — берёт несущую
    slot-iface)  slot_lib_ok || exit 2; slot_tun "$2" ;;           # имя несущей слота — учёту трафика (владелец имени один: slot-tun-lib.sh)
    *) echo "usage: $0 up|down|cold|status|health|failover|dns|access-purge|slot-up <id> <cfg>|slot-down <id>|slot-health <id>|slot-iface <id>"; exit 2 ;;
esac
