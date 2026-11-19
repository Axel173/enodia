#!/bin/sh
# Private descriptor reader and isolated client primitives. Never source a record.
# The caller owns a protected RAM directory and the switching lock at snapshot.

dp_hash() { doh_probe_hash "$1"; }
dp_hex() { [ "${#1}" = 64 ] && case "$1" in *[!a-f0-9]*) return 1 ;; esac; }
dp_uint() { case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac; [ "${#1}" -le 10 ]; }
dp_id() { [ "${#1}" = 16 ] && case "$1" in *[!a-f0-9]*) return 1 ;; esac; }

# Bound the input before awk or shell read; enforce exact field order, one final
# newline and a closed schema. Reject NUL/control bytes, duplicates and truncation.
dp_read() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	# Read the path once. A changed file must never supply the digest for
	# launch fields read from an earlier inode. The sentinel checks the final
	# newline, and converting NUL makes it visible to stock awk.
	_dp_record=$(
		{ head -c 8193 "$1" && printf '%s\n' end-of-descriptor; } |
			tr '\000' '\001' | LC_ALL=C awk '
			 BEGIN { fields="schema key proto url path ips sni port l4 bootstrap binary installed binary_sha256 ca ca_present ca_sha256" }
			 NR==1 {
			   n=split(fields " sig",names," ")
			 }
			 NR==n+1 && $0=="end-of-descriptor" { complete=1; next }
			 {
			   bytes+=length($0)+1
			   if (NR>n || bytes>8192 || length($0)>2200 || $0 ~ /[[:cntrl:]]/) exit 1
			   p=index($0,"="); if (!p || substr($0,1,p-1)!=names[NR]) exit 1
			   print
			 }
			 END { if (!complete || NR!=n+1) exit 1 }'
	) || return 1
	while IFS= read -r _dp_line; do
		_dp_v=${_dp_line#*=}
		case "${_dp_line%%=*}" in
			schema) DP_SCHEMA=$_dp_v ;; key) DP_KEY=$_dp_v ;; proto) DP_PROTO=$_dp_v ;;
			url) DP_URL=$_dp_v ;; path) DP_PATH=$_dp_v ;; ips) DP_IPS=$_dp_v ;; sni) DP_SNI=$_dp_v ;;
			port) DP_PORT=$_dp_v ;; l4) DP_L4=$_dp_v ;; bootstrap) DP_BOOTSTRAP=$_dp_v ;;
			binary) DP_BINARY=$_dp_v ;; installed) DP_INSTALLED=$_dp_v ;; binary_sha256) DP_BINARY_SHA=$_dp_v ;;
			ca) DP_CA=$_dp_v ;; ca_present) DP_CA_PRESENT=$_dp_v ;; ca_sha256) DP_CA_SHA=$_dp_v ;; sig) DP_SIG=$_dp_v ;;
		esac
	done <<EOF
$_dp_record
EOF
	[ "$DP_SCHEMA" = 1 ] || return 1
	case "$DP_KEY" in custom|saved|odoh) return 1 ;; esac
	dp_hex "$DP_SIG" || return 1
	[ "$(printf '%s' "${_dp_record%"sig=$DP_SIG"}" | doh_probe_hash)" = "$DP_SIG" ] || return 1
	case "$DP_KEY" in ''|*[!a-z0-9_-]*) return 1 ;; esac
	[ "${#DP_KEY}" -le 32 ] && [ "${#DP_URL}" -le 2048 ] && [ "${#DP_PATH}" -le 2048 ] && [ "${#DP_SNI}" -le 253 ] || return 1
	case "$DP_URL" in https://?*) ;; *) return 1 ;; esac
	case "$DP_PROTO:$DP_L4" in doh:tcp|dot:tcp|doq:udp|doh3:udp) ;; *) return 1 ;; esac
	case "$DP_PROTO" in dot|doq|doh3) case "$DP_SNI" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac ;; esac
	case "$DP_PROTO" in doh3) case "$DP_PATH" in /*) ;; *) return 1 ;; esac ;; esac
	dp_uint "$DP_PORT" && [ "$DP_PORT" -ge 1 ] && [ "$DP_PORT" -le 65535 ] || return 1
	[ "$(doh_probe_ipv4s "$DP_IPS")" = "$DP_IPS" ] && [ -n "$DP_IPS" ] || return 1
	case "$DP_INSTALLED:$DP_CA_PRESENT" in [01]:[01]) ;; *) return 1 ;; esac
	# A record cannot turn an endpoint field into an executable path.
	[ "$DP_BINARY" = "$(doh_bin_for "$DP_PROTO")" ] || return 1
	case "$DP_CA" in ''|/*) ;; *) return 1 ;; esac
	[ "${#DP_BINARY}" -le 1024 ] && [ "${#DP_CA}" -le 1024 ] || return 1
	if [ "$DP_INSTALLED" = 1 ]; then dp_hex "$DP_BINARY_SHA" || return 1; else [ -z "$DP_BINARY_SHA" ] || return 1; fi
	if [ "$DP_CA_PRESENT" = 1 ]; then dp_hex "$DP_CA_SHA" && [ -n "$DP_CA" ] || return 1; else [ -z "$DP_CA_SHA" ] || return 1; fi
	return 0
}

# Copies have a different process name: production doh_reap_stray must not kill
# them by pidof. Protected immutable objects are shared by hash, never by symlink.
dp_object() {
	[ -f "$1" ] && [ -r "$1" ] && dp_hex "$2" || return 1
	_dp_obj="$DS_ROOT/objects/$2-$3"
	if [ ! -e "$_dp_obj" ]; then
		_dp_sz=$(stat -c%s "$1" 2>/dev/null)
		dp_uint "$_dp_sz" && [ "$_dp_sz" -le 12582912 ] || return 1
		[ $(( $(du -sk "$DS_ROOT" | awk '{print $1}') * 1024 + _dp_sz )) -le 33554432 ] || return 1
		cp "$1" "$_dp_obj.new" && [ "$(dp_hash "$_dp_obj.new")" = "$2" ] || return 1
		chmod "$4" "$_dp_obj.new" && mv "$_dp_obj.new" "$_dp_obj" || return 1
	fi
	[ ! -L "$_dp_obj" ] && [ "$(dp_hash "$_dp_obj")" = "$2" ] || return 1
	printf '%s\n' "$_dp_obj"
}

# The launcher's help is read under a whole-tree deadline by the job owner.
# No client may be run with endpoints before these actual installed gates pass.
dp_capable() {
	case "$DP_PROTO" in
		doh)
			grep -q -- '-R resolver_ip' "$1" && grep -q -- '-C ca_path' "$1" || return 1
			;;
		dot) grep -q '^dot-proxy 1\.' "$1" ;;
		doq|doh3) grep -q 'quic-dns-proxy' "$1" ;;
		*) return 1 ;;
	esac
}

# Version output has its own grammar. Help contains the private executable path
# and must never become public metadata merely because its characters look safe.
dp_version() (
	LC_ALL=C; export LC_ALL
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	_dpv_size=$(stat -c%s "$1" 2>/dev/null)
	dp_uint "$_dpv_size" && [ "$_dpv_size" -le 8192 ] || return 1
	[ "$(tr -d '\000' < "$1" | wc -c | tr -d ' ')" = "$_dpv_size" ] || return 1
	IFS= read -r _dpv_line < "$1" || return 1
	case "$DP_PROTO" in
		doh) _dpv_version=$_dpv_line ;;
		dot) case "$_dpv_line" in 'dot-proxy '*) _dpv_version=${_dpv_line#'dot-proxy '} ;; *) return 1 ;; esac ;;
		doq|doh3) case "$_dpv_line" in 'quic-dns-proxy '*) _dpv_version=${_dpv_line#'quic-dns-proxy '} ;; *) return 1 ;; esac ;;
		*) return 1 ;;
	esac
	case "$_dpv_version" in ''|*[!A-Za-z0-9._+-]*) return 1 ;; esac
	[ "${#_dpv_version}" -le 64 ] || return 1
	printf '%s' "$_dpv_version"
)

# The client log is private and bounded. Match the clients' validation codes,
# not a resolver URL containing words such as "certificate-error".
dp_certificate_error() {
	LC_ALL=C grep -qE '^\[W\] [0-9.]+ [^ ]+ [^ ]+: curl request failed with 60: |^\[[EI]\] [0-9.]+ handshake .+: -0x2700 X509 - Certificate verification failed|^\[[EI]\] [0-9.]+ handshake .+: TLS alert (42|43|44|45|46|48) \(' "$1"
}

# dnsq drops the identity and execs, with no resident supervisor. All endpoints
# stay literal catalogue addresses; production proxy binaries are unchanged.
dp_exec() {
	_dp_csv=$(printf '%s' "$DP_IPS" | tr ' ' ',')
	set -- -a 127.0.0.1 -p "$DS_LISTEN" -C "$DS_CA"
	case "$DP_PROTO" in
		doh) set -- "$@" -v -4 -r "$DP_URL" -R "${DP_IPS%% *}" -b 127.0.0.1 ;;
		dot) set -- "$@" -r "$_dp_csv" -s "$DP_SNI" -P "$DP_PORT" -T 10000 ;;
		doq|doh3)
			_dp_mode=doq; [ "$DP_PROTO" != doh3 ] || _dp_mode=h3
			set -- "$@" -m "$_dp_mode" -r "$_dp_csv" -s "$DP_SNI" -P "$DP_PORT" -T 10000
			[ "$DP_PROTO" != doh3 ] || set -- "$@" -u "$DP_PATH" ;;
		*) return 1 ;;
	esac
	exec "$DS_DNSQ" --isolated-client "$DS_CLIENT" "$@"
}

dp_iface() { case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac; [ "${#1}" -le 15 ]; }
dp_ipt() {
	case "$1" in add) _dp_flag=-I ;; check) _dp_flag=-C ;; del) _dp_flag=-D ;; *) return 1 ;; esac
	shift; _dp_hook=$1; shift
	if [ "$_dp_flag" = -I ]; then iptables -t mangle "$_dp_flag" "$_dp_hook" 1 "$@" >/dev/null 2>&1
	else iptables -t mangle "$_dp_flag" "$_dp_hook" "$@" >/dev/null 2>&1; fi
}
# The final hook binds the selected egress, not just the pre-mark route. Other
# traffic, including the live DNS proxies, never matches this unused UID.
dp_fence() {
	_dp_action=$1; _dp_failed=0
	for _dp_hook in OUTPUT POSTROUTING; do
		for _dp_kind in drop loopback; do
			set -- -m owner --uid-owner "$DS_UID" -m comment --comment "enodia-dns-scan:$DS_ID:fence"
			if [ "$_dp_kind" = loopback ]; then set -- "$@" -s 127.0.0.1 -d 127.0.0.1 -p udp --sport "$DS_LISTEN" -j RETURN
			else set -- "$@" -j DROP; fi
			dp_ipt "$_dp_action" "$_dp_hook" "$@" || _dp_failed=1
		done
	done
	[ "$_dp_action" = del ] || [ "$_dp_failed" = 0 ]
}
dp_rule() {
	_dp_action=$1; _dp_hook=$2; _dp_target=$3; _dp_ip=$4; _dp_l4=$5; _dp_port=$6; _dp_mark=$7; _dp_iface=$8; _dp_mss=$9
	set -- -d "$_dp_ip" -p "$_dp_l4" --dport "$_dp_port" -m owner --uid-owner "$DS_UID" -m comment --comment "enodia-dns-scan:$DS_ID"
	[ "$_dp_hook" != POSTROUTING ] || set -- "$@" -o "$_dp_iface"
	case "$_dp_target" in
		MARK) set -- "$@" -j MARK --set-xmark "$_dp_mark/0xff" ;;
		RETURN) set -- "$@" -j RETURN ;;
		TCPMSS) set -- "$@" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$_dp_mss" ;;
		*) return 1 ;;
	esac
	dp_ipt "$_dp_action" "$_dp_hook" "$@"
}
dp_rules() {
	[ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c%s "$1")" -le 2048 ] || return 1
	_dp_recipe=$1; _dp_action=$2; _dp_failed=0
	while IFS='|' read -r _dp_ip _dp_l4 _dp_port _dp_mark _dp_iface _dp_mss _dp_extra; do
		[ -z "$_dp_extra" ] && [ "$(doh_probe_ipv4s "$_dp_ip")" = "$_dp_ip" ] && dp_iface "$_dp_iface" || return 1
		case "$_dp_l4:$_dp_mark" in tcp:0x0|udp:0x0|tcp:0x1|udp:0x1) ;; *) return 1 ;; esac
		dp_uint "$_dp_port" && [ "$_dp_port" -gt 0 ] && [ "$_dp_port" -le 65535 ] || return 1
		dp_uint "$_dp_mss" && { [ "$_dp_mss" = 0 ] || { [ "$_dp_l4" = tcp ] && [ "$_dp_mss" -ge 536 ] && [ "$_dp_mss" -le 65495 ]; }; } || return 1
		for _dp_pair in POSTROUTING:RETURN OUTPUT:RETURN OUTPUT:MARK OUTPUT:TCPMSS; do
			[ "$_dp_pair:$_dp_mss" != OUTPUT:TCPMSS:0 ] || continue
			dp_rule "$_dp_action" "${_dp_pair%:*}" "${_dp_pair#*:}" "$_dp_ip" "$_dp_l4" "$_dp_port" "$_dp_mark" "$_dp_iface" "$_dp_mss" || _dp_failed=1
		done
	done < "$_dp_recipe"
	[ "$_dp_action" = del ] || [ "$_dp_failed" = 0 ]
}
