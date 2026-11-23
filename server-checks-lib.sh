#!/bin/sh
# One small atomic record file per saved config. A digest ties both verdicts to the measured bytes.
SC_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
SC_STORE="$SC_STATE/.srv-checks.d"
SC_LOCK=/tmp/enodia-srv-check.lock
SC_HOLDERS='cgi-bin/(ping|action)|subs-import\.sh'
SC_MAX_KIB=2048
SC_TAB=$(printf '\t')
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi
if ! command -v pid_runs >/dev/null 2>&1 && [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
if ! command -v fs_free_b >/dev/null 2>&1 && [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi

sc_rev() { lbl_cfg_digest "$1"; }
sc_file() { printf '%s/%s/%s' "$SC_STORE" "$1" "${2##*/}"; }
sc_mutate() (
    lbl_lock_take "$SC_LOCK" "$SC_HOLDERS" || exit 1
    trap 'lbl_lock_drop "$SC_LOCK"' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    "$@"
)
sc_drop() { [ ! -d "$SC_STORE/$1" ] || sc_mutate rm -f "$(sc_file "$1" "$2")"; }
sc_move() {
    _sc_src=$(sc_file "$1" "$2")
    _sc_dst=$(sc_file "$1" "$3")
    [ ! -d "$SC_STORE/$1" ] || sc_mutate sc_move_locked "$_sc_src" "$_sc_dst"
}
sc_move_locked() { [ ! -f "$1" ] || mv -f "$1" "$2"; }

sc_save() { sc_mutate sc_save_locked "$@"; }
sc_save_locked() ( # family, config path, digest, endpoint|egress, then the fields of one result
    _sc_kind=$1; _sc_cfg=$2; _sc_rev=$3; _sc_scope=$4; shift 4
    case "$_sc_kind" in awg|hy2|xray) ;; *) exit 1 ;; esac
    _sc_name=${_sc_cfg##*/}; _sc_name=${_sc_name%.*}
    case "$_sc_name" in ''|*[!A-Za-z0-9_.-]*) exit 1 ;; esac
    [ -n "$_sc_rev" ] && [ "$(sc_rev "$_sc_cfg")" = "$_sc_rev" ] || exit 1
    # A temp record and its directory entries need room above the normal
    # maintenance reserve, even when a check only replaces an existing row.
    _sc_free=$(fs_free_b "$SC_STATE") || exit 1
    [ "$_sc_free" -ge "$((DATA_RESERVE_B+16384))" ] || exit 1
    umask 077
    [ ! -L "$SC_STORE" ] && [ ! -L "$SC_STORE/$_sc_kind" ] || exit 1
    mkdir -p "$SC_STORE/$_sc_kind" || exit 1
    _sc_dest=$(sc_file "$_sc_kind" "$_sc_cfg")
    _sc_stage="$SC_STORE/.check.new"
    trap 'rm -f "$_sc_stage" "$_sc_stage.tmp"' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    rm -f "$_sc_stage" "$_sc_stage.tmp" || exit 1
    _sc_old=$_sc_dest; [ -f "$_sc_old" ] || _sc_old=/dev/null
    _sc_time=$(date +%s)
    _sc_row=$(printf '%s\t' "$_sc_rev" "$1" "$2" "$3" "$4" "$5" "$6" "$_sc_time" "$7" "$8" "$9" "${10}" "${11}" "${12}")
    _sc_body=$(awk -F "$SC_TAB" -v OFS="$SC_TAB" -v rev="$_sc_rev" -v scope="$_sc_scope" -v row="$_sc_row$_sc_scope" '
        BEGIN { split(row, nextRow, FS) }
        $1==rev && $15!=scope && ($15=="endpoint" || $15=="egress") {
            if (!kept++) print
            next
        }
        $1==rev && $15=="egress" && $2=="ok" && nextRow[2]=="ok" {
            if (nextRow[3]=="-") { nextRow[3]=$3; nextRow[4]=$4 }
            if (nextRow[6]=="-") { nextRow[6]=$6; nextRow[7]=$7 }
        }
        END { for (i=1;i<=15;i++) printf "%s%s", nextRow[i], (i==15 ? ORS : OFS) }
    ' "$_sc_old") || exit 1
    [ "${#_sc_body}" -le 1536 ] &&
        lbl_commit_out_as "$_sc_stage.tmp" "$_sc_stage" printf '%s\n' "$_sc_body" || exit 1
    # Include all three families and the staged allocation. Deduct only
    # the record this rename actually replaces.
    _sc_size=$(du -sk "$SC_STORE") && { set -- $_sc_size; _sc_size=$1; } || exit 1
    _sc_prev=0
    if [ -f "$_sc_dest" ]; then
        _sc_prev=$(du -sk "$_sc_dest") && { set -- $_sc_prev; _sc_prev=$1; } || exit 1
    fi
    case "$_sc_size:$_sc_prev" in *[!0-9:]*) exit 1 ;; esac
    [ "$((_sc_size-_sc_prev))" -le "$SC_MAX_KIB" ] &&
        [ "$(sc_rev "$_sc_cfg")" = "$_sc_rev" ] &&
        mv -f "$_sc_stage" "$_sc_dest" && printf '%s\n' "$_sc_time"
)

sc_egress() {
    _sce_st=dead; _sce_ms=-; _sce_mbps=-; _sce_kind=ping
    case "$3" in
        *'"busy":true'*|*'"nobin":true'*) return 0 ;;
        '{"ok":true,'*) _sce_st=ok ;;
        '{"ok":false,'*) ;;
        *) return 0 ;;
    esac
    if [ "$_sce_st" = ok ]; then
        _sce_ms=$(printf '%s\n' "$3" | jsonfilter -e '@.ms' 2>/dev/null)
        _sce_mbps=$(printf '%s\n' "$3" | jsonfilter -e '@.mbps' 2>/dev/null)
        [ -z "$_sce_mbps" ] || _sce_kind=speed
    elif [ "${4:-}" = speed ]; then
        return 0  # a failed throughput sample carries no egress verdict
    fi
    sc_save xray "$1" "$2" egress "$_sce_st" "${_sce_ms:--}" tun 0 "${_sce_mbps:--}" "$_sce_kind" - - - - 0 -
}

sc_rows() (
    [ -d "$SC_STORE" ] && [ -f "$ENODIA_DIR/xray-profile-lib.sh" ] || exit 0
    . "$ENODIA_DIR/xray-profile-lib.sh"
    for _scr_kind in awg xray hy2; do
        case "$_scr_kind" in awg) _scr_dir=configs; _scr_ext=conf ;; xray) _scr_dir=xray-configs; _scr_ext=json ;; hy2) _scr_dir=hy2-configs; _scr_ext=yaml ;; esac
        [ -d "$SC_STORE/$_scr_kind" ] || continue
        set --
        for _scr_cfg in "$SC_STATE/$_scr_dir"/*."$_scr_ext"; do
            [ ! -f "$_scr_cfg" ] || [ ! -f "$SC_STORE/$_scr_kind/${_scr_cfg##*/}" ] || set -- "$@" "$_scr_cfg"
        done
        [ "$#" -gt 0 ] || continue
        _xmr_live_sums "$@" | awk -F "$SC_TAB" -v dir="$SC_STORE/$_scr_kind/" -v kind="$_scr_kind" '
            { name=$2; sub(/^.*\//,"",name); file=dir name; sub(/\.[^.]*$/,"",name)
              while ((getline row < file)>0)
                  if (substr(row,1,33)==$1 FS) print kind "|" name FS substr(row,34) FS $1
              close(file) }
        '
    done
)
