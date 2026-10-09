#!/bin/sh
# packages.sh — ДВИЖОК КОМПОНЕНТОВ («связок»): что установлено, сколько займёт/освободит,
# можно ли снять и почему нет, и собственно установка/удаление по ПЛАНУ.
#
# ЗАЧЕМ отдельный движок, когда есть proto-install.sh: тот знает только ФИКСИРОВАННЫЕ наборы
# (awg-xray, awg-hy2, …) и потому врёт про реальный роутер — на живом BE7000 автора одновременно
# стоят xray (основная несущая) и byedpi (несёт доп-выход №2), а панель рисует «AmneziaWG + Xray»,
# потому что комбо такого не предусматривает. Модульность = привести UI к тому, что уже есть.
#
# ЕДИНИЦА — НЕ бинарь, а СВЯЗКА на протокол: «Xray» = xray + hev, «AmneziaWG» = amneziawg-go + awg
# (CLI), «ByeDPI» = byedpi + hev. Человек мыслит протоколами, а не файлами; связка «awg без CLI»
# уже ловилась как «готов, но awg0 не встаёт» ([[awg-ready-needs-both-binaries]]).
#
# УСТАНОВЛЕН ≠ АКТИВЕН. Рядом могут лежать несколько альтов (если влезли); трафик несёт один —
# это стережёт transport.sh, а доп-выходы (слоты) имеют свой socks 10830+id. Поэтому движок НИЧЕГО
# не переключает: он только кладёт и снимает файлы. Активация — transport.sh switch из панели.
#
# ПОРЯДОК ОПЕРАЦИИ (грабли флеша): удаления ВСЕГДА первыми → sync (UBIFS пишет лениво, иначе df
# завышает «занято» и гард ложно блокирует) → закачки. Отсюда и форма верба: ОДИН план
# «поставить X, снять Y», а не два независимых действия — замена Xray→Hysteria2 при неснижаемом
# резерве иначе распадается на два прогона, между которыми роутер остаётся без транспорта.
#
# РЕЗЕРВ /data — ЖЁСТКИЙ (2.5 МБ, цифра одна и живёт в store-lib.sh). /data всего 20.6 МБ, и «в
# ноль» его выбирать нельзя: там же логи, снимки
# гео, бэкапы обновлений, а UBIFS без свободных блоков начинает отдавать ENOSPC на ровном месте.
# Не хватило — план возвращает ok=false и СПИСОК того, что можно снять (панель предлагает выбор).
#
# Прогресс — ТОТ ЖЕ протокол и ТЕ ЖЕ файлы, что у proto-install.sh (.proto-install.{state,log} +
# лок /tmp/enodia-proto-install.lock): панель уже умеет их опрашивать, а «две установки разом» на 20-МБ
# флеше — ровно тот случай, который лок и придуман не пускать.
#
# rm живёт ЗДЕСЬ (PS-guard на литерал rm). set -e НЕ используем — шаги best-effort.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Бутстрап — ЕДИНСТВЕННЫЙ каталог, про который известно, что он на флеше РОУТЕРА в любой
# раскладке. Нужен не для запуска, а чтобы ответить «а тот ли это носитель» (disk_on_store).
ENODIA_BOOT=${ENODIA_BOOT:-/data/usr/app/enodia-boot}
# Где лежит бинарь (store-lib.sh). Движку это нужно, чтобы «установлен ли» и «сколько
# освободит» отвечали про ФАКТИЧЕСКИЙ файл, а не про ожидаемое место: связка, уехавшая на
# внешний накопитель, обязана оставаться «установленной». Без накопителя — прежний путь.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
# Журнал операции → элементы JSON-массива (op-json). Библиотеки нет (смешанное обновление) — журнал пустой, а не битый ответ.
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
# Old library: the restart takes the lock only when it is free — no waiting for the watchdog (the behaviour before switch_hold).
command -v switch_hold >/dev/null 2>&1 || switch_hold() { ( set -C; echo $$ > "$1" ) 2>/dev/null; }
# Does the main carrier carry right now (cmd_restart) — the owner's answer, ip-lib.sh::carrier_iface (C81).
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v carrier_iface >/dev/null 2>&1 || carrier_iface() { ip route show table 1000 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
command -v jlines >/dev/null 2>&1 || jlines() { cat >/dev/null; }
command -v bin_path   >/dev/null 2>&1 || bin_path()   { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_dest   >/dev/null 2>&1 || bin_dest()   { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_prune  >/dev/null 2>&1 || bin_prune()  { return 0; }
command -v store_ready >/dev/null 2>&1 || store_ready() { return 1; }
command -v store_root  >/dev/null 2>&1 || store_root()  { printf ''; }
# fs_* — «сколько места на томе, которому принадлежит путь». Шим повторяет библиотечную форму
# ОДИН В ОДИН, включая гард на пустой ответ df (нет пути, чужой формат): без него `%s` в
# list-json дал бы `"free_b":,` — синтаксически битый JSON, то есть «карточка Компонентов не
# открылась». Ровно этот гард ради того же и стоит в usb-offload.sh (num()).
command -v fs_anchor  >/dev/null 2>&1 || fs_anchor()  { _fan="${1:-$ENODIA_DIR}"; while [ -n "$_fan" ] && [ ! -e "$_fan" ]; do _fan="${_fan%/*}"; done; printf '%s' "${_fan:-/}"; }
command -v fs_line    >/dev/null 2>&1 || fs_line()    { df -k "$(fs_anchor "$1")" 2>/dev/null | tail -1 | awk '{for(i=NF;i>1;i--) if($i ~ /%$/) break; if(i>=4 && $(i-3) ~ /^[0-9]+$/ && $(i-1) ~ /^[0-9]+$/ && $(i-3)+0>0){m=""; for(j=i+1;j<=NF;j++){ if(j>i+1) m=m " "; m=m $j }; print $(i-3), $(i-1), m}}'; }
command -v fs_free_b  >/dev/null 2>&1 || fs_free_b()  { _fsb=$(fs_line "$1" | awk '{printf "%.0f", $2*1024}'); case "$_fsb" in ''|*[!0-9]*) _fsb=0 ;; esac; printf '%s' "$_fsb"; }
command -v fs_total_b >/dev/null 2>&1 || fs_total_b() { _fst=$(fs_line "$1" | awk '{printf "%.0f", $1*1024}'); case "$_fst" in ''|*[!0-9]*) _fst=0 ;; esac; printf '%s' "$_fst"; }
command -v fs_mount   >/dev/null 2>&1 || fs_mount()   { _fsm=$(fs_line "$1"); printf '%s' "${_fsm#* * }"; }
# БЕЗ store-lib.sh переменная пуста, а do_remove сравнивает её с $ENODIA_DIR и делает rm по
# "$BIN_DIR/$b" — то есть по «/имя» в корне. Дефолт закрывает весь этот класс разом.
: "${BIN_DIR:=$ENODIA_DIR}"
# То же и для резерва: цифра живёт в store-lib.sh (её сторожит и usb-offload.sh, возвращая бинари
# с накопителя), а литерал здесь — ровно шим для установки без библиотеки.
: "${DATA_RESERVE_B:=2621440}"
GH="$ENODIA_DIR/gh-update.sh"
STATE="$ENODIA_STATE/.proto-install.state"
LOG="$ENODIA_STATE/.proto-install.log"
# ЧТО ставит/снимает текущая (или последняя) операция — «<ставим>\t<снимаем>», как их передали. «Идёт ли установка» не
# отвечает на «чья»: экран «Шифрованного DNS» выдавал установку Xray из «Компонентов» за свою (ревью шага 5a, круг 2).
# Живёт рядом с .state/.log (та же маска исключения бэкапа) и переживает конец операции: по нему понятно, ЧЬЯ последняя
# строка лога. Пишет cmd_apply первым делом; фоновый запуск из панели (pkg_bg) обнуляет его вместе с логом.
PLANF="$ENODIA_STATE/.proto-install.plan"
LOCK=/tmp/enodia-proto-install.lock
# PID фонового запуска из панели (его пишет spawn_bg в cgi-bin/action). Нужен ВЕРБУ busy: лок
# несёт pid САМОГО движка, но в окне между стартом обёртки и `mkdir` лока его ещё нет, а человек
# уже нажал кнопку. Два источника отвечают на один вопрос — поэтому оба читает ОДИН верб.
BGPID=/tmp/enodia-proto-install.pid
RESERVE_B="$DATA_RESERVE_B"   # 2.5 МБ неснижаемого запаса на /data (единственная цифра — в store-lib.sh)

# Реестр связок. Новый компонент = ОДНО слово в PKGS + по строке в трёх case ниже.
PKGS="awg xray hy2 byedpi zapret doh tls filter"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
# СОСТОЯНИЕ ПИШЕМ АТОМАРНО (запись рядом + `mv`): `>` сперва ОБРЕЗАЕТ файл, и читатель, попавший между обрезкой и записью,
# видит ПУСТОЙ файл = «IDLE». Опрос панели стартует сразу после ответа на «Применить» — ровно когда движок переписывает
# RUNNING поверх RUNNING из CGI, — и в эту долю секунды решал «установка кончилась, не удалось» (замер BE7000 23.09.2026:
# `pkg_op` отдал `state:IDLE` через секунду после запуска, панель перерисовала экран до начала операции). `.new` — под маской
# мусора clean.sh: оборванная запись не копится.
set_state() { echo "$1" > "$STATE.new" && mv -f "$STATE.new" "$STATE"; }

pkg_known()  { case " $PKGS " in *" $1 "*) return 0 ;; esac; return 1; }
pkg_label()  { case "$1" in
        awg) echo "AmneziaWG" ;; xray) echo "Xray" ;; hy2) echo "Hysteria2" ;;
        byedpi) echo "ByeDPI" ;; zapret) echo "Zapret" ;;
        doh) echo "Шифрованный DNS" ;; tls) echo "HTTPS панели" ;; filter) echo "Фильтр по категориям" ;;
    esac; }
# Свои бинари связки (их и удаляем).
pkg_own()    { case "$1" in
        awg) echo "amneziawg-go awg" ;; xray) echo "xray" ;; hy2) echo "hysteria" ;;
        byedpi) echo "byedpi" ;; zapret) echo "nfqws" ;;
        doh) echo "https-dns-proxy dot-proxy" ;; tls) echo "panel-tls" ;; filter) echo "dns-filter" ;;
    esac; }
# ОБЩИЕ бинари: нужны связке, но принадлежат не ей (ref-count при удалении).
pkg_shared() { case "$1" in xray|hy2|byedpi) echo "hev" ;; esac; }
# Всё, что должно лежать, чтобы связка РАБОТАЛА (наличие + размер установки).
pkg_files()  { echo "$(pkg_own "$1") $(pkg_shared "$1")"; }

have_bin() { [ -x "$(bin_path "$1")" ]; }
in_list()  { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# --- СВЕЖЕСТЬ СТОЯЩЕГО ------------------------------------------------------------------
# ОБНОВЛЕНИЕ СВЯЗКИ = УСТАНОВКА УСТАРЕВШИХ ЕЁ ФАЙЛОВ, а не третий вид операции: «должна стоять» у человека значит «стоит
# рабочая и нынешняя», и устаревший бинарь в плане — то же «недостающее», что и отсутствующий (та же закачка в `.dl` + `mv`,
# тот же гард места: новая сборка ложится РЯДОМ со старой, пик — её полный размер). Без этого исправленная сборка (dot-proxy 1.2)
# доезжала только через «снять и поставить заново», о чём человеку не говорил никто.
# Ответ «устарел ли» — у апдейтера (`gh-update.sh bin-status`: sha стоящего против манифеста, БЕЗ сети) и ОДИН раз на процесс:
# его спрашивают list-json и план на каждую связку, а сам ответ читает бинари. Грузить — вызовом НЕ из `$(…)` (bst_load в начале
# верба): присваивание из подоболочки наружу не возвращается, и срез пересчитывался бы на каждой связке.
BST=""; BST_DONE=0
bst_load() { [ "$BST_DONE" = 1 ] && return 0; BST_DONE=1; [ -f "$GH" ] && BST=$(sh "$GH" bin-status 2>/dev/null); return 0; }
bst_field() { bst_load; printf '%s\n' "$BST" | awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }'; }
bin_outdated() { [ "$(bst_field "$1" 2)" = outdated ]; }
# Файл только что заменён свежей сборкой — срез процесса об этом ОБЯЗАН знать: он прочитан один раз ДО закачек, и следующая
# связка того же плана (общий hev у Xray и ByeDPI) качала бы тот же файл второй раз — лишний шанс поймать 429 и «часть
# компонентов не установилась» при уже заменённом файле (ревью ветки, круг 1). Зовётся в основном шелле движка, не в `$(…)`.
bst_mark_fresh() { BST=$(printf '%s\n' "$BST" | awk -F'\t' -v OFS='\t' -v n="$1" '$1 == n && $2 == "outdated" { $2 = "current" } { print }'); }
# Какой файл связки устарел (первый по порядку; пусто — ни один): его версии и называет строка «есть обновление».
pkg_upd_bin() { for b in $(pkg_files "$1"); do have_bin "$b" && bin_outdated "$b" && { echo "$b"; return 0; }; done; return 0; }
# Нужен ли файл плану: его нет ИЛИ он устарел ($1 — pkg_state связки ДО операции). Единственный ответ для веса и «доставим/
# обновим» (закачка везёт то, что решил план, — P_FILES). ЧАСТИЧНОЙ связке — ТОЛЬКО недостающее: доставка hev к Xray с
# устаревшим xray тянула бы и 8 МБ новой сборки, и на тесном флеше починка неподнимающегося транспорта превращалась в «снимите
# что-нибудь ещё» (ревью ветки fix/dot-tails, круг 2); обновить её можно, когда она станет целой, — строка скажет. Ставящейся с
# нуля — и устаревший ОБЩИЙ файл (hev): иначе свежепоставленный Xray сразу показывал бы «есть обновление» (круг 3).
bin_needs() { ! have_bin "$2" || { [ "$1" != partial ] && bin_outdated "$2"; }; }
# Связка стоит ЦЕЛИКОМ и хоть один её файл устарел (общий hev — тоже: обновляет его любая связка, что на нём живёт).
pkg_upd() {
    [ "$(pkg_state "$1")" = installed ] || return 1
    for b in $(pkg_files "$1"); do have_bin "$b" && bin_outdated "$b" && return 0; done
    return 1
}
# Живой процесс связки исполняет прежнюю сборку (файл заменили под ним) — новая заработает после перезапуска.
pkg_run_old() { for b in $(pkg_files "$1"); do [ "$(bst_field "$b" 5)" = old ] && return 0; done; return 1; }

# --- ПЕРЕЗАПУСК НА УСТАНОВЛЕННУЮ СБОРКУ («Перезапустить» у строки «работает прежняя сборка») ----------------------------------
# An update replaces the FILE; a live daemon keeps executing the replaced build until it restarts, and all the screen could offer
# was "reboot the router" — a couple of minutes offline for what takes seconds per process (and no hint that the panel's own
# switches would do it: «Отключить VPN» → «Включить» restarts the tunnel and exits but NOT home access).
# The unit of a restart is not a binary but the OWNER of a process: amneziawg-go alone runs as the main carrier, an extra exit, a
# warm reserve and the home server, and each comes back only through its owner's verb. Killing a pid and letting someone notice
# would be the watchdog's ladder: failover, emails, a switch to a reserve.
# Whose process: amneziawg-go by its interface (no pidfile — the same match as awg_kill_daemon / srv_kill_daemon); the rest by
# THEIR pidfile, names as the owners declare them: XRAY_PID/slot_xray_pid (xray-transport.sh), HY2_PID/slot_hy2_pid
# (transport-hy2.sh), CIADPI_PID/slot_ciadpi_pid (transport-byedpi.sh), HEV_PID/slot_hev_pid (plugins, slot-tun-lib.sh), NFQ_PID
# (zapret.sh), DOH_PID (doh-lib.sh), TLS_PID (web-ui.sh). Three kinds of stale pid, told apart because only the first can be acted on:
#   · a UNIT — its owner is live, and its verb brings the process back on the installed file;
#   · an ORPHAN — ours (our pidfile, our interface naming), but its owner is gone: a daemon of a transport that is no longer active,
#     of an exit since disabled or moved to another transport. No owner verb reaches it (`slot-down` of a disabled exit refuses,
#     `down` of an inactive transport would tear the ACTIVE one's routing), so it is named, not restarted — a reboot clears it;
#   · NOT OURS — in no pidfile at all (a throwaway xray-test.sh instance): it ends by itself.
RST_ORDER="doh zapret filter slot2 slot3 slot4 slot5 slot6 slot7 server warm-awg main tls"   # short cuts first; the main tunnel late, the panel's own HTTPS last
# What the scan reads — top-level, so the sandbox stand points them at its own world (dev/pkg-restart-test.sh), as with LOCK/BGPID.
RST_PROC=/proc
RST_PIDDIR=/tmp
RST_HEALTH_TRIES=6
RST_HOLD_WAIT=120   # с: столько ждём, пока несущую ведёт сторож, heal или чужая смена (фон — ждать можно; перебор резервов дольше)
RST_HOLD_GAP=1      # с: пауза перед переспросом тика, уже взяв лок (щель между его гейтом и записью пида — разбор у switch_hold)
# The owners' own output (plugins, mark-core, awg_setup…) goes HERE, not into the operation log: the screen shows that log's last
# line as progress and as the reason of a failure, and the owners speak their own untranslated words — a toast «несущая снята…
# трафик напрямую» in the middle of a restart reads as an accident. RAM, rewritten per restart; the diagnostic dump takes it.
RST_OWNER_LOG=/tmp/enodia-pkg-restart.log
# An exit's daemon is the exit's only while the exit is ON and run by the transport of that daemon (`slots.sh show`: ⇥-fields,
# 3 = transport, 6 = on|off) — otherwise `slot-down`/`slot-up` refuse or call the new transport's plugin, and the old process stays.
rst_slot_of() {   # $1 = id, $2… = транспорты, чей это демон → slot<id> | orphan
    _rsy=$(sh "$ENODIA_DIR/slots.sh" show "$1" 2>/dev/null); _rsyi=$1; shift
    if [ "$(printf '%s\n' "$_rsy" | cut -f6)" = on ]; then
        case " $* " in *" $(printf '%s\n' "$_rsy" | cut -f3) "*) echo "slot$_rsyi"; return 0 ;; esac
    fi
    echo orphan
}
rst_unit() {   # $1 = pid, $2 = бинарь, $3 = активный транспорт → main | warm-awg | slot<N> | server | zapret | doh | tls | orphan | (пусто)
    case "$2" in
        amneziawg-go)
            _rui=$(tr '\000' ' ' 2>/dev/null < "$RST_PROC/$1/cmdline" | awk '{ print $2 }')
            case "$_rui" in
                # awg0 is a warm reserve only while ANOTHER transport is active. No `.transport` at all is the layout from before
                # multi-transport, where AmneziaWG is implied (transport.sh::implied): there awg0 IS the tunnel, and `cold` on it
                # would take the home off the VPN while reporting «warm reserve restarted».
                awg0)     case "$3" in ""|awg) echo main ;; *) echo warm-awg ;; esac ;;
                awg[2-7]) rst_slot_of "${_rui#awg}" awg ;;
                # The home server's daemon only while the server is ON (its owner answers): a leftover awgs0 without the intent is
                # an orphan — `vpn-server.sh restart` would do nothing, and the rescan would call it «still on the previous build».
                awgs0)    if sh "$ENODIA_DIR/vpn-server.sh" enabled >/dev/null 2>&1; then echo server; else echo orphan; fi ;;
            esac
            return 0 ;;
    esac
    for _ruf in "$RST_PIDDIR"/enodia-*.pid; do
        [ "$(tr -cd '0-9' < "$_ruf" 2>/dev/null)" = "$1" ] || continue
        _run=${_ruf#"$RST_PIDDIR"/enodia-}; _run=${_run%.pid}
        case "$_run" in
            # The main carrier's daemons only while THAT transport is active: restarting the active transport would not touch an
            # earlier one's leftover.
            xray|hysteria|byedpi|hev)
                case "$3:$_run" in xray:xray|xray:hev|hy2:hysteria|hy2:hev|byedpi:byedpi|byedpi:hev) echo main ;; *) echo orphan ;; esac ;;
            xray-s[2-7])     rst_slot_of "${_run##*-s}" xray ;;
            hysteria-s[2-7]) rst_slot_of "${_run##*-s}" hy2 ;;
            byedpi-s[2-7])   rst_slot_of "${_run##*-s}" byedpi ;;
            hev-s[2-7])      rst_slot_of "${_run##*-s}" xray hy2 byedpi ;;
            zapret-nfqws)    echo zapret ;;
            doh)             echo doh ;;
            panel-tls)       echo tls ;;
            dns-filter)      echo filter ;;
        esac
        return 0
    done
    return 0
}
# Stale processes are read ONCE per scan (`bin-stale` hashes what it hasn't cached); a rescan after a restart resets RSS_DONE.
# Load by a plain call, never inside `$(…)`: the assignment would die with the subshell (same as bst_load).
# Each pid's unit and component are worked out ONCE here too (RSU: pid⇥бинарь⇥unit⇥component, «-» for orphans and strangers):
# list-json asks rst_scan for every component, and per-component classification started `slots.sh` and a `tr` per pidfile for
# every stale pid again and again — 45 `sh` and 390 `tr` for one screen right after an update (review of bins-2026-10, round 3).
RSS=""; RSU=""; RSS_T=""; RSS_DONE=0
rss_load() {
    [ "$RSS_DONE" = 1 ] && return 0; RSS_DONE=1
    RSS=""; [ -f "$GH" ] && RSS=$(sh "$GH" bin-stale 2>/dev/null)
    RSS_T=$(sh "$ENODIA_DIR/transport.sh" active 2>/dev/null)
    RSU=$(printf '%s\n' "$RSS" | while IFS="$(printf '\t')" read -r _rlq _rln; do
        [ -n "$_rlq" ] || continue
        _rlx=$(rst_unit "$_rlq" "$_rln" "$RSS_T"); _rlx=${_rlx:-other}
        case "$_rlx" in orphan|other) _rlk=- ;; *) _rlk=$(rst_comp "$_rlx" "$RSS_T"); _rlk=${_rlk:--} ;; esac
        printf '%s\t%s\t%s\t%s\n' "$_rlq" "$_rln" "$_rlx" "$_rlk"
    done)
    return 0
}
# THE COMPONENT A UNIT BELONGS TO — the one whose transport RUNS it, not every component listing the binary. hev is a file of Xray,
# Hysteria2 and ByeDPI alike, and judged by files a stale hev of the Xray tunnel put «Перезапустить» on all three rows: «Restart
# Hysteria2?» then restarted the Xray tunnel, titled «Перезапуск Hysteria2» (review of bins-2026-10, round 2). Main — the active
# transport (no flag: the implied AmneziaWG); an exit — the transport of that exit; the reserve and home access — AmneziaWG.
rst_comp() {   # $1 = unit, $2 = активный транспорт → id связки
    case "$1" in
        main)              echo "${2:-awg}" ;;
        warm-awg|server)   echo awg ;;
        slot[2-7])         sh "$ENODIA_DIR/slots.sh" show "${1#slot}" 2>/dev/null | cut -f3 ;;
        *)                 echo "$1" ;;
    esac
}
rst_scan() {   # $@ = связки → RST_UNITS (в порядке RST_ORDER), RST_ORPHAN (pid'ов без живого хозяина), RST_OTHER (не наших)
    RST_UNITS=""; RST_ORPHAN=0; RST_OTHER=0
    rss_load
    [ -n "$RSS" ] || return 0
    _rsc=" $* "
    _rsf=""; for _rsp in "$@"; do _rsf="$_rsf $(pkg_files "$_rsp")"; done
    # A unit — by the component that runs it (rst_comp); orphans and strangers have no such component, so they are counted for every
    # requested component whose files they execute.
    _rsu=$(printf '%s\n' "$RSU" | while IFS="$(printf '\t')" read -r _rsq _rsn _rsx _rsk; do
        [ -n "$_rsq" ] || continue
        case "$_rsx" in
            orphan|other) case " $_rsf " in *" $_rsn "*) echo "$_rsx" ;; esac ;;
            *)            case "$_rsc" in *" $_rsk "*) echo "$_rsx" ;; esac ;;
        esac
    done)
    for _rso in $RST_ORDER; do
        printf '%s\n' "$_rsu" | grep -qxF "$_rso" && RST_UNITS="$RST_UNITS${RST_UNITS:+ }$_rso"
    done
    RST_ORPHAN=$(printf '%s\n' "$_rsu" | grep -cxF orphan || true)
    RST_OTHER=$(printf '%s\n' "$_rsu" | grep -cxF other || true)
    return 0
}
rst_label() { case "$1" in
        main) echo "основной канал" ;; warm-awg) echo "тёплый резерв AmneziaWG" ;; server) echo "«доступ домой»" ;;
        slot[2-7]) echo "дополнительный выход №${1#slot}" ;; zapret) echo "Zapret (nfqws)" ;;
        doh) echo "шифрованный DNS" ;; tls) echo "HTTPS панели" ;; filter) echo "фильтр по категориям" ;; *) echo "$1" ;;
    esac; }
# CAN A UNIT BE RESTARTED NOW — one answer for the offer (list-json `rst_units`) and the run (cmd_restart): the main carrier only while
# it CARRIES. No default route in table 1000 means the watchdog holds traffic direct (FAILOPEN — a network state, not the string in
# its state file) or is bringing the tunnel up; a restart would put the route back into the server the watchdog has just given up on,
# behind its back — and a confirmation that promised «5–10 s» for a channel the engine then refuses read as a broken tunnel.
rst_can() { [ "$1" != main ] || [ -n "$(carrier_iface)" ]; }
# The carrier of exit N exists — its name asked of the owner (`transport.sh slot-iface`: awgN at AmneziaWG, xtunN at the alts).
rst_slot_iface() { _rsi=$(sh "$ENODIA_DIR/transport.sh" slot-iface "$1" 2>/dev/null); [ -n "$_rsi" ] && ip link show "$_rsi" >/dev/null 2>&1; }
# WORKS after the restart — by the RESULT («демон жив» never meant «сервис работает»). The owners of DoH, zapret, home access and the
# panel's HTTPS answer it themselves: their restart verbs wait for the service and return non-zero when it did not come back (doh-lib.sh
# restart, zapret.sh reload, vpn-server.sh restart, web-ui.sh tls-reload), so their code IS the verdict (cmd_restart). The tunnels are
# judged here, by health; a fresh one needs a moment for its first handshake, hence the retry.
# An exit is judged by its plugin's `slot-health` CONTRACT (transport.sh): 0 alive · 1 sagging · 2 «can't judge». 2 is the AmneziaWG
# plugin, which has no exit health at all — an idle exit has no handshake until traffic or its 25-s keepalive reaches it (BE7000
# 2026-10-05: an idle awg3 restarted fine, first handshake 30 s later, and was reported «не отвечает»); then the fact we CAN check is
# the exit's carrier interface. HEV_CHECK=0: the hev path check belongs to the watchdog's sweep — it would restart the hev we have
# just started, and under our own switching lock it answers 4 «not judged» on every try (slot-tun-lib.sh::slot_hev_path_check).
# HEALTH_OWN_LOCK=1: a plugin that refuses to judge under the switching lock (ByeDPI: «a switch is in progress, hands off») must judge
# for its holder — otherwise «0 under any lock» made every ByeDPI restart «Готово», forwarding or not (review, round 2).
rst_works() {   # $1 = unit
    case "$1" in
        main|slot[2-7])
            _rwn=0
            while [ "$_rwn" -lt "$RST_HEALTH_TRIES" ]; do
                if [ "$1" = main ]; then HEALTH_OWN_LOCK=1 sh "$ENODIA_DIR/transport.sh" health >/dev/null 2>&1; _rwc=$?
                else HEV_CHECK=0 sh "$ENODIA_DIR/transport.sh" slot-health "${1#slot}" >/dev/null 2>&1; _rwc=$?
                     [ "$_rwc" = 2 ] && rst_slot_iface "${1#slot}" && _rwc=0; fi
                [ "$_rwc" = 0 ] && return 0
                sleep 2; _rwn=$((_rwn + 1))
            done
            return 1 ;;
    esac
    return 0
}
rst_one() {   # $1 = unit → код владельца (0 — перезапустил и своё проверил)
    log "Перезапускаю: $(rst_label "$1")…"
    echo "=== $(date '+%H:%M:%S') $1" >> "$RST_OWNER_LOG" 2>/dev/null
    case "$1" in
        doh)       sh "$ENODIA_DIR/doh-lib.sh" restart >> "$RST_OWNER_LOG" 2>&1 ;;
        zapret)    sh "$ENODIA_DIR/zapret.sh" reload >> "$RST_OWNER_LOG" 2>&1 ;;                   # nfqws only: rules and set stay
        slot[2-7]) sh "$ENODIA_DIR/transport.sh" slot-down "${1#slot}" >> "$RST_OWNER_LOG" 2>&1
                   sh "$ENODIA_DIR/transport.sh" slot-up "${1#slot}" >> "$RST_OWNER_LOG" 2>&1 ;;
        server)    sh "$ENODIA_DIR/vpn-server.sh" restart >> "$RST_OWNER_LOG" 2>&1 ;;
        # The warm reserve comes back AS a reserve (the watchdog notices the home server by its handshake): not `cold` alone.
        warm-awg)  sh "$ENODIA_DIR/transport.sh" rewarm awg >> "$RST_OWNER_LOG" 2>&1 ;;
        main)      sh "$ENODIA_DIR/transport.sh" restart >> "$RST_OWNER_LOG" 2>&1 ;;
        tls)       sh "$ENODIA_DIR/web-ui.sh" tls-reload >> "$RST_OWNER_LOG" 2>&1 ;;
        filter)    sh "$ENODIA_DIR/access-sched.sh" filter-restart >> "$RST_OWNER_LOG" 2>&1 ;;
        *)         return 1 ;;
    esac
}
# CONSENT: the panel asked the human about the units its screen listed and sends them back (`$2`); a unit found now that was not on that
# list — a failover made awg0 the main carrier after the screen was drawn, an exit was switched on — is not touched: the confirmation
# said «warm reserve, put out», not «the tunnel drops for 10 s». The CLI sends nothing: whoever types the command chose everything.
rst_agreed() { [ -z "$RST_OK" ] && return 0; case " $RST_OK " in *" $1 "*) return 0 ;; esac; return 1; }
cmd_restart() {   # $1 = связки через запятую («-» = все), [$2 = владельцы, на чей перерыв согласились, через запятую; пусто — все]
    : > "$LOG"; set_state RUNNING; : > "$RST_OWNER_LOG" 2>/dev/null
    _rp=$(printf '%s' "${1:--}" | tr ',' ' ')
    [ "$_rp" = - ] && _rp=$PKGS
    for p in $_rp; do pkg_known "$p" || { set_state FAIL; log "Отказ: неизвестный компонент: $p"; return 1; }; done
    RST_OK=$(printf '%s' "$2" | tr ',' ' ')
    # The plan names what is restarted (4th field: the screen titles the operation by it) — the components that HAVE something to
    # restart; `-` from the CLI would otherwise title it with every component, absent ones included.
    _rpa=""; for p in $_rp; do rst_scan "$p"; [ -n "$RST_UNITS" ] && _rpa="$_rpa${_rpa:+,}$p"; done
    printf -- '-\t-\t-\t%s\n' "${_rpa:-$(printf '%s' "$_rp" | tr ' ' ',')}" > "$PLANF" 2>/dev/null
    rst_scan $_rp
    if [ -n "$RST_UNITS" ]; then
        # The carrier is ours alone for the restart: no watchdog tick, no heal run, no other switch — and our pid in the lock, so a
        # manual switch waits for us instead of running alongside (daemon-lib.sh::switch_hold, reasons there).
        SWITCH_LOCK=$SWLOCK
        # Waiting is not silence: the screen shows the last line as progress, and an empty one for up to two minutes reads as a hang.
        if [ -e "$SWLOCK" ] || { command -v carrier_busy >/dev/null 2>&1 && carrier_busy; }; then
            log "Жду, пока роутер закончит свою работу с туннелем (проверка сторожа, восстановление или другая смена), — до $((RST_HOLD_WAIT / 60)) мин"
        fi
        if ! switch_hold "$SWLOCK" "$RST_HOLD_WAIT" "$RST_HOLD_GAP"; then
            set_state FAIL
            log "Роутер сейчас сам ведёт туннель (проверка сторожа, восстановление или другая смена) — ничего не перезапускал, повторите через пару минут"
            return 1
        fi
        SWMINE=1
        RSS_DONE=0; rst_scan $_rp   # the world may have changed while we waited
    fi
    if [ -z "$RST_UNITS" ]; then
        set_state OK
        if [ "$RST_ORPHAN" -gt 0 ]; then
            log "Без хозяина, на прежней сборке: $RST_ORPHAN (демон выключенного выхода или прежнего транспорта) — уйдёт с перезагрузкой роутера"
        else
            log "Перезапускать нечего: все процессы уже работают на установленных сборках."
        fi
        return 0
    fi
    # «Can't now» comes BEFORE consent: the screen never offers such a unit (list-json, rst_can), so it is not «not agreed» — and
    # «нажмите «Перезапустить» ещё раз» for a channel that carries nothing would only repeat itself (review, round 3).
    _rgo=""; _rskip=""; _rhold=""
    for u in $RST_UNITS; do
        if ! rst_can "$u"; then _rhold="$_rhold${_rhold:+, }$(rst_label "$u")"
        elif rst_agreed "$u"; then _rgo="$_rgo${_rgo:+ }$u"
        else _rskip="$_rskip${_rskip:+, }$(rst_label "$u")"; fi
    done
    _rl=""; for u in $_rgo; do _rl="$_rl${_rl:+, }$(rst_label "$u")"; done
    [ -n "$_rl" ] && log "Перезапуск на установленной сборке: $_rl"
    [ "$RST_ORPHAN" -gt 0 ] && log "Без хозяина, на прежней сборке: $RST_ORPHAN (демон выключенного выхода или прежнего транспорта) — уйдёт с перезагрузкой роутера"
    [ "$RST_OTHER" -gt 0 ] && log "Ещё процессов на прежней сборке, не наших: $RST_OTHER (разовая проверка сервера) — закончатся сами"
    # FAILED and NOT TOUCHED are two lists: the last line is what the screen shows as the reason, and «Перезапуск не удался: основной
    # канал» for a channel nobody touched read as a broken tunnel (review of bins-2026-10, round 2).
    _rrc=0; _rbad=""; _rnot=""
    # The watchdog restores the carrier itself when the server answers (rst_can — reasons there).
    if [ -n "$_rhold" ]; then
        log "Основной канал не трогаю: сейчас он не везёт трафик (прямой режим сторожа или подъём туннеля). Перезапустите, когда туннель вернётся."
        _rrc=1; _rnot=$_rhold
    fi
    if [ -n "$_rskip" ]; then
        log "Не трогаю без вашего согласия: $_rskip — экран о нём не спрашивал; нажмите «Перезапустить» ещё раз"
        _rrc=1; _rnot="$_rnot${_rnot:+, }$_rskip"
    fi
    for u in $_rgo; do
        rst_one "$u"; _rorc=$?
        # Judged by FACT: the unit's processes must no longer run a replaced build, its owner must say it came back, and it must work.
        RSS_DONE=0; rst_scan $_rp
        case " $RST_UNITS " in
            *" $u "*) log "Не вышло: $(rst_label "$u") — всё ещё на прежней сборке"; _rrc=1; _rbad="$_rbad${_rbad:+, }$(rst_label "$u")" ;;
            *) if [ "$_rorc" != 0 ]; then
                   log "Не вышло: $(rst_label "$u") — после перезапуска не работает (подробности — в диагностике роутера)"; _rrc=1; _rbad="$_rbad${_rbad:+, }$(rst_label "$u")"
               elif rst_works "$u"; then log "Готово: $(rst_label "$u") — на установленной сборке"
               else log "Перезапущено, но не отвечает: $(rst_label "$u") — сторож проверит и починит на своём тике"; _rrc=1; _rbad="$_rbad${_rbad:+, }$(rst_label "$u")"; fi ;;
        esac
    done
    _rtail=""; [ -n "$_rnot" ] && _rtail="; не трогал: $_rnot"
    if [ "$_rrc" = 0 ]; then set_state OK; log "Готово: всё перезапущено на установленных сборках."
    elif [ -n "$_rbad" ]; then set_state FAIL; log "Перезапуск не удался: $_rbad$_rtail"
    else set_state FAIL; log "Перезапущено не всё — не трогал: $_rnot"; fi
    return $_rrc
}

# absent (ничего нет) | partial (часть файлов) | installed (всё на месте).
# «partial» — не педантизм: половинная установка awg («демон есть, CLI нет») ВРАЛА «готов»,
# и переключение на неё роняло рабочий xray.
# «Есть ли связка вообще» судим по СВОИМ бинарям, а общие (hev) — только на «полноту»:
# иначе hev, лежащий ради byedpi, делал НЕустановленную Hysteria2 «частично установленной»
# (панель предвыбирала её галочкой как стоящую). Поймано на железе 31.07.
pkg_state() {
    _n=0; _h=0
    for b in $(pkg_own "$1");   do _n=$((_n+1)); have_bin "$b" && _h=$((_h+1)); done
    [ "$_h" = 0 ] && { echo absent; return 0; }
    for b in $(pkg_shared "$1"); do _n=$((_n+1)); have_bin "$b" && _h=$((_h+1)); done
    if [ "$_h" = "$_n" ]; then echo installed; else echo partial; fi
}

# Транспорты, несущие доп-выходы — спрашиваем РЕЕСТР слотов (единственный владелец ответа).
# Гард `-f`, а не `-x` (класс Б5-9): снятый бит выполнения ⇒ ответ «выходов нет» ⇒ гард удаления
# молча разрешает снять транспорт, несущий доп-выход, и утащить hev из-под живых слотов. Ref-count
# обязан замолкать только когда реестра НЕТ, а не когда ему забыли поставить +x.
slot_carriers() { [ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" carriers 2>/dev/null; }
slot_uses() { slot_carriers | grep -qx "$1"; }

# --- ГАРДЫ УДАЛЕНИЯ -----------------------------------------------------------------
# Печатает ПРИЧИНУ, по которой связку снимать нельзя (пусто = можно). Причины намеренно
# человеческие: их показывает панель прямо на серой кнопке, а не «ошибка 1».
# Гард по «доступу домой» — НОВЫЙ и закрывает живой баг: awgs0 (роутер как VPN-сервер) — ЭТОТ ЖЕ
# демон amneziawg-go, и снятие awg молча уносило его вместе с правилами. Панель при этом
# продолжала показывать «включено», а телефон домой не заходил до ребута.
pkg_hold() {
    # СНЯТЬ МОЖНО ТОЛЬКО ТО, ЧТО СТОИТ. Гард судил по одному НАМЕРЕНИЮ (`.transport`, реестр слотов,
    # `.doh-on`, `.panel-tls`) и не спрашивал, установлена ли связка вообще, — поэтому на свежей
    # установке с ИМПОРТИРОВАННЫМ бэкапом панель показывала «AmneziaWG · НЕ УСТАНОВЛЕН · снять
    # нельзя: несёт трафик прямо сейчас» и «Шифрованный DNS · НЕ УСТАНОВЛЕН · снять нельзя:
    # включён». Замерено на AX3600 16.08.2026: импорт вернул `.transport=awg` и `.doh-on`, а
    # бинарей нет вовсе — намерение с чужого роутера приехало, файлы остались там.
    # Для плана это безопасно: снятие отсутствующего и так пустая операция.
    if [ "$(pkg_state "$1")" = absent ]; then return 0; fi
    _t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    case "$1" in
        awg|xray|hy2|byedpi|zapret)
            [ "$_t" = "$1" ] && { echo "несёт трафик прямо сейчас — сперва переключите транспорт"; return 0; }
            slot_uses "$1" && { echo "несёт дополнительный выход — сперва уберите его в «Дополнительных выходах»"; return 0; }
            ;;
    esac
    case "$1" in
        awg) [ -f "$ENODIA_STATE/server/.on" ] && { echo "нужен для «доступа домой» (сервер awgs0 — тот же демон)"; return 0; } ;;
        # Третий потребитель nfqws — устройства «целиком в десинк» (правила по источнику). Их не
        # видно ни в .transport, ни в списке выходов, поэтому без этой строки удаление проходило
        # бы «успешно», а у телевизора десинк тихо исчезал.
        zapret) [ -s "$ENODIA_STATE/.desync-ips" ] && { echo "его держат устройства «целиком в десинк» ($(grep -c . "$ENODIA_STATE/.desync-ips" 2>/dev/null)) — сперва верните им обычный режим"; return 0; } ;;
        doh) [ "$(cat "$ENODIA_STATE/.doh-on" 2>/dev/null)" = on ] && { echo "включён шифрованный DNS — сперва выключите"; return 0; }
             # АВТО-РЕЖИМ ТОЖЕ ДЕРЖИТ DNS (прямой режим: десинк, упавший туннель, выключенный VPN): тумблер выключен, а
             # dnsmasq смотрит в прокси. Снятие гасило прокси и удаляло бинарь — DNS не возвращал никто, и сеть сидела
             # без имён до отката по промахам (10–20 минут; ревью шага 5a, круг 1). Ответ — у владельца слоя
             # (doh-lib.sh::doh_auto_active), в подоболочке: библиотека тащит свои пути и шимы.
             [ -f "$ENODIA_DIR/doh-lib.sh" ] && ( . "$ENODIA_DIR/doh-lib.sh"; doh_auto_active ) 2>/dev/null && \
                 { echo "шифрованный DNS сейчас держит DNS сети сам (прямой режим) — сперва выключите «Включать само в прямых режимах»"; return 0; } ;;
        tls) [ -f "$ENODIA_STATE/.panel-tls" ] && { echo "включён HTTPS панели — снимете и потеряете вход"; return 0; } ;;
        # a schedule with «limited» in its week would go fully OPEN without the filter (fail-open) — the owner answers who
        filter) if [ -f "$ENODIA_DIR/access-sched.sh" ] && sh "$ENODIA_DIR/access-sched.sh" uses-filter >/dev/null 2>&1; then
                    echo "его держат расписания с «ограничено» — сперва уберите из них «ограничено»"; return 0
                fi ;;
    esac
    return 0
}

# ПОЧЕМУ СТОЯЩАЯ СВЯЗКА ЗДЕСЬ НЕ ЗАРАБОТАЕТ. Отдельный вопрос от pkg_hold («почему нельзя снять»)
# и от state («стоит ли»): бинарь бывает на месте, а сделать им нечего — zapret на ядре 4.4
# (AX3600/BE3600) без libxt_NFQUEUE. Экран «Компоненты» показывал такую связку просто «установлен»,
# и человек видел занятые 122 КБ без единого слова о том, что включить их тут невозможно; причину
# называла только карточка Zapret. Спрашиваем ВЛАДЕЛЬЦА ответа (verb nfq-ok, проба кэширована) —
# второй копии пробы в проекте нет; rc=2 (старая копия плагина) = НЕ судим, как в transport_ready.
# Печатает строку-причину или ничего.
pkg_warn() {
    [ "$(pkg_state "$1")" = absent ] && return 0
    case "$1" in
        zapret) [ -f "$ENODIA_DIR/zapret.sh" ] || return 0
                sh "$ENODIA_DIR/zapret.sh" nfq-ok >/dev/null 2>&1 || [ "$?" = 2 ] || \
                    echo "на этом роутере не заработает: ядро без NFQUEUE (десинк без VPS здесь даёт ByeDPI)" ;;
    esac
    return 0
}

# --- РАЗМЕРЫ -------------------------------------------------------------------------
# ДВЕ СТОРОНЫ ОДНОГО ПЛАНА. С внешним накопителем «сколько займёт» перестаёт быть одним числом:
# xray уедет на флешку, hev останется на /data — и резерв стережёт ТОЛЬКО /data. Поэтому у
# обеих размерных функций есть scope: пусто = «весь вес связки» (человеку — сколько она весит),
# data = «сколько из этого ляжет/лежит на /data» (арифметика резерва). Без накопителя оба ответа
# совпадают байт-в-байт, то есть на стоковом роутере ничего не изменилось.
# Куда ЛЯЖЕТ новый файл, знает bin_dest; где ЛЕЖИТ существующий — bin_path. Спрашивать надо
# разное: снимаем мы то, что лежит, а ставим — туда, где место.
#
# «Сколько ЗАЙМЁТ» — из bin-manifest.txt (gh-update.sh bin-size), только недостающие файлы:
# доустановка hev к уже стоящему byedpi стоит 0.15 МБ, а не размер всей связки.
pkg_add_b() {       # $1 = связка, $2 = scope (пусто | data)
    _s=0; _pas=$(pkg_state "$1")
    for b in $(pkg_files "$1"); do
        bin_needs "$_pas" "$b" || continue
        if [ "$2" = data ] && [ "$(bin_dest "$b")" != "$ENODIA_BIN/$b" ]; then continue; fi
        _n=$(sh "$GH" bin-size "$b" 2>/dev/null | tr -d ' \r'); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
        _s=$((_s+_n))
    done
    echo "$_s"
}
# «Сколько ОСВОБОДИТ» — ФАКТИЧЕСКИЕ байты файлов на диске (манифест мог отстать от того, что
# реально лежит). hev считаем только если после ЭТОГО плана он никому не нужен.
pkg_del_b() {       # $1 = связка, $2 = ВЕСЬ список снимаемых (ref-count для hev), $3 = scope,
                    # $4 = 1, если hev в ЭТОМ плане уже засчитан кем-то другим (см. plan_calc)
    _s=0
    for b in $(pkg_own "$1"); do
        _p=$(bin_path "$b"); [ -f "$_p" ] || continue
        if [ "$3" = data ] && [ "$_p" != "$ENODIA_BIN/$b" ]; then continue; fi
        _n=$(stat -c%s "$_p" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
        _s=$((_s+_n))
    done
    _hp=$(bin_path hev)
    if [ "$4" != 1 ] && [ -n "$(pkg_shared "$1")" ] && [ -f "$_hp" ] && ! hev_needed_after "$2"; then
        if [ "$3" != data ] || [ "$_hp" = "$ENODIA_BIN/hev" ]; then
            _n=$(stat -c%s "$_hp" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
            _s=$((_s+_n))
        fi
    fi
    echo "$_s"
}
# hev общий: его держат ЛЮБОЙ оставшийся socks-карриер и ЛЮБОЙ слот на нём (slot-tun-lib.sh).
hev_needed_after() {   # $1 = список снимаемых; 0 = hev ещё нужен
    # …в том числе тому, кого этот же план СТАВИТ (P_INS — план уже посчитан): «снять ByeDPI, поставить Xray» сносил hev, а Xray
    # вставал без него — в закачку плана hev не попадал, потому что на момент плана стоял (найдено стендом закачки заранее, 01.10.2026).
    for p in $P_INS; do case "$p" in xray|hy2|byedpi) return 0 ;; esac; done
    for p in xray hy2 byedpi; do
        in_list "$p" "$1" && continue
        for b in $(pkg_own "$p"); do have_bin "$b" && return 0; done
    done
    for c in $(slot_carriers); do
        case "$c" in xray|hy2|byedpi) return 0 ;; esac
    done
    return 1
}

# ГДЕ мерить — вопрос store-lib.sh (fs_*), своей копии знания тут нет: на BE10000 `/data` —
# ЧУЖОЙ том со стоковыми конфигами, а наш код и бинари живут на `/data/usr`. Спрашиваем по
# каталогу КОДА: он существует всегда (в нём лежит этот файл), тогда как `$ENODIA_BIN` на
# свежем роутере может ещё не быть создан, а df по несуществующему пути молчит — и гард
# прочитал бы «свободно 0», запретив установку ровно там, где она нужна.
disk_free_b()  { fs_free_b  "$ENODIA_DIR"; }
# Сколько ОЗУ можно занять под закачку заранее (cmd_apply): меньшее из «свободно в /tmp» (tmpfs режет запись своим потолком) и
# «доступно ядру» (MemAvailable; у старого ядра его нет — MemFree): tmpfs пишет в ту же память, что нужна демонам. MEMINFO —
# подмена для стендов (то же соглашение, что у dump.sh).
ram_room_b() {
    _rrt=$(fs_free_b /tmp)
    _rra=$(awk '/^MemAvailable:/{a=$2}/^MemFree:/{f=$2}END{printf "%.0f", (a==""?f:a)*1024}' "${MEMINFO:-/proc/meminfo}" 2>/dev/null)
    case "$_rra" in ''|*[!0-9]*) _rra=0 ;; esac
    [ "$_rra" -lt "$_rrt" ] && _rrt=$_rra
    printf '%s' "$_rrt"
}
PF_MARGIN_B=33554432   # 32 МБ сверх скачиваемого остаются демонам (xray, dnsmasq) и самой установке
disk_total_b() { fs_total_b "$ENODIA_DIR"; }
# Точка монтирования НАШЕГО тома — панель подписывает ею полосу флеша: «Флеш /data» на
# роутере, где мы живём на /data/usr, — это ровно та подпись, из-за которой BE10000 полгода
# показывал чужие 4.7 МБ и никто не усомнился.
disk_mount()   { fs_mount "$ENODIA_DIR"; }
# НА ЧЁМ мы меряем место. Мерить надо ТУДА, КУДА ЛЯЖЕТ файл (это $ENODIA_DIR — верно во всех
# раскладках), но НАЗВАТЬ носитель обязан роутер: в режиме `full` это накопитель, и панель
# подписывала полосу «Флеш /mnt/usb-…» — то есть называла флешку флешем роутера. Судим по
# ФАКТУ (разные тома у кода и у бутстрапа), а не по флагу режима: флаг — ещё один источник
# правды, а томов ровно два и их видно. Точку монтирования кода спрашиваем У disk_mount — своё
# второе выражение для того же вопроса разъехалось бы с ним при первой же правке.
disk_on_store() { [ "$(disk_mount)" != "$(fs_mount "$ENODIA_BOOT")" ] && echo true || echo false; }
# Свободно на внешнем накопителе (0, когда его нет). Флешка на порядки больше флеша, но
# «на порядки» ≠ «бесконечно»: там же файлы пользователя, поэтому свой скромный запас есть и тут.
store_free_b() {
    if store_ready; then fs_free_b "$(store_root)"
    else echo 0; fi
}
STORE_RESERVE_B=16777216
# «xray,hy2» → «xray hy2»; «-» и пусто → пусто (панель шлёт «-» для пустой стороны плана).
norm_list()    { printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//; s/^-$//'; }
# Байты → «X.Y МБ» для ЛОГА (человек читает мегабайты, а busybox не умеет float). Знак вручную:
# остаток от деления отрицательного даёт «-1.-2», а «останется» бывает и отрицательным.
mb() { _v=${1:-0}; _sg=""; [ "$_v" -lt 0 ] && { _sg="-"; _v=$((0-_v)); }; echo "$_sg$((_v/1048576)).$(( (_v%1048576)*10/1048576 ))"; }

# --- СОСТОЯНИЕ ДЛЯ ПАНЕЛИ ------------------------------------------------------------
# Один срез: диск + все связки. Второй копии «что установлено» в CGI быть не должно —
# ровно так разъезжались прежние curCombo()/cur_alt().
cmd_list_json() {
    bst_load
    # now — часы роутера (возраст панель считает по ним, как у журнала операции).
    # arch/staged/need — для двери «Загрузить файл с компьютера» (установка без GitHub): какая арка у роутера (имя файла в архиве
    # проекта — `bin/<арка>/<имя>.user`), что уже принято и ждёт установки, какие файлы нужны связке. Спрашиваем у владельца.
    _arch=$(sh "$GH" bin-arch 2>/dev/null | tr -cd 'a-z0-9')
    _stgj=$(sh "$GH" bin-staged 2>/dev/null | awk '/^[a-z0-9-]+$/ { printf "%s\"%s\"", s, $0; s="," }')
    printf '{"engine":true,"reserve_b":%s,"free_b":%s,"total_b":%s,"mount":"%s","on_store":%s,"now":%s,"arch":"%s","staged":[%s],"pkgs":[' "$RESERVE_B" "$(disk_free_b)" "$(disk_total_b)" "$(disk_mount)" "$(disk_on_store)" "$(date +%s)" "$_arch" "$_stgj"
    _first=1
    for p in $PKGS; do
        _st=$(pkg_state "$p"); _hold=$(pkg_hold "$p"); _warn=$(pkg_warn "$p")
        _ver=$(sh "$GH" bin-ver "$(pkg_own "$p" | cut -d' ' -f1)" 2>/dev/null | tr -d ' \r')
        # cur — версия СТОЯЩЕГО (первый свой бинарь; пусто — не знаем), upd — стоит и хоть один файл устарел, run_old — работает
        # прежняя сборка до перезапуска. Строки версий — из манифеста, но экранируем всё равно: кэш лежит на флеше.
        _cur=$(bst_field "$(pkg_own "$p" | cut -d' ' -f1)" 3 | tr -d '"\\\r')
        _upd=false; pkg_upd "$p" && _upd=true
        # ub/ucur/uver — КАКОЙ файл устарел и его версии: у связки из нескольких файлов устаревает не обязательно первый (у DoH
        # — dot-proxy при свежем https-dns-proxy, у Xray — общий hev), и строка «есть обновление A → B» по версиям первого
        # писала «A → A» (ревью ветки, круг 1). cur/ver остаются про главный файл — их показывает имя строки.
        _ub=""; _uc=""; _uv=""
        if [ "$_upd" = true ]; then _ub=$(pkg_upd_bin "$p"); _uc=$(bst_field "$_ub" 3 | tr -d '"\\\r'); _uv=$(bst_field "$_ub" 4 | tr -d '"\\\r'); fi
        # run_old — a process of THIS component runs a replaced build: the Xray tunnel's stale hev is a file of Hysteria2 too, but not
        # its process (rst_comp). rst_units — WHAT a restart of this component would touch (units in restart order, only what can be
        # restarted now — rst_can): the panel names exactly that before asking and sends it back as the consent (cmd_restart).
        # Orphans are not units: nothing but a reboot reaches them, so they keep «работает прежняя» with the reboot advice.
        _ro=false; _rsj=""
        if [ "$_st" != absent ] && pkg_run_old "$p"; then
            rst_scan "$p"
            if [ -n "$RST_UNITS" ] || [ "$RST_ORPHAN" -gt 0 ] || [ "$RST_OTHER" -gt 0 ]; then _ro=true; fi
            for _rsu1 in $RST_UNITS; do rst_can "$_rsu1" && _rsj="$_rsj${_rsj:+,}\"$_rsu1\""; done
        fi
        _need=""; for b in $(pkg_files "$p"); do bin_needs "$_st" "$b" && _need="$_need${_need:+,}\"$b\""; done
        [ "$_first" = 1 ] || printf ','
        _first=0
        # Вес связки — ДВА числа, ровно как в плане: полный и та его часть, что лежит (ляжет) на
        # /data. Без накопителя они совпадают байт-в-байт. С накопителем разница — единственное,
        # из чего панель может узнать место жительства связки: иначе карточка «Xray» обещала бы
        # освободить 7.9 МБ ФЛЕША, а освободила бы флешку, и полоса не шевельнулась бы.
        # add_b у стоящей связки с обновлением — вес НОВЫХ сборок её устаревших файлов (тот же pkg_add_b, что у плана).
        printf '{"id":"%s","label":"%s","state":"%s","ver":"%s","cur":"%s","upd":%s,"ub":"%s","ucur":"%s","uver":"%s","run_old":%s,"rst_units":[%s],"need":[%s],"add_b":%s,"add_data_b":%s,"del_b":%s,"del_data_b":%s,"hold":"%s","warn":"%s"}' \
            "$p" "$(pkg_label "$p")" "$_st" "$_ver" "$_cur" "$_upd" "$_ub" "$_uc" "$_uv" "$_ro" "$_rsj" "$_need" \
            "$(pkg_add_b "$p")" "$(pkg_add_b "$p" data)" \
            "$(pkg_del_b "$p" "$p")" "$(pkg_del_b "$p" "$p" data)" "$_hold" "$_warn"
    done
    printf ']}\n'
}

# --- ПЛАН ------------------------------------------------------------------------------
# Считает вердикт БЕЗ побочных эффектов: «останется = свободно + Σснимаемое − Σставимое».
# Заполняет P_* для cmd_apply, чтобы арифметика жила в ОДНОМ месте (иначе кнопка и сама
# операция начнут расходиться в оценке — классика «в панели влезало, а на роутере нет»).
plan_calc() {       # $1 = ставим, $2 = снимаем
    bst_load
    P_INS=$(norm_list "$1"); P_DEL=$(norm_list "$2")
    P_ERR=""; P_BLOCK=""; P_NEED=0; P_FREED=0; P_UNK=0; P_NEED_ST=0; P_FREED_ST=0; P_TAKES=0; P_SHORT=0; P_UPD=""; P_FILES=""; _pcnt=" "
    for p in $P_INS; do
        pkg_known "$p" || { P_ERR="$P_ERR неизвестный компонент: $p"; continue; }
        in_list "$p" "$P_DEL" && { P_ERR="$P_ERR $p указан и на установку, и на удаление"; continue; }
        # Стоящая целиком связка с устаревшим файлом в «ставим» — это ОБНОВЛЕНИЕ; журнал и панель называют его своим словом.
        # Частичная — «доставим» (установка, даже если заодно что-то устарело); свежая — пустая операция, а не «обновляю».
        _pst=$(pkg_state "$p")
        [ "$_pst" = installed ] && pkg_upd "$p" && P_UPD="$P_UPD${P_UPD:+ }$p"
        # КАЖДЫЙ ФАЙЛ — ОДИН РАЗ НА ПЛАН: общий hev нужен каждой своей связке, и сумма весов по связкам считала его столько раз,
        # сколько их в плане («займут» втрое при обновлении hev у Xray, ByeDPI и Hysteria2 разом; у границы резерва — ложный
        # отказ). Снятия это знают давно (`_hevdone` ниже), установка — с ревью ветки fix/dot-tails, круг 2. Вес делим по месту
        # жительства: в резерв /data идёт только то, что там осядет (bin_dest). «Не знаю размер» ≠ «ноль»: манифест может не
        # доехать (старый публичный снимок, нет сети), и недостающий файл молча считался бы БЕСПЛАТНЫМ — вердикт «влезет» врал бы
        # на мегабайты. Панели это флаг (`unknown`), машинным вызывающим (plan-ok) — ОТКАЗ.
        for b in $(pkg_files "$p"); do
            bin_needs "$_pst" "$b" || continue
            case "$_pcnt" in *" $b "*) continue ;; esac
            _pcnt="$_pcnt$b "
            _n=$(sh "$GH" bin-size "$b" 2>/dev/null | tr -d ' \r'); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
            [ "$_n" = 0 ] && P_UNK=1
            if [ "$(bin_dest "$b")" = "$ENODIA_BIN/$b" ]; then P_NEED=$((P_NEED + _n)); else P_NEED_ST=$((P_NEED_ST + _n)); fi
        done
    done
    # ЧТО ВЕЗТИ — решение ПЛАНА, и закачка его не пересматривает (ревью ветки, круг 3): do_install считал состояние связки заново,
    # уже после предыдущих связок того же плана, и частичная Hysteria2, которой Xray только что привёз hev, становилась «целой» —
    # качалась и устаревшая hysteria (4.5 МБ мимо веса плана и гарда резерва), а журнал писал «Ставлю… Обновляю…».
    P_FILES=$_pcnt
    # hev — ОДИН файл на всех: снимая в одном плане ДВУХ его потребителей (Xray + ByeDPI),
    # прежний код засчитывал его освобождение КАЖДОМУ (hev_needed_after судит про весь список
    # сразу, а зовётся на каждую связку) — «освободится» завышалось, а у самой границы резерва
    # это переворачивает вердикт «влезет». Считаем его РОВНО ОДИН раз за план.
    _hevdone=0
    for p in $P_DEL; do
        pkg_known "$p" || { P_ERR="$P_ERR неизвестный компонент: $p"; continue; }
        _h=$(pkg_hold "$p")
        [ -n "$_h" ] && { P_BLOCK="$P_BLOCK|$p: $_h"; continue; }
        _a=$(pkg_del_b "$p" "$P_DEL" "" "$_hevdone"); _d=$(pkg_del_b "$p" "$P_DEL" data "$_hevdone")
        P_FREED=$((P_FREED + _d)); P_FREED_ST=$((P_FREED_ST + _a - _d))
        if [ "$_hevdone" = 0 ] && [ -n "$(pkg_shared "$p")" ] && [ -f "$(bin_path hev)" ] \
           && ! hev_needed_after "$P_DEL"; then _hevdone=1; fi
    done
    P_FREE=$(disk_free_b); case "$P_FREE" in ''|*[!0-9]*) P_FREE=0 ;; esac
    P_LEFT=$((P_FREE + P_FREED - P_NEED))
    P_OK=1
    [ -n "$P_ERR" ] && P_OK=0
    [ -n "$P_BLOCK" ] && P_OK=0
    # ГАРД МЕСТА — ПО ДЕЛЬТЕ, а не по абсолюту. Отказывать надо плану, который ЗАБИРАЕТ место у
    # тома; человек, пришедший место ОСВОБОДИТЬ, не может быть остановлен нехваткой места.
    # Прежняя форма судила по одному «останется < резерва» — и на роутере, уже перебравшем
    # резерв, панель отвечала «не хватает 2.11 МБ» и на план «снять ByeDPI», и на ПУСТОЙ план
    # (панель считает им полосу флеша, то есть карточка блокировала сама себя).
    # P_SHORT — размер нехватки: считает РОУТЕР, панель его только печатает (её инвариант
    # «своей арифметики во фронте НЕТ»; вторая копия этого вычитания там и жила).
    P_TAKES=$((P_NEED - P_FREED))
    if [ "$P_TAKES" -gt 0 ] && [ "$P_LEFT" -lt "$RESERVE_B" ]; then
        P_OK=0
        P_SHORT=$((RESERVE_B - P_LEFT))
    fi
    # Вторая сторона: место на накопителе. Спрашиваем ТОЛЬКО когда туда что-то поедет — иначе
    # это лишний df на роутере без флешки (а таких большинство).
    P_SFREE=0; P_SLEFT=0
    if [ "$P_NEED_ST" -gt 0 ] || [ "$P_FREED_ST" -gt 0 ]; then
        P_SFREE=$(store_free_b); case "$P_SFREE" in ''|*[!0-9]*) P_SFREE=0 ;; esac
        P_SLEFT=$((P_SFREE + P_FREED_ST - P_NEED_ST))
        if [ "$P_NEED_ST" -gt 0 ] && [ "$P_SLEFT" -lt "$STORE_RESERVE_B" ]; then
            P_ERR="$P_ERR на внешнем накопителе не хватает места"
            P_OK=0
        fi
    fi
}

# Что МОЖНО снять, чтобы освободить место (панель показывает это списком «сними лишнее»).
# Только установленное, без гарда и не участвующее в текущем плане.
# need_b/freed_b/left_b — ПРО /data: панель считает по ним «останется свободно» и рисует полосу
# флеша, поэтому смешивать сюда накопитель нельзя (арифметика перестала бы сходиться). Что
# уедет на флешку, отдаём отдельными полями — они появились вместе с накопителем и на роутере
# без него всегда нули.
cmd_plan() {
    plan_calc "$1" "$2"
    # upd — какие из «ставим» обновления (имена через пробел): CGI пишет план в журнал операции ДО старта движка, и без этого
    # поля карточка «Идёт установка» первые секунды называла обновление «Поставить» (замер BE7000 29.09.2026).
    printf '{"ok":%s,"free_b":%s,"need_b":%s,"freed_b":%s,"left_b":%s,"reserve_b":%s,"short_b":%s,"mount":"%s","unknown":%s,"upd":"%s"' \
        "$([ "$P_OK" = 1 ] && echo true || echo false)" "$P_FREE" "$P_NEED" "$P_FREED" "$P_LEFT" "$RESERVE_B" \
        "$P_SHORT" "$(disk_mount)" \
        "$([ "$P_UNK" = 1 ] && echo true || echo false)" "$P_UPD"
    printf ',"store":%s,"need_store_b":%s,"freed_store_b":%s,"store_free_b":%s' \
        "$(store_ready && echo true || echo false)" "$P_NEED_ST" "$P_FREED_ST" "$P_SFREE"
    printf ',"errors":['
    [ -n "$P_ERR" ] && printf '"%s"' "$(printf '%s' "$P_ERR" | sed 's/^ *//')"
    printf '],"blocked":['
    _f=1
    if [ -n "$P_BLOCK" ]; then
        # `printf '%s\n'` ОБЯЗАТЕЛЕН: без завершающего перевода строки `while read` возвращает
        # ненулевой код на последней записи и молча её теряет — а записей тут обычно ровно одна,
        # так что «нельзя снять, потому что…» не печаталось вовсе (ok=false без единой причины).
        printf '%s\n' "$P_BLOCK" | tr '|' '\n' | while IFS= read -r b; do
            [ -n "$b" ] || continue
            [ "$_f" = 1 ] || printf ','
            _f=0
            printf '{"id":"%s","why":"%s"}' "${b%%:*}" "$(printf '%s' "${b#*: }")"
        done
    fi
    printf '],"free_candidates":['
    _f=1
    for p in $PKGS; do
        [ "$(pkg_state "$p")" = absent ] && continue
        [ -n "$(pkg_hold "$p")" ] && continue
        in_list "$p" "$P_DEL" && continue
        in_list "$p" "$P_INS" && continue
        # Кандидат, освобождающий 0 байт (частичная связка, чьи файлы держит кто-то ещё), в списке
        # «сними, чтобы влезло» — обман: человек снимет и не получит ни мегабайта. Считаем строго
        # по /data: список нужен ровно тогда, когда упёрлись в резерв ФЛЕША, и связка, целиком
        # уехавшая на накопитель, там не помогает ничем.
        _d=$(pkg_del_b "$p" "$p" data); [ "$_d" -gt 0 ] || continue
        [ "$_f" = 1 ] || printf ','
        _f=0
        printf '{"id":"%s","label":"%s","del_b":%s}' "$p" "$(pkg_label "$p")" "$_d"
    done
    printf ']}\n'
}

# --- ВЫПОЛНЕНИЕ ------------------------------------------------------------------------
# Пидфайл(ы) демона связки. Нужны, чтобы снятие не оставляло ЖИВОЙ процесс без бинаря:
# гарды выше берегут лишь то, что числится активным (.transport, слоты), а осиротевшийся демон
# (упавший switch, прерванный failover) в них не виден — и продолжает держать общий socks 10808
# или xtun. Ровно за этим `_kill_alt_daemon` стоит в purge-alt установщика; панельный путь
# остался без него, хотя теперь именно он — единственный экран установки.
pkg_pids() { case "$1" in
        xray) echo /tmp/enodia-xray.pid ;; hy2) echo /tmp/enodia-hysteria.pid ;; byedpi) echo /tmp/enodia-byedpi.pid ;;
        doh) echo /tmp/enodia-doh.pid ;; tls) echo /tmp/enodia-panel-tls.pid ;; filter) echo /tmp/enodia-dns-filter.pid ;;
    esac; }
kill_by_pidfile() { [ -f "$1" ] || return 0; start-stop-daemon -K -p "$1" >/dev/null 2>&1; rm -f "$1"; return 0; }

do_remove() {       # $1 = связка, $2 = весь список снимаемых
    log "Снимаю $(pkg_label "$1")…"
    # Zapret снимает СЕБЯ САМ: у него не только бинарь, но и правила NFQUEUE, dnsmasq и флаг
    # десинка — вторая копия этого teardown разъехалась бы с zapret.sh на первой же правке.
    # Гард `-f` + `sh` (класс Б5-9): при `-x` снятый бит выполнения давал ТИХИЙ пропуск teardown
    # и бодрое «Снимаю Zapret…» в логе при живых правилах и живом nfqws.
    if [ "$1" = zapret ]; then
        [ -f "$ENODIA_DIR/zapret.sh" ] && sh "$ENODIA_DIR/zapret.sh" remove >> "$LOG" 2>&1
        return 0
    fi
    for _pf in $(pkg_pids "$1"); do kill_by_pidfile "$_pf"; done
    # Сносим ОБЕ возможные копии — резидентную и на внешнем накопителе. Инвариант store-lib
    # «копия ровно одна» держится именно здесь: оставь мы файл на накопителе, bin_path (он
    # предпочитает накопитель) продолжил бы отдавать снятый бинарь как живой.
    for b in $(pkg_own "$1"); do
        rm -f "$ENODIA_BIN/$b"
        [ "$BIN_DIR" != "$ENODIA_BIN" ] && rm -f "$BIN_DIR/$b"
    done
    if [ -n "$(pkg_shared "$1")" ] && ! hev_needed_after "$2"; then
        log "hev больше никому не нужен — снимаю"
        kill_by_pidfile /tmp/enodia-hev.pid
        rm -f "$ENODIA_BIN/hev"
        [ "$BIN_DIR" != "$ENODIA_BIN" ] && rm -f "$BIN_DIR/hev"
    fi
    return 0
}
do_install() {      # $1 = связка
    if in_list "$1" "$P_UPD"; then log "Обновляю $(pkg_label "$1")…"; else log "Ставлю $(pkg_label "$1")…"; fi
    if [ "$1" = zapret ]; then
        # У zapret своя установка: бинарь + фейки TLS/QUIC + переигрыш правил, если десинк был включён.
        [ -f "$ENODIA_DIR/zapret.sh" ] || { log "нет zapret.sh — обновите скрипты"; I_WHY=${I_WHY:-"нет zapret.sh — обновите скрипты"}; return 1; }
        # Причину отказа называет zapret.sh строкой «[zapret] FAIL: …» (закачку он ведёт в СВОЙ журнал, и строк fetch-bin здесь
        # нет) — без неё итог говорил только «zapret не установился» (ревью шага 6c, круг 2).
        # Обновление — тот же верб с ключом: стоящий nfqws без него zapret.sh честно оставляет как есть («уже установлен»).
        _zu=""; bin_outdated nfqws && _zu=update
        if ! sh "$ENODIA_DIR/zapret.sh" install $_zu >> "$LOG" 2>&1; then
            _zw=$(grep '^\[zapret\] FAIL: ' "$LOG" 2>/dev/null | tail -n 1 | sed 's/^\[zapret\] FAIL: //')
            log "zapret не установился"; I_WHY=${I_WHY:-${_zw:-"zapret не установился"}}; return 1
        fi
        # ОБНОВЛЕНИЕ — своими словами и БЕЗ совета «включить» (ревью ветки, круг 1): ветка zapret выходит раньше общей, и прежде
        # обновление писало «Zapret установлен. Включить — …», а про прежнюю сборку nfqws в работе молчало (её строка уходит в
        # свой журнал zapret.sh). Спрашиваем тот же факт, что и общая ветка.
        if in_list zapret "$P_UPD"; then
            bst_mark_fresh nfqws
            _ro=$(sh "$GH" bin-status nfqws 2>/dev/null | awk -F'\t' '$5 == "old" { print $1 }')
            if [ -n "$_ro" ]; then log "Zapret обновлён. Сейчас работает прежняя сборка (nfqws) — новая заработает после перезапуска компонента: кнопка «Перезапустить» в его строке, а где её нет — перезагрузка роутера."
            else log "Zapret обновлён."; fi
            return 0
        fi
        # Звать включать — только если ядро умеет NFQUEUE (AX3600 на 4.4 не умеет): иначе строка предлагала бы действие, которого нет
        # (карта проекта: `nfq-ok` обязан звать КАЖДЫЙ, кто предлагает действие).
        if sh "$ENODIA_DIR/zapret.sh" nfq-ok >/dev/null 2>&1; then log "Zapret установлен. Включить — в «Соединение → Транспорт»."
        else log "Zapret установлен, но ядро роутера без NFQUEUE — включить его здесь нельзя."; fi
        return 0
    fi
    _upd_b=""
    for b in $(pkg_files "$1"); do
        # Файл из решения плана (P_FILES) и ещё нужен: общий, уже привезённый предыдущей связкой, свеж (bst_mark_fresh).
        in_list "$b" "$P_FILES" || continue
        { ! have_bin "$b" || bin_outdated "$b"; } || continue
        if have_bin "$b"; then
            # Какая стоит и какая приедет — словами апдейтера; стоящую он знает не всегда (поставлена до учёта версий).
            _bc=$(bst_field "$b" 3); _ba=$(bst_field "$b" 4)
            log "Обновляю $b: ${_bc:-прежняя сборка} → ${_ba:-свежая сборка}…"; _upd_b="$_upd_b $b"
        elif in_list "$b" "$_stg"; then
            log "Ставлю $b из файла, загруженного с компьютера…"   # «Скачиваю» было бы неправдой: сети этот шаг не касается
        elif [ "$PF_ON" = 1 ] && in_list "$b" "$PF_LIST"; then
            log "Ставлю $b (скачан заранее)…"
        else
            log "Скачиваю $b…"
        fi
        # КУДА качать решает bin_dest (store-lib.sh), а не этот цикл: с включённым накопителем
        # тяжёлое едет сразу туда, минуя 20-МБ флеш (иначе «поставить три транспорта» упиралось бы
        # в место ровно так же, как до накопителя). bin_prune следом убирает копию с другой
        # стороны — bin_path предпочитает накопитель, и забытый там старый файл выдавал бы себя
        # за свежескачанный. Порог обрыва и арку выбирает сам gh-update (bin-manifest.txt).
        _dst=$(bin_dest "$b")
        mkdir -p "${_dst%/*}" 2>/dev/null
        # ПРИЧИНУ отказа называет fetch-bin (его последняя строка FAIL: код GitHub, обрыв, целостность); её и поднимаем в итог —
        # строки прогресса идут раз в 2 с, и на медленном канале хвост журнала вытеснил бы её вовсе (ревью шага 6c, круг 1).
        if ! sh "$GH" fetch-bin "$b" "$_dst" >> "$LOG" 2>&1; then
            _fw=$(grep '^\[fetch-bin\] FAIL: ' "$LOG" 2>/dev/null | tail -n 1 | sed 's/^\[fetch-bin\] FAIL: //')
            log "не скачал $b"; I_WHY=${I_WHY:-${_fw:-"не скачал $b"}}; return 1
        fi
        bin_prune "$b"
        bst_mark_fresh "$b"
        [ "$_dst" = "$ENODIA_BIN/$b" ] || log "  $b лёг на внешний накопитель"
    done
    # ЗАМЕНА ФАЙЛА ДЕМОН НЕ ПЕРЕЗАПУСКАЕТ — и движок не будет: он ставит, а не активирует. Перезапуск несущей роняет туннель,
    # прокси шифрованного DNS встаёт ~28 с (сеть всё это время без имён) — решать такое за человека нельзя. Но СКАЗАТЬ обязаны:
    # иначе «обновил, а ничего не изменилось». Спрашиваем по факту (живой процесс исполняет заменённый файл), а не гадаем.
    if [ -n "$_upd_b" ] && [ -f "$GH" ]; then
        _ro=$(sh "$GH" bin-status $_upd_b 2>/dev/null | awk -F'\t' '$5 == "old" { printf "%s%s", s, $1; s=", " }')
        [ -n "$_ro" ] && log "Сейчас работает прежняя сборка ($_ro) — новая заработает после перезапуска компонента: кнопка «Перезапустить» в его строке, а где её нет — перезагрузка роутера."
    fi
    # «Установлен ≠ активен» — про это надо СКАЗАТЬ, иначе «поставил и ничего не изменилось». Обновлению — не надо: оно не меняет,
    # включён ли компонент, и совет «включить — там-то» уводил бы человека включать уже включённое.
    in_list "$1" "$P_UPD" && return 0
    case "$1" in
        # Куда идти включать — адресом панели («раздел → экран»): прежнее «Транспорт VPN» было карточкой главной, которой нет.
        awg|xray|hy2) log "$(pkg_label "$1") установлен. Включить — в «Соединение → Транспорт» (нужен активный конфиг)." ;;
        byedpi) log "ByeDPI установлен. Включить — в «Соединение → Транспорт»." ;;
        doh) log "Компоненты шифрованного DNS установлены. Включить — в «Сеть → Шифрованный DNS»." ;;
        tls) log "Компонент HTTPS установлен. Включить — в «Панель → Доступ к панели»." ;;
        filter) log "Фильтр по категориям установлен. Действует в окнах «ограничено» — «Маршрутизация → Расписания доступа»." ;;
    esac
    return 0
}

cmd_apply() {
    : > "$LOG"; set_state RUNNING
    # «Чья операция» — сразу, до расчёта плана (он читает бинари и стоит секунды). Третье поле («из них обновления») знает только
    # план; его уже записал CGI для ЭТОЙ ЖЕ операции (pkg_bg) — сохраняем, а не затираем: панель рисует карточку «Идёт установка»
    # именно в это окно, и прежняя запись двумя полями называла обновление «Поставить» (замер BE7000 29.09.2026).
    _pu=-
    if [ -f "$PLANF" ]; then
        IFS="$(printf '\t')" read -r _pa _pd _pc < "$PLANF" 2>/dev/null
        [ "$_pa" = "${1:--}" ] && [ "$_pd" = "${2:--}" ] && [ -n "$_pc" ] && _pu=$_pc
    fi
    printf '%s\t%s\t%s\n' "${1:--}" "${2:--}" "$_pu" > "$PLANF" 2>/dev/null
    plan_calc "$1" "$2"
    # Третье поле плана — какие из «ставим» на деле ОБНОВЛЕНИЯ: по окончании связка «установлена» в обоих случаях, и отличить
    # «Поставить» от «Обновить» в «Последней операции» задним числом нечем. Пишем ПОСЛЕ plan_calc — он это и решает.
    printf '%s\t%s\t%s\n' "${1:--}" "${2:--}" "$(printf '%s' "${P_UPD:--}" | tr ' ' ',')" > "$PLANF" 2>/dev/null
    log "План: ставим [${P_INS:-—}], снимаем [${P_DEL:-—}]${P_UPD:+, из них обновляем [$P_UPD]}"
    if [ -n "$P_ERR" ]; then set_state FAIL; log "Отказ:$P_ERR"; return 1; fi
    if [ -n "$P_BLOCK" ]; then
        set_state FAIL
        printf '%s\n' "$P_BLOCK" | tr '|' '\n' | while IFS= read -r b; do [ -n "$b" ] && log "Нельзя снять $b"; done
        return 1
    fi
    log "Свободно $(mb "$P_FREE") МБ; освободим $(mb "$P_FREED"), займём $(mb "$P_NEED"), останется $(mb "$P_LEFT") МБ"
    [ "$P_NEED_ST" -gt 0 ] && log "На внешний накопитель уедет $(mb "$P_NEED_ST") МБ (свободно там $(mb "$P_SFREE") МБ) — флеш это не тронет"
    [ "$P_UNK" = 1 ] && log "ВНИМАНИЕ: размеры части файлов неизвестны (нет bin-manifest.txt) — оценка занятого НЕПОЛНАЯ."
    # ГАРД — ТОТ ЖЕ, ЧТО У ПЛАНА (по ДЕЛЬТЕ, `P_SHORT` считает plan_calc): прежний абсолютный «останется < резерва» здесь
    # отказывал и в СНЯТИИ на переполненном флеше — план панели говорил «можно», движок «не хватает места», и освободить место
    # было нечем (найдено ревью ветки fix/dot-tails, круг 2: свободно 0.9 МБ, «снять ByeDPI» — отказ).
    if [ "$P_SHORT" -gt 0 ]; then
        set_state FAIL
        log "Не хватает места: после операции осталось бы $(mb "$P_LEFT") МБ при неснижаемом резерве $(mb "$RESERVE_B") МБ. Снимите что-нибудь ещё."
        return 1
    fi
    # Пре-чек сети ДО удалений: иначе снимем рабочий компонент и не скачаем новый (тот же довод,
    # что в proto-install — там на этом уже обжигались). reachable = проба СЕТИ, не наличия файла.
    # Гард `-f`, а не `-x`: при снятом бите пре-чек молча ПРОПУСКАЛСЯ (условие ложно) — то есть
    # ровно в том случае, когда качать всё равно будем через `sh "$GH"`, мы сперва сносили
    # рабочий компонент и только потом узнавали, что сети нет.
    # ПРИЧИНУ берём у пре-чека, а не выдумываем: «GitHub недоступен» на отказе по частоте (429)
    # отправляло человека чинить интернет, которого не ломали. Пусто = старая копия gh-update,
    # которая причин ещё не печатает ⇒ прежний текст.
    # ВСЁ НУЖНОЕ УЖЕ ЗАГРУЖЕНО С КОМПЬЮТЕРА (gh-update.sh bin-stage) — GitHub не нужен вовсе, и пре-чек сети отказал бы ровно тому,
    # кто загрузил файлы, потому что GitHub у него закрыт (решение пользователя 30.09.2026). Пустой список качаемого — то же самое.
    # Перечень — В ОДНУ СТРОКУ через пробел: in_list ищет « имя »; построчный вывод находил имя, только когда файл один (ревью с.88).
    _stg=""; [ -f "$GH" ] && _stg=$(sh "$GH" bin-staged 2>/dev/null | tr '\n' ' ')
    _cov=1; for b in $P_FILES; do in_list "$b" "$_stg" || _cov=0; done
    if [ -n "$P_INS" ] && [ -f "$GH" ] && [ "$_cov" = 1 ]; then
        # P_FILES начинается пробелом (разделитель plan_calc) — «есть что качать» судим по НЕпробельному символу, иначе строка писалась бы
        # и при пустом плане закачки (ревью с.88, круг 2).
        case "$P_FILES" in *[!\ ]*) log "Нужные файлы загружены с компьютера — GitHub не спрашиваю." ;; esac
    elif [ -n "$P_INS" ] && [ -f "$GH" ]; then
        _why=$(sh "$GH" reachable 2>/dev/null)
        if [ "$?" != 0 ]; then
            [ -n "$_why" ] || _why="GitHub недоступен — проверьте интернет"
            set_state FAIL; log "$_why. НИЧЕГО не тронул."; return 1
        fi
    fi
    # ЗАКАЧКА ЗАРАНЕЕ — ДО ПЕРВОЙ ПЕРЕМЕНЫ (решение пользователя 01.10.2026). Прежде снятия шли ПЕРВЫМИ, а пре-чек выше спрашивает
    # только СЕТЬ: «на GitHub другая сборка» (нет тега, чужой .gh-repo, дев-код без опубликованного тега) — отказ детерминированный, и
    # план «снять Xray, поставить Hysteria2» оставлял без обоих; так же — связка из двух файлов (amneziawg-go + awg), где второй не
    # скачался. Теперь всё, что план качает, сперва ложится в ОЗУ (gh-update.sh bin-prefetch — та же сверка с подписанным манифестом),
    # и только потом снятия и установка из скачанного (она сверяет копию ещё раз). Загруженное с компьютера не качаем — оно уже в ОЗУ.
    # Цена — ОЗУ на время операции (xray — 8 МБ); не хватает — прежний порядок, и журнал говорит это словами. Скачанное, но не взятое
    # (отказ, упавшая связка, обрыв) из ОЗУ убирает ловушка выхода — при любом исходе, одна на все дороги.
    PF_LIST=""; PF_ON=0   # не `_pf`: так зовётся цикл пидфайлов в do_remove, и снятие затирало бы этот список
    # Хвост операции, убитой без ловушек (SIGKILL, OOM), — вон ДО решения: иначе при нехватке ОЗУ (прежний порядок) установка молча
    # взяла бы его, а журнал писал бы «Скачиваю» (ревью порции «закачка заранее», находка 7).
    [ -f "$GH" ] && sh "$GH" bin-unprefetch >/dev/null 2>&1
    for b in $P_FILES; do in_list "$b" "$_stg" || PF_LIST="$PF_LIST $b"; done
    if [ -n "$P_INS" ] && [ -f "$GH" ] && [ -n "$PF_LIST" ]; then
        _pfn=0
        for b in $PF_LIST; do _pfs=$(sh "$GH" bin-size "$b" 2>/dev/null | tr -d ' \r'); case "$_pfs" in ''|*[!0-9]*) _pfs=0 ;; esac; _pfn=$((_pfn + _pfs)); done
        _pfr=$(ram_room_b)
        if [ "$_pfr" -lt $((_pfn + PF_MARGIN_B)) ]; then
            log "Заранее не скачать: в ОЗУ свободно $(mb "$_pfr") МБ, нужно $(mb "$_pfn") МБ и запас — качаю по ходу установки, как прежде."
        else
            PF_ON=1
            for b in $PF_LIST; do
                log "Скачиваю заранее: $b…"
                if ! sh "$GH" bin-prefetch "$b" >> "$LOG" 2>&1; then
                    _fw=$(grep '^\[fetch-bin\] FAIL: ' "$LOG" 2>/dev/null | tail -n 1 | sed 's/^\[fetch-bin\] FAIL: //')
                    set_state FAIL; log "Не скачал $b: ${_fw:-причина в журнале операции}. НИЧЕГО не тронул."; return 1
                fi
            done
            log "Всё нужное скачано — меняю набор."
        fi
    fi
    for p in $P_DEL; do do_remove "$p" "$P_DEL"; done
    [ -n "$P_DEL" ] && sync 2>/dev/null
    _rc=0; I_WHY=""
    for p in $P_INS; do do_install "$p" || _rc=1; done
    if [ "$_rc" = 0 ]; then
        set_state OK; log "Готово. Свободно $(mb "$(disk_free_b)") МБ."
    else
        # Итог — ПОСЛЕДНЕЙ строкой и С ПРИЧИНОЙ первого отказа: панель и тост показывают именно её, а «см. журнал выше» при хвосте
        # в 40 строк может ссылаться на вытесненное.
        set_state FAIL; log "Часть компонентов не установилась: ${I_WHY:-причина в журнале операции}"
    fi
    return $_rc
}

# ИДЁТ ЛИ ОПЕРАЦИЯ И КАКАЯ (заполняет _bs · _bp · _br · _bi · _bd). Держатель — ЖИВОЙ ПРОЦЕСС, а не строка в файле (разбор —
# у верба `busy` ниже). Состояние пишем в JSON как есть, поэтому берём из файла только буквы: сбойная запись не должна рвать
# ответ, по которому панель запирает кнопки.
# ДЕРЖАТЕЛЬ — ЖИВОЙ процесс ИМЕННО НАШЕГО скрипта (движок или его CLI-двойник), а не «какой-то pid жив» (разбор у
# daemon-lib.sh::pid_runs). Спрашивают ДВОЕ — `busy` (гард кнопки) и проверка протухшего лока ниже: разойдись они, `busy` пускал бы
# «Применить», а движок отказывал бы «уже выполняется» (ревью шага 6c, круг 3).
pkg_pid_ours() { pid_runs "$1" 'packages\.sh|proto-install\.sh'; }
busy_calc() {
    _bs=$(cat "$STATE" 2>/dev/null | tr -cd 'A-Z'); [ -n "$_bs" ] || _bs=IDLE
    _bp=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')
    # Pid в каталоге лока МЁРТВ (OOM, `kill -9` — трапов нет, лок остался) — судим по пидфайлу фона: иначе новая операция из панели в
    # первые мгновения (до того, как движок перехватит лок) читалась бы «не идёт» (ревью шага 6c, круг 1).
    pkg_pid_ours "$_bp" || _bp=$(cat "$BGPID" 2>/dev/null | tr -cd '0-9')
    _br=false
    [ "$_bs" = RUNNING ] && pkg_pid_ours "$_bp" && _br=true
    # План — словами движка (`ins`/`del`, имена связок через пробел, «-» = ничего); чужого в строку не пускаем.
    # Третье поле (`_bu`) — какие из «ставим» обновления; у плана прежнего формата (и у записи из CGI до старта движка) его нет.
    _bi=""; _bd=""; _bu=""; _brs=""
    if [ -f "$PLANF" ]; then
        IFS="$(printf '\t')" read -r _bi _bd _bu _brs < "$PLANF" 2>/dev/null
        _bi=$(printf '%s' "$_bi" | tr ',' ' ' | tr -cd 'a-z0-9 -'); _bd=$(printf '%s' "$_bd" | tr ',' ' ' | tr -cd 'a-z0-9 -')
        _bu=$(printf '%s' "$_bu" | tr ',' ' ' | tr -cd 'a-z0-9 -'); _brs=$(printf '%s' "$_brs" | tr ',' ' ' | tr -cd 'a-z0-9 -')
    fi
    return 0
}
# Журнал — ХВОСТ: у полной установки строк два десятка, а панели нужен смысл, а не простыня. `at` — отметка ЖУРНАЛА (последняя
# запись = конец операции), `now` — часы роутера: возраст панель считает по ним обоим, как у журнала событий, и часы браузера
# тут ни при чём. Журнала нет — операций не было: `at` = 0 и пустой массив. Смену набора из CLI (proto-install.sh) пишет тот же
# журнал, а план стирает — тогда `ins`/`del` пусты, и панель называет операцию общими словами.
cmd_op_json() {
    busy_calc
    _at=$(stat -c %Y "$LOG" 2>/dev/null); case "$_at" in ''|*[!0-9]*) _at=0 ;; esac
    printf '{"running":%s,"state":"%s","ins":"%s","del":"%s","upd":"%s","rst":"%s","at":%s,"now":%s,"log":[' "$_br" "$_bs" "$_bi" "$_bd" "$_bu" "$_brs" "$_at" "$(date +%s)"
    # Потолок строки — 600 байт: итог отказа с причиной 429 весит ~330, и при 300 обрывался посреди фразы, а под английским
    # оставался русским целиком (перевод по обрывку не ложится; ревью шага 6c, круг 3).
    [ -f "$LOG" ] && tail -n 40 "$LOG" 2>/dev/null | jlines 600
    printf ']}\n'
}

case "$1" in
    list-json) cmd_list_json ;;
    plan)      cmd_plan "$2" "$3" ;;
    # МАШИННЫЙ вердикт для sh-вызывающих (proto-install.sh, установщик с ПК): код 0 = «влезет,
    # сносить ради места ничего не надо». JSON на busybox не парсят, а вторая копия арифметики
    # ровно там и разъезжается («в панели влезало, а на роутере нет»). Неизвестные размеры =
    # ОТКАЗ: лучше отработать по-старому (снести лишнее), чем соврать «места хватит».
    # Обновлений plan-ok НЕ считает (срез пуст ⇒ устаревших нет): его машинные вызыватели (proto-install.sh) ставят только
    # недостающее, и новые сборки устаревших файлов, которых они качать не будут, у границы резерва давали лишний purge-alt
    # установленных альтов (ревью ветки, круг 1).
    plan-ok)   BST_DONE=1; BST=""; plan_calc "$2" "$3"; [ "$P_OK" = 1 ] && [ "$P_UNK" = 0 ] && exit 0; exit 1 ;;
    # Лок — mkdir (атомарно, без TOCTOU): два клика в панели на 20-МБ флеше = «No space».
    # Тот же лок, что у proto-install.sh: смена набора и правка компонентов — одна очередь.
    # ВТОРОЙ лок — switching: между `do_remove` (гасим демоны снимаемой связки) и концом закачек
    # лежат МИНУТЫ, и тик сторожа в это окно волен уводить транспорт/переподнимать несущую поверх
    # идущей установки. proto-install.sh это уже держит (батч 10), а панельный путь — единственный
    # экран установки — ходит СЮДА. Идиома общая: чужой лок не трогаем, свой снимаем trap'ом.
    apply|install|remove|restart)
               if ! mkdir "$LOCK" 2>/dev/null; then
                   # ЛОК МОЖЕТ БЫТЬ ПРОТУХШИМ, и признать это обязаны МЫ. Держатель снимает его trap'ом, но
                   # `kill -9` (OOM на 176-МБ модели) трапов не знает, а `ram-lib.sh` мог принести сюда лок,
                   # взятый кодом ПРОШЛОЙ эпохи под прежним именем — снять его по старому пути уже некому.
                   # Судим ПО ДЕРЖАТЕЛЮ: pid внутри каталога. Пусто — это либо ОКНО между `mkdir` и записью
                   # ПИДа (микросекунды), либо как раз прошлая эпоха (тогда pid внутрь не писали вовсе).
                   # Различаем ОДНОЙ секундой сна, без часов: окно закрывается само, эпоха — нет. Часам тут
                   # верить нельзя (RTC нет, они прыгают через ~13 мин после загрузки), поэтому не возраст.
                   _pl=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')
                   [ -n "$_pl" ] || { sleep 1; _pl=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9'); }
                   # Держатель — ЖИВОЙ процесс движка или этого скрипта (тот же ответ, что у packages.sh::pkg_pid_ours и `busy`).
                   if pid_runs "$_pl" 'packages\.sh|proto-install\.sh'; then echo "уже выполняется"; exit 1; fi
                   rm -rf "$LOCK" 2>/dev/null
                   mkdir "$LOCK" 2>/dev/null || { echo "уже выполняется"; exit 1; }
               fi
               echo $$ > "$LOCK/pid" 2>/dev/null
               # A SYSTEM UPDATE replaces this very file, gh-update.sh and bin-manifest.txt under a running operation (fetch-bin would
               # check against another manifest), and both peak on the 20-MB /data at once (review of bins-2026-10, round 3: the visible
               # «Обновление» door made it one click away). Asked AFTER our lock — pkg-install.sh asks `busy` after its own (pi_gate), so
               # at least one of two that started together sees the other. The updater's own answer covers the download before it.
               if { command -v pkg_install_alive >/dev/null 2>&1 && pkg_install_alive; } || { [ -f "$GH" ] && sh "$GH" upd-busy >/dev/null 2>&1; }; then
                   : > "$LOG"; set_state FAIL; log "Идёт обновление системы — компоненты не трогал; дождитесь его конца и повторите"
                   rm -rf "$LOCK" 2>/dev/null; exit 1
               fi
               SWLOCK=/tmp/enodia-switching.lock; SWMINE=0
               # `restart` takes it itself — with its pid, after waiting for the watchdog and heal (cmd_restart, switch_hold).
               [ "$1" = restart ] || [ -e "$SWLOCK" ] || { : > "$SWLOCK" 2>/dev/null && SWMINE=1; }
               # Уборка — ОДНА, на выходе, при ЛЮБОМ исходе: скачанное заранее из ОЗУ (иначе мегабайты лежали бы в /tmp до ребута) —
               # ДО снятия лока, иначе следующая операция успела бы начать свою закачку в тот же каталог. СИГНАЛ — это ВЫХОД (ревью
               # порции «закачка заранее», находка 5): ловушка INT/TERM/HUP/PIPE без `exit` убирала лок и ОЗУ, а шелл шёл ДАЛЬШЕ — к
               # снятиям без лока (HUP при обрыве SSH у CLI-запуска). EXIT-ловушка busybox на сигнале сама не срабатывает — отсюда
               # `exit 1` в сигнальной: он и зовёт уборку.
               pkg_exit() {
                   [ -f "$GH" ] && sh "$GH" bin-unprefetch >/dev/null 2>&1
                   rm -rf "$LOCK" 2>/dev/null; [ "$SWMINE" = 1 ] && rm -f "$SWLOCK" 2>/dev/null
                   return 0
               }
               trap pkg_exit EXIT
               trap 'exit 1' INT TERM HUP PIPE
               case "$1" in
                   apply)   cmd_apply "$2" "$3" ;;
                   install) cmd_apply "$2" "" ;;
                   remove)  cmd_apply "" "$2" ;;
                   restart) cmd_restart "$2" "$3" ;;
               esac ;;
    state)     cat "$STATE" 2>/dev/null || echo IDLE ;;
    # ЕДИНСТВЕННЫЙ ОТВЕТ «идёт ли установка ПРЯМО СЕЙЧАС». До 03.09.2026 на него отвечали ТРОЕ и
    # по-разному: web-ui.sh — по pid-файлу фонового запуска, гард панели — по .state плюс pid
    # внутри лока, а `data` отдавал сырой .state. Разъезд стоил бага: карточка предлагала кнопку
    # «Установить», а гард на неё отказывал. Держатель — ЖИВОЙ ПРОЦЕСС, а не строка в файле:
    # RUNNING без держателя (ребут посреди операции, `kill -9` от OOM) — осиротевший статус, и
    # «идёт» он не значит, иначе панель залипает в «устанавливаю…» навсегда.
    # Код возврата: 0 = идёт, 1 = нет. JSON — для панели (ей нужен и сам статус).
    busy)      busy_calc
               # `busy <связка>` — ещё и `mine`: ставит ли текущая (или последняя) операция ЭТУ связку. Ответ один на всех
               # читателей (секция doh, карточка HTTPS): своя копия разбора плана у каждого разъехалась бы (ревью 5a, круг 3).
               _bm=false
               [ -n "$2" ] && case " $_bi " in *" $2 "*) _bm=true ;; esac
               printf '{"running":%s,"state":"%s","pid":%s,"ins":"%s","del":"%s","upd":"%s","rst":"%s","mine":%s}\n' "$_br" "$_bs" "${_bp:-0}" "$_bi" "$_bd" "$_bu" "$_brs" "$_bm"
               [ "$_br" = true ] && exit 0
               exit 1 ;;
    # ПОСЛЕДНЯЯ ОПЕРАЦИЯ — экрану «Компоненты»: что делали, чем кончилось, когда и журнал словами движка. Тост с отказом
    # исчезает, а причина («GitHub ограничил…», «не скачал xray») остаётся только здесь. Отдельный верб, а не поля в `busy`:
    # `busy` зовут гард кнопки и опрос раз в две секунды, и журнал им не нужен.
    op-json)   cmd_op_json ;;
    # ТОЧЕЧНЫЙ и ДЕШЁВЫЙ ответ «стоит ли связка» (absent|partial|installed) — для тех, кому нужен
    # один пакет, а не весь срез. `list-json` для этого не годится: он на КАЖДУЮ связку зовёт
    # `gh-update.sh bin-ver` и сверку сборок. Здесь — только файловая система. Владелец состояния остаётся один (pkg_state), копий не заводим.
    pkg-state) pkg_known "$2" || { echo "неизвестный компонент: $2" >&2; exit 2; }
               pkg_state "$2" ;;
    *) echo "usage: $0 list-json | plan <ставим> <снимаем> | plan-ok <ставим> <снимаем> | apply <ставим> <снимаем> | install <список> | remove <список> | restart <список|-> [владельцы] | state | busy [компонент] | op-json | pkg-state <компонент>"; echo "       списки через запятую, «-» = пусто; компоненты: $PKGS"; exit 2 ;;
esac
