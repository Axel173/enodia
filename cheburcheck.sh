#!/bin/sh
# cheburcheck.sh — «ВТОРОЕ МНЕНИЕ О БЛОКИРОВКЕ»: проверка адреса сервера публичным сервисом cheburcheck.ru (ТСПУ глазами ~30
# точек российских провайдеров).
#
# WHY. «Server does not answer» has two causes the router alone can't always tell apart: the server is down, or the ISP cut its
# ADDRESS (ТСПУ drops every packet; the address is in no public list — measured 09.10.2026: our VPS — 23 of 30 probes
# `tspu_block`, a working one — 23 `ok`). The router's own evidence comes first (cgi-bin/ping: direct is silent, through a live
# tunnel it answers ⇒ blocked); this service answers what the router can't: no tunnel to compare with (VPN off, the only
# server), and «is this address blocked across Russia» before a person buys a server.
# OPT-IN, OFF BY DEFAULT (user's decision 10.10.2026): the panel is installed outside Russia too, and a server address sent to a
# third-party Russian service is a privacy cost nobody should pay by default. Off ⇒ every verb but on/state refuses, the panel
# shows nothing about it. `auto` (ask by itself when a server is silent) is a second switch, also off, ≥ CACHE_TTL per address
# (the service keeps its answer that long anyway).
# THE SERVICE CAN CHANGE OR VANISH: every deviation (HTTP ≠ 200, no SSE, no `done`, answers ≠ results, unknown verdicts) is
# «нет данных», never a verdict — the checks mirror the user's own bot (ping-bot SseParser/Verdict). Long call (SSE up to
# ~80 s) ⇒ always in the background, result into a file the panel polls (uhttpd SIGKILLs a CGI that outlives its client, C127).
#
# Commands:
#   cheburcheck.sh on|off | auto on|off — the switches (`.chebur`, `.chebur-auto` in $ENODIA_STATE)
#   cheburcheck.sh state                — {"on":bool,"auto":bool}
#   cheburcheck.sh check <ipv4>         — start a check in the background (refuses when off); a fresh result is not re-asked
#   cheburcheck.sh want <ipv4>          — `check` only when `auto` is on (the ping CGI calls it for a silent server)
#   cheburcheck.sh get <ipv4>           — the cached result as one JSON object (state none|running|done|error)
#   cheburcheck.sh run <ipv4>           — the check itself, in the foreground (what `check` starts)
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
API=https://cheburcheck.ru/api/v1
C=/tmp/enodia-chebur                 # RAM: answers live 3 h at the service anyway, a reboot just asks again
CACHE_TTL=10800
BLOCK_MIN=2                          # ≥ 2 probes saw `tspu_block` ⇒ blocked (the bot's threshold)
CLEAR_MIN=3                          # all answered, 0 blocks, ≥ 3 `ok` ⇒ reachable from Russia
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
command -v curl_ca_opt >/dev/null 2>&1 || curl_ca_opt() { return 0; }
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
# Text into JSON — only through json-lib (`jtxt`: a byte cut that drops a half-letter at the end, quotes escaped): a bare `cut -c`
# cut a Cyrillic provider name in half, and the whole answer stopped being valid UTF-8 (caught by this file's stand).
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '"\000-\037\\'; }
command -v jesc >/dev/null 2>&1 || jesc() { tr -d '"\000-\037\\'; }   # jesc = jtxt for one line of output: the trailing newline isn't a space
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }

is_ip4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
on()   { [ -f "$ENODIA_STATE/.chebur" ]; }
auto() { on && [ -f "$ENODIA_STATE/.chebur-auto" ]; }
put()  { _cpt=$(mktemp "$C/$1.json.XXXXXX" 2>/dev/null) || return 1; printf '%s\n' "$2" > "$_cpt" && mv "$_cpt" "$C/$1.json"; }   # atomic (the panel polls); mktemp — no planted name

# A result is fresh while its UPTIME stamp is younger than CACHE_TTL (uptime, not the clock: the router's clock jumps, C24).
fresh() {   # $1 = ip
    _cfs=$(sed -n 's/.*"up":\([0-9]*\).*/\1/p' "$C/$1.json" 2>/dev/null)
    [ -n "$_cfs" ] || return 1
    _cfu=$(uptime_s); [ -n "$_cfu" ] && [ "$_cfu" -ge "$_cfs" ] 2>/dev/null && [ $((_cfu - _cfs)) -lt "$CACHE_TTL" ]
}
running() { _crp=$(cat "$C/$1.pid" 2>/dev/null | tr -cd '0-9'); [ -n "$_crp" ] && [ -d "/proc/$_crp" ]; }

cmd_check() {   # $1 = ip
    on || { echo "[chebur] второе мнение выключено — включите его в «Проверке серверов»"; return 1; }
    is_ip4 "$1" || { echo "[chebur] нужен адрес IPv4"; return 1; }
    mkdir -p "$C" 2>/dev/null
    running "$1" && { echo "[chebur] проверка уже идёт"; return 0; }
    # «Once per 3 h per address» — after a failure too: a service that is down is not hit on every probe of a silent server (up to
    # ~105 s of stream each time); the person's «Проверить ещё раз» (force) goes past the limit (review s.118).
    if [ "${2:-}" != force ] && fresh "$1" && grep -qE '"state":"(done|error)"' "$C/$1.json" 2>/dev/null; then echo "[chebur] свежий ответ уже есть"; return 0; fi
    put "$1" "{\"state\":\"running\",\"up\":$(uptime_s)}"
    if [ -x /sbin/start-stop-daemon ]; then
        start-stop-daemon -S -b -m -p "$C/$1.pid" -x /bin/sh -- "$ENODIA_DIR/cheburcheck.sh" run "$1" >/dev/null 2>&1
    else
        ( sh "$ENODIA_DIR/cheburcheck.sh" run "$1" >/dev/null 2>&1 & )
    fi
    echo "[chebur] проверка запущена — до полутора минут"
}

nodata() { put "$1" "{\"state\":\"error\",\"up\":$(uptime_s),\"msg\":\"$2\"}"; exit 0; }

cmd_run() {   # $1 = ip
    is_ip4 "$1" || exit 1
    mkdir -p "$C" 2>/dev/null
    W="$C/$1.work"; rm -rf "$W"; ( umask 077; mkdir "$W" ) || nodata "$1" "нет места для ответа"
    # Expanded NOW: at exit `$1` would be the script's own argument (`run`). The address is validated IPv4 — safe in the string.
    trap "rm -rf '$W' '$C/$1.pid'" EXIT
    trap 'exit 1' INT TERM HUP PIPE
    _cca=$(curl_ca_opt "$API/check?target=$1")
    # shellcheck disable=SC2086
    _cc=$(curl -s $_cca -o "$W/check" -w '%{http_code}' --connect-timeout 10 --max-time 25 -H 'Accept: application/json' "$API/check?target=$1" 2>/dev/null)
    [ "$_cc" = 200 ] || nodata "$1" "сервис не ответил (HTTP ${_cc:-нет связи})"
    _cid=$(jsonfilter -i "$W/check" -e '@.id' 2>/dev/null)
    printf '%s' "$_cid" | grep -Eq '^[A-Za-z0-9_.-]{1,50}$' || nodata "$1" "сервис не вернул номер проверки"
    _creg=$(jsonfilter -i "$W/check" -e '@.blocked' 2>/dev/null)
    case "$_creg" in true|false) ;; *) _creg=null ;; esac
    _cc=$(curl -s -N $_cca -D "$W/head" -o "$W/sse" -w '%{http_code}' --connect-timeout 10 --max-time 80 -H 'Accept: text/event-stream' "$API/probe/$_cid" 2>/dev/null)
    [ "$_cc" = 200 ] || nodata "$1" "сервис проверки не ответил (HTTP ${_cc:-нет связи})"
    grep -qi '^content-type:.*text/event-stream' "$W/head" || nodata "$1" "сервис ответил не потоком событий"
    # SSE → one line per event: `event⇥data` (blocks split by an empty line; `event:`/`data:` come WITHOUT a space — measured).
    # A trailing empty line is appended so the last block is flushed by the same rule (busybox awk has no user functions).
    { tr -d '\r' < "$W/sse"; echo; } | awk '
        BEGIN { e = "message"; d = "" }
        /^$/ { if (d != "" && (e == "started" || e == "result" || e == "done")) print e "\t" d; e = "message"; d = ""; next }
        /^event:/ { e = substr($0, 7); sub(/^ +/, "", e); next }
        /^data:/ { v = substr($0, 6); sub(/^ +/, "", v); d = (d == "" ? v : d " " v); next }' > "$W/ev"
    _cso=$(awk -F'\t' '$1=="started" { print $2; exit }' "$W/ev"); _cdo=$(awk -F'\t' '$1=="done" { print $2; exit }' "$W/ev")
    [ -n "$_cso" ] && [ -n "$_cdo" ] || nodata "$1" "поток проверки не дошёл до конца"
    _con=$(jsonfilter -s "$_cso" -e '@.online_probes' 2>/dev/null); _cdn=$(jsonfilter -s "$_cdo" -e '@.online_probes' 2>/dev/null)
    _crc=$(jsonfilter -s "$_cdo" -e '@.response_count' 2>/dev/null)
    for _cv in "$_con" "$_cdn" "$_crc"; do case "$_cv" in ''|*[!0-9]*) nodata "$1" "сервис прислал неверные числа" ;; esac; done
    { [ "$_con" = "$_cdn" ] && [ "$_crc" -le "$_cdn" ]; } || nodata "$1" "сервис прислал неверные числа"
    _cn=0; _cb=0; _ck=0; _cprov=""; _cids=" "
    while IFS="$(printf '\t')" read -r _ce _cd; do
        [ "$_ce" = result ] || continue
        _cpi=$(jsonfilter -s "$_cd" -e '@.probe_id' 2>/dev/null)
        [ -n "$_cpi" ] || nodata "$1" "сервис прислал неверный ответ точки"
        case "$_cids" in *" $_cpi "*) continue ;; esac   # the same probe twice — counted once (the bot keys by probe_id)
        _cids="$_cids$_cpi "
        _cvd=$(jsonfilter -s "$_cd" -e '@.verdicts[*]' 2>/dev/null)
        printf '%s\n' "$_cvd" | grep -qvE '^(ok|tspu_block|uncertain)?$' && nodata "$1" "сервис прислал незнакомый вердикт"
        _cn=$((_cn + 1))
        if printf '%s\n' "$_cvd" | grep -qx tspu_block; then
            _cb=$((_cb + 1))
            _cp=$(jsonfilter -s "$_cd" -e '@.provider' 2>/dev/null | tr -d '"\\' | jesc 40)
            [ -n "$_cp" ] && case ", $_cprov, " in *", $_cp, "*) ;; *) _cprov="${_cprov:+$_cprov, }$_cp" ;; esac
        elif printf '%s\n' "$_cvd" | grep -qx ok; then
            _ck=$((_ck + 1))
        fi
    done < "$W/ev"
    [ "$_cn" = "$_crc" ] || nodata "$1" "получены не все ответы точек"
    _cvr=uncertain
    if [ "$_cb" -ge "$BLOCK_MIN" ]; then _cvr=blocked
    elif [ "$_cb" = 0 ] && [ "$_cn" = "$_cdn" ] && [ "$_cdn" -gt 0 ] && [ "$_ck" -ge "$CLEAR_MIN" ]; then _cvr=clear; fi
    _cprov=$(printf '%s' "$_cprov" | jtxt 200)
    put "$1" "{\"state\":\"done\",\"up\":$(uptime_s),\"verdict\":\"$_cvr\",\"blocked\":$_cb,\"ok\":$_ck,\"online\":$_cdn,\"answered\":$_cn,\"registry\":$_creg,\"providers\":\"$_cprov\"}"
    exit 0
}

cmd_get() {   # $1 = ip
    on || { printf '{"state":"off"}\n'; return 0; }
    is_ip4 "$1" || { printf '{"state":"none"}\n'; return 0; }
    # A «running» file whose worker is gone (killed, reboot of the shell) is not running: say «no data», not «still checking».
    if grep -q '"state":"running"' "$C/$1.json" 2>/dev/null && ! running "$1"; then
        printf '{"state":"error","msg":"проверка оборвалась — запустите ещё раз"}\n'; return 0
    fi
    if [ -f "$C/$1.json" ]; then
        _cg=$(cat "$C/$1.json"); fresh "$1" || _cg=$(printf '%s' "$_cg" | sed 's/}$/,"stale":true}/')
        # How long ago, by uptime (the clock jumps, C24): the panel says «проверено N мин назад» from the router's number.
        _cgs=$(printf '%s' "$_cg" | sed -n 's/.*"up":\([0-9]*\).*/\1/p'); _cgu=$(uptime_s)
        if [ -n "$_cgs" ] && [ "$_cgu" -ge "$_cgs" ] 2>/dev/null; then _cg=$(printf '%s' "$_cg" | sed "s/}\$/,\"age\":$((_cgu - _cgs))}/"); fi
        printf '%s\n' "$_cg"
    else printf '{"state":"none"}\n'; fi
}

case "$1" in
    on)    mkdir -p "$ENODIA_STATE" && : > "$ENODIA_STATE/.chebur" && echo "[chebur] второе мнение включено" ;;
    off)   rm -f "$ENODIA_STATE/.chebur" "$ENODIA_STATE/.chebur-auto"; rm -rf "$C"; echo "[chebur] второе мнение выключено" ;;
    auto)  case "$2" in
               on)  on || { echo "[chebur] сперва включите второе мнение"; exit 1; }; : > "$ENODIA_STATE/.chebur-auto"; echo "[chebur] спрашиваю сам, когда сервер молчит" ;;
               off) rm -f "$ENODIA_STATE/.chebur-auto"; echo "[chebur] сам не спрашиваю" ;;
               *)   echo "usage: $0 auto on|off"; exit 2 ;;
           esac ;;
    state) printf '{"on":%s,"auto":%s}\n' "$(on && echo true || echo false)" "$(auto && echo true || echo false)" ;;
    check) cmd_check "$2" "$3" ;;
    want)  auto || exit 0; cmd_check "$2" >/dev/null 2>&1; exit 0 ;;
    get)   cmd_get "$2" ;;
    run)   on || exit 0; cmd_run "$2" ;;
    *)     echo "usage: $0 on|off | auto on|off | state | check <ipv4> [force] | want <ipv4> | get <ipv4> | run <ipv4>"; exit 2 ;;
esac
