#!/bin/sh
# cron-lib.sh — the ONLY lock around writing the crontab. Sourced; takes and drops one lock, nothing else.
#
# WHY. Six writers change /etc/crontabs/root by read-modify-write: install.sh (cron_put, the legacy line), update-sched.sh
# (write_cron), boot.sh (cron_to_boot), uninstall.sh (step_cron, cron-restore) and tasks.sh (every derivation). Each reads the
# file, changes its own lines and writes the whole back; two at once — the later write was built from a file without the earlier
# one's line, and that line is gone (review s.106, PLAUSIBLE: heal's line lost = a router that raises nothing after a reboot, the
# watchdog's — a dead VPS with nobody to fail open). Their logic stays theirs; what they share is this ONE lock, taken before the
# read and dropped after the write.
#
# THE LOCK is a directory (mkdir is atomic on every FS here) with the holder's pid inside. A holder that died (uhttpd SIGKILLs a
# CGI, a pulled drive) is judged by /proc/<pid>. «No pid file» is not «dead» by itself — the owner may be between its mkdir and
# its write — so only a pid file missing for CRON_LOCK_NOPID waits in a row is (counted in waits: no clock, it jumps at boot).
# NESTING: a holder runs another writer as its child (uninstall's step_cron hands the crontab to `tasks.sh apply`), and the child
# would wait for its own parent. The holder exports ENODIA_CRON_HOLDER=<its pid>; a writer that finds the lock held by exactly that
# pid goes on without taking it (and leaves it to its parent).
# SAFE UNDER `set -e` (install.sh runs with it, and cron_put is called at its top level): no bare `x=$(failing)` here — a missing
# pid file read that way exited the installer on every install and update (review s.153 r1, reproduced on BE7000's busybox).
# THE WAIT HAS A CEILING (CRON_LOCK_WAIT seconds): past it the writer goes on WITHOUT the lock and says so on stderr — the line a
# person or the installer needs is worth more than the race this lock closes; a pid reused by another process cannot wedge cron.
CRON_LOCK=${CRON_LOCK:-/tmp/enodia-cron.lock}
CRON_LOCK_WAIT=${CRON_LOCK_WAIT:-30}
CRON_LOCK_NOPID=3
CRON_HELD=0
CRON_DEPTH=0
CRON_LOCK_AT=""

# cron_lock_of <crontab> — the lock of THAT file: the real crontab's lives in /tmp (CRON_LOCK); any other path (a stand's world
# substitutes the file) gets its own beside it, so worlds side by side never wait for each other.
cron_lock_of() { case "${1:-/etc/crontabs/root}" in /etc/crontabs/root) printf '%s' "$CRON_LOCK" ;; *) printf '%s' "$1.enodia-lock" ;; esac; }

# cron_pid_live <pid> — the holder still runs: its /proc entry exists and is not a ZOMBIE (a dead writer whose parent is busy
# keeps /proc/<pid> until it is reaped — read as alive, it wedged every other writer up to the ceiling).
cron_pid_live() {
	[ -d "/proc/$1" ] || return 1
	case "$(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "/proc/$1/status" 2>/dev/null)" in Z) return 1 ;; esac
	return 0
}

# cron_hold [crontab] — take the lock of that crontab (default the real one), or find it held by our ancestor. Always rc 0: the write goes on either way. RE-ENTRANT within one
# process (a writer whose helper takes it too): a second hold only counts, and only the matching last drop gives it back — else
# the inner pair reset the flag and the outer drop left the lock behind.
cron_hold() {
	if [ "$CRON_HELD" = 1 ]; then CRON_DEPTH=$((CRON_DEPTH + 1)); return 0; fi
	CRON_HELD=0; CRON_LOCK_AT=$(cron_lock_of "${1:-}")
	_chp=$(cat "$CRON_LOCK_AT/pid" 2>/dev/null) || _chp=""
	if [ -n "${ENODIA_CRON_HOLDER:-}" ] && [ "$_chp" = "$ENODIA_CRON_HOLDER" ]; then return 0; fi
	_chw=0; _chn=0
	# The lock beside a crontab whose directory is not made yet (a fresh router, a stand's world): make the directory — the writer
	# makes it anyway. A lock that CANNOT be made (mkdir fails and nothing is there: read-only, no space, a file in the way) is
	# nobody's to wait for — go on at once; waiting is only for a lock somebody holds (it cost every write the whole ceiling).
	[ -d "${CRON_LOCK_AT%/*}" ] || mkdir -p "${CRON_LOCK_AT%/*}" 2>/dev/null
	until mkdir "$CRON_LOCK_AT" 2>/dev/null; do
		if [ ! -e "$CRON_LOCK_AT" ]; then
			mkdir "$CRON_LOCK_AT" 2>/dev/null && break
			[ -e "$CRON_LOCK_AT" ] || { echo "cron-lib: cannot make the crontab lock $CRON_LOCK_AT — writing without it" >&2; return 0; }
		fi
		_chp=$(cat "$CRON_LOCK_AT/pid" 2>/dev/null) || _chp=""
		# A corpse is removed only while the lock still names it: two waiters that both saw it dead would otherwise race, and the
		# later `rm` take the lock the earlier one had just made (the window shrinks to the read below; the ceiling bounds the rest).
		if [ -n "$_chp" ]; then
			_chn=0
			if ! cron_pid_live "$_chp" && [ "$(cat "$CRON_LOCK_AT/pid" 2>/dev/null)" = "$_chp" ] && rm -rf "$CRON_LOCK_AT" 2>/dev/null; then
				continue   # removed — try again at once; a failed removal waits like a live holder (no busy loop)
			fi
		else
			_chn=$((_chn + 1))
			if [ "$_chn" -gt "$CRON_LOCK_NOPID" ] && [ ! -s "$CRON_LOCK_AT/pid" ] && rm -rf "$CRON_LOCK_AT" 2>/dev/null; then
				_chn=0; continue
			fi
		fi
		_chw=$((_chw + 1))
		if [ "$_chw" -gt "$CRON_LOCK_WAIT" ]; then
			echo "cron-lib: the crontab lock is held by ${_chp:-?} for over $CRON_LOCK_WAIT s — writing without it" >&2
			return 0
		fi
		sleep 1
	done
	# The pid must LAND (a full /tmp: `>` makes the file and the write fails — an empty pid its holder would not recognise to drop,
	# review s.153 r2): not written — the lock goes, the write goes on without it (and a `set -e` caller survives).
	if ! { echo "$$" > "$CRON_LOCK_AT/pid"; } 2>/dev/null || [ "$(cat "$CRON_LOCK_AT/pid" 2>/dev/null)" != "$$" ]; then
		rm -rf "$CRON_LOCK_AT" 2>/dev/null
		echo "cron-lib: the crontab lock's pid did not land in $CRON_LOCK_AT — writing without it" >&2
		return 0
	fi
	CRON_HELD=1
	ENODIA_CRON_HOLDER=$$; export ENODIA_CRON_HOLDER
	return 0
}

# cron_drop [all] — give back what cron_hold took (nothing when it took nothing: an ancestor's lock, the ceiling passed). `all` —
# whatever the nesting depth: an EXIT trap's word (a `jfail` inside a held section must not leave the lock to a pid that may be
# reused — review s.153 r1).
cron_drop() {
	[ "$CRON_HELD" = 1 ] || return 0
	[ "${1:-}" = all ] && CRON_DEPTH=0
	if [ "$CRON_DEPTH" -gt 0 ]; then CRON_DEPTH=$((CRON_DEPTH - 1)); return 0; fi
	[ "$(cat "$CRON_LOCK_AT/pid" 2>/dev/null)" = "$$" ] && rm -rf "$CRON_LOCK_AT"
	CRON_HELD=0
	unset ENODIA_CRON_HOLDER
	return 0
}
