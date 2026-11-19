#!/bin/sh
# Bounded, opt-in resolver diagnostics. No production DNS/client/hosts setters.
# All records are private data; public progress never contains a URL/profile/log.
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
DS_ROOT=${ENODIA_DNS_SCAN_ROOT:-/tmp/enodia-dns-scan}
DS_SWITCH=${ENODIA_DNS_SCAN_SWITCH:-/tmp/enodia-switching.lock}
DS_UID=64553
export ENODIA_DIR ENODIA_BIN ENODIA_STATE
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
for _ds_lib in label-lib.sh doh-lib.sh dns-probe-lib.sh; do
	[ -f "$ENODIA_DIR/$_ds_lib" ] || { printf '{"engine":false,"ok":false,"reason":"scripts_missing"}\n'; exit 1; }
	. "$ENODIA_DIR/$_ds_lib"
done

ds_now() { uptime_s; }

ds_random() { tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-16; }

ds_fail() { printf '{"engine":true,"ok":false,"reason":"%s"}\n' "$1"; return 1; }

ds_safe_path() {
	case "$1" in /*) ;; *) return 1 ;; esac
	_ds_p=$1
	while [ -n "$_ds_p" ]; do
		[ ! -L "$_ds_p" ] || return 1
		[ "$_ds_p" != / ] || break
		_ds_p=${_ds_p%/*}; [ -n "$_ds_p" ] || _ds_p=/
	done
	[ "$(readlink -f "$1")" = "$1" ]
}

ds_directory() {
	if [ ! -e "$1" ]; then
		[ "${2:-}" != read ] || return 1
		mkdir -m 0711 "$1" 2>/dev/null || [ -d "$1" ] || return 1
	fi
	ds_safe_path "$1" && [ -d "$1" ] || return 1
	case "$(stat -c '%u:%a' "$1")" in
		0:711) return 0 ;;
		0:*) chmod 0711 "$1" ;;
		*) return 1 ;;
	esac
}

ds_root() {
	[ "$(id -u)" = 0 ] || return 1
	case "$DS_ROOT" in *'/../'*|*'/./'*|*/|*'|'*|*' '*|*'\'*) return 1 ;; esac
	ds_safe_path "${DS_ROOT%/*}" || return 1
	# Recover an interrupted initialization without changing a foreign path.
	ds_directory "$DS_ROOT" "${1:-}" || return 1
	for _ds_sub in jobs objects; do
		ds_directory "$DS_ROOT/$_ds_sub" "${1:-}" || return 1
	done
}

ds_ref() { # read a private pid|start record; no source/eval
	[ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c%s "$1")" -le 128 ] || return 1
	IFS='|' read -r DS_PID DS_START DS_UNTIL _ds_ref_extra < "$1"
	dp_uint "$DS_PID" && dp_uint "$DS_START" && [ -z "$_ds_ref_extra" ] && [ "$DS_PID" -gt 1 ] || return 1
	proc_ref_alive "$DS_PID" "$DS_START"
}

ds_stop_ref() { if ds_ref "$1"; then proc_ref_tree_kill "$DS_PID" "$DS_START"; fi; return 0; }

ds_limits() { ulimit -c 0; ulimit -f "${DS_FILE_BLOCKS:-16}"; ulimit -v 196608; ulimit -n 64; }

ds_run() {
	_ds_seconds=$1; _ds_output=$2; shift 2
	( ds_limits && "$@" ) > "$_ds_output" 2>&1 &
	_ds_child=$!; _ds_stamp=$(proc_start_id "$_ds_child")
	if [ -n "$_ds_stamp" ]; then
		printf '%s|%s|%s\n' "$_ds_child" "$_ds_stamp" "$(( $(ds_now) + _ds_seconds ))" > "$DS_JOB/child.ref.new"
		mv "$DS_JOB/child.ref.new" "$DS_JOB/child.ref" || return 1
	fi
	wait "$_ds_child"; _ds_rc=$?
	printf '0|0|0\n' > "$DS_JOB/child.ref.new"; mv "$DS_JOB/child.ref.new" "$DS_JOB/child.ref"
	return "$_ds_rc"
}

ds_uid_free() {
	if awk -F: -v u="$DS_UID" '$3==u {found=1} END {exit !found}' /etc/passwd; then return 1; fi
	for _ds_status in /proc/[0-9]*/status; do
		awk -v u="$DS_UID" '$1=="Uid:" && ($2==u || $3==u || $4==u || $5==u) {found=1} END {exit !found}' "$_ds_status" 2>/dev/null && return 1
	done
	return 0
}

ds_port_free() {
	_ds_hex=$(printf '%04X' "$DS_LISTEN")
	! awk -v p=":$_ds_hex" 'NR>1 && substr($2,length($2)-length(p)+1)==p {f=1} END {exit !f}' /proc/net/udp /proc/net/udp6
}

ds_listener_owned() {
	_ds_hex=$(printf '%04X' "$DS_LISTEN")
	awk -v p=":$_ds_hex" -v u="$DS_UID" '
	 NR>1 && substr($2,length($2)-length(p)+1)==p {n++; if ($2=="0100007F" p && $8==u) own++}
	 END {exit !(n==1 && own==1)}' /proc/net/udp /proc/net/udp6
}


ds_load() {
 dp_id "$1" || return 1
 DS_ID=$1; DS_JOB="$DS_ROOT/jobs/$DS_ID"
 ds_safe_path "$DS_JOB" && [ -d "$DS_JOB" ] && [ "$(stat -c '%u:%a' "$DS_JOB")" = 0:711 ] || return 1
 [ -f "$DS_JOB/meta" ] && [ ! -L "$DS_JOB/meta" ] && [ "$(stat -c%s "$DS_JOB/meta")" -le 512 ] || return 1
 IFS='|' read -r DS_PROTO DS_MODE DS_KEYS DS_BEGAN DS_AT DS_LISTEN DS_SPORTS _ds_extra < "$DS_JOB/meta"
 [ -z "$_ds_extra" ] && ds_shape "$DS_PROTO" "$DS_MODE" "$DS_KEYS" || return 1
 dp_uint "$DS_BEGAN" && dp_uint "$DS_AT" && dp_uint "$DS_LISTEN" || return 1
 [ "$DS_LISTEN" -ge 23000 ] && [ "$DS_LISTEN" -lt 24000 ] || return 1
 _ds_lo=${DS_SPORTS%:*}; _ds_hi=${DS_SPORTS#*:}
 dp_uint "$_ds_lo" && dp_uint "$_ds_hi" && [ "$_ds_lo" -ge 49152 ] && [ "$_ds_hi" -le 57343 ] && [ $((_ds_hi-_ds_lo)) = 31 ]
}
ds_shape() {
 case "$1" in doh|dot|doq|doh3) ;; *) return 1 ;; esac
 case "$2" in direct|carrier|both) ;; *) return 1 ;; esac
 case "$3" in ''|,*|*,|*,,*|*[!a-z0-9_,-]*) return 1 ;; esac
 [ "${#3}" -le 256 ] || return 1
 _ds_seen=,; _ds_n=0
 for _ds_key in $(printf '%s' "$3" | tr ',' ' '); do
  case "$_ds_key" in custom|saved|odoh) return 1 ;; esac
  case "$_ds_seen" in *",$_ds_key,"*) return 1 ;; esac
  case " $(doh_resolver_list) " in *" $_ds_key "*) ;; *) return 1 ;; esac
  _ds_seen="$_ds_seen$_ds_key,"; _ds_n=$((_ds_n+1))
 done
 [ "$_ds_n" -gt 0 ] && [ "$_ds_n" -le 16 ]
}
ds_paths() { if [ "$DS_MODE" = both ]; then printf 'direct carrier'; else printf '%s' "$DS_MODE"; fi; }
ds_generation() (
 _ds_inventory=$(
  for _ds_f in "$ENODIA_STATE"/.doh-* "$ENODIA_STATE/.transport" "$ENODIA_STATE/.vpn-off" \
    /tmp/dnsmasq.d/00-upstream.conf /etc/dnsmasq.d/00-upstream.conf; do
   [ -f "$_ds_f" ] || continue
   [ "$(stat -c%s "$_ds_f")" -le 1048576 ] || exit 1
   printf '%s ' "$_ds_f"; dp_hash "$_ds_f" || exit 1
  done
  ip rule show && ip route show table main && ip route show table 1000 || exit 1
  _ds_routes=$(iptables -t mangle -S) || exit 1
  [ "${#_ds_routes}" -le 32768 ] || exit 1
  printf '%s\n' "$_ds_routes" | grep -vF "enodia-dns-scan:$DS_ID" || :
 ) || exit 1
 [ "${#_ds_inventory}" -le 65536 ] || exit 1
 printf '%s\n' "$_ds_inventory" | doh_probe_hash
)
ds_same() {
 [ ! -f "$DS_JOB/cancel" ] && [ ! -f "$DS_JOB/closing" ] && [ ! -e "$DS_SWITCH" ] || return 1
 [ ! -f "$DS_JOB/fence" ] || dp_fence check || return 1
 [ "${DS_RULES_ON:-0}" != 1 ] || dp_rules "$DS_CELL.rules" check || return 1
 _ds_now_gen=$(ds_generation) || return 1
 [ "$_ds_now_gen" = "$(cat "$DS_JOB/generation")" ]
}
ds_cell_reset() {
 DS_RESULT=queued; DS_REASON=''; DS_COLD=null; DS_WARM=null; DS_ATTEMPTED=0; DS_ANSWERED=0; DS_CHECKED=0; DS_WALL=0
}
ds_cell_json() {
 printf '{"index":%s,"key":"%s","proto":"%s","path":"%s","status":"%s","reason":"%s","cold_ms":%s,"warm_median_ms":%s,"attempted":%s,"answered":%s,"checked_mono":%s,"measured_at":%s}\n' \
  "$DS_INDEX" "$DS_KEY" "$DS_PROTO" "$DS_PATH" "$DS_RESULT" "$DS_REASON" "$DS_COLD" "$DS_WARM" "$DS_ATTEMPTED" "$DS_ANSWERED" "$DS_CHECKED" "$DS_WALL"
}
ds_progress_json() {
 printf '{"schema":1,"id":"%s","state":"%s","reason":"%s","proto":"%s","path":"%s","started_at":%s,"cells":[' "$DS_ID" "$1" "$2" "$DS_PROTO" "$DS_MODE" "$DS_AT"
 _ds_sep=''
 for _ds_cell in "$DS_JOB"/cell-*.json; do
  [ -f "$_ds_cell" ] && [ ! -L "$_ds_cell" ] || continue
  [ "$(stat -c%s "$_ds_cell")" -le 1024 ] || return 1
  printf '%s' "$_ds_sep"; cat "$_ds_cell"; _ds_sep=,
 done
 printf ']}\n'
}
ds_publish() { lbl_commit_out "$DS_JOB/progress.json" ds_progress_json "$1" "$2"; }
ds_cleanup() {
 ds_stop_ref "$DS_JOB/client.ref"; ds_stop_ref "$DS_JOB/child.ref"
 for _ds_rules in "$DS_JOB"/cell-*.rules; do [ ! -f "$_ds_rules" ] || dp_rules "$_ds_rules" del; done
 [ ! -f "$DS_JOB/fence" ] || dp_fence del
 _ds_left=$(iptables -t mangle -S) || return 1
 ! printf '%s\n' "$_ds_left" | grep -qF "enodia-dns-scan:$DS_ID"
}
ds_release() {
 [ "$(cat "$DS_ROOT/active" 2>/dev/null)" != "$DS_ID" ] || mv "$DS_ROOT/active" "$DS_JOB/active.released"
}
ds_finish() (
 # Only one finisher may remove the active ID or publish a terminal result.
 exec 8>"$DS_JOB/finish.lock"; flock -x 8 || exit 1
 if [ -f "$DS_JOB/finished" ]; then
  ds_release; exit $?
 fi
 : > "$DS_JOB/closing"
 _ds_final=$1; _ds_why=$2
 if ds_ref "$DS_JOB/worker.ref" && [ "$DS_PID" != "$$" ]; then proc_ref_tree_kill "$DS_PID" "$DS_START"; fi
 ds_cleanup || { ds_publish cleanup_failed cleanup_failed; exit 1; }
 if [ -f "$DS_JOB/cancel" ]; then _ds_final=cancelled; _ds_why=cancelled; fi
 ds_publish "$_ds_final" "$_ds_why" || exit 1
 printf '%s\n' "$(ds_now)" > "$DS_JOB/finished"
 ds_release
)

# Admission holds this same lock from the first prepared metadata through spawn.
# A dead launcher releases it in the kernel, even before any guard exists.
ds_recover() (
 exec 7>"$DS_ROOT/admission.lock"; flock -x 7 || exit 1
 ds_recover_locked
)
ds_recover_locked() {
 if [ -f "$DS_ROOT/active" ] && [ ! -s "$DS_ROOT/active" ] && [ ! -L "$DS_ROOT/active" ]; then
  # A pre-atomic launcher could die between open and its first write. No worker
  # can pass the active-ID gate in this state; refuse retirement if rules remain.
  _ds_empty_rules=$(iptables -t mangle -S) || return 1
  ! printf '%s\n' "$_ds_empty_rules" | grep -qF 'enodia-dns-scan:' || return 1
  mv "$DS_ROOT/active" "$DS_ROOT/empty.released" || return 1
  _ds_hint=$(cat "$DS_ROOT/latest" 2>/dev/null)
  if ds_load "$_ds_hint" && [ ! -f "$DS_JOB/finished" ] &&
     ! ds_ref "$DS_JOB/worker.ref" && ! ds_ref "$DS_JOB/guard.ref" && ! ds_ref "$DS_JOB/launcher.ref"; then
   ds_finish crashed worker_lost
  fi
  return 0
 fi
 _ds_active=$(cat "$DS_ROOT/active" 2>/dev/null)
 [ -n "$_ds_active" ] || return 0
 dp_id "$_ds_active" || return 1
 if ! ds_load "$_ds_active"; then
  # Legacy interruption before metadata: no worker can have passed ds_load.
  _ds_orphans=$(iptables -t mangle -S) || return 1
  ! printf '%s\n' "$_ds_orphans" | grep -qF "enodia-dns-scan:$_ds_active" || return 1
  mv "$DS_ROOT/active" "$DS_ROOT/abandoned-$_ds_active"
  return $?
 fi
 if [ -f "$DS_JOB/finished" ] || [ -f "$DS_JOB/closing" ]; then ds_finish crashed worker_lost; return $?; fi
 ds_ref "$DS_JOB/worker.ref" && return 0
 ds_ref "$DS_JOB/guard.ref" && return 0
 ds_ref "$DS_JOB/launcher.ref" && return 0
 # Admission can die after active but before latest was published.
 lbl_commit "$DS_ROOT/latest" "$DS_ID" || return 1
 ds_finish crashed worker_lost
}
ds_route_plan() {
 DS_REASON=path_unavailable; DS_IFACE=''; _ds_mark=0x0; _ds_mss=0
 if [ "$DS_PATH" = direct ]; then DS_IFACE=$(wan_iface)
 else
  [ ! -f "$ENODIA_STATE/.vpn-off" ] || return 1
  DS_IFACE=$(carrier_iface); _ds_mark=0x1
 fi
 dp_iface "$DS_IFACE" || return 1
 # Unknown native desync rules cannot be bypassed by this small diagnostic.
 _ds_rules=$(iptables -t mangle -S) || return 1
 if printf '%s\n' "$_ds_rules" | grep -qiE 'z2[-_]|zapret2|CONNMARK.*(0xff000000|0x00ff0000)'; then DS_REASON=unsupported_path; return 1; fi
 if [ "$DS_PATH:$DP_L4" = carrier:tcp ]; then
  _ds_mtu=$(carrier_mtu); dp_uint "$_ds_mtu" && [ "$_ds_mtu" -ge 576 ] && [ "$_ds_mtu" -le 65535 ] || return 1
  _ds_mss=$((_ds_mtu-40))
 fi
 for _ds_ip in $DP_IPS; do
  _ds_route=$(ip route get "$_ds_ip" mark "$_ds_mark") || return 1 # not-wan: destination-specific marked lookup, not discovery of the WAN or carrier.
  _ds_dev=$(printf '%s\n' "$_ds_route" | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}') # not-wan: verify this marked destination against the interface supplied by ip-lib.
  [ "$_ds_dev" = "$DS_IFACE" ] || return 1
 done
 # Recipe precedes any rule: interruption removes only this diagnostic UID tuple.
 for _ds_ip in $DP_IPS; do printf '%s|%s|%s|%s|%s|%s\n' "$_ds_ip" "$DP_L4" "$DP_PORT" "$_ds_mark" "$DS_IFACE" "$_ds_mss"; done > "$DS_CELL.rules"
 dp_rules "$DS_CELL.rules" add || { DS_REASON=isolation_unavailable; return 1; }
 DS_RULES_ON=1
}
ds_query() {
 ds_same || return 10
 DS_ATTEMPTED=$((DS_ATTEMPTED+1)); _ds_qname=$(doh_probe_name)
 _ds_out="$DS_CELL.q$DS_ATTEMPTED"
 ds_run "$(( ($1+999)/1000+1 ))" "$_ds_out" "$DS_DNSQ" --json --timeout-ms "$1" --expect response 127.0.0.1 "$DS_LISTEN" "$_ds_qname"; _ds_qrc=$?
 ds_same || return 10
 _ds_ok=$(jsonfilter -i "$_ds_out" -e '@.ok' 2>/dev/null); DS_Q_MS=$(jsonfilter -i "$_ds_out" -e '@.elapsed_ms' 2>/dev/null)
 if [ "$_ds_qrc:$_ds_ok" = 0:true ] && dp_uint "$DS_Q_MS"; then DS_ANSWERED=$((DS_ANSWERED+1)); return 0; fi
 DS_REASON=$(jsonfilter -i "$_ds_out" -e '@.status' 2>/dev/null)
 case "$DS_REASON" in
  timeout) DS_REASON=timeout ;;
  servfail|dns_error) DS_REASON=dns_error ;;
  truncated|malformed|response_limit) DS_REASON=malformed ;;
  io_error) DS_REASON=transport ;;
  *) DS_REASON=unexpected_answer ;;
 esac
 return 1
}
ds_proxy() {
 ds_root read && ds_load "$1" || exit 1
 case "$2" in [0-9][0-9]) ;; *) exit 1 ;; esac
 DS_CELL="$DS_JOB/cell-$2"
 [ "$(cat "$DS_ROOT/active")" = "$DS_ID" ] && [ ! -f "$DS_JOB/closing" ] && [ ! -f "$DS_JOB/cancel" ] || exit 1
 dp_read "$DS_CELL.desc" || exit 1
 DS_CLIENT="$DS_ROOT/objects/$DP_BINARY_SHA-client"; DS_CA="$DS_ROOT/objects/$DP_CA_SHA-ca"
 [ -f "$DS_CLIENT" ] && [ ! -L "$DS_CLIENT" ] && [ "$(dp_hash "$DS_CLIENT")" = "$DP_BINARY_SHA" ] || exit 1
 [ -f "$DS_CA" ] && [ ! -L "$DS_CA" ] && [ "$(dp_hash "$DS_CA")" = "$DP_CA_SHA" ] || exit 1
 printf '%s|%s|%s\n' "$$" "$(proc_start_id "$$")" "$(( $(ds_now)+45 ))" > "$DS_JOB/client.ref.new"
 mv "$DS_JOB/client.ref.new" "$DS_JOB/client.ref" || exit 1
 # Publishing the reference before exec makes the guard responsible for the
 # exact process; a closing job can never start a delayed new proxy.
 [ ! -f "$DS_JOB/closing" ] && [ ! -f "$DS_JOB/cancel" ] || exit 1
 DS_DNSQ="$DS_ROOT/objects/$(dp_hash "$(bin_path dnsq)")-dnsq"
 [ -x "$DS_DNSQ" ] && [ ! -L "$DS_DNSQ" ] || exit 1
 dp_exec >> "$DS_CELL.log" 2>&1
}
ds_spawn() {
 # BusyBox double-forks here; a raw '&' would retain uhttpd's killed CGI group.
 [ -x /sbin/start-stop-daemon ] || return 1
 /sbin/start-stop-daemon -S -b -m -p "$DS_JOB/$1.pid" -x /bin/sh -- "$ENODIA_DIR/dns-scan.sh" "$@" 7>&- </dev/null >/dev/null 2>&1 || return 1
 # Do not return a dead launcher with neither child identity published yet.
 # Admission stays locked until the detached child acknowledges its start.
 _ds_spawn_wait=0
 while ! ds_ref "$DS_JOB/$1.ref"; do
  [ ! -f "$DS_JOB/finished" ] || return 0
  [ "$_ds_spawn_wait" -lt 5 ] || return 1
  sleep 1; _ds_spawn_wait=$((_ds_spawn_wait+1))
 done
}
ds_cell() {
 DS_RESULT=unavailable
 dp_read "$DS_CELL.desc" || { DS_REASON=descriptor_invalid; return; }
 [ "$DP_INSTALLED" = 1 ] || { DS_REASON=component_missing; return; }
 [ "$DP_CA_PRESENT" = 1 ] || { DS_REASON=ca_missing; return; }
 DS_CLIENT=$(dp_object "$DP_BINARY" "$DP_BINARY_SHA" client 555) && DS_CA=$(dp_object "$DP_CA" "$DP_CA_SHA" ca 444) || { DS_REASON=component_changed; return; }
 # Reserve bounded client output plus help (whose UPX loader needs file space).
 [ "$(du -sk "$DS_ROOT" | awk '{print $1}')" -le 26624 ] || { DS_REASON=ram_budget; return; }
 DS_FILE_BLOCKS=4096 ds_run 2 "$DS_CELL.help" "$DS_CLIENT" -h
 dp_capable "$DS_CELL.help" || { DS_REASON=component_update; return; }
 ds_port_free || { DS_REASON=port_busy; return; }
 ds_route_plan || return
 ds_same || { DS_RESULT=stale; DS_REASON=state_changed; return; }
 : > "$DS_CELL.log"
 lbl_commit_out "$DS_JOB/client.plan" printf '%s\n' "${DS_CELL##*/}.rules" || { DS_REASON=isolation_unavailable; return; }
 # Keep the proxy a direct child of this detached worker: dnsq binds its
 # lifetime to that parent, and refuses an orphaned/PID1 launch.
 /bin/sh "$ENODIA_DIR/dns-scan.sh" proxy "$DS_ID" "$(printf '%02d' "$DS_INDEX")" </dev/null >/dev/null 2>&1 &
 _ds_wait=0
 while [ "$_ds_wait" -lt 5 ]; do
  if ds_ref "$DS_JOB/client.ref"; then _ds_client=$DS_PID; ds_listener_owned && break; fi
  [ ! -f "$DS_JOB/cancel" ] || return
  sleep 1; _ds_wait=$((_ds_wait+1))
 done
 [ "$_ds_wait" -lt 5 ] || { DS_REASON=client_failed; return; }
 # The isolated launch must actually drop all UIDs; otherwise its rules would
 # not select this client. No query is sent before this check.
 grep -Eq "^Uid:[[:space:]]+$DS_UID[[:space:]]+$DS_UID[[:space:]]+$DS_UID[[:space:]]+$DS_UID$" "/proc/$_ds_client/status" || { DS_REASON=isolation_unavailable; return; }
 DS_RESULT=checking
 ds_query 10000; _ds_rc=$?; [ "$_ds_rc" != 10 ] || { DS_RESULT=stale; DS_REASON=state_changed; return; }
 [ "$_ds_rc" != 0 ] || DS_COLD=$DS_Q_MS
 _ds_warm=''; _ds_i=0
 while [ "$_ds_i" -lt 3 ]; do
  ds_query 4000; _ds_rc=$?; [ "$_ds_rc" != 10 ] || { DS_RESULT=stale; DS_REASON=state_changed; return; }
  [ "$_ds_rc" != 0 ] || _ds_warm="$_ds_warm $DS_Q_MS"
  _ds_i=$((_ds_i+1))
 done
 if [ "$(printf '%s\n' "$_ds_warm" | wc -w)" = 3 ]; then DS_WARM=$(printf '%s\n' "$_ds_warm" | tr ' ' '\n' | grep . | sort -n | sed -n '2p'); fi
 if [ "$DS_ANSWERED" = 4 ]; then DS_RESULT=answered; DS_REASON=''
 elif [ "$DS_ANSWERED" -gt 0 ]; then DS_RESULT=unstable
 else DS_RESULT=no_reply; fi
 if dp_certificate_error "$DS_CELL.log"; then DS_RESULT=certificate_error; DS_REASON=certificate_error; fi
}
ds_worker() {
 ds_root read && ds_load "$1" || exit 1
 printf '%s|%s|0\n' "$$" "$(proc_start_id "$$")" > "$DS_JOB/worker.ref"
 [ "$(cat "$DS_ROOT/active" 2>/dev/null)" = "$DS_ID" ] && [ ! -f "$DS_JOB/closing" ] || exit 1
 trap 'exit 1' HUP INT TERM PIPE
 DS_INDEX=0
 for DS_PATH in $(ds_paths); do for DS_KEY in $(printf '%s' "$DS_KEYS" | tr ',' ' '); do
  DS_INDEX=$((DS_INDEX+1)); DS_CELL="$DS_JOB/cell-$(printf '%02d' "$DS_INDEX")"; ds_cell_reset
  doh_probe_descriptor "$DS_KEY" "$DS_PROTO" > "$DS_CELL.desc" || { DS_RESULT=unavailable; DS_REASON=descriptor_invalid; }
  ds_cell_json > "$DS_CELL.json"
 done; done
 if [ -e "$DS_SWITCH" ] || ! ds_run 3 "$DS_JOB/generation" ds_generation; then ds_finish done router_busy; exit; fi
 ds_uid_free || { ds_finish done uid_in_use; exit; }
 DS_DNSQ_SOURCE=$(bin_path dnsq); [ -x "$DS_DNSQ_SOURCE" ] || { ds_finish done dnsq_update; exit; }
 DS_DNSQ=$(dp_object "$DS_DNSQ_SOURCE" "$(dp_hash "$DS_DNSQ_SOURCE")" dnsq 555) || { ds_finish done component_changed; exit; }
 ds_run 2 "$DS_JOB/dnsq.version" "$DS_DNSQ" --version
 case "$(cat "$DS_JOB/dnsq.version")" in 'dnsq 2.3') ;; *) ds_finish done dnsq_update; exit ;; esac
 ds_same || { ds_finish stale state_changed; exit; }
 : > "$DS_JOB/fence"; dp_fence add || { ds_finish done isolation_unavailable; exit; }
 DS_INDEX=0
 for DS_PATH in $(ds_paths); do for DS_KEY in $(printf '%s' "$DS_KEYS" | tr ',' ' '); do
  DS_INDEX=$((DS_INDEX+1)); DS_CELL="$DS_JOB/cell-$(printf '%02d' "$DS_INDEX")"; ds_cell_reset; DS_RULES_ON=0
  ds_same || { ds_finish stale state_changed; exit; }
  ds_publish running ''; ds_cell
  # Retire the plan before stopping its client/removing its rules. The guard
  # may already be halfway through checking this cell; it revalidates below.
  lbl_commit_out "$DS_JOB/client.plan" printf '%s\n' idle || { ds_finish crashed worker_lost; exit; }
  ds_stop_ref "$DS_JOB/client.ref"; [ ! -f "$DS_CELL.rules" ] || dp_rules "$DS_CELL.rules" del
  DS_RULES_ON=0
  DS_CHECKED=$(ds_now); DS_WALL=$(date +%s)
  lbl_commit_out "$DS_CELL.json" ds_cell_json; ds_publish running ''
  [ "$DS_RESULT" != stale ] || { ds_finish stale state_changed; exit; }
 done; done
 ds_finish done ''
}
ds_guard_current() {
 [ "$(cat "$DS_JOB/client.plan" 2>/dev/null)" = "$2" ] &&
 [ "$(cat "$DS_JOB/client.ref" 2>/dev/null)" = "$1" ] && ds_ref "$DS_JOB/client.ref"
}

ds_guard() {
 ds_root read && ds_load "$1" || exit 1
 printf '%s|%s|0\n' "$$" "$(proc_start_id "$$")" > "$DS_JOB/guard.ref"
 _ds_wait=0
 while [ ! -f "$DS_JOB/worker.ref" ] && [ "$_ds_wait" -lt 5 ]; do sleep 1; _ds_wait=$((_ds_wait+1)); done
 while [ "$(cat "$DS_ROOT/active" 2>/dev/null)" = "$DS_ID" ]; do
  if [ -f "$DS_JOB/cancel" ]; then ds_finish cancelled cancelled; exit; fi
  if [ $(( $(ds_now)-DS_BEGAN )) -ge 600 ]; then ds_finish deadline batch_deadline; exit; fi
  if ! ds_ref "$DS_JOB/worker.ref"; then ds_finish crashed worker_lost; exit; fi
  if ds_ref "$DS_JOB/client.ref"; then
   _ds_guard_ref="$DS_PID|$DS_START|$DS_UNTIL"
   _ds_plan=$(cat "$DS_JOB/client.plan" 2>/dev/null)
   case "$_ds_plan" in cell-[0-9][0-9].rules)
    if [ -e "$DS_SWITCH" ] || ! dp_fence check || ! dp_rules "$DS_JOB/$_ds_plan" check; then
     if ds_guard_current "$_ds_guard_ref" "$_ds_plan"; then ds_finish stale state_changed; exit; fi
    fi ;;
    idle) : ;; # Worker-owned retirement, before client teardown.
    *) if ds_guard_current "$_ds_guard_ref" "$_ds_plan"; then ds_finish stale state_changed; exit; fi ;;
   esac
  fi
  for _ds_ref in child client; do
   if ds_ref "$DS_JOB/$_ds_ref.ref" && dp_uint "$DS_UNTIL" && [ "$(ds_now)" -ge "$DS_UNTIL" ]; then proc_ref_tree_kill "$DS_PID" "$DS_START"; fi
  done
  sleep 1
 done
}
ds_start() (
 ds_shape "$1" "$2" "$3" || { ds_fail bad_selection; return; }
 [ -x /sbin/start-stop-daemon ] && command -v flock >/dev/null 2>&1 || { ds_fail isolation_unavailable; return; }
 ds_root || { ds_fail isolation_unavailable; return; }
 exec 7>"$DS_ROOT/admission.lock"; flock -x 7 || { ds_fail isolation_unavailable; return; }
 # Uninstall publishes its live PID before calling our finisher and keeps it
 # through its process/rule sweeps. Both sides synchronize on admission.
 if uninstall_alive; then ds_fail router_busy; return; fi
 ds_recover_locked || { ds_fail busy; return; }
 [ ! -f "$DS_ROOT/active" ] || { ds_fail busy; return; }
 for _ds_old in "$DS_ROOT"/jobs/*; do
  dp_id "${_ds_old##*/}" && [ -d "$_ds_old" ] && [ ! -L "$_ds_old" ] || continue
  rm -rf "$_ds_old" || { ds_fail ram_budget; return; }
 done
 # Snapshots serve only the admitted job. An upgrade can change every hash.
 for _ds_old in "$DS_ROOT"/objects/*; do
  [ -f "$_ds_old" ] && [ ! -L "$_ds_old" ] || continue
  _ds_name=${_ds_old##*/}
  case "$_ds_name" in *-client|*-ca|*-dnsq) dp_hex "${_ds_name%-*}" || continue ;; *) continue ;; esac
  rm -f "$_ds_old" || { ds_fail ram_budget; return; }
 done
 [ "$(du -sk "$DS_ROOT" | awk '{print $1}')" -lt 32768 ] || { ds_fail ram_budget; return; }
 DS_ID=$(ds_random); dp_id "$DS_ID" || { ds_fail isolation_unavailable; return; }
 DS_JOB="$DS_ROOT/jobs/$DS_ID"; (umask 077; mkdir "$DS_JOB") && chmod 711 "$DS_JOB" || { ds_start_abort; return; }
 DS_PROTO=$1; DS_MODE=$2; DS_KEYS=$3; DS_BEGAN=$(ds_now); DS_AT=$(date +%s)
 _ds_seed=$(printf '%d' "0x$(printf '%s' "$DS_ID" | cut -c1-4)")
 DS_LISTEN=$((23000+_ds_seed%1000)); _ds_lo=$((49152+(_ds_seed%256)*32)); DS_SPORTS="$_ds_lo:$((_ds_lo+31))"
 printf '%s|%s|%s|%s|%s|%s|%s\n' "$DS_PROTO" "$DS_MODE" "$DS_KEYS" "$DS_BEGAN" "$DS_AT" "$DS_LISTEN" "$DS_SPORTS" > "$DS_JOB/meta" || { ds_start_abort; return; }
 ds_publish preparing '' || { ds_start_abort; return; }
 printf '%s|%s|0\n' "$$" "$(proc_start_id "$$")" > "$DS_JOB/launcher.ref" || { ds_start_abort; return; }
 # Admission is serialized above; atomic publication leaves no empty lease if killed.
 lbl_commit "$DS_ROOT/active" "$DS_ID" || { ds_start_abort; return; }
 lbl_commit "$DS_ROOT/latest" "$DS_ID" || { ds_start_abort; return; }
 ds_spawn guard "$DS_ID" && ds_spawn worker "$DS_ID" || { ds_finish crashed launch_failed; ds_fail launch_failed; return; }
 printf '{"engine":true,"ok":true,"id":"%s"}\n' "$DS_ID"
)
ds_start_abort() {
 [ "$(cat "$DS_ROOT/active" 2>/dev/null)" != "$DS_ID" ] || rm -f "$DS_ROOT/active"
 ds_fail ram_budget
}
ds_cancel() {
 ds_root read && ds_load "$1" || { ds_fail unknown_job; return; }
 : > "$DS_JOB/cancel"
 # Also release a terminal result whose publisher died before releasing the lease.
 if [ "$(cat "$DS_ROOT/active" 2>/dev/null)" = "$DS_ID" ] && ! ds_ref "$DS_JOB/guard.ref"; then
  ds_finish cancelled cancelled || :
 fi
 printf '{"ok":true,"id":"%s"}\n' "$DS_ID"
}
ds_status() {
 if [ ! -d "$DS_ROOT" ]; then printf '{"engine":true,"state":"idle","cells":[]}\n'; return; fi
 ds_root || { ds_fail isolation_unavailable; return; }
 ds_recover || :
 _ds_id=${1:-$(cat "$DS_ROOT/latest" 2>/dev/null)}
 [ -n "$_ds_id" ] || { printf '{"engine":true,"state":"idle","cells":[]}\n'; return; }
 if ! ds_load "$_ds_id"; then
  if [ -z "${1:-}" ] && [ ! -f "$DS_ROOT/active" ]; then printf '{"engine":true,"state":"idle","cells":[]}\n'; return; fi
  ds_fail unknown_job; return
 fi
 [ -f "$DS_JOB/progress.json" ] && [ ! -L "$DS_JOB/progress.json" ] && [ "$(stat -c%s "$DS_JOB/progress.json")" -le 65536 ] || { ds_fail invalid_progress; return; }
 _ds_dns=$(dns_now)
 _ds_src=$(printf '%s\n' "$_ds_dns" | sed -n 's/^src=//p')
 _ds_via=$(printf '%s\n' "$_ds_dns" | sed -n 's/^via=//p')
 _ds_key=''; _ds_proto=''
 if [ "$_ds_src" = doh ]; then
  if doh_running; then
   _ds_proto=$(doh_proto_now)
   _ds_key=$(doh_live_catalog_key "$_ds_proto")
  else
   _ds_src=unavailable
  fi
 fi
 printf '{"now_mono":%s,"effective":{"src":"%s","via":"%s","key":"%s","proto":"%s"},"progress":' "$(ds_now)" "$_ds_src" "$_ds_via" "$_ds_key" "$_ds_proto"
 cat "$DS_JOB/progress.json"; printf '}\n'
}
# Teardown uses the finisher under admission; verify rules and lease afterwards.
ds_verify() {
    [ ! -e "$DS_ROOT/active" ] || return 1
    _ds_verify=$(iptables -t mangle -S) || return 1
    ! printf '%s\n' "$_ds_verify" | grep -qF 'enodia-dns-scan:'
}
ds_teardown() (
    if [ -d "$DS_ROOT" ]; then
        ds_root || exit 1
        exec 7>"$DS_ROOT/admission.lock"; flock -x 7 || exit 1
        ds_recover_locked || exit 1
        _ds_teardown_id=$(cat "$DS_ROOT/active" 2>/dev/null)
        if [ -n "$_ds_teardown_id" ]; then
            ds_load "$_ds_teardown_id" || exit 1
            : > "$DS_JOB/cancel"
            ds_finish cancelled cancelled || exit 1
        fi
    fi
    ds_verify
)
umask 077
case "$1:$#" in
 teardown:1) ds_teardown ;;
 verify:1) ds_verify ;;
 start:4) ds_start "$2" "$3" "$4" ;;
 status:1|status:2) ds_status "${2:-}" ;;
 cancel:2) ds_cancel "$2" ;;
 worker:2) ds_worker "$2" ;;
 guard:2) ds_guard "$2" ;;
 proxy:3) ds_proxy "$2" "$3" ;;
 *) ds_fail bad_selection; exit 2 ;;
esac
