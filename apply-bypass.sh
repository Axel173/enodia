#!/bin/sh
# apply-bypass.sh — переигрывает «вырезы мимо VPN» после ребута и fw3-reload.
#
# ЗАЧЕМ. Базовое раздельное туннелирование (трафик из списков -> VPN) восстанавливает
# heal.sh/split-route.sh при КАЖДОЙ загрузке. А ИСКЛЮЧЕНИЯ (то, что ты увёл
# НАПРЯМУЮ, мимо VPN) живут только в iptables/ip rule = RAM, и их не восстанавливал
# никто: после ребута/fw3-reload устройство/SSID/гостевая молча возвращались в VPN.
# Этот скрипт хранит исключения в persistent-файлах на /data и переигрывает их.
#
# Что хранит (файлы в $ENODIA_DIR, раздел /data переживает ребут):
#   .bypass-ips      — IP устройств (ИСТОЧНИК, LAN) мимо VPN (по строке на IP).
#                      Зеркало `vpn-toggle.sh exclude` (-s IP -j ACCEPT в VPN_EXCLUDE).
#   .bypass-dst      — IP/подсети НАЗНАЧЕНИЯ (сайты/сервисы) мимо VPN (CIDR на строку).
#                      Правило -d CIDR -j ACCEPT в VPN_EXCLUDE. Надёжно перебивает
#                      iplist_set/enodia_list, т.к. цепочка проверяется ПЕРВОЙ, до меток.
#   .vpn-dst         — ОБРАТНОЕ: IP/подсети назначения ЦЕЛИКОМ в туннель (CIDR на строку).
#                      Наполняет ipset enodia_ip_vpn, его метит mark-core. У адреса, как у
#                      домена, ТРИ состояния: в VPN / мимо VPN / правила нет (см. ниже).
#   .endpoint-bypass — IP endpoint'а АКТИВНОЙ несущей (VPS-сервер), исключённый
#                      из маркировки. АВТО, управляет ТОЛЬКО код несущей
#                      (transport-*.sh up), не пользователь. ЗАЧЕМ: если IP сервера
#                      попадает в iplist_set (opencck), mangle OUTPUT метит СВОИ ЖЕ
#                      зашифрованные пакеты к VPS -> ip rule 99 -> table 1000 ->
#                      default dev awg0/xtun -> пакет к серверу заворачивается ОБРАТНО
#                      в туннель = бесконечная петля (sent растёт, received~0, DNS
#                      мёртв). Отдельно от .bypass-dst, чтобы IP сервера не светился
#                      в пользовательском списке и смена сервера сама снимала старый.
#   .bypass-ifaces   — Wi-Fi СЕТИ мимо VPN: по строке на SSID (правило -m physdev
#                      --physdev-in <все wlN этого SSID>). ХРАНИМ ИМЯ СЕТИ, А НЕ wlN:
#                      сток переклеивает пары ifname↔SSID при правке Wi-Fi, и отметка
#                      уезжала на ЧУЖУЮ сеть (04.08.2026: трёхдиапазонный режим увёл всех
#                      клиентов мимо туннеля). Раскрытие «SSID → живые wlN» — в момент
#                      применения, wifi_resolve из wifi-lib.sh. Legacy-строки `wlN`
#                      (и сети, которых сейчас нет в эфире) продолжают работать как раньше;
#                      apply мигрирует их в SSID, когда сеть удаётся опознать.
#   .bypass-guest    — флаг-файл: есть -> гостевая 192.168.33.0/24 идёт мимо VPN
#                      (ip rule pref 90 -> main). Зеркало пункта 24 меню.
#   .port-rules      — ПРАВИЛА ПО ПОРТАМ (цепочка VPN_PORTS): «у ЭТОГО устройства
#                      вот эти порты идут не туда, куда остальной его трафик».
#                      TSV: src<TAB>proto<TAB>порты<TAB>направление (см. блок ниже).
#
# И ОБРАТНОЕ — «ЦЕЛИКОМ через VPN» (force, цепочка VPN_FORCE, MARK вместо ACCEPT):
#   .fullvpn-ips     — IP устройств (источник) целиком в VPN. Строка: `IP` (основной
#                      туннель) либо `IP<TAB>sN` (доп-выход N, мульти-транспорт).
#                      Миграции НЕТ и не нужно: старые строки без TAB читаются как «основной».
#   .fullvpn-ifaces  — Wi-Fi СЕТЬ целиком в VPN (physdev, по строке на SSID) — зеркало
#                      .bypass-ifaces, включая формат и миграцию legacy-имён.
#   .fullvpn-guest   — флаг: гостевая целиком в VPN (взаимоискл. с .bypass-guest).
#   .full-tunnel     — флаг: ВЕСЬ трафик через VPN (catch-all). Зеркало пункта 23.
#
# БЕЗОПАСНОСТЬ. Все правила тут гонят трафик ТОЛЬКО в прямой путь (провайдер) или в
# main-таблицу — они физически НЕ могут увести трафик в дохлый awg0. Поэтому даже при
# кривом/пустом хранилище «интернет и VPN не упадут»: это лишь карта исключений, а не
# базовая маршрутизация (её держит split-route.sh).
#
# ИДЕМПОТЕНТНОСТЬ. apply можно звать сколько угодно: перед каждым -A стоит -C (а для
# ip rule — grep-проверка), дубли не плодятся. Зовётся из heal.sh (после
# split-route) и из vpn-toggle.sh repair.
#
# busybox-замечания: используем grep -qxF / grep -vxF
# (whole-line, fixed-string) — они есть в busybox; НЕ используем grep -c/--color.
#
# Использование:
#   apply-bypass.sh apply           — переиграть всё из хранилища (идемпотентно)
#   apply-bypass.sh add-ip   <IP>    — занести IP устройства в хранилище и применить
#   apply-bypass.sh del-ip   <IP>    — убрать IP устройства из хранилища и снять
#   apply-bypass.sh add-dst  <CIDR>  — сайт-IP/подсеть назначения мимо VPN (+хранилище)
#   apply-bypass.sh del-dst  <CIDR>  — снять правило «мимо VPN» (адрес снова «как все»)
#   apply-bypass.sh add-vpn-dst <CIDR> — сайт-IP/подсеть ЦЕЛИКОМ в туннель (+хранилище)
#   apply-bypass.sh del-vpn-dst <CIDR> — снять правило «в VPN» (адрес снова «как все»)
#   apply-bypass.sh endpoint-set <IP> — endpoint несущей мимо VPN (авто из transport-*.sh up;
#                                       пусто = снять). Анти-петля (IP VPS в iplist_set).
#   apply-bypass.sh add-if   <IFACE> — занести iface и применить правило
#   apply-bypass.sh del-if   <IFACE> — убрать iface и снять правило
#   apply-bypass.sh guest-on         — гостевая мимо VPN (флаг + ip rule pref 90)
#   apply-bypass.sh guest-off        — гостевая обратно в VPN (снять флаг + правило)
#   apply-bypass.sh force-add-ip <IP>    — устройство ЦЕЛИКОМ через VPN (+хранилище)
#   apply-bypass.sh force-del-ip <IP>    — вернуть устройство в раздельный режим
#   apply-bypass.sh force-add-if <IFACE> — SSID/iface ЦЕЛИКОМ через VPN
#   apply-bypass.sh force-del-if <IFACE> — вернуть SSID/iface в раздельный режим
#   apply-bypass.sh force-guest-on       — гостевая ЦЕЛИКОМ через VPN
#   apply-bypass.sh force-guest-off      — гостевая обратно в раздельный режим
#   apply-bypass.sh forget-if <СТРОКА>   — снять правило сети ПО СТРОКЕ хранилища (из обоих): сеть не в эфире,
#                                          и интерфейса, который прислала бы панель, у неё нет
#   apply-bypass.sh if-states            — для панели: что хранилище говорит о каждом живом интерфейсе
#   apply-bypass.sh full-tunnel on|off   — ВЕСЬ трафик через VPN (глоб. catch-all)
#   apply-bypass.sh port-add <src> <proto> <порты> <куда> — правило по портам
#   apply-bypass.sh port-del <src> <proto> <порты>        — снять его
#   apply-bypass.sh port-list        — показать правила по портам (TSV, для панели)
#   apply-bypass.sh dev-rebind       — переиграть правила устройств по адресам (цепочка VPN_DEV;
#                                      состав правил хранит groups.sh, зовёт он же после сборки)
#   apply-bypass.sh order            — только переиграть порядок цепочек в PREROUTING
#   apply-bypass.sh list             — показать хранилище

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# «Какая сеть на каком wlN» — только отсюда (см. шапку про .bypass-ifaces).
if [ -f "$ENODIA_DIR/wifi-lib.sh" ]; then . "$ENODIA_DIR/wifi-lib.sh"; fi
# Шим на случай частичного apply-scripts: правила по сетям продолжают работать, но как до
# 04.08.2026 — строка хранилища трактуется как ИМЯ ИНТЕРФЕЙСА (осознанная деградация, не мёртвый код).
if ! command -v wifi_resolve >/dev/null 2>&1; then
    wifi_resolve()  { [ -n "$1" ] && printf '%s\n' "$1"; }
    wifi_ssid_of()  { return 1; }
fi
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600) утилиты
# conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op (правило есть,
# поток идёт по-старому через NSS/ECM). Шим = прежнее поведение, чтобы частичный apply-scripts не падал.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# Правила по портам: какая строка хранилища действует и в каком порядке встаёт в цепочку — только
# port-lib.sh (у хранилища три читателя, копии фильтра расходились). Шима нет намеренно: без файла
# rebuild_ports оставляет прежнюю цепочку и говорит об этом, а port-add отказывает.
if [ -f "$ENODIA_DIR/port-lib.sh" ]; then . "$ENODIA_DIR/port-lib.sh"; fi
if ! command -v ct_flush >/dev/null 2>&1; then
    ct_flush()     { conntrack -F >/dev/null 2>&1 || true; }
    ct_flush_src() { [ -n "$1" ] && conntrack -D --src "$1" >/dev/null 2>&1; return 0; }
    ct_flush_dst() { [ -n "$1" ] && conntrack -D -d    "$1" >/dev/null 2>&1; return 0; }
fi
EXCLUDE_CHAIN=VPN_EXCLUDE
STORE_IPS="$ENODIA_STATE/.bypass-ips"
STORE_DST="$ENODIA_STATE/.bypass-dst"
STORE_IFS="$ENODIA_STATE/.bypass-ifaces"
STORE_GUEST="$ENODIA_STATE/.bypass-guest"
STORE_EP="$ENODIA_STATE/.endpoint-bypass"   # IP endpoint'а активной несущей (авто, анти-петля)
GUEST_SUBNET=192.168.33.0/24
GUEST_PREF=90

# --- «ЦЕЛИКОМ через VPN» (force) — зеркало bypass, но наоборот: помечаем -----
# Цепочка VPN_FORCE — обратная к VPN_EXCLUDE: вместо ACCEPT (мимо VPN) ставит
# MARK $FWMARK (= в туннель), игнорируя сплит по enodia_list/iplist_set. Нужна,
# чтобы целую сеть/устройство/гостевую гнать в VPN ПОЛНОСТЬЮ, и для глобального
# full-tunnel («весь трафик через VPN»). Подцепляется в PREROUTING ВТОРОЙ —
# после VPN_EXCLUDE (явный вырез мимо VPN перебивает force) и ДО mark-правил
# split-route. ТОЛЬКО PREROUTING: трафик самого роутера (OUTPUT — handshake к
# endpoint, DNS к VPS) в туннель заворачивать нельзя, будет петля.
# БЕЗОПАСНОСТЬ: как и split-route, всё держится на одном `ip rule fwmark` →
# safety_off (watchdog при смерти VPS) удаляет его, и помеченный трафик уходит
# напрямую. Т.е. full-tunnel не способен «запереть» интернет насмерть.
FORCE_CHAIN=VPN_FORCE
STORE_FORCE_IPS="$ENODIA_STATE/.fullvpn-ips"     # IP устройств (источник) ЦЕЛИКОМ в VPN (`IP` | `IP<TAB>sN`)
STORE_FORCE_IFS="$ENODIA_STATE/.fullvpn-ifaces"  # Wi-Fi iface (SSID) ЦЕЛИКОМ в VPN
STORE_FORCE_GUEST="$ENODIA_STATE/.fullvpn-guest" # флаг: гостевая ЦЕЛИКОМ в VPN
FULLTUNNEL_FLAG="$ENODIA_STATE/.full-tunnel"     # флаг: ВЕСЬ трафик через VPN
FWMARK=0x1
TAB=$(printf '\t')   # разделитель полей в TSV-хранилищах (.port-rules, .fullvpn-ips)
# Частные/служебные подсети, которые НЕ заворачиваем в VPN даже в full-tunnel —
# иначе ляжет связность внутри LAN и доступ к самому роутеру. RETURN (не ACCEPT):
# выходим из VPN_FORCE обратно в PREROUTING, где локалку никто не метит (в
# enodia_list/iplist_set только публичные адреса), а стоковый mangle сохраняется.
LOCAL_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4"
# ipset'ы «мимо VPN», которые наполняются ЧУЖИМИ скриптами и dnsmasq'ом по мере резолва их
# доменов. Правило по сету ставим здесь (хозяин цепочки VPN_EXCLUDE — этот скрипт), а наполнение
# живёт своей жизнью. Имена держим ЗДЕСЬ единожды: сюда смотрят и apply_all, и whitelist
# set-dst-ensure — новый сет добавляется ОДНИМ словом в список.
#   grp_out     — именованные группы «мимо VPN» (groups.sh)
#   enodia_bypass  — одиночные домены «мимо VPN» (domain.sh bypass) — зеркало enodia_list
#   geo_out     — гео-категории «мимо VPN» (geo.sh: страны/сервисы из фетч-CIDR)
BYPASS_SETS="grp_out enodia_bypass geo_out"

# --- ПРАВИЛА ПО ПОРТАМ (цепочка VPN_PORTS) ---------------------------------------
# ЗАЧЕМ. До этого «куда идёт устройство» решалось ЦЕЛИКОМ: раздельно / мимо VPN /
# в VPN. Но бывает нужно расщепить сам трафик устройства по портам: консоль/ТВ ходит
# напрямую (скорость, латентность), а её голосовой чат или игровые UDP-порты — через
# VPN (или наоборот: устройство в VPN, но один порт напрямую). Правилами по адресу
# назначения это не выражается — dst у p2p-сессии заранее не известен.
#
# ПОЧЕМУ ОТДЕЛЬНАЯ ЦЕПОЧКА И ПОЧЕМУ ОНА ВЫШЕ VPN_EXCLUDE. Порт-правило СПЕЦИФИЧНЕЕ
# правила по устройству, значит обязано его перебивать. А «мимо VPN» у устройства —
# это `-s IP -j ACCEPT` в VPN_EXCLUDE, и ACCEPT обрывает обход ВСЕЙ таблицы mangle:
# любое правило НИЖЕ него для этого устройства не отрабатывает вообще. Ровно на это
# наступают, когда добавляют MARK руками через SSH: правило видно в `iptables -S`,
# эффекта ноль. Поэтому VPN_PORTS подцеплен ВЫШЕ VPN_EXCLUDE (порядок держит
# ensure_prerouting_order — один владелец на все цепочки).
#
# ФОРМАТ строки хранилища (TSV, 4 поля):
#   src    — IPv4 устройства-источника или `any` (правило на всю LAN)
#   proto  — udp | tcp | both
#   ports  — `all` или список через запятую: `7600`, `3478-3480`, `40000-65535`
#   dir    — vpn (в основной туннель) | direct (напрямую) | s2|s3|s4 (в доп-выход)
#            | block (не выпускать вовсе)
#
# КАК ПРЕВРАЩАЕТСЯ В ПРАВИЛА. dir=vpn/sN — MARK+ACCEPT (парой, как в mark-core: ACCEPT
# обрывает mangle ДО miwifi/NFQUEUE, иначе стоковый демон стёр бы метку — грабля
# mipctld). dir=direct — голый ACCEPT (метки нет ⇒ main-таблица ⇒ провайдер).
# Порт задаётся ЧЕРЕЗ `--dport` без multiport-модуля (диапазон `a:b` умеет сам
# iptables) — на стоке модуля может не быть, а список портов мы и так разворачиваем
# в отдельные правила.
#
# ЗАЧЕМ ЧЕТВЁРТОЕ НАПРАВЛЕНИЕ `block` И ПОЧЕМУ DROP, А НЕ REJECT. Главный потребитель —
# QUIC (udp/443): ByeDPI это socks-прокси, то есть ТОЛЬКО TCP, и браузер по QUIC уезжает
# мимо десинка вообще (половина истории «YouTube не берётся ничем»); у zapret дырки нет —
# там QUIC глушится своим фейком. Погасив udp/443, заставляем клиента откатиться на TLS
# поверх TCP, где десинк работает. REJECT сюда не поставить: это target таблицы FILTER,
# в mangle его нет — а заводить ВТОРУЮ цепочку в filter FORWARD значило бы второго
# владельца порядка и вторую копию локалочной преамбулы ниже. Цена DROP: клиент падает на
# TCP не по ICMP-ответу, а по таймауту хендшейка (браузер после первой неудачи помечает
# QUIC сломанным и дальше идёт по TCP сразу) — задержка разовая, на первое соединение.
#
# ЛОКАЛКА. Цепочка начинается тем же RETURN-преамбулом, что и VPN_FORCE: правило вида
# «весь UDP в VPN» иначе утащило бы туда LAN-LAN трафик (SSDP/mDNS/игры по локалке).
# Трафик к САМОМУ роутеру (DNS на 53/udp!) выводит reply-guard — он стоит ещё выше.
#
# FAIL-OPEN. dir=sN при выключенном доп-выходе = марка есть, `ip rule` под неё нет ⇒
# lookup проваливается в main ⇒ напрямую. Хуже прямого пути не становится.
PORTS_CHAIN=VPN_PORTS
STORE_PORTS="$ENODIA_STATE/.port-rules"

# --- ИСКЛЮЧЕНИЯ ИЗ «МИМО VPN» (цепочка VPN_KEEP) ----------------------------------
# ЗАЧЕМ (жалоба тестера A., 02.08.2026: «мимо впн ИГНОРИРУЕТ этот список»). «Мимо VPN» у
# устройства = `-s IP -j ACCEPT` в VPN_EXCLUDE, а ACCEPT обрывает обход ВСЕЙ mangle ⇒ для
# этого устройства мертвы разом `enodia_list`, `enodia_ip_vpn`, `grp_vpn`, `geo_vpn`, `iplist_set`.
# То есть человек уводит ноутбук напрямую и ТЕРЯЕТ свои же ручные правила «этот сайт — в VPN»;
# обойти это можно было только портами (они и так выше выреза) — а тестеру «одних портов
# оказалось недостаточно». Обратная сторона дыры давно закрыта: «устройство целиком в VPN +
# этот адрес мимо» работает, т.к. VPN_EXCLUDE выше VPN_FORCE. Асимметрия была ровно одна.
#
# ЧТО ДЕЛАЕМ. Ещё одна ступень ВЫШЕ выреза: для помеченных устройств метим трафик, чей dst
# лежит в РУЧНЫХ сетах, и ACCEPT'им (парой, как в VPN_PORTS: ACCEPT обрывает mangle до
# miwifi/NFQUEUE, иначе стоковый демон стёр бы метку — грабля mipctld). Итог для устройства:
# «иду напрямую, но МОИ правила действуют».
#
# ПОЧЕМУ ТОЛЬКО ЭТИ ТРИ СЕТА. `enodia_list` (домены, добавленные руками), `enodia_ip_vpn` (адреса
# «в VPN» руками), `grp_vpn` (именованные группы) — это то, что человек завёл САМ. `iplist_set`
# (~3000 подсетей от opencck) и `geo_vpn` (гео-категории) — МАССОВЫЕ пулы: включив их, мы бы
# вернули устройство в VPN почти целиком и обесценили сам тумблер «мимо VPN». Новый ручной сет
# = ОДНО слово в KEEP_SETS.
#
# ПОРЯДОК. reply-guard → VPN_PORTS → VPN_KEEP → VPN_EXCLUDE → VPN_FORCE. Порты остаются САМЫМИ
# специфичными (порт-правило устройства перебивает и это исключение), владелец порядка —
# ensure_prerouting_order, своих `-I PREROUTING <N>` не заводим.
#
# ПОЯВЛЕНИЕ СЕТОВ ПОЗЖЕ НАС. ipset живёт в RAM: на буте heal зовёт apply-bypass РАНЬШЕ, чем
# groups.sh создаст `grp_vpn`. Правило по несуществующему сету iptables не примет, поэтому
# пропускаем молча, а пересборку зовём ещё и из `set-dst-ensure` — его дёргают groups.sh/
# domain.sh/geo.sh сразу после сборки СВОИХ сетов (тот же приём, что у rule_add_set_dst).
KEEP_CHAIN=VPN_KEEP
STORE_KEEP="$ENODIA_STATE/.keep-vpn-ips"   # IP устройств: «мимо VPN, но ручные правила действуют»
KEEP_SETS="enodia_list enodia_ip_vpn grp_vpn"

# --- УСТРОЙСТВО ЦЕЛИКОМ В ДЕСИНК (4-й режим; NFQUEUE по ИСТОЧНИКУ) -----------------
# ЗАЧЕМ. Десинк (zapret/nfqws) до этого умел ровно одно: «эти АДРЕСА НАЗНАЧЕНИЯ пробиваем» —
# ipset-пулы наполняет dnsmasq по ответам резолвера. Значит устройство со СВОИМ DNS (ТВ, приставка,
# всё с зашитым DoH) в пул не попадает НИКОГДА: на ПК и телефоне работает, на телевизоре нет, и
# сделать с этим было нечего. Правило по ИСТОЧНИКУ от резолвера не зависит вообще — это
# единственный способ дать десинк такому устройству. Оно же закрывает второй отказ движка:
# «направить устройство целиком в zapret-выход» (марки у zapret нет, назначение было бы мёртвым).
#
# ИЗ ЧЕГО СОСТОИТ РЕЖИМ (две половины, у каждой свой владелец):
#   1) ПРЯМОЙ ПУТЬ — `-s IP -j ACCEPT` в VPN_EXCLUDE, ровно как «мимо VPN» (тот же кирпич
#      rule_add_ip). Без него десинк был бы ВРЕДЕН: nfqws кромсал бы пакеты УЖЕ ВНУТРИ туннеля.
#   2) ДЕСИНК — POSTROUTING-NFQUEUE по `-s IP`, ставит zapret.sh (`src-wire`/`src-unwire`).
#      Демон, анти-петля и стратегия — ОБЩИЕ с транспортом и доп-выходами (ref-count у него же).
# Хранилище (список устройств) наше, правила NFQUEUE — его: два владельца, каждый у себя. Ровно
# как с VPN_DEV (реестр у groups.sh, цепочка у нас) — иначе один список парсили бы двое.
#
# ВЗАИМОИСКЛЮЧИТЕЛЬНОСТЬ. Режим устройства ОДИН: включение «в десинк» снимает «мимо VPN»,
# «целиком в VPN» и исключения VPN_KEEP; обратные вербы снимают «в десинк» (desync_drop). Держим
# это в ДВИЖКЕ, а не только в CGI: из CLI набор правил обязан быть так же непротиворечив.
#
# ЧЕСТНАЯ ГРАНИЦА. Десинкуется рукопожатие 443 (TCP+QUIC) — как у всех потребителей nfqws;
# остальной трафик устройства просто идёт напрямую. Нет бинаря nfqws ⇒ движок ОТКАЗЫВАЕТ с
# причиной, а не пишет режим, которого на роутере нет.
STORE_DESYNC="$ENODIA_STATE/.desync-ips"   # IP устройств: «напрямую + десинк рукопожатий» (nfqws по src)
ZAPRET_SH="$ENODIA_DIR/zapret.sh"
# Цепочка ПУЛОВ десинка. Правила внутри ставит и снимает zapret.sh (владелец «что десинкать»), а
# ПОЗИЦИЮ среди прочих — только мы (ensure_prerouting_order, см. ниже): имя обязано быть известно
# обеим сторонам, поэтому живёт здесь, рядом с остальными именами цепочек.
ZAPRET_CHAIN=ENODIA_ZAPRET

# --- ПРАВИЛА УСТРОЙСТВА ПО АДРЕСАМ НАЗНАЧЕНИЯ (цепочка VPN_DEV) --------------------
# ЗАЧЕМ. Ступени выше отвечают на вопрос «куда идёт устройство ЦЕЛИКОМ» (и ещё портами — «а эти
# порты?»). Незакрытым оставался самый частый: «этому ТВ ютуб — через выход №3, остальным как
# обычно». Общие списки/группы/гео действуют на ВСЮ сеть, VPN_KEEP включает их для устройства
# ОПТОМ, а нужен ВЫБОР адресов для ОДНОГО источника.
#
# ЧТО ДЕЛАЕМ. `-s <IP устройства> -m set --match-set grp_dev_<gid> dst -j …`. Сами адреса живут в
# сете, который ведёт groups.sh (правило устройства = группа с непустым src, см. его шапку);
# оттуда же приходит машинный список — верб `dev-rules` (src⇥сет⇥dir⇥slot). Реестр читает ОН,
# цепочку держим МЫ: два владельца, каждый у себя, парсить чужой TSV никто не начинает.
#
# НАПРАВЛЕНИЯ. vpn → MARK 0x1 + ACCEPT (пара обязательна: ACCEPT обрывает mangle до miwifi/NFQUEUE,
# иначе стоковый демон стёр бы метку — грабля mipctld) · sN → та же пара с маркой доп-выхода ·
# bypass → голый ACCEPT (мимо туннеля) · block → DROP (родительский контроль; REJECT в mangle
# нет — см. блок PORTS_CHAIN, там же цена: отлуп по таймауту, а не по ICMP).
#
# ПОРЯДОК: reply-guard → VPN_PORTS → VPN_DEV → VPN_KEEP → VPN_EXCLUDE → VPN_FORCE. Выше выреза и
# режима — иначе ACCEPT «мимо VPN» оборвал бы mangle и правило молча не работало бы (ровно та
# асимметрия, ради которой заводили VPN_KEEP). Ниже портов — порт-правило остаётся самым
# специфичным (там указан и протокол, и порт).
#
# ГЕЙТ ВЫХОДА. Тот же, что у «устройства целиком» (rebuild_force): выход выключен/удалён или это
# zapret ⇒ падаем на ОСНОВНОЙ туннель, а не на «марка есть, ip rule нет» = молча НАПРЯМУЮ.
# Zapret-выход движок не принимает ещё на входе (groups.sh dev-add отвечает отказом с причиной):
# он десинкает по адресам НАЗНАЧЕНИЯ и марку не разбирает, так что правило было бы вечно мёртвым.
DEV_CHAIN=VPN_DEV

# --- одиночные IP/подсети «В VPN» (обратное к .bypass-dst) ------------------------
# ЗАЧЕМ. Для домена было три состояния (в VPN / мимо VPN / нет правила, domain.sh), а для
# адреса — только «мимо VPN» (.bypass-dst). Загнать ОДИН адрес в туннель было нечем: только
# «Свой список IP» (менеджер источников, категория tunnel-cidr) — это блоб на много подсетей
# с перекачкой всех источников, а не «добавить 5.6.7.8». Тестер так и написал: «ip через
# впн — не работают». Теперь ось симметрична доменной.
#
# ПОЧЕМУ ipset, А НЕ ПРАВИЛО НА АДРЕС (как .bypass-dst). Маркировка обязана стоять ВЫШЕ
# miwifi/NFQUEUE (грабля mipctld — иначе метку стирают), и эта логика живёт в mark-core.sh.
# Дублировать её здесь = размножать ядро. mark-core уже метит СПИСОК сетов — добавить туда
# ОДНО слово дешевле и честнее, чем свой MARK-хук. Заодно N адресов = 1 правило (bulk не
# раздувает mangle) и OUTPUT-ветка (трафик самого роутера) достаётся даром.
# Обратное направление (.bypass-dst) остаётся правилами на адрес: там ACCEPT в VPN_EXCLUDE,
# цепочка своя, ядро ни при чём — переписывать рабочее ради симметрии смысла нет.
STORE_VPN_DST="$ENODIA_STATE/.vpn-dst"   # IP/подсети назначения ЦЕЛИКОМ в туннель (по строке)
VPN_DST_SET=enodia_ip_vpn              # его метит mark-core.sh тем же циклом, что enodia_list/grp_vpn

# --- ПОРЯДОК ЦЕПОЧЕК в mangle PREROUTING — ОДИН владелец --------------------------
# Раньше каждая ensure_*_chain вставляла СЕБЯ на фиксированную позицию (VPN_EXCLUDE → 1,
# VPN_FORCE → 2, reply-guard → 1). Пока цепочек было две, порядок случайно сходился: он
# зависел от того, кого позвали ПОСЛЕДНИМ (вставка на позицию 1 сдвигает соседей вниз).
# С третьей цепочкой (VPN_PORTS) это перестало работать — порт-правило уезжало ПОД вырез
# устройства, где ACCEPT из VPN_EXCLUDE уже оборвал обход mangle, и правило молча не
# срабатывало. Поэтому позиция задаётся ровно ЗДЕСЬ и только целиком, снизу вверх:
#   1) reply-guard (dst-LOCAL ACCEPT) — обратный трафик к WAN-IP не метим НИКОГДА
#   2) VPN_PORTS   — правило по портам специфичнее правила по устройству
#   3) VPN_DEV     — правила устройства по адресам назначения («этому ТВ ютуб — в выход №3»)
#   4) VPN_KEEP    — исключения из выреза: «мимо VPN, но МОИ правила действуют»
#   5) VPN_EXCLUDE — вырез «мимо VPN» перебивает force и общий список
#   6) VPN_FORCE   — «целиком в VPN»
#   7) ENODIA_ZAPRET  — пулы десинка «напрямую» (владелец правил внутри — zapret.sh)
# Переставляем ТОЛЬКО уже подцепленные цепочки: у кого нет force/портов, набор правил
# остаётся байт-в-байт прежним. Зовут все ensure_*_chain и верб `order` (им пользуется
# vpn-toggle.sh — его ensure_chain тоже двигает VPN_EXCLUDE на позицию 1).
#
# ПОЧЕМУ ДЕСИНК В САМОМ НИЗУ (ревью 04.08.2026). Его ACCEPT'ы жили прямо в PREROUTING на позиции 1
# мимо этой функции, и приоритет «пул десинка против правил устройства» определял тот, кто отработал
# ПОСЛЕДНИМ. Закрепляем обратный порядок: правила КОНКРЕТНОГО устройства (порты, адреса, keep,
# мимо VPN, целиком в VPN) сильнее ГЛОБАЛЬНОГО пула десинка — иначе, например, порт-правило `block`
# (глушилка QUIC под ByeDPI) вечно мертво для любого dst, попавшего в пул. Пулы при этом
# по-прежнему ВЫШЕ базовой маркировки mark-core, ради чего ACCEPT и заводился.
ensure_prerouting_order() {
    for _c in "$ZAPRET_CHAIN" "$FORCE_CHAIN" "$EXCLUDE_CHAIN" "$KEEP_CHAIN" "$DEV_CHAIN" "$PORTS_CHAIN"; do
        iptables -t mangle -C PREROUTING -j "$_c" 2>/dev/null || continue
        iptables -t mangle -D PREROUTING -j "$_c" 2>/dev/null
        iptables -t mangle -I PREROUTING 1 -j "$_c"
    done
    ensure_reply_guard
}

# chain VPN_EXCLUDE: создать (если нет) и подцепить в PREROUTING+OUTPUT.
# Один-в-один с ensure_chain из vpn-toggle.sh — набор хуков должен совпадать
# (PREROUTING — для LAN-клиентов через роутер, OUTPUT — для трафика самого роутера).
# Позицию в PREROUTING назначает ensure_prerouting_order (см. выше), а не мы: важно
# лишь то, что исключение проверяется РАНЬШЕ mark-правил enodia_list/iplist_set.
ensure_chain() {
    iptables -t mangle -L "$EXCLUDE_CHAIN" -n >/dev/null 2>&1 || \
        iptables -t mangle -N "$EXCLUDE_CHAIN"
    iptables -t mangle -C PREROUTING -j "$EXCLUDE_CHAIN" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -j "$EXCLUDE_CHAIN"
    iptables -t mangle -D OUTPUT -j "$EXCLUDE_CHAIN" 2>/dev/null
    iptables -t mangle -I OUTPUT 1 -j "$EXCLUDE_CHAIN"
    ensure_prerouting_order
}

# --- хранилище (атомарная правка: tmp + mv, чтобы обрыв записи не побил файл) ---
store_add() {   # $1 файл, $2 значение
    [ -z "$2" ] && return 0
    touch "$1"
    # `--` и printf, а не echo: имя сети с ведущим «-» grep прочёл бы ОПЦИЕЙ (а store_del ниже на ошибке grep
    # переписал бы хранилище ПУСТЫМ), echo — съел бы его как флаг.
    grep -qxF -- "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
}
store_del() {   # $1 файл, $2 значение
    [ -f "$1" ] || return 0
    grep -vxF -- "$2" "$1" > "$1.tmp" 2>/dev/null
    mv "$1.tmp" "$1"
}

# --- применение/снятие ОДНОГО правила (идемпотентно) ---
rule_add_ip() {
    iptables -t mangle -C "$EXCLUDE_CHAIN" -s "$1" -j ACCEPT 2>/dev/null || \
        iptables -t mangle -A "$EXCLUDE_CHAIN" -s "$1" -j ACCEPT
}
rule_del_ip() { iptables -t mangle -D "$EXCLUDE_CHAIN" -s "$1" -j ACCEPT 2>/dev/null; }
# dst: исключаем по АДРЕСУ НАЗНАЧЕНИЯ (-d) — это «сайт мимо VPN». ACCEPT в
# VPN_EXCLUDE (цепочка первая в PREROUTING) обрывает обход mangle раньше, чем
# трафик пометится по enodia_list/iplist_set, поэтому перебивает CIDR-список.
rule_add_dst() {
    iptables -t mangle -C "$EXCLUDE_CHAIN" -d "$1" -j ACCEPT 2>/dev/null || \
        iptables -t mangle -A "$EXCLUDE_CHAIN" -d "$1" -j ACCEPT
}
rule_del_dst() { iptables -t mangle -D "$EXCLUDE_CHAIN" -d "$1" -j ACCEPT 2>/dev/null; }
# set-dst: то же «мимо VPN» по назначению, но по ЦЕЛОМУ ipset, а не по одному адресу. Нужен
# группам (groups.sh, сет grp_out) и одиночным доменам «мимо VPN» (domain.sh, сет enodia_bypass):
# оба наполняются динамически — статикой из членов-CIDR и dnsmasq'ом по мере резолва доменов
# (`ipset=/дом/<сет>`), поэтому правило одно, а содержимое живёт своей жизнью. Хозяин цепочки
# VPN_EXCLUDE — этот скрипт, значит и правило ставим здесь (а не в groups.sh/domain.sh), и
# переигрываем в apply_all на boot/repair, как всё остальное.
# Сет может ещё не существовать (ipset живёт в RAM, на boot его создаёт groups.sh/domain.sh apply
# позже) — без него iptables правило не примет, поэтому молча пропускаем: appear-later лечит их apply.
rule_add_set_dst() {
    ipset list -n 2>/dev/null | grep -qx "$1" || return 0
    iptables -t mangle -C "$EXCLUDE_CHAIN" -m set --match-set "$1" dst -j ACCEPT 2>/dev/null || \
        iptables -t mangle -A "$EXCLUDE_CHAIN" -m set --match-set "$1" dst -j ACCEPT
}
# --- «в VPN» по адресу назначения: сет + его маркировка ---------------------------
# hash:net с теми же параметрами, что у groups.sh/domain.sh — сет держит и одиночные адреса,
# и подсети (/32 — частный случай), поэтому add-vpn-dst принимает и то, и другое.
ensure_vpn_dst_set() {
    ipset list -n 2>/dev/null | grep -qx "$VPN_DST_SET" || \
        ipset create "$VPN_DST_SET" hash:net hashsize 1024 maxelem 65536 2>/dev/null
}
# Правило MARK по сету ставит mark-core.sh (там же логика «выше miwifi/NFQUEUE» — дублировать
# её здесь нельзя, это ядро). Но сет создаётся ПОЗЖЕ mark-core: на буте heal зовёт mark-core
# раньше нас, а mark-core ставит правило только для СУЩЕСТВУЮЩЕГО сета. Значит: правила нет →
# зовём mark-core (он идемпотентен). Есть → живой mangle зря не трогаем. Один в один с
# ensure_mark_rule из groups.sh — та же ситуация, то же лечение.
ensure_vpn_dst_mark() {
    iptables -t mangle -C PREROUTING -m set --match-set "$VPN_DST_SET" dst -j MARK --set-mark $FWMARK 2>/dev/null \
        || sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1 || true
}
vpn_dst_add() { ensure_vpn_dst_set; ipset add "$VPN_DST_SET" "$1" 2>/dev/null; ensure_vpn_dst_mark; }
vpn_dst_del() { ipset del "$VPN_DST_SET" "$1" 2>/dev/null; }

# Ключ хранилища для интерфейса, пришедшего от панели: имя СЕТИ, а не удалось опознать (сеть
# выключена, чужой ifname) — само имя интерфейса, ровно как до 04.08.2026.
if_store_key() { wifi_ssid_of "$1" || printf '%s\n' "$1"; }
# $1 — строка хранилища (SSID; legacy — имя интерфейса). Раскрываем в ЖИВЫЕ wlN: у одного имени
# сети их бывает несколько (гостевая 2.4+5 ГГц — одна сеть, две VAP).
rule_add_if() {
    _ain=0
    for _ai in $(wifi_resolve "$1"); do
        iptables -t mangle -C "$EXCLUDE_CHAIN" -m physdev --physdev-in "$_ai" -j ACCEPT 2>/dev/null || \
            iptables -t mangle -A "$EXCLUDE_CHAIN" -m physdev --physdev-in "$_ai" -j ACCEPT || continue
        _ain=$((_ain+1))
    done
    [ "$_ain" -gt 0 ]
}
# Снимаем и по раскрытию, и по САМОЙ строке: строка могла остаться legacy-именем, а сеть —
# переехать на другой wlN (тогда раскрытие даёт новый, а висит правило на старом).
rule_del_if() {
    for _di in $(wifi_resolve "$1") "$1"; do
        case "$_di" in wl[0-9]*) : ;; *) continue ;; esac
        iptables -t mangle -D "$EXCLUDE_CHAIN" -m physdev --physdev-in "$_di" -j ACCEPT 2>/dev/null
        iptables -t mangle -D "$EXCLUDE_CHAIN" -i "$_di" -j ACCEPT 2>/dev/null   # legacy-формат (-i)
    done
    return 0
}
# Снять ВСЕ physdev-правила семьи. Владелец у них ровно один — этот скрипт, поэтому на apply
# честнее собрать семью заново, чем дописывать: иначе правило сети, УЕХАВШЕЙ на другой wlN,
# висело бы до ребута (ровно та грабля, от которой лечим), а хранилище перестало бы быть истиной.
purge_if_rules() {
    iptables -t mangle -S "$EXCLUDE_CHAIN" 2>/dev/null | \
        sed -n 's/^-A [^ ]* -m physdev --physdev-in \([A-Za-z0-9_-][A-Za-z0-9_-]*\) .*/\1/p' | \
        while IFS= read -r _pi; do
            [ -n "$_pi" ] || continue
            iptables -t mangle -D "$EXCLUDE_CHAIN" -m physdev --physdev-in "$_pi" -j ACCEPT 2>/dev/null
        done
    return 0
}
# Миграция хранилища «имя интерфейса → имя сети». Идемпотентна: строка, которую удалось опознать
# как ЖИВОЙ wlN, заменяется на его SSID; всё остальное остаётся как есть (сеть выключена — имя
# трогать нельзя, иначе потеряем правило). Дедуп обязателен: две VAP одной сети дают одну строку.
migrate_if_store() {   # $1 = файл хранилища
    [ -s "$1" ] || return 0
    _mch=0
    : > "$1.tmp" || return 0
    while IFS= read -r _ml || [ -n "$_ml" ]; do
        [ -n "$_ml" ] || continue
        _ms=$(wifi_ssid_of "$_ml") && { _ml="$_ms"; _mch=1; }
        grep -qxF -- "$_ml" "$1.tmp" 2>/dev/null || printf '%s\n' "$_ml" >> "$1.tmp"
    done < "$1"
    if [ "$_mch" = 1 ]; then mv "$1.tmp" "$1"; else rm -f "$1.tmp"; fi
    return 0
}
# СЕМЬЯ «СЕТЬ МИМО VPN» ЗАНОВО ПО ХРАНИЛИЩУ: сперва legacy-имена интерфейсов → имена сетей, затем purge + add — хранилище
# тут единственная истина (см. purge_if_rules). Зовут apply и forget-if: снятие строки сети, которой нет в эфире, раскрытием
# по имени не снимет правило, оставшееся на её ПРЕЖНЕМ интерфейсе (сеть переименовали, wlN теперь у соседней) — а пересборка
# снимет, потому что строки в хранилище больше нет (ревью шага 5b, круг 1).
rebuild_if_rules() {
    migrate_if_store "$STORE_IFS"
    purge_if_rules
    n_if=0
    if [ -f "$STORE_IFS" ]; then
        while IFS= read -r iface || [ -n "$iface" ]; do
            [ -n "$iface" ] && rule_add_if "$iface" && n_if=$((n_if+1))
        done < "$STORE_IFS"
    fi
    return 0
}
# Подцеплены ли наши правила вообще (переход PREROUTING → VPN_EXCLUDE ставит ensure_chain/apply). Нет — VPN выключен до ребута,
# транспорт не выбран (heal пропускает apply), fw3 reload снёс всё до repair: правил сетей в ядре нет ни у одной сети.
if_wired() { iptables -t mangle -S PREROUTING 2>/dev/null | grep -q -- "-j $EXCLUDE_CHAIN\$"; }
# Правила обеих семей «сеть мимо / целиком в VPN» одной строкой на правило — для сравнения до и после.
if_chain_rules() { iptables -t mangle -S "$EXCLUDE_CHAIN" 2>/dev/null; iptables -t mangle -S "$FORCE_CHAIN" 2>/dev/null; }
# Изменилось ли то, что НАПРАВЛЯЕТ трафик: правило живого интерфейса (physdev) либо прочая метка/вырез (не `-j RETURN`, не
# `-N`). Код 0 — да. Разница — строки, которые есть только в одном из снимков (`sort | uniq -u`).
if_change_live() {
    _icd=$( { printf '%s\n' "$1"; printf '%s\n' "$2"; } | sort | uniq -u )
    [ -n "$_icd" ] || return 1
    for _ici in $(printf '%s\n' "$_icd" | sed -n 's/.*--physdev-in \([A-Za-z0-9_.-]*\).*/\1/p'); do
        [ -d "/sys/class/net/$_ici" ] && return 0
    done
    printf '%s\n' "$_icd" | grep -v -e '--physdev-in' -e ' -j RETURN' -e '^-N ' | grep -q .
}
guest_rule_add() {
    ip rule show | grep -q "from $GUEST_SUBNET lookup main" || \
        ip rule add from "$GUEST_SUBNET" lookup main pref $GUEST_PREF
}
guest_rule_del() { ip rule del from "$GUEST_SUBNET" lookup main pref $GUEST_PREF 2>/dev/null; }

# Набор «не блокировать» блокировки по адресам (lists-lib.sh::collect_critical: списки вредоносных адресов и гео-«Блок»)
# держит адреса серверов основного туннеля и выходов. Сменился сервер — набор пересобираем СРАЗУ: прежде новый VPS попадал
# туда только на следующем обновлении списков (сутки-неделя), и сервер, оказавшийся в списке FireHOL, рвал туннель при
# включённой блокировке. Блокировки по адресам нет (набора нет) — пересобирать нечего, и lists-update.sh не зовём вовсе.
allow_sync() {
    ipset list -n 2>/dev/null | grep -qx blocklist_allow || return 0
    [ -f "$ENODIA_DIR/lists-update.sh" ] && sh "$ENODIA_DIR/lists-update.sh" allow-sync >/dev/null 2>&1
    return 0
}

# --- endpoint активной несущей мимо VPN (анти-петля, см. шапку про .endpoint-bypass) ---
# Replace-семантика: храним ОДИН IP (endpoint активной несущей). Зовётся из
# transport-*.sh up (а switch-vpn делегирует в transport-awg up -> покрыты и смена
# страны/конфига, и failover, и кросс-смена транспорта). Пустой $1 = снять исключение.
endpoint_set() {   # $1 = IPv4 endpoint'а (пусто = снять)
    ensure_chain
    new="$1"
    # Снять прежний авто-endpoint — КРОМЕ совпадающего с новым и КРОМЕ адреса, чей ACCEPT
    # принадлежит не нам. Арбитр общий с семьёй слотов (_ep_needed_elsewhere): раньше здесь
    # проверялся только юзер-вырез .bypass-dst, и если ОДИН и тот же VPS несёт основную несущую и
    # доп-выход (частый случай — сервер один, конфигов два), смена основного сервера снимала
    # правило вместе с анти-петлёй СЛОТА: его endpoint снова попадал под маркировку, и хендшейк
    # уезжал в туннель. Симптом тот же, что в [[endpoint-in-iplist-loop]], только у доп-выхода.
    if [ -f "$STORE_EP" ]; then
        while IFS= read -r old; do
            [ -z "$old" ] && continue
            [ "$old" = "$new" ] && continue
            _ep_needed_elsewhere "$old" "$STORE_EP" && continue
            rule_del_dst "$old"
        done < "$STORE_EP"
    fi
    : > "$STORE_EP"
    [ -z "$new" ] && { echo "[apply-bypass] endpoint-исключение снято"; return 0; }
    # строго IPv4 — в VPN_EXCLUDE кладём только числовой адрес (не имя: iptables -d
    # с именем резолвит ОДИН раз и может уйти в дохлый туннель; имя резолвит несущая).
    echo "$new" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || {
        echo "[apply-bypass] endpoint '$new' не IPv4 — пропуск"; return 0; }
    echo "$new" > "$STORE_EP"
    rule_add_dst "$new"
    allow_sync
    ct_flush_dst "$new"                              # сбросить уже зациклившиеся сессии к VPS
    echo "[apply-bypass] endpoint $new -> мимо VPN (анти-петля)"
}

# --- endpoint ДОП-ВЫХОДА (слота) мимо VPN (анти-петля, мульти-транспорт Ф2) --------------
# endpoint_set выше хранит РОВНО один IP (основной несущей). У доп-выходов (slots.sh) СВОЯ
# несущая awgN/xtunN с СВОИМ endpoint'ом VPS — его тоже надо вывести из-под маркировки (иначе
# router-локальные UDP к этому VPS, если его IP ∈ iplist_set/слот-сете, завернутся в туннель =
# петля, ровно как у основного, [[endpoint-in-iplist-loop]]). Но затирать основной .endpoint-bypass
# нельзя — поэтому per-slot store `.endpoint-bypass-s<id>` и АДДИТИВНОЕ правило. Правило (ACCEPT в
# VPN_EXCLUDE) по dst-IP то же самое, что у основного — снимаем СТАРЫЙ endpoint слота только если он
# больше НИГДЕ не нужен (ни основному, ни другому слоту, ни юзер-вырезу .bypass-dst), иначе оборвём
# чужую анти-петлю. Зовёт transport-*.sh slot-up/slot-down (авто, как endpoint-set у основного).
STORE_EP_SLOT_PREFIX="$ENODIA_STATE/.endpoint-bypass-s"

# Нужен ли этот IP-endpoint ещё где-то (кроме store $2) — тогда его ACCEPT-правило НЕ снимаем.
_ep_needed_elsewhere() {   # $1=ip  $2=свой store (исключить из проверки)
    _ip="$1"; _self="$2"
    # `$_self` исключаем и для ОСНОВНОГО store: арбитром пользуется и endpoint_set, а без этой
    # проверки он всегда находил бы адрес «нужным» в собственном файле и не снимал бы правило НИКОГДА.
    [ "$STORE_EP" != "$_self" ] && grep -qxF "$_ip" "$STORE_EP" 2>/dev/null && return 0   # основной endpoint
    grep -qxF "$_ip" "$STORE_DST" 2>/dev/null && return 0     # осознанный юзер-вырез «мимо VPN»
    for _f in "${STORE_EP_SLOT_PREFIX}2" "${STORE_EP_SLOT_PREFIX}3" "${STORE_EP_SLOT_PREFIX}4"; do
        [ "$_f" = "$_self" ] && continue
        grep -qxF "$_ip" "$_f" 2>/dev/null && return 0        # endpoint другого слота
    done
    return 1
}

endpoint_slot_set() {   # $1 = id слота (2..4); $2 = IPv4 endpoint'а (пусто = снять)
    ensure_chain
    _sid="$1"; new="$2"
    case "$_sid" in 2|3|4) ;; *) echo "[apply-bypass] endpoint-slot: id = 2..4"; return 1 ;; esac
    store="${STORE_EP_SLOT_PREFIX}${_sid}"
    # снять прежний endpoint этого слота (если он есть, отличается от нового и больше нигде не нужен)
    if [ -f "$store" ]; then
        old=$(head -1 "$store" 2>/dev/null | tr -d ' \r\n')
        if [ -n "$old" ] && [ "$old" != "$new" ]; then
            _ep_needed_elsewhere "$old" "$store" || rule_del_dst "$old"
        fi
    fi
    : > "$store"
    if [ -z "$new" ]; then rm -f "$store"; echo "[apply-bypass] endpoint слота №$_sid снят"; return 0; fi
    echo "$new" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || {
        rm -f "$store"; echo "[apply-bypass] endpoint слота №$_sid '$new' не IPv4 — пропуск"; return 0; }
    echo "$new" > "$store"
    rule_add_dst "$new"
    allow_sync
    ct_flush_dst "$new"
    echo "[apply-bypass] endpoint слота №$_sid $new -> мимо VPN (анти-петля)"
}

# --- VPN_FORCE: «целиком через VPN» (см. шапку про force) -------------------
# reply-guard (dst-LOCAL ACCEPT) обязан стоять ВЫШЕ VPN_FORCE catch-all и MARK-правил.
# Любая перестановка цепочек ЗАДВИГАЕТ guard (его ставит mark-core поз.1) вниз. Тогда FORCE
# catch-all (-j MARK на весь форвард в full-tunnel) метит ОТВЕТНЫЙ пакет прямого соединения
# с dst=WAN-IP (адрес LOCAL) РАНЬШЕ guard → возврат уезжает в туннель = рвётся прямой трафик
# вырезов/excluded-устройств (ровно та грабля, ради которой guard и вводили, mark-core.sh).
# Переустанавливаем guard ПЕРВЫМ правилом ПОСЛЕ перестройки порядка (хвост
# ensure_prerouting_order). Идемпотентно; addrtype как в mark-core (нет модуля → тихо
# no-op, поведение как без guard).
# ДУБЛЬ С mark-core.sh — ОСОЗНАННЫЙ (единственный в проекте). Канонический владелец правила и
# честного сообщения о недоступном addrtype — ядро; здесь ровно две строки, потому что порядок
# цепочек переигрывается на КАЖДЫЙ ensure_*_chain (десятки раз за один apply), а звать оттуда
# mark-core значило бы каждый раз перекладывать ВСЮ маркировку. Правка одного — правка обоих.
ensure_reply_guard() {
    while iptables -t mangle -D PREROUTING -m addrtype --dst-type LOCAL -j ACCEPT 2>/dev/null; do :; done
    iptables -t mangle -I PREROUTING 1 -m addrtype --dst-type LOCAL -j ACCEPT 2>/dev/null
}

# chain VPN_FORCE: создать (если нет) и подцепить в PREROUTING. Только PREROUTING:
# трафик самого роутера (OUTPUT — handshake к endpoint, DNS к VPS) в туннель заворачивать
# нельзя, будет петля. Позицию (ниже VPN_EXCLUDE) назначает ensure_prerouting_order.
ensure_force_chain() {
    iptables -t mangle -L "$FORCE_CHAIN" -n >/dev/null 2>&1 || \
        iptables -t mangle -N "$FORCE_CHAIN"
    iptables -t mangle -C PREROUTING -j "$FORCE_CHAIN" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -j "$FORCE_CHAIN"
    ensure_prerouting_order
}

# Есть ли вообще что форсить в VPN? Если нет — VPN_FORCE не вешаем вовсе, чтобы
# у тех, кто полным туннелем не пользуется, набор правил остался прежним (split).
force_active() {
    [ -f "$FULLTUNNEL_FLAG" ]   && return 0
    [ -s "$STORE_FORCE_IPS" ]   && return 0
    [ -s "$STORE_FORCE_IFS" ]   && return 0
    [ -f "$STORE_FORCE_GUEST" ] && return 0
    return 1
}

# Доп-выходы, чья МАРКА реально работает: включённые и НЕ zapret (тот десинкает по адресам
# НАЗНАЧЕНИЯ и марку не разбирает — `ip rule` под 0xN для него не создаётся). Печатает « 2 3 »,
# рамочные пробелы — чтобы проверять принадлежность через case.
# ОДИН источник на обе семьи правил по источнику: «устройство целиком» (rebuild_force) и «адреса
# устройства» (rebuild_dev). Разъехавшись, эти два списка дали бы «здесь выход учли, а здесь
# молча напрямую» — самый дорогой вид расхождения, он не виден в панели вообще.
mark_slots() {
    [ -f "$ENODIA_DIR/slots.sh" ] || { printf ' '; return 0; }
    printf ' %s' "$(sh "$ENODIA_DIR/slots.sh" list-enabled 2>/dev/null | awk -F"$TAB" '$2!="zapret"{print $1}' | tr '\n' ' ')"
}

# Пересобрать VPN_FORCE из хранилища (идемпотентно: flush + заново в нужном
# порядке). Порядок ВНУТРИ цепочки важен: сперва вывести локалку (RETURN), затем
# точечный force (устройства/iface/guest), и в самом конце — глобальный catch-all.
#
# КАЖДЫЙ MARK здесь идёт В ПАРЕ С ACCEPT — ровно как в rebuild_dev/rebuild_keep/port_rule_add
# (ревью 04.08.2026: эта цепочка была ЕДИНСТВЕННОЙ с голым MARK). Две причины, обе молчаливые:
#   * VPN_FORCE стоит ПОСЛЕДНЕЙ в порядке цепочек, а ниже неё идёт базовый цикл mark-core
#     (`enodia_list iplist_set grp_vpn enodia_ip_vpn geo_vpn` → MARK 0x1). Без ACCEPT марка ДОП-ВЫХОДА
#     (0x2..0x4) переписывается на 0x1 ровно для тех адресов, ради которых выход и заводили
#     (iplist_set = тысячи подсетей заблок-сервисов) ⇒ «устройство целиком в выход №N» едет
#     ОСНОВНЫМ туннелем: правило в цепочке есть, счётчики растут, эффекта нет;
#   * на роутерах с mipctld/ipt_compiler метку стирает стоковый NFQUEUE (грабля mipctld, от
#     которой ядро закрыто парой MARK+ACCEPT выше инспекции, а эта цепочка не была).
# ЦЕНА ACCEPT, честно: он обрывает обход mangle ⇒ трафик выходит из-под стоковых цепочек Xiaomi
# (родконтроль/QoS/антивирус). Для точечных правил это плевок, для catch-all `full-tunnel` — весь
# форвард дома. Пару ставим и там СОЗНАТЕЛЬНО: (1) четыре соседние цепочки (PORTS/DEV/KEEP/EXCLUDE)
# уже так работают — исключение только запутывало бы; (2) при «весь дом в VPN» инспекция Xiaomi
# всё равно смотрит на трафик, который целиком уезжает в туннель; (3) без ACCEPT режим на таких
# роутерах молча вырождается в «в VPN идут только заблокированные» — то есть НЕ делает обещанного.
rebuild_force() {
    if ! force_active; then
        # ничего не форсим — снять jump и очистить, вернуть чистый split
        iptables -t mangle -D PREROUTING -j "$FORCE_CHAIN" 2>/dev/null
        iptables -t mangle -F "$FORCE_CHAIN" 2>/dev/null
        echo "[apply-bypass] force(в VPN): выключено (раздельный режим)"
        return 0
    fi
    ensure_chain          # VPN_EXCLUDE должен существовать: порядок цепочек их сводит вместе
    ensure_force_chain
    iptables -t mangle -F "$FORCE_CHAIN"
    # 1) локалку/служебное — наружу из цепочки (остаётся в прямом/локальном пути)
    for net in $LOCAL_NETS; do
        iptables -t mangle -A "$FORCE_CHAIN" -d "$net" -j RETURN
    done
    iptables -t mangle -A "$FORCE_CHAIN" -d 255.255.255.255 -j RETURN
    n_fip=0; n_fif=0; fg=off; ft=off
    # 2) устройства (источник) целиком в VPN — основным туннелем (0x1) либо ДОП-ВЫХОДОМ (0xN).
    # Марку слота дальше обслуживает mark-core (`ip rule fwmark 0xN -> table 100N`, fallback-aware) —
    # своего PBR тут не заводим. ГЕЙТ по ВКЛЮЧЁННЫМ выходам — зеркало groups.sh: выход выключен или
    # удалён ⇒ падаем на ОСНОВНОЙ туннель, а не на «марка есть, ip rule нет» = молча НАПРЯМУЮ.
    # Для порт-правила такой fail-open принят сознательно (там правило узкое), но «весь ноутбук
    # незаметно вышел мимо VPN» — совсем другая цена ошибки.
    # ZAPRET-выход в этот список НЕ входит (поймано на железе 03.08): он единственный работает
    # БЕЗ марки — ACCEPT + scoped NFQUEUE по своим сетам, т.е. по адресу НАЗНАЧЕНИЯ. `ip rule`
    # под 0xN для него не создаётся, поэтому «устройство целиком через zapret-выход» уехало бы
    # напрямую и БЕЗ десинка — то есть тише и хуже, чем основной туннель. Гейт держим и здесь,
    # а не только в панели: движок обязан быть безопасен и из CLI.
    _en_slots=$(mark_slots)
    _fdown=""
    if [ -f "$STORE_FORCE_IPS" ]; then
        while IFS="$TAB" read -r ip fslot; do
            [ -n "$ip" ] || continue
            # В iptables уходит подстановка (зеркало rebuild_keep/rebuild_dev): битая строка
            # хранилища не должна ни ронять сборку цепочки, ни утаскивать в правило мусор.
            echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || continue
            _fmk=$FWMARK
            case "$fslot" in
                s[234])
                    case "$_en_slots" in
                        *" ${fslot#s} "*) _fmk="0x${fslot#s}" ;;
                        *) _fdown="$_fdown $ip->$fslot" ;;
                    esac ;;
            esac
            iptables -t mangle -A "$FORCE_CHAIN" -s "$ip" -j MARK --set-mark "$_fmk" || continue
            iptables -t mangle -A "$FORCE_CHAIN" -s "$ip" -j ACCEPT
            n_fip=$((n_fip+1))
        done < "$STORE_FORCE_IPS"
    fi
    # 3) Wi-Fi iface (SSID) целиком в VPN — physdev (wlN живёт в bridge, см.
    #    комментарий про physdev в шапке про bypass-ifaces / vpn-toggle.sh)
    # Строка — имя СЕТИ (см. шапку): раскрываем в живые wlN. Цепочка тут пересобирается с нуля
    # (-F выше), поэтому своего purge не нужно — достаточно миграции хранилища.
    migrate_if_store "$STORE_FORCE_IFS"
    if [ -f "$STORE_FORCE_IFS" ]; then
        while IFS= read -r iface || [ -n "$iface" ]; do
            [ -n "$iface" ] || continue
            for _ffi in $(wifi_resolve "$iface"); do
                iptables -t mangle -A "$FORCE_CHAIN" -m physdev --physdev-in "$_ffi" -j MARK --set-mark $FWMARK || continue
                iptables -t mangle -A "$FORCE_CHAIN" -m physdev --physdev-in "$_ffi" -j ACCEPT
                n_fif=$((n_fif+1))
            done
        done < "$STORE_FORCE_IFS"
    fi
    # 4) гостевая целиком в VPN (по источнику-подсети)
    if [ -f "$STORE_FORCE_GUEST" ]; then
        iptables -t mangle -A "$FORCE_CHAIN" -s "$GUEST_SUBNET" -j MARK --set-mark $FWMARK
        iptables -t mangle -A "$FORCE_CHAIN" -s "$GUEST_SUBNET" -j ACCEPT
        fg=on
    fi
    # 5) ГЛОБАЛЬНО: весь остальной (нелокальный) форвард — в VPN. Должен идти
    #    ПОСЛЕДНИМ, после локалки-RETURN и точечных правил.
    if [ -f "$FULLTUNNEL_FLAG" ]; then
        iptables -t mangle -A "$FORCE_CHAIN" -j MARK --set-mark $FWMARK
        iptables -t mangle -A "$FORCE_CHAIN" -j ACCEPT
        ft=on
    fi
    echo "[apply-bypass] force(в VPN): ip=$n_fip, iface=$n_fif, guest=$fg, full-tunnel=$ft${_fdown:+, выход выключен (идут основным):$_fdown}"
}

# Переписать строку устройства в хранилище force: ключ — IP, направление ОДНО (иначе накопились
# бы две строки на один адрес и молча выигрывала бы верхняя). Сравнение по ПЕРВОМУ ПОЛЮ, поэтому
# обе формы строки (`IP` и `IP<TAB>sN`) снимаются одинаково.
force_store_set() {   # $1 = IP, $2 = пусто (основной) | sN
    touch "$STORE_FORCE_IPS"
    awk -F"$TAB" -v ip="$1" '$1!=ip' "$STORE_FORCE_IPS" > "$STORE_FORCE_IPS.tmp" 2>/dev/null
    mv "$STORE_FORCE_IPS.tmp" "$STORE_FORCE_IPS"
    if [ -n "$2" ]; then printf '%s\t%s\n' "$1" "$2" >> "$STORE_FORCE_IPS"
    else printf '%s\n' "$1" >> "$STORE_FORCE_IPS"; fi
}
force_store_del() {   # $1 = IP (обе формы строки)
    [ -f "$STORE_FORCE_IPS" ] || return 0
    awk -F"$TAB" -v ip="$1" '$1!=ip' "$STORE_FORCE_IPS" > "$STORE_FORCE_IPS.tmp" 2>/dev/null
    mv "$STORE_FORCE_IPS.tmp" "$STORE_FORCE_IPS"
}

# Сбросить conntrack, чтобы смена режима применилась к УЖЕ установленным
# соединениям сразу (Qualcomm NSS/ECM иначе держит старый маршрут до таймаута).
# Кратко рвёт активные сессии — это норма для
# осознанного переключения режима. Полный flush (не точечный): full-tunnel/iface/
# guest точечно по src не выберешь.
#
# ЗОВУТ ОБЕ СЕМЬИ — и force-*, и вырезы «мимо VPN». Долгое время flush стоял ТОЛЬКО в
# force-* (её писали позже, уже зная про NSS), а add-dst/add-ip/add-if/guest молча его
# не делали → правило в VPN_EXCLUDE появлялось, но трафик к адресу продолжал идти в
# туннель. Доказано на железе 2026-07-15: `add-dst <IP Cloudflare>` → egress остался
# VPS 192.0.2.198; тот же самый набор правил + `conntrack -F` → egress сразу ISP.
# Это и есть жалоба тестера «ip мимо впн — не работают»: пользователь видел правило в
# списке и нулевой эффект. Имя без префикса force_ — функция общая (см. грабли карты проекта:
# после ЛЮБОГО iptables-изменения для УЖЕ установленных соединений conntrack обязателен).
# Сам сброс делает ct-lib.sh (единственный владелец: где-то есть утилита, где-то только ручка
# ускорителя) — здесь остаётся ИМЯ, которым эту причину зовут вырезы и force-семьи.
conntrack_flush() { ct_flush; }

# --- правила по портам (VPN_PORTS): разбор хранилища -> iptables --------------------
# Формат строки и семантика — в шапке блока PORTS_CHAIN выше.
ensure_ports_chain() {
    iptables -t mangle -L "$PORTS_CHAIN" -n >/dev/null 2>&1 || \
        iptables -t mangle -N "$PORTS_CHAIN"
    iptables -t mangle -C PREROUTING -j "$PORTS_CHAIN" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -j "$PORTS_CHAIN"
    ensure_prerouting_order
}

# Поля правила по портам (port_src_ok/port_proto_ok/port_list_ok/port_dir_ok, port_list_norm) — в
# port-lib.sh: их же читают devwatch.sh и cgi-bin/data, копия здесь разошлась бы с ними.
# Адрес НАЗНАЧЕНИЯ правила: одиночный IPv4 либо подсеть. Валидация в ДВИЖКЕ, а не только в CGI
# (зеркало force-add-ip/keep-add-ip/port-add): в iptables и в ipset уходит подстановка, а мусор,
# записанный в хранилище, потом молча выпадал бы из каждой пересборки — правило видно, эффекта нет.
dst_ok()        { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; }
# Одно правило: $1 src, $2 proto (уже развёрнут в udp|tcp), $3 спецификация порта
# (`all` = без --dport), $4 марка (пусто = только ACCEPT, т.е. напрямую; слово `block` =
# не выпускать вовсе — с шестнадцатеричной маркой `0x…` оно не спутается).
port_rule_add() {
    _s=""; [ "$1" = any ] || _s="-s $1"
    _d=""; [ "$3" = all ] || _d="--dport $(echo "$3" | tr '-' ':')"
    # Блокировка — терминальный DROP вместо пары MARK+ACCEPT (почему DROP, а не REJECT —
    # в шапке блока PORTS_CHAIN). Локалка и трафик к самому роутеру сюда не доходят:
    # их выводят RETURN-преамбула цепочки и reply-guard выше неё.
    if [ "$4" = block ]; then
        # shellcheck disable=SC2086 # $_s/$_d намеренно разбиваются на аргументы
        iptables -t mangle -A "$PORTS_CHAIN" $_s -p "$2" $_d -j DROP 2>/dev/null || return 1
        return 0
    fi
    # dir=vpn/sN: MARK и СРАЗУ ACCEPT — пара обязательна (ACCEPT обрывает mangle до
    # miwifi/NFQUEUE, который иначе стёр бы метку; грабля mipctld, см. mark-core.sh).
    if [ -n "$4" ]; then
        # shellcheck disable=SC2086 # $_s/$_d намеренно разбиваются на аргументы
        iptables -t mangle -A "$PORTS_CHAIN" $_s -p "$2" $_d -j MARK --set-mark "$4" 2>/dev/null || return 1
    fi
    iptables -t mangle -A "$PORTS_CHAIN" $_s -p "$2" $_d -j ACCEPT 2>/dev/null || return 1
    return 0
}

# Пересобрать VPN_PORTS из хранилища (идемпотентно: flush + заново, как rebuild_force).
rebuild_ports() {
    if [ ! -s "$STORE_PORTS" ]; then
        # нет правил — снять jump и очистить: у тех, кто портами не пользуется,
        # набор правил остаётся ровно прежним (тот же приём, что в rebuild_force)
        iptables -t mangle -D PREROUTING -j "$PORTS_CHAIN" 2>/dev/null
        iptables -t mangle -F "$PORTS_CHAIN" 2>/dev/null
        echo "[apply-bypass] порт-правила: нет"
        return 0
    fi
    # Без разборщика строк цепочку НЕ трогаем: сброс с пустой пересборкой снял бы все правила по портам молча.
    if ! command -v port_rules_in_order >/dev/null 2>&1; then
        echo "[apply-bypass] порт-правила: нет port-lib.sh — прежняя цепочка оставлена"
        return 1
    fi
    ensure_ports_chain
    iptables -t mangle -F "$PORTS_CHAIN"
    # локалку — наружу из цепочки (иначе «весь UDP в VPN» утащит туда LAN-LAN:
    # SSDP/mDNS/игры по локальной сети). Трафик к самому роутеру (DNS 53/udp)
    # выводит reply-guard, он стоит ВЫШЕ этой цепочки.
    for _net in $LOCAL_NETS; do
        iptables -t mangle -A "$PORTS_CHAIN" -d "$_net" -j RETURN
    done
    iptables -t mangle -A "$PORTS_CHAIN" -d 255.255.255.255 -j RETURN
    _n=0; _tab=$(printf '\t')
    # Строки — в ПОРЯДКЕ ЦЕПОЧКИ и только действующие (port-lib.sh::port_rules_in_order): сперва правила
    # устройств, потом всего роутера. Тот же порядок и тот же фильтр читает devwatch.sh::load_port_rules
    # («что победит» и строки «Что запрашивает») — потому он и живёт в одном месте.
    # Цикл по here-doc (не пайп) — в текущем шелле, счётчик не теряется. Оборотная сторона:
    # переменные цикла ЖИВУТ в шелле вызывающего и на EOF обнуляются последним read. Поэтому
    # имена намеренно СВОИ (_l*): совпади они с $_src/$_dir из ветки port-add — та печатала бы
    # пустое «порт-правило:  udp 443 -> », а точечный conntrack по IP выродился бы в общий flush.
    _lrows=$(port_rules_in_order "$STORE_PORTS")
    while IFS="$_tab" read -r _lsrc _lpro _lpts _ldir; do
        [ -n "$_ldir" ] || continue
        case "$_ldir" in
            vpn)      _mk=$FWMARK ;;
            s2|s3|s4) _mk="0x${_ldir#s}" ;;  # марка доп-выхода; ip rule под неё ставит mark-core
            block)    _mk=block ;;           # не выпускать вовсе — DROP вместо MARK+ACCEPT
            *)        _mk="" ;;              # direct — без метки, main-таблица
        esac
        case "$_lpro" in both) _prl="udp tcp" ;; *) _prl="$_lpro" ;; esac
        for _pr in $_prl; do
            for _pt in $(echo "$_lpts" | tr ',' ' '); do
                port_rule_add "$_lsrc" "$_pr" "$_pt" "$_mk" && _n=$((_n+1))
            done
        done
    done <<EOF_PORTS
$_lrows
EOF_PORTS
    echo "[apply-bypass] порт-правила: $_n"
}

# --- исключения из «мимо VPN» (VPN_KEEP): хранилище -> iptables ---------------------
# Семантика и выбор сетов — в шапке блока KEEP_CHAIN выше.
ensure_keep_chain() {
    iptables -t mangle -L "$KEEP_CHAIN" -n >/dev/null 2>&1 || \
        iptables -t mangle -N "$KEEP_CHAIN"
    iptables -t mangle -C PREROUTING -j "$KEEP_CHAIN" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -j "$KEEP_CHAIN"
    ensure_prerouting_order
}

# Пересобрать VPN_KEEP из хранилища (идемпотентно: flush + заново, как rebuild_ports).
# Пустое хранилище ⇒ цепочки нет вовсе: у того, кто тумблером не пользуется, набор правил
# остаётся БАЙТ-В-БАЙТ прежним (тот же приём, что в rebuild_force/rebuild_ports).
rebuild_keep() {
    if [ ! -s "$STORE_KEEP" ]; then
        iptables -t mangle -D PREROUTING -j "$KEEP_CHAIN" 2>/dev/null
        iptables -t mangle -F "$KEEP_CHAIN" 2>/dev/null
        echo "[apply-bypass] исключения из «мимо VPN»: нет"
        return 0
    fi
    ensure_keep_chain
    iptables -t mangle -F "$KEEP_CHAIN"
    _kn=0; _kskip=""
    while IFS= read -r _kip; do
        [ -n "$_kip" ] || continue
        echo "$_kip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || continue   # в iptables уходит подстановка
        # Устройство, снятое с «мимо VPN», в этой цепочке не нужно: там оно и так метится
        # общим ядром, а лишняя пара правил только путала бы диагностику.
        grep -qxF "$_kip" "$STORE_IPS" 2>/dev/null || continue
        for _ks in $KEEP_SETS; do
            ipset list -n 2>/dev/null | grep -qx "$_ks" || { case "$_kskip" in *" $_ks"*) ;; *) _kskip="$_kskip $_ks" ;; esac; continue; }
            iptables -t mangle -A "$KEEP_CHAIN" -s "$_kip" -m set --match-set "$_ks" dst -j MARK --set-mark $FWMARK 2>/dev/null || continue
            iptables -t mangle -A "$KEEP_CHAIN" -s "$_kip" -m set --match-set "$_ks" dst -j ACCEPT 2>/dev/null
            _kn=$((_kn+1))
        done
    done < "$STORE_KEEP"
    # «Сет ещё не создан» — норма на буте (см. шапку): сообщаем, но не ругаемся.
    echo "[apply-bypass] исключения из «мимо VPN»: правил $_kn${_kskip:+, сетов ещё нет:$_kskip}"
}

# --- устройство целиком в десинк: хранилище -> ACCEPT + NFQUEUE по источнику ---------
# Семантика и разделение владельцев — в шапке блока STORE_DESYNC выше.
# Идемпотентно и СВЕРКОЙ, а не «снести и налить»: сперва снимаем проводку устройств, которых в
# хранилище больше нет (истина про правила — mangle, `zapret.sh src-list`), потом дописываем свои.
# Перестраивать всё целиком было бы дороже и заметнее: снятие NFQUEUE у живого устройства рвёт
# ему текущие сессии, а на буте нас зовут раньше, чем поднимется несущая.
rebuild_desync() {
    [ -f "$ZAPRET_SH" ] || { [ -s "$STORE_DESYNC" ] && echo "[apply-bypass] десинк устройств: нет zapret.sh — пропуск"; return 0; }
    _wired=$(sh "$ZAPRET_SH" src-list 2>/dev/null)
    for _old in $_wired; do
        grep -qxF "$_old" "$STORE_DESYNC" 2>/dev/null && continue
        sh "$ZAPRET_SH" src-unwire "$_old" >/dev/null 2>&1
        # Снять и ВТОРУЮ половину режима — ACCEPT «идти напрямую». Ловушка (поймана на железе
        # 04.08.2026 первым же прогоном): без этого устройство оставалось выведенным из туннеля,
        # но уже без десинка — то есть тихо получало ХУДШИЙ из режимов, которого никто не просил.
        # Гард по .bypass-ips обязателен: тот же ACCEPT может принадлежать режиму «мимо VPN».
        grep -qxF "$_old" "$STORE_IPS" 2>/dev/null || rule_del_ip "$_old"
    done
    [ -s "$STORE_DESYNC" ] || { echo "[apply-bypass] десинк устройств: нет"; return 0; }
    _dsn=0; _dsfail=""
    while IFS= read -r _dsip; do
        [ -n "$_dsip" ] || continue
        echo "$_dsip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || continue   # в iptables уходит подстановка
        # Прямой путь — тем же кирпичом, что «мимо VPN» (цепочка VPN_EXCLUDE): десинк имеет смысл
        # ТОЛЬКО вне туннеля. Идемпотентен, второй раз ничего не добавит.
        rule_add_ip "$_dsip"
        if sh "$ZAPRET_SH" src-wire "$_dsip" >/dev/null 2>&1; then _dsn=$((_dsn+1))
        else _dsfail="$_dsfail $_dsip"; fi
    done < "$STORE_DESYNC"
    # Провал src-wire = нет бинаря nfqws (или ядро не приняло NFQUEUE). Устройство при этом идёт
    # НАПРЯМУЮ, но без десинка — молчать об этом нельзя: в панели режим виден, а эффекта нет.
    echo "[apply-bypass] десинк устройств: $_dsn${_dsfail:+, БЕЗ десинка (нет nfqws?):$_dsfail}"
}
# Снять «в десинк» с адреса, если он там был (зовут противоположные вербы: режим устройства ОДИН).
desync_drop() {   # $1 = IP
    [ -s "$STORE_DESYNC" ] || return 0
    grep -qxF "$1" "$STORE_DESYNC" 2>/dev/null || return 0
    store_del "$STORE_DESYNC" "$1"
    [ -f "$ZAPRET_SH" ] && sh "$ZAPRET_SH" src-unwire "$1" >/dev/null 2>&1
    return 0
}

# --- правила устройства по адресам назначения (VPN_DEV): groups.sh -> iptables -------
# Семантика, порядок и гейт выхода — в шапке блока DEV_CHAIN выше.
ensure_dev_chain() {
    iptables -t mangle -L "$DEV_CHAIN" -n >/dev/null 2>&1 || \
        iptables -t mangle -N "$DEV_CHAIN"
    iptables -t mangle -C PREROUTING -j "$DEV_CHAIN" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -j "$DEV_CHAIN"
    ensure_prerouting_order
}

# Пересобрать VPN_DEV (идемпотентно: flush + заново, как rebuild_ports/rebuild_keep).
# Источник — `groups.sh dev-rules`: реестр правил ведёт ОН, мы держим цепочку. Пусто ⇒ цепочки нет
# вовсе: у того, кто правилами устройства не пользуется, набор правил БАЙТ-В-БАЙТ прежний.
rebuild_dev() {
    _drules=$(sh "$ENODIA_DIR/groups.sh" dev-rules 2>/dev/null)
    if [ -z "$_drules" ]; then
        iptables -t mangle -D PREROUTING -j "$DEV_CHAIN" 2>/dev/null
        iptables -t mangle -F "$DEV_CHAIN" 2>/dev/null
        echo "[apply-bypass] правила устройств (адреса): нет"
        return 0
    fi
    ensure_dev_chain
    iptables -t mangle -F "$DEV_CHAIN"
    # Локалку — наружу из цепочки: правило «эти адреса блокировать» не должно задевать связь
    # внутри LAN, а «в VPN» — утаскивать её в туннель (зеркало преамбулы VPN_PORTS/VPN_FORCE).
    # Трафик к САМОМУ роутеру выводит reply-guard, он стоит выше.
    for _net in $LOCAL_NETS; do
        iptables -t mangle -A "$DEV_CHAIN" -d "$_net" -j RETURN
    done
    iptables -t mangle -A "$DEV_CHAIN" -d 255.255.255.255 -j RETURN
    _dn=0; _dskip=""; _ddown=""
    _en_slots=$(mark_slots)
    # `done < файл` (не пайп): цикл в текущем шелле, счётчики не теряются. Имена переменных СВОИ
    # (_d*), чтобы не затирать переменные вызывающей ветки (грабля из rebuild_ports).
    _dtmp=/tmp/.enodia-dev-rules.$$
    printf '%s\n' "$_drules" > "$_dtmp"
    while IFS="$TAB" read -r _dip _dset _ddir _dslot; do
        [ -n "$_dset" ] || continue
        echo "$_dip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || continue   # в iptables уходит подстановка
        # Сет создаёт groups.sh; на буте мы бежим РАНЬШЕ него (ipset живёт в RAM) — тогда молча
        # пропускаем, а полную сборку зовёт он сам сразу после наполнения (dev_wire → dev-rebind).
        ipset list -n 2>/dev/null | grep -qx "$_dset" || { case "$_dskip" in *" $_dset"*) ;; *) _dskip="$_dskip $_dset" ;; esac; continue; }
        case "$_ddir" in
            vpn)
                # Марка доп-выхода — только если выход включён и не zapret; иначе ОСНОВНОЙ туннель
                # (зеркало rebuild_force: «марка есть, ip rule нет» = молча напрямую — не наш выбор).
                _dmk=$FWMARK
                case "$_dslot" in
                    2|3|4) case "$_en_slots" in
                               *" $_dslot "*) _dmk="0x$_dslot" ;;
                               *) _ddown="$_ddown $_dip->s$_dslot" ;;
                           esac ;;
                esac
                # MARK и СРАЗУ ACCEPT — пара обязательна (ACCEPT обрывает mangle до miwifi/NFQUEUE,
                # который иначе стёр бы метку; грабля mipctld, см. mark-core.sh).
                iptables -t mangle -A "$DEV_CHAIN" -s "$_dip" -m set --match-set "$_dset" dst -j MARK --set-mark "$_dmk" 2>/dev/null || continue
                iptables -t mangle -A "$DEV_CHAIN" -s "$_dip" -m set --match-set "$_dset" dst -j ACCEPT 2>/dev/null ;;
            bypass)
                iptables -t mangle -A "$DEV_CHAIN" -s "$_dip" -m set --match-set "$_dset" dst -j ACCEPT 2>/dev/null || continue ;;
            block)
                iptables -t mangle -A "$DEV_CHAIN" -s "$_dip" -m set --match-set "$_dset" dst -j DROP 2>/dev/null || continue ;;
            *)  continue ;;
        esac
        _dn=$((_dn+1))
    done < "$_dtmp"
    rm -f "$_dtmp" 2>/dev/null
    echo "[apply-bypass] правила устройств (адреса): $_dn${_dskip:+, сетов ещё нет:$_dskip}${_ddown:+, выход выключен (идут основным):$_ddown}"
}

# Сброс conntrack после правки: точечно по источнику (не рвём сессии всей сети),
# для `any` — общий flush. Без этого NSS/ECM держит старый маршрут (см. conntrack_flush).
ports_conntrack() {
    case "$1" in
        ""|any) conntrack_flush ;;
        *)      ct_flush_src "$1" ;;
    esac
}

# Снять строку из хранилища по КЛЮЧУ (src+proto+ports): направление в ключ не входит —
# у одного и того же набора портов оно ровно одно, повторный add его ПЕРЕПИСЫВАЕТ
# (иначе накопились бы два противоположных правила). Порты сверяем НОРМАЛИЗОВАННЫМИ (port-lib.sh):
# строку из бэкапа «443, 80» или «0443» панель показывает и снимает в нормализованной форме — сверка
# фиксированной строкой такую не находила, и строка оставалась навсегда (ревью пачки 3, круг 2).
# Остальное в строке не трогаем: поля сверяются как есть, а мусор снимается тем ключом, каким его показали.
ports_store_del() {   # $1 src, $2 proto, $3 ports (нормализованный)
    [ -f "$STORE_PORTS" ] || return 0
    _dt=$(printf '\t')
    : > "$STORE_PORTS.tmp"
    while IFS= read -r _dl || [ -n "$_dl" ]; do
        # Поля — тем же `IFS=<tab> read`, что у цепочки и CGI (port-lib.sh, cgi-bin/data): табуляция — пробельный символ IFS,
        # двойной и ведущий таб там схлопываются. Позиционная нарезка видела в «any⇥udp⇥⇥443» другой ключ — строку, которую
        # панель показала и снимала, «снятие» оставляло, а повторный add дописывал вторую (ревью пачки 3, круг 3).
        IFS="$_dt" read -r _ds _dp _dx _dd <<EOF_DEL
$_dl
EOF_DEL
        if [ "$_ds" = "$1" ] && [ "$_dp" = "$2" ] && [ "$(port_list_norm "$_dx")" = "$3" ]; then continue; fi
        printf '%s\n' "$_dl" >> "$STORE_PORTS.tmp"
    done < "$STORE_PORTS"
    mv "$STORE_PORTS.tmp" "$STORE_PORTS"
}

# --- переиграть ВСЁ хранилище (вызов на boot/repair) ---
apply_all() {
    ensure_chain
    n_ip=0; n_dst=0; n_if=0; g=off
    if [ -f "$STORE_IPS" ]; then
        # `done < файл` (не пайп) — цикл в текущем шелле, счётчики не теряются
        while IFS= read -r ip; do
            [ -n "$ip" ] && rule_add_ip "$ip" && n_ip=$((n_ip+1))
        done < "$STORE_IPS"
    fi
    if [ -f "$STORE_DST" ]; then
        while IFS= read -r dst; do
            [ -n "$dst" ] && rule_add_dst "$dst" && n_dst=$((n_dst+1))
        done < "$STORE_DST"
    fi
    # Wi-Fi сети: семья правил ЗАНОВО по хранилищу (rebuild_if_rules).
    rebuild_if_rules
    # Одиночные адреса «в VPN». Сет живёт в RAM → на буте пуст: наполняем из хранилища и
    # пересобираем с нуля (у сета ОДИН хозяин — этот скрипт, значит его содержимое обязано
    # в точности равняться файлу; иначе снятый адрес остался бы в туннеле, ср. domain.sh).
    n_vdst=0
    if [ -s "$STORE_VPN_DST" ]; then
        ensure_vpn_dst_set
        ipset flush "$VPN_DST_SET" 2>/dev/null
        while IFS= read -r vd; do
            [ -n "$vd" ] && ipset add "$VPN_DST_SET" "$vd" 2>/dev/null && n_vdst=$((n_vdst+1))
        done < "$STORE_VPN_DST"
        ensure_vpn_dst_mark
    fi
    [ -f "$STORE_GUEST" ] && { guest_rule_add; g=on; }
    # Сеты «мимо VPN» (группы groups.sh + одиночные домены domain.sh): по одному правилу на сет.
    # Здесь — только ПРОВОДКА; наполнение сетов переигрывают сами groups.sh apply / domain.sh apply
    # (их зовёт heal.sh на буте).
    for _s in $BYPASS_SETS; do rule_add_set_dst "$_s"; done
    # endpoint активной несущей (анти-петля) — переиграть на boot/repair ДО подъёма
    # несущей (несущая потом сама обновит через transport-*.sh up endpoint-set).
    ep=""
    if [ -s "$STORE_EP" ]; then
        ep=$(head -1 "$STORE_EP" | tr -d ' \r\n')
        [ -n "$ep" ] && rule_add_dst "$ep"
    fi
    # endpoint'ы доп-выходов (слотов) — тоже анти-петля, аддитивно (см. endpoint_slot_set). На
    # boot их обычно переигрывает slot-up (heal 5.13b), но repair/standalone apply зовут и нас —
    # держим правила и здесь (идемпотентно). Store остаётся только у живших слотов.
    eps=""
    for _f in "${STORE_EP_SLOT_PREFIX}2" "${STORE_EP_SLOT_PREFIX}3" "${STORE_EP_SLOT_PREFIX}4"; do
        [ -s "$_f" ] || continue
        _e=$(head -1 "$_f" | tr -d ' \r\n')
        [ -n "$_e" ] && { rule_add_dst "$_e"; eps="$eps${eps:+,}$_e"; }
    done
    echo "[apply-bypass] восстановлено: ip=$n_ip, dst=$n_dst, vpn-dst=$n_vdst, iface=$n_if, guest=$g, endpoint=${ep:-нет}${eps:+, слот-endpoint=$eps}"
    # «целиком через VPN» (force) — отдельная цепочка VPN_FORCE
    rebuild_force
    # правила по портам — отдельная цепочка VPN_PORTS, ВЫШЕ вырезов (см. блок PORTS_CHAIN).
    # Отсюда же они переживают ребут и fw3-reload: apply зовут heal (5.x) и vpn-toggle repair.
    rebuild_ports
    # исключения из «мимо VPN» — цепочка VPN_KEEP между портами и вырезом. Часть сетов на
    # этот момент ещё не создана (groups.sh идёт позже нас) — их доберёт set-dst-ensure.
    rebuild_keep
    # правила устройства по адресам — цепочка VPN_DEV между портами и исключениями. Их сеты на
    # буте тоже ещё не созданы; полную сборку зовёт groups.sh apply сразу после наполнения.
    rebuild_dev
    # устройства «целиком в десинк» — обе половины режима: ACCEPT в VPN_EXCLUDE (прямой путь) и
    # NFQUEUE по источнику у zapret.sh. Идут ПОСЛЕ ensure_chain выше — цепочка вырезов уже есть.
    rebuild_desync
}

case "$1" in
    apply)     apply_all ;;
    # Проводка правила «сет мимо VPN» по требованию — зовут groups.sh apply / domain.sh apply сразу
    # после того, как создали/наполнили свой сет (на боевом роутере сет появляется уже после apply_all).
    set-dst-ensure) [ -z "$2" ] && { echo "нужно имя ipset"; exit 1; }
        _ok=0; for _s in $BYPASS_SETS; do [ "$2" = "$_s" ] && _ok=1; done
        [ "$_ok" = 1 ] || { echo "чужой ipset"; exit 1; }
        # Заодно пересобираем VPN_KEEP: его сеты (grp_vpn и др.) создаёт тот же вызывающий и
        # обычно ПОЗЖЕ нашего apply на буте — иначе исключения молча не встали бы до ребута.
        ensure_chain; rule_add_set_dst "$2"; rebuild_keep >/dev/null; echo "сет $2 -> мимо VPN (правило в $EXCLUDE_CHAIN)" ;;
    # --- вырезы «мимо VPN». conntrack_flush ОБЯЗАТЕЛЕН в каждой ветке, ровно как в force-*
    #     ниже: без него правило есть, а трафик идёт по-старому (NSS/ECM держит маршрут).
    #     Доказано на железе — см. комментарий к conntrack_flush.
    add-ip)    [ -z "$2" ] && { echo "нужен IP";    exit 1; }; ensure_chain; desync_drop "$2"; store_add "$STORE_IPS" "$2"; rule_add_ip "$2"; conntrack_flush; echo "IP $2 -> хранилище + применён" ;;
    # Снятие «мимо VPN» уносит и исключение из него: без выреза оно бессмысленно (устройство и так
    # метится ядром), а осиротевшая строка врала бы тумблером в панели. Владелец связи — движок,
    # чтобы CLI и панель не расходились.
    del-ip)    [ -z "$2" ] && { echo "нужен IP";    exit 1; }; desync_drop "$2"; store_del "$STORE_IPS" "$2"; rule_del_ip "$2"; store_del "$STORE_KEEP" "$2"; rebuild_keep >/dev/null; conntrack_flush; echo "IP $2 убран из хранилища" ;;
    add-dst)   [ -z "$2" ] && { echo "нужен CIDR";  exit 1; }; dst_ok "$2" || { echo "нужен IPv4 или CIDR"; exit 1; }
        ensure_chain; store_del "$STORE_VPN_DST" "$2"; vpn_dst_del "$2"; store_add "$STORE_DST" "$2"; rule_add_dst "$2"; conntrack_flush; echo "dst $2 -> хранилище + мимо VPN" ;;
    del-dst)   [ -z "$2" ] && { echo "нужен CIDR";  exit 1; }; store_del "$STORE_DST" "$2"; rule_del_dst "$2"; conntrack_flush; echo "dst $2 убран из хранилища" ;;
    # --- «в VPN» по адресу назначения (обратное к add-dst). Направление у адреса ОДНО:
    #     сперва снимаем противоположное правило, иначе адрес попал бы разом и в ACCEPT
    #     (VPN_EXCLUDE), и в MARK — а цепочка вырезов идёт первой и молча победила бы
    #     («добавил в VPN, ничего не изменилось»). Ровно как domain.sh: add/bypass
    #     начинают со снятия прежней строки.
    add-vpn-dst) [ -z "$2" ] && { echo "нужен CIDR"; exit 1; }; dst_ok "$2" || { echo "нужен IPv4 или CIDR"; exit 1; }
        store_del "$STORE_DST" "$2"; rule_del_dst "$2"; store_add "$STORE_VPN_DST" "$2"; vpn_dst_add "$2"; conntrack_flush; echo "dst $2 -> хранилище + в VPN" ;;
    del-vpn-dst) [ -z "$2" ] && { echo "нужен CIDR"; exit 1; }; store_del "$STORE_VPN_DST" "$2"; vpn_dst_del "$2"; conntrack_flush; echo "dst $2 убран из хранилища (правила нет)" ;;
    endpoint-set) endpoint_set "$2" ;;   # IP endpoint'а несущей мимо VPN (пусто = снять); зовёт transport-*.sh up
    endpoint-slot-set) endpoint_slot_set "$2" "$3" ;;   # <id> <IP|""> endpoint доп-выхода мимо VPN (авто из transport-*.sh slot-up)
    # Панель шлёт ИМЯ ИНТЕРФЕЙСА (оно у неё под рукой и валидируется в cgi-bin/action), а в
    # хранилище ложится имя СЕТИ — перевод делает эта, единственная владеющая хранилищем сторона.
    # Прежнюю строку-имя-интерфейса снимаем: иначе на одну сеть накопились бы две записи.
    add-if)    [ -z "$2" ] && { echo "нужен iface"; exit 1; }; ensure_chain
        _ifk=$(if_store_key "$2"); store_del "$STORE_IFS" "$2"; store_add "$STORE_IFS" "$_ifk"
        rule_add_if "$_ifk"; conntrack_flush; echo "сеть «$_ifk» -> хранилище + применена" ;;
    del-if)    [ -z "$2" ] && { echo "нужен iface"; exit 1; }
        _ifk=$(if_store_key "$2"); store_del "$STORE_IFS" "$_ifk"; store_del "$STORE_IFS" "$2"
        rule_del_if "$_ifk"; rule_del_if "$2"; conntrack_flush; echo "сеть «$_ifk» убрана из хранилища" ;;
    guest-on)  ensure_chain; touch "$STORE_GUEST"; guest_rule_add; conntrack_flush; echo "гостевая сеть → мимо VPN" ;;
    guest-off) rm -f "$STORE_GUEST"; guest_rule_del; conntrack_flush; echo "гостевая сеть → по правилам" ;;
    # --- «целиком через VPN» (force). Меняем хранилище -> пересобираем VPN_FORCE
    #     -> сбрасываем conntrack, чтобы применилось к текущим соединениям сразу.
    # Третий аргумент — ВЫХОД: пусто/0/main = основной туннель, s2|s3|s4 = доп-выход.
    # Выключенный выход не запрещаем: rebuild_force уводит такое устройство на основной
    # туннель (гейт по list-enabled), а привязка оживёт сама, когда выход включат.
    force-add-ip)  [ -z "$2" ] && { echo "нужен IP";    exit 1; }
        # Формат проверяем ЗДЕСЬ, а не только в CGI (зеркало keep-add-ip и port-add): из CLI движок
        # обязан быть так же безопасен, а мусор в хранилище потом молча выпадал бы из сборки.
        echo "$2" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "нужен IPv4"; exit 1; }
        _fs=""; case "$3" in s2|s3|s4) _fs="$3" ;; ''|0|main) _fs="" ;; *) echo "выход: s2|s3|s4 или пусто"; exit 1 ;; esac
        # Явный отказ вместо тихого фолбэка: zapret-выход десинкает по адресу назначения и
        # марку не разбирает — «устройство целиком» через него не выразить (см. rebuild_force).
        if [ -n "$_fs" ] && [ -f "$ENODIA_DIR/slots.sh" ] &&
           sh "$ENODIA_DIR/slots.sh" list 2>/dev/null | awk -F"$TAB" -v i="${_fs#s}" '$1==i && $3=="zapret"{f=1} END{exit !f}'; then
            echo "выход №${_fs#s} — десинк (zapret): он работает по адресам назначения, направить в него устройство целиком нельзя"; exit 1
        fi
        desync_drop "$2"
        force_store_set "$2" "$_fs"; rebuild_force; conntrack_flush
        echo "IP $2 -> ЦЕЛИКОМ через VPN${_fs:+ (выход №${_fs#s})} (+хранилище)" ;;
    force-del-ip)  [ -z "$2" ] && { echo "нужен IP";    exit 1; }; force_store_del "$2"; rebuild_force; conntrack_flush; echo "IP $2 -> обычный режим (раздельный)" ;;
    # Пересобрать VPN_FORCE под текущее состояние выходов — зовёт slots.sh при enable/disable/del
    # (иначе устройство, привязанное к выходу, узнало бы о его выключении лишь со следующей правкой).
    force-rebind)  rebuild_force; conntrack_flush ;;
    force-add-if)  [ -z "$2" ] && { echo "нужен iface"; exit 1; }
        _ifk=$(if_store_key "$2"); store_del "$STORE_FORCE_IFS" "$2"; store_add "$STORE_FORCE_IFS" "$_ifk"
        rebuild_force; conntrack_flush; echo "сеть «$_ifk» -> ЦЕЛИКОМ через VPN" ;;
    force-del-if)  [ -z "$2" ] && { echo "нужен iface"; exit 1; }
        _ifk=$(if_store_key "$2"); store_del "$STORE_FORCE_IFS" "$_ifk"; store_del "$STORE_FORCE_IFS" "$2"
        rebuild_force; conntrack_flush; echo "сеть «$_ifk» -> обычный режим" ;;
    # ПРАВИЛО СЕТИ, КОТОРОЙ НЕТ В ЭФИРЕ (выключена в родной панели, переименована, legacy-имя интерфейса): у неё нет
    # живого интерфейса, и del-if/force-del-if позвать не с чем — панель знает только СТРОКУ хранилища. Снимаем строку
    # ТОЧНО (grep -x -F: в имени сети законны пробелы, в том числе ведущие, и символы регулярок) из обоих хранилищ, правила
    # по её раскрытию — тем же rule_del_if и сборкой VPN_FORCE. Строки нет ни в одном — отказ: снимать нечего.
    forget-if) [ -n "$2" ] || { echo "нужно имя сети"; exit 1; }
        _fk=0
        grep -qxF -- "$2" "$STORE_IFS" 2>/dev/null && _fk=1
        grep -qxF -- "$2" "$STORE_FORCE_IFS" 2>/dev/null && _fk=1
        [ "$_fk" = 1 ] || { echo "такого правила сети нет"; exit 1; }
        store_del "$STORE_IFS" "$2"; store_del "$STORE_FORCE_IFS" "$2"
        # Цепочки НЕ подцеплены (VPN выключен тумблером до ребута, транспорта нет — heal пропустил apply) — меняем только хранилище:
        # пересборка VPN_FORCE завела бы наши цепочки в mangle роутера, который «работает как сток», и рвала бы соединения дома
        # (ревью шага 5b, круг 3). Правила встанут вместе с остальными, когда их применят.
        if if_wired; then
            _fb=$(if_chain_rules); rebuild_if_rules; rebuild_force
            # Сброс соединений ВСЕГО роутера — только если правило действительно что-то направляло: снятие строки сети, которой нет
            # в эфире, меняет правила МЁРТВОГО интерфейса, и рвать ради этого сессии всего дома незачем (ревью шага 5b, круг 2).
            # Меняются правила живого интерфейса (сеть переименовали, правило стояло на её прежнем wlN) или иные метки — сброс
            # обязателен (NSS).
            if_change_live "$_fb" "$(if_chain_rules)" && conntrack_flush
        fi
        echo "правило сети снято" ;;
    # ЧТО ГОВОРИТ ХРАНИЛИЩЕ о каждом ЖИВОМ интерфейсе: «iface<TAB>bypass|force|both|пусто». Ядро (physdev в VPN_EXCLUDE /
    # VPN_FORCE) панель читает сама; расхождение «сохранено ≠ стоит» — сеть переехала на другой wlN, fw3 reload снёс правила до
    # repair, правило встало на одном радио из двух — и экран обязан это сказать, а не показать одно ядро (ревью шага 5b, круг 1).
    # Ключ строки — тот же, которым пишет add-if (`if_store_key`: имя сети, legacy — имя интерфейса).
    if-states)
        # Первая строка — `@wired<TAB>1|0`: подцеплены ли правила вообще. Без этого «сохранено, а в ядре нет» после ребута с
        # выключенным VPN читалось бы расхождением (ревью шага 5b, круг 3): там правил нет у ВСЕХ, и это не поломка.
        if if_wired; then printf '@wired\t1\n'; else printf '@wired\t0\n'; fi
        command -v wifi_live_ifaces >/dev/null 2>&1 || exit 0
        for _si in $(wifi_live_ifaces); do
            _sk=$(if_store_key "$_si"); _sb=""; _sf=""
            { grep -qxF -- "$_sk" "$STORE_IFS" || grep -qxF -- "$_si" "$STORE_IFS"; } 2>/dev/null && _sb=1
            { grep -qxF -- "$_sk" "$STORE_FORCE_IFS" || grep -qxF -- "$_si" "$STORE_FORCE_IFS"; } 2>/dev/null && _sf=1
            if [ -n "$_sb" ] && [ -n "$_sf" ]; then _ss=both; elif [ -n "$_sb" ]; then _ss=bypass; elif [ -n "$_sf" ]; then _ss=force; else _ss=""; fi
            printf '%s\t%s\n' "$_si" "$_ss"
        done ;;
    # guest целиком в VPN взаимоисключим с guest мимо VPN — снимаем bypass-флаг
    force-guest-on)  rm -f "$STORE_GUEST"; guest_rule_del; touch "$STORE_FORCE_GUEST"; rebuild_force; conntrack_flush; echo "гостевая сеть → целиком в VPN" ;;
    force-guest-off) rm -f "$STORE_FORCE_GUEST"; rebuild_force; conntrack_flush; echo "гостевая сеть → по правилам" ;;
    full-tunnel)
        case "$2" in
            on)  touch "$FULLTUNNEL_FLAG"; rebuild_force; conntrack_flush; echo "FULL-TUNNEL ON: весь трафик через VPN (кроме локалки и вырезов)" ;;
            off) rm -f "$FULLTUNNEL_FLAG"; rebuild_force; conntrack_flush; echo "FULL-TUNNEL OFF: вернулся раздельный режим (split по enodia_list/iplist_set)" ;;
            *)   if [ -f "$FULLTUNNEL_FLAG" ]; then echo "full-tunnel: ON"; else echo "full-tunnel: OFF"; fi ;;
        esac ;;
    # --- правила по портам (VPN_PORTS). Направление у набора портов ОДНО: add сперва
    #     снимает прежнюю строку с тем же ключом (src+proto+ports), иначе в цепочке
    #     оказались бы два правила, и молча выигрывало бы верхнее.
    port-add)
        [ -z "$5" ] && { echo "нужно: port-add <IP|any> <udp|tcp|both> <порты|all> <vpn|direct|block|s2|s3|s4>"; exit 1; }
        command -v port_line_ok >/dev/null 2>&1 || { echo "нет port-lib.sh — обновите скрипты роутера"; exit 1; }
        _src="$2"; _pro="$3"; _pts=$(port_list_norm "$4"); _dir="$5"
        port_src_ok   "$_src" || { echo "src: нужен IPv4 или any"; exit 1; }
        port_proto_ok "$_pro" || { echo "proto: udp|tcp|both"; exit 1; }
        port_list_ok  "$_pts" || { echo "порты: all или список 80,443,40000-65535"; exit 1; }
        port_dir_ok   "$_dir" || { echo "куда: vpn|direct|block|s2|s3|s4"; exit 1; }
        # Зеркало гейта force-add-ip: zapret-выход единственный работает БЕЗ марки (ACCEPT +
        # scoped NFQUEUE по адресам НАЗНАЧЕНИЯ), `ip rule` под 0xN для него не создаётся ⇒
        # правило встало бы, а порты молча уехали бы напрямую и БЕЗ десинка. Fail-open
        # ВЫКЛЮЧЕННОГО выхода тут по-прежнему принят (правило узкое), а этот — не fail-open,
        # а вечно мёртвое правило: отказываем с причиной.
        case "$_dir" in
            s[234])
                if [ -f "$ENODIA_DIR/slots.sh" ] && \
                   sh "$ENODIA_DIR/slots.sh" list 2>/dev/null | awk -F"$TAB" -v i="${_dir#s}" '$1==i && $3=="zapret"{f=1} END{exit !f}'; then
                    echo "выход №${_dir#s} — десинк (zapret): он работает по адресам назначения, направить в него порты нельзя"; exit 1
                fi ;;
        esac
        ports_store_del "$_src" "$_pro" "$_pts"
        printf '%s\t%s\t%s\t%s\n' "$_src" "$_pro" "$_pts" "$_dir" >> "$STORE_PORTS"
        rebuild_ports; ports_conntrack "$_src"
        echo "порт-правило: $_src $_pro $_pts -> $_dir" ;;
    port-del)
        [ -z "$4" ] && { echo "нужно: port-del <IP|any> <udp|tcp|both> <порты|all>"; exit 1; }
        command -v port_list_norm >/dev/null 2>&1 || { echo "нет port-lib.sh — обновите скрипты роутера"; exit 1; }
        ports_store_del "$2" "$3" "$(port_list_norm "$4")"
        rebuild_ports; ports_conntrack "$2"
        echo "порт-правило снято: $2 $3 $4" ;;
    port-list)   # TSV as-is — читает панель (человеческий текст парсить нельзя)
        if [ -s "$STORE_PORTS" ]; then cat "$STORE_PORTS"; fi ;;
    # --- исключения из «мимо VPN» (VPN_KEEP): «устройство идёт напрямую, но МОИ правила
    #     действуют». Гейт «устройство реально в вырезе» — здесь, а не только в панели:
    #     иначе тумблер молча ничего не делал бы (правил-то нет), а строка в хранилище жила.
    keep-add-ip)
        [ -z "$2" ] && { echo "нужен IP"; exit 1; }
        echo "$2" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "нужен IPv4"; exit 1; }
        grep -qxF "$2" "$STORE_IPS" 2>/dev/null || { echo "IP $2 не в списке «мимо VPN» — исключать не из чего"; exit 1; }
        store_add "$STORE_KEEP" "$2"; rebuild_keep; ct_flush_src "$2"
        echo "IP $2 -> мимо VPN, но ручные правила (домены/адреса/группы «в VPN») действуют" ;;
    keep-del-ip)
        [ -z "$2" ] && { echo "нужен IP"; exit 1; }
        store_del "$STORE_KEEP" "$2"; rebuild_keep; ct_flush_src "$2"
        echo "IP $2 -> мимо VPN целиком (исключения сняты)" ;;
    keep-list)   # по строке на IP — читает панель
        if [ -s "$STORE_KEEP" ]; then cat "$STORE_KEEP"; fi ;;
    # --- устройство ЦЕЛИКОМ В ДЕСИНК (напрямую + nfqws по источнику). Режим устройства ОДИН,
    #     поэтому снимаем противоположные: «целиком в VPN», «мимо VPN» и исключения VPN_KEEP.
    #     ACCEPT «мимо VPN» при этом ОСТАЁТСЯ (это и есть прямой путь режима) — снимаем только
    #     строку хранилища, иначе устройство числилось бы разом в двух режимах.
    desync-add-ip)
        [ -z "$2" ] && { echo "нужен IP"; exit 1; }
        echo "$2" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo "нужен IPv4"; exit 1; }
        [ -f "$ZAPRET_SH" ] || { echo "нет zapret.sh — обновите скрипты"; exit 1; }
        # Гейт «есть чем десинкать» — В ДВИЖКЕ: без бинаря режим означал бы «просто мимо VPN»,
        # а панель показывала бы «в десинк». Отказываем с причиной ДО записи в хранилище.
        # Вывод движка десинка глушим: свою причину печатаем сами, а дублировать её в одной
        # строке ответа панели («…НЕТ бинаря… десинк недоступен…») незачем.
        sh "$ZAPRET_SH" src-wire "$2" >/dev/null 2>&1 || { echo "десинк недоступен: нет nfqws (поставьте Zapret в «Роутер → Компоненты»)"; exit 1; }
        force_store_del "$2"; rebuild_force >/dev/null
        store_del "$STORE_IPS" "$2"; store_del "$STORE_KEEP" "$2"; rebuild_keep >/dev/null
        ensure_chain; store_add "$STORE_DESYNC" "$2"; rule_add_ip "$2"
        ct_flush_src "$2"
        echo "IP $2 -> напрямую + десинк рукопожатий (nfqws по источнику)" ;;
    desync-del-ip)
        [ -z "$2" ] && { echo "нужен IP"; exit 1; }
        store_del "$STORE_DESYNC" "$2"
        # ACCEPT «идти напрямую» снимаем ТОЛЬКО если он наш: тот же самый кирпич принадлежит режиму
        # «мимо VPN», и без гарда снятие десинка молча возвращало бы устройство в туннель (гард-
        # зеркало уже стоит в rebuild_desync — здесь его просто забыли).
        grep -qxF "$2" "$STORE_IPS" 2>/dev/null || rule_del_ip "$2"
        [ -f "$ZAPRET_SH" ] && sh "$ZAPRET_SH" src-unwire "$2" >/dev/null 2>&1
        ct_flush_src "$2"
        echo "IP $2 -> обычный режим (раздельный)" ;;
    desync-list)   # по строке на IP — читает панель
        if [ -s "$STORE_DESYNC" ]; then cat "$STORE_DESYNC"; fi ;;
    # Переиграть проводку десинка устройств: зовёт zapret.sh после install/remove бинаря и
    # repair — иначе режим, записанный без nfqws, ожил бы только со следующей правкой.
    desync-rebind) rebuild_desync ;;
    # --- правила устройства по адресам назначения (VPN_DEV). Хранилище чужое (groups.sh: группа
    #     с непустым src), поэтому здесь только ПРОВОДКА: состав изменился → переиграть цепочку.
    #     Зовёт groups.sh do_apply (dev_wire) после пересборки сетов и apply_all на boot/repair.
    dev-rebind)  rebuild_dev ;;
    order)       ensure_prerouting_order; echo "порядок цепочек в mangle PREROUTING переигран" ;;
    list)
        echo "== .bypass-ips (устройства/источник мимо VPN) =="
        if [ -s "$STORE_IPS" ]; then cat "$STORE_IPS"; else echo "(пусто)"; fi
        echo "== .bypass-dst (сайты-IP/назначение мимо VPN) =="
        if [ -s "$STORE_DST" ]; then cat "$STORE_DST"; else echo "(пусто)"; fi
        echo "== .vpn-dst (сайты-IP/назначение ЦЕЛИКОМ в VPN) =="
        if [ -s "$STORE_VPN_DST" ]; then cat "$STORE_VPN_DST"; else echo "(пусто)"; fi
        echo "== .endpoint-bypass (endpoint несущей мимо VPN — авто, анти-петля) =="
        if [ -s "$STORE_EP" ]; then cat "$STORE_EP"; else echo "(пусто)"; fi
        echo "== .bypass-ifaces (SSID/iface мимо VPN) =="
        if [ -s "$STORE_IFS" ]; then cat "$STORE_IFS"; else echo "(пусто)"; fi
        echo "== ЦЕЛИКОМ через VPN (force) =="
        if [ -f "$FULLTUNNEL_FLAG" ]; then echo "FULL-TUNNEL: ВЕСЬ трафик через VPN (кроме локалки и вырезов выше)"; fi
        echo "-- .fullvpn-ips (устройства целиком в VPN; 2-я колонка = доп-выход) --"
        if [ -s "$STORE_FORCE_IPS" ]; then cat "$STORE_FORCE_IPS"; else echo "(пусто)"; fi
        echo "-- .fullvpn-ifaces (SSID/iface целиком в VPN) --"
        if [ -s "$STORE_FORCE_IFS" ]; then cat "$STORE_FORCE_IFS"; else echo "(пусто)"; fi
        echo "== .port-rules (правила по портам: src / proto / порты / куда) =="
        if [ -s "$STORE_PORTS" ]; then cat "$STORE_PORTS"; else echo "(пусто)"; fi
        echo "== .keep-vpn-ips (мимо VPN, но ручные правила действуют: $KEEP_SETS) =="
        if [ -s "$STORE_KEEP" ]; then cat "$STORE_KEEP"; else echo "(пусто)"; fi
        echo "== .desync-ips (устройства ЦЕЛИКОМ в десинк: напрямую + nfqws по источнику) =="
        if [ -s "$STORE_DESYNC" ]; then cat "$STORE_DESYNC"; else echo "(пусто)"; fi
        echo "-- проводнено в mangle (факт, zapret.sh src-list) --"
        _sl=$([ -f "$ZAPRET_SH" ] && sh "$ZAPRET_SH" src-list 2>/dev/null)
        if [ -n "$_sl" ]; then printf '%s\n' "$_sl"; else echo "(пусто)"; fi
        echo "== правила устройств по адресам (VPN_DEV; хранит groups.sh: ip / значение / куда / выход) =="
        _dl=$(sh "$ENODIA_DIR/groups.sh" dev-list 2>/dev/null)
        if [ -n "$_dl" ]; then printf '%s\n' "$_dl"; else echo "(пусто)"; fi
        echo "== guest =="
        if   [ -f "$STORE_FORCE_GUEST" ]; then echo "ЦЕЛИКОМ через VPN (force)"
        elif [ -f "$STORE_GUEST" ];       then echo "мимо VPN (pref $GUEST_PREF)"
        else echo "раздельный режим (split)"; fi
        ;;
    *)
        echo "Использование: $0 {apply|dev-rebind|desync-add-ip IP|desync-del-ip IP|desync-list|desync-rebind|add-ip IP|del-ip IP|add-dst CIDR|del-dst CIDR|add-vpn-dst CIDR|del-vpn-dst CIDR|endpoint-set IP|endpoint-slot-set ID IP|add-if IFACE|del-if IFACE|guest-on|guest-off|force-add-ip IP [s2|s3|s4]|force-del-ip IP|force-rebind|force-add-if IFACE|force-del-if IFACE|force-guest-on|force-guest-off|forget-if СТРОКА|if-states|full-tunnel on|off|port-add SRC PROTO PORTS vpn|direct|block|sN|port-del SRC PROTO PORTS|port-list|keep-add-ip IP|keep-del-ip IP|keep-list|order|list}"
        exit 1
        ;;
esac
