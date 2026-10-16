#!/bin/sh
# warp.sh — «ПОЛУЧИТЬ WARP»: the router registers ITSELF at Cloudflare WARP and gets its own AmneziaWG config, an exit on it and
# (optionally) a road through it for a server whose address the ISP blocked (road.sh).
#
# WHY ITS OWN REGISTRATION. A WARP config from a bot or a friend is a SHARED key: the server keeps one session per key and roams
# between the devices that use it — both flap (the same WARP.conf on BE7000 and AX3600 did exactly that). Online generators also
# create the private key on THEIR side. Here the key is generated on the router (`awg genkey`) and never leaves it; one
# registration per config. The API is Cloudflare's unofficial client API (the Android app's): it changes ⇒ every deviation is a
# refusal in words («Cloudflare сменил порядок — нужна новая версия панели»), never a half-written config.
# MASKING (spike BE7000 10.10.2026, dev notes «сервер-через-WARP-дизайн» §9): plain WireGuard to WARP is cut by the ISP after the
# handshake (~3 KB). The config always carries an I1 the ROUTER builds: a QUIC Initial header — the bytes every real QUIC
# Initial has — with the connection id and the body random (`<r N>` is re-drawn by amneziawg-go on EVERY handshake): nothing to
# learn but «this is QUIC», nothing to go stale. S1..S4 stay 0 and H1..H4 = 1..4: the server is vanilla WireGuard.
# PORT BY THE RESULT (hardware test of the registration, BE7000 10.10.2026, dev notes §10): WARP listens on many ports and the ISP
# cuts some of them right after the handshake — 2408, WARP's standard one, gave a handshake and 92 bytes, 891 carried. A handshake
# proves nothing, so the config gets the first port that CARRIES DATA: `transport-awg.sh try` raises a throwaway interface per port
# and asks Cloudflare's trace through it (`warp=on` = pass; the same answer names the colo). None passes ⇒ an error in words and no
# config, and the registration nobody uses is given back (`fail` → `give_back`).
# SEVERAL, AND WHAT IS KNOWN ABOUT EACH (user's decisions 10.10.2026). `get` no longer stops at one: the next config is WARP-2,
# WARP-3… — its own key each, never a copy. What the router learnt while getting one (which ports the ISP cut, where Cloudflare took
# the connection, when) and the registration's id and token used to die with the /tmp answer — now they are a record (REG below),
# and the panel shows it. A config that already exists is worked on WITHOUT touching its live session: the port is picked again
# (`repick`) and a masking is tried (`mask`) under a THROWAWAY registration — the server keeps one session per key, a probe with the
# config's own key would knock its exit off — and only a config that passed is written; `reget` replaces the key itself.
# `device` — a WARP for ANOTHER device: registered and probed here, shown once (QR, file, text), nothing of it kept on the router.
#
# Commands (the long ones start in the background; progress and the answer → a JSON file the panel polls, `status`):
#   warp.sh get [<rider config>] — register, write configs/<next free name>.conf, create the exit of that name, and set the rider's
#                                  road through it
#   warp.sh repick <config>      — pick the port again: the config's own port first; it still passes ⇒ the config and its exit
#                                  are not touched (the record alone notes what this pick saw, when)
#   warp.sh reget <config>       — a new registration (new key) into the same config; its exit and the roads stay
#   warp.sh mask <config> gen|<file> — the masking: the router's own, or the text of <file>; written only if WARP answers with it
#   warp.sh device               — a config for another device → RAM; `device-take` hands it out ONCE as {"ok":true,"conf_b64":…}
#   warp.sh status               — that JSON (`dev` first — a device config waits; state none|running|done|error, op, name, msg,
#                                  exit, rider, port, colo; `job` last — the id of whoever started the work)
#   warp.sh info                 — {"now":…,"items":[…]}: every WARP config and what the record knows about it
#   warp.sh repick <cfg> own     — the same pick with the config's OWN key: for an exit that shakes hands and carries nothing
#                                  (the watchdog's call) — no registration, no Cloudflare API; `running` — the config a job works on now;
#                                  `holds <cfg>` — code 0 while such a pick keeps that config's exits DOWN (nobody else raises them)
#   warp.sh prune [give]         — drop the records of configs that are gone; `give` (the config's delete calls it so) — and
#                                  give their registrations back to Cloudflare, in the background
#   warp.sh import <file>        — a backup's records: merged by key (the archive's line wins), then pruned
#   warp.sh run … | run-repick … | run-reget … | run-mask … | run-device — the work itself, in the foreground
#   warp.sh i1                   — print a generated I1 (what the config gets)
#   warp.sh list                 — the AmneziaWG configs that ARE WARP (server key = Cloudflare's): `name⇥i1` (1 — has a masking
#                                  I1, 0 — none: the ISP may cut it after the handshake) — the ONLY answer «is this config WARP»
#   warp.sh colo <exit id>       — where Cloudflare took exit <id>'s connection: its trace through the exit's live interface →
#                                  {"colo":"HEL","warp":true} | {"colo":"","why":"…"} (DME = Moscow, filtered since spring 2026)
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
API=https://api.cloudflareclient.com/v0a2158
UA="okhttp/3.12.1"; CV="a-6.10-2158"                  # what the Android app sends; the API refuses other clients
WARP_PUB='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo='   # one server key for everyone — a config with it IS WARP (road/panel badge)
NAME=WARP                                              # the first config and its exit; the next ones — WARP-2 … WARP-9 (next_name)
PORTS="891 500 1701 4500 854 878 894 908 2408"          # the measured one first, WARP's standard one last (cut here)
TRACE=https://1.1.1.1/cdn-cgi/trace                     # answers `warp=on` + `colo=XXX` only through WARP
TRY_SECS=8                                             # per port: a live WARP answers in ~1 s; worst case ≤ 9 × ~11 s
ST=/tmp/enodia-warp.json; PIDF=/tmp/enodia-warp.pid
STARTF=/tmp/enodia-warp.start                          # the pid of the front verb that is launching a job right now (busy)
STARTL=/tmp/enodia-warp-start.lock                     # «is a job alive?» and «the start is mine» are ONE step under it (take_start)
REGL=/tmp/enodia-warp-reg.lock                         # one writer of the record at a time (reg_lock)
HOLDF=/tmp/enodia-warp.hold                            # the config whose exits an own-key pick keeps DOWN right now (cmd_holds)
DEVF=/tmp/enodia-warp-dev.conf                         # RAM, 600: the other device's config until the panel takes it (once)
DEV_TTL=${ENODIA_WARP_DEV_TTL:-600}                    # …and no longer than this: nobody came for it — it is removed
case "$DEV_TTL" in ''|*[!0-9]*) DEV_TTL=600 ;; esac
# THE RECORD — `pub⇥own⇥id⇥token⇥at⇥port⇥cut⇥colo⇥i1⇥pat`, one line per WARP config, mode 600 (the token manages the registration).
# KEYED BY THE PUBLIC KEY of the config's private key, not by the file's name: a rename needs no hook, and a config REPLACED under
# the same name (an upload) does not inherit a stranger's record — the name is not identity. own 1|0 — registered here; at / pat —
# when registered / when the port was last picked (epoch, 0 — the clock was not real then); cut — the ports that did NOT pass at
# that pick, by commas; i1 — gen|custom. Empty fields are `-`.
REG="$ENODIA_STATE/.warp-reg"
OP=get
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
command -v curl_ca_opt >/dev/null 2>&1 || curl_ca_opt() { return 0; }
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi   # jtxt: a byte cut that keeps UTF-8 whole
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '"\000-\037\\'; }
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi   # pid_runs: alive AND ours
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi     # lbl_lock_take/_drop: a lock directory, stale by /proc
command -v lbl_lock_take >/dev/null 2>&1 || { lbl_lock_take() { mkdir "$1" 2>/dev/null; }; lbl_lock_drop() { rm -rf "$1" 2>/dev/null; }; }
command -v lbl_commit >/dev/null 2>&1 || lbl_commit() { if [ -z "$2" ]; then rm -f "$1"; return $?; fi; if printf '%s\n' "$2" > "$1.$$" 2>/dev/null && [ "$(cat "$1.$$" 2>/dev/null)" = "$2" ]; then mv "$1.$$" "$1" && return 0; fi; rm -f "$1.$$"; return 1; }
TAB=$(printf '\t')
NL='
'

# The masking packet: QUIC v1 Initial long header — first byte 0xce (long header, Initial, 4-byte packet number), version
# 00000001, DCID length 8, DCID random, SCID length 0, token length 0, length 0x44d0 (1232), packet number + payload random ⇒
# 1250 bytes, the size of a real client Initial. Measured: works like a captured template, with and without Jc.
gen_i1() { printf '<b 0xce0000000108><r 8><b 0x000044d0><r 1232>'; }

# THE JOB'S ID — whoever starts a work may name it (ENODIA_WARP_JOB: the panel makes an id per start and the CGI exports it; the
# background work inherits the environment). It goes into EVERY status line of that work, at the END of the object (cmd_status
# reads a line by its beginning): a tab knows its own job among the ones it merely sees running — «I started something» is not
# that knowledge (a tab took another tab's device config, review s.122). A work started by hand has no id and is nobody's.
JOB=$(printf '%s' "${ENODIA_WARP_JOB:-}" | tr -cd 'a-f0-9' | cut -c1-32)
put() {
    _wpj=$1; [ -z "$JOB" ] || _wpj="${1%\}},\"job\":\"$JOB\"}"
    _wpt=$(mktemp "$ST.XXXXXX" 2>/dev/null) || return 1; printf '%s\n' "$_wpj" > "$_wpt" && mv "$_wpt" "$ST"   # mktemp: O_EXCL, no planted name
}
# The config for port $1 from the registration's answer (reg_new's variables): the probe and the saved file are one text. `_wi1` —
# a masking to keep (reget of a config with the person's own); empty — the router's.
wconf() {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32%s\nMTU = 1280\n' "$_wpriv" "$_wv4" "${_wv6:+, $_wv6/128}"
    printf 'S1 = 0\nS2 = 0\nJc = 4\nJmin = 40\nJmax = 70\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = %s\n' "${_wi1:-$(gen_i1)}"
    printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s:%s\nPersistentKeepalive = 25\n' "$WARP_PUB" "$_wep" "$1"
}
# …the same for ANOTHER device: a phone has no resolver of its own inside the tunnel — Cloudflare's.
dconf() { wconf "$1" | awk '{ print } /^MTU = 1280$/ { print "DNS = 1.1.1.1, 1.0.0.1" }'; }
# The text of config $1 with: the key and address of ANOTHER registration ($2, $3; empty — its own), the Endpoint's port $4 and the
# masking $5 (empty — its own; a config that had none gets the line before [Peer]). One awk for the probe's copy and the saved file.
conf_as() {
    awk -v pk="$2" -v ad="$3" -v pt="$4" -v i1="$5" '
        { sub(/\r$/, "") }
        /^[ \t]*PrivateKey[ \t]*=/ { if (pk != "") { print "PrivateKey = " pk; next } }
        /^[ \t]*Address[ \t]*=/    { if (ad != "") { print "Address = " ad; next } }
        /^[ \t]*Endpoint[ \t]*=/   { if (pt != "") { v = $0; sub(/:[0-9]+[ \t]*$/, "", v); print v ":" pt; next } }
        /^[ \t]*I1[ \t]*=/         { seen = 1; if (i1 != "") { print "I1 = " i1; next } }
        /^[ \t]*\[Peer\]/          { if (i1 != "" && !seen) { print "I1 = " i1; seen = 1 } }
        { print }' "$1"
}
xconf() { conf_as "$_wsrc" "$_wpriv" "$_wv4/32${_wv6:+, $_wv6/128}" "$1" "$_wi1"; }
oconf() { conf_as "$_wsrc" "" "" "$1" ""; }   # …and the config AS IT IS but for the port: its own key, address and masking
say() { put "{\"state\":\"running\",\"op\":\"$OP\",\"name\":\"$_wnm\",\"msg\":\"$1\"}"; }
# A registration this run made and NO SAVED CONFIG OWNS YET (_wgid, _wgtok — set by reg_new): the throwaway of a probe, a new one
# before its config is written. Every refusal goes through `fail`, so it is given back there — no branch has to remember (the
# all-ports-cut refusal of `get` and the probe's own refusals used to leave theirs at Cloudflare). The work that keeps the
# registration says so by `owned`.
_wgid=""; _wgtok=""
give_back() { reg_del "$_wgid" "$_wgtok"; _wgid=""; _wgtok=""; }
owned() { _wgid=""; _wgtok=""; }
# A REFUSAL THAT IS NOT AN ANSWER (`_wsoon=1` before `fail` → `"soon":true` in the status): something passing cut the work short
# — another config probe held the probe's lock, the probe's own interface did not come up (a loaded router, a rule that did not
# go in: it says nothing of the ISP). Whoever repeats the work by itself (the watchdog's re-pick) reads it: such a work is
# repeated after the SHORT pause, every other refusal is an answer that half an hour would not change.
_wsoon=""
fail() { give_back; put "{\"state\":\"error\",\"op\":\"$OP\",\"name\":\"$_wnm\",\"msg\":\"$1\"${_wsoon:+,\"soon\":true}}"; exit 1; }
now_s() { if clock_sane; then date +%s 2>/dev/null; else echo 0; fi; }

# ---- what a config says about itself -------------------------------------------------------------------------------------------
cfg_val() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'; }
cfg_pub() { _wcp=$(cfg_val "$1" PrivateKey | tr -d ' \t'); [ -n "$_wcp" ] && printf '%s' "$_wcp" | "$ENODIA_BIN/awg" pubkey 2>/dev/null | tr -d ' \r\n'; }
cfg_port() { cfg_val "$1" Endpoint | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p'; }
cfg_ep() { cfg_val "$1" Endpoint | sed 's/:[0-9]*[[:space:]]*$//' | tr -d '[] \t'; }
# Names are compared AS TEXT (`x ""`): awk takes a `-v` value that looks like a number for one, and config «01» was config «1».
is_warp() { cmd_list | awk -F"$TAB" -v n="$1" '($1 "") == (n "") { f = 1 } END { exit !f }'; }
# The ENABLED exits that run on config $1 — the registry's answer without the exit's free-text name (slots.sh list-enabled:
# id⇥transport⇥config⇥…): a name is the person's text, and a tab in it shifted the fields. A switched-off exit has no carrier to
# restart — it reads the config when it is switched on.
exits_of() { sh "$ENODIA_DIR/slots.sh" list-enabled 2>/dev/null | awk -F"$TAB" -v c="$1" '$2 == "awg" && ($3 "") == (c "") { print $1 }'; }
# A config changed under its exits: the registry's own «set the config» takes the carrier down and up by the new text (slots.sh
# cmd_set) — no second way to restart an exit. With the VPN switched off by hand it raises nothing, as it should. An exit that
# did not come back is NAMED (_wrf, for the work's last word): the registry answers a refusal by its code and «не поднялась» in
# words, and a thrown-away answer left the person with «готово» over an exit that is down.
reup_exits() {
    _wrf=""
    for _wx in $(exits_of "$1"); do
        _wxo=$(sh "$ENODIA_DIR/slots.sh" set "$_wx" config "$1" 2>&1) && ! printf '%s' "$_wxo" | grep -q 'не поднялась' || _wrf="$_wrf${_wrf:+, }№$_wx"
    done
}
# …and the words for it, appended to the work's result.
reup_note() { [ -z "$_wrf" ] || printf '; выход %s не поднялся — откройте его в «Дополнительных выходах»' "$_wrf"; }

# ---- the record ----------------------------------------------------------------------------------------------------------------
reg_line() { [ -n "$1" ] && [ -f "$REG" ] && awk -F"$TAB" -v k="$1" '($1 "") == (k "") { print; exit }' "$REG" 2>/dev/null; }
# ONE WRITER AT A TIME. Every writer reads the file and writes it back whole: a job's reg_put and `prune` (a config deleted in the
# panel while the job runs) at once — and the later one writes the record without the other's line, a fresh registration losing
# its token (review s.122). A lock that could not be taken does not stop the write: a record lost for sure is worse than a race.
reg_lock() { _wrl=0; lbl_lock_take "$REGL" 'warp\.sh' && _wrl=1; return 0; }
reg_unlock() { [ "$_wrl" = 1 ] && lbl_lock_drop "$REGL"; _wrl=0; return 0; }
# EVERY WRITER OF THE RECORD BUILDS THE WHOLE NEW TEXT IN MEMORY AND COMMITS IT WHOLE OR NOT AT ALL (label-lib's lbl_commit: next
# to the file + mv, the temp file COMPARED with the text before the rename; mode 600; an empty text removes the file). It used to
# be `awk … > tmp && mv tmp file` — trusting the writer's exit code, and BusyBox 1.25.1 awk EXITS 0 WHEN ITS WRITE FAILS — measured
# with the router's binary, gawk reports the error. On a state partition with no free block an empty temp file replaced the
# record — the id and token of every registration gone, on any config delete or backup import (review s.123, round 4).
# «Could not compute the text» is not «the text is empty»: a reader that failed (no fork under memory pressure) commits nothing.
reg_commit() { ( umask 077; lbl_commit "$REG" "$1" ); }
# The record's lines without key $1 → _wrx; code 1 — the file could not be read.
reg_others() {
    _wrx=""
    [ -f "$REG" ] || return 0
    _wrx=$(awk -F"$TAB" -v k="$1" '($1 "") != (k "")' "$REG" 2>/dev/null) || return 1
    return 0
}
reg_put() {   # pub own id token at port cut colo i1 pat
    [ -n "$1" ] || return 1
    reg_lock
    _wrr=1
    if reg_others "$1"; then
        reg_commit "${_wrx:+$_wrx$NL}$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "${2:-0}" "${3:--}" "${4:--}" "${5:-0}" "${6:--}" "${7:--}" "${8:--}" "${9:--}" "${10:-0}")"; _wrr=$?
    fi
    reg_unlock
    return "$_wrr"
}
reg_drop() {
    [ -n "$1" ] && [ -f "$REG" ] || return 0
    reg_lock
    reg_others "$1" && reg_commit "$_wrx"
    reg_unlock
    return 0
}
# The public keys of every WARP config, a line each → stdout; code 1 — one of them could NOT be read (no `awg` program, the fork
# failed under memory pressure): the list is then not the whole truth, and nobody may drop a record by it.
warp_keys() {
    [ -x "$ENODIA_BIN/awg" ] || return 1
    for _wpn in $(cmd_list | cut -f1); do
        _wk=$(cfg_pub "$ENODIA_STATE/configs/$_wpn.conf"); [ -n "$_wk" ] || return 1
        printf '%s\n' "$_wk"
    done
    return 0
}
# The records whose key no WARP config holds any more are dropped — a deleted config takes its token with it. «Could not check» is
# not «gone»: a key that could not be read (warp_keys) — and nothing is dropped.
# THE KEYS ARE READ UNDER THE LOCK: read before it, the list was a picture of the past by the time the record was rewritten — a
# job that saved its config and its record in between lost the record (id and token) to a `prune` started by a config deleted in
# another tab or by a backup's import (review s.123, round 3). A writer waits for the lock while the keys are read.
# The lines are sifted by the shell itself, in memory: no key list in a file (unchecked, it kept NOTHING when it came out empty),
# no awk between the record and its new text.
cmd_prune() {   # $1 = give — the registrations of the OWN records dropped here go back to Cloudflare (give_bg)
    [ -s "$REG" ] || return 0
    reg_lock
    _wpgv=""
    if _wkeep=$(warp_keys); then
        _wprn=""
        while IFS= read -r _wprl || [ -n "$_wprl" ]; do
            case "$NL$_wkeep$NL" in
                *"$NL${_wprl%%"$TAB"*}$NL"*) _wprn="${_wprn:+$_wprn$NL}$_wprl" ;;
                *) _wpgv="${_wpgv:+$_wpgv$NL}$_wprl" ;;
            esac
        done < "$REG"
        reg_commit "$_wprn" || _wpgv=""   # not rewritten — the lines (and their tokens) are still in the record: nothing goes back
    fi
    reg_unlock
    if [ "$1" = give ] && [ -n "$_wpgv" ]; then give_bg "$_wpgv"; fi
    return 0
}
# THE REGISTRATIONS OF THE RECORDS `prune give` DROPPED GO BACK TO CLOUDFLARE. The config was deleted in the panel, and with the
# record its token was lost for good: the registration stayed at Cloudflare, used by nobody, and nothing could remove it any
# more (hardware walk 12.10.2026 — the pair of a deleted config still answered 200). Only OWN records with both halves, and only
# on `give`: an import's prune drops an archive's records of configs that are not here, and those registrations may be in use
# where the archive came from.
# IN THE BACKGROUND: a DELETE lasts up to 15 s, and the caller is the panel's «Удалить конфиг». The pairs travel in a private
# file (600), never in argv (see reg_del); the job removes it. BEST EFFORT, as every give-back: no answer — the registration
# simply stays. `-p` names a pidfile of this very job: without one start-stop-daemon looks for a running /bin/sh and starts
# nothing.
give_bg() {   # $1 = the dropped lines of the record
    _wgl=$(printf '%s\n' "$1" | awk -F"$TAB" '$2 == "1" && $3 != "" && $3 != "-" && $4 != "" && $4 != "-" { print $3 "\t" $4 }')
    [ -n "$_wgl" ] || return 0
    _wgf=$(umask 077; mktemp /tmp/enodia-warp-give.XXXXXX 2>/dev/null) || return 0
    printf '%s\n' "$_wgl" > "$_wgf" || { rm -f "$_wgf"; return 0; }
    if [ -x /sbin/start-stop-daemon ]; then
        start-stop-daemon -S -b -m -p "$_wgf.pid" -x /bin/sh -- "$ENODIA_DIR/warp.sh" run-give "$_wgf" >/dev/null 2>&1
    else ( sh "$ENODIA_DIR/warp.sh" run-give "$_wgf" </dev/null >/dev/null 2>&1 & ); fi
    return 0
}
cmd_run_give() {   # $1 = the file of `id⇥token` pairs — ours by its name, and nothing else
    case "$1" in /tmp/enodia-warp-give.*) ;; *) return 1 ;; esac
    [ -f "$1" ] || return 0
    _wgvf=$1
    trap 'rm -f "$_wgvf" "$_wgvf.pid"' EXIT
    trap 'exit 1' INT TERM HUP PIPE
    while IFS="$TAB" read -r _wgi _wgt || [ -n "$_wgi" ]; do reg_del "$_wgi" "$_wgt"; done < "$_wgvf"
    return 0
}
# A backup's records (cgi-bin/backup, after the configs are in): a line is taken only in the record's own shape, the archive's
# wins for its key, and then everything whose key no WARP config holds is dropped — a record means something only next to its
# config. The archive is a stranger's text: the key must look like a key (with no `awg` program nothing is pruned, and the line
# would stay), a number has no leading zero (`007` went into `info`'s JSON as is, and the panel lost every card's record), at most
# IMPORT_MAX lines are read, and the record is written ONCE — a write per line was a flash rewrite per line.
IMPORT_MAX=64
cmd_import() {
    if [ -f "$1" ]; then
        reg_lock
        # The archive's lines of the record's own shape → _wia (in memory, like every writer here — see reg_commit).
        _wim=0; _wia=""
        while IFS="$TAB" read -r _wr1 _wr2 _wr3 _wr4 _wr5 _wr6 _wr7 _wr8 _wr9 _wr10 _wrrest || [ -n "$_wr1" ]; do
            [ "$_wim" -lt "$IMPORT_MAX" ] || break
            printf '%s' "$_wr1" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || continue
            case "$_wr2" in 0|1) ;; *) continue ;; esac
            printf '%s\n%s\n' "$_wr3" "$_wr4" | grep -Evq '^(-|[A-Za-z0-9_-]{1,64})$' && continue
            printf '%s\n%s\n' "$_wr5" "$_wr10" | grep -Evq '^(0|[1-9][0-9]{0,11})$' && continue
            case "$_wr6" in -) ;; ''|0*|*[!0-9]*) continue ;; esac
            case "$_wr7" in -) ;; ''|*[!0-9,]*) continue ;; esac
            case "$_wr8" in -|[A-Z][A-Z][A-Z]) ;; *) continue ;; esac
            case "$_wr9" in -|gen|custom) ;; *) continue ;; esac
            _wim=$((_wim+1))
            _wia="${_wia:+$_wia$NL}$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$_wr1" "$_wr2" "$_wr3" "$_wr4" "$_wr5" "$_wr6" "$_wr7" "$_wr8" "$_wr9" "$_wr10")"
        done < "$1"
        # The archive's line wins for its key (the LAST one, if the archive repeats a key); the rest of the record stays.
        if [ -n "$_wia" ] && _wia=$(printf '%s\n' "$_wia" | awk -F"$TAB" '{ a[$1] = $0; if (!($1 in o)) { o[$1] = 1; q[++n] = $1 } }
                END { for (i = 1; i <= n; i++) print a[q[i]] }') && [ -n "$_wia" ]; then
            _wiak=$(printf '%s\n' "$_wia" | cut -f1); _wio=""
            if [ -f "$REG" ]; then
                while IFS= read -r _wil || [ -n "$_wil" ]; do
                    [ -n "$_wil" ] || continue
                    case "$NL$_wiak$NL" in *"$NL${_wil%%"$TAB"*}$NL"*) ;; *) _wio="${_wio:+$_wio$NL}$_wil" ;; esac
                done < "$REG"
            fi
            reg_commit "${_wio:+$_wio$NL}$_wia"
        fi
        reg_unlock
    fi
    cmd_prune
}

# ---- Cloudflare ----------------------------------------------------------------------------------------------------------------
# A new registration → _wpriv _wpub _wv4 _wv6 _wep _wrid _wtok. Needs the work directory $W.
reg_new() {
    say "создаю ключ на роутере"
    _wpriv=$("$ENODIA_BIN/awg" genkey 2>/dev/null); _wpub=$(printf '%s' "$_wpriv" | "$ENODIA_BIN/awg" pubkey 2>/dev/null)
    [ -n "$_wpriv" ] && [ -n "$_wpub" ] || fail "не удалось создать ключ (awg genkey)"
    say "регистрируюсь у Cloudflare"
    _wtos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    printf '{"key":"%s","install_id":"","fcm_token":"","tos":"%s","model":"PC","serial_number":"","locale":"en_US"}' "$_wpub" "$_wtos" > "$W/req"
    _wca=$(curl_ca_opt "$API/reg")
    # shellcheck disable=SC2086
    _wc=$(curl -s $_wca -o "$W/reg" -w '%{http_code}' --connect-timeout 10 --max-time 20 -X POST \
        -H "User-Agent: $UA" -H "CF-Client-Version: $CV" -H 'Content-Type: application/json' --data-binary @"$W/req" "$API/reg" 2>/dev/null)
    case "$_wc" in
        200) ;;
        000|'') fail "Cloudflare не ответил — попробуйте позже" ;;
        *) fail "Cloudflare отклонил регистрацию (HTTP $_wc): он сменил порядок — нужна новая версия панели" ;;
    esac
    _wsk=$(jsonfilter -i "$W/reg" -e '@.config.peers[0].public_key' 2>/dev/null)
    _wv4=$(jsonfilter -i "$W/reg" -e '@.config.interface.addresses.v4' 2>/dev/null)
    _wv6=$(jsonfilter -i "$W/reg" -e '@.config.interface.addresses.v6' 2>/dev/null)
    _wep=$(jsonfilter -i "$W/reg" -e '@.config.peers[0].endpoint.v4' 2>/dev/null | sed 's/:[0-9]*$//')
    # The registration's id and token — kept with the config (REG): they are what «manage this registration» needs later. Not the
    # form we know — not kept, and nothing else depends on them.
    _wrid=$(jsonfilter -i "$W/reg" -e '@.id' 2>/dev/null); _wtok=$(jsonfilter -i "$W/reg" -e '@.token' 2>/dev/null)
    printf '%s' "$_wrid" | grep -Eq '^[A-Za-z0-9_-]{1,64}$' || _wrid=""
    printf '%s' "$_wtok" | grep -Eq '^[A-Za-z0-9_-]{1,64}$' || _wtok=""
    _wgid=$_wrid; _wgtok=$_wtok          # nobody's yet: `fail` gives it back (the three refusals right below included)
    [ "$_wsk" = "$WARP_PUB" ] || fail "Cloudflare прислал незнакомый ключ сервера — нужна новая версия панели"
    printf '%s' "$_wv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || fail "Cloudflare не прислал адрес — нужна новая версия панели"
    printf '%s' "$_wep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || fail "Cloudflare не прислал адрес сервера — нужна новая версия панели"
}
# Give a registration back ($1 id, $2 token): the throwaway one of a probe, the old one after `reget`. The call is the Android
# client's «delete», measured on hardware 11.10.2026: 204, after it the registration answers 404 to its own token (a repeat — 404,
# a wrong token — 401). BEST EFFORT all the same — a refusal or silence changes nothing: an unused registration just stays there.
# THE TOKEN goes to curl in a private file (`-K`: a header line of its config), not in its arguments — any process on the router
# reads another's argv (/proc/<pid>/cmdline), for up to the 15 s the call may last.
reg_del() {
    [ -n "$1" ] && [ -n "$2" ] && [ "$1" != - ] && [ "$2" != - ] || return 0
    _wdh=$(umask 077; mktemp /tmp/enodia-warp-del.XXXXXX 2>/dev/null) || return 0
    printf 'header = "Authorization: Bearer %s"\n' "$2" > "$_wdh"
    _wca=$(curl_ca_opt "$API/reg/$1")
    # shellcheck disable=SC2086
    curl -s $_wca -K "$_wdh" -o /dev/null --connect-timeout 8 --max-time 15 -X DELETE \
        -H "User-Agent: $UA" -H "CF-Client-Version: $CV" "$API/reg/$1" >/dev/null 2>&1
    rm -f "$_wdh"
    return 0
}
# The port BY THE RESULT → _wport _wcolo _wcut (the ports that did not pass, by commas). $1 — the port to ask first (the config's
# own, at a re-pick), $2 — «only this one» (a masking is tried on the port the config already has). `$MK <port>` prints the
# candidate config.
pick() {
    _wport=""; _wcolo=""; _wcut=""
    _wpl=$1; [ -n "$2" ] || for _wp in $PORTS; do [ "$_wp" = "$1" ] || _wpl="$_wpl $_wp"; done
    _wn=0; _wall=0
    for _wp in $_wpl; do _wall=$((_wall+1)); done
    for _wp in $_wpl; do
        _wn=$((_wn+1))
        if [ -n "$2" ]; then say "спрашиваю WARP с этой маскировкой (порт $_wp)"; else say "ищу порт, который провайдер не режет: $_wp ($_wn из $_wall)"; fi
        $MK "$_wp" > "$W/conf" || fail "не удалось записать конфиг"
        _wtr=$(sh "$ENODIA_DIR/transport-awg.sh" try "$W/conf" "$TRACE" "$TRY_SECS" 2>/dev/null); _wrc=$?
        case "$_wrc" in
            0) if printf '%s\n' "$_wtr" | grep -qx 'warp=on'; then
                   _wport=$_wp; _wcolo=$(printf '%s\n' "$_wtr" | sed -n 's/^colo=\([A-Z][A-Z][A-Z]\)$/\1/p' | head -n 1); break
               fi ;;
            4) _wsoon=1; fail "не поднялся пробный интерфейс AmneziaWG — проверьте его в «Компонентах»" ;;
            5) _wsoon=1; fail "сейчас идёт другая проба конфига — повторите через минуту" ;;
        esac
        _wcut="$_wcut${_wcut:+,}$_wp"
    done
}
# The first free name: WARP, WARP-2 … WARP-9 (an exit takes the same one). On a filesystem without letter case `warp.conf` is
# the same file — `ls | grep -i`, not `-e`.
# A NAME IS TAKEN BY A FILE — OR BY WHOEVER STILL NAMES IT WITHOUT ONE (`name_held`): an exit whose config was deleted from under
# it (the registry keeps the name, `del_server` lets a config without riders go), the main channel's server and its «home». A
# fresh WARP.conf under such a name is «held» the moment it is written — the exit's line then reads the NEW key, and `slots.sh
# add` refused «ключ занят» AFTER the config, its record and its registration existed; every next click left one more (review
# s.123, round 3 — the same «refusal after the config is written» get_room was made against).
# THE READER TAKES THE WHOLE INPUT (`>/dev/null`, not `-q`): under uhttpd's CGI SIGPIPE is IGNORED, so a reader that leaves at the
# first match does not kill the writers — they fail with EPIPE and SAY so. «tr: short write», «sh: write error: Broken pipe» stood
# in the toast of a refusal, in front of its words (hardware walk 12.10.2026; in a stand's world the writer just dies in silence).
name_held() {   # $1 = a config name → 0 when somebody names it
    { [ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" configs awg 2>/dev/null
      head -n 1 "$ENODIA_STATE/.active" 2>/dev/null; echo
      head -n 1 "$ENODIA_STATE/.failover-home" 2>/dev/null; echo
    } | tr -d '\r' | grep -Fxi "$1" >/dev/null
}
next_name() {
    for _wnn in "" 2 3 4 5 6 7 8 9; do
        _wcand="$NAME${_wnn:+-$_wnn}"
        ls -1 "$ENODIA_STATE/configs" 2>/dev/null | grep -Fxi "$_wcand.conf" >/dev/null && continue
        name_held "$_wcand" && continue
        printf '%s' "$_wcand"; return 0
    done
    return 1
}
# The config to work on ($1) → _wsrc, _wnm, _wcur (its port), _wold (its record), _wopub. A refusal — code 1 and its words in _wtm:
# the front verb prints them, the background work puts them into the status.
target() {
    _wnm=""
    printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.-]+$' || { _wtm="недопустимое имя конфига"; return 1; }
    _wnm=$1
    [ -f "$ENODIA_STATE/configs/$1.conf" ] || { _wtm="нет конфига «$1»"; return 1; }
    is_warp "$1" || { _wtm="конфиг «$1» — не WARP"; return 1; }
    # The config of the MAIN channel: its carrier is not an exit, and rewriting the text under it would leave the tunnel on the old
    # one until the next switch — a refusal in words instead (WARP does not change the country: as the main server it is rare).
    # Held by the main channel whatever carries NOW: with another transport in front the config is still the AmneziaWG server —
    # its working copies and a warm awg0 keep the old text, and after a re-get the next return to AmneziaWG would sit on a
    # registration that was given back (review s.121). The same answer road.sh and the key registry give.
    if [ "$(cat "$ENODIA_STATE/.active" 2>/dev/null | tr -d ' \r\n')" = "$1" ]; then
        _wtm="«$1» выбран сервером AmneziaWG для основного канала — сперва выберите там другой"; return 1
    fi
    _wsrc="$ENODIA_STATE/configs/$1.conf"; _wcur=$(cfg_port "$_wsrc"); _wopub=$(cfg_pub "$_wsrc"); _wold=$(reg_line "$_wopub")
    [ -n "$_wcur" ] || { _wtm="в конфиге «$1» нет порта сервера"; return 1; }
    return 0
}
# Write the text of $W/new over the config $_wnm (600, next to it + mv)… A config DELETED while the work ran (a probe lasts up to
# a minute and a half) is not written: the write used to bring it back, under a fresh registration (review s.122).
still_there() { [ -f "$_wsrc" ] || fail "конфиг «$_wnm» удалён, пока шла работа — ничего не записано"; }
conf_write() {
    still_there
    ( umask 077; cp "$W/new" "$_wsrc.$$" ) && mv "$_wsrc.$$" "$_wsrc" || { rm -f "$_wsrc.$$"; fail "не удалось записать конфиг (место на разделе?)"; }
}
# The config's new text ("$@" — conf_as's arguments) → $W/new, WHOLE OR NOT AT ALL: built in memory, committed by lbl_commit (the
# file is compared with the text). `conf_as … > "$W/new" || fail` could not fail on the router — its awk exits 0 on a failed
# write (see reg_commit) — and with /tmp full a cut text was then copied over the config: the key gone (review s.123, round 4).
conf_new() {
    _wcnt=$(conf_as "$@") && [ -n "$_wcnt" ] && ( umask 077; lbl_commit "$W/new" "$_wcnt" ) || fail "не удалось записать конфиг"
}
# …then its record ("$@" — reg_put's arguments), then its exits are restarted. THE RECORD AFTER THE CONFIG: written first, it
# said what the config did not hold when the write failed — «ваша» over the router's masking, and a failed «вернуть собранную
# роутером» turned the person's masking into `gen`, which the next «Получить заново» then replaced (review s.122).
conf_save() {
    conf_write
    reg_put "$@"
    say "перезапускаю выход"
    reup_exits "$_wnm"
}
# The work directory holds the private key and Cloudflare's answer with the token. One job at a time ⇒ any OTHER work directory
# (and a masking copy whose job never started) is a killed job's leftover: nobody else would ever remove it.
work_dir() {
    W=/tmp/enodia-warp.work.$$
    rm -rf /tmp/enodia-warp.work.* /tmp/enodia-warp-mask.* /tmp/enodia-warp-del.* "$HOLDF" 2>/dev/null
    ( umask 077; mkdir "$W" ) || fail "нет места для работы"
    trap 'rm -rf "$W" "$PIDF"' EXIT
    trap 'exit 1' INT TERM HUP PIPE
}

# ---- the verbs -----------------------------------------------------------------------------------------------------------------
# IS A WARP JOB RUNNING — two witnesses: the job's own pidfile (start-stop-daemon's child writes it) and the START mark, the pid
# of the front verb that is launching one right now (without it a status asked between «начинаю» and the pidfile saw «running»
# with no live job). A pid counts only with OUR script in its argv: a pidfile left by a kill names a stranger once the number is
# reused, and every verb then answered «уже идёт» for as long as that stranger lived.
job_alive() { _wjp=$(cat "$1" 2>/dev/null | tr -cd '0-9'); [ -n "$_wjp" ] && pid_runs "$_wjp" 'warp\.sh'; }
busy() { job_alive "$PIDF" || job_alive "$STARTF"; }
# Take the start: ONE front verb at a time. «Is a job alive or starting» and «the start is mine» are ONE step under a lock (the
# project's lock directory — mkdir is atomic, a dead holder's is taken over by /proc): the check, then `rm -f` of a «dead» mark,
# then a noclobber create let two verbs a few milliseconds apart each remove the other's fresh mark — both passed, two jobs ran,
# and each tab polled the other's (15 rounds of 40 in the reviewer's sandbox, review s.122). A dead verb's mark is no obstacle.
# Code 1 — a job runs or starts; the front verb says so and returns 1: the panel must not take that job for its own.
take_start() {
    lbl_lock_take "$STARTL" 'warp\.sh' || return 1
    if busy; then lbl_lock_drop "$STARTL"; return 1; fi
    rm -f "$STARTF" "$PIDF"
    # noclobber: the name lives in the shared /tmp — a symlink planted on it must not turn our write into a write into its target
    ( set -C; echo $$ > "$STARTF" ) 2>/dev/null || { lbl_lock_drop "$STARTL"; return 1; }
    lbl_lock_drop "$STARTL"
    trap 'rm -f "$STARTF"' EXIT
    trap 'exit 1' INT TERM HUP PIPE
    return 0
}
BUSY_MSG="[warp] другая работа с WARP уже идёт — дождитесь её"
# Start the foreground verb $1 with its arguments in the background; $OP and $_wnm name the work in the first status line. The
# start mark is held until the job's own pidfile names it: `-b` forks twice and the child writes the pidfile later.
start() {
    say "начинаю"
    if [ -x /sbin/start-stop-daemon ]; then
        start-stop-daemon -S -b -m -p "$PIDF" -x /bin/sh -- "$ENODIA_DIR/warp.sh" "$@" >/dev/null 2>&1
    else ( sh "$ENODIA_DIR/warp.sh" "$@" >/dev/null 2>&1 & echo $! > "$PIDF" ); fi
    # fixed-wait: not a daemon's start — the pidfile written by start-stop-daemon's child; a job that has already ended is not waited for longer.
    _wsw=0
    while ! job_alive "$PIDF" && [ "$_wsw" -lt 20 ]; do
        if command -v usleep >/dev/null 2>&1; then usleep 100000; else sleep 1; _wsw=$((_wsw+9)); fi
        _wsw=$((_wsw+1))
    done
}
need_awg() { [ -x "$ENODIA_BIN/awg" ] || { echo "[warp] нет AmneziaWG — поставьте его в «Компонентах»"; return 1; }; }

# WHAT `get` NEEDS BESIDES CLOUDFLARE — asked before anything is registered or saved (the words → _wtm): a free exit, and a rider
# that may ride at all. The refusal used to come AFTER the config was written: «выход не создался» left WARP.conf, its record and
# its registration behind, and the next click made WARP-2 with one more registration — up to WARP-9 (review s.122). The owners
# answer (slots.sh free, road.sh serves), read by the FORM of the answer: anything else than a refusal in words lets the work go on.
get_room() {   # $1 = rider (optional)
    _wgr=$(sh "$ENODIA_DIR/slots.sh" free 2>/dev/null | tail -n 1)
    case "$_wgr" in '[slots] '*) _wtm=${_wgr#\[slots\] }; return 1 ;; esac
    if [ -n "$1" ] && [ -f "$ENODIA_DIR/road.sh" ]; then
        _wgr=$(sh "$ENODIA_DIR/road.sh" serves awg "$1" 2>/dev/null | tr -cd '2-7' | cut -c1)
        [ -z "$_wgr" ] || { _wtm="«$1» сам служит дорогой (выход №$_wgr) — дорога бывает только в один шаг"; return 1; }
    fi
    return 0
}
cmd_get() {
    if [ -n "$1" ]; then printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.-]+$' && [ -f "$ENODIA_STATE/configs/$1.conf" ] \
        || { echo "[warp] нет конфига «$1»"; return 1; }; fi
    _wnm=$(next_name) || { echo "[warp] имена WARP … WARP-9 заняты — удалите ненужный конфиг"; return 1; }
    need_awg || return 1
    get_room "$1" || { echo "[warp] $_wtm"; return 1; }
    take_start || { echo "$BUSY_MSG"; return 1; }
    start run "$1"
    echo "[warp] получаю WARP — обычно до 30 секунд"
}
cmd_run() {   # $1 = rider (optional)
    _wnm=$(next_name) || fail "имена WARP … WARP-9 заняты — удалите ненужный конфиг"
    get_room "$1" || fail "$_wtm"
    work_dir
    reg_new
    MK=wconf; pick ""
    [ -n "$_wport" ] || fail "Cloudflare выдал WARP, но провайдер режет его на всех портах ($(echo $PORTS | sed 's/ /, /g')) — конфиг не сохранён"
    say "сохраняю конфиг (порт $_wport)"
    mkdir -p "$ENODIA_STATE/configs" || fail "нет каталога конфигов"
    _wtmp="$ENODIA_STATE/configs/$_wnm.conf.$$"
    ( umask 077; cp "$W/conf" "$_wtmp" ) || { rm -f "$_wtmp"; fail "не удалось записать конфиг (место на разделе?)"; }
    # THE NAME IS TAKEN AT THE WRITE, NO-CLOBBER (`set -C`, as the upload CGI takes its names). It was picked before the probe,
    # which lasts up to a minute and a half: a config that appeared under it meanwhile (an upload, a rename, a backup's import in
    # another tab) was REPLACED by this one — its key gone, the status «done» (review s.123, round 4). Taken ⇒ the next free name;
    # a file the partition refuses to create is not «taken» (the same name would be offered for ever).
    _wtk=0; _wtn=0
    while [ "$_wtn" -lt 10 ]; do
        _wtn=$((_wtn+1))
        ( set -C; umask 077; : > "$ENODIA_STATE/configs/$_wnm.conf" ) 2>/dev/null && { _wtk=1; break; }
        [ -e "$ENODIA_STATE/configs/$_wnm.conf" ] || break
        _wnm=$(next_name) || { _wtk=2; break; }
    done
    case "$_wtk" in
        1) ;;
        2) rm -f "$_wtmp"; fail "имена WARP … WARP-9 заняты — удалите ненужный конфиг" ;;
        *) rm -f "$_wtmp"; fail "не удалось записать конфиг (место на разделе?)" ;;
    esac
    mv "$_wtmp" "$ENODIA_STATE/configs/$_wnm.conf" || { rm -f "$_wtmp" "$ENODIA_STATE/configs/$_wnm.conf"; fail "не удалось записать конфиг (место на разделе?)"; }
    owned
    reg_put "$_wpub" 1 "$_wrid" "$_wtok" "$(now_s)" "$_wport" "$_wcut" "$_wcolo" gen "$(now_s)"
    say "создаю выход"
    _wso=$(sh "$ENODIA_DIR/slots.sh" add "$_wnm" awg "$_wnm" main 2>&1)
    _wid=$(printf '%s\n' "$_wso" | sed -n 's/.*выход №\([2-7]\) .*создан.*/\1/p' | tail -n 1)
    # The tail is ANOTHER owner's refusal, WHOLE (slots.sh's «тот же ключ» is 363 bytes, road.sh's «тот же сервер» 213): cut
    # at 160 it arrived broken mid-word and matched no translation rule of the panel (review s.123, round 4).
    [ -n "$_wid" ] || fail "конфиг «$_wnm» сохранён, а выход не создался: $(printf '%s' "$_wso" | tail -n 1 | sed 's/^\[slots\] //' | tr -d '"\\' | jtxt 600)"
    if [ -n "$1" ]; then
        say "прокладываю дорогу для $1"
        _wro=$(sh "$ENODIA_DIR/road.sh" set awg "$1" "$_wid" 2>&1) \
            || fail "WARP получен (выход №$_wid), а дорога не встала: $(printf '%s' "$_wro" | tail -n 1 | sed 's/^\[road\] //' | tr -d '"\\' | jtxt 600)"
    fi
    put "{\"state\":\"done\",\"op\":\"get\",\"name\":\"$_wnm\",\"exit\":\"$_wid\",\"rider\":\"$1\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"WARP получен: выход №$_wid${1:+, $1 едет через него}\"}"
    exit 0
}

# «Подобрать порт заново»: the ISP started cutting the port the config has. Asked under a throwaway registration (see the header),
# the config's own port FIRST: it still carries ⇒ the config and its exit are not touched.
cmd_repick() { target "$1" || { echo "[warp] $_wtm"; return 1; }; need_awg || return 1
    take_start || { echo "$BUSY_MSG"; return 1; }
    OP=repick
    if [ "$2" = own ]; then start run-repick-own "$1"; else start run-repick "$1"; fi
    echo "[warp] подбираю порт — до двух минут"; }
# THE PICK WITH THE CONFIG'S OWN KEY — for an exit that SHAKES HANDS AND CARRIES NOTHING (the watchdog's call, `repick <cfg>
# own`). WHY (BE7000, 12.10.2026, the walk of 1.2.0-dev.8): the throwaway registration needs Cloudflare's API, and from an ISP
# that filters WARP the API answers only THROUGH A TUNNEL (through awg0/awg4 — 0.3 s, through WAN — a timeout). A silent WARP
# road is exactly when there is none: the main tunnel rides that road and stands in FAILOPEN — the job answered «Cloudflare не
# ответил», and the exit stayed silent for the six hours till the next attempt. The reason for the throwaway — «the live exit
# is not touched», one session per key — does not hold for an exit that carries nothing: its carrier goes DOWN for the pick
# (one session per key is kept — the probe's interface is then the only one on the key), the ports are asked by the config's
# own text, a port that passes is written, and the exit is raised again WHATEVER the pick said (_wodn, the EXIT trap: a
# refusal or a kill in the middle must not leave it down). The panel's button stays on the throwaway: there the exit may well
# be carrying, and the person did not ask to stop it.
# While the job runs the watchdog must keep its hands off the exits of this config (their carriers are gone on purpose, and
# its return probe would raise a second session on the key) — it asks `running`.
# …AND SO MUST EVERYBODY ELSE WHO RAISES AN EXIT (review s.128): saving a group or a geo rule, the watchdog's rule repair,
# «Включить VPN», a component's restart, the panel's own verbs — each ends in `slot-up`, and an exit raised on the old port in the
# middle of the pick takes the server's session from the probe: a port that passes then reads «cut». The pick says what it holds
# (HOLDF, from before the exits go down till right before they come back), and the ONE place every raise goes through — the
# plugin's slot-up and slot-probe — asks `holds` and refuses. A hold is a LIVE job's: a killed one holds nothing.
# THE EXITS COME BACK BY ONE RAISE (own_back): they are down already, and the registry's «set the config» (reup_exits) would take
# them down once more — each of those ends in a flush of the whole home's connections. A pick that found nothing must cost what
# it has to: the exit down, the exit up.
own_back() {
    [ "$_wodn" = 1 ] || return 0
    _wodn=0; rm -f "$HOLDF"; _wrf=""
    [ ! -f "$ENODIA_STATE/.vpn-off" ] || return 0      # the VPN was switched off meanwhile: nothing is raised, as it should be
    for _wx in $(exits_of "$_wnm"); do
        sh "$ENODIA_DIR/transport.sh" slot-up "$_wx" >/dev/null 2>&1 || _wrf="$_wrf${_wrf:+, }№$_wx"
    done
}
cmd_run_repick_own() {
    OP=repick; target "$1" || fail "$_wtm"
    work_dir
    _wodn=1
    trap 'own_back; rm -rf "$W" "$PIDF"' EXIT
    say "снимаю выход на время подбора — он всё равно не везёт"
    ( umask 077; set -C; printf '%s\n' "$_wnm" > "$HOLDF" ) 2>/dev/null   # noclobber: the name lives in the shared /tmp
    for _wx in $(exits_of "$_wnm"); do sh "$ENODIA_DIR/transport.sh" slot-down "$_wx" >/dev/null 2>&1; done
    MK=oconf; pick "$_wcur"
    # nothing passes: the exits first (who did not come up is named in the refusal), then the refusal
    [ -n "$_wport" ] || { own_back; fail "провайдер режет WARP на всех портах ($(echo "$_wcut" | sed 's/,/, /g')) — конфиг не изменён$(reup_note)"; }
    _wo=$(printf '%s' "$_wold" | cut -f2); _wi=$(printf '%s' "$_wold" | cut -f9)
    set -- "$_wopub" "${_wo:-0}" "$(printf '%s' "$_wold" | cut -f3)" "$(printf '%s' "$_wold" | cut -f4)" "$(printf '%s' "$_wold" | cut -f5)" \
        "$_wport" "$_wcut" "$_wcolo" "${_wi:--}" "$(now_s)"
    if [ "$_wport" = "$_wcur" ]; then
        still_there
        reg_put "$@"
        own_back
        put "{\"state\":\"done\",\"op\":\"repick\",\"name\":\"$_wnm\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"порт $_wport по-прежнему проходит — конфиг «$_wnm» не менялся$(reup_note)\"}"; exit 0
    fi
    conf_new "$_wsrc" "" "" "$_wport" ""
    conf_write
    reg_put "$@"
    say "перезапускаю выход"
    # AN EXIT THAT IS UP RIGHT NOW (raised a moment before the hold stood; the hold could not be written; an exit moved to this
    # config meanwhile) would go through the plugin's WARM path in own_back — and keep the OLD port under a config and a status
    # that say the new one, till the next pick. Down first; an exit that is down as it should be costs nothing here.
    for _wx in $(exits_of "$_wnm"); do
        _wxi=$(sh "$ENODIA_DIR/transport.sh" slot-iface "$_wx" 2>/dev/null | head -n 1 | tr -d ' \t\r')
        [ -n "$_wxi" ] && [ -e "/sys/class/net/$_wxi" ] && sh "$ENODIA_DIR/transport.sh" slot-down "$_wx" >/dev/null 2>&1
    done
    own_back         # by the new text; a refusal above (the config deleted, no room for it) brings them back by the old one — the trap
    put "{\"state\":\"done\",\"op\":\"repick\",\"name\":\"$_wnm\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"«$_wnm»: порт $_wcur провайдер режет — теперь $_wport$(reup_note)\"}"
    exit 0
}
# Does an own-key pick keep the exits of config $1 down right now → 0. The answer of a LIVE job only: the name it wrote and its
# own pid alive — a job killed in the middle left the name behind and holds nothing (the watchdog's return probe takes over).
cmd_holds() {
    [ -n "$1" ] && [ -f "$HOLDF" ] || return 1
    [ "$(head -n 1 "$HOLDF" 2>/dev/null | tr -d '\r\n')" = "$1" ] || return 1
    job_alive "$PIDF"
}
# The config a job is working on right now (its name, code 0) — or nothing, code 1. The watchdog asks it once per sweep, before
# it judges that config's exits.
cmd_running() {
    busy || return 1
    _wrn=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$ST" 2>/dev/null | head -n 1)
    [ -n "$_wrn" ] || return 1
    printf '%s\n' "$_wrn"
}
cmd_run_repick() {
    OP=repick; target "$1" || fail "$_wtm"
    work_dir
    reg_new; _wi1=""
    MK=xconf; pick "$_wcur"
    give_back
    [ -n "$_wport" ] || fail "провайдер режет WARP на всех портах ($(echo "$_wcut" | sed 's/,/, /g')) — конфиг не изменён"
    _wo=$(printf '%s' "$_wold" | cut -f2); _wi=$(printf '%s' "$_wold" | cut -f9)
    # the record's new line (what this pick saw); written at once when the config does not change, after the config when it does
    set -- "$_wopub" "${_wo:-0}" "$(printf '%s' "$_wold" | cut -f3)" "$(printf '%s' "$_wold" | cut -f4)" "$(printf '%s' "$_wold" | cut -f5)" \
        "$_wport" "$_wcut" "$_wcolo" "${_wi:--}" "$(now_s)"
    if [ "$_wport" = "$_wcur" ]; then
        # …the record only: of a config that is STILL THERE. Deleted (and pruned) during the probe, it got its record back —
        # id and token for a key no config held — and the last word spoke of a deleted config (review s.123, round 4).
        still_there
        reg_put "$@"
        put "{\"state\":\"done\",\"op\":\"repick\",\"name\":\"$_wnm\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"порт $_wport по-прежнему проходит — конфиг «$_wnm» не менялся\"}"; exit 0
    fi
    conf_new "$_wsrc" "" "" "$_wport" ""
    conf_save "$@"
    put "{\"state\":\"done\",\"op\":\"repick\",\"name\":\"$_wnm\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"«$_wnm»: порт $_wcur провайдер режет — теперь $_wport$(reup_note)\"}"
    exit 0
}

# «Получить заново»: a new registration into the SAME config — the key was shared by mistake, the config came from a bot, Cloudflare
# dropped the registration. The exit on it and the roads through it stay. The text is the router's own (key, address, server and
# port of the new registration, its measured Jc/S/H) with ONE thing kept from the old one: a masking the router did not build —
# the record says `custom`, or there is no record and the config came with an I1 (an uploaded config: «no record» is not «the
# router's masking»). The old registration is given back — unless another config still holds its key.
cmd_reget() { target "$1" || { echo "[warp] $_wtm"; return 1; }; need_awg || return 1
    take_start || { echo "$BUSY_MSG"; return 1; }
    OP=reget; start run-reget "$1"; echo "[warp] получаю WARP заново — обычно до 30 секунд"; }
cmd_run_reget() {
    OP=reget; target "$1" || fail "$_wtm"
    work_dir
    _wkind=gen; _wkeep=""
    if [ "$(printf '%s' "$_wold" | cut -f9)" != gen ]; then
        _wkeep=$(cfg_val "$_wsrc" I1 | mask_norm)
        # …but the router's OWN packet is the router's whatever the record says: a config got before the record existed has none,
        # and its I1 came out of gen_i1 — kept as «the person's», the card then called it «ваша» (review s.122).
        if [ "$_wkeep" != "$(gen_i1)" ] && printf '%s' "$_wkeep" | grep -Eq "$MASK_RE"; then _wkind=custom; else _wkeep=""; fi
    fi
    reg_new; _wi1=$_wkeep
    MK=wconf; pick "$_wcur"
    [ -n "$_wport" ] || fail "Cloudflare выдал WARP, но провайдер режет его на всех портах ($(echo "$_wcut" | sed 's/,/, /g')) — конфиг «$_wnm» не изменён"
    say "сохраняю конфиг (порт $_wport)"
    cp "$W/conf" "$W/new" || fail "не удалось записать конфиг"
    # The order is the promise «never a config on a registration that was given back»: the new text is WRITTEN (a failed write —
    # `fail` returns the new registration, the old one is untouched), only then the registration is the config's, and only after
    # that the old one goes.
    conf_write
    owned
    reg_put "$_wpub" 1 "$_wrid" "$_wtok" "$(now_s)" "$_wport" "$_wcut" "$_wcolo" "$_wkind" "$(now_s)"
    say "перезапускаю выход"
    reup_exits "$_wnm"
    # The old key is gone from THIS config — its record and its registration go too, unless another config still runs on that key
    # (the same file uploaded twice, a copy from a backup): its exit would die with the registration. Keys that could not be read
    # — nothing is given back.
    if [ "$_wopub" != "$_wpub" ]; then
        if _wks=$(warp_keys) && ! printf '%s\n' "$_wks" | grep -Fxq "$_wopub"; then
            reg_drop "$_wopub"
            reg_del "$(printf '%s' "$_wold" | cut -f3)" "$(printf '%s' "$_wold" | cut -f4)"
        fi
    fi
    put "{\"state\":\"done\",\"op\":\"reget\",\"name\":\"$_wnm\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"«$_wnm» получен заново: ключ новый, порт $_wport$(reup_note)\"}"
    exit 0
}

# The masking: the router's own (`gen` — also «add one» to a config that came without) or the person's text. The text is tags only
# (`<b 0x…>` bytes, `<r N>` / `<rc N>` / `<rd N>` random, `<c>` counter, `<t>` time — AmneziaWG's own set): anything else in that
# line would make `awg setconf` refuse the WHOLE config, and the exit would come up empty. And tags that are fine by form may still
# not pass the ISP — so the candidate is ASKED first (the config's port, a throwaway registration) and written only on an answer.
MASK_RE='^(<(b 0x[0-9a-fA-F]+|r [0-9]+|rc [0-9]+|rd [0-9]+|c|t)>)+$'
# The person's text as it is pasted → the line AmneziaWG reads: line breaks out, and the blanks BETWEEN tags and around the text
# (a masking copied from a guide comes wrapped, or with a space after each tag). The blank INSIDE a tag (`<r 16>`) is the tag's
# own. ONE owner: the panel sends what was typed — it used to turn a line break into a space, and the router refused its text.
mask_norm() { tr -d '\r\n' | sed 's/>[[:space:]]*</></g; s/^[[:space:]]*//; s/[[:space:]]*$//'; }
cmd_mask() { target "$1" || { echo "[warp] $_wtm"; return 1; }; need_awg || return 1
    _wmt=""
    if [ "$2" != gen ]; then
        [ -f "$2" ] || { echo "[warp] нет текста маскировки"; return 1; }
        _wmt=$(mask_norm < "$2")
        [ "${#_wmt}" -le 8000 ] && printf '%s' "$_wmt" | grep -Eq "$MASK_RE" \
            || { echo "[warp] маскировка — только теги <b 0x…>, <r N>, <rc N>, <rd N>, <c>, <t> подряд, до 8000 знаков"; return 1; }
    fi
    take_start || { echo "$BUSY_MSG"; return 1; }
    if [ "$2" != gen ]; then
        # The text outlives the request's own directory: a private copy for the background work, which removes it. Made only
        # AFTER the start is taken — a job's work_dir sweeps every copy it finds as a dead job's.
        _wmf=$(mktemp /tmp/enodia-warp-mask.XXXXXX 2>/dev/null) || { echo "[warp] нет места для работы"; return 1; }
        printf '%s' "$_wmt" > "$_wmf"; set -- "$1" "$_wmf"
    fi
    OP=mask; start run-mask "$1" "$2"; echo "[warp] проверяю маскировку — до 20 секунд"; }
cmd_run_mask() {
    OP=mask
    _wkind=gen; _wi1=$(gen_i1)
    if [ "$2" != gen ]; then
        _wkind=custom; _wi1=$(mask_norm < "$2" 2>/dev/null)
        case "$2" in /tmp/enodia-warp-mask.*) rm -f "$2" ;; esac   # cmd_mask's private copy — and nothing else
    fi
    target "$1" || fail "$_wtm"
    printf '%s' "$_wi1" | grep -Eq "$MASK_RE" || fail "маскировка — только теги <b 0x…>, <r N>, <rc N>, <rd N>, <c>, <t> подряд"
    work_dir
    reg_new
    MK=xconf; pick "$_wcur" only
    give_back
    [ -n "$_wport" ] || fail "с этой маскировкой WARP не ответил (порт $_wcur) — конфиг «$_wnm» не изменён"
    conf_new "$_wsrc" "" "" "" "$_wi1"
    _wo=$(printf '%s' "$_wold" | cut -f2)
    conf_save "$_wopub" "${_wo:-0}" "$(printf '%s' "$_wold" | cut -f3)" "$(printf '%s' "$_wold" | cut -f4)" "$(printf '%s' "$_wold" | cut -f5)" \
        "$_wport" "$(printf '%s' "$_wold" | cut -f7)" "$_wcolo" "$_wkind" "$(printf '%s' "$_wold" | cut -f10)"
    put "{\"state\":\"done\",\"op\":\"mask\",\"name\":\"$_wnm\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"«$_wnm»: маскировка $([ "$_wkind" = gen ] && echo 'собрана роутером' || echo 'ваша') — WARP с ней отвечает$(reup_note)\"}"
    exit 0
}

# A WARP for ANOTHER device: its own registration and key, the port picked from THIS network (the phone at home sits behind the
# same ISP). The text waits in RAM for the panel to take it once; the router keeps no record and no key of it — and does not keep
# the text for ever either: nobody took it in DEV_TTL seconds (the tab was closed before the work ended) — it is removed. The
# waiter is a detached child with nothing of the job's (stdio closed, the pidfile is the job's and goes with it), and it removes
# only the file it saw born: a newer config under the same name has another sum.
cmd_device() { need_awg || return 1
    take_start || { echo "$BUSY_MSG"; return 1; }
    _wnm=""; OP=device; rm -f "$DEVF"; start run-device; echo "[warp] получаю WARP для устройства — обычно до 30 секунд"; }
cmd_run_device() {
    OP=device; _wnm=""
    work_dir
    reg_new; _wi1=""
    MK=dconf; pick ""
    [ -n "$_wport" ] || fail "Cloudflare выдал WARP, но провайдер режет его на всех портах ($(echo $PORTS | sed 's/ /, /g')) — конфиг не собран"
    rm -f "$DEVF"
    _wdn=$(umask 077; mktemp "$DEVF.XXXXXX" 2>/dev/null) && cp "$W/conf" "$_wdn" && mv "$_wdn" "$DEVF" || { rm -f "$_wdn"; fail "не удалось собрать конфиг"; }
    owned
    _wds=$(md5sum < "$DEVF" 2>/dev/null)
    ( sleep "$DEV_TTL"; [ -f "$DEVF" ] && [ "$(md5sum < "$DEVF" 2>/dev/null)" = "$_wds" ] && rm -f "$DEVF" ) </dev/null >/dev/null 2>&1 &
    put "{\"state\":\"done\",\"op\":\"device\",\"name\":\"\",\"port\":\"$_wport\",\"colo\":\"$_wcolo\",\"msg\":\"WARP для устройства получен: порт $_wport\"}"
    exit 0
}
# `ep` — the address of Cloudflare's server in the config handed out, the router's own reading of it (`cfg_ep`): at home such a
# device's tunnel is marked into the router's tunnel like any packet to that address (every WARP address tried sits in the shared
# «в VPN» pool — dev notes §27.16), and the panel offers an ordinary «мимо VPN» rule for THIS address. An address only (a rule
# takes nothing else); a config whose server is not an IPv4 literal gives none, and the panel then offers nothing.
cmd_device_take() {
    [ -f "$DEVF" ] || { echo '{"ok":false,"msg":"конфиг уже забран или не получен — получите новый"}'; return 0; }
    _wdt=$(base64 < "$DEVF" 2>/dev/null | tr -d '\n'); _wde=$(cfg_ep "$DEVF"); rm -f "$DEVF"
    [ -n "$_wdt" ] || { echo '{"ok":false,"msg":"не удалось прочитать конфиг"}'; return 0; }
    printf '%s' "$_wde" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || _wde=""
    printf '{"ok":true,"conf_b64":"%s","ep":"%s"}\n' "$_wdt" "$_wde"
}
# The status AS THE PANEL READS IT — the stored line plus two facts only the owner knows:
#   * «running» with no live job is NOT running. A work that died without its last word (killed, out of memory, a signal — the
#     trap removes the pidfile and writes nothing; a launch that never happened) left «running» for ever, and the screen locks
#     every button on that word until a reboot. It is an error, said here. The line is read AGAIN after «no job»: a work that
#     ended between the two looks has already written its real last word;
#   * `dev` — a config for another device waits to be taken (the screen that was closed while it was being made offers it).
cmd_status() {
    _wss=$(cat "$ST" 2>/dev/null)
    case "$_wss" in
        '{"state":"running",'*)
            if ! busy; then
                _wss=$(cat "$ST" 2>/dev/null)
                case "$_wss" in '{"state":"running",'*)
                    _wss=$(printf '%s\n' "$_wss" | sed 's/^{"state":"running",/{"state":"error",/; s/"msg":"[^"]*"/"msg":"работа прервалась — запустите её снова","soon":true/') ;;
                esac
            fi ;;
    esac
    case "$_wss" in '{'*'}') ;; *) _wss='{"state":"none"}' ;; esac
    if [ -f "$DEVF" ]; then _wdv=true; else _wdv=false; fi
    printf '%s\n' "$_wss" | sed "s/^{/{\"dev\":$_wdv,/"
}

# One awk pass over every config: a [Peer] key equal to Cloudflare's makes it WARP; a non-empty I1 is the masking. Names as the
# panel knows them (the file name without .conf).
cmd_list() {
    set -- "$ENODIA_STATE"/configs/*.conf
    [ -f "$1" ] || return 0
    awk -v k="$WARP_PUB" '
        FNR == 1 { if (nm != "" && w) print nm "\t" i; nm = FILENAME; sub(/^.*\//, "", nm); sub(/\.conf$/, "", nm); w = 0; i = 0 }
        { sub(/\r$/, "") }
        /^[ \t]*PublicKey[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); if (v == k) w = 1 }
        /^[ \t]*I1[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); if (v ~ /[^ \t]/) i = 1 }
        END { if (nm != "" && w) print nm "\t" i }' "$@" 2>/dev/null | grep -E "^[A-Za-z0-9._-]+$(printf '\t')[01]\$"
}
# What is known about every WARP config: the address and port — from the CONFIG (the truth the daemon reads), the rest — from the
# record of its key; no record — a config that was uploaded (`own` 0, nothing else to say). `now` — the router's clock, for «when»
# (0 — the clock is not real: the panel then says no age). The token never leaves the router.
cmd_info() {
    printf '{"now":%s,"items":[' "$(now_s)"
    _wfirst=1
    cmd_list | while IFS="$TAB" read -r _wn _wm; do
        [ -n "$_wn" ] || continue
        _wf="$ENODIA_STATE/configs/$_wn.conf"; _wr=$(reg_line "$(cfg_pub "$_wf")")
        _wown=0; _wat=0; _wct=""; _wcl=""; _wik=""; _wpat=0
        if [ -n "$_wr" ]; then
            [ "$(printf '%s' "$_wr" | cut -f2)" = 1 ] && _wown=1
            # Numbers go into JSON bare: a leading zero (a hand edit) is cut here, or the whole answer is not JSON.
            _wat=$(printf '%s' "$_wr" | cut -f5 | tr -cd '0-9' | sed 's/^0*//'); _wpat=$(printf '%s' "$_wr" | cut -f10 | tr -cd '0-9' | sed 's/^0*//')
            _wct=$(printf '%s' "$_wr" | cut -f7 | tr -cd '0-9,'); _wcl=$(printf '%s' "$_wr" | cut -f8 | tr -cd 'A-Z')
            _wik=$(printf '%s' "$_wr" | cut -f9 | tr -cd 'a-z')
        fi
        # The masking as it IS: none in the config — «none», whatever the record remembers.
        [ "$_wm" = 1 ] || _wik=none
        case "$_wik" in gen|custom|none) ;; *) _wik=other ;; esac
        [ "$_wfirst" = 1 ] || printf ','
        _wfirst=0
        printf '{"name":"%s","own":%s,"at":%s,"pat":%s,"ep":"%s","port":"%s","cut":"%s","colo":"%s","i1":"%s"}' \
            "$_wn" "$([ "$_wown" = 1 ] && echo true || echo false)" "${_wat:-0}" "${_wpat:-0}" \
            "$(cfg_ep "$_wf" | tr -cd 'A-Za-z0-9.:-')" "$(cfg_port "$_wf" | tr -cd '0-9')" "$_wct" "$_wcl" "$_wik"
    done
    printf ']}\n'
}
# Cloudflare's point for an exit: the trace through ITS interface (the name — from the orchestrator, the only owner of «id → iface»).
# The answer is Cloudflare's text; anything else — «нет данных» with a reason, never a guessed point.
cmd_colo() {
    case "$1" in [2-7]) ;; *) echo '{"colo":"","why":"битый номер выхода"}'; return 0 ;; esac
    _wif=$(sh "$ENODIA_DIR/transport.sh" slot-iface "$1" 2>/dev/null | tr -cd 'a-z0-9')
    [ -n "$_wif" ] && [ -d "/sys/class/net/$_wif" ] || { echo '{"colo":"","why":"выход не поднят"}'; return 0; }
    _wca=$(curl_ca_opt "$TRACE" --interface "$_wif")
    # shellcheck disable=SC2086
    _wtr=$(curl -s $_wca --interface "$_wif" --connect-timeout 5 --max-time "$TRY_SECS" "$TRACE" 2>/dev/null)
    _wcl=$(printf '%s\n' "$_wtr" | sed -n 's/^colo=\([A-Z][A-Z][A-Z]\)$/\1/p' | head -n 1)
    [ -n "$_wcl" ] || { echo '{"colo":"","why":"Cloudflare не ответил через выход"}'; return 0; }
    printf '{"colo":"%s","warp":%s}\n' "$_wcl" "$(printf '%s\n' "$_wtr" | grep -qx 'warp=on' && echo true || echo false)"
}

case "$1" in
    get)         cmd_get "$2" ;;
    repick)      cmd_repick "$2" "$3" ;;
    running)     cmd_running ;;
    holds)       cmd_holds "$2" ;;
    reget)       cmd_reget "$2" ;;
    mask)        cmd_mask "$2" "$3" ;;
    device)      cmd_device ;;
    device-take) cmd_device_take ;;
    status)      cmd_status ;;
    info)        cmd_info ;;
    prune)       cmd_prune "$2" ;;
    run-give)    cmd_run_give "$2" ;;
    import)      cmd_import "$2" ;;
    run)         cmd_run "$2" ;;
    run-repick)  cmd_run_repick "$2" ;;
    run-repick-own) cmd_run_repick_own "$2" ;;
    run-reget)   cmd_run_reget "$2" ;;
    run-mask)    cmd_run_mask "$2" "$3" ;;
    run-device)  cmd_run_device ;;
    i1)          gen_i1; echo ;;
    list)        cmd_list ;;
    colo)        cmd_colo "$2" ;;
    *)           echo "usage: $0 get [<конфиг>] | repick|reget <конфиг> | mask <конфиг> gen|<файл> | device | device-take | status | info | prune | import <файл> | i1 | list | colo <id>"; exit 2 ;;
esac
