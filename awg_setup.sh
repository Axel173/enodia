#!/bin/sh

# Пути АБСОЛЮТНЫЕ, а не относительные, как было у вендора: конфиги AWG живут в каталоге
# СОСТОЯНИЯ, а сам скрипт — в каталоге кода, и вызывателей у него пятеро с разным CWD
# (install.sh зовёт без `cd` вовсе). Относительное имя означало бы «где окажемся, там и
# сгенерируем awg0.conf» — файл лёг бы мимо, а awg0 встал бы пустым при зелёном логе.
: "${ENODIA_DIR:=/data/usr/app/enodia}"
: "${ENODIA_STATE:=/data/usr/app/enodia-state}"
: "${ENODIA_BIN:=/data/usr/app/enodia-bin}"
config_file="$ENODIA_STATE/amnezia_for_awg.conf"
interface_config="$ENODIA_STATE/awg0.conf"
# «ОТКЛЮЧИТЬ VPN» — awg0 НЕ ПОДНИМАЕМ ДАЖЕ ТЁПЛЫМ РЕЗЕРВОМ. Нас зовут пятеро (heal на буте, смена и перебор серверов switch-vpn,
# плагин awg, доустановка протокола), и каждый прошёл свою проверку флага РАНЬШЕ: перебор серверов досчитывал до живого и поднимал
# awg0 минуты спустя после выключения (ревью ветки, круг 2). Спрашиваем здесь, в единственном месте, где awg0 рождается, — ДО (ничего
# не делаем, даже firewall reload) и ПОСЛЕ подъёма (выключили по ходу — гасим свой демон). Владелец ответа — daemon-lib.sh.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v carrier_barred >/dev/null 2>&1 || carrier_barred() { return 1; }
# Отметка «несущую только что подняли» (clock-lib.sh, разбор у вызова ниже). Нет библиотеки — отметки нет, как раньше.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v carrier_up_mark >/dev/null 2>&1 || carrier_up_mark() { return 0; }
if carrier_barred; then
    echo "VPN выключен вручную — awg0 не поднимаю (включить: тумблер в панели)"
    exit 1
fi
if [ ! -f "$config_file" ]; then
    echo "File $config_file not found"
    exit 1
fi

# Парсим Address/DNS устойчиво к формату конфига: «=» с пробелами ИЛИ без, dual-stack
# через запятую (берём первый токен = IPv4), хвостовой CR. Старый `-F' = '` требовал
# РОВНО «Address = X»: на экспорте без пробелов (Address=...) или с IPv6 через запятую он
# возвращал пусто → `ip a add` ниже падал, и awg0 оставался БЕЗ IPv4 (handshake идёт,
# данные не ходят, rx≈0). Идиома та же, что для DNS в install.sh.
address=$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' \t\r')
dns=$(grep -E '^[[:space:]]*DNS[[:space:]]*=' "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' \t\r')
# MTU — wg-quick-директива (в awg0.conf НЕ идёт, см. awk ниже), но применяем её к awg0
# отдельно через `ip link set mtu`. Конфиги Cloudflare WARP несут MTU=1280 — без него
# awg0 остался бы на дефолтных 1420 (крупные пакеты через WARP фрагментируются/теряются).
mtu=$(grep -E '^[[:space:]]*MTU[[:space:]]*=' "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')

# ДЕФОЛТ, когда строки MTU= в конфиге НЕТ. Нативный `.conf` от Amnezia её не несёт НИКОГДА
# (MTU живёт в поле `mtu` контейнера vpn://, до нативного файла не доезжает) ⇒ раньше awg0
# оставался на ядерных 1420, а приложение на том же конфиге поднимало 1376 — отсюда вечное
# «в приложении быстро, на роутере еле ползёт» при живом хендшейке.
# Считаем накладные AWG 2.0 на КАЖДЫЙ пакет данных: 28 (IP+UDP) + 32 (заголовок WG + тег
# Poly1305) + S4 (padding транспортного пакета, до 15 Б) ⇒ наружу уходит до inner+75.
# При 1420 это 1495 и путь обязан держать полные 1500; у VPS за скруббингом/в чужом туннеле
# PMTU сплошь и рядом 1450 — крупные пакеты молча дохнут, TCP ретранзмитит, скорость падает
# на два порядка. ЗАМЕРЕНО на железе 2026-08-01 (изолированный awgtest, конфиг с S4=12):
# MTU 1400 → 43 КБ/с · 1390 → 107 КБ/с · 1376 → 8.5 МБ/с · 1344 → 9.1 МБ/с. Колено ровно там,
# где наружный пакет перестаёт влезать в 1450.
# Берём 1376 — дефолт САМОГО приложения Amnezia: конфиг, который у пользователя «работает в
# приложении», обязан так же работать и здесь. Цена — ~3% пропускной способности на здоровом
# пути; альтернатива (оставить 1420) — тихая деградация в 200 раз на пути с PMTU<1500.
AWG_MTU_DEFAULT=1376
echo "AmneziaWG client address: $address"
echo "DNS: $dns"

if [ -f "$interface_config" ]; then
    echo "$interface_config already exists"
    # Миграция: awg0.conf, собранный ДО вырезки ListenPort (ниже), переживает ребут и обновление и пересобирается лишь при
    # смене сервера — порт жил бы в нём до неё (ревью 27.09.2026). Снимаем на месте; grep впереди — без записи на флеш зря.
    # Регистр имени ключа — любой (wg читает его без учёта регистра); правка — через файл рядом и `mv`, как у генератора.
    if grep -qiE '^[[:space:]]*listenport[[:space:]]*=' "$interface_config" 2>/dev/null; then
        awk '{ t = tolower($0) } !(t ~ /^[[:space:]]*listenport[[:space:]]*=/)' "$interface_config" > "$interface_config.lp" 2>/dev/null \
            && mv "$interface_config.lp" "$interface_config"
    fi
else
    # ВАЖНО: вырезаем ВСЕ wg-quick-only директивы. `awg setconf` (форк wg setconf) их НЕ
    # понимает и на ПЕРВОЙ же такой строке падает "Line unrecognized: MTU=..." →
    # отвергает ВЕСЬ конфиг → awg0 поднимается ПУСТЫМ (без PrivateKey и [Peer]) → handshake
    # невозможен. Старый фильтр резал только Address/DNS и спотыкался на MTU из WARP-конфига.
    # Валидные для setconf ключи [Interface]: PrivateKey/ListenPort/FwMark + AWG (Jc/S*/H*/I*).
    # ListenPort — вон, как и у выхода (transport-awg.sh slot_gen_conf): клиенту фиксированный порт не нужен, а занятый другим
    # нашим демоном («доступ домой» awgs0, выход) порт = рукопожатия нет никогда.
    # Имя ключа — без учёта регистра (как у парсера wg); зеркало — transport-awg.sh slot_gen_conf.
    awk '{ t = tolower($0) } !(t ~ /^[[:space:]]*(address|dns|mtu|table|preup|postup|predown|postdown|saveconfig|listenport)[[:space:]]*=/)' "$config_file" > "$interface_config"
    # Пустые I1..I5 (AmneziaVPN 4.8.12.9+ кладёт заготовки даже в Legacy) валят setconf целиком:
    # «Line unrecognized: I2=» ⇒ awg0 встаёт ПУСТЫМ, хендшейка нет. Чистку имели switch-vpn.sh,
    # heal.sh, install.sh и transport-awg.sh, а здесь её не было — и путь «конфиг
    # положили в configs/ и подняли, минуя switch» (а также heal при живом amnezia_for_awg.conf
    # с пустыми I и отсутствующем awg0.conf) отваливался. Поймано на железе 2026-08-01.
    # Заполненные I1 (`I1 = <r 2><b 0x...>`) НЕ трогаем — это рабочий параметр AWG 2.0.
    sed -i '/^[[:space:]]*I[1-5][[:space:]]*=[[:space:]]*$/d' "$interface_config" 2>/dev/null
    echo "$interface_config created"
fi

# Endpoint ПО ИМЕНИ → подставляем IP САМИ. ЗАЧЕМ: `awg setconf` резолвит домен через системный
# resolver (dnsmasq), а тот форвардит upstream ВНУТРЬ туннеля — который в момент подъёма ещё/уже
# не работает (boot, `vpn-toggle repair` на мёртвой несущей, switch). Осечка резолва = НЕ «пир без
# endpoint», а отказ ВСЕГО конфига: «Name does not resolve … Configuration parsing error» → awg0
# встаёт ПУСТЫМ (private-key-set=0, peers=0) → handshake невозможен → туннель не поднять → DNS
# так и не оживёт = дедлок (проверено на железе 2026-07-15 на отдельном awgtest). Ту же граблю у
# xray/hy2 лечит seed_server_dns, но для WG подстановка ЧИЩЕ сида: у WireGuard нет SNI — endpoint
# это просто IP:порт, имя нигде больше не используется (в отличие от TLS-транспортов).
# ВАЖНО — имя берём из ИСХОДНОГО конфига, а awg0.conf только патчим: awg0.conf переживает ребуты,
# и записанный в него IP иначе застыл бы навсегда, сломав DDNS-эндпоинты (раньше setconf резолвил
# имя на КАЖДЫЙ подъём). Так резолв свежий на каждом запуске, а setconf получает готовый IP.
# Голый IPv4 (99% конфигов) → шага нет вообще: ни DNS-запроса, ни задержки. IPv6-литерал в скобках
# пропускаем (резолвить нечего, а слепой s|.*| сломал бы адрес с двоеточиями). Резолв — dns-lib.sh
# (системный резолвер, при его смерти DoH по IP-литералу мимо dnsmasq).
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# Под `[ -f ]`: провалившийся `.` в ash фатален и МОЛЧАЛИВ (шелл выходит на месте, rc=2), а этот
# файл — генератор awg0.conf, и «тихо ничего не сгенерировали» читалось бы как «awg не поднялся».
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; else
    echo "нет $ENODIA_DIR/dns-lib.sh — обновите установку (панель → «Обновление» или переустановка с компьютера)" >&2; exit 1
fi
ep_src=$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
ep_host=$(echo "$ep_src" | sed 's/:[0-9]*$//')
ep_port=$(echo "$ep_src" | sed -n 's/.*:\([0-9]*\)$/\1/p')
case "$ep_host" in
    ''|\[*) : ;;                                   # нет Endpoint / IPv6-литерал — не наш случай
    *)
        if ! is_ipv4 "$ep_host"; then
            ep_ip=$(resolve_ipv4 "$ep_host")
            if [ -n "$ep_ip" ] && [ -n "$ep_port" ]; then
                sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = $ep_ip:$ep_port|" "$interface_config"
                echo "Endpoint $ep_host -> $ep_ip (подставлен IP: awg setconf не резолвит через мёртвый dnsmasq)"
            else
                # Честно предупреждаем: setconf сейчас попробует резолвить сам и, скорее всего,
                # отвергнет конфиг целиком. Не падаем — вдруг у resolver'а выйдет там, где у нас нет.
                echo "ВНИМАНИЕ: не зарезолвил Endpoint '$ep_host' (ни dnsmasq, ни DoH) — awg setconf может отвергнуть конфиг целиком" >&2
            fi
        fi ;;
esac

# Проверяем бинари AmneziaWG. ВАЖНО: НЕ качаем их с github (как в оригинале
# Шалина) — там СТАРАЯ AWG 1.x, которая не понимает S3/S4/H-диапазоны AWG 2.0
# (awg setconf падает с "Line unrecognized: S3="). Канонический источник бинарей —
# панель («Компоненты» -> packages.sh -> gh-update.sh) и bin/*.user из payload. Если рабочего
# бинаря нет — ЯВНО падаем
# (НЕ тянем старьё с внешнего github; репо может исчезнуть).
# Восстановление при пропаже/порче = переустановка с ПК
# (отдельной .working.bak-копии на роутере больше не держим — экономия флеша).
# ПУТЬ АБСОЛЮТНЫЙ (следит C51). Голые имена означали «ищем в ТЕКУЩЕМ каталоге» и работали
# лишь потому, что вызыватель делал `cd $ENODIA_DIR`, где бинари тогда и лежали. После
# переезда бинарей в $ENODIA_BIN (30.08.2026) гард стал ЛОЖНО-ОТРИЦАТЕЛЬНЫМ: смена
# сервера/страны падала «бинари не найдены» ВСЕГДА, а switch-vpn.sh следом делал
# safety_off — то есть кнопка «сменить сервер» гасила VPN. Поймано на живом AX3600
# 31.08.2026. Судим по НАЛИЧИЮ (-f), а не по биту -x: бит не наш (--push кладёт 644).
if [ ! -f "$ENODIA_BIN/awg" ] || [ ! -f "$ENODIA_BIN/amneziawg-go" ]; then
    echo "ERROR: бинари AmneziaWG (awg/amneziawg-go) не найдены." >&2
    echo "       Поставьте AmneziaWG в панели :8088 -> «Компоненты». Качать старую" >&2
    echo "       AWG 1.x с github НЕ будем — она ломает конфиг AWG 2.0." >&2
    exit 1
fi
echo "AmneziaWG binaries exist, setting up awg0 interface"


# --- Снять осиротевший демон + STALE UAPI-сокет предыдущего awg0 (анти-дедлок) ---
# amneziawg-go (форк wireguard-go) при старте создаёт TUN awg0 И слушающий UAPI-сокет
# /var/run/amneziawg/awg0.sock (unix, srwx------). После `ip link del awg0` (Uninstall с
# ПК, heal.sh на буте, switch-vpn, proto-install) демон может пережить удаление своего
# TUN, а файл-сокет остаётся на tmpfs. Тогда НОВЫЙ `amneziawg-go awg0` ниже не встаёт:
# TUN awg0 держит зомби-демон, бинд к сокету занят → awg0 не появляется → установщик
# падает «awg0 не появился за 30 секунд» (install.sh). Раньше лечил ТОЛЬКО ребут
# (при перезагрузке чистятся и процессы, и /var/run=tmpfs). Здесь чистим детерминированно
# ПЕРЕД пересозданием: гасим прежний демон (TERM → добить KILL) и удаляем stale-сокет.
# На чистом буте — no-op (демона/сокета ещё нет). Идемпотентно и живую несущую не роняет:
# awg_setup.sh зовётся только когда awg0 пересоздаётся с нуля (вызыватели делают link del).
#
# ГРАБЛЯ (поймано на железе): матчить демон ИМЕНЕМ БИНАРЯ нельзя. Инстансов amneziawg-go у нас
# теперь несколько — awg0 (основная несущая), awgN (awg-выходы слотов) и awgs0 (VPN-сервер
# «доступ домой»), — а `pidof`/`killall amneziawg-go` бьют по ВСЕМ сразу. Любой failover звал
# switch-vpn.sh → этот скрипт и молча гасил сервер со слотами: правила фаервола оставались,
# несущей не было, «доступ домой» отваливался до следующего ребута. Матчим РОВНО awg0 по
# /proc/*/cmdline — зеркало awg_kill_daemon (transport-awg.sh) и srv_kill_daemon (vpn-server.sh).
awg0_daemon_pids() {
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        case "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline") " in
            *"amneziawg-go awg0 "*) echo "${p#/proc/}" ;;
        esac
    done
}
if [ -n "$(awg0_daemon_pids)" ]; then
    for p in $(awg0_daemon_pids); do kill "$p" 2>/dev/null; done
    i=0
    while [ -n "$(awg0_daemon_pids)" ] && [ "$i" -lt 10 ]; do
        if [ "$i" = 3 ]; then
            for p in $(awg0_daemon_pids); do kill -9 "$p" 2>/dev/null; done
        fi
        sleep 1; i=$((i + 1))
    done
fi
rm -f /var/run/amneziawg/awg0.sock /var/run/wireguard/awg0.sock 2>/dev/null

# Set up AmneziaWG interface
# GOMEMLIMIT: пул пакетных буферов у amneziawg-go БЕЗ потолка (апстримный
# `PreallocatedBuffersPerPool = 0`), куча растёт по объёму трафика и ядру не возвращается — на
# тесных моделях это ребут по нехватке ОЗУ. Владелец значения ОДИН — net-tune.sh (.go-memlimit),
# своей копии правила тут не заводим. Нет скрипта/значения ⇒ подстановка пуста и запуск прежний
# БАЙТ В БАЙТ. Потолок задаётся только СТАРТОМ демона, менять его на лету нельзя.
# Фильтр по ФОРМЕ обязателен: при рассинхроне версий (старый net-tune.sh рядом с новым вызывателем)
# верб уходит в ветку `*)`, а та печатает `usage: …` в STDOUT — и без фильтра это слово встало бы
# первым аргументом env, то есть awg0 не поднялся бы ВООБЩЕ. Свой фильтр держим тут же, рядом с
# env: вынесенный в библиотеку он сам может оказаться устаревшей копией.
env $(sh "$ENODIA_DIR/net-tune.sh" memlimit-env 2>/dev/null | grep -E '^GOMEMLIMIT=[0-9]+MiB$') "$ENODIA_BIN/amneziawg-go" awg0
"$ENODIA_BIN/awg" setconf awg0 "$interface_config"
if [ -n "$address" ]; then
    ip a add "$address" dev awg0
else
    echo "ERROR: поле Address не найдено в $config_file — awg0 останется БЕЗ IPv4 (туннель не понесёт трафик)." >&2
fi
# MTU: строка из конфига (WARP несёт 1280), иначе AWG_MTU_DEFAULT — см. разбор при объявлении.
ip link set dev awg0 mtu "${mtu:-$AWG_MTU_DEFAULT}"
# Ручная настройка пользователя (.tun-mtu) — ПОВЕРХ обеих. Владелец флага один — net-tune.sh,
# своей копии чтения/валидации тут не заводим (DRY). Заодно чиним старый перекос: net-tune звал
# ТОЛЬКО heal.sh на буте, поэтому смена сервера сбрасывала ручной MTU до следующей перезагрузки.
if [ -f "$ENODIA_DIR/net-tune.sh" ]; then
    sh "$ENODIA_DIR/net-tune.sh" mtu >/dev/null 2>&1
fi
ip l set up awg0
# Выключили, пока поднимали, — отпускаем СВОЙ демон (матч по cmdline, другие инстансы не трогаем) и не доходим до firewall reload.
if carrier_barred; then
    echo "VPN выключили вручную, пока поднимался awg0, — снимаю его"
    for p in $(awg0_daemon_pids); do kill "$p" 2>/dev/null; done
    ip link del awg0 2>/dev/null
    exit 1
fi
# «НЕСУЩУЮ ТОЛЬКО ЧТО ПОДНЯЛИ» (clock-lib.sh::carrier_up_mark) — awg0 рождается ТОЛЬКО здесь, поэтому и отметка здесь. Её читают
# двое: сторож (грейс прогрева, как у альтов) и слой DoH — прокси держит HTTP/2 к резолверу через СНЕСЁННЫЙ awg0, и без
# перезапуска первая проба имён после смены сервера упиралась в мёртвое соединение: 4 с таймаута + 2 с паузы (замер BE7000
# 02.10.2026, смена сервера 9.1 с вместо ~2). Прежде у AmneziaWG отметки не было вовсе — её ставили лишь плагины альтов.
carrier_up_mark

# $ENODIA_BIN/awg - check connection

# ЗОНА `awg` В ФАЕРВОЛЕ — И firewall reload ТОЛЬКО РАДИ ЕЁ РОЖДЕНИЯ. Reload флашит ВСЕ iptables, и вызыватель обязан
# переиграть снесённое; раньше это происходило на КАЖДОЙ смене сервера. А зона — декоративная: интерфейса `network.awg0`
# у netifd нет, fw3 не знает её устройства, и цепочки `zone_awg_*` стоят без единого правила на awg0 (замер BE7000
# 02.10.2026). Маршрут, FORWARD и MASQUERADE несущей ставим МЫ (плагин), а правила с `-i/-o awg0` переживают пересоздание
# интерфейса — они матчат имя. Поэтому reload нужен, только когда зоны ещё нет: uci-конфиг её не знает (на BE7000 /etc —
# ramfs, то есть первый подъём после загрузки) или fw3 её ещё не загрузил (цепочки нет — судим по ФАКТУ ядра).
# Перезагрузили — отмечаем (`fw3_gen_new`, ipt-lib.sh): вызыватель сверяет отметку и переигрывает ТОЛЬКО тогда.
command -v fw3_gen_new >/dev/null 2>&1 || fw3_gen_new() { :; }   # нет ipt-lib — у вызывателей шим «reload был всегда»
awg_zone_ready() {
    [ "$(uci -q get firewall.awg)" = zone ] || return 1
    for _z in name=awg network=awg0 input=ACCEPT output=ACCEPT forward=ACCEPT; do
        [ "$(uci -q get "firewall.awg.${_z%%=*}")" = "${_z#*=}" ] || return 1
    done
    uci show firewall 2>/dev/null | grep -qE "src='awg'|dest='awg'" || return 1
    iptables -S zone_awg_forward >/dev/null 2>&1
}
if awg_zone_ready; then
    echo "Зона awg в фаерволе уже стоит — firewall reload не нужен, правила остаются на месте"
    ip route flush cache
    # …ЕСЛИ ОНИ НА МЕСТЕ (ревью с.96, круг 2). ЧУЖОЙ reload (вебморда Xiaomi сохраняет настройки) сносит НАШИ цепочки, а зону fw3
    # рождает заново сам — проверка выше её видит. Прежде нашу проводку попутно возвращал наш же reload+переигрыш на КАЖДОЙ смене
    # сервера, а сторож сносу верит лишь по пропаже `FORWARD -o awg0`, которую эта же смена тут же и возвращает: смена в окне
    # подтверждения оставляла «мимо VPN», порты, zapret, доп-выходы и «доступ домой» снесёнными до ребута. Признак — прыжок цепочки
    # вырезов (apply-bypass.sh, ставит его переигрыш; анти-петля несущей ставит его тоже, но ПОЗЖЕ нас). Нет — отмечаем поколение
    # без reload: вызыватель переиграет, как после нашего. Ложное «нет» стоит прежней цены (переигрыш).
    # …НО ПРЫЖОК ВОЗВРАЩАЕТ И ЧАСТНАЯ ПРАВКА (ревью с.96, круг 3): сохранение группы, домена, «мимо VPN» зовёт apply-bypass ensure_chain,
    # и после чужого reload прыжок стоял над пустой цепочкой. Второй признак — `FORWARD -o awg0`: его ставят только плагин и полный
    # переигрыш, и ровно по нему сторож судит снос. Спрашиваем его, когда несущую ведёт AmneziaWG (иначе правила может не быть законно).
    _awg_wired=1
    iptables -t mangle -C PREROUTING -j VPN_EXCLUDE 2>/dev/null || _awg_wired=0
    if [ "$_awg_wired" = 1 ] && [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" = awg ]; then
        iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || _awg_wired=0
    fi
    if [ "$_awg_wired" = 0 ]; then
        echo "Нашей проводки в ядре нет (чужой firewall reload?) — отмечаю: вызыватель переиграет правила"
        fw3_gen_new
    fi
else
    # Set up firewall AmneziaWG zone
    uci set firewall.awg=zone
    uci set firewall.awg.name='awg'
    uci set firewall.awg.network='awg0'
    uci set firewall.awg.input='ACCEPT'
    uci set firewall.awg.output='ACCEPT'
    uci set firewall.awg.forward='ACCEPT'
    if ! uci show firewall | grep -qE "src='awg'|dest='awg'"; then
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='guest'
        uci set firewall.@forwarding[-1].dest='awg'
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='awg'
        uci set firewall.@forwarding[-1].dest='guest'
    fi
    uci commit firewall

    # Clear routes cache and restart firewall
    # ПОМЕТКА ЧУЖОГО ВЫВОДА. Ниже говорит СТОКОВЫЙ fw3, а стенограмма садится в НАШ лог
    # (enodia-startup.log / switch-vpn-setup.log) — и его собственные ошибки читаются как наши.
    # Замерено на AX3600 17.08.2026, каждый подъём несущей: «! Failed with exit code 1» от
    # /etc/firewall.d/qca-nss-ecm, «Cannot find device br-guest» и «Error: argument "dport" is
    # wrong» от миксиного parentalctl (на ядре 4.4 iproute2 не знает dport). Ни одна из них не
    # наша, но именно они всплывают первыми, когда грепаешь лог тестера на error|fail.
    echo "Restarting firewall..."
    echo "--- НИЖЕ ВЫВОД СТОКОВОГО firewall reload (fw3/miwifi). Его ошибки — НЕ наши ---"
    ip route flush cache
    /etc/init.d/firewall reload
    fw3_gen_new
    echo "--- конец вывода стокового firewall reload ---"
fi

# --- Гостевая сеть: маршруты/правила/NAT (мимо-и-в-VPN) — ИДЕМПОТЕНТНО ---------
# ПОЧЕМУ ЭТОТ БЛОК СТОИТ ПОСЛЕ `firewall reload`, А НЕ ДО (найдено ревью, батч 4).
# fw3 reload флашит ВСЕ iptables. Раньше блок стоял ВЫШЕ него — и наш же reload сносил
# свежепоставленные правила через пару строк: в рантайме от «гостевой сети» жила только
# uci-зона, а DNAT гостевого DNS на $dns и MASQUERADE 192.168.33.0/24 не существовали
# НИКОГДА (симптом: гость в VPN, но резолвит мимо/не резолвит вовсе). ip route/ip rule
# reload не трогает, но держим их вместе с остальным блоком — читается как одно целое.
#
# awg_setup.sh зовётся НЕ только на fresh-install: heal.sh гоняет его на КАЖДОМ
# буте (ip link del awg0 + ./awg_setup.sh), а switch-vpn/transport-awg/proto-install —
# когда awg0 не поднят (смена страны, cross, доустановка awg). Голые `ip rule add` /
# `iptables -A` при повторном прогоне В ПРЕДЕЛАХ ОДНОЙ ЗАГРУЗКИ доклеивали дубли
# (правила живут в RAM, на ребуте чистятся, но за долгий аптайм с парой переключений
# копились). Дедуп — устоявшимися идиомами проекта: route -> replace; ip rule ->
# delete-loop + add; iptables -> -C || -A (ср. mark-core.sh, transport-awg.sh, zapret.sh).
# Delete-loop заодно вычищает уже накопленные дубли БЕЗ ребута.

# Маршруты гостевой сети (replace = add-or-update, дубль невозможен)
ip route replace 192.168.33.0/24 dev br-guest table main
# УБРАНО (16.08.2026): `ip route replace default dev awg0 table 200` + парная `ip rule … pref 200`
# ниже — «вся гостевая сеть безусловно в awg0». Это ЧЕТВЁРТЫЙ режим гостевой сети, которого нет в
# продукте: панель предлагает ТРИ («раздельно» — деф. · «мимо VPN» · «целиком в VPN»), владелец у
# них один — apply-bypass.sh, и он же их персистит и переигрывает. Правило отсюда навязывало
# «целиком в VPN» поверх выбора человека, но только на awg (у альтов несущая xtun, и этой ветки
# нет вовсе) и только до первой смены несущей: маршрут умирает вместе с awg0, а восстанавливал его
# лишь бутовый путь heal — в replay секция awg_setup.sh пропускается. Итог: «раздельно» в панели
# и full-tunnel на роутере после ребута, split-tunnel после смены сервера, и ни одна из подсистем
# за это не отвечала. Осиротевшее правило снимает `uninstall.sh` ($GUEST_RULE_*), замерено на
# AX3600 — оно переживало даже полное удаление.

# ip rule: снимаем ВСЕ накопленные дубли (полный селектор = тот же парсер busybox,
# что у add), затем ставим ровно один
while ip rule del from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100 2>/dev/null; do :; done
# Это правило ОСТАЁТСЯ и в режиме «целиком в VPN» осмысленно: DNS-запрос гостя к самому роутеру
# (192.168.33.1) обязан идти в main, иначе apply-bypass пометит его вместе с остальным трафиком и
# отправит в туннель — резолвер у гостя окажется недостижим.
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
# Правила `pref 200 → table 200` больше нет: см. комментарий у маршрутов выше. Delete-loop СНИМАЕТ
# его и здесь — на роутере, обновившемся поверх старой установки, оно иначе осталось бы в RAM жить
# своей жизнью до ребута, навязывая гостям режим, которого человек не выбирал.
while ip rule del from 192.168.33.0/24 table 200 pref 200 2>/dev/null; do :; done

# Файрвол: DNS-запросы гостя (FORWARD)
iptables -C FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT
iptables -C FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT
iptables -C FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT
iptables -C FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT

# Общий трафик гость <-> awg0
iptables -C FORWARD -i br-guest -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT
iptables -C FORWARD -i awg0 -o br-guest -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -o br-guest -j ACCEPT

# NAT: DNS-запросы гостя -> upstream ($dns).
# Гард на пустой $dns: в конфиге может не быть строки `DNS=` вовсе (нативные .conf её несут не
# всегда), и правило собиралось как `--to-destination :53` — iptables ругался в лог, а правила
# не было. Для Address такой случай логировался, для DNS — нет; теперь говорим прямо.
# DNAT НА DNS ПРЕЖНЕГО СЕРВЕРА — СНЯТЬ. Его смывал firewall reload на каждой смене сервера; теперь reload бывает раз на
# загрузку (см. зону выше), и правило прошлого конфига осталось бы ПЕРВЫМ: у WARP DNS = 1.1.1.1, у Amnezia — 172.29.172.254,
# и гость после смены слал бы запросы туда, куда новый туннель не ведёт (гостевая сеть без имён). Снимаем всё, что смотрит
# не в $dns; пустой $dns — снимаем всё (гость идёт к dnsmasq роутера, как и обещает строка ниже).
iptables -t nat -S PREROUTING 2>/dev/null \
    | grep -E -- '^-A PREROUTING -s 192\.168\.33\.0/24 .*--dport 53 -j DNAT --to-destination ' \
    | grep -vF -- "--to-destination ${dns:-x}:53" | sed 's/^-A /-D /' \
    | while read -r _gd; do iptables -t nat $_gd 2>/dev/null; done
if [ -n "$dns" ]; then
    iptables -t nat -C PREROUTING -p udp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53 2>/dev/null || iptables -t nat -A PREROUTING -p udp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53
    iptables -t nat -C PREROUTING -p tcp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53 2>/dev/null || iptables -t nat -A PREROUTING -p tcp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53
else
    echo "ВНИМАНИЕ: поля DNS нет в $config_file — DNAT гостевого DNS не ставим (гость пойдёт к dnsmasq роутера)." >&2
fi

# NAT: MASQUERADE гостя через awg0
iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# Turn IP-forwarding on
echo 1 > /proc/sys/net/ipv4/ip_forward
