#!/bin/sh
# slots.sh — РЕЕСТР «выходов» (слотов) мульти-транспорта. Ф0 фундамента.
#
# «Выход» (slot) = (транспорт, конфиг): доп-туннель/десинк, через который едут ПРИВЯЗАННЫЕ
# к нему группы (groups.sh) и гео-категории (geo.sh). Основной транспорт (.transport) — это
# неявный слот №1, ЕГО этот реестр НЕ описывает (истина по-прежнему .transport/transport.sh).
# Only EXTRA slots live here: ids MIN_ID..MAX_ID = 2..7. mark = id and `pref 9<id>` must stay above the base pref 99,
# so this numbering stops at 8; MAX_ID is the one ceiling, every other literal of the range is checked against it (C130).
#
# Дизайн целиком: заметки разработки «мультитранспорт-дизайн». Ключевое:
#   * марка слота = его id (0x2..0x7) -> ip rule pref 9<id> -> table 100<id>;
#   * слот-сеты grp_vpn_s<id> / geo_vpn_s<id> МЕТИТ mark-core.sh (инвариант проекта: логика
#     «выше miwifi/NFQUEUE» живёт в ОДНОМ месте — там). Этот скрипт правила НЕ СТАВИТ;
#   * mark-core also owns withdrawal of the lookup when the exit is disabled or removed;
#   * пустая table 100<id> (несущая слота не поднята) => fwmark проваливается в main =
#     fail-open напрямую. Безопасно by construction — как и всё ядро.
#
# Registry TSV: id<TAB>name_b64<TAB>transport<TAB>config<TAB>fallback<TAB>on|off[<TAB>keep_when_off=1]
#   name_b64 — имя слота в base64 (кириллица/пробелы/эмодзи; JSON/TSV-эскейпа на busybox нет —
#   тот же паттерн, что title/text в events.sh);
#   transport — из SELECTABLE transport.sh (awg|xray|hy2|byedpi|zapret);
#   config    — имя конфига несущей (для awg: configs/<имя>.conf; для xray: xray-configs/<имя>;
#               для byedpi/zapret: '-' — конфига нет, стратегия своя);
#   fallback  — main (default), direct, or a tunnel exit ID (2..7, tunnel sources only).
#
# Команды:
#   slots.sh list                — все слоты (человеко-TSV: id, имя, транспорт, конфиг, fallback, вкл)
#   slots.sh list-enabled        — только включённые, машинный TSV: id<TAB>transport<TAB>config<TAB>fallback
#                                  (его читает mark-core.sh — формат менять ОСТОРОЖНО)
#   slots.sh show <id>           — одна строка реестра (сырая)
#   slots.sh domains <id|0|zapret> [кап] — ДОМЕНЫ привязок выхода (0 = основной, zapret = всё,
#                                  что десинкает общий nfqws), по одному на строку; единый
#                                  источник для пула проб панели и byedpi-test.sh
#   slots.sh route <id|0|zapret> <домен> — «а ЭТОТ домен едет через выход?»: резолв + ipset test
#                                  по сетам цели. TSV: hit|miss|noresolve|badhost<TAB>ip<TAB>сет
#   slots.sh add <имя> <транспорт> [конфиг] [fallback]  — создать (id = первый свободный 2..7)
#   slots.sh set <id> <name|transport|config|fallback> <значение>
#   slots.sh enable <id> / disable <id>
#   slots.sh del <id>            — снять правила (unwire) + удалить из реестра
#   slots.sh unwire <id>         — только снять iptables/ip rule слота (без правки реестра)
#   slots.sh rename-config <транспорт> <старое> <новое> — конфиг ПЕРЕИМЕНОВАН: поле config выходов этого транспорта
#                                  со старым именем → новое (печатает, сколько строк переписано)
#   slots.sh key-holder <конфиг> <main|2..7> [live] — занят ли КЛЮЧ этого awg-конфига основным каналом или
#                                  другим выходом (0 = занят, причина словами; 1 = свободен; 2 = не судить);
#                                  без `live` — «можно ли назначить», с `live` — «поднимать ли сейчас» (см. блок ключей)
#   slots.sh key-map             — «конфиг⇥держатель» по занятым ключам configs/ (пометки в выборе панели)
#   slots.sh holders <транспорт> <конфиг> [on] — the numbers of the exits that NAME this config («3,5»; `on` — switched-on only)
#   (выход-ДОРОГА, по которому едут конфиги road.sh, не выключается, не удаляется, не меняет транспорт и не берёт конфиг,
#    который сам едет по дороге — slot_road_guard)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
command -v slot_rules_show >/dev/null 2>&1 || slot_rules_show() { ip rule show 2>/dev/null; }
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v ct_flush_slot >/dev/null 2>&1 || ct_flush_slot() { :; }
SLOTS_FILE="$ENODIA_STATE/.slots"
SLOTS_PENDING="$ENODIA_STATE/.slots-unapplied"
MIN_ID=2
MAX_ID=7
TAB=$(printf '\t')

# Где лежит бинарь (store-lib.sh): накопитель = ОПЦИЯ, но если он включён — альт-бинари живут
# НА НЁМ, и проверка `-x "$ENODIA_BIN/byedpi"` отвечает «нет» при установленном ciadpi (поймано на
# железе 04.08: панель прятала «Тест стратегий по пулу»). Нет маркера накопителя ⇒ bin_path
# отдаёт прежний путь БАЙТ-В-БАЙТ. Шим — на случай установки без lib.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Порт socks доп-выхода считает ОДИН владелец — slot-tun-lib.sh (там же диапазон и его разбор).
# Своей арифметики 10830+id тут не держим: это была третья копия. Библиотека — только функции,
# исполняемого кода в ней нет, поэтому source безопасен и вне плагинов.
if [ -f "$ENODIA_DIR/slot-tun-lib.sh" ]; then . "$ENODIA_DIR/slot-tun-lib.sh"; fi
# daemon_ram_room — «is there room for one more Go daemon» (slot_ram_guard). No library — no guard: the old behaviour.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v slot_socks_port >/dev/null 2>&1 || slot_socks_port() { echo $((10830 + $1)); }
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi   # lbl_commit_out: a file replaced whole or not at all
command -v lbl_commit_out_as >/dev/null 2>&1 || { lbl_commit_out_as() { _lct=$1; _lcf=$2; shift 2; "$@" > "$_lct" && mv -f "$_lct" "$_lcf" && return 0; rm -f "$_lct"; return 1; }; lbl_commit_out() { _lcf=$1; shift; lbl_commit_out_as "$_lcf.$$.new" "$_lcf" "$@"; }; lbl_grep() { grep "$@" || [ "$?" -le 1 ]; }; lbl_without() { if [ -f "$1" ]; then lbl_grep -v -- "$2" "$1" || return 1; fi; [ -z "${3:-}" ] || printf '%s\n' "$3"; }; }   # write-blind: the shim of a missing library is the old line

b64e() { printf '%s' "$1" | base64 | tr -d '\n'; }
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

valid_id() { case "$1" in [0-9]) [ "$1" -ge "$MIN_ID" ] && [ "$1" -le "$MAX_ID" ] ;; *) return 1 ;; esac; }

# Транспорт слота должен быть известен оркестратору (SELECTABLE transport.sh). Дублировать
# список не хотим (DRY) — но и сорсить transport.sh нельзя (он исполняемый, не либа), поэтому
# СПРАШИВАЕМ ЕГО САМОГО (верб `names` = SELECTABLE). Готовность здесь НЕ требуем (слот можно
# завести до установки бинаря — как deferred-config), требуем лишь ИЗВЕСТНОСТЬ имени.
# Фолбэк на вшитый список — для дрейфа деплоя (старый transport.sh без верба `names`): пустой
# ответ означал бы «любой транспорт неизвестен», т.е. невозможность завести выход вообще.
valid_transport() {
    _known=""
    [ -f "$ENODIA_DIR/transport.sh" ] && _known=$(sh "$ENODIA_DIR/transport.sh" names 2>/dev/null)
    case "$_known" in ''|*usage*) _known="awg xray hy2 byedpi zapret" ;; esac
    for _kt in $_known; do [ "$1" = "$_kt" ] && return 0; done
    return 1
}

slot_line() { grep "^$1$TAB" "$SLOTS_FILE" 2>/dev/null | head -n1; }
slot_tunnel() { case "$1" in awg|xray|hy2|byedpi) return 0 ;; *) return 1 ;; esac; }

SWITCH_LOCK=/tmp/enodia-switching.lock
FALLBACK_HANDOVER=/tmp/enodia-fallback-handover.lock

# A disabled row still supplies its next edge. Bound malformed imports and ignore Zapret entirely.
cmd_slot_plan() {
    [ -s "$SLOTS_FILE" ] || return 0
    [ ! -f "$ENODIA_STATE/.vpn-deactivated" ] || return 0
    _sp_legacy="$1"; fallback_downgrading && _sp_legacy=legacy
    _sp_off=0; [ ! -f "$ENODIA_STATE/.vpn-off" ] || _sp_off=1
    [ "$_sp_off:$_sp_legacy" != 1:legacy ] || return 0
    _sp_rows=$(cmd_list_admitted)
    _sp_admitted=$(printf '%s\n' "$_sp_rows" | cut -f1 | tr '\n' ' ')
    _sp_targets=$(printf '%s\n' "$_sp_rows" | while IFS="$TAB" read -r _spi _spt _spc _spf; do
        slot_tunnel "$_spt" || continue
        if slot_owned_default "$_spi" "$_spt" ||
           { ! slot_route_default "100$_spi" && sh "$ENODIA_DIR/transport.sh" slot-ready "$_spt" >/dev/null 2>&1; }; then
            printf ' %s ' "$_spi"
        fi
    done)
    _sp_plan=$(awk -F "$TAB" -v lo="$MIN_ID" -v hi="$MAX_ID" -v legacy="$_sp_legacy" -v off="$_sp_off" -v targets="$_sp_targets" -v admitted_ids=" $_sp_admitted" '
        function tunnel(i) { return kind[i] ~ /^(awg|xray|hy2|byedpi)$/ }
        $1 ~ /^[0-9]$/ && $1>=lo && $1<=hi && !($1 in kind) {
            kind[$1]=$3; edge[$1]=$5; admitted[$1]=index(admitted_ids," " $1 " ")
        }
        END {
            for (i=lo; i<=hi; i++) {
                if (!admitted[i] || !tunnel(i)) continue
                if (legacy=="legacy") { print i, "9" i, "100" i, edge[i]; continue }
                if (index(targets," " i " ")) print i, "9" i, "100" i
                pref=110; seen=" " i " "; hop=edge[i]
                while (hop ~ /^[0-9]$/ && !index(seen," " hop " ") && tunnel(hop)) {
                    if (admitted[hop] && index(targets," " hop " ")) print i, pref++, "100" hop
                    seen=seen hop " "; hop=edge[hop]
                }
                if (!off && hop!="direct") print i, pref, 1000
            }
        }' "$SLOTS_FILE") || return 1
    [ "$_sp_legacy" = legacy ] || { printf '%s\n' "$_sp_plan"; return; }
    printf '%s\n' "$_sp_plan" | while read -r _sp_id _sp_pref _sp_table _sp_edge; do
        [ -n "$_sp_id" ] || continue
        if [ "$_sp_edge" = main ] && ! slot_route_default "$_sp_table"; then _sp_table=1000; fi
        printf '%s %s %s\n' "$_sp_id" "$_sp_pref" "$_sp_table"
    done
}

fallback_dependants() {
    [ -s "$SLOTS_FILE" ] || return 0
    awk -F "$TAB" -v id="$1" '$3!="zapret" && $5 ""==id "" && $1!=id {printf "%s%s", sep,$1; sep=", "}' "$SLOTS_FILE"
}
fallback_guard() {   # source, proposed edge, source transport; called under the registry lock
    case "$2" in main|direct) return 0 ;; esac
    valid_id "$2" || { echo "[slots] fallback = main|direct|$MIN_ID..$MAX_ID"; return 1; }
    slot_tunnel "$3" || { echo 'Для выхода Zapret запасной путь — основной выход или напрямую'; return 1; }
    fallback_handover && { echo 'Идёт обновление или смена транспорта — повторите позже'; return 1; }
    _fg_next=$2; _fg_seen=" $1 "; _fg_path=$1
    while valid_id "$_fg_next"; do
        _fg_path="$_fg_path → $_fg_next"
        case "$_fg_seen" in *" $_fg_next "*) echo "Цикл запасных выходов: $_fg_path"; return 1 ;; esac
        _fg_seen="$_fg_seen$_fg_next "
        _fg_row=$(slot_line "$_fg_next")
        [ -n "$_fg_row" ] || { echo "Запасной выход не найден: №$_fg_next"; return 1; }
        slot_tunnel "$(printf '%s\n' "$_fg_row" | cut -f3)" || { echo 'Запасным может быть только туннельный выход'; return 1; }
        _fg_next=$(printf '%s\n' "$_fg_row" | cut -f5)
    done
    case "$_fg_next" in main|direct) return 0 ;; *) echo '[slots] Повреждён запасной путь'; return 1 ;; esac
}

fallback_downgrading() { pid_runs "$(cat "$FALLBACK_HANDOVER/pid" 2>/dev/null)" '(gh-update|pkg-install)\.sh' 2>/dev/null; }
fallback_handover() { [ -e "$SWITCH_LOCK" ] || fallback_downgrading || pkg_install_alive 2>/dev/null; }

# --- ЗАПИСЬ В РЕЕСТР: лок + атомарная подмена ------------------------------------------------
# Реестр правят НЕСКОЛЬКО потребителей (клик в панели, второй клик, slot-* из сторожа/heal), а
# запись — read-modify-write ЦЕЛОГО файла ⇒ без лока два одновременных вызова склеивают строки
# или теряют выход; cmd_add вдобавок выбирает id ЧТЕНИЕМ (TOCTOU). Лок — КАТАЛОГ (mkdir атомарен
# на любой ФС, идиома groups/geo/dns-merge), устаревший снимаем `rm -rf`: внутри пид-файл, rmdir
# его не возьмёт. Временный файл — со СВОИМ ПИДом: общее имя `.new` два процесса делили бы.
SLOTS_LOCK=/tmp/.enodia-slots.lock
slots_lock_take() {   # $1 = сколько секунд ждать (деф. 10)
    _lw="${1:-10}"; _li=0
    while ! mkdir "$SLOTS_LOCK" 2>/dev/null; do
        _lp=$(cat "$SLOTS_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
        if { [ -z "$_lp" ] && [ "$_li" -ge 2 ]; } || { [ -n "$_lp" ] && ! kill -0 "$_lp" 2>/dev/null; }; then
            rm -rf "$SLOTS_LOCK" 2>/dev/null        # держатель умер — лок протух
        fi
        _li=$((_li+1)); [ "$_li" -ge "$_lw" ] && return 1
        sleep 1
    done
    if echo $$ > "$SLOTS_LOCK/pid" 2>/dev/null; then
        ENODIA_SLOTS_OWNER=$$; export ENODIA_SLOTS_OWNER
        return 0
    fi
    slots_lock_drop; return 1
}
slots_lock_drop() { rm -rf "$SLOTS_LOCK" 2>/dev/null; }
slots_mutate() {
    slots_lock_take || { echo '[slots] реестр занят другой операцией — повторите'; return 1; }
    trap 'slots_lock_drop' EXIT
    trap 'exit 1' HUP INT TERM
    "$@"
}
# Registry edits and carrier dispatch both take this lock before reading the row.
# Imports take the road registry lock first; carrier publication may take the road wire lock last.
slot_dispatch_carrier() {
    ENODIA_DIR="$ENODIA_DIR" ENODIA_STATE="$ENODIA_STATE" sh "$ENODIA_DIR/transport.sh" dispatch-held "$@"
}
# Переписать (или УДАЛИТЬ, если полей нет) строку слота. Звать ТОЛЬКО под локом.
# Whole or not at all (label-lib.sh): every line but the exit's own, then the exit's. A registry that could not be read is a
# failure, not «no other exits» — the file then stays as it is. The last exit gone — the file goes too.
# Code 1 — NOTHING was written (no room, an unreadable registry): the caller must say so and stop — an exit raised, announced
# «создан» and absent from the registry is what the code used to answer a full partition with (review s.127).
SLOTS_NOWRITE="[slots] реестр выходов не записался (нет места на разделе настроек?) — изменение не сохранено"
_slots_write() {   # $1 = id ; [$2..$7 = name_b64 transport config fallback en keep-token]
    _wln=""; [ "$#" -le 1 ] || _wln="$1$TAB$2$TAB$3$TAB$4$TAB$5$TAB$6"
    [ -z "${7:-}" ] || _wln="$_wln$TAB$7"
    lbl_commit_out "$SLOTS_FILE" lbl_without "$SLOTS_FILE" "^$1$TAB" "$_wln" || return 1
    [ -s "$SLOTS_FILE" ] || rm -f "$SLOTS_FILE"
}

cmd_validate_registry() {
    [ -f "$1" ] && awk -F "$TAB" '
        $1 !~ /^[2-7]$/ || seen[$1]++ || $6 !~ /^(on|off)$/ {exit 1}
        NF!=6 && !(NF==7 && $7=="keep_when_off=1") {exit 1}
    ' "$1" || {
        echo '[slots] неверный формат реестра выходов'; return 1;
    }
}

# Profile and strategy publication share the dispatcher lock. Publish each Off profile whole
# so a failed copy leaves a usable file for the next watchdog tick.
import_exit_files() (
    [ -n "$1" ] || exit 0
    umask 077
    for _ip_dir in configs xray-configs hy2-configs; do
        [ -d "$1/$_ip_dir" ] || continue
        mkdir -p "$ENODIA_STATE/$_ip_dir" || exit 1
        if [ "$_srr_off" = 0 ]; then
            cp -rp "$1/$_ip_dir/." "$ENODIA_STATE/$_ip_dir/" || exit 1
        else
            for _ip_src in "$1/$_ip_dir"/* "$1/$_ip_dir"/.[!.]* "$1/$_ip_dir"/..?*; do
                [ -e "$_ip_src" ] || continue
                if [ -d "$_ip_src" ]; then
                    cp -rp "$_ip_src" "$ENODIA_STATE/$_ip_dir/" || exit 1
                else
                    lbl_commit_out "$ENODIA_STATE/$_ip_dir/${_ip_src##*/}" cat "$_ip_src" || exit 1
                fi
            done
        fi
    done
    for _ip_src in "$1"/.byedpi-args "$1"/.byedpi-args-s[2-7] "$1"/.zapret-args; do
        [ ! -f "$_ip_src" ] || lbl_commit_out "$ENODIA_STATE/${_ip_src##*/}" cat "$_ip_src" || exit 1
    done
)

# The old plugin is still the only owner that can remove its carrier.
retire_import_carriers() {
    _rik_kept=''
    if [ "$_srr_off" = 1 ]; then
        _rik_kept=$({ slot_rows off; slot_rows off '' '' "$1"; } | awk -F "$TAB" '{printf " %s ", $1}')
    fi
    while IFS="$TAB" read -r _rik_id _rik_kind _rik_cfg _rik_fb; do
        [ -n "$_rik_id" ] || continue
        case "$_rik_kept" in
            *" $_rik_id "*) ;;
            *) awk -F "$TAB" -v id="$_rik_id" -v kind="$_rik_kind" -v cfg="$_rik_cfg" '
                $1==id && $3==kind && ($4 "")==(cfg "") && $6=="on" {same=1}
                END {exit !same}' "$1" && continue ;;
        esac
        slot_deactivate "$_rik_id" || return 1
        _srr_retired="$_srr_retired $_rik_id"
    done <<EOF
$(cmd_list_enabled)
EOF
}

# A settings restore compares against the registry the road owner inspected before publishing any road changes.
cmd_restore_registry() {   # staged registry, previous contents, [staged off intent], [archive root], [switch/restore holder PID]
    _srr_holder=${5:-}; _srr_archive=${4:-}; _srr_registry=$1
    [ -f "$_srr_registry" ] || _srr_registry=$SLOTS_FILE
    cmd_validate_registry "$_srr_registry" || return 1
    slots_lock_take || return 1
    trap 'slots_lock_drop' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    _srr_now=""; _srr_rc=1; _srr_retired=''; _srr_off=0
    [ ! -f "$ENODIA_STATE/.vpn-off" ] && [ ! -f "${3:-}" ] || _srr_off=1
    if { { [ -e "$SWITCH_LOCK" ] && { [ -z "$_srr_holder" ] || [ "$(cat "$SWITCH_LOCK" 2>/dev/null)" != "$_srr_holder" ]; }; } ||
         fallback_downgrading || pkg_install_alive 2>/dev/null; } && awk -F "$TAB" '$5 ~ /^[0-9]+$/ {f=1} END {exit !f}' "$_srr_registry"; then
        echo 'Идёт обновление или смена транспорта — повторите позже'
    elif { [ ! -e "$SLOTS_FILE" ] || _srr_now=$(cat "$SLOTS_FILE"); } && [ "$_srr_now" = "$2" ]; then
        if [ -n "$_srr_holder" ] && [ -f "$ENODIA_DIR/subs-import.sh" ]; then
            sh "$ENODIA_DIR/subs-import.sh" restore-lock "$_srr_holder" || return 1
        fi
        if retire_import_carriers "$_srr_registry" &&
           import_exit_files "$_srr_archive" &&
           { [ ! -f "${3:-}" ] || [ -f "$ENODIA_STATE/.vpn-off" ] || : > "$ENODIA_STATE/.vpn-off"; } &&
           { [ "$_srr_registry" = "$SLOTS_FILE" ] || lbl_commit_out "$SLOTS_FILE" cat "$_srr_registry"; }; then
            _srr_rc=0
        elif [ "$_srr_off" = 0 ]; then
            for _srr_id in $_srr_retired; do slot_restore_carrier "$_srr_id"; done
        fi
    fi
    return "$_srr_rc"
}

# carriers — какие ТРАНСПОРТЫ несут доп-выходы (уникальные значения 3-й колонки, по слову в строке).
# ЗАЧЕМ вербом: это единственный ответ на вопрос «можно ли сносить бинарь транспорта», а спрашивают
# его РАЗНЫЕ подсистемы (установщик в purge-alt, движок компонентов packages.sh). Берём ВСЕ строки,
# включая ВЫКЛЮЧЕННЫЕ: выключенный выход — это запись с конфигом и привязками, снесённый бинарь
# сделал бы её невоскресимой (и «включить» молча не сработало бы).
cmd_carriers() { [ -s "$SLOTS_FILE" ] || return 0; cut -f3 "$SLOTS_FILE" 2>/dev/null | grep -v '^$' | sort -u; }
# holders <transport> <config> [on] — the numbers of the exits whose registry line names that config, comma-joined («5», «3,5»;
# empty — none); with `on` — only the switched-on ones. ONE answer to «which exits stand on this config»: the server screen's facts
# and the refusal to delete (cgi-bin/action), a subscription's pruning and its re-raise of a changed config (subs-update.sh). Names
# are compared AS TEXT (`x ""`): awk takes a `-v` value that looks like a number for one, and config «01» was shown the exits of «1».
cmd_holders() {
    [ -s "$SLOTS_FILE" ] || return 0
    awk -F"$TAB" -v t="$1" -v n="$2" -v o="${3:-}" \
        '($3 "") == (t "") && ($4 "") == (n "") && (o != "on" || $6 == "on") { printf "%s%s", (c++ ? "," : ""), $1 }' "$SLOTS_FILE" 2>/dev/null | tr -cd '0-9,'
}

cmd_list() {
    [ -s "$SLOTS_FILE" ] || return 0
    while IFS="$TAB" read -r id nb t cfg fb en keep || [ -n "$id" ]; do
        [ -n "$id" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(b64d "$nb")" "$t" "$cfg" "$fb" "$en"
    done < "$SLOTS_FILE"
}

# configs <transport> — the config NAMES the registry holds for that transport, a line each, from EVERY row: a switched-off exit
# and an exit whose config file was deleted still name theirs, and a new file under that name becomes that exit's the moment it
# is written. The answer to «is this name free for a NEW config» (warp.sh next_name); names compared by whoever asks.
cmd_configs() {
    [ -s "$SLOTS_FILE" ] || return 0
    awk -F"$TAB" -v t="$1" '($3 "") == (t "") && $4 != "" && $4 != "-" { print $4 }' "$SLOTS_FILE" 2>/dev/null
}

cmd_list_enabled() { slot_rows enabled; }
cmd_list_admitted() { slot_rows "${1:-admitted}"; }

# --- ДОМЕНЫ ПРИВЯЗОК ВЫХОДА -----------------------------------------------------------------
# «Какие домены реально едут через выход №N» — ЕДИНЫЙ ответ на всех потребителей: кандидаты
# пула проб браузер-свипа (панель) и пул тестера стратегий (byedpi-test.sh). id 0 = ОСНОВНОЙ
# выход (привязки без слота). Только ДОМЕНЫ: проба ходит по имени (SNI/TLS), CIDR десинку не
# проба, поэтому адреса отбрасываем.
#
# Два источника, объединяются (дедуп), потому что отвечают на РАЗНЫЕ вопросы:
#   (а) РЕЕСТР (groups.tsv + geo/actions.tsv + гео-кэш в ОЗУ) — «что человек привязал»; работает
#       и у ВЫКЛЮЧЕННОГО выхода (иначе пул проб нельзя собрать до первого включения: пока слот
#       выключен, гейт groups/geo уводит домены в основной сет и слот-строк в dnsmasq НЕТ);
#   (б) ЖИВОЙ dnsmasq (`ipset=/дом/<сет>`) — «что реально зашито в сет выхода»; ловит то, чего
#       в реестре групп нет вовсе: пулы zapret (zapret_set/zapret_dom) у основной несущей.
slot_pool_sets() {   # <id> -> имена ipset, наполняемые dnsmasq для этого выхода
    case "$1" in
        0) _ss="grp_vpn geo_vpn enodia_list"
           [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && _ss="$_ss zapret_set zapret_dom geo_zapret"
           echo "$_ss" ;;
        *) echo "grp_vpn_s$1 geo_vpn_s$1" ;;
    esac
}
collect_domains() {   # <id> -> дописать домены привязок выхода в $_raw
    _c="$1"
    # (а) реестр групп: включённые, «в VPN», привязанные к этому выходу
    _gtsv="$ENODIA_STATE/groups/groups.tsv"
    if [ -f "$_gtsv" ]; then
        while IFS="$TAB" read -r _gid _gen _gdir _gslot _gname _gsrc; do
            [ "$_gen" = 1 ] && [ "$_gdir" = vpn ] && [ "${_gslot:-0}" = "$_c" ] || continue
            [ -f "$ENODIA_STATE/groups/$_gid.list" ] && cat "$ENODIA_STATE/groups/$_gid.list" >> "$_raw"
        done < "$_gtsv"
    fi
    # (а) реестр гео: доменные категории «в VPN» этого выхода (кэш в ОЗУ уже нормализован;
    # нет кэша = категория не резолвлена — путь (б) её всё равно подберёт из dnsmasq)
    _geor="$ENODIA_STATE/geo/actions.tsv"
    if [ -f "$_geor" ]; then
        while IFS="$TAB" read -r _gk _ga _gc _gt _gs; do
            [ "$_ga" = vpn ] && [ "${_gs:-0}" = "$_c" ] || continue
            [ -f "/tmp/enodia-geo/cache/$_gk" ] && cat "/tmp/enodia-geo/cache/$_gk" >> "$_raw"
        done < "$_geor"
    fi
    # (б) живой dnsmasq: `ipset=/дом/сет[,сет2]` -> домен. Хвост после последнего «/» — СПИСОК
    # сетов через запятую (groups.sh агрегирует строки: dnsmasq применяет к домену ровно одну).
    # Поэтому спрашиваем ЧЛЕНСТВО в списке, а не «сет в конце строки»: анкор `[/,]сет$` видел бы
    # только последний сет, и выход, попавший в середину, читался бы как «доменов нет».
    for _s in $(slot_pool_sets "$_c"); do
        awk -F/ -v s="$_s" '/^ipset=/ && NF==3 && ("," $3 ",") ~ ("," s ",") {print $2}' \
            /tmp/dnsmasq.d/*.conf 2>/dev/null >> "$_raw"
    done
}
cmd_domains() {
    _id="$1"; [ -n "$_id" ] || _id=0
    case "$_id" in
        zapret|0) ;;
        *) valid_id "$_id" || { echo "[slots] domains: битый id '$_id'" >&2; return 1; } ;;
    esac
    _cap="$2"; case "$_cap" in ''|*[!0-9]*) _cap=24 ;; esac
    _raw="/tmp/.enodia-slot-doms.$$"; : > "$_raw"
    if [ "$_id" = zapret ]; then
        # Особый «выход» для карточки Zapret: nfqws ОДИН на очередь 212 ⇒ стратегия у транспорта
        # и у всех zapret-выходов ОБЩАЯ, значит честный пул проверки — всё, что он десинкает.
        # Транспорт учитываем, только если zapret и правда активен (иначе его сеты не в игре).
        [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && collect_domains 0
        if [ -s "$SLOTS_FILE" ]; then
            while IFS="$TAB" read -r _zi _zn _zt _zc _zf _ze _zk; do
                [ "$_ze" = on ] && [ "$_zt" = zapret ] && collect_domains "$_zi"
            done < "$SLOTS_FILE"
        fi
    else
        collect_domains "$_id"
    fi
    # Домены 2-го уровня — ВПЕРЁД (у них выше шанс отдать favicon: у CDN-поддоменов его обычно
    # нет вовсе, а «нет картинки» неотличимо от «DPI зарезал»), затем остальные; кап общий.
    _d2='^[A-Za-z0-9-]+\.[A-Za-z][A-Za-z]+$'
    _dn='^[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+$'
    { grep -E "$_d2" "$_raw" 2>/dev/null | sort -u
      grep -E "$_dn" "$_raw" 2>/dev/null | grep -Ev "$_d2" | sort -u
    } > "$_raw.s"
    # Поддомен под живым родителем — ЛИШНЯЯ проба: dnsmasq матчит поддомены сам (инвариант
    # «маска *.дом не нужна») ⇒ ntl.service.konami.net при konami.net в списке едет ТЕМ ЖЕ
    # маршрутом, но фавикона у сервисного поддомена обычно нет вовсе = ложный «красный» в
    # калибровке. Родитель в отсортированном списке всегда ВЫШЕ (домены 2-го уровня идут
    # первыми), поэтому хватает одного прохода. Кап считаем ПОСЛЕ схлопывания — иначе места в
    # пуле занимали клоны одного сайта (железо 28.07: 3 кандидата = 1 сайт).
    _acc=""; _n=0
    while read -r _d; do
        [ -n "$_d" ] || continue
        _skip=""
        for _p in $_acc; do case "$_d" in *".$_p") _skip=1; break ;; esac; done
        [ -n "$_skip" ] && continue
        _acc="$_acc $_d"; echo "$_d"
        _n=$((_n+1)); [ "$_n" -ge "$_cap" ] && break
    done < "$_raw.s"
    rm -f "$_raw" "$_raw.s" 2>/dev/null
    return 0
}

# --- МАРШРУТ ОДНОГО ИМЕНИ («а ЭТОТ домен вообще едет через десинк?») ------------------------
# Вопрос ОТДЕЛЬНЫЙ от `domains`, и реестром на него не ответить: у основного выхода почти весь
# трафик метится по CIDR (iplist_set — тысячи подсетей opencck), доменов у этих сетей нет ВООБЩЕ.
# Значит имя, которого нет ни в одной группе, всё равно может честно ехать через десинк — и без
# этой проверки браузер-тест доступен только тому, кто завёл доменные правила руками, а всем
# остальным недоступен как класс (железо 28.07). Отвечаем ФАКТОМ ЯДРА: резолв + ipset test.
#
# Резолвим СИСТЕМНЫМ резолвером (dnsmasq), намеренно без DoH-обхода из dns-lib: сеты наполняет
# ровно он и клиенты ходят через него же, поэтому чужой ответ дал бы IP, которого в сете нет, —
# вердикт был бы про несуществующий маршрут.
slot_route_sets() {   # <id|0|zapret> -> сеты, попадание в которые = «едет через эту цель»
    case "$1" in
        0)  _rs="enodia_list grp_vpn geo_vpn iplist_set"
            [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && _rs="$_rs zapret_set zapret_cidr zapret_dom geo_zapret"
            echo "$_rs" ;;
        zapret)
            _rs=""
            [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && _rs="zapret_set zapret_cidr zapret_dom geo_zapret"
            if [ -s "$SLOTS_FILE" ]; then
                while IFS="$TAB" read -r _zi _zn _zt _zc _zf _ze _zk; do
                    [ "$_ze" = on ] && [ "$_zt" = zapret ] && _rs="$_rs grp_vpn_s$_zi geo_vpn_s$_zi"
                done < "$SLOTS_FILE"
            fi
            echo "$_rs" ;;
        *)  echo "grp_vpn_s$1 geo_vpn_s$1" ;;
    esac
}
cmd_route() {   # <id|0|zapret> <домен>
    _rid="$1"; [ -n "$_rid" ] || _rid=0
    case "$_rid" in
        zapret|0) ;;
        *) valid_id "$_rid" || { printf 'badhost\t-\t-\n'; return 1; } ;;
    esac
    _rh="$2"
    printf '%s' "$_rh" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$' || { printf 'badhost\t-\t-\n'; return 1; }
    # ВСЕ A-записи имени, а не первую: у CDN/anycast в сете может лежать лишь часть адресов. Разбор
    # вывода busybox nslookup — у dns-lib.sh::ns_ips (там же, почему `$NF` врёт): копий этого awk было
    # две, и третья просилась в проверялку «что победит». БИБЛИОТЕКУ СОРСИМ ЗДЕСЬ, А НЕ В ШАПКЕ: её
    # 47 КБ разбора платил бы КАЖДЫЙ `list-json`, а его зовёт опрос панели. Нет библиотеки (частично
    # доехавший apply-scripts) — прежний путь байт-в-байт.
    if ! command -v ns_ips >/dev/null 2>&1 && [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
    if command -v ns_ips >/dev/null 2>&1; then _rips=$(ns_ips "$_rh")
    else _rips=$(nslookup "$_rh" 2>/dev/null | awk '/^Name:/{f=1} f&&/^Address/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}'); fi
    [ -n "$_rips" ] || { printf 'noresolve\t-\t-\n'; return 0; }
    _rsets=$(slot_route_sets "$_rid")
    for _ri in $_rips; do
        for _rss in $_rsets; do
            ipset test "$_rss" "$_ri" >/dev/null 2>&1 && { printf 'hit\t%s\t%s\n' "$_ri" "$_rss"; return 0; }
        done
    done
    printf 'miss\t%s\t-\n' "$(echo "$_rips" | head -n1)"
    return 0
}

# JSON для панели: слоты + счётчик привязанных ГРУПП на слот (гео — Ф1b, пока 0) + флаг «мест
# нет». name уезжает как name_b64 (в реестре уже base64: кириллица/эмодзи без JSON-эскейпа, как
# title/text в events.sh — панель декодирует b64toUtf8). transport/fallback из whitelist,
# config — имя файла (панель выбирает из готового списка cgi-bin/list, инъекции нет).
# ЧЕСТНЫЙ СТАТУС ВЫХОДА. «on» в реестре — НАМЕРЕНИЕ, а не факт: несущая слота могла не подняться
# (битый конфиг/мёртвый VPS), умереть между тиками watchdog (лаг до 2 мин) или потерять правила
# после fw3-reload. Панель рисовала зелёную точку прямо по строке реестра — тот же класс вранья,
# что «шапка врёт про протокол». Читаем ФАКТЫ ЯДРА, дёшево и БЕЗ egress-проб (блок выходов
# рисуется синхронно, а `transport.sh slot-health` у xray/hy2 — проба на секунды):
#   карриер (awg/xray/hy2/byedpi): есть ip rule метки 0x<id> + default в table 100<id>;
#   zapret:                        марки нет вовсе (mark-core его пропускает) — судим по ОБЩЕМУ
#                                  nfqws + scoped NFQUEUE на сетах слота.
# Ответы: up (несёт свой трафик) · fallback (трафик идёт через запасной выход или основной туннель) ·
#         direct (несущей нет, метка проваливается в main ⇒ трафик выхода идёт НАПРЯМУЮ мимо VPN) ·
#         down (правил выхода нет вовсе — лечит «Починить правила») ·
#         idle (zapret-выход без привязок: десинкать нечего, это не поломка).
slot_report() {   # id, transport, enabled
    [ "$3" = on ] || { printf 'off\tunavailable\n'; return; }
    if ! slot_admitted "$1" "$2"; then printf 'down\tunavailable\n'; return; fi
    if [ "$2" = zapret ]; then
        if sh "$ENODIA_DIR/zapret.sh" slot-health "$1" >/dev/null 2>&1; then printf 'up\tself\n'
        else printf 'down\tunavailable\n'; fi
        return
    fi
    _srl=$(slot_rules_show | slot_rule_rows "$1")
    [ -n "$_srl" ] || { printf 'down\tunavailable\n'; return; }
    _srt=$(printf '%s\n' "$_srl" | slot_rule_path)
    case "$_srt" in
        1000) if [ -f "$ENODIA_STATE/.vpn-off" ]; then printf 'direct\tdirect\n'; else printf 'fallback\tmain\n'; fi ;;
        100[2-7])
            _target=${_srt#100}
            if [ "$_target" = "$1" ]; then _path=self; _health=up; _type=$2
            else _path=$_target; _health=fallback; _type=$(slot_line "$_target" | cut -f3); fi
            case "$_type" in
                xray|hy2|byedpi)
                    netstat -ltn 2>/dev/null | grep -q "127\.0\.0\.1:$(slot_socks_port "$_target")[[:space:]]" || _health=dead ;;
            esac
            if [ "$_health" = up ] && ! sh "$ENODIA_DIR/mark-core.sh" slot-wired "$1" "$2" >/dev/null 2>&1; then
                printf 'down\tunavailable\n'
            else printf '%s\t%s\n' "$_health" "$_path"; fi ;;
        *) printf 'direct\tdirect\n' ;;
    esac
}
# Machine status: id⇥state⇥installed path for every exit in the registry. The first two columns retain their meaning.
# cgi-bin/status (индикатор «выход не работает» в шапке) и диагностика.
cmd_state() {
    [ -s "$SLOTS_FILE" ] || return 0
    while IFS="$TAB" read -r id nb t cfg fb en keep || [ -n "$id" ]; do
        [ -n "$id" ] || continue
        valid_id "$id" || continue
        printf '%s%s%s\n' "$id" "$TAB" "$(slot_report "$id" "$t" "$en")"
    done < "$SLOTS_FILE"
}

# Bindings of ONE exit -> _bc (groups), _be (geo «в VPN»), _bk (geo keys as a JSON list body). Asked per exit, not
# tallied into per-id variables: a tally keeps one branch per id and silently drops every id the branches do not name
# (exits 5..7 read as «0 groups, 0 geo» while bound — review s.106). Group rows count whatever their state, as before.
# Geo: 5th column of geo/actions.tsv (key⇥action⇥cnt⇥ts⇥slot); the slot is valid only with action=vpn (geo.sh keeps it).
# Keys are [a-z0-9._!-] (no JSON escape needed; the CGI sanitises the charset again) — the panel lights preset chips by them.
slot_bindings() {   # $1 = id
    _bc=0; _be=0; _bk=''
    if [ -f "$_gtsv" ]; then
        while IFS="$TAB" read -r _gid _gen _gdir _gslot _gname _gsrc; do
            [ "$_gslot" = "$1" ] && _bc=$((_bc+1))
        done < "$_gtsv"
    fi
    if [ -f "$_geor" ]; then
        while IFS="$TAB" read -r _bkey _ga _gcnt _gt _gs; do
            [ "$_ga" = vpn ] && [ "$_gs" = "$1" ] || continue
            _be=$((_be+1)); _bk="$_bk${_bk:+,}\"$_bkey\""
        done < "$_geor"
    fi
}

cmd_list_json() {
    _gtsv="$ENODIA_STATE/groups/groups.tsv"
    _geor="$ENODIA_STATE/geo/actions.tsv"
    _n=0; _first=1; _krlx=0; _krix=0   # держатели ключей — один раз на ответ, а не на выход (живой ключ = вызовы awg)
    # Roads (road.sh) and WARP (warp.sh) — once per answer: «who rides this exit» (the panel refuses to disable or delete a ridden
    # exit before the click and names the riders) and «is its config WARP» (the Cloudflare point card). The owners answer; here
    # only the filter by id / config name.
    _rdl=''; if [ -f "$ENODIA_DIR/road.sh" ] && [ -s "$ENODIA_STATE/.cfg-via" ]; then _rdl=$(sh "$ENODIA_DIR/road.sh" list 2>/dev/null); fi
    _wpl=''; if [ -f "$ENODIA_DIR/warp.sh" ]; then _wpl=$(sh "$ENODIA_DIR/warp.sh" list 2>/dev/null | cut -f1); fi
    printf '{"slots":['
    if [ -s "$SLOTS_FILE" ]; then
        while IFS="$TAB" read -r id nb t cfg fb en keep || [ -n "$id" ]; do
            valid_id "$id" || continue
            _n=$((_n+1))
            [ "$_first" = 1 ] || printf ','
            _first=0
            slot_bindings "$id"
            # state — честный статус (см. slot_report): панель красит точку и объясняет, почему
            # включённый выход не везёт трафик. Выключенный не щупаем (правил у него нет).
            _sr=$(slot_report "$id" "$t" "$en")
            _st=${_sr%%"$TAB"*}; _path=${_sr#*"$TAB"}
            case "$fb" in main|direct) ;; *) slot_tunnel "$t" && valid_id "$fb" || fb=main ;; esac
            # key_clash — КТО МЕШАЕТ этому awg-выходу (main | s<N> | пусто), и вопрос у включённого и выключенного разный:
            # включённому — «почему не поднимается» (live: держатель занимает сессию СЕЙЧАС — cmd_slot_up откажет, а состояние
            # скажет лишь «несущая не поднялась»), выключенному — «почему не включится» (intent: откажет форма). Иначе работающий
            # выход носил бы плашку «не поднимется», пока ключ лишь числится за выключенным соседом (ревью 27.09.2026).
            # Попадают сюда мимо формы: импорт бэкапа, ручная правка `.slots`, выход, заведённый до гарда.
            _kcl=''
            if [ "$t" = awg ] && [ -f "$AWG_CONFIGS/$cfg.conf" ]; then
                if [ "$en" = on ]; then [ "$_krlx" = 1 ] || { _krl=$(key_rows live); _krlx=1; }; _kr=$_krl
                else [ "$_krix" = 1 ] || { _kri=$(key_rows intent); _krix=1; }; _kr=$_kri; fi
                _kcl=$(awg_ids "$AWG_CONFIGS/$cfg.conf" | key_match "$_kr" "s$id" | head -n1 | cut -f2)
            fi
            # Old panels prefix every rider with awg/. Keep their original list alongside the typed keys.
            _rdr=''; _rlegacy=''
            if [ -n "$_rdl" ]; then
                _rdr=$(printf '%s\n' "$_rdl" | awk -F"$TAB" -v i="$id" '$2 == i { printf "%s\"%s\"", (c++ ? "," : ""), $1 }')
                _rlegacy=$(printf '%s\n' "$_rdl" | awk -F"$TAB" -v i="$id" '$2 == i && $1 ~ /^awg\// { printf "%s\"%s\"", (c++ ? "," : ""), substr($1,5) }')
            fi
            _wp=false; if [ "$t" = awg ] && [ -n "$_wpl" ] && printf '%s\n' "$_wpl" | grep -qxF -- "$cfg"; then _wp=true; fi
            _keep_json=false; [ "$keep" != keep_when_off=1 ] || _keep_json=true
            printf '{"id":%s,"name_b64":"%s","transport":"%s","config":"%s","fallback":"%s","enabled":%s,"state":"%s","groups":%s,"geo":%s,"geo_keys":[%s],"key_clash":"%s","riders":[%s],"road_riders":[%s],"warp":%s,"path":"%s","unapplied":%s,"keep_when_off":%s}' \
                "$id" "$nb" "$t" "$cfg" "$fb" "$([ "$en" = on ] && echo true || echo false)" "$_st" "$_bc" "$_be" "$_bk" "$_kcl" "$_rlegacy" "$_rdr" "$_wp" "$_path" "$([ -f "$SLOTS_PENDING.$id" ] && echo true || echo false)" "$_keep_json"
        done < "$SLOTS_FILE"
    fi
    # Транспорты, готовые нести ДОП-ВЫХОД, — от ОРКЕСТРАТОРА (`transport.sh slot-list`),
    # единственная истина, дублировать не хотим. Именно slot-list, а НЕ list: у выхода свой
    # сервер из каталога, активный конфиг ему не нужен (см. slot_ready в transport.sh) —
    # по `list` xray/hy2 без активации основным в пикер бы не попали. Фолбэк на `list` —
    # для дрейфа деплоя (старый transport.sh без верба: пусто лучше не отдавать).
    # configs для формы панель берёт из /cgi-bin/list (тот же ответ, что у экрана «Серверы»).
    _ready=''
    # `-f`, а не `-x`: зовём через `sh` (класс Б5-9). Снятый бит выключал бы ВЕСЬ пикер
    # транспортов в форме «добавить выход» — панель показала бы «нечего добавить» при живом
    # transport.sh. Так же теперь и все соседние вызовы: форма в проекте ОДНА (см. C27).
    if [ -f "$ENODIA_DIR/transport.sh" ]; then
        _rl=$(sh "$ENODIA_DIR/transport.sh" slot-list 2>/dev/null) || _rl=$(sh "$ENODIA_DIR/transport.sh" list 2>/dev/null)
        for _rt in $_rl; do
            _ready="$_ready${_ready:+,}\"$_rt\""
        done
    fi
    # byedpi = установлен ли бинарь ciadpi (для ⋮ «Тест стратегий по пулу» — тестер гоняет
    # ciadpi-стратегии по доменам привязок слота; без бинаря пункт панель прячет). Путь — через
    # bin_path: с включённым накопителем бинарь лежит НА НЁМ, и прежнее `-x "$ENODIA_BIN/byedpi"`
    # врало «не установлен» (железо 04.08 — тот же класс, что geo.sh и nfqws).
    printf '],"count":%s,"max":%s,"full":%s,"ready":[%s],"byedpi":%s}\n' \
        "$_n" "$((MAX_ID-MIN_ID+1))" "$([ "$_n" -ge $((MAX_ID-MIN_ID+1)) ] && echo true || echo false)" "$_ready" \
        "$([ -x "$(bin_path byedpi)" ] && echo true || echo false)"
}

# Имя конфига несущей: обязана быть ОДНА TSV-колонка. Значение с табом/переводом строки
# разъехалось бы по полям реестра (и утащило бы за собой fallback/en — read их схлопывает),
# а поле пишут и CLI, и панель ⇒ валидируем здесь, как transport/fallback: движок обязан быть
# безопасен и из CLI. '-' = «конфига нет» (byedpi/zapret).
# Имя — ОДНОЙ строкой: `grep ^…$` судит построчно, и имя с переводом строки внутри проходило бы по первой строке — а в реестр
# (TSV) легла бы лишняя строка и обрезанная эта (ревью пачки 2: POST переименования с `%0A` дописывал в .slots выход №7).
valid_config() {
    case "$1" in
        -) return 0 ;;
        '') return 1 ;;
        *) [ "$(printf '%s' "$1" | wc -l)" -eq 0 ] && printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$' ;;
    esac
}

# --- «ЭТОТ КЛЮЧ AmneziaWG УЖЕ ЗАНЯТ?» — ЕДИНСТВЕННЫЙ ответ на роутер ----------------------------------
# Сервер WireGuard/AmneziaWG опознаёт клиента по КЛЮЧУ, и сессия у ключа ОДНА: два наших демона на одном
# ключе (основной awg0 — живой или ТЁПЛЫМ РЕЗЕРВОМ — и выход awgN, либо два выхода) перетягивают её, и
# выход переустанавливает рукопожатие каждые 25–40 с (замер на BE3600 тестера 10.09.2026: конфиг
# выхода был тем же файлом, что у основного). Человек видит «выход не работает» и письмо про мёртвый
# сервер, а сервер жив — связать это сам он не может: в панели нет ни строчки о занятом ключе.
# Сверяем КЛЮЧ, а НЕ имя файла: первое, что сделает человек, которому сказали «заведите выходу свой
# конфиг», — скопирует файл под новым именем, и сверка имён пропустила бы ту же беду. ИДЕНТИЧНОСТЬ
# СЕССИИ — пара «PrivateKey : PublicKey пира»: один клиентский ключ на ДВУХ РАЗНЫХ серверах (пира
# переносят между своими серверами) — две независимые сессии, и отказ был бы ложным (ревью 27.09.2026).
# Пира нет с одной из сторон — судим по одному приватнику. Сам ключ не печатаем НИКОГДА — наружу
# уходят только имена.
# ДВА РЕЖИМА, потому что вопросов два:
#   intent — «можно ли НАЗНАЧИТЬ» (форма: add/set/enable, смена сервера основного, пометки в выборе).
#            Держатели — всё, что поднимется: `awg.conf` основного (его поднимает AmneziaWG основным и
#            держит тёплым резервом, даже когда основной транспорт другой), ключ ЖИВОГО awg0 (резерв мог
#            остаться от прежнего сервера — warm-carrier-keeps-old-server), «дом» режима «Домой»
#            (`.failover-home`: сторож вернётся на него, и возврат упёрся бы в выход) и awg-выходы,
#            ВКЛЮЧЁННЫЕ И НЕТ (выключенный включат позже — беда проявилась бы вдали от места, где её назвать).
#   live   — «поднимать ли СЕЙЧАС» (подъём выхода, transport-awg.sh cmd_slot_up — последний рубеж).
#            Держатели — только те, кто ЗАНИМАЕТ сессию: живой awg0, `awg.conf`, когда основной — AmneziaWG
#            (awg0 встанет с минуты на минуту: порядок подъёма на буте не наш), и ЖИВЫЕ соседние выходы. По
#            намерению тут судить нельзя: выход, заведённый до гарда при основном VLESS и `awg.conf` от
#            прежнего AmneziaWG, работал — и снимался бы на первом же ребуте без письма (ревью 27.09.2026).
#            Два включённых выхода на одном ключе: поднимается первый, второй получает отказ.
# Потребители: add/set/enable (здесь), смена сервера основного канала и перебор его резервов
# (switch-vpn.sh), подъём выхода (transport-awg.sh), пометки «занят» (cgi-bin/list → панель) и
# `key_clash` выхода (list-json). Своих копий не заводить.
# Только AmneziaWG: у VLESS/Hysteria один UUID обычно держит несколько подключений (не замерено ⇒ не
# запрещаем), у byedpi/zapret конфига нет вовсе.
AWG_CONFIGS="$ENODIA_STATE/configs"
# Разбор конфигов — ОДНИМ awk на любое их число (прежний путь звал ~19 процессов на конфиг, а `cgi-bin/list` — это меню
# «Сервер»: 30 конфигов = 571 процесс; ревью 27.09.2026). Имя ключа — без учёта регистра (как у wg), комментарий `# …` после
# значения — вон, префикс ОТРЕЗАЕМ, а не делим по «=»: ключ — base64 с «=» на конце (грабля 27.09.2026 у сверки пира).
# ПИРОВ МОЖЕТ БЫТЬ НЕСКОЛЬКО, и порядок их у userspace-демона случаен (обход Go-map) ⇒ никакого «первого пира»: на каждый пир —
# своя строка «C⇥имя⇥ключ:пир» (пиров нет — «ключ»), и совпадение ЛЮБОЙ пары — одна сессия на двоих (ревью 28.09.2026, круг 2).
# ПРИВАТНИК — В «ПРИЖАТОЙ» ФОРМЕ. Демон хранит ключ после clamping Curve25519 (у первого байта сброшены 3 младших бита, у последнего —
# старший, а соседний взведён), а в конфиге он бывает сырым — сгенерирован не `wg genkey`. Тогда живой ключ (`show private-key`) ≠
# строке файла при ТОМ ЖЕ ключе (замер BE7000 02.10.2026: расходился один знак base64), и «занят ли ключ ЖИВЫМ держателем» не
# находил держателя НИКОГДА: последний рубеж подъёма выхода молчал. Приводим ОБЕ стороны к прижатой форме — она у ключа одна.
# Прижатие трогает ровно три знака base64 (0, 1 и 41 — биты первого и последнего байта), и делается АРИФМЕТИКОЙ, без and()/or():
# битовых функций у busybox awk может не быть. Неканоничная строка (не 44 знака, чужой алфавит) остаётся как есть.
AWG_CLAMP_BEGIN='BEGIN { B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; for (i = 0; i < 64; i++) b64[substr(B, i + 1, 1)] = i }'
AWG_CLAMP='if (length(v) == 44 && (substr(v, 1, 1) in b64) && (substr(v, 2, 1) in b64) && (substr(v, 42, 1) in b64)) { c0 = b64[substr(v, 1, 1)]; c1 = b64[substr(v, 2, 1)]; c41 = b64[substr(v, 42, 1)]; c0 = c0 - c0 % 2; c1 = c1 % 16; c41 = int(c41 / 16) * 16 + 4 + c41 % 4; v = substr(B, c0 + 1, 1) substr(B, c1 + 1, 1) substr(v, 3, 39) substr(B, c41 + 1, 1) substr(v, 43) }'
AWG_ID_AWK="$AWG_CLAMP_BEGIN"'
FNR == 1 && NR > 1 && pk != "" { if (np == 0) print "C\t" nm "\t" pk; for (k = 1; k <= np; k++) print "C\t" nm "\t" pk ":" pe[k] }
FNR == 1 { nm = FILENAME; sub(/.*\//, "", nm); sub(/\.conf$/, "", nm); pk = ""; np = 0 }
{ l = $0; sub(/\r$/, "", l); t = tolower(l) }
t ~ /^[ \t]*privatekey[ \t]*=/ && pk == "" { v = l; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v); gsub(/[ \t]/, "", v); '"$AWG_CLAMP"'; pk = v }
t ~ /^[ \t]*publickey[ \t]*=/ { v = l; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v); gsub(/[ \t]/, "", v); if (v != "") pe[++np] = v }
END { if (pk != "") { if (np == 0) print "C\t" nm "\t" pk; for (k = 1; k <= np; k++) print "C\t" nm "\t" pk ":" pe[k] } }'
awg_ids() { awk "$AWG_ID_AWK" "$@" 2>/dev/null; }             # файлы .conf -> «C⇥имя⇥идентичность» (строка на пир)
awg_key_file() { [ -f "$1" ] || return 0; awg_ids "$1" | cut -f3; }
awg_key_live() {   # $1 = iface -> «ключ:пир» живого демона строкой на пир (пусто, если его нет или нечем спросить)
    ip link show "$1" >/dev/null 2>&1 || return 0
    _kb=$(bin_path awg); [ -x "$_kb" ] || return 0
    # Та же прижатая форма, что у файлов (AWG_CLAMP): демон и так отдаёт прижатый, но правило «обе стороны — через одно» дешевле
    # доверия к чужой реализации.
    _kl=$("$_kb" show "$1" private-key 2>/dev/null | head -n1 | tr -d ' \t\r' | awk "$AWG_CLAMP_BEGIN"' { v = $0; '"$AWG_CLAMP"'; print v }')
    [ -n "$_kl" ] || return 0
    _kp=$("$_kb" show "$1" peers 2>/dev/null | tr -d ' \t\r')
    if [ -z "$_kp" ]; then printf '%s\n' "$_kl"; return 0; fi
    printf '%s\n' "$_kp" | while IFS= read -r _kq; do [ -n "$_kq" ] && printf '%s:%s\n' "$_kl" "$_kq"; done
    return 0
}
# Public keys of the runtime carriers, including a warm AWG main and an exit whose saved config changed.
# The registry can name a different file or key by now. An unreadable live interface invalidates the snapshot.
cmd_live_awg_keys() {
    command -v ip >/dev/null 2>&1 || return 1
    _lpk_bin=$(bin_path awg)
    _lpk_ids=0; _lpk_id=$MIN_ID
    while [ "$_lpk_id" -le "$MAX_ID" ]; do _lpk_ids="$_lpk_ids $_lpk_id"; _lpk_id=$((_lpk_id+1)); done
    for _lpk_id in $_lpk_ids; do
        [ "$_lpk_id:${1:-}" != 0:stop-selected-reserve ] || continue
        ip link show "awg$_lpk_id" >/dev/null 2>&1 || continue
        [ -x "$_lpk_bin" ] || return 1
        _lpk_pub=$("$_lpk_bin" show "awg$_lpk_id" public-key 2>/dev/null) || return 1
        case "$_lpk_pub" in '(none)') continue ;; '') return 1 ;; esac
        printf '%s\t%s\n' "$_lpk_id" "$_lpk_pub"
    done
}
delete_live_holder() {
    _dlh_rows=$(cmd_live_awg_keys "${2:-}") || return 2
    [ -n "$_dlh_rows" ] || return 1
    _dlh_priv=$(awg_key_file "$AWG_CONFIGS/$1.conf" | sed -n '1s/:.*//p')
    [ -n "$_dlh_priv" ] || return 1
    _dlh_bin=$(bin_path awg)
    _dlh_pub=$(printf '%s\n' "$_dlh_priv" | "$_dlh_bin" pubkey 2>/dev/null) || return 2
    [ -n "$_dlh_pub" ] || return 2
    _dlh_id=$(printf '%s\n' "$_dlh_rows" | awk -F "$TAB" -v key="$_dlh_pub" '$2 == key { print $1; exit }')
    case "$_dlh_id" in
        '') return 1 ;;
        0)
            _dlh_at=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
            if [ ! -f "$ENODIA_STATE/.vpn-off" ] && [ "${_dlh_at:-awg}" = awg ]; then key_busy_msg "$1" main
            else echo 'Конфиг используется резервом AmneziaWG — сначала выберите другой сервер.'; fi ;;
        *) key_busy_msg "$1" "s$_dlh_id" ;;
    esac
}
key_row() {   # $1 = кто, $2 = имя, $3 = идентичности строками -> R-строки
    printf '%s\n' "$3" | while IFS= read -r _kr1; do [ -n "$_kr1" ] && printf 'R\t%s\t%s\t%s\n' "$1" "$2" "$_kr1"; done
    return 0
}
# key_rows <intent|live|enabled> -> держатели строками «R⇥кто⇥имя⇥идентичность» (кто = main | s<N>). Считаются ОДИН раз на вопрос:
# живой ключ — это два вызова `awg` на интерфейс. Имена переменных — СВОИ (`_r*`): `local` в busybox sh нет.
key_main_rows() {
    _rm=$(awg_key_file "$ENODIA_STATE/awg.conf"); _ra=$(cat "$ENODIA_STATE/.active" 2>/dev/null | tr -d ' \r\n')
    if [ "$_rmode" = intent ] || [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" = awg ]; then
        key_row main "$_ra" "$_rm"
    fi
    # Живой awg0: имя из `.active` — ТОЛЬКО когда он на ключе конфига основного; иначе это резерв ПРЕЖНЕГО сервера, и имя из
    # `.active` назвало бы чужой конфиг. Пустое имя = «неизвестно» (принято в проекте). Сверяем приватник (до «:»).
    _rl=$(awg_key_live awg0)
    if [ -n "$_rl" ]; then
        if [ "$(printf '%s\n' "$_rl" | head -n1 | cut -d: -f1)" = "$(printf '%s\n' "$_rm" | head -n1 | cut -d: -f1)" ]; then
            key_row main "$_ra" "$_rl"
        else key_row main '' "$_rl"; fi
    fi
    if [ "$_rmode" = intent ] && [ "$(cat "$ENODIA_STATE/.failover-mode" 2>/dev/null | tr -d ' \t\r\n')" = home ]; then
        _rh=$(cat "$ENODIA_STATE/.failover-home" 2>/dev/null | tr -d ' \r\n')
        if [ -n "$_rh" ] && [ "$_rh" != "$_ra" ] && valid_config "$_rh"; then
            key_row main "$_rh" "$(awg_key_file "$AWG_CONFIGS/$_rh.conf")"
        fi
    fi
}
key_rows() {
    _rmode="$1"
    [ "$_rmode" = enabled ] || key_main_rows
    [ -s "$SLOTS_FILE" ] || return 0
    # `|| [ -n ]` — последняя строка без перевода строки не теряется (busybox read).
    while IFS="$TAB" read -r _ri _rn _rt _rc _rf _re _rk || [ -n "$_ri" ]; do
        [ "$_rt" = awg ] || continue
        case "$_rmode" in
            intent)  _rk=$(awg_key_file "$AWG_CONFIGS/$_rc.conf") ;;
            live)    [ "$_re" = on ] || continue; _rk=$(awg_key_live "awg$_ri") ;;
            enabled) [ "$_re" = on ] || continue; _rk=$(awg_key_file "$AWG_CONFIGS/$_rc.conf")
                     # The enabled exit references this name even when the file is malformed.
                     [ -n "$_rk" ] || { printf 'R\ts%s\t%s\t\n' "$_ri" "$_rc"; continue; } ;;
        esac
        key_row "s$_ri" "$_rc" "$_rk"
    done < "$SLOTS_FILE"
}
# СВЕРКА — ОДНА на все вопросы: stdin = R-строки держателей, затем C-строки конфигов; -v self = кто спрашивает (main | s<N> |
# none — «все»; себя пропускаем: выход не конфликтует сам с собой, основной — сам с собой). Печатает «конфиг⇥кто⇥имя» на каждое
# совпадение: приватники равны И пиры равны (или пира нет с одной из сторон). Без split()/функций — busybox awk их не умеет.
KEY_MATCH_AWK='
$1 == "R" { n++; rw[n] = $2; rn[n] = $3; rp[n] = $4; next }
$1 == "C" {
    ck = $3; sub(/:.*/, "", ck); ce = ""; if ($3 ~ /:/) { ce = $3; sub(/^[^:]*:/, "", ce) }
    for (i = 1; i <= n; i++) {
        if (rw[i] == self) continue
        if (byname && (rn[i] "") == ($2 "")) { print $2 "\t" rw[i] "\t" rn[i]; continue }
        if (ck == "") continue
        rk = rp[i]; sub(/:.*/, "", rk)
        if (rk == "" || rk != ck) continue
        re = ""; if (rp[i] ~ /:/) { re = rp[i]; sub(/^[^:]*:/, "", re) }
        if (ce != "" && re != "" && ce != re) continue
        print $2 "\t" rw[i] "\t" rn[i]
    }
}'
key_match() {   # $1 = R-строки (key_rows), $2 = self, $3 = compare names too; stdin — C-строки
    { printf '%s\n' "$1"; cat; } | awk -F"$TAB" -v self="$2" -v byname="${3:-0}" "$KEY_MATCH_AWK"
}
# Человеческая причина отказа — ОДНА формулировка на все точки (выход и основной канал говорят одно).
# $1 = имя конфига, $2 = «main⇥имя» | «s<N>⇥имя» (держатель).
key_busy_msg() {
    _mh=$(printf '%s' "$2" | cut -f1); _mhn=$(printf '%s' "$2" | cut -f2)
    # Держатель «main» — СЕРВЕР AmneziaWG основного канала, и называем его так: он занят и тогда, когда основной сейчас
    # другой протокол (резервом и для возврата AmneziaWG держит именно его), и «занят основным каналом» при xray сбивало бы.
    case "$_mh" in
        main) _mwho="сервер AmneziaWG основного канала" ;;
        *)    _mwho="конфиг выхода №${_mh#s}" ;;
    esac
    if [ "$_mhn" = "$1" ]; then
        _mwhat="конфиг «$1» уже занят: это $_mwho"
    elif [ -n "$_mhn" ]; then
        _mwhat="у конфига «$1» тот же ключ, что у «$_mhn», а это $_mwho"
    else
        _mwhat="у конфига «$1» тот же ключ, что у $(printf '%s' "$_mwho" | sed 's/^сервер /сервера /; s/^конфиг /конфига /')"
    fi
    echo "$_mwhat. Один ключ AmneziaWG не держит два подключения: сервер оставит одно, и второе будет постоянно отваливаться. Заведите отдельный конфиг (с другим ключом)."
}
key_self() { case "$1" in main|none) printf '%s' "$1" ;; *) printf 's%s' "$1" ;; esac; }
# key-holder <имя конфига> <main|2..7> [live] — CLI-вход для switch-vpn.sh (intent) и transport-awg.sh (live).
# Код: 0 — ЗАНЯТ (в stdout причина словами), 1 — свободен, 2 — судить не по чему (нет файла/ключа).
# enabled is the delete check: include enabled intents and the current public key of every carrying interface.
cmd_key_holder() {
    _kc="$1"; _ks=$(key_self "$2"); _kmode=intent; _kn=0
    case "$3" in live) _kmode=live ;; enabled) _kmode=enabled; _kn=1 ;; esac
    valid_config "$_kc" && [ "$_kc" != '-' ] || return 2
    [ -f "$AWG_CONFIGS/$_kc.conf" ] || return 2
    _kid=$(awg_ids "$AWG_CONFIGS/$_kc.conf")
    if [ -z "$_kid" ]; then
        [ "$_kn" = 1 ] || return 2
        _kid=$(printf 'C\t%s\t' "$_kc")
    fi
    _kh=$(printf '%s\n' "$_kid" | key_match "$(key_rows "$_kmode")" "$_ks" "$_kn" | head -n1 | cut -f2-)
    if [ -z "$_kh" ]; then
        [ "$_kmode" = enabled ] || return 1
        delete_live_holder "$_kc" "${4:-}"
        return $?
    fi
    key_busy_msg "$_kc" "$_kh"
    return 0
}
# key-map — ПОМЕТКИ для выбора конфига в панели: «имя⇥держатели» (через запятую: main, s2…) по каждому
# конфигу configs/, чей ключ держит основной канал или выход (intent). Сами их конфиги — тоже: панель вычтет
# «себя» и отличит «это мой» от «занят чужим»; ВСЕ держатели, а не первый — иначе при двух выходах на
# одном ключе (импорт бэкапа, ручная правка) предупреждение досталось бы только одному. Незанятые не печатаем.
cmd_key_map() {
    [ -d "$AWG_CONFIGS" ] || return 0
    # Только читаемые файлы: busybox awk на первом же нечитаемом (каталог с именем *.conf, битые права) бросает ВЕСЬ проход, и
    # пометок не осталось бы ни у одного конфига.
    set --; for _kf in "$AWG_CONFIGS"/*.conf; do [ -f "$_kf" ] && [ -r "$_kf" ] && set -- "$@" "$_kf"; done
    [ $# -gt 0 ] || return 0
    awg_ids "$@" | key_match "$(key_rows intent)" none | awk -F"$TAB" '
        { kk = $1 "\t" $2; if (kk in s) next; s[kk] = 1
          if ($1 in h) h[$1] = h[$1] "," $2; else { k++; o[k] = $1; h[$1] = $2 } }
        END { for (i = 1; i <= k; i++) print o[i] "\t" h[o[i]] }'
}
# Гард назначения конфига ВЫХОДУ (add/set config/enable): занят — отказ причиной. $1 = транспорт,
# $2 = конфиг, $3 = id выхода (у add — «new»: себя в реестре ещё нет).
slot_key_guard() {
    [ "$1" = awg ] || return 0
    _kg=$(cmd_key_holder "$2" "$3") || return 0
    echo "[slots] $_kg"
    return 1
}

# A HEAVY EXIT (Xray, Hysteria2) is a second Go daemon beside the main tunnel, and on a 393-MB router the second one took the tunnel
# down with it (BE6500 tester, OOM 24.10.2026). Created or switched on only while there is room (daemon-lib.sh::daemon_ram_room);
# AmneziaWG, ByeDPI and Zapret are light and pass. The person's action is asked, not the watchdog's re-raise of a running exit.
slot_ram_guard() {   # $1 = transport
    case "$1" in xray|hy2) ;; *) return 0 ;; esac
    command -v daemon_ram_room >/dev/null 2>&1 || return 0
    daemon_ram_room "$DAEMON_GO_NEED_KB" && return 0
    if [ "$1" = xray ]; then _srg=Xray; else _srg=Hysteria2; fi
    echo "[slots] мало свободной памяти для ещё одного $_srg ($DAEMON_RAM_WHY) — выход не поднимаю: он уронил бы основной туннель"
    return 1
}

# A ROAD exit (road.sh: a server's packets ride it) somebody rides can't be disabled, deleted or moved to another transport, and
# can't take a config that rides a road itself (a road is one step): the rider would be left on a cut road — a server that
# silently goes direct to its blocked address. Refusal in words with the riders named; the panel's door leads to them.
slot_road_guard() {   # $1 = id, $2 = what the person tried (words)
    [ -f "$ENODIA_DIR/road.sh" ] || return 0
    _srr=$(_sr_sep=''; sh "$ENODIA_DIR/road.sh" riders "$1" 2>/dev/null | while IFS= read -r _sr_key; do
        _sr_file=${_sr_key#*/}
        _sr_name=$(sh "$ENODIA_DIR/cfg-names.sh" display "${_sr_key%%/*}" "$_sr_file" 2>/dev/null) || _sr_name=''
        printf '%s%s' "$_sr_sep" "${_sr_name:-$_sr_file}"
        _sr_sep=', '
    done)
    [ -n "$_srr" ] || return 0
    printf '%s\n' "[slots] выход №$1 служит дорогой к серверу ($_srr) — сначала переключите их дорогу на «напрямую», потом $2"
    return 1
}

# The first free exit id → stdout; none — code 1 (the words — SLOTS_FULL). ONE owner of «is there room»: `add` under its lock,
# and verb `free` for whoever must know BEFORE the work an exit would end (warp.sh get registers at Cloudflare first).
slot_free_id() {
    _sfi=$MIN_ID
    while [ "$_sfi" -le "$MAX_ID" ]; do
        [ -z "$(slot_line "$_sfi")" ] && { echo "$_sfi"; return 0; }
        _sfi=$((_sfi+1))
    done
    return 1
}
SLOTS_FULL="[slots] мест нет: заняты все $((MAX_ID-MIN_ID+1)) доп-выходов"

# Revalidate the file under the same registry lock that deletion takes.
slot_config_present() {
    case "$1/$2" in
        */-) return 0 ;;
        awg/*) [ -f "$AWG_CONFIGS/$2.conf" ] ;;
        xray/*) [ -f "$ENODIA_STATE/xray-configs/$2.json" ] ;;
        hy2/*) [ -f "$ENODIA_STATE/hy2-configs/$2.yaml" ] ;;
        *) return 0 ;;
    esac && return 0
    echo 'Конфиг для выхода не найден — выберите сервер.'
    return 1
}

cmd_add() {
    name="$1"; t="$2"; cfg="${3:--}"; fb="${4:-main}"
    keep=$(keep_token "${5:-0}") || { echo '[slots] keep_when_off = 0|1'; return 1; }
    [ -n "$name" ] || { echo "[slots] имя обязательно"; return 1; }
    valid_transport "$t" || { echo "[slots] неизвестный транспорт '$t' (awg|xray|hy2|byedpi|zapret)"; return 1; }
    valid_config "$cfg" || { echo "[slots] недопустимое имя конфига (буквы, цифры, . _ - или '-')"; return 1; }
    slot_config_present "$t" "$cfg" && slot_key_guard "$t" "$cfg" new || return 1
    slot_ram_guard "$t" || return 1
    id=$(slot_free_id) || { echo "$SLOTS_FULL"; return 1; }
    fallback_guard "$id" "$fb" "$t" || return 1
    _slots_write "$id" "$(b64e "$name")" "$t" "$cfg" "$fb" on "$keep" || { echo "$SLOTS_NOWRITE"; return 1; }
    # Строка пишется сразу en=on ⇒ выход ОБЯЗАН начать работать здесь же, а не через тик
    # watchdog: поднимаем несущую и переигрываем владельцев (ровно как enable) — см. slot_activate.
    slot_apply "$id" slot_rebind || return 1
    # «-» = «конфига нет» (zapret) — в сообщении не показываем, иначе «(zapret · -)».
    if [ "$cfg" = '-' ]; then _cfgh=""; else _cfgh=" · $cfg"; fi
    echo "[slots] выход №$id «$name» ($t$_cfgh) создан, fallback=$fb"
}

# rename-config <транспорт> <старое> <новое> — конфиг ПЕРЕИМЕНОВАН (cgi-bin/action::rename_config): у всех выходов этого
# транспорта со старым именем поле config → новое. Несущую НЕ трогаем: работающий демон держит уже прочитанный конфиг, а его
# рабочая копия названа по НОМЕРУ слота. Без правки реестра первый же переподъём (сторож, heal, ребут) не нашёл бы конфиг и увёл
# выход на запасной путь. Печатает число переписанных строк (0 — выходов на этом конфиге нет).
cmd_rename_config() {
    t="$1"; old="$2"; new="$3"
    valid_transport "$t" || { echo "[slots] неизвестный транспорт '$t'"; return 1; }
    { [ "$old" != '-' ] && valid_config "$old" && [ "$new" != '-' ] && valid_config "$new"; } \
        || { echo "[slots] недопустимое имя конфига"; return 1; }
    [ -f "$SLOTS_FILE" ] || { echo 0; return 0; }
    slots_lock_take || { echo "[slots] реестр занят другой операцией — повторите"; return 1; }
    # Новое имя уже указано у выхода (его сервер удалили, а ссылка осталась) — переименование ТИХО привязало бы этот выход к
    # переименованному серверу. Отказ словами. Откат (обратное переименование, когда `mv` файла не удался) проходит ту же проверку,
    # но старого имени у выходов после прямого прохода уже нет — отказа не будет.
    # The name is compared AS TEXT (`x ""`): awk takes a `-v` value that looks like a number for one, and «01» was «1» — a rename
    # to «01» was refused while an exit named config «1».
    _rdup=$(awk -F"$TAB" -v t="$t" -v n="$new" '$3==t && ($4 "") == (n "") { print $1; exit }' "$SLOTS_FILE" 2>/dev/null)
    if [ -n "$_rdup" ]; then slots_lock_drop; echo "[slots] имя «$new» уже указано у выхода №$_rdup — выберите другое"; return 1; fi
    # How many exits name the old config — asked FIRST: the rewrite itself runs as lbl_commit_out's producer, in a subshell.
    _rn=$(_slots_renamed "$t" "$old" "$new" count) \
        || { slots_lock_drop; echo "[slots] реестр выходов не читается — переименование не выполнено"; return 1; }
    case "$_rn" in ''|*[!0-9]*) _rn=0 ;; esac
    # Whole or not at all (label-lib.sh). The registry was built by `printf >> temp` in a loop with nobody asking the codes, then
    # `mv` — on a full partition a stump replaced it (review s.127, round 2; the last registry writer outside _slots_write).
    if [ "$_rn" -gt 0 ] && ! lbl_commit_out "$SLOTS_FILE" _slots_renamed "$t" "$old" "$new"; then
        slots_lock_drop; echo "$SLOTS_NOWRITE"; return 1
    fi
    slots_lock_drop
    echo "$_rn"
}
# The registry with config $2 of transport $1 renamed to $3 — to stdout; $4 = count — only the number of lines that changes.
# `|| [ -n ]` — последняя строка без перевода строки не теряется (busybox read).
_slots_renamed() {
    _rnn=0
    while IFS="$TAB" read -r _i _nb _t _c _f _e _k || [ -n "$_i" ]; do
        [ -n "$_i" ] || continue
        if [ "$_t" = "$1" ] && [ "$_c" = "$2" ]; then _c="$3"; _rnn=$((_rnn+1)); fi
        if [ "${4:-}" != count ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s' "$_i" "$_nb" "$_t" "$_c" "$_f" "$_e"
            [ -z "$_k" ] || printf '\t%s' "$_k"
            printf '\n'
        fi
    done < "$SLOTS_FILE" || return 1
    [ "${4:-}" != count ] || echo "$_rnn"
}

keep_token() { case "$1" in 0) return 0 ;; 1) printf 'keep_when_off=1' ;; *) return 1 ;; esac; }

# Переписать одно поле строки id. Правка через временный файл + mv (атомарно на /data,
# как весь персист проекта) — sed по TSV с base64 внутри хрупок, собираем строку заново.
cmd_set() {
    id="$1"; field="$2"; val="$3"
    valid_id "$id" || { echo "[slots] id = $MIN_ID..$MAX_ID"; return 1; }
    line=$(slot_line "$id"); [ -n "$line" ] || { echo "[slots] нет слота №$id"; return 1; }
    old_nb=$(echo "$line" | cut -f2); old_t=$(echo "$line" | cut -f3)
    old_cfg=$(echo "$line" | cut -f4); old_fb=$(echo "$line" | cut -f5); old_en=$(echo "$line" | cut -f6)
    old_keep=$(printf '%s\n' "$line" | cut -f7)
    reup=0
    case "$field" in
        name)      old_nb=$(b64e "$val") ;;
        transport) valid_transport "$val" || { echo "[slots] неизвестный транспорт '$val'"; return 1; }
                   if [ "$val" = zapret ] && [ -n "$(fallback_dependants "$id")" ]; then
                       echo 'Запасным может быть только туннельный выход'; return 1
                   fi
                   if [ "$old_t" = zapret ] && valid_id "$old_fb"; then old_fb=main; fi
                   if [ "$val" = zapret ]; then fallback_guard "$id" "$old_fb" "$val" || return 1; fi
                   old_t="$val" ;;
        config)    valid_config "$val" || { echo "[slots] недопустимое имя конфига (буквы, цифры, . _ - или '-')"; return 1; }
                   old_cfg="$val" ;;
        fallback)  fallback_guard "$id" "$val" "$old_t" || return 1
                   old_fb="$val" ;;
        keep_when_off)
            new_keep=$(keep_token "$val") || { echo '[slots] keep_when_off = 0|1'; return 1; }
            if [ "$old_en" = on ] && [ -f "$ENODIA_STATE/.vpn-off" ] && [ "$old_keep" != "$new_keep" ]; then
                if [ -z "$new_keep" ]; then
                    slot_disable "$id" _slots_write "$id" "$old_nb" "$old_t" "$old_cfg" "$old_fb" "$old_en" '' || return 1
                    echo "[slots] слот №$id: $field обновлён"
                    return 0
                fi
                slot_ram_guard "$old_t" || return 1
                reup=1
            fi
            old_keep=$new_keep ;;
        *) echo "[slots] поле = name|transport|config|fallback|keep_when_off"; return 1 ;;
    esac
    # Сверка ключа — и при смене КОНФИГА, и при смене ТРАНСПОРТА на awg (конфиг тот, что уже записан).
    case "$field" in transport|config)
        [ "$old_en" != on ] || slot_config_present "$old_t" "$old_cfg" || return 1
        slot_key_guard "$old_t" "$old_cfg" "$id" || return 1 ;;
    esac
    # Road exit: only AmneziaWG carries a road, and its config must go direct itself (road.sh, one step).
    [ "$field" = transport ] && [ "$old_t" != awg ] && { slot_road_guard "$id" "меняйте транспорт" || return 1; }
    # A heavy daemon replacing a light one on an exit that runs (AmneziaWG → Xray) is a second Go daemon now: asked as add/enable are;
    # heavy → heavy frees its own memory first (review s.166 r1).
    if [ "$field" = transport ] && [ "$old_en" = on ]; then
        case "$(echo "$line" | cut -f3)" in xray|hy2) ;; *) slot_ram_guard "$old_t" || return 1 ;; esac
    fi
    if [ "$field" = config ] && [ -f "$ENODIA_DIR/road.sh" ] && [ -n "$(sh "$ENODIA_DIR/road.sh" get "$old_t" "$old_cfg" 2>/dev/null)" ]; then
        slot_road_guard "$id" "ставьте ему конфиг, который сам едет по дороге" || return 1
    fi
    if [ "$field" = config ] && [ "$old_t" = awg ]; then
        slot_road_clash "$id" "$old_cfg" || return 1
    fi
    # Несущая ВКЛЮЧЁННОГО выхода уже поднята по СТАРЫМ (транспорт, конфиг) — одной записи в реестр
    # мало: демон продолжил бы ходить прежним сервером («сменил сервер, а выход тот же»), а смена
    # ТРАНСПОРТА ещё и осиротила бы старую несущую (следующий slot-down ушёл бы уже в НОВЫЙ плагин,
    # и демон/tun/table прежнего остались бы жить). Поэтому: down СТАРЫМ плагином (реестр ещё
    # старый и en=on — диспетч требует именно этого) → запись → up НОВЫМ.
    case "$field" in transport|config) [ "$old_en" = on ] && reup=1 ;; esac
    retire=$reup
    [ "$field:$val" != keep_when_off:1 ] || retire=0
    if [ "$retire" = 1 ]; then slot_deactivate "$id" || return 1; fi
    # A refused write leaves the old row authoritative. Restore its carrier before releasing the registry lock.
    if ! _slots_write "$id" "$old_nb" "$old_t" "$old_cfg" "$old_fb" "$old_en" "$old_keep"; then
        echo "$SLOTS_NOWRITE"
        [ "$retire" != 1 ] || slot_restore_carrier "$id"
        return 1
    fi
    if [ "$reup" = 1 ]; then
        if ! _cs_state=$(slot_apply "$id" slot_rebind report); then
            printf '%s\n' "$_cs_state"
            return 1
        fi
        case "$_cs_state" in
            up) echo "[slots] слот №$id: $field обновлён, несущая перезапущена" ;;
            off) echo "[slots] слот №$id: $field обновлён; VPN выключен вручную — выход поднимется при включении" ;;
            *) echo "[slots] слот №$id: $field обновлён, но несущая не поднялась — выход идёт по запасному пути" ;;
        esac
        return 0
    fi
    # fallback — политику ip rule держит mark-core (владелец правил слота): без переигровки у
    # выхода с УПАВШЕЙ несущей осталась бы прежняя политика (main вместо direct и наоборот).
    if [ "$field" = fallback ] || { [ -f "$ENODIA_STATE/.vpn-off" ] && [ -z "$(cmd_list_admitted)" ]; }; then
        slot_apply "$id" slot_reconcile || return 1
    fi
    echo "[slots] слот №$id: $field обновлён"
}

# Переписать поле en (6-е) строки слота id: под локом, атомарно tmp+mv (как cmd_set).
write_en() {
    line=$(slot_line "$1")
    [ -n "$line" ] || return 1
    _slots_write "$1" "$(printf '%s' "$line" | cut -f2)" "$(printf '%s' "$line" | cut -f3)" \
                 "$(printf '%s' "$line" | cut -f4)" "$(printf '%s' "$line" | cut -f5)" "$2" "$(printf '%s' "$line" | cut -f7)" \
        || { echo "$SLOTS_NOWRITE"; return 1; }
}

slot_reconcile() {
    [ -f "$ENODIA_DIR/mark-core.sh" ] || return 0
    _scr_verb=slot-rules
    if [ -f "$ENODIA_STATE/.vpn-off" ] && [ -z "$(cmd_list_admitted)" ]; then _scr_verb=slot-replay; fi
    CT_SLOT_EDIT="$1" sh "$ENODIA_DIR/mark-core.sh" "$_scr_verb" >/dev/null 2>&1
}

slot_apply() (
    _sa_pending="$SLOTS_PENDING.$1"; _sa_op="$2"
    _sa_last=$(cat "$_sa_pending" 2>/dev/null)
    [ "$_sa_last" != slot_rebind ] || _sa_op=slot_rebind
    if _sa_result=$("$_sa_op" "$1") && rm -f "$_sa_pending"; then
        [ "${3:-}" != report ] || printf '%s\n' "$_sa_result"
        return 0
    fi
    [ "$_sa_last" = "$_sa_op" ] || printf '%s\n' "$_sa_op" > "$_sa_pending"
    echo 'Настройки выхода сохранены, но не применены'
    return 1
)

slot_retry() {
    valid_id "$1" || return 1
    _sp="$SLOTS_PENDING.$1"
    [ -f "$_sp" ] || return 0
    [ -n "$(slot_line "$1")" ] || { rm -f "$_sp"; return $?; }
    case "$(cat "$_sp")" in
        slot_rebind) slot_apply "$1" slot_rebind ;;
        slot_reconcile) slot_apply "$1" slot_reconcile ;;
        *) echo 'Настройки выхода сохранены, но не применены'; return 1 ;;
    esac
}

cmd_retry_pending() {
    set -- "$SLOTS_PENDING".[2-7]
    [ -f "$1" ] || return 0
    slots_lock_take 1 || return 0
    trap 'slots_lock_drop' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    for _sp in "$@"; do
        _pr_id=${_sp##*.}
        slot_retry "$_pr_id" || :
    done
    return 0
}
# Переиграть ВЛАДЕЛЬЦЕВ слот-сетов после смены состояния слота (enable/disable/del).
# ЗАЧЕМ (грабля, поймана на железе 2026-07-26): «какой сет наполнять» решают groups.sh/geo.sh в
# своём do_apply — гейт «привязка к ВЫКЛЮЧЕННОМУ слоту → основной сет (grp_vpn/geo_vpn)». Сам по
# себе disable этот гейт не переигрывает: правила слота мы сняли (unwire), а члены остались в
# осиротевшем grp_vpn_s<N>/geo_vpn_s<N>, на который уже нет НИ ОДНОГО mangle-правила ⇒ пул идёт
# НАПРЯМУЮ (fail-open мимо VPN), хотя fallback=main обещает основной выход; чинилось лишь
# следующим редактированием правил/ребутом. Симметрично на enable: члены сидят в общем grp_vpn и
# едут основным выходом, пока владелец не пересоберётся — «включил выход, а пул не поехал».
# Зовём ТОЛЬКО тех владельцев, у кого реально есть привязка к этому слоту (иначе даром гоняем
# сборку). A busy owner queues its scoped rebuild. The next retry finishes publication after both owners respond.
rebind_owners() (
    [ ! -f "$ENODIA_STATE/.vpn-deactivated" ] || exit 0
    id="$1"; _rb_fail=''
    # Гарды `-f`, а НЕ `-x` (класс Б5-9): все три зовутся через `sh`, бит выполнения им не нужен,
    # а снятый (заливка по scp/base64, ручная копия, чужой архиватор) означал бы ТИХИЙ пропуск
    # пересборки — привязанные к выходу группы/гео/устройства остались бы в осиротевшем сете без
    # mangle, то есть молча поехали мимо выхода. Ровно ради этого rebind_owners и существует.
    if [ -f "$ENODIA_DIR/groups.sh" ] && [ -s "$ENODIA_STATE/groups/groups.tsv" ] &&
       awk -F"$TAB" -v s="$id" '$4==s{f=1} END{exit !f}' "$ENODIA_STATE/groups/groups.tsv" 2>/dev/null; then
        sh "$ENODIA_DIR/groups.sh" rebind >/dev/null || _rb_fail=groups
    fi
    if [ -f "$ENODIA_DIR/geo.sh" ] && [ -s "$ENODIA_STATE/geo/actions.tsv" ] &&
       awk -F"$TAB" -v s="$id" '$5==s{f=1} END{exit !f}' "$ENODIA_STATE/geo/actions.tsv" 2>/dev/null; then
        sh "$ENODIA_DIR/geo.sh" rebind >/dev/null || _rb_fail="$_rb_fail geo"
    fi
    [ -z "$_rb_fail" ]
)

# Ввести слот В СТРОЙ: поднять несущую + переиграть владельцев слот-сетов. ОБЩЕЕ для создания
# (cmd_add пишет строку сразу en=on) и включения (cmd_toggle on) — «выход есть и он on» обязан
# означать одно и то же независимо от пути; звать ТОЛЬКО когда в реестре уже лежит en=on
# (диспетч slot-up в плагин читает поле en — _slot_dispatch). Оркестратор сам переиграет
# mark-core (и марку non-zapret-слота, и врайринг zapret-слота).
# Грабля (железо, 2026-07-26): cmd_add ЭТОГО не делал — «удалил выход и создал заново» (а это
# был ЕДИНСТВЕННЫЙ способ сменить сервер до dev51) оставляло привязанные группы/гео в ОСНОВНОМ
# сете: del честно вернул их в grp_vpn, а add обратно в grp_vpn_s<N> не забрал. Правила слота
# стояли, сет был ПУСТ ⇒ пул молча ехал основным VPN. Несущую тем временем поднимал лишь
# следующий тик watchdog (idem-slot-up) — до него выход не работал вовсе.
slot_deactivate() {
    [ -f "$ENODIA_DIR/transport.sh" ] || return 0
    # 2 = nothing of a plugin to take down (no slot layer, or a transport this code does not know): slot-up raised nothing either.
    # Only a real refusal keeps the exit — else it could be neither disabled nor deleted, and «повторите» would never help.
    CT_SLOT_EDIT=defer sh "$ENODIA_DIR/transport.sh" slot-down "$1" carrier >/dev/null 2>&1 && return 0
    [ "$?" = 2 ] && return 0
    echo "[slots] выход №$1 не снят — настройки сохранены, повторите операцию"
    return 1
}
slot_restore_carrier() {
    [ -f "$ENODIA_DIR/transport.sh" ] || return 0
    # The old rules are still installed. Restore the carrier within the edit's retirement scope.
    CT_SLOT_EDIT=defer sh "$ENODIA_DIR/transport.sh" slot-up "$1" carrier >/dev/null 2>&1
    ct_flush_slot "$1" origin
}
slot_road_clash() {
    [ -f "$ENODIA_DIR/road.sh" ] || return 0
    _scl=$(sh "$ENODIA_DIR/road.sh" clash "$1" "$2" 2>/dev/null)
    [ -z "$_scl" ] || { echo "[slots] выход №$1 служит дорогой, а новый конфиг идёт к серверу $_scl, который уже едет по дороге — выберите конфиг к другому серверу"; return 1; }
}
slot_rebind() (
    _sr_id="$1"; _sr_en=$(slot_line "$1" | cut -f6)
    _sr_rc=0; _sr_state=''
    [ -n "$(slot_rows admitted "$_sr_id")" ] || CT_SLOT_EDIT=defer cmd_unwire "$_sr_id" || _sr_rc=1
    rebind_owners "$_sr_id" || _sr_rc=1
    if [ "$_sr_rc" = 0 ]; then
        if [ -f "$ENODIA_DIR/transport.sh" ]; then
            _sr_state=$(CT_SLOT_EDIT=defer sh "$ENODIA_DIR/transport.sh" slot-rebind "$_sr_id" "$_sr_en" 2>/dev/null) || _sr_rc=1
        elif [ -f "$ENODIA_DIR/mark-core.sh" ]; then
            CT_SLOT_EDIT=defer sh "$ENODIA_DIR/mark-core.sh" slot-replay >/dev/null 2>&1 || _sr_rc=1
        fi
    fi
    # Retire the edited mark. Other marks keep their conntrack entries, but a carrier teardown can end sessions it carried.
    ct_flush_slot "$_sr_id" origin
    [ "$_sr_rc" != 0 ] || [ -z "$_sr_state" ] || printf '%s\n' "$_sr_state"
    return "$_sr_rc"
)


# The registry lock spans old-row teardown, publication and the set owners' retry.
slot_disable() {
    _sd_id=$1; shift
    slot_road_guard "$_sd_id" "выключайте выход" || return 1
    if [ "$(slot_line "$_sd_id" | cut -f6)" = on ]; then slot_deactivate "$_sd_id" || return 1; fi
    if ! "$@"; then slot_restore_carrier "$_sd_id"; return 1; fi
    slot_apply "$_sd_id" slot_rebind
}

cmd_toggle() {
    id="$1"; en="$2"
    valid_id "$id" || { echo "[slots] id = $MIN_ID..$MAX_ID"; return 1; }
    _tl=$(slot_line "$id")
    [ -n "$_tl" ] || { echo "[slots] нет слота №$id"; return 1; }
    if [ "$en" = on ]; then
        _tl_kind=$(printf '%s' "$_tl" | cut -f3); _tl_name=$(printf '%s' "$_tl" | cut -f4)
        if [ "$_tl_kind" = awg ] && { ! valid_config "$_tl_name" || [ ! -f "$AWG_CONFIGS/$_tl_name.conf" ]; }; then
            echo "Нет конфига AmneziaWG для выхода №$id — выберите сервер."
            return 1
        fi
        # Выход, заведённый ДО гарда (или приехавший импортом бэкапа), мог получить занятый ключ: включение
        # — та же точка назначения, что add/set, и отказывает той же причиной, не трогая реестр.
        slot_config_present "$_tl_kind" "$_tl_name" && slot_key_guard "$_tl_kind" "$_tl_name" "$id" || return 1
        if [ "$_tl_kind" = awg ]; then slot_road_clash "$id" "$_tl_name" || return 1; fi
        # Already on (a second tab): its daemon runs and is counted in the memory already — no second admission.
        if [ "$(printf '%s' "$_tl" | cut -f6)" != on ]; then slot_ram_guard "$_tl_kind" || return 1; fi
        # Порядок: сперва пишем on (диспетч slot-up в плагин ТРЕБУЕТ включённый слот —
        # _slot_dispatch читает поле en), затем ввод в строй. Запись не прошла (реестр занят) —
        # НЕ активируем: диспетч всё равно увидел бы off, а мы отрапортовали бы «включён».
        write_en "$id" on || return 1
        slot_apply "$id" slot_rebind || return 1
        echo "[slots] слот №$id включён"
    else
        slot_disable "$id" write_en "$id" off || return 1
        echo "[slots] слот №$id выключен"
    fi
}

# Снять СЛЕДЫ слота из ядра: MARK/ACCEPT его сетов в mangle + ip rule его марки. Сеты и
# таблицу НЕ трогаем (сеты — собственность groups/geo, несущую слота опустит её плагин в Ф1+).
# Offloaded flows can keep their old route after unwiring. Retire them by the exit's saved ct mark.
cmd_unwire() {
    id="$1"
    valid_id "$id" || { echo "[slots] id = $MIN_ID..$MAX_ID"; return 1; }
    for sset in "grp_vpn_s$id" "geo_vpn_s$id"; do
        for chain in PREROUTING OUTPUT ENODIA_SLOT_OUT; do
            while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j ACCEPT 2>/dev/null; do :; done
            while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j MARK --set-mark "0x$id" 2>/dev/null; do :; done
        done
    done
    [ ! -f "$ENODIA_DIR/mark-core.sh" ] || sh "$ENODIA_DIR/mark-core.sh" slot-unrule "$id" >/dev/null 2>&1 || return 1
    ct_flush_slot "$id" origin
}

cmd_del() {
    id="$1"
    valid_id "$id" || { echo "[slots] id = $MIN_ID..$MAX_ID"; return 1; }
    line=$(slot_line "$id"); [ -n "$line" ] || { echo "[slots] нет слота №$id"; return 1; }
    _drefs=$(fallback_dependants "$id")
    [ -z "$_drefs" ] || { echo "На этот выход ссылаются: $_drefs"; return 1; }
    slot_road_guard "$id" "удаляйте выход" || return 1
    # Keep an off row until the owners have moved its bindings. A failed rebind can then be retried.
    if [ "$(printf '%s' "$line" | cut -f6)" = on ]; then
        slot_deactivate "$id" || return 1
        if ! write_en "$id" off; then
            slot_restore_carrier "$id"
            return 1
        fi
    fi
    slot_apply "$id" slot_rebind || return 1
    _slots_write "$id" || { echo "$SLOTS_NOWRITE"; return 1; }
    echo "[slots] слот №$id удалён (правила сняты)"
}

cmd_downgrade_fallbacks() {
    _df_core="$ENODIA_DIR/mark-core.sh"
    if [ -s "$SLOTS_FILE" ]; then
        lbl_commit_out "$SLOTS_FILE" awk -F "$TAB" -v OFS="$TAB" '$5 ~ /^[0-9]+$/ {$5="main"} {print}' "$SLOTS_FILE" || return 1
    fi
    sh "$_df_core" slot-downgrade
}

refresh_registered_config() {   # exit id, kind, file observed by the importer
    [ "$(slot_line "$1" | cut -f3,4,6)" = "$2$TAB$3${TAB}on" ] ||
        { echo '[slots] выход изменился — обновление конфига пропущено'; return 1; }
    cmd_set "$1" config "$3"
}

case "$1" in
    list)         cmd_list ;;
    list-enabled) cmd_list_enabled ;;
    list-admitted) cmd_list_admitted "$2" ;;
    validate-registry) cmd_validate_registry "$2" ;;
    list-json)    cmd_list_json ;;
    state)        cmd_state ;;
    retry)        slots_mutate slot_retry "$2" && echo 'Настройки выхода применены' ;;
    retry-pending) cmd_retry_pending ;;
    slot-plan)    cmd_slot_plan "$2" ;;
    downgrade-fallbacks) slots_mutate cmd_downgrade_fallbacks ;;
    carriers)     cmd_carriers ;;
    configs)      cmd_configs "$2" ;;
    show)         slot_line "$2" ;;
    restore-registry) shift; cmd_restore_registry "$@" ;;
    dispatch-carrier) shift; slots_mutate slot_dispatch_carrier "$@" ;;
    domains)      cmd_domains "$2" "$3" ;;
    route)        cmd_route "$2" "$3" ;;
    add)          slots_mutate cmd_add "$2" "$3" "$4" "$5" "$6" ;;
    free)         slot_free_id || { echo "$SLOTS_FULL"; exit 1; } ;;
    set)          slots_mutate cmd_set "$2" "$3" "$4" ;;
    enable)       slots_mutate cmd_toggle "$2" on ;;
    disable)      slots_mutate cmd_toggle "$2" off ;;
    del)          slots_mutate cmd_del "$2" ;;
    unwire)       cmd_unwire "$2" ;;
    rename-config) cmd_rename_config "$2" "$3" "$4" ;;
    key-holder)   cmd_key_holder "$2" "$3" "$4" "$5" ;;
    live-awg-keys) cmd_live_awg_keys ;;
    # Switch → road map → registry (here) → subscription.
    delete-config|prune-sub)
        [ -f "$ENODIA_DIR/subs-import.sh" ] || { echo 'Обновите скрипты роутера и повторите удаление.'; exit 1; }
        slots_mutate sh "$ENODIA_DIR/subs-import.sh" "$@" ;;
    refresh-config) slots_mutate refresh_registered_config "$2" "$3" "$4" ;;
    key-map)      cmd_key_map ;;
    holders)      cmd_holders "$2" "$3" "$4" ;;
    *) echo "usage: $0 list|list-enabled|list-json|state|carriers|configs <транспорт>|show <id>|domains <id|0> [кап]|route <id|0> <домен>|add <имя> <транспорт> [конфиг] [fallback]|set <id> <поле> <знач>|enable <id>|disable <id>|del <id>|unwire <id>|rename-config <транспорт> <старое> <новое>|key-holder <конфиг> <main|2..7> [live]|key-map|holders <транспорт> <конфиг> [on]"; exit 2 ;;
esac
