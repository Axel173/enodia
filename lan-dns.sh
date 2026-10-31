#!/bin/sh
# lan-dns.sh — WHO IN THE HOUSE ASKS DNS PAST THE ROUTER, and whether the router itself sends them there.
#
# WHY (Dom.ru tester, 30.10.2026). Everything DNS-shaped in Enodia lives in the router's dnsmasq: encrypted DNS, the domain
# rules (dnsmasq fills their sets), adblock, own names, the Russian split. A device that asks someone else skips all of it, and
# on an ISP that answers plain udp/53 itself (Dom.ru: a stub for every blocked name, whatever address the query went to) such a
# device gets the stub — neither the VPN's domain rules nor Zapret can help with an address that is not the site's. The
# tester's screen said «encryption on» while every device in the house asked 1.1.1.1 directly: the stock fields «Настройки
# локальной сети → DHCP-сервер → DNS1/DNS2» (dhcp.lan.dns1/dns2) made the router hand out 1.1.1.1/1.0.0.1 instead of itself.
# Nothing in the panel showed it; it took a support session.
#
# TWO FACTS, both read from what is LIVE, never from what should be:
#  · dhcp — a network whose DHCP hands out a DNS other than the router: the `dhcp-option[-force]` lines (option 6 /
#    option:dns-server / option6:dns-server) of every file the running dnsmasq reads (dns-lib.sh::dnsmasq_conf_files), minus
#    the router's own addresses and dnsmasq's «myself» (0.0.0.0, ::). `own` says one of those stood in the line too: devices
#    get the router first and the foreign one beside it. WHERE the line comes from is told so the panel can point at the
#    field: the stock fields `dhcp.<net>.dns1/dns2` (`stock`), an own `dhcp_option[_force]` (`uci`), else the file.
#  · dev — devices asking DNS past the router right now: conntrack entries to port 53 (plain) or 853 (DoT) whose REPLY source
#    is not the router (a query that asked the router, or that our DNAT/REDIRECT caught — guests, access schedules — is
#    answered by the router) and whose source is a client of ours (lease-lib.sh::ip_is_local; a container on br-docker
#    counts: it is ours, asking past us). `dhcp` says the resolver is one the DHCP of the device's OWN network hands out (its
#    network = the `dhcp-range` its address falls in; IPv6 has none — only untagged lines count): the panel's own address
#    matching read a lease still held after the fix as «own DNS», never matched IPv6 and mixed the guest network's option
#    into the main one (review s.175). DoH rides 443 and cannot be told from any HTTPS — not seen, the panel says so.
#    conntrack keeps a DNS exchange ~30 s: a snapshot of «now».
# «The router itself» = `ip route get` prints `local` (measured BE7000 30.10.2026 for its v4, ULA and link-local addresses) —
# the rule of ip-lib.sh::ip_is_self; the shim below is that same line for a payload without it.
# COST: section doh asks this on every open of the DNS screen (and every 2 s while a component installs). The reply source is
# asked FIRST — it is the router for nearly every line and cached — so only the rare lines past the router cost `ip` calls;
# conntrack and the config files are cut by grep before any awk (an adblock snippet is hundreds of thousands of lines).
# BUSYBOX AWK: `name (…)` is a CALL there (C118) — every concatenation below goes through `if`, never a name before `(`.
#
# Verbs:
#   lan-dns.sh scan — `key=value` lines (format like doh-lib.sh::dns_now; the reader formats, no verdicts here):
#     ct=1|0                                conntrack readable (0 ⇒ the dev part could not be asked)
#     dhcp=<net>⇥<addr …>⇥<src>⇥<own 0|1>   net = the dnsmasq tag (uci section) or `*`; src = stock | uci | file:<path>
#     dev=<ip>⇥<resolver>⇥<port>⇥<n>⇥<dhcp 0|1>  port 53 | 853; n = conntrack entries (≈ queries of the last half minute)
#   lan-dns.sh json [secs] — the same as ONE JSON object for cgi-bin/data (`lan_dns`), or `null` when the scan said nothing;
#   with `secs` the scan is capped (ld_cap): past it, nothing is printed and the caller says `null`.
#   Every value is cut to its own alphabet here (addresses, tags, paths): it goes into JSON as it is.
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
TAB=$(printf '\t')

if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
if [ -f "$ENODIA_DIR/lease-lib.sh" ]; then . "$ENODIA_DIR/lease-lib.sh"; fi
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v dns_bulk_snippet >/dev/null 2>&1 || dns_bulk_snippet() { case "${1##*/}" in 06-adblock.conf|07-zapret-dom.conf|1[0-9]-geo*.conf) return 0 ;; esac; return 1; }
# The connection table: LANDNS_CT is the stand's file (dev/lan-dns-test.sh; the router never sets it), else the owner of listing
# it (ct-lib.sh::ct_list_all: `conntrack -L` where the utility exists, else /proc), else /proc itself.
ld_ct() {
	if [ -n "${LANDNS_CT:-}" ]; then cat "$LANDNS_CT" 2>/dev/null; return 0; fi
	if command -v ct_list_all >/dev/null 2>&1; then ct_list_all; return 0; fi
	cat /proc/net/nf_conntrack 2>/dev/null || cat /proc/net/ip_conntrack 2>/dev/null
	return 0
}
command -v ip_is_self >/dev/null 2>&1 || ip_is_self() { [ -n "$1" ] || return 1; case "$(ip route get "${1%/32}" 2>/dev/null | sed -n 1p)" in "local "*) return 0 ;; esac; return 1; }   # not-wan: «is this the router itself», the rule of ip-lib.sh::ip_is_self
command -v ip_is_local >/dev/null 2>&1 || ip_is_local() { [ -n "$1" ] || return 1; case "$(ip route get "$1" 2>/dev/null | sed -n '1s/.* dev \([^ ]*\).*/\1/p')" in br-*|awgs0|lo) return 0 ;; esac; return 1; }   # not-wan: the client's bridge, the rule of lease-lib.sh::ip_is_local
command -v dnsmasq_conf_files >/dev/null 2>&1 || dnsmasq_conf_files() { for _dcf_f in /var/etc/dnsmasq.conf* /etc/dnsmasq.conf /tmp/dnsmasq.d/*; do [ -f "$_dcf_f" ] && echo "$_dcf_f"; done; }

# ONE FORM of an address, so a resolver from conntrack (IPv6 printed fully expanded, 0000:…:0001) and the same resolver from a
# dnsmasq line (short, `2001:4860:4860::8888`) compare equal: `::` expanded to its zero groups, leading zeros of each group
# dropped, lower case — 2001:4860:4860:0:0:0:0:8888. IPv4 and an IPv4-tailed IPv6 pass untouched. Anything outside the address
# alphabet is cut: the value goes into JSON as is.
ld_addr() {
	printf '%s\n' "$1" | tr -cd '0-9a-fA-F.:\n' | awk '/:/ && !/\./ {
		s = tolower($0); n = 0
		if (s ~ /::/) sub(/::/, ":z:", s)
		gsub(/:/, " ", s); $0 = s
		for (i = 1; i <= NF; i++) if ($i != "z") n++
		o = ""
		for (i = 1; i <= NF; i++) {
			if ($i == "z") { for (k = n; k < 8; k++) { if (o != "") o = o ":"; o = o "0" }; continue }
			g = $i; sub(/^0+/, "", g); if (g == "") g = "0"
			if (o != "") o = o ":"
			o = o g
		}
		print o; next } { print }'
}

# Self/client answers per DISTINCT address, cached for the run: a busy house has hundreds of DNS entries, a handful of addresses.
_ld_self=" "; _ld_notself=" "; _ld_cli=" "; _ld_notcli=" "
ld_self() {
	case "$_ld_self" in *" $1 "*) return 0 ;; esac
	case "$_ld_notself" in *" $1 "*) return 1 ;; esac
	if ip_is_self "$1"; then _ld_self="$_ld_self$1 "; return 0; fi
	_ld_notself="$_ld_notself$1 "; return 1
}
ld_client() {
	case "$_ld_cli" in *" $1 "*) return 0 ;; esac
	case "$_ld_notcli" in *" $1 "*) return 1 ;; esac
	if ip_is_local "$1"; then _ld_cli="$_ld_cli$1 "; return 0; fi
	_ld_notcli="$_ld_notcli$1 "; return 1
}

# The config's two kinds of records, from every file dnsmasq reads (grep first: only these lines reach awk):
#   O⇥<net>⇥<addr …>⇥<file>   an option-6 line; fields before the option are tags (`tag:x`, `set:x`, `net:x`, or bare —
#                              OpenWrt writes `dhcp-option=lan,6,…`); none ⇒ `*`; a negated one (`tag:!lan` — every network
#                              BUT that one) stays `!lan`: shown as every network, never matched to a device of `lan`; an
#                              encap/vendor line is not a DNS option to the client; an empty value (`lan,6`) is no line.
#   R⇥<net>⇥<start>⇥<mask>    an IPv4 dhcp-range and the tag it SETS (`set:x`, or a bare first word — the old syntax; else `*`);
#                              mask 255.255.255.0 when not written.
# dnsmasq's grammar allows spaces around `=`; its reader (option.c read_file) turns every whitespace — a snippet's CR too — into a
# space, starts a comment at `#` after whitespace, drops quotes, and looks an `option:` name up case-blind: read the same way, or
# a CRLF snippet's `lan,6,<the router>\r` was a foreign DNS, `… # the router` glued the comment's letters to the address, and
# `option:DNS-Server` was missed (review s.175 r3). Our bulk snippets (dns-lib.sh::dns_bulk_snippet) are not read: no DHCP option
# lives there, and one busybox grep over an adblock list costs seconds on every open of the screen (review s.175 r2). ONE grep
# over all files (`-H` names each line's file): a grep and an awk per file were two processes per snippet.
# A tag is cut to ONE alphabet for both kinds (the range's and the option's are compared by ld_given): `guest.1` on one side and
# `guest1` on the other never matched.
ld_records() {
	_ldfl=$(dnsmasq_conf_files | while IFS= read -r _ldf; do dns_bulk_snippet "$_ldf" || echo "$_ldf"; done)
	[ -n "$_ldfl" ] || return 0
	# $_ldfl unquoted on purpose: a list of paths (dnsmasq's paths carry no spaces).
	grep -H -E '^[[:space:]]*dhcp-(option|option-force|range)[[:space:]]*=' $_ldfl /dev/null 2>/dev/null | awk -v T="$TAB" 'BEGIN { FS = "," }
		{ f = $0; sub(/:.*/, "", f); s = $0; sub(/^[^:]*:/, "", s)
			gsub(/[\t\r]/, " ", s); sub(/ #.*/, "", s); gsub(/"/, "", s); $0 = s }
		/^[ \t]*dhcp-range[ \t]*=/ {
			sub(/^[ \t]*dhcp-range[ \t]*=/, "", s); $0 = s
			tag = "*"; st = ""; mk = ""
			for (i = 1; i <= NF; i++) { x = $i; gsub(/[ \t]/, "", x)
				if (x ~ /^set:/) { sub(/^set:/, "", x); tag = x; continue }
				if (i == 1 && x !~ /:/ && x !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { tag = x; continue }
				if (x !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) continue
				if (st == "") st = x
				else if (x ~ /^255\./) mk = x
			}
			if (st == "") next
			if (mk == "") mk = "255.255.255.0"
			gsub(/[^A-Za-z0-9_*!-]/, "", tag); if (tag == "") tag = "*"
			print "R" T tag T st T mk; next
		}
		{
			sub(/^[ \t]*dhcp-option(-force)?[ \t]*=/, "", s); $0 = s
			tag = ""; opt = ""; st = 0
			for (i = 1; i <= NF; i++) { x = $i; gsub(/[][ \t]/, "", x); lx = tolower(x)
				if (x ~ /^(encap|vi-encap|rfc3925-encap|vendor):/) { opt = "skip"; break }
				if (lx ~ /^option6?:/ || lx ~ /^[0-9]+$/) { opt = lx; st = i + 1; break }
				if (x ~ /^(tag|set|net):/) sub(/^[a-z]+:/, "", x)
				if (tag == "") tag = x
			}
			if (opt != "6" && opt != "option:dns-server" && opt != "option6:dns-server" && opt != "option6:23") next
			a = ""
			for (i = st; i <= NF; i++) { x = $i; gsub(/[][ \t]/, "", x); if (x == "") continue; if (a != "") a = a " "; a = a x }
			if (a == "") next
			if (tag == "") tag = "*"
			print "O" T tag T a T f
		}'
}

# Where a network's foreign DNS is set: the stock DHCP fields, an own uci option, or only the file. `$1` net, `$2` addresses (one
# form — ld_addr), `$3` the file.
ld_dhcp_src() {
	case "$1" in *[!A-Za-z0-9_]*|'') echo "file:$3"; return ;; esac
	for _lds in $(uci -q get "dhcp.$1.dns1" 2>/dev/null) $(uci -q get "dhcp.$1.dns2" 2>/dev/null); do
		case " $2 " in *" $(ld_addr "$_lds") "*) echo stock; return ;; esac
	done
	case " $(uci -q get "dhcp.$1.dhcp_option" 2>/dev/null) $(uci -q get "dhcp.$1.dhcp_option_force" 2>/dev/null) " in
		*" 6,"*|*"option:dns-server"*) echo uci; return ;;
	esac
	echo "file:$3"
}

# Is IPv4 `$1` inside the network of range start `$2` with mask `$3`? Octet by octet: sh arithmetic is 32-bit signed on armv7
# (BE3600) and a whole address overflows it; an octet never does.
ld_in_net() {
	case "$1.$2.$3" in *[!0-9.]*) return 1 ;; esac
	set -- $(echo "$1 $2 $3" | tr '.' ' ')
	[ "$#" -eq 12 ] || return 1
	[ $(( $1 & $9 )) -eq $(( $5 & $9 )) ] && [ $(( $2 & ${10} )) -eq $(( $6 & ${10} )) ] \
		&& [ $(( $3 & ${11} )) -eq $(( $7 & ${11} )) ] && [ $(( $4 & ${12} )) -eq $(( $8 & ${12} )) ]
}
# The network (dhcp tag) a device's address belongs to — the first range whose network holds it; nothing for IPv6.
ld_net_of() {   # $1 ip, $2 the R records
	printf '%s\n' "$2" | while IFS="$TAB" read -r _lnk _lnn _lns _lnm; do
		[ "$_lnk" = R ] || continue
		if ld_in_net "$1" "$_lns" "$_lnm"; then echo "$_lnn"; break; fi
	done
}
# Does the DHCP of network `$2` (or an untagged line) hand out resolver `$1`? `$3` — the dhcp findings `net⇥addrs⇥src⇥own`. A
# negated line (`!lan`) hands out to every network but that one — and to none we cannot place (IPv6: no range tells its network).
ld_given() {
	printf '%s\n' "$3" | while IFS="$TAB" read -r _lgn _lga _lgs _lgo; do
		case "$_lgn" in
			'*') ;;
			!*) [ -n "$2" ] && [ "${_lgn#!}" != "$2" ] || continue ;;
			*) [ -n "$2" ] && [ "$_lgn" = "$2" ] || continue ;;
		esac
		case " $_lga " in *" $1 "*) echo y; break ;; esac
	done | grep y >/dev/null
}

cmd_scan() {
	_ldrec=$(ld_records)
	# 1. DHCP: a line counts only if an address in it is NOT the router (0.0.0.0 / :: = dnsmasq's own address); the same line
	#    in both conf-dirs (init copies /etc → /tmp) is told once.
	_ldfound=$(printf '%s\n' "$_ldrec" | while IFS="$TAB" read -r _ldk _ldn _lda _ldf; do
		[ "$_ldk" = O ] || continue
		_ldo=0; _ldx=""
		for _lde in $_lda; do
			case "$_lde" in 0.0.0.0|::|'') _ldo=1; continue ;; esac
			if ld_self "$_lde"; then _ldo=1; continue; fi
			_ldx="$_ldx${_ldx:+ }$(ld_addr "$_lde")"
		done
		[ -n "$_ldx" ] || continue
		_ldn=$(printf '%s' "$_ldn" | tr -cd 'A-Za-z0-9_*!-')
		_ldp=$(printf '%s' "$_ldf" | tr -cd 'A-Za-z0-9_./-')
		printf '%s\t%s\t%s\t%s\n' "${_ldn:-*}" "$_ldx" "$(ld_dhcp_src "$_ldn" "$_ldx" "$_ldp")" "$_ldo"
	done | awk -F "$TAB" '!seen[$1 FS $2]++')
	[ -z "$_ldfound" ] || printf '%s\n' "$_ldfound" | sed 's/^/dhcp=/'
	# 2. Devices: the ORIGINAL direction's src/dst/dport and the REPLY's src (the second src= of the line). The table comes from
	#    ct-lib.sh::ct_list_all (the utility where there is one, else /proc) in one pass that also says whether it was read at
	#    all: a live router's table is never empty (this very request is in it) — nothing read ⇒ ct=0.
	_ldct=$(ld_ct | awk '{ seen = 1 } /dport=(53|853) / { s = ""; d = ""; p = ""; r = ""; n = 0
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^src=/) { n++; if (n == 1) s = substr($i, 5); else if (n == 2) r = substr($i, 5) }
			else if ($i ~ /^dst=/ && d == "") d = substr($i, 5)
			else if ($i ~ /^dport=/ && p == "") p = substr($i, 7)
		}
		if (p == "53" || p == "853") print s, d, p, r }
		END { if (seen) print "#read" }')
	case "$_ldct" in *"#read"*) echo "ct=1" ;; *) echo "ct=0"; return 0 ;; esac
	printf '%s\n' "$_ldct" | grep -v '^#read$' | sort | uniq -c |
	while read -r _ldc _lds _ldd _ldp _ldr; do
		# Answered by the router (asked it, or caught by our DNAT/REDIRECT): the reply's source is ours. Asked FIRST — cached and
		# true for nearly every line. An empty reply source (a line cut short) is not counted as past us.
		{ [ -z "$_ldr" ] || ld_self "$_ldr"; } && continue
		ld_self "$_lds" && continue          # the router's own query (to its upstream, a probe)
		ld_client "$_lds" || continue        # not a device of ours (a WAN host asking a LAN server)
		echo "$(ld_addr "$_lds") $(ld_addr "$_ldd") $_ldp $_ldc"
	done | awk '{ c[$1 "\t" $2 "\t" $3] += $4 } END { for (k in c) print k "\t" c[k] }' | sort |
	while IFS="$TAB" read -r _ldi _ldt _ldq _ldm; do
		_ldg=0
		ld_given "$_ldt" "$(ld_net_of "$_ldi" "$_ldrec")" "$_ldfound" && _ldg=1
		printf 'dev=%s\t%s\t%s\t%s\t%s\n' "$_ldi" "$_ldt" "$_ldq" "$_ldm" "$_ldg"
	done
}

# THE CAP OVER THE WHOLE TREE (review s.175 r3, both halves). The CGI capped the scan with busybox `timeout -t 8`, which signals
# ONE pid — this shell; the pipelines' children (the conntrack awk, the grep over the config, the `ip route get` loop) lived on and
# held the CGI's `$(…)` open, so a slow table still held the whole DNS screen (the console's rake, cgi-bin/action, BE7000
# 23.09.2026). So the scan caps itself (and needs no `timeout` applet: upstream busybox ≥ 1.30 dropped its `-t`, although
# BE10000 PRO's 1.36.1 still ran `timeout -t 4 nslookup` in the 29.10.2026 trace). The watchdog is started DETACHED — a subshell whose parent exits at once, reparented to init: it is not in this shell's
# tree, so the walk below never signals the watchdog itself halfway through the list — with stdio in /dev/null, never holding the
# caller's pipe. Past the cap, if this very scan still runs (pid_runs: a pid is reused), it kills the scan's whole tree
# (daemon-lib.sh::proc_tree_kill — frozen first, so a child born mid-way does not survive). A finished scan leaves the watchdog
# asleep until the cap; it then finds the pid gone and exits. No proc_tree_kill (a library older than the script) — no cap, as
# before the cap existed.
ld_cap() {   # $1 seconds
	case "$1" in ''|0|*[!0-9]*) return 0 ;; esac
	command -v proc_tree_kill >/dev/null 2>&1 || return 0
	_ldme=$$
	( ( sleep "$1"; pid_runs "$_ldme" 'lan-dns\.sh json' && proc_tree_kill "$_ldme" ) & ) </dev/null >/dev/null 2>&1
	return 0
}

# The scan as ONE JSON object for the panel (cgi-bin/data, section doh → `lan_dns`). Nothing said (no `ct=` line: the scan died)
# ⇒ `null`, never an «all clean» answer made of an empty scan.
cmd_json() {
	cmd_scan | awk -v T="$TAB" 'BEGIN { FS = T; ct = ""; d = ""; v = "" }
		/^ct=/ { ct = substr($0, 4); next }
		/^dhcp=/ { n = substr($1, 6); if (n ~ /^!/) n = "*"; o = "false"; if ($4 == "1") o = "true"
			if (d != "") d = d ","
			d = d "{\"net\":\"" n "\",\"addr\":\"" $2 "\",\"src\":\"" $3 "\",\"own\":" o "}"; next }
		/^dev=/ { i = substr($1, 5); g = "false"; if ($5 == "1") g = "true"; p = $3 + 0; m = $4 + 0
			if (v != "") v = v ","
			v = v "{\"ip\":\"" i "\",\"to\":\"" $2 "\",\"port\":" p ",\"n\":" m ",\"dhcp\":" g "}"; next }
		END { if (ct == "") { print "null"; exit }
			c = "false"; if (ct == "1") c = "true"
			printf "{\"ct\":%s,\"dhcp\":[%s],\"devs\":[%s]}\n", c, d, v }'
}

case "$1" in
	scan) cmd_scan ;;
	json) ld_cap "$2"; cmd_json ;;
	*) echo "usage: lan-dns.sh scan|json [secs]" >&2; exit 2 ;;
esac
