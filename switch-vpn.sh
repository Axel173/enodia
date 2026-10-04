#!/bin/sh
#
# switch-vpn.sh v3 — переключение страны/конфига AmneziaWG с правильной
# заменой ВСЕХ файлов конфигурации, без гонок с heal.sh и с safety net
# на случай полного фейла.
#
# v3 (май 2026) — лечит «при смене страны интернет на роутере пропадает,
# падает awg, помогает только перезагрузка»:
#
#   1) вендорный awg_setup.sh читает не awg.conf, а amnezia_for_awg.conf.
#      Из него генерирует awg0.conf для amneziawg-go. v2 копировал ТОЛЬКО
#      awg.conf — поэтому на самом деле awg продолжал использовать СТАРЫЕ
#      ключи/endpoint. v3 синхронно обновляет все три файла.
#
#   2) Новый конфиг от приложения AmneziaVPN 4.8.12.9+ часто содержит
#      пустые I1..I5 — старые awg-tools валятся на них. Перед запуском
#      вендорного скрипта v3 их вычищает.
#
#   3) Между bring_down и bring_up могут параллельно сработать heal.sh
#      (cron каждую минуту) и сломать состояние. v3 берёт лок
#      /tmp/enodia-switching.lock — heal.sh с него же читает и выходит,
#      пока идёт переключение.
#
#   4) Если awg0 в итоге не поднялся ни на новом, ни на старом конфиге —
#      v2 ОСТАВЛЯЛ висеть `ip rule fwmark 0x1 → table 1000 → dev awg0`
#      и mangle-правила по iplist_set (~3100 CIDR — Cloudflare/Google/
#      OpenAI/Discord). В результате весь трафик роутера к этим адресам
#      уходил в несуществующий awg0 → «интернет вовсе пропал, помогает
#      только ребут». v3 в этой ситуации флашит правила (safety_off),
#      роутер сохраняет доступ в интернет, а heal.sh при следующем
#      запуске всё восстановит.
#
#   5) Принудительно убиваем зависшие amneziawg-go процессы перед
#      bring_up (иногда init.d stop их не убирает, особенно если запуск
#      был не через init.d).
#
# Использование:
#   switch-vpn.sh                — список конфигов
#   switch-vpn.sh <имя>          — переключиться на configs/<имя>.conf
#   switch-vpn.sh status         — текущий статус
#   switch-vpn.sh rollback       — вручную откатиться на .last.bak
#   switch-vpn.sh failover       — перебрать резервы и встать на первый рабочий
#                                  (зовётся watchdog'ом при смерти активного VPS)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BOOT=${ENODIA_BOOT:-/data/usr/app/enodia-boot}   # для ПОДСКАЗОК в письмах: команду человеку даём только через запускатель
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v ct_flush >/dev/null 2>&1 || ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
CONFIGS_DIR="$ENODIA_STATE/configs"
ACTIVE_CONF="$ENODIA_STATE/awg.conf"
SHALIN_CONF="$ENODIA_STATE/amnezia_for_awg.conf"
AWG0_CONF="$ENODIA_STATE/awg0.conf"
ACTIVE_NAME="$ENODIA_STATE/.active"
BACKUP_CONF="$ENODIA_STATE/.last.bak.conf"
BACKUP_NAME="$ENODIA_STATE/.last.bak.name"
SWITCH_LOCK="/tmp/enodia-switching.lock"
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"   # обёртка событийных писем (throttle)
WD_STATE="/tmp/enodia-watchdog.state"   # состояние watchdog (NORMAL/FAILOPEN) — держим синхронным (см. safety_off/apply_routing)
HS_WAIT=25                       # сколько секунд ждать handshake

# Возраст отметки времени (clock-lib.sh). Критично именно здесь: wait_for_handshake судит «пришло
# ли рукопожатие», и при скачке часов (роутер без RTC, реальный случай 10.08.2026) РУЧНАЯ смена
# сервера из панели «не поднялась» и откатилась, хотя туннель встал. Шим = прежнее поведение.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

# Общий примитив «внешний IPv4» (ip-lib.sh): IP-литерал-проба, DNS-free — чинит пустой egress на
# ядре 4.4 (hostname api.ipify.org там молча пустел). Шим на случай частичной установки без lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }

# Язык событийных писем (rollback/failover/failopen) — панельный pref lang (деф. ru).
# Русские ветки сообщений ниже — байт-в-байт прежние; en — параллельный перевод.
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
NF_LANG=$(nf_lang)

# Слой шифрованного DNS (doh-lib.sh) — тот же приём, что в плагинах транспорта: DoH ВЫКЛ
# (дефолт) → doh_apply_dns даёт 1, и аварийная DNS-ветка safety_off работает прежним путём
# байт-в-байт. DoH ВКЛ → слой сам переводит dnsmasq на локальный прокси МИМО туннеля, и
# затирать 00-upstream.conf публичными серверами нельзя: это молча выключило бы шифрованный
# DNS до следующего repair. Шим — на случай установки без lib.
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
command -v doh_apply_dns >/dev/null 2>&1 || doh_apply_dns() { return 1; }
# «VPN выключен вручную — несущую не берёт никто» (daemon-lib.sh::carrier_barred, разбор там): смена и перебор серверов идут минутами,
# и выключение, нажатое посреди них, обязано их остановить (ревью ветки, круг 2). Нет библиотеки — прежний путь.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v carrier_barred >/dev/null 2>&1 || carrier_barred() { return 1; }
# Смерть демона ждём по процессу с шагом 0.1 с (daemon-lib.sh). Нет библиотеки — прежний секундный шаг.
command -v daemon_wait_gone >/dev/null 2>&1 || daemon_wait_gone() { _dwg=0; while [ -d "/proc/$1" ]; do [ "$_dwg" -ge "${2:-5}" ] && return 1; sleep 1; _dwg=$((_dwg+1)); done; return 0; }
# Поколение firewall reload (ipt-lib.sh). Нет библиотеки — «reload был всегда»: каждое чтение даёт новую строку, как раньше.
command -v fw3_gen >/dev/null 2>&1 || fw3_gen() { cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$-$RANDOM-$RANDOM"; }

# `/etc/init.d/firewall reload` из awg_setup.sh СНОСИТ ВСЕ iptables: цепочки apply-bypass
# (VPN_EXCLUDE/KEEP/DEV/PORTS/FORCE, режим «целиком в десинк»), ENODIA_ZAPRET + NFQUEUE, FORWARD
# доп-выходов, PANEL_WAN и цепочки «доступа домой». Полный переигрыш после этого делает ТОЛЬКО
# heal.sh (на буте), а смена страны из панели шла мимо него — правила оставались снесёнными до
# ребута, и сторож этого не видел (rule-heal судит по `FORWARD -o awg0 ACCEPT`, который тут же
# возвращает сам awg_setup). Флаг ставит bring_up — ТОЛЬКО если reload правда был (поколение
# `fw3_gen` сменилось: зона `awg` уже стоит ⇒ reload не нужен, см. awg_setup.sh), гасят его
# replay_* — так переигрыш случается РОВНО после нашего же fw3-reload.
FW3_WIPED=0

# Событийное письмо: $1 key, $2 throttle_sec, $3 тема, $4 текст.
# Тихо ничего не делает, если обёртки нет или почта не настроена
# (notify-event.sh сам уважает .notify-off и тихо выходит без notify.conf).
notify_event() {
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$CONFIGS_DIR"

# Бинарь для проверки handshake. Порядок ОБРАТНЫЙ прежнему и совпадает с wg_bin() в
# transport-awg.sh (инвариант «handshake читает awg, НЕ wg»): сперва НАШ awg из $ENODIA_DIR
# (amneziawg-tools известной версии), потом awg из PATH, и только в самом конце wg. На стоке
# wg нет вовсе, но если он появится от чужой установки — читать AWG-интерфейс им не наш выбор.
WG=""
[ -x "$ENODIA_BIN/awg" ] && WG="$ENODIA_BIN/awg"
[ -z "$WG" ] && command -v awg >/dev/null 2>&1 && WG=awg
[ -z "$WG" ] && command -v wg  >/dev/null 2>&1 && WG=wg

# ============================================================
# Локи против гонок с heal.sh
# ============================================================
SWITCH_LOCK_MINE=0
acquire_lock() {
    # ЧУЖОЙ лок не перебиваем и не снимаем — его снимет владелец (идиома take_switch_lock из
    # transport.sh, она же в proto-install.sh и в CGI панели). Прежняя форма (безусловный `: >` +
    # безусловный `rm` в trap) освобождала лок, который держал КТО-ТО ДРУГОЙ: смена сервера из
    # панели посреди установки компонентов открывала сторожу дорогу в середину чужой операции.
    [ -e "$SWITCH_LOCK" ] || { : > "$SWITCH_LOCK" 2>/dev/null && SWITCH_LOCK_MINE=1; }
    # Сигнал — ВЫХОД (C121): ловушка без `exit` снимала лок, а смена страны шла дальше уже без него.
    trap 'release_lock' EXIT
    trap 'exit 1' INT TERM HUP PIPE
}
release_lock() {
    # Сохраняем код возврата: failover отдаёт его watchdog'у (0=встал на резерв /
    # 1=прямой режим), а этот хендлер висит на EXIT-trap и не должен его затереть.
    _rc=$?
    [ "$SWITCH_LOCK_MINE" = 1 ] && rm -f "$SWITCH_LOCK" 2>/dev/null
    return $_rc
}

# ============================================================
# Утилиты
# ============================================================
list_configs() {
    printf "${BLUE}Доступные конфиги в $CONFIGS_DIR:${NC}\n"
    found=0
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        endpoint=$(grep -E "^Endpoint" "$f" | head -1 | awk -F'= *' '{print $2}')
        active=""
        if [ -f "$ACTIVE_NAME" ] && [ "$(cat "$ACTIVE_NAME")" = "$name" ]; then
            active="${GREEN} ← АКТИВНЫЙ${NC}"
        fi
        printf "  ${YELLOW}%-20s${NC} (Endpoint: %s)%s\n" "$name" "$endpoint" "$active"
        found=$((found+1))
    done
    [ $found -eq 0 ] && printf "  ${RED}Конфигов нет.${NC} Положите .conf в %s\n" "$CONFIGS_DIR"
}

show_status() {
    printf "${BLUE}Статус AmneziaWG:${NC}\n"
    if [ -f "$ACTIVE_NAME" ]; then
        # ПУСТОЙ ФАЙЛ = «имя неизвестно» (см. install_config): печатаем `?`, как соседи
        # (`status.sh`, `dump.sh`, boot-письмо heal) — один факт обязан называться одним словом.
        _ss_act=$(cat "$ACTIVE_NAME" 2>/dev/null | tr -d '\r')
        printf "  Активный конфиг: ${GREEN}%s${NC}\n" "${_ss_act:-?}"
    fi
    if ip link show awg0 >/dev/null 2>&1; then
        printf "  Интерфейс awg0: ${GREEN}поднят${NC}\n"
        if [ -n "$WG" ]; then
            hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$hs" in
                ''|*[!0-9]*) hs=0 ;;
            esac
            if [ "$hs" -gt 0 ]; then
                ago=$(age_since "$hs")
                printf "  Handshake: ${GREEN}%d сек назад${NC}\n" "$ago"
            else
                printf "  Handshake: ${RED}нет${NC}\n"
            fi
        fi
        # Внешний IP — только по просьбе (`status`): это запрос наружу с потолком 5 с, а смена сервера и откат ждали
        # его ради строки в тосте, хотя панель сама перечитывает IP после любого действия (`loadIp`).
        if [ "$1" = ip ]; then
            ip_vpn=$(probe_ext_ip "--interface awg0" 5)
            [ -n "$ip_vpn" ] && printf "  Внешний IP через VPN: ${GREEN}%s${NC}\n" "$ip_vpn"
        fi
    else
        printf "  Интерфейс awg0: ${RED}не поднят${NC}\n"
    fi
}

# Ждать handshake до HS_WAIT секунд. Шаг — четверть секунды (`usleep`; дробного `sleep` в этом busybox нет):
# рукопожатие приходит за доли секунды после setconf, а секундный шаг добавлял к смене сервера почти целую
# секунду ожидания уже пришедшего ответа. Нет `usleep` — прежний секундный шаг; точка — раз в секунду, как раньше.
wait_for_handshake() {
    [ -z "$WG" ] && return 1
    _whq=1; command -v usleep >/dev/null 2>&1 && _whq=4
    _whi=0
    while [ "$_whi" -lt $((HS_WAIT * _whq)) ]; do
        hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
        case "$hs" in
            ''|*[!0-9]*) hs=0 ;;
        esac
        if [ "$hs" -gt 0 ]; then
            ago=$(age_since "$hs")
            [ "$ago" -lt 300 ] && return 0
        fi
        if [ "$_whq" = 4 ]; then usleep 250000; else sleep 1; fi
        _whi=$((_whi+1))
        [ $((_whi % _whq)) = 0 ] && printf "."
    done
    return 1
}

# ЧУЖУЮ НЕСУЩУЮ ВОЗВРАЩАЕМ МЫ ЖЕ. Смена awg-сервера СНАЧАЛА отпускает активный xray/hy2/byedpi/
# zapret (см. `cur_t` в switch_to) — потому что человек выбрал awg-сервер. Не состоялось —
# «прежним» для него остаётся ИМЕННО ТА несущая: подними мы вместо неё awg0, несостоявшаяся смена
# СЕРВЕРА молча сменила бы ТРАНСПОРТ. Ветка нужна на ВСЕХ путях отказа, а не только там, где не
# разложился конфиг (ревью 4, 08.09.2026): не поднялся awg0 и не пришло рукопожатие — то же самое.
# Возврат: 0 — случай наш и обработан (несущая вернулась ИЛИ мы честно ушли в прямой режим),
#          1 — чужой несущей не было, вызыватель идёт прежним путём (откат на снимок).
alt_back() {
    [ -n "$cur_t" ] && [ "$cur_t" != awg ] || return 1
    # ОРКЕСТРАТОРА НЕТ ⇒ МЫ ЕЁ И НЕ ОТПУСКАЛИ: гард на `transport.sh` стоит и у отпускания (см.
    # `cur_t` в switch_to), значит чужая несущая всё это время работала. Прямой режим тут был бы
    # ВРЕДОМ — он снял бы маршрут живого альта, — а письмо «прежняя несущая не поднялась» ложью
    # про то, чего мы не делали (ревью 8).
    if [ ! -f "$ENODIA_DIR/transport.sh" ]; then
        printf "${YELLOW}[возврат]${NC} оркестратора нет — прежнюю несущую (%s) не отпускали, она работает.\n" "$cur_t"
        return 0
    fi
    # Выключили VPN посреди смены — прежнюю не поднимаем: намерение (`.transport`) при ней, поднимет «Включить VPN».
    if carrier_barred; then
        printf "${YELLOW}[возврат]${NC} VPN выключен вручную — прежнюю несущую (%s) не поднимаю.\n" "$cur_t"
        return 0
    fi
    printf "${YELLOW}[возврат]${NC} поднимаю обратно прежнюю несущую (%s)…\n" "$cur_t"
    if sh "$ENODIA_DIR/transport.sh" up "$cur_t" >/dev/null 2>&1; then
        printf "${GREEN}[возврат]${NC} несущая %s вернулась.\n" "$cur_t"
        # ПЕРЕИГРЫШ ПОСЛЕ НАШЕГО ЖЕ firewall reload ОБЯЗАТЕЛЕН. `bring_up` кончается вендорным
        # `awg_setup.sh`, а тот — `/etc/init.d/firewall reload`, то есть сносом ВСЕХ наших цепочек
        # (вырезы «мимо VPN», порты, устройства, zapret, FORWARD доп-выходов, «доступ домой»).
        # Раньше эту дыру закрывал `rollback` (через apply_routing → replay_after_fw3); когда
        # возврат чужой несущей стал уходить своим путём, переигрыш потерялся, а сторож его не
        # ловит: rule-heal судит по FORWARD несущей и `ip rule`, а их вернул сам `transport.sh up`
        # (ревью 5, 08.09.2026). Флаг ставит bring_up, гасит сам replay_after_fw3 — на путях, где
        # firewall reload не случался, это no-op.
        replay_after_fw3
        return 0
    fi
    printf "${RED}[FAIL]${NC} прежняя несущая (%s) не вернулась — включаю прямой режим.\n" "$cur_t"
    safety_off
    if [ "$NF_LANG" = en ]; then
        notify_event "switch-failopen" 3600 "BE7000: CRIT — VPN did not come up, direct mode" \
"Switching to the config $target did not work out, and the PREVIOUS carrier ($cur_t) did not
come back up either. Direct mode is on (safety_off): internet and DNS work bypassing the VPN,
listed sites are unavailable.
Check free space and the log: df -h; cat /tmp/enodia-switch-vpn-setup.log"
    else
        notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Переключение на конфиг $target не удалось, а ПРЕЖНЯЯ несущая ($cur_t) обратно не поднялась.
Включён прямой режим (safety_off): интернет и DNS работают мимо VPN, сайты из списка недоступны.
Проверьте место и лог: df -h; cat /tmp/enodia-switch-vpn-setup.log"
    fi
    return 0
}

# Установить ВСЕ файлы конфигурации из source-файла.
# Это главное изменение v3: amnezia_for_awg.conf — то, что реально
# читает вендорный awg_setup.sh, поэтому он тоже должен обновиться.
#
# ЧЕРЕЗ СТУПЕНЬ, С ПРОВЕРКОЙ КАЖДОЙ ЗАПИСИ И С КОДОМ ВОЗВРАТА. Раньше тут стояли голые `cp`,
# `rm` и `echo`, а кода возврата у функции не было вовсе. На полном разделе (20-МБ /data, UBIFS
# GC — штатная беда этого роутера) первый `cp` оставлял ОБРЕЗАННЫЙ awg.conf, второй копировал
# обрезок в amnezia_for_awg.conf, третий УДАЛЯЛ awg0.conf, четвёртый писал в `.active` имя
# сервера, которого в конфиге уже нет, — и вызыватель как ни в чём не бывало шёл в bring_up.
# Итог: конфига человека нет, генерировать awg0.conf не из чего, откатываться некуда.
# Теперь обе копии пишутся СТУПЕНЬЮ рядом с целью (тот же том ⇒ `mv` — переименование, оно
# метаданные и на переполнении не рвётся), у каждой проверяются КОД ВОЗВРАТА И РАЗМЕР, и лишь
# потом публикуются файлы, удаляется awg0.conf и пишется `.active`.
# КОДЫ ВОЗВРАТА — ТРИ, И РАЗНИЦА НЕ КОСМЕТИЧЕСКАЯ: 0 — разложено · 1 — НИ ОДНОГО изменения на
# диске (вызывателю достаточно поднять прежнюю несущую) · 2 — ПОЛУПРИМЕНЕНО: `awg.conf` уже НОВЫЙ,
# `amnezia_for_awg.conf` снят, `awg0.conf` снят, имя активного обнулено. «Прежнего» на диске в
# этом случае НЕТ — поднимать нечего, и вернуть согласованность может только откат на снимок.
install_config() {
    _ic_src="$1"
    _ic_name="$2"
    # ИМЯ СТУПЕНИ КОНЧАЕТСЯ НА `.new` — это уже принятый в проекте признак «оборванная запись»
    # (его чистит clean.sh: `iplist.conf.new` у состояния, `xray.new` у бинарей), и своего
    # третьего расширения для мусора мы не заводим. Номер процесса в середине — чтобы две
    # раскладки (лок смены транспорта не абсолютен) не писали в одну ступень.
    _ic_t1="$ACTIVE_CONF.$$.new"
    _ic_t2="$SHALIN_CONF.$$.new"
    # ХВОСТ СВОЕГО ЖЕ НОМЕРА УБИРАЕМ, ЧУЖОЙ — НЕТ. Прибитый uhttpd'ом CGI оставляет ступень, и
    # номер процесса может повториться; но маска `*.new` снесла бы ступень ПАРАЛЛЕЛЬНОГО прогона
    # (лок смены не абсолютен), и жертва получила бы «после чистки I1..I5 не осталось ничего» —
    # совет про пустой конфиг там, где конфиг цел. Чужие хвосты метёт `clean.sh` (у него `*.new`
    # и так в списке мусора).
    rm -f "$_ic_t1" "$_ic_t2" 2>/dev/null

    # 1. Ступень главного awg.conf. РЕЖИМ СТАВИМ СРАЗУ: ступень рождается с правами ИСТОЧНИКА
    #    (у импортированного конфига это может быть 644) и уже содержит приватный ключ.
    if ! cp "$_ic_src" "$_ic_t1" 2>/dev/null || [ ! -s "$_ic_t1" ]; then
        rm -f "$_ic_t1" 2>/dev/null
        printf "${RED}[FAIL]${NC} конфиг %s не разложен: не пишется рядом с %s (место на разделе? df)\n" "${_ic_name:-?}" "$ACTIVE_CONF"
        return 1
    fi
    chmod 600 "$_ic_t1" 2>/dev/null

    # 2. Чистим пустые I1..I5 (AmneziaVPN 4.8.12.9+ их добавляет) — ЕЩЁ НА СТУПЕНИ: `sed -i`
    #    пишет через свой временный файл и на переполнении обрезал бы УЖЕ опубликованный
    #    awg.conf. Размер перепроверяем по той же причине.
    if grep -qE '^I[1-5][[:space:]]*=[[:space:]]*$' "$_ic_t1"; then
        sed -i '/^I[1-5][[:space:]]*=[[:space:]]*$/d' "$_ic_t1"
    fi

    # 3. Ступень ОПУСТЕЛА — это НЕ та же беда, что «не пишется вторая», и человека надо слать в
    #    другое место: либо `sed -i` оборвался на переполнении, либо в конфиге не было ничего,
    #    кроме пустых I1..I5. Раньше оба случая печатали одно и то же имя чужого файла.
    if [ ! -s "$_ic_t1" ]; then
        rm -f "$_ic_t1" "$_ic_t2" 2>/dev/null
        printf "${RED}[FAIL]${NC} конфиг %s не разложен: после чистки пустых I1..I5 не осталось ничего (обрыв записи или пустой конфиг)\n" "${_ic_name:-?}"
        return 1
    fi

    # 4. Ступень amnezia_for_awg.conf — вендорный awg_setup.sh читает именно его. БЕЗ этого awg
    #    продолжит использовать СТАРЫЕ ключи и endpoint после «переключения».
    if ! cp "$_ic_t1" "$_ic_t2" 2>/dev/null || [ ! -s "$_ic_t2" ]; then
        rm -f "$_ic_t1" "$_ic_t2" 2>/dev/null
        printf "${RED}[FAIL]${NC} конфиг %s не разложен: не пишется рядом с %s (место на разделе? df)\n" "${_ic_name:-?}" "$SHALIN_CONF"
        return 1
    fi
    chmod 600 "$_ic_t2" 2>/dev/null

    # 5. РЕЖИМ ДОСТУПА — ЯВНО, А НЕ ПО НАСЛЕДСТВУ (стоит сразу за каждым `cp` выше). В конфиге
    #    лежит приватный ключ, и раньше режим 600 держался САМ СОБОЙ: `cp` писал ПОВЕРХ
    #    существующего awg.conf, сохраняя права ЦЕЛИ. Запись через ступень переворачивает это —
    #    новый файл получает режим ИСТОЧНИКА (замерено на busybox 08.09.2026), то есть ключ стал бы
    #    миру виден от одного конфига, приехавшего с 644 (импорт, ручная заливка, чужая ФС без
    #    прав). Соседи по транспортам (`xray-transport.sh`, `transport-hy2.sh`) ставят 600 явно.

    # 6. СНИМАЕМ awg0.conf — ДО ПУБЛИКАЦИИ И ПО ФАКТУ, А НЕ ПО КОДУ `rm`. Файл ПРОИЗВОДНЫЙ:
    #    вендорный скрипт генерирует его из amnezia_for_awg.conf, только КОГДА ФАЙЛА НЕТ
    #    (`awg_setup.sh`: «already exists» и пропуск). Отсюда оба вывода:
    #      * снять его РАНЬШЕ публикации безопасно — «нет awg0.conf» это не изменение состояния,
    #        а сброс кэша: сорвись публикация ниже, следующий подъём соберёт его из ПРЕЖНЕГО
    #        конфига, то есть вернёт прежний сервер;
    #      * отказ снятия (RO-раздел после ошибок UBIFS, EIO) обязан ОТМЕНИТЬ раскладку: иначе
    #        демон поднялся бы на СТАРЫХ ключах при новых конфигах, а мы отрапортовали бы успех.
    rm -f "$AWG0_CONF" 2>/dev/null
    if [ -e "$AWG0_CONF" ]; then
        rm -f "$_ic_t1" "$_ic_t2" 2>/dev/null
        printf "${RED}[FAIL]${NC} конфиг %s не разложен: не снять %s — демон взял бы СТАРЫЕ ключи\n" "${_ic_name:-?}" "$AWG0_CONF"
        return 1
    fi

    # 7. Публикация. Обе ступени уже целиком лежат на том же томе ⇒ это переименования.
    if ! mv -f "$_ic_t1" "$ACTIVE_CONF" 2>/dev/null; then
        rm -f "$_ic_t1" "$_ic_t2" 2>/dev/null
        printf "${RED}[FAIL]${NC} конфиг %s не разложен: публикация %s не удалась\n" "${_ic_name:-?}" "$ACTIVE_CONF"
        return 1
    fi
    if ! mv -f "$_ic_t2" "$SHALIN_CONF" 2>/dev/null; then
        # ПОЛУПРИМЕНЕНО, И МОЛЧАТЬ ОБ ЭТОМ НЕЛЬЗЯ: awg.conf уже новый, а вендорный скрипт читает
        # ВТОРОЙ файл. Оставить его старым — значит поднять демона на ПРОШЛОМ сервере при новом
        # awg.conf, и расхождение будет ВЕЧНЫМ: heal пересоздаёт этот файл, только если тот
        # ПРОПАЛ. Поэтому сперва пробуем закрыть расхождение ВТОРЫМ способом — записью ПОВЕРХ
        # (перезапись и переименование отказывают по разным причинам), а если и она не вышла —
        # СНИМАЕМ протухший файл: пусть подъём откажется громко (`awg_setup.sh` без него выходит
        # с ошибкой), а heal на ближайшей загрузке соберёт его из нового awg.conf.
        # ЗАПАСНОЙ ПУТЬ ПИШЕТ ПРЯМО В ЦЕЛЬ (ступень уже не спасёт — первый файл опубликован),
        # поэтому судим не по «непусто», а по РАВЕНСТВУ РАЗМЕРОВ: обрезок с нулевым кодом — ровно
        # тот случай, ради которого вся раскладка и переехала на ступени.
        if cp "$ACTIVE_CONF" "$SHALIN_CONF" 2>/dev/null && [ -s "$SHALIN_CONF" ] \
           && [ "$(wc -c < "$SHALIN_CONF" 2>/dev/null)" = "$(wc -c < "$ACTIVE_CONF" 2>/dev/null)" ]; then
            chmod 600 "$SHALIN_CONF" 2>/dev/null
            rm -f "$_ic_t2" 2>/dev/null
        else
            rm -f "$_ic_t2" "$SHALIN_CONF" 2>/dev/null
            # ИМЯ АКТИВНОГО ТОЖЕ БОЛЬШЕ НЕ ПРАВДА: в `awg.conf` уже НОВЫЙ конфиг, а в `.active`
            # осталось бы СТАРОЕ имя — по нему перебор резервов пропускал бы как «дохлый» не тот
            # конфиг, а панель показывала бы не тот сервер. Пишем принятое «неизвестно» (пустой
            # файл): состояние и правда неизвестно, пока раскладку не доведут.
            : > "$ACTIVE_NAME" 2>/dev/null || true
            printf "${RED}[FAIL]${NC} конфиг %s разложен НАПОЛОВИНУ: %s обновлён, а %s записать не вышло (снят, чтобы демон не взял СТАРЫЕ ключи; пересоздаст heal на загрузке при включённом VPN)\n" "${_ic_name:-?}" "$ACTIVE_CONF" "$SHALIN_CONF"
            return 2
        fi
    fi

    # 8. Запоминаем имя активного. ПУСТОЕ ИМЯ — ПУСТОЙ ФАЙЛ (`: >`, а не `echo ""`): «какой
    #    конфиг несёт трафик — неизвестно» это НУЛЕВОЙ размер, по нему судят `install.sh` (сеет
    #    `default`) и панель; байт перевода строки читался бы как «имя есть».
    if [ -n "$_ic_name" ]; then
        # НЕ ЗАПИСАЛОСЬ — ЗНАЧИТ «НЕИЗВЕСТНО», А НЕ «КАК ПОЛУЧИТСЯ»: `>` на полном разделе сперва
        # УСЕКАЕТ файл, и молчаливый огрызок читался бы как имя. Конфиги при этом разложены,
        # поэтому код успеха не меняем — говорим вслух и приводим файл к честному пустому виду.
        if ! echo "$_ic_name" > "$ACTIVE_NAME" 2>/dev/null; then
            : > "$ACTIVE_NAME" 2>/dev/null || true
            printf "${YELLOW}[warn]${NC} имя активного конфига (%s) не записалось в %s — считаем неизвестным\n" "$_ic_name" "$ACTIVE_NAME"
        fi
    else
        : > "$ACTIVE_NAME" 2>/dev/null || true
    fi
    return 0
}

# Глушим amneziawg-go процессы (на случай если init.d не убил)
# Гасим демон ИМЕННО awg0. ГРАБЛЯ (поймано на железе 30.07.2026): раньше тут стоял killall по
# ИМЕНИ БИНАРЯ, а инстансов amneziawg-go у нас теперь несколько — awg0 (эта несущая), awgN
# (awg-выходы слотов) и awgs0 (VPN-сервер «доступ домой»). Каждый failover звал bring_up →
# killall уносил сервер и слоты вместе с awg0, поднять их было НЕКОМУ до следующего ребута.
# Снаружи это выглядело как «телефон вчера подключался, а сегодня нет»: правила фаервола на
# месте, панель показывает «включено», а несущей нет. Матчим по /proc/*/cmdline — зеркало
# awg_kill_daemon (transport-awg.sh) и srv_kill_daemon (vpn-server.sh).
awg0_daemon_pids() {
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        case "$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline") " in
            *"amneziawg-go awg0 "*|*"amnezia-wg awg0 "*|*"wireguard-go awg0 "*) echo "${_p#/proc/}" ;;
        esac
    done
}
# Смерть ждём ПО ПРОЦЕССУ с шагом 0.1 с (daemon_wait_gone), а не секундными шагами обхода /proc: демон уходит за
# доли секунды, а первая же проверка после TERM застаёт его живым — и смена сервера платила целую секунду дважды
# (bring_down + bring_up). Потолки прежние: 3 с на TERM, затем KILL и ещё до 5 с.
kill_awg_processes() {
    _kap=$(awg0_daemon_pids)
    for _pid in $_kap; do kill -TERM "$_pid" 2>/dev/null; done
    for _pid in $_kap; do
        daemon_wait_gone "$_pid" 3 && continue
        kill -KILL "$_pid" 2>/dev/null
        daemon_wait_gone "$_pid" 5
    done
}

# AmneziaWG реально установлен? Нужны ОБА бинаря: amneziawg-go (демон несущей awg0) И
# awg (CLI amneziawg-tools — bring_up/awg_setup.sh делают им `awg setconf awg0`). На
# hy2/xray-only установке их НЕТ (awg = опциональная база транспорт-агностичного ядра),
# либо awg стоит наполовину (демон докачался, CLI — нет). Тогда switch_to/do_failover НЕ
# должны рвать рабочую несущую и звать safety_off ради awg-конфига, который некому поднять
# (orphaned awg.conf + bring_down + bring_up-fail + safety_off). Симметрично transport_ready awg.
awg_installed() { [ -x "$ENODIA_BIN/amneziawg-go" ] && [ -x "$ENODIA_BIN/awg" ]; }

# КЛЮЧ КОНФИГА ЗАНЯТ ВЫХОДОМ? Сервер AmneziaWG опознаёт клиента по ключу, и сессия у ключа одна: основной awg0 на ключе
# выхода выбивал бы его сессию (и наоборот), а человек видел бы «выход не работает» при живом сервере (замер 10.09.2026).
# Ответ — у ОДНОГО владельца, `slots.sh key-holder` (сверка по ключу, а не по имени: копия файла под другим именем — та же
# беда). 0 = занят, причина словами в $KEY_BUSY. Нет slots.sh — судить нечем, не мешаем (прежний путь).
key_busy() {
    KEY_BUSY=""
    [ -f "$ENODIA_DIR/slots.sh" ] || return 1
    KEY_BUSY=$(sh "$ENODIA_DIR/slots.sh" key-holder "$1" main 2>/dev/null) && return 0
    KEY_BUSY=""
    return 1
}

# --- переигрыш ВСЕХ наших цепочек после fw3-reload внутри awg_setup.sh (см. FW3_WIPED) -----
# Канонический переигрыш один — `vpn-toggle.sh repair`: он заведён ровно под fw3-reload и уже
# знает про apply-bypass, zapret, доп-выходы и «доступ домой». Своей копии этого списка тут
# быть не должно (она отстанет с первой же новой подсистемой). Рекурсии нет: repair при
# transport=awg ставит несущую ИНЛАЙНОМ (awg0 к этому моменту уже поднят), awg_setup.sh не зовёт.
replay_after_fw3() {
    [ "$FW3_WIPED" = 1 ] || return 0
    FW3_WIPED=0
    [ -f "$ENODIA_DIR/vpn-toggle.sh" ] || return 0
    printf "${BLUE}[правила]${NC} переигрываю цепочки после firewall reload...\n"
    sh "$ENODIA_DIR/vpn-toggle.sh" repair >/dev/null 2>&1 || true
}
# АВАРИЙНЫЙ вариант того же: туннель мёртв и мы уже в прямом режиме (safety_off). Полный repair
# звать НЕЛЬЗЯ — он вернёт default в дохлый awg0, т.е. ровно тот кирпич, от которого safety_off и
# спасает. Зовём `rules` — тот же канонический список БЕЗ несущей: вырезы, zapret, доп-выходы,
# блокировки, IPv6-запрет и «доступ домой» (телефон снаружи иначе молча отваливался бы до ребута).
# Маршрута в туннель он не ставит, а ядро маркировки без `default` в table 1000 ведёт в main —
# прямой режим остаётся прямым. Прежде здесь поднимался ТОЛЬКО «доступ домой», остальное ждало
# ребута (ревью dev233). Панельные PANEL_WAN/DNAT переигрывает свой cron (`web-ui.sh start` раз в 5 мин).
replay_rules_only() {
    [ "$FW3_WIPED" = 1 ] || return 0
    FW3_WIPED=0
    # -f + `sh` (класс Б5-9): при снятом бите аварийная ветка молча не переигрывала бы ничего
    # — а зовут её как раз после safety_off, когда «доступ домой» и есть единственный путь домой.
    [ -f "$ENODIA_DIR/vpn-toggle.sh" ] && sh "$ENODIA_DIR/vpn-toggle.sh" rules >/dev/null 2>&1
    return 0
}

# Поднять туннель из текущего awg.conf
bring_up() {
    ip link del awg0 2>/dev/null
    kill_awg_processes      # ждёт смерти демона сам — отдельной паузы после него не нужно

    started=0
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        if [ -x "$s" ]; then
            "$s" start >/dev/null 2>&1
            started=1
            break
        fi
    done

    # Если init.d не справился или его нет — зовём вендорный awg_setup.sh.
    # /etc/init.d/awg в проекте никто не создаёт ⇒ ветка init.d выше промахивается ВСЕГДА, и
    # эта строка бежит на КАЖДОЙ смене страны. Внутри бывает `/etc/init.d/firewall reload`, который
    # сносит все iptables: случился (сменилось поколение) — помечаем флагом, переигрыш сделают
    # replay_* (см. FW3_WIPED). Не случился — переигрывать нечего, правила на месте.
    if ! ip link show awg0 >/dev/null 2>&1 && [ -f "$ENODIA_DIR/awg_setup.sh" ]; then
        _bu_gen=$(fw3_gen)
        ( cd "$ENODIA_DIR" && sh ./awg_setup.sh >"/tmp/enodia-switch-vpn-setup.log" 2>&1 )
        [ "$(fw3_gen)" = "$_bu_gen" ] || FW3_WIPED=1
    fi

    # Ждём появления интерфейса
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        ip link show awg0 >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

bring_down() {
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        [ -x "$s" ] && "$s" stop >/dev/null 2>&1 && break
    done
    ip link set awg0 down 2>/dev/null
    ip link del awg0 2>/dev/null
    kill_awg_processes
}

# VPN ВЫКЛЮЧИЛИ ВРУЧНУЮ посреди нашей работы: дальше несущую не поднимаем и писем о «прямом режиме» и «откате» не шлём — человек
# выключил VPN сам. Своей копии «как выключить» нет: awg0 гасим своим bring_down (при выключенном VPN его не бывает даже тёплым),
# снесённое нашим же firewall reload возвращает `rules` (правила НЕ про VPN — их `vpn-toggle` при флаге и ставит); маршрут, DNS и
# марки к этому моменту снял сам `off`. Код 0 = остановились (вызыватель выходит отказом), 1 = VPN не выключали.
off_stop() {
    carrier_barred || return 1
    printf "${YELLOW}[стоп]${NC} VPN выключили вручную — %s; несущую не поднимаю (включить: тумблер в панели).\n" "$1"
    bring_down
    replay_rules_only
    return 0
}

# Восстановить нормальную маршрутизацию через awg0: ЯДРО (mark-core: маркировка
# ipset->MARK + ip rule fwmark->table 1000) + awg-НЕСУЩАЯ (transport-awg.sh up:
# default dev awg0 + FORWARD + MASQUERADE + туннельный DNS + .transport=awg).
# Единый источник правды вместо ретайрнутого split-route.sh. awg0 здесь уже поднят
# (bring_up до вызова), поэтому ensure_carrier в плагине — мгновенный no-op
# (awg_setup/fw3-reload НЕ трогаются). split-route.sh оставлен лишь фолбэком для
# старых роутеров без плагинов.
apply_routing() {
    [ -f "$ENODIA_DIR/mark-core.sh" ] && sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1
    if [ -f "$ENODIA_DIR/transport-awg.sh" ]; then
        sh "$ENODIA_DIR/transport-awg.sh" up >/dev/null 2>&1
    elif [ -f "$ENODIA_DIR/split-route.sh" ]; then
        sh "$ENODIA_DIR/split-route.sh" >/dev/null 2>&1
    fi
    # enodia_list НЕ флашим. Прежний код это делал с мотивировкой «там осели старые IP, привязанные
    # к старому endpoint» — она НЕВЕРНА: в enodia_list лежат адреса САЙТОВ (их кладёт dnsmasq по
    # `ipset=/домен/enodia_list`), от endpoint'а VPS они не зависят вовсе. Цена флаша — ровно та же
    # авария, что чинил set-lib.sh [[groups-set-rebuild-wipes-dnsmasq-ips]]: после смены страны
    # доменные правила МЕРТВЫ, пока каждый домен не перерезолвят заново, а `killall -HUP dnsmasq`
    # чистит лишь кэш dnsmasq и заставить клиента переспросить не может (у него свой кэш и живые
    # соединения). HUP оставляем: после смены выхода кэш прежнего сервера стоит сбросить.
    killall -HUP dnsmasq 2>/dev/null
    # Несущая через туннель восстановлена — синхронизируем watchdog в NORMAL (safety_off ставил
    # FAILOPEN). Иначе после успешного ручного failover/rollback STATE залипал бы в FAILOPEN и
    # сторож на следующем тике зря дёргал бы restore_awg_carrier.
    echo NORMAL > "$WD_STATE" 2>/dev/null || true
    # Несущая жива и правила ядра на месте — самое время вернуть всё, что смёл наш же
    # firewall reload (bypass/порты/устройства/zapret/доп-выходы/«доступ домой»).
    replay_after_fw3
}

# SAFETY NET: туннель окончательно мёртв (новый конфиг не поднялся и
# откат тоже не поднялся). Без этого роутер «уходит в кирпич»:
#   1) fwmark+mangle гонят трафик в дохлый awg0 — даже исходящий с
#      самого роутера к Cloudflare/Google/OpenAI (~3100 CIDR в iplist_set)
#   2) КЛЮЧЕВОЕ: dnsmasq настроен на upstream-DNS внутри туннеля
#      (172.29.172.254 от Amnezia). Когда awg0 умирает, dnsmasq шлёт
#      запросы в дохлый интерфейс → НИ ОДИН сайт не резолвится, даже
#      yandex.ru. SSH работает только потому, что заходишь по IP.
# safety_off восстанавливает оба пути: трафик идёт напрямую через
# провайдера, DNS — на 1.1.1.1/8.8.8.8. Это временное состояние;
# heal.sh при следующем срабатывании (раз в минуту) всё восстановит,
# если awg.conf к тому моменту валиден (после rollback он уже OLD).
safety_off() {
    printf "${YELLOW}[safety]${NC} убираю маршрут/марку/DNS-привязку к дохлому awg0\n"

    # 1. КЛЮЧЕВОЕ: убрать сам МАРШРУТ в дохлый туннель. `default dev awg0` в table 1000 —
    #    единственная причина блэкхола, и снять его надо ДО/ВМЕСТО возни с марками:
    #      * awg0 мы СОЗНАТЕЛЬНО не опускаем (сторож продолжает мониторить handshake) ⇒ маршрут
    #        оставался живым, и любой, кто вернёт марку, вернёт и кирпич. А возвращает её сторож
    #        САМ: mipctld-guard (cron */2) видит «нет MARK по iplist_set» и переигрывает
    #        mark-core — вместе с `ip rule fwmark 0x1 -> table 1000`;
    #      * ДОП-ВЫХОДЫ с fallback=main смотрят в ту же table 1000 (mark-core, FALLBACK-AWARE), и
    #        снятие ОДНОЙ марки 0x1 их не спасало: привязанные группы/гео/устройства продолжали
    #        уезжать в мёртвый awg0 — блэкхол вместо fail-open (находка ревью, батч 4).
    #    Пустая table 1000 = lookup проваливается в main = НАПРЯМУЮ, что и обещает fail-open.
    #    Живые доп-выходы со СВОЕЙ несущей (table 100N) при этом продолжают работать — правильно.
    ip route del default dev awg0 table 1000 2>/dev/null
    ip rule del fwmark 0x1 table 1000 2>/dev/null
    # Марки в mangle снимать не нужно и вредно копировать сюда список сетов: их у mark-core
    # ПЯТЬ (+слот-сеты), а здешняя копия отстала на двух и молча не снимала grp_vpn/enodia_ip_vpn/
    # geo_vpn. Без ip rule и без default марка ни на что не влияет, а вернёт её (и правильно)
    # первый же mark-core. Снимаем лишь NAT нашей несущей.
    iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null

    # 2. DNS — выключаем upstream через дохлый туннель, ставим публичный.
    #    Это файл в overlay (/etc), он сбросится при ребуте — нам и надо.
    #    При включённом «Шифрованном DNS» решает doh-lib: он переводит dnsmasq на локальный
    #    прокси, ходящий НАПРЯМУЮ через WAN. Затирать конфиг публичными серверами в этом случае
    #    значило бы молча выключить шифрованный DNS до следующего repair.
    if doh_apply_dns direct; then
        # Шапка не врёт: при включённом DoH публичных серверов в конфиге НЕТ, и сообщение
        # в конце функции обязано говорить то, что произошло на самом деле.
        _dnsmsg="DNS остаётся на шифрованном резолвере (он ходит мимо туннеля, напрямую)"
    elif [ -f /etc/dnsmasq.d/00-upstream.conf ]; then
        _dnsmsg="DNS временно на 1.1.1.1/8.8.8.8"
        # upstream-own: аварийный fail-open — файл с шапкой-пояснением для того, кто его найдёт, и рестарт ниже БЕЗУСЛОВНЫЙ
        # (демон мог залипнуть на мёртвом туннельном upstream); экономия dns_upstream_put здесь не нужна.
        cat > /etc/dnsmasq.d/00-upstream.conf <<'DNS_FALLBACK'
# Временный fallback, поставлен switch-vpn.sh safety_off.
# Будет заменён обратно на VPN-DNS при следующем срабатывании heal.sh
# (как только awg0 поднимется). При ребуте overlay /etc сбрасывается.
no-resolv
server=1.1.1.1
server=8.8.8.8
DNS_FALLBACK
    else
        _dnsmsg="DNS не трогали (нет 00-upstream.conf)"
    fi
    # Снимаем маршрут к VPN-DNS через дохлый awg0 (если был)
    VPN_DNS=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -n "$VPN_DNS" ] && ip route del "$VPN_DNS/32" dev awg0 2>/dev/null

    # Перезапускаем dnsmasq, чтобы подхватил новый upstream
    /etc/init.d/dnsmasq restart 2>/dev/null || killall -HUP dnsmasq 2>/dev/null

    # NSS/ECM offload: для УЖЕ установленных потоков старый маршрут (в дохлый awg0) залипает
    # до conntrack-таймаута — клиенты висят, хотя fail-open уже включён. Инвариант проекта:
    # после iptables-изменения обязателен conntrack -F (см. transport-*/zapret/apply-bypass).
    ct_flush

    # Пометить watchdog FAILOPEN: мы в прямом режиме. Без этого ALIVE-ветка сторожа (она
    # восстанавливает маркировку ТОЛЬКО из состояния FAILOPEN) не вернёт VPN, если VPS оживёт
    # с живым handshake раньше HS_DEAD — типичный кейс: ручной switch → rollback → safety_off
    # оставлял STATE=NORMAL → VPN молча выключен «навсегда» (heal под boot-локом). apply_routing
    # вернёт NORMAL при успешном подъёме несущей.
    echo FAILOPEN > "$WD_STATE" 2>/dev/null || true

    # Если сюда пришли ПОСЛЕ нашего же awg_setup.sh — его firewall reload снёс и цепочки
    # «доступа домой». Полный repair тут запрещён (вернул бы маршрут в дохлый awg0), поднимаем
    # только независимое от туннеля.
    replay_rules_only

    printf "${YELLOW}[safety]${NC} %s, трафик весь напрямую\n" "${_dnsmsg:-DNS не менялся}"
}

# ВОЗВРАТ ТУННЕЛЬНОГО DNS живёт в ПЛАГИНЕ (transport-awg.sh restore_vpn_dns), сюда его копию
# больше не заводим. Здешняя копия была написана до плагинов и не проходила через doh_apply_dns:
# в do_failover она бежала ПОСЛЕ apply_routing (который уже поставил DNS правильно, через плагин
# и слой DoH) и перетирала 00-upstream.conf туннельным сервером ⇒ при включённом «Шифрованном
# DNS» DoH молча отваливался после КАЖДОГО failover'а. Кому нужно переиграть DNS активного
# транспорта — верб `transport.sh dns`.

# ============================================================
# Главная процедура переключения с автооткатом
# ============================================================
switch_to() {
    target="$1"
    # Гард: без awg-демона активировать awg-конфиг нечем. Выходим ДО bring_down/safety_off,
    # чтобы НЕ уронить уже несущий транспорт (hy2/xray). Это та самая ловушка из логов:
    # «Залить конфиг + активировать» при hy2-only установке.
    if ! awg_installed; then
        # КАТАЛОГ НАЗЫВАЕМ ТОТ, В КОТОРОМ ИСКАЛИ: `awg_installed` смотрит в $ENODIA_BIN, а строка
        # печатала $ENODIA_DIR — в раскладках `bins`/`full` это разные тома, и человек грепал
        # пустой каталог (ревью 5, 06.09.2026).
        printf "${RED}[FAIL]${NC} AmneziaWG не установлен (нет %s/amneziawg-go).\n" "$ENODIA_BIN"
        printf "Активировать awg-конфиг нечем — текущий транспорт НЕ тронут.\n"
        printf "Чтобы получить AmneziaWG: переустановите с ПК (enodia-setup.bat -> Установка),\n"
        printf "выбрав вариант с AmneziaWG (например «AmneziaWG + Hysteria2»).\n"
        exit 1
    fi
    src="$CONFIGS_DIR/${target}.conf"
    if [ ! -f "$src" ]; then
        printf "${RED}[FAIL]${NC} Не найден файл %s\n" "$src"
        printf "Доступные конфиги:\n"
        list_configs
        exit 1
    fi
    # ДО лока и до снятия чего бы то ни было: отказ обязан оставить работающий канал как был.
    if key_busy "$target"; then
        printf "${RED}[FAIL]${NC} %s\n" "$KEY_BUSY"
        printf "Текущий сервер не тронут.\n"
        exit 1
    fi
    # VPN ВЫКЛЮЧЕН ВРУЧНУЮ — выбор сервера не включает его: раскладываем конфиг и не поднимаем несущую (то же делает панель при
    # выключенном VPN — «конфиг выбираем, несущую не трогаем, человек включает тумблером»).
    if carrier_barred; then
        install_config "$src" "$target" || exit 1
        printf "${GREEN}[OK]${NC} конфиг %s разложен; VPN выключен вручную — поднимется при включении.\n" "$target"
        return 0
    fi

    acquire_lock

    # Активна ЧУЖАЯ несущая (xray/hy2/byedpi/zapret)? Отпустить её через ОРКЕСТРАТОР, иначе
    # смена awg-сервера уводит транспорт на awg МИМО него: apply_routing ниже поднимет awg0 и
    # плагин запишет `.transport=awg`, а `down` прежнего плагина не позовёт НИКТО. Итог —
    # осиротевшие ciadpi/xray/hysteria + hev держат socks 10808 и xtun, их FORWARD-правила
    # остаются, RAM течёт (на BE3600 со 176 МБ это заметно). Соседний set_xray_server в панели
    # делает ровно наоборот и специально об этом пишет («НЕ роняет чужую несущую») — здесь же
    # пользователь ЯВНО выбрал awg-сервер, значит смена несущей и есть его намерение.
    cur_t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    case "$cur_t" in
        ''|awg) ;;
        *) if [ -f "$ENODIA_DIR/transport.sh" ]; then
               printf "${BLUE}[транспорт]${NC} отпускаю текущую несущую (%s) — переходим на AmneziaWG\n" "$cur_t"
               sh "$ENODIA_DIR/transport.sh" down "$cur_t" >/dev/null 2>&1 || true
           fi ;;
    esac

    # Сохраняем текущее (на случай отката). ФЛАГ «СНИМОК НАШ, ЭТОГО ПРОГОНА» — тот же, что у
    # перебора резервов: файл `.last.bak.conf` переживает ребут и обновление, и голый гард
    # `[ -f ]` у отката означал бы «на этом роутере когда-то меняли страну». Без `awg.conf`
    # (снесли `deactivate`, ручное удаление, панель поставили поверх старого state) откат
    # поднимал бы СЕРВЕР ПРОШЛОЙ ЖИЗНИ и слал письмо «автооткат VPN -> <тот, кого не выбирали>»
    # (ревью 3, 06.09.2026).
    # И `-s`, А НЕ `-f`: `cp` тут не проверяется, а на полном /data он оставляет обрезанный
    # (нулевой) файл — `install_config` положил бы его поверх awg.conf и amnezia_for_awg.conf,
    # то есть затёр бы рабочий конфиг человека пустым.
    # КОД ВОЗВРАТА `cp` — ЧАСТЬ ОТВЕТА, не только размер: `-s` ловит лишь обрезанный файл
    # (ENOSPC). Упавший по другой причине `cp` (RO после ошибок UBIFS, сорванный носитель, EACCES)
    # оставляет ПРЕЖНИЙ снимок целым и непустым — флаг сказал бы «наш», а поднялся бы сервер
    # прошлой жизни, то есть та же беда через другую дверь (ревью 4).
    _sw_bak=0
    if [ -f "$ACTIVE_CONF" ]; then
        if cp "$ACTIVE_CONF" "$BACKUP_CONF" 2>/dev/null && [ -s "$BACKUP_CONF" ]; then _sw_bak=1; fi
        if [ -f "$ACTIVE_NAME" ]; then
            cp "$ACTIVE_NAME" "$BACKUP_NAME"
        else
            : > "$BACKUP_NAME"
        fi
        printf "${BLUE}[бэкап]${NC} текущий конфиг сохранён в %s\n" "$BACKUP_CONF"
    fi

    printf "${BLUE}[1/5]${NC} Останавливаю awg0...\n"
    bring_down

    printf "${BLUE}[2/5]${NC} Применяю конфиг ${YELLOW}%s${NC} (awg.conf + amnezia_for_awg.conf + awg0.conf)...\n" "$target"
    # РАСКЛАДКА НЕ УДАЛАСЬ = ПЕРЕКЛЮЧЕНИЯ НЕ БЫЛО, а не «переключение провалилось»: install_config
    # публикует только целые ступени, поэтому awg.conf, amnezia_for_awg.conf и awg0.conf остались
    # ТЕМИ ЖЕ, на которых мы работали минуту назад. Откатывать тут нечего (снимок совпадает с
    # текущим конфигом байт в байт) — надо вернуть несущую, которую мы только что опустили.
    install_config "$src" "$target"; _sw_ic=$?
    # ПОЛУПРИМЕНЕНО (код 2): `awg.conf` УЖЕ новый, а `amnezia_for_awg.conf` снят — «поднять
    # прежнюю несущую» тут значит поднять НЕЧТО: вендорный скрипт без второго файла честно падает.
    # Согласованность возвращает только откат на снимок ЭТОГО прогона (он положит оба файла и имя).
    if [ "$_sw_ic" = 2 ]; then
        printf "${RED}[FAIL]${NC} переключение на %s оборвалось на полпути: конфиги AmneziaWG несогласованы.\n" "$target"
        # ЧУЖАЯ НЕСУЩАЯ — ОСОБЫЙ СЛУЧАЙ: полный `rollback` поднял бы awg0 и через apply_routing
        # записал `.transport=awg`, то есть несостоявшаяся смена СЕРВЕРА сменила бы ТРАНСПОРТ
        # (ревью 5). Файлы возвращаем тем же снимком, но БЕЗ подъёма awg0, а несущую — тем же
        # `alt_back`, что и на прочих путях отказа. Снимок берём только СВОЙ (флаг прогона).
        if [ -n "$cur_t" ] && [ "$cur_t" != awg ]; then
            # СНИМОК ЭТОГО ПРОГОНА ЕСТЬ — возвращаем файлы им; НЕТ (не было awg.conf, `cp` снимка
            # упал) — говорим это ВСЛУХ. Молчание тут было бы обещанием отката, которого не было:
            # на диске остаётся полуприменение, и человек об этом не узнает (ревью 7).
            if [ "$_sw_bak" = 1 ] && [ -s "$BACKUP_CONF" ]; then
                _sw_bakname=$(cat "$BACKUP_NAME" 2>/dev/null)
                if install_config "$BACKUP_CONF" "$_sw_bakname"; then
                    printf "${YELLOW}[возврат]${NC} конфиги AmneziaWG возвращены к снимку (%s).\n" "${_sw_bakname:-?}"
                else
                    printf "${RED}[FAIL]${NC} конфиги AmneziaWG остались несогласованными — их вернёт heal на загрузке.\n"
                fi
            else
                printf "${RED}[FAIL]${NC} снимка этого прогона нет — конфиги AmneziaWG остались несогласованными, их вернёт heal на загрузке.\n"
            fi
            alt_back
            return 1
        fi
        printf "${YELLOW}=> откатываюсь на снимок${NC}\n"
        rollback
        return $?
    fi
    if [ "$_sw_ic" != 0 ]; then
        printf "${RED}[FAIL]${NC} переключение на %s не состоялось: конфиг не разложен.\n" "$target"
        if alt_back; then return 1; fi
        _sw_prev=$(cat "$ACTIVE_NAME" 2>/dev/null)
        off_stop "прежний конфиг (${_sw_prev:-?}) на диске не тронут" && return 1
        # СУДИМ ПО РУКОПОЖАТИЮ, А НЕ ПО ФАКТУ ИНТЕРФЕЙСА. Сервер меняют чаще всего ИМЕННО потому,
        # что прежний умер: подними мы «прежнюю несущую» по одному лишь появлению awg0 и заверни
        # в неё маршрут и DNS всего дома — получился бы блэкхол под зелёным рапортом (тот же
        # разбор, что в откате ниже), и держался бы он до тика сторожа.
        if bring_up && wait_for_handshake; then
            apply_routing
            printf "${YELLOW}[возврат]${NC} awg0 снова на прежнем конфиге (%s).\n" "${_sw_prev:-?}"
        else
            printf "${RED}[FAIL]${NC} прежняя несущая тоже не поднялась — включаю прямой режим.\n"
            safety_off
            # ПРЯМОЙ РЕЖИМ БЕЗ ПИСЬМА — ЭТО МОЛЧАНИЕ О ГЛАВНОМ. Все прочие пути в safety_off шлют
            # событие (оно же строка в центре уведомлений панели), и новая ветка не имеет права
            # быть исключением: снаружи это выглядит как «нажал сменить сервер — и VPN пропал».
            if [ "$NF_LANG" = en ]; then
                notify_event "switch-failopen" 3600 "BE7000: CRIT — VPN did not come up, direct mode" \
"The config $target could not be laid out (no space, a broken config or a write failure — the exact
reason is in the log), and the PREVIOUS carrier (${_sw_prev:-unknown}) did not come back up either.
Direct mode is on (safety_off): internet and DNS work bypassing the VPN, listed sites are unavailable.
Check the log and free space: cat /tmp/enodia-switch-vpn-setup.log; df -h"
            else
                notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Конфиг $target не удалось разложить (место на разделе, битый конфиг или сбой записи — точная
причина в логе), а ПРЕЖНЯЯ несущая (${_sw_prev:-неизвестно}) обратно не поднялась. Включён прямой
режим (safety_off): интернет и DNS работают мимо VPN, сайты из списка недоступны.
Проверьте лог и место: cat /tmp/enodia-switch-vpn-setup.log; df -h"
            fi
        fi
        return 1
    fi

    off_stop "сервер $target разложен, поднимется при включении VPN" && return 1
    printf "${BLUE}[3/5]${NC} Поднимаю awg0...\n"
    if ! bring_up; then
        off_stop "сервер $target разложен, поднимется при включении VPN" && return 1
        printf "${RED}[FAIL]${NC} awg0 не поднялся → автооткат\n"
        # Отпускали ЧУЖУЮ несущую — её же и возвращаем: откат поднял бы СТАРЫЙ awg-конфиг и через
        # apply_routing записал бы `.transport=awg`, то есть смена СЕРВЕРА сменила бы ТРАНСПОРТ.
        if alt_back; then return 1; fi
        rollback
        return $?
    fi

    printf "${BLUE}[4/5]${NC} Жду handshake (до %d сек)" "$HS_WAIT"
    if wait_for_handshake; then
        printf " ${GREEN}есть${NC}\n"
        off_stop "сервер $target разложен, поднимется при включении VPN" && return 1
        printf "${BLUE}[5/5]${NC} Применяю правила маршрутизации...\n"
        apply_routing
        printf "\n${GREEN}[OK]${NC} Переключение на ${YELLOW}%s${NC} успешно.\n\n" "$target"
        show_status
        # Осознанный (ручной) выбор страны = новый «основной» (home) для режима
        # failover home: именно сюда watchdog будет возвращаться, когда home оживёт.
        echo "$target" > "$ENODIA_STATE/.failover-home"
        return 0
    else
        printf " ${RED}нет ответа${NC}\n"
        printf "${RED}[FAIL]${NC} %s не подключается (handshake не пришёл за %d сек)\n" "$target" "$HS_WAIT"
        printf "${YELLOW}=> автооткат на предыдущий конфиг${NC}\n\n"
        if alt_back; then return 1; fi
        rollback
        return $?
    fi
}

# Откат на сохранённый бэкап. СУДИМ ПО ФЛАГУ ЭТОГО ПРОГОНА (_sw_bak), а не по наличию файла:
# см. разбор у снимка в switch_to. Ручной верб `rollback` флага не имеет — там он пуст, и
# проверка вырождается в прежнее «есть ли файл», что для ручного отката и правильно.
rollback() {
    if [ "${_sw_bak:-x}" = 0 ] || [ ! -s "$BACKUP_CONF" ]; then
        # ПОЧЕМУ откатываться не на что — два разных факта, и человек проверит их по-разному.
        _rb_why="бэкапа $BACKUP_CONF нет"
        _rb_whye="there is no backup $BACKUP_CONF"
        if [ -s "$BACKUP_CONF" ]; then
            _rb_why="снимок $BACKUP_CONF остался от ПРОШЛОЙ смены сервера — поднимать по нему чужой конфиг мы не станем"
            _rb_whye="the snapshot $BACKUP_CONF is left over from an EARLIER switch — we will not bring up a config nobody chose now"
        fi
        printf "${RED}[FAIL]${NC} откатываться не на что: %s\n" "$_rb_why"
        off_stop "откат не нужен" && return 1
        safety_off
        if [ "$NF_LANG" = en ]; then
            notify_event "switch-failopen" 3600 "BE7000: CRIT — VPN did not come up, direct mode" \
"The new config did not come up, and there is nothing to roll back to: $_rb_whye.
Direct mode is on (safety_off): internet and DNS work bypassing the VPN,
listed sites are unavailable. awg0 is not active.
Log in via SSH: cat /tmp/enodia-switch-vpn-setup.log; then sh $ENODIA_BOOT/boot.sh heal.sh"
        else
            notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Новый конфиг не поднялся, а откатиться не на что: $_rb_why.
Включён прямой режим (safety_off): интернет и DNS работают мимо VPN,
сайты из списка недоступны. awg0 не активен.
Зайдите по SSH: cat /tmp/enodia-switch-vpn-setup.log; затем sh $ENODIA_BOOT/boot.sh heal.sh"
        fi
        return 1
    fi
    # ИМЯ ДЛЯ ЧЕЛОВЕКА И ИМЯ ДЛЯ `.active` — РАЗНЫЕ ОТВЕТЫ, а были одним. Пустой `.last.bak.name`
    # (снимок сняли, когда `.active` ещё не завели) уводил ЛИТЕРАЛ «(неизвестно)» в install_config,
    # то есть в файл, по которому судят панель, письма, `install.sh` и сам перебор резервов («какой
    # конфиг пропустить как дохлый»). Дальше система искала конфиг с именем «(неизвестно)» и не
    # находила его никогда. Теперь в `.active` уезжает ПУСТОТА — принятое в проекте «неизвестно»
    # (нулевой размер, см. install_config п.8), а скобки живут только в тексте для человека.
    # Угадывать имя по СОДЕРЖИМОМУ снимка не станем: install_config вычищает пустые I1..I5, и
    # совпадение с файлом в configs/ уже не обязано быть точным — ошибиться именем хуже, чем
    # честно промолчать.
    prev_name=""
    [ -s "$BACKUP_NAME" ] && prev_name=$(cat "$BACKUP_NAME")
    prev_label="$prev_name"
    [ -n "$prev_label" ] || prev_label="(неизвестно)"

    bring_down
    # Восстанавливаем ВСЕ три файла, как в install_config. КОД ВОЗВРАТА — В ТОЙ ЖЕ ЦЕПОЧКЕ, что и
    # bring_up: не разложили снимок — откат не состоялся ровно так же, как если бы не поднялся
    # туннель, и человеку об этом говорит то же самое письмо (ниже), а не тишина.
    install_config "$BACKUP_CONF" "$prev_name"; _rb_ic=$?
    off_stop "конфиг $prev_label возвращён на диск" && return 1
    if [ "$_rb_ic" = 0 ] && bring_up && wait_for_handshake; then
        off_stop "конфиг $prev_label возвращён на диск" && return 1
        apply_routing
        printf "\n${GREEN}[ОТКАТ OK]${NC} вернулся на ${YELLOW}%s${NC}\n\n" "$prev_label"
        show_status
        if [ "$NF_LANG" = en ]; then
            notify_event "switch-rollback" 3600 "BE7000: VPN auto-rollback → $prev_label" \
"Switching to the new config failed (the tunnel did not come up or no
handshake arrived). The router automatically rolled back to the previous config: $prev_label —
VPN works on it again. Check the new config and try again."
        else
            notify_event "switch-rollback" 3600 "BE7000: автооткат VPN → $prev_label" \
"Переключение на новый конфиг не удалось (туннель не поднялся или не пришёл
handshake). Роутер автоматически откатился на предыдущий конфиг: $prev_label —
VPN снова работает на нём. Проверьте новый конфиг и попробуйте ещё раз."
        fi
        return 0
    else
        # ЧТО ИМЕННО НЕ ВЫШЛО — ДВА РАЗНЫХ ФАКТА, и человек проверит их по-разному: «туннель не
        # встал» ведёт к ключам и серверу, «снимок не разложить» — к месту на разделе. Раньше
        # ветка была одна и говорила про туннель, которого никто не пробовал поднимать.
        _rb_fail="даже старый конфиг ($prev_label) не поднялся"
        _rb_faile="the ROLLBACK to the old config ($prev_label) also did not bring the tunnel up"
        if [ "$_rb_ic" != 0 ]; then
            _rb_fail="снимок $BACKUP_CONF ($prev_label) не удалось разложить (место на разделе?)"
            _rb_faile="the snapshot $BACKUP_CONF could not be written back (no space on the partition?)"
        fi
        # СНИМОК НЕ РАЗЛОЖИЛИ ⇒ НА ДИСКЕ ВСЁ ПРЕЖНЕЕ, и ручной откат не имеет права ронять
        # работающий VPN: конфиг, который вёз трафик минуту назад, лежит на месте — пробуем
        # вернуть несущую на него. Судим ПО РУКОПОЖАТИЮ, а не по факту интерфейса: поднятая, но
        # мёртвая несущая — это блэкхол, а не fail-open. Внутри `switch_to` (там стоит `_sw_bak`)
        # ветки нет: на диске лежит НОВЫЙ конфиг, который только что не поднялся.
        # ТОЛЬКО КОД 1 («на диске всё прежнее»). При коде 2 снимок лёг НАПОЛОВИНУ —
        # amnezia_for_awg.conf снят, вендорный скрипт заведомо откажется, и попытка стоила бы
        # пятнадцати секунд ожидания интерфейса ни за чем.
        if [ "$_rb_ic" = 1 ] && [ -z "${_sw_bak:-}" ] && bring_up && wait_for_handshake; then
            apply_routing
            printf "\n${YELLOW}[ОТКАТ НЕ ВЫШЕЛ]${NC} %s — но конфиг на диске жив, несущая возвращена на него.\n" "$_rb_fail"
            show_status
            return 1
        fi
        off_stop "конфиг $prev_label возвращён на диск" && return 1
        printf "\n${RED}[ОТКАТ FAIL]${NC} %s\n" "$_rb_fail"
        printf "${RED}Включаю safety_off — чтобы роутер не упёрся в дохлый awg0.${NC}\n"
        safety_off
        if [ "$NF_LANG" = en ]; then
            notify_event "switch-failopen" 3600 "BE7000: CRIT — VPN did not come up, direct mode" \
"The config change failed, and $_rb_faile.
Direct mode is on (safety_off): internet and DNS work
bypassing the VPN, listed sites are unavailable. awg0 is not active.
Investigate via SSH: cat /tmp/enodia-switch-vpn-setup.log; cat /tmp/enodia-startup.log."
        else
            notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Смена конфига провалилась: $_rb_fail.
Включён прямой режим (safety_off): интернет и DNS работают
мимо VPN, сайты из списка недоступны. awg0 не активен.
Разбор по SSH: cat /tmp/enodia-switch-vpn-setup.log; cat /tmp/enodia-startup.log."
        fi
        printf "${YELLOW}Что делать:${NC}\n"
        printf "  1) Проверьте awg.conf: cat %s\n" "$ACTIVE_CONF"
        printf "  2) Проверьте интернет на роутере: ping 1.1.1.1\n"
        printf "  3) Запустите heal.sh вручную: %s/heal.sh\n" "$ENODIA_DIR"
        printf "  4) Если не помогло — reboot и SSH-вход, разбор по логам:\n"
        printf "     cat /tmp/enodia-startup.log; cat /tmp/enodia-switch-vpn-setup.log\n"
        return 1
    fi
}

# ============================================================
# FAILOVER: автоматический перебор резервных конфигов
# ============================================================
# Зовётся watchdog.sh (или вручную: switch-vpn.sh failover), когда активный
# VPS умер. В отличие от switch_to (переключение на КОНКРЕТНУЮ страну) —
# перебирает ВСЕ configs/*.conf по алфавиту (glob в sh сортирован), кроме
# текущего, и встаёт на первый, давший handshake.
#
# Почему safety_off ПЕРВЫМ: перебор несколько раз опускает/поднимает awg0. Если
# оставить fwmark/mangle и туннельный DNS — на время перебора клиенты снова без
# интернета и DNS (ровно та авария, что чиним: трафик к iplist_set/enodia_list
# уходит в дохлый awg0, dnsmasq не резолвит). safety_off сразу пускает трафик/DNS
# напрямую, а VPN-роутинг возвращаем ТОЛЬКО когда резерв реально ответил (apply_routing —
# он же вернёт туннельный DNS через плагин и слой DoH).
#
# Возврат: 0 — встали на резерв (.active обновлён install_config'ом); 1 — ни один
# не встал, остались в прямом режиме (safety_off), awg0 поднят на ИСХОДНОМ конфиге
# для дальнейшего мониторинга watchdog'ом (вернётся, когда исходный оживёт).
do_failover() {
    # Гард: нет awg-демона — awg-перебор невозможен. Возвращаем 1 (watchdog трактует как
    # «прямой режим»), НЕ дёргая safety_off/bring_down. До этой ветки штатно не доходим
    # (cross на awg отсечён transport_ready), но защищаемся от любого вызова.
    if ! awg_installed; then
        printf "${YELLOW}[failover]${NC} AmneziaWG не установлен — awg-перебор невозможен, пропускаю.\n"
        return 1
    fi
    # VPN выключен вручную — перебирать не для кого (сторож при флаге перебор не зовёт; это страховка от прочих вызывателей).
    if carrier_barred; then
        printf "${YELLOW}[failover]${NC} VPN выключен вручную — перебор серверов не начинаю.\n"
        return 1
    fi
    acquire_lock

    cur_name=""
    [ -f "$ACTIVE_NAME" ] && cur_name=$(cat "$ACTIVE_NAME")

    # Сохраняем текущий (исходный) конфиг — если ни один резерв не встанет,
    # вернём его, чтобы awg0 мониторил именно исходный сервер.
    # ФЛАГ «СНИМОК НАШ, ЭТОГО ПРОГОНА»: сам файл `.last.bak.conf` ПЕРЕЖИВАЕТ сессии (его же читает
    # верб `rollback`, поэтому удалять его нельзя), и гард `[ -f ]` на возврате означал бы «на этом
    # роутере когда-то меняли страну». При пропавшем `awg.conf` мы бы молча подняли конфиг ПРОШЛОЙ
    # смены, записали в `.active` пустое имя (cur_name пуст) и прислали письмо «awg0 поднят на
    # исходном — мониторинг продолжается» про сервер, которого человек не выбирал (ревью 1).
    # `-s`, а не голое присваивание: `cp` не проверяется, и на полном /data снимок выходит
    # нулевым — возврат положил бы пустой файл поверх рабочего конфига (ревью 3).
    _fo_bak=0
    if [ -f "$ACTIVE_CONF" ]; then
        if cp "$ACTIVE_CONF" "$BACKUP_CONF" 2>/dev/null && [ -s "$BACKUP_CONF" ]; then _fo_bak=1; fi
        if [ -f "$ACTIVE_NAME" ]; then cp "$ACTIVE_NAME" "$BACKUP_NAME"; else : > "$BACKUP_NAME"; fi
    fi

    printf "${BLUE}[failover]${NC} активный сервер ${YELLOW}%s${NC} не отвечает — перебираю резервы\n" "${cur_name:-?}"

    # 1) Немедленно вернуть интернет/публичный DNS (см. шапку функции).
    safety_off

    # 2) Перебор резервов по алфавиту; первый с handshake — наш.
    tried=""
    _fo_dirty=0
    _fo_off=0
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        # ВЫКЛЮЧИЛИ ПОСРЕДИ ПЕРЕБОРА — дальше не пробуем: каждый кандидат = awg_setup с firewall reload и демон к VPS при «выключенном»
        # VPN, и так минутами (ревью ветки, круг 2). Исходный конфиг возвращаем ниже, несущую не поднимаем.
        carrier_barred && { _fo_off=1; break; }
        name=$(basename "$f" .conf)
        [ "$name" = "$cur_name" ] && continue   # текущий (дохлый) пропускаем
        # Конфиг ВЫХОДА — не резерв основного: встав на него, awg0 выбил бы сессию выхода (один ключ — одна сессия). В список
        # «пробовал» не пишем — до подъёма дело не дошло (как и с неразложенным кандидатом ниже).
        if key_busy "$name"; then
            printf "${YELLOW}[failover]${NC} %s пропускаю: ключ занят выходом.\n" "$name"
            continue
        fi

        printf "${BLUE}[failover]${NC} пробую ${YELLOW}%s${NC}...\n" "$name"
        bring_down
        # Не разложили — кандидат НЕ ПРОБОВАН (файлы не тронуты): считаем его перебранным и идём
        # дальше, вместо того чтобы поднимать несущую на конфиге ПРЕДЫДУЩЕГО кандидата и звать
        # это «встали на $name».
        install_config "$f" "$name"; _fo_ic=$?
        if [ "$_fo_ic" != 0 ]; then
            # В СПИСОК «ПРОБОВАЛ» НЕ ПИШЕМ: до подъёма дело не дошло, а письмо этим списком
            # отвечает на вопрос «какие резервы проверены» — приписка сюда врала бы, что сервер
            # проверен и не ответил. Причина видна в логе строкой выше.
            printf "${YELLOW}[failover]${NC} %s пропускаю: конфиг не разложить.\n" "$name"
            # КОД 2 — «ПОЛУПРИМЕНЕНО»: на диске уже лежит конфиг ЭТОГО кандидата, а второго файла
            # нет. Обычно это чинит следующая итерация или возврат исходного, но если ни того ни
            # другого не случится, письмо «возвращаться было не на что» солжёт: файлы-то тронуты.
            [ "$_fo_ic" = 2 ] && _fo_dirty=1
            continue
        fi
        # РАЗЛОЖИЛОСЬ ЧИСТО ⇒ следов полуприменения на диске больше нет: этот кандидат переписал
        # оба файла и имя. Флаг обязан гаснуть, иначе письмо уйдёт с чужой головой («исходный
        # конфиг не удалось разложить») там, где исходного конфига не было вовсе (ревью 6).
        _fo_dirty=0
        if bring_up && wait_for_handshake; then
            carrier_barred && { _fo_off=1; break; }
            apply_routing            # он же вернёт туннельный DNS: плагин + слой DoH
            ip=$(probe_ext_ip "--interface awg0" 5)
            printf "\n${GREEN}[failover OK]${NC} встал на ${YELLOW}%s${NC} (внешний IP: %s)\n" "$name" "${ip:-?}"
            if [ "$NF_LANG" = en ]; then
                notify_event "failover-ok" 1800 "BE7000: VPN failover -> $name" \
"Server ${cur_name:-?} stopped responding. The router automatically switched
to a backup config: $name — VPN works again (handshake received).
External IP now: ${ip:-unknown}.

To return to ${cur_name:-the previous one} manually: panel :8088 -> the VPN card."
            else
                notify_event "failover-ok" 1800 "BE7000: VPN-failover -> $name" \
"Сервер ${cur_name:-?} перестал отвечать. Роутер автоматически переключился
на резервный конфиг: $name — VPN снова работает (handshake получен).
Внешний IP сейчас: ${ip:-неизвестен}.

Вернуться на ${cur_name:-прежний} вручную: панель :8088 -> карточка VPN."
            fi
            return 0
        fi
        tried="$tried $name"
    done

    # ПЕРЕБОР ПРЕРВАН «Отключить VPN» (или выключили сразу после него) — на диск возвращаем исходный конфиг (снимок ЭТОГО прогона),
    # а awg0 для мониторинга НЕ поднимаем: при выключенном VPN его не бывает даже тёплым. Писем о прямом режиме не шлём.
    carrier_barred && _fo_off=1
    if [ "$_fo_off" = 1 ]; then
        if [ "$_fo_bak" = 1 ] && [ -s "$BACKUP_CONF" ]; then
            install_config "$BACKUP_CONF" "$cur_name" || printf "${RED}[FAIL]${NC} исходный конфиг (%s) на диск не вернулся — его вернёт heal на загрузке.\n" "${cur_name:-?}"
        fi
        off_stop "перебор серверов прерван, на диске исходный конфиг (${cur_name:-?})"
        return 1
    fi
    # 3) Ни один резерв не встал — возвращаем ИСХОДНЫЙ конфиг (чтобы awg0 мониторил
    #    именно его) и остаёмся в прямом режиме: safety_off уже сделан в п.1,
    #    apply_routing НЕ зовём.
    printf "\n${RED}[failover FAIL]${NC} ни один резерв не поднялся (пробовал:%s)\n" "${tried:- нет}"
    bring_down
    # КОД ВОЗВРАТА ЗАПОМИНАЕМ: он отвечает на вопрос, которого нет у `ip link` ниже — «интерфейс
    # ПОДНЯЛСЯ и потом исчез» против «не поднялся вовсе». Первое — почти всегда ОЗУ (демона унёс
    # OOM) или занятый флеш, второе — конфиг/ключи/бинарь, и советы тут противоположные.
    # `-` = bring_up не звался вовсе: возвращать было нечего (исходного конфига нет).
    # `s` = снимок ЕСТЬ, но его не разложить (места нет / раздел не пишется): bring_up не звался,
    # как и при `-`, но совет человеку противоположный — там «выбери сервер», тут «освободи место».
    _fo_up=-
    # Свип успел наполовину разложить чей-то конфиг ⇒ «возвращаться было не на что» — ложь: на
    # диске лежит НЕ ТО, что выбирал человек. Но и «исходный конфиг не разложить» (исход `s`) —
    # ложь, если исходного не было вовсе: снимок мы не делали, раскладывать было нечего. Отсюда
    # ШЕСТОЙ исход `d` — «на диске остался конфиг кандидата» (ревью 8).
    # СНИМОК ЕСТЬ ⇒ исход решит блок ниже (он присваивает `_fo_up` во ВСЕХ своих ветках), и своя
    # ветка `s` тут была бы мёртвой. Наш случай — ровно «снимка не было».
    if [ "${_fo_dirty:-0}" = 1 ] && { [ "$_fo_bak" != 1 ] || [ ! -s "$BACKUP_CONF" ]; }; then _fo_up=d; fi
    if [ "$_fo_bak" = 1 ] && [ -s "$BACKUP_CONF" ]; then
        if install_config "$BACKUP_CONF" "$cur_name"; then
            # без ожидания handshake: VPS мёртв, нам нужен лишь awg0 для мониторинга
            if bring_up; then _fo_up=1; else _fo_up=0; fi
        else
            _fo_up=s
        fi
    fi
    # Остаёмся в прямом режиме ⇒ полный repair запрещён (вернул бы маршрут в дохлый awg0),
    # но «доступ домой» после наших firewall reload'ов поднять надо — см. replay_home_only.
    replay_rules_only
    # Выключили, пока возвращали исходный, — письмо «прямой режим» про выключенный вручную VPN не шлём (awg0 гасим).
    off_stop "перебор серверов кончился, на диске исходный конфиг (${cur_name:-?})" && return 1
    # ЧЕМ КОНЧИЛОСЬ — РАЗНОЕ, И ГОВОРИТЬ НАДО РАЗНОЕ. Перебор зовут ДВА повода: «сервер молчит»
    # (awg0 есть, рукопожатия нет) и «awg0 не создаётся вовсе» (битый конфиг/ключи/бинарь; сюда
    # приводит эскалация сторожа). Во втором случае обещание «awg0 поднят на исходном — мониторинг
    # продолжается» ложно: мониторить нечего, оживать нечему.
    # ЗАМЕР — ЗДЕСЬ, А НЕ В НАЧАЛЕ ПЕРЕБОРА (ревью 4, 06.09.2026): письмо утверждает о состоянии
    # ПОСЛЕ свипа, а между началом и этой точкой лежат bring_down на каждого кандидата,
    # install_config исходного (он УДАЛЯЕТ awg0.conf) и bring_up. Оба расхождения реальны:
    # интерфейс был и не вернулся — обещали бы «мониторинг продолжается»; интерфейса не было, а
    # свип его пересоздал — слали бы человека проверять ключи при живом awg0.
    _fo_iface=0; ip link show awg0 >/dev/null 2>&1 && _fo_iface=1
    # ТРИ ИСХОДА, А НЕ ДВА. Факт («интерфейс есть сейчас») отвечает на вопрос «продолжается ли
    # мониторинг», но НЕ отличает «поднять не смогли» от «подняли, а он тут же исчез» — советы у
    # них противоположные: ОЗУ и место против ключей и бинарей (зеркало ветки AWG0_SEEN у
    # сторожа). Второе видно ТОЛЬКО по коду возврата bring_up, первое — только по факту, поэтому
    # судим по обоим: код без факта обещал бы мониторинг мёртвому интерфейсу (демон мог умереть
    # уже после подъёма — replay_home_only между ними), факт без кода валил бы на ключи то, что
    # поднялось и не удержалось.
    if [ "$_fo_iface" = 1 ]; then
        _fo_head="Сервер ${cur_name:-?} не отвечает"
        _fo_heade="Server ${cur_name:-?} is not responding"
        _fo_tail="awg0 поднят на ${cur_name:-исходном} — мониторинг продолжается: когда любой
сервер оживёт, VPN вернётся автоматически (watchdog повторит перебор резервов)."
        _fo_taile="awg0 is up on ${cur_name:-the original} — monitoring continues: when any
server comes back, VPN returns automatically (the watchdog will retry the backups)."
    elif [ "$_fo_up" = 1 ]; then
        _fo_head="Интерфейс awg0 поднялся и тут же исчез"
        _fo_heade="The awg0 interface came up and vanished right away"
        _fo_tail="awg0 создаётся, но не держится — чаще всего это нехватка ОЗУ (демона унёс OOM)
или занятый флеш; конфиг и ключи тут ни при чём. Панель: :8088 -> «О роутере» (клик по чипам в шапке)."
        _fo_taile="awg0 is created but does not stay up — usually that means low RAM (the daemon was
OOM-killed) or a full flash; the config and keys are not the cause.
Panel: :8088 -> About the router (click the header chips)."
    elif [ "$_fo_up" = d ]; then
        _fo_head="На диске остался конфиг, которого никто не выбирал"
        _fo_heade="A config nobody chose is left on the disk"
        _fo_tail="Перебор успел записать файлы одного из резервов лишь наполовину, а исходного конфига
на роутере не было вовсе — возвращать было не к чему. awg0 не поднят. Освободите место и выберите
сервер заново: панель :8088 -> карточка VPN."
        _fo_taile="The sweep half-wrote the files of one of the backups, and there was no original config
on the router at all — nothing to return to. awg0 is down. Free some space and pick a server
again: panel :8088 -> the VPN card."
    elif [ "$_fo_up" = s ]; then
        _fo_head="Исходный конфиг не удалось разложить"
        _fo_heade="The original config could not be written back"
        _fo_tail="awg0 сейчас не поднят: файлы конфигурации не записались — почти всегда это
кончившееся место на разделе. Панель: :8088 -> «О роутере» (место на флеше), затем повторите выбор сервера."
        _fo_taile="awg0 is down: the config files could not be written — almost always a full
partition. Panel: :8088 -> About the router (flash space), then pick the server again."
    elif [ "$_fo_up" = "-" ]; then
        # ВОЗВРАЩАТЬ БЫЛО НЕЧЕГО: исходного конфига на роутере нет, `bring_up` мы не звали вовсе.
        # Общий текст «дело НЕ в том, что сервер молчит» тут ЛОЖЬ: awg0 мог подниматься у каждого
        # кандидата и падать только на рукопожатии, то есть сервер как раз и молчал (ревью 1).
        _fo_head="Возвращаться было не на что: активного конфига нет"
        _fo_heade="There was no active config to return to"
        _fo_tail="awg0 сейчас не поднят: перебор кончился, а исходного сервера на роутере нет.
Выберите сервер в панели: :8088 -> карточка VPN."
        _fo_taile="awg0 is down: the sweep ended and there is no original server on the router.
Pick one in the panel: :8088 -> the VPN card."
    else
        _fo_head="Интерфейс awg0 не удалось создать"
        _fo_heade="The awg0 interface could not be created"
        _fo_tail="awg0 не поднимается вовсе — дело НЕ в том, что сервер молчит: проверьте конфиг
AmneziaWG (ключи, Endpoint), бинари в «Компонентах» и место на флеше."
        _fo_taile="awg0 does not come up at all — the problem is NOT the server being down: check the
AmneziaWG config (keys, Endpoint), the binaries in Components and free flash space."
    fi
    if [ "$NF_LANG" = en ]; then
        notify_event "failover-fail" 3600 "BE7000: VPN down, backups unavailable — direct mode" \
"$_fo_heade, and no backup config came up
(tried:${tried:- none}). The router is in DIRECT mode (safety_off): traffic and DNS
go around the VPN — if the ISP link is alive, the internet works; listed sites are
unavailable.
$_fo_taile"
    else
        notify_event "failover-fail" 3600 "BE7000: VPN упал, резервы недоступны — прямой режим" \
"$_fo_head, и ни один резервный конфиг не поднялся
(пробовал:${tried:- нет}). Роутер в ПРЯМОМ режиме (safety_off): трафик и DNS идут
мимо VPN — если связь с провайдером есть, интернет работает; сайты из списка
недоступны.
$_fo_tail"
    fi
    return 1
}

# ============================================================
# MAIN
# ============================================================
case "$1" in
    ""|list|ls)
        list_configs
        echo ""
        printf "Использование: %s <имя_конфига>\n" "$0"
        printf "Пример:        %s germany\n" "$0"
        printf "Откат:         %s rollback\n" "$0"
        printf "Текущий:       %s status\n" "$0"
        ;;
    status)
        show_status ip
        ;;
    rollback)
        # ГАРД КОМПОНЕНТА — как у switch_to и do_failover: без бинарей AmneziaWG откат неизбежно
        # провалится на bring_up и уйдёт в safety_off, а тот снимает default из table 1000 и общую
        # маркировку — то есть роняет ЧУЖУЮ живую несущую (xray/hy2) ради awg, которого нет
        # (ревью 4, 06.09.2026).
        if ! awg_installed; then
            printf "${YELLOW}[rollback]${NC} AmneziaWG не установлен — откатывать нечем, ничего не трогаю.\n"
            exit 1
        fi
        acquire_lock
        rollback
        ;;
    safety-off|safety_off)
        # Точка входа для watchdog.sh: аварийный fail-open БЕЗ перебора
        # серверов — снять привязку к дохлому awg0 и пустить трафик/DNS
        # напрямую. Туннель НЕ опускаем: handshake продолжит мониториться,
        # и watchdog вернёт VPN, когда VPS оживёт.
        safety_off
        ;;
    failover)
        # Точка входа для watchdog.sh (режимы sticky/home) и ручного запуска:
        # перебрать резервы и встать на первый рабочий. Код возврата (0=встали на
        # резерв / 1=прямой режим) watchdog читает, чтобы выставить своё состояние.
        do_failover
        ;;
    stage)
        # РАЗЛОЖИТЬ конфиг БЕЗ переключения — зеркало того, что панель делает для xray/hy2
        # (`set_xray_server`: «просто стейджим конфиг — применится при switch»). Зачем отдельный
        # верб: у AmneziaWG раскладка не сводится к `cp` — это ТРИ файла (awg.conf +
        # amnezia_for_awg.conf, который читает вендорный awg_setup.sh, + удаление awg0.conf,
        # иначе демон возьмёт СТАРЫЕ ключи) плюс вычистка пустых I1..I5. Копия этой логики в CGI
        # разъехалась бы с install_config первой же правкой.
        # ЗАЧЕМ ВООБЩЕ (разбор с тестером 14.08.2026): без awg.conf `transport_ready awg` = false,
        # и панель честно пишет «нужен конфиг» — при том, что конфиг ДОБАВЛЕН и виден в списке.
        # Единственным способом положить awg.conf было полное переключение, а оно СНАЧАЛА роняет
        # текущую несущую: не поднялся awg — откатываться не на что (прежнего awg.conf нет) ⇒
        # safety_off, и человек остаётся вообще без VPN. Ровно это он и получил: «после попытки
        # установить авг теперь даже хистерия не запускается».
        [ -n "$2" ] || { printf "${RED}[FAIL]${NC} укажите имя конфига\n"; exit 1; }
        _st_src="$CONFIGS_DIR/${2}.conf"
        [ -f "$_st_src" ] || { printf "${RED}[FAIL]${NC} Не найден файл %s\n" "$_st_src"; exit 1; }
        if key_busy "$2"; then printf "${RED}[FAIL]${NC} %s\n" "$KEY_BUSY"; exit 1; fi
        install_config "$_st_src" "$2" || exit 1
        printf "${GREEN}[OK]${NC} конфиг %s разложен (awg.conf + amnezia_for_awg.conf). Несущая НЕ тронута.\n" "$2"
        ;;
    *)
        switch_to "$1"
        ;;
esac
