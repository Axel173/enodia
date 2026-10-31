#!/bin/sh
# prog-lib.sh — THE UPDATE'S PROGRESS BY STAGES (the «Обновление» screen): the ONLY owner of the progress file — its writers, its
# reader and its stage plan. Sourced, never run.
#
# WHY. An update took ~75 s on BE7000 (the file swap on a USB drive, then the replay of the settings), and the screen showed one
# spinning «Обновляю…» all along (s.174, the user: «полторы минуты — очень долго»). The screen now draws the stages with HONEST
# numbers: bytes and speed only for the download (its size is known from the signed release.txt), «N of M» files for the swap,
# named steps for the re-apply; no overall percent — the stages differ in length by two orders, and one bar would lie. The time of
# a stage is the ROUTER's monotonic clock (uptime): no RTC here, the wall clock jumps ~13 min after boot, the browser's is not ours.
#
# WHO WRITES. One run passes through several processes of possibly TWO versions: the INSTALLED gh-update.sh (download, checks), the
# package's pkg-install.sh (snapshot, swap), the new install.sh and the heal.sh replay it calls (re-apply), transport.sh for the
# exits. Each reads the file, changes its line and puts it back whole (label-lib.sh::lbl_commit_out — a poll never reads a cut
# file, C105). They run one after another, never at once, so there is no lock.
# ONLY INSIDE A RUN THE PANEL STARTED: the CGI starts the file (`prog_begin`) and gives the run ENODIA_UPD_PROG=1. heal.sh replay,
# repair and slots-up are called from many other places (boot, watchdog, «Включить VPN») — there every writer is a no-op, and its
# dependencies are not even loaded.
# A write that fails costs one line of progress, never the update: every writer returns 0.
#
# THE FORMAT IS A CONTRACT BETWEEN VERSIONS: the download is written by the version installed BEFORE the update, the rest by the one
# being installed, and it is read by whichever is installed when the panel asks. One fact per line, words separated by one space;
# a reader skips a line it does not know, a writer keeps lines it does not know.
#   mode <apply|rollback>     t0 <uptime at start>     t1 <uptime at the end>
#   st <key> <now|ok> <ts> <te|-> <n> <m> <x> <flag|->   a stage (keys — prog_plan); starting one closes the running one
#   dl <total bytes> <ts> <path>                          the package's download: the reader measures the file itself
#   sub <key> <now|ok|bad> <n> <m> [reason…]              a step of the re-apply, in the order it ran
#   now <key> [arg…]                                      what the re-apply is doing this moment
#   nowd <word>                                           its phase (`hs` — an exit waits for the handshake)
#   ver <from> <from code> <to> <to code>                 what replaces what
# A stage's END state (failed, cut) is not written: a stage stays «now» until the next one starts, and the reader judges the one
# left running by the run's outcome — so no early exit among dozens of `СТОП:` lines can forget to mark its stage.

# The file lives in a directory of its OWN, 0700, made anew by each run (prog_begin): the writers' temp files sit next to the file,
# and in a bare /tmp their names (`<file>.<pid>.new`) are predictable — a process of nobody's (dnsmasq, the desync probes) could plant
# a symlink there and root's `cat >` would write through it; the same class GH_TMP closed with `mktemp -d` (review s.175).
PROG_DIR=/tmp/enodia-upd
PROG_FILE=$PROG_DIR/prog
# Where the dependencies live: the code dir, unless the includer runs from elsewhere (pkg-install.sh runs from the PACKAGE, and the
# installed code may be older than this file).
PROG_LIB_DIR=${PROG_LIB_DIR:-$ENODIA_DIR}

# The stage plan of a mode — what the screen draws ahead of the work. One table: the reader emits it, the panel names the keys.
prog_plan() { case "$1" in rollback) echo "chk snap swap apply" ;; *) echo "dl chk snap swap apply" ;; esac; }

# Dependencies on first use only: a caller outside an update pays for parsing this file and nothing more.
_prog_deps() {
    command -v lbl_commit_out >/dev/null 2>&1 || { if [ -f "$PROG_LIB_DIR/label-lib.sh" ]; then . "$PROG_LIB_DIR/label-lib.sh"; fi; }
    command -v uptime_s >/dev/null 2>&1 || { if [ -f "$PROG_LIB_DIR/clock-lib.sh" ]; then . "$PROG_LIB_DIR/clock-lib.sh"; fi; }
    command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
    command -v lbl_commit_out >/dev/null 2>&1
}
# A writer acts only inside a run the panel started, only on a file that run began, and only until the run is closed: a background
# job the run started (heal's geo fetch → slots-up) could carry the flag past its end and write into the finished run — or race the
# run's own writers, there is no lock (review s.175; heal starts its jobs with the flag emptied, this is the second guard).
prog_on() { [ "${ENODIA_UPD_PROG:-}" = 1 ] && _prog_safe && [ -f "$PROG_FILE" ] && ! grep -q '^t1 ' "$PROG_FILE" 2>/dev/null && _prog_deps; }
# THE DIRECTORY IS OURS: not a symlink, mode 0700, owned by the user we run as (root on the router) — `prog_begin` makes it after
# `rm -rf`, and a process that made it in that gap (loop `mkdir`) would own it and plant `prog.<pid>.new` symlinks for root's `cat >`
# to write through (review s.175 r2). Asked once a process: in a sticky /tmp nobody else can move our directory afterwards.
_PRG_SAFE=0
_prog_safe() {
    [ "$_PRG_SAFE" = 1 ] && return 0
    [ -d "$PROG_DIR" ] && [ ! -L "$PROG_DIR" ] || return 1
    _prgo=$(ls -ldn "$PROG_DIR" 2>/dev/null | awk '{ print $1 " " $3 }')
    [ "$_prgo" = "drwx------ $(id -u 2>/dev/null)" ] || return 1
    _PRG_SAFE=1
}
# Free text (a reason, an exit's name) travels as one line of words: no control bytes, no quote, no backslash — the reader prints
# it into JSON as is, and awk -v would read a backslash as an escape.
_prog_txt() { printf '%s' "$*" | tr -d '\000-\037"\\'; }
# The file through awk, whole or not at all.
# `|| true`: install.sh runs under `set -e`, and a progress line must never end it.
_prog_put() { lbl_commit_out "$PROG_FILE" awk "$@" "$PROG_FILE" 2>/dev/null || true; }

# prog_begin <apply|rollback> — a new run: the previous run's file goes first, so a poll between the click and the first stage shows
# no stale stages. Called by the CGI (not gated by the flag — the flag is what it hands to the run, and only when this said 0).
# 1 — no progress for this run (the directory could not be made ours, the libraries are missing).
prog_begin() {
    # Never a directory found here: the previous run's (ours) or one planted before it (a symlink is removed, not followed). A failed
    # `mkdir` — someone made it again in between — means no progress for this run, not a write into theirs.
    rm -rf "$PROG_DIR" 2>/dev/null
    _prog_deps || return 1
    mkdir -m 700 "$PROG_DIR" 2>/dev/null || return 1
    _PRG_SAFE=0; _prog_safe || return 1
    lbl_commit_out "$PROG_FILE" printf 'mode %s\nt0 %s\n' "$1" "$(uptime_s)" 2>/dev/null
}
# prog_stage <key> — start a stage; the running one is done. Starting the stage that already runs changes nothing: the checks begin
# in gh-update.sh and go on in pkg-install.sh, and the time counts from the first.
prog_stage() {
    prog_on || return 0
    _prog_put -v k="$1" -v u="$(uptime_s)" '
        { L[++n] = $0; if ($1 == "st" && $3 == "now") cur = $2 }
        END {
            for (i = 1; i <= n; i++) {
                $0 = L[i]
                if (cur != k && $1 == "st" && $3 == "now") { $3 = "ok"; $5 = u }
                if (cur != k && $1 == "st" && $2 == k) continue
                print
            }
            if (cur != k) print "st " k " now " u " - 0 0 0 -"
        }'
}
# prog_count <n> <m> [x] — the running stage's counters (files done of all; x — files taken away by the swap).
prog_count() {
    prog_on || return 0
    _prog_put -v a="${1:-0}" -v b="${2:-0}" -v c="${3:-}" '$1 == "st" && $3 == "now" { $6 = a + 0; $7 = b + 0; if (c != "") $8 = c + 0 } { print }'
}
# prog_flag <word> — a word about the running stage (snap: `same` — the set does not change, no snapshot was taken).
prog_flag() {
    prog_on || return 0
    _prog_put -v w="$1" '$1 == "st" && $3 == "now" { $9 = w } { print }'
}
# prog_dl <total bytes> <path> — the package is being downloaded to <path>: the reader measures the file itself, so curl's chunks
# cost no writes at all.
prog_dl() {
    prog_on || return 0
    _prog_put -v t="${1:-0}" -v p="$2" -v u="$(uptime_s)" '$1 == "dl" { next } { print } END { print "dl " (t + 0) " " u " " p }'
}
# prog_sub <key> <now|ok|bad> [n m [reason…]] — a step of the re-apply; it keeps the place where it first appeared.
prog_sub() {
    prog_on || return 0
    _prgk=$1; _prgs=$2; _prgn=${3:-0}; _prgm=${4:-0}; shift 2
    if [ $# -gt 0 ]; then shift; fi
    if [ $# -gt 0 ]; then shift; fi
    _prog_put -v k="$_prgk" -v l="sub $_prgk $_prgs $_prgn $_prgm $(_prog_txt "$*")" \
        '$1 == "sub" && $2 == k { if (!d) print l; d = 1; next } { print } END { if (!d) print l }'
}
# prog_now <key> [arg…] — what the re-apply is doing this moment (the screen words the key; the arg is data, e.g. an exit's name).
prog_now() {
    prog_on || return 0
    _prgk=$1; shift
    _prog_put -v l="now $_prgk $(_prog_txt "$*")" '$1 == "now" || $1 == "nowd" { next } { print } END { print l }'
}
# prog_nowd <word> — a phase of what is done now (`hs`: an exit waits for its server's handshake — transport-awg.sh::slot_wait_hs);
# the next prog_now drops it.
prog_nowd() {
    prog_on || return 0
    _prog_put -v l="nowd $(_prog_txt "$1")" '$1 == "nowd" { next } { print } END { print l }'
}
# prog_ver <from name> <from code> <to name> <to code> — what is replaced by what (the screen's «1.3.4 → 1.3.5»). The updater says it
# from the signed description, the installer again from the package itself (the rollback's target is known only there).
prog_ver() {
    prog_on || return 0
    _prog_put -v l="ver $(_prog_txt "${1:-?}") $(_prog_txt "${2:-0}") $(_prog_txt "${3:-?}") $(_prog_txt "${4:-0}")" '$1 == "ver" { next } { print } END { print l }'
}
# prog_close — the run is over (its outcome is the updater's state file); the stage left running ends here.
prog_close() {
    prog_on || return 0
    _prog_put -v u="$(uptime_s)" '$1 == "t1" { next } { print } END { print "t1 " u }'
}

# prog_json <run|ok|fail|cut> — the run as the screen draws it, or `null` (no run since boot, or one the panel did not start). The
# outcome is the updater's (status-json): running · ended well · ended with a refusal · its holder died. Every stage of the plan is
# answered:
#   now — running; ok — done (no time when it left no line: a version without this file did it — the first update to it);
#   bad — the run ended with a refusal while it ran, or (apply) a step of it failed; cut — the run's holder died while it ran;
#   wait — not reached.
prog_json() {
    # The same directory check as the writers: before the first run since boot anyone could have made /tmp/enodia-upd with a «run» of
    # their own in it (review s.175 r3) — the screen draws only ours.
    if [ ! -f "$PROG_FILE" ] || ! _prog_safe || ! _prog_deps; then printf 'null'; return 0; fi
    _prgp=$(awk '$1 == "dl" { print $4; exit }' "$PROG_FILE" 2>/dev/null)
    # Measured only where the updater downloads (its mktemp -d, gh-update.sh::pkg_mkdir): root sizes no other file named in the line.
    case "$_prgp" in /tmp/enodia-pkg.*/pkg.tar.gz) ;; *) _prgp="" ;; esac
    _prgg=-1
    if [ -n "$_prgp" ] && [ -f "$_prgp" ]; then _prgg=$(wc -c < "$_prgp" 2>/dev/null | tr -cd '0-9'); [ -n "$_prgg" ] || _prgg=-1; fi
    # Whole or nothing here too: a JSON cut by a failing awk would break the panel's whole status answer.
    # A line with a quote or a backslash is not one of ours (the writers strip both) — skipped, never printed into the JSON.
    _prgj=$(awk -v o="$1" -v up="$(uptime_s)" -v got="$_prgg" -v pa="$(prog_plan apply)" -v pr="$(prog_plan rollback)" '
        /["\\]/ { next }
        $1 == "mode" { mode = ($2 == "rollback") ? "rollback" : "apply" }
        $1 == "nowd" { nd = $2 }
        $1 == "t0" { t0 = $2 + 0 }
        $1 == "t1" { t1 = $2 + 0; closed = 1 }
        $1 == "st" { S[$2] = 1; SS[$2] = $3; TS[$2] = $4 + 0; TE[$2] = $5; N[$2] = $6 + 0; M[$2] = $7 + 0; X[$2] = $8 + 0; F[$2] = ($9 == "-" ? "" : $9) }
        $1 == "dl" { dt = $2 + 0; dts = $3 + 0; hasdl = 1 }
        $1 == "sub" { if (!(($2) in SB)) SO[++ns] = $2; SB[$2] = $3; SN[$2] = $4 + 0; SM[$2] = $5 + 0
                      r = ""; for (i = 6; i <= NF; i++) { if (i > 6) r = r " "; r = r $i }; SR[$2] = r; if ($3 == "bad") subbad = 1 }
        $1 == "now" { nk = $2; na = ""; for (i = 3; i <= NF; i++) { if (i > 3) na = na " "; na = na $i }; hasnow = 1 }
        $1 == "ver" { vf = $2; vfc = $3 + 0; vt = $4; vtc = $5 + 0; hasver = 1 }
        END {
            # The plan as words of one line: awk here has no split() (BusyBox), so the keys are taken apart by hand.
            pl = (mode == "rollback") ? pr : pa; np = 0; w = ""
            for (i = 1; i <= length(pl); i++) { c = substr(pl, i, 1); if (c == " ") { if (w != "") P[++np] = w; w = "" } else w = w c }
            if (w != "") P[++np] = w
            last = 0; for (i = 1; i <= np; i++) if (P[i] in S) last = i
            printf "{\"mode\":\"%s\",\"up\":%d,\"t0\":%d,\"t1\":%s,\"plan\":[", mode, up, t0, (closed ? t1 : "null")
            for (i = 1; i <= np; i++) printf "%s\"%s\"", (i > 1 ? "," : ""), P[i]
            printf "],\"stages\":["
            for (i = 1; i <= np; i++) {
                k = P[i]
                if (k in S) {
                    st = SS[k]
                    if (st == "now" && o != "run") st = (o == "ok") ? "ok" : (o == "fail") ? "bad" : "cut"
                    if (k == "apply" && subbad && st == "ok") st = "bad"
                    te = (TE[k] == "-") ? ((SS[k] == "now" && closed) ? t1 : "null") : TE[k] + 0
                    printf "%s{\"k\":\"%s\",\"st\":\"%s\",\"ts\":%d,\"te\":%s,\"n\":%d,\"m\":%d,\"x\":%d,\"f\":\"%s\"}", (i > 1 ? "," : ""), k, st, TS[k], te, N[k], M[k], X[k], F[k]
                } else {
                    st = (i < last || o == "ok") ? "ok" : "wait"
                    printf "%s{\"k\":\"%s\",\"st\":\"%s\",\"ts\":null,\"te\":null,\"n\":0,\"m\":0,\"x\":0,\"f\":\"\"}", (i > 1 ? "," : ""), k, st
                }
            }
            printf "],\"dl\":"
            if (hasdl) printf "{\"total\":%d,\"ts\":%d,\"got\":%d}", dt, dts, got + 0; else printf "null"
            printf ",\"subs\":["
            # A step left running when the run ended takes the outcome of the run, as a stage does.
            for (i = 1; i <= ns; i++) {
                k = SO[i]; st = SB[k]
                if (st == "now" && o != "run") st = (o == "ok") ? "ok" : (o == "fail") ? "bad" : "cut"
                printf "%s{\"k\":\"%s\",\"st\":\"%s\",\"n\":%d,\"m\":%d,\"why\":\"%s\"}", (i > 1 ? "," : ""), k, st, SN[k], SM[k], SR[k]
            }
            printf "],\"now\":"
            if (hasnow) printf "{\"k\":\"%s\",\"a\":\"%s\",\"d\":\"%s\"}", nk, na, nd; else printf "null"
            printf ",\"ver\":"
            if (hasver) printf "{\"from\":\"%s\",\"fc\":%d,\"to\":\"%s\",\"tc\":%d}", vf, vfc, vt, vtc; else printf "null"
            printf "}"
        }' "$PROG_FILE" 2>/dev/null) || _prgj=""
    case "$_prgj" in '{'*'}') printf '%s' "$_prgj" ;; *) printf 'null' ;; esac
}
