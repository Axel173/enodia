#!/bin/sh
#
# status.sh v3 — диагностический отчёт по AWG-туннелю.
#
# v3 (май 2026):
#   * "Версия протокола" теперь учитывает РЕАЛЬНОЕ состояние:
#     - пробует $ENODIA_BIN/amneziawg-go --version и awg --version
#     - если AWG 2.0 в конфиге И handshake идёт → бинарь умеет 2.0, зелёный
#     - предупреждение только если 2.0 в конфиге, а handshake нет
#   * показывает ОБА ipset — enodia_list (домены) и iplist_set (CIDR)
#   * cron + heal.sh — главный механизм автозапуска, rc.local инфо

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Бутстрап — единственный каталог, про который известно, что он на флеше РОУТЕРА в любой
# раскладке: им подписываем строку «сколько осталось на роутере» (см. разбор ниже, у df).
ENODIA_BOOT=${ENODIA_BOOT:-/data/usr/app/enodia-boot}
ENODIA_LIST_NAME="enodia_list"
IPLIST_NAME="iplist_set"

# Общий примитив «внешний IPv4» (ip-lib.sh): IP-литерал-проба, DNS-free — чинит пустой egress на
# ядре 4.4 (hostname api.ipify.org там молча пустел). Шим на случай частичной установки без lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }
command -v carrier_iface >/dev/null 2>&1 || carrier_iface() { ip route show table 1000 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# Возраст рукопожатия считаем через age_since (clock-lib.sh): после скачка часов голая разность
# печатала «21 час назад» на туннеле, поднятом минуту назад. Шим = прежнее поведение.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

WG=""
if command -v wg >/dev/null 2>&1; then WG=wg
elif [ -x "$ENODIA_BIN/awg" ]; then WG="$ENODIA_BIN/awg"
fi

header() { echo ""; printf "${BOLD}${BLUE}══════ %s ══════${NC}\n" "$1"; }
status() {
    label="$1"; value="$2"; color="${3:-$GREEN}"
    printf "  %-30s ${color}%s${NC}\n" "$label" "$value"
}
num() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$1" ;;
    esac
}

# Число членов ipset. Канон — ipset_count() в lists-lib.sh; тут локальная копия (lib не source-им
# ради строки). «Number of entries:» печатают НЕ все ядра: на 4.4 (AX3600/BE3600) её нет →
# фолбэк на подсчёт строк-членов (член ipset начинается с цифры), иначе счётчик врал бы 0.
ipset_count() {
    _c=$(ipset list "$1" 2>/dev/null | sed -n 's/^Number of entries:[[:space:]]*//p' | head -1)
    case "$_c" in ''|*[!0-9]*) _c=$(ipset list "$1" 2>/dev/null | grep -cE '^[0-9]') ;; esac
    case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
    printf '%s' "$_c"
}

# Поколение конфига — у ВЛАДЕЛЬЦА ответа (transport-awg.sh conf-gen, его же спрашивают «Серверы» панели): своя копия здесь не
# знала AWG 3.x и называла конфиг 3.1 «2.0».
detect_awg_version() {
    conf="$ENODIA_STATE/awg.conf"
    [ ! -f "$conf" ] && { echo "?"; return; }
    _avg=""; [ -f "$ENODIA_DIR/transport-awg.sh" ] && _avg=$(sh "$ENODIA_DIR/transport-awg.sh" conf-gen "$conf" 2>/dev/null | awk -F'\t' 'NR == 1 { print $2 }')
    case "$_avg" in
        wg) echo "обычный WireGuard" ;;
        [0-9].[0-9]) echo "$_avg" ;;
        *) echo "?" ;;
    esac
}

# Попытка получить версию бинарника amneziawg-go / awg
detect_binary_version() {
    for cand in "$ENODIA_BIN/amneziawg-go" "$ENODIA_BIN/awg" amneziawg-go wg; do
        if [ -x "$cand" ] || command -v "$cand" >/dev/null 2>&1; then
            v=$("$cand" --version 2>&1 | head -1 | tr -d '\r' | head -c 80)
            # Принимаем только если есть цифры (отфильтровываем usage/error)
            case "$v" in
                *[0-9]*) echo "$v"; return ;;
            esac
        fi
    done
    # Fallback: дата файла бинарника
    if [ -f "$ENODIA_BIN/amneziawg-go" ]; then
        d=$(date -r "$ENODIA_BIN/amneziawg-go" "+%Y-%m-%d" 2>/dev/null)
        [ -n "$d" ] && echo "amneziawg-go от $d"
    fi
}

# ==================== 0. ТРАНСПОРТ VPN ====================
# Какой протокол НЕСЁТ трафик сейчас: AmneziaWG (awg0) или Xray (xtun). Маркировка
# (fwmark/ipset/ip rule) у них ОБЩАЯ — меняется только default в table 1000
# (awg0<->xtun). Без этой секции статус показывал бы handshake awg0, даже когда
# реально активен xray, а awg0 — лишь тёплый резерв (вводило в заблуждение).
header "Транспорт VPN"
TRANSPORT=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
# Пусто = либо роутер старше флага (там несущая awg — историческое умолчание), либо установка
# «только панель», где транспорта нет ВООБЩЕ. Диагностику присылают при разборе, и «Активный
# протокол: AmneziaWG» на роутере, где ничего, кроме панели, не ставили, уводит разбор в сторону
# ровно так же, как прежнее «иначе AmneziaWG» уводило с hy2/byedpi. Ответ — у оркестратора.
if [ -z "$TRANSPORT" ]; then
    TRANSPORT=awg
    if [ -f "$ENODIA_DIR/transport.sh" ]; then
        sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1
        [ "$?" = 1 ] && TRANSPORT=none
    fi
fi
# Вилка ЗНАЕТ про все транспорты, а не «xray иначе AmneziaWG»: прежняя форма роняла hy2/byedpi/
# zapret в awg-ветку, и отчёт диагностики — то, что человек присылает при разборе, — начинался с
# уверенного «Активный протокол: AmneziaWG (awg0)» при мёртвом awg0. Класс «код забывает альт».
case "$TRANSPORT" in
    hy2)     status "Активный протокол:" "Hysteria2 (через xtun)" "$GREEN" ;;
    byedpi)  status "Активный протокол:" "ByeDPI — десинк через локальный socks, VPS не участвует" "$GREEN" ;;
    zapret)  status "Активный протокол:" "Zapret — десинк напрямую (nfqws/NFQUEUE), туннеля нет" "$GREEN"
             # Пид-файл, а не `pidof nfqws`: имя демона в проекте не считается признаком (инстанс
             # опознаём своим пидфайлом — та же идиома, что в zapret.sh proc_alive).
             _zp=$(cat /tmp/enodia-zapret-nfqws.pid 2>/dev/null | tr -d ' \r\n')
             if [ -n "$_zp" ] && kill -0 "$_zp" 2>/dev/null; then status "Демон nfqws:" "жив (pid $_zp)" "$GREEN"
             else status "Демон nfqws:" "НЕ запущен" "$RED"; fi
             # Признак живой ПРОВОДКИ — тот же, по которому судит сторож (rule-heal): без jump'а
             # десинк мёртв при бодром демоне, и это ровно то, что fw3 reload смывает первым.
             if iptables -t mangle -C PREROUTING -j ENODIA_ZAPRET 2>/dev/null; then
                 status "Проводка (mangle -j ENODIA_ZAPRET):" "на месте" "$GREEN"
             else
                 status "Проводка (mangle -j ENODIA_ZAPRET):" "СНЕСЕНА — десинк мёртв при живом демоне" "$RED"
             fi ;;
    none)    status "Активный протокол:" "нет — установлена только панель, транспорт не выбран" "$YELLOW"
             status "Что делать:" "панель :8088 → «Компоненты» (поставить) → «Серверы» (включить)" ;;
    xray)    : ;;    # подробности ниже — у xray своя развёрнутая ветка
    awg)     : ;;
    *)       status "Активный протокол:" "$TRANSPORT (диагностика этого транспорта не описана)" "$YELLOW" ;;
esac
if [ "$TRANSPORT" = "xray" ]; then
    active_xray=$(cat "$ENODIA_STATE/.xray-active" 2>/dev/null | tr -d '\r')
    status "Активный протокол:" "Xray (xtun)" "$GREEN"
    status "Активный xray-конфиг:" "${active_xray:-?}"
    if [ -f /tmp/enodia-xray.pid ] && kill -0 "$(cat /tmp/enodia-xray.pid 2>/dev/null)" 2>/dev/null; then
        status "Демон xray:" "жив (pid $(cat /tmp/enodia-xray.pid))" "$GREEN"
    else
        status "Демон xray:" "НЕ запущен" "$RED"
    fi
    if [ -f /tmp/enodia-hev.pid ] && kill -0 "$(cat /tmp/enodia-hev.pid 2>/dev/null)" 2>/dev/null; then
        status "tun2socks (hev):" "жив (pid $(cat /tmp/enodia-hev.pid))" "$GREEN"
    else
        status "tun2socks (hev):" "НЕ запущен" "$RED"
    fi
    if ip link show xtun >/dev/null 2>&1; then
        status "Интерфейс xtun:" "поднят" "$GREEN"
    else
        status "Интерфейс xtun:" "НЕ создан" "$RED"
    fi
    # Реальный выходной IP активного протокола — через локальный socks Xray
    # (порт 10808 = SOCKS_PORT в xray-transport.sh). curl --interface awg0 ниже
    # это НЕ покажет: он тестирует резерв awg0, а не путь xtun->xray.
    ip_xray=$(probe_ext_ip "--socks5-hostname 127.0.0.1:10808" 8)
    if [ -n "$ip_xray" ]; then
        status "Выходной IP (xray):" "$ip_xray" "$GREEN"
    else
        status "Выходной IP (xray):" "недоступен" "$RED"
    fi
    status "AmneziaWG (awg0):" "тёплый резерв" "$BLUE"
elif [ "$TRANSPORT" = "awg" ]; then
    active_awg=$(cat "$ENODIA_STATE/.active" 2>/dev/null | tr -d '\r')
    status "Активный протокол:" "AmneziaWG (awg0)" "$GREEN"
    status "Активный конфиг:" "${active_awg:-?}"
else
    # Альты (hy2/byedpi) делят ОДИН socks 10808 и общий hev/xtun — спрашиваем ровно их, а не awg0.
    # Список ПОЛОЖИТЕЛЬНЫЙ, а не «все, кроме zapret»: в ту же ветку падает и `none` (установка
    # «только панель»), и на СТОКОВОМ роутере статус рисовал два КРАСНЫХ отказа — «xtun НЕ создан»
    # и «socks 10808 недоступен» — сразу под честным «транспорт не выбран». Это ровно тот класс,
    # который уже чинили в шапке («статус врал о стоке»): красное = сломалось, а тут ничего не
    # ломалось. Заодно исчезает 8-секундная проба несуществующего socks.
    case "$TRANSPORT" in
        hy2|byedpi)
            if ip link show xtun >/dev/null 2>&1; then status "Интерфейс xtun:" "поднят" "$GREEN"
            else status "Интерфейс xtun:" "НЕ создан" "$RED"; fi
            ip_alt=$(probe_ext_ip "--socks5-hostname 127.0.0.1:10808" 8)
            if [ -n "$ip_alt" ]; then status "Выходной IP (socks 10808):" "$ip_alt" "$GREEN"
            else status "Выходной IP (socks 10808):" "недоступен" "$RED"; fi
            ;;
    esac
    # Про awg0 на установке «только панель» говорить нечего: его не поднимают не потому, что
    # «транспорт его не использует», а потому что транспорта нет вовсе (и бинарей тоже).
    if [ "$TRANSPORT" != "none" ]; then
        if ip link show awg0 >/dev/null 2>&1; then status "AmneziaWG (awg0):" "поднят, но трафик несёт НЕ он" "$BLUE"
        else status "AmneziaWG (awg0):" "не поднят (транспорт его не использует)" "$BLUE"; fi
    fi
fi

# А КОМПОНЕНТ ВЫБРАННОГО ТРАНСПОРТА ВООБЩЕ СТОИТ? `.transport` — это НАМЕРЕНИЕ, и после импорта
# бэкапа с другого роутера оно приезжает БЕЗ бинарей (замерено 17.08 на AX3600: строка выше
# печатала уверенное зелёное «Активный протокол: AmneziaWG (awg0)» там, где amneziawg-go нет
# вовсе). Тот же класс, что чинили в диаг-дампе: секция обязана СПРОСИТЬ владельца, а не
# пересказать флаг. Ответ у оркестратора; РОВНО код 1 = «нет» — код 2 значит «старая копия
# скрипта, верба не знает», и тогда молчим, как раньше.
COMP_MISSING=0
if [ "$TRANSPORT" != "none" ] && [ -f "$ENODIA_DIR/transport.sh" ]; then
    sh "$ENODIA_DIR/transport.sh" installed "$TRANSPORT" >/dev/null 2>&1
    if [ "$?" = 1 ]; then
        COMP_MISSING=1
        status "Компонент:" "НЕ УСТАНОВЛЕН — бинарей этого транспорта на роутере нет" "$RED"
        status "Что делать:" "панель :8088 → «Компоненты» (поставить); до этого весь трафик идёт напрямую" "$YELLOW"
    fi
fi

# ==================== 1. ИНТЕРФЕЙС AWG0 ====================
# Секцию целиком пропускаем на установке «только панель»: awg там не установлен, и «Состояние:
# НЕ ПОДНЯТ» красным — не диагноз, а описание замысла. Тот же принцип, что в шапке выше.
if [ "$TRANSPORT" != "none" ]; then
header "Интерфейс awg0"
if ip link show awg0 >/dev/null 2>&1; then
    status "Состояние:" "поднят" "$GREEN"
    awg_ip=$(ip -4 addr show awg0 | awk '/inet / {print $2}' | head -1)
    status "Внутренний IP:" "$awg_ip"

    # --- Handshake (нужен ПЕРЕД проверкой версии — даёт ground truth) ---
    hs_ago=-1
    if [ -n "$WG" ]; then
        hs=$(num "$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')")
        if [ "$hs" -gt 0 ]; then
            hs_ago=$(age_since "$hs")
        fi
    fi

    # --- Версия протокола + версия бинарника ---
    awg_ver=$(detect_awg_version)
    bin_ver=$(detect_binary_version)

    case "$awg_ver" in
        2.0|3.0|3.1)
            # AWG 2.0+ в конфиге. Главный признак "бинарь свежий" — есть handshake.
            if [ "$hs_ago" -ge 0 ] && [ "$hs_ago" -lt 600 ]; then
                status "Версия протокола:" "AWG $awg_ver — работает (handshake идёт)" "$GREEN"
            elif [ "$hs_ago" -ge 0 ]; then
                status "Версия протокола:" "AWG $awg_ver — handshake давний, проверьте VPS" "$YELLOW"
            else
                status "Версия протокола:" "AWG $awg_ver — handshake нет, возможно бинарь старый" "$YELLOW"
            fi
            ;;
        "1.5")    status "Версия протокола:" "AWG 1.5 — поддерживается" "$GREEN" ;;
        "1.0")    status "Версия протокола:" "AWG 1.0 (Legacy) — стабильно работает" "$GREEN" ;;
        *)        status "Версия протокола:" "$awg_ver" "$YELLOW" ;;
    esac
    [ -n "$bin_ver" ] && status "Бинарь:" "$bin_ver" "$BLUE"

    # ПУСТОЙ ФАЙЛ — ЭТО ОТВЕТ «ИМЯ НЕИЗВЕСТНО», а не отсутствие строки: так `install_config`
    # пишет `.active`, когда имя неоткуда взять (откат без снимка имени, полуприменённая
    # раскладка). Голый `cat` печатал пустоту, и раздел выглядел обрезанным. Знак тот же, что у
    # соседа выше (`${active_awg:-?}`): в ОДНОМ отчёте один факт обязан называться одним словом.
    _st_act=$(cat "$ENODIA_STATE/.active" 2>/dev/null | tr -d '\r')
    [ -f "$ENODIA_STATE/.active" ] && status "Активный конфиг:" "${_st_act:-?}"
    endpoint=$(grep -E "^Endpoint" "$ENODIA_STATE/awg.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}')
    [ -n "$endpoint" ] && status "Endpoint VPS:" "$endpoint"

    # --- Handshake вывод ---
    if [ "$hs_ago" -ge 0 ]; then
        if   [ "$hs_ago" -lt 180 ]; then status "Последний handshake:" "$hs_ago сек назад" "$GREEN"
        elif [ "$hs_ago" -lt 600 ]; then status "Последний handshake:" "$hs_ago сек назад (давно)" "$YELLOW"
        else                             status "Последний handshake:" "$hs_ago сек назад — СТАРЫЙ" "$RED"
        fi
    elif [ -n "$WG" ]; then
        status "Последний handshake:" "никогда — VPS не отвечает!" "$RED"
    else
        status "Бинарь wg/awg:" "не найден" "$YELLOW"
    fi

    if [ -n "$WG" ]; then
        xfer=$($WG show awg0 transfer 2>/dev/null | awk 'NR==1{print $2" "$3}')
        rx=$(num "$(echo "$xfer" | awk '{print $1}')")
        tx=$(num "$(echo "$xfer" | awk '{print $2}')")
        if [ "$rx" -gt 0 ] || [ "$tx" -gt 0 ]; then
            status "Принято/передано:" "$((rx/1024/1024)) MB / $((tx/1024/1024)) MB"
        fi
    fi
else
    # ВЫКЛЮЧЕНО ЧЕЛОВЕКОМ — НЕ ПОЛОМКА, И КРАСНЫМ ЭТО КРАСИТЬ НЕЛЬЗЯ. До 02.09.2026 `off` оставлял
    # awg0 ТЁПЛЫМ РЕЗЕРВОМ, и сюда выключенный роутер просто не попадал; теперь `off` снимает
    # несущую холодно (демон гасится, TUN уходит с ним), и «интерфейса нет» стало ШТАТНЫМ
    # состоянием выключенного роутера. Принцип тот же, что у пропуска всей секции при
    # TRANSPORT=none десятью строками выше: красное = сломалось, а тут ничего не ломалось —
    # человек выключил сам, и отправлять его чинить это значит врать.
    if [ -f "$ENODIA_STATE/.vpn-off" ]; then
        status "Состояние:" "не поднят — VPN выключен человеком (норма; тумблер переживает ребут)" "$BLUE"
    else
        status "Состояние:" "НЕ ПОДНЯТ" "$RED"
    fi
fi
fi   # конец секции «Интерфейс awg0» (пропущена целиком при TRANSPORT=none)

# ==================== 2. IPSET enodia_list (домены) ====================
header "ipset $ENODIA_LIST_NAME — IP резолвленных доменов"
if ipset list -n 2>/dev/null | grep -qx "$ENODIA_LIST_NAME"; then
    cnt=$(ipset_count "$ENODIA_LIST_NAME")
    if [ "$cnt" -gt 0 ]; then
        status "Состояние:" "наполнен" "$GREEN"
        status "IP-адресов:" "$cnt"
    else
        status "Состояние:" "пустой (ОК если CIDR-список наполнен)" "$YELLOW"
        status "IP-адресов:" "0"
    fi
else
    status "Состояние:" "НЕ СОЗДАН" "$RED"
fi

# ==================== 3. IPSET iplist_set (CIDR от opencck) ====================
header "ipset $IPLIST_NAME — подсети CIDR от iplist.opencck.org"
if ipset list -n 2>/dev/null | grep -qx "$IPLIST_NAME"; then
    cnt=$(ipset_count "$IPLIST_NAME")
    if   [ "$cnt" -gt 100 ]; then status "Состояние:" "наполнен" "$GREEN";          status "CIDR-подсетей:" "$cnt"
    elif [ "$cnt" -gt 0 ];   then status "Состояние:" "подозрительно мало" "$YELLOW"; status "CIDR-подсетей:" "$cnt"
    else                          status "Состояние:" "пустой — запустите iplist-update.sh" "$RED"
    fi
    if [ -f /tmp/enodia-iplist-update.log ]; then
        last=$(grep -E "^=====" /tmp/enodia-iplist-update.log | tail -1 | sed 's/===== //; s/ =====//')
        [ -n "$last" ] && status "Обновлён:" "$last"
    fi
else
    status "Состояние:" "НЕ СОЗДАН — запустите iplist-update.sh" "$RED"
fi

# ==================== 4. ВНЕШНИЕ IP ====================
header "Тест: куда идёт трафик"
# «Прямой IP» = реальный выход В ОБХОД туннеля: bind к WAN-iface (--interface). БЕЗ bind проба к
# 1.1.1.1 (Cloudflare ∈ iplist_set) ушла бы В туннель и показала бы egress → ложное «совпадает с
# прямым». Тот же приём, что в cgi-bin/ip для реального WAN. Пусто → провайдер режет / нет WAN.
# Имя WAN — у владельца (ip-lib.sh::wan_iface, следит C81); шим в шапке.
wan_if=$(wan_iface)
ip_direct=$(probe_ext_ip "${wan_if:+--interface $wan_if}" 5)
if [ -n "$ip_direct" ]; then
    status "Прямой IP (без VPN):" "$ip_direct"
else
    status "Прямой IP (без VPN):" "недоступен (проба не ответила)" "$YELLOW"
fi
if ip link show awg0 >/dev/null 2>&1; then
    ip_vpn=$(probe_ext_ip "--interface awg0" 5)
    # При активном xray awg0 — лишь тёплый резерв: помечаем как «резерв», а не
    # как «IP через VPN», и не пугаем красным «совпадает с прямым» (реальный
    # выход показан выше в секции «Транспорт VPN»).
    if [ "$TRANSPORT" = "xray" ]; then vpn_label="IP awg0 (резерв):"; else vpn_label="IP через VPN:"; fi
    if [ -n "$ip_vpn" ]; then
        if [ "$TRANSPORT" != "xray" ] && [ -n "$ip_direct" ] && [ "$ip_direct" = "$ip_vpn" ]; then
            status "$vpn_label" "$ip_vpn — СОВПАДАЕТ С ПРЯМЫМ!" "$RED"
        else
            status "$vpn_label" "$ip_vpn" "$GREEN"
        fi
    else
        # НЕ красное «недоступен»: промах ОДНОЙ пробы бывает и на исправном туннеле — замерено на
        # AX3600 17.08.2026, 3 пустых из 10 при живом рукопожатии и растущих счётчиках awg0 (бюджет
        # съедал занятый роутер, не сеть). Красный тут читался как «VPN не работает» и уводил разбор
        # от настоящей причины; о том, ВЕЗЁТ ли туннель, отвечают рукопожатие и сторож выше.
        # Формулировка — та же, что у прямого IP строкой выше (один симптом = один текст).
        status "$vpn_label" "недоступен (проба не ответила)" "$YELLOW"
    fi
fi

# ==================== 5. ПРАВИЛА ====================
header "Правила маршрутизации"
fwmark_rules=$(ip rule 2>/dev/null | grep -c "fwmark 0x1")
mangle_awg=$(iptables -t mangle -L PREROUTING -v -n 2>/dev/null | grep -c "match-set $ENODIA_LIST_NAME")
mangle_ipl=$(iptables -t mangle -L PREROUTING -v -n 2>/dev/null | grep -c "match-set $IPLIST_NAME")
mangle_total=$((mangle_awg + mangle_ipl))
nat_rules=$(iptables -t nat -L POSTROUTING -v -n 2>/dev/null | grep -c "MASQUERADE.*awg0")
# КУДА ВЕДЁТ МЕТКА. Сама по себе она не значит ничего: без `ip rule fwmark→table 1000` и `default`
# в этой таблице помеченный пакет уходит обычным путём. Спрашиваем ОБА звена — иначе вердикт врёт
# в ДВЕ стороны, и обе замерены на AX3600 17.08.2026:
#   * импорт бэкапа (намерение awg, бинарей нет) — три MARK 0x1 в mangle при ПУСТОЙ table 1000 и
#     НУЛЕ ip rule, а секция печатала ЗЕЛЁНОЕ «метки на месте»: читается как «маршрутизация цела»;
#   * установка «только панель» — правил там не должно быть ВООБЩЕ (роутер работает как сток), а
#     ноль красился ЖЁЛТЫМ, то есть «чего-то не хватает». Тот же класс, что чинили в диаг-дампе:
# вердикт обязан СПРОСИТЬ «а несущая-то предполагается?», а не пересказать счётчик правил.
# Устройство несущей — у владельца (ip-lib.sh::carrier_iface, следит C81), а не свой `grep -c`:
# счётчик всё равно бывал только 0 или 1, зато его форму копировали дальше.
carrier_dev=$(carrier_iface); route_dst=0; [ -n "$carrier_dev" ] && route_dst=1
# ВЫКЛЮЧЕНО ЧЕЛОВЕКОМ — ПЕРВОЙ веткой, раньше всех прочих: с 02.09.2026 тумблер переживает ребут
# (флаг .vpn-off на /data), и отсутствие правил в этом состоянии — НОРМА, а не поломка. Без этой
# ветки status красил бы выключенный роутер КРАСНЫМ («маршрутизация неполная») и отправлял чинить
# то, что человек выключил сам.
if [ -f "$ENODIA_STATE/.vpn-off" ]; then
    # СУДИМ ПО `ip rule`, А НЕ ПО МЕТКАМ. Первая редакция этой ветки требовала, чтобы исчезли и
    # метки в mangle, — и на живом AX3600 02.09.2026 честно выключенный роутер получил ЖЁЛТОЕ
    # «правила есть»: `vpn-toggle off` снимает РОВНО маршрутную привязку (ip rule fwmark→1000),
    # а метки и default в table 1000 оставляет НАРОЧНО — без правила они холостые, это и есть
    # штатный fail-open. Тревога уместна только в обратном случае: тумблер снят, а привязка жива.
    if [ "$fwmark_rules" = 0 ]; then
        status "VPN выключен человеком:" "тумблер снят (переживает ребут) — метки холостые, трафик идёт напрямую" "$BLUE"
        _rc="$BLUE"
    else
        status "VPN выключен, а маршрут жив:" "тумблер снят, но ip rule fwmark→1000 на месте — трафик всё ещё уходит в туннель" "$YELLOW"
        _rc="$YELLOW"
    fi
elif [ "$TRANSPORT" = "zapret" ]; then
    # У десинка нет ни несущей, ни table 1000: его проводка — jump ENODIA_ZAPRET, и она проверена
    # в секции «Транспорт VPN». Требовать здесь маршрут значило бы красить рабочий zapret КРАСНЫМ.
    status "Маркировка в туннель:" "у Zapret её нет и быть не должно — проводка проверена выше" "$BLUE"
    _rc="$BLUE"
elif [ "$TRANSPORT" = "none" ] || [ "$COMP_MISSING" = 1 ]; then
    if [ "$mangle_total" = 0 ] && [ "$fwmark_rules" = 0 ]; then
        status "Наших правил нет:" "норма — транспорт не выбран/не установлен, роутер работает как сток" "$BLUE"
        _rc="$BLUE"
    else
        status "Метки без маршрута:" "остались от прежней настройки; трафик идёт НАПРЯМУЮ (fail-open) — вреда нет, эффекта тоже" "$YELLOW"
        _rc="$YELLOW"
    fi
elif [ "$mangle_total" -ge 2 ] && [ "$fwmark_rules" -ge 1 ] && [ "$route_dst" -ge 1 ]; then
    _rc="$GREEN"
else
    status "Маршрутизация НЕПОЛНАЯ:" "метка есть, а вести её некуда (или наоборот) — «Починить правила» в панели" "$RED"
    _rc="$RED"
fi
status "iptables-метки PREROUTING:" "$mangle_awg ($ENODIA_LIST_NAME) + $mangle_ipl ($IPLIST_NAME)" "$_rc"
status "ip rule с fwmark 0x1:" "$fwmark_rules шт." "$_rc"
status "default в table 1000:" "$([ "$route_dst" = 1 ] && echo "есть → $carrier_dev" || echo "НЕТ (метка холостая)")" "$_rc"
status "MASQUERADE на awg0:" "$nat_rules шт." "$_rc"

# ==================== 6. СПИСКИ ДОМЕНОВ ====================
header "Списки доменов (dnsmasq)"
# Легаси re-filter вырезан целиком в dev153 (свой генератор доменов обходил dom_ok/dns-merge и оба
# conf-dir), и установщик его остатки СТИРАЕТ. Строку «нет — используется iplist+custom» на каждом
# роутере печатать больше не о чем: подсистемы нет. Файл, однако, ещё может лежать на роутере,
# который обновляли, а не ставили с нуля, — тогда о НЁМ и говорим, потому что он влияет на DNS.
if [ -f /etc/dnsmasq.d/enodia-domains.conf ]; then
    main_count=$(num "$(grep -c '^ipset=' /etc/dnsmasq.d/enodia-domains.conf 2>/dev/null)")
    main_size=$(du -h /etc/dnsmasq.d/enodia-domains.conf 2>/dev/null | awk '{print $1}')
    main_age=$(date -r /etc/dnsmasq.d/enodia-domains.conf "+%Y-%m-%d %H:%M" 2>/dev/null || echo "?")
    status "ОСТАТОК легаси re-filter:" "$main_count правил, $main_size — подсистема удалена, файл лишний" "$YELLOW"
    status "  обновлён:" "$main_age"
fi
if [ -f /etc/dnsmasq.d/enodia-custom.conf ]; then
    cust=$(num "$(grep -c '^ipset=' /etc/dnsmasq.d/enodia-custom.conf 2>/dev/null)")
    status "Ваши добавления:" "$cust доменов"
fi

# ==================== 7. ТЕСТ КОНКРЕТНЫХ САЙТОВ ====================
if [ "$1" = "test" ]; then
    header "Проверка популярных сайтов"
    for domain in youtube.com chatgpt.com claude.ai instagram.com discord.com github.com; do
        ip_first=$(nslookup "$domain" 127.0.0.1 2>/dev/null | grep -A1 'Name:' | tail -1 | awk '{print $NF}')
        if [ -n "$ip_first" ]; then
            in_awg=0; in_ipl=0
            ipset test "$ENODIA_LIST_NAME" "$ip_first" 2>/dev/null && in_awg=1
            ipset test "$IPLIST_NAME"   "$ip_first" 2>/dev/null && in_ipl=1
            if [ "$in_awg" = "1" ] || [ "$in_ipl" = "1" ]; then
                tag=""
                [ "$in_awg" = "1" ] && tag="${tag}enodia_list "
                [ "$in_ipl" = "1" ] && tag="${tag}iplist_set"
                status "$domain:" "ЧЕРЕЗ VPN ($ip_first, $tag)" "$GREEN"
            else
                status "$domain:" "НАПРЯМУЮ ($ip_first)" "$YELLOW"
            fi
        fi
    done
fi

# ==================== 8. АВТОЗАПУСК ====================
header "Автозапуск (главное — cron)"
if grep -q "heal.sh" /etc/crontabs/root 2>/dev/null; then
    heal_line=$(grep "heal.sh" /etc/crontabs/root | head -1 | awk '{print $1,$2,$3,$4,$5}')
    status "cron heal.sh:" "включён ($heal_line)" "$GREEN"
else
    status "cron heal.sh:" "ОТСУТСТВУЕТ — после ребута всё развалится!" "$RED"
fi
if grep -q "iplist-update" /etc/crontabs/root 2>/dev/null; then
    upd_line=$(grep "iplist-update" /etc/crontabs/root | head -1 | awk '{print $1,$2,$3,$4,$5}')
    status "cron iplist-update:" "включён ($upd_line)" "$GREEN"
else
    status "cron iplist-update:" "выключен — CIDR не обновляются" "$YELLOW"
fi
if grep -q "AWG-SETUP-BE7000" /etc/rc.local 2>/dev/null; then
    status "rc.local:" "блок есть (бонус)" "$GREEN"
else
    # Модель тут не называем и причину «/etc сбрасывается» не приводим: на AX3600 /etc —
    # ПЕРСИСТЕНТНЫЙ ubifs (тот же том, что /data), файл там ребут переживёт. Правда, общая для
    # всех моделей, другая: rc.local нам не нужен вовсе — автозапуск проекта живёт в cron.
    status "rc.local:" "пусто (норм — автозапуск у нас через cron)" "$BLUE"
fi

# ==================== 9. РЕСУРСЫ РОУТЕРА ====================
# Зачем здесь: при установке и после полезно видеть, что VPN/скрипты не съедают
# память. ВАЖНО: все наши логи лежат в /tmp, а /tmp на BE7000 — это tmpfs (RAM),
# поэтому раздутый лог = съеденная RAM (до ребута; ребут /tmp чистит).
# RAM берём из /proc/meminfo — его формат стабилен на любом busybox, в отличие
# от `free` (у разных версий разный вывод). df считаем устойчиво к переносу
# длинного имени устройства на отдельную строку: числа всегда в ПОСЛЕДНЕЙ строке,
# поэтому адресуем поля от конца ($(NF-2)=Avail, $(NF-4)=Size, $(NF-1)=Use%).
header "Ресурсы роутера"
mt=$(num "$(awk '/^MemTotal:/{print $2}'     /proc/meminfo 2>/dev/null)")
mf=$(num "$(awk '/^MemFree:/{print $2}'      /proc/meminfo 2>/dev/null)")
ma=$(num "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)")
if [ "$mt" -gt 0 ]; then
    # старое ядро без MemAvailable → как оценку «доступно» берём MemFree
    if [ "$ma" -gt 0 ]; then avail_mb=$((ma/1024)); else avail_mb=$((mf/1024)); fi
    txt="$((mf/1024)) МБ свободно из $((mt/1024)) МБ"
    [ "$ma" -gt 0 ] && txt="$txt (доступно $((ma/1024)) МБ)"
    if   [ "$avail_mb" -lt 30 ]; then status "RAM:" "$txt" "$RED"
    elif [ "$avail_mb" -lt 60 ]; then status "RAM:" "$txt" "$YELLOW"
    else                              status "RAM:" "$txt" "$GREEN"
    fi
fi
# Берём /data (ubifs, переживает ребут — туда ставится awg) и /tmp (tmpfs=RAM, логи).
# /overlay НЕ трогаем: на BE7000 такого монтирования НЕТ (корень — ro-squashfs, /etc —
# ramfs), и `df /overlay` свалился бы на squashfs-корень `/`, а он ВСЕГДА 100% по природе
# сжатого read-only образа — показывает мнимое «забито под завязку» и пугает зря.
# «ЗАНЯТО» СЧИТАЕМ САМИ, а не берём колонку `Use%` у df. Она считает used/(used+avail), то есть
# БЕЗ неснижаемого резерва UBIFS, и на /data это расходилось с панелью на 3 пункта: панель (оба
# CGI и «Компоненты») говорит «занято = total − available». Два числа про одно место в материалах,
# которые тестер копирует в отчёт, — ровно то, что чинили 16.08.2026 внутри самой панели; здесь
# была третья копия арифметики. Формат тот же, поэтому `df` в КИЛОБАЙТАХ + `%.1fM` руками
# (оба монтирования здесь заведомо меньше гигабайта). Гард `$(NF-4)+0>0` — от деления на ноль и
# от строки-заголовка df (`+0` обязателен: без него сравнение строковое — см. store-lib.sh).
# ТОМ, О КОТОРОМ РЕЧЬ, СПРАШИВАЕМ ПО ПУТИ КАТАЛОГА. `/data` — литерал, и на BE10000 (RC01) это
# ЧУЖОЙ том: флеш там поделён на три ubifs, стоковый cfg зовётся `/data` (4.7 МБ, забит Xiaomi),
# а весь наш код живёт на `/data/usr`. Строка «Диск /data: 0.7M своб» в статусе — это чужая
# теснота, выданная за нашу. Соседние экраны (dump.sh, панель, гард установщика) переведены на
# путь ещё 31.08.2026; здесь литерал уцелел, потому что df тут зовётся через переменную и под
# первую версию проверки C50 не попадал — она смотрела только на аргумент рядом с `df`.
_ourmp=$(df -k "$ENODIA_DIR" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{print $NF}')
# ФЛЕШ РОУТЕРА — СВОЕЙ СТРОКОЙ. В режиме «всё на накопителе» $ENODIA_DIR лежит на флешке, и
# статус переставал отвечать «сколько осталось на роутере» вообще. Якорь — бутстрап (резидентен
# на /data по определению); совпал с томом кода — второй строки не печатаем, она была бы дублем.
# Гард на СУЩЕСТВОВАНИЕ, а не фолбэк на литерал «/data»: без бутстрапа (установка старее фичи)
# df по несуществующему пути отдал бы пусто, а литерал на BE10000 — ЧУЖОЙ том, то есть ровно
# ту тесноту, выданную за нашу, против которой написан абзац выше. Нет бутстрапа ⇒ якорь тот
# же, что и был, и вторая строка не появляется вовсе — поведение байт-в-байт прежнее.
_flashdir="$ENODIA_BOOT"; [ -d "$_flashdir" ] || _flashdir="$ENODIA_DIR"
_bootmp=$(df -k "$_flashdir" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{print $NF}')
_mps="${_bootmp:-${_ourmp:-/data}}"
if [ -n "$_ourmp" ] && [ -n "$_bootmp" ] && [ "$_ourmp" != "$_bootmp" ]; then _mps="$_mps $_ourmp"; fi
for m in $_mps /tmp; do
    dline=$(df "$m" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{printf "%.1fM своб из %.1fM (занято %.0f%%)", $(NF-2)/1024, $(NF-4)/1024, ($(NF-4)-$(NF-2))*100/$(NF-4)}')
    [ -n "$dline" ] && status "Диск $m:" "$dline"
done
# Суммарный размер НАШИХ логов в /tmp (это tmpfs = RAM). Список имён спрашиваем у ВЛАДЕЛЬЦА —
# `clean.sh ramlogs-list`: маску `/tmp/*.log` брать нельзя, рядом лежат СТОКОВЫЕ логи Xiaomi
# (wifi_analysis, ssh_patch, *.bootcheck, stat_points_*), и на свежем AX3600 статус приписывал нам
# 10 файлов / 8 КБ вместо наших 2 / 3 КБ — то есть чужой расход ОЗУ. ls -l: размер в поле $5.
logsz=$(sh "$ENODIA_DIR/clean.sh" ramlogs-list 2>/dev/null | while read -r _lp; do
            ls -l "$_lp" 2>/dev/null
        done | awk '{s+=$5} END{if (NR>0) printf "%d КБ в %d файл(ах)", (s+1023)/1024, NR}')
[ -n "$logsz" ] && status "Логи в /tmp:" "$logsz"

echo ""
printf "${BLUE}Совет:${NC} '${BOLD}status.sh test${NC}' покажет, какие сайты идут через VPN.\n"
echo ""
