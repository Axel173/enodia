#!/bin/sh
# traffic-dev.sh — TRAFFIC BY DEVICE: the firmware's own per-device byte counters (`ubus call trafficd hw`) accumulated into
# days, for «Трафик → Устройства» and the «Статистика» tab of a device in the panel.
#
# WHY THIS SOURCE. By address the router cannot count at all: NSS/ECM offload takes established flows past netfilter (the
# project map), so rule counters and conntrack stand still or undercount. The stock trafficd counts per device what the
# station moved — offloaded and tunnelled bytes included (BE7000 08.10.2026: a 1 GiB download → +1129 MB). It counts
# EVERYTHING through the router: casting to the TV, the NAS, retries into a REJECT — so the panel says «через роутер», never
# «в интернет», and the sum over devices does not have to match the WAN total of traffic-acct.sh.
#
# THE ONE PARSER of trafficd (`snap`): the day limit of access-sched.sh reads the same answer through it.
#
# COUNTERS ARE PER (MAC, ADDRESS). trafficd keeps a counter per address of a device (`ip_list`), and an address ages out of
# the list: a per-MAC sum then FALLS, and the ladder «went back = counted from zero» would count the surviving addresses a
# second time. So deltas are taken per pair and only then summed per MAC.
#
# STATE — the flash cost is the design constraint (/data: 20 MB, mounted `sync`; .traffic-daily is rewritten every 5 min):
#   RAM   $TD_RUN/last   the previous sample: «#⇥<uptime>» + «mac⇥ip⇥rx⇥tx» per pair. It dies with a reboot — and so do the
#                        trafficd counters it is compared with.
#         $TD_RUN/day    today so far: «<date> <boot id>» + «mac rx tx»
#         $TD_RUN/hosts  «mac⇥host» — the last name trafficd gave each device (a device gone from its table keeps a name)
#         $TD_RUN/saved  uptime of the last checkpoint
#   flash $TD_CKPT       the day, copied every TD_SAVE (4 h — user decision 09.10.2026: a power cut may lose up to that much of
#                        TODAY's split; the totals of traffic-acct.sh are not affected) and on the first tick of every boot
#         $TD_HIST       closed days «date mac rx tx», appended ONCE per day: at most TD_DAY_MAX devices a day by volume, the
#                        rest summed into one «other» line (bytes kept, lines bounded); TD_KEEP days, trimmed once a month
#         $TD_HOSTS      «mac⇥host» of the devices in the history, rewritten only when a closed day brings a change
#
# AFTER A REBOOT trafficd counts from zero and RAM is empty. The checkpoint carries the boot id it was written in: another
# boot id ⇒ the counters started with this boot ⇒ the first sample counts them whole. The same boot id (RAM lost without a
# reboot) or no checkpoint at all (first run) ⇒ the first sample only records. Without a boot id (a kernel without it) — «a
# reboot» = uptime under TD_BOOT_WIN.
#
# THE WALL CLOCK decides which day a delta belongs to ⇒ the tick runs only on a clock synced THIS boot (clock_trusted): after a
# reboot the clock sits on a file's mtime, a sane-looking date days behind. Until it syncs the deltas wait in the trafficd
# counters (RAM `last` is kept) and land on the right day.
#
# Commands:
#   traffic-dev.sh snap            — trafficd now, TSV per pair: mac⇥ip⇥rx⇥tx⇥assoc⇥ifname⇥host (MAC lowercase; ifname «-»
#                                    when empty; host without quotes, backslashes, tabs and control bytes — it goes into JSON)
#   traffic-dev.sh tick            — one accounting step (traffic-acct.sh calls it every 5 min, under its lock)
#   traffic-dev.sh json <today|week|month|year> — the window's devices by volume (JSON for cgi-bin/traffic)
#   traffic-dev.sh json-mac <mac>  — one device: the four windows and the house's total in each (JSON)
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
TD_RUN=${TD_RUN:-/tmp/enodia-traffic-dev}
TD_BOOT_F=${TD_BOOT_F:-/proc/sys/kernel/random/boot_id}
TD_HIST="$ENODIA_STATE/.traffic-dev"
TD_CKPT="$ENODIA_STATE/.traffic-dev-day"
TD_HOSTS="$ENODIA_STATE/.traffic-dev-hosts"
TD_KEEP=400            # days of history — as .traffic-daily keeps: every window of the screen has its days
TD_DAY_MAX=16          # devices a closed day keeps by name; the rest — one «other» line
TD_SAVE=14400          # seconds of uptime between checkpoints of the day
TD_BOOT_WIN=7200       # without a boot id: «the counters are this boot's» while uptime is under this
TD_CAP=1250000000      # bytes per second of one pair (10 Gbit/s): a delta over it is a counter glitch, not traffic
TD_CARRY=86400         # seconds of uptime a pair missing from trafficd's answer keeps its last counters in `last`
# One closed-day line of the history as the readers accept it: date · MAC or «other» · two counters. A hand-edited or imported
# line that is not this is not counted and not taken as «the last closed day» (review s.115, round 1: a garbage first field sorts
# after every date — counted in every window, shown as «since» unescaped, and as the last line it blocked every later close).
# …and a day NOT AFTER TODAY (round 2: a future line from a backup of a router whose clock ran ahead stopped every close until
# that date and hid «сегодня»), a real month and day, counters of at most 15 digits (a 309-digit one is `inf` in awk — invalid
# JSON for 400 days). EVERY awk using it gets `-v today=<YYYY-MM-DD>`: unset, it would reject every line.
TD_LINE_OK='NF == 4 && $1 <= today && $1 ~ /^[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/ && ($2 ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/ || $2 == "other") && $3 ~ /^[0-9]+$/ && length($3) <= 15 && $4 ~ /^[0-9]+$/ && length($4) <= 15'
TAB=$(printf '\t')

# MAC parsing — the owner of «who is this device» (lease-lib.sh, it also sources clock-lib.sh). Shims = the same lines.
if [ -f "$ENODIA_DIR/lease-lib.sh" ]; then . "$ENODIA_DIR/lease-lib.sh"; fi
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v mac_norm >/dev/null 2>&1 || mac_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n'; }
command -v mac_ok   >/dev/null 2>&1 || mac_ok()   { printf '%s' "$1" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; }
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
command -v clock_trusted >/dev/null 2>&1 || clock_trusted() { return 1; }

# Temporary files are ours by the pid suffix; a signal must not leave them in RAM (C121: EXIT does not fire on a signal).
td_cleanup() { rm -f "$TD_RUN/"*".$$" "$TD_CKPT.$$" "$TD_HIST.$$" "$TD_HOSTS.$$" 2>/dev/null; }
trap td_cleanup EXIT
trap 'exit 1' INT TERM HUP PIPE

# What goes into JSON from a foreign source (trafficd, leases, a hand-edited or imported file): no quote, no backslash, no
# control byte — TAB and LF stay, they are field and line separators here.
td_clean() { tr -d '\000-\010\013-\037"\\'; }
td_lt() { awk 'BEGIN { exit !(ARGV[1] < ARGV[2]) }' "$1" "$2"; }   # string order of two dates (ISO sorts as text)
td_boot() {
	_tbi=""; read -r _tbi < "$TD_BOOT_F" 2>/dev/null
	case "$_tbi" in *[!0-9a-f-]*) _tbi="" ;; esac
	echo "$_tbi"
}

# trafficd → pairs. ubus prints one key per line; the device's fields precede its `ip_list`, an address entry opens with a
# bare «{» and its "ip" comes before the counters (the shape of BE7000 08.10.2026). Backslashes and control bytes go BEFORE
# parsing (the quotes stay — they are the JSON's structure): an escaped quote inside a name then ends the name, so no name
# carries a quote or a backslash out. EVERY KEY IS MATCHED AT THE START OF ITS LINE: with the backslashes gone, a name like
# `kid\", \"hw\": \"aa:…` reads as more keys on the hostname's line, and an unanchored `"hw":` took the device's bytes to a
# MAC of the name's choosing (review s.115, round 1) — out of the split and out of the day limit, which reads this parser. The
# counters go to the pair opened by its "ip" line, not to whatever MAC the last "hw" line named.
# `-t 5`: the tick holds traffic-acct.sh's lock — a hung bus must not hold it for an hour.
td_snap() {
	ubus -t 5 call trafficd hw 2>/dev/null | tr -d '\000-\010\013-\037\\' | awk -v T="$TAB" '
		BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f" }
		/^[ \t]*\{[ \t]*$/ { ip = ""; pk = "" }
		# the device is named by the "hw" of its object, never by the "hw" inside an address entry (round 2: if trafficd keeps
		# the current holder of the address there, the bytes of the next entry would go to another MAC)
		/^[ \t]*"[0-9A-Fa-f:]+": *\{/ { inl = 0 }
		/^[ \t]*"ip_list":/ { inl = 1 }
		/^[ \t]*\][ \t,]*$/ { inl = 0 }   # the list closed: a device object keyed otherwise than by a MAC still names itself (r.3)
		/^[ \t]*"hw":/ { if (inl) next; v = $0; sub(/^[ \t]*"hw": *"/, "", v); sub(/".*/, "", v); mac = tolower(v) }
		/^[ \t]*"hostname":/ { v = $0; sub(/^[ \t]*"hostname": *"/, "", v); sub(/".*/, "", v); if (v == "*") v = ""; gsub(/\t/, " ", v); hn[mac] = v }
		/^[ \t]*"ifname":/ { v = $0; sub(/^[ \t]*"ifname": *"/, "", v); sub(/".*/, "", v); ifn[mac] = v }
		/^[ \t]*"assoc":/ { v = $0; gsub(/[^0-9]/, "", v); as[mac] = v + 0 }
		/^[ \t]*"ip":/ { v = $0; sub(/^[ \t]*"ip": *"/, "", v); sub(/".*/, "", v); ip = v; pk = mac T ip
			if (!(pk in seen)) { seen[pk] = 1; pm[++n] = mac; pi[n] = ip } }
		/^[ \t]*"rx_bytes":/ { v = $0; gsub(/[^0-9]/, "", v); if (length(v) > 15) v = 0; if (pk != "") rx[pk] += v }
		/^[ \t]*"tx_bytes":/ { v = $0; gsub(/[^0-9]/, "", v); if (length(v) > 15) v = 0; if (pk != "") tx[pk] += v }
		END { for (i = 1; i <= n; i++) {
			m = pm[i]; a = pi[i]; k = m T a
			if (m !~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/) continue
			if (a !~ /^[0-9A-Fa-f:.]+$/) a = "-"
			f = ifn[m]; if (f !~ /^[A-Za-z0-9._-]+$/) f = "-"
			printf "%s%s%s%s%.0f%s%.0f%s%d%s%s%s%s\n", m, T, a, T, rx[k] + 0, T, tx[k] + 0, T, as[m], T, f, T, hn[m] } }'
}

# td_deltas <last|/dev/null> <snap> <delta|boot|seed|live> <elapsed s> → «mac drx dtx» per device that moved.
# The ladder per pair: seen and grew ⇒ the difference · seen and fell ⇒ restarted, counted from zero · not seen (a pair born
# since the last sample) or a boot sample ⇒ the whole counter · seed ⇒ nothing (we only learn the counters). A delta over the
# link ceiling for the elapsed time is a glitch and counts nothing — it would poison the history for a year.
# `live` — the READER's «unwritten delta of now»: only growth counts. Its snapshot is taken before it reads `last`, and a tick
# writing a newer `last` in between makes every grown pair look «fallen» — the ladder above would add whole counters since boot
# to one answer (review s.115, round 1). A fall or a new pair waits for the tick, which judges them on its own sample.
td_deltas() {
	awk -F'\t' -v L="$1" -v md="$3" -v el="$4" -v cps="$TD_CAP" '
		BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f"; T = "\t"; c = cps * el }
		FILENAME == L { if ($1 != "#") { k = $1 T $2; lr[k] = $3 + 0; lt[k] = $4 + 0; lk[k] = 1 }; next }
		md == "seed" { next }
		{ k = $1 T $2; r = $3 + 0; t = $4 + 0
		  if (md == "live") { dr = ((k in lk) && r >= lr[k]) ? r - lr[k] : 0; dt = ((k in lk) && t >= lt[k]) ? t - lt[k] : 0 }
		  else if (md == "boot" || !(k in lk)) { dr = r; dt = t }
		  else { dr = (r >= lr[k]) ? r - lr[k] : r; dt = (t >= lt[k]) ? t - lt[k] : t }
		  if (dr > c) dr = 0
		  if (dt > c) dt = 0
		  if (!($1 in seen)) { seen[$1] = 1; o[++n] = $1 }
		  R[$1] += dr; X[$1] += dt }
		END { for (i = 1; i <= n; i++) if (R[o[i]] + X[o[i]] > 0) printf "%s %.0f %.0f\n", o[i], R[o[i]], X[o[i]] }' "$1" "$2"
}

# Close a day: its devices into the history (once), their names into the remembered ones, a trim when the oldest line is a
# month past the keep. «Once»: a checkpoint written before the close comes back after a reboot or a lost RAM — a day not after
# the last closed one is closed already. <day file> <now epoch>
td_close() {
	_cd=$(head -n 1 "$1" 2>/dev/null | cut -d' ' -f1)
	case "$_cd" in [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;; *) return 0 ;; esac
	_cdt=$(date +%F)
	_cl=$(awk -v today="$_cdt" "$TD_LINE_OK { d = \$1 } END { print d }" "$TD_HIST" 2>/dev/null)   # the last VALID closed day (a once-a-day pass)
	if [ -n "$_cl" ] && ! td_lt "$_cl" "$_cd"; then return 0; fi
	# busybox sort has no -k: the volume goes first, zero-padded to a fixed width, and a TEXT sort orders it — its `-n` compares
	# modulo 2^32 (BE7000 09.10.2026: 4294967297 sorts as 1), and a device past 4 GB a day fell out of the top into «other»
	awk 'NR > 1 && NF == 3 && ($2 + $3) > 0 { printf "%017.0f %s %.0f %.0f\n", $2 + $3, $1, $2, $3 }' "$1" | sort -r |
		awk -v d="$_cd" -v n="$TD_DAY_MAX" 'BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f" }
			NR <= n && $2 != "other" { printf "%s %s %.0f %.0f\n", d, $2, $3, $4; next }
			{ r += $3; t += $4 }
			END { if (r + t > 0) printf "%s other %.0f %.0f\n", d, r, t }' >> "$TD_HIST"
	# Names: the remembered file changes only when this day brings a new or another name for one of its devices (awk exits 1
	# when nothing changed — no write).
	: >> "$TD_HOSTS" 2>/dev/null
	if [ -f "$TD_RUN/hosts" ] && awk -F'\t' -v H="$TD_HOSTS" -v R="$TD_RUN/hosts" -v T="$TAB" '
			FILENAME == H { if (NF >= 2 && !($1 in h)) { h[$1] = $2; o[++n] = $1 }; next }
			FILENAME == R { if (NF >= 2 && $2 != "") r[$1] = $2; next }
			FNR > 1 { m = $1; sub(/ .*/, "", m)
				# membership BEFORE the comparison: reading h[m] would create the element, and a new device would never be listed
				if (!(m in r)) next
				if (!(m in h)) { o[++n] = m; h[m] = r[m]; ch = 1 } else if (h[m] != r[m]) { h[m] = r[m]; ch = 1 } }
			END { if (!ch) exit 1; for (i = 1; i <= n; i++) print o[i] T h[o[i]] }' "$TD_HOSTS" "$TD_RUN/hosts" "$1" > "$TD_HOSTS.$$"
	then mv "$TD_HOSTS.$$" "$TD_HOSTS"; fi
	rm -f "$TD_HOSTS.$$" 2>/dev/null
	_cf=$(awk -v today="$_cdt" "$TD_LINE_OK { print \$1; exit }" "$TD_HIST" 2>/dev/null)   # the first VALID line: a garbage one must not stall the trim
	_ck=$(date -d "@$(( $2 - TD_KEEP * 86400 ))" +%F 2>/dev/null)
	_ct=$(date -d "@$(( $2 - (TD_KEEP + 31) * 86400 ))" +%F 2>/dev/null)
	if [ -n "$_cf" ] && [ -n "$_ct" ] && td_lt "$_cf" "$_ct"; then
		awk -v k="$_ck" -v today="$_cdt" "$TD_LINE_OK"' && $1 >= k' "$TD_HIST" > "$TD_HIST.$$" && mv "$TD_HIST.$$" "$TD_HIST"
		awk -F'\t' -v Hh="$TD_HIST" 'FILENAME == Hh { k = $0; sub(/^[^ ]* /, "", k); sub(/ .*/, "", k); m[k] = 1; next } ($1 in m)' \
			"$TD_HIST" "$TD_HOSTS" > "$TD_HOSTS.$$" && mv "$TD_HOSTS.$$" "$TD_HOSTS"
	fi
	return 0
}

cmd_tick() {
	clock_trusted || return 0
	mkdir -p "$TD_RUN" 2>/dev/null || return 0
	# Temporary files of a dead process: uhttpd SIGKILLs a CGI whose client left (the trap is silent then) — a reader leaves its
	# `rsnap.<pid>`/`rout.<pid>` in RAM; nobody else knows this directory (round 2).
	for _tf in "$TD_RUN"/*.* "$TD_CKPT".* "$TD_HIST".* "$TD_HOSTS".*; do   # …and a killed tick's own on the flash (r.3)
		_tp=${_tf##*.}; case "$_tp" in ''|*[!0-9]*) continue ;; esac
		[ -d "/proc/$_tp" ] || rm -f "$_tf"
	done
	_tn=$(date +%s); _tt=$(date +%F); _tu=$(uptime_s); _tb=$(td_boot)
	_ts="$TD_RUN/snap.$$"
	td_snap > "$_ts"
	[ -s "$_ts" ] || return 0              # trafficd silent: no sample — `last` stays, the next answer covers the gap
	_tdf="$TD_RUN/day"
	if [ ! -s "$_tdf" ] && [ -s "$TD_CKPT" ]; then cp "$TD_CKPT" "$_tdf" 2>/dev/null; fi
	_tlf="$TD_RUN/last"
	if [ -s "$_tlf" ]; then
		_tm=delta
		_tlu=$(head -n 1 "$_tlf" | cut -f2); case "$_tlu" in ''|*[!0-9]*) _tlu=$_tu ;; esac
		_tel=$(( _tu - _tlu ))
	else
		_tm=seed; _tlf=/dev/null; _tel=$_tu
		if [ -s "$TD_CKPT" ]; then
			_tcb=$(head -n 1 "$TD_CKPT" | cut -d' ' -f2)
			if [ -n "$_tb" ]; then
				if [ "$_tcb" != "$_tb" ]; then _tm=boot; fi
			elif [ "$_tu" -lt "$TD_BOOT_WIN" ]; then _tm=boot; fi
		fi
	fi
	[ "$_tel" -ge 60 ] 2>/dev/null || _tel=60
	# A day of another date: an earlier one is closed; a LATER one is a relic of a wrong clock — closing it would put a future
	# date at the end of the history, and every real day after it would count as «closed already» — and is dropped. EXCEPT one
	# day ahead: a time zone set back across midnight on a trusted clock (round 2) — that day keeps its date and its bytes, the
	# re-lived hour goes into it, and it closes when the clock reaches its end.
	_tdd=$(head -n 1 "$_tdf" 2>/dev/null | cut -d' ' -f1); _tday=$_tt
	if [ -n "$_tdd" ] && [ "$_tdd" != "$_tt" ]; then
		if td_lt "$_tdd" "$_tt"; then td_close "$_tdf" "$_tn"; rm -f "$_tdf"
		elif [ "$_tdd" = "$(date -d "@$(( _tn + 86400 ))" +%F 2>/dev/null)" ]; then _tday=$_tdd
		else rm -f "$_tdf"; fi
	fi
	td_deltas "$_tlf" "$_ts" "$_tm" "$_tel" > "$TD_RUN/dlt.$$"
	# The next sample's base: this snapshot's pairs, PLUS a pair missing from it for less than TD_CARRY of uptime with its last
	# counters. A pair absent from one answer (a partial table, a mesh node switching parents) that comes back with its old counter
	# would otherwise be «new» and charged whole again; one that comes back restarted reads as «fell» — counted from zero, right
	# either way (review s.115, round 1). The fifth field = uptime when the pair was last seen.
	# `last` is replaced BEFORE `day` (round 2): a reader between the two then misses this tick's delta for one answer (its live
	# delta against the new base is ~0) instead of counting it twice (the new day plus a delta against the old base).
	awk -F'\t' -v S="$_ts" -v up="$_tu" -v keep="$TD_CARRY" -v T="$TAB" '
		BEGIN { print "#" T up }
		FILENAME == S { s[$1 T $2] = 1; print $1 T $2 T $3 T $4 T up; next }
		$1 != "#" && NF >= 5 && !(($1 T $2) in s) && $5 + keep >= up { print $1 T $2 T $3 T $4 T $5 }' \
		"$_ts" "$_tlf" > "$TD_RUN/last.$$" && mv "$TD_RUN/last.$$" "$TD_RUN/last"
	{
		printf '%s %s\n' "$_tday" "${_tb:--}"
		{ if [ -s "$_tdf" ]; then awk 'NR > 1 && NF == 3' "$_tdf"; fi; cat "$TD_RUN/dlt.$$"; } |
			awk 'BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f" }
				$1 ~ /^[0-9a-f:]+$/ || $1 == "other" { if (!($1 in s)) { s[$1] = 1; o[++n] = $1 }; r[$1] += $2; t[$1] += $3 }
				END { for (i = 1; i <= n; i++) printf "%s %.0f %.0f\n", o[i], r[o[i]], t[o[i]] }'
	} > "$TD_RUN/day.$$" && mv "$TD_RUN/day.$$" "$_tdf"
	: >> "$TD_RUN/hosts"
	awk -F'\t' -v H="$TD_RUN/hosts" -v T="$TAB" '
		FILENAME == H { if (NF >= 2 && !($1 in h)) { h[$1] = $2; o[++n] = $1 }; next }
		$7 != "" { if (!($1 in h)) o[++n] = $1; h[$1] = $7 }
		END { for (i = 1; i <= n; i++) print o[i] T h[o[i]] }' "$TD_RUN/hosts" "$_ts" > "$TD_RUN/hosts.$$" && mv "$TD_RUN/hosts.$$" "$TD_RUN/hosts"
	# The checkpoint: on the first tick of a boot (no `saved` — it records this boot's id at once), when it is missing, and every
	# TD_SAVE of uptime. Uptime, not the wall clock: the clock jumps after a boot, uptime does not.
	_tsv=$(cat "$TD_RUN/saved" 2>/dev/null); case "$_tsv" in ''|*[!0-9]*) _tsv="" ;; esac
	if [ -z "$_tsv" ] || [ ! -s "$TD_CKPT" ] || [ "$_tu" -lt "$_tsv" ] || [ $(( _tu - _tsv )) -ge "$TD_SAVE" ]; then
		cp "$_tdf" "$TD_CKPT.$$" 2>/dev/null && mv "$TD_CKPT.$$" "$TD_CKPT" && echo "$_tu" > "$TD_RUN/saved"
	fi
	return 0
}

# The reader: one tagged stream into one awk — history (H) and the day (D) by date, the unwritten delta of «now» (U, only
# against RAM `last`: a checkpoint has no sample to compare with), trafficd now (S: address, interface, name), own labels (A),
# lease names (L), remembered names (R). Four windows in one pass; the list answers one of them, the device all four.
# Windows match the screen's: a window of N days = today and the N-1 days before it.
td_read() {   # list <today|week|month|year> | mac <mac>
	mkdir -p "$TD_RUN" 2>/dev/null
	_rn=$(date +%s); _rt=$(date +%F)
	_rw=$(date -d "@$(( _rn - 6 * 86400 ))" +%F 2>/dev/null)
	_rm=$(date -d "@$(( _rn - 29 * 86400 ))" +%F 2>/dev/null)
	_ry=$(date -d "@$(( _rn - 364 * 86400 ))" +%F 2>/dev/null)
	if [ -z "$_ry" ]; then echo '{"ok":false,"msg":"date -d"}'; return 1; fi
	_rs="$TD_RUN/rsnap.$$"
	td_snap > "$_rs"
	_rsrc=false; [ -s "$_rs" ] && _rsrc=true
	_rtr=false; clock_trusted && _rtr=true
	_rd="$TD_RUN/day"; [ -s "$_rd" ] || _rd="$TD_CKPT"
	_rel=60
	if [ -s "$TD_RUN/last" ]; then
		_rlu=$(head -n 1 "$TD_RUN/last" | cut -f2); case "$_rlu" in ''|*[!0-9]*) _rlu=0 ;; esac
		_rel=$(( $(uptime_s) - _rlu )); [ "$_rel" -ge 60 ] 2>/dev/null || _rel=60
	fi
	{
		if [ -s "$TD_HIST" ]; then
			awk -v today="$_rt" "$TD_LINE_OK"' { print "F\t" $1; exit }' "$TD_HIST"
			awk -v y="$_ry" -v today="$_rt" "$TD_LINE_OK"' && $1 >= y { print "H\t" $1 "\t" $2 "\t" $3 "\t" $4 }' "$TD_HIST"
		fi
		if [ -s "$_rd" ]; then awk 'NR == 1 { d = $1; if (d !~ /^[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]$/) exit; next }
			NF == 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print "D\t" d "\t" $1 "\t" $2 "\t" $3 }' "$_rd"; fi
		if [ -s "$TD_RUN/last" ] && [ "$_rsrc" = true ]; then
			td_deltas "$TD_RUN/last" "$_rs" live "$_rel" | awk '{ print "U\t" $1 "\t" $2 "\t" $3 }'
		fi
		# Who owns each address trafficd lists NOW — the project's one answer (lease-lib.sh::ip_owner_now: the lease, then the
		# neighbour table). A door goes only to an address that is this device's now (round 2: trafficd keeps an absent device's
		# old address for days and lists entries in its own order; DHCP may have lent the address to another; a wired client
		# without an interface in trafficd is still found here). No owner library — no doors, the numbers stay.
		if [ "$1" = list ] && command -v ip_owner_now >/dev/null 2>&1; then   # one device (json-mac) has no door field
			for _ri in $(awk -F'\t' '$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }' "$_rs" | sort -u); do
				_ro=$(ip_owner_now "$_ri" 2>/dev/null) && printf 'O\t%s\t%s\n' "$_ri" "$_ro"
			done
		fi
		awk -F'\t' '{ print "S\t" $1 "\t" $2 "\t" $5 "\t" $6 "\t" $7 }' "$_rs"
		if [ -f "$ENODIA_DIR/dev-names.sh" ]; then
			sh "$ENODIA_DIR/dev-names.sh" list 2>/dev/null | awk -F'\t' 'NF >= 2 { print "A\t" $1 "\t" $2 }'
		fi
		td_clean < "${LEASE_FILE:-/tmp/dhcp.leases}" 2>/dev/null | awk '$4 != "*" && $4 != "" { print "L\t" tolower($2) "\t" $4 }'
		cat "$TD_HOSTS" "$TD_RUN/hosts" 2>/dev/null | td_clean | awk -F'\t' 'NF >= 2 && $2 != "" { print "R\t" $1 "\t" $2 }'
	} | awk -F'\t' -v md="$1" -v q="$2" -v today="$_rt" -v fw="$_rw" -v fm="$_rm" -v fy="$_ry" -v src="$_rsrc" -v tr="$_rtr" '
		BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f"; w = (q == "today") ? 0 : (q == "week") ? 1 : (q == "month") ? 2 : 3 }
		$1 == "F" { since = $2; next }
		$1 == "O" { own[$2] = $3; next }
		$1 == "S" { if ($6 != "") sh[$2] = $6
			if (!($2 in sif) && $5 != "-") sif[$2] = $5
			if (!($2 in sip) && ($3 in own) && own[$3] == $2) sip[$2] = $3
			next }
		$1 == "A" { al[$2] = $3; next }
		$1 == "L" { lh[$2] = $3; next }
		$1 == "R" { rh[$2] = $3; next }
		$1 == "H" { if ($2 > hl) hl = $2; dt = $2; m = $3; r = $4 + 0; t = $5 + 0 }
		$1 == "D" { if (hl != "" && $2 <= hl) next; if (since == "") since = $2; dt = $2; m = $3; r = $4 + 0; t = $5 + 0 }
		$1 == "U" { dt = today; m = $2; r = $3 + 0; t = $4 + 0; if (since == "") since = today }
		$1 == "H" || $1 == "D" || $1 == "U" {
			if (m !~ /^[0-9a-f:]+$/ && m != "other") next
			if (!(m in seen)) { seen[m] = 1; o[++n] = m }
			if (dt == today) { r0[m] += r; t0[m] += t }
			if (dt >= fw) { r1[m] += r; t1[m] += t }
			if (dt >= fm) { r2[m] += r; t2[m] += t }
			if (dt >= fy) { r3[m] += r; t3[m] += t } }
		END {
			if (md == "mac") {
				for (i = 1; i <= n; i++) { k = o[i]; a0 += r0[k]; b0 += t0[k]; a1 += r1[k]; b1 += t1[k]; a2 += r2[k]; b2 += t2[k]; a3 += r3[k]; b3 += t3[k] }
				printf "{\"ok\":true,\"mac\":\"%s\",\"src\":%s,\"trusted\":%s,\"since\":\"%s\",\"w\":{", q, src, tr, since
				printf "\"today\":[%.0f,%.0f,%.0f,%.0f],\"week\":[%.0f,%.0f,%.0f,%.0f],", r0[q], t0[q], a0, b0, r1[q], t1[q], a1, b1
				printf "\"month\":[%.0f,%.0f,%.0f,%.0f],\"year\":[%.0f,%.0f,%.0f,%.0f]}}\n", r2[q], t2[q], a2, b2, r3[q], t3[q], a3, b3
				exit
			}
			for (i = 1; i <= n; i++) {
				k = o[i]
				r = (w == 0) ? r0[k] : (w == 1) ? r1[k] : (w == 2) ? r2[k] : r3[k]
				t = (w == 0) ? t0[k] : (w == 1) ? t1[k] : (w == 2) ? t2[k] : t3[k]
				if (k == "other") { orx = r; otx = t; continue }
				if (r + t <= 0) continue
				h = (k in lh) ? lh[k] : ((k in sh) ? sh[k] : rh[k])
				printf "%017.0f\t{\"mac\":\"%s\",\"rx\":%.0f,\"tx\":%.0f,\"ip\":\"%s\",\"ifn\":\"%s\",\"host\":\"%s\",\"alias\":\"%s\"}\n", r + t, k, r, t, sip[k], sif[k], h, al[k]
			}
			printf "-\t%s\t%.0f\t%.0f\n", since, orx, otx
		}' > "$TD_RUN/rout.$$"
	if [ "$1" = mac ]; then cat "$TD_RUN/rout.$$"; return 0; fi
	# the same zero-padded TEXT sort (busybox `sort -n` wraps at 2^32 — the TV with 6.9 GB was listed last); «-» = the meta line, last
	sort -r "$TD_RUN/rout.$$" | awk -F'\t' -v per="$2" -v from="$(case "$2" in today) echo "$_rt" ;; week) echo "$_rw" ;; month) echo "$_rm" ;; *) echo "$_ry" ;; esac)" \
		-v src="$_rsrc" -v tr="$_rtr" '
		BEGIN { printf "{\"ok\":true,\"per\":\"%s\",\"from\":\"%s\",\"src\":%s,\"trusted\":%s,\"devs\":[", per, from, src, tr }
		$1 == "-" { since = $2; orx = $3; otx = $4; next }
		{ printf "%s%s", (n++ ? "," : ""), $2 }
		END { printf "],\"since\":\"%s\",\"other_rx\":%s,\"other_tx\":%s}\n", since, (orx == "" ? 0 : orx), (otx == "" ? 0 : otx) }'
}

case "$1" in
	snap) td_snap ;;
	tick) cmd_tick ;;
	json)
		case "$2" in today|week|month|year) td_read list "$2" ;; *) echo '{"ok":false,"msg":"period"}'; exit 1 ;; esac ;;
	json-mac)
		_jm=$(mac_norm "$2")
		mac_ok "$_jm" || { echo '{"ok":false,"msg":"mac"}'; exit 1; }
		td_read mac "$_jm" ;;
	*) echo "usage: traffic-dev.sh snap | tick | json <today|week|month|year> | json-mac <mac>" >&2; exit 1 ;;
esac
