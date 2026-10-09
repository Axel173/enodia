#!/bin/sh
# tasks.sh — «ЗАДАЧИ»: the panel's cron manager. ONE owner of the user's schedule and THE runner of user tasks.
#
# Why a registry and not "edit crontab lines": a cron line can carry neither a name, nor a script body, nor a timeout, nor
# «at boot» (busybox crond has no @reboot), nor «mail me on failure». So a task lives in a REGISTRY on /data
# ($ENODIA_STATE/tasks/: <id>.task settings, <id>.body script, <id>.env variables), and its cron line is DERIVED from it
# (`apply`). The line goes through the resident bootstrap like every line of ours (`boot.sh tasks.sh run <id> sched`):
# code may live on a USB drive, and `uninstall.sh::cron_ours` recognises our lines by that very path — so deactivation and
# removal take user tasks along without a second list.
#
# Three kinds of crontab lines, and this file is honest about all of them (decision 07.10.2026, «risk is on the user»):
#   * task lines (signature TK_SIG) — rewritten from the registry on every save; editing them by hand is pointless;
#   * Enodia lines (bootstrap / code dir) — their OWNERS rewrite them (install, update-sched, cron-restore); read-only here;
#   * every other line — FOREIGN (firmware, hand-made, the SSH-access patch): edit, disable (`# `), delete, adopt — by
#     EXACT CONTENT, not by line number: the file can change between the panel's read and its write (another writer,
#     a firmware update), and a number would then hit a different line.
# The raw tab saves the whole file, but every line is validated FIRST: busybox crond silently skips a line it cannot
# parse, so a typo would look like «the task just never runs». It saves against the version it was opened on (`rev`): a
# file changed meanwhile (a task saved, another tab, update-sched) is refused, not overwritten; and task lines in it are
# derived as on every save — the answer carries the file as it now is, so the tab shows what cron really has.
#
# Cron syntax = what busybox 1.25 crond ACCEPTS, not vixie: lists, ranges, `*/n`, `a-b/n`, 3-letter names; NO @macros,
# NO `VAR=value` lines, day of week 0..6 (7 is rejected by crond), a step only after `*` or a range (busybox reads `5/10`
# as just 5 — vixie as 5..59/10; rejecting it beats a schedule that silently means something else), ranges ascending.
# Day-of-month and day-of-week combine like busybox FixDayDow: one of them restricted ⇒ only it counts, both ⇒ OR. crond keeps
# days in slots 0..31 and a `*` fills them FROM 0: `*/2` is days 0,2,4… (even), `*/7` — 7,14,21,28 (slot 0 never matches);
# «restricted» = some slot of 0..31 empty, so `*,5` is NOT restricted and `1-31` IS (review s.106: the panel showed odd days).
# The next runs are computed HERE, in the router's own calendar (its TZ), so the panel shows them without arithmetic.
#
# Adopted lines («Взять под управление») and the «off» form of the crontab — see «adopted lines» below the registry.
# Task ids are never reused (`.last-id`): a delete's delayed cleanup of RAM state would otherwise hit a task born in its place.
#
# Runner (`run <id> <sched|boot|manual>`): per-task lock (skip / wait / run alongside), optional wait for sane clocks
# (after a reboot the clock sits in the past until synced — clock-lib.sh), timeout that kills the WHOLE process tree
# (a script's `ping` would outlive a killed `sh`), output cap while running (/tmp is RAM: `yes` in a task would eat it),
# last 32 KB of output kept per run in RAM (no flash writes per run), history in RAM, failure → events journal / mail.
#
# Usage:
#   tasks.sh list-json | get-json <id> | explain "<m h dom mon dow>" | raw-get
#   tasks.sh save <specfile> | del <id> | toggle <id> on|off | dup <id> | run-bg <id> | stop <id>
#   tasks.sh line-set <old_b64> <new_b64> | line-toggle <old_b64> | adopt <old_b64> | raw-save <b64file>
#   tasks.sh file-get <path> | file-put <path> <b64file>
#   tasks.sh apply [<prepared crontab>] | import <archive tasks dir> <full 0|1> | boot | run <id> <trigger> | run-delayed <id> <sec>
# JSON verbs print one JSON object; messages are Russian (the panel translates them by its dictionary).

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BOOT=${ENODIA_BOOT:-/data/usr/app/enodia-boot}
TK_DIR="$ENODIA_STATE/tasks"
TK_RUN=/tmp/enodia-tasks            # RAM: locks, history, outputs — gone with a reboot by design
TK_LOCK="$TK_RUN/registry.lock"     # serialises registry + crontab writes of this owner; inside the 700 RAM dir (tk_rundir):
                                    # on a shared /tmp name, anything laid there by another process held the lock for good
CRON=/etc/crontabs/root
CRON_RUN="$ENODIA_BOOT/boot.sh"
TK_SIG="boot.sh tasks.sh run "      # signature of task lines: the owner key for `apply`
TK_BODY_MAX=16384                   # script size (the CGI body is 32 KB, base64 adds a third)
TK_OUT_KEEP=32768                   # output kept per run
TK_OUT_CAP=524288                   # output allowed WHILE running; beyond it the run is cut (RAM)
TK_FILE_MAX=16384                   # «open and edit the file» / raw crontab: what a save can carry back (the CGI body is 32 KB)
TK_NOTE_GAP=3600                    # one word (journal line / letter) per task and outcome per this many seconds
TK_CR=$(printf '\r')
TK_TAB=$(printf '\t')
TK_OFF="$ENODIA_STATE/.tasks-off"   # exists only in the «off» form: the plain lines we wrote (see «adopted lines»)

if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '\000-\010\013-\037' | tr '\n\t' '  ' | cut -c1-"$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
# the tree walk's owner is daemon-lib.sh (same package); without it a timeout kills the top process only
command -v proc_tree >/dev/null 2>&1 || proc_tree() { echo "$1"; }
command -v daemon_step_init >/dev/null 2>&1 || daemon_step_init() { DAEMON_STEP_Q=1; }
command -v daemon_step >/dev/null 2>&1 || daemon_step() { sleep 1; }

b64() { base64 2>/dev/null | tr -d '\n'; }
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }
jstr() { printf '%s' "$1" | jtxt "${2:-200}"; }
jok() { printf '{"ok":true%s}\n' "${1:+,$1}"; }
jfail() { printf '{"ok":false,"msg":"%s"%s}\n' "$(jstr "$1" 400)" "${2:+,$2}"; exit 0; }
# the ONE form of an id: no leading zero (`t01` and `t1` would be two files of one number), at most six digits
id_ok() { printf '%s' "$1" | grep -qE '^t[1-9][0-9]{0,5}$'; }
# a decimal of at most 6 digits without leading zeros, else $2: `010` is octal in ash arithmetic (an archive's counter gave t9 and
# overwrote it), `08` a fatal error — review s.113, the twin of access-sched.sh's sc_new_id
tk_dec() {
	_td=$1; case "$_td" in ''|*[!0-9]*) echo "$2"; return 0 ;; esac
	while :; do case "$_td" in 0?*) _td=${_td#0} ;; *) break ;; esac; done
	if [ "${#_td}" -le 6 ]; then echo "$_td"; else echo "$2"; fi
}
now_local() { date '+%Y-%m-%d %H:%M' 2>/dev/null; }
# sh single-quote: the path goes into a command line the user's shell syntax surrounds
tk_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---- RAM dir, lock, cleanup ---------------------------------------------------------------------------------------
# /tmp is shared with stock daemons (some run as nobody): a symlink or a foreign directory laid on our name beforehand would
# turn every write of ours into a write as root into ITS target (the class cap_run in cgi-bin/action is built against).
# So the directory is ours only when it is a real directory owned by root; anything else is removed and made anew, 700.
tk_rundir() {
	if [ -L "$TK_RUN" ] || { [ -e "$TK_RUN" ] && { [ ! -d "$TK_RUN" ] || [ "$(stat -c %u "$TK_RUN" 2>/dev/null)" != "$(id -u)" ]; }; }; then
		rm -rf "$TK_RUN" 2>/dev/null
	fi
	[ -d "$TK_RUN" ] || ( umask 077; mkdir "$TK_RUN" ) 2>/dev/null
	[ -d "$TK_RUN" ] && [ ! -L "$TK_RUN" ]
}
TK_LOCKED=0; TK_TMP=""; TK_DROP=""
tk_exit() { _xr=$?; [ "$TK_LOCKED" = 1 ] && tk_link_drop "$TK_LOCK"; [ -n "$TK_TMP" ] && rm -rf "$TK_TMP" 2>/dev/null; return "$_xr"; }
# tk_link_take <path> -> rc 0 = the lock is ours now, rc 1 = a live process holds it. Every lock of this file (registry, a task's
# run, its wait place) is a SYMBOLIC LINK whose target is the holder's pid, made in one step: a lock never exists without its pid
# (a mkdir-then-echo lock had that moment — a reader took a live lock then, or a TERM in it left a lock nobody removed; review
# s.106). A dead holder's lock is moved aside under our OWN name before it goes: of two takers that saw the same dead pid only one
# moves it, and the other finds it moved the winner's fresh lock and puts it back (a remove by name removed that live lock — two
# runs together, round 4). Left open: a THIRD taker grabbing the name in the microseconds of that put-back.
# A DIRECTORY on the name is an older version's lock (mkdir + `pid` inside): held while that pid lives, cleared otherwise. It is
# checked FIRST — busybox `ln -s` makes the link INSIDE an existing directory and returns 0, so the lock «succeeded» for everyone
# and the run went alongside a live one (round 5). `-n`: a link to a directory is a name, not a place to write into.
tk_link_take() {
	_kn=0
	while [ "$_kn" -lt 50 ]; do
		_kn=$((_kn + 1))
		if [ -d "$1" ] && [ ! -L "$1" ]; then
			_kd=$(cat "$1/pid" 2>/dev/null)
			case "$_kd" in ''|*[!0-9]*) ;; *) [ -d "/proc/$_kd" ] && return 1 ;; esac
			rm -rf "$1" 2>/dev/null; continue
		fi
		ln -sn "$$" "$1" 2>/dev/null && return 0
		_kh=$(readlink "$1" 2>/dev/null)
		case "$_kh" in
			'') { [ -e "$1" ] || [ -L "$1" ]; } && rm -rf "$1" 2>/dev/null; continue ;;
			*[!0-9]*) rm -f "$1" 2>/dev/null; continue ;;
		esac
		[ -d "/proc/$_kh" ] && return 1
		mv -f "$1" "$1.x$$" 2>/dev/null || continue
		_kg=$(readlink "$1.x$$" 2>/dev/null)
		[ "$_kg" = "$_kh" ] || ln -sn "$_kg" "$1" 2>/dev/null
		rm -f "$1.x$$"
	done
	return 1
}
tk_link_drop() { [ "$(readlink "$1" 2>/dev/null)" = "$$" ] && rm -f "$1"; return 0; }
# tk_lock [soft] — the registry and crontab writes of this owner. soft: rc 1 when busy (system callers: uninstall, heal, the
# backup import read the code), otherwise a JSON refusal for the panel
tk_lock() {
	_lw=0
	tk_rundir || { [ "${1:-}" = soft ] && return 1; jfail "не удалось создать каталог задач в памяти"; }
	until tk_link_take "$TK_LOCK"; do
		_lw=$((_lw + 1))
		if [ "$_lw" -gt 20 ]; then [ "${1:-}" = soft ] && return 1; jfail "задачи сейчас меняет другой запрос — повторите через минуту"; fi
		sleep 1
	done
	TK_LOCKED=1
}
tk_unlock() { [ "$TK_LOCKED" = 1 ] && tk_link_drop "$TK_LOCK"; TK_LOCKED=0; return 0; }

# ---- cron field expansion (busybox 1.25 grammar, see the header) --------------------------------------------------
# tk_num <token> <kind> -> number (names allowed for mon/dow), rc 1 on garbage
tk_num() {
	case "$1" in
		''|*[!0-9A-Za-z]*) return 1 ;;
		*[!0-9]*)
			_tn=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
			case "$2" in
				mon) case "$_tn" in jan) echo 1;; feb) echo 2;; mar) echo 3;; apr) echo 4;; may) echo 5;; jun) echo 6;;
				                    jul) echo 7;; aug) echo 8;; sep) echo 9;; oct) echo 10;; nov) echo 11;; dec) echo 12;; *) return 1;; esac ;;
				dow) case "$_tn" in sun) echo 0;; mon) echo 1;; tue) echo 2;; wed) echo 3;; thu) echo 4;; fri) echo 5;; sat) echo 6;; *) return 1;; esac ;;
				*) return 1 ;;
			esac ;;
		*) [ "${#1}" -le 4 ] || return 1
		   _tz=$(printf '%s' "$1" | sed 's/^0*//'); echo "${_tz:-0}" ;;   # textually: `$((08))` is an octal error in ash
	esac
}
# tk_expand <field> <lo> <hi> <kind> -> TKX=" n n n " (ascending, de-duplicated), TKE = reason on failure (rc 1)
tk_expand() {
	TKX=" "; TKE=""; _xf=$1; _xlo=$2; _xhi=$3; _xk=$4
	[ -n "$_xf" ] || { TKE="пустое поле"; return 1; }
	_xrest="$_xf,"
	while [ -n "$_xrest" ]; do
		_xit=${_xrest%%,*}; _xrest=${_xrest#*,}
		[ -n "$_xit" ] || { TKE="пустой элемент списка: $_xf"; return 1; }
		_xst=1; _xhas=0
		case "$_xit" in */*) _xst=${_xit#*/}; _xit=${_xit%/*}; _xhas=1
			case "$_xst" in ''|*[!0-9]*) TKE="шаг — число: $_xf"; return 1 ;; esac
			_xst=$(tk_num "$_xst" min) || { TKE="шаг — число: $_xf"; return 1; }
			[ "$_xst" -ge 1 ] || { TKE="шаг — от 1: $_xf"; return 1; } ;;
		esac
		_xstar=0
		case "$_xit" in
			'*') _xa=$_xlo; _xb=$_xhi; _xstar=1; [ "$_xk" = dom ] && _xa=0 ;;   # crond's day slots start at 0 (see the header)
			*-*) _xa=$(tk_num "${_xit%%-*}" "$_xk") || { TKE="не число: $_xf"; return 1; }
			     _xb=$(tk_num "${_xit#*-}" "$_xk") || { TKE="не число: $_xf"; return 1; } ;;
			*)   [ "$_xhas" = 1 ] && { TKE="шаг — только после «*» или диапазона (например 0-59/10): $_xf"; return 1; }
			     _xa=$(tk_num "$_xit" "$_xk") || { TKE="не число: $_xf"; return 1; }; _xb=$_xa ;;
		esac
		[ "$_xstar" = 1 ] || { [ "$_xa" -ge "$_xlo" ] && [ "$_xb" -le "$_xhi" ]; } || { TKE="вне диапазона $_xlo–$_xhi: $_xf"; return 1; }
		[ "$_xa" -le "$_xb" ] || { TKE="диапазон — по возрастанию: $_xf"; return 1; }
		_xi=$_xa
		while [ "$_xi" -le "$_xb" ]; do
			case "$TKX" in *" $_xi "*) ;; *) TKX="$TKX$_xi " ;; esac
			_xi=$((_xi + _xst))
		done
	done
	# ascending order (busybox sort has no -k, a plain numeric sort of one column is fine)
	TKX=" $(printf '%s\n' $TKX | sort -n | tr '\n' ' ')"
	return 0
}
# tk_sched_parse "<m h dom mon dow>" -> TK_M TK_H TK_D TK_MO TK_W lists, TK_DU/TK_WU «restricted» flags; TKE on failure
tk_sched_parse() {
	# the alphabet first: a newline would split into a 5-field «valid» schedule and then into a SECOND crontab line
	case "$1" in *[!0-9A-Za-z\ \*/,-]*) TKE="в расписании — только цифры, названия, пробелы и * / , -"; return 1 ;; esac
	set -f; set -- $1; set +f
	[ "$#" -eq 5 ] || { TKE="в расписании нужно ровно пять полей: минута, час, день месяца, месяц, день недели"; return 1; }
	tk_expand "$1" 0 59 min || { TKE="минута: $TKE"; return 1; }; TK_M=$TKX
	tk_expand "$2" 0 23 hour || { TKE="час: $TKE"; return 1; }; TK_H=$TKX
	tk_expand "$3" 1 31 dom || { TKE="день месяца: $TKE"; return 1; }; TK_D=$TKX
	tk_expand "$4" 1 12 mon || { TKE="месяц: $TKE"; return 1; }; TK_MO=$TKX
	tk_expand "$5" 0 6 dow || { TKE="день недели (0–6, воскресенье — 0): $TKE"; return 1; }; TK_W=$TKX
	# busybox FixDayDow: «used» = not every slot set — for days, slots 0..31 (32 values), slot 0 filled only by a `*`
	set -- $TK_D; if [ "$#" -ge 32 ]; then TK_DU=0; else TK_DU=1; fi
	if [ "$TK_W" = " 0 1 2 3 4 5 6 " ]; then TK_WU=0; else TK_WU=1; fi
	return 0
}
tk_dim() {   # days in month <y> <m> -> TKD (a variable, not stdout: the next-run loop calls it per day, a fork each was slow)
	case "$2" in 4|6|9|11) TKD=30 ;;
		2) if [ $(($1 % 4)) -eq 0 ] && { [ $(($1 % 100)) -ne 0 ] || [ $(($1 % 400)) -eq 0 ]; }; then TKD=29; else TKD=28; fi ;;
		*) TKD=31 ;; esac
}
# tk_next <count> -> lines "YYYY-MM-DD HH:MM" of the next runs after now (router calendar), from the parsed TK_* lists.
# Day by day up to ~4 years (29 Feb), then hour and minute lists: cheap even on the slowest supported router.
tk_next() {
	_nc=$1; _nf=0
	set -- $(date '+%Y %m %d %H %M %w')
	_ny=$1; _nm=$(tk_num "$2" min); _nd=$(tk_num "$3" min); _nH=$(tk_num "$4" min); _nM=$(tk_num "$5" min); _nw=$6
	_nday=0
	while [ "$_nday" -le 1470 ] && [ "$_nf" -lt "$_nc" ]; do
		_nok=0
		case "$TK_MO" in *" $_nm "*)
			_dm=0; _wm=0
			case "$TK_D" in *" $_nd "*) _dm=1 ;; esac
			case "$TK_W" in *" $_nw "*) _wm=1 ;; esac
			if [ "$TK_DU" = "$TK_WU" ]; then
				if [ "$TK_DU" = 0 ] || [ "$_dm" = 1 ] || [ "$_wm" = 1 ]; then _nok=1; fi
			elif [ "$TK_DU" = 1 ]; then _nok=$_dm
			else _nok=$_wm
			fi ;;
		esac
		if [ "$_nok" = 1 ]; then
			for _hh in $TK_H; do
				[ "$_nday" = 0 ] && [ "$_hh" -lt "$_nH" ] && continue
				for _mm in $TK_M; do
					[ "$_nday" = 0 ] && [ "$_hh" -eq "$_nH" ] && [ "$_mm" -le "$_nM" ] && continue
					printf '%04d-%02d-%02d %02d:%02d\n' "$_ny" "$_nm" "$_nd" "$_hh" "$_mm"
					_nf=$((_nf + 1)); [ "$_nf" -ge "$_nc" ] && return 0
				done
			done
		fi
		_nd=$((_nd + 1)); _nw=$(( (_nw + 1) % 7 )); _nday=$((_nday + 1))
		tk_dim "$_ny" "$_nm"
		if [ "$_nd" -gt "$TKD" ]; then _nd=1; _nm=$((_nm + 1)); [ "$_nm" -gt 12 ] && { _nm=1; _ny=$((_ny + 1)); }; fi
	done
	return 0
}
tk_next_json() {   # "<sched>" <count> -> JSON array of local times (empty array for no schedule / no run soon)
	[ -n "$1" ] || { printf '[]'; return 0; }
	tk_sched_parse "$1" || { printf '[]'; return 0; }
	printf '['; _nj=0
	for _nt in $(tk_next "$2" | tr ' ' '_'); do
		[ "$_nj" = 1 ] && printf ','; _nj=1; printf '"%s"' "$(printf '%s' "$_nt" | tr '_' ' ')"
	done
	printf ']'
}

# ---- crontab lines ----------------------------------------------------------------------------------------------
# tk_line_check <line> -> TKL = blank|comment|cron ; for cron: TKL_S (5 fields), TKL_C (command); TKE on invalid (rc 1)
tk_line_check() {
	TKL=""; TKL_S=""; TKL_C=""; TKE=""
	_lc=$(printf '%s' "$1" | sed 's/^[[:space:]]*//')
	case "$_lc" in
		'') TKL=blank; return 0 ;;
		'#'*) TKL=comment; return 0 ;;
		'@'*) TKE="@-сокращения busybox cron не понимает — нужны пять полей; «при загрузке» — настройка задачи"; return 1 ;;
	esac
	if printf '%s' "$_lc" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
		TKE="строки-переменные cron этого роутера не понимает — переменные задаются в настройках задачи"; return 1
	fi
	set -f; set -- $_lc; set +f
	[ "$#" -ge 6 ] || { TKE="нужны пять полей расписания и команда"; return 1; }
	TKL_S="$1 $2 $3 $4 $5"
	tk_sched_parse "$TKL_S" || return 1
	TKL_C=$(printf '%s' "$_lc" | sed 's/^\([^[:space:]][^[:space:]]*[[:space:]][[:space:]]*\)\{5\}//')
	[ -n "$TKL_C" ] || { TKE="нет команды"; return 1; }
	TKL=cron; return 0
}
# an Enodia line = the bootstrap or the code dir (the same test as uninstall.sh::cron_ours), but not a task line
tk_is_ours() { case "$1" in *"$TK_SIG"*) return 1 ;; *"$ENODIA_BOOT/boot.sh"*|*"$ENODIA_DIR/"*) return 0 ;; esac; return 1; }
tk_is_task() { case "$1" in *"$TK_SIG"*) return 0 ;; esac; return 1; }
restart_cron() {
	/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/crond restart >/dev/null 2>&1 \
		|| killall -HUP crond 2>/dev/null || true
}
# tk_cron_put <newfile in RAM> — replace the crontab if it changed, restart crond. The new file is built in RAM and copied next to
# the crontab, COMPARED, and only then renamed over it (tk_put): /etc/crontabs is the small cfg volume (4.7 MB on BE10000), and a
# derivation written straight there was renamed over the live file cut short when the volume was full — the firmware's lines and
# every foreign one gone (review s.106, round 4).
tk_cron_put() {
	mkdir -p "${CRON%/*}" 2>/dev/null
	if [ -f "$CRON" ] && cmp -s "$1" "$CRON"; then rm -f "$1"; return 0; fi
	tk_put "$1" "$CRON" || { rm -f "$1"; return 1; }
	rm -f "$1"; restart_cron; return 0
}
tk_each_line() {   # print the crontab line by line, the last line too even without a trailing newline
	[ -f "$CRON" ] || return 0
	while IFS= read -r _el || [ -n "$_el" ]; do printf '%s\n' "$_el"; done < "$CRON"
}

# ---- registry ---------------------------------------------------------------------------------------------------
tk_defaults() {
	T_NAME=""; T_ENABLED=1; T_KIND=script; T_LANG=sh; T_TARGET=""; T_ARGS=""; T_SCHED=""; T_BOOT=0; T_DELAY=60
	T_TIMEOUT=300; T_OVERLAP=skip; T_PRIO=low; T_CLOCK=1; T_WORKDIR=""; T_KEEP=5; T_MAIL=fail; T_JOURNAL=0
	T_ORIGIN=""   # base64 of the crontab line the task was adopted from (see «adopted lines»)
}
tk_load() {   # tk_load <id> -> T_* ; rc 1 when there is no such task
	tk_defaults
	[ -f "$TK_DIR/$1.task" ] || return 1
	while IFS= read -r _tl || [ -n "$_tl" ]; do
		_tl=${_tl%"$TK_CR"}; _tv=${_tl#*=}   # a hand edit or an imported archive may carry CR; it would go raw into the JSON
		case "${_tl%%=*}" in
			name) T_NAME=$_tv ;; enabled) T_ENABLED=$_tv ;; kind) T_KIND=$_tv ;; lang) T_LANG=$_tv ;;
			target) T_TARGET=$_tv ;; args) T_ARGS=$_tv ;; sched) T_SCHED=$_tv ;; boot) T_BOOT=$_tv ;; delay) T_DELAY=$_tv ;;
			timeout) T_TIMEOUT=$_tv ;; overlap) T_OVERLAP=$_tv ;; prio) T_PRIO=$_tv ;; clockwait) T_CLOCK=$_tv ;;
			workdir) T_WORKDIR=$_tv ;; keep) T_KEEP=$_tv ;; mail) T_MAIL=$_tv ;; journal) T_JOURNAL=$_tv ;;
			origin) T_ORIGIN=$_tv ;;
		esac
	done < "$TK_DIR/$1.task"
	# The file is ours only by convention (hand edits, archives): every enum and flag goes into JSON and decisions unquoted,
	# so a value outside its set reads as the default, and a schedule outside cron's alphabet as «no schedule».
	case "$T_ENABLED" in 0|1) ;; *) T_ENABLED=0 ;; esac
	case "$T_KIND" in script|file|cmd) ;; *) T_KIND=cmd ;; esac
	case "$T_LANG" in sh|lua|auto) ;; *) T_LANG=sh ;; esac
	case "$T_OVERLAP" in skip|wait|par) ;; *) T_OVERLAP=skip ;; esac
	case "$T_PRIO" in normal|low) ;; *) T_PRIO=low ;; esac
	case "$T_MAIL" in never|fail|always) ;; *) T_MAIL=fail ;; esac
	case "$T_BOOT" in 0|1) ;; *) T_BOOT=0 ;; esac
	case "$T_CLOCK" in 0|1) ;; *) T_CLOCK=1 ;; esac
	case "$T_JOURNAL" in 0|1) ;; *) T_JOURNAL=0 ;; esac
	case "$T_KEEP" in 0|1|5) ;; *) T_KEEP=5 ;; esac
	case "$T_DELAY" in ''|*[!0-9]*) T_DELAY=60 ;; esac
	case "$T_TIMEOUT" in ''|*[!0-9]*) T_TIMEOUT=300 ;; esac
	case "$T_SCHED" in *[!0-9A-Za-z\ \*/,-]*) T_SCHED="" ;; esac
	case "$T_ORIGIN" in *[!A-Za-z0-9+/=]*) T_ORIGIN="" ;; esac
	return 0
}
tk_write() {   # tk_write <id> — registry file atomically (write next to it + mv)
	mkdir -p "$TK_DIR" 2>/dev/null
	{ printf 'name=%s\nenabled=%s\nkind=%s\nlang=%s\ntarget=%s\nargs=%s\nsched=%s\nboot=%s\ndelay=%s\n' \
		"$T_NAME" "$T_ENABLED" "$T_KIND" "$T_LANG" "$T_TARGET" "$T_ARGS" "$T_SCHED" "$T_BOOT" "$T_DELAY"
	  printf 'timeout=%s\noverlap=%s\nprio=%s\nclockwait=%s\nworkdir=%s\nkeep=%s\nmail=%s\njournal=%s\n' \
		"$T_TIMEOUT" "$T_OVERLAP" "$T_PRIO" "$T_CLOCK" "$T_WORKDIR" "$T_KEEP" "$T_MAIL" "$T_JOURNAL"
	  if [ -n "$T_ORIGIN" ]; then printf 'origin=%s\n' "$T_ORIGIN"; fi; } > "$TK_DIR/$1.task.new" \
		&& mv -f "$TK_DIR/$1.task.new" "$TK_DIR/$1.task"
}
# tk_put <src> <dst> — a copy that ARRIVED (compared byte for byte) next to its place, then a rename on the same file system:
# /tmp → /data is a copy, not a rename, so a plain `mv` could leave a cut script on a full flash under «saved», and a run
# starting that moment would read half of it.
# The staging name is this process's own: `root.new` is uninstall's draft beside the crontab, and a refused copy removed it (round 5).
tk_put() { cp "$1" "$2.tk$$" 2>/dev/null && cmp -s "$1" "$2.tk$$" && mv -f "$2.tk$$" "$2" && return 0; rm -f "$2.tk$$"; return 1; }
tk_ids() { for _f in "$TK_DIR"/t*.task; do [ -f "$_f" ] || continue; _b=${_f##*/}; echo "${_b%.task}"; done | grep -E '^t[1-9][0-9]{0,5}$' | sed 's/^t//' | sort -n | sed 's/^/t/'; }
tk_new_id() {   # under the lock; the highest id ever given (`.last-id`) + 1, never a deleted one's
	_ni=$(tk_ids | sed 's/^t//' | tail -n 1); _nl=$(tk_dec "$(cat "$TK_DIR/.last-id" 2>/dev/null)" 0)
	[ "${_ni:-0}" -ge "$_nl" ] || _ni=$_nl
	_ni=$(( ${_ni:-0} + 1 ))
	# past six digits (a crafted counter) — the lowest free number; and never a number whose file is there
	[ "$_ni" -le 999999 ] || _ni=1
	while [ -f "$TK_DIR/t$_ni.task" ]; do _ni=$((_ni + 1)); done
	mkdir -p "$TK_DIR" 2>/dev/null; echo "$_ni" > "$TK_DIR/.last-id"
	echo "t$_ni"
}

# ---- adopted lines and the «off» form ---------------------------------------------------------------------------------
# A task taken over from a crontab line keeps that line (`origin`). While Enodia is deactivated or removed, our task lines are
# gone (`cron_ours`), and the line the task replaced must live on without us — the firmware's SSH-access patch among them. So
# the crontab has TWO forms, derived from the same registry:
#   * on  — a task line for every enabled task with a schedule (the runner gives history, timeout, letters);
#   * off — NO task lines at all, and every adopted task as a plain cron line: its current command and schedule when cron can
#           run it alone (a command, a schedule, no variables, no working dir), commented out when the task is disabled or
#           cannot live without Enodia (a script, variables, no schedule) — a trace of the line, never a run nobody kept.
# THE FORM IS A FACT OF THE CRONTAB ITSELF: «on» while Enodia's own schedule is in it (an active heal.sh line of ours — the line
# uninstall removes on deactivate and purge, and cron-restore, install and update put back), «off» otherwise (tk_sys_on). Two
# switch verbs that callers had to remember were the defect class of round 4: a failed or skipped `activate` left every task
# silent on an active router for good, and boot tasks ran on a deactivated one. Now every derivation — boot, update, import,
# any edit — reads the form from what it derives, and uninstall hands its stripped crontab to `apply` in the SAME write.
# Which plain line is whose. A line we write carries the MARK of its task's family: `#enodia-task:<hash of the adopted line>`, a
# shell comment at the end of the command. The mark is what survives us — a purge leaves the line, and an archive imported after
# a reinstall (an older one too, the schedule edited since) is recognised by it, not by its text (round 4: the leftover ran beside
# the re-imported task). A hash of the LINE, not of a task id: ids are per router, and the same firmware line adopted on two
# routers is one family. The record $TK_OFF (exists only in the «off» form) holds what we wrote per task, with its mark — so the
# next derivation replaces exactly those lines, and an entry counts only while the task under that id carries the same mark
# (an import may have put another task there — the line is then just a line, never removed: round 4 lost the SSH patch so).
# The family's UNMARKED lines — the task's job word for word, and the line it came from while the task still runs that command
# (the firmware putting its line back, the human copying it, another schedule or spacing of the same line) — are taken back by
# the task whenever its own line runs, in BOTH forms: they are the same job, never a reason to disable it (round 5: the off form
# let them stand and wrote ours beside the same command with another text — twice, for good). Per adopted task, from the record
# and the file, «another line of the family» = one with the mark that is not ours as written (the human's edit, a leftover):
#   ours  — our line is there as written (or as we would write it now: a write that never got its record) → written anew; with
#           the human's ACTIVE version beside it, that one stands and the task is disabled;
#   gone  — not there: the human edited it (another line of the family) or removed an active one → the task is disabled —
#           theirs, never run beside it; a removed trace stays removed;
#   taken — written nothing last time (the human's line stood) → nothing, unless the human enabled the task again and no active
#           line of the family is left (a trace is never written again);
#   new   — no record: written, unless an active line of the family is there (a purge's leftover — that one stands; enabled, the
#           task takes it back in the «on» form).
# In the «on» form an enabled task takes back every line of its family — the marked ones and the unmarked ones (edited to another
# command, it covers the line it came from no more: round 4). One family has one task: a second enabled task of the same mark (an
# import, a hand-edited registry) is disabled, never run beside the first. The record lives outside the tasks dir and the backup:
# it describes THIS router's crontab. Nothing is marked before the crontab is written: the record and the disables follow a
# successful write — and the derived file must hold exactly the lines it was built from (a full RAM cut it short, round 5).
TK_MARK="#enodia-task:"

# tk_sys_on <crontab file> -> rc 0 when Enodia's own schedule is in it: the form of the derivation (see above)
tk_sys_on() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -qF -e "$CRON_RUN heal.sh" -e "$ENODIA_DIR/heal.sh"; }
# tk_origin_line <origin b64> -> the adopted line itself: uncommented, without a mark (a line given back once and adopted again)
tk_origin_line() { b64d "$1" | sed 's/^[[:space:]]*#[[:space:]]*//; s/[[:space:]]*#enodia-task:[0-9a-f]*[[:space:]]*$//'; }
# tk_mark <origin b64> -> TKM = the mark of the line's family
tk_mark() { TKM="$TK_MARK$(printf '%s\n' "$(tk_origin_line "$1")" | md5sum 2>/dev/null | cut -c1-8)"; }
# tk_plain <id> (after tk_load) -> TKP = the task as one plain cron line for the «off» form, TKM its mark; "" = not adopted.
# A command ending in «\» would swallow the mark into its last word — such a one is written as a trace.
tk_plain() {
	TKP=""; TKM=""
	[ -n "$T_ORIGIN" ] || return 0
	tk_mark "$T_ORIGIN"
	case "$T_TARGET" in *\\) _pq=0 ;; *) _pq=1 ;; esac
	if [ "$_pq" = 1 ] && [ "$T_KIND" = cmd ] && [ -n "$T_SCHED" ] && [ -z "$T_WORKDIR" ] && [ ! -s "$TK_DIR/$1.env" ] && tk_sched_parse "$T_SCHED"; then
		TKP="$T_SCHED $T_TARGET $TKM"; [ "$T_ENABLED" = 1 ] || TKP="# $TKP"
	else
		TKP="# $(tk_origin_line "$T_ORIGIN") $TKM"
	fi
	return 0
}
tk_drop_first() {   # stdin without the FIRST line equal to $1
	_fd=0
	while IFS= read -r _fl || [ -n "$_fl" ]; do
		if [ "$_fd" = 0 ] && [ "$_fl" = "$1" ]; then _fd=1; continue; fi
		printf '%s\n' "$_fl"
	done
}
# <file> <line>: the first equal line out, in place; TKD counts the lines dropped (the derivation's own bookkeeping, see below)
tk_drop_in() { tk_drop_first "$2" < "$1" > "$1.n" && mv -f "$1.n" "$1" && [ "$_fd" = 1 ] && TKD=$((TKD + 1)); return 0; }
tk_drop_all() {   # <file> <text>: every line with it (rc 1 of grep = none left)
	_dac=$(grep -cF -- "$2" "$1" 2>/dev/null); case "$_dac" in ''|*[!0-9]*) _dac=0 ;; esac
	grep -vF -- "$2" "$1" > "$1.n"; mv -f "$1.n" "$1" && TKD=$((TKD + _dac)); return 0
}
# tk_fam_plain (after tk_load) -> TKF_JOB, TKF_ORG: the UNMARKED lines of the task's family — its job word for word, and the line
# it came from while the task still runs that command (spaces at the end aside); "" = none
tk_fam_plain() {
	TKF_JOB=""; TKF_ORG=""
	[ "$T_KIND" = cmd ] && [ -n "$T_ORIGIN" ] || return 0
	[ -n "$T_SCHED" ] && [ -n "$T_TARGET" ] && TKF_JOB="$T_SCHED $T_TARGET"
	_fo=$(tk_origin_line "$T_ORIGIN")
	if tk_line_check "$_fo" && [ "$TKL" = cron ] \
		&& [ "$(printf '%s' "$TKL_C" | sed 's/[[:space:]]*$//')" = "$(printf '%s' "$T_TARGET" | sed 's/[[:space:]]*$//')" ]; then
		TKF_ORG=$_fo
	fi
	return 0
}
tk_fam_take() {   # <file>: the unmarked family lines out (an enabled task whose own line runs takes them back)
	[ -z "$TKF_JOB" ] || ! grep -qxF -- "$TKF_JOB" "$1" || tk_drop_in "$1" "$TKF_JOB"
	[ -z "$TKF_ORG" ] || ! grep -qxF -- "$TKF_ORG" "$1" || tk_drop_in "$1" "$TKF_ORG"
	return 0
}
# tk_derive <src> <out> — the crontab derived from <src>, in the form <src> itself says (tk_sys_on), written to <out>. Side files
# next to <src>: .rec — the record of the «off» form, .dis — ids the human took over (disabled after the write). Call under the
# lock. rc 1 = the derived file is not whole: it must hold exactly the source's lines, minus the task lines and every line dropped,
# plus every line added — a write cut short by a full RAM went through the checked copy as it was (round 5).
tk_derive() {
	_dsrc=$1; _dtk="$_dsrc.d"; _dst="$_dsrc.st"; : > "$_dsrc.rec"; : > "$_dsrc.dis"; : > "$_dst"; TKD=0; _dadd=0; _dfam=" "
	if tk_sys_on "$_dsrc"; then _dfm=on; else _dfm=off; fi
	_dn=$(( $(wc -l < "$_dsrc") )); _dsig=$(grep -cF "$TK_SIG" "$_dsrc"); case "$_dsig" in ''|*[!0-9]*) _dsig=0 ;; esac
	grep -vF "$TK_SIG" "$_dsrc" > "$_dtk"   # task lines are always derived anew
	if [ -f "$TK_OFF" ]; then
		while IFS="$TK_TAB" read -r _di _dm _db || [ -n "$_di" ]; do
			id_ok "$_di" || continue
			_dok=0
			if tk_load "$_di" && [ -n "$T_ORIGIN" ]; then tk_mark "$T_ORIGIN"; [ "$TKM" = "$_dm" ] && _dok=1; fi
			if [ "$_db" = - ]; then [ "$_dok" = 1 ] && printf '%s\ttaken\t0\n' "$_di" >> "$_dst"; continue; fi
			_dl=$(b64d "$_db"); [ -n "$_dl" ] || continue
			if [ "$_dok" = 0 ]; then
				# not this task's any more: deleted NOW — its line goes with it; replaced by an import — the line stays, a line like any
				case "$TK_DROP" in *" $_di "*) tk_drop_in "$_dtk" "$_dl" ;; esac
				continue
			fi
			if grep -qxF -- "$_dl" "$_dtk"; then tk_drop_in "$_dtk" "$_dl"; printf '%s\tours\t0\n' "$_di" >> "$_dst"
			else case "$_dl" in '#'*) _dwa=0 ;; *) _dwa=1 ;; esac; printf '%s\tgone\t%s\n' "$_di" "$_dwa" >> "$_dst"; fi
		done < "$TK_OFF"
	fi
	for _ai in $(tk_ids); do
		tk_load "$_ai" || continue
		if [ -n "$T_ORIGIN" ]; then
			tk_plain "$_ai"
			_dS=new; _dwa=0
			_dsl=$(grep "^$_ai$TK_TAB" "$_dst" | head -n 1)
			if [ -n "$_dsl" ]; then _dS=$(printf '%s' "$_dsl" | cut -f2); _dwa=$(printf '%s' "$_dsl" | cut -f3); fi
			# the line as we would write it now is ours whatever the record says (a write whose record never came: power, full flash)
			if [ "$_dS" != ours ] && grep -qxF -- "$TKP" "$_dtk"; then tk_drop_in "$_dtk" "$TKP"; _dS=ours; fi
			# gone, but the task's own task line is in the source: our «on» form replaced it (a write the record did not follow)
			if [ "$_dS" = gone ] && grep -qF "$TK_SIG$_ai " "$_dsrc"; then _dS=ours; fi
			# another line of the mark left in the file, not ours as written: the human's version of our line (or a purge's leftover) —
			# _dEa any, _dEc an ACTIVE one; a commented one only tells that the human touched ours
			_dEa=0; _dEc=0
			if grep -qF -- "$TKM" "$_dtk"; then _dEa=1; grep -v '^[[:space:]]*#' "$_dtk" | grep -qF -- "$TKM" && _dEc=1; fi
			case "$_dS" in   # the human took it over: theirs, and the task is disabled rather than run beside it
				gone) if [ "$_dEa" = 1 ] || [ "$_dwa" = 1 ]; then echo "$_ai" >> "$_dsrc.dis"; T_ENABLED=0; fi ;;
				ours) if [ "$_dEc" = 1 ]; then echo "$_ai" >> "$_dsrc.dis"; T_ENABLED=0; fi ;;
			esac
			# one family, one task: a second enabled task of the same mark is disabled, never run beside the first
			if [ "$T_ENABLED" = 1 ]; then
				case "$_dfam" in *" $TKM "*) echo "$_ai" >> "$_dsrc.dis"; T_ENABLED=0 ;; *) _dfam="$_dfam$TKM " ;; esac
			fi
			tk_plain "$_ai"   # its line as of the decisions above (a disabled task is written as a trace)
			# the family's unmarked lines are taken back whenever the task's own line runs — in both forms (see the header)
			_drun=0
			if [ "$T_ENABLED" = 1 ]; then
				if [ "$_dfm" = off ]; then case "$TKP" in '#'*|'') ;; *) _drun=1 ;; esac
				elif [ -n "$T_SCHED" ] && tk_sched_parse "$T_SCHED"; then _drun=1; fi
			fi
			tk_fam_plain
			[ "$_drun" = 1 ] && tk_fam_take "$_dtk"
			if [ "$_dfm" = off ]; then
				_dw=0
				case "$_dS" in
					ours|new) [ "$_dEc" = 0 ] && _dw=1 ;;
					taken) [ "$_dEc" = 0 ] && case "$TKP" in '#'*) ;; *) _dw=1 ;; esac ;;
				esac
				if [ "$_dw" = 1 ]; then
					printf '%s\n' "$TKP" >> "$_dtk"; _dadd=$((_dadd + 1))
					printf '%s\t%s\t%s\n' "$_ai" "$TKM" "$(printf '%s' "$TKP" | b64)" >> "$_dsrc.rec"
				else printf '%s\t%s\t-\n' "$_ai" "$TKM" >> "$_dsrc.rec"; fi
				continue
			fi
		fi
		[ "$_dfm" = on ] || continue   # the «off» form has no task lines at all
		[ "$T_ENABLED" = 1 ] && [ -n "$T_SCHED" ] && tk_sched_parse "$T_SCHED" || continue
		if [ -n "$T_ORIGIN" ]; then
			tk_drop_all "$_dtk" "$TKM"
		fi
		printf '%s %s tasks.sh run %s sched >/dev/null 2>&1\n' "$T_SCHED" "$CRON_RUN" "$_ai" >> "$_dtk"; _dadd=$((_dadd + 1))
	done
	_dgot=$(( $(wc -l < "$_dtk" 2>/dev/null || echo -1) ))
	if [ "${_dgot:-x}" != "$((_dn - _dsig - TKD + _dadd))" ]; then
		echo "tasks.sh: the derived crontab is not whole (lines $_dgot, expected $((_dn - _dsig - TKD + _dadd))) — not written" >&2
		rm -f "$_dtk" "$_dtk.n" "$_dst"; return 1
	fi
	rm -f "$_dtk.n" "$_dst"; mv -f "$_dtk" "$2"
}
# tk_apply [source] — derive and write (source: a prepared crontab — uninstall's, the raw tab's, adopt's —, default the live one),
# all of it in RAM until the checked copy (tk_cron_put). After a SUCCESSFUL write: the record follows the form, the human's tasks
# are disabled. A record that could not be written is not fatal: the next derivation knows our lines as «as we would write them».
tk_apply() {
	tk_rundir || return 1
	_ta="$TK_RUN/.apply.$$"
	# the source line by line: a prepared file without its last newline would count one line short
	if [ -n "${1:-}" ]; then
		while IFS= read -r _tal || [ -n "$_tal" ]; do printf '%s\n' "$_tal"; done < "$1" > "$_ta.src" || { rm -f "$_ta.src"; return 1; }
	else tk_each_line > "$_ta.src" || { rm -f "$_ta.src"; return 1; }; fi
	tk_derive "$_ta.src" "$_ta" || { rm -f "$_ta" "$_ta.src" "$_ta.src.rec" "$_ta.src.dis"; return 1; }
	tk_cron_put "$_ta" || { rm -f "$_ta.src" "$_ta.src.rec" "$_ta.src.dis"; return 1; }
	if [ -s "$_ta.src.rec" ]; then tk_put "$_ta.src.rec" "$TK_OFF" || echo "tasks.sh: the record of the off form was not written" >&2
	else rm -f "$TK_OFF"; fi
	while read -r _tdi; do tk_load "$_tdi" && { T_ENABLED=0; tk_write "$_tdi"; }; done < "$_ta.src.dis"
	rm -f "$_ta.src" "$_ta.src.rec" "$_ta.src.dis"
	return 0
}
# apply [<prepared crontab>] — boot (heal), install/update, uninstall (its stripped crontab: the «off» form in the same write),
# cron-restore. Exit 1 = not written (busy past 20 s, the volume refused): the caller says so instead of a silent «done».
cmd_apply() {
	[ -z "${1:-}" ] || [ -f "$1" ] || { echo "нет файла $1"; return 1; }
	tk_lock soft || { echo "задачи сейчас меняет другой запрос — расписание задач не выведено"; return 1; }
	tk_apply "${1:-}"; _apr=$?
	tk_unlock
	[ "$_apr" = 0 ] || { echo "не удалось записать crontab — расписание задач не выведено"; return 1; }
	if [ -s "$TK_OFF" ]; then
		_apn=$(grep -vc "$TK_TAB-\$" "$TK_OFF" 2>/dev/null || true)
		[ "${_apn:-0}" -gt 0 ] 2>/dev/null && echo "Enodia снята с расписания — задачи не запускаются; строк, взятых задачами из crontab, отдано обратно: $_apn"
	fi
	return 0
}

# ---- interpreters -----------------------------------------------------------------------------------------------
tk_langs() { printf '"sh"'; command -v lua >/dev/null 2>&1 && printf ',"lua"'; return 0; }
# tk_interp <file> <lang> -> TKI = interpreter command line part ("sh", "lua", shebang); TKE when unusable
tk_interp() {
	TKI=""; TKE=""
	case "$2" in
		sh) TKI=sh ;;
		lua) command -v lua >/dev/null 2>&1 || { TKE="Lua на этом роутере нет"; return 1; }; TKI=lua ;;
		*)  _sb=$(head -n 1 "$1" 2>/dev/null | tr -d '\r')
		    case "$_sb" in
			'#!'*) _sb=$(printf '%s' "$_sb" | sed 's/^#![[:space:]]*//'); set -f; set -- $_sb; set +f
			       [ -n "$1" ] || { TKE="в строке #! нет интерпретатора"; return 1; }
			       [ -x "$1" ] || command -v "$1" >/dev/null 2>&1 || { TKE="интерпретатора из строки #! на роутере нет: $1"; return 1; }
			       TKI="$*" ;;
			*) TKI=sh ;;
		    esac ;;
	esac
	return 0
}
# tk_syntax <file> -> TKE with the interpreter's own words on a syntax error (sh -n / Lua loadfile); others unchecked
tk_syntax() {
	tk_interp "$1" "$2" || return 1
	case "${TKI%% *}" in
		sh|*/sh|ash|*/ash|bash|*/bash) _se=$(sh -n "$1" 2>&1) || { TKE="ошибка синтаксиса: $(printf '%s' "$_se" | sed "s#$1: ##" | head -n 3)"; return 1; } ;;
		lua|*/lua) _se=$(lua -e "local f,e=loadfile('$1') if not f then io.stderr:write(e) os.exit(1) end" 2>&1) \
		           || { TKE="ошибка синтаксиса: $(printf '%s' "$_se" | sed "s#$1:#строка #" | head -n 3)"; return 1; } ;;
	esac
	return 0
}

# ---- JSON views -------------------------------------------------------------------------------------------------
tk_hist_last() {   # tk_hist_last <id> -> TH_* of the last history line; rc 1 when none
	_hl=$(tail -n 1 "$TK_RUN/$1.hist" 2>/dev/null)
	[ -n "$_hl" ] || return 1
	TH_TS=$(printf '%s' "$_hl" | cut -f1); TH_DUR=$(printf '%s' "$_hl" | cut -f2); TH_CODE=$(printf '%s' "$_hl" | cut -f3)
	TH_TRIG=$(printf '%s' "$_hl" | cut -f4); TH_FLAG=$(printf '%s' "$_hl" | cut -f6)
	return 0
}
# tk_running_json <id> [out] -> {"since":..,"trig":..,"dur":..[,"out":..]} | null — by the runner's pid, not by a stale file.
# dur comes from the uptime the runner noted (a clock step after boot would lie). `out` = the output SO FAR (the task screen
# follows it; without it the screen said «running» above «no runs» for the whole run) — not in the list: 32 KB per task.
# tk_cur <id> -> _rc = the line of the NEWEST live run (runs alongside each have their own `.cur.<seq>`: one shared file was
# removed by the first to finish, and the other looked stopped); rc 1 when nothing runs
tk_cur() {
	_rc=""; _rcs=-1
	for _cf in "$TK_RUN/$1".cur.*; do
		[ -f "$_cf" ] || continue
		_cs=${_cf##*.}; case "$_cs" in ''|*[!0-9]*) continue ;; esac
		_cl=$(cat "$_cf" 2>/dev/null); _cp=$(printf '%s' "$_cl" | cut -f3)
		[ -n "$_cp" ] && [ -d "/proc/$_cp" ] || continue
		[ "$_cs" -gt "$_rcs" ] && { _rc=$_cl; _rcs=$_cs; }
	done
	[ -n "$_rc" ]
}
tk_running_json() {
	if tk_cur "$1"; then
		_ru=$(uptime_s); _rd=$(( _ru - $(tk_num_or "$(printf '%s' "$_rc" | cut -f2)" "$_ru") )); [ "$_rd" -ge 0 ] || _rd=0
		printf '{"since":"%s","trig":"%s","dur":%s' "$(printf '%s' "$_rc" | cut -f1)" "$(printf '%s' "$_rc" | cut -f4)" "$_rd"
		if [ "$2" = out ]; then
			_rs=$(printf '%s' "$_rc" | cut -f5)
			case "$_rs" in ''|*[!0-9]*) printf ',"out":""' ;;
				*) printf ',"out":"%s"' "$(tail -c "$TK_OUT_KEEP" "$TK_RUN/$1.out.$_rs.run" 2>/dev/null | b64)" ;; esac
		fi
		printf '}'
	else printf 'null'; fi
}
tk_num_or() { case "$1" in ''|*[!0-9-]*) echo "$2" ;; *) echo "$1" ;; esac; }
cmd_list_json() {
	# form: «off» = Enodia is off the schedule (deactivated) — no task runs, adopted ones live as plain lines; the panel says so
	printf '{"ok":true,"now":"%s","langs":[%s],"form":"%s","tasks":[' "$(now_local)" "$(tk_langs)" "$(tk_sys_on "$CRON" && echo on || echo off)"
	_lf=1
	for _li in $(tk_ids); do
		tk_load "$_li" || continue
		[ "$_lf" = 1 ] || printf ','; _lf=0
		printf '{"id":"%s","name":"%s","enabled":%s,"kind":"%s","lang":"%s","sched":"%s","boot":%s,"next":%s' \
			"$_li" "$(jstr "$T_NAME" 400)" "$([ "$T_ENABLED" = 1 ] && echo true || echo false)" "$T_KIND" "$T_LANG" \
			"$(jstr "$T_SCHED" 120)" "$([ "$T_BOOT" = 1 ] && echo true || echo false)" \
			"$([ "$T_ENABLED" = 1 ] && tk_next_json "$T_SCHED" 1 || printf '[]')"
		if tk_hist_last "$_li"; then
			printf ',"last":{"ts":"%s","dur":%s,"code":%s,"trig":"%s","flag":"%s"}' "$TH_TS" "$(tk_num_or "$TH_DUR" 0)" \
				"$(tk_num_or "$TH_CODE" 0)" "$TH_TRIG" "$TH_FLAG"
		else printf ',"last":null'; fi
		# «off» form: the line we wrote for it is ACTIVE — it runs without Enodia (the row must not say «not run»)
		_lpl=false
		if [ -f "$TK_OFF" ]; then
			_lpb=$(grep "^$_li$TK_TAB" "$TK_OFF" 2>/dev/null | head -n 1 | cut -f3)
			case "$_lpb" in ''|-) ;; *) case "$(b64d "$_lpb")" in '#'*|'') ;; *) _lpl=true ;; esac ;; esac
		fi
		printf ',"plain":%s,"running":%s}' "$_lpl" "$(tk_running_json "$_li")"
	done
	printf '],"ours":['
	_lf=1
	tk_rundir; TK_TMP="$TK_RUN/.list.$$"
	tk_each_line > "$TK_TMP"
	while IFS= read -r _ll || [ -n "$_ll" ]; do
		tk_is_ours "$_ll" || continue
		tk_line_check "$_ll" || continue
		[ "$TKL" = cron ] || continue
		_ls=$(printf '%s' "$TKL_C" | sed 's/[[:space:]]*[0-9]*>.*$//; s#^.*boot\.sh[[:space:]][[:space:]]*##; s#^[^[:space:]]*/##')
		[ "$_lf" = 1 ] || printf ','; _lf=0
		printf '{"sched":"%s","cmd":"%s"}' "$TKL_S" "$(jstr "$_ls" 120)"
	done < "$TK_TMP"
	printf '],"foreign":['
	_lf=1
	while IFS= read -r _ll || [ -n "$_ll" ]; do
		tk_is_task "$_ll" && continue
		tk_is_ours "$_ll" && continue
		_on=true; _bad=false; _lb=$_ll
		if tk_line_check "$_ll"; then
			case "$TKL" in
				blank) continue ;;
				comment)   # a commented-out VALID cron line is a disabled line; any other comment is just a comment
					_lu=$(printf '%s' "$_ll" | sed 's/^[[:space:]]*#[[:space:]]*//')
					tk_line_check "$_lu" && [ "$TKL" = cron ] || continue
					tk_is_task "$_lu" && continue; tk_is_ours "$_lu" && continue
					_on=false ;;
			esac
		else _bad=true; fi
		[ "$_lf" = 1 ] || printf ','; _lf=0
		printf '{"line":"%s","on":%s,"bad":%s}' "$(printf '%s' "$_lb" | b64)" "$_on" "$_bad"
	done < "$TK_TMP"
	printf ']}\n'
}
cmd_get_json() {
	id_ok "$1" && tk_load "$1" || jfail "такой задачи нет"
	_body=""; [ -f "$TK_DIR/$1.body" ] && _body=$(b64 < "$TK_DIR/$1.body")
	_env=""; [ -f "$TK_DIR/$1.env" ] && _env=$(b64 < "$TK_DIR/$1.env")
	printf '{"ok":true,"now":"%s","langs":[%s],"task":{"id":"%s","name":"%s","enabled":%s,"kind":"%s","lang":"%s",' \
		"$(now_local)" "$(tk_langs)" "$1" "$(jstr "$T_NAME" 400)" "$([ "$T_ENABLED" = 1 ] && echo true || echo false)" "$T_KIND" "$T_LANG"
	printf '"target":"%s","args":"%s","workdir":"%s","sched":"%s","boot":%s,"delay":%s,"timeout":%s,"overlap":"%s",' \
		"$(printf '%s' "$T_TARGET" | b64)" "$(printf '%s' "$T_ARGS" | b64)" "$(printf '%s' "$T_WORKDIR" | b64)" "$(jstr "$T_SCHED" 120)" \
		"$([ "$T_BOOT" = 1 ] && echo true || echo false)" "$T_DELAY" "$T_TIMEOUT" "$T_OVERLAP"
	printf '"prio":"%s","clockwait":%s,"keep":%s,"mail":"%s","journal":%s,"adopted":%s,"body":"%s","env":"%s"},' \
		"$T_PRIO" "$([ "$T_CLOCK" = 1 ] && echo true || echo false)" "$(tk_num_or "$T_KEEP" 5)" "$T_MAIL" \
		"$([ "$T_JOURNAL" = 1 ] && echo true || echo false)" "$([ -n "$T_ORIGIN" ] && echo true || echo false)" "$_body" "$_env"
	printf '"next":%s,"running":%s,"runs":[' "$([ "$T_ENABLED" = 1 ] && tk_next_json "$T_SCHED" 3 || printf '[]')" "$(tk_running_json "$1" out)"
	_gf=1
	# newest first; a run's output is there only while its file lives (keep setting, RAM)
	TK_TMP="$TK_RUN/.hist.$$"
	[ -f "$TK_RUN/$1.hist" ] && sed '1!G;h;$!d' "$TK_RUN/$1.hist" > "$TK_TMP" 2>/dev/null
	if [ -f "$TK_TMP" ]; then
		while IFS= read -r _gl || [ -n "$_gl" ]; do
			[ -n "$_gl" ] || continue
			_gs=$(printf '%s' "$_gl" | cut -f5); _go=""; _gk=false   # kept = the file lives (an EMPTY output is still kept)
			case "$_gs" in ''|*[!0-9]*) ;; *) [ -f "$TK_RUN/$1.out.$_gs" ] && { _go=$(b64 < "$TK_RUN/$1.out.$_gs"); _gk=true; } ;; esac
			[ "$_gf" = 1 ] || printf ','; _gf=0
			printf '{"ts":"%s","dur":%s,"code":%s,"trig":"%s","flag":"%s","kept":%s,"out":"%s"}' "$(printf '%s' "$_gl" | cut -f1)" \
				"$(tk_num_or "$(printf '%s' "$_gl" | cut -f2)" 0)" "$(tk_num_or "$(printf '%s' "$_gl" | cut -f3)" 0)" \
				"$(printf '%s' "$_gl" | cut -f4)" "$(printf '%s' "$_gl" | cut -f6)" "$_gk" "$_go"
		done < "$TK_TMP"
	fi
	printf ']}\n'
}
cmd_explain() {
	tk_sched_parse "$1" || jfail "$TKE"
	printf '{"ok":true,"now":"%s","next":%s}\n' "$(now_local)" "$(tk_next_json "$1" 3)"
}

# ---- save / edit --------------------------------------------------------------------------------------------------
# spec = key=value lines from the CGI (enums/numbers as is, free text as base64 with the _b64 suffix). EVERY value is
# validated here: the owner checks, the CGI only carries.
cmd_save() {
	[ -f "$1" ] || jfail "нет данных задачи"
	_sid=""; _sbody=""; _senv=""; _srun=0; _snew=0
	tk_defaults; _sset=""
	while IFS= read -r _sl || [ -n "$_sl" ]; do
		_sv=${_sl#*=}
		case "${_sl%%=*}" in
			id) _sid=$_sv ;;
			run) _srun=$_sv ;;
			name_b64) T_NAME=$(b64d "$_sv" | tr -d '\000-\037' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') ;;
			enabled) T_ENABLED=$_sv ;; kind) T_KIND=$_sv ;; lang) T_LANG=$_sv ;;
			target_b64) T_TARGET=$(b64d "$_sv" | tr -d '\r') ;;
			args_b64) T_ARGS=$(b64d "$_sv" | tr -d '\r') ;;
			sched_b64) T_SCHED=$(b64d "$_sv" | tr -s ' \t' '  ' | sed 's/^ *//; s/ *$//') ;;
			boot) T_BOOT=$_sv ;; delay) T_DELAY=$_sv ;; timeout) T_TIMEOUT=$_sv ;; overlap) T_OVERLAP=$_sv ;;
			prio) T_PRIO=$_sv ;; clockwait) T_CLOCK=$_sv ;; keep) T_KEEP=$_sv ;; mail) T_MAIL=$_sv ;; journal) T_JOURNAL=$_sv ;;
			workdir_b64) T_WORKDIR=$(b64d "$_sv" | tr -d '\r') ;;
			body_b64) _sbody=$_sv; _sset="$_sset body" ;;
			env_b64) _senv=$_sv; _sset="$_sset env" ;;
		esac
	done < "$1"
	[ -n "$_sid" ] && { id_ok "$_sid" || jfail "неверный номер задачи"; }
	[ -n "$T_NAME" ] || jfail "введите название задачи"
	# characters, not bytes: UTF-8 continuation bytes (0x80..0xBF) are not characters (80 emoji are 320 bytes, review s.106)
	[ "$(printf '%s' "$T_NAME" | tr -d '\200-\277' | wc -c)" -le 80 ] || jfail "название длиннее 80 знаков"
	case "$T_ENABLED$T_BOOT$T_CLOCK$T_JOURNAL" in *[!01]*) jfail "неверные данные задачи" ;; esac
	[ "${#T_ENABLED}${#T_BOOT}${#T_CLOCK}${#T_JOURNAL}" = 1111 ] || jfail "неверные данные задачи"
	case "$T_KIND" in script|file|cmd) ;; *) jfail "неверный вид задачи" ;; esac
	case "$T_LANG" in sh|lua|auto) ;; *) jfail "неверный язык" ;; esac
	case "$T_OVERLAP" in skip|wait|par) ;; *) jfail "неверная настройка наложения" ;; esac
	case "$T_PRIO" in normal|low) ;; *) jfail "неверный приоритет" ;; esac
	case "$T_MAIL" in never|fail|always) ;; *) jfail "неверная настройка писем" ;; esac
	case "$T_KEEP" in 0|1|5) ;; *) jfail "неверная настройка вывода" ;; esac
	case "$T_DELAY" in ''|*[!0-9]*) jfail "задержка — число секунд" ;; esac
	[ "$T_DELAY" -le 3600 ] || jfail "задержка — не больше 3600 секунд"
	case "$T_TIMEOUT" in ''|*[!0-9]*) jfail "ограничение по времени — число секунд" ;; esac
	[ "$T_TIMEOUT" -le 86400 ] || jfail "ограничение по времени — не больше суток"
	if [ -n "$T_SCHED" ]; then tk_sched_parse "$T_SCHED" || jfail "расписание: $TKE"; fi
	case "$T_WORKDIR" in ''|/*) ;; *) jfail "рабочий каталог — полный путь, от /" ;; esac
	[ "$(printf '%s' "$T_WORKDIR$T_TARGET$T_ARGS" | wc -l)" -eq 0 ] || jfail "путь, команда и аргументы — одной строкой"
	tk_rundir || jfail "не удалось создать каталог задач в памяти"
	_stmp="$TK_RUN/.save.$$"; rm -rf "$_stmp"; ( umask 077; mkdir "$_stmp" ) || jfail "не удалось создать временный каталог"
	TK_TMP=$_stmp
	case "$T_KIND" in
		script)
			T_TARGET=""; T_ARGS=""
			b64d "$_sbody" | tr -d '\r' > "$_stmp/body"
			[ -s "$_stmp/body" ] || jfail "скрипт пустой"
			[ "$(wc -c < "$_stmp/body")" -le "$TK_BODY_MAX" ] || jfail "скрипт больше 16 КБ"
			[ -n "$(tail -c 1 "$_stmp/body")" ] && echo >> "$_stmp/body"   # a last line without \n is lost by `read`
			tk_syntax "$_stmp/body" "$T_LANG" || jfail "$TKE" ;;
		file)
			case "$T_TARGET" in /*) ;; *) jfail "путь к файлу — полный, от /" ;; esac
			[ -f "$T_TARGET" ] || jfail "файла нет: $T_TARGET"
			tk_interp "$T_TARGET" "$T_LANG" || jfail "$TKE" ;;
		cmd)
			T_ARGS=""
			[ -n "$(printf '%s' "$T_TARGET" | tr -d ' \t')" ] || jfail "введите команду"
			[ "${#T_TARGET}" -le 2000 ] || jfail "команда длиннее 2000 знаков — сделайте её скриптом" ;;
	esac
	case "$_sset" in *env*)
		b64d "$_senv" | tr -d '\r' | sed '/^[[:space:]]*$/d' > "$_stmp/env"
		[ "$(wc -c < "$_stmp/env")" -le 4096 ] || jfail "переменных больше 4 КБ"
		_bad=$(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' "$_stmp/env" | head -n 1)
		[ -z "$_bad" ] || jfail "переменная — ИМЯ=значение, латиницей: $_bad" ;;
	esac
	tk_lock
	if [ -z "$_sid" ]; then _sid=$(tk_new_id); _snew=1
	else
		[ -f "$TK_DIR/$_sid.task" ] || jfail "такой задачи нет — её удалили, пока вы правили"
		# the spec does not carry it: dropped, an adopted task lost the line `release` gives back at uninstall (round 2)
		T_ORIGIN=$(sed -n 's/^origin=//p' "$TK_DIR/$_sid.task" | tr -d '\r' | head -n 1)
		case "$T_ORIGIN" in *[!A-Za-z0-9+/=]*) T_ORIGIN="" ;; esac
	fi
	mkdir -p "$TK_DIR" 2>/dev/null
	if [ "$T_KIND" = script ]; then tk_put "$_stmp/body" "$TK_DIR/$_sid.body" || jfail "не удалось записать скрипт на флеш — места нет?"
	else rm -f "$TK_DIR/$_sid.body"; fi
	case "$_sset" in *env*)
		if [ -s "$_stmp/env" ]; then tk_put "$_stmp/env" "$TK_DIR/$_sid.env" || jfail "не удалось записать переменные на флеш — места нет?"
		else rm -f "$TK_DIR/$_sid.env"; fi ;;
	esac
	tk_write "$_sid" || jfail "не удалось записать задачу на флеш"
	tk_apply || jfail "задача сохранена, но расписание не записалось (crontab)"
	tk_unlock
	[ "$_srun" = 1 ] && cmd_run_bg "$_sid" quiet
	jok "\"id\":\"$_sid\",\"new\":$([ "$_snew" = 1 ] && echo true || echo false),\"msg\":\"$([ "$_snew" = 1 ] && echo 'задача создана' || echo 'задача сохранена')$([ "$_srun" = 1 ] && echo ' и запущена')\""
}
cmd_del() {
	id_ok "$1" && [ -f "$TK_DIR/$1.task" ] || jfail "такой задачи нет"
	tk_lock
	tk_rundir && echo 999999999 > "$TK_RUN/$1.stop"   # every running copy stops itself (the runner reads the flag)
	rm -f "$TK_DIR/$1.task" "$TK_DIR/$1.body" "$TK_DIR/$1.env"
	TK_DROP=" $1 "; tk_apply; _dap=$?   # in the «off» form its plain line goes too — a delete stops the command, as a task line would
	tk_unlock
	( sleep 3; rm -f "$TK_RUN/$1".* ) >/dev/null 2>&1 &   # the id is never given again (tk_new_id) — nothing else's state
	[ "$_dap" = 0 ] || jfail "задача удалена, но расписание не записалось (crontab)"
	jok '"msg":"задача удалена"'
}
cmd_toggle() {
	case "$2" in on|off) ;; *) jfail "неверное действие" ;; esac
	id_ok "$1" || jfail "такой задачи нет"
	tk_lock
	tk_load "$1" || jfail "такой задачи нет"
	if [ "$2" = on ]; then T_ENABLED=1; _tgw='задача включена'; else T_ENABLED=0; _tgw='задача выключена'; fi
	tk_write "$1" && tk_apply || jfail "не удалось записать задачу"
	tk_unlock
	jok "\"msg\":\"$_tgw\""
}
cmd_dup() {   # a copy is born DISABLED: two identical tasks running side by side is never what a click on «copy» meant
	id_ok "$1" && tk_load "$1" || jfail "такой задачи нет"
	tk_lock
	_nid=$(tk_new_id); tk_load "$1"
	T_NAME="$T_NAME (копия)"; T_ENABLED=0; T_ORIGIN=""   # a copy did not come from the line: release must not write it twice
	[ -f "$TK_DIR/$1.body" ] && cp "$TK_DIR/$1.body" "$TK_DIR/$_nid.body"
	[ -f "$TK_DIR/$1.env" ] && cp "$TK_DIR/$1.env" "$TK_DIR/$_nid.env"
	tk_write "$_nid" || jfail "не удалось записать копию"
	tk_unlock
	jok "\"id\":\"$_nid\",\"msg\":\"копия создана выключенной\""
}

# import <archive tasks dir> <full 0|1> — a backup's tasks into the registry (cgi-bin/backup; the owner decides, the CGI carries).
# A task arrives WHOLE: settings, script and variables of one id are one task (a merge by file left the router's old script or
# variables under an imported task of the same id — review s.106). Variables travel only in a full backup (they hold passwords):
# a SETTINGS archive of the very same task — the same file but for `enabled=`, the same script — keeps the router's variables
# (round 2); a name alone is no identity (round 3). A task of this router replaced by an archive task of the same id is not lost
# if it held a crontab line of another family (adopted, another mark): that line is given back into the crontab, in the same
# write — ids are per router, and another router's t1 erased the firmware's SSH patch held by this one's t1 (round 4). Ids: the
# higher `.last-id` wins (an older archive would bring back ids already given). Exit 1 = nothing imported or not written.
cmd_import() {
	[ -d "${1:-}" ] || { echo "нет каталога задач"; return 1; }
	_isrc=$1; _ifull=${2:-0}
	tk_rundir || { echo "не удалось создать каталог задач в памяти"; return 1; }
	tk_lock soft || { echo "задачи сейчас меняет другой запрос — задачи не импортированы"; return 1; }
	mkdir -p "$TK_DIR" 2>/dev/null
	_ig="$TK_RUN/.import.$$"; : > "$_ig"; tk_each_line > "$_ig.work"; _in=0; _iids=" "
	for _itk in "$_isrc"/t*.task; do
		[ -f "$_itk" ] || continue
		_ii=${_itk##*/}; _ii=${_ii%.task}; id_ok "$_ii" || continue
		if tk_load "$_ii"; then
			if [ -n "$T_ORIGIN" ]; then
				tk_plain "$_ii"; _imr=$TKM; _ima=""
				_iao=$(sed -n 's/^origin=//p' "$_itk" | tr -d '\r' | head -n 1)
				case "$_iao" in ''|*[!A-Za-z0-9+/=]*) ;; *) tk_mark "$_iao"; _ima=$TKM ;; esac
				# After the import no task holds this family: exactly ONE line of it must stay. An active line of its mark (the «off» form
				# wrote it; the record no longer claims it) stands, and its unmarked twins (the firmware put the line back meanwhile) go —
				# no task is left to take them back, the command would run twice for good (round 5). Otherwise a line of the family in
				# the file stands as it is; with none, the task's line is given back without a mark.
				if [ "$_ima" != "$_imr" ]; then
					_igb=$(printf '%s\n' "$TKP" | sed 's/[[:space:]]*#enodia-task:[0-9a-f]*$//'); tk_fam_plain
					if grep -v '^[[:space:]]*#' "$_ig.work" | grep -qF -- "$_imr"; then
						for _igt in "$TKF_JOB" "$TKF_ORG"; do
							[ -n "$_igt" ] && grep -qxF -- "$_igt" "$_ig.work" && tk_drop_in "$_ig.work" "$_igt"
						done
					elif ! grep -qF -- "$_imr" "$_ig.work" && ! grep -qxF -- "$_igb" "$_ig.work" \
						&& { [ -z "$TKF_JOB" ] || ! grep -qxF -- "$TKF_JOB" "$_ig.work"; } \
						&& { [ -z "$TKF_ORG" ] || ! grep -qxF -- "$TKF_ORG" "$_ig.work"; }; then
						printf '%s\n' "$_igb" >> "$_ig"
					fi
				fi
			fi
			_ikeep=0
			if [ "$_ifull" = 0 ] && [ ! -f "$_isrc/$_ii.env" ]; then
				grep -v '^enabled=' "$_itk" | tr -d '\r' > "$_ig.a"; grep -v '^enabled=' "$TK_DIR/$_ii.task" | tr -d '\r' > "$_ig.b"
				cmp -s "$_ig.a" "$_ig.b" && _ikeep=1
				if [ -f "$_isrc/$_ii.body" ] || [ -f "$TK_DIR/$_ii.body" ]; then cmp -s "$_isrc/$_ii.body" "$TK_DIR/$_ii.body" || _ikeep=0; fi
			fi
			rm -f "$TK_DIR/$_ii.task" "$TK_DIR/$_ii.body"
			[ "$_ikeep" = 1 ] || rm -f "$TK_DIR/$_ii.env"
		fi
		tk_put "$_itk" "$TK_DIR/$_ii.task" || continue
		[ -f "$_isrc/$_ii.body" ] && tk_put "$_isrc/$_ii.body" "$TK_DIR/$_ii.body"
		if [ -f "$_isrc/$_ii.env" ]; then tk_put "$_isrc/$_ii.env" "$TK_DIR/$_ii.env" && chmod 600 "$TK_DIR/$_ii.env" 2>/dev/null; fi
		_in=$((_in + 1)); _iids="$_iids $_ii "
	done
	# One family, one task: an imported adopted task whose line another task here already holds comes in DISABLED — the router's
	# own task keeps running it (an old backup after the line was re-adopted, another router's backup of the same firmware line:
	# two task lines, the command twice — round 5). The derivation's own guard would disable the LOWER id, often the router's.
	_ifam=" "
	for _ifi in $(tk_ids); do
		case "$_iids" in *" $_ifi "*) continue ;; esac
		tk_load "$_ifi" && [ -n "$T_ORIGIN" ] && [ "$T_ENABLED" = 1 ] || continue
		tk_mark "$T_ORIGIN"; _ifam="$_ifam$TKM "
	done
	for _ifi in $(tk_ids); do
		case "$_iids" in *" $_ifi "*) ;; *) continue ;; esac
		tk_load "$_ifi" && [ -n "$T_ORIGIN" ] && [ "$T_ENABLED" = 1 ] || continue
		tk_mark "$T_ORIGIN"
		case "$_ifam" in *" $TKM "*) T_ENABLED=0; tk_write "$_ifi" ;; *) _ifam="$_ifam$TKM " ;; esac
	done
	_ial=$(tk_dec "$(cat "$_isrc/.last-id" 2>/dev/null)" 0); _irl=$(tk_dec "$(cat "$TK_DIR/.last-id" 2>/dev/null)" 0)
	[ "$_ial" -gt "$_irl" ] && echo "$_ial" > "$TK_DIR/.last-id"
	cat "$_ig.work" "$_ig" > "$_ig.src"; tk_apply "$_ig.src"; _iap=$?
	tk_unlock
	rm -f "$_ig" "$_ig.work" "$_ig.work.n" "$_ig.a" "$_ig.b" "$_ig.src"
	[ "$_iap" = 0 ] || { echo "задачи импортированы ($_in), но расписание не записалось (crontab)"; return 1; }
	echo "задач импортировано: $_in"
	[ "$_in" -gt 0 ]
}

# ---- foreign lines ------------------------------------------------------------------------------------------------
tk_lines_without() {   # the crontab without the FIRST exact match of $1
	_wd=0
	tk_each_line | while IFS= read -r _wl || [ -n "$_wl" ]; do
		if [ "$_wd" = 0 ] && [ "$_wl" = "$1" ]; then _wd=1; continue; fi
		printf '%s\n' "$_wl"
	done
}
# tk_line_find <line> -> rc 0 when the crontab has this exact line
tk_line_find() { tk_each_line | grep -qxF -- "$1"; }
tk_line_guard() {   # refuse lines this owner does not own: tasks (edit the task) and Enodia (their owners rewrite them)
	tk_is_task "$1" && jfail "это строка задачи — меняйте саму задачу"
	tk_is_ours "$1" && jfail "строки Enodia меняет их владелец — расписание правится на их экране"
	return 0
}
# tk_line_replace <old> <new|""> -> new crontab with the FIRST exact match replaced (empty = removed)
tk_line_replace() {
	tk_rundir || return 1
	_rt="$TK_RUN/.line.$$"; _rdone=0
	tk_each_line > "$_rt.src"
	while IFS= read -r _rl || [ -n "$_rl" ]; do
		if [ "$_rdone" = 0 ] && [ "$_rl" = "$1" ]; then
			_rdone=1; [ -n "$2" ] && printf '%s\n' "$2"
		else printf '%s\n' "$_rl"; fi
	done < "$_rt.src" > "$_rt"
	rm -f "$_rt.src"
	[ "$_rdone" = 1 ] || { rm -f "$_rt"; return 1; }
	tk_cron_put "$_rt"
}
cmd_line_set() {
	_old=$(b64d "$1"); _new=$(b64d "$2" | tr -d '\r\n')
	[ -n "$_old" ] || jfail "нет строки"
	tk_line_guard "$_old"
	if [ -n "$_new" ]; then
		tk_line_check "$_new" || jfail "$TKE"
		case "$TKL" in cron|comment) ;; *) jfail "пустая строка — для удаления есть своя кнопка" ;; esac
		tk_is_task "$_new" && jfail "строку задачи так не завести — создайте задачу"
	fi
	tk_lock
	tk_line_find "$_old" || jfail "строка изменилась с тех пор, как вы открыли экран — обновите его"
	tk_line_replace "$_old" "$_new" || jfail "не удалось записать crontab"
	tk_unlock
	jok "\"msg\":\"$([ -n "$_new" ] && echo 'строка сохранена' || echo 'строка удалена')\",\"line\":\"$(printf '%s' "$_new" | b64)\""
}
cmd_line_toggle() {
	_old=$(b64d "$1"); [ -n "$_old" ] || jfail "нет строки"
	tk_line_guard "$_old"
	case "$(printf '%s' "$_old" | sed 's/^[[:space:]]*//')" in
		'#'*) _new=$(printf '%s' "$_old" | sed 's/^[[:space:]]*#[[:space:]]*//')
		      tk_line_check "$_new" && [ "$TKL" = cron ] || jfail "после снятия «#» строка не годится: $TKE"
		      tk_line_guard "$_new"; _what='строка включена' ;;
		*) _new="# $_old"; _what='строка выключена' ;;
	esac
	tk_lock
	tk_line_find "$_old" || jfail "строка изменилась с тех пор, как вы открыли экран — обновите его"
	tk_line_replace "$_old" "$_new" || jfail "не удалось записать crontab"
	tk_unlock
	jok "\"msg\":\"$_what\",\"line\":\"$(printf '%s' "$_new" | b64)\""
}
# adopt: a foreign line becomes a task (kind=cmd, same schedule and command, disabled if the line was) — the line is
# replaced by the task's line in the SAME crontab write, so there is no minute where both or neither run.
cmd_adopt() {
	_old=$(b64d "$1"); [ -n "$_old" ] || jfail "нет строки"
	tk_line_guard "$_old"
	_aon=1; _al=$_old
	case "$(printf '%s' "$_old" | sed 's/^[[:space:]]*//')" in '#'*) _aon=0; _al=$(printf '%s' "$_old" | sed 's/^[[:space:]]*#[[:space:]]*//') ;; esac
	tk_line_check "$_al" && [ "$TKL" = cron ] || jfail "строку не разобрать: $TKE"
	tk_defaults
	# behaves as the line did: no time limit, normal priority, no wait for the clock (a firmware line — the SSH patch — must
	# run after a reboot without internet too), no letters; the line itself is kept for `release` (see the header)
	T_KIND=cmd; T_TARGET=$TKL_C; T_SCHED=$TKL_S; T_ENABLED=$_aon; T_TIMEOUT=0; T_PRIO=normal; T_CLOCK=0; T_MAIL=never; T_JOURNAL=0
	T_ORIGIN=$(printf '%s' "$_old" | b64)
	T_NAME=$(printf '%s' "$TKL_C" | sed 's/^.*&&[[:space:]]*//; s/[[:space:]].*$//; s#^.*/##')
	[ -n "$T_NAME" ] || T_NAME="задача из crontab"
	tk_lock
	tk_line_find "$_old" || jfail "строка изменилась с тех пор, как вы открыли экран — обновите его"
	# one family, one task: the firmware put back the line a task already holds — the task takes it back at the next derivation
	tk_mark "$T_ORIGIN"; _afam=$TKM
	for _afi in $(tk_ids); do
		_afo=$(sed -n 's/^origin=//p' "$TK_DIR/$_afi.task" 2>/dev/null | tr -d '\r' | head -n 1)
		case "$_afo" in ''|*[!A-Za-z0-9+/=]*) continue ;; esac
		tk_mark "$_afo"; [ "$TKM" = "$_afam" ] && jfail "эту строку уже ведёт одна из ваших задач — откройте её в списке"
	done
	_aid=$(tk_new_id)
	tk_write "$_aid" || jfail "не удалось записать задачу"
	tk_rundir || { rm -f "$TK_DIR/$_aid.task"; jfail "не удалось создать каталог задач в памяти"; }
	_at="$TK_RUN/.adopt.$$"
	tk_lines_without "$_old" > "$_at"
	tk_apply "$_at" || { rm -f "$_at" "$TK_DIR/$_aid.task"; jfail "не удалось записать crontab"; }
	rm -f "$_at"

	tk_unlock
	jok "\"id\":\"$_aid\",\"msg\":\"строка стала задачей\""
}
tk_rev() { tk_each_line | md5sum 2>/dev/null | cut -c1-32; }
cmd_raw_get() { printf '{"ok":true,"rev":"%s","text":"%s"}\n' "$(tk_rev)" "$(tk_each_line | b64)"; }
cmd_raw_save() {   # <b64file> <rev the panel opened>
	[ -f "$1" ] || jfail "нет текста"
	tk_rundir || jfail "не удалось создать каталог задач в памяти"
	_rw="$TK_RUN/.raw.$$"; TK_TMP=$_rw
	base64 -d < "$1" 2>/dev/null | tr -d '\r' > "$_rw"
	[ "$(wc -c < "$_rw")" -le "$TK_FILE_MAX" ] || { rm -f "$_rw"; jfail "файл больше 16 КБ — правьте его по SSH"; }
	_rn=0
	while IFS= read -r _rl || [ -n "$_rl" ]; do
		_rn=$((_rn + 1))
		tk_line_check "$_rl" || { rm -f "$_rw"; jfail "строка $_rn: $TKE" "\"line\":$_rn"; }
	done < "$_rw"
	[ -n "$(tail -c 1 "$_rw")" ] && echo >> "$_rw"
	tk_lock
	[ -n "$2" ] && [ "$2" != "$(tk_rev)" ] && jfail "crontab изменился, пока вы его правили — откройте вкладку заново" '"stale":true'
	tk_apply "$_rw" || jfail "не удалось записать crontab"
	tk_unlock
	# the schedules' engine stands its rules only while its tick line is in the crontab (access-sched.sh sc_ticking): a raw edit
	# that dropped it froze them — a 23:00 close nobody would lift any more (review s.113, round 4). One tick now: the line gone
	# ⇒ the rules go; the line kept ⇒ nothing changes
	if [ -f "$ENODIA_DIR/access-sched.sh" ]; then sh "$ENODIA_DIR/access-sched.sh" tick wait >/dev/null 2>&1 || true; fi
	jok "\"msg\":\"crontab сохранён\",\"rev\":\"$(tk_rev)\",\"text\":\"$(tk_each_line | b64)\""
}

# ---- «open and edit the file» --------------------------------------------------------------------------------------
# A symbolic link is refused with its target named: a save renames a new file over the PATH, and that would replace the link
# itself with a copy — the file it pointed to unchanged, the link gone.
tk_file_link() { [ -L "$1" ] && jfail "это ссылка на $(readlink "$1" 2>/dev/null) — откройте сам файл"; return 0; }
cmd_file_get() {
	case "$1" in /*) ;; *) jfail "путь — полный, от /" ;; esac
	tk_file_link "$1"
	[ -f "$1" ] || jfail "файла нет: $1"
	_fs=$(wc -c < "$1" | tr -d ' '); [ "$_fs" -le "$TK_FILE_MAX" ] || jfail "файл больше 16 КБ — правьте его по SSH"
	[ "$(tr -d '\000' < "$1" | wc -c | tr -d ' ')" = "$_fs" ] || jfail "файл не текстовый"
	printf '{"ok":true,"size":%s,"text":"%s"}\n' "$_fs" "$(b64 < "$1")"
}
cmd_file_put() {
	case "$1" in /*) ;; *) jfail "путь — полный, от /" ;; esac
	tk_file_link "$1"
	[ -f "$1" ] || jfail "файла нет: $1"
	[ -f "$2" ] || jfail "нет текста"
	# created EXCLUSIVELY (mktemp): the file may sit in /tmp, shared with stock daemons — a link laid on a predictable name would
	# turn our write as root into a write into its target (the class tk_rundir and cap_run are built against)
	_ft=$(mktemp "$1.enodia-new.XXXXXX" 2>/dev/null) || jfail "не удалось записать файл"
	base64 -d < "$2" 2>/dev/null | tr -d '\r' > "$_ft" || { rm -f "$_ft"; jfail "не удалось записать файл"; }
	[ "$(wc -c < "$_ft")" -le "$TK_FILE_MAX" ] || { rm -f "$_ft"; jfail "файл больше 16 КБ — правьте его по SSH"; }
	cp -p "$1" "$1.bak" 2>/dev/null
	chmod --reference="$1" "$_ft" 2>/dev/null || chmod "$(stat -c %a "$1" 2>/dev/null || echo 644)" "$_ft" 2>/dev/null
	mv -f "$_ft" "$1" || { rm -f "$_ft"; jfail "не удалось записать файл"; }
	jok '"msg":"файл сохранён, прежняя версия — рядом с суффиксом .bak"'
}

# ---- runner -------------------------------------------------------------------------------------------------------
tk_hist_add() {   # <id> <ts> <dur> <code> <trig> <seq> <flag> — RAM history, last 20 lines
	tk_rundir || return 0
	case "$7" in skip-*) [ "$(tail -n 1 "$TK_RUN/$1.hist" 2>/dev/null | cut -f6)" = "$7" ] && sed -i '$d' "$TK_RUN/$1.hist" ;; esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" >> "$TK_RUN/$1.hist"
	tail -n 20 "$TK_RUN/$1.hist" > "$TK_RUN/$1.hist.new" 2>/dev/null && mv -f "$TK_RUN/$1.hist.new" "$TK_RUN/$1.hist"
}
tk_kill_tree() { _kt=$(proc_tree "$1"); kill -TERM $_kt 2>/dev/null; sleep 1; kill -KILL $_kt 2>/dev/null; return 0; }
# alive = a process that is not a zombie: our finished background child stays in /proc as Z until `wait`
tk_alive() { [ -d "/proc/$1" ] && [ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]; }
# tk_note_gate <id> <ok|fail> — rc 0 = speak now (TK_NREP = runs of this outcome held back since the last word), rc 1 = hold.
# Why: a task on a one-minute schedule spoke on EVERY run. The journal is a ring of 100 events, rewritten whole on /data once
# full — a per-minute task evicted the VPN's events in 100 minutes and wrote ~29 MB a day; «каждый раз» meant 1440 letters a
# day (decision 07.10.2026: one word an hour per task and outcome, the repeats as a count). The first word of an outcome goes
# at once (the first failure, the first success after a boot — /tmp is empty then). The gate is THE throttle: notify-event
# and events.sh get 0 — a second throttle on wall-clock stamps, taken a moment later, would swallow the hourly word
# (3599 s < 3600) and then every next one. Age by uptime (a /tmp mark; the clock steps after a boot); RAM only.
tk_note_gate() {
	_ngf="$TK_RUN/$1.note-$2"; _ngu=$(uptime_s); _ngt=""; _ngn=0
	[ -f "$_ngf" ] && read -r _ngt _ngn < "$_ngf" 2>/dev/null
	case "$_ngn" in ''|*[!0-9]*) _ngn=0 ;; esac
	case "$_ngt" in ''|*[!0-9]*) ;; *)
		if [ "$_ngu" -ge "$_ngt" ] && [ $((_ngu - _ngt)) -lt "$TK_NOTE_GAP" ]; then
			echo "$_ngt $((_ngn + 1))" > "$_ngf.$$" && mv -f "$_ngf.$$" "$_ngf"
			return 1
		fi ;;
	esac
	TK_NREP=$_ngn
	echo "$_ngu 0" > "$_ngf.$$" && mv -f "$_ngf.$$" "$_ngf"
	return 0
}
tk_notify() {   # <id> <ok|fail> <ts> <dur> <code> <flag> <trig> <outfile>
	_nk="task-$2-$1"
	if [ "$2" = fail ]; then
		case "$T_MAIL" in fail|always) _nhow=mail ;; *) _nhow=journal ;; esac
	else
		case "$T_MAIL" in always) _nhow=mail ;; *) [ "$T_JOURNAL" = 1 ] && _nhow=journal || return 0 ;; esac
	fi
	tk_rundir && tk_note_gate "$1" "$2" || return 0
	NF_LANG=ru
	if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; command -v nf_lang >/dev/null 2>&1 && NF_LANG=$(nf_lang); fi
	_ntail=$(tail -n 15 "$8" 2>/dev/null)
	case "$6" in killed) _nwhy=$( [ "$NF_LANG" = en ] && echo "stopped by the time limit" || echo "оборвана по ограничению времени") ;;
		cut) _nwhy=$( [ "$NF_LANG" = en ] && echo "output over 512 KB — the run was cut" || echo "вывод больше 512 КБ — оборвана") ;;
		nodir) _nwhy=$( [ "$NF_LANG" = en ] && echo "no working directory" || echo "нет рабочего каталога") ;;
		*) _nwhy="" ;; esac
	_nrep=""
	if [ "$NF_LANG" = en ]; then
		[ "$TK_NREP" -gt 0 ] 2>/dev/null && _nrep="
Since the previous message: $TK_NREP more such runs (one message an hour per task)."
		_ntitle="BE7000: task «$T_NAME» $([ "$2" = fail ] && echo failed || echo done)"
		_ntext="Task «$T_NAME» ($1), started $3 ($7): exit code $5, $4 s${_nwhy:+, $_nwhy}.$_nrep
${_ntail:+Output (last lines):
$_ntail}"
	else
		[ "$TK_NREP" -gt 0 ] 2>/dev/null && _nrep="
С прошлого сообщения таких запусков ещё $TK_NREP (о задаче — не чаще раза в час)."
		_ntitle="BE7000: задача «$T_NAME» $([ "$2" = fail ] && echo 'не удалась' || echo 'выполнена')"
		_ntext="Задача «$T_NAME» ($1), запуск $3 ($7): код выхода $5, $4 с${_nwhy:+, $_nwhy}.$_nrep
${_ntail:+Вывод (последние строки):
$_ntail}"
	fi
	# throttle 0: tk_note_gate above is the one throttle (why — at the gate)
	if [ "$_nhow" = mail ] && [ -f "$ENODIA_DIR/notify-event.sh" ]; then
		sh "$ENODIA_DIR/notify-event.sh" "$_nk" 0 "$_ntitle" "$_ntext" >/dev/null 2>&1
	elif [ -f "$ENODIA_DIR/events.sh" ]; then
		sh "$ENODIA_DIR/events.sh" add "$_nk" 0 "$_ntitle" "$_ntext" >/dev/null 2>&1
	fi
	return 0
}
cmd_run() {
	_id=$1; _trig=${2:-manual}
	id_ok "$_id" && tk_load "$_id" || exit 1
	case "$_trig" in sched|boot|manual) ;; *) _trig=manual ;; esac
	[ "$_trig" != manual ] && [ "$T_ENABLED" != 1 ] && exit 0
	tk_rundir || exit 1
	_ts=$(date '+%Y-%m-%d %H:%M:%S')
	if [ "$_trig" = sched ] && [ "$T_CLOCK" = 1 ] && ! clock_sane; then
		tk_hist_add "$_id" "$_ts" 0 0 "$_trig" - skip-clock; exit 0
	fi
	# overlap: the run lock and the wait place are pid links (tk_link_take: never without a pid, a dead holder's taken over once)
	_lk="$TK_RUN/$_id.lock"; _mine=0; _qd=0
	if [ "$T_OVERLAP" != par ]; then
		_ww=0
		while :; do
			if tk_link_take "$_lk"; then _mine=1; break; fi
			if [ "$T_OVERLAP" = skip ]; then tk_hist_add "$_id" "$_ts" 0 0 "$_trig" - skip-busy; exit 0; fi
			# wait: ONE run queued behind the current one, every further tick folds into it — a per-minute task behind a hung
			# run queued a sleeping shell a minute, 1440 a day on a 176-MB router (review s.106). Its place is a link like the lock.
			if [ "$_qd" = 0 ]; then
				if tk_link_take "$_lk.q"; then _qd=1
				else tk_hist_add "$_id" "$_ts" 0 0 "$_trig" - skip-busy; exit 0; fi
			fi
			_ww=$((_ww + 2)); [ "$_ww" -gt 86400 ] && { rm -f "$_lk.q"; exit 0; }
			sleep 2
		done
		[ "$_qd" = 1 ] && rm -f "$_lk.q"
		# a run that WAITED reads its task again: deleted, disabled or edited meanwhile — the queued tick still held the old
		# settings and ran a deleted task's command once more (review s.106, round 2)
		if [ "$_ww" -gt 0 ]; then
			tk_load "$_id" || { rm -rf "$_lk"; exit 0; }
			if [ "$_trig" != manual ] && [ "$T_ENABLED" != 1 ]; then rm -rf "$_lk"; exit 0; fi
		fi
	fi
	# the run number: runs alongside take it at the same moment, so under a lock of its own (a dead taker's lock is stolen
	# after ~3 s — the section is one read and one write)
	_sl="$TK_RUN/$_id.seqlock"; _sw=0
	while ! mkdir "$_sl" 2>/dev/null; do _sw=$((_sw + 1)); [ "$_sw" -gt 3 ] && rm -rf "$_sl"; sleep 1; done
	_seq=$(( $(cat "$TK_RUN/$_id.seq" 2>/dev/null || echo 0) + 1 )); echo "$_seq" > "$TK_RUN/$_id.seq"; rm -rf "$_sl"
	_out="$TK_RUN/$_id.out.$_seq"; _rcf="$TK_RUN/$_id.rc.$_seq"; rm -f "$_rcf"
	trap 'rm -f "$TK_RUN/$_id.cur.$_seq" "$_rcf" "$_out.run"; [ "$_mine" = 1 ] && rm -rf "$_lk"' EXIT
	trap 'exit 1' INT TERM HUP PIPE
	# what to execute: one command line for `sh -c` — the user's own shell syntax around a quoted file path
	case "$T_KIND" in
		script) tk_interp "$TK_DIR/$_id.body" "$T_LANG" || { printf '%s\n' "$TKE" > "$_out"; tk_hist_add "$_id" "$_ts" 0 127 "$_trig" "$_seq" err; tk_notify "$_id" fail "$_ts" 0 127 err "$_trig" "$_out"; exit 0; }
		        _cl="$TKI $(tk_sq "$TK_DIR/$_id.body")" ;;
		file)   tk_interp "$T_TARGET" "$T_LANG" || { printf '%s\n' "$TKE" > "$_out"; tk_hist_add "$_id" "$_ts" 0 127 "$_trig" "$_seq" err; tk_notify "$_id" fail "$_ts" 0 127 err "$_trig" "$_out"; exit 0; }
		        _cl="$TKI $(tk_sq "$T_TARGET")${T_ARGS:+ $T_ARGS}" ;;
		*)      _cl=$T_TARGET ;;
	esac
	_wd=${T_WORKDIR:-/tmp}; _nice=""; [ "$T_PRIO" = low ] && command -v nice >/dev/null 2>&1 && _nice="nice -n 19"
	_up0=$(uptime_s)
	(
		cd "$_wd" 2>/dev/null || { echo "нет рабочего каталога: $_wd"; echo 126 > "$_rcf"; exit 126; }
		if [ -f "$TK_DIR/$_id.env" ]; then
			while IFS= read -r _ev || [ -n "$_ev" ]; do case "$_ev" in [A-Za-z_]*=*) export "$_ev" ;; esac; done < "$TK_DIR/$_id.env"
		fi
		$_nice sh -c "$_cl" </dev/null; echo $? > "$_rcf"
	) > "$_out.run" 2>&1 &
	_wp=$!
	printf '%s\t%s\t%s\t%s\t%s\n' "$_ts" "$_up0" "$$" "$_trig" "$_seq" > "$TK_RUN/$_id.cur.$_seq"
	_flag=""; _rpq=0; daemon_step_init
	while [ ! -s "$_rcf" ]; do
		# «stop» holds the last run number it applies to: a run started after the click is not stopped by it (a flag removed
		# by the next start cancelled a stop meant for a run alongside), and nothing has to remove it
		_sv=""; [ -f "$TK_RUN/$_id.stop" ] && read -r _sv < "$TK_RUN/$_id.stop" 2>/dev/null
		case "$_sv" in ''|*[!0-9]*) ;; *) if [ "$_seq" -le "$_sv" ]; then _flag=stopped; tk_kill_tree "$_wp"; break; fi ;; esac
		if [ "$T_TIMEOUT" -gt 0 ] 2>/dev/null && [ $(( $(uptime_s) - _up0 )) -ge "$T_TIMEOUT" ]; then _flag=killed; tk_kill_tree "$_wp"; break; fi
		if [ "$(wc -c < "$_out.run" 2>/dev/null)" -gt "$TK_OUT_CAP" ] 2>/dev/null; then _flag=cut; tk_kill_tree "$_wp"; break; fi
		# gone already: its code is read NOW — the grace second is for a run that never wrote one. A short run ends while this
		# body forks wc/awk (tens of ms each on the router), and every «Запустить» of `echo` paid that second (BE7000 10.10.2026:
		# 1.25 s → 0.05 s)
		tk_alive "$_wp" || { [ -s "$_rcf" ] && break; sleep 1; [ -s "$_rcf" ] || { _flag=err; break; }; }
		# the first two seconds in short steps (daemon-lib.sh::daemon_step): most runs end in a fraction of a second, and a
		# whole-second step made «Запустить» of `true` take a second; a long run is then polled once a second as before
		_rpq=$((_rpq + 1)); if [ "$_rpq" -le $((2 * DAEMON_STEP_Q)) ]; then daemon_step; else sleep 1; fi
	done
	wait "$_wp" 2>/dev/null
	_code=$(cat "$_rcf" 2>/dev/null | tr -d ' \r\n'); case "$_code" in ''|*[!0-9]*) _code=143 ;; esac
	_dur=$(( $(uptime_s) - _up0 ))
	[ "$_code" = 126 ] && grep -q '^нет рабочего каталога' "$_out.run" 2>/dev/null && _flag=nodir
	[ -n "$_flag" ] || { [ "$_code" = 0 ] && _flag=ok || _flag=err; }
	tail -c "$TK_OUT_KEEP" "$_out.run" > "$_out" 2>/dev/null; rm -f "$_out.run"
	tk_hist_add "$_id" "$_ts" "$_dur" "$_code" "$_trig" "$_seq" "$_flag"
	# outputs: the newest N of this task (keep setting; 0 = none), the rest goes
	_kp=$(tk_num_or "$T_KEEP" 5); _kk=$_kp; [ "$_kk" -ge 1 ] || _kk=1   # the current one stays for the letter
	for _of in "$TK_RUN/$_id".out.*; do
		[ -f "$_of" ] || continue
		_os=${_of##*.}; case "$_os" in ''|*[!0-9]*) continue ;; esac
		[ "$_os" -le $((_seq - _kk)) ] && rm -f "$_of"
	done
	case "$_flag" in
		ok) tk_notify "$_id" ok "$_ts" "$_dur" "$_code" "$_flag" "$_trig" "$_out" ;;
		stopped) ;;   # the human pressed «stop» — not news for them
		*) tk_notify "$_id" fail "$_ts" "$_dur" "$_code" "$_flag" "$_trig" "$_out" ;;
	esac
	[ "$_kp" = 0 ] && rm -f "$_out"
	exit 0
}
# background start for the panel and boot: start-stop-daemon -b (no nohup/setsid here), -m -p MANDATORY (else -x /bin/sh
# matches every sh); `quiet` = called from save, which prints its own JSON
cmd_run_bg() {
	id_ok "$1" && [ -f "$TK_DIR/$1.task" ] || { [ "$2" = quiet ] && return 0; jfail "такой задачи нет"; }
	tk_rundir || { [ "$2" = quiet ] && return 0; jfail "не удалось создать каталог задач в памяти"; }
	_bp="$TK_RUN/$1.bg.pid"
	if tk_cur "$1"; then
		[ "$2" = quiet ] && return 0; jfail "задача уже выполняется"
	fi
	rm -f "$_bp"
	start-stop-daemon -S -b -m -p "$_bp" -x /bin/sh -- "$ENODIA_DIR/tasks.sh" run "$1" "${3:-manual}" >/dev/null 2>&1 \
		|| ( sh "$ENODIA_DIR/tasks.sh" run "$1" "${3:-manual}" >/dev/null 2>&1 & )
	# Answer once the run has REGISTERED (or its runner is already gone — refused, skipped): the panel asks for the task right
	# after this answer, and a run not yet registered read as «not running», so the screen never followed it (review s.106).
	# The wait is the runner's life, not a stopwatch; the ceiling only bounds a runner that hangs before registering.
	# busybox start-stop-daemon -b returns BEFORE its grandchild writes the pidfile: an empty one is «not started yet»
	_bw=0; daemon_step_init
	while [ "$_bw" -lt $((10 * DAEMON_STEP_Q)) ]; do
		tk_cur "$1" && break
		_bpid=$(cat "$_bp" 2>/dev/null); if [ -n "$_bpid" ] && [ ! -d "/proc/$_bpid" ]; then break; fi
		daemon_step; _bw=$((_bw + 1))
	done
	[ "$2" = quiet ] && return 0
	jok '"msg":"задача запущена"'
}
cmd_stop() {   # every run started so far: the flag holds the last run number (see the runner)
	id_ok "$1" || jfail "такой задачи нет"
	tk_cur "$1" || jfail "задача сейчас не выполняется"
	cat "$TK_RUN/$1.seq" > "$TK_RUN/$1.stop" 2>/dev/null
	jok '"msg":"останавливаю задачу"'
}
cmd_boot() {   # heal.sh at boot: every enabled task with «at boot» — each in its own background with its own delay
	# the «off» form: nothing of ours runs, «at boot» neither — heal reaches here on a deactivated router too (a USB drive plugged in
	# runs it from hotplug in the `full` layout; review s.106, round 4)
	tk_sys_on "$CRON" || { echo "Enodia снята с расписания — задачи «при загрузке» не запускаются"; return 0; }
	for _bi in $(tk_ids); do
		tk_load "$_bi" || continue
		[ "$T_ENABLED" = 1 ] && [ "$T_BOOT" = 1 ] || continue
		tk_rundir || return 0; rm -f "$TK_RUN/$_bi.boot.pid"
		start-stop-daemon -S -b -m -p "$TK_RUN/$_bi.boot.pid" -x /bin/sh -- "$ENODIA_DIR/tasks.sh" run-delayed "$_bi" "$(tk_num_or "$T_DELAY" 60)" >/dev/null 2>&1
		echo "задача $_bi «$T_NAME»: запуск через $(tk_num_or "$T_DELAY" 60) с"
	done
	return 0
}

case "$1" in run|run-delayed) ;; *) trap tk_exit EXIT; trap 'exit 1' INT TERM HUP PIPE ;; esac
case "$1" in
	list-json)   cmd_list_json ;;
	get-json)    cmd_get_json "$2" ;;
	explain)     cmd_explain "$2" ;;
	raw-get)     cmd_raw_get ;;
	save)        cmd_save "$2" ;;
	del)         cmd_del "$2" ;;
	toggle)      cmd_toggle "$2" "$3" ;;
	dup)         cmd_dup "$2" ;;
	run-bg)      cmd_run_bg "$2" ;;
	stop)        cmd_stop "$2" ;;
	line-set)    cmd_line_set "$2" "$3" ;;
	line-toggle) cmd_line_toggle "$2" ;;
	adopt)       cmd_adopt "$2" ;;
	raw-save)    cmd_raw_save "$2" "$3" ;;
	file-get)    cmd_file_get "$2" ;;
	file-put)    cmd_file_put "$2" "$3" ;;
	apply)       cmd_apply "$2" ;;
	import)      cmd_import "$2" "$3" ;;
	boot)        cmd_boot ;;
	run)         cmd_run "$2" "$3" ;;
	run-delayed) case "$3" in ''|*[!0-9]*) ;; *) sleep "$3" ;; esac; cmd_run "$2" boot ;;
	*) echo "usage: tasks.sh list-json|get-json <id>|explain \"<m h dom mon dow>\"|raw-get|save <spec>|del|toggle|dup|run-bg|stop <id>|line-set|line-toggle|adopt|raw-save|file-get|file-put|apply [<crontab>]|import <dir> <full>|boot|run <id> <trigger>" >&2
	   exit 2 ;;
esac
