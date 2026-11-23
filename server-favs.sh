#!/bin/sh
# Router-wide favourites in user order. Subscription keys follow the stable filenames
# assigned by subs-import.sh using .sub-names. A complete refresh retires vanished keys.
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
FAV_STORE="$ENODIA_STATE/.server-favs"
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; else exit 1; fi

fav_keys() { lbl_list "$1" "$LBL_CFG_KEY_RE" | awk -F "$LBL_TAB" '$2=="1" {print $1}'; }
fav_exists() {
    case "$1" in
        awg/*) [ -f "$ENODIA_STATE/configs/${1#*/}.conf" ] ;;
        xray/*) [ -f "$ENODIA_STATE/xray-configs/${1#*/}.json" ] ;;
        hy2/*) [ -f "$ENODIA_STATE/hy2-configs/${1#*/}.yaml" ] ;;
        *) return 1 ;;
    esac
}
fav_live() {
    while IFS= read -r _fvl_key; do
        if fav_exists "$_fvl_key"; then printf '%s\n' "$_fvl_key"; fi
    done
}
fav_error() { printf '%s\n' "$*" >&2; exit 1; }

_fv_cmd=${1:-}; [ "$#" -eq 0 ] || shift
case "$_fv_cmd" in
    list) fav_keys "$FAV_STORE" | fav_live; exit ;;
    json) fav_keys "$FAV_STORE" | fav_live | awk '{ printf "%s\"%s\"", (NR>1 ? "," : ""), $0 }'; exit ;;
    set|del|mv|import) ;;
    *) exit 1 ;;
esac
command -v pid_runs >/dev/null 2>&1 || fav_error 'не удалось открыть избранное'
lbl_lock_take "$LBL_FAV_LOCK" "$LBL_FAV_HOLDERS" || fav_error 'избранное сейчас меняется — повторите'
trap 'lbl_lock_drop "$LBL_FAV_LOCK"' EXIT
trap 'exit 1' HUP INT TERM PIPE
_fv_old=$(fav_keys "$FAV_STORE")
_fv_result=0
case "$_fv_cmd" in
    set|del|mv) lbl_cfg_key "${1:-}" || fav_error 'плохое имя конфига' ;;
esac
case "$_fv_cmd" in
    set)
        fav_exists "$1" || fav_error 'конфиг не найден'
        _fv_new="$_fv_old$LBL_NL$1"
        ;;
    del) _fv_new=$(printf '%s\n' "$_fv_old" | awk -v k="$1" '$0 != k') ;;
    mv)
        lbl_cfg_key "${2:-}" || fav_error 'плохое имя конфига'
        _fv_new=$(printf '%s\n' "$_fv_old" | awk -v o="$1" -v n="$2" '{ print ($0==o ? n : $0) }')
        ;;
    import)
        _fv_requested=$(fav_keys "$1")
        _fv_found=$(printf '%s\n' "$_fv_requested" | fav_live)
        _fv_kept=$_fv_old
        if [ -n "${2:-}" ]; then
            _fv_brought=$(lbl_cfg_keys "$2")
            _fv_found=$(printf '%s\n' "$_fv_brought" --- "$_fv_found" |
                awk '$0=="---" {archive=1; next} !archive {brought[$0]=1; next} NF && ($0 in brought)')
            _fv_kept=$(printf '%s\n' "$_fv_brought" --- "$_fv_old" |
                awk '$0=="---" {local=1; next} !local {brought[$0]=1; next} NF && !($0 in brought)')
        fi
        [ "$_fv_found" = "$_fv_requested" ] || _fv_result=2
        _fv_new="$_fv_kept$LBL_NL$_fv_found" ;;
esac
_fv_new=$(printf '%s\n' "$_fv_new" | awk 'NF && !seen[$0]++')
if [ "$_fv_new" != "$_fv_old" ]; then
    _fv_rows=$(printf '%s\n' "$_fv_new" | awk 'NF {print $0 "\t1"}')
    (umask 077; lbl_commit "$FAV_STORE" "$_fv_rows") || fav_error 'не удалось сохранить избранное'
fi
exit "$_fv_result"
