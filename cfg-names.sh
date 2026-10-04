#!/bin/sh
# cfg-names.sh — НАСТОЯЩИЕ ИМЕНА КОНФИГОВ («Frankfurt 🇩🇪 vps» вместо файла Frankfurt-DE-vps).
#
# ЗАЧЕМ (жалоба 03.10.2026). Имя ФАЙЛА конфига роутер держит латиницей ([A-Za-z0-9_.-]: его режут глобы, скрипты, cron, имена
# выходов), и панель транслитерирует то, что человек назвал (cfgSlug): кириллица — транслитом, флаг — кодом страны, прочие
# эмодзи — в дефис. А серверы из VLESS-подписок с самого начала показываются как названы, с эмодзи и флагами: их ремарка
# лежит рядом (`.sub-names`). Конфиг, добавленный руками (vpn://, файл, ссылка) или переименованный, такого не имел — флаг и
# эмодзи терялись. Теперь у него то же самое: файл — латиницей, показ — как назвал человек.
#
# ГДЕ ЖИВЁТ: `$ENODIA_STATE/.cfg-names` — TSV `вид/файл⇥имя` (вид — awg|xray|hy2: у разных протоколов файл может совпасть по
# имени), единственная истина; переживает ребут и обновление, входит в бэкап. Пишут CGI загрузки, переименования и удаления
# конфига; читает `cgi-bin/list` (поле `cfgnames`, ОДИН запуск на весь список) и `cgi-bin/status` (имя активного в шапке).
# Серверы подписок сюда не пишутся — их показ у `.sub-names` (идентичность файлов подписки — там, subs-update.sh).
# Механика (лок, очистка, разбор, атомарная запись) — общая с dev-names.sh, у одного владельца: label-lib.sh.
#
# Команды:
#   cfg-names.sh set <вид> <файл> <имя>  — задать (пустое имя или совпавшее с именем файла = снять)
#   cfg-names.sh del <вид> <файл>        — снять
#   cfg-names.sh mv  <вид> <старый> <новый> [имя] — переименование файла: показ едет с ним (имя дано — задать новое)
#   cfg-names.sh get <вид> <файл>        — имя или пусто
#   cfg-names.sh list                    — все: `вид/файл⇥имя`
#   cfg-names.sh json                    — то же картой JSON {"вид/файл":"имя"} (кавычки и косая вычищены разбором)
#   cfg-names.sh merge <файл>            — влить имена из файла (импорт бэкапа): у своего ключа побеждает файл, прочие остаются
#   cfg-names.sh import <файл> <корень>  — импорт бэкапа: merge + снять локальный показ у конфигов, привезённых архивом без имени
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
STORE="$ENODIA_STATE/.cfg-names"
LOCK=/tmp/enodia-cfg-names.lock
# Потолок — БАЙТАМИ и ОТКАЗОМ, как у меток устройств (обрезка `cut -c` режет байты и рвёт UTF-8). Эмодзи — 4 байта: 240 байт —
# это 60 букв даже из одних эмодзи — ровно столько панель и отправляет (dispCap режет показ по буквам ещё до отправки).
NAME_MAX=240
KEY_RE='^(awg|xray|hy2)/[A-Za-z0-9_.-]+$'
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] && tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -qE "$2"; }
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; else
    echo "[cfg-names] нет $ENODIA_DIR/label-lib.sh — обновите установку" >&2; exit 1
fi

key_ok() { printf '%s' "$1" | grep -qE "$KEY_RE"; }
cmd_list() { lbl_list "$STORE" "$KEY_RE"; }
cmd_get() { key_ok "$1/$2" || return 1; cmd_list | awk -F"$LBL_TAB" -v k="$1/$2" '$1==k { print $2; exit }'; }

# Записать «вид/файл → имя» под локом. Имя, совпавшее с именем файла, — не своё имя: строку снимаем (показ и так тот же).
put() {   # $1 = вид/файл, $2 = имя (пусто = снять)
    lbl_lock_take "$LOCK" 'cfg-names' || { echo "[cfg-names] имена сейчас правит другая операция — повторите"; return 1; }
    lbl_write "$STORE" "$1" "$2" "$KEY_RE"; _pr=$?
    lbl_lock_drop "$LOCK"
    [ "$_pr" = 0 ] || { echo "[cfg-names] не удалось записать имя (место на разделе?)"; return 1; }
    return 0
}
san_checked() {   # $1 = файл, $2 = имя → очищенное имя в $SN; 1 — отказ (сказано словами)
    SN=$(lbl_san "$2")
    # Имя из одних запрещённых знаков («"», «\») — НЕ «снять»: человек что-то написал и ждёт показ (так же у меток устройств,
    # dev-names.sh). Снимает только пустое поле (или одни пробелы).
    if [ -z "$SN" ] && [ -n "$(printf '%s' "$2" | tr -d ' \t\r\n')" ]; then
        echo "[cfg-names] в имени нет ни одного допустимого знака — кавычки и обратная косая не сохраняются"; return 1
    fi
    [ "$SN" = "$1" ] && SN=""
    if [ "$(printf '%s' "$SN" | wc -c)" -gt "$NAME_MAX" ]; then
        echo "[cfg-names] имя слишком длинное — сократите"; return 1
    fi
    return 0
}

cmd_set() {
    key_ok "$1/$2" || { echo "[cfg-names] не тот вид или имя файла: $1/$2"; return 1; }
    san_checked "$2" "$3" || return 1
    put "$1/$2" "$SN" || return 1
    # ЧТО СОХРАНЕНО — последней строкой: очистка могла убрать знаки, и ответ панели обязан назвать то, что роутер записал, а не набранное.
    if [ -n "$SN" ]; then echo "[cfg-names] имя «$SN»"; else echo "[cfg-names] своё имя снято"; fi
}

# Переименование файла: строка старого снимается, у нового — данное имя или прежний показ (файл переименовали, а назвали его
# по-прежнему). Всё — одной записью под одним локом: прочитать «прежний» и записать два ключа без окна для чужой правки.
cmd_mv() {
    key_ok "$1/$2" && key_ok "$1/$3" || { echo "[cfg-names] не тот вид или имя файла: $1/$2 → $1/$3"; return 1; }
    lbl_lock_take "$LOCK" 'cfg-names' || { echo "[cfg-names] имена сейчас правит другая операция — повторите"; return 1; }
    if [ "$#" -ge 4 ]; then _mvn="$4"; else _mvn=$(cmd_list | awk -F"$LBL_TAB" -v k="$1/$2" '$1==k { print $2; exit }'); fi
    # Файл уже переименован (зовут ПОСЛЕ mv): строку старого ключа снимаем В ЛЮБОМ случае — иначе её получил бы следующий файл с тем же
    # именем. Отказ очистки — ЕГО словами последней строкой (CGI берёт последнюю; ревью с.96, круг 2: причину закрывало «не удалось»).
    if san_checked "$3" "$_mvn"; then
        lbl_write "$STORE" "$1/$2" "" "$KEY_RE" && lbl_write "$STORE" "$1/$3" "$SN" "$KEY_RE"; _mr=$?
    else
        lbl_write "$STORE" "$1/$2" "" "$KEY_RE"; lbl_lock_drop "$LOCK"; return 1
    fi
    lbl_lock_drop "$LOCK"
    [ "$_mr" = 0 ] || { echo "[cfg-names] не удалось записать имя"; return 1; }
    return 0
}

cmd_json() {
    cmd_list | awk -F"$LBL_TAB" '{ printf "%s\"%s\":\"%s\"", (c++ ? "," : ""), $1, $2 }'
}

# Импорт бэкапа (cgi-bin/backup): $1 — файл имён архива (может не быть), $2 — корень архива. Архивное имя побеждает у своего ключа;
# у конфига, который архив ПРИВЁЗ (его файл заменён архивным), а строки имени в архиве нет, локальный показ СНИМАЕМ — он про прежний
# сервер с тем же файлом (ревью с.96, круг 2: слияние оставляло «🇩🇪 Германия» на заменённом из архива vless). Прочие — как были.
cmd_import() {
    _ik=$( for _if in "$2"/configs/*.conf; do [ -f "$_if" ] && { _ib=${_if##*/}; echo "awg/${_ib%.conf}"; }; done
           for _if in "$2"/xray-configs/*.json; do [ -f "$_if" ] && { _ib=${_if##*/}; echo "xray/${_ib%.json}"; }; done
           for _if in "$2"/hy2-configs/*.yaml; do [ -f "$_if" ] && { _ib=${_if##*/}; echo "hy2/${_ib%.yaml}"; }; done )
    lbl_lock_take "$LOCK" 'cfg-names' || { echo "[cfg-names] имена сейчас правит другая операция — повторите"; return 1; }
    # Архивные имена — ТОЛЬКО у конфигов, которые архив привёз: застрявшая в архиве строка (сбой снятия) иначе легла бы на ЧУЖОЙ
    # локальный конфиг с тем же файлом — класс находки 1 ревью с.95 (ревью с.96, круг 3).
    _ia=""
    if [ -f "$1" ]; then
        while IFS= read -r _ir || [ -n "$_ir" ]; do
            [ -n "$_ir" ] || continue
            case "$LBL_NL$_ik$LBL_NL" in *"$LBL_NL${_ir%%"$LBL_TAB"*}$LBL_NL"*) _ia="${_ia:+$_ia$LBL_NL}$_ir" ;; esac
        done <<EOF
$(lbl_list "$1" "$KEY_RE")
EOF
    fi
    _ikeep=""
    while IFS= read -r _ir || [ -n "$_ir" ]; do
        [ -n "$_ir" ] || continue
        case "$LBL_NL$_ik$LBL_NL" in *"$LBL_NL${_ir%%"$LBL_TAB"*}$LBL_NL"*) continue ;; esac
        _ikeep="${_ikeep:+$_ikeep$LBL_NL}$_ir"
    done <<EOF
$(lbl_list "$STORE" "$KEY_RE")
EOF
    _iw=$(printf '%s\n%s\n' "$_ia" "$_ikeep" | awk -F"$LBL_TAB" 'NF >= 2 && !($1 in s) { s[$1] = 1; print }')
    lbl_commit "$STORE" "$_iw"; _imr=$?
    lbl_lock_drop "$LOCK"
    [ "$_imr" = 0 ] || { echo "[cfg-names] не удалось записать имена (место на разделе?)"; return 1; }
    return 0
}

cmd_merge() {
    [ -f "$1" ] || { echo "[cfg-names] нет файла $1"; return 1; }
    lbl_lock_take "$LOCK" 'cfg-names' || { echo "[cfg-names] имена сейчас правит другая операция — повторите"; return 1; }
    lbl_merge "$STORE" "$1" "$KEY_RE"; _mgr=$?
    lbl_lock_drop "$LOCK"
    [ "$_mgr" = 0 ] || { echo "[cfg-names] не удалось записать имена (место на разделе?)"; return 1; }
    return 0
}

case "$1" in
    set)  cmd_set "$2" "$3" "$4" ;;
    merge) cmd_merge "$2" ;;
    import) cmd_import "$2" "$3" ;;
    del)  key_ok "$2/$3" || exit 1; put "$2/$3" "" ;;
    mv)   shift; cmd_mv "$@" ;;
    get)  cmd_get "$2" "$3" ;;
    list) cmd_list; exit 0 ;;
    json) cmd_json; exit 0 ;;
    *) echo "usage: $0 set <вид> <файл> <имя> | del <вид> <файл> | mv <вид> <старый> <новый> [имя] | get <вид> <файл> | list | json | merge <файл> | import <файл> <корень архива>"; exit 2 ;;
esac
