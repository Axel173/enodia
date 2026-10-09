#!/bin/sh
# byedpi-test.sh — ТЕСТЕР стратегий десинка ByeDPI на роутере (аналог тестера Android-приложения
# ByeByeDPI). Прогоняет НАБОР стратегий (курированные пресеты transport-byedpi.sh + текущие свои
# .byedpi-args) против пула доменов ЦЕЛИ и считает, сколько доменов открылось на каждой стратегии.
# CLI-ONLY: вербов/CGI у него нет — человеку в панели показываем ровно ОДИН тест (браузер-свип);
# этот остался инструментом диагностики с роутера.
#
# ЧТО ТЕСТИРУЕМ — ПУЛ ЦЕЛИ; ВШИТЫХ КАТЕГОРИЙ НЕТ. Раньше здесь лежали семь прибитых наборов
# (youtube/discord/social/telegram/general/cloudflare/google) со списками доменов прямо в коде:
# они не были связаны с тем, что РЕАЛЬНО едет через десинк, поэтому таблица мерила чужой трафик, а
# пятый сервис нельзя было добавить без правки скрипта. ЕДИНСТВЕННЫЙ источник пула —
# `slots.sh domains <цель>` (его же читают кандидаты браузер-свипа и карточка Zapret): 0 = основная
# несущая · 2..7 = доп-выход · zapret = общий nfqws. Пуст пул ⇒ тест честно ОТКАЗЫВАЕТСЯ идти.
#
# КАК МЕРЯЕМ (важно понимать ограничение). Поднимаем КАНДИДАТА ciadpi на ОТДЕЛЬНОМ порту 10809
# (боевой, если byedpi активен, слушает 10808 — его НЕ трогаем) и стучимся через него `curl
# --socks5-hostname` (ciadpi сам резолвит и видит, что это TLS → SNI парсится из ЦЕЛОГО
# ClientHello). Это ровно путь тестера приложения: показывает, какая стратегия СПОСОБНА пробить
# DPI. РЕАЛЬНЫЙ трафик дома идёт иначе (через hev, ClientHello приходит кусками — `+s` может
# деградировать; QUIC мы не меряем) → результат теста ИНДИКАТИВНЫЙ, не гарантия. Это честно
# отражено в панели.
#
# ПАРАЛЛЕЛЬНО (иначе тест на десятках доменов был бы слишком долгим). Пробы доменов внутри пула
# запускаем пачками по $T_PARALLEL фоновых curl с `wait` между пачками; на пачку — один таймаут,
# а не суммарный. Настройки (таймаут / запросов на домен / параллельность / пауза) читаются из
# `.byedpi-test.conf` (key=value), с дефолтами и клампом диапазонов.
#
# ПРЯМОЙ ВЫХОД (иначе тест врёт). Egress кандидата ciadpi гоним под nobody (uid 65534) и ставим
# `-m owner --uid-owner 65534 -j RETURN` в mangle OUTPUT → его пакеты идут МИМО маркировки = ПРЯМО
# в WAN, а не через awg0/VPS. Иначе (без owner-RETURN) трафик к заблок-сайтам (они в iplist_set)
# ушёл бы в активный туннель и ВСЕ стратегии «прошли бы» через VPS — тест стал бы бессмысленным.
# Если byedpi сейчас АКТИВЕН, правило owner-RETURN уже стоит (боевое) — мы его НЕ трогаем и НЕ
# снимаем; добавляем/снимаем только СВОЁ (флаг $OWNER_MARK).
#
# БЕЗОПАСНОСТЬ: не трогает активный транспорт/awg-туннель/маршруты — только локальный кандидат на
# 10809 + одно owner-правило для nobody. На любом выходе (trap) кандидат гасится, наше owner-правило
# снимается. Грабли: нет nohup/setsid → фон через start-stop-daemon -b -m -p (запускает CGI).
#
# Использование:
#   byedpi-test.sh run [цель]  — прогнать тест по пулу цели (0 = основная несущая, деф.; 2..7 —
#                                доп-выход; zapret — общий nfqws)
#   byedpi-test.sh stop        — прервать
#   byedpi-test.sh state       — текущее состояние (IDLE|RUNNING n/N|DONE|ERR|STOPPED)
#   byedpi-test.sh config      — эффективные настройки + доступные цели (JSON)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# Тот же bin_path, что у боевого плагина (store-lib.sh): кандидат-ciadpi обязан быть ТЕМ ЖЕ
# бинарём, что понесёт трафик, иначе замер стратегии ни о чём.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Ожидание СТАРТА демона (daemon-lib.sh) — тот же владелец, что у боевого плагина: тест обязан
# ждать бинарь СТОЛЬКО ЖЕ, сколько ждёт несущая, иначе «сервер не поднялся» приезжает от медленного
# накопителя, а не от сервера (замер 448 КБ/с ⇒ 8-МБ xray читается 18 с при пороге 8).
# Нет файла (частичный apply-scripts) — шим повторяет ПРЕЖНИЙ путь: фиксированный срок.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v daemon_wait_port >/dev/null 2>&1 || daemon_wait_port() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0; sleep 1; _dwi=$((_dwi+1)); done
    netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0
    DAEMON_WAIT_WHY="не появился за $3 с"; return 1; }
CIADPI=$(bin_path byedpi)
TPLUGIN="$ENODIA_DIR/transport-byedpi.sh"
TEST_PORT=10809                               # отдельно от боевого 10808
SOCKS=127.0.0.1
BYEDPI_UID=65534                              # nobody — его egress ловит owner-RETURN
PIDF=/tmp/enodia-byedpi-test-ciadpi.pid       # pid кандидата ciadpi (НЕ боевого, НЕ run-процесса)
STATE="$ENODIA_STATE/.byedpi-test.state"
RESULT="$ENODIA_STATE/.byedpi-test.json"
CONF="$ENODIA_STATE/.byedpi-test.conf"        # настройки теста (пишет панель: key=value)
LOG=/tmp/enodia-byedpi-test-run.log
RES_DIR=/tmp/enodia-byedpi-test-res           # временные файлы проб (1/0 на пробу)
OWNER_MARK=/tmp/enodia-byedpi-test.owneradded # есть файл = owner-RETURN добавили МЫ (снять на выходе)
POOL_FILE=/tmp/enodia-byedpi-test-pool.lst    # пул доменов ЦЕЛИ (наполняет build_pool)
POOL_CAP=24                                   # кап доменов в пуле (тест по сотням был бы неприлично долгим)
TARGET=0                                      # цель теста: 0 | 2..7 | zapret (ставит run)
TARGET_LABEL=""                               # подпись столбца/цели (ставит build_pool)

# Дефолты настроек (перекрываются .byedpi-test.conf). Диапазоны — как в приложении.
T_TIMEOUT=5      # таймаут запроса, сек (1..15)
T_REQUESTS=1     # запросов на домен (1..20)
T_PARALLEL=8     # одновременных проб (1..50)
T_DELAY=0        # пауза между стратегиями, сек (0..10)

log() { echo "$*" >> "$LOG" 2>/dev/null; }

# --- ЦЕЛЬ и её пул ---------------------------------------------------------------------------
# Метка цели — только для подписи столбца и лога. Имена доп-выходов НЕ тянем: `slots.sh list-json`
# ради одной подписи — лишний форк, а номер выхода человек и так видит в панели.
target_label() {
    case "$1" in
        0)      echo "Основной десинк" ;;
        zapret) echo "Zapret (nfqws)" ;;
        *)      echo "Выход №$1" ;;
    esac
}
target_known() {
    case "$1" in
        0|[2-7]|zapret) return 0 ;;
        *) return 1 ;;
    esac
}
pool() { cat "$POOL_FILE" 2>/dev/null; }

# --- Пул ЦЕЛИ: ДОМЕНЫ, которые через неё реально едут. Своей копии сбора здесь НЕТ — единственный
# источник истины `slots.sh domains <цель> <кап>` (он же кормит кандидатов браузер-свипа и карточку
# Zapret; две реализации разъезжались бы на первой же правке модели привязок). Пишет $POOL_FILE,
# echo — число доменов. ------------------------------------------------------------------------
# ВАЖНО: метку цели ставит ВЫЗЫВАЮЩИЙ (см. run) — здесь присваивать нельзя, функция бежит в `$(...)`,
# то есть в ПОДШЕЛЛЕ, и переменная в родителя не доезжает (сообщение об отказе выходило «через «»»).
build_pool() {
    sh "$ENODIA_DIR/slots.sh" domains "$1" "$POOL_CAP" 2>/dev/null > "$POOL_FILE"
    _n=$(wc -l < "$POOL_FILE" 2>/dev/null | tr -d ' '); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    echo "$_n"
}

# --- Настройки: читаем .byedpi-test.conf (key=value), кламп диапазонов, фильтр категорий. -----
clamp() {  # clamp <val> <min> <max> <default>
    v="$1"; case "$v" in ''|*[!0-9]*) v="$4" ;; esac
    [ "$v" -lt "$2" ] && v="$2"; [ "$v" -gt "$3" ] && v="$3"; echo "$v"
}
load_conf() {
    if [ -s "$CONF" ]; then
        while IFS='=' read -r k v; do
            # Режем ТОЛЬКО CR/NL глобально, пробелы — точечно в числовых полях (ключ `cats=` от
            # старых установок молча игнорируем: набор проб теперь задаёт ЦЕЛЬ, а не список).
            v=$(printf '%s' "$v" | tr -d '\r\n')
            case "$k" in
                timeout)  T_TIMEOUT=$(printf '%s' "$v" | tr -d ' ') ;;
                requests) T_REQUESTS=$(printf '%s' "$v" | tr -d ' ') ;;
                parallel) T_PARALLEL=$(printf '%s' "$v" | tr -d ' ') ;;
                delay)    T_DELAY=$(printf '%s' "$v" | tr -d ' ') ;;
            esac
        done < "$CONF"
    fi
    T_TIMEOUT=$(clamp "$T_TIMEOUT" 1 15 5)
    T_REQUESTS=$(clamp "$T_REQUESTS" 1 20 1)
    T_PARALLEL=$(clamp "$T_PARALLEL" 1 50 8)
    T_DELAY=$(clamp "$T_DELAY" 0 10 0)
}

cleanup() {
    start-stop-daemon -K -p "$PIDF" 2>/dev/null
    if [ -f "$OWNER_MARK" ]; then
        # Снять owner-RETURN, который добавили МЫ — но РОВНО ОДНУ копию и ТОЛЬКО если byedpi сейчас
        # НЕ активный транспорт. Правило `-m owner --uid-owner 65534 -j RETURN` ОБЩЕЕ (по uid nobody):
        # если во время теста пользователь включил боевой byedpi, тот полагается на ТО ЖЕ правило.
        # Прежний while-цикл `-D пока -C` снёс бы ВСЕ копии (в т.ч. боевую) → live-ciadpi без анти-петли,
        # его egress маркируется в table 1000 = блэкхол. Теперь: byedpi активен → правило оставляем ему.
        if [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" != byedpi ]; then
            iptables -t mangle -D OUTPUT -m owner --uid-owner "$BYEDPI_UID" -j RETURN 2>/dev/null
        fi
        rm -f "$OWNER_MARK" 2>/dev/null   # НЕ `find -delete`: такой опции у busybox нет — см. C39
    fi
    rm -rf "$RES_DIR" 2>/dev/null
}

# owner-RETURN: добавить, только если его ещё нет. Если уже стоит (boевой byedpi) — НЕ наше,
# не помечаем $OWNER_MARK → не снимем на выходе.
ensure_owner() {
    iptables -t mangle -C OUTPUT -m owner --uid-owner "$BYEDPI_UID" -j RETURN 2>/dev/null && return 0
    iptables -t mangle -I OUTPUT 1 -m owner --uid-owner "$BYEDPI_UID" -j RETURN && : > "$OWNER_MARK"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# поднять кандидата ciadpi на тест-порту с данными args ($1). 0 = слушает, 1 = не поднялся.
spawn() {
    start-stop-daemon -K -p "$PIDF" 2>/dev/null; sleep 1
    start-stop-daemon -S -b -c nobody -m -p "$PIDF" -x /bin/sh -- -c "exec '$CIADPI' -i $SOCKS -p $TEST_PORT $1 >/dev/null 2>&1"
    # Ждём порт, пока жив процесс (daemon-lib.sh): тот же владелец, что у боевого плагина.
    daemon_wait_port "$PIDF" byedpi 8 "$SOCKS" "$TEST_PORT"
}

# одна проба домена ($1) через кандидата → пишет 1 (открылся) / 0 в файл $2.
probe() {
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$T_TIMEOUT" --connect-timeout 4 \
        --socks5-hostname "$SOCKS:$TEST_PORT" "https://$1" 2>/dev/null)
    case "$code" in 2*|3*) echo 1 > "$2" ;; *) echo 0 > "$2" ;; esac
}

# прогнать пул цели ПАРАЛЛЕЛЬНО пачками по $T_PARALLEL. echo — число открывшихся проб.
run_pool() {
    rm -rf "$RES_DIR"; mkdir -p "$RES_DIR"
    idx=0; j=0
    for dom in $(pool); do
        r=1
        while [ "$r" -le "$T_REQUESTS" ]; do
            probe "$dom" "$RES_DIR/$idx" &
            idx=$((idx+1)); j=$((j+1))
            [ "$j" -ge "$T_PARALLEL" ] && { wait; j=0; }
            r=$((r+1))
        done
    done
    wait
    # каждый файл = "0"/"1"; считаем единицы (tr -cd '1' оставляет только '1', wc -c их число)
    ok=$(cat "$RES_DIR"/* 2>/dev/null | tr -cd '1' | wc -c)
    case "$ok" in ''|*[!0-9]*) ok=0 ;; esac
    echo "$ok"
}

# максимум проб (домены × запросов-на-домен) — знаменатель «X/N».
pool_max() { n=$(pool | wc -l); echo $((n * T_REQUESTS)); }

run() {
    TARGET="${1:-0}"   # цель: 0 = основная несущая (деф.) | 2..7 = доп-выход | zapret = общий nfqws
    # Трапы ставим ТОЛЬКО в run (иначе state/stop чистили бы чужой запущенный тест). На сигнал —
    # ВЫХОДИМ (`exit`), а не просто чистим: иначе sh после хендлера ПРОДОЛЖИЛ БЫ цикл (трап не
    # прерывает выполнение) → run спаунил бы следующего кандидата и затирал STATE уже после stop.
    trap 'cleanup' EXIT
    trap 'exit 143' INT TERM
    [ -x "$CIADPI" ] || { echo ERR > "$STATE"; : > "$LOG"; log "нет бинаря ciadpi — установите набор с ByeDPI"; return 1; }
    target_known "$TARGET" || { echo ERR > "$STATE"; : > "$LOG"; log "неизвестная цель «$TARGET» (0|2..7|zapret)"; return 1; }
    load_conf
    : > "$LOG"; echo RUNNING > "$STATE"
    # Пул ЦЕЛИ — единственный источник проб. Пусто ⇒ ОТКАЗ, а не фолбэк на «общеизвестные сайты»:
    # гонять два десятка стратегий по доменам, которые через эту цель не едут, — значит мерить чужой
    # трафик и объявить победителя наугад (ровно то, чем грешила прежняя вшитая таблица категорий).
    TARGET_LABEL=$(target_label "$TARGET")
    _np=$(build_pool "$TARGET")
    case "$_np" in ''|0|*[!0-9]*)
        echo ERR > "$STATE"
        log "через «$TARGET_LABEL» по доменам ничего не едет — заведите доменное правило, группу или доменный гео-сервис для этой цели"
        return 1 ;;
    esac
    log "цель «$TARGET_LABEL»: $_np доменов (кап $POOL_CAP)"
    # Обнуляем прошлый результат СРАЗУ — иначе читатель увидел бы СТАРУЮ таблицу (счёт от прошлого
    # прогона), пока не доедет первый кандидат. Пустой файл → result:null, таблица чистится.
    : > "$RESULT"

    # шапка: ОДНА колонка — пул цели. Формат {k,l,n} сохранён (его понимает прежний парсер JSON).
    total_max=$(pool_max)
    cats_json="{\"k\":\"$(json_escape "$TARGET")\",\"l\":\"$(json_escape "$TARGET_LABEL")\",\"n\":$total_max}"
    log "макс проб: $total_max; timeout=$T_TIMEOUT requests=$T_REQUESTS parallel=$T_PARALLEL delay=$T_DELAY"
    ensure_owner

    TAB=$(printf '\t')
    # пресет «Авто» идёт с пустыми args = «использовать авто-набор»; для теста подставляем РЕАЛЬНЫЙ
    # авто-набор (DEFAULT_ARGS), иначе мерили бы голый релей без десинка.
    defargs=$(sh "$TPLUGIN" defaults 2>/dev/null)
    # кандидаты: пресеты (label|args) + текущие свои .byedpi-args (если заданы и не дублируют)
    cand=/tmp/enodia-byedpi-test-cand.lst; : > "$cand"
    sh "$TPLUGIN" presets 2>/dev/null | while IFS='|' read -r lbl args; do
        [ -z "$args" ] && args="$defargs"
        [ -n "$lbl" ] && printf '%s%s%s\n' "$lbl" "$TAB" "$args" >> "$cand"
    done
    # «Текущие свои» — стратегия ТОГО, что тестируем: в режиме пула это .byedpi-args-s<id> выхода
    # (у него свой ciadpi), иначе общая .byedpi-args. Иначе таблица сравнивала бы кандидатов с
    # чужой стратегией и «Текущая» подсвечивалась бы не там.
    _cf="$ENODIA_STATE/.byedpi-args"
    case "$TARGET" in [2-7]) _cf="$ENODIA_STATE/.byedpi-args-s$TARGET" ;; esac
    cust=$(grep -vE '^[[:space:]]*#' "$_cf" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
    if [ -n "$cust" ] && ! grep -qF "$TAB$cust" "$cand"; then
        printf 'Текущие свои%s%s\n' "$TAB" "$cust" >> "$cand"
    fi
    total=$(wc -l < "$cand" 2>/dev/null); case "$total" in ''|*[!0-9]*) total=0 ;; esac

    out="$RESULT.new"
    # slot — ЧЕЙ пул тестировали: по нему решается, куда ляжет применение (стратегия доп-выхода или
    # общая). `zapret` слотом не является (nfqws один на очередь 212, пер-слот стратегии нет) ⇒ в
    # числовое поле кладём 0, а саму цель дублируем строкой `target` — %d на «zapret» сорвал бы JSON.
    _sn="$TARGET"; case "$_sn" in ''|*[!0-9]*) _sn=0 ;; esac
    printf '{"slot":%d,"target":"%s","cats":[%s],"max":%d,"results":[' \
        "$_sn" "$(json_escape "$TARGET")" "$cats_json" "$total_max" > "$out"

    n=0; rfirst=1
    while IFS="$TAB" read -r lbl args; do
        n=$((n+1))
        # Имя текущей стратегии — В STATE (после `n/total`), чтобы панель показывала «сейчас
        # проверяю: <label>», а не только цифры. Фронт парсит `RUNNING n/N <label>` регуляркой.
        echo "RUNNING $n/$total $lbl" > "$STATE"
        log "[$n/$total] $lbl  ($args)"
        tot=0; per=0
        if spawn "$args"; then
            tot=$(run_pool); per="$tot"
            log "    $TARGET_LABEL -> $tot"
        else
            log "    ciadpi не поднялся (пропуск)"
        fi
        start-stop-daemon -K -p "$PIDF" 2>/dev/null
        [ $rfirst -eq 1 ] && rfirst=0 || printf ',' >> "$out"
        printf '{"label":"%s","args":"%s","total":%d,"per":[%s]}' \
            "$(json_escape "$lbl")" "$(json_escape "$args")" "$tot" "$per" >> "$out"
        # ПРОГРЕССИВНЫЙ снимок: дописываем закрывающие скобки в копию и атомарно публикуем в RESULT
        # → панель видит таблицу, заполняющуюся ПО ХОДУ теста (уже проверенные стратегии со счётом),
        # а не пустоту до самого конца. Финальный mv ниже перезапишет тем же контентом.
        { cat "$out"; printf ']}'; } > "$RESULT.tmp" 2>/dev/null && mv "$RESULT.tmp" "$RESULT" 2>/dev/null
        log "  итог: $tot/$total_max"
        [ "$T_DELAY" -gt 0 ] && sleep "$T_DELAY"
    done < "$cand"

    printf ']}' >> "$out"
    mv "$out" "$RESULT"
    rm -f "$cand" 2>/dev/null             # НЕ `find -delete`: такой опции у busybox нет — см. C39
    echo DONE > "$STATE"
    log "готово: проверено $total стратегий, max $total_max проб"
    # cleanup вызовет EXIT-trap (owner-RETURN снимется, кандидат погаснет)
}

# config — эффективные настройки + доступные ЦЕЛИ с размером пула. `n` считаем ФАКТОМ (тем же
# `slots.sh domains`, что и сам прогон): по цели с n=0 тест откажется идти, и знать это лучше ДО
# запуска. Пять форков на CLI-верб приемлемы — в горячем пути его нет.
emit_config() {
    load_conf
    av=""
    for t in 0 2 3 4 5 6 7 zapret; do
        _n=$(sh "$ENODIA_DIR/slots.sh" domains "$t" "$POOL_CAP" 2>/dev/null | wc -l | tr -d ' ')
        case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
        av="$av${av:+,}{\"k\":\"$t\",\"l\":\"$(json_escape "$(target_label "$t")")\",\"n\":$_n}"
    done
    printf '{"timeout":%d,"requests":%d,"parallel":%d,"delay":%d,"targets":[%s]}\n' \
        "$T_TIMEOUT" "$T_REQUESTS" "$T_PARALLEL" "$T_DELAY" "$av"
}

case "$1" in
    run)   run "$2" ;;
    stop)
        # сигналим run-процессу и ЖДЁМ его смерти (он в curl до ~таймаута) — иначе его EXIT-trap/
        # итерация затёрли бы STOPPED уже после нас. Потом добиваем кандидата (belt) и фиксируем.
        start-stop-daemon -K -p /tmp/enodia-byedpi-test.pid 2>/dev/null
        i=0; while [ $i -lt 12 ]; do p=$(cat /tmp/enodia-byedpi-test.pid 2>/dev/null | tr -d ' \r\n'); { [ -n "$p" ] && kill -0 "$p" 2>/dev/null; } || break; sleep 1; i=$((i+1)); done
        cleanup; echo STOPPED > "$STATE"; log "прервано пользователем" ;;
    state) cat "$STATE" 2>/dev/null || echo IDLE ;;
    config) emit_config ;;
    *) echo "usage: $0 run [0|2..7|zapret]|stop|state|config"; exit 2 ;;
esac
