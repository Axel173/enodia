#!/bin/sh
# support.sh — «РЕЖИМ ПОДДЕРЖКИ»: временный удалённый доступ разработчику к роутеру тестера.
#
# ИДЕЯ. Тестер кнопкой в веб-панели открывает разработчику ВРЕМЕННЫЙ SSH-доступ к
# своему роутеру для живой отладки, когда сам баг не находит. Механизм — ОБРАТНЫЙ SSH-туннель
# от роутера НАРУЖУ на подконтрольный VPS-релей: роутер сам инициирует исходящее соединение
# (`dbclient -N -R`), поэтому пробивает CGNAT/NAT тестера, а поверхность доступа = SSH роутера
# (:22, dropbear) — из одного SSH достаётся всё (панель :8088 локальным форвардом, дамп, консоль).
#
# ТОПОЛОГИЯ (единственное ИСХОДЯЩЕЕ соединение по инициативе тестера):
#   роутер тестера                 релей (VPS разработчика)      разработчик
#     dbclient -N -R  ──SSH,наружу─►  sshd, юзер `support`
#      127.0.0.1:PORT ◄─loopback-bind─ 127.0.0.1:PORT ◄─ssh -J─  ssh -J support@relay -p PORT root@127.0.0.1
#      :22 (dropbear)                  (GatewayPorts no)
#   Форвард биндится на LOOPBACK релея (не на публичный интерфейс) → снаружи релея не виден.
#   Внутренний SSH-хендшейк E2E между клиентом разработчика и dropbear роутера → релей видит только
#   ШИФРТЕКСТ, root-пароль роутера туда НЕ утекает.
#
# БЕЗОПАСНОСТЬ (инварианты). OFF по умолчанию; opt-in кнопкой; авто-экспайр (деф. 30 мин, cap 2 ч);
# ручной kill; смерть на ребуте (всё рантайм-состояние в /tmp = RAM). НЕ авто-резюмится на буте —
# для анти-цензурного инструмента удалённый доступ чувствителен, поэтому НЕ трогаем heal.sh.
# Двухфакторность: даже завладев support-креденшелом релея, атакующий получит лишь loopback-форвард;
# чтобы дойти до роутера, нужно (а) чтобы тестер был В режиме поддержки и (б) знать root-пароль роутера.
#
# АУТЕНТИФИКАЦИЯ — ТОЛЬКО ПО КЛЮЧУ. dbclient (dropbear v2017.75) на стоке BE7000 собран БЕЗ клиентской
# ПАРОЛЬНОЙ auth (usage без password; DROPBEAR_PASSWORD игнорируется → «exited: Interrupted» — проверено
# на железе 2026-07-12). Поэтому «код поддержки» несёт САМ ПРИВАТНЫЙ dropbear-КЛЮЧ (base64 внутри кода),
# а не пароль. Два источника ключа (DRY, без флагов):
#   * ключ ИЗ КОДА (ОСН.) — open-code декодирует ключ из base64-кода во временный $CODEKEY (RAM, 0600) →
#                     `dbclient -i $CODEKEY`. ЕДИНЫЙ путь веб-панели, одинаково на приватной и широкой
#                     сборке (разработчик тестирует РОВНО то же, что тестер). Ключ лежит в RAM ПОКА ЖИВА
#                     СЕССИЯ (не «до старта dbclient», как было): без него невозможен переподъём после
#                     разрыва (см. reup), а разрыв даёт любой ct_flush. Стирает cmd_down — руками, по
#                     TTL из reap или ребутом (/tmp = RAM).
#   * стоячий $KEY (ФОЛБЭК) — нет ключа из кода, но есть $KEY (0600) → `dbclient -i $KEY`. Только для
#                     голого CLI `support.sh up` без кода (аварийный заход для себя); панель им НЕ ходит.
#   Координаты релея (IP+порт, НЕ секрет) — в $RELAY_CONF (провижнятся кодом/set-relay).
#
# ГРАБЛИ (busybox / это железо — см. карту проекта):
#   * НЕТ nohup/setsid → фон через `start-stop-daemon -S -b -m -p` (как плагины-транспорты).
#   * Релей ТОЛЬКО по IP-литералу — при сломанном туннеле dnsmasq мёртв (DNS-SPOF), имя не резолвится.
#   * ПЕТЛЯ endpoint-в-iplist: IP релея может быть ∈ iplist_set → без прямого-пути guard'а туннель
#     завернётся в VPN (петля, если awg0 жив; не встанет, если мёртв). Guard ОБЯЗАТЕЛЕН (см. cmd_up).
#   * NSS/ECM-offload: после mangle-guard нужен conntrack -D по потоку, иначе старый маршрут залипнет.
#   * `-y -y` — не проверять host key релея (внешний хоп транзиентен; E2E к роутеру защищён его же
#     ключом, который верифицирует ssh-клиент разработчика). known_hosts на ramfs всё равно сбрасывается.
#   * `timeout -t СЕК CMD` (старый синтаксис) — срок сессии держит им сам dbclient (tunnel_spawn): сторожа после деактивации нет.
#
# Контракт (как у transport-*.sh — DRY):
#   support.sh up [ttl]      — открыть доступ (ttl сек, деф. 1800, cap 7200); печатает статус
#   support.sh down          — закрыть доступ (убить туннель, снять guard, стереть состояние)
#   support.sh status        — JSON {active,port,expires_in,ttl} для панели
#   support.sh reap          — экспайр/сборка мусора (зовёт watchdog.sh cron */2; сам себя гасит)
#   support.sh reup          — переподнять упавший туннель, пока сессия жива (внутри reap; см. ниже)
#   support.sh set-relay IP PORT [USER]  — записать координаты релея в $RELAY_CONF (деплой/тест)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# Имя WAN-интерфейса — у владельца (ip-lib.sh::wan_iface, следит C81): его спрашивает гейт «WAN
# жив?» ниже. Шим = прежняя строка на случай частичной установки.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }
if ! command -v ct_flush_dst >/dev/null 2>&1; then
    ct_flush_dst()  { [ -n "$1" ] && conntrack -D -p tcp -d "$1" --dport "$2" >/dev/null 2>&1; return 0; }
fi
RELAY_CONF="$ENODIA_STATE/.support-relay" # "IP PORT [USER]" — координаты релея (НЕ секрет)
KEY="$ENODIA_STATE/.support-key"          # стоячий приватный ключ (0600), фолбэк для голого CLI `up`
CODEKEY=/tmp/.enodia-support-code-key     # приватный ключ, доставленный «кодом поддержки» (RAM, 0600, транзитный)
PIDFILE=/tmp/enodia-support-tunnel.pid
LOG=/tmp/enodia-support.log
ACTIVE=/tmp/.enodia-support-active        # рантайм: "PORT EXPIRE_EPOCH RELAY_IP RELAY_PORT" (RAM)
FWMARK=0x1
TABLE=1000
TTL_DEF=1800                              # 30 мин по умолчанию
TTL_CAP=7200                              # жёсткий потолок 2 ч
PORT_LO=20000
PORT_HI=39999

log() { echo "[$(date '+%H:%M:%S' 2>/dev/null)] $*" >> "$LOG" 2>/dev/null; }

# Пустой/0-байтовый пидфайл = НЕ жив (busybox `kill -0 ""` возвращает 0 → ложное «жив»). Зеркало плагинов.
# ВАЖНО: внутренняя переменная — `_ap` (НЕ `p`): busybox sh без `local`, а cmd_up держит порт в `$pt`;
# раньше internal `p` затирал бы его (баг: в статус попадал PID вместо порта туннеля). Держим имя редким.
proc_alive() { _ap=$(cat "$1" 2>/dev/null | tr -d ' \r\n'); [ -n "$_ap" ] && kill -0 "$_ap" 2>/dev/null; }

# WAN жив? Ответ ОДИН на проект — ip-lib.sh::wan_up (сорсится выше; следит C81). Зеркало сторожа
# тут стояло с пометкой DRY: сорсить watchdog.sh нельзя (он прогонит весь тик), и копия честно
# называла себя копией — а расходиться ей нельзя тем более, «жив ли аплинк» спрашивают ровно в
# аварии. Ниже шим на случай старой библиотеки: нет дефолта / carrier=0 → туннелю некуда идти.
command -v wan_up >/dev/null 2>&1 || wan_up() { _wu=$(wan_iface); [ -n "$_wu" ] || return 1; if [ -r "/sys/class/net/$_wu/carrier" ]; then [ "$(cat "/sys/class/net/$_wu/carrier" 2>/dev/null)" = "1" ] || return 1; fi; return 0; }

# Прочитать координаты релея. Заполняет RELAY_IP/RELAY_PORT/RELAY_USER; 1 = не настроено/битое.
load_relay() {
    [ -s "$RELAY_CONF" ] || { log "релей не настроен ($RELAY_CONF нет) — see set-relay"; return 1; }
    read -r RELAY_IP RELAY_PORT RELAY_USER _rest < "$RELAY_CONF"
    [ -n "$RELAY_USER" ] || RELAY_USER=support
    echo "$RELAY_IP"   | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { log "релей: IP '$RELAY_IP' не литерал (нужен IPv4, не имя — dnsmasq-SPOF)"; return 1; }
    case "$RELAY_PORT" in ''|*[!0-9]*) log "релей: порт '$RELAY_PORT' не число"; return 1 ;; esac
    return 0
}

# --- прямой-путь guard: трафик туннеля к релею ВСЕГДА мимо VPN --------------------
# ЗАЧЕМ. Support должен работать РОВНО когда VPN сломан (тогда тестер и зовёт на помощь). Если
# пакеты к релею пойдут через маркировку в table $TABLE → в дохлый awg0 = туннель не встанет; а
# если IP релея ∈ iplist_set и awg0 жив — свои же пакеты к релею заворачиваются в VPN = ПЕТЛЯ
# (класс бага endpoint-в-iplist). Выводим router-локальный поток к релею из mangle OUTPUT РАНЬШЕ
# MARK (по образцу SMTP notify-guard в mark-core.sh), но ДИНАМИЧЕСКИ на IP:порт релея и БЕЗ персиста
# (support транзиентен; НЕ через apply-bypass, тот пишет на /data). -j ACCEPT, НЕ RETURN (в mangle
# RETURN не спасает от последующего MARK). Идемпотентно (delete-loop → -I 1). conntrack -D по потоку
# (NSS-offload держит старый путь). На down guard снимаем.
guard_on() {
    while iptables -t mangle -D OUTPUT -d "$RELAY_IP" -p tcp --dport "$RELAY_PORT" -j ACCEPT 2>/dev/null; do :; done
    iptables -t mangle -I OUTPUT 1 -d "$RELAY_IP" -p tcp --dport "$RELAY_PORT" -j ACCEPT 2>/dev/null
    ct_flush_dst "$RELAY_IP" "$RELAY_PORT"
    log "guard: трафик к релею $RELAY_IP:$RELAY_PORT мимо VPN (прямой путь)"
}
guard_off() {
    _ip="$1"; _pt="$2"
    [ -n "$_ip" ] && [ -n "$_pt" ] || return 0
    while iptables -t mangle -D OUTPUT -d "$_ip" -p tcp --dport "$_pt" -j ACCEPT 2>/dev/null; do :; done
    ct_flush_dst "$_ip" "$_pt"
}
# Гард НА МЕСТЕ? Отдельной проверкой, потому что зовёт её ТИК СТОРОЖА: `guard_on` идемпотентен,
# но каждый раз пишет строку в лог и трогает conntrack — раз в две минуты это шум и работа впустую.
# А проверять надо: `mark-core.sh` пересобирает mangle OUTPUT ЦЕЛИКОМ (switch транспорта, repair
# после fw3 reload) и уносит наш ACCEPT вместе с чужими правилами — гард ставится ВНЕ ядра.
guard_check() {
    [ -n "$1" ] && [ -n "$2" ] || return 1
    iptables -t mangle -C OUTPUT -d "$1" -p tcp --dport "$2" -j ACCEPT 2>/dev/null
}

# Случайный порт релея (busybox awk есть rand/srand; /dev/urandom без od не распарсить).
rand_port() { awk "BEGIN{srand(); print $PORT_LO+int(rand()*($PORT_HI-$PORT_LO+1))}"; }

# dbclient поддерживает `-o OPT`? (usage печатается на пустой вызов). Если да — добавим
# ExitOnForwardFailure=yes, чтобы dbclient ВЫШЕЛ при неудачном remote-bind (иначе висит «живой»
# с нерабочим форвардом → ложный успех). Первичная защита от коллизии — широкий рандом-диапазон.
eof_opt() {
    if dbclient 2>&1 | grep -q -- '-o '; then echo '-o ExitOnForwardFailure=yes'; fi
}

# Ключ для dbclient → $AUTH. Приоритет — ключ ИЗ КОДА, стоячий $KEY — фолбэк; 1 = креда нет вовсе.
# ЗАЧЕМ функцией, а не строками в cmd_up: спрашивают ДВОЕ — открытие доступа и ПЕРЕПОДЪЁМ из
# сторожа. У второго нет ни `$SUPPORT_KEY_FILE` (то env одного вызова open-code), ни человека,
# который введёт код заново, — поэтому ключ из кода ищется и ПО ПУТИ ($CODEKEY), пока жива сессия.
auth_opt() {
    AUTH=""
    if [ -n "$SUPPORT_KEY_FILE" ] && [ -r "$SUPPORT_KEY_FILE" ]; then AUTH="-i $SUPPORT_KEY_FILE"; return 0; fi
    if [ -r "$CODEKEY" ]; then AUTH="-i $CODEKEY"; return 0; fi
    if [ -r "$KEY" ]; then AUTH="-i $KEY"; return 0; fi
    return 1
}

# Поднять dbclient В ФОНЕ и записать $ACTIVE. $1 = предпочтительный порт (пусто → случайный),
# $2 = момент истечения (epoch), $3 = сколько попыток. Успех: 0 и $port = живой порт.
# ЗАЧЕМ отдельной функцией: подъём нужен ДВУМ вызывателям с РАЗНОЙ политикой. Открытие доступа —
# три попытки, порт каждый раз новый (коллизия на релее). Переподъём из сторожа — две попытки за
# тик (тик не имеет права стоять девять секунд), и ПЕРВАЯ на ПРЕЖНЕМ порту: человек уже
# подключается по нему, смена порта с его стороны неотличима от «доступ пропал».
tunnel_spawn() {
    _tsp="$1"; _tse="$2"; _tsn="$3"; case "$_tsn" in ''|*[!0-9]*) _tsn=1 ;; esac
    _eo=$(eof_opt)
    port=""; _tsi=0
    while [ "$_tsi" -lt "$_tsn" ]; do
        _tsi=$((_tsi+1))
        # pt (НЕ p): proc_alive внутри трогает свою переменную — не путать с портом.
        if [ "$_tsi" = 1 ] && [ -n "$_tsp" ]; then pt="$_tsp"; else pt=$(rand_port); fi
        log "попытка $_tsi: порт $pt → dbclient -R 127.0.0.1:$pt:127.0.0.1:22 к $RELAY_USER@$RELAY_IP:$RELAY_PORT"
        # sh -c 'exec … >>log' — переоткрыть stdio ПОСЛЕ демонизации (start-stop-daemon -b уводит в
        # /dev/null), сохранив PID для pidfile (как spawn_hysteria). -y -y = не проверять host key релея.
        # СРОК ДЕРЖИТ САМ ТУННЕЛЬ, А НЕ ТОЛЬКО СТОРОЖ (ревью шага 6d): `reap` зовёт тик сторожа, а после деактивации его cron-строки нет
        # — сессия не истекала бы до ребута при обещании «закроется сам». busybox `timeout -t` запускает программу В ТОМ ЖЕ pid (свой
        # сторож — дочерним процессом; замер BE7000 23.09.2026), поэтому пидфайл остаётся пидом dbclient. Нет `timeout -t` — как раньше.
        _tsl=$(( _tse - $(date +%s) )); _tst=""
        [ "$_tsl" -gt 0 ] && timeout -t 1 true >/dev/null 2>&1 && _tst="timeout -t $_tsl "
        start-stop-daemon -S -b -m -p "$PIDFILE" -x /bin/sh -- -c \
            "exec ${_tst}dbclient -N -y -y -K 30 $_eo $AUTH -R 127.0.0.1:$pt:127.0.0.1:22 -p $RELAY_PORT $RELAY_USER@$RELAY_IP >>'$LOG' 2>&1"
        sleep 3
        if proc_alive "$PIDFILE"; then
            port="$pt"
            printf '%s %s %s %s\n' "$port" "$_tse" "$RELAY_IP" "$RELAY_PORT" > "$ACTIVE"
            return 0
        fi
        log "попытка $_tsi: dbclient умер за 3с (порт занят / кред / сеть)"
        start-stop-daemon -K -p "$PIDFILE" >/dev/null 2>&1; rm -f "$PIDFILE" 2>/dev/null
    done
    return 1
}

# Тихо снести прошлый экземпляр (идемпотентный up): убить демон, снять guard по записи ACTIVE.
teardown() {
    start-stop-daemon -K -p "$PIDFILE" >/dev/null 2>&1
    if [ -s "$ACTIVE" ]; then
        read -r _p _e _gip _gpt _r < "$ACTIVE"
        guard_off "$_gip" "$_gpt"
    fi
    rm -f "$PIDFILE" "$ACTIVE" 2>/dev/null
}

cmd_up() {
    ttl="$1"; case "$ttl" in ''|*[!0-9]*) ttl=$TTL_DEF ;; esac
    [ "$ttl" -gt "$TTL_CAP" ] && ttl=$TTL_CAP
    [ "$ttl" -lt 60 ] && ttl=60

    load_relay || { echo '{"active":0,"error":"relay-unset"}'; return 1; }

    # Аутентификация ТОЛЬКО по ключу (dbclient без парольной auth) — владелец ответа один, auth_opt.
    auth_opt || {
        log "нет ключа из кода и нет $KEY — открыть доступ нечем"
        echo '{"active":0,"error":"no-credential"}'; return 1
    }

    # Сессии не случилось — ключу из кода жить незачем (тот же довод, что у `tunnel-failed` ниже).
    wan_up || { log "WAN мёртв — туннелю некуда идти"; rm -f "$CODEKEY" 2>/dev/null; echo '{"active":0,"error":"wan-down"}'; return 1; }

    : > "$LOG" 2>/dev/null || true
    teardown                          # снять прошлый экземпляр (идемпотентно)
    guard_on                          # прямой путь к релею ДО подъёма туннеля

    expire=$(( $(date +%s) + ttl ))
    # Ключ из кода ОСТАВЛЯЕМ в $CODEKEY на время сессии (RAM, 0600), а не стираем сразу после
    # старта dbclient, как было. ЗАЧЕМ: соединение рвёт ЛЮБОЙ ct_flush (switch транспорта = два
    # подряд), а `dbclient -N` переподключаться не умеет — переподъём из сторожа без ключа
    # невозможен, и режим поддержки гас ровно на том действии, ради разбора которого его
    # открывали (замерено вживую 01.09.2026). Секрет живёт не дольше сессии: его сносит cmd_down
    # (в том числе по TTL из reap), а /tmp пуст после ребута.
    if ! tunnel_spawn "" "$expire" 3; then
        guard_off "$RELAY_IP" "$RELAY_PORT"
        # Сессии не случилось ⇒ ключу из кода жить незачем: держим его в RAM РОВНО пока есть что
        # переподнимать. Иначе неудачная попытка оставляла бы секрет лежать до самого ребута.
        rm -f "$CODEKEY" 2>/dev/null
        log "туннель не поднялся за 3 попытки — см. лог выше"
        echo '{"active":0,"error":"tunnel-failed"}'; return 1
    fi

    log "ДОСТУП ОТКРЫТ: порт $port, истекает через ${ttl}с. Заходить: ssh -J $RELAY_USER@$RELAY_IP -p $port root@127.0.0.1"
    cmd_status
}

# ПЕРЕПОДЪЁМ упавшего туннеля, пока сессия не истекла. Зовёт тик сторожа (через reap).
# ЗАЧЕМ. Доступ держится на ОДНОМ долгоживущем исходящем TCP, а его рвёт любой сброс conntrack:
# `transport.sh switch` зовёт ct_flush ДВАЖДЫ (down старого + up нового), и на BE7000 это
# `conntrack -F` — вся таблица. `dbclient -N` не переподключается вовсе, поэтому доступ гас
# ровно на том действии, ради разбора которого его открывали. Гард маршрута тут не спасает: он
# защищает МАРШРУТ (релей мимо маркировки), а рвётся СОЕДИНЕНИЕ — разные вопросы.
# Судим по ФАКТУ (`proc_alive`), а не по флагу: живая запись $ACTIVE — это НАМЕРЕНИЕ человека
# «доступ открыт до такого-то времени», а жив ли туннель, знает только процесс.
# ДВЕ попытки за вызов, и вторая — СО СЛУЧАЙНЫМ портом. Одной было бы мало: прежний порт на релее
# может быть ещё занят полумёртвым форвардом, и тик за тиком мы ломились бы в него вечно (ACTIVE
# помнит только его). Три, как при открытии, тоже нельзя — тик сторожа не имеет права стоять
# девять секунд. Первая попытка всегда на ПРЕЖНЕМ порту: по нему уже подключается человек.
cmd_reup() {
    [ -s "$ACTIVE" ] || return 0          # доступ не открыт — не наше дело (штатный no-op после ребута)
    read -r _rp _re _rip _rpt _rr < "$ACTIVE"
    case "$_re" in ''|*[!0-9]*) _re=0 ;; esac
    _rnow=$(date +%s)
    [ "$_rnow" -ge "$_re" ] && return 1   # TTL истёк — поднимать нечего, закрытие за reap
    # Координаты релея берём ИЗ ЗАПИСИ: доступ открыт к ТОМУ релею, а .support-relay мог с тех
    # пор поменяться (set-relay из панели). Записи нет полей — фолбэк на конфиг.
    load_relay >/dev/null 2>&1 || true    # ради RELAY_USER (и координат, если в записи их нет)
    [ -n "$RELAY_USER" ] || RELAY_USER=support
    if [ -n "$_rip" ] && [ -n "$_rpt" ]; then RELAY_IP="$_rip"; RELAY_PORT="$_rpt"; fi
    [ -n "$RELAY_IP" ] && [ -n "$RELAY_PORT" ] || { log "reup: координат релея нет ни в записи, ни в конфиге"; return 1; }
    if proc_alive "$PIDFILE"; then
        # Туннель жив — переподнимать нечего, но ГАРД мог унести mark-core (он пересобирает mangle
        # OUTPUT целиком). Ставим молча и только когда правила действительно нет.
        guard_check "$RELAY_IP" "$RELAY_PORT" || { log "гард к релею пропал (пересборка mangle) — ставлю заново"; guard_on; }
        return 0
    fi
    wan_up || { log "reup: туннель мёртв, но и WAN мёртв — жду следующего тика"; return 1; }
    auth_opt || { log "reup: туннель мёртв, а ключа для переподъёма нет (сессия открыта старым кодом?) — закрываю"; return 1; }
    guard_on
    if tunnel_spawn "$_rp" "$_re" 2; then
        [ "$port" = "$_rp" ] && log "reup: доступ восстановлен на ТОМ ЖЕ порту $port" \
                             || log "reup: прежний порт $_rp занят — доступ восстановлен на порту $port (человеку нужен новый)"
        return 0
    fi
    log "reup: поднять не удалось — попробую на следующем тике (осталось $(( _re - _rnow ))с)"
    return 1
}

cmd_down() {
    gip=""; gpt=""
    [ -s "$ACTIVE" ] && { read -r _p _e gip gpt _r < "$ACTIVE"; }
    [ -z "$gip" ] && load_relay >/dev/null 2>&1 && { gip="$RELAY_IP"; gpt="$RELAY_PORT"; }
    start-stop-daemon -K -p "$PIDFILE" >/dev/null 2>&1
    guard_off "$gip" "$gpt"
    rm -f "$PIDFILE" "$ACTIVE" "$CODEKEY" 2>/dev/null
    log "доступ закрыт (туннель снят, guard убран)"
    echo '{"active":0}'
}

cmd_status() {
    # ИСТЁКШУЮ СЕССИЮ ЗАКРЫВАЕМ И ЗДЕСЬ, а не только тиком сторожа (`reap`): после «Отключить VPN» сторожа нет, и ключ релея из кода,
    # запись и правило-гард лежали бы до ребута, а каждый опрос статуса форкал бы нас вечно (ревью шага 6d, круг 2). `reap` на
    # истёкшей записи — тот же `down`, идемпотентен; при живом стороже это тот же шаг на минуту раньше.
    if [ -s "$ACTIVE" ]; then
        read -r _sp _se _sr < "$ACTIVE"
        case "$_se" in ''|*[!0-9]*) _se=0 ;; esac
        if [ "$(date +%s)" -ge "$_se" ]; then cmd_reap >/dev/null 2>&1; fi
    fi
    # relay_set — настроен ли релей (панель гасит кнопку, если нет). need_cred — нужно ли поле
    # одноразового креда: есть стоячий ключ → 0 (просто кнопка), нет → 1 (per-session пароль).
    rset=0;  [ -s "$RELAY_CONF" ] && rset=1
    ncred=1; [ -r "$KEY" ] && ncred=0
    if [ -s "$ACTIVE" ] && proc_alive "$PIDFILE"; then
        read -r port expire _gip _gpt _r < "$ACTIVE"
        now=$(date +%s); left=$(( expire - now )); [ "$left" -lt 0 ] && left=0
        printf '{"active":1,"port":%s,"expires_in":%s,"relay_set":%s,"need_cred":%s}\n' "$port" "$left" "$rset" "$ncred"
    elif [ -s "$ACTIVE" ] && auth_opt; then
        # СЕССИЯ ОТКРЫТА, А СОЕДИНЕНИЕ ОБОРВАНО — третье состояние, а не «выключено». Туннель рвёт любой сброс
        # conntrack (смена транспорта), и до ближайшего тика сторожа (`reap` → `reup`, ≤2 мин) демона нет, а запись
        # «доступ открыт до такого-то» жива. Отвечая `active:0`, панель показывала «выключен» с полем для кода —
        # человек вставлял код заново поверх живой сессии, а шапка гасила «поддержка активна» при открытом доступе.
        # Истёкшую запись и сессию без ключа сторож закроет сам — их не показываем открытыми.
        read -r port expire _gip _gpt _r < "$ACTIVE"
        case "$expire" in ''|*[!0-9]*) expire=0 ;; esac
        case "$port" in ''|*[!0-9]*) port=0 ;; esac
        now=$(date +%s); left=$(( expire - now ))
        if [ "$left" -gt 0 ]; then
            printf '{"active":0,"pending":1,"port":%s,"expires_in":%s,"relay_set":%s,"need_cred":%s}\n' "$port" "$left" "$rset" "$ncred"
        else
            printf '{"active":0,"relay_set":%s,"need_cred":%s}\n' "$rset" "$ncred"
        fi
    else
        printf '{"active":0,"relay_set":%s,"need_cred":%s}\n' "$rset" "$ncred"
    fi
}

# Сборка мусора: экспайр по времени ИЛИ мёртвый демон при живой записи → закрыть. Зовёт watchdog
# (cron */2 — DRY, не плодим демон). Плюс страховка на ребут: /tmp сброшен → ACTIVE нет → no-op.
cmd_reap() {
    [ -s "$ACTIVE" ] || return 0
    read -r port expire _gip _gpt _r < "$ACTIVE"
    now=$(date +%s)
    case "$expire" in ''|*[!0-9]*) expire=0 ;; esac
    # TTL — ПЕРВЫМ: истёкшую сессию закрываем, что бы ни было с демоном. Порядок был обратным, и
    # это ровно та ошибка, из-за которой мёртвый демон хоронил ЖИВУЮ сессию: «демон мёртв» —
    # не приговор доступу, а повод его переподнять (соединение рвёт любой ct_flush).
    if [ "$now" -ge "$expire" ]; then
        log "reap: TTL истёк (порт $port) — закрываю доступ"
        cmd_down >/dev/null; return 0
    fi
    if ! proc_alive "$PIDFILE"; then
        # Переподъём. Не вышло — запись НЕ трогаем: впереди ещё тики, а закрыть по TTL мы всегда
        # успеем. Единственное исключение — нечем поднимать (нет ключа): тогда ждать нечего.
        if cmd_reup; then return 0; fi
        if ! auth_opt; then
            log "reap: демон мёртв, переподнять нечем (ключа нет) — чищу"
            cmd_down >/dev/null
        fi
        return 0
    fi
    # Туннель жив — проверим только гард (mark-core мог пересобрать mangle OUTPUT под нами).
    cmd_reup >/dev/null 2>&1
    return 0
}

cmd_set_relay() {
    _ip="$1"; _pt="$2"; _u="$3"
    echo "$_ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "IP должен быть литералом IPv4"; return 2; }
    case "$_pt" in ''|*[!0-9]*) echo "порт должен быть числом"; return 2 ;; esac
    mkdir -p "$ENODIA_STATE"
    printf '%s %s %s\n' "$_ip" "$_pt" "${_u:-support}" > "$RELAY_CONF"
    chmod 600 "$RELAY_CONF" 2>/dev/null
    echo "релей записан: $_ip:$_pt (${_u:-support})"
}

# --- open-code: провижн релея + подъём туннеля из «кода поддержки» --------------------
# Широкая сборка НЕ несёт ни координат релея, ни ключа (ничего серверного в билде/репе). Разработчик
# присылает ОДНУ base64-строку `BE7SUP2 IP PORT USER KEY_B64` (KEY_B64 = base64 сырых байт приватного
# dropbear-ключа = ПОСЛЕДНЕЕ поле, без пробелов). Тестер вставляет её в панель → сюда приходит base64
# ЧЕРЕЗ STDIN. Декодируем внешний base64, валидируем магию/IP/порт, пишем координаты (cmd_set_relay,
# .support-relay — НЕ секрет), декодируем ключ во временный $CODEKEY (RAM, 0600) и поднимаем туннель
# `dbclient -i` (cmd_up). Ключ — только транзитом: стирается сразу после старта dbclient, на буте /tmp пуст.
# NB: почему КЛЮЧ, а не пароль — dbclient на стоке БЕЗ парольной auth (см. шапку АУТЕНТИФИКАЦИЯ). Ключ
# из кода БЬЁТ стоячий $KEY (cmd_up: $SUPPORT_KEY_FILE приоритетнее) — код работает ОДИНАКОВО на
# приватной и широкой сборке. Магия BE7SUP2 отбивает случайную/битую вставку.
cmd_open_code() {
    ttl="$1"
    _b64=$(cat 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$_b64" ] || { echo '{"active":0,"error":"empty-code"}'; return 1; }
    _dec=$(printf '%s' "$_b64" | base64 -d 2>/dev/null | tr -d '\r')
    [ -n "$_dec" ] || { log "open-code: base64 не декодируется"; echo '{"active":0,"error":"bad-code"}'; return 1; }
    read -r _magic _ip _port _user _keyb64 <<EOF
$_dec
EOF
    [ "$_magic" = "BE7SUP2" ] || { log "open-code: неверная магия кода"; echo '{"active":0,"error":"bad-code"}'; return 1; }
    echo "$_ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { log "open-code: IP '$_ip' не литерал"; echo '{"active":0,"error":"bad-code"}'; return 1; }
    case "$_port" in ''|*[!0-9]*) log "open-code: порт '$_port' не число"; echo '{"active":0,"error":"bad-code"}'; return 1 ;; esac
    [ -n "$_user" ] || _user=support
    [ -n "$_keyb64" ] || { log "open-code: нет ключа в коде"; echo '{"active":0,"error":"bad-code"}'; return 1; }
    # Приватный ключ из кода → временный файл (RAM, 0600). umask 077 на случай гонки создания.
    ( umask 077; printf '%s' "$_keyb64" | base64 -d > "$CODEKEY" 2>/dev/null )
    [ -s "$CODEKEY" ] || { rm -f "$CODEKEY" 2>/dev/null; log "open-code: ключ из кода не декодируется"; echo '{"active":0,"error":"bad-code"}'; return 1; }
    chmod 600 "$CODEKEY" 2>/dev/null
    cmd_set_relay "$_ip" "$_port" "$_user" >/dev/null 2>&1 || { rm -f "$CODEKEY" 2>/dev/null; echo '{"active":0,"error":"bad-relay"}'; return 1; }
    SUPPORT_KEY_FILE="$CODEKEY"   # локальная — cmd_up возьмёт ключ из кода приоритетно
    cmd_up "$ttl"
}

case "$1" in
    up)        cmd_up "$2" ;;
    down)      cmd_down ;;
    status)    cmd_status ;;
    reap)      cmd_reap ;;
    reup)      cmd_reup ;;   # переподнять упавший туннель, пока сессия не истекла (зовёт reap из сторожа)
    set-relay) cmd_set_relay "$2" "$3" "$4" ;;
    open-code) cmd_open_code "$2" ;;   # base64-код поддержки на STDIN
    *) echo "usage: $0 up [ttl]|down|status|reap|reup|set-relay IP PORT [USER]|open-code [ttl] (base64<stdin)"; exit 2 ;;
esac
