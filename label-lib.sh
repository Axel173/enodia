#!/bin/sh
# label-lib.sh — ОБЩЕЕ ХРАНИЛИЩЕ «КЛЮЧ ⇥ СВОЁ ИМЯ» для меток панели. Сорсится, сам ничего не делает.
#
# ЗАЧЕМ. Меток у панели две, и механика у них одна: свои имена УСТРОЙСТВ (dev-names.sh, ключ — MAC) и свои имена КОНФИГОВ
# (cfg-names.sh, ключ — «вид/имя файла»: в имя файла роутер кладёт только [A-Za-z0-9_.-], а человек назвал сервер
# «Frankfurt 🇩🇪 vps»). Каждая метка — read-modify-write целого файла несколькими писателями (две вкладки панели), и каждая
# отдаётся в JSON всего списка, где один управляющий байт из руками правленного файла ронял весь экран (ревью 27.09.2026).
# Вторая копия этой механики разошлась бы с первой на первой же правке — владелец один.
#
# Контракт вызывающего: определить `pid_runs` (daemon-lib.sh или его шим) — лок судит держателя по /proc.
#   lbl_lock_take <лок-каталог> <регулярка cmdline держателя> — 0 взяли, 1 не взяли за 5 с
#   lbl_lock_drop <лок-каталог>
#   lbl_san <текст>                                  — имя человека → строка персиста (stdout)
#   lbl_list <файл> <регулярка ключа> [lower]         — ЕДИНСТВЕННЫЙ разбор: `ключ⇥имя` построчно, ключ — первый на строку
#   lbl_write <файл> <ключ> <имя|пусто> <регулярка ключа> [lower] — записать (пусто = снять), атомарно; 0 — записано
#   lbl_merge <файл> <файл-источник> <регулярка ключа> [lower]   — влить метки источника (у своего ключа побеждает источник)
#   lbl_import <файл> <файл-архива> <ключи привезённого> <регулярка ключа> — импорт бэкапа «по привезённому» (см. функцию)
# …and the project's ONLY «replace a file whole or not at all» (any file, not only labels — see the two functions at the end):
#   lbl_commit <file> <text>                — the text is in a variable; an empty text removes the file
#   lbl_commit_out <file> <command> [args…] — the command's output; an empty output is an empty file
#   lbl_commit_out_as <temp> <file> <command> [args…] — the same, the temp file named by the caller (a file outside our dirs)
#   lbl_grep <grep args…>                   — grep for lbl_commit_out: «nothing selected» is not a failure
#   lbl_without <file> <pattern> [line]     — a producer: the file without the pattern's lines, then the line
LBL_TAB=$(printf '\t')
LBL_CFG_KEY_RE='^(awg|xray|hy2)/[A-Za-z0-9_.-]+$'
lbl_cfg_key() {
    case "$1" in *"$LBL_NL"*) return 1 ;; esac
    printf '%s' "$1" | grep -qE "$LBL_CFG_KEY_RE"
}
lbl_endpoint_key() { sed -n 's/^key=//p' "$@" 2>/dev/null; }
lbl_endpoint_hosts() { sed -n 's/^host=//p' "$@" 2>/dev/null; }
lbl_endpoint_ips() { sed '/^key=/d; /^host=/d' "$@" 2>/dev/null; }
LBL_NL='
'

XT_ROAD_LOCK=/tmp/enodia-xray-test.road
TRY_LOCK=/tmp/enodia-awg-try.lock
TRY_LOCK_HOLDERS='transport-awg\.sh|road\.sh'
LBL_CFG_NAMES_LOCK=/tmp/enodia-cfg-names.lock
LBL_FAV_LOCK=${FAV_LOCK:-/tmp/enodia-server-favs.lock}
LBL_CFG_NAMES_HOLDERS='cfg-names|subs-import\.sh'
LBL_FAV_HOLDERS='server-favs\.sh|subs-import\.sh'
lbl_lock_live() {   # A missing PID can be a holder still publishing it.
    _lp=$(cat "$1/pid" 2>/dev/null | tr -cd '0-9')
    [ -n "$_lp" ] || { sleep 1; _lp=$(cat "$1/pid" 2>/dev/null | tr -cd '0-9'); }
    pid_runs "$_lp" "$2"
}
lbl_rule_sweep() {
    _lrs_n=$(ip rule show 2>/dev/null | grep -c "^$1:")
    while [ "$_lrs_n" -gt 0 ] && ip rule del pref "$@" 2>/dev/null; do _lrs_n=$((_lrs_n - 1)); done
}

# Лок-КАТАЛОГ (mkdir атомарен) с ПИДом. Протух — если держателя нет: пид мёртв ИЛИ уже чужой (пиды переиспользуются, а лок в
# /tmp живёт до ребута), либо пида нет дольше, чем живой держатель пишет его (миг после mkdir): держатель умер между mkdir и
# echo. Судим по /proc, а не по возрасту (часы роутера прыгают, C24). Не взять за 5 с — отказ словами, а не тихая потеря правки.
lbl_lock_take() {   # lock, holder pattern, [owner PID for a nested operation]
    _lbli=0
    while ! mkdir "$1" 2>/dev/null; do
        _lbli=$((_lbli+1)); [ "$_lbli" -gt 5 ] && return 1
        _lblp=$(cat "$1/pid" 2>/dev/null | tr -d ' \r\n')
        if [ -n "$_lblp" ]; then
            pid_runs "$_lblp" "$2" || { rm -rf "$1" 2>/dev/null; continue; }
        elif [ "$_lbli" -ge 3 ]; then
            rm -rf "$1" 2>/dev/null; continue
        fi
        sleep 1
    done
    echo "${3:-$$}" > "$1/pid" 2>/dev/null || { lbl_lock_drop "$1"; return 1; }
}
lbl_lock_drop() { rm -rf "$1" 2>/dev/null; }

# Prepare a label removal beside the store. Publish only after the owner
# commits the operation the label belongs to.
lbl_stage_drop() {   # store, key, stage
    [ -e "$1" ] || return 0
    [ -f "$1" ] || return 1
    (umask 077; lbl_commit_out "$3" awk -F "$LBL_TAB" -v key="$2" '($1 "") != (key "")' "$1") || return 1
    if cmp -s "$1" "$3"; then rm -f "$3"; fi
}
lbl_publish_drop() {   # store, stage
    [ -f "$2" ] || return 0
    if [ -s "$2" ]; then mv -f "$2" "$1"; else rm -f "$1" "$2"; fi
}

# Имя человека → безопасная строка персиста: таб и переводы строки — в пробел (это разделители TSV, но человеку — пробел),
# прочие управляющие байты, кавычка и обратная косая — вон (JSON), пробелы по краям — вон, подряд идущие — в один.
lbl_san() { printf '%s' "$1" | tr '\t\r\n' '   ' | tr -d '\000-\037"\\' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g'; }

# ЕДИНСТВЕННЫЙ разбор персиста: управляющие байты, кроме таба и перевода строки, кавычку и косую — вон ещё до awk; ключ — без
# пробелов (и строчными, если просили) и только подходящий под регулярку; хвост полей (таб в имени) — пробелом; пустое имя —
# не метка; на ключ — первая строка.
lbl_list() {
    [ -f "$1" ] || return 0
    tr -d '\000-\010\013-\037"\\' < "$1" 2>/dev/null | awk -F"$LBL_TAB" -v kre="$2" -v low="${3:-}" '
    {
        m = $1; if (low != "") m = tolower(m); gsub(/ /, "", m)
        if (m !~ kre) next
        if (m in seen) next
        n = $2; for (i = 3; i <= NF; i++) n = n " " $i
        gsub(/  +/, " ", n); sub(/^ /, "", n); sub(/ $/, "", n)
        if (n == "") next
        seen[m] = 1; print m "\t" n
    }'
}

# Запись: прочие строки — через тот же разбор (руками правленный файл чинится заодно), своя — заменой; пустое имя — снять,
# пустой итог — файл снят. Временный файл сверяем с тем, что хотели записать (полный раздел обрезал бы его молча).
lbl_write() {
    _lblw=$(lbl_list "$1" "$4" "$5" | awk -F"$LBL_TAB" -v m="$2" '$1!=m')
    [ -n "$3" ] && _lblw="${_lblw:+$_lblw$LBL_NL}$2$LBL_TAB$3"
    lbl_commit "$1" "$_lblw"
}
# lbl_merge <файл> <файл-источник> <регулярка ключа> [lower] — влить метки источника (импорт бэкапа): у СВОЕГО ключа побеждает
# источник, прочие метки файла остаются. Оба — через тот же разбор.
lbl_merge() {
    _lblw=$( { lbl_list "$2" "$3" "$4"; lbl_list "$1" "$3" "$4"; } | awk -F"$LBL_TAB" '!($1 in s) { s[$1] = 1; print }')
    lbl_commit "$1" "$_lblw"
}
lbl_cfg_keys() {
    for _lcf in "$1"/configs/*.conf "$1"/xray-configs/*.json "$1"/hy2-configs/*.yaml; do
        [ -f "$_lcf" ] || continue
        _lcn=${_lcf##*/}
        case "$_lcf" in
            "$1"/configs/*) printf 'awg/%s\n' "${_lcn%.conf}" ;;
            "$1"/xray-configs/*) printf 'xray/%s\n' "${_lcn%.json}" ;;
            "$1"/hy2-configs/*) printf 'hy2/%s\n' "${_lcn%.yaml}" ;;
        esac
    done
}

# Backup import BY WHAT THE ARCHIVE BROUGHT ($3 — its keys, one per line): an archive line counts only for a key the archive
# brought (a line stuck in the archive would land on SOMEONE ELSE'S local file of the same name — review s.96, round 3); a
# local line of a key the archive brought is dropped even when the archive has none (it described the replaced file — the
# same review, round 2); other local lines stay. Owners: cfg-names.sh (config names) and road.sh (config roads). No lock here:
# the caller holds its own.
lbl_import() {   # store, archive file (may be absent), brought keys, key regex
    _lbia=""
    if [ -f "$2" ]; then
        while IFS= read -r _lbir || [ -n "$_lbir" ]; do
            [ -n "$_lbir" ] || continue
            case "$LBL_NL$3$LBL_NL" in *"$LBL_NL${_lbir%%"$LBL_TAB"*}$LBL_NL"*) _lbia="${_lbia:+$_lbia$LBL_NL}$_lbir" ;; esac
        done <<EOF
$(lbl_list "$2" "$4")
EOF
    fi
    _lbik=""
    while IFS= read -r _lbir || [ -n "$_lbir" ]; do
        [ -n "$_lbir" ] || continue
        case "$LBL_NL$3$LBL_NL" in *"$LBL_NL${_lbir%%"$LBL_TAB"*}$LBL_NL"*) continue ;; esac
        _lbik="${_lbik:+$_lbik$LBL_NL}$_lbir"
    done <<EOF
$(lbl_list "$1" "$4")
EOF
    lbl_commit "$1" "$(printf '%s\n%s\n' "$_lbia" "$_lbik" | awk -F"$LBL_TAB" 'NF >= 2 && !($1 in s) { s[$1] = 1; print }')"
}

# Записать готовое содержимое АТОМАРНО (пусто = файл снять). Временный файл сверяем с тем, что хотели записать: полный раздел
# обрезал бы его молча.
lbl_commit() {
    if [ -z "$2" ]; then rm -f "$1"; return $?; fi
    _lblt="$1.$$"
    if printf '%s\n' "$2" > "$_lblt" 2>/dev/null && [ "$(cat "$_lblt" 2>/dev/null)" = "$2" ]; then
        mv "$_lblt" "$1" && return 0
    fi
    rm -f "$_lblt"; return 1
}

# lbl_commit_out <file> <command> [args…] — THE COMMAND'S OUTPUT BECOMES THE FILE, WHOLE OR NOT AT ALL. The sibling of lbl_commit
# for a text that is not held in a variable (a filter over the file itself, a list of a hundred thousand lines); an empty output
# is an EMPTY FILE here — exactly what `cmd > tmp && mv tmp file` made, and that line is what this replaces.
# WHY IT EXISTS. `cmd > tmp && mv tmp file` rests on cmd's exit code, and BusyBox 1.25.1 applets write through stdio and never
# look at the result: on a partition with no free block awk, grep, sort, cut, uniq, base64 (and wc, md5sum, date, ls, tee…) EXIT 0
# with the temp file cut short — measured on BE7000 12.10.2026 (`awk … > /tmp-64k/a`: rc 0, 65536 of 820000 bytes), and the `&&`
# then puts the stump over the registry. cat, sed, tr, head, tail, printf, echo DO report it. So the bytes go to the file through
# `cat`, and BOTH codes are asked before the rename: the command's (it could not read, it was killed) and the sink's (the bytes
# did not land) — through fd 3, a pipe's own code is the sink's only. A sink that failed drains its input: the command must not
# get EPIPE and say so into a CGI's answer (uhttpd starts us with SIGPIPE ignored).
# The command may be a shell function (a pipe inside it is judged by its last link, as a pipe always was); its stdin and stderr
# are the caller's. A grep whose «nothing selected» is an answer, not a failure — lbl_grep.
# The project's check for the class — dev/blind-write-scan.py (the tool table is there).
# The temp file is `<file>.<pid>.new` — next to the file (the rename stays inside one filesystem), the pid keeps two writers
# apart, the tail .new is under clean.sh's mask (a writer killed halfway leaves nothing that piles up).
lbl_commit_out() { _lcf=$1; shift; lbl_commit_out_as "$_lcf.$$.new" "$_lcf" "$@"; }
# lbl_commit_out_as <temp> <file> <command> [args…] — the same with the temp file NAMED BY THE CALLER: outside our directories
# a name of ours must say whose it is (`/etc/hosts.enodiatmp` — uninstall and the cleaner find ours by name).
lbl_commit_out_as() {
    _lct=$1; _lcf=$2; shift 2
    _lcr=$( { { "$@" 3>&-; echo "p$?" >&3; } | { { cat > "$_lct"; } 2>/dev/null; _lcs=$?; [ "$_lcs" = 0 ] || cat > /dev/null; echo "s$_lcs" >&3; }; } 3>&1 )
    case "$_lcr" in
        "p0${LBL_NL}s0"|"s0${LBL_NL}p0") mv -f "$_lct" "$_lcf" 2>/dev/null && return 0 ;;
    esac
    rm -f "$_lct" 2>/dev/null; return 1
}
# grep as a producer for lbl_commit_out: code 1 («no line selected») is an empty answer, 2 and above — a failure.
# `||`, not `;`: under `set -e` (inherited by the helper's subshell) a bare grep that selects nothing ENDS the producer before
# its code is reported — the last line of a registry could not be removed (review s.127; no caller runs under -e today).
lbl_grep() { grep "$@" || [ "$?" -le 1 ]; }
# lbl_without <file> <pattern> [line] — the commonest producer, «the registry with this key's line replaced»: the file without
# the lines grep finds by the pattern (a basic regex: `^key<TAB>`), then the line (none or empty — the key is simply gone).
# A file that is not there is an empty one; a file that could not be read is a FAILURE — the writer then leaves it as it was.
lbl_without() { if [ -f "$1" ]; then lbl_grep -v -- "$2" "$1" || return 1; fi; [ -z "${3:-}" ] || printf '%s\n' "$3"; }

# Byte identity for config observations and the owners that act on them.
lbl_cfg_digest() {
    [ -f "$1" ] || return 1
    _lcd=$(md5sum < "$1" 2>/dev/null) || return 1
    printf '%s\n' "${_lcd%% *}"
}
lbl_cfg_matches() {
    [ "${#2}" -eq 32 ] || return 1
    [ "$(lbl_cfg_digest "$1")" = "$2" ]
}

# Relative config path for the archive and the installed registry.
lbl_cfg_path() {
    lbl_cfg_key "$1/$2" || return 1
    case "$1" in
        awg) printf 'configs/%s.conf\n' "$2" ;;
        xray) printf 'xray-configs/%s.json\n' "$2" ;;
        hy2) printf 'hy2-configs/%s.yaml\n' "$2" ;;
        *) return 1 ;;
    esac
}
