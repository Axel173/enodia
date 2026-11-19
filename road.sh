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
# The rules are DERIVED from the published endpoint stores and `.cfg-via`. The warm AmneziaWG reserve has its own row.
# `wire` rebuilds the whole pref 82..87 block from those; whoever changes one of
# them calls it (apply-bypass on every endpoint change, road.sh itself, heal/repair through apply-bypass apply).
# One address under two carriers (two configs of one VPS) shares the road: the rule is per address — the first carrier
# that wants a road wins (main first), the panel shows the road on every config of that address.
#
# INVARIANTS (a refusal in words, never a silent cascade):
#   * a road is ONE step: the config of a road exit has no road of its own, and a config never rides the exit it runs;
#   * a road is an ENABLED AmneziaWG exit; AmneziaWG, Xray and Hysteria2 configs can ride it over IPv4;
#   * an exit somebody rides can't be disabled, deleted or moved to another transport — slots.sh asks `riders`.
# MTU. A config on a road lives inside the road's tunnel: its MTU must fit the road's MTU minus its own overhead (80 =
# IPv6-outer WireGuard, + its S4 transport padding). `mtu-fix` only LOWERS a live rider (never raises): it runs after every
# writer — the carrier's raise (via endpoint-set → wire) and a manual MTU (net-tune.sh). Clearing a road on a live carrier
# re-raises it through the orchestrator: the carrier's MTU has ONE writer, its raise — no second copy of «which MTU is due».
# A CHANGED ROAD AND AN EXIT THAT IS DOWN: its server is asked by the new path at once (`set`, the return probe).
#
# STORE: `$ENODIA_STATE/.cfg-via` — TSV `<kind>/<file>⇥<id>`, kind is awg, xray or hy2; label-lib.sh owns the file mechanics.
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
#   road.sh probe-paths <kind/file> <bound|temporary> <address>... — address, exit and installed/saved probe source
#   road.sh want                       — the rules that MUST stand: `address⇥id⇥carrier` (main|s<id>) — dump and stands
#   road.sh mtu-cap <kind> <file>      — MTU ceiling of a config on its road (live road MTU − 80 − own S4) or empty
#   road.sh mtu-fix                    — lower live riders to their ceiling
#   road.sh carrier <main|2..7>        — the road exit of this carrier or empty; `carriers` — all of them (watchdog: whom to blame)
#   road.sh import <archive root> | merge <file> — backup
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
STORE="$ENODIA_STATE/.cfg-via"
LOCK=/tmp/enodia-road.lock          # store writes
WLOCK=/tmp/enodia-road-wire.lock    # kernel rebuild: carriers, the panel and heal call it concurrently; `ip rule add` doesn't dedupe
OVERHEAD=80                         # WireGuard over IPv6 outer: 40 IP + 8 UDP + 32 WG (1500 − 80 = WireGuard's own 1420)
TAB=$(printf '\t')
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] && tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -qE "$2"; }
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; else
    echo "[road] нет $ENODIA_DIR/label-lib.sh — обновите установку" >&2; exit 1
fi
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
command -v ct_flush_dst >/dev/null 2>&1 || ct_flush_dst() { [ -n "$1" ] && conntrack -D -d "$1" >/dev/null 2>&1; return 0; }

KEY_RE=$LBL_CFG_KEY_RE
is_ip4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
cmd_list() { lbl_list "$STORE" "$KEY_RE" | awk -F"$TAB" '$2 ~ /^[2-7]$/'; }
via_of() { cmd_list | awk -F"$TAB" -v k="$1" '$1==k { print $2; exit }'; }   # $1 = kind/file
cmd_riders() { cmd_list | awk -F"$TAB" -v i="$1" '$2==i { print $1 }'; }

cfg_path() {
    case "$1" in
        awg) echo "$ENODIA_STATE/configs/$2.conf" ;;
        xray) echo "$ENODIA_STATE/xray-configs/$2.json" ;;
        hy2) echo "$ENODIA_STATE/hy2-configs/$2.yaml" ;;
    esac
}
alt_members() (   # kind, config path, hosts|ips, seed file, [shared]
    [ -r "$2" ] && [ -f "$ENODIA_DIR/dns-lib.sh" ] || exit 0
    . "$ENODIA_DIR/dns-lib.sh"
    case "$1" in
        xray) [ -f "$ENODIA_DIR/xray-profile-lib.sh" ] && . "$ENODIA_DIR/xray-profile-lib.sh" && xp_members "$2" "$3" "$4" "${5:-}" ;;
        hy2) _ram_host=$(hy2_conf_host "$2")
             if [ "$3" = hosts ]; then printf '%s\n' "$_ram_host"; else seed_ipv4_rows "$_ram_host" "$4" "${5:-}" | sort -u; fi ;;
    esac
)
live_pin_ips() (   # publication, seed file
    [ -f "$ENODIA_DIR/dns-lib.sh" ] || exit 0
    . "$ENODIA_DIR/dns-lib.sh"
    _rlp_hosts=$(printf '%s\n' "$1" | lbl_endpoint_hosts)
    [ -n "$_rlp_hosts" ] || _rlp_hosts=$(seed_pin_names "$2" "$(printf '%s\n' "$1" | sed '/^key=/,$d')")
    for _rlp_host in $_rlp_hosts; do seed_ipv4_rows "$_rlp_host" "$2" pins; done
)
key_ips() {   # addresses known before an edit, including any live publication
    case "$1" in
        awg/*)
            _rki_file=${1#*/}
            endpoint_ip_of "$(cfg_path awg "$_rki_file")"
            [ "$(active_cfg)" != "$_rki_file" ] || main_ip "$_rki_file"
            for _rki_id in $(exits_on "$_rki_file"); do exit_ip "$_rki_id" "$_rki_file"; done ;;
        *) alt_members "${1%%/*}" "$(cfg_path "${1%%/*}" "${1#*/}")" ips "" shared ;;
    esac
    for _rki_store in "$ENODIA_STATE/.endpoint-bypass" "$ENODIA_STATE"/.endpoint-bypass-s[2-7]; do
        [ "$(lbl_endpoint_key "$_rki_store")" = "$1" ] || continue
        sed '/^key=/,$d' "$_rki_store"
        case "$1" in xray/*|hy2/*)
            _rki_suffix=${_rki_store##*/.endpoint-bypass}
            live_pin_ips "$(cat "$_rki_store")" "/etc/dnsmasq.d/02-altserver$_rki_suffix.conf" ;;
        esac
    done
}
hy2_mtu_ok() { [ "$(cat "/sys/class/net/awg$1/mtu" 2>/dev/null)" -ge 1228 ] 2>/dev/null; }

hy2_warp_notice() {   # exit id, [timeout]
    local _hwn_cfg
    [ -f "$ENODIA_DIR/warp.sh" ] || return 1
    _hwn_cfg=$(slots_enabled | awk -F"$TAB" -v id="$1" '$1==id && $2=="awg" {print $3; exit}')
    [ -n "$_hwn_cfg" ] || return 1
    sh "$ENODIA_DIR/warp.sh" list | awk -F"$TAB" -v c="$_hwn_cfg" '($1 "")==(c "") {ok=1; exit} END {exit !ok}' || return 1
    [ ! -f "$ENODIA_DIR/nf-i18n.sh" ] || . "$ENODIA_DIR/nf-i18n.sh"
    case "$(command -v nf_lang >/dev/null 2>&1 && nf_lang):$2" in
        en:timeout) echo '[road] Hysteria2 handshake timed out through WARP. Choose another road or connect directly.' ;;
        *:timeout)  echo '[road] Тайм-аут рукопожатия Hysteria2 через WARP. Выберите другую дорогу или прямое подключение.' ;;
        en:*)       echo '[road] WARP can drop large Hysteria2 handshake packets. Verify egress after switching.' ;;
        *)          echo '[road] WARP может терять крупные пакеты рукопожатия Hysteria2. После подключения проверьте выход в интернет через сервер.' ;;
    esac
}

# The exits registry — read ONCE per call (each `slots.sh` is a fork). Enabled exits: id⇥transport⇥config⇥fallback.
slots_enabled() { [ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" list-enabled 2>/dev/null; }
# The ENABLED AmneziaWG exits that run config $1, one id per line. The name is compared AS TEXT (`x ""`): awk takes a `-v` value
# that looks like a number for one, and config «01» was config «1» — it «served as a road» for the other's riders, and clearing
# its road re-raised the other's exit.
exits_on() { slots_enabled | awk -F"$TAB" -v c="$1" '$2=="awg" && ($3 "") == (c "") { print $1 }'; }
# Does this config SERVE as a road: it runs an enabled AmneziaWG exit somebody rides → that exit's id (empty — it doesn't). The ONLY
# answer: a config can't ride a road while it is one (`set`), and it can't be deleted from under its riders (cgi-bin/action del_server).
# An address of a serving exit must stay direct, no matter whose road its rider uses.
overlap() {   # road endpoint IPv4, optional new rider key
    [ -n "$1" ] || return 0
    for _rok in ${2:-$(cmd_list | cut -f1)}; do
        key_ips "$_rok" | grep -qxF "$1" && { echo "${_rok#awg/}"; break; }
    done
    return 0
}
cmd_clash() {
    [ -n "$(cmd_riders "$1")" ] || return 0
    overlap "$(endpoint_ip_of "$(cfg_path awg "$2")")"
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
# Annotate enabled AWG exits with the one-hop check. Keep all their addresses available to the loop guard.
road_exits() {
    { cmd_list; printf '%s\n' "$1"; } | awk -F "$TAB" '
        NF==2 { via[$1]=1; next }
        $2=="awg" { print $0 "\t" (!via["awg/" $3]) }'
}
road_peer_stale() {   # exit, configured file; a cold exit can still be selected
    command -v awg_peers_match >/dev/null 2>&1 || return 1
    ip link show "awg$1" >/dev/null 2>&1 || return 1
    _rps_awg=${ENODIA_BIN:-/data/usr/app/enodia-bin}/awg
    [ -x "$_rps_awg" ] || _rps_awg=$(command -v awg)
    ! awg_peers_match "$_rps_awg" "awg$1" "$(cfg_path awg "$2")"
}
# Is exit $1 an eligible road (by the registry in $2): enabled, AmneziaWG, its own config rides nothing — and it does NOT go
# to the rider's own server ($3): `to <address> lookup 100N` would catch the road exit's own packets to that address too and send
# them into itself — a loop instead of fail-open (one VPS, two configs — the common case; review s.118).
road_ok() {   # $1 = id, $2 = slots_enabled output, $3 = the rider's address (empty — not checked)
    _rol=$(road_exits "$2" | awk -F"$TAB" -v i="$1" '$1==i && $5 { print $3; exit }')
    [ -n "$_rol" ] || return 1
    road_peer_stale "$1" "$_rol" && return 2
    [ -z "$3" ] || [ "$(exit_ip "$1" "$_rol")" != "$3" ]
}
cmd_eligible() {
    _rei_id=$(via_of "$1/$2")
    [ -n "$_rei_id" ] || return 0
    road_ok "$_rei_id" "$(slots_enabled)" ""; _rei_status=$?
    [ "$_rei_status" != 1 ] || return 0
    printf '%s\n' "$_rei_id"
    return "$_rei_status"
}

# One input stream for the address winners and watchdog dependencies.
carrier_rows() {   # carrier, fallback key, slot, published record, current selection flag
    _rcr_key=$(printf '%s\n' "$4" | lbl_endpoint_key)
    _rcr_live=1
    if [ -z "$_rcr_key" ]; then
        _rcr_key=$2
        case "$2:$4" in awg/*:[0-9]*) ;; *) _rcr_live=0 ;; esac
    fi
    lbl_cfg_key "$_rcr_key" || return 0
    case "$_rcr_key" in
        awg/*)
            if [ "$_rcr_live" = 1 ]; then _rcr_ips=$(printf '%s\n' "$4" | grep -E '^[0-9]')
            else _rcr_ips=$(endpoint_ip_of "$(cfg_path awg "${_rcr_key#*/}")"); fi ;;
        *) _rcr_ips=$({
            _rcr_seed="/etc/dnsmasq.d/02-altserver${3:+-s$3}.conf"
            if [ "$_rcr_live" = 1 ]; then
                printf '%s\n' "$4" | sed '/^key=/,$d'
                live_pin_ips "$4" "$_rcr_seed"
            else
                alt_members "${_rcr_key%%/*}" "$(cfg_path "${_rcr_key%%/*}" "${_rcr_key#*/}")" ips "$_rcr_seed" shared
            fi
        } | sort -u) ;;
    esac
    for _rcr_ip in ${_rcr_ips:--}; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$_rcr_key" "$_rcr_live" "$_rcr_ip" "$5"
    done
}
rider_rows() {   # carrier, selected key, slot, published record
    _rrr_live=$(printf '%s\n' "$4" | lbl_endpoint_key)
    if [ -z "$2" ]; then
        carrier_rows "$1" '' "$3" "$4" 2   # a legacy publication can own rules without a selected rider
    elif [ -n "$_rrr_live" ] && [ "$_rrr_live" != "$2" ]; then
        carrier_rows "$1" '' "$3" "$4" 0
        carrier_rows "$1" "$2" "$3" '' 1
    else
        carrier_rows "$1" "$2" "$3" "$4" 1
    fi
}
road_rows() {
    _rr_via=$(cmd_list)
    printf '%s\n' "$_rr_via" | sed "s/^/via$TAB/"
    _rr_record=$(cat "$ENODIA_STATE/.endpoint-bypass" 2>/dev/null)
    _rr_cfg=$(active_cfg)
    _rr_kind=$(head -n1 "$ENODIA_STATE/.transport" 2>/dev/null)
    [ -n "$_rr_kind" ] || _rr_kind=$(active_transport)
    _rr_selected=''
    case "$_rr_kind" in
        awg|'') _rr_selected=${_rr_cfg:+awg/$_rr_cfg} ;;
        xray|hy2)
            _rr_name=$(head -n1 "$ENODIA_STATE/.$_rr_kind-active" 2>/dev/null | tr -d '\r')
            _rr_selected=${_rr_name:+$_rr_kind/$_rr_name} ;;
    esac
    _rr_main=$(printf '%s\n' "$_rr_record" | lbl_endpoint_key)
    if [ -z "$_rr_main" ] && [ -n "$_rr_cfg" ] && [ "$_rr_selected" = "awg/$_rr_cfg" ]; then
        printf 'main\t%s\t1\t%s\t1\n' "$_rr_selected" "$(main_ip "$_rr_cfg")"
    else
        rider_rows main "$_rr_selected" '' "$_rr_record"
    fi
    if [ -n "$_rr_cfg" ] && [ "$_rr_main" != "awg/$_rr_cfg" ]; then
        [ "$_rr_selected" = "awg/$_rr_cfg" ] || printf 'warm\tawg/%s\t1\t%s\t0\n' "$_rr_cfg" "$(main_ip "$_rr_cfg")"
    fi
    _rr_slots=$(slots_enabled)
    road_exits "$_rr_slots" | while IFS="$TAB" read -r _rr_id _rr_kind _rr_file _rr_fb _rr_ok; do
        _rr_addr=$(exit_ip "$_rr_id" "$_rr_file")
        _rr_mtu=0; hy2_mtu_ok "$_rr_id" && _rr_mtu=1
        _rr_stale=0
        if printf '%s\n' "$_rr_via" | grep -q "${TAB}$_rr_id\$" && road_peer_stale "$_rr_id" "$_rr_file"; then _rr_stale=1; fi
        printf 'exit\t%s\t%s\t%s\t%s\t%s\n' "$_rr_id" "$_rr_ok" "$_rr_addr" "$_rr_mtu" "$_rr_stale"
    done
    printf '%s\n' "$_rr_slots" | while IFS="$TAB" read -r _rr_id _rr_kind _rr_file _rr_fb; do
        rider_rows "s$_rr_id" "$_rr_kind/$_rr_file" "$_rr_id" "$(cat "$ENODIA_STATE/.endpoint-bypass-s$_rr_id" 2>/dev/null)"
    done
}
road_view() {
    [ ! -f "$ENODIA_STATE/.vpn-off" ] && [ -s "$STORE" ] || return 0
    road_rows | awk -F "$TAB" -v mode="$1" '
        $1=="via" { via[$2]=$3; serving[$3]=1; next }
        $1=="exit" { exits[$2]=$3; mtu[$2]=$5; stale[$2]=$6; if (serving[$2] && $4!="") guard[$4]=1; next }
        { tag[++n]=$1; key[n]=$2; live[n]=$3; ip[n]=$4; selected[n]=$5
          if ($3) { published[$1]=1; if ($2~/^hy2\//) quic[$4]=1 } }
        END {
            for (i=1; i<=n; i++) {
                a=ip[i]; r=via[key[i]]
                if (r && exits[r] && tag[i]!="s" r && !(a in guard))
                    candidate[i]=r
                if (live[i] && a!="" && a!="-" && candidate[i] && !stale[r] && !winner[a] && (!quic[a] || mtu[r])) {
                    winner[a]=r
                    if (mode=="want") print a "\t" r "\t" (tag[i]=="warm" ? "main" : tag[i])
                }
            }
            if (mode=="want") exit
            for (i=1; i<=n; i++) {
                t=tag[i]; if (t=="warm") continue
                if (mode=="watchdog" ? selected[i]!=1 : published[t] && !live[i]) continue
                r=winner[ip[i]]
                if (!r) r=candidate[i]
                if (!(t in dep)) { dep[t]=r; rider[t]=key[i] }
                else if (dep[t]!=r) dep[t]=""
            }
            for (i=1; i<=n; i++) {
                t=tag[i]; if (!dep[t]) continue
                printf "%s\t%s",t,dep[t]
                if (mode=="watchdog") printf "\t%s\t%d",rider[t],stale[dep[t]]
                printf "\n"; delete dep[t]
            }
        }'
}
# Our rules in the kernel now: `pref⇥address⇥table`, one line per rule (duplicates included — they are removed as stale).
have_rules() {
    _hrules=$(ip rule show 2>/dev/null) || return 1
    printf '%s\n' "$_hrules" | awk '$1 ~ /^8[2-7]:$/ { p = $1; sub(/:$/, "", p); t = ""; l = ""
    for (i = 2; i < NF; i++) { if ($i == "to") t = $(i+1); if ($i == "lookup" || $i == "table") l = $(i+1) }
    sub(/\/32$/, "", t); if (t != "") print p "\t" t "\t" l }'; }

road_table_up() {
    ip route show table "100$1" 2>/dev/null | grep -E "^default dev awg$1([[:space:]]|$)" | grep -vq ' linkdown'   # not-wan: road table
}

# For each address, the first installed road whose table can forward it.
usable_paths() {
    _rpr=$1
    [ -n "$_rpr" ] || return 0
    _rpu=" "
    for _rpi in $(printf '%s\n' "$_rpr" | awk '$3 == 1000 + ($1-80) && !seen[$1]++ { print $1-80 }'); do
        if road_table_up "$_rpi"; then
            _rpu="$_rpu$_rpi "
        fi
    done
    printf '%s\n' "$_rpr" | awk -F "$TAB" -v usable="$_rpu" '
        { id=$1-80 }
        $3==1000+id && index(usable," " id " ") && !seen[$2]++ { print $2 "\t" id }'
}

cmd_paths() { usable_paths "$(have_rules)"; }
road_live_ips() { road_rows | awk -F "$TAB" '$1=="exit" || ($1!="via" && $3) {print $4}' | sort -u; }

# Address, exit, source. A probe can use a saved road only where no permanent rule
# stands. A temporary kernel rule must also leave existing carriers' dials alone.
cmd_probe_paths() {   # <kind/file> <bound|temporary> <address>...
    _rpp_key=$1; _rpp_mode=$2; shift 2
    _rpp_rules=$(have_rules) || return 1
    _rpp_live=$(usable_paths "$_rpp_rules")
    _rpp_id=$(via_of "$_rpp_key")
    _rpp_ready=
    for _rpp_ip do
        is_ip4 "$_rpp_ip" || return 1
        _rpp_hit=$(printf '%s\n' "$_rpp_live" | awk -F "$TAB" -v a="$_rpp_ip" '$1==a {print $2; exit}')
        if [ -n "$_rpp_hit" ]; then
            printf '%s\t%s\tinstalled\n' "$_rpp_ip" "$_rpp_hit"
            continue
        fi
        printf '%s\n' "$_rpp_rules" | awk -F "$TAB" -v a="$_rpp_ip" '$2==a{found=1; exit} END{exit !found}' && return 1
        if [ -z "$_rpp_ready" ]; then
            [ -n "$_rpp_id" ] && [ ! -f "$ENODIA_STATE/.vpn-off" ] && road_table_up "$_rpp_id" &&
                road_ok "$_rpp_id" "$(slots_enabled)" "" || return 1
            _rpp_edge=$(exit_ip "$_rpp_id" "$_rol")
            if [ "$_rpp_mode" = temporary ]; then
                _rpp_protected=$(road_live_ips)
            fi
            _rpp_ready=1
        fi
        [ "$_rpp_ip" != "$_rpp_edge" ] || return 1
        if [ "$_rpp_mode" = temporary ] && printf '%s\n' "$_rpp_protected" | grep -qxF "$_rpp_ip"; then return 2; fi
        printf '%s\t%s\tsaved\n' "$_rpp_ip" "$_rpp_id"
    done
}

# Serialize temporary installation with live publication's wire pass.
cmd_probe_wire() (
    lbl_lock_take "$WLOCK" 'road\.sh' || exit 3
    trap 'lbl_lock_drop "$WLOCK"' EXIT
    trap 'exit 3' HUP INT TERM PIPE
    _rpw_key=$1; shift
    _rpw_paths=$(cmd_probe_paths "$_rpw_key" temporary "$@") || exit "$?"
    _rpw_n=0
    while IFS="$TAB" read -r _rpw_ip _rpw_id _rpw_src; do
        [ "$_rpw_src" = saved ] || continue
        ip rule add to "$_rpw_ip/32" iif lo lookup "100$_rpw_id" pref 88 2>/dev/null || exit 5
        _rpw_n=$((_rpw_n + 1))
    done <<EOF
$_rpw_paths
EOF
    printf '%s\n' "$_rpw_n"
)

road_probe_reap() {
    _rpr_rules=$(ip rule show 2>/dev/null) || return 0
    if printf '%s\n' "$_rpr_rules" | grep -q '^88:'; then
        if [ -d "$XT_ROAD_LOCK" ] && lbl_lock_live "$XT_ROAD_LOCK" xray-test; then
            for _rpr_ip in $(road_live_ips); do lbl_rule_sweep 88 iif lo to "$_rpr_ip/32"; done
        else
            lbl_rule_sweep 88 iif lo
        fi
    fi
    if printf '%s\n' "$_rpr_rules" | grep -q '^51:' &&
       { [ ! -d "$TRY_LOCK" ] || ! lbl_lock_live "$TRY_LOCK" "$TRY_LOCK_HOLDERS"; } &&
       lbl_lock_take "$TRY_LOCK" "$TRY_LOCK_HOLDERS"; then
        lbl_rule_sweep 51
        lbl_lock_drop "$TRY_LOCK"
    fi
}

cmd_main_path() {   # kind, active config (legacy AWG fallback)
    _rmp_paths=$(cmd_paths)
    [ -n "$_rmp_paths" ] || return 0
    _rmp_record=$(cat "$ENODIA_STATE/.endpoint-bypass" 2>/dev/null)
    if [ -n "$(printf '%s\n' "$_rmp_record" | lbl_endpoint_key)" ]; then
        _rmp_ips=$(carrier_rows main "" "" "$_rmp_record" 1 | cut -f4)
    elif [ "$1" = awg ]; then _rmp_ips=$(main_ip "$2")
    else _rmp_ips=$(printf '%s\n' "$_rmp_record" | grep -E '^[0-9]'); fi
    # Only report one path if it carries every published address for this carrier.
    printf '%s\nmain\n%s\n' "$_rmp_paths" "$_rmp_ips" | awk -F "$TAB" '
        $0=="main" { main=1; next }
        !main { path[$1]=$2; next }
        NF { if (!path[$1] || (id && id!=path[$1])) { mixed=1; exit }; id=path[$1] }
        END { if (id && !mixed) print id }'
}

cmd_wire() {
    _rwchg=""; _rwfail=0
    _rwerr="[road] не удалось применить правила дороги — повторите выбор"
    # A failed clear can leave a rule after the last saved row is gone.
    if [ ! -s "$STORE" ] && [ ! -d "$WLOCK" ]; then
        _rwh=$(ip rule show 2>/dev/null) || { echo "$_rwerr"; return 1; }
        printf '%s\n' "$_rwh" | grep -qE '^(51|8[2-8]):' || return 0
    fi
    lbl_lock_take "$WLOCK" 'road\.sh' || { echo "[road] правила дорог сейчас пересобирает другая операция — повторите"; return 1; }
    road_probe_reap
    _rwh=$(have_rules) || { lbl_lock_drop "$WLOCK"; echo "$_rwerr"; return 1; }
    _rww=$(road_view want | cut -f1,2)
    # Stale or duplicate: everything that isn't wanted exactly once.
    _rwseen=""
    while IFS="$TAB" read -r _rwp _rwt _rwl; do
        [ -n "$_rwp" ] || continue
        _rwid=${_rwp#8}
        _rwk="$_rwt$TAB$_rwid"
        if [ "$_rwl" = "100$_rwid" ] && printf '%s\n' "$_rww" | grep -qxF "$_rwk" && ! printf '%s\n' "$_rwseen" | grep -qxF "$_rwk"; then
            _rwseen="$_rwseen$LBL_NL$_rwk"; continue
        fi
        if ip rule del pref "$_rwp" to "$_rwt" lookup "$_rwl" 2>/dev/null; then _rwchg="$_rwchg $_rwt"
        else _rwfail=1; fi
    done <<EOF
$_rwh
EOF
    # Keep any failed-to-retire rule from competing with a replacement.
    while [ "$_rwfail" = 0 ] && IFS="$TAB" read -r _rwt _rwid; do
        [ -n "$_rwt" ] || continue
        printf '%s\n' "$_rwseen" | grep -qxF "$_rwt$TAB$_rwid" && continue
        if ip rule add to "$_rwt/32" lookup "100$_rwid" pref "8$_rwid" 2>/dev/null; then _rwchg="$_rwchg $_rwt"
        else _rwfail=1; fi
    done <<EOF
$_rww
EOF
    lbl_lock_drop "$WLOCK"
    # A flow already set up toward the server kept its old path (and its NAT binding): flush the changed addresses only.
    for _rwt in $(printf '%s\n' $_rwchg | sort -u); do ct_flush_dst "$_rwt"; done
    [ "$_rwfail" = 0 ] || { echo "$_rwerr"; return 1; }
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
    [ "$1" = awg ] && lbl_cfg_key "$1/$2" || return 0
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
        main) road_view carriers | awk -F"$TAB" '$1=="main" { print $2; exit }' ;;
        [2-7]) road_view carriers | awk -F"$TAB" -v c="s$1" '$1==c { print $2; exit }' ;;
    esac
    return 0
}

put() {   # kind/file, road id (empty = drop), expected exit config for a new assignment
    lbl_lock_take "$LOCK" 'road\.sh' || { echo "[road] дороги сейчас правит другая операция — повторите"; return 1; }
    if [ -n "$2" ] && [ "$(sh "$ENODIA_DIR/slots.sh" show "$2" 2>/dev/null | cut -f3,4,6)" != "awg$TAB$3${TAB}on" ]; then
        lbl_lock_drop "$LOCK"
        echo "[road] выход №$2 изменился — выберите дорогу заново"; return 1
    fi
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
    lbl_cfg_key "$1/$2" || { echo "[road] дорога доступна для конфигов AmneziaWG, Xray и Hysteria2"; return 1; }
    _rso=$(via_of "$1/$2")
    if [ -n "$3" ] && [ "$_rso" != "$3" ]; then
        # The file is needed to SET a road; a road of a removed file is still cleared below (else its exit stays «ridden»).
        _rsfile=$(cfg_path "$1" "$2")
        [ -f "$_rsfile" ] || { echo "[road] нет конфига «$2»"; return 1; }
        case "$3" in [2-7]) ;; *) echo "[road] номер выхода — от 2 до 7"; return 1 ;; esac
        _rsl=$([ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" show "$3" 2>/dev/null)
        [ -n "$_rsl" ] || { echo "[road] выхода №$3 нет"; return 1; }
        [ "$(printf '%s' "$_rsl" | cut -f6)" = on ] || { echo "[road] выход №$3 выключен — включите его, тогда он станет дорогой"; return 1; }
        [ "$(printf '%s' "$_rsl" | cut -f3)" = awg ] || { echo "[road] дорогой служит только выход AmneziaWG"; return 1; }
        _rsc=$(printf '%s' "$_rsl" | cut -f4)
        [ "awg/$_rsc" != "$1/$2" ] || { echo "[road] выход №$3 работает на этом же конфиге — по самому себе ехать нельзя"; return 1; }
        road_ok "$3" "$(printf '%s\n' "$_rsl" | cut -f1,3-5)" ""
        case "$?" in
            1) echo "[road] выход №$3 сам едет по дороге — выберите выход, который идёт напрямую"; return 1 ;;
            2) echo "[road] выход №$3 ещё работает с прежним сервером — переподнимите выход"; return 1 ;;
        esac
        # This config serves as somebody's road (it runs exit M, and M has riders): it can't ride one itself.
        _rsm=$([ "$1" != awg ] || cmd_serves "$2")
        [ -z "$_rsm" ] || { echo "[road] этот конфиг сам служит дорогой (выход №$_rsm) — дорога бывает только в один шаг"; return 1; }
        _rsh=$(if [ "$1" = awg ]; then grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$_rsfile" | sed 's/[[:space:]]*#.*//; s/:[0-9]*[[:space:]]*$//'; else alt_members "$1" "$_rsfile" hosts ""; fi)
        case "$_rsh" in *:*) echo "[road] дорога к серверу доступна только по IPv4 — в конфиге адрес IPv6"; return 1 ;; esac
        [ "$1" != hy2 ] || hy2_mtu_ok "$3" || { echo "[road] Hysteria2 нужен больший MTU пути"; return 1; }
        _rse=$(exit_ip "$3" "$_rsc")
        _rs_conflict=$(overlap "$_rse")
        if [ -n "$_rs_conflict" ] && [ -z "$(cmd_riders "$3")" ]; then
            echo "[road] выход №$3 уже нужен серверу $_rs_conflict по другой дороге — выберите выход к другому серверу"; return 1
        fi
        while IFS="$TAB" read -r _rsi _rst _rsk _rsf; do
            [ "$_rst" = awg ] && { [ "$_rsi" = "$3" ] || [ -n "$(cmd_riders "$_rsi")" ]; } || continue
            _rsx=$(exit_ip "$_rsi" "$_rsk"); [ -n "$_rsx" ] || continue
            [ -n "$(overlap "$_rsx" "$1/$2")" ] || continue
            echo "[road] выход №$_rsi идёт к тому же серверу ($_rsx) — его пакеты к серверу пошли бы сами в себя; выберите выход к другому серверу"; return 1
        done <<EOF
$(slots_enabled)
EOF
    fi
    [ "$_rso" = "$3" ] || put "$1/$2" "$3" "${_rsc:-}" || return 1
    cmd_wire || return 1
    if [ "$1" = hy2 ] && [ -n "$3" ]; then hy2_warp_notice "$3" "" || :; fi
    if [ "$_rso" = "$3" ] && [ -z "$_rwchg" ]; then
        if [ -n "$3" ]; then echo "[road] дорога уже через выход №$3"
        else echo "[road] дороги и так нет — сервер идёт напрямую"; fi
        return 0
    fi
    if [ ! -f "$ENODIA_STATE/.vpn-off" ] && [ "$1" = awg ]; then
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
    elif [ ! -f "$ENODIA_STATE/.vpn-off" ]; then
        _rs_live=$(lbl_endpoint_key "$ENODIA_STATE/.endpoint-bypass")
        if [ "$_rs_live" = "$1/$2" ] || { [ -z "$_rs_live" ] && [ "$(active_transport)" = "$1" ] && [ "$(head -n1 "$ENODIA_STATE/.$1-active" 2>/dev/null)" = "$2" ]; }; then
            sh "$ENODIA_DIR/transport.sh" restart >/dev/null 2>&1
        fi
        for _rsr in $(slots_enabled | awk -F"$TAB" -v k="$1/$2" '$2 "/" $3 == k {print $1}'); do
            sh "$ENODIA_DIR/transport.sh" slot-down "$_rsr" >/dev/null 2>&1
            sh "$ENODIA_DIR/transport.sh" slot-up "$_rsr" >/dev/null 2>&1
        done
    fi
    if [ -n "$3" ]; then echo "[road] дорога к серверу — через выход №$3"; else echo "[road] дорога снята — сервер идёт напрямую"; fi
    return 0
}

cmd_mv() {   # $1 = kind, $2 = old, $3 = new
    lbl_cfg_key "$1/$2" && lbl_cfg_key "$1/$3" || return 0
    lbl_lock_take "$LOCK" 'road\.sh' || { echo "[road] дороги сейчас правит другая операция — повторите"; return 1; }
    _rmvv=$(via_of "$1/$2")
    _rmvr=0
    if [ -n "$_rmvv" ]; then
        lbl_commit_out "$STORE" awk -F "$TAB" -v old="$1/$2" -v new="$1/$3" -v id="$_rmvv" '$1!=old && $1!=new; END {print new "\t" id}' "$STORE"
        _rmvr=$?
    fi
    lbl_lock_drop "$LOCK"
    [ "$_rmvr" = 0 ] || { echo "[road] не удалось перенести дорогу"; return 1; }
    [ -z "$_rmvv" ] || cmd_wire >/dev/null
    return 0
}

restore_slot() { ENODIA_STATE="$1" sh "$ENODIA_DIR/slots.sh" show "$2" 2>/dev/null | cut -f3,4; }
cmd_restore_scan() {   # compare against the local config before CGI copies the archive
    _rrs_root=$ENODIA_STATE
    [ ! -f "$1/.slots" ] || _rrs_root=$1
    for _rrs_id in 2 3 4 5 6 7; do
        _rrs_old=$(restore_slot "$ENODIA_STATE" "$_rrs_id")
        _rrs_new=$(restore_slot "$_rrs_root" "$_rrs_id")
        case "$_rrs_old:$_rrs_new" in awg"$TAB"*|*:awg"$TAB"*) ;; *) continue ;; esac
        if [ "${_rrs_old%%"$TAB"*}" = awg ] && [ "${_rrs_new%%"$TAB"*}" = awg ]; then
            _rrs_cfg=${_rrs_new#*"$TAB"}
            _rrs_prev=${_rrs_old#*"$TAB"}
            lbl_cfg_key "awg/$_rrs_cfg" && lbl_cfg_key "awg/$_rrs_prev" || continue
            _rrs_src="$1/configs/$_rrs_cfg.conf"
            [ -f "$_rrs_src" ] || _rrs_src=$(cfg_path awg "$_rrs_cfg")
            _rrs_dst=$(cfg_path awg "$_rrs_prev")
            if [ "$_rrs_src" = "$_rrs_dst" ] || cmp -s "$_rrs_src" "$_rrs_dst"; then continue; fi
        fi
        printf '%s\n' "$_rrs_id"
    done
}

# Stage the road map before publishing the registry. A rejected registry leaves roads and peer files alone.
cmd_import() (
    _rik=$(for _rif in "$1"/configs/*.conf "$1"/xray-configs/*.json "$1"/hy2-configs/*.yaml; do
        [ -f "$_rif" ] || continue
        _rib=${_rif##*/}
        case "$_rib" in *.conf) echo "awg/${_rib%.conf}" ;; *.json) echo "xray/${_rib%.json}" ;; *.yaml) echo "hy2/${_rib%.yaml}" ;; esac
    done)
    lbl_lock_take "$LOCK" 'road\.sh' || exit 1
    _ri_stage="$STORE.$$.new"
    trap 'rm -f "$_ri_stage"; lbl_lock_drop "$LOCK"' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    _ri_before=""
    [ ! -e "$ENODIA_STATE/.slots" ] || _ri_before=$(cat "$ENODIA_STATE/.slots") || exit 1
    _ri_ids=$(cmd_restore_scan "$1" | tr '\n' ' ')
    _ri_local=$(cmd_list)
    _ri_archive=$(lbl_list "$1/.cfg-via" "$KEY_RE")
    _ri_rows=$(printf 'archive\n%s\nlocal\n%s\n' "$_ri_archive" "$_ri_local" |
        awk -F "$TAB" -v OFS="$TAB" -v ids=" $_ri_ids " -v brought="\n$_rik\n" '
        NF==1 { src=$1; next }
        $2 ~ /^[2-7]$/ {
            if (index(ids, " " $2 " ")) { if (!drop[$1,$2]++) print "drop", $1, $2 }
            else if ((src=="local" || index(brought, "\n" $1 "\n")) && !seen[$1]++) print "keep", $1, $2
        }')
    _ri_next=$(printf '%s\n' "$_ri_rows" | awk -F "$TAB" '$1=="keep"' | cut -f2-)
    [ "$_ri_next" = "$_ri_local" ] || lbl_commit "$_ri_stage" "$_ri_next" || exit 1
    [ ! -f "$1/.slots" ] || sh "$ENODIA_DIR/slots.sh" restore-registry "$1/.slots" "$_ri_before" || exit 1
    if [ "$_ri_next" != "$_ri_local" ]; then
        if [ -n "$_ri_next" ]; then mv -f "$_ri_stage" "$STORE" || exit 1; else rm -f "$STORE" || exit 1; fi
    fi
    trap - EXIT HUP INT TERM PIPE
    lbl_lock_drop "$LOCK"
    cmd_wire >/dev/null || true
    printf '%s\n' "$_ri_rows" | awk -F "$TAB" '$1=="drop"' | cut -f2-
)
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
    get)     lbl_cfg_key "$2/$3" && via_of "$2/$3"; exit 0 ;;
    eligible) lbl_cfg_key "$2/$3" && cmd_eligible "$2" "$3"; exit $? ;;
    set)     cmd_set "$2" "$3" "$4" ;;
    del)     lbl_cfg_key "$2/$3" || exit 0; [ -z "$(via_of "$2/$3")" ] || put "$2/$3" "" || exit 1; cmd_wire >/dev/null ;;
    mv)      cmd_mv "$2" "$3" "$4" ;;
    riders)  case "$2" in [2-7]) cmd_riders "$2" ;; esac; exit 0 ;;
    serves)  [ "$2" = awg ] && lbl_cfg_key "$2/$3" && cmd_serves "$3"; exit 0 ;;
    clash)   case "$2" in [2-7]) lbl_cfg_key "awg/$3" && cmd_clash "$2" "$3" ;; esac; exit 0 ;;
    list)    cmd_list; exit 0 ;;
    json)    cmd_list | awk -F"$TAB" '{ printf "%s\"%s\":\"%s\"", (c++ ? "," : ""), $1, $2 }'; exit 0 ;;
    wire)    cmd_wire ;;
    unwire)  cmd_unwire ;;
    want)    road_view want; exit 0 ;;
    installed) have_rules; exit 0 ;;
    paths)   cmd_paths ;;
    probe-paths) lbl_cfg_key "$2" && [ "$#" -ge 4 ] && { shift; cmd_probe_paths "$@"; } ;;
    probe-wire) lbl_cfg_key "$2" && [ "$#" -ge 3 ] && { shift; cmd_probe_wire "$@"; } ;;
    main-path) cmd_main_path "$2" "$3" ;;
    mtu-cap) cmd_mtu_cap "$2" "$3"; exit 0 ;;
    hy2-mtu-ok) case "$2" in [2-7]) hy2_mtu_ok "$2" ;; *) exit 1 ;; esac ;;
    hy2-warp-timeout) case "$2" in [2-7]) hy2_warp_notice "$2" timeout ;; *) exit 1 ;; esac ;;
    mtu-fix) cmd_mtu_fix ;;
    carrier) cmd_carrier "$2"; exit 0 ;;
    carriers) case "$2" in watchdog) road_view watchdog ;; *) road_view carriers ;; esac; exit 0 ;;
    import)  cmd_import "$2" ;;
    merge)   cmd_merge "$2" ;;
    *) echo "usage: $0 get <вид> <файл> | set <вид> <файл> <id|\"\"> | del <вид> <файл> | mv <вид> <старый> <новый> | riders <id> | list | json | wire | unwire | want | mtu-cap <вид> <файл> | mtu-fix | carrier <main|id> | import <корень архива> | merge <файл>"; exit 2 ;;
esac
