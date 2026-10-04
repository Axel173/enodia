#!/bin/sh
# proto-install.sh — смена НАБОРА протоколов на роутере (awg / альт), скачивая бинари с
# GitHub через gh-update.sh. Запускается ФОНОМ из веб-панели (cgi-bin/action), прогресс
# пишется в $ENODIA_STATE/.proto-install.{state,log} — фронт их опрашивает (polling).
#
# Наборы (combo): awg | xray | hy2 | byedpi | awg-xray | awg-hy2 | awg-byedpi.
#   awg-axis: amneziawg-go(+awg) база; alt-axis: один из xray/hy2/byedpi (общий socks 10808 + hev
#   → АКТИВЕН один альт за раз). byedpi = локальный DPI-десинк БЕЗ VPS (~0.3 МБ + общий hev),
#   конфиг не нужен — десинк-аргументы опц. в .byedpi-args.
#   ВАЖНО: набор описывает, что должно БЫТЬ установлено и активно, а НЕ «чего быть не должно».
#   Прочие альты остаются лежать, если позволяет флеш (установлен ≠ активен — рядом легально
#   живут «основной xray» и «byedpi как карриер выхода №2»). Прежнее безусловное «ровно один»
#   разлучало именно такую пару при каждой смене набора. Про место судит packages.sh plan-ok —
#   единственная арифметика с резервом 3 МБ; своей второй копии здесь нет намеренно.
#   Штучный выбор компонентов — карточка «Компоненты» в панели (packages.sh), этот файл легаси/CLI.
#
# ПОРЯДОК (грабли флеша/несущей):
#   1) Если активная несущая уходит из набора — релинквиш (transport.sh down → fail-open в прямой),
#      иначе осиротевший xtun/awg0 блэкхолит трафик (как в purge-alt/_relinquish_if_active).
#   2) УДАЛЕНИЯ сперва (освободить флеш) — ТОЛЬКО если иначе не влезет: лишние альты → reuse
#      install.sh purge-alt (он же гасит демон + чистит hev по ref-count); снятие awg
#      → rm amneziawg-go+awg (с гардом «доступа домой»).
#   3) Гард места (df /data) — НЕ начинать качать, если не влезет.
#   4) СКАЧИВАНИЯ недостающего (gh-update.sh fetch-bin, atomic + ELF-проверка).
#   5) Активация целевой несущей (transport.sh switch) — если есть конфиг; иначе fail-open
#      с подсказкой «добавь конфиг в Серверы».
# Добавление awg С НУЛЯ (alt-only → +awg, когда awg0 не настроен) реюзает awg_setup.sh при
# наличии awg.conf; без него — просим вернуть awg через установщик с ПК.
#
# rm живёт ЗДЕСЬ (PS-guard на литерал rm). НЕ используем set -e — шаги best-effort.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Где лежит бинарь (store-lib.sh): без внешнего накопителя — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
command -v bin_path  >/dev/null 2>&1 || bin_path()  { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_dest  >/dev/null 2>&1 || bin_dest()  { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_prune >/dev/null 2>&1 || bin_prune() { return 0; }
GH="$ENODIA_DIR/gh-update.sh"
SETUP="$ENODIA_DIR/install.sh"
TRANSPORT="$ENODIA_DIR/transport.sh"
STATE="$ENODIA_STATE/.proto-install.state"
LOG="$ENODIA_STATE/.proto-install.log"
LOCK="/tmp/enodia-proto-install.lock"

# Атомарно (запись рядом + `mv`) — разбор у packages.sh::set_state: файл тот же, и читатель пустого видит «IDLE».
set_state() { echo "$1" > "$STATE.new" && mv -f "$STATE.new" "$STATE"; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

parse_combo() {
    case "$1" in
        awg)        WANT_AWG=1; WANT_ALT=none ;;
        xray)       WANT_AWG=0; WANT_ALT=xray ;;
        hy2)        WANT_AWG=0; WANT_ALT=hy2 ;;
        byedpi)     WANT_AWG=0; WANT_ALT=byedpi ;;
        awg-xray)   WANT_AWG=1; WANT_ALT=xray ;;
        awg-hy2)    WANT_AWG=1; WANT_ALT=hy2 ;;
        awg-byedpi) WANT_AWG=1; WANT_ALT=byedpi ;;
        *) return 1 ;;
    esac
}

# awg «установлен» = ОБА бинаря: amneziawg-go (демон) И awg (CLI amneziawg-tools).
# Если есть только демон (CLI пропал/не докачался) — awg НЕ готов и его надо ДОкачать,
# иначе awg0 не встанет (awg_setup.sh делает `awg setconf awg0`). Симметрично transport_ready.
# awg-база резидентна всегда, альты ищем через bin_path (store-lib.sh): уехавший на внешний
# накопитель бинарь обязан считаться УСТАНОВЛЕННЫМ, иначе гард места решит, что его надо
# качать заново, и потребует мегабайты, которых на флеше нет.
have_awg()    { [ -x "$ENODIA_BIN/amneziawg-go" ] && [ -x "$ENODIA_BIN/awg" ]; }
have_xray()   { [ -x "$(bin_path xray)" ]; }
have_hy2()    { [ -x "$(bin_path hysteria)" ]; }
have_byedpi() { [ -x "$(bin_path byedpi)" ]; }
# ВСЕ установленные альты, не «первый попавшийся»: прежний cur_alt() возвращал одно слово и тем
# самым прятал второй альт от лога и от решения о чистке (ровно так панель рисовала «awg+xray» на
# роутере, где рядом стоял ещё и byedpi).
cur_alts()    { _l=""; have_xray && _l="$_l xray"; have_hy2 && _l="$_l hy2"; have_byedpi && _l="$_l byedpi"; echo "${_l# }"; }
# Том — по ПУТИ каталога, не по литералу `/data`: на BE10000 это чужой том (следит C50).
df_free_mb(){ df -k "$ENODIA_DIR" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{printf "%d",$(NF-2)/1024}'; }

apply() {
    combo="$1"
    # План движка компонентов (packages.sh) описывает ЕГО операцию; у смены набора плана нет — снимаем прежний, иначе
    # секция doh и карточка HTTPS приписали бы эту операцию и её лог прошлому плану (ревью шага 5a, круг 3).
    rm -f "$ENODIA_STATE/.proto-install.plan" 2>/dev/null
    if ! parse_combo "$combo"; then : > "$LOG"; set_state FAIL; log "неизвестный набор: $combo"; return 1; fi
    : > "$LOG"; set_state RUNNING
    free=$(df_free_mb)
    log "Цель: awg=$WANT_AWG, альт=$WANT_ALT (свободно ${free:-?} МБ)"

    active=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    cura=$(cur_alts)
    log "Сейчас: активный=$active, альты=[${cura:-нет}], awg-бинарь=$(have_awg && echo да || echo нет)"

    # 0. ПРЕ-ЧЕК доступности GitHub ДО удалений. Если для целевого набора нужно что-то качать,
    #    а GitHub недоступен — НЕ сносим рабочий альт (purge-alt + rm бинарей идут ниже, шаг 2):
    #    иначе остались бы без единого транспорта в прямом режиме до ручного повтора. Пробуем
    #    ДОСТИЖИМОСТЬ raw.github через `gh reachable` (тот же надёжный anycast-перебор, что и у
    #    бинарей). ВАЖНО: это проверка СЕТИ, а не наличия файла — публичный репо может не
    #    содержать VERSION (→ 404), а bin/*.user на месте и качаются; старый `gh dl VERSION`
    #    ложно ронял смену набора на этом 404 (поймано на железе 2026-07-11).
    #    have_* тут ещё в ДО-purge состоянии, но purge удаляет НЕ целевой альт → оценка верна.
    need_dl=0
    { [ "$WANT_AWG" = 1 ] && ! have_awg; }           && need_dl=1
    { [ "$WANT_ALT" = xray ]   && ! have_xray; }      && need_dl=1
    { [ "$WANT_ALT" = hy2 ]    && ! have_hy2; }       && need_dl=1
    { [ "$WANT_ALT" = byedpi ] && ! have_byedpi; }    && need_dl=1
    { [ "$WANT_ALT" != none ]  && [ ! -x "$(bin_path hev)" ]; } && need_dl=1
    # Гарды вокруг вызовов через `sh` — `-f`, а НЕ `-x` (класс Б5-9): снятый бит выполнения
    # означал бы не «нет файла», а ТИХИЙ пропуск шага. Здесь цена пропуска максимальна — без
    # пре-чека сети мы идём сносить рабочий альт (шаг 2) и только потом узнаём, что качать нечем.
    if [ "$need_dl" = 1 ] && [ -f "$GH" ]; then
        log "Пре-чек доступности GitHub (нужны закачки)…"
        # Причину печатает сам пре-чек (напр. отказ по частоте 429 — интернет при этом цел).
        # Пусто = старая копия gh-update без этой строки ⇒ прежний текст.
        _why=$(sh "$GH" reachable 2>/dev/null)
        if [ "$?" = 0 ]; then
            log "GitHub доступен — продолжаю."
        else
            [ -n "$_why" ] || _why="GitHub недоступен — проверьте VPN и интернет"
            set_state FAIL
            log "$_why. НЕ трогаю текущий набор (ничего не удалено)."
            return 1
        fi
    fi

    # 1. Релинквиш активной несущей, если она уходит из набора.
    drop_active=0
    case "$active" in
        awg)    [ "$WANT_AWG" = 1 ]      || drop_active=1 ;;
        xray)   [ "$WANT_ALT" = xray ]   || drop_active=1 ;;
        hy2)    [ "$WANT_ALT" = hy2 ]    || drop_active=1 ;;
        byedpi) [ "$WANT_ALT" = byedpi ] || drop_active=1 ;;
    esac
    if [ "$drop_active" = 1 ] && [ -n "$active" ]; then
        log "Активная несущая ($active) уходит из набора — релинквиш (прямой режим до подъёма новой)"
        sh "$TRANSPORT" down "$active" >/dev/null 2>&1
    fi

    # 2. УДАЛЕНИЯ сперва (освободить флеш) — но ТОЛЬКО ради места. Раньше «лишний» альт сносился
    #    безусловно, из-за понимания «на флеше ровно один альт»; на живом роутере это разлучало
    #    xray (несущая) и byedpi (карриер выхода №2) при каждой смене набора. Теперь спрашиваем
    #    packages.sh plan-ok: «влезет ли целевой набор, если НИЧЕГО не снимать?». Влезет — не
    #    трогаем чужие бинари. Нет packages.sh (старый роутер) или размеры неизвестны (нет
    #    bin-manifest) → plan-ok даёт отказ и мы работаем по-старому. Качать нечего (need_dl=0) —
    #    чистить незачем в принципе. Осиротевший демон снятого набора уже отпущен шагом 1
    #    (transport.sh down), остальное подберёт free_foreign_socks плагина.
    purge_needed=0
    if [ "$need_dl" = 1 ] && [ -f "$SETUP" ]; then
        purge_needed=1
        want_pkgs=""
        [ "$WANT_AWG" = 1 ] && want_pkgs="awg"
        [ "$WANT_ALT" != none ] && want_pkgs="${want_pkgs:+$want_pkgs,}$WANT_ALT"
        if [ -f "$ENODIA_DIR/packages.sh" ] && sh "$ENODIA_DIR/packages.sh" plan-ok "${want_pkgs:--}" - >/dev/null 2>&1; then
            purge_needed=0
            log "Места хватает — прочие альты ОСТАВЛЯЮ на флеше (установлен ≠ активен)."
        fi
    fi
    if [ "$purge_needed" = 1 ]; then
        log "Освобождаю флеш: снимаю альты, кроме нужного ($WANT_ALT), через purge-alt…"
        INSTALL_ALT="$WANT_ALT" sh "$SETUP" purge-alt >> "$LOG" 2>&1
    fi
    # ГАРД ДОП-ВЫХОДА (тот же, что у purge-alt для альтов и у packages.sh для всех связок): awg
    # может нести не основной туннель, а СЛОТ («выход №3 — другая страна тем же AmneziaWG»).
    # Слот не виден ни в наборе, ни в .transport, поэтому без этой проверки смена набора на
    # alt-only сносила бинарь из-под живого выхода: правила на месте, панель показывает «вкл»,
    # а трафик группы уходит в никуда — ровно та жалоба, из-за которой рядом появился гард
    # «доступа домой». Реестр слотов спрашиваем у его владельца.
    awg_carries_slot=0
    if [ -f "$ENODIA_DIR/slots.sh" ] && sh "$ENODIA_DIR/slots.sh" carriers 2>/dev/null | grep -qx awg; then
        awg_carries_slot=1
    fi
    if [ "$WANT_AWG" = 0 ] && have_awg && [ "$awg_carries_slot" = 1 ]; then
        log "AmneziaWG-бинари ОСТАВЛЕНЫ: на них висит дополнительный выход (см. «Соединение → Дополнительные выходы»)."
    elif [ "$WANT_AWG" = 0 ] && have_awg; then
        # ГАРД «ДОСТУПА ДОМОЙ»: awgs0 (роутер как VPN-сервер) — ЭТОТ ЖЕ amneziawg-go. Раньше набор
        # без awg молча сносил оба бинаря и уносил сервер вместе с ними: правила на месте, панель
        # показывает «включено», а телефон домой не заходит — до ребута и без единой строчки в
        # логе. Бинари ОСТАВЛЯЕМ (1.1 МБ) и говорим почему — ровно как purge-alt поступает с
        # бинарём, несущим доп-выход. Целевой транспорт при этом поднимется как ни в чём не бывало.
        if [ -f "$ENODIA_STATE/server/.on" ]; then
            log "AmneziaWG-бинари ОСТАВЛЕНЫ: включён «доступ домой» (сервер awgs0 — тот же демон). Выключите его на экране «Доступ домой», если нужно освободить ~1.1 МБ."
        else
            log "Снимаю AmneziaWG (база) — целевой набор без awg"
            [ "$active" = awg ] && sh "$TRANSPORT" down awg >/dev/null 2>&1
            rm -f "$ENODIA_BIN/amneziawg-go" "$ENODIA_BIN/awg"
        fi
    fi

    # 3. Гард места ПЕРЕД скачиваниями. Размеры берём из bin-manifest.txt (`gh-update.sh bin-size`,
    #    байты реального файла в репо), а не хардкодом «+8 МБ»: прежние числа врали в обе стороны
    #    после каждой пересборки/перепаковки UPX, а на 20-МБ флеше ошибка в мегабайт — это отказ.
    #    Манифеста нет (старый публичный снимок / нет сети) → гард ПРОПУСКАЕМ и говорим об этом:
    #    второй таблицы размеров в проекте быть не должно, а провал по месту поймает сама закачка.
    need_b=0; need_unknown=0
    add_need() {
        _n=$(sh "$GH" bin-size "$1" 2>/dev/null | tr -d ' \r')
        case "$_n" in ''|*[!0-9]*|0) need_unknown=1; return 0 ;; esac
        need_b=$((need_b+_n))
    }
    { [ "$WANT_AWG" = 1 ] && ! have_awg; } && { add_need amneziawg-go; add_need awg; }
    { [ "$WANT_ALT" = xray ]   && ! have_xray; }   && add_need xray
    { [ "$WANT_ALT" = hy2 ]    && ! have_hy2; }    && add_need hysteria
    { [ "$WANT_ALT" = byedpi ] && ! have_byedpi; } && add_need byedpi
    { [ "$WANT_ALT" != none ] && [ ! -x "$(bin_path hev)" ]; } && add_need hev   # bin_path: hev может лежать на накопителе (иначе лишняя перекачка и завышенный план места)
    need=$(( (need_b + 1048575) / 1048576 ))   # байты → МБ ВВЕРХ
    [ "$need_unknown" = 0 ] || log "Размеры части бинарей неизвестны (нет bin-manifest.txt) — гард места неполный"
    sync 2>/dev/null   # отразить недавние rm (purge-alt): UBIFS пишет лениво, иначе df завышает «занято»
    free=$(df_free_mb)
    if [ "$need" -gt 0 ]; then
        log "Нужно скачать ~${need} МБ, свободно ${free:-0} МБ"
        # need — точная сумма байтов из манифеста, округлённая ВВЕРХ до МБ, а закачка идёт
        # ПОСЛЕДОВАТЕЛЬНО (.dl → mv, без удвоения на флеше). Поэтому буфер +1, а не +2: иначе на
        # тесном 20-МБ флеше (after-install ~4-5 МБ free — норма для awg+xray) гард ЛОЖНО блокировал
        # установку при реально достаточных 10-11 МБ (free колеблется из-за ленивого UBIFS-GC).
        if [ "${free:-0}" -lt $((need+1)) ]; then
            set_state FAIL; log "Мало места на /data (нужно ~${need} МБ, свободно ${free:-0} МБ) — освободите флеш или перезагрузите роутер и повторите."; return 1
        fi
    fi

    # 4. СКАЧИВАНИЯ недостающего.
    if [ "$WANT_AWG" = 1 ] && ! have_awg; then
        log "Скачиваю AmneziaWG-бинари…"
        sh "$GH" fetch-bin amneziawg-go "$ENODIA_BIN/amneziawg-go" >> "$LOG" 2>&1 || { set_state FAIL; log "не скачал amneziawg-go"; return 1; }
        sh "$GH" fetch-bin awg "$ENODIA_BIN/awg" >> "$LOG" 2>&1 || { set_state FAIL; log "не скачал awg"; return 1; }
    fi
    # КУДА качать альт-бинари решает bin_dest (store-lib.sh), а не эти строки: при включённом
    # внешнем накопителе тяжёлое едет сразу туда. bin_prune следом убирает копию с другой
    # стороны — «копия ровно одна» (bin_path предпочитает накопитель, забытый там старый файл
    # выдавал бы себя за свежескачанный). Без накопителя оба вызова — прежний путь байт-в-байт.
    dl_bin() {   # $1 = имя бинаря, $2 = человеческая метка
        log "Скачиваю $2…"
        _d=$(bin_dest "$1"); mkdir -p "${_d%/*}" 2>/dev/null
        sh "$GH" fetch-bin "$1" "$_d" >> "$LOG" 2>&1 || { set_state FAIL; log "не скачал $1"; return 1; }
        bin_prune "$1"
        return 0
    }
    case "$WANT_ALT" in
        xray)
            have_xray || dl_bin xray "Xray" || return 1
            [ -x "$(bin_path hev)" ] || dl_bin hev "hev (tun2socks)" || return 1
            ;;
        hy2)
            have_hy2 || dl_bin hysteria "Hysteria2" || return 1
            [ -x "$(bin_path hev)" ] || dl_bin hev "hev (tun2socks)" || return 1
            ;;
        byedpi)
            # byedpi = ciadpi (UPX-сжатый статик: ~138 КБ arm64 / ~64 КБ armv7, bin/<арка>/byedpi.user).
            # Конфиг НЕ нужен (десинк локальный, без VPS) — только бинарь + общий hev.
            have_byedpi || dl_bin byedpi "ByeDPI (ciadpi)" || return 1
            [ -x "$(bin_path hev)" ] || dl_bin hev "hev (tun2socks)" || return 1
            ;;
    esac
    # Гард — `-f`: с прежним `-x` chmod доставался ровно тем файлам, у которых бит УЖЕ стоял,
    # то есть строки не делали ничего вообще (мёртвый код на месте страховки).
    [ -f "$ENODIA_DIR/xray-transport.sh" ] && chmod +x "$ENODIA_DIR/xray-transport.sh" 2>/dev/null
    [ -f "$ENODIA_DIR/transport-hy2.sh" ] && chmod +x "$ENODIA_DIR/transport-hy2.sh" 2>/dev/null
    [ -f "$ENODIA_DIR/transport-byedpi.sh" ] && chmod +x "$ENODIA_DIR/transport-byedpi.sh" 2>/dev/null

    # 4b. Добавляем awg, а awg0 ещё не настроен → нужен awg_setup.sh (генерит awg0.conf).
    fw3_wiped=0
    if [ "$WANT_AWG" = 1 ] && ! ip link show awg0 >/dev/null 2>&1; then
        # Зеркало amnezia_for_awg.conf из awg.conf (его читает вендорный awg_setup.sh, НЕ awg.conf) — как большой установщик
        # (install.sh), иначе «File amnezia_for_awg.conf not found». ДО гарда выключенного VPN: зеркала на подъёме не делает никто,
        # кроме бутового heal, и «Включить VPN» после этой установки AmneziaWG не подняло бы (ревью ветки, круг 3).
        if [ -f "$ENODIA_STATE/awg.conf" ] && [ ! -f "$ENODIA_STATE/amnezia_for_awg.conf" ]; then
            cp "$ENODIA_STATE/awg.conf" "$ENODIA_STATE/amnezia_for_awg.conf"
        fi
        # VPN ВЫКЛЮЧЕН ВРУЧНУЮ — awg0 не поднимаем даже ради конфига: при выключенном VPN его не бывает и тёплым, а awg_setup ещё и
        # делает firewall reload. awg0.conf сгенерит первый же подъём после «Включить VPN» (ревью ветки, круг 2; при флаге отказал
        # бы и сам awg_setup — здесь говорим это словами и не помечаем снос правил, которого не было).
        if [ -f "$ENODIA_STATE/.vpn-off" ]; then
            log "VPN выключен вручную — AmneziaWG не поднимаю (поднимется при включении VPN)"
        elif [ -f "$ENODIA_STATE/awg.conf" ] && [ -f "$ENODIA_DIR/awg_setup.sh" ]; then
            # awg_setup.sh работает по ОТНОСИТЕЛЬНЫМ путям (бинари ./awg ./amneziawg-go; конфиг зеркалим выше) ⇒
            # ОБЯЗАТЕЛЬНО cd в $ENODIA_DIR, иначе скрипт ищет бинари в CWD фонового процесса (/) и падает даже когда файлы на месте.
            log "Поднимаю AmneziaWG с нуля (awg_setup.sh)…"
            # Внутри — `/etc/init.d/firewall reload`, т.е. снос ВСЕХ iptables (цепочки
            # apply-bypass, ENODIA_ZAPRET, FORWARD доп-выходов, PANEL_WAN, «доступ домой»).
            # Помечаем и переигрываем в п.5 — ПОСЛЕ подъёма целевой несущей.
            fw3_wiped=1
            ( cd "$ENODIA_DIR" && sh ./awg_setup.sh ) >> "$LOG" 2>&1 || log "awg_setup завершился с ошибкой (см. лог выше)"
        else
            log "Нет awg.conf или awg_setup.sh — добавьте сервер AmneziaWG в «Соединение → Серверы и конфиги»"
        fi
    fi

    # 5. Маркировка-ядро + выбор/подъём целевой несущей.
    [ -f "$ENODIA_DIR/mark-core.sh" ] && sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1
    target=""
    case "$active" in
        awg)    [ "$WANT_AWG" = 1 ]      && target=awg ;;
        xray)   [ "$WANT_ALT" = xray ]   && target=xray ;;
        hy2)    [ "$WANT_ALT" = hy2 ]    && target=hy2 ;;
        byedpi) [ "$WANT_ALT" = byedpi ] && target=byedpi ;;
    esac
    if [ -z "$target" ]; then
        if [ "$WANT_AWG" = 1 ]; then target=awg; else target="$WANT_ALT"; fi
    fi
    if [ -n "$target" ] && [ "$target" != none ] && [ -f "$ENODIA_STATE/.vpn-off" ]; then
        # VPN ВЫКЛЮЧЕН ТУМБЛЕРОМ: смена набора — не включение. switch без `--home` при флаге откажет (автомат не отменяет
        # выключение), а прежний протокол набор мог уже снять — `.transport` остался бы на протоколе, которого нет, с ложной
        # причиной в логе (ревью ветки, круг 1). Меняем только НАМЕРЕНИЕ (как CGI zapret_off): поднимет его «Включить VPN».
        echo "$target" > "$ENODIA_STATE/.transport"; rm -f "$ENODIA_STATE/.zapret-on" 2>/dev/null
        log "VPN выключен вручную — несущую не поднимаю; при включении поднимется $target"
    elif [ -n "$target" ] && [ "$target" != none ]; then
        log "Активирую несущую: $target…"
        if sh "$TRANSPORT" switch "$target" >> "$LOG" 2>&1; then
            log "Активная несущая: $target"
        else
            log "Несущую '$target' поднять не вышло (нет активного конфига?) — добавьте конфиг в «Соединение → Серверы и конфиги». Пока прямой режим (интернет работает)."
        fi
    fi

    # 5b. Переигрыш ПОСЛЕ firewall reload из awg_setup.sh (см. fw3_wiped): mark-core выше вернул
    # только ЯДРО, а снесено было всё — bypass/порты/устройства, zapret, доп-выходы, «доступ
    # домой». Канонический переигрыш один (vpn-toggle.sh repair), своей копии списка тут не
    # держим. Зовём ПОСЛЕ switch: repair поднимает несущую по .transport, а его пишет switch.
    if [ "$fw3_wiped" = 1 ] && [ -f "$ENODIA_DIR/vpn-toggle.sh" ]; then
        log "awg_setup сделал firewall reload — переигрываю правила (vpn-toggle repair)…"
        sh "$ENODIA_DIR/vpn-toggle.sh" repair >> "$LOG" 2>&1 || true
    fi

    set_state OK
    log "Готово. Установлено/готово: $(sh "$TRANSPORT" list 2>/dev/null | tr '\n' ' ')"
}

case "$1" in
    apply)
        # АТОМАРНЫЙ лок через mkdir (succeeds-or-fails без гонки). Прежний `[ RUNNING ] && [ -f LOCK ]`
        # + `: > LOCK` имел TOCTOU-окно между созданием файла и set_state RUNNING: два быстрых клика
        # из панели проходили гард ОБА → два purge+fetch на 20-МБ флеше = «No space». mkdir так не даст.
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
        # ВТОРОЙ лок — «идёт смена транспорта» (класс Б5-4). Между релинквишем несущей (шаг 1) и
        # её подъёмом (шаг 5) лежат ЗАКАЧКИ, то есть минуты, в течение которых `.transport` всё
        # ещё называет снятый транспорт: тик сторожа честно читает «health провалился» и
        # переподнимает его несущую (или уводит в cross) ПОВЕРХ идущей установки — осиротевшие
        # демоны на общем socks 10808 и table 1000, смотрящая в чужой xtun. Идиома switch-vpn:
        # ЧУЖОЙ лок не трогаем (его снимет владелец), свой снимаем trap'ом.
        SWLOCK=/tmp/enodia-switching.lock; SWMINE=0
        [ -e "$SWLOCK" ] || { : > "$SWLOCK" 2>/dev/null && SWMINE=1; }
        # Сигнал — ВЫХОД (C121). HUP и PIPE глушим, как pkg-install.sh: между снятием несущей и подъёмом новой — минуты закачек,
        # и обрыв SSH у ручного запуска не должен бросать роутер без транспорта посреди смены.
        trap 'rm -rf "$LOCK" 2>/dev/null; [ "$SWMINE" = 1 ] && rm -f "$SWLOCK" 2>/dev/null' EXIT
        trap 'exit 1' INT TERM
        trap '' HUP PIPE
        apply "$2"
        ;;
    state) cat "$STATE" 2>/dev/null || echo IDLE ;;
    *) echo "usage: $0 apply <awg|xray|hy2|byedpi|awg-xray|awg-hy2|awg-byedpi> | state"; exit 2 ;;
esac
