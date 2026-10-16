#!/bin/sh
# premium.sh — «AMNEZIA PREMIUM»: the key of Amnezia's paid service (`vpn://` with an api_key inside and no server in it) as a
# source of servers. The router asks Amnezia's API itself, as the AmneziaVPN app does, and the configs it gets are ordinary ones:
# the main server, exits, the reserve and roads take them like any other. Research — dev notes «amnezia-premium-дизайн».
#
# A SUBSCRIPTION, NOT A NEW KIND OF THING (the user's decision 14.10.2026: the key is pasted where a subscription's link is). Its
# line is in the ONE registry `.subs` — the link field holds the key itself (a credential like any subscription's link; the
# registry is 600) — and its servers live in the subscription namespace: `sub-<tag>-<cc>-awg` (configs/) and `sub-<tag>-<cc>-vless`
# (xray-configs/). The list, «↳ подписка», the counts by family, «a server in use is kept» and the subscription's removal are the
# subscriptions' own machinery; the files are laid out by their owner (subs-update.sh put/unput, under its lock), what is
# Amnezia's is here. A COUNTRY IS PICKED BY THE PERSON (decision 14.10.2026), not taken all at once: whether Amnezia keeps 51 keys
# of one device alive is not measured. The picked set is the files themselves — no second registry to drift from them.
#
# THE ROUTER IS ONE DEVICE. Amnezia counts devices by `installation_uuid`: one installation held VLESS-DE and AWG-NL working at once
# and the count grew by one (measured 10.10.2026) ⇒ one uuid for the router ($INST_F), any number of countries under it.
# A CONFIG'S KEY DOES NOT EXPIRE IN PRACTICE: `public_key.expires_at` (+2 h) is the app's hint «take a fresh one at the next
# connect» — 161 probes of 161 passed 43 min after it, a fresh handshake too ⇒ no schedule. A new config (`refresh`) is the person's
# button and the watchdog's background step for a silent server (decisions 14.10.2026) — and it is taken ON STANDBY (wait_live):
# a fresh key carries only ~2 min after it is issued, and a pair Amnezia assigns may never carry it.
# WHO WE SAY WE ARE: the app's own words — AmneziaVPN $APP_VER, os `openwrt` (decision 14.10.2026; the device list shows the router
# as linux:openwrt). Amnezia may ask for a newer client (501 «update») — the refusal says so, a new Enodia moves APP_VER.
#
# THE WIRE (the app's GatewayController, client 5.0.3.0): the request JSON under AES-256-CBC with a random key (iv — the first 16 of
# 32 random bytes), that key under RSA-PKCS#1 with Amnezia's public key; the answer — ciphertext under the same key. The public key
# ships with the code BYTE FOR BYTE (`amnezia-gw.pem`): the gateway lists' AES key is SHA-512 of those exact bytes. Gateways ROTATE
# (Cloud Run names changed within six days) ⇒ they are never shipped: `gw.amnezia.org` first, then the lists on S3/GCS, as the app.
# Every deviation of the API is a refusal in words, never a half-written config. No `hexdump` on every busybox ⇒ random bytes are
# made as hex by openssl and turned into base64 by awk (hex_b64).
#
# Commands (the long ones start in the background; the panel polls `status`):
#   premium.sh check <key file>          — what the key is, without the network: {"ok":true,"svc":…,"name":…} | {"ok":false,"msg":…}
#   premium.sh account <tag>             — ask Amnezia about the subscription (date, devices, countries) → premium/<tag>.account
#   premium.sh pick <tag> <cc> <awg|vless> — get the country's config into the subscription's namespace
#   premium.sh unpick <tag> <cc> <awg|vless> — remove it (refused while it is in use: the active server, an exit, the reserve's home)
#   premium.sh refresh <config name> [auto] — a new config (a new key) for the same country and protocol, laid out once it
#                                          CARRIES (in use — brought into service then); the panel's button, and the watchdog's
#                                          kick (`auto`: a standby that never carried is not replaced before PM_NOCARRY_GAP)
#   premium.sh revoke <tag> <uuid>       — free a device's place in the subscription (a foreign device; the router's own — by `drop`)
#   premium.sh info <tag>                — JSON for the panel: what the last answer said + the countries picked here
#   premium.sh status                    — the job's JSON (state none|running|done|error, op, tag, msg; `job` — whoever started it)
#   premium.sh update <tag>              — subs-update.sh's step for this subscription (cron, «Обновить все»): `account`, foreground
#                                          (code 2 — another Amnezia work runs: skipped)
#   premium.sh busy                      — code 0 while a job runs
#   premium.sh is <config name>          — code 0: a server of an Amnezia Premium subscription (by the name — the namespace IS the record)
#   premium.sh drop <tag> <kept>         — the subscription is being removed (subs-update.sh drop, BEFORE its link is cleared):
#                                          its cache goes; nothing kept ⇒ the router's place is given back in the background
#   premium.sh run … | run-revoke-own …  — the work itself, in the foreground
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
APP_VER=5.0.3.0; CLI=AmneziaVPN; OS=openwrt          # the app's words (see the header)
PEM="$ENODIA_DIR/amnezia-gw.pem"                     # Amnezia's public key, byte for byte (C138 pins its sum)
GW_MAIN=http://gw.amnezia.org:80/                    # the app's first gateway (plain HTTP: the payload is encrypted anyway)
GW_LISTS="https://s3.eu-north-1.amazonaws.com/amnezia/ https://storage.googleapis.com/lambda-list/"
# THE STAND'S DOORS: a sandbox points the wire at its own gateway (dev/premium-test.sh). Nothing else reads these names.
[ -z "${ENODIA_PREMIUM_PEM:-}" ] || PEM=$ENODIA_PREMIUM_PEM
[ -z "${ENODIA_PREMIUM_GW:-}" ] || GW_MAIN=$ENODIA_PREMIUM_GW
[ -z "${ENODIA_PREMIUM_LISTS+x}" ] || GW_LISTS=$ENODIA_PREMIUM_LISTS
PDIR="$ENODIA_STATE/premium"
INST_F="$PDIR/.installation"                         # the router's installation_uuid — ONE for every key (see the header)
ST=/tmp/enodia-premium.json; PIDF=/tmp/enodia-premium.pid
STARTF=/tmp/enodia-premium.start                     # the pid of the front verb launching a job right now (busy)
STARTL=/tmp/enodia-premium-start.lock                # «is a job alive?» and «the start is mine» are ONE step under it
GWC=/tmp/enodia-premium-gw                           # this boot's gateway list: `<uptime>` then a URL per line
GWC_TTL=21600                                        # …trusted for six hours, then fetched again (they rotate)
CNT_MAX=80                                           # countries read from one answer (51 measured on a paid key)
PM_LIVE_MAX=${PM_LIVE_MAX:-240}                      # s: how long a new key may take to carry (~90–120 s measured) — see wait_live
PM_LIVE_STEP=${PM_LIVE_STEP:-15}                     # s between two probes of it
PM_TRACE=https://1.1.1.1/cdn-cgi/trace               # the probe's answer (warp.sh's: DNS-free, answers through any carrier)
PM_XT_PORT=10819                                     # the probe's temporary socks (xray-test.sh's range; the last — the panel starts low)
# THE STANDBY — a new key Amnezia issued that is NOT laid out yet (it did not carry within PM_LIVE_MAX, or the layout could not run):
# `.<name>` the config's text (600), `.<name>.at` «<uptime of the issue>⇥<display>». In RAM: a reboot forgets it, the next refresh
# asks anew. See run_pick.
NEXT=/tmp/enodia-premium-next
PM_NOCARRY_GAP=${PM_NOCARRY_GAP:-21600}              # s: the watchdog's kick asks for another key only after a standby this old never carried
PM_SETTLE_MAX=${PM_SETTLE_MAX:-600}                  # s: how long a laid-out key of the active server waits for a switch to end (settle)…
PM_SETTLE_HARD=${PM_SETTLE_HARD:-3600}               # s: …and how long while a switch or a watchdog tick is still running (a ladder: 26 min measured)
SWLOCK=/tmp/enodia-switching.lock                    # the switching lock (switch-vpn.sh, transport.sh, the watchdog's) — only looked at
SUBS_LOCK=/tmp/enodia-subs-update.lock               # the subscriptions' run lock (subs-update.sh take_lock: a directory, its pid inside)
PM_SUBS_WAIT=${PM_SUBS_WAIT:-90}                     # s: one wait for that lock before the layout (six of them at most)
DEV_MAX=32                                           # devices read from one answer (7 places measured)

if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi     # lbl_commit_out, lbl_lock_take
command -v lbl_commit_out_as >/dev/null 2>&1 || { lbl_commit_out_as() { _lct=$1; _lcf=$2; shift 2; "$@" > "$_lct" && mv -f "$_lct" "$_lcf" && return 0; rm -f "$_lct"; return 1; }; lbl_commit_out() { _lcf=$1; shift; lbl_commit_out_as "$_lcf.$$.new" "$_lcf" "$@"; }; lbl_grep() { grep "$@" || [ "$?" -le 1 ]; }; lbl_without() { if [ -f "$1" ]; then lbl_grep -v -- "$2" "$1" || return 1; fi; [ -z "${3:-}" ] || printf '%s\n' "$3"; }; }   # write-blind: the shim of a missing library is the old line
command -v lbl_lock_take >/dev/null 2>&1 || { lbl_lock_take() { mkdir "$1" 2>/dev/null; }; lbl_lock_drop() { rm -rf "$1" 2>/dev/null; }; }
command -v lbl_commit >/dev/null 2>&1 || lbl_commit() { if [ -z "$2" ]; then rm -f "$1"; return $?; fi; if printf '%s\n' "$2" > "$1.$$" 2>/dev/null && [ "$(cat "$1.$$" 2>/dev/null)" = "$2" ]; then mv "$1.$$" "$1" && return 0; fi; rm -f "$1.$$"; return 1; }
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
command -v iso_date_epoch >/dev/null 2>&1 || iso_date_epoch() { return 1; }
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi        # curl_ca_opt, doh_ips
command -v curl_ca_opt >/dev/null 2>&1 || curl_ca_opt() { return 0; }
command -v doh_ips >/dev/null 2>&1 || doh_ips() { return 1; }
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi      # jtxt: a byte cut that keeps UTF-8 whole
command -v jtxt >/dev/null 2>&1 || jtxt() { tr -d '"\000-\037\\'; }
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi  # pid_runs: alive AND ours
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
command -v carrier_busy >/dev/null 2>&1 || carrier_busy() { return 1; }   # a tick or a heal run drives the carrier
if [ -f "$ENODIA_DIR/subs-lib.sh" ]; then . "$ENODIA_DIR/subs-lib.sh"; fi      # the registry, sub_info_put, sub_fetch, wan_iface
command -v sub_url_of >/dev/null 2>&1 || { echo "[premium] нет subs-lib.sh — обновите скрипты роутера"; exit 1; }
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi        # nf_lang: the panel's language → the API's
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
TAB=$(printf '\t')

jf() { jsonfilter -i "$1" -e "$2" 2>/dev/null; }
# jline <limit> — the first line of stdin as the content of a JSON string (its line end is not a trailing space: jtxt keeps data's own).
jline() { head -n 1 | tr -d '\r\n' | jtxt "$1"; }
now_s() { if clock_sane; then date +%s 2>/dev/null; else echo 0; fi; }
new_uuid() { tr -cd 'a-f0-9-' < /proc/sys/kernel/random/uuid 2>/dev/null; }

# hex_b64 <hex> — base64 of the bytes a hex string spells (the random key, iv and salt go into the key envelope as base64).
# Lookup tables built in BEGIN: this awk has no index().
hex_b64() {
    printf '%s\n' "$1" | awk 'BEGIN { a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; h = "0123456789abcdef"
            for (i = 0; i < 16; i++) v[substr(h, i + 1, 1)] = i }
        { n = length($0); o = ""
          for (i = 1; i + 5 <= n; i += 6) {
              x = 0; for (j = 0; j < 6; j++) x = x * 16 + v[substr($0, i + j, 1)]
              o = o substr(a, int(x / 262144) + 1, 1) substr(a, int(x / 4096) % 64 + 1, 1) substr(a, int(x / 64) % 64 + 1, 1) substr(a, x % 64 + 1, 1) }
          r = n - i + 1
          if (r == 2) { x = v[substr($0, i, 1)] * 16 + v[substr($0, i + 1, 1)]
              o = o substr(a, int(x / 4) + 1, 1) substr(a, (x % 4) * 16 + 1, 1) "==" }
          else if (r == 4) { x = 0; for (j = 0; j < 4; j++) x = x * 16 + v[substr($0, i + j, 1)]
              o = o substr(a, int(x / 1024) + 1, 1) substr(a, int(x / 16) % 64 + 1, 1) substr(a, (x % 16) * 4 + 1, 1) "=" }
          printf "%s", o }'
}

# ---- the job ---------------------------------------------------------------------------------------------------------------------
# THE JOB'S ID — the panel makes one per start and the CGI exports it (ENODIA_PREMIUM_JOB): a tab knows ITS work among the ones it
# merely sees running (the same reason as warp.sh's). It goes at the END of every status line.
JOB=$(printf '%s' "${ENODIA_PREMIUM_JOB:-}" | tr -cd 'a-f0-9' | cut -c1-32)
OP=""; _ptg=""
put() {
    _ppj=$1; [ -z "$JOB" ] || _ppj="${1%\}},\"job\":\"$JOB\"}"
    _ppt=$(mktemp "$ST.XXXXXX" 2>/dev/null) || return 1; printf '%s\n' "$_ppj" > "$_ppt" && mv "$_ppt" "$ST"
}
# PEX — the work's country and protocol (`,"cc":…,"p":…`), set by a pick/refresh: the panel shows «беру конфиг…» at that country's
# switch and a refusal at its line.
PEX=""
say() { put "{\"state\":\"running\",\"op\":\"$OP\",\"tag\":\"$_ptg\"$PEX,\"msg\":\"$1\"}"; }
# A refusal: the status says it; a foreground caller (the watchdog, `update`) reads the words from FAILMSG.
FAILMSG=""
fail() { FAILMSG=$1; put "{\"state\":\"error\",\"op\":\"$OP\",\"tag\":\"$_ptg\"$PEX,\"msg\":\"$1\"}"; exit 1; }
done_() { put "{\"state\":\"done\",\"op\":\"$OP\",\"tag\":\"$_ptg\"$PEX,\"msg\":\"$1\"${2:+,$2}}"; }
job_alive() { _pja=$(cat "$1" 2>/dev/null | tr -cd '0-9'); [ -n "$_pja" ] && pid_runs "$_pja" 'premium\.sh'; }
busy() { job_alive "$PIDF" || job_alive "$STARTF"; }
take_start() {
    lbl_lock_take "$STARTL" 'premium\.sh' || return 1
    if busy; then lbl_lock_drop "$STARTL"; return 1; fi
    rm -f "$STARTF" "$PIDF"
    ( set -C; echo $$ > "$STARTF" ) 2>/dev/null || { lbl_lock_drop "$STARTL"; return 1; }
    lbl_lock_drop "$STARTL"
    trap 'rm -f "$STARTF"' EXIT
    trap 'exit 1' INT TERM HUP PIPE
    return 0
}
BUSY_MSG="[premium] другая работа с Amnezia Premium уже идёт — дождитесь её"
start() {
    say "начинаю"
    if [ -x /sbin/start-stop-daemon ]; then
        start-stop-daemon -S -b -m -p "$PIDF" -x /bin/sh -- "$ENODIA_DIR/premium.sh" "$@" >/dev/null 2>&1
    else ( sh "$ENODIA_DIR/premium.sh" "$@" >/dev/null 2>&1 & echo $! > "$PIDF" ); fi
    # fixed-wait: not a daemon's start — the pidfile written by start-stop-daemon's child; a job that has already ended is not waited for longer.
    _psw=0
    while ! job_alive "$PIDF" && [ "$_psw" -lt 20 ]; do
        if command -v usleep >/dev/null 2>&1; then usleep 100000; else sleep 1; _psw=$((_psw+9)); fi
        _psw=$((_psw+1))
    done
}
# The work directory holds the API key, the private key of a new config and Amnezia's answers: the job's OWN and closed. One job at
# a time ⇒ any other work directory is a killed job's leftover.
work_dir() {
    W=/tmp/enodia-premium.work.$$
    rm -rf /tmp/enodia-premium.work.* 2>/dev/null
    ( umask 077; mkdir "$W" ) || fail "нет места для работы"
    trap 'rm -rf "$W" "$PIDF"' EXIT
    trap 'exit 1' INT TERM HUP PIPE
}

# ---- the key ---------------------------------------------------------------------------------------------------------------------
# key_parse <decoded JSON> → K_SVC K_UCC K_PROTO K_API K_NAME; code 1 + KEY_WHY — not a key we can use. The decoder of the link
# is the router's one (subs-update.sh vpn-json: the same four forms as a subscription's `vpn://`).
key_parse() {
    KEY_WHY=""
    _pkv=$(jf "$1" '@.config_version' | tr -cd '0-9' | cut -c1-6)   # it goes into the refusal's words, and they into JSON
    K_SVC=$(jf "$1" '@.api_config.service_type' | tr -cd 'a-z0-9-' | cut -c1-40)
    K_API=$(jf "$1" '@.auth_data.api_key')
    if [ -z "$K_SVC" ] || [ -z "$K_API" ]; then
        if [ -n "$(jf "$1" '@.containers[0]')" ]; then KEY_WHY="это готовый конфиг Amnezia, а не ключ подписки — добавьте его как сервер"
        else KEY_WHY="это не ключ подписки Amnezia Premium (нет api_key)"; fi
        return 1
    fi
    case "$_pkv" in 2) ;; *) KEY_WHY="ключ Amnezia незнакомого вида (config_version ${_pkv:-нет}) — нужна новая версия панели"; return 1 ;; esac
    # amnezia-premium — the paid service; external-premium — a partner's, through the same gateway. The free one and the rest have
    # another life cycle the router does not know.
    case "$K_SVC" in amnezia-premium|external-premium) ;; *) KEY_WHY="этот вид подписки Amnezia («$K_SVC») роутер не поддерживает"; return 1 ;; esac
    # The key goes into the request JSON as is ⇒ only what a token is made of.
    # (busybox regex: an interval stops at 255 — the length is counted by the shell.)
    # ONE line: grep judges line by line, and a value with a newline passed on its good line (review s.136, L8).
    [ "$(printf '%s' "$K_API" | tr -d '\n\r')" = "$K_API" ] && printf '%s' "$K_API" | grep -Eq '^[A-Za-z0-9._~+/=:-]+$' \
        && [ "${#K_API}" -ge 8 ] && [ "${#K_API}" -le 512 ] || { KEY_WHY="в ключе непонятный api_key"; return 1; }
    K_UCC=$(jf "$1" '@.api_config.user_country_code' | tr -cd 'a-z' | cut -c1-8); [ -n "$K_UCC" ] || K_UCC=ru
    K_PROTO=$(jf "$1" '@.api_config.service_protocol' | tr -cd 'a-z'); case "$K_PROTO" in awg|vless) ;; *) K_PROTO=awg ;; esac
    K_NAME=$(jf "$1" '@.name' | jline 64); [ -n "$K_NAME" ] || K_NAME="Amnezia Premium"
    return 0
}
# key_decode <file with the link> <out JSON> — 0: the JSON is there.
key_decode() { [ -f "$ENODIA_DIR/subs-update.sh" ] && sh "$ENODIA_DIR/subs-update.sh" vpn-json "$1" "$2" >/dev/null 2>&1 </dev/null && [ -s "$2" ]; }
# key_of <tag> — the subscription's key out of the registry into the work directory, parsed (K_*); a refusal — fail.
key_of() {
    _pku=$(sub_url_of "$1")
    case "$_pku" in vpn://*) ;; *) fail "у подписки «$1» нет ключа Amnezia" ;; esac
    printf '%s\n' "$_pku" > "$W/key"
    key_decode "$W/key" "$W/key.json" || fail "ключ подписки не читается"
    key_parse "$W/key.json" || fail "$KEY_WHY"
    rm -f "$W/key"
}
# The router's installation: made once, kept in the state (it IS the device Amnezia counts).
inst_id() {
    _pii=$(tr -cd 'a-f0-9-' 2>/dev/null < "$INST_F")
    case "$_pii" in ????????-????-????-????-????????????) printf '%s' "$_pii"; return 0 ;; esac
    _pii=$(new_uuid)
    case "$_pii" in ????????-????-????-????-????????????) ;; *) return 1 ;; esac
    ( umask 077; mkdir -p "$PDIR" && lbl_commit "$INST_F" "$_pii" ) 2>/dev/null || return 1
    printf '%s' "$_pii"
}

# ---- the wire --------------------------------------------------------------------------------------------------------------------
# The request's common part, as the app's GatewayPayloadBuilder writes it (after the key: K_*, INST). Every value here was checked
# for its characters before (key_parse, inst_id, the verbs' own checks) — nothing goes in that a JSON string cannot hold as is.
common() {
    printf '"os_version":"%s","app_version":"%s","cli_name":"%s","app_language":"%s","installation_uuid":"%s","user_country_code":"%s","service_type":"%s","auth_data":{"api_key":"%s"}' \
        "$OS" "$APP_VER" "$CLI" "$(nf_lang)" "$INST" "$K_UCC" "$K_SVC" "$K_API"
}
# gw_list — the gateways to try, one per line: the app's main one, then the lists (this boot's copy while it is fresh). A list is
# AES under SHA-512 of the PEM bytes; an entry is taken only as an https URL of a public host — the list's key is derived from a
# PUBLIC file, so a list is no proof of origin: it is a hint, the answer's decryption is the proof.
gw_list() {
    printf '%s\n' "$GW_MAIN"
    _pgu=$(head -n 1 "$GWC" 2>/dev/null | tr -cd '0-9'); _pgn=$(uptime_s)
    if [ -n "$_pgu" ] && [ -n "$_pgn" ] && [ "$_pgn" -ge "$_pgu" ] && [ $((_pgn - _pgu)) -lt "$GWC_TTL" ] && [ "$(wc -l < "$GWC")" -gt 1 ]; then
        tail -n +2 "$GWC"; return 0
    fi
    gw_fetch && tail -n +2 "$GWC"
    return 0
}
gw_fetch() {
    [ -s "$PEM" ] || return 1
    _pgd=$(openssl dgst -sha512 "$PEM" 2>/dev/null | sed 's/^.*= *//' | tr -cd 'a-f0-9')
    [ "${#_pgd}" = 128 ] || return 1
    _pgk=$(printf '%s' "$_pgd" | cut -c1-64); _pgi=$(printf '%s' "$_pgd" | cut -c65-96)
    _pgname=$(printf 'endpoints-%s-%s' "$K_SVC" "$K_UCC" | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '=')
    _pgout=""
    for _pgb in $GW_LISTS; do
        for _pgf in "$_pgname.json" endpoints.json; do
            sub_fetch "$_pgb$_pgf" "$W/gl.enc" || continue
            tr -d '\r\n' < "$W/gl.enc" > "$W/gl.b64" 2>/dev/null
            openssl enc -d -aes-256-cbc -K "$_pgk" -iv "$_pgi" -a -A -in "$W/gl.b64" -out "$W/gl.json" 2>/dev/null || continue
            _pgout=$(jf "$W/gl.json" '@[*]' | grep -E '^https://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?/$' | head -n 16)
            [ -n "$_pgout" ] && break 2
        done
    done
    rm -f "$W/gl.enc" "$W/gl.b64" "$W/gl.json" 2>/dev/null
    [ -n "$_pgout" ] || return 1
    _pgok=""
    for _pgx in $_pgout; do sub_host_public "$_pgx" && _pgok="$_pgok$_pgx
"; done
    [ -n "$_pgok" ] || return 1
    ( umask 077; lbl_commit "$GWC" "$(uptime_s)
${_pgok%
}" ) 2>/dev/null
}
# post_one <gateway> <path> <body> <out> [wan] — one POST; the HTTP code on stdout. `wan` — bound to the WAN interface with the
# name resolved by DoH over WAN: the way when the router's own traffic rides a tunnel that does not carry (a Premium server the
# watchdog is about to call dead — rake «a bypass fallback MUST bind to WAN»).
post_one() {
    _ppu="$1$2"; _ppx=""
    if [ "${5:-}" = wan ]; then
        _ppw=$(wan_iface); [ -n "$_ppw" ] || { echo 000; return 0; }
        _pph=$(printf '%s' "$1" | sed 's#^[a-z]*://##; s#[/:].*##')
        _ppp=$(printf '%s' "$1" | sed -n 's#^[a-z]*://[^/:]*:\([0-9]*\).*#\1#p')
        [ -n "$_ppp" ] || case "$1" in https:*) _ppp=443 ;; *) _ppp=80 ;; esac
        _ppa=$(doh_ips "$_pph" 2>/dev/null | head -n 1)
        [ -n "$_ppa" ] || { echo 000; return 0; }
        _ppx="--interface $_ppw --resolve $_pph:$_ppp:$_ppa"
    fi
    _ppca=""; case "$1" in https:*) _ppca=$(curl_ca_opt "$1") ;; esac
    # shellcheck disable=SC2086
    curl -s $_ppca $_ppx --connect-timeout 8 --max-time 25 -X POST -H 'Content-Type: application/json' \
        -H "X-Client-Request-ID: $(new_uuid)" --data-binary @"$3" -o "$4" -w '%{http_code}' "$_ppu" 2>/dev/null || echo 000
}
# call <path> <payload file> — the request through the first gateway that ANSWERS; the decrypted answer → $W/resp.json, its
# http_status → HS, its message → HMSG. Code 1 — no gateway gave an answer we could read (CALL_WHY says what was seen).
# WHEN TO TRY THE NEXT GATEWAY — the app's shouldBypassProxy: no answer, an answer that does not decrypt (a dead or rotated proxy, a
# filter's page), a 404/501 that is not the API's own word, a 422 that is not «subscription not active», a 5xx. Everything else IS
# the API's answer and goes back to the caller (409 places, 402 captcha, 429 slow down, 408, the known 404s, 501 «update»).
call() {
    _pck=$(openssl rand -hex 32 2>/dev/null); _pcv=$(openssl rand -hex 32 2>/dev/null); _pcs=$(openssl rand -hex 8 2>/dev/null)
    [ "${#_pck}" = 64 ] && [ "${#_pcv}" = 64 ] && [ "${#_pcs}" = 16 ] || { CALL_WHY="нет openssl для шифрования запроса"; return 1; }
    _pci=$(printf '%s' "$_pcv" | cut -c1-32)
    printf '{"aes_key":"%s","aes_iv":"%s","aes_salt":"%s"}' "$(hex_b64 "$_pck")" "$(hex_b64 "$_pcv")" "$(hex_b64 "$_pcs")" > "$W/kp.json"
    openssl rsautl -encrypt -pubin -inkey "$PEM" -pkcs -in "$W/kp.json" -out "$W/kp.bin" 2>/dev/null || { CALL_WHY="не удалось зашифровать запрос (ключ Amnezia)"; return 1; }
    openssl enc -aes-256-cbc -K "$_pck" -iv "$_pci" -in "$2" -out "$W/ap.bin" 2>/dev/null || { CALL_WHY="не удалось зашифровать запрос"; return 1; }
    printf '{"key_payload":"%s","api_payload":"%s"}' "$(openssl base64 -A < "$W/kp.bin")" "$(openssl base64 -A < "$W/ap.bin")" > "$W/body.json"
    rm -f "$W/kp.json" "$W/kp.bin" "$W/ap.bin" "$2"
    HS=""; HMSG=""; CALL_WHY="ни один шлюз Amnezia не ответил"
    _pcfinal=""
    for _pcmode in plain wan; do
        for _pcg in $(gw_list); do
            rm -f "$W/resp.bin" "$W/resp.json"
            _pcc=$(post_one "$_pcg" "$1" "$W/body.json" "$W/resp.bin" "$_pcmode")
            [ -s "$W/resp.bin" ] || continue
            openssl enc -d -aes-256-cbc -K "$_pck" -iv "$_pci" -in "$W/resp.bin" -out "$W/resp.json" 2>/dev/null || { rm -f "$W/resp.json"; continue; }
            _pchs=$(jf "$W/resp.json" '@.http_status' | tr -cd '0-9')
            [ -n "$_pchs" ] || continue
            # The app's rule as it is (GatewayController::shouldBypassProxy): «html» in the DECRYPTED body, case as written — a case-blind
            # match dropped ~0.3 % of good answers (a base64 config holds those letters; review s.136, L2).
            grep -q 'html' "$W/resp.json" 2>/dev/null && continue
            HS=$_pchs; HMSG=$(jf "$W/resp.json" '@.message' | jline 200)
            [ -n "$HMSG" ] || HMSG=$(jf "$W/resp.json" '@.error' | jline 200)
            case "$HS" in
                2??) return 0 ;;
                404) printf '%s' "$HMSG" | grep -qE 'No active configuration found for|No non-revoked public key found for|Account not found|ession not found' && return 0 ;;
                501) printf '%s' "$HMSG" | grep -q 'client version update is required' && return 0 ;;
                422) [ "$HMSG" = "Failed to retrieve subscription information. Is it activated?" ] && return 0 ;;
                5??) ;;
                *) return 0 ;;
            esac
            _pcfinal=1   # the API's answer of the kind that is tried elsewhere — kept as the last word if nobody says better
            cp "$W/resp.json" "$W/resp.last" 2>/dev/null
        done
        # An answer in the plain pass is an answer: the WAN pass is for a router whose own traffic does not get out at all.
        [ -n "$_pcfinal" ] && break
    done
    if [ -n "$_pcfinal" ] && [ -s "$W/resp.last" ]; then mv "$W/resp.last" "$W/resp.json"; return 0; fi
    return 1
}
# api_why — the API's refusal (HS, HMSG) in the person's words.
api_why() {
    case "$HS" in
        409) if printf '%s' "$HMSG" | grep -qi 'trial'; then echo "пробный период этого аккаунта уже использован"
             else echo "все места подписки заняты — освободите одно в списке устройств подписки (или в приложении AmneziaVPN)"; fi ;;
        404) if printf '%s' "$HMSG" | grep -q 'Account not found'; then echo "Amnezia не знает этот ключ — он отозван или набран с ошибкой"
             else echo "Amnezia не нашла конфиг этого устройства — возьмите страну заново"; fi ;;
        422) if [ "$HMSG" = "Failed to retrieve subscription information. Is it activated?" ]; then echo "подписка не активна — истекла или ещё не оплачена"
             else echo "Amnezia не выдала конфиг${HMSG:+: $HMSG}"; fi ;;
        429) echo "Amnezia просит подождать: слишком много запросов — повторите через несколько минут" ;;
        402) echo "Amnezia просит пройти капчу — роутер этого не умеет; откройте приложение AmneziaVPN и повторите там, потом здесь" ;;
        501) echo "Amnezia требует новую версию клиента — обновите Enodia" ;;
        408) echo "Amnezia не успела ответить — повторите" ;;
        *) echo "Amnezia ответила ошибкой ${HS:-?}${HMSG:+: $HMSG}" ;;
    esac
}
# ask <path> <payload file> — call, and a refusal of any kind is the job's end in words.
ask() {
    call "$1" "$2" || fail "$CALL_WHY"
    case "$HS" in 2??) ;; *) fail "$(api_why)" ;; esac
}

# ---- what an answer says ---------------------------------------------------------------------------------------------------------
# account_save <tag> — the decrypted account_info → premium/<tag>.account (600, whole) and the subscription's own line (.sub-info):
# the end date is the list line's «до …», `have` with no total is «без лимита» (Premium has no traffic cap).
# Code 1 — not saved: the caller decides whether that ends its work (the account's own job) or not (a pick, a revoke: their work is
# done, the cache is a courtesy to the screen).
account_save() {
    ( umask 077; mkdir -p "$PDIR" && lbl_commit_out "$PDIR/$1.account" cat "$W/resp.json" ) 2>/dev/null || return 1
    _pae=$(iso_date_epoch "$(jf "$PDIR/$1.account" '@.subscription_end_date')") || _pae=0
    SUB_UI_HAVE=1 SUB_UI_UP=0 SUB_UI_DOWN=0 SUB_UI_TOTAL=0 SUB_UI_EXP=$_pae sub_info_put "$1" ok
}
# The configs of subscription $1 on the router: «cc⇥proto⇥name» per line. A file is ours by the namespace AND by the owner (the
# longest tag — a subscription whose tag is a prefix of ours owns none of these).
picks_of() {
    for _pof in "$ENODIA_STATE"/configs/sub-"$1"-*-awg.conf "$ENODIA_STATE"/xray-configs/sub-"$1"-*-vless.json; do
        [ -e "$_pof" ] || continue
        _pob=${_pof##*/}; _pob=${_pob%.*}
        [ "$(sub_owner_tag "$_pob")" = "$1" ] || continue
        _poc=${_pob#sub-"$1"-}; _pop=${_poc##*-}; _poc=${_poc%-*}
        printf '%s\t%s\t%s\n' "$_poc" "$_pop" "$_pob"
    done
}
# cc_flag <code> — the country's flag: two regional letters (U+1F1E6 + letter), UTF-8 F0 9F 87 A6+n; «us-east» → 🇺🇸. Anything else —
# nothing. The letter's number is its place in the alphabet (no `printf "'c"` trust on every busybox).
CC_ABC=ABCDEFGHIJKLMNOPQRSTUVWXYZ
cc_flag() {
    _pcf=$(printf '%s' "$1" | cut -c1-2 | tr 'a-z' 'A-Z')
    case "$_pcf" in [A-Z][A-Z]) ;; *) return 0 ;; esac
    _pcf1=${_pcf%?}; _pcf2=${_pcf#?}
    _pcx1=${CC_ABC%%"$_pcf1"*}; _pcx2=${CC_ABC%%"$_pcf2"*}
    printf "\360\237\207\\$(printf '%o' $((166 + ${#_pcx1})))\360\237\207\\$(printf '%o' $((166 + ${#_pcx2})))"
}
cc_ok() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{1,15}$'; }
name_of() { printf 'sub-%s-%s-%s' "$1" "$2" "$3"; }
fam_of_proto() { case "$1" in awg) echo awg ;; vless) echo xray ;; esac; }
cfg_file() { case "$1" in awg) printf '%s/configs/%s.conf' "$ENODIA_STATE" "$2" ;; *) printf '%s/xray-configs/%s.json' "$ENODIA_STATE" "$2" ;; esac; }

# THE SUBSCRIPTIONS' RUN HOLDS ITS LOCK — `put` refuses at once then, and by that moment Amnezia's side of a pick or a refresh is
# done: the issued config would be thrown away and the old key already superseded (review s.136, M1). So the lock is waited for
# BEFORE the API is asked and again before the config is laid out.
subs_busy() { _psb=$(cat "$SUBS_LOCK/pid" 2>/dev/null | tr -cd '0-9'); [ -n "$_psb" ] && pid_runs "$_psb" 'subs-update\.sh'; }
subs_wait() {   # $1 = seconds → 0 no run holds the lock now
    _psw2=0
    while subs_busy; do [ "$_psw2" -ge "$1" ] && return 1; sleep 3; _psw2=$((_psw2 + 3)); done
    return 0
}

# THE NEW KEY ON STANDBY (the user's decision 14.10.2026, after the walk's measurements): Amnezia takes a fresh key into service
# ~1.5–2 min after it is issued (NL VLESS 18:17 → carried 18:19; DE AWG 18:20 → 18:22), and a server pair it assigns to a country
# may never carry our user (sub 1's EE VLESS: three keys, never). A swap at once raised a carrier that could not shake hands, rolled
# back after 25 s to a key Amnezia had just superseded — the main server could not come back by itself (review s.136, H1). So a
# refresh lays the new text out only once it CARRIES, asked by the result: an AmneziaWG config through a throwaway interface
# (transport-awg.sh try — the live ones untouched), a VLESS one through a temporary socks (xray-test.sh). The old file serves
# meanwhile. live_probe: 0 — it carries now · 1 — not yet · 2 — it cannot be asked here (LIVE_WHY).
# THE ROAD: a config whose server rides another exit (road.sh) is probed by that road too (TRY_ROAD) — directly the probe met the
# ISP's block, read «never carried», and its rule took the live tunnel's packets to the same relay off the road (review s.136 r2, M3).
live_probe() {   # $1 = proto  $2 = config file  $3 = the config's name
    LIVE_WHY=""
    if [ "$1" = awg ]; then
        _plo=$(TRY_ROAD=$3 sh "$ENODIA_DIR/transport-awg.sh" try "$2" "$PM_TRACE" 10 2>/dev/null </dev/null); _plr=$?
        case "$_plr" in
            0) printf '%s\n' "$_plo" | grep '^ip=' >/dev/null && return 0; return 1 ;;
            4) LIVE_WHY="не поднялся пробный интерфейс AmneziaWG — проверьте AmneziaWG в «Компонентах»"; return 2 ;;
        esac
        return 1
    fi
    _plo=$(XRAY_TEST_SRC=$2 sh "$ENODIA_DIR/xray-test.sh" premium-standby "$PM_XT_PORT" 2>/dev/null </dev/null)
    case "$_plo" in
        *'"ok":true'*) return 0 ;;
        *'"busy":true'*) return 1 ;;
        *'не установлен'*|*'не найден'*|*'не удалось подготовить'*)
            LIVE_WHY=$(printf '%s' "$_plo" | sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' | jline 200); return 2 ;;
    esac
    return 1
}
# wait_live <proto> <file> — 0: it carries; 1: it did not within PM_LIVE_MAX (by uptime: no clock trust needed). A probe that cannot
# run here ends the work in its words.
wait_live() {   # $1 = proto  $2 = file  $3 = the config's name
    _pwe=$(( $(uptime_s) + PM_LIVE_MAX ))
    while :; do
        live_probe "$1" "$2" "$3"
        case $? in 0) return 0 ;; 2) rm -f "$W/out" "$W/priv"; fail "$LIVE_WHY" ;; esac
        _pwn=$(uptime_s); [ "$_pwn" -lt "$_pwe" ] || return 1
        say "Amnezia заводит новый ключ — жду, пока он повезёт (до $(( (_pwe - _pwn + 59) / 60 )) мин); прежний конфиг на месте"
        sleep "$PM_LIVE_STEP"
    done
}

# ---- the verbs -------------------------------------------------------------------------------------------------------------------
cmd_check() {
    [ -s "$1" ] || { printf '{"ok":false,"msg":"пустой ключ"}\n'; return 1; }
    _pcw=$(umask 077; mktemp -d /tmp/enodia-premium-check.XXXXXX 2>/dev/null) || { printf '{"ok":false,"msg":"нет места для работы"}\n'; return 1; }
    if key_decode "$1" "$_pcw/k.json" && key_parse "$_pcw/k.json"; then
        rm -rf "$_pcw"
        printf '{"ok":true,"svc":"%s","name":"%s","proto":"%s","ucc":"%s"}\n' "$K_SVC" "$K_NAME" "$K_PROTO" "$K_UCC"
        return 0
    fi
    rm -rf "$_pcw"
    printf '{"ok":false,"msg":"%s"}\n' "${KEY_WHY:-ссылка не читается как ключ Amnezia}"
    return 1
}
tag_ok() { printf '%s' "$1" | grep -Eq '^[a-z0-9-]{1,16}$' && case "$(sub_url_of "$1")" in vpn://*) true ;; *) false ;; esac; }

# account — the front verb starts the work; run-account does it.
cmd_account() {
    tag_ok "$1" || { echo "[premium] нет подписки Amnezia Premium «$1»"; return 1; }
    take_start || { echo "$BUSY_MSG"; return 1; }
    OP=account; _ptg=$1
    start run-account "$1"
    echo "[premium] спрашиваю Amnezia о подписке"
}
run_account() {
    OP=account; _ptg=$1
    work_dir
    key_of "$1"
    INST=$(inst_id) || fail "не удалось завести идентификатор роутера"
    say "спрашиваю Amnezia о подписке"
    printf '{%s,"cli_version":"%s","subscription_status":"active"}' "$(common)" "$APP_VER" > "$W/req.json"
    if ! call v1/account_info "$W/req.json"; then sub_info_put "$1" fail; fail "$CALL_WHY"; fi
    case "$HS" in 2??) ;; *) sub_info_put "$1" fail; fail "$(api_why)" ;; esac
    account_save "$1" || fail "не удалось сохранить ответ — нет места?"
    _pan=$(jf "$PDIR/$1.account" '@.available_countries[*].server_country_code' | wc -l)
    done_ "подписка проверена: стран $_pan"
}

# pick / refresh — a config of country $2 by protocol $3 for subscription $1. `refresh` names an existing config; the work is the
# same, and the owner of the files (subs-update.sh put) brings an in-use config into service.
cmd_pick() {
    tag_ok "$1" || { echo "[premium] нет подписки Amnezia Premium «$1»"; return 1; }
    cc_ok "$2" || { echo "[premium] плохой код страны"; return 1; }
    case "$3" in awg|vless) ;; *) echo "[premium] протокол — awg или vless"; return 1 ;; esac
    if [ "$3" = awg ] && [ ! -x "$ENODIA_BIN/awg" ]; then echo "[premium] нет AmneziaWG — поставьте его в «Компонентах»"; return 1; fi
    # A country picked already: a pick would lay a new key over a server that may be in use, without the standby a refresh has (two
    # tabs, a stale screen — review s.136, panel 7). A new key is «Взять новый».
    if [ -e "$(cfg_file "$3" "$(name_of "$1" "$2" "$3")")" ]; then
        echo "[premium] эта страна уже отмечена — новый ключ для неё берут кнопкой «Взять новый» на экране её сервера"; return 1
    fi
    take_start || { echo "$BUSY_MSG"; return 1; }
    OP=pick; _ptg=$1; PEX=",\"cc\":\"$2\",\"p\":\"$3\""
    start run-pick "$1" "$2" "$3"
    echo "[premium] беру конфиг у Amnezia"
}
# refresh <name> → its tag, country and protocol from the name (the namespace IS the record).
name_parts() {
    _pnn=$1; _pnt=$(sub_owner_tag "$_pnn")
    [ -n "$_pnt" ] && tag_ok "$_pnt" || return 1
    _pnc=${_pnn#sub-"$_pnt"-}; _pnp=${_pnc##*-}; _pnc=${_pnc%-*}
    case "$_pnp" in awg|vless) ;; *) return 1 ;; esac
    cc_ok "$_pnc"
}
cmd_refresh() {   # $1 name  [$2 auto — the watchdog's kick]
    name_parts "$1" || { echo "[premium] «$1» — не сервер подписки Amnezia Premium"; return 1; }
    # A stale screen (another tab unpicked it) would lay the country out again under «новый конфиг на месте» (review s.136 r2, L6).
    [ -e "$(cfg_file "$_pnp" "$1")" ] || { echo "[premium] эта страна уже не отмечена — новый ключ ей не нужен"; return 1; }
    take_start || { echo "$BUSY_MSG"; return 1; }
    OP=refresh; _ptg=$_pnt; PEX=",\"cc\":\"$_pnc\",\"p\":\"$_pnp\""
    start run-pick "$_pnt" "$_pnc" "$_pnp" refresh "$( [ "${2:-}" = auto ] && echo auto )"
    echo "[premium] беру у Amnezia новый конфиг"
}
# THE STANDBY (review s.136 r2, M2, M4). A new key that did not carry in time, or that the owner could not lay out, was thrown away —
# and with it the only key Amnezia then held current: the issue supersedes the previous one (same Address reissued; older configs die
# within minutes to ~2 h, measured). A relay down for ten minutes, or a subscriptions' run longer than the wait, left the router with
# a dying old key, no new one, and a watchdog told not to ask again for 6 h. Now the text stays (keep_next) and is tried FIRST: a
# refresh probes it once — it carries ⇒ laid out with no new request; a pick lays it out at once. A refresh of the person's
# (button) asks Amnezia anew when it does not carry; the watchdog's (`auto`) does that only after PM_NOCARRY_GAP — a pair Amnezia
# pins may never carry our user (sub 1's EE: three keys), and every request moves the server to a key again.
keep_next() {
    ( umask 077; lbl_commit_out "$NEXT.$_prn" cat "$W/out" && lbl_commit "$NEXT.$_prn.at" "$_prat$TAB$_prd" ) 2>/dev/null
}
next_drop() { rm -f "$NEXT.$1" "$NEXT.$1.at" 2>/dev/null; }
run_pick() {   # $1 tag  $2 cc  $3 proto  [$4 refresh]  [$5 auto]
    OP=${4:-pick}; _ptg=$1; PEX=",\"cc\":\"$2\",\"p\":\"$3\""
    work_dir
    key_of "$1"
    INST=$(inst_id) || fail "не удалось завести идентификатор роутера"
    _prn=$(name_of "$1" "$2" "$3"); _prf=$(fam_of_proto "$3")
    _prsb=0; _prat=""
    if [ -s "$NEXT.$_prn" ]; then
        ( umask 077; cat "$NEXT.$_prn" > "$W/out" ) 2>/dev/null
        _prat=$(cut -f1 "$NEXT.$_prn.at" 2>/dev/null | tr -cd '0-9'); _prd=$(cut -f2- "$NEXT.$_prn.at" 2>/dev/null | jline 64)
        [ -n "$_prd" ] || _prd=$(printf '%s' "$2" | tr 'a-z' 'A-Z')
        if [ ! -s "$W/out" ]; then rm -f "$W/out"
        elif [ "$OP" = pick ]; then _prsb=1
        else
            say "проверяю новый ключ, взятый раньше: он ещё не стоял на месте"
            live_probe "$3" "$W/out" "$_prn"
            case $? in
                0) _prsb=1 ;;
                2) rm -f "$W/out"; fail "$LIVE_WHY" ;;
                *) rm -f "$W/out"
                   _prnw=$(uptime_s)
                   if [ "${5:-}" = auto ] && [ -n "$_prat" ] && [ "$_prnw" -ge "$_prat" ] && [ $((_prnw - _prat)) -lt "$PM_NOCARRY_GAP" ]; then
                       fail "новый ключ «$_prd», взятый $(( (_prnw - _prat) / 60 )) мин назад, всё ещё не везёт — прежний конфиг на месте; другой ключ попрошу у Amnezia через $(( (PM_NOCARRY_GAP - _prnw + _prat + 3599) / 3600 )) ч"
                   fi ;;
            esac
        fi
    fi
    if [ "$_prsb" = 0 ]; then
        if [ "$3" = awg ]; then
            [ -x "$ENODIA_BIN/awg" ] || fail "нет AmneziaWG — поставьте его в «Компонентах»"
            say "создаю ключ на роутере"
            ( umask 077; "$ENODIA_BIN/awg" genkey > "$W/priv" ) 2>/dev/null
            _prk=$(cat "$W/priv" 2>/dev/null); _prpub=$(printf '%s' "$_prk" | "$ENODIA_BIN/awg" pubkey 2>/dev/null)
            printf '%s' "$_prk" | grep -Eq '^[A-Za-z0-9+/]{43}=$' && printf '%s' "$_prpub" | grep -Eq '^[A-Za-z0-9+/]{43}=$' \
                || fail "не удалось создать ключ (awg genkey)"
        else
            _prpub=$(new_uuid)
            case "$_prpub" in ????????-????-????-????-????????????) ;; *) fail "не удалось создать идентификатор VLESS" ;; esac
        fi
        say "беру конфиг у Amnezia"
        subs_wait 60 || fail "идёт обновление подписок — повторите через минуту"
        # The subscription may have gone while we waited (its removal holds the same lock): asked now, Amnezia would give the router
        # a place again, with no config laid out and no subscription to free it from (review s.136 r2, L7).
        tag_ok "$1" || fail "подписку удалили — конфиг у Amnezia не беру"
        printf '{%s,"server_country_code":"%s","service_protocol":"%s","public_key":"%s"}' "$(common)" "$2" "$3" "$_prpub" > "$W/req.json"
        ask v1/config "$W/req.json"
        _prat=$(uptime_s)
        jf "$W/resp.json" '@.config' > "$W/cfg.vpn"
        grep -q '^vpn://' "$W/cfg.vpn" 2>/dev/null || fail "Amnezia ответила без конфига — её ответ изменился, нужна новая версия панели"
        say "раскладываю конфиг"
        sh "$ENODIA_DIR/subs-update.sh" vpn-json "$W/cfg.vpn" "$W/c.json" >/dev/null 2>&1 </dev/null && [ -s "$W/c.json" ] \
            || fail "конфиг Amnezia не читается"
        # The country as Amnezia names it (in the panel's language — app_language), else its code.
        _prd=$(jf "$W/c.json" '@.server_country_name' | jline 48); [ -n "$_prd" ] || _prd=$(printf '%s' "$2" | tr 'a-z' 'A-Z')
        _prf2=$(cc_flag "$2"); [ -z "$_prf2" ] || _prd="$_prf2 $_prd"
        if [ "$3" = awg ]; then
            sh "$ENODIA_DIR/subs-update.sh" vpn-conf "$W/cfg.vpn" "$W/out" "$W/priv" >/dev/null 2>&1 </dev/null && [ -s "$W/out" ] \
                || fail "в ответе Amnezia нет годного конфига AmneziaWG"
        else
            xray_take "$W/c.json" "$W/out" || fail "$XRAY_WHY"
        fi
        # A REFRESH WAITS UNTIL THE NEW KEY CARRIES (wait_live); not within the wait — the old file stays and the new text is the
        # standby. The words name what was seen — the server did not answer — not a cause: a relay down for ten minutes reads the
        # same as a pair that never takes our user. A pick lays its file out at once: there is no old one to keep.
        if [ "$OP" = refresh ]; then
            say "проверяю новый ключ: Amnezia заводит его до пары минут, прежний конфиг пока на месте"
            if ! wait_live "$3" "$W/out" "$_prn"; then
                keep_next
                rm -f "$W/out" "$W/priv"
                fail "Amnezia выдала новый ключ «$_prd», но за $((PM_LIVE_MAX / 60)) мин сервер на него не ответил — прежний конфиг на месте, новый отложен до следующей попытки. Если так раз за разом — возьмите другой протокол или страну"
            fi
        fi
    fi
    # Laid out under the subscriptions' lock — a run holding it is waited for, each try up to 90 s and six of them (the budget, not
    # the first timeout: one run lasts minutes — review s.136 r2, M4). SUBS_PUT_WHY — whose news it is: the owner's words and events
    # say «новый ключ Amnezia», not «изменился в подписке».
    _prr=1; _prt=0; _pro=""
    while [ "$_prt" -lt 6 ]; do
        _prt=$((_prt + 1))
        subs_wait "$PM_SUBS_WAIT" || continue
        _pro=$(SUBS_PUT_WHY=premium sh "$ENODIA_DIR/subs-update.sh" put "$1" "$_prf" "$_prn" "$W/out" "$_prd" 2>&1 </dev/null); _prr=$?
        case "$_prr" in 0|4) break ;; esac
        subs_busy || break                               # refused for its own reason, not the lock — its words below
    done
    case "$_prr" in
        0|4) next_drop "$_prn" ;;
        *)  _prl=$(printf '%s\n' "$_pro" | grep -v '^[[:space:]]*$' | tail -n 1 | sed 's/^[[:space:]]*//' | jline 300)
            [ -n "$_prl" ] || _prl="обновление подписок не отпускало свой лок $((6 * PM_SUBS_WAIT / 60)) мин"
            # Not laid out: the text Amnezia moved the server to stays as the standby — unless the subscription is gone.
            if tag_ok "$1"; then keep_next; _prl="$_prl — новый ключ отложен до следующей попытки"; fi
            rm -f "$W/out" "$W/priv"
            fail "$_prl" ;;
    esac
    rm -f "$W/out" "$W/priv"
    # What the owner did with a config IN USE (the active server raised on the new text, an exit restarted — or why not): its lines
    # before its last one («конфиг … на месте»); the last of them is the news.
    _prw=$(printf '%s\n' "$_pro" | grep -v '^[[:space:]]*$' | sed '$d' | tail -n 1 | sed 's/^[[:space:]]*//' | jline 300)
    # CODE 4 — the file is in place, but a switch held the lock while the owner was to raise the ACTIVE server on it; no subscriptions'
    # run would ever come back to it, and a failover meanwhile went on with the key Amnezia had just superseded (review s.136 r2,
    # H1). Asked again by state (`settle`) once the switch is over. THE CEILING COUNTS WHILE NOTHING DRIVES THE CARRIER: a ladder over a
    # pool lasts tens of minutes, and a job that gave up in its middle left the new key unused — in FAILOPEN the retries skip the
    # current name, so «the router chooses it again» never came (review s.136 r3, L3). While a switch or a tick runs — up to
    # PM_SETTLE_HARD.
    # …AND GIVES UP ONLY ON AN ANSWER ASKED WHILE NOTHING DROVE IT (`_psq`): a switch that ended while `settle` was asking left its
    # «4» behind, and the check «nothing drives it now» right after it gave up on a key it could raise that very second, saying the
    # switch «идёт дольше» (the busybox lane hit the window, s.138).
    if [ "$_prr" = 4 ]; then
        _pse=$(( $(uptime_s) + PM_SETTLE_MAX )); _psh=$(( $(uptime_s) + PM_SETTLE_HARD )); _psq=0
        while [ "$_prr" = 4 ]; do
            say "новый конфиг «$_prd» на месте; роутер сейчас сам меняет сервер — подниму новый, когда смена закончится"
            _psn=$(uptime_s)
            [ "$_psn" -lt "$_psh" ] || break
            if [ "$_psn" -ge "$_pse" ] && [ "$_psq" = 1 ] && [ ! -e "$SWLOCK" ] && ! carrier_busy; then break; fi
            sleep "$PM_LIVE_STEP"
            _psq=0                                       # a round without an ask (subs lock busy) proves nothing either
            subs_wait "$PM_SUBS_WAIT" || continue
            if [ ! -e "$SWLOCK" ] && ! carrier_busy; then _psq=1; fi
            _pso=$(SUBS_PUT_WHY=premium sh "$ENODIA_DIR/subs-update.sh" settle "$1" 2>&1 </dev/null); _prr=$?
            # a run took the lock in between — wait on; that «4» is no switch's, so no ground to give up on (review s.138)
            if [ "$_prr" = 1 ] && subs_busy; then _prr=4; _psq=0; fi
            _prw=$(printf '%s\n' "$_pso" | grep -v '^[[:space:]]*$' | tail -n 1 | sed 's/^[[:space:]]*//' | jline 300)
        done
        [ "$_prr" != 4 ] || _prw="смена сервера идёт дольше $(( (_psn - _pse + PM_SETTLE_MAX) / 60 )) мин — новый конфиг поднимется, когда роутер снова выберет этот сервер; сразу — выберите его в панели"
    fi
    # The subscription as Amnezia sees it now (walk 14.10.2026: after the first country the screen still said «устройств 2 из 7» —
    # that config made the router a device of the subscription, and the cache was older). Its failure is not the pick's.
    say "сверяю устройства подписки"
    printf '{%s,"cli_version":"%s","subscription_status":"active"}' "$(common)" "$APP_VER" > "$W/req.json"
    if call v1/account_info "$W/req.json"; then case "$HS" in 2??) account_save "$1" || : ;; esac; fi
    if [ "$OP" = refresh ]; then done_ "новый конфиг «$_prd» на месте${_prw:+ — $_prw}" "\"name\":\"$_prn\""
    else done_ "сервер «$_prd» добавлен" "\"name\":\"$_prn\""; fi
}
# xray_take <container JSON> <out> — the VLESS answer's xray config, made the router's: the access log OFF (xray writes it to
# stdout when the key is absent — into its log in RAM, ~15 MB a day; rake «xray's access log»), and the socks inbound the router's
# tun2socks expects (127.0.0.1:10808 — Amnezia's own; another one is a refusal, not a guess).
XRAY_WHY=""
xray_take() {
    jf "$1" '@.containers[0].xray.last_config' > "$2.raw"
    [ -s "$2.raw" ] || { XRAY_WHY="в ответе Amnezia нет конфига Xray"; return 1; }
    tr -d '\r\n' < "$2.raw" > "$2.one" 2>/dev/null
    if grep -q '"log"[[:space:]]*:[[:space:]]*{[^}]*}' "$2.one"; then
        sed 's/"log"[[:space:]]*:[[:space:]]*{[^}]*}/"log":{"loglevel":"warning","access":"none"}/' "$2.one" > "$2.new"
    else
        sed 's/^[[:space:]]*{/{"log":{"loglevel":"warning","access":"none"},/' "$2.one" > "$2.new"
    fi
    rm -f "$2.raw" "$2.one"
    [ "$(jf "$2.new" '@.log.access')" = none ] || { rm -f "$2.new"; XRAY_WHY="конфиг Xray от Amnezia не читается"; return 1; }
    [ -n "$(jf "$2.new" '@.outbounds[0].protocol')" ] || { rm -f "$2.new"; XRAY_WHY="в конфиге Xray от Amnezia нет сервера"; return 1; }
    if [ "$(jf "$2.new" '@.inbounds[0].port')" != 10808 ] || [ "$(jf "$2.new" '@.inbounds[0].protocol')" != socks ]; then
        rm -f "$2.new"; XRAY_WHY="Amnezia прислала конфиг Xray с другим локальным входом — нужна новая версия панели"; return 1
    fi
    mv "$2.new" "$2"
}

# unpick — no network: the owner of the files refuses a config in use, in its own words.
cmd_unpick() {
    tag_ok "$1" || { echo "[premium] нет подписки Amnezia Premium «$1»"; return 1; }
    cc_ok "$2" || { echo "[premium] плохой код страны"; return 1; }
    case "$3" in awg|vless) ;; *) echo "[premium] протокол — awg или vless"; return 1 ;; esac
    # Not beside a job: a pick of this country running now would lay its file out after the removal — the country came back
    # (review s.136, L5).
    if busy; then echo "$BUSY_MSG"; return 1; fi
    sh "$ENODIA_DIR/subs-update.sh" unput "$1" "$(fam_of_proto "$3")" "$(name_of "$1" "$2" "$3")" </dev/null; _pur2=$?
    [ "$_pur2" != 0 ] || next_drop "$(name_of "$1" "$2" "$3")"   # its standby goes with it
    return "$_pur2"
}

# revoke — a device's place given back (a foreign one; the router's own goes with the subscription — `drop`).
cmd_revoke() {
    tag_ok "$1" || { echo "[premium] нет подписки Amnezia Premium «$1»"; return 1; }
    case "$2" in ????????-????-????-????-????????????) ;; *) echo "[premium] плохой идентификатор устройства"; return 1 ;; esac
    printf '%s' "$2" | grep -Eq '^[a-f0-9-]{36}$' || { echo "[premium] плохой идентификатор устройства"; return 1; }
    # The router's own place goes with the subscription (`drop`): freed here, every country of every key would die within hours.
    if [ "$2" = "$(tr -cd 'a-f0-9-' 2>/dev/null < "$INST_F")" ]; then
        echo "[premium] это место самого роутера — оно освобождается вместе с подпиской (удалите её)"; return 1
    fi
    take_start || { echo "$BUSY_MSG"; return 1; }
    OP=revoke; _ptg=$1
    start run-revoke "$1" "$2"
    echo "[premium] освобождаю место устройства"
}
run_revoke() {   # $1 tag  $2 uuid
    OP=revoke; _ptg=$1
    work_dir
    key_of "$1"
    INST=$(inst_id) || fail "не удалось завести идентификатор роутера"
    # The device's country — from the last answer (the app sends it); unknown — none.
    _pvc=""
    _pvn=$(jf "$PDIR/$1.account" '@.issued_configs[*].installation_uuid' | head -n "$DEV_MAX" | grep -n -x "$2" | head -n 1 | cut -d: -f1)
    [ -z "$_pvn" ] || _pvc=$(jf "$PDIR/$1.account" "@.issued_configs[$((_pvn - 1))].server_country_code" | tr -cd 'a-z0-9-' | cut -c1-16)
    say "освобождаю место устройства"
    _pvown=$INST; INST=$2
    printf '{%s%s}' "$(common)" "${_pvc:+,\"server_country_code\":\"$_pvc\"}" > "$W/req.json"
    INST=$_pvown
    # A device Amnezia has dropped already answers 404 «no active configuration» — the place IS free; the app takes it so too
    # (review s.136, M3: «возьмите страну заново» was the answer, and the list kept the device).
    call v1/revoke_config "$W/req.json" || fail "$CALL_WHY"
    case "$HS" in
        2??) ;;
        404) printf '%s' "$HMSG" | grep -qE 'No active configuration found for|No non-revoked public key found for' || fail "$(api_why)" ;;
        *) fail "$(api_why)" ;;
    esac
    # The list as it is now: the freed place shows at once.
    printf '{%s,"cli_version":"%s","subscription_status":"active"}' "$(common)" "$APP_VER" > "$W/req.json"
    if call v1/account_info "$W/req.json"; then case "$HS" in 2??) account_save "$1" || : ;; esac; fi
    done_ "место устройства освобождено"
}

# drop <tag> <kept> — called by the subscription's removal (subs-update.sh drop) while the key is still in the registry. The cache
# goes. The router's place is given back ONLY when no config of this key stays on the router: a kept one (the active server, an
# exit) would die within the hour of a revoke (measured 10.10.2026: a revoked AWG key ~1 h 40 min later) — the person would lose
# the tunnel they kept on purpose. The revoke runs in the background with the key in a private file (never in argv).
cmd_drop() {
    printf '%s' "$1" | grep -Eq '^[a-z0-9-]{1,16}$' || return 1
    rm -f "$PDIR/$1.account" 2>/dev/null
    # The standbys of its countries go too — by the owner (the longest tag), as every file of the namespace.
    for _pdn in "$NEXT".sub-"$1"-*; do
        case "$_pdn" in *.at) continue ;; esac
        [ -e "$_pdn" ] || continue
        [ "$(sub_owner_tag "${_pdn#"$NEXT".}")" = "$1" ] && next_drop "${_pdn#"$NEXT".}"
    done
    [ "${2:-0}" = 0 ] || return 0
    _pdu=$(sub_url_of "$1"); case "$_pdu" in vpn://*) ;; *) return 0 ;; esac
    [ -s "$INST_F" ] || return 0                     # the router never asked Amnezia with any key: no place to give back
    _pdf=$(umask 077; mktemp /tmp/enodia-premium-give.XXXXXX 2>/dev/null) || return 0
    printf '%s\n' "$_pdu" > "$_pdf" || { rm -f "$_pdf"; return 0; }
    if [ -x /sbin/start-stop-daemon ]; then
        start-stop-daemon -S -b -m -p "$_pdf.pid" -x /bin/sh -- "$ENODIA_DIR/premium.sh" run-revoke-own "$_pdf" >/dev/null 2>&1
    else ( sh "$ENODIA_DIR/premium.sh" run-revoke-own "$_pdf" </dev/null >/dev/null 2>&1 & ); fi
    return 0
}
# run-revoke-own <file> — BEST EFFORT, as every give-back: no answer — the place simply stays taken (the app's device list frees it).
run_revoke_own() {
    case "$1" in /tmp/enodia-premium-give.*) ;; *) return 1 ;; esac
    _pgf=$1
    W=/tmp/enodia-premium.give.$$
    ( umask 077; mkdir "$W" ) 2>/dev/null || { rm -f "$_pgf"; return 0; }
    trap 'rm -rf "$W" "$_pgf" "$_pgf.pid"' EXIT
    trap 'exit 1' INT TERM HUP PIPE
    ST="$W/st"     # a background give-back has no status of its own (the panel's job line is another work's); a private file, not
                   # /dev/null — `put` replaces its status file by `mv` (review s.136, L4)
    key_decode "$_pgf" "$W/key.json" && key_parse "$W/key.json" || return 0
    INST=$(tr -cd 'a-f0-9-' 2>/dev/null < "$INST_F"); [ -n "$INST" ] || return 0
    printf '{%s}' "$(common)" > "$W/req.json"
    call v1/revoke_config "$W/req.json" >/dev/null 2>&1
    return 0
}

# A FOREGROUND WORK IS A JOB TOO (`update` from subs-update.sh): it takes the start like a front verb and names itself in the
# pidfile, so a panel job does not run beside it on the same files, and the panel sees «busy».
fg_job() { take_start || return 1; echo $$ > "$PIDF"; rm -f "$STARTF"; return 0; }
# update <tag> — subs-update.sh's step (its lock is held): the account asked again, in the foreground; the record's words on stdout.
# Its status goes to a PRIVATE file: the panel's job line is about the panel's work, and a cron run would overwrite it.
cmd_update() {
    tag_ok "$1" || { echo "нет ключа Amnezia"; return 1; }
    fg_job || { echo "занята другой работой с Amnezia — в следующий раз"; return 2; }
    _pust=$(umask 077; mktemp /tmp/enodia-premium-upd.XXXXXX 2>/dev/null) || { rm -f "$PIDF"; echo "нет места для работы"; return 1; }
    ( ST=$_pust; JOB=""; run_account "$1" ) >/dev/null 2>&1; _pur=$?
    _pum=$(sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' "$_pust" 2>/dev/null)
    rm -f "$_pust" "$_pust".* "$PIDF"
    if [ "$_pur" = 0 ]; then
        _pud=$(jf "$PDIR/$1.account" '@.active_device_count' | tr -cd '0-9'); _pux=$(jf "$PDIR/$1.account" '@.max_device_count' | tr -cd '0-9')
        echo "устройств ${_pud:-?} из ${_pux:-?}, выбрано стран $(picks_of "$1" | wc -l)"
        return 0
    fi
    echo "${_pum:-Amnezia не ответила}"
    return 1
}
# info <tag> — JSON for the panel. The last answer is a CACHE (its age is said); the picks are the files, asked now.
cmd_info() {
    tag_ok "$1" || { printf '{"ok":false,"msg":"нет подписки Amnezia Premium"}\n'; return 0; }
    _pia="$PDIR/$1.account"; _pinow=$(now_s)
    _pime=$(tr -cd 'a-f0-9-' 2>/dev/null < "$INST_F")
    _piout="{\"ok\":true,\"tag\":\"$1\",\"now\":$_pinow"
    if [ -s "$_pia" ]; then
        _piat=$(stat -c %Y "$_pia" 2>/dev/null | tr -cd '0-9'); [ -n "$_piat" ] || _piat=0
        _pie=$(iso_date_epoch "$(jf "$_pia" '@.subscription_end_date')") || _pie=0
        _pimx=$(jf "$_pia" '@.max_device_count' | tr -cd '0-9'); _pidc=$(jf "$_pia" '@.active_device_count' | tr -cd '0-9')
        _pinm=$(jf "$_pia" '@.display_name' | jline 64)
        _piout="$_piout,\"have\":true,\"at\":$_piat,\"end\":$_pie,\"max\":${_pimx:-0},\"used\":${_pidc:-0},\"name\":\"$_pinm\""
        # Devices: the uuid is the person's own account data and the door to «free this place»; the router's own is marked.
        _pid=""; _pii=0
        _pin=$(jf "$_pia" '@.issued_configs[*].installation_uuid' | wc -l)
        while [ "$_pii" -lt "$_pin" ] && [ "$_pii" -lt "$DEV_MAX" ]; do
            _piu=$(jf "$_pia" "@.issued_configs[$_pii].installation_uuid" | tr -cd 'a-f0-9-' | cut -c1-36)
            _pio=$(jf "$_pia" "@.issued_configs[$_pii].os_version" | jline 32)
            _pic=$(jf "$_pia" "@.issued_configs[$_pii].server_country_name" | jline 48)
            _pik=$(jf "$_pia" "@.issued_configs[$_pii].source_type" | tr -cd 'a-z_' | cut -c1-24)
            _pil=$(iso_date_epoch "$(jf "$_pia" "@.issued_configs[$_pii].last_downloaded")") || _pil=0
            _pmeb=false; [ -n "$_pime" ] && [ "$_piu" = "$_pime" ] && _pmeb=true
            _pid="$_pid${_pid:+,}{\"id\":\"$_piu\",\"os\":\"$_pio\",\"country\":\"$_pic\",\"kind\":\"$_pik\",\"at\":$_pil,\"me\":$_pmeb}"
            _pii=$((_pii+1))
        done
        _piout="$_piout,\"devices\":[$_pid]"
        _pic2=""; _pii=0
        _pin=$(jf "$_pia" '@.available_countries[*].server_country_code' | wc -l)
        while [ "$_pii" -lt "$_pin" ] && [ "$_pii" -lt "$CNT_MAX" ]; do
            _pcc=$(jf "$_pia" "@.available_countries[$_pii].server_country_code" | tr -cd 'a-z0-9-' | cut -c1-16)
            _pcn=$(jf "$_pia" "@.available_countries[$_pii].server_country_name" | jline 48)
            _pcp=$(jf "$_pia" "@.available_countries[$_pii].available_protocols[*]" | grep -xE 'awg|vless' | awk '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }')
            cc_ok "$_pcc" && _pic2="$_pic2${_pic2:+,}{\"cc\":\"$_pcc\",\"name\":\"$_pcn\",\"p\":[$_pcp]}"
            _pii=$((_pii+1))
        done
        _piout="$_piout,\"countries\":[$_pic2]"
    else
        _piout="$_piout,\"have\":false"
    fi
    _pip=$(picks_of "$1" | awk -F"$TAB" '{ printf "%s{\"cc\":\"%s\",\"p\":\"%s\",\"name\":\"%s\"}", (NR > 1 ? "," : ""), $1, $2, $3 }')
    printf '%s,"picks":[%s]}\n' "$_piout" "$_pip"
}
cmd_status() {
    _pss=$(cat "$ST" 2>/dev/null)
    case "$_pss" in
        '{"state":"running",'*)
            if ! busy; then
                _pss=$(cat "$ST" 2>/dev/null)
                case "$_pss" in '{"state":"running",'*)
                    _pss=$(printf '%s\n' "$_pss" | sed 's/^{"state":"running",/{"state":"error",/; s/"msg":"[^"]*"/"msg":"работа прервалась — запустите её снова"/') ;;
                esac
            fi ;;
    esac
    case "$_pss" in '{'*'}') ;; *) _pss='{"state":"none"}' ;; esac
    printf '%s\n' "$_pss"
}

case "$1" in
    check)          cmd_check "$2" ;;
    account)        cmd_account "$2" ;;
    run-account)    run_account "$2" ;;
    pick)           cmd_pick "$2" "$3" "$4" ;;
    run-pick)       run_pick "$2" "$3" "$4" "$5" "$6" ;;
    unpick)         cmd_unpick "$2" "$3" "$4" ;;
    refresh)        cmd_refresh "$2" "$3" ;;
    busy)           busy ;;                        # code 0 — a job runs now (subs-update.sh drop asks before removing a key)
    is)             name_parts "$2" ;;             # code 0 — a server of an Amnezia Premium subscription (the watchdog's return home)
    revoke)         cmd_revoke "$2" "$3" ;;
    run-revoke)     run_revoke "$2" "$3" ;;
    drop)           cmd_drop "$2" "$3" ;;
    run-revoke-own) run_revoke_own "$2" ;;
    update)         cmd_update "$2" ;;
    info)           cmd_info "$2" ;;
    status)         cmd_status ;;
    *) echo "usage: premium.sh check <file> | account <tag> | pick|unpick <tag> <cc> <awg|vless> | refresh <name> [auto] | busy | revoke <tag> <uuid> | info <tag> | status | update <tag> | drop <tag> <kept>" >&2
       exit 1 ;;
esac
