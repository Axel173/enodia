#!/bin/sh
# access-sched.sh — «РАСПИСАНИЯ ДОСТУПА»: when a device may go out to the internet. ONE owner of the registry, the evaluator, the
# kernel form and the per-minute tick. Design: dev notes «расписания-дизайн».
#
# Model. A schedule = devices (keyed by MAC — an address is only lent for a lease, a MAC-keyed rule does not drift to a
# neighbour) + a week of windows of three states (open · limited · closed) + the state OUTSIDE the windows (`base`). Overlap ⇒
# the stricter state wins; a window whose end is not after its start runs past midnight and belongs to the day it STARTS on
# (Fri 23:00–07:00 covers Saturday 00:00–07:00); start = end is a whole day. Actions over the schedule carry their own expiry
# (close now / open for… / postpone — `<id>.ovr`; «close all now» — `.all`; holidays — `hol`). One device = one schedule.
#
# LEVEL-TRIGGERED, not edge-triggered: there is no «close at 23:00» event pair in cron. Every minute the tick computes «what
# must be true now» and converges the kernel to it — so a reboot at 23:30, a clock step, a firewall reload that wiped our chain,
# a missed minute all heal by themselves on the next tick. The tick has its own cron line (install.sh `cron_put`): the
# watchdog's tick can run tens of minutes (failover ladder) and a 23:00 close would wait for it; heal runs once per boot.
#
# FAIL-OPEN ON AN UNSYNCED CLOCK. The router has no RTC: after a boot the clock sits on a file's mtime (a sane-looking date
# hours or days behind) until it is synced. Windows applied by that clock would close the internet in the middle of the day —
# worse than not closing. So nothing is installed until clock-lib.sh says the time is synced (`clock_trusted`), and the panel
# says so in words.
# …AND ONLY WHILE OUR TICK IS IN THE CRONTAB (`sc_ticking`). A level-triggered rule needs someone to lift it at the window's end:
# deactivation takes the cron line (uninstall.sh step_cron), and a rule a panel action or a tick in flight put back then would
# stand for good (review s.112). Without the line every schedule reads «stop» — nothing in the kernel, the panel says why.
#
# Kernel form — filter FORWARD, both families (the only place every forwarded packet passes, tunnelled or not):
#   FORWARD 1: -j ENODIA_SCHED
#   ENODIA_SCHED: -o br+ -j RETURN — the home network stays (measured BE7000: bridge-nf-call-iptables=1, so bridged LAN frames
#                 traverse FORWARD too, and a bare per-MAC DROP would cut the printer and the cameras);
#                 closed — `-m mac --mac-source M` → REJECT (tcp-reset for TCP): the app fails at once instead of hanging on
#                 a TCP timeout. INPUT stays open (DNS, the panel) — and the REDIRECTed DNS of a limited device is ACCEPTed
#                 at its top (`ENODIA_SCHED_DNSIN`, `--ctstate DNAT` to its profile's port): stock `miot_input` DROPs all
#                 but DHCP from br-miot before any zone, and a zone without redirects has no «accept port redirections»
#                 (BE7000 09.10.2026) — the device would be left with no DNS at all;
#                 limited — only DoT/DoQ (853) REJECTed: names go through our filter, see below; addresses the schedule
#                 closes — REJECT to its set (`enodia_sch_<id>`, v6 `enodia_sch6_<id>`).
# «ОГРАНИЧЕНО» = OUR DNS FILTER, not address sets (decided 08.10.2026: categories share anycast frontends — closing youtube.com by
# address closes Google Search and Gemini on the device too; «only allowed» cannot be said by address; and dnsmasq has no
# per-client answers). The DNS of a limited device is REDIRECTed by MAC (nat PREROUTING `ENODIA_SCHED_DNS`, at the top — above
# the stock guest DNAT; both families) to the port of its schedule's PROFILE in `dns-filter` (component «filter», source
# dev/dns-filter/): it answers «nothing there» for the chosen categories and own sites and passes the rest to dnsmasq. Category
# data is geo.sh's (the one owner): `geo.sh want sched <keys>` on a save, READY forms by `geo.sh ready` in the tick — never a
# fetch here. No filter binary, or it does not answer its probe after a restart ⇒ limited devices stay OPEN (fail-open, as with
# the clock) and the journal says why once. Without ip6 nat the device's IPv6 is REJECTed whole and its DNS to the router's v6
# addresses refused in INPUT (`ENODIA_SCHED_IN6`) — it falls back to IPv4, where the REDIRECT stands.
# ADDRESSES TOO, where names cannot do it (phone walk BE7000 08.10.2026: everything chosen closed except Telegram). Telegram dials
# the addresses built into the app, past DNS, so a filter of names leaves it working; its network carries nothing but Telegram —
# the anycast reason above does not hold for it. So a curated category may carry ADDRESS keys (SC_CATS, third field), a pool of
# the geo catalogue may be an address one (`geo=`, runetfreedom geoip, a country), and own sites may be addresses (`addr=`).
# geo.sh hands their data in (the same `ready`, bogons cut there); a set per SCHEDULE and family (set-lib.sh fills it, an
# unchanged one is not touched), alive only while some limited device of the schedule needs it.
# Two modes. «block» — the chosen names are answered «nothing there», the chosen addresses REJECTed. «allow» — every name but
# the chosen ones (and connectivity checks) is answered «nothing there»; addresses cannot say «only these» (an allowed site lives
# on any CDN address), so there they work one way only: the address keys of the curated categories NOT allowed are REJECTed —
# otherwise Telegram, not allowed, would still connect by its built-in addresses.
# SAFE SEARCH (`safe=1`): the same filter answers the search engines' names with their own safe front doors (dev/dns-filter,
# SAFE_MAP; YouTube moderate). It acts ALL DAY except closed time — a device of such a schedule whose week says «open» is in the
# plan as «safe»: its DNS is REDIRECTed to a profile without lists (`port P block - safe`), DoT refused as in «limited»; nothing
# else is closed. A dead filter takes it away with «limited» (fail-open, said once in the journal).
# After a device's state changes, its established flows are dropped (`ct_flush_src` per address of the MAC): NSS/ECM keeps
# offloaded flows out of netfilter otherwise. Never a global flush — a 23:00 close would drop every call in the house.
# A plan that closes nobody = no chain at all (no footprint while everything is open).
#
# Usage:
#   access-sched.sh list-json | get-json <id> | dump
#   access-sched.sh save <specfile> | del <id> | toggle <id> on|off
#   access-sched.sh ovr <id> close|open|postpone|clear [minutes|HH:MM|end|0]
#   access-sched.sh all <minutes|HH:MM|0|off> | hol <id> <YYYY-MM-DD|off>
#   access-sched.sh tick | unwire
# JSON verbs print one JSON object; messages are Russian (the panel translates them by its dictionary).

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
SC_DIR="$ENODIA_STATE/sched"        # registry on /data: written only on user actions (and once per expired override)
SC_RUN=/tmp/enodia-sched            # RAM: lock, the plan now in the kernel, last states — gone with a reboot like the kernel
SC_LOCK="$SC_RUN/lock"
SC_APPLIED="$SC_RUN/applied"        # the plan in the kernel: «<mac> <state> <id>» per line, sorted
SC_CHAIN=ENODIA_SCHED
SC_MAX=16                           # schedules
SC_WIN_MAX=24                       # windows per schedule
SC_DEV_MAX=32                       # devices per schedule
SC_NAME_MAX=60                      # characters of a name (the panel's field)
SC_K=6                              # upcoming changes reported to the panel
SC_CLOCK_NOTE=600                   # s of uptime with schedules and an unsynced clock before one journal line
# DAY LIMIT — minutes of REAL activity, by the stock `trafficd` (per MAC, counts NSS-offloaded and tunnelled traffic alike —
# measured BE7000 08.10.2026: a 1 GiB download +1129 MB there, conntrack accounting −5 %). A minute is «active» when the device
# moved at least SC_ACTIVE_B in it. Measured BE7000 08.10.2026, a phone per minute: idle 0–240 KB (one 30-MB minute — an app
# update), a YouTube video 4.1–8.8 MB in EVERY minute of 32 (no buffering gaps). 256 KB sat right above the idle peaks ⇒ 512 KB:
# twice the background, an eighth of a video. Light games (tens of KB a minute) count at neither — said in the panel.
SC_ACTIVE_B=524288
SC_USE_GAP=5                        # minutes one sample may cover (a missed tick); a longer gap counts as this much at most
SC_USE_SAVE=900                     # s between saves of the day's usage to the flash while it changes (a reboot loses ≤ 15 min)
SC_USE="$SC_RUN/use"                # RAM: «<date>» then «<mac> <minutes>» — the day's usage
SC_USE_LAST="$SC_RUN/use.last"      # RAM: «<epoch>» then «<mac> <bytes>» — the previous trafficd sample
# «ОГРАНИЧЕНО» — the DNS filter (header). A profile = a schedule with limited devices NOW; its port stays while it exists (a port
# that moved under a device would hand its next queries to another profile).
SC_FDIR="$SC_RUN/filter"            # RAM: the daemon's config, own-sites lists, the port map
# the daemon's pidfile and log by the project's /tmp names: «Перезапустить» (packages.sh) finds processes by /tmp/enodia-*.pid,
# and dump.sh / clean.sh know logs by their names
SC_FPID=/tmp/enodia-dns-filter.pid
SC_FLOG=/tmp/enodia-dns-filter.log
SC_FPORT0=5390                      # profile ports: SC_FPORT0 .. SC_FPORT0 + SC_MAX - 1 (checked free on BE7000 08.10.2026)
SC_NAT=ENODIA_SCHED_DNS             # nat PREROUTING, both families: DNS of a limited MAC → its profile's port
SC_IN6=ENODIA_SCHED_IN6             # filter INPUT v6, only without ip6 nat: DNS of a limited MAC to the router refused
SC_DNSIN=ENODIA_SCHED_DNSIN         # filter INPUT, the families with a REDIRECT: that DNS accepted at its port (header)
SC_CRONTAB=/etc/crontabs/root       # our tick's line lives here (install.sh cron_put); the stand substitutes it
SC_SITE_MAX=200                     # own sites and addresses per schedule
# pools of the geo catalogue per schedule: the filter loads a list per pool (dns-filter MAX_PL 64 per profile = 32 pools + the
# curated keys + own sites, with room), and every pool is the router's RAM
SC_POOL_MAX=32
SC_WANT_GAP=600                     # s between background fetches the tick starts for categories not downloaded yet
# Categories offered for «limited»: id|name keys|address keys|name (the panel words it by its dictionary). The keys are geo.sh's
# — the ONE owner of category data; a category is a SET of keys because «Видео» is not one upstream category. No dating or
# gambling category exists upstream ⇒ not offered (own sites cover them). ADDRESS keys (header): only for a network that carries
# nothing else — Telegram's (runetfreedom geoip); the other messengers' apps ask DNS, the filter is enough for them. They are
# also what «allow» closes by address when the category is not allowed.
# v2fly `category-communication` is not taken whole: it carries mail (protonmail, mail.com) and work chats (slack).
SC_CATS='social|v2fly-category-social-media-!cn||Соцсети
msg|v2fly-telegram v2fly-whatsapp v2fly-discord v2fly-signal v2fly-viber v2fly-messenger|rfip-telegram|Мессенджеры
video|v2fly-youtube v2fly-tiktok v2fly-twitch v2fly-vimeo v2fly-dailymotion||Видео
games|v2fly-category-games||Игры
ent|v2fly-category-entertainment||Развлечения
adult|v2fly-category-porn||Для взрослых'
SC_NL='
'

if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
# without the clock owner nobody can say the time is synced ⇒ fail-open (never close by a clock we cannot vouch for)
command -v clock_trusted >/dev/null 2>&1 || clock_trusted() { return 1; }
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '\000-\010\013-\037' | tr '\n\t' '  ' | cut -c1-"$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
command -v daemon_step_init >/dev/null 2>&1 || daemon_step_init() { DAEMON_STEP_Q=1; }
command -v daemon_step >/dev/null 2>&1 || daemon_step() { sleep 1; }
# the filter daemon's start (daemon-lib.sh owns the wait: the term is the PROCESS's life, not a stopwatch); the shim keeps a fixed
# ceiling + its own life guard for a partial update, the doh-lib.sh form
command -v daemon_wait_uport >/dev/null 2>&1 || daemon_wait_uport() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do
        netstat -lnu 2>/dev/null | grep -q "$4:$5 " && return 0
        _dwp=$(cat "$1" 2>/dev/null); [ -d "/proc/${_dwp:-none}" ] || break
        sleep 1; _dwi=$((_dwi+1))
    done
    DAEMON_WAIT_WHY="порт $5 не появился за $_dwi с (или процесс умер)"; return 1; }
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi
command -v lbl_san >/dev/null 2>&1 || lbl_san() { printf '%s' "$1" | tr '\t\r\n' '   ' | tr -d '\000-\037"\\' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g'; }
command -v lbl_lock_take >/dev/null 2>&1 || lbl_lock_take() { mkdir "$1" 2>/dev/null; }
command -v lbl_lock_drop >/dev/null 2>&1 || lbl_lock_drop() { rm -rf "$1" 2>/dev/null; }
if [ -f "$ENODIA_DIR/lease-lib.sh" ]; then . "$ENODIA_DIR/lease-lib.sh"; fi
command -v mac_norm >/dev/null 2>&1 || mac_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n'; }
command -v mac_ok >/dev/null 2>&1 || mac_ok() { printf '%s' "$1" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; }
# xtables lock wait (a rule must not silently fail to land while a foreign cron holds the lock) — ipt-lib.sh
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
command -v ct_flush_src >/dev/null 2>&1 || ct_flush_src() { [ -n "$1" ] && conntrack -D --src "$1" >/dev/null 2>&1; return 0; }
# the address sets of «limited» (header): set-lib.sh fills one atomically and leaves an unchanged one alone; without it (a partial
# update) the address part is skipped — names still go through the filter
if [ -f "$ENODIA_DIR/set-lib.sh" ]; then . "$ENODIA_DIR/set-lib.sh"; fi
# «same content» by set-lib.sh's owner (cmp, md5sum, cat — whichever this busybox has): a `cmp` that is not there would rewrite the
# site lists every tick (their stat feeds the filter's reload signature: a HUP a minute)
sc_same() { if command -v _sl_same >/dev/null 2>&1; then _sl_same "$1" "$2"; else cmp -s "$1" "$2" 2>/dev/null; fi; }
SET_MAXELEM=1000000                 # a ceiling, not an allocation: a pool may be a whole country (geo.sh takes the same)
# where the filter binary lies (the store may hold it) — store-lib.sh; without it the binaries' own directory
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }

jstr() { printf '%s' "$1" | jtxt "${2:-200}"; }
jok() { printf '{"ok":true%s}\n' "${1:+,$1}"; }
jfail() { printf '{"ok":false,"msg":"%s"%s}\n' "$(jstr "$1" 400)" "${2:+,$2}"; exit 0; }
# the ONE form of an id: no leading zero (`s01` and `s1` would be two files of one number), at most six digits (sc_new_id keeps it)
id_ok() { printf '%s' "$1" | grep -qE '^s[1-9][0-9]{0,5}$'; }
num_or() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
# the same into a variable, without a subshell (the tick runs every minute; every `$(…)` is a fork on the router)
# …without leading zeros (`060` is octal in ash arithmetic and no JSON number, `08` breaks the arithmetic) and at most 18 digits
# (64-bit arithmetic; an epoch is 10) — a hand-edited backup's `lim_wd=060` broke the whole list's JSON (review s.113, round 5)
sc_num() {
	case "$2" in ''|*[!0-9]*|???????????????????*) eval "$1=\$3" ;;
		*) _snv=$2; while :; do case "$_snv" in 0?*) _snv=${_snv#0} ;; *) break ;; esac; done; eval "$1=\$_snv" ;; esac
}
have_v6() { command -v ip6tables >/dev/null 2>&1; }

# ---- RAM dir and lock ---------------------------------------------------------------------------------------------
# /tmp is shared with stock daemons (some run as nobody): a symlink or a foreign directory laid on our name beforehand would
# turn our writes into writes as root into ITS target (the class tasks.sh::tk_rundir is built against). Ours = a real
# directory owned by root; anything else is removed and made anew, 700.
sc_rundir() {
	if [ -L "$SC_RUN" ] || { [ -e "$SC_RUN" ] && { [ ! -d "$SC_RUN" ] || [ "$(stat -c %u "$SC_RUN" 2>/dev/null)" != "$(id -u)" ]; }; }; then
		rm -rf "$SC_RUN" 2>/dev/null
	fi
	[ -d "$SC_RUN" ] || ( umask 077; mkdir "$SC_RUN" ) 2>/dev/null
	[ -d "$SC_RUN" ] && [ ! -L "$SC_RUN" ]
}
SC_LOCKED=0
sc_lock() {
	sc_rundir || return 1
	lbl_lock_take "$SC_LOCK" 'access-sched\.sh' || return 1
	SC_LOCKED=1
	trap 'sc_unlock' EXIT
	trap 'exit 1' INT TERM HUP PIPE
	return 0
}
sc_unlock() { [ "$SC_LOCKED" = 1 ] && lbl_lock_drop "$SC_LOCK"; SC_LOCKED=0; return 0; }

# ---- time ---------------------------------------------------------------------------------------------------------
# ONE `date` per call: epoch, weekday (0 = Sunday), hour, minute, second. Leading zeros go (`08` is octal in ash arithmetic).
sc_now() {
	set -- $(date '+%s %w %H %M %S %Y-%m-%d' 2>/dev/null)
	sc_num SC_E "$1" 0; sc_num SC_W "$2" 0
	sc_num SC_H "${3#0}" 0; sc_num SC_M "${4#0}" 0; sc_num SC_S "${5#0}" 0
	SC_D=${6:-}                                      # the local date: the key of the day's usage
	SC_NM=$(( SC_W * 1440 + SC_H * 60 + SC_M ))   # minute of the week, local
	SC_E0=$(( SC_E - SC_S ))                         # epoch of the start of this minute
}
# local «YYYY-MM-DD HH:MM» and weekday of an epoch -> SC_AT, SC_AW
sc_at() {
	set -- $(date -d "@$1" '+%Y-%m-%d %H:%M %w' 2>/dev/null)
	SC_AT="$1 $2"; sc_num SC_AW "$3" 0
}
# epoch of the next local HH:MM after now (today if still ahead, else tomorrow); rc 1 on a bad time
sc_next_hhmm() {
	printf '%s' "$1" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$' || return 1
	_nh=${1%%:*}; _nm=${1#*:}; _nh=${_nh#0}; _nm=${_nm#0}
	_nd=$(( ${_nh:-0} * 60 + ${_nm:-0} - SC_H * 60 - SC_M ))
	[ "$_nd" -le 0 ] && _nd=$(( _nd + 1440 ))
	SC_NEXT=$(( SC_E0 + _nd * 60 ))
}

# ---- registry -----------------------------------------------------------------------------------------------------
# <id>.sch — key=value lines; `win=` and `dev=` repeat. Read through the SAME validation as a save: the file can come from a
# backup or a hand edit, and a stray line must neither break the JSON nor reach iptables.
# categories of «limited» (SC_CATS): is it one of ours · its geo keys · the keys of a list of ids
sc_cat_ok() { case "$1" in ''|*[!a-z]*) return 1 ;; esac; case "$SC_NL$SC_CATS" in *"$SC_NL$1|"*) return 0 ;; esac; return 1; }
sc_cat_keys() {   # <id>… → the geo keys (names and addresses), a key per line, each once
	for _ck in "$@"; do printf '%s\n' "$SC_CATS" | awk -F'|' -v c="$_ck" '$1 == c { print $2 " " $3 }'; done | tr ' ' '\n' | grep . | sort -u
}
# the keys one LOADED schedule acts by, a key per line, each once: its categories and pools; «allow» adds the address keys of
# the curated categories it does not allow (header — what closes Telegram there)
sc_keys() {
	{ sc_cat_keys $SC_CATON; printf '%s\n' $SC_GEO; [ "$SC_LMODE" = allow ] && sc_bypass_keys; } | grep . | sort -u
}
sc_bypass_keys() {   # «allow»: address keys of the curated categories not allowed, minus pools chosen by hand (busybox awk: no index())
	printf '%s\n' "$SC_CATS" | while IFS='|' read -r _bi _bn _ba _bl; do
		[ -n "$_ba" ] || continue
		case " $SC_CATON " in *" $_bi "*) continue ;; esac
		for _bk in $_ba; do case " $SC_GEO " in *" $_bk "*) ;; *) echo "$_bk" ;; esac; done
	done
}
sc_geo_ok() { case "$1" in ''|.*|*[!a-z0-9._!-]*) return 1 ;; esac; [ "${#1}" -le 64 ]; }   # a pool key's form (geo.sh judges it on a save)
sc_ids() { for _f in "$SC_DIR"/s*.sch; do [ -f "$_f" ] || continue; _b=${_f##*/}; echo "${_b%.sch}"; done | grep -E '^s[1-9][0-9]{0,5}$' | sed 's/^s//' | sort -n | sed 's/^/s/'; }
# Window line «<days> <HH:MM> <HH:MM> <state>»: days are digits 0..6 (0 = Sunday), ascending, each once. ONE program for the
# load and the save — two copies of «what a window is» would let a save write what the next load silently drops. Prints the
# valid `win=` lines of a registry file (or of bare window lines with -v bare=1).
SC_WIN_AWK='
{ l = $0; if (bare != 1) { if (l !~ /^win=/) next; l = substr(l, 5) } }
l !~ /^[0-6]+ ([01][0-9]|2[0-3]):[0-5][0-9] ([01][0-9]|2[0-3]):[0-5][0-9] (open|limited|closed)$/ { next }
{ d = l; sub(/ .*/, "", d); ok = (length(d) <= 7); p = -1
  for (i = 1; i <= length(d); i++) { c = substr(d, i, 1) + 0; if (c <= p) ok = 0; p = c }
  if (ok && !(l in seen)) { seen[l] = 1; print l } }'
# Load one schedule. The whole file is read ONCE (CR from a hand edit stripped at once): the tick runs every minute, and a fork
# per line — per window, per device — cost a tenth of a second per schedule on the router. The name is kept as written and
# sanitised where it leaves (JSON, journal): the tick itself never needs it.
sc_load() {   # sc_load <id> [<file>] -> SC_* ; rc 1 = no such schedule. A file = the same schedule from elsewhere (import)
	SC_F=${2:-"$SC_DIR/$1.sch"}; [ -f "$SC_F" ] || return 1
	SC_ID=$1; SC_NAME=""; SC_ON=0; SC_BASE=open; SC_HOL=0; SC_VER=0; SC_LWD=0; SC_LWE=0; SC_LMODE=block; SC_CATON=""; SC_GEO=""; SC_SAFE=0
	_slt=$(tr -d '\r' < "$SC_F" 2>/dev/null)
	while IFS= read -r _sl; do
		case "$_sl" in
			name=*)       [ -n "$SC_NAME" ] || SC_NAME=${_sl#name=} ;;
			enabled=1)    SC_ON=1 ;;
			base=open|base=limited|base=closed) SC_BASE=${_sl#base=} ;;
			hol=*)        sc_num SC_HOL "${_sl#hol=}" 0 ;;
			# ≤ 15 digits: a JS number past 2^53 came back to the router another number, and every save was refused as stale
			ver=*)        sc_num SC_VER "${_sl#ver=}" 0; [ "${#SC_VER}" -le 15 ] || SC_VER=1 ;;
			lim_wd=*)     sc_num SC_LWD "${_sl#lim_wd=}" 0 ;;
			lim_we=*)     sc_num SC_LWE "${_sl#lim_we=}" 0 ;;
			lmode=block|lmode=allow) SC_LMODE=${_sl#lmode=} ;;
			safe=1)       SC_SAFE=1 ;;
			cat=*)        sc_cat_ok "${_sl#cat=}" && case " $SC_CATON " in *" ${_sl#cat=} "*) ;; *) SC_CATON="${SC_CATON:+$SC_CATON }${_sl#cat=}" ;; esac ;;
			geo=*)        sc_geo_ok "${_sl#geo=}" && case " $SC_GEO " in *" ${_sl#geo=} "*) ;; *) SC_GEO="${SC_GEO:+$SC_GEO }${_sl#geo=}" ;; esac ;;
		esac
	done <<EOF
$_slt
EOF
	# own sites: `site=` lines, the same form a save writes (lowercase host names, each once) — a hand edit loads what is valid
	SC_SITES=$(printf '%s\n' "$_slt" | awk -v max="$SC_SITE_MAX" '
		/^site=/ { d = substr($0, 6)
		  if (d ~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/ && !(d in s) && n < max) { s[d] = 1; n++; print d } }')
	# own addresses: `addr=` lines — a v4 or v6 address/CIDR as a save writes it (bogons were cut there)
	SC_ADDRS=$(printf '%s\n' "$_slt" | awk -v max="$SC_SITE_MAX" '
		/^addr=/ { a = substr($0, 6)
		  if ((a ~ /^[0-9][0-9]?[0-9]?(\.[0-9][0-9]?[0-9]?)(\.[0-9][0-9]?[0-9]?)(\.[0-9][0-9]?[0-9]?)(\/[0-9][0-9]?)?$/ || a ~ /^[23][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f:]*(\/[0-9][0-9]?[0-9]?)?$/) && !(a in s) && n < max) { s[a] = 1; n++; print a } }')
	# …and their VALUES by the save's own judges (octets, masks, the v6 form): the awk above is the shape only, and a hand-edited or
	# imported «1.2.300.4» would stop the restore of the set that carries Telegram's network too (review s.112, round 2)
	if [ -n "$SC_ADDRS" ]; then
		command -v cidr4_ok >/dev/null 2>&1 || { if [ -f "$ENODIA_DIR/lists-lib.sh" ]; then . "$ENODIA_DIR/lists-lib.sh"; fi; }
		if command -v cidr4_ok >/dev/null 2>&1 && command -v norm_cidr6 >/dev/null 2>&1; then
			SC_ADDRS=$( { printf '%s\n' "$SC_ADDRS" | grep -v ':' | cidr4_ok; printf '%s\n' "$SC_ADDRS" | grep ':' | norm_cidr6; } | grep .)
		fi
	fi
	[ "$(set -- $SC_GEO; echo $#)" -le "$SC_POOL_MAX" ] || SC_GEO=$(printf '%s\n' $SC_GEO | head -n "$SC_POOL_MAX" | tr '\n' ' ' | sed 's/ $//')
	[ "$SC_LWD" -le 1440 ] || SC_LWD=0; [ "$SC_LWE" -le 1440 ] || SC_LWE=0
	# capped as a save caps them (SC_WIN_MAX, SC_DEV_MAX below): an imported file of thousands of windows held every tick's lock
	# for minutes (the change walk is quadratic) and hung the panel's list (review s.113, round 5)
	SC_WINS=$(printf '%s\n' "$_slt" | awk "$SC_WIN_AWK" | head -n "$SC_WIN_MAX")
	[ -n "$SC_WINS" ] && SC_WINS="$SC_WINS$SC_NL"
	# devices: `dev=mac:` lines, lowercase, valid, each once
	SC_DEVS=$(printf '%s\n' "$_slt" | awk -v max="$SC_DEV_MAX" '
		/^dev=mac:/ { m = tolower(substr($0, 9)); gsub(/[ \t]/, "", m)
		  if (m ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/ && !(m in s) && n < max) {
		    s[m] = 1; printf "%s%s", (n++ ? " " : ""), m } }')
	return 0
}
sc_name() { lbl_san "$SC_NAME" | cut -c1-200; }   # the loaded schedule's name, safe for JSON and the journal
sc_write() {   # sc_write <id> — from SC_*: atomically (write next to it, compare, mv)
	_wf="$SC_DIR/$1.sch"; _wt="$_wf.$$"
	{
		printf 'name=%s\nenabled=%s\nbase=%s\nhol=%s\nver=%s\nlim_wd=%s\nlim_we=%s\nlmode=%s\nsafe=%s\n' "$SC_NAME" "$SC_ON" "$SC_BASE" "$SC_HOL" "$SC_VER" "$SC_LWD" "$SC_LWE" "$SC_LMODE" "$SC_SAFE"
		printf '%s' "$SC_WINS" | while IFS= read -r _wl; do [ -n "$_wl" ] && printf 'win=%s\n' "$_wl"; done
		for _wm in $SC_DEVS; do printf 'dev=mac:%s\n' "$_wm"; done
		for _wm in $SC_CATON; do printf 'cat=%s\n' "$_wm"; done
		for _wm in $SC_GEO; do printf 'geo=%s\n' "$_wm"; done
		for _wm in $SC_SITES; do printf 'site=%s\n' "$_wm"; done
		for _wm in $SC_ADDRS; do printf 'addr=%s\n' "$_wm"; done
	} > "$_wt" 2>/dev/null || { rm -f "$_wt"; return 1; }
	grep -q "^ver=$SC_VER\$" "$_wt" && mv -f "$_wt" "$_wf" && return 0
	rm -f "$_wt"; return 1
}
sc_new_id() {   # under the lock: the highest id ever given (`.last-id`) + 1 — never a deleted one's
	sc_num _ln "$(cat "$SC_DIR/.last-id" 2>/dev/null | tr -cd '0-9')" 0
	for _li in $(sc_ids); do _lv=${_li#s}; [ "$_lv" -gt "$_ln" ] && _ln=$_lv; done
	_ln=$((_ln + 1))
	# a counter at its end (a crafted backup: `.last-id` 999999) — the lowest free number: s1000000 could be neither edited nor
	# deleted (id_ok); and never a number whose file is there (review s.113, round 5: an archive's `010` overwrote s9)
	[ "$_ln" -le 999999 ] || _ln=1
	while [ -f "$SC_DIR/s$_ln.sch" ]; do _ln=$((_ln + 1)); done
	echo "$_ln" > "$SC_DIR/.last-id" 2>/dev/null
	echo "s$_ln"
}
# action over one schedule: «<state> <until epoch, 0 = until cancelled> <kind> [<state> <until> <kind>]»; over all: «<until>».
# The optional second triple is the hand CLOSE an «open for…» was laid over: when the open expires the close is back — «Закрыть…
# пока не откроете», then «Открыть на 15 мин» must close again after 15 minutes, not hand the device to the week (review s.112).
sc_ovr_ok() {   # <state> <until> <kind> -> 0 = a live action
	case "$1" in open|limited|closed) ;; *) return 1 ;; esac
	case "$2" in ''|*[!0-9]*) return 1 ;; esac
	case "$3" in close|open|postpone) ;; *) return 1 ;; esac
	[ "$2" = 0 ] && [ "$1" != closed ] && return 1           # only a close may last until cancelled
	[ "$2" != 0 ] && [ "$2" -le "$SC_E" ] && return 1        # expired
	return 0
}
sc_ovr_get() {   # <id> -> SC_OS SC_OU SC_OK, SC_OB = 1 when a close comes back after it (empty SC_OS = none or expired)
	SC_OS=""; SC_OU=0; SC_OK=""; SC_OB=0; SC_PB=""; SC_PBU=0
	[ -f "$SC_DIR/$1.ovr" ] || return 1
	read -r _os _ou _ok _ps _pu _pk < "$SC_DIR/$1.ovr" 2>/dev/null
	if sc_ovr_ok "$_os" "$_ou" "$_ok"; then
		SC_OS=$_os; SC_OU=$_ou; SC_OK=$_ok
		[ "$_ps" = closed ] && sc_ovr_ok "$_ps" "$_pu" "$_pk" && { SC_OB=1; SC_PB="$_ps $_pu $_pk"; SC_PBU=$_pu; }
		return 0
	fi
	[ "$_ps" = closed ] && sc_ovr_ok "$_ps" "$_pu" "$_pk" || return 1
	SC_OS=$_ps; SC_OU=$_pu; SC_OK=$_pk
	return 0
}
sc_all_get() {   # -> SC_AU (until; 0 = until cancelled); rc 1 = not active
	SC_AU=""
	[ -f "$SC_DIR/.all" ] || return 1
	read -r _au < "$SC_DIR/.all" 2>/dev/null
	case "$_au" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_au" != 0 ] && [ "$_au" -le "$SC_E" ] && return 1
	SC_AU=$_au; return 0
}

# ---- evaluator ----------------------------------------------------------------------------------------------------
# From SC_WINS, SC_BASE and the minute of the week -> SC_CUR (state by the week alone), SC_INWIN (1 = a window decides) and
# SC_CHG («<minutes ahead> <state>» per line, the next $1 changes). Minutes of the week 0..10079, Sunday 00:00 = 0; a window
# may end past 10080 (Saturday night) — coverage is checked at t and t+week. Change points are window edges; the state is
# re-evaluated at each, and only real changes are reported (adjacent windows of one state are one stretch).
sc_eval() {
	_sev=$(printf '%s' "$SC_WINS" | awk -v base="$SC_BASE" -v now="$SC_NM" -v K="${1:-1}" '
	BEGIN { rk["open"] = 0; rk["limited"] = 1; rk["closed"] = 2; nm[0] = "open"; nm[1] = "limited"; nm[2] = "closed"; n = 0; W = 10080 }
	NF == 4 && ($4 in rk) {
		a = substr($2, 1, 2) * 60 + substr($2, 4, 2); b = substr($3, 1, 2) * 60 + substr($3, 4, 2)
		len = (b > a) ? b - a : 1440 - a + b
		for (i = 1; i <= length($1); i++) { d = substr($1, i, 1) + 0; n++; S[n] = d * 1440 + a; E[n] = S[n] + len; R[n] = rk[$4] }
	}
	END {
		b0 = (base in rk) ? rk[base] : 0
		st = -1
		for (j = 1; j <= n; j++) if ((now >= S[j] && now < E[j]) || (now + W >= S[j] && now + W < E[j])) { if (R[j] > st) st = R[j] }
		inw = (st >= 0) ? 1 : 0; if (st < 0) st = b0
		print "cur " nm[st] " " inw
		m = 0
		for (j = 1; j <= n; j++) {
			o = (S[j] - now) % W; if (o <= 0) o += W; m++; P[m] = o
			o = (E[j] - now) % W; if (o <= 0) o += W; m++; P[m] = o
		}
		prev = st; last = 0; out = 0
		while (out < K) {
			best = W + 1
			for (q = 1; q <= m; q++) if (P[q] > last && P[q] < best) best = P[q]
			if (best > W) break
			last = best; t = (now + best) % W; s2 = -1
			for (j = 1; j <= n; j++) if ((t >= S[j] && t < E[j]) || (t + W >= S[j] && t + W < E[j])) { if (R[j] > s2) s2 = R[j] }
			if (s2 < 0) s2 = b0
			if (s2 != prev) { print "chg " best " " nm[s2]; prev = s2; out++ }
		}
	}')
	SC_CUR=open; SC_INWIN=0; SC_CHG=""
	_sevl=$(printf '%s\n' "$_sev" | sed -n 's/^cur //p')
	set -- $_sevl; case "$1" in open|limited|closed) SC_CUR=$1 ;; esac; [ "${2:-0}" = 1 ] && SC_INWIN=1
	SC_CHG=$(printf '%s\n' "$_sev" | sed -n 's/^chg //p')
}
# Is our tick in the crontab (header)? One read per process; a commented line is not a line.
sc_ticking() {
	if [ -z "${SC_TK:-}" ]; then if grep -qE '^[^#]*access-sched\.sh tick' "$SC_CRONTAB" 2>/dev/null; then SC_TK=1; else SC_TK=0; fi; fi
	[ "$SC_TK" = 1 ]
}
# The effective state of the loaded schedule NOW: SC_ST + SC_WHY (stop|off|all|hol|ovr|win|base). Needs sc_now + sc_eval.
# «Закрыть всем» stands above holidays: a pause «for every device of every schedule» that skipped the resting ones would lie
# (review s.112); a switched-off schedule closes nothing, not even then.
sc_effective() {
	SC_ST=open; SC_WHY=base
	if ! sc_ticking; then SC_WHY=stop; return 0; fi
	if [ "$SC_ON" != 1 ]; then SC_WHY=off; return 0; fi
	if sc_all_get; then SC_ST=closed; SC_WHY=all; return 0; fi
	if [ "$SC_HOL" -gt "$SC_E" ] 2>/dev/null; then SC_WHY=hol; return 0; fi
	if sc_ovr_get "$SC_ID"; then SC_ST=$SC_OS; SC_WHY=ovr; return 0; fi
	SC_ST=$SC_CUR
	if [ "$SC_INWIN" = 1 ]; then SC_WHY=win; else SC_WHY=base; fi
}
# epoch of the first upcoming change of the week (empty = the week never changes)
sc_first_change() { _fc=$(printf '%s\n' "$SC_CHG" | awk 'NF==2{print $1; exit}'); [ -n "$_fc" ] && echo $(( SC_E0 + _fc * 60 )); }

# ---- day limit: usage ---------------------------------------------------------------------------------------------
sc_lim_today() { if [ "$SC_W" -ge 1 ] && [ "$SC_W" -le 5 ]; then SC_LT=$SC_LWD; else SC_LT=$SC_LWE; fi; }   # weekdays / weekend
# Does today's limit act now? Only while the WEEK decides (holidays rest it, a hand action beats it) and nothing closes anyway.
# A postpone is not a hand «open»: it moves the week's closing by minutes, the day's limit keeps counting under it.
sc_lim_applies() { [ "$SC_LT" -gt 0 ] && [ "$SC_ST" != closed ] && { [ "$SC_WHY" = win ] || [ "$SC_WHY" = base ] || { [ "$SC_WHY" = ovr ] && [ "$SC_OK" = postpone ]; }; }; }
# The day's usage -> SC_USED («<mac> <minutes>» lines): RAM first (fresh), the flash copy after a reboot; another date = none yet.
sc_use_load() {
	SC_USED=""
	for _uf in "$SC_USE" "$SC_DIR/.use"; do
		[ -f "$_uf" ] || continue
		[ "$(head -n 1 "$_uf" 2>/dev/null)" = "$SC_D" ] || continue
		SC_USED=$(sed 1d "$_uf" 2>/dev/null); return 0
	done
	return 0
}
sc_used_of() { printf '%s\n' "$SC_USED" | awk -v m="$1" '$1 == m { print $2 + 0; f = 1; exit } END { if (!f) print 0 }'; }
# trafficd -> «<mac>@<address> <bytes in+out>» per ADDRESS of a device (MAC lowercase). The counters pass 32 bits: awk's
# doubles, printed as integers. trafficd is parsed by ONE owner (traffic-dev.sh snap). Per address, not per MAC: an address ages
# out of trafficd's list, a per-MAC sum then FALLS, and «went back ⇒ counted from zero» made an idle device's minute active
# (review s.115, round 1 — the same ladder as traffic-dev.sh's, fixed there first).
sc_traffic() {
	[ -f "$ENODIA_DIR/traffic-dev.sh" ] || return 0
	sh "$ENODIA_DIR/traffic-dev.sh" snap 2>/dev/null | awk -F'\t' '{ printf "%s@%s %.0f\n", $1, $2, $3 + $4 }'
}
# Save the day's usage to the flash: every SC_USE_SAVE while it changes, at once when $1 = now (a device just ran out — a
# reboot must not hand it a new day).
sc_use_save() {
	[ -f "$SC_USE" ] || return 0
	_usv=$(cat "$SC_RUN/use.saved" 2>/dev/null); case "$_usv" in ''|*[!0-9]*) _usv=0 ;; esac
	[ "${1:-}" = now ] || [ $(( SC_E - _usv )) -ge "$SC_USE_SAVE" ] || return 0   # clock-raw: both are this boot's synced clock
	sc_same "$SC_USE" "$SC_DIR/.use" && return 0
	mkdir -p "$SC_DIR" 2>/dev/null
	cp "$SC_USE" "$SC_DIR/.use.$$" 2>/dev/null && mv -f "$SC_DIR/.use.$$" "$SC_DIR/.use" && echo "$SC_E" > "$SC_RUN/use.saved"
	rm -f "$SC_DIR/.use.$$" 2>/dev/null
	return 0
}
# One sample per tick, only for the devices of enabled schedules with a limit today. A minute counts when the device moved at
# least SC_ACTIVE_B per minute of the gap since the previous sample (the gap capped at SC_USE_GAP: a stalled tick must neither
# grant nor take an hour). A device's first sample only records; a counter that went back (trafficd restarted, the device
# came back) counts from zero. Two ticks within one minute: the second waits — its delta belongs to the next one.
# A device the kernel kept CLOSED through the minute (the plan in SC_APPLIED — this tick has not replanned yet) does not count:
# trafficd counts every byte the station moves, retries into a REJECT and the home network too (BE7000 08.10.2026: a phone
# closed by its limit went 4 → 6 «minutes in the internet» in a quarter of an hour). A limited one is partly out — it counts.
sc_use_tick() {
	_um=""
	for _ui in $SC_IDS; do
		sc_load "$_ui" || continue
		[ "$SC_ON" = 1 ] || continue
		sc_lim_today; [ "$SC_LT" -gt 0 ] || continue
		_um="$_um $SC_DEVS"
	done
	if [ -z "$_um" ]; then rm -f "$SC_USE_LAST" 2>/dev/null; return 0; fi
	sc_use_load
	_upe=$(head -n 1 "$SC_USE_LAST" 2>/dev/null); case "$_upe" in ''|*[!0-9]*) _upe=0 ;; esac
	_uel=0
	if [ "$_upe" -gt 0 ]; then
		_uel=$(( (SC_E - _upe + 30) / 60 ))   # clock-raw: two samples of this boot's synced clock
		if [ "$_uel" -lt 0 ]; then _uel=0       # the clock went back: resync the sample, count nothing
		elif [ "$_uel" = 0 ]; then return 0     # the same minute: its delta belongs to the next tick
		fi
	fi
	_ucur=$(sc_traffic)
	[ -n "$_ucur" ] || return 0      # trafficd silent: nothing counted (an unknown minute is not an active one)
	_uout=$( {
		for _uk in $_um; do echo "L $_uk"; done
		printf '%s\n' "$SC_USED" | sed -n 's/^\([0-9a-f:]* [0-9]*\)$/U \1/p'
		sed -n '2,$s/^/P /p' "$SC_USE_LAST" 2>/dev/null
		printf '%s\n' "$_ucur" | sed 's/^/C /'
		awk '$2 == "closed" { print "X " $1 }' "$SC_APPLIED" 2>/dev/null
	} | awk -v el="$_uel" -v gap="$SC_USE_GAP" -v act="$SC_ACTIVE_B" '
		$1 == "L" { lim[$2] = 1; next }
		$1 == "X" { x[$2] = 1; next }
		$1 == "U" { u[$2] = $3 + 0; next }
		$1 == "P" { p[$2] = $3 + 0; next }
		$1 == "C" { c[$2] = $3 + 0; next }
		END {
			m = el; if (m > gap) m = gap
			# per address (the MAC is the first 17 characters of the key): an address seen before adds its delta, a new one
			# only records (its first sample), one gone from trafficd adds nothing
			for (k in c) { mac = substr(k, 1, 17); if (!(mac in lim)) continue
				printf "C %s %.0f\n", k, c[k]
				if (k in p) { d = c[k] - p[k]; if (d < 0) d = c[k]; D[mac] += d; seen[mac] = 1 } }
			for (mac in seen) if (m >= 1 && !(mac in x) && D[mac] >= act * m) u[mac] += m
			for (k in u) if (u[k] > 0) printf "U %s %d\n", k, u[k]
		}')
	{ echo "$SC_E"; printf '%s\n' "$_uout" | sed -n 's/^C //p'; } > "$SC_USE_LAST.$$" && mv -f "$SC_USE_LAST.$$" "$SC_USE_LAST"
	_unew=$(printf '%s\n' "$_uout" | sed -n 's/^U //p' | sort)
	if [ "$_unew" != "$(printf '%s\n' "$SC_USED" | grep . | sort)" ] || [ "$(head -n 1 "$SC_USE" 2>/dev/null)" != "$SC_D" ]; then
		# `[ -z ] ||`, not `[ -n ] &&`: the group's status is its last command's — nobody's minutes yet would fail the write,
		# skip the mv and leave a temp file in RAM on every tick until the first active minute (BE7000, 08.10.2026)
		{ echo "$SC_D"; [ -z "$_unew" ] || printf '%s\n' "$_unew"; } > "$SC_USE.$$" && mv -f "$SC_USE.$$" "$SC_USE"
	fi
	SC_USED=$_unew
	sc_use_save
}

# ---- kernel -------------------------------------------------------------------------------------------------------
# The plan: every device of an enabled schedule whose state is not open — «<mac> <state> <id>», sorted (stable comparison); an
# open device of a schedule with safe search is «safe» (header).
# A device whose day limit ran out is closed till the end of the day — but only while the WEEK decides (a window or the base
# state): holidays rest the limit too, and an «open for…» by hand beats it («добавляет время»). SC_OVER — «<mac> <id>» of those.
sc_plan() {
	SC_PLAN=""; SC_OVER=""
	clock_trusted || return 0
	sc_ticking || return 0
	sc_use_load
	for _pi in $(sc_ids); do
		sc_load "$_pi" || continue
		[ "$SC_ON" = 1 ] && [ -n "$SC_DEVS" ] || continue
		sc_eval 1; sc_effective; sc_lim_today
		_plm=0; sc_lim_applies && _plm=1
		[ "$SC_ST" = open ] && [ "$_plm" = 0 ] && [ "$SC_SAFE" != 1 ] && continue
		for _pm in $SC_DEVS; do
			_ps=$SC_ST
			if [ "$_plm" = 1 ] && [ "$(sc_used_of "$_pm")" -ge "$SC_LT" ]; then _ps=closed; SC_OVER="$SC_OVER$_pm $_pi$SC_NL"; fi
			[ "$_ps" = open ] && [ "$SC_SAFE" = 1 ] && _ps=safe
			[ "$_ps" = open ] && continue
			SC_PLAN="$SC_PLAN$_pm $_ps $_pi$SC_NL"
		done
	done
	SC_PLAN=$(printf '%s' "$SC_PLAN" | sort)
}
# rules of one family into the chain (the chain exists and is empty). $1 = iptables|ip6tables
sc_fam() { if [ "$1" = ip6tables ]; then echo 6; else echo 4; fi; }
sc_fill() {
	"$1" -A "$SC_CHAIN" -o br+ -j RETURN 2>/dev/null || return 1
	_kfm=$(sc_fam "$1")
	printf '%s\n' "$SC_PLAN" | while read -r _km _ks _ki; do
		[ -n "$_km" ] || continue
		# limited, by the filter: only encrypted DNS (DoT/DoQ, 853) is refused here — a device that falls back from it asks
		# plain DNS, and that is REDIRECTed to the filter. Without ip6 nat its IPv6 cannot be steered: closed whole (header).
		# Two rules per device in every form, two more per address set of a limited one — sc_rules_n counts that.
		_kf=$_ks; [ "$_ks" = limited ] && [ "$1" = ip6tables ] && [ "$SC_NAT6" != 1 ] && _kf=closed
		case "$_kf" in
			closed)
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -j REJECT 2>/dev/null ;;
			limited)
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p udp --dport 853 -j REJECT 2>/dev/null
				# the schedule's categories closed by address too (messengers dialling their own addresses — header)
				for _kst in $(printf '%s\n' "$SC_ASETS" | awk -v i="$_ki" -v f="$_kfm" '$1 == i && $2 == f { print $3 }'); do
					"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -m set --match-set "$_kst" dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null
					"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -m set --match-set "$_kst" dst -j REJECT 2>/dev/null
				done ;;
			safe)   # safe search only: its DNS goes to the filter (nat), encrypted DNS refused — nothing else is closed
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null
				"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p udp --dport 853 -j REJECT 2>/dev/null ;;
		esac
		# v6 plain DNS to OUTSIDE resolvers of a captured device: refused — without ip6 nat nothing of v6 is steered, with it only
		# the private sources are (sc_nat_put); a public v6 resolver would answer the real Google past safe search, or a category
		# past «limited». A limited device without ip6 nat is closed whole in v6 already. It falls back to v4, where the REDIRECT stands.
		if [ "$1" = ip6tables ] && { [ "$_ks" = safe ] || { [ "$_ks" = limited ] && [ "$SC_NAT6" = 1 ]; }; }; then
			"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p tcp --dport 53 -j REJECT --reject-with tcp-reset 2>/dev/null
			"$1" -A "$SC_CHAIN" -m mac --mac-source "$_km" -p udp --dport 53 -j REJECT 2>/dev/null
		fi
	done
	return 0
}
sc_rules_n() {   # $1 = 4|6 — rules the plan makes in that family: the home RETURN, two per device, two per address set of a limited
	# one, two more for a captured one in v6 (plain DNS to outside resolvers refused: «safe» always, «limited» with ip6 nat)
	{ printf '%s\n' "$SC_ASETS" | sed 's/^/A /'; printf '%s\n' "$SC_PLAN" | sed 's/^/P /'; } | awk -v f="$1" -v n6="$SC_NAT6" '
		$1 == "A" && NF == 4 { if ($3 == f) a[$2] += 2; next }
		$1 == "P" && NF == 4 { n += 2; if ($3 == "limited" && (f == 4 || n6 == 1)) n += a[$4]
			if (f == 6 && ($3 == "safe" || ($3 == "limited" && n6 == 1))) n += 2 }
		END { print n + 1 }'
}
# Is the plan's form standing in the kernel of one family? Jump in FORWARD + the expected count of rules in the chain.
sc_wired() {   # $1 = iptables|ip6tables -> 0 standing, 1 not
	"$1" -C FORWARD -j "$SC_CHAIN" 2>/dev/null || return 1
	[ "$("$1" -S "$SC_CHAIN" 2>/dev/null | grep -c '^-A ' || true)" = "$(sc_rules_n "$(sc_fam "$1")")" ]
}
sc_drop_fam() {   # $1 = iptables|ip6tables — jump(s) and chain away
	_dn=0; while "$1" -D FORWARD -j "$SC_CHAIN" 2>/dev/null; do _dn=$((_dn + 1)); [ "$_dn" -ge 8 ] && break; done
	"$1" -F "$SC_CHAIN" 2>/dev/null; "$1" -X "$SC_CHAIN" 2>/dev/null
	return 0
}
sc_put_fam() {   # $1 = iptables|ip6tables
	"$1" -N "$SC_CHAIN" 2>/dev/null || "$1" -F "$SC_CHAIN" 2>/dev/null || return 1
	sc_fill "$1" || return 1
	# at the TOP: every forwarded packet of the house passes here before any ACCEPT (fw3 accepts ESTABLISHED early, and the
	# stock `--physdev-is-bridged -j ACCEPT` sits high); ipt-lib.sh::ipt_top puts our ACCEPTs below the block chains
	"$1" -C FORWARD -j "$SC_CHAIN" 2>/dev/null || "$1" -I FORWARD 1 -j "$SC_CHAIN" 2>/dev/null
}
# addresses a MAC holds now (both families; neighbour table first, the lease too — a device that just woke up)
sc_mac_ips() {
	ip neigh show 2>/dev/null | awk -v m="$1" '$4 == "lladdr" && tolower($5) == m && $NF != "FAILED" && $NF != "INCOMPLETE" { print $1 }'
	command -v lease_ip_of_mac >/dev/null 2>&1 && lease_ip_of_mac "$1"
	return 0
}
# Converge the kernel to SC_PLAN. Rebuild only when the plan changed or the form is gone (a firewall reload); flows of devices
# whose state changed are dropped AFTER the rules stand (dropped before, the next packet would be offloaded again unjudged).
# a record of what stands: a file per non-empty plan, NONE for an empty one (cmd_tick's cheap exit is «no schedules, no record»;
# a file of one empty line kept every minute's tick full after the last schedule was deleted)
sc_arec1() {   # <file> <content>
	if [ -n "$2" ]; then printf '%s\n' "$2" > "$1.$$" && mv -f "$1.$$" "$1"; else rm -f "$1"; fi
}
sc_apply() {
	_aold=$(cat "$SC_APPLIED" 2>/dev/null); _anold=$(cat "$SC_APPLIED.nat" 2>/dev/null); _asold=$(cat "$SC_APPLIED.sets" 2>/dev/null)
	sc_nplan
	SC_NAT6=0
	if [ -n "$SC_NPLAN" ] && have_nat6; then SC_NAT6=1; fi
	_achg=0; _amiss=0
	# a JUMP gone = a reload wiped the form: flows opened in the gap are offloaded past it (NSS/ECM) — every device of the plan is
	# flushed. Only then: a count that differs (a foreign rule put above our accept, a rule the kernel does not take) is rebuilt
	# without a flush — flushed, a «safe» device lost its calls every minute (review s.112, round 2)
	# Probed only while there is a form to judge: nobody closed = no iptables call at all (the header's promise)
	_ajf=0; [ -z "$SC_PLAN" ] || iptables -C FORWARD -j "$SC_CHAIN" 2>/dev/null || _ajf=1
	_ajn=0; [ -z "$SC_NPLAN" ] || iptables -t nat -C PREROUTING -j "$SC_NAT" 2>/dev/null || _ajn=1
	_aput=0; _anput=0
	# A RECORD AHEAD OF ITS RULES IS A PROMISE until they stand (below): a tick killed in between left a record naming a plan the
	# kernel never got — the same count of rules, other MACs (the day limit moved from A to B) — and the next tick saw plan = record
	# and kept A closed, B open (review s.113, round 4). The mark goes down with the record and up after the rules; found here,
	# the record is not trusted: the form is rebuilt and every device of the plan flushed.
	_apend=0; [ -f "$SC_APPLIED.pend" ] && { _apend=1; _amiss=1; }
	if [ -n "$SC_PLAN" ] && { [ "$_apend" = 1 ] || [ "$SC_PLAN" != "$_aold" ] || [ "$SC_ASETS" != "$_asold" ] || ! sc_wired iptables || { have_v6 && ! sc_wired ip6tables; }; }; then
		_aput=1
		# the plan the same and the form gone = a firewall reload wiped it: flows opened in the gap are offloaded past the
		# REJECT now (NSS/ECM), so every device of the plan is flushed, not only the changed ones (review s.112)
		[ "$SC_PLAN" = "$_aold" ] && [ "$SC_ASETS" = "$_asold" ] && [ "$_ajf" = 1 ] && _amiss=1
	fi
	if [ -n "$SC_NPLAN" ] && { [ "$_apend" = 1 ] || [ "$SC_NPLAN" != "$_anold" ] || ! sc_cap_wired; }; then
		_anput=1
		[ "$SC_NPLAN" = "$_anold" ] && [ "$_ajn" = 1 ] && _amiss=1   # wiped as above: a DNS flow to 8.8.8.8 opened in the gap keeps its old NAT
	fi
	# THE RECORD BEFORE THE KERNEL: a tick killed between putting the form and writing its record (OOM, an unwire that gave up on
	# the lock) left a form no record named — an empty plan then never took it down, a device closed till the reboot (review s.112,
	# round 3). A record is only ever written AHEAD of rules it names and removed AFTER the rules it names are gone.
	if [ "$_aput" = 1 ] || [ "$_anput" = 1 ]; then : > "$SC_APPLIED.pend"; fi
	[ "$_aput" = 1 ] && sc_arec1 "$SC_APPLIED" "$SC_PLAN"
	[ "$_anput" = 1 ] && sc_arec1 "$SC_APPLIED.nat" "$SC_NPLAN"
	if [ -z "$SC_PLAN" ]; then
		if [ -n "$_aold" ]; then sc_drop_fam iptables; if have_v6; then sc_drop_fam ip6tables; fi; _achg=1; fi
	elif [ "$_aput" = 1 ]; then
		sc_put_fam iptables; if have_v6; then sc_put_fam ip6tables; fi; _achg=1
	fi
	# address sets no rule refers to any more go AFTER the chains are rebuilt (a referenced set cannot be destroyed)
	[ "$SC_ASETS" = "$_asold" ] || { sc_aset_gc; _achg=1; }
	# the DNS of limited devices to their filter profile (a separate plan: a profile's port may change while the state does not)
	if [ -z "$SC_NPLAN" ]; then
		if [ -n "$_anold" ]; then sc_cap_drop; _achg=1; fi
	elif [ "$_anput" = 1 ]; then
		sc_cap_put; _achg=1
	fi
	rm -f "$SC_APPLIED.pend"
	[ "$_achg" = 1 ] || return 0
	sc_arec1 "$SC_APPLIED" "$SC_PLAN"; sc_arec1 "$SC_APPLIED.nat" "$SC_NPLAN"; sc_arec1 "$SC_APPLIED.sets" "$SC_ASETS"
	# devices whose line changed (new, gone, other state, another filter port): only a stricter state needs the flush, but
	# opening is rare and a flush there is harmless — one rule, no second copy of «stricter». The filter needs it as much as
	# REJECT does: a device's DNS flow to 8.8.8.8 that exists already keeps its old NAT decision.
	{ printf '%s\n' "$_aold"; printf '%s\n' "$SC_PLAN"; } | awk 'NF==3' | sort | uniq -u | awk '{print $1}' > "$SC_RUN/chg.$$"
	{ printf '%s\n' "$_anold"; printf '%s\n' "$SC_NPLAN"; } | awk 'NF==2' | sort | uniq -u | awk '{print $1}' >> "$SC_RUN/chg.$$"
	# …and the devices of a schedule whose address sets changed (a category added: an open Telegram flow is offloaded otherwise)
	{ { printf '%s\n' "$_asold"; printf '%s\n' "$SC_ASETS"; } | awk 'NF==3' | sort | uniq -u | awk '{print "I", $1}'
	  printf '%s\n' "$SC_PLAN" | awk 'NF==3 {print "P", $1, $3}'; } | awk '$1 == "I" { c[$2] = 1; next } $1 == "P" && ($3 in c) { print $2 }' >> "$SC_RUN/chg.$$"
	[ "$_amiss" = 1 ] && { printf '%s\n' "$SC_PLAN" | awk 'NF==3 {print $1}'; printf '%s\n' "$SC_NPLAN" | awk 'NF==2 {print $1}'; } >> "$SC_RUN/chg.$$"
	sort -u "$SC_RUN/chg.$$" | while read -r _am; do
		for _aip in $(sc_mac_ips "$_am" | sort -u); do ct_flush_src "$_aip"; done
	done
	rm -f "$SC_RUN/chg.$$"
	return 0
}

# ---- «ОГРАНИЧЕНО» by address: a set per schedule and family (header) ------------------------------------------------------
# SC_AFILES (sc_fconf): «<id> <4|6> <file>» — geo's ready address forms of the keys the schedule closes by address, and its own
# addresses; out: SC_ASETS «<id> <4|6> <set>» for the sets that stand. A family without data has no set and no rule.
sc_aset_name() { if [ "$2" = 6 ]; then echo "enodia_sch6_$1"; else echo "enodia_sch_$1"; fi; }   # <id> <4|6>
sc_aset_sync() {
	SC_ASETS=""
	[ -n "$SC_AFILES" ] || return 0
	command -v set_sync >/dev/null 2>&1 || return 0
	for _asi in $(printf '%s\n' "$SC_AFILES" | awk 'NF == 3 { print $1 }' | sort -u); do
		for _asf in 4 6; do
			[ "$_asf" = 6 ] && ! have_v6 && continue
			_ass=$(sc_aset_name "$_asi" "$_asf")
			printf '%s\n' "$SC_AFILES" | awk -v i="$_asi" -v f="$_asf" 'NF == 3 && $1 == i && $2 == f { print $3 }' |
				while read -r _asp; do cat "$_asp" 2>/dev/null; done | sort -u > "$SC_RUN/aset.$$"
			SET_FAMILY=inet; [ "$_asf" = 6 ] && SET_FAMILY=inet6
			if [ -s "$SC_RUN/aset.$$" ] && set_sync "$_ass" "$SC_RUN/aset.$$"; then SC_ASETS="$SC_ASETS$_asi $_asf $_ass$SC_NL"; fi
			SET_FAMILY=""
			rm -f "$SC_RUN/aset.$$"
		done
	done
	SC_ASETS=$(printf '%s' "$SC_ASETS" | grep . | sort)
	return 0
}
sc_aset_gc() {   # our sets that SC_ASETS does not name (all of them with an empty SC_ASETS — unwire); set-lib.sh drops its snapshot too
	for _gs in $(ipset list -n 2>/dev/null | grep -E '^enodia_sch6?_[a-z0-9]+$'); do
		printf '%s\n' "$SC_ASETS" | awk -v s="$_gs" '$3 == s { f = 1 } END { exit !f }' && continue
		if command -v set_drop >/dev/null 2>&1; then set_drop "$_gs"; else ipset destroy "$_gs" 2>/dev/null; fi
	done
	return 0
}

# ---- «ОГРАНИЧЕНО»: the DNS of limited devices → the filter ------------------------------------------------------------
# ip6 nat present and not found unusable this boot (a REDIRECT the kernel refused — sc_nat_put marks it; the no-nat6 form then)
have_nat6() { have_v6 && [ ! -e "$SC_RUN/nat6.bad" ] && ip6tables -t nat -S PREROUTING >/dev/null 2>&1; }
# the capture plan: «<mac> <port>» per limited device whose schedule has a profile in the filter now (SC_FMAP)
sc_nplan() {
	SC_NPLAN=$( { printf '%s\n' "$SC_FMAP" | sed 's/^/M /'; printf '%s\n' "$SC_PLAN" | sed 's/^/P /'; } |
		awk '$1 == "M" && NF == 3 { p[$2] = $3; next } $1 == "P" && ($3 == "limited" || $3 == "safe") && ($4 in p) { print $2, p[$4] }' | sort)
}
sc_nat_put() {   # $1 = iptables|ip6tables — the chain refilled, the jump at the TOP of nat PREROUTING (above the stock guest DNAT);
	# the same DNS accepted at the top of INPUT (header: stock miot_input, zones without redirects)
	"$1" -t nat -N "$SC_NAT" 2>/dev/null || "$1" -t nat -F "$SC_NAT" 2>/dev/null || return 1
	"$1" -N "$SC_DNSIN" 2>/dev/null || "$1" -F "$SC_DNSIN" 2>/dev/null || return 1
	printf '%s\n' "$SC_NPLAN" | while read -r _nm _np; do
		[ -n "$_np" ] || continue
		if [ "$1" = ip6tables ]; then
			# v6: only from the device's PRIVATE addresses (ULA, link-local) — the filter answers private sources only (its second
			# lock against the WAN), and DNS from a GLOBAL address of a LAN with native IPv6 timed out there on every lookup. That
			# DNS is refused instead (below and in sc_fill): the device falls back at once to v4 or its private address, which are
			# REDIRECTed (review s.112, round 2). A REDIRECT the kernel cannot do (no target) marks ip6 nat unusable for this boot.
			for _ns in fc00::/7 fe80::/10; do
				"$1" -t nat -A "$SC_NAT" -m mac --mac-source "$_nm" -s "$_ns" -p udp --dport 53 -j REDIRECT --to-ports "$_np" 2>/dev/null &&
				"$1" -t nat -A "$SC_NAT" -m mac --mac-source "$_nm" -s "$_ns" -p tcp --dport 53 -j REDIRECT --to-ports "$_np" 2>/dev/null ||
					: > "$SC_RUN/nat6.bad"
			done
		else
			"$1" -t nat -A "$SC_NAT" -m mac --mac-source "$_nm" -p udp --dport 53 -j REDIRECT --to-ports "$_np" 2>/dev/null
			"$1" -t nat -A "$SC_NAT" -m mac --mac-source "$_nm" -p tcp --dport 53 -j REDIRECT --to-ports "$_np" 2>/dev/null
		fi
		"$1" -A "$SC_DNSIN" -m mac --mac-source "$_nm" -p udp --dport "$_np" -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null
		"$1" -A "$SC_DNSIN" -m mac --mac-source "$_nm" -p tcp --dport "$_np" -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null
		if [ "$1" = ip6tables ]; then   # plain DNS to the router from a global address: refused (the REDIRECTed one is not on 53)
			"$1" -A "$SC_DNSIN" -m mac --mac-source "$_nm" -p udp --dport 53 -j REJECT 2>/dev/null
			"$1" -A "$SC_DNSIN" -m mac --mac-source "$_nm" -p tcp --dport 53 -j REJECT --reject-with tcp-reset 2>/dev/null
		fi
	done
	# the filter's ports take only REDIRECTed DNS: sent straight to <LAN-IP>:539x, a device reached ANOTHER profile — a list-less
	# safe-search one of another schedule (review s.112, round 3); the tick's probe comes over lo
	"$1" -A "$SC_DNSIN" ! -i lo -p udp --dport "$SC_FPORT0:$((SC_FPORT0 + SC_MAX - 1))" -m conntrack ! --ctstate DNAT -j DROP 2>/dev/null
	"$1" -A "$SC_DNSIN" ! -i lo -p tcp --dport "$SC_FPORT0:$((SC_FPORT0 + SC_MAX - 1))" -m conntrack ! --ctstate DNAT -j DROP 2>/dev/null
	sc_dnsin_top "$1" || { _dn=0; while "$1" -D INPUT -j "$SC_DNSIN" 2>/dev/null; do _dn=$((_dn + 1)); [ "$_dn" -ge 8 ] && break; done
		"$1" -I INPUT 1 -j "$SC_DNSIN" 2>/dev/null; }
	"$1" -t nat -C PREROUTING -j "$SC_NAT" 2>/dev/null || "$1" -t nat -I PREROUTING 1 -j "$SC_NAT" 2>/dev/null
}
# the accept stands above every foreign INPUT rule: only our chains (ENODIA_*, «доступ домой» VPNSRV_*) may come before it — the
# stock miot_input that DROPs br-miot is put back by the firmware's own hooks, and a jump below it accepts nothing
sc_dnsin_top() {   # $1 = iptables|ip6tables
	"$1" -S INPUT 2>/dev/null | awk -v c="$SC_DNSIN" '$1 == "-A" { if ($0 ~ ("-j " c "$")) { f = 1; exit } if ($0 !~ /-j[ ](ENODIA_|VPNSRV_)[A-Z0-9_]*$/) exit } END { exit !f }'
}
sc_nat_drop() {   # $1 = iptables|ip6tables
	_dn=0; while "$1" -t nat -D PREROUTING -j "$SC_NAT" 2>/dev/null; do _dn=$((_dn + 1)); [ "$_dn" -ge 8 ] && break; done
	"$1" -t nat -F "$SC_NAT" 2>/dev/null; "$1" -t nat -X "$SC_NAT" 2>/dev/null
	_dn=0; while "$1" -D INPUT -j "$SC_DNSIN" 2>/dev/null; do _dn=$((_dn + 1)); [ "$_dn" -ge 8 ] && break; done
	"$1" -F "$SC_DNSIN" 2>/dev/null; "$1" -X "$SC_DNSIN" 2>/dev/null
	return 0
}
sc_nat_wired() {   # $1 = iptables|ip6tables — both jumps and the rules per device: two each (v4), four each (v6: two prefixes; the
	# accept and the refusal) — the kernel rewrites the text, we count
	"$1" -t nat -C PREROUTING -j "$SC_NAT" 2>/dev/null || return 1
	sc_dnsin_top "$1" || return 1
	_nwk=2; [ "$1" = ip6tables ] && _nwk=4
	_nwn=$(printf '%s\n' "$SC_NPLAN" | awk -v k="$_nwk" 'NF == 2 { n += k } END { print n + 0 }')
	[ "$("$1" -t nat -S "$SC_NAT" 2>/dev/null | grep -c '^-A ' || true)" = "$_nwn" ] || return 1
	[ "$("$1" -S "$SC_DNSIN" 2>/dev/null | grep -c '^-A ' || true)" = "$((_nwn + 2))" ]   # + the two drops of straight traffic
}
# without ip6 nat: the device's DNS to the router's own v6 addresses refused (its v6 FORWARD is closed whole in sc_fill)
sc_in6_put() {
	ip6tables -N "$SC_IN6" 2>/dev/null || ip6tables -F "$SC_IN6" 2>/dev/null || return 1
	printf '%s\n' "$SC_NPLAN" | while read -r _nm _np; do
		[ -n "$_np" ] || continue
		ip6tables -A "$SC_IN6" -m mac --mac-source "$_nm" -p udp --dport 53 -j REJECT 2>/dev/null
		ip6tables -A "$SC_IN6" -m mac --mac-source "$_nm" -p tcp --dport 53 -j REJECT --reject-with tcp-reset 2>/dev/null
	done
	ip6tables -C INPUT -j "$SC_IN6" 2>/dev/null || ip6tables -I INPUT 1 -j "$SC_IN6" 2>/dev/null
}
sc_in6_drop() {
	_dn=0; while ip6tables -D INPUT -j "$SC_IN6" 2>/dev/null; do _dn=$((_dn + 1)); [ "$_dn" -ge 8 ] && break; done
	ip6tables -F "$SC_IN6" 2>/dev/null; ip6tables -X "$SC_IN6" 2>/dev/null
	return 0
}
sc_in6_wired() {
	ip6tables -C INPUT -j "$SC_IN6" 2>/dev/null || return 1
	[ "$(ip6tables -S "$SC_IN6" 2>/dev/null | grep -c '^-A ' || true)" = "$(printf '%s\n' "$SC_NPLAN" | awk 'NF == 2 { n += 2 } END { print n + 0 }')" ]
}
sc_cap_put() {
	sc_nat_put iptables
	have_v6 || return 0
	if [ "$SC_NAT6" = 1 ]; then sc_nat_put ip6tables; sc_in6_drop; else sc_nat_drop ip6tables; sc_in6_put; fi
}
sc_cap_drop() {
	sc_nat_drop iptables
	if have_v6; then sc_nat_drop ip6tables; sc_in6_drop; fi
	return 0
}
sc_cap_wired() {
	sc_nat_wired iptables || return 1
	have_v6 || return 0
	if [ "$SC_NAT6" = 1 ]; then sc_nat_wired ip6tables; else sc_in6_wired; fi
}

# The daemon. One process for all profiles; it runs only while some device is limited NOW (RAM comes back after).
sc_fpid() { cat "$SC_FPID" 2>/dev/null | tr -cd '0-9'; }
sc_falive() { pid_runs "$(sc_fpid)" 'dns-filter'; }
sc_fstop() {
	_fsp=$(sc_fpid)
	if pid_runs "$_fsp" 'dns-filter'; then
		kill "$_fsp" 2>/dev/null
		if command -v daemon_wait_gone >/dev/null 2>&1; then daemon_wait_gone "$_fsp" 3; fi
	fi
	rm -f "$SC_FPID" "$SC_FDIR/sig" "$SC_FDIR/state" 2>/dev/null
	return 0
}
# The config the daemon RUNS is the one in $SC_FDIR/conf: it says so in its state file (DNS_FILTER_STATE, «ok <inode> <size>
# <mtime>» of the conf). The canary probe is answered by ANY config — the old one a refused reload kept (a list it could not
# read, no memory for both) too, and the new categories then never acted while the panel showed them (review s.112, round 2).
# A HUP is asynchronous: up to 3 s for the line. No state file at all = a binary older than 1.3 (it cannot say) — taken as applied.
sc_fapplied() {
	[ -e "$SC_FDIR/state" ] || return 0
	_fst=$(stat -c '%i %s %Y' "$SC_FDIR/conf" 2>/dev/null)
	_fsw=0; daemon_step_init
	while :; do
		case "$(cat "$SC_FDIR/state" 2>/dev/null)" in
			"ok $_fst") return 0 ;;
			"refused $_fst") return 1 ;;
		esac
		_fsw=$((_fsw + 1)); [ "$_fsw" -gt $((3 * DAEMON_STEP_Q)) ] && return 1
		daemon_step   # fixed-wait: the daemon is alive and reloading in its own loop — a reload, not a start
	done
}
sc_fstart() {   # $1 = a port of the config — 0 when it answers the probe
	# the log's clock: a static musl binary reads TZ from the environment only, and the router keeps it in /etc/TZ
	if [ -s /etc/TZ ]; then TZ=$(cat /etc/TZ 2>/dev/null); export TZ; fi
	DNS_FILTER_STATE="$SC_FDIR/state"; export DNS_FILTER_STATE
	start-stop-daemon -S -b -m -p "$SC_FPID" -x "$SC_FBIN" -- -c "$SC_FDIR/conf" -l "$SC_FLOG" >/dev/null 2>&1 || return 1
	daemon_wait_uport "$SC_FPID" dns-filter 5 0.0.0.0 "$1" || return 1
	"$SC_FBIN" -q "$1"
}
# The port of each profile: kept while the schedule exists, the lowest free one for a new profile. RAM: a reboot reassigns, and
# no device keeps a port across a reboot (its DNS flows go with the conntrack table). $1 = ids limited now → SC_FMAP for them.
sc_fports() {
	_fall=" $(sc_ids | tr '\n' ' ') "
	_fmp=$(cat "$SC_FDIR/ports" 2>/dev/null | while read -r _fi _fpn; do
		case "$_fall" in *" $_fi "*) case "$_fpn" in ''|*[!0-9]*) ;; *) echo "$_fi $_fpn" ;; esac ;; esac
	done)
	for _fi in $1; do
		case "$SC_NL$_fmp$SC_NL" in *"$SC_NL$_fi "*) continue ;; esac
		_fpn=$SC_FPORT0
		while case "$SC_NL$_fmp$SC_NL" in *" $_fpn$SC_NL"*) true ;; *) false ;; esac; do _fpn=$((_fpn + 1)); done
		_fmp="${_fmp:+$_fmp$SC_NL}$_fi $_fpn"
	done
	printf '%s\n' "$_fmp" > "$SC_FDIR/ports.$$" && mv -f "$SC_FDIR/ports.$$" "$SC_FDIR/ports"
	SC_FMAP=$(printf '%s\n' "$_fmp" | while read -r _fi _fpn; do case " $1 " in *" $_fi "*) echo "$_fi $_fpn" ;; esac; done)
}
# The config for ids limited now → $SC_FDIR/conf.new. Data is geo's READY forms (one `geo.sh ready` for all keys → SC_GREADY):
# a domain key is a list of the filter (block: closed, allow: allowed); a cidr key is an address file of the schedule's set
# (SC_AFILES «<id> <4|6> <file>», sets by sc_aset_sync) — in «block» what it chose, in «allow» only sc_bypass_keys (an address
# cannot be «allowed only»). A key whose data is not downloaded yet acts without it and goes to SC_FPEND — the tick then starts
# the background fetch. Own sites and own addresses — files per schedule here (RAM; rewritten only when they change).
sc_fconf() {
	SC_FPEND=""; SC_AFILES=""; _fk=""
	# ids that are «limited» now; the others are here for safe search only (open + safe): a profile without lists or addresses
	_flim=" $(printf '%s\n' "$SC_PLAN" | awk '$2 == "limited" { print $3 }' | sort -u | tr '\n' ' ') "
	for _fi in $1; do
		case "$_flim" in *" $_fi "*) ;; *) continue ;; esac
		sc_load "$_fi" || continue; _fk="$_fk $(sc_keys | tr '\n' ' ')"
	done
	SC_GREADY=""
	if [ -n "$(echo $_fk)" ] && [ -f "$ENODIA_DIR/geo.sh" ]; then SC_GREADY=$(sh "$ENODIA_DIR/geo.sh" ready $_fk 2>/dev/null); fi
	# «<key>=<kind>» of every ready key, once — the loop below asks it per key without a fork (32 pools a schedule, every minute)
	_fkinds=" $(printf '%s\n' "$SC_GREADY" | awk -F'\t' 'NF == 3 && ($2 == "domain" || $2 == "cidr") { printf "%s=%s ", $1, $2 }') "
	{
		echo "# access-sched.sh: a profile per schedule with limited devices now"
		printf '%s\n' "$SC_GREADY" | awk -F'\t' 'NF == 3 && $2 == "domain" && !s[$1]++ { print "list " $1 " " $3 }'
		for _fi in $1; do
			sc_load "$_fi" || continue
			_fsf=""; [ "$SC_SAFE" = 1 ] && _fsf=" safe"
			case "$_flim" in *" $_fi "*) ;; *)
				echo "port $(printf '%s\n' "$SC_FMAP" | awk -v i="$_fi" '$1 == i { print $2 }') block -$_fsf"
				continue ;; esac
			_fl=""; _fap=0; _fbp=" "; [ "$SC_LMODE" = allow ] && _fbp=" $(sc_bypass_keys | tr '\n' ' ') "
			for _fkk in $(sc_keys); do
				case "$_fkinds" in
					*" $_fkk=domain "*)
						case "$_fbp" in *" $_fkk "*) ;; *) _fl="${_fl:+$_fl,}$_fkk" ;; esac ;;
					*" $_fkk=cidr "*)
						if [ "$SC_LMODE" = block ] || case "$_fbp" in *" $_fkk "*) true ;; *) false ;; esac; then
							SC_AFILES="$SC_AFILES$(printf '%s\n' "$SC_GREADY" | awk -F'\t' -v k="$_fkk" -v i="$_fi" '$1 == k && $2 == "cidr" { print i, 4, $3 } $1 == k && $2 == "cidr6" { print i, 6, $3 }')$SC_NL"
						fi ;;
					*) SC_FPEND="$SC_FPEND $_fi:$_fkk"; [ "$SC_LMODE" = allow ] && sc_fnames_key "$_fkk" && _fap=1 ;;
				esac
			done
			if [ -n "$SC_SITES" ]; then
				sc_fput "site-$_fi.list" "$SC_SITES"
				echo "list site-$_fi $SC_FDIR/site-$_fi.list"
				_fl="${_fl:+$_fl,}site-$_fi"
			else rm -f "$SC_FDIR/site-$_fi.list"; fi
			# own addresses close in «block» only (in «allow» every address is open anyway: the filter judges names)
			for _faf in 4 6; do
				if [ "$_faf" = 4 ]; then _fav=$(printf '%s\n' $SC_ADDRS | grep -v ':'); else _fav=$(printf '%s\n' $SC_ADDRS | grep ':'); fi
				if [ "$SC_LMODE" = block ] && [ -n "$_fav" ]; then
					sc_fput "addr-$_fi.$_faf" "$_fav"; SC_AFILES="$SC_AFILES$_fi $_faf $SC_FDIR/addr-$_fi.$_faf$SC_NL"
				else rm -f "$SC_FDIR/addr-$_fi.$_faf"; fi
			done
			# «allow» with an allowed category not downloaded yet: the profile would allow almost NOTHING (fail-closed for minutes, for
			# good while the source is unreachable) — it blocks nothing until the data is here; the panel says so (review s.112, round 3)
			if [ "$SC_LMODE" = allow ] && [ "$_fap" = 1 ]; then
				echo "port $(printf '%s\n' "$SC_FMAP" | awk -v i="$_fi" '$1 == i { print $2 }') block -$_fsf"
			else
				echo "port $(printf '%s\n' "$SC_FMAP" | awk -v i="$_fi" '$1 == i { print $2 }') $SC_LMODE ${_fl:--}$_fsf"
			fi
		done
	} > "$SC_FDIR/conf.new"
	SC_AFILES=$(printf '%s' "$SC_AFILES" | grep .)
}
# «allow»: does a key not downloaded yet feed the ALLOWED names (sc_fconf: only then the profile waits open)? Address keys never
# do — the curated categories' (SC_CATS field 3: closed by address when not allowed, unused when allowed) and pools of addresses
# (the kind by the key alone, geo.sh about): Telegram's network still downloading opened every name of an «allow» profile that
# needed no data at all — own sites only (review s.113, round 4). Reads _fbp of the caller's loop.
sc_fnames_key() {
	case " $_fbp $(printf '%s\n' "$SC_CATS" | awk -F'|' '{ print $3 }' | tr '\n' ' ') " in *" $1 "*) return 1 ;; esac
	case " $SC_GEO " in *" $1 "*)
		[ "$(sh "$ENODIA_DIR/geo.sh" about "$1" 2>/dev/null | awk -F'\t' '{ print $2; exit }')" = domain ]; return ;; esac
	return 0
}
sc_fput() {   # <name in SC_FDIR> <content> — rewritten only when it changes (its stat feeds the daemon's reload signature)
	printf '%s\n' "$2" > "$SC_FDIR/$1.new"
	if sc_same "$SC_FDIR/$1.new" "$SC_FDIR/$1"; then rm -f "$SC_FDIR/$1.new"; else mv -f "$SC_FDIR/$1.new" "$SC_FDIR/$1"; fi
}
# Converge the filter to SC_PLAN: profiles of the limited schedules, the daemon started / reloaded / stopped, its probe. A filter
# that cannot work ⇒ the limited lines leave SC_PLAN (fail-open: open, never «no DNS») and the journal says why, once.
# `keep` (the tick's first pass, before sc_apply): ports the kernel still steers DNS to (the NAT record) that this plan has no
# profile for stay open as pass-through — stopped or HUPped away first, the leaving devices' DNS hit a closed port until sc_apply
# took their REDIRECT, ~3–14 s at every end of a limited window, for good when the tick died in between (review s.113, round 4).
# They are in SC_FKEPT; the tick's second pass (no `keep`, after sc_apply) takes them.
sc_filter_sync() {
	SC_FMAP=""; SC_FPEND=""; SC_ASETS=""; SC_AFILES=""; SC_FKEPT=""
	_fids=$(printf '%s\n' "$SC_PLAN" | awk '$2 == "limited" || $2 == "safe" { print $3 }' | sort -u | tr '\n' ' ')
	if [ -z "$(echo $_fids)" ]; then
		if [ "${1:-}" = keep ] && sc_falive; then
			SC_FKEPT=$(awk 'NF == 2 { print $2 }' "$SC_APPLIED.nat" 2>/dev/null | sort -u | tr '\n' ' ')
			# the daemon as it runs: its profiles answer the leaving devices until their REDIRECT goes
			[ -n "$(echo $SC_FKEPT)" ] && return 0
		fi
		if sc_falive; then sc_fstop; fi
		sc_fstate idle; return 0
	fi
	SC_FBIN=$(bin_path dns-filter)
	if [ ! -x "$SC_FBIN" ]; then sc_ffail nobin; return 0; fi
	[ -d "$SC_FDIR" ] || ( umask 077; mkdir -p "$SC_FDIR" ) 2>/dev/null
	sc_fports "$_fids"
	sc_fconf "$_fids"
	if [ "${1:-}" = keep ]; then
		SC_FKEPT=$(awk 'NF == 2 { print $2 }' "$SC_APPLIED.nat" 2>/dev/null | sort -u | while read -r _fkp; do
			case "$SC_NL$SC_FMAP$SC_NL" in *" $_fkp$SC_NL"*) ;; *) echo "$_fkp" ;; esac; done | tr '\n' ' ')
		for _fkp in $SC_FKEPT; do echo "port $_fkp block -"; done >> "$SC_FDIR/conf.new"
	fi
	_fp0=$(printf '%s\n' "$SC_FMAP" | awk 'NF == 2 { print $2; exit }'); _fpa=$(printf '%s\n' "$SC_FMAP" | awk 'NF == 2 { print $2 }')
	_fsig=$( { cat "$SC_FDIR/conf.new"; awk '$1 == "list" { print $3 }' "$SC_FDIR/conf.new" | while read -r _fpth; do stat -c '%s %Y %n' "$_fpth" 2>/dev/null; done; } | md5sum | cut -c1-32)
	if sc_falive; then
		if [ "$_fsig" != "$(cat "$SC_FDIR/sig" 2>/dev/null)" ]; then
			mv -f "$SC_FDIR/conf.new" "$SC_FDIR/conf"; kill -HUP "$(sc_fpid)" 2>/dev/null
		else rm -f "$SC_FDIR/conf.new"; fi
		# alive is not answering (map rake «демон жив ≠ работает»): one restart, then fail-open. EVERY port: a reload the daemon
		# refused (a list it cannot read) keeps the old config, and a new profile's port never opens while its REDIRECT stands
		if ! sc_fprobe_all "$_fpa" || ! sc_fapplied; then sc_fstop; sc_fstart "$_fp0" && sc_fprobe_all "$_fpa" && sc_fapplied || { sc_ffail dead; return 0; }; fi
	else
		mv -f "$SC_FDIR/conf.new" "$SC_FDIR/conf"
		sc_fstop
		sc_fstart "$_fp0" && sc_fprobe_all "$_fpa" && sc_fapplied || { sc_ffail dead; return 0; }
	fi
	echo "$_fsig" > "$SC_FDIR/sig"
	sc_aset_sync
	sc_fstate ok
	if [ -n "$SC_FPEND" ]; then sc_want_fetch; fi
	return 0
}
# Every port of the config answers its probe. A HUP is asynchronous (the daemon reloads in its loop, lists of hundreds of
# thousands of names take a moment on ARM): a port that does not answer yet is asked again for up to 3 s.
sc_fprobe_all() {
	daemon_step_init
	for _fpq in $1; do
		_fpw=0
		until "$SC_FBIN" -q "$_fpq"; do
			_fpw=$((_fpw + 1)); [ "$_fpw" -gt $((3 * DAEMON_STEP_Q)) ] && return 1
			daemon_step   # fixed-wait: the daemon is alive (its first port answered or it was just started); a reload, not a start
		done
	done
	return 0
}
sc_ffail() {   # $1 = nobin|dead — «limited» acts whole or not at all: no address sets either; SC_FFAILED for «Перезапустить»
	SC_FFAILED=$1; SC_FKEPT=""
	SC_PLAN=$(printf '%s\n' "$SC_PLAN" | awk 'NF == 3 && $2 != "limited" && $2 != "safe"')
	SC_FMAP=""; SC_ASETS=""; SC_AFILES=""
	sc_fstop
	sc_fstate "$1"
}
# The installed filter is an OLDER build than this code's (gh-update.sh bin-status, no network; asked only once it failed): a
# config word it does not know makes it refuse the whole config, and «did not start» did not say what helps (review s.113, round 4)
sc_fold() {
	[ -f "$ENODIA_DIR/gh-update.sh" ] || return 1
	sh "$ENODIA_DIR/gh-update.sh" bin-status dns-filter 2>/dev/null | awk -F'\t' '$1 == "dns-filter" && $2 == "outdated" { f = 1 } END { exit !f }'
}
# the filter's state within this boot → a journal line on a change into a failure and back (not «idle ↔ ok»)
sc_fstate() {
	_fso=$(cat "$SC_RUN/filter.state" 2>/dev/null)
	[ "$_fso" = "$1" ] && return 0
	echo "$1" > "$SC_RUN/filter.state" 2>/dev/null
	case "$1" in idle) return 0 ;; ok) case "$_fso" in nobin|dead) ;; *) return 0 ;; esac ;; esac
	sc_lang
	case "$1:$SC_LANG" in
		nobin:en) sc_note sched-filter "«Limited» is not acting: the category filter component is not installed" "Devices in a limited state are fully open now. Install the «Category filter» component on the «Components» screen." ;;
		nobin:*)  sc_note sched-filter "«Ограничено» не действует: нет компонента «Фильтр по категориям»" "Устройства с «ограничено» сейчас открыты целиком. Поставьте компонент «Фильтр по категориям» на экране «Компоненты»." ;;
		dead:en)  if sc_fold; then sc_note sched-filter "«Limited» is not acting: the category filter is outdated" "Devices in a limited state are fully open now. The installed filter is an older build than Enodia's — update the «Category filter» component on the «Components» screen."
		          else sc_note sched-filter "«Limited» is not acting: the category filter did not start" "Devices in a limited state are fully open now. The filter's log is in the diagnostics archive; the next minute tries again."; fi ;;
		dead:*)   if sc_fold; then sc_note sched-filter "«Ограничено» не действует: фильтр по категориям устарел" "Устройства с «ограничено» сейчас открыты целиком. Стоит прежняя сборка фильтра — обновите компонент «Фильтр по категориям» на экране «Компоненты»."
		          else sc_note sched-filter "«Ограничено» не действует: фильтр по категориям не запустился" "Устройства с «ограничено» сейчас открыты целиком. Лог фильтра — в архиве диагностики; через минуту роутер попробует снова."; fi ;;
		*:en)     sc_note sched-filter "«Limited» acts again" "The category filter answers again." ;;
		*)        sc_note sched-filter "«Ограничено» снова действует" "Фильтр по категориям снова отвечает." ;;
	esac
}
# Category data: the consumer's keys to geo.sh (the one owner), and the background fetch of what is not downloaded yet.
sc_want_sync() {   # under the lock, after a write: every schedule's keys (sc_keys) → `geo.sh want sched`
	[ -f "$ENODIA_DIR/geo.sh" ] || return 0
	_wsk=""
	for _wsi in $(sc_ids); do sc_load "$_wsi" || continue; _wsk="$_wsk $(sc_keys | tr '\n' ' ')"; done
	_wsk=$(printf '%s\n' $_wsk | grep . | sort -u | tr '\n' ' ')
	sh "$ENODIA_DIR/geo.sh" want sched $_wsk >/dev/null 2>&1
	if [ -n "$(echo $_wsk)" ]; then sc_want_fetch force; fi
	return 0
}
sc_want_fetch() {   # `geo.sh wanted` in the background; not twice at once, and from the tick not more often than SC_WANT_GAP
	_wfp=$(cat "$SC_RUN/wanted.pid" 2>/dev/null | tr -cd '0-9')
	pid_runs "$_wfp" 'geo\.sh' && return 0
	if [ "${1:-}" != force ]; then
		_wfl=$(cat "$SC_RUN/wanted.at" 2>/dev/null); case "$_wfl" in ''|*[!0-9]*) _wfl=-999999 ;; esac
		[ $(( $(uptime_s) - _wfl )) -ge "$SC_WANT_GAP" ] || return 0
	fi
	uptime_s > "$SC_RUN/wanted.at" 2>/dev/null
	start-stop-daemon -S -b -m -p "$SC_RUN/wanted.pid" -x /bin/sh -- "$ENODIA_DIR/geo.sh" wanted >/dev/null 2>&1
	return 0
}

# ---- journal ------------------------------------------------------------------------------------------------------
SC_WD_RU="вс пн вт ср чт пт сб"; SC_WD_EN="Sun Mon Tue Wed Thu Fri Sat"
sc_wd() { _wdi=$1; set -- $2; shift "$_wdi"; echo "$1"; }   # sc_wd <0..6> "<names>"
sc_lang() {
	SC_LANG=ru
	if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; command -v nf_lang >/dev/null 2>&1 && SC_LANG=$(nf_lang); fi
}
sc_note() {   # <key> <title> <text>
	[ -f "$ENODIA_DIR/events.sh" ] && sh "$ENODIA_DIR/events.sh" add "$1" 0 "$2" "$3" >/dev/null 2>&1
	return 0
}
# A schedule's state changed since the last tick of this boot ⇒ one journal line. The first tick of a boot only records: a
# line per schedule after every reboot would bury the real changes.
sc_journal() {   # needs SC_ID SC_NAME SC_ST SC_WHY SC_CHG loaded
	_jf="$SC_RUN/st.$SC_ID"; _jnew="$SC_ST $SC_WHY"
	_jold=$(cat "$_jf" 2>/dev/null)
	[ "$_jold" = "$_jnew" ] && return 0
	echo "$_jnew" > "$_jf" 2>/dev/null
	[ -n "$_jold" ] || return 0
	[ "${_jold%% *}" = "$SC_ST" ] && return 0      # same state, other reason (an override ran out into the same window)
	[ -n "$SC_LANG" ] || sc_lang
	_jt=""; _jc=$(sc_first_change)
	if [ -n "$_jc" ]; then
		sc_at "$_jc"
		if [ "$SC_LANG" = en ]; then _jt=" until $(sc_wd "$SC_AW" "$SC_WD_EN") ${SC_AT#* }"; else _jt=" до $(sc_wd "$SC_AW" "$SC_WD_RU") ${SC_AT#* }"; fi
	fi
	[ "$SC_WHY" = ovr ] && _jt=""                  # an override's own end is not the week's next change
	if [ "$SC_LANG" = en ]; then
		case "$SC_ST" in closed) _js="closed" ;; limited) _js="limited" ;; *) _js="open" ;; esac
		case "$SC_WHY" in ovr) _jw="by hand" ;; all) _jw="«close all now»" ;; hol) _jw="holidays" ;; off) _jw="schedule switched off" ;; *) _jw="by the schedule" ;; esac
		sc_note "sched-$SC_ID" "Schedule «$(sc_name)»: $_js" "Devices of the schedule are $_js$_jt ($_jw)."
	else
		case "$SC_ST" in closed) _js="закрыто" ;; limited) _js="ограничено" ;; *) _js="открыто" ;; esac
		case "$SC_WHY" in ovr) _jw="вручную" ;; all) _jw="«Закрыть всем сейчас»" ;; hol) _jw="каникулы" ;; off) _jw="расписание выключено" ;; *) _jw="по расписанию" ;; esac
		sc_note "sched-$SC_ID" "Расписание «$(sc_name)»: $_js" "Устройствам расписания $_js$_jt ($_jw)."
	fi
}
# The clock is still not synced long after the boot while schedules exist ⇒ one line per boot: «why did nothing close».
sc_clock_note() {
	[ -f "$SC_RUN/clock-noted" ] && return 0
	[ "$(uptime_s)" -ge "$SC_CLOCK_NOTE" ] || return 0
	: > "$SC_RUN/clock-noted" 2>/dev/null
	sc_lang
	if [ "$SC_LANG" = en ]; then
		sc_note sched-clock "Access schedules are not acting: the router clock is not synced" "The router has no clock of its own: after a boot the time comes from the network. It has not come yet, so the schedules close nothing — closing the internet by a wrong clock is worse than not closing. They start acting by themselves once the time is synced."
	else
		sc_note sched-clock "Расписания доступа не действуют: время роутера не сверено" "Своих часов у роутера нет: после загрузки время приходит из сети. Оно ещё не пришло, поэтому расписания ничего не закрывают — закрыть интернет по неверным часам хуже, чем не закрыть. Как только время сверится, они начнут действовать сами."
	fi
}

# ---- tick ---------------------------------------------------------------------------------------------------------
# Under the lock: expired actions go, the plan converges, transitions go to the journal. Cheap when nothing changes: one
# `date`, the registry read, one `-C` and one `-S` per family — and no iptables call at all while nobody is closed.
sc_tick_locked() {
	sc_now
	if clock_trusted; then
		# expired actions leave the registry (one write per action's life); the panel then shows the week, not a dead override
		for _ti in $(sc_ids); do
			[ -f "$SC_DIR/$_ti.ovr" ] && ! sc_ovr_get "$_ti" && rm -f "$SC_DIR/$_ti.ovr"
		done
		[ -f "$SC_DIR/.all" ] && ! sc_all_get && rm -f "$SC_DIR/.all"
		rm -f "$SC_RUN/clock-noted" 2>/dev/null
	elif [ -n "$(sc_ids)" ]; then
		sc_clock_note
	fi
	SC_IDS=$(sc_ids)
	clock_trusted && sc_use_tick
	sc_plan
	sc_filter_sync keep   # may take the limited lines out of the plan (fail-open) — before the kernel converges
	sc_apply
	# the ports kept for leaving devices go now that no REDIRECT names them (a failure there takes lines out: sc_apply again)
	# …not after a failure (sc_ffail stopped the daemon, the kept ports with it): the second pass wrote «idle» over «dead», and the
	# panel showed «Ограничено» for devices open whole (review s.113, round 5)
	if [ -n "$(echo $SC_FKEPT)" ] && [ -z "$SC_FFAILED" ]; then sc_filter_sync; sc_apply; fi
	clock_trusted || return 0
	SC_LANG=""
	for _ti in $SC_IDS; do
		sc_load "$_ti" || continue
		sc_eval 1; sc_effective; sc_journal
	done
	sc_over_note
	return 0
}
# A device newly out of its day limit ⇒ one journal line (the first tick of a boot only records), and the day's usage goes to the
# flash at once: a reboot must not hand the device a fresh day.
sc_over_note() {
	_on=$(printf '%s' "$SC_OVER" | grep . | sort)
	# the first tick of a boot writes its record even when nobody is over — otherwise the first real crossing would read as
	# «the first tick» and stay silent
	if [ ! -f "$SC_RUN/over" ]; then
		printf '%s\n' "$_on" > "$SC_RUN/over" 2>/dev/null
		[ -n "$_on" ] && sc_use_save now
		return 0
	fi
	_oo=$(cat "$SC_RUN/over" 2>/dev/null)
	[ "$_on" = "$_oo" ] && return 0
	printf '%s\n' "$_on" > "$SC_RUN/over" 2>/dev/null
	[ -n "$_on" ] && sc_use_save now
	printf '%s\n' "$_on" | while read -r _om _oi; do
		[ -n "$_om" ] || continue
		case "$SC_NL$_oo$SC_NL" in *"$SC_NL$_om $_oi$SC_NL"*) continue ;; esac
		sc_load "$_oi" || continue
		# the name the panel shows: own label, then the name the device gave its lease, then the MAC (BE7000 08.10.2026: the line
		# said «7E:E7:…» while the panel said «OnePlus-Ace-6»)
		_onm=""; [ -f "$ENODIA_DIR/dev-names.sh" ] && _onm=$(sh "$ENODIA_DIR/dev-names.sh" get "$_om" 2>/dev/null)
		if [ -z "$_onm" ] && command -v lease_host_of >/dev/null 2>&1; then
			_onm=$(lease_host_of "$(lease_ip_of_mac "$_om")" 2>/dev/null)
		fi
		[ -n "$_onm" ] || _onm=$(printf '%s' "$_om" | tr 'a-f' 'A-F')
		[ -n "$SC_LANG" ] || sc_lang
		if [ "$SC_LANG" = en ]; then
			sc_note "sched-lim-$_oi" "Schedule «$(sc_name)»: the day's limit is used up" "$_onm has used up today's limit — closed until the end of the day. «Open for…» on the schedule adds time."
		else
			sc_note "sched-lim-$_oi" "Расписание «$(sc_name)»: лимит на сегодня исчерпан" "$_onm исчерпало лимит на сегодня — закрыто до конца дня. «Открыть на…» на экране расписания добавит время."
		fi
	done
	return 0
}
cmd_tick() {
	# nothing registered and nothing in the kernel: the per-minute cron line costs one directory listing
	[ -n "$(sc_ids)" ] || [ -s "$SC_APPLIED" ] || return 0
	if [ "${1:-}" = wait ]; then
		# a caller that changed what a tick in flight has already read (tasks.sh raw-save: the tick line itself — the holder kept the
		# rules it read as «ticking») waits for its own tick, ≤ 60 s, the way unwire does (review s.113, round 5)
		_twn=0; until sc_lock; do _twn=$((_twn + 1)); [ "$_twn" -ge 12 ] && return 0; done
	else
		sc_lock || return 0      # another tick or a save holds it — it converges for us
	fi
	sc_tick_locked
}
cmd_unwire() {
	# a tick in flight may hold the lock for its filter start: wait it out, else it would put back what we take
	_uwn=0; until sc_lock; do _uwn=$((_uwn + 1)); [ "$_uwn" -ge 12 ] && break; done   # ≤ 60 s: a filter restart path takes ~33
	sc_drop_fam iptables; if have_v6; then sc_drop_fam ip6tables; fi
	sc_cap_drop
	sc_fstop
	SC_ASETS=""; sc_aset_gc
	rm -f "$SC_APPLIED" "$SC_APPLIED.nat" "$SC_APPLIED.sets" "$SC_APPLIED.pend" "$SC_RUN"/st.* "$SC_RUN/filter.state" 2>/dev/null
	rm -rf "$SC_FDIR" 2>/dev/null
	echo "Расписания доступа: правила сняты."
}

# ---- JSON -----------------------------------------------------------------------------------------------------------
sc_at_json() {   # <epoch> -> {"at":"…","w":N,"ue":E}
	sc_at "$1"; printf '{"at":"%s","w":%s,"ue":%s}' "$SC_AT" "$SC_AW" "$1"
}
sc_item_json() {   # the loaded schedule, after sc_now + sc_use_load
	sc_eval "$SC_K"; sc_effective; sc_lim_today
	printf '{"id":"%s","name":"%s","on":%s,"ver":%s,"base":"%s",' "$SC_ID" "$(jstr "$(sc_name)" 200)" "$SC_ON" "$SC_VER" "$SC_BASE"
	# the day limit: minutes per weekday / weekend day, today's; every device's minutes today; who is closed by it NOW
	printf '"lim":{"wd":%s,"we":%s,"today":%s},"used":{' "$SC_LWD" "$SC_LWE" "$SC_LT"
	_ij=0; _iov=""
	for _im in $SC_DEVS; do
		_iu=$(sc_used_of "$_im")
		[ "$_ij" = 1 ] && printf ','; _ij=1; printf '"%s":%s' "$_im" "$_iu"
		sc_lim_applies && [ "$_iu" -ge "$SC_LT" ] && _iov="${_iov:+$_iov,}\"$_im\""
	done
	printf '},"over":[%s],"wins":[' "$_iov"
	_ij=0
	printf '%s' "$SC_WINS" | while read -r _id _ia _ib _is; do
		[ -n "$_is" ] || continue
		[ "$_ij" = 1 ] && printf ','; _ij=1
		printf '{"d":"%s","a":"%s","b":"%s","s":"%s"}' "$_id" "$_ia" "$_ib" "$_is"
	done
	printf '],"devs":['
	_ij=0; for _im in $SC_DEVS; do [ "$_ij" = 1 ] && printf ','; _ij=1; printf '"%s"' "$_im"; done
	# «limited»: the mode, the chosen categories, own sites, and the categories whose data is not downloaded yet (SC_FREADY —
	# the ready keys, asked once per answer by sc_fready)
	printf '],"safe":%s,"lmode":"%s","cats":[' "$SC_SAFE" "$SC_LMODE"
	_ij=0; _ipd=""
	for _ic in $SC_CATON; do
		[ "$_ij" = 1 ] && printf ','; _ij=1; printf '"%s"' "$_ic"
		for _ik in $(sc_cat_keys "$_ic"); do
			case " $SC_FREADY " in *" $_ik "*) ;; *) _ipd="${_ipd:+$_ipd,}\"$_ic\""; break ;; esac
		done
	done
	printf '],"pend":[%s],"geo":[' "$_ipd"
	# pools of the catalogue: key, kind (domain|cidr), its catalogue tab and label — geo.sh's answer (SC_GABOUT, sc_fready)
	_ij=0; _ipd=""
	for _ig in $SC_GEO; do
		[ "$_ij" = 1 ] && printf ','; _ij=1
		printf '%s\n' "$SC_GABOUT" | awk -F'\t' -v k="$_ig" '$1 == k { printf "{\"k\":\"%s\",\"kind\":\"%s\",\"t\":\"%s\",\"l\":\"%s\"}", $1, $2, $3, $4; f = 1; exit }
			END { if (!f) printf "{\"k\":\"%s\",\"kind\":\"\",\"t\":\"\",\"l\":\"%s\"}", k, k }'
		case " $SC_FREADY " in *" $_ig "*) ;; *) _ipd="${_ipd:+$_ipd,}\"$_ig\"" ;; esac
	done
	printf '],"gpend":[%s],"sites":[' "$_ipd"
	_ij=0
	for _is in $SC_SITES; do [ "$_ij" = 1 ] && printf ','; _ij=1; printf '"%s"' "$_is"; done
	printf '],"addrs":['
	_ij=0
	for _is in $SC_ADDRS; do [ "$_ij" = 1 ] && printf ','; _ij=1; printf '"%s"' "$_is"; done
	printf '],"st":"%s","why":"%s","hol":' "$SC_ST" "$SC_WHY"
	# the LAST rested minute (23:59 of the chosen day): the panel says the day «включительно»; SC_HOL itself is the 00:00 after it
	if [ "$SC_HOL" -gt "$SC_E" ] 2>/dev/null; then sc_at_json "$(( SC_HOL - 60 ))"; else printf 'null'; fi
	printf ',"ovr":'
	if sc_ovr_get "$SC_ID"; then
		printf '{"s":"%s","kind":"%s","back":%s,"until":' "$SC_OS" "$SC_OK" "$SC_OB"
		if [ "$SC_OU" = 0 ]; then printf 'null'; else sc_at_json "$SC_OU"; fi
		printf '}'
	else printf 'null'; fi
	# the week's upcoming changes — the router's calendar and TZ, so the panel shows them without arithmetic
	printf ',"next":['
	_ij=0
	printf '%s\n' "$SC_CHG" | while read -r _io _is; do
		[ -n "$_is" ] || continue
		[ "$_ij" = 1 ] && printf ','; _ij=1
		sc_at "$(( SC_E0 + _io * 60 ))"; printf '{"at":"%s","w":%s,"ue":%s,"s":"%s"}' "$SC_AT" "$SC_AW" "$(( SC_E0 + _io * 60 ))" "$_is"
	done
	printf ']}'
}
sc_head_json() {   # router clock + «close all» + limits, after sc_now
	_hc=0; clock_trusted && _hc=1
	sc_at "$SC_E"
	# `ne` — «now» as an epoch: «in 20 min» is then one subtraction of two router numbers in the panel, not a calendar
	_htk=0; sc_ticking && _htk=1
	printf '"clock":%s,"tick":%s,"now":"%s","w":%s,"ne":%s,"max":%s,"wmax":%s,"dmax":%s,"all":' "$_hc" "$_htk" "$SC_AT" "$SC_AW" "$SC_E" "$SC_MAX" "$SC_WIN_MAX" "$SC_DEV_MAX"
	# said without the clock too: the panel's «Открыть всем» is the one way to cancel it then (cmd_all off needs no clock)
	if sc_all_get; then
		if [ "$SC_AU" = 0 ]; then printf '{"until":null}'; else printf '{"until":'; sc_at_json "$SC_AU"; printf '}'; fi
	else printf 'null'; fi
	# «limited»: the categories offered (the router's table — the panel words them) and the filter: installed? its state now
	_hfi=0; [ -x "$(bin_path dns-filter)" ] && _hfi=1
	printf ',"cats":['
	# a category that also closes by address says so (`addr`): «allow» closes it by address when it is not allowed
	printf '%s\n' "$SC_CATS" | awk -F'|' 'NF == 4 { printf "%s{\"id\":\"%s\",\"name\":\"%s\",\"addr\":%s}", (n++ ? "," : ""), $1, $4, ($3 == "" ? "false" : "true") }'
	_hfs=$(cat "$SC_RUN/filter.state" 2>/dev/null | tr -cd 'a-z')
	# `old` — a dead filter that is an older build than the code's: the panel leads to «Компоненты» then (sc_fold)
	_hfo=false; [ "$_hfs" = dead ] && sc_fold && _hfo=true
	printf '],"pmax":%s,"filter":{"inst":%s,"state":"%s","old":%s}' "$SC_POOL_MAX" "$_hfi" "$_hfs" "$_hfo"
}
# the keys of the listed schedules that have READY data now → SC_FREADY, and what the catalogue says of their pools → SC_GABOUT
# (one geo.sh call each per answer; `about` only when some schedule has pools)
sc_fready() {
	SC_FREADY=""; SC_GABOUT=""; _frk=""; _frg=""
	for _fri in "$@"; do sc_load "$_fri" || continue; _frg="$_frg $SC_GEO"; done
	if [ -n "$(echo $_frg)" ] && [ -f "$ENODIA_DIR/geo.sh" ]; then SC_GABOUT=$(sh "$ENODIA_DIR/geo.sh" about $_frg 2>/dev/null); fi
	for _fri in "$@"; do sc_load "$_fri" || continue; _frk="$_frk $(sc_keys | tr '\n' ' ')"; done
	[ -n "$(echo $_frk)" ] && [ -f "$ENODIA_DIR/geo.sh" ] || return 0
	SC_FREADY=$(sh "$ENODIA_DIR/geo.sh" ready $_frk 2>/dev/null | cut -f1 | sort -u | tr '\n' ' ')
	return 0
}
cmd_list_json() {
	sc_now; sc_use_load; sc_fready $(sc_ids)
	printf '{"ok":true,'; sc_head_json; printf ',"items":['
	_lj=0
	for _li in $(sc_ids); do
		sc_load "$_li" || continue
		[ "$_lj" = 1 ] && printf ','; _lj=1
		sc_item_json
	done
	printf ']}\n'
}
cmd_get_json() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_now; sc_use_load; sc_fready "$1"
	sc_load "$1" || jfail "нет такого расписания"
	printf '{"ok":true,'; sc_head_json; printf ',"item":'; sc_item_json; printf '}\n'
}

# ---- writes -------------------------------------------------------------------------------------------------------
# Spec from the CGI (key=value lines, values already charset-checked there; meaning is checked HERE):
#   id=<sN|new> ver=<n the panel opened> name_b64=… enabled=0|1 base=open|limited|closed
#   wins=<d>.<HHMM>.<HHMM>.<o|l|c>[;…]   devs=<mac>[,<mac>…]   lim_wd= lim_we= (minutes)
#   lmode=block|allow   cats=<id>[,<id>…]   geo=<geo key>[,…]   sites_b64=<base64 of a site or an address per line>   safe=0|1
#   — absent = the schedule keeps its own
sc_spec() { sed -n "s/^$1=//p" "$SC_SPEC" | head -n 1 | tr -d '\r'; }
sc_st_of() { case "$1" in o) echo open ;; l) echo limited ;; c) echo closed ;; *) return 1 ;; esac; }
cmd_save() {
	SC_SPEC=$1; [ -f "$SC_SPEC" ] || jfail "нет данных расписания"
	_vid=$(sc_spec id); _vver=$(num_or "$(sc_spec ver)" 0)
	_vname=$(sc_spec name_b64 | base64 -d 2>/dev/null); _vname=$(lbl_san "$_vname")
	[ -n "$_vname" ] || jfail "нужно имя расписания"
	# characters, not bytes: UTF-8 continuation bytes (0x80–0xBF) do not start a character (busybox `wc` has no -m)
	[ "$(printf '%s' "$_vname" | tr -d '\200-\277' | wc -c | tr -d ' ')" -le "$SC_NAME_MAX" ] || jfail "имя длиннее $SC_NAME_MAX знаков"
	_von=$(sc_spec enabled); case "$_von" in 0|1) ;; *) jfail "неверный выключатель" ;; esac
	_vbase=$(sc_spec base); case "$_vbase" in open|limited|closed) ;; *) jfail "неверное состояние вне окон" ;; esac
	# day limits, minutes (0 = none); absent from the spec = the schedule keeps its own (an older panel knows nothing of them)
	_vlwd=$(sc_spec lim_wd | sed 's/^0*\([0-9]\)/\1/'); _vlwe=$(sc_spec lim_we | sed 's/^0*\([0-9]\)/\1/')   # «090» is octal to $((…))
	for _vlv in "$_vlwd" "$_vlwe"; do
		case "$_vlv" in '') continue ;; *[!0-9]*) jfail "неверный лимит" ;; esac
		[ "$_vlv" -le 1440 ] || jfail "лимит — не больше суток"
	done
	# windows: «days.HHMM.HHMM.s» → registry lines (days sorted, each once), then through the SAME check as a load (SC_WIN_AWK)
	_vwn=$(sc_spec wins | tr ';' '\n' | grep -c . || true)
	[ "${_vwn:-0}" -le "$SC_WIN_MAX" ] || jfail "окон больше $SC_WIN_MAX"
	_vconv=$(sc_spec wins | tr ';' '\n' | awk -F. '
		NF == 0 { next }
		NF != 4 || $1 !~ /^[0-6]+$/ || $2 !~ /^[0-9][0-9][0-9][0-9]$/ || $3 !~ /^[0-9][0-9][0-9][0-9]$/ || $4 !~ /^[olc]$/ { print "BAD " $0; next }
		{ d = ""; for (c = 0; c <= 6; c++) { f = 0; for (i = 1; i <= length($1); i++) if (substr($1, i, 1) == c "") f = 1; if (f) d = d c }
		  s = ($4 == "o") ? "open" : ($4 == "l") ? "limited" : "closed"
		  print d " " substr($2, 1, 2) ":" substr($2, 3, 2) " " substr($3, 1, 2) ":" substr($3, 3, 2) " " s }')
	_vbad=$(printf '%s\n' "$_vconv" | sed -n 's/^BAD //p' | head -n 1)
	[ -z "$_vbad" ] || jfail "неверное окно: $_vbad"
	_vwins=$(printf '%s\n' "$_vconv" | awk -v bare=1 "$SC_WIN_AWK")
	[ "$(printf '%s\n' "$_vconv" | grep . | sort -u | grep -c . || true)" = "$(printf '%s\n' "$_vwins" | grep -c . || true)" ] || jfail "неверное время окна"
	[ -n "$_vwins" ] && _vwins="$_vwins$SC_NL"
	_vdevs=""; _vdn=0
	for _vm in $(sc_spec devs | tr ',' ' '); do
		_vm=$(mac_norm "$_vm"); mac_ok "$_vm" || jfail "неверный MAC: $_vm"
		case " $_vdevs " in *" $_vm "*) continue ;; esac
		_vdn=$((_vdn + 1)); [ "$_vdn" -le "$SC_DEV_MAX" ] || jfail "устройств больше $SC_DEV_MAX"
		_vdevs="${_vdevs:+$_vdevs }$_vm"
	done
	# «limited»: the mode, categories (ours only), own sites. Sites as a person pastes them — URLs, «*.x», capitals: the ONE
	# normaliser of the project's domain lists (lists-lib.sh::norm_domains) makes host names of them; what it cannot is dropped
	# and COUNTED in the answer (the panel says how many lines were not sites).
	_vlm=$(sc_spec lmode); case "$_vlm" in ''|block|allow) ;; *) jfail "неверный режим «ограничено»" ;; esac
	_vsafe=$(sc_spec safe); case "$_vsafe" in ''|0|1) ;; *) jfail "неверный выключатель безопасного поиска" ;; esac
	_vcats=""; _vhc=0
	if grep -q '^cats=' "$SC_SPEC"; then
		_vhc=1
		for _vc in $(sc_spec cats | tr ',' ' '); do
			sc_cat_ok "$_vc" || jfail "неизвестная категория: $_vc"
			case " $_vcats " in *" $_vc "*) ;; *) _vcats="${_vcats:+$_vcats }$_vc" ;; esac
		done
	fi
	# pools of the geo catalogue: their form here, membership in the catalogue by geo.sh (the one owner) — an unknown key would
	# stay «downloading» for ever
	_vgeo=""; _vhg=0
	if grep -q '^geo=' "$SC_SPEC"; then
		_vhg=1
		for _vg in $(sc_spec geo | tr ',' ' '); do
			sc_geo_ok "$_vg" || jfail "неверный пул: $_vg"
			case " $_vgeo " in *" $_vg "*) ;; *) _vgeo="${_vgeo:+$_vgeo }$_vg" ;; esac
		done
		[ "$(set -- $_vgeo; echo $#)" -le "$SC_POOL_MAX" ] || jfail "пулов больше $SC_POOL_MAX"
		if [ -n "$_vgeo" ]; then
			[ -f "$ENODIA_DIR/geo.sh" ] || jfail "на роутере нет geo.sh — обновите скрипты роутера"
			_vknown=$(sh "$ENODIA_DIR/geo.sh" about $_vgeo 2>/dev/null | cut -f1)
			for _vg in $_vgeo; do printf '%s\n' "$_vknown" | grep -qxF -- "$_vg" || jfail "неизвестный пул: $_vg"; done
		fi
	fi
	_vhs=0; _vsites=""; _vaddrs=""; _vdrop=0
	if grep -q '^sites_b64=' "$SC_SPEC"; then
		_vhs=1
		# «*.x» is x and below (dnsmasq semantics, the filter's too) — cut here: the shared normaliser drops a star as junk
		_vraw=$(sc_spec sites_b64 | base64 -d 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*\*\.//')
		_vin=$(printf '%s\n' "$_vraw" | grep -c '[^[:space:]]' || true)
		if [ -f "$ENODIA_DIR/lists-lib.sh" ]; then
			. "$ENODIA_DIR/lists-lib.sh"
			# addresses by the project's ONE address normalisers, bogons cut (the map rake: a private range must never become a
			# REJECT); the names' normaliser skips address lines itself (a bare IP or a CIDR is not a host name there)
			_vaddrs=$( { printf '%s\n' "$_vraw" | norm_cidr | strip_bogon; printf '%s\n' "$_vraw" | norm_cidr6 | strip_bogon6; } | awk '!s[$0]++')
			# a leading www. goes: the filter closes a name AND its subdomains, so www.instagram.com would leave instagram.com
			# and the app's own names open (and in «allow» let only www through); groups.sh norm_member does the same
			_vsites=$(printf '%s\n' "$_vraw" | norm_domains | sed 's/^www\.//' | awk '!s[$0]++')
		else
			_vsites=$(printf '%s\n' "$_vraw" | tr 'A-Z' 'a-z' | awk '{ d = $1; sub(/^\*?\./, "", d) } d ~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/ && !s[d]++ { print d }')
		fi
		_vout=$( { printf '%s\n' "$_vsites"; printf '%s\n' "$_vaddrs"; } | grep -c . || true)
		[ "$_vout" -le "$SC_SITE_MAX" ] || jfail "своих сайтов и адресов больше $SC_SITE_MAX"
		_vdrop=$(( ${_vin:-0} - ${_vout:-0} )); [ "$_vdrop" -ge 0 ] || _vdrop=0
	fi
	mkdir -p "$SC_DIR" 2>/dev/null || jfail "не удалось создать $SC_DIR"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	if [ "$_vid" = new ]; then
		[ "$(sc_ids | wc -l | tr -d ' ')" -lt "$SC_MAX" ] || jfail "расписаний не больше $SC_MAX"
		_vid=$(sc_new_id); SC_VER=0; SC_HOL=0; SC_LWD=0; SC_LWE=0; SC_LMODE=block; SC_CATON=""; SC_SITES=""; SC_GEO=""; SC_ADDRS=""; SC_SAFE=0
	else
		id_ok "$_vid" || jfail "неверный номер расписания"
		sc_load "$_vid" || jfail "расписание удалено — откройте список заново"
		[ "$SC_VER" = "$_vver" ] || jfail "расписание изменили в другой вкладке — откройте его заново"
	fi
	# one device = one schedule: two of them would fight over its rule, and the panel shows ONE schedule per device
	for _vo in $(sc_ids); do
		[ "$_vo" = "$_vid" ] && continue
		_vown=$(grep -h '^dev=mac:' "$SC_DIR/$_vo.sch" 2>/dev/null | sed 's/^dev=mac://' | tr 'A-Z' 'a-z')
		for _vm in $_vdevs; do
			case "$SC_NL$_vown$SC_NL" in *"$SC_NL$_vm$SC_NL"*)
				_von2=$(sed -n 's/^name=//p' "$SC_DIR/$_vo.sch" | head -n 1)
				jfail "устройство $_vm уже в расписании «$(lbl_san "$_von2")»" ;; esac
		done
	done
	SC_ID=$_vid; SC_NAME=$_vname; SC_ON=$_von; SC_BASE=$_vbase; SC_WINS=$_vwins; SC_DEVS=$_vdevs; SC_VER=$((SC_VER + 1))
	[ -n "$_vlwd" ] && SC_LWD=$_vlwd; [ -n "$_vlwe" ] && SC_LWE=$_vlwe
	[ -n "$_vlm" ] && SC_LMODE=$_vlm; [ "$_vhc" = 1 ] && SC_CATON=$_vcats; [ "$_vhg" = 1 ] && SC_GEO=$_vgeo
	[ -n "$_vsafe" ] && SC_SAFE=$_vsafe
	[ "$_vhs" = 1 ] && { SC_SITES=$_vsites; SC_ADDRS=$_vaddrs; }
	sc_write "$_vid" || jfail "не удалось записать расписание"
	_vv=$SC_VER          # the tick and the keys' sync load OTHER schedules into the same SC_* — the answer is this one's
	sc_want_sync
	sc_tick_locked
	jok "\"id\":\"$_vid\",\"ver\":$_vv,\"dropped\":$_vdrop"
}
cmd_del() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	[ -f "$SC_DIR/$1.sch" ] || jfail "нет такого расписания"
	rm -f "$SC_DIR/$1.sch" "$SC_DIR/$1.ovr" "$SC_RUN/st.$1" 2>/dev/null
	sc_want_sync
	sc_tick_locked
	jok
}
cmd_toggle() {
	id_ok "$1" || jfail "неверный номер расписания"
	case "$2" in on) _tv=1 ;; off) _tv=0 ;; *) jfail "нужно on|off" ;; esac
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_load "$1" || jfail "нет такого расписания"
	SC_ON=$_tv; SC_VER=$((SC_VER + 1))
	sc_write "$1" || jfail "не удалось записать расписание"
	_tvv=$SC_VER; sc_tick_locked
	jok "\"ver\":$_tvv"
}
# minutes|HH:MM|0 -> SC_UNTIL (epoch; 0 = until cancelled). `end` is handled by the caller (it needs the week).
sc_until() {
	case "$1" in
		0) SC_UNTIL=0 ;;
		*:*) sc_next_hhmm "$1" || return 1; SC_UNTIL=$SC_NEXT ;;
		# minutes through sc_num: `060` was 48 minutes (octal), `08` killed the engine mid-request (review s.113, confirming)
		*) sc_num _sum "$1" -1; [ "$_sum" -ge 1 ] && [ "$_sum" -le 10080 ] || return 1
		   SC_UNTIL=$(( SC_E + _sum * 60 )) ;;
	esac
}
cmd_ovr() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_now
	# «вернуть по расписанию» takes an action away — no clock needed for that (the panel offers it while the clock is unsynced)
	[ "$2" = clear ] || clock_trusted || jfail "время роутера ещё не сверено — расписания не действуют"
	sc_load "$1" || jfail "нет такого расписания"
	sc_eval 1; sc_effective
	# an action the state above it would hide is refused, not «ok» with nothing done (review s.112: «Закрыть на час» on holidays
	# answered ok, the screen said «закрыто вручную», the device stayed open)
	if [ "$2" != clear ]; then
		case "$SC_WHY" in
			stop) jfail "расписания сейчас не действуют: Enodia снята с расписания — включите VPN" ;;
			off)  jfail "расписание выключено — включите его" ;;
			all)  jfail "сейчас закрыто всем — сначала «Открыть всем»" ;;
			hol)  jfail "у расписания каникулы — сначала отмените их" ;;
		esac
	fi
	case "$2" in
		clear) rm -f "$SC_DIR/$1.ovr" ;;
		close)
			sc_until "${3:-0}" || jfail "неверный срок"
			echo "closed $SC_UNTIL close" > "$SC_DIR/$1.ovr" ;;
		open)
			if [ "${3:-}" = end ]; then
				# «до конца окна»: until the week itself next changes the state
				SC_UNTIL=$(sc_first_change); [ -n "$SC_UNTIL" ] || jfail "у этого расписания закрытое время не кончается — выберите срок"
			else
				sc_until "${3:-}" && [ "$SC_UNTIL" != 0 ] || jfail "неверный срок"
			fi
			# over a hand close that outlives it, the close comes back when this open ends (sc_ovr_get)
			_ob=""
			if [ "$SC_WHY" = ovr ] && [ "$SC_OS" = closed ] && { [ "$SC_OU" = 0 ] || [ "$SC_OU" -gt "$SC_UNTIL" ]; }; then _ob=" closed $SC_OU $SC_OK"
			# an open laid over such an open (extended): the close still waiting behind it is carried on
			elif [ "$SC_WHY" = ovr ] && [ "$SC_OB" = 1 ] && { [ "$SC_PBU" = 0 ] || [ "$SC_PBU" -gt "$SC_UNTIL" ]; }; then _ob=" $SC_PB"
			fi
			echo "open $SC_UNTIL open$_ob" > "$SC_DIR/$1.ovr" ;;
		postpone)
			# «отложить закрытие»: the week is open now and is about to get stricter — stay open N minutes past that change
			sc_num _pm "${3:-}" 0; [ "$_pm" -ge 1 ] && [ "$_pm" -le 1440 ] || jfail "неверный срок"
			[ "$SC_CUR" = open ] || jfail "сейчас не открыто — откладывать нечего"
			# a hand action decides now: a postpone over «Закрыть пока не откроете» opened the device and lost that close
			[ "$SC_WHY" = win ] || [ "$SC_WHY" = base ] || jfail "сейчас действует ручное действие — сначала верните по расписанию"
			_pc=$(sc_first_change); [ -n "$_pc" ] || jfail "закрытия впереди нет"
			# near the closing only: far ahead an «open» till then would rest the day's limit and the week for hours
			[ $(( _pc - SC_E )) -le 3600 ] || jfail "закрытие ещё не скоро — отложить можно за час до него"
			echo "open $(( _pc + _pm * 60 )) postpone" > "$SC_DIR/$1.ovr" ;;
		*) jfail "неизвестное действие" ;;
	esac
	sc_tick_locked
	jok
}
cmd_all() {
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_now
	# «open for all» needs no clock (as `ovr clear`, review s.112): a «close all until opened» set before a reboot with the provider
	# down could not be cancelled, and every scheduled device closed the moment the time synced (review s.113, round 4)
	[ "$1" = off ] || clock_trusted || jfail "время роутера ещё не сверено — расписания не действуют"
	[ "$1" = off ] || sc_ticking || jfail "расписания сейчас не действуют: Enodia снята с расписания — включите VPN"
	mkdir -p "$SC_DIR" 2>/dev/null
	if [ "$1" = off ]; then rm -f "$SC_DIR/.all"
	else
		sc_until "$1" || jfail "неверный срок"
		echo "$SC_UNTIL" > "$SC_DIR/.all.$$" && mv -f "$SC_DIR/.all.$$" "$SC_DIR/.all"
	fi
	sc_tick_locked
	jok
}
cmd_hol() {
	id_ok "$1" || jfail "неверный номер расписания"
	sc_lock || jfail "расписания сейчас меняет другой запрос — повторите"
	sc_now
	sc_load "$1" || jfail "нет такого расписания"
	if [ "$2" = off ]; then SC_HOL=0
	else
		clock_trusted || jfail "время роутера ещё не сверено — расписания не действуют"
		printf '%s' "$2" | grep -qE '^20[0-9]{2}-[01][0-9]-[0-3][0-9]$' || jfail "неверная дата"
		_hd=$(date -d "$2 23:59" +%s 2>/dev/null); _hd=$(num_or "$_hd" 0)
		[ "$_hd" -gt "$SC_E" ] || jfail "дата уже прошла"
		SC_HOL=$(( _hd + 60 ))       # the whole chosen day rests; the schedule acts again at 00:00 after it
	fi
	SC_VER=$((SC_VER + 1))
	sc_write "$1" || jfail "не удалось записать расписание"
	_hvv=$SC_VER; sc_tick_locked
	jok "\"ver\":$_hvv"
}

# Backup import (cgi-bin/backup): a schedule from the archive replaces the one under its id, written through the SAME load
# (a foreign or old file loads only what is valid) and sc_write. Actions over a schedule (`.ovr`, `.all`) are «now», not settings
# — the export leaves them out, and an action of the replaced schedule goes with it. One device = one schedule after the
# merge too: a device the archive puts in a schedule leaves a local one. The id counter keeps the higher of both.
cmd_import() {
	[ -d "$1" ] || jfail "нет каталога расписаний"
	mkdir -p "$SC_DIR" 2>/dev/null || jfail "не удалось создать $SC_DIR"
	# a backup restore is not a click to repeat: wait out a tick in flight (≤ 30 s) rather than be refused for it
	_imn=0; until sc_lock; do _imn=$((_imn + 1)); [ "$_imn" -ge 6 ] && jfail "расписания сейчас меняет другой запрос — повторите"; done
	sc_now
	_mi=""; _mdevs=""
	for _mf in "$1"/s*.sch; do
		[ -f "$_mf" ] || continue
		_mid=${_mf##*/}; _mid=${_mid%.sch}
		id_ok "$_mid" || continue
		sc_load "$_mid" "$_mf" || continue
		SC_NAME=$(sc_name); [ -n "$SC_NAME" ] || SC_NAME=$_mid
		SC_HOL=0                                   # a holiday of the archive's past means nothing here
		# the version moves past BOTH: a panel tab open on the local schedule must see «changed elsewhere», not save over it
		sc_num _mlv "$(sed -n 's/^ver=//p' "$SC_DIR/$_mid.sch" 2>/dev/null | head -n 1 | tr -cd '0-9')" 0
		[ "$_mlv" -gt "$SC_VER" ] && SC_VER=$_mlv
		SC_VER=$((SC_VER + 1))
		[ "$(sc_ids | grep -cx "$_mid" || true)" = 0 ] && [ "$(sc_ids | wc -l | tr -d ' ')" -ge "$SC_MAX" ] && continue
		sc_write "$_mid" || continue
		rm -f "$SC_DIR/$_mid.ovr" 2>/dev/null
		_mi="$_mi $_mid"; _mdevs="$_mdevs $SC_DEVS"
	done
	for _mo in $(sc_ids); do
		case " $_mi " in *" $_mo "*) continue ;; esac
		sc_load "$_mo" || continue
		_mk=""; _mch=0
		for _mm in $SC_DEVS; do case " $_mdevs " in *" $_mm "*) _mch=1 ;; *) _mk="${_mk:+$_mk }$_mm" ;; esac; done
		[ "$_mch" = 1 ] || continue
		SC_DEVS=$_mk; SC_VER=$((SC_VER + 1)); sc_write "$_mo"
	done
	sc_num _ma "$(cat "$1/.last-id" 2>/dev/null | tr -cd '0-9')" 0; sc_num _ml "$(cat "$SC_DIR/.last-id" 2>/dev/null | tr -cd '0-9')" 0
	[ "$_ma" -gt "$_ml" ] && [ "$_ma" -le 999999 ] && echo "$_ma" > "$SC_DIR/.last-id"
	sc_want_sync
	sc_tick_locked
	jok "\"n\":$(set -- $_mi; echo $#)"
}

# Does any switched-on schedule use «limited» in its week (a window or the state outside them) or safe search? packages.sh asks before removing
# the filter component: without it those devices would go fully open. rc 0 = yes.
cmd_uses_filter() {
	for _ui in $(sc_ids); do
		sc_load "$_ui" || continue
		[ "$SC_ON" = 1 ] || continue
		[ "$SC_BASE" = limited ] && return 0
		[ "$SC_SAFE" = 1 ] && return 0
		case "$SC_NL$SC_WINS" in *" limited$SC_NL"*) return 0 ;; esac
	done
	return 1
}
# «Перезапустить» (packages.sh, after a new build of the binary): the daemon goes, the tick brings it back if something is
# limited now. rc 0 = nothing limited, or the new process answers its probe.
cmd_filter_restart() {
	sc_lock || { echo "расписания сейчас меняет другой запрос — повторите"; return 1; }
	sc_fstop
	SC_FFAILED=""
	sc_tick_locked
	# the tick's sc_ffail takes the limited lines out of the plan — «nothing limited» was then said of a filter that did not come up
	if [ -n "$SC_FFAILED" ]; then echo "фильтр не поднялся — устройства с «ограничено» открыты (подробности в $SC_FLOG)"; return 1; fi
	[ -z "$SC_FMAP" ] && [ -z "$(printf '%s\n' "$SC_PLAN" | awk '$2 == "limited" || $2 == "safe"')" ] && { echo "сейчас ничего не ограничено — фильтр не нужен"; return 0; }
	if sc_falive && "$SC_FBIN" -q "$(printf '%s\n' "$SC_FMAP" | awk 'NF == 2 { print $2; exit }')"; then echo "фильтр перезапущен: $(sc_fpid)"; return 0; fi
	echo "фильтр не поднялся — устройства с «ограничено» открыты (подробности в $SC_FLOG)"; return 1
}

# ---- diagnostics --------------------------------------------------------------------------------------------------
cmd_dump() {
	sc_now
	echo "время: $(date '+%Y-%m-%d %H:%M %Z' 2>/dev/null) · сверено: $(clock_trusted && echo да || echo НЕТ — расписания не действуют)"
	sc_all_get && echo "«Закрыть всем»: до $([ "$SC_AU" = 0 ] && echo 'отмены' || { sc_at "$SC_AU"; echo "$SC_AT"; })"
	for _di in $(sc_ids); do
		sc_load "$_di" || continue
		sc_eval 1; sc_effective
		# by id, not by name: the dump goes into a chat, and a schedule is named after a person («Маша») more often than not
		echo "$_di: вкл=$SC_ON вне окон=$SC_BASE сейчас=$SC_ST ($SC_WHY) устройств=$(set -- $SC_DEVS; echo $#) окон=$(printf '%s' "$SC_WINS" | grep -c . || true) безопасный поиск=$SC_SAFE «ограничено»: $SC_LMODE [${SC_CATON:-—}] пулов=$(set -- $SC_GEO; echo $#) [${SC_GEO:-—}] своих сайтов=$(printf '%s\n' "$SC_SITES" | grep -c . || true) адресов=$(set -- $SC_ADDRS; echo $#)"
	done
	# the filter of «limited»: component, state, the daemon, its config (ports and lists) and the last lines of its log
	echo "фильтр «ограничено»: компонент $([ -x "$(bin_path dns-filter)" ] && echo есть || echo НЕТ) · состояние $(cat "$SC_RUN/filter.state" 2>/dev/null || echo —) · процесс $(sc_falive && echo "жив ($(sc_fpid))" || echo нет)"
	grep -E '^(list|port) ' "$SC_FDIR/conf" 2>/dev/null | sed 's/^/  /'
	iptables -t nat -S "$SC_NAT" 2>/dev/null | sed 's/^/  v4 nat /'
	have_v6 && ip6tables -t nat -S "$SC_NAT" 2>/dev/null | sed 's/^/  v6 nat /'
	tail -n 5 "$SC_FLOG" 2>/dev/null | sed 's/^/  лог: /'
	# the address sets (messengers): which stand and how big — a set the rules name and the kernel lacks is the rake to see here
	for _ds in $(ipset list -n 2>/dev/null | grep -E '^enodia_sch6?_'); do
		echo "  набор $_ds: $(ipset list "$_ds" 2>/dev/null | grep -cE '^[0-9a-f]+[.:]' || true) адресов"
	done
	sed 's/^/  в плане: /' "$SC_APPLIED.sets" 2>/dev/null | grep -v ': $'
	_dn=$(grep -c . "$SC_APPLIED" 2>/dev/null || true)
	echo "в ядре (план): ${_dn:-0} устройств закрыто/ограничено"
	# MACs as they are: dump.sh masks its whole output with the one redact() of the project
	iptables -S "$SC_CHAIN" 2>/dev/null | sed 's/^/  v4 /'
	iptables -C FORWARD -j "$SC_CHAIN" 2>/dev/null && echo "  v4 прыжок из FORWARD: есть"
	have_v6 && ip6tables -C FORWARD -j "$SC_CHAIN" 2>/dev/null && echo "  v6 прыжок из FORWARD: есть"
	[ -f /etc/config/parentalctl ] && [ "$(uci -q get parentalctl.global.disabled 2>/dev/null)" = 0 ] && \
		echo "ВНИМАНИЕ: включено стоковое родительское управление Xiaomi (parentalctl) — два движка правил одновременно"
	return 0
}

SC_VERB=${1:-}; [ $# -gt 0 ] && shift
case "$SC_VERB" in
	list-json) cmd_list_json ;;
	get-json)  cmd_get_json "${1:-}" ;;
	save)      cmd_save "${1:-}" ;;
	del)       cmd_del "${1:-}" ;;
	toggle)    cmd_toggle "$@" ;;
	ovr)       cmd_ovr "$@" ;;
	all)       cmd_all "${1:-}" ;;
	hol)       cmd_hol "$@" ;;
	import)    cmd_import "${1:-}" ;;
	tick)      cmd_tick "${1:-}" ;;
	unwire)    cmd_unwire ;;
	dump)      cmd_dump ;;
	uses-filter)    cmd_uses_filter ;;
	filter-restart) cmd_filter_restart ;;
	*) echo "usage: access-sched.sh list-json|get-json <id>|save <spec>|del <id>|toggle <id> on|off|ovr <id> …|all …|hol <id> …|import <dir>|tick|unwire|dump|uses-filter|filter-restart"; exit 1 ;;
esac
