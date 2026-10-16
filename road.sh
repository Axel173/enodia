#!/bin/sh
# road.sh — «ДОРОГА К СЕРВЕРУ»: a carrier's own packets to its server travel through ANOTHER exit.
#
# WHY (BE7000, 09.10.2026). The ISP (ТСПУ) can cut a VPS by ADDRESS: directly the server is silent on every port, through a
# live tunnel it answers — the server is alive, the ROAD to it is cut. The cure is to carry the carrier's packets to that
# address through another exit (Cloudflare WARP: handshake in 1 s, speed close to the plain tunnel). Before this file the
# endpoint anti-loop (apply-bypass.sh endpoint_set) always sent them straight to the ISP — there was no way to say «to THIS
# server through THAT exit». Analysis and measurements — dev notes «сервер-через-WARP-дизайн».
#
# MODEL. The road is a property of a CONFIG (`awg/<file>` → exit id 2..7), not of an exit: one server rides it both as the
# main transport and as an exit. Kernel: `ip rule to <server address> lookup 100N pref 8N`, on top of the endpoint ACCEPT that
# keeps those packets unmarked. The road exit is down ⇒ its table 100N is empty (mark-core moves the exit's MARK to table
# 1000 on fallback=main, it never fills 100N) ⇒ the lookup goes on to main ⇒ direct: fail-open, neither loop nor blackhole.
# The rules are DERIVED, never stored: the main AmneziaWG config (`.active`) and its Endpoint — it rides the road carrying and
# as the warm reserve alike; an exit — its endpoint store `.endpoint-bypass-s<id>` (set while its carrier is up) and its config
# in the registry; «by which road» — `.cfg-via`. `wire` rebuilds the whole pref 82..87 block from those; whoever changes one of
# them calls it (apply-bypass on every endpoint change, road.sh itself, heal/repair through apply-bypass apply).
# One address under two carriers (two configs of one VPS) shares the road: the rule is per address — the first carrier
# that wants a road wins (main first), the panel shows the road on every config of that address.
#
# INVARIANTS (a refusal in words, never a silent cascade):
#   * a road is ONE step: the config of a road exit has no road of its own, and a config never rides the exit it runs;
#   * a road is an ENABLED AmneziaWG exit (measured; xray/hy2 carry UDP through socks — not measured; byedpi/zapret are not
#     tunnels); only AmneziaWG configs ride roads (v1, user's decision 10.10.2026);
#   * an exit somebody rides can't be disabled, deleted or moved to another transport — slots.sh asks `riders`.
# MTU. A config on a road lives inside the road's tunnel: its MTU must fit the road's MTU minus its own overhead (80 =
# IPv6-outer WireGuard, + its S4 transport padding). `mtu-fix` only LOWERS a live rider (never raises): it runs after every
# writer — the carrier's raise (via endpoint-set → wire) and a manual MTU (net-tune.sh). Clearing a road on a live carrier
# re-raises it through the orchestrator: the carrier's MTU has ONE writer, its raise — no second copy of «which MTU is due».
# A CHANGED ROAD AND AN EXIT THAT IS DOWN: its server is asked by the new path at once (`set`, the return probe).
#
# STORE: `$ENODIA_STATE/.cfg-via` — TSV `awg/<file>⇥<id>`; mechanics (lock, parse, atomic write) — label-lib.sh.
#
# Commands:
#   road.sh get <kind> <file>          — the road's exit id or empty
#   road.sh set <kind> <file> <id|"">  — set (empty = direct); invariants first, then `wire`
#   road.sh del <kind> <file>          — the config was deleted: drop its line (+ wire)
#   road.sh mv <kind> <old> <new>      — the config was renamed: its road moves with it
#   road.sh riders <id>                — configs riding this exit (one `kind/file` per line)
#   road.sh serves <kind> <file>       — the exit this config runs that somebody rides (it IS a road), or empty
#   road.sh clash <id> <file>          — a rider of exit <id> going to <file>'s server (moving the exit there would loop), or empty
#   road.sh list | json                — every road (`kind/file⇥id` / {"kind/file":"id"})
#   road.sh wire                       — rebuild the kernel rules (idempotent); `.vpn-off` ⇒ same as unwire
#   road.sh unwire                     — remove every road rule
#   road.sh want                       — the rules that MUST stand: `address⇥id⇥carrier` (main|s<id>) — dump and stands
#   road.sh mtu-cap <kind> <file>      — MTU ceiling of a config on its road (live road MTU − 80 − own S4) or empty
#   road.sh mtu-fix                    — lower live riders to their ceiling
#   road.sh carrier <main|2..7>        — the road exit of this carrier or empty; `carriers` — all of them (watchdog: whom to blame)
#   road.sh import <file> <root> | merge <file> — backup
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
STORE="$ENODIA_STATE/.cfg-via"
LOCK=/tmp/enodia-road.lock          # store writes
WLOCK=/tmp/enodia-road-wire.lock    # kernel rebuild: carriers, the panel and heal call it concurrently; `ip rule add` doesn't dedupe
KEY_RE='^awg/[A-Za-z0-9_.-]+$'      # v1: only AmneziaWG configs ride a road
OVERHEAD=80                         # WireGuard over IPv6 outer: 40 IP + 8 UDP + 32 WG (1500 − 80 = WireGuard's own 1420)
TAB=$(printf '\t')
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] && tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -qE "$2"; }
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; else
    echo "[road] нет $ENODIA_DIR/label-lib.sh — обновите установку" >&2; exit 1
fi
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
command -v ct_flush_dst >/dev/null 2>&1 || ct_flush_dst() { [ -n "$1" ] && conntrack -D -d "$1" >/dev/null 2>&1; return 0; }

key_ok() { printf '%s' "$1" | grep -qE "$KEY_RE"; }
is_ip4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
cmd_list() { lbl_list "$STORE" "$KEY_RE" | awk -F"$TAB" '$2 ~ /^[2-7]$/'; }
via_of() { cmd_list | awk -F"$TAB" -v k="$1" '$1==k { print $2; exit }'; }   # $1 = kind/file
cmd_riders() { cmd_list | awk -F"$TAB" -v i="$1" '$2==i { print $1 }'; }

# The exits registry — read ONCE per call (each `slots.sh` is a fork). Enabled exits: id⇥transport⇥config⇥fallback.
slots_enabled() { [ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" list-enabled 2>/dev/null; }
# The ENABLED AmneziaWG exits that run config $1, one id per line. The name is compared AS TEXT (`x ""`): awk takes a `-v` value
# that looks like a number for one, and config «01» was config «1» — it «served as a road» for the other's riders, and clearing
# its road re-raised the other's exit.
exits_on() { slots_enabled | awk -F"$TAB" -v c="$1" '$2=="awg" && ($3 "") == (c "") { print $1 }'; }
# Does this config SERVE as a road: it runs an enabled AmneziaWG exit somebody rides → that exit's id (empty — it doesn't). The ONLY
# answer: a config can't ride a road while it is one (`set`), and it can't be deleted from under its riders (cgi-bin/action del_server).
# Would exit $1 on config $2 go to the server of one of ITS riders: then `to <address> lookup 100N` would send the exit's own packets
# into itself. The first such rider's file, or empty. Asked by slots.sh before it moves a road exit to another config (review s.118).
cmd_clash() {   # $1 = exit id, $2 = the config it is about to run
    _rca=$(endpoint_ip_of "$ENODIA_STATE/configs/$2.conf"); [ -n "$_rca" ] || return 0
    cmd_riders "$1" | while read -r _rcr; do
        [ "$(endpoint_ip_of "$ENODIA_STATE/configs/${_rcr#*/}.conf")" = "$_rca" ] && { echo "${_rcr#*/}"; break; }
    done
    return 0
}
cmd_serves() {   # $1 = file
    for _rvm in $(exits_on "$1"); do
        [ -n "$(cmd_riders "$_rvm")" ] && { echo "$_rvm"; return 0; }
    done
    return 0
}
active_transport() { [ -f "$ENODIA_DIR/transport.sh" ] && sh "$ENODIA_DIR/transport.sh" active 2>/dev/null | head -n1 | tr -d ' \t\r'; }
active_cfg() { head -n1 "$ENODIA_STATE/.active" 2>/dev/null | tr -d '\r\n'; }
store_ip() { _rsi=$(head -n1 "$1" 2>/dev/null | tr -d ' \r\n'); is_ip4 "$_rsi" && printf '%s\n' "$_rsi"; }
endpoint_ip_of() {   # $1 = a WireGuard config: its Endpoint when it is an IPv4 literal
    _rei=$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$1" 2>/dev/null | head -n1 | sed 's/^[^=]*=//; s/:[0-9]*[[:space:]]*$//' | tr -d ' \t\r')
    is_ip4 "$_rei" && printf '%s\n' "$_rei"
}
# The address of the MAIN AmneziaWG config (`.active`) — from the config itself, not from «which transport carries»: awg0 rides
# the road both carrying and as the WARM reserve (the watchdog reads the reserve's handshake to see the home server is back —
# without the road a blocked server would never answer it), and the plugin sets its endpoint BEFORE it writes `.transport`.
# A name in Endpoint: the generated awg0.conf holds the address awg_setup resolved; last — the carrying endpoint store.
main_ip() {   # $1 = file of `.active`
    endpoint_ip_of "$ENODIA_STATE/configs/$1.conf" && return 0
    endpoint_ip_of "$ENODIA_STATE/awg0.conf" && return 0
    [ "$(active_transport)" = awg ] && store_ip "$ENODIA_STATE/.endpoint-bypass"
}

# The exit's OWN server address: its endpoint store while it is up, else its config's IPv4 literal (empty — unknown, a name).
exit_ip() {   # $1 = id, $2 = its config
    store_ip "$ENODIA_STATE/.endpoint-bypass-s$1" && return 0
    endpoint_ip_of "$ENODIA_STATE/configs/$2.conf"
}
# Is exit $1 a usable road right now (by the registry in $2): enabled, AmneziaWG, its own config rides nothing — and it does NOT go
# to the rider's own server ($3): `to <address> lookup 100N` would catch the road exit's own packets to that address too and send
# them into itself — a loop instead of fail-open (one VPS, two configs — the common case; review s.118).
road_ok() {   # $1 = id, $2 = slots_enabled output, $3 = the rider's address (empty — not checked)
    _rol=$(printf '%s\n' "$2" | awk -F"$TAB" -v i="$1" '$1==i && $2=="awg" { print $3; exit }')
    [ -n "$_rol" ] || return 1
    [ -z "$(via_of "awg/$_rol")" ] || return 1
    [ -z "$3" ] || [ "$(exit_ip "$1" "$_rol")" != "$3" ]
}

# The rules that must stand: address⇥id⇥carrier. Main first: one address — one rule, the first carrier wins.
cmd_want() {
    [ -f "$ENODIA_STATE/.vpn-off" ] && return 0
    _rws=$(slots_enabled)
    _rwc=$(active_cfg)
    if [ -n "$_rwc" ]; then
        _rwv=$(via_of "awg/$_rwc")
        if [ -n "$_rwv" ]; then
            _rwi=$(main_ip "$_rwc")
            [ -n "$_rwi" ] && road_ok "$_rwv" "$_rws" "$_rwi" && printf '%s\t%s\tmain\n' "$_rwi" "$_rwv"
        fi
    fi
    printf '%s\n' "$_rws" | while IFS="$TAB" read -r _rwid _rwt _rwcfg _rwfb; do
        [ "$_rwt" = awg ] || continue
        _rwi=$(store_ip "$ENODIA_STATE/.endpoint-bypass-s$_rwid"); [ -n "$_rwi" ] || continue
        _rwv=$(via_of "awg/$_rwcfg"); [ -n "$_rwv" ] && [ "$_rwv" != "$_rwid" ] || continue
        road_ok "$_rwv" "$_rws" "$_rwi" && printf '%s\t%s\ts%s\n' "$_rwi" "$_rwv" "$_rwid"
    done
}

# WHICH CARRIER RIDES WHICH ROAD — by the REGISTRY (`carrier⇥id`, carrier = main | s<id>), not by the rules: the watchdog asks it to
# know whom to blame, and an exit taken down while its road lies loses its endpoint store — `want` forgets it, and from the next
# tick the rider was probed as a dead server with a backoff growing to 30 min (review s.118). The rider's address here is what is
# known (store, else its config's literal) — only for the same-server check.
cmd_carriers() {
    [ -f "$ENODIA_STATE/.vpn-off" ] && return 0
    _rcs=$(slots_enabled)
    _rcm=$(active_cfg)
    if [ -n "$_rcm" ]; then
        _rcv=$(via_of "awg/$_rcm")
        [ -n "$_rcv" ] && road_ok "$_rcv" "$_rcs" "$(main_ip "$_rcm")" && printf 'main\t%s\n' "$_rcv"
    fi
    printf '%s\n' "$_rcs" | while IFS="$TAB" read -r _rcid _rct _rccfg _rcfb; do
        [ "$_rct" = awg ] || continue
        _rcv=$(via_of "awg/$_rccfg"); [ -n "$_rcv" ] && [ "$_rcv" != "$_rcid" ] || continue
        road_ok "$_rcv" "$_rcs" "$(exit_ip "$_rcid" "$_rccfg")" && printf 's%s\t%s\n' "$_rcid" "$_rcv"
    done
    return 0
}

# Our rules in the kernel now: `pref⇥address⇥table`, one line per rule (duplicates included — they are removed as stale).
have_rules() { ip rule 2>/dev/null | awk '$1 ~ /^8[2-7]:$/ { p = $1; sub(/:$/, "", p); t = ""; l = ""
    for (i = 2; i < NF; i++) { if ($i == "to") t = $(i+1); if ($i == "lookup" || $i == "table") l = $(i+1) }
    sub(/\/32$/, "", t); if (t != "") print p "\t" t "\t" l }'; }

cmd_wire() {
    # Most routers have no road at all, and every carrier raise calls us: no store and no rule ⇒ one `ip rule`, no forks.
    [ -s "$STORE" ] || [ -n "$(have_rules)" ] || return 0
    lbl_lock_take "$WLOCK" 'road\.sh' || { echo "[road] правила дорог сейчас пересобирает другая операция — повторите"; return 1; }
    _rww=$(cmd_want | awk -F"$TAB" '!($1 in s) { s[$1] = 1; print $1 "\t" $2 }')
    _rwchg=""
    # Stale or duplicate: everything that isn't wanted exactly once.
    _rwseen=""
    while IFS="$TAB" read -r _rwp _rwt _rwl; do
        [ -n "$_rwp" ] || continue
        _rwid=${_rwp#8}
        _rwk="$_rwt$TAB$_rwid"
        if [ "$_rwl" = "100$_rwid" ] && printf '%s\n' "$_rww" | grep -qxF "$_rwk" && ! printf '%s\n' "$_rwseen" | grep -qxF "$_rwk"; then
            _rwseen="$_rwseen$LBL_NL$_rwk"; continue
        fi
        ip rule del pref "$_rwp" to "$_rwt" lookup "$_rwl" 2>/dev/null
        _rwchg="$_rwchg $_rwt"
    done <<EOF
$(have_rules)
EOF
    while IFS="$TAB" read -r _rwt _rwid; do
        [ -n "$_rwt" ] || continue
        printf '%s\n' "$_rwseen" | grep -qxF "$_rwt$TAB$_rwid" && continue
        ip rule add to "$_rwt/32" lookup "100$_rwid" pref "8$_rwid" 2>/dev/null
        _rwchg="$_rwchg $_rwt"
    done <<EOF
$_rww
EOF
    lbl_lock_drop "$WLOCK"
    # A flow already set up toward the server kept its old path (and its NAT binding): flush the changed addresses only.
    for _rwt in $(printf '%s\n' $_rwchg | sort -u); do ct_flush_dst "$_rwt"; done
    cmd_mtu_fix
    return 0
}
cmd_unwire() {
    have_rules | while IFS="$TAB" read -r _rup _rut _rul; do
        ip rule del pref "$_rup" to "$_rut" lookup "$_rul" 2>/dev/null && ct_flush_dst "$_rut"
    done
    return 0
}

# MTU ceiling of a config on its road: the road's LIVE interface MTU (the fact; nothing to cap by while it is down — the
# rider's packets go direct then) − OVERHEAD − the config's S4 (AmneziaWG 2.0 pads every transport packet by S4 bytes).
cmd_mtu_cap() {   # $1 = kind, $2 = file
    key_ok "$1/$2" || return 0
    _rmv=$(via_of "$1/$2"); [ -n "$_rmv" ] || return 0
    # Only a road that WORKS caps: one `road_ok` refuses (the same server, a road that rides a road) has no rule — the packets go
    # directly, and lowering the MTU there would only slow the carrier (review s.118, round 2).
    _rma=$(endpoint_ip_of "$ENODIA_STATE/configs/$2.conf"); [ -z "$_rma" ] && [ "$2" = "$(active_cfg)" ] && _rma=$(main_ip "$2")
    road_ok "$_rmv" "$(slots_enabled)" "$_rma" || return 0
    _rmu=$(cat "/sys/class/net/awg$_rmv/mtu" 2>/dev/null | tr -cd '0-9'); [ -n "$_rmu" ] || return 0
    _rms=$(grep -E '^[[:space:]]*S4[[:space:]]*=' "$ENODIA_STATE/configs/$2.conf" 2>/dev/null | head -n1 | sed 's/^[^=]*=//' | tr -cd '0-9')
    _rmc=$((_rmu - OVERHEAD - ${_rms:-0}))
    [ "$_rmc" -ge 576 ] 2>/dev/null || _rmc=576
    printf '%s\n' "$_rmc"
}
lower_mtu() {   # $1 = iface, $2 = kind/file — lower to the ceiling, never raise
    [ -r "/sys/class/net/$1/mtu" ] || return 0
    _rlc=$(cmd_mtu_cap "${2%%/*}" "${2#*/}"); [ -n "$_rlc" ] || return 0
    _rlm=$(cat "/sys/class/net/$1/mtu" 2>/dev/null | tr -cd '0-9')
    [ -n "$_rlm" ] && [ "$_rlm" -gt "$_rlc" ] 2>/dev/null && ip link set dev "$1" mtu "$_rlc" 2>/dev/null
    return 0
}
cmd_mtu_fix() {
    [ -f "$ENODIA_STATE/.vpn-off" ] && return 0
    [ -s "$STORE" ] || return 0
    _rfc=$(active_cfg)
    [ -n "$_rfc" ] && lower_mtu awg0 "awg/$_rfc"   # carrying or the warm reserve — both ride the road
    slots_enabled | while IFS="$TAB" read -r _rfid _rft _rfcfg _rffb; do
        [ "$_rft" = awg ] && lower_mtu "awg$_rfid" "awg/$_rfcfg"
    done
    return 0
}

# The road exit of a running carrier (watchdog: «main dead and its road dead ⇒ heal the road, not the server»).
cmd_carrier() {   # $1 = main | 2..7
    case "$1" in
        main) cmd_carriers | awk -F"$TAB" '$1=="main" { print $2; exit }' ;;
        [2-7]) cmd_carriers | awk -F"$TAB" -v c="s$1" '$1==c { print $2; exit }' ;;
    esac
    return 0
}

put() {   # $1 = kind/file, $2 = id (empty = drop)
    lbl_lock_take "$LOCK" 'road\.sh' || { echo "[road] дороги сейчас правит другая операция — повторите"; return 1; }
    lbl_write "$STORE" "$1" "$2" "$KEY_RE"; _rpr=$?
    lbl_lock_drop "$LOCK"
    [ "$_rpr" = 0 ] || { echo "[road] не удалось записать дорогу (место на разделе?)"; return 1; }
    return 0
}

# Who runs this config right now: `main` (carrying), `warm` (awg0 as the reserve) and/or exit ids, one per line — the re-raise
# targets when its road is cleared.
runners() {   # $1 = file
    if [ "$(active_cfg)" = "$1" ]; then
        if [ "$(active_transport)" = awg ]; then echo main
        elif [ -e /sys/class/net/awg0 ]; then echo warm; fi
    fi
    exits_on "$1"
}

cmd_set() {   # $1 = kind, $2 = file, $3 = id | ""
    key_ok "$1/$2" || { echo "[road] дорога есть только у конфигов AmneziaWG"; return 1; }
    _rso=$(via_of "$1/$2")
    if [ -n "$3" ]; then
        # The file is needed to SET a road; a road of a removed file is still cleared below (else its exit stays «ridden»).
        [ -f "$ENODIA_STATE/configs/$2.conf" ] || { echo "[road] нет конфига «$2»"; return 1; }
        case "$3" in [2-7]) ;; *) echo "[road] номер выхода — от 2 до 7"; return 1 ;; esac
        _rsl=$([ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" show "$3" 2>/dev/null)
        [ -n "$_rsl" ] || { echo "[road] выхода №$3 нет"; return 1; }
        [ "$(printf '%s' "$_rsl" | cut -f6)" = on ] || { echo "[road] выход №$3 выключен — включите его, тогда он станет дорогой"; return 1; }
        [ "$(printf '%s' "$_rsl" | cut -f3)" = awg ] || { echo "[road] дорогой служит только выход AmneziaWG"; return 1; }
        _rsc=$(printf '%s' "$_rsl" | cut -f4)
        [ "$_rsc" != "$2" ] || { echo "[road] выход №$3 работает на этом же конфиге — по самому себе ехать нельзя"; return 1; }
        [ -z "$(via_of "awg/$_rsc")" ] || { echo "[road] выход №$3 сам едет по дороге — выберите выход, который идёт напрямую"; return 1; }
        # This config serves as somebody's road (it runs exit M, and M has riders): it can't ride one itself.
        _rsm=$(cmd_serves "$2")
        [ -z "$_rsm" ] || { echo "[road] этот конфиг сам служит дорогой (выход №$_rsm) — дорога бывает только в один шаг"; return 1; }
        _rsa=$(endpoint_ip_of "$ENODIA_STATE/configs/$2.conf"); _rsx=$(exit_ip "$3" "$_rsc")
        [ -z "$_rsa" ] || [ "$_rsa" != "$_rsx" ] || { echo "[road] выход №$3 идёт к тому же серверу ($_rsa) — его пакеты к серверу пошли бы сами в себя; выберите выход к другому серверу"; return 1; }
        [ "$_rso" = "$3" ] && { echo "[road] дорога уже через выход №$3"; return 0; }
    else
        [ -n "$_rso" ] || { echo "[road] дороги и так нет — сервер идёт напрямую"; return 0; }
    fi
    put "$1/$2" "$3" || return 1
    cmd_wire >/dev/null || true
    if [ ! -f "$ENODIA_STATE/.vpn-off" ]; then
        # THE PATH TO THE SERVER HAS JUST CHANGED — whoever runs this config is brought in line with it NOW (BE7000, the walk of
        # 12.10.2026, both halves):
        #  * the road is CLEARED under a live carrier — its MTU was lowered for the road, and its raise is the only writer of the
        #    due value: a REAL re-raise. For an exit that is slot-down + slot-up: a bare `slot-up` of a live exit is the plugin's
        #    warm path, which writes no MTU — awg3 stayed at 1188 under a config (and a panel) that said 1376;
        #  * an exit of this config whose carrier is DOWN (the watchdog took it down: its server did not answer by the OLD path)
        #    is asked by the new one at once — `slot-probe`, the watchdog's own return probe: the carrier comes back only when the
        #    server answers, a silent one changes nothing and costs no flush. Without it the exit waited out the backoff its
        #    failures on the old path had earned (4 min on the walk, up to 30) — under a road set exactly to bring it back.
        # A live carrier that GETS a road needs nothing here: `wire` above has moved its flow and lowered its MTU.
        for _rsr in $(runners "$2"); do
            case "$_rsr" in
                main) [ -n "$3" ] || sh "$ENODIA_DIR/transport.sh" restart >/dev/null 2>&1 ;;
                warm) [ -n "$3" ] || sh "$ENODIA_DIR/transport.sh" rewarm awg >/dev/null 2>&1 ;;
                *)  if [ ! -e "/sys/class/net/awg$_rsr" ]; then
                        sh "$ENODIA_DIR/transport.sh" slot-probe "$_rsr" >/dev/null 2>&1
                    elif [ -z "$3" ]; then
                        sh "$ENODIA_DIR/transport.sh" slot-down "$_rsr" >/dev/null 2>&1
                        sh "$ENODIA_DIR/transport.sh" slot-up "$_rsr" >/dev/null 2>&1
                    fi ;;
            esac
        done
    fi
    if [ -n "$3" ]; then echo "[road] дорога к серверу — через выход №$3"; else echo "[road] дорога снята — сервер идёт напрямую"; fi
    return 0
}

cmd_mv() {   # $1 = kind, $2 = old, $3 = new
    key_ok "$1/$2" && key_ok "$1/$3" || return 0
    lbl_lock_take "$LOCK" 'road\.sh' || { echo "[road] дороги сейчас правит другая операция — повторите"; return 1; }
    _rmvv=$(via_of "$1/$2")
    lbl_write "$STORE" "$1/$2" "" "$KEY_RE" && { [ -z "$_rmvv" ] || lbl_write "$STORE" "$1/$3" "$_rmvv" "$KEY_RE"; }; _rmvr=$?
    lbl_lock_drop "$LOCK"
    [ "$_rmvr" = 0 ] || { echo "[road] не удалось перенести дорогу"; return 1; }
    return 0
}

# Backup import (cgi-bin/backup): the archive's road wins for the configs the archive BROUGHT; a local road of a config the
# archive replaced without a road line is dropped (it described another server under the same file) — cfg-names.sh import's rule.
cmd_import() {   # $1 = archive's .cfg-via (may be absent), $2 = archive root
    _rik=$(for _rif in "$2"/configs/*.conf; do [ -f "$_rif" ] && { _rib=${_rif##*/}; echo "awg/${_rib%.conf}"; }; done)
    lbl_lock_take "$LOCK" 'road\.sh' || { echo "[road] дороги сейчас правит другая операция — повторите"; return 1; }
    lbl_import "$STORE" "$1" "$_rik" "$KEY_RE"; _rir=$?
    lbl_lock_drop "$LOCK"
    [ "$_rir" = 0 ] || { echo "[road] не удалось записать дороги (место на разделе?)"; return 1; }
    cmd_wire >/dev/null || true
    return 0
}
cmd_merge() {
    [ -f "$1" ] || { echo "[road] нет файла $1"; return 1; }
    lbl_lock_take "$LOCK" 'road\.sh' || { echo "[road] дороги сейчас правит другая операция — повторите"; return 1; }
    lbl_merge "$STORE" "$1" "$KEY_RE"; _rgr=$?
    lbl_lock_drop "$LOCK"
    [ "$_rgr" = 0 ] || { echo "[road] не удалось записать дороги (место на разделе?)"; return 1; }
    cmd_wire >/dev/null || true
    return 0
}

case "$1" in
    get)     key_ok "$2/$3" && via_of "$2/$3"; exit 0 ;;
    set)     cmd_set "$2" "$3" "$4" ;;
    del)     key_ok "$2/$3" || exit 0; [ -n "$(via_of "$2/$3")" ] || exit 0; put "$2/$3" "" && cmd_wire >/dev/null ;;
    mv)      cmd_mv "$2" "$3" "$4" ;;
    riders)  case "$2" in [2-7]) cmd_riders "$2" ;; esac; exit 0 ;;
    serves)  key_ok "$2/$3" && cmd_serves "$3"; exit 0 ;;
    clash)   case "$2" in [2-7]) key_ok "awg/$3" && cmd_clash "$2" "$3" ;; esac; exit 0 ;;
    list)    cmd_list; exit 0 ;;
    json)    cmd_list | awk -F"$TAB" '{ printf "%s\"%s\":\"%s\"", (c++ ? "," : ""), $1, $2 }'; exit 0 ;;
    wire)    cmd_wire ;;
    unwire)  cmd_unwire ;;
    want)    cmd_want; exit 0 ;;
    mtu-cap) cmd_mtu_cap "$2" "$3"; exit 0 ;;
    mtu-fix) cmd_mtu_fix ;;
    carrier) cmd_carrier "$2"; exit 0 ;;
    carriers) cmd_carriers; exit 0 ;;
    import)  cmd_import "$2" "$3" ;;
    merge)   cmd_merge "$2" ;;
    *) echo "usage: $0 get <вид> <файл> | set <вид> <файл> <id|\"\"> | del <вид> <файл> | mv <вид> <старый> <новый> | riders <id> | list | json | wire | unwire | want | mtu-cap <вид> <файл> | mtu-fix | carrier <main|id> | import <файл> <корень> | merge <файл>"; exit 2 ;;
esac
