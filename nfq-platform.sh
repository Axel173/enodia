#!/bin/sh
# Exact-firmware NFQUEUE support packages. Native routers continue using zapret.sh's native probe.
# Data bundles travel inside the signed code package; the binary store is written by an install — the Zapret component's, or
# zapret.sh rebuilding a cache a storage move lost (usb-offload.sh carries files, not this directory).
# Keep the complete stock extension directory visible to every iptables reader while new rules exist.
# No global acceleration switch where a per-flow one exists: raw CT opts only selected TCP443 flows out of vendor ECM. A newer ECM
# with no such package gets the one global knob it has (ecm-hold, below), held only while our queues are wired.
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
[ ! -f "$ENODIA_DIR/ipt-lib.sh" ] || . "$ENODIA_DIR/ipt-lib.sh"
# Free space and the flash reserve have one owner (C50): a raw `df` field read busybox's wrapped line as «50%».
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
KM_CATALOG="$ENODIA_DIR/nfq-kmods.txt"
KM_STORE="$ENODIA_BIN/nfq-kmods"
# The person's INTENT («the Zapret component's kernel package is installed») lives with the settings, not with the cache: a move
# to a drive carries files, not the cache directory (usb-offload.sh), and the cache is derived data — rebuilt from the signed
# bundle in the code dir by `prepare` whenever the intent says so. A nfqws the PC bootstrap put alone is no intent.
KM_INTENT="$ENODIA_STATE/.nfq-kmods"
KM_RUN=/tmp/enodia-nfq-platform
KM_LOCK=/tmp/enodia-nfq-platform.lock
KM_CHAIN=ENODIA_NFQ_RAW
KM_FILES="nfnetlink_queue.ko xt_NFQUEUE.ko iptable_raw.ko xt_CT.ko enodia_noflow.ko libxt_NFQUEUE.so libxt_CT.so"
KM_MODULES="nfnetlink_queue xt_NFQUEUE iptable_raw xt_CT enodia_noflow"
# ECM's slow-path allowance (measured on BE7000 30.10.2026, dev notes «AX3600-NFQUEUE» §ECM): its PPE takes a WIRED client's flow
# to the fast path before the ClientHello — NFQUEUE got SYN, SYN-ACK and ACK and never the ClientHello (3/3, the router's own wired
# client too), so every desync consumer did nothing for wired clients while Wi-Fi ones were fine. The default classifier keeps
# each TCP/UDP flow on the slow path until it has seen this many packets — ONE count over both directions
# (ecm_front_end_get_slow_packet_count) — stock 0, not kept over a reboot. 8 already let the ClientHello through; 20 kept the whole
# queue window with the 10-MB download as fast. GLOBAL (every flow's first packets) ⇒ held only while one of OUR queues is wired —
# the stock's own NFQUEUE (mipctld, `--queue-balance`) is not ours to serve. AX3600's older ECM has no such file (enodia_noflow
# does it there per flow). The delay must cover twice the widest queue window (zapret.sh CB), our queues are zapret.sh QNUM: C148.
KM_ECM=/sys/kernel/debug/ecm/ecm_classifier_default/accel_delay_pkts
KM_ECM_DELAY=20
KM_QUEUES=212
km_log() { km_last=$*; echo "[nfq-platform] $*" >&2; }   # km_last: a failed rebuild repeats its reason (km_prepare)
# /tmp is shared with the stock's daemons, some of them `nobody`: an entry another uid made is not ours — a planted lock would
# hold every teardown off, a planted run dir would let its owner swap the extensions we bind-mount for root's iptables and forge
# the verdicts kept there. No `id` (never seen) — no ownership to compare, as before.
KM_UID=$(id -u 2>/dev/null)
km_mine() { [ -e "$1" ] && [ ! -L "$1" ] && { [ -z "$KM_UID" ] || [ "$(stat -c %u "$1" 2>/dev/null)" = "$KM_UID" ]; }; }
km_run_ok() {
    if [ -e "$KM_RUN" ] || [ -L "$KM_RUN" ]; then
        { km_mine "$KM_RUN" && [ -d "$KM_RUN" ]; } || rm -rf "$KM_RUN" 2>/dev/null
    fi
    [ -d "$KM_RUN" ] || mkdir "$KM_RUN" 2>/dev/null
    chmod 700 "$KM_RUN" 2>/dev/null && km_mine "$KM_RUN" && [ -d "$KM_RUN" ]
}
km_memo_put() {   # $1 = file in KM_RUN, $2 = line
    km_run_ok && printf '%s\n' "$2" > "$KM_RUN/$1.$$" && mv "$KM_RUN/$1.$$" "$KM_RUN/$1"
}
km_sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1; exit}'
    else
        openssl dgst -sha256 "$1" 2>/dev/null | sed 's/.*= *//'
    fi
}
km_profile() {
    [ -s "$KM_CATALOG" ] || return 1
    km_machine=$(uname -m); km_release=$(uname -r)
    km_hardware=$(sed -n "s/.*option HARDWARE '\([^']*\)'.*/\1/p" /usr/share/xiaoqiang/xiaoqiang_version 2>/dev/null)
    km_rom=$(sed -n "s/.*option ROM '\([^']*\)'.*/\1/p" /usr/share/xiaoqiang/xiaoqiang_version 2>/dev/null)
    km_cheap="$km_machine:$km_hardware:$km_rom:$km_release"
    # No row for this model and ROM at all (every native router): no hashing, no state in /tmp.
    awk -F'|' -v c="$km_cheap" '$1 !~ /^#/ && ($2 ":" $3 ":" $4 ":" $5) == c {f = 1} END {exit !f}' "$KM_CATALOG" || return 1
    # The hashed files cannot change within a boot (squashfs, the running kernel), so the verdict is kept in our RAM dir per boot,
    # catalog and the fields above: the panel's status poll asked every 10 s — 41 openssl runs per poll on AX3600.
    km_key="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)|$(stat -c '%Y:%s' "$KM_CATALOG" 2>/dev/null)|$km_cheap"
    km_memo=''
    if km_run_ok; then km_memo=$(awk -v k="$km_key" '$1 == k {print $2; exit}' "$KM_RUN/profile" 2>/dev/null); fi
    [ "$km_memo" != - ] || return 1
    while IFS='|' read -r KM_ID km_m km_h km_r km_k km_v km_c km_x km_l km_t KM_HASH KM_BYTES KM_SUMHASH; do
        case "$KM_ID" in ''|'#'*) continue ;; *[!a-z0-9.-]*) continue ;; esac
        if [ -n "$km_memo" ]; then
            [ "$KM_ID" = "$km_memo" ] || continue
        else
            [ "$km_cheap" = "$km_m:$km_h:$km_r:$km_k" ] || continue
            [ "$(uname -v | openssl dgst -sha256 2>/dev/null | sed 's/.*= *//')" = "$km_v" ] || continue
            [ "$(km_sha /proc/config.gz)" = "$km_c" ] || continue
            [ "$(km_sha "/lib/modules/$km_release/x_tables.ko")" = "$km_x" ] || continue
            [ "$(km_sha /lib/libc.so)" = "$km_l" ] || continue
            [ "$(km_sha /usr/lib/libxtables.so.12)" = "$km_t" ] || continue
        fi
        [ "${#KM_HASH}:${#KM_SUMHASH}" = 64:64 ] || continue
        KM_CACHE="$KM_STORE/$KM_ID"
        KM_BUNDLE="$ENODIA_DIR/nfq-kmods/$KM_ID.tar.gz"
        [ -n "$km_memo" ] || km_memo_put profile "$km_key $KM_ID"
        return 0
    done < "$KM_CATALOG"
    [ -n "$km_memo" ] || km_memo_put profile "$km_key -"
    return 1
}
# The cache's verified bytes are kept per boot the same way, keyed by the files' identity (inode, mtime, size): an install replaces
# the directory, a damaged file changes its size or time, and either is verified again.
km_cache_ok() {
    km_sig="$km_key|$KM_ID|$(stat -c '%i:%Y:%s' "$KM_CACHE" "$KM_CACHE"/* 2>/dev/null | tr '\n' ' ')"
    km_run_ok && [ "$(cat "$KM_RUN/verified" 2>/dev/null)" = "$km_sig" ] && return 0
    km_verify "$KM_CACHE" || return 1
    km_memo_put verified "$km_sig"
    return 0
}
km_verify() {
    [ "$(km_sha "$1/SHA256SUMS")" = "$KM_SUMHASH" ] || return 1
    for km_f in $KM_FILES; do
        [ -f "$1/$km_f" ] && [ ! -L "$1/$km_f" ] || return 1
        km_want=$(awk -v n="$km_f" '$2==n {print $1}' "$1/SHA256SUMS")
        [ "${#km_want}" = 64 ] && [ "$(km_sha "$1/$km_f")" = "$km_want" ] || return 1
    done
}
km_mounted() { awk '$5=="/usr/lib/iptables" {f=1} END{exit !f}' /proc/self/mountinfo; }
km_own_mount() {
    km_mounted && [ -d "$KM_RUN/xt" ] &&
        [ "$(stat -c '%d:%i' "$KM_RUN/xt")" = "$(stat -c '%d:%i' /usr/lib/iptables)" ]
}
km_unlock() {
    km_result=$?
    trap - EXIT INT TERM HUP PIPE
    if [ -n "${km_tmp:-}" ]; then rm -rf "$km_tmp"; fi
    if [ -n "${km_new:-}" ]; then rm -rf "$km_new"; fi
    if [ -n "${km_old:-}" ] && [ -d "$km_old" ]; then
        if [ -d "$KM_CACHE" ]; then rm -rf "$km_old"; else mv "$km_old" "$KM_CACHE" || km_result=1; fi
    fi
    rm -f "$KM_LOCK/pid"; rmdir "$KM_LOCK" 2>/dev/null
    exit "$km_result"
}
km_lock() {   # $1 = looks before giving up (a second each; default 25)
    km_wait=0; km_nopid=0
    until mkdir "$KM_LOCK" 2>/dev/null; do
        # ONE look at the owner: a lock gone since the failed mkdir is a hand-off, not a plant — removing «what is there now» would
        # remove the next root holder's lock and let two of us in.
        # A lock still there that stat cannot read (no applet) counts as ours: the safe side waits, it never removes a live holder.
        km_u=$(stat -c %u "$KM_LOCK" 2>/dev/null) || { [ -e "$KM_LOCK" ] || [ -L "$KM_LOCK" ] || continue; km_u=$KM_UID; }
        if [ ! -L "$KM_LOCK" ] && { [ -z "$KM_UID" ] || [ "$km_u" = "$KM_UID" ]; }; then
            km_pid=$(cat "$KM_LOCK/pid" 2>/dev/null)
            case "$km_pid" in
                ''|*[!0-9]*)
                    # A holder writes its pid right after its mkdir: none for three looks is a holder killed in between (or one on a
                    # full /tmp, which fails its own writes anyway). Left alone it held every later caller — since the ECM knob, the
                    # watchdog's tick and an uninstall too. Falls through to the count: a lock that will not go cannot spin us.
                    km_nopid=$((km_nopid+1))
                    if [ "$km_nopid" -ge 3 ]; then rm -f "$KM_LOCK/pid"; rmdir "$KM_LOCK" 2>/dev/null; km_nopid=0; fi ;;
                *)  km_nopid=0
                    if ! kill -0 "$km_pid" 2>/dev/null; then rm -f "$KM_LOCK/pid"; rmdir "$KM_LOCK" 2>/dev/null; continue; fi ;;
            esac
        else
            rm -rf "$KM_LOCK" 2>/dev/null   # planted by another uid (see km_mine); counted below, so a re-planter cannot spin us
        fi
        km_wait=$((km_wait+1)); [ "$km_wait" -lt "${1:-25}" ] || { km_log 'операция уже выполняется'; return 1; }
        sleep 1
    done
    echo $$ > "$KM_LOCK/pid"
    trap km_unlock EXIT
    trap 'exit 1' INT TERM HUP PIPE
    km_run_ok
}
km_install() {
    km_profile || { km_log 'нет проверенного пакета для этой прошивки'; return 1; }
    km_cache_ok && { printf '%s\n' "$KM_ID" > "$KM_INTENT" 2>/dev/null; return 0; }
    [ "$(km_sha "$KM_BUNDLE")" = "$KM_HASH" ] || { km_log 'пакет модулей повреждён'; return 1; }
    if km_mounted; then
        km_own_mount && [ "$(cat "$KM_RUN/active" 2>/dev/null)" = "$KM_ID:$KM_HASH" ] || {
            km_log 'сначала отключите Zapret перед заменой работающего пакета'; return 1;
        }
    fi
    command -v fs_free_b >/dev/null 2>&1 || { km_log 'нет store-lib.sh — обновите скрипты'; return 1; }
    km_free=$(fs_free_b "$KM_STORE")
    [ "$km_free" -ge "$((KM_BYTES+DATA_RESERVE_B))" ] || { km_log 'не хватает места с резервом 2,5 МиБ'; return 1; }
    mkdir -p "$KM_STORE" || return 1
    km_tmp=$(mktemp -d /tmp/enodia-nfq-install.XXXXXX) || return 1
    tar -tzf "$KM_BUNDLE" | sort > "$km_tmp/members"
    printf '%s\n' $KM_FILES SHA256SUMS | sort > "$km_tmp/expected"
    if ! cmp -s "$km_tmp/members" "$km_tmp/expected" || ! tar -xzf "$KM_BUNDLE" -C "$km_tmp" || ! km_verify "$km_tmp"; then
        rm -rf "$km_tmp"; km_log 'состав или контрольные суммы пакета неверны'; return 1
    fi
    km_new="$KM_STORE/.new.$$"; km_old="$KM_STORE/.old.$$"
    mkdir "$km_new" || { rm -rf "$km_tmp"; return 1; }
    for km_f in $KM_FILES SHA256SUMS; do
        cp "$km_tmp/$km_f" "$km_new/$km_f" || { rm -rf "$km_tmp" "$km_new"; return 1; }
    done
    rm -rf "$km_tmp"
    km_verify "$km_new" || { rm -rf "$km_new"; return 1; }
    [ ! -e "$KM_CACHE" ] || mv "$KM_CACHE" "$km_old" || { rm -rf "$km_new"; return 1; }
    if ! mv "$km_new" "$KM_CACHE"; then
        [ ! -d "$km_old" ] || mv "$km_old" "$KM_CACHE"
        rm -rf "$km_new"; return 1
    fi
    [ ! -d "$km_old" ] || rm -rf "$km_old"
    printf '%s\n' "$KM_ID" > "$KM_INTENT" 2>/dev/null
    km_log "пакет $KM_ID установлен"
}
# «Will Zapret's kernel side come up here»: nothing to do on a native kernel; else a verified cache, or the intent and the bundle
# to rebuild it from (the bundle is verified by the rebuild itself).
km_ready() {
    km_profile || return 0
    km_cache_ok || { [ -f "$KM_INTENT" ] && [ -s "$KM_BUNDLE" ]; }
}
km_prepare() {
    km_profile || return 0
    if km_cache_ok; then
        [ -f "$KM_INTENT" ] || printf '%s\n' "$KM_ID" > "$KM_INTENT" 2>/dev/null   # an install older than the intent file
    else
        # With the intent the component IS installed (Components says so): callers show the LAST line, so it carries the failed
        # rebuild's own reason (space, a damaged bundle), and the advice to install is said only without the intent.
        [ -f "$KM_INTENT" ] || { km_log 'установите пакет поддержки в компонентах Zapret'; return 1; }
        km_last=""
        km_install || { km_log "пакет поддержки ядра не восстановлен${km_last:+: $km_last}"; return 1; }
    fi
    if km_mounted; then
        km_own_mount && [ "$(cat "$KM_RUN/active" 2>/dev/null)" = "$KM_ID:$KM_HASH" ] || return 1
    else
        [ ! -e /usr/lib/iptables/libxt_NFQUEUE.so ] && [ ! -e /usr/lib/iptables/libxt_CT.so ] || {
            km_log 'сторонние расширения iptables: автоматическая замена запрещена'; return 1;
        }
        rm -rf "$KM_RUN/xt"
        mkdir "$KM_RUN/xt" || return 1
        (cd /usr/lib/iptables && md5sum *.so) > "$KM_RUN/stock.md5" || return 1
        cp -a /usr/lib/iptables/. "$KM_RUN/xt/" || return 1
        cp "$KM_CACHE/libxt_NFQUEUE.so" "$KM_CACHE/libxt_CT.so" "$KM_RUN/xt/" || return 1
        echo "$KM_ID:$KM_HASH" > "$KM_RUN/active"
        mount -o bind "$KM_RUN/xt" /usr/lib/iptables || return 1
    fi
    for km_mod in $KM_MODULES; do
        if ! grep -q "^$km_mod " /proc/modules; then
            insmod "$KM_CACHE/$km_mod.ko" || return 1
            echo "$km_mod" >> "$KM_RUN/owned.modules"
        fi
    done
    iptables-save >/dev/null && ip6tables-save >/dev/null
}
km_raw_gc() {
    iptables -t raw -S "$KM_CHAIN" >/dev/null 2>&1 || return 0
    if ! iptables -t raw -S "$KM_CHAIN" | grep -q '^-A'; then
        while iptables -t raw -D PREROUTING -i br+ -p tcp --dport 443 -j "$KM_CHAIN" 2>/dev/null; do :; done
        iptables -t raw -X "$KM_CHAIN"
    fi
}
km_sources() {
    km_profile || return 0
    # Reconciliation must also find a raw selector left before its mangle peer was installed.
    iptables -t raw -S "$KM_CHAIN" 2>/dev/null |
        grep -- '--helper enodia_noflow' |
        sed -n 's/.* -s \([0-9.]*\)\(\/32\)\{0,1\} .*/\1/p' | sort -u
}
km_wire() {
    km_profile || return 0
    case "$2" in add|del) : ;; *) return 1 ;; esac
    case "$1:$3" in set:*)
        case "$3" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
        set -- "$2" -p tcp -m set --match-set "$3" dst -j CT --helper enodia_noflow ;;
    src:*)
        echo "$3" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/32)?$' || return 1
        set -- "$2" -p tcp -s "$3" -j CT --helper enodia_noflow ;;
    *) return 1 ;;
    esac
    km_action=$1; shift
    if [ "$km_action" = del ]; then
        grep -q '^iptable_raw ' /proc/modules || return 0
        while iptables -t raw -D "$KM_CHAIN" "$@" 2>/dev/null; do :; done
        km_raw_gc
    else
        km_prepare || return 1
        iptables -t raw -S "$KM_CHAIN" >/dev/null 2>&1 || iptables -t raw -N "$KM_CHAIN" || return 1
        iptables -t raw -C PREROUTING -i br+ -p tcp --dport 443 -j "$KM_CHAIN" 2>/dev/null ||
            iptables -t raw -I PREROUTING 1 -i br+ -p tcp --dport 443 -j "$KM_CHAIN" || return 1
        iptables -t raw -C "$KM_CHAIN" "$@" 2>/dev/null || iptables -t raw -A "$KM_CHAIN" "$@"
    fi
}
# Stock fw3 assigns conntrack helpers (FTP, SIP, PPTP…) in the raw table only when the kernel has the CT target — on stock AX3600
# that is OUR xt_CT (and our libxt_CT.so): a `fw3 reload` (any change in Xiaomi's web UI) while Zapret runs adds zone_*_helper
# chains with `-j CT --helper ftp|sip|…` (measured 19.10.2026, 1.1.21). They are our side effect, not the stock's state, and they
# hold xt_CT, iptable_raw and the mount: release kept everything and `remove` (the component, purge) refused until a reboot. Once
# our own consumers are gone and xt_CT is ours, they go first; the next fw3 reload without our modules does not add them back.
# By rule NUMBER: the jump carries fw3's quoted comment, and re-reading a rule through eval would run whatever that text holds.
km_fw3_helpers_drop() {   # $1 = iptables | ip6tables
    [ -f "$KM_RUN/owned.modules" ] && grep -qx xt_CT "$KM_RUN/owned.modules" || return 0
    for km_hc in $("$1" -t raw -S 2>/dev/null | sed -n 's/^-N \(zone_[A-Za-z0-9_]*_helper\)$/\1/p'); do
        for km_hp in PREROUTING OUTPUT; do
            for km_hn in $("$1" -t raw -L "$km_hp" -n --line-numbers 2>/dev/null | awk -v c="$km_hc" '($2 "") == (c "") {print $1}' | sort -rn); do
                "$1" -t raw -D "$km_hp" "$km_hn" || return 1
            done
        done
        "$1" -t raw -F "$km_hc" && "$1" -t raw -X "$km_hc" || return 1
    done
}
# Raised AFTER the queue rule is in, given back by the FACT, both under the lock: a give reads the rules and writes the knob in one
# hold of it, so a wire's raise, coming after its rule, either finds that rule already seen (kept) or comes after the write (raises
# again). Raised before the rule, a give in between lowered the knob under a live queue. Only a value this owner raised is given
# back, and only while the knob still holds it — a value set since is not ours. The memo (RAM, like the knob) is «<found> <raised>»:
# the raised value, not today's KM_ECM_DELAY, says «still ours» — an update that changes the delay under a live queue must read our
# own old raise as ours, or the give would put back 20 instead of the stock 0.
# Three callers: zapret.sh's bricks (`ecm-hold`, as they wire), `release` (the give, as a consumer goes) and the watchdog's tick
# (`ecm-sync`, both ways by the fact) — the knob is debugfs, an ECM reload resets it, and an intent-gated teardown skips release.
km_ecm_now() {
    km_now=$(cat "$KM_ECM" 2>/dev/null)
    case "$km_now" in ''|*[!0-9]*) km_log 'задержка ускорения ECM не читается'; return 1 ;; esac
}
km_ecm_memo() {   # → km_found, km_raised (empty: no memo, or not ours to read)
    km_found=''; km_raised=''
    km_mine "$KM_RUN" && [ -f "$KM_RUN/ecm" ] || return 1
    read -r km_found km_raised < "$KM_RUN/ecm" 2>/dev/null
    case "$km_found" in ''|*[!0-9]*) km_found=0 ;; esac
    case "$km_raised" in ''|*[!0-9]*) km_raised=$KM_ECM_DELAY ;; esac
}
# 0 — a queue of ours is wired, 1 — none, 2 — the rules did not read (unread is not empty: it would lower the knob under a queue).
# Read where our queues live: zapret.sh queues IPv4 only (C148 refuses an ip6tables queue there), and a failing IPv6 dump (no IPv6
# mangle on some build) held the knob up for good. A consumer that queues IPv6 brings its family here. zapret.sh's capability
# probe (chain ENODIA_NFQ_PROBE, never jumped to) queues nothing — not ours to serve.
km_ecm_queued() {
    km_r4=$(iptables-save -t mangle 2>/dev/null) || { km_log 'правила не читаются — задержка ECM не тронута'; return 2; }
    km_qre=$(echo $KM_QUEUES | sed 's/ /|/g')
    printf '%s\n' "$km_r4" | grep -v '^-A ENODIA_NFQ_PROBE ' |
        grep -E -- "-j NFQUEUE --queue-num ($km_qre)( |\$)" >/dev/null   # not `-q`: C134
}
# Anything of the kernel package set up this boot. Without it the knob is all this owner holds here.
km_pkg_live() { [ -d "$KM_RUN/xt" ] || [ -f "$KM_RUN/active" ] || [ -f "$KM_RUN/owned.modules" ]; }
km_ecm_hold() {
    km_ecm_now || return 1
    [ "$km_now" -lt "$KM_ECM_DELAY" ] || return 0
    # The found value is kept first — a raise without it is one nobody gives back — and by EVERY raise: a value below ours is never
    # ours (the knob was reset since, or someone set it), and the give must put back that one, not the first boot's. Except our own
    # earlier raise (a smaller delay before an update): that one keeps the value it found.
    km_ecm_memo; km_f=$km_now
    [ -z "$km_raised" ] || [ "$km_now" != "$km_raised" ] || km_f=$km_found
    km_memo_put ecm "$km_f $KM_ECM_DELAY" || { km_log 'задержка ускорения ECM не поднята: нет места в /tmp'; return 1; }
    # A memo of a raise that did not happen would read as «ours, reset from outside»: it goes with the failed write.
    echo "$KM_ECM_DELAY" > "$KM_ECM" || {
        rm -f "$KM_RUN/ecm"; km_log 'задержка ускорения ECM не поднята — проводные клиенты останутся без десинка'; return 1;
    }
}
# The fact said «no queue of ours»: put back the value found, if the knob still holds our raise.
km_ecm_back() {
    km_gave=''
    km_ecm_memo || return 0
    km_was=$km_found
    if [ "$km_now" = "$km_raised" ]; then
        echo "$km_was" > "$KM_ECM" || { km_log 'задержка ускорения ECM не возвращена'; return 1; }
        km_gave=1
    fi
    rm -f "$KM_RUN/ecm"
}
km_ecm_give() {
    [ -f "$KM_ECM" ] && [ -f "$KM_RUN/ecm" ] || return 0
    km_ecm_now || return 1
    km_ecm_queued; case $? in 0) return 0 ;; 2) return 1 ;; esac
    km_ecm_back
}
# The tick's look: a line when it changed the knob (a heal worth the watchdog's log) or could not (the dispatcher says that once
# an episode).
km_ecm_sync() {
    km_ecm_now || return 1
    km_ecm_queued; case $? in
        0) [ "$km_now" -lt "$KM_ECM_DELAY" ] || return 0
           km_ecm_hold && km_log "задержка ускорения ECM была $km_now при живой очереди десинка — поднята до $KM_ECM_DELAY" ;;
        1) [ -f "$KM_RUN/ecm" ] || return 0
           km_ecm_back || return 1
           [ -z "$km_gave" ] || km_log "очередей десинка нет — задержка ускорения ECM возвращена к $km_was" ;;
        *) return 1 ;;
    esac
}
km_release() {
    [ -d "$KM_RUN" ] || return 0
    # Its own resource: a knob not given back stops no package release (km_ecm_give logs its own reason).
    km_ecm_give || :
    # Nothing of the kernel package was set up this boot (a router that only has the ECM knob; AX3600 before Zapret's first prepare):
    # nothing more to release — someone else's /usr/lib/iptables mount or a full /tmp is no reason to fail an uninstall there.
    km_pkg_live || return 0
    if km_mounted && ! km_own_mount; then km_log 'чужое монтирование iptables оставлено'; return 1; fi
    if km_own_mount; then
        iptables-save > "$KM_RUN/rules.v4" && ip6tables-save > "$KM_RUN/rules.v6" || return 1
        # Our consumers first (queues, our helper): while they live, fw3's helpers are no business of ours either.
        if ! grep -qE ' -j NFQUEUE( |$)| --helper enodia_noflow( |$)' "$KM_RUN/rules.v4" "$KM_RUN/rules.v6"; then
            km_fw3_helpers_drop iptables && km_fw3_helpers_drop ip6tables || return 1
            iptables-save > "$KM_RUN/rules.v4" && ip6tables-save > "$KM_RUN/rules.v6" || return 1
        fi
        if grep -qE ' -j (NFQUEUE|CT)( |$)' "$KM_RUN/rules.v4" "$KM_RUN/rules.v6"; then
            km_log 'правила ещё используют расширения: ресурсы оставлены'; return 0
        fi
        # An iptables run of someone else holds the mount busy for a moment: a lazy unmount detaches it now and lets that run end.
        umount /usr/lib/iptables 2>/dev/null || umount -l /usr/lib/iptables || return 1
        (cd /usr/lib/iptables && md5sum -c "$KM_RUN/stock.md5") >/dev/null || return 1
        rm -rf "$KM_RUN/xt"
        rm -f "$KM_RUN/active"
    fi
    # Modules already present before our first prepare do not belong to this manager.
    : > "$KM_RUN/owned.next"
    for km_mod in enodia_noflow xt_CT iptable_raw xt_NFQUEUE nfnetlink_queue; do
        [ -f "$KM_RUN/owned.modules" ] && grep -qx "$km_mod" "$KM_RUN/owned.modules" || continue
        grep -q "^$km_mod " /proc/modules || continue
        if ! rmmod "$km_mod" 2>/dev/null; then
            km_log "$km_mod ещё используется, выгрузка отложена"
            echo "$km_mod" >> "$KM_RUN/owned.next"
        fi
    done
    mv "$KM_RUN/owned.next" "$KM_RUN/owned.modules"
}

case "$1" in
    supported) km_profile ;;
    installed) km_profile && km_cache_ok ;;
    ready) km_ready ;;
    profile) km_profile && echo "$KM_ID" ;;
    sources) km_sources ;;
    bytes-needed) if km_profile && ! km_cache_ok; then echo "$KM_BYTES"; else echo 0; fi ;;
    bytes-installed) if [ -d "$KM_STORE" ]; then du -sk "$KM_STORE" | awk '{print $1*1024}'; else echo 0; fi ;;
    # For the status screen: the knob, and the value it had before we raised it. Nothing where the knob does not exist.
    ecm) [ -f "$KM_ECM" ] || exit 0
        km_v=$(cat "$KM_ECM" 2>/dev/null); km_v=${km_v:-не читается}
        if ! km_ecm_memo; then echo "$km_v"
        elif [ "$km_v" = "$km_raised" ]; then echo "$km_v (поднято нами, было $km_found)"
        else echo "$km_v (наш подъём до $km_raised изменён извне, было $km_found)"; fi ;;
    install|prepare|wire-set|wire-src|ecm-hold|ecm-sync|release|remove)
        # A router this owner does not serve (every native kernel without the ECM knob) takes no lock and leaves nothing in /tmp.
        case "$1" in
            prepare|wire-set|wire-src) km_profile || exit 0 ;;
            ecm-hold|ecm-sync) [ -f "$KM_ECM" ] || exit 0 ;;
            release) [ -d "$KM_RUN" ] || exit 0 ;;
            remove) [ -d "$KM_RUN" ] || [ -e "$KM_STORE" ] || [ -e "$KM_INTENT" ] || exit 0 ;;
        esac
        # The tick does not wait out another operation: the next tick looks again (a held tick delays the whole watchdog). Where the
        # knob is all this owner holds, a lock held for good (its holder killed, the pid reused) must not fail a teardown or an
        # uninstall either: the knob goes back by the fact on a later look.
        if [ "$1" = ecm-sync ]; then km_lock 2 2>/dev/null || exit 0
        elif { [ "$1" = release ] || [ "$1" = remove ]; } && ! km_pkg_live && [ ! -e "$KM_STORE" ] && [ ! -e "$KM_INTENT" ]; then
            km_lock || exit 0
        else km_lock || exit 1; fi
        case "$1" in
            install) km_install ;;
            prepare) km_prepare || { km_release; exit 1; } ;;
            wire-set) km_wire set "$3" "$2" ;;
            wire-src) km_wire src "$3" "$2" ;;
            ecm-hold) km_ecm_hold ;;
            ecm-sync)
                # A failure says its reason once an episode: the tick asks every 2 minutes, its log in RAM is rotated by nobody. A
                # good look ends the episode. Into a file of ours, not `$(…)`: a subshell would not be this lock's holder.
                km_ecm_sync 2> "$KM_RUN/ecm.out"; km_rc=$?
                if [ "$km_rc" = 0 ]; then rm -f "$KM_RUN/ecm.fail"; cat "$KM_RUN/ecm.out" >&2
                elif [ ! -f "$KM_RUN/ecm.fail" ]; then : > "$KM_RUN/ecm.fail"; cat "$KM_RUN/ecm.out" >&2; fi
                rm -f "$KM_RUN/ecm.out"
                exit "$km_rc" ;;
            release) km_release ;;
            remove)
                if km_own_mount; then
                    iptables-save > "$KM_RUN/rules.v4" && ip6tables-save > "$KM_RUN/rules.v6" || exit 1
                    if grep -qE ' -j NFQUEUE( |$)' "$KM_RUN/rules.v4" "$KM_RUN/rules.v6"; then
                        km_log 'очереди ещё используются'; exit 1
                    fi
                    # With no packet consumer, any remaining selectors in our chain are interrupted adds.
                    if iptables -t raw -S "$KM_CHAIN" >/dev/null 2>&1; then
                        iptables -t raw -F "$KM_CHAIN" && km_raw_gc || exit 1
                    fi
                fi
                km_release || exit 1
                km_own_mount && { km_log 'пакет используется'; exit 1; }
                for km_mod in $KM_MODULES; do
                    if [ -f "$KM_RUN/owned.modules" ] && grep -qx "$km_mod" "$KM_RUN/owned.modules" && grep -q "^$km_mod " /proc/modules; then exit 1; fi
                done
                rm -rf "$KM_STORE"; rm -f "$KM_INTENT" ;;
        esac ;;
    *) echo 'usage: nfq-platform.sh supported|installed|profile|sources|ecm|install|prepare|wire-set <set> add|del|wire-src <ip> add|del|ecm-hold|ecm-sync|release|remove' >&2; exit 2 ;;
esac
