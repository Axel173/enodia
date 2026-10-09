#!/bin/sh
# transport-awg.sh — ПЛАГИН транспорта AmneziaWG (несущая awg0).
#
# Часть плана «транспорт-агностичное ядро + плагины».
# Это ЗЕРКАЛО xray-transport.sh для AmneziaWG: одинаковый контракт up|down|health|
# failover|status, чтобы оркестратор (heal/watchdog/меню) дёргал любой протокол
# единообразно, не зная, awg внутри или xray.
#
# РАЗДЕЛЕНИЕ СЛОЁВ (ключевая идея красивого варианта):
#   * mark-core (ОБЩЕЕ, не зависит от протокола): ipset enodia_list/iplist_set, маркировка
#     mangle -m set -> MARK 0x1, ip rule fwmark 0x1 -> table 1000, цепочки VPN_EXCLUDE/
#     VPN_FORCE, домены. Его строит установщик/heal ОДИН раз и не трогает при смене
#     транспорта. Этот плагин mark-core НЕ касается.
#   * НЕСУЩАЯ (пер-транспорт, забота плагина): что стоит в default table 1000 (тут awg0),
#     FORWARD на неё, MASQUERADE (awg — нужен, у xtun/tun2socks — нет), DNS-схема
#     (awg — внутренний 172.29.x через awg0; xray — публичный, маркированный в туннель).
#
# БЕЗОПАСНОСТЬ. Всё держится на ip rule fwmark -> table 1000 (mark-core). Если awg0
# умирает или несущую сняли (down) — table 1000 теряет default, fwmark-трафик падает
# в main -> НАПРЯМУЮ (fail-open, не блэкхол). Снять привязку к ДОХЛОМУ awg0 полностью
# (вместе с mark-core) — это switch-vpn.sh safety_off; здесь down лишь РЕЛИНКВИТ
# несущей (mark-core остаётся, повторная активация дешевле). Управление/SSH (br-lan,
# main) от транспорта не зависят.
#
# ВЫЗОВ — как подпроцесс (НЕ source), симметрично xray-transport.sh:
#   transport-awg.sh up        — сделать AmneziaWG активной несущей (весь дом)
#   transport-awg.sh down      — снять awg-несущую (awg0 -> тёплый резерв, трафик прямой)
#   transport-awg.sh status    — показать состояние
#   transport-awg.sh health    — здоровье awg-несущей (для watchdog):
#                                код 0 = здорова / активен не awg; 1 = awg нездоров
#   transport-awg.sh failover  — перебор awg-резервов (делегат в switch-vpn.sh failover,
#                                единый источник правды по перебору; см. ниже)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# Нет ipt-lib.sh с `ipt_top` (частичное обновление) ⇒ прежнее «первым в цепочку», байт-в-байт.
command -v ipt_top >/dev/null 2>&1 || ipt_top() { _itc=$1; shift; iptables -C "$_itc" "$@" 2>/dev/null || iptables -I "$_itc" 1 "$@"; }
command -v ct_flush >/dev/null 2>&1 || ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
TABLE=1000
IFACE=awg0
FWMARK=0x1
TRANSPORT_FLAG="$ENODIA_STATE/.transport"
ACTIVE_CONF="$ENODIA_STATE/awg.conf"
SWITCH="$ENODIA_DIR/switch-vpn.sh"
AWG_SETUP="$ENODIA_DIR/awg_setup.sh"
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"
APPLY_BYPASS="$ENODIA_DIR/apply-bypass.sh"
HS_MAX=180            # порог возраста handshake (сек) — как в watchdog.sh
PUB_DNS1=1.1.1.1
PUB_DNS2=8.8.8.8

# Слой шифрованного DNS (doh-lib.sh): при включённом DoH перехватывает установку upstream
# (dnsmasq→127.0.0.1#5053 + :443 резолвера в туннель). ВЫКЛ (дефолт) → doh_apply_dns даёт 1,
# работает прежний путь байт-в-байт. Шим на случай установки без lib (DoH просто недоступен).
# Форма `if [ -f ]; then . ; fi` — инвариант проекта: провалившийся `.` в ash фатален и
# МОЛЧАЛИВ (шелл выходит на месте, rc=2), а `[ -f x ] && . x` под set -e ещё и пробрасывает 1.
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
command -v doh_apply_dns >/dev/null 2>&1 || doh_apply_dns() { return 1; }
# dns-lib: общий резолв Endpoint-домена (is_ipv4/resolve_ipv4) для awg-СЛОТА (Ф2) — тот же
# приём подстановки IP в Endpoint, что у awg_setup.sh для awg0 (setconf не резолвит через
# запертый dnsmasq, [[awg-config-format-footguns]]). Библиотеки нет — НЕ падаем (основная
# несущая awg0 её не требует, конфиг ей генерит awg_setup.sh), но слот об этом честно скажет:
# см. slot_gen_conf, где молчаливый пропуск подстановки означал бы отвергнутый setconf'ом
# конфиг слота и НИ СЛОВА в логе.
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi

# Возраст отметки времени с защитой от скачка часов (clock-lib.sh). Шим = прежнее поведение:
# частичная установка без lib не должна падать, но и защиты там не будет.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
# «VPN выключен вручную — несущую не берёт никто» (daemon-lib.sh: carrier_barred/carrier_run, разбор там). Нет библиотеки —
# шимы дают прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v carrier_barred >/dev/null 2>&1 || carrier_barred() { return 1; }
command -v carrier_run >/dev/null 2>&1 || carrier_run() { shift; "$@"; }
# Смерть демона ждём по процессу с шагом 0.1 с (daemon-lib.sh). Нет библиотеки — прежний секундный шаг.
command -v daemon_wait_gone >/dev/null 2>&1 || daemon_wait_gone() { _dwg=0; while [ -d "/proc/$1" ]; do [ "$_dwg" -ge "${2:-5}" ] && return 1; sleep 1; _dwg=$((_dwg+1)); done; return 0; }
# Поколение firewall reload (ipt-lib.sh). Нет библиотеки — «reload был всегда»: каждое чтение даёт новую строку, как раньше.
command -v fw3_gen >/dev/null 2>&1 || fw3_gen() { cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$-$RANDOM-$RANDOM"; }
# Наш upstream dnsmasq пишет ОДИН владелец (doh-lib.sh, разбор там). Нет библиотеки — прежняя пара «записать + рестарт».
command -v dns_upstream_put >/dev/null 2>&1 || dns_upstream_put() { mkdir -p /etc/dnsmasq.d; { echo no-resolv; for _dus in "$@"; do echo "server=$_dus"; done; } > /etc/dnsmasq.d/00-upstream.conf; /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }

log() { echo "[transport-awg] $*"; }
notify_event() { [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

# CLI handshake читает awg (amneziawg-tools), НЕ amneziawg-go (тот ДЕМОН и на show
# печатает Usage). Предпочитаем локальный бинарь, иначе из PATH.
wg_bin() {
    if [ -x "$ENODIA_BIN/awg" ]; then echo "$ENODIA_BIN/awg"
    elif command -v awg >/dev/null 2>&1; then echo awg
    else echo ""; fi
}

# Возраст последнего handshake в секундах (999999 = handshake'а не было / нет бинаря).
# Считает age_since (clock-lib.sh): голая разность «now - hs» врёт ровно на величину скачка часов,
# а часы тут без RTC и прыгают вперёд через ~13 мин после загрузки — cmd_health на этом объявлял
# живую несущую мёртвой. [[watchdog-clock-step-false-death]]
hs_age() {
    wg=$(wg_bin); [ -n "$wg" ] || { echo 999999; return; }
    hs=$("$wg" show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    age_since "$hs"
}

carrier_up() { ip link show "$IFACE" 2>/dev/null | grep -q 'state UP\|UNKNOWN\|LOWER_UP'; }   # not-wan: своя несущая (awg0/awgN), а не аплинк; про аплинк отвечает ip-lib.sh

# ---- анти-петля: endpoint своего VPS мимо маркировки ----------------------
# IP endpoint'а awg-сервера. Сначала у демона (awg show — уже резолвленный пир),
# фолбэк — Endpoint из awg.conf (обычно сразу IP). Только IPv4 (iplist_set = cidr4).
awg_endpoint_ip() {
    wg=$(wg_bin)
    if [ -n "$wg" ]; then
        ep=$("$wg" show "$IFACE" endpoints 2>/dev/null | awk 'NR==1{print $2}' | sed 's/:[0-9]*$//')
        echo "$ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && { echo "$ep"; return 0; }
    fi
    ep=$(grep -E '^Endpoint' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//; s/[[:space:]]//g')
    echo "$ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && echo "$ep"
}
# Исключить endpoint awg-сервера из маркировки (иначе свои же UDP-пакеты к VPS,
# если его IP в iplist_set, заворачиваются обратно в awg0 = петля). Идемпотентно,
# переживает ребут (.endpoint-bypass на /data). Зовём ДО постановки default->awg0.
exclude_endpoint() {
    ep=$(awg_endpoint_ip)
    [ -n "$ep" ] || { log "endpoint awg не определён — пропуск анти-петли"; return 0; }
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-set "$ep" >/dev/null 2>&1
    log "endpoint $ep исключён из маркировки (анти-петля)"
}

# ---- DNS ------------------------------------------------------------------
# awg-режим: dnsmasq форвардит во ВНУТРЕННИЙ Amnezia-DNS (172.29.172.254 dev awg0).
# ЕДИНСТВЕННАЯ копия возврата туннельного DNS для awg (в switch-vpn.sh жил дубль мимо
# doh_apply_dns — он перетирал 00-upstream.conf после failover'а и молча выключал DoH;
# снят при ревью батча 4). VPN_DNS берём из активного awg.conf.
restore_vpn_dns() {
    # DoH ВКЛ → резолв через локальный прокси в туннель; ВЫКЛ → ниже как было. DOH_APPLY_NOTE — слово
    # библиотеки о том, что резолвер пришлось увести МИМО ещё не везущей несущей (см. doh_apply_dns).
    if doh_apply_dns tunnel; then [ -n "${DOH_APPLY_NOTE:-}" ] && log "DoH: $DOH_APPLY_NOTE"; return 0; fi
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -z "$vpn_dns" ] && vpn_dns=172.29.172.254
    ip route replace "$vpn_dns/32" dev "$IFACE" 2>/dev/null
    dns_upstream_put "$vpn_dns"
}
# Релинквит несущей -> DNS на публичный НАПРЯМУЮ (не маркируем: при снятой несущей
# трафик к 1.1.1.1/8.8.8.8 должен идти мимо туннеля). Зеркало DNS-части safety_off.
set_public_dns() {
    doh_apply_dns direct && return 0    # DoH ВКЛ (или авто-режим прямых) → резолв через локальный прокси; иначе → ниже как было
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -n "$vpn_dns" ] && ip route del "$vpn_dns/32" dev "$IFACE" 2>/dev/null
    dns_upstream_put "$PUB_DNS1" "$PUB_DNS2"
}

# ---- несущая (carrier) ----------------------------------------------------
# Поднять awg0, если его нет. Зеркало bring_up из switch-vpn.sh (init.d -> вендорный
# awg_setup.sh -> ждём интерфейс). Возврат 0 — awg0 есть.
# `/etc/init.d/firewall reload` из awg_setup.sh СНОСИТ ВСЕ iptables: цепочки apply-bypass,
# ENODIA_ZAPRET+NFQUEUE, FORWARD доп-выходов, PANEL_WAN, «доступ домой». Мы вернём только СВОЮ
# несущую, поэтому просим канонический переигрыш — см. replay_fw3. Флаг ставим ТОЛЬКО если reload
# правда был (сменилось поколение `fw3_gen`): зона `awg` уже стоит ⇒ awg_setup его не делает.
FW3_WIPED=0
# …И «ИНТЕРФЕЙС ЕСТЬ» НЕ ЗНАЧИТ «ОТ ТОГО СЕРВЕРА». awg0 живёт ТЁПЛЫМ РЕЗЕРВОМ: `down` плагина
# снимает маршрутизацию, но интерфейс и демон оставляет — и всё это время конфиг могли сменить.
# ЗАМЕР НА ЖЕЛЕЗЕ (BE7000, 02.09.2026): выключить VPN тумблером → выбрать в панели другой сервер
# (панель обещает «включите VPN, и роутер пойдёт через этот сервер») → включить обратно. `.active`
# и `awg.conf` — новые, а awg0 продолжал ходить на ПРЕЖНИЙ endpoint: `ensure_carrier` выходил на
# первой строке, а `awg setconf` никто не звал. Человек уверен, что сменил страну; трафик идёт
# в старую. Судим ПО ФАКТУ (ключ пира у демона против ключа в конфиге), а не по наличию линка;
# `stage` к этому моменту уже разложил awg.conf/amnezia_for_awg.conf и УДАЛИЛ awg0.conf, поэтому
# пересозданный интерфейс поднимется именно с новым сервером (цикла быть не может).
# КЛЮЧ — base64, и он КОНЧАЕТСЯ «=»: отрезаем префикс `PublicKey =`, а не делим строку по «=». Прежний
# `awk -F'= *'` отдавал 43 знака без хвостового «=» против 44 у демона ⇒ сверка не сходилась НИКОГДА, и
# каждый подъём поверх тёплого резерва пересоздавал awg0 с `awg_setup` и firewall reload (замер на BE7000,
# 27.09.2026: фолбэк «Выкл» на неизменный сервер — «awg0 поднят с ДРУГИМ сервером — пересоздаю»).
carrier_matches_conf() {
    _cmw=$(wg_bin); [ -n "$_cmw" ] || return 0          # сверять нечем — прежнее поведение
    # Пиров бывает несколько, а порядок их у userspace-демона случаен (обход Go-map): «последний в файле ↔ первый у демона» давал
    # ложное «другой сервер» и пересоздание с firewall reload (ревью 28.09.2026, круг 2) ⇒ КАЖДЫЙ пир демона обязан быть в конфиге.
    _cmk=$(sed -n 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*//p' "$ACTIVE_CONF" 2>/dev/null | sed "s/#.*//" | tr -d ' \t\r')
    [ -n "$_cmk" ] || return 0                          # в конфиге нет ключа пира — не судим
    _cml=$("$_cmw" show "$IFACE" peers 2>/dev/null | tr -d ' \t\r')
    [ -n "$_cml" ] || return 0                          # демон ещё не сконфигурен — обычный путь
    for _cmx in $_cml; do printf '%s\n' "$_cmk" | grep -qxF -e "$_cmx" || return 1; done
    # Пир тот же — а СВОЙ ключ? Два клиента ОДНОГО сервера (два конфига с одним пиром) отличаются только им: без этой сверки
    # тёплый awg0 на ключе A переживал переход на конфиг B, `.active` = B, а сессию держал A — и выход на A получал отказ
    # «ключ занят основным», которого человек не видит (ревью 27.09.2026). Нет строки в конфиге или демон ключа не назвал —
    # судим по пиру, как раньше: «сверить нечем» ≠ «разошлось», а расхождение стоит awg_setup с firewall reload.
    # СВЕРЯЕМ ПУБЛИЧНЫЕ, А НЕ ПРИВАТНИКИ. Демон хранит приватник «прижатым» (clamping Curve25519: младшие 3 бита первого байта и
    # старший бит последнего), а в конфиге он бывает и сырым — ключ сгенерирован не `wg genkey`. Тогда `show private-key` ≠ строке
    # конфига при ТОМ ЖЕ ключе (замер BE7000 02.10.2026: расходился один знак base64), сверка не сходилась НИКОГДА, и каждый возврат
    # на AmneziaWG поверх тёплого резерва пересоздавал awg0 с firewall reload. Публичный ключ из обоих один — его и сравниваем.
    _cmp=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$ACTIVE_CONF" 2>/dev/null | head -1 | sed "s/#.*//" | tr -d ' \t\r')
    [ -n "$_cmp" ] || return 0
    _cmp=$(printf '%s\n' "$_cmp" | "$_cmw" pubkey 2>/dev/null | tr -d ' \t\r')
    [ -n "$_cmp" ] || return 0                          # ключ конфига не читается — сверить нечем
    _cmq=$("$_cmw" show "$IFACE" public-key 2>/dev/null | head -1 | tr -d ' \t\r')
    [ -n "$_cmq" ] || return 0
    [ "$_cmp" = "$_cmq" ]
}
ensure_carrier() {
    if ip link show "$IFACE" >/dev/null 2>&1; then
        carrier_matches_conf && return 0
        log "awg0 поднят с ДРУГИМ сервером (конфиг сменили, пока несущая была тёплым резервом) — пересоздаю"
        ip link del "$IFACE" 2>/dev/null
    fi
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        [ -x "$s" ] && { "$s" start >/dev/null 2>&1; break; }
    done
    if ! ip link show "$IFACE" >/dev/null 2>&1 && [ -f "$AWG_SETUP" ]; then
        _ec_gen=$(fw3_gen)
        ( cd "$ENODIA_DIR" && sh ./awg_setup.sh >/tmp/enodia-transport-awg-setup.log 2>&1 )
        [ "$(fw3_gen)" = "$_ec_gen" ] || FW3_WIPED=1
    fi
    i=0; while [ $i -lt 15 ]; do
        ip link show "$IFACE" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# Переиграть ВСЕ цепочки после нашего же fw3-reload. Канонический переигрыш один —
# `vpn-toggle.sh repair` (он знает про apply-bypass, zapret, доп-выходы и «доступ домой»),
# своей копии списка тут быть не должно. Зовём ТОЛЬКО после записи .transport=awg: repair
# читает этот флаг и иначе поднял бы несущую ПРЕЖНЕГО транспорта. Рекурсии нет — на
# transport=awg repair ставит несущую инлайном, awg_setup.sh не трогает (awg0 уже поднят).
# $1 = repair | rules. awg0 НЕ ПОДНЯЛСЯ, а reload уже случился (awg_setup кончается им и при
# провале) ⇒ `rules` — тот же список без несущей: `repair` отказал бы на гарде «awg0 не поднят», и
# снесённое ждало бы ребута. Владелец переигрыша — тот, кто снёс: так он случается при ЛЮБОМ
# вызывателе `up` (откат `switch`, «Включить VPN», heal, сторож), а не у одного из них (ревью dev233).
replay_fw3() {
    [ "$FW3_WIPED" = 1 ] || return 0
    FW3_WIPED=0
    [ -f "$ENODIA_DIR/vpn-toggle.sh" ] || return 0
    log "awg_setup сделал firewall reload — переигрываю цепочки (vpn-toggle $1)"
    sh "$ENODIA_DIR/vpn-toggle.sh" "$1" >/dev/null 2>&1 || true
}

# Наложить awg-несущую поверх mark-core: default dev awg0 + FORWARD awg0 + MASQUERADE
# awg0 + маршрут к VPN_DNS. Это КАРРИЕР-часть split-route.sh (mark-core/ip rule —
# отдельно, тут не трогаем). Идемпотентно.
apply_awg_routing() {
    ip link set "$IFACE" up 2>/dev/null
    # FORWARD ACCEPT (fw3 policy FORWARD=DROP -> без этого LAN-трафик в awg0 дропается)
    ipt_top FORWARD -o "$IFACE" -j ACCEPT
    ipt_top FORWARD -i "$IFACE" -j ACCEPT
    # NAT для исходящего через awg0 (у tun2socks/xtun этого НЕ нужно — он терминирует)
    iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    # СВАП дефолта в боевой таблице на awg0 (маркировку/ip rule mark-core НЕ трогаем)
    ip route replace default dev "$IFACE" table "$TABLE"
}

# Снять awg-несущую (релинквит): убрать default/FORWARD/MASQUERADE awg0. mark-core
# (ip rule + ipset MARK) ОСТАЁТСЯ -> table 1000 без default -> fail-open в main (прямой).
# awg0 НЕ удаляем — тёплый резерв для быстрого кросс-возврата.
remove_awg_routing() {
    ip route del default dev "$IFACE" table "$TABLE" 2>/dev/null
    iptables -D FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null
}

# ---- awg-СЛОТ (доп-выход, мульти-транспорт Ф2) ----------------------------------
# Дизайн: заметки разработки «мультитранспорт-дизайн». «Выход» слота = (awg, configs/<cfg>.conf):
# СВОЯ несущая awg<id> (id 2..7; awg0 = основной), свой UAPI-сокет, свой IP из конфига, default в
# table 100<id>. Марку 0x<id> и `ip rule fwmark -> table 100<id>` ставит mark-core (transport.sh
# после slot-up его переигрывает) — тут ТОЛЬКО карриер: подъём awgN + FORWARD/MASQUERADE + вывод
# endpoint'а из-под маркировки (анти-петля). БЕЗ DNS (один dnsmasq через основной слот, дизайн §DNS),
# БЕЗ guest/firewall-зоны (это awg0-специфика awg_setup.sh). КЛЮЧЕВОЕ ОТЛИЧИЕ от awg_setup.sh:
# НИКАКОГО `killall amneziawg-go` (убил бы awg0 и другие слоты!) — гасим ТОЛЬКО демон СВОЕГО awgN.
slot_iface()   { echo "awg$1"; }               # id 2..7 -> awg2..awg7
slot_table()   { echo "100$1"; }               # id 2 -> 1002 ...
slot_srcconf() { echo "$ENODIA_STATE/configs/$1.conf"; }   # исходный конфиг страны/сервера
slot_ifconf()  { echo "$ENODIA_BIN/awg$1.conf"; }        # сгенерированный stripped conf для setconf

# pid'ы демона amneziawg-go ИМЕННО этого iface (по /proc/*/cmdline: busybox ps ненадёжен с флагами,
# а демон зовётся с полным путём + iface-аргументом — матчим по нему, соседей не заденем).
# `killall` ЗАПРЕЩЁН: инстансов несколько — awg0 (несущая), awgN (доп-выходы), awgs0 («доступ
# домой»). Копий этого перебора в проекте ЧЕТЫРЕ и они объявлены зеркалами (switch-vpn.sh,
# vpn-server.sh, awg_setup.sh) — правя одну, держи их ОДИНАКОВЫМИ либо своди к одному владельцу.
awg_daemon_pids() {   # $1 = iface (awg0 | awgN)
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        case "$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline") " in
            *"amneziawg-go $1 "*) echo "${_p#/proc/}" ;;
        esac
    done
}
# Погасить демон ЭТОГО iface (TERM -> добить KILL) + снять его stale UAPI-сокет. Соседей не трогает.
# Смерть ждём ПО ПРОЦЕССУ с шагом 0.1 с (daemon_wait_gone), а не секундными обходами /proc — первая проверка после TERM
# застаёт демона живым, и каждое снятие стоило целой секунды. Потолки прежние: 3 с на TERM, затем KILL и ещё до 5 с.
awg_kill_daemon() {   # $1 = iface
    _if="$1"
    _akd=$(awg_daemon_pids "$_if")
    for _pid in $_akd; do kill "$_pid" 2>/dev/null; done
    for _pid in $_akd; do
        daemon_wait_gone "$_pid" 3 && continue
        kill -9 "$_pid" 2>/dev/null
        daemon_wait_gone "$_pid" 5
    done
    rm -f "/var/run/amneziawg/$_if.sock" "/var/run/wireguard/$_if.sock" 2>/dev/null
}

# Дефолтный MTU доп-выхода, когда строки MTU= в конфиге нет (у нативных .conf Amnezia её нет
# НИКОГДА). Зеркало AWG_MTU_DEFAULT из awg_setup.sh — полный разбор «почему 1376, а не 1420»
# и замеры с железа там же; правишь одно — правь и второе.
AWG_MTU_DEFAULT=1376

# Сгенерировать stripped iface-conf из configs/<cfg>.conf. Зеркало awg_setup.sh (парс Address/MTU,
# вырезание wg-quick-директив, чистка пустых I1..I5 AWG 2.0, подстановка IP в Endpoint-домен). DNS
# слоту не нужен (свой dnsmasq не поднимаем). Печатает "ADDRESS<TAB>MTU".
slot_gen_conf() {   # $1 = src_conf, $2 = dst iface-conf
    _src="$1"; _dst="$2"
    _addr=$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$_src" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' \t\r')
    _mtu=$(grep -E '^[[:space:]]*MTU[[:space:]]*=' "$_src" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
    # ListenPort — тоже вон (в отличие от прочего он setconf'у ВАЛИДЕН): клиенту фиксированный порт не нужен, а у второго
    # демона с тем же портом (основной awg0, другой выход, «доступ домой») порт уже занят — рукопожатия не будет НИКОГДА.
    # Имя ключа — БЕЗ учёта регистра: парсер wg читает `listenport=` так же, как `ListenPort=`, и строчная запись проходила фильтр
    # мимо (ревью 28.09.2026, круг 2). Зеркало — awg_setup.sh (генератор основного).
    awk '{ t = tolower($0) } !(t ~ /^[[:space:]]*(address|dns|mtu|table|preup|postup|predown|postdown|saveconfig|listenport)[[:space:]]*=/)' "$_src" > "$_dst"
    sed -i '/^[[:space:]]*I[1-5][[:space:]]*=[[:space:]]*$/d' "$_dst" 2>/dev/null   # пустые I1..I5 валят setconf
    _epsrc=$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$_src" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r')
    _ephost=$(echo "$_epsrc" | sed 's/:[0-9]*$//')
    _epport=$(echo "$_epsrc" | sed -n 's/.*:\([0-9]*\)$/\1/p')
    case "$_ephost" in
        ''|\[*) : ;;                                   # нет Endpoint / IPv6-литерал — не подставляем
        # ВНИМАНИЕ: stdout функции — это её РЕЗУЛЬТАТ ("ADDRESS<TAB>MTU", его читает
        # slot_carrier_up через cut), поэтому все сообщения тут строго в stderr.
        *) if ! command -v is_ipv4 >/dev/null 2>&1; then
               # Без dns-lib.sh подставить IP нечем. Молчать тут НЕЛЬЗЯ: `awg setconf` резолвит
               # домен сам через запертый в туннель dnsmasq и, промахнувшись, отвергает конфиг
               # ЦЕЛИКОМ — awgN встанет пустым, а в логе не будет ни строчки о причине.
               log "слот: нет $ENODIA_DIR/dns-lib.sh — Endpoint '$_ephost' останется ИМЕНЕМ; awg setconf может отвергнуть конфиг слота целиком (обновите скрипты)" >&2
           elif ! is_ipv4 "$_ephost"; then
               _epip=$(resolve_ipv4 "$_ephost" 2>/dev/null)
               if [ -n "$_epip" ] && [ -n "$_epport" ]; then
                   sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = $_epip:$_epport|" "$_dst"
               else
                   log "слот: не зарезолвил Endpoint '$_ephost' (ни dnsmasq, ни DoH) — setconf может отвергнуть конфиг слота целиком" >&2
               fi
           fi ;;
    esac
    printf '%s\t%s\n' "$_addr" "$_mtu"
}

# KEEPALIVE ВЫХОДУ ОБЯЗАТЕЛЕН — по нему сторож судит, жив ли выход. WireGuard обновляет рукопожатие, лишь когда через туннель
# ИДУТ ПАКЕТЫ, а у выхода без трафика (привязок нет, устройство спит) их нет никогда: возраст рукопожатия растёт линейно, на
# HS_DEAD сторож объявлял ЖИВОЙ выход мёртвым, гасил его и слал письмо «сервер не отвечает» — каждые пару минут по кругу (замер
# на BE3600 тестера 10.09.2026: исправный awg0 вёл себя так же, его не судили лишь потому, что он был резервом). У нативных
# `.conf` Amnezia строки PersistentKeepalive обычно нет вовсе. С keepalive пакет уходит каждые 25 с, ключи обновляются раз в
# ~2 мин, и «рукопожатие старше HS_DEAD» снова значит «сервер не отвечает». Своё значение конфига уважаем, пока оно НЕ ДЛИННЕЕ
# нашего: при keepalive 100–120 с рукопожатие без трафика стареет до 120 + keepalive ≥ HS_DEAD (180), и ложная «смерть»
# возвращалась бы (ревью 27.09.2026) — такое опускаем до 25. amneziawg печатает значение диапазоном («25-35»): судим по
# первому числу. Тот же предикат «keepalive годен» — у сторожа (watchdog.sh slot_health_sweep, SLOT_KA_MAX = это число).
# Ставим В ЖИВОЙ ДЕМОН (`awg set`), а не в текст конфига: так и тёплый выход, поднятый старой версией без keepalive, получает
# его на ближайшем slot-up (сторож зовёт его сам, когда keepalive не годен).
SLOT_KEEPALIVE=25
slot_keepalive() {   # $1 = iface
    [ -x "$ENODIA_BIN/awg" ] || return 0
    "$ENODIA_BIN/awg" show "$1" persistent-keepalive 2>/dev/null | awk -v cap="$SLOT_KEEPALIVE" '$2=="off" || $2+0>cap {print $1}' | while read -r _kp; do
        [ -n "$_kp" ] && "$ENODIA_BIN/awg" set "$1" peer "$_kp" persistent-keepalive "$SLOT_KEEPALIVE" 2>/dev/null
    done
    return 0
}

# Поднять несущую awgN (id, cfg-name). Возврат 0 = awgN есть. Идемпотентно: живой iface = тёплый,
# конфиг не пересобираем; отсутствует = генерим conf + стартуем демон + IP/MTU/up.
slot_carrier_up() {   # $1 = id ; $2 = cfg
    _id="$1"; _cfg="$2"; _if=$(slot_iface "$_id")
    if ip link show "$_if" >/dev/null 2>&1; then ip link set "$_if" up 2>/dev/null; slot_keepalive "$_if"; return 0; fi
    _am=$(slot_carrier_conf "$_id" "$_cfg") || return 1
    slot_carrier_start "$_id" "$_am"
}
# Собрать ifconf выхода из его конфига: печатает "ADDRESS<TAB>MTU" (вывод slot_gen_conf), 1 — поднимать нечего (причина
# строкой в лог). Отдельно от старта ради ПРОБЫ возврата (cmd_slot_probe): ей анти-петлю ставить МЕЖДУ сборкой и первым пакетом,
# а Endpoint-домен резолвится при сборке — пересобери она конфиг второй раз, исключён был бы один адрес, а стучались бы в другой.
slot_carrier_conf() {   # $1 = id ; $2 = cfg
    # stdout функции — её РЕЗУЛЬТАТ (зовут через `$(…)`), поэтому сообщения строго в stderr — как у slot_gen_conf.
    _src=$(slot_srcconf "$2")
    [ -f "$_src" ] || { log "слот №$1: нет конфига $_src" >&2; return 1; }
    [ -x "$ENODIA_BIN/amneziawg-go" ] && [ -x "$ENODIA_BIN/awg" ] || { log "слот №$1: нет бинарей amneziawg-go/awg" >&2; return 1; }
    _scc=$(slot_gen_conf "$_src" "$(slot_ifconf "$1")")
    [ -n "$(printf '%s' "$_scc" | cut -f1)" ] || { log "слот №$1: в $_src нет Address — awgN был бы без IPv4, не поднимаю" >&2; return 1; }
    printf '%s\n' "$_scc"
}
# Стартовать демон awgN на УЖЕ собранном ifconf: $2 — вывод slot_carrier_conf.
slot_carrier_start() {   # $1 = id ; $2 = "ADDRESS<TAB>MTU"
    _id="$1"; _if=$(slot_iface "$_id"); _dst=$(slot_ifconf "$_id")
    _addr=$(printf '%s' "$2" | cut -f1); _mtu=$(printf '%s' "$2" | cut -f2)
    awg_kill_daemon "$_if"                      # добить возможный stale-демон/сокет ИМЕННО awgN
    # GOMEMLIMIT — см. разбор в шапке net-tune.sh (он единственный владелец значения). Слот такой
    # же демон, как awg0: без потолка его куча растёт по трафику, а на тесной модели их несколько.
    # grep по ФОРМЕ — гард на рассинхрон версий: старый net-tune.sh печатает на этот верб `usage: …`
    # в stdout, и оно стало бы первым аргументом env (демон не стартует). См. шапку net-tune.sh.
    env $(sh "$ENODIA_DIR/net-tune.sh" memlimit-env 2>/dev/null | grep -E '^GOMEMLIMIT=[0-9]+MiB$') "$ENODIA_BIN/amneziawg-go" "$_if" || { log "слот №$_id: amneziawg-go $_if не стартовал"; return 1; }
    _i=0; while ! ip link show "$_if" >/dev/null 2>&1 && [ "$_i" -lt 10 ]; do sleep 1; _i=$((_i+1)); done
    ip link show "$_if" >/dev/null 2>&1 || { log "слот №$_id: $_if не появился"; awg_kill_daemon "$_if"; return 1; }
    "$ENODIA_BIN/awg" setconf "$_if" "$_dst"
    slot_keepalive "$_if"
    ip a add "$_addr" dev "$_if" 2>/dev/null
    ip link set dev "$_if" mtu "${_mtu:-$AWG_MTU_DEFAULT}" 2>/dev/null
    ip link set up "$_if"
    return 0
}

# Вывести endpoint слота из-под маркировки (анти-петля). Берём IP из СГЕНЕРИРОВАННОГО ifconf (там
# Endpoint уже подставлен как IP). Аддитивно, не затирая основной endpoint-bypass (apply-bypass).
slot_exclude_endpoint() {   # $1 = id
    _id="$1"; _dst=$(slot_ifconf "$_id")
    _ep=$(grep -E '^[[:space:]]*Endpoint' "$_dst" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//; s/[[:space:]]//g')
    if echo "$_ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "$_ep" >/dev/null 2>&1
        log "слот №$_id: endpoint $_ep исключён из маркировки (анти-петля)"
    else
        log "слот №$_id: endpoint не IPv4/не определён — пропуск анти-петли"
    fi
}

# Наложить карриер-часть слота: default dev awgN в table 100N + FORWARD ACCEPT + MASQUERADE.
# ip rule (fwmark 0xN -> table 100N) ставит mark-core (transport.sh переигрывает после slot-up).
slot_apply_routing() {   # $1 = id
    _id="$1"; _if=$(slot_iface "$_id"); _tab=$(slot_table "$_id")
    ip link set "$_if" up 2>/dev/null
    ipt_top FORWARD -o "$_if" -j ACCEPT
    ipt_top FORWARD -i "$_if" -j ACCEPT
    iptables -t nat -C POSTROUTING -o "$_if" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$_if" -j MASQUERADE
    ip route replace default dev "$_if" table "$_tab"
}
slot_remove_routing() {   # $1 = id
    _id="$1"; _if=$(slot_iface "$_id"); _tab=$(slot_table "$_id")
    ip route del default dev "$_if" table "$_tab" 2>/dev/null
    iptables -D FORWARD -o "$_if" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$_if" -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$_if" -j MASQUERADE 2>/dev/null
}

# Контракт слота (transport.sh _slot_dispatch): slot-up <id> <cfg> / slot-down <id>.
cmd_slot_up() {   # $1 = id, $2 = cfg
    _id="$1"; _cfg="$2"
    case "$_id" in [2-7]) ;; *) log "слот: id = 2..7"; return 1 ;; esac
    [ -n "$_cfg" ] && [ "$_cfg" != '-' ] || { log "слот №$_id: awg-выходу нужен конфиг (configs/<имя>.conf)"; return 1; }
    # КЛЮЧ ЗАНЯТ — НЕ ПОДНИМАЕМ (последний рубеж; форма отказывает раньше — slots.sh add/set/enable). Сюда доходит то, что мимо
    # формы: импорт бэкапа с чужого роутера, ручная правка `.slots`, перезалитый файл конфига. Поднятый выход на чужом ключе
    # выбивал бы сессию у основного канала или соседа и гас бы сам. Судим по ФАКТУ (`live`: сессию занимает живой awg0, живой
    # сосед или основной-AmneziaWG), а не по намерению: иначе снимался бы и РАБОТАЮЩИЙ выход, чей ключ лишь числится за
    # выключенным соседом или за `awg.conf` при основном VLESS (ревью 27.09.2026). Отказ ПУСТОЙ: живую несущую выхода снимаем,
    # трафик выхода идёт по его запасному пути; причину видит панель (`key_clash` выхода). Гард по наличию `-f` (C27): без
    # slots.sh судить нечем — прежний путь.
    if [ -f "$ENODIA_DIR/slots.sh" ] && _kb=$(sh "$ENODIA_DIR/slots.sh" key-holder "$_cfg" "$_id" live 2>/dev/null); then
        log "слот №$_id: не поднимаю — $_kb"
        ip link show "$(slot_iface "$_id")" >/dev/null 2>&1 && cmd_slot_down "$_id"
        return 1
    fi
    if ! slot_carrier_up "$_id" "$_cfg"; then
        log "слот №$_id: несущая awg не поднялась → выход живёт по fallback-политике (mark-core)"
        return 1
    fi
    slot_exclude_endpoint "$_id"                # ifconf сгенерирован → endpoint известен
    slot_apply_routing "$_id"
    ct_flush
    log "слот №$_id: awg-несущая $(slot_iface "$_id") в table $(slot_table "$_id") (конфиг $_cfg)"
    return 0
}
cmd_slot_down() {   # $1 = id
    _id="$1"
    case "$_id" in [2-7]) ;; *) log "слот: id = 2..7"; return 1 ;; esac
    _if=$(slot_iface "$_id")
    slot_remove_routing "$_id"
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "" >/dev/null 2>&1   # снять анти-петлю слота
    awg_kill_daemon "$_if"                      # гасим демон (владелец TUN) — TUN уходит следом
    ip link del "$_if" 2>/dev/null              # cleanup, если TUN пережил демон
    ct_flush
    log "слот №$_id: awg-несущая $_if снята"
    return 0
}

# ВОЗВРАТ СНЯТОГО ВЫХОДА — ПРОБА СЕРВЕРА БЕЗ ПЕРЕПРОВОДКИ (тестер 02.10.2026: выход, снятый сторожем, лежал до ручного «выключить
# и включить» или ребута). Пробовать полным slot-up нельзя: он кончается ct_flush — сброс УСТАНОВЛЕННЫХ соединений всего дома, — и
# на лежащем сервере сторож платил бы этим на каждой попытке. Проба — свой awgN БЕЗ маршрута в table 100N: mark-core судит выход
# по default в 100N (slots.sh slot_state — так же), значит метки выхода по-прежнему едут запасным путём, а панель видит то же
# состояние. Анти-петля — ДО первого пакета: иначе рукопожатие ушло бы в основной туннель (IP сервера в iplist_set) и «прошло»
# там, где прямой путь к серверу закрыт, — выход вернулся бы, чтобы через три минуты лечь снова. Первый пакет шлёт keepalive на
# подъёме (slot_keepalive до `ip link set up`). Рукопожатие есть — достраиваем выход ровно как slot-up (маршрут + ct_flush), нет —
# снимаем всё поднятое; сброса соединений у неудачной попытки нет. Коды: 0 — выход вернулся · 1 — сервер не ответил · 3 — ключ занят
# живым держателем: сервер ни при чём, причину покажет панель (key_clash) · 4 — несущая не встала (нет конфига, программы AmneziaWG,
# демон не стартовал; причина строкой выше): сервер НЕ СУДИЛИ, и письмо «сервер не отвечает» было бы неправдой · 5 — несущая уже
# есть (её держит кто-то другой — панель, heal): пробовать нечего, и это НЕ возврат · 6 — выход выключили или перевели на другой
# конфиг, пока шла проба (verbs панели лока не берут): поднятое снято, вердикта нет (ревью с.93, круг 2 — прежде выключенный выход
# мог остаться с живым awgN и маршрутом до ребута).
# Реестр: выход всё ещё включён, AmneziaWG и на этом конфиге? Без slots.sh судить нечем — считаем «да».
slot_reg_is() {   # $1 = id ; $2 = cfg
    [ -f "$ENODIA_DIR/slots.sh" ] || return 0
    _sri=$(sh "$ENODIA_DIR/slots.sh" show "$1" 2>/dev/null)
    [ "$(printf '%s' "$_sri" | cut -f6)" = on ] && [ "$(printf '%s' "$_sri" | cut -f3)" = awg ] && [ "$(printf '%s' "$_sri" | cut -f4)" = "$2" ]
}
SLOT_PROBE_WAIT=15   # с: живой сервер отвечает за доли секунды; не дошедшую инициацию WireGuard повторяет через 5 с
cmd_slot_probe() {   # $1 = id, $2 = cfg
    _id="$1"; _cfg="$2"
    case "$_id" in [2-7]) ;; *) log "слот: id = 2..7"; return 1 ;; esac
    [ -n "$_cfg" ] && [ "$_cfg" != '-' ] || { log "слот №$_id: awg-выходу нужен конфиг (configs/<имя>.conf)"; return 1; }
    _if=$(slot_iface "$_id")
    # Несущая уже есть — пробовать нечего: её поднял кто-то другой (heal, панель), судить её будет следующий тик по рукопожатию.
    ip link show "$_if" >/dev/null 2>&1 && return 5
    if [ -f "$ENODIA_DIR/slots.sh" ] && _kb=$(sh "$ENODIA_DIR/slots.sh" key-holder "$_cfg" "$_id" live 2>/dev/null); then
        log "слот №$_id: пробу возврата не делаю — $_kb"
        return 3
    fi
    _am=$(slot_carrier_conf "$_id" "$_cfg") || return 4
    slot_reg_is "$_id" "$_cfg" || return 6       # выключили/сменили, пока тик шёл к нам — ничего не поднимаем
    slot_exclude_endpoint "$_id"                # проба: анти-петля ДО первого пакета (см. шапку)
    _spr=4; _spp=""
    # Пока собирали конфиг (резолв Endpoint — секунды), выход могла поднять панель: slot_carrier_start первым делом гасит демон на
    # awgN — чужой, — так что ещё раз спрашиваем, прежде чем стартовать (ревью с.96, круг 3).
    if ip link show "$_if" >/dev/null 2>&1; then log "слот №$_id: пока собирали конфиг, выход поднял кто-то другой — пробу не начинаю"; return 5; fi
    if slot_carrier_start "$_id" "$_am"; then
        _spr=1
        # ДЕМОН ЭТОЙ ПРОБЫ — по пиду (ревью с.93, круг 3). За 15 секунд панель может сменить выходу сервер или выключить и
        # включить его (slots.sh: slot-down гасит наш демон, slot-up рождает НОВЫЙ awgN с маршрутом и анти-петлёй). Интерфейс тот же
        # по имени, и уборка по имени снесла бы выход, поднятый панелью, — а при fallback=main его трафик ушёл бы напрямую.
        _spp=$(awg_daemon_pids "$_if")
        # Демона нет уже сейчас — несущая не встала (сервер не судили): код 4, а не 15 с ожидания и «сервер не отвечает» (ревью с.96).
        [ -n "$_spp" ] || { _spr=4; log "слот №$_id: amneziawg-go $_if умер сразу после старта — несущая не встала"; }
        _w=0
        while [ -n "$_spp" ] && [ "$_w" -lt "$SLOT_PROBE_WAIT" ]; do
            # Демон сменился — выход теперь чужой: судить его будет следующий тик, а наше снимать нечего (код 5, как «несущая уже есть»).
            [ "$(awg_daemon_pids "$_if")" = "$_spp" ] || { _spr=5; break; }
            # Интерфейс новый: любая ненулевая отметка — рукопожатие ЭТОЙ пробы, возраст считать не нужно.
            _hs=$("$ENODIA_BIN/awg" show "$_if" latest-handshakes 2>/dev/null | awk 'NR==1{print $2+0}')
            if [ "${_hs:-0}" -gt 0 ]; then
                # Последняя сверка перед маршрутом: выход выключили или сменили за эти секунды — маршрут не ставим, поднятое снимаем.
                if ! slot_reg_is "$_id" "$_cfg"; then _spr=6; break; fi
                slot_apply_routing "$_id"
                ct_flush
                log "слот №$_id: сервер ответил за ${_w}с — awg-несущая $_if снова в table $(slot_table "$_id") (конфиг $_cfg)"
                return 0
            fi
            sleep 1; _w=$((_w+1))
        done
        case "$_spr" in
            6) log "слот №$_id: выход выключили или сменили, пока шла проба, — поднятое снимаю, маршрут не ставлю" ;;
            5) ;;
            *) log "слот №$_id: сервер не ответил за ${SLOT_PROBE_WAIT}с — выход остаётся на запасном пути" ;;
        esac
    fi
    # Уборка — ТОЛЬКО своего: демон на интерфейсе уже не наш (панель подняла выход заново) — ни демона, ни интерфейса, ни
    # анти-петли не трогаем. Нашего нет вовсе — его снял чужой slot-down, и, может быть, slot-up той же панели уже ставит
    # анти-петлю нового сервера: снятая нами, она отправила бы рукопожатие выхода в основной туннель. Уборка — за тем, кто снял.
    _spn=$(awg_daemon_pids "$_if")
    if [ -n "$_spp" ] && [ "$_spn" != "$_spp" ]; then
        if [ -n "$_spn" ]; then log "слот №$_id: пока шла проба, выход поднял кто-то другой (панель) — его не трогаю"
        else log "слот №$_id: демон пробы снят кем-то другим (панель) — уборка за ним"; fi
        return 5
    fi
    # Демон тот же, но выход ДОСТРОИЛ кто-то другой: тёплый slot-up (сохранение группы или гео, heal replay) взял наш awgN как есть и
    # положил маршрут в 100N. Уборка снесла бы достроенный выход, а ip rule смотрел бы в пустую таблицу (ревью с.96, круг 2).
    if [ -n "$_spp" ] && ip route show table "$(slot_table "$_id")" 2>/dev/null | grep -q "^default dev $_if"; then   # not-wan: несущая СЛОТА (table 100N)
        log "слот №$_id: пока шла проба, выход достроил кто-то другой (slot-up) — его не трогаю"
        return 5
    fi
    awg_kill_daemon "$_if"
    ip link del "$_if" 2>/dev/null
    [ -f "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-slot-set "$_id" "" >/dev/null 2>&1   # проба не удалась: анти-петлю снять
    return "$_spr"
}

# ---- команды контракта ----------------------------------------------------
cmd_up() {
    # ЧАСЫ — ДО НЕСУЩЕЙ, и именно ЗДЕСЬ, а не только в heal: несущую поднимают и мимо него —
    # панель (switch-vpn apply_routing), `vpn-toggle repair`, reup сторожа. С часами «на прошлом
    # буте» сервер отбрасывает наше рукопожатие как повтор (clock-lib.sh, замер 05.09.2026); после
    # первой удачи это один тест `[ -f ]` (отметка 1×/boot). Нет библиотеки — no-op.
    if command -v clock_boot_sync >/dev/null 2>&1 && clock_boot_sync; then log "$CLOCK_MSG"; fi
    if ! ensure_carrier; then
        log "awg0 не поднялся — несущую не активирую"
        replay_fw3 rules
        return 1
    fi
    exclude_endpoint        # анти-петля: endpoint мимо маркировки ДО постановки default->awg0
    apply_awg_routing
    restore_vpn_dns
    echo awg > "$TRANSPORT_FLAG"
    replay_fw3 repair       # только ПОСЛЕ записи флага: repair поднимает несущую по .transport
    # Ручная/оркестраторная смена транспорта = новый «эпизод» для авто-failover.
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    ct_flush
    log "транспорт = AmneziaWG (default table $TABLE -> $IFACE). mark-core сохранён."
    cmd_status
}

cmd_down() {
    remove_awg_routing
    set_public_dns
    # .transport НЕ переписываем: «кто активен» решает оркестратор (он поднимет
    # следующий транспорт). Снятая несущая = прямой режим до следующего up.
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    ct_flush
    log "AmneziaWG-несущая снята ($IFACE — тёплый резерв, трафик напрямую)."
}

# ХОЛОДНОЕ СНЯТИЕ — «выключили VPN целиком», а не сменили транспорт. Зовут ПОСЛЕ `down`.
# Тёплый резерв оправдан ровно одним сценарием: awg ждёт, пока везёт другой транспорт, и тогда
# кросс-возврат стоит один `setconf` вместо старта демона и рукопожатия. При снятом тумблере
# (`.vpn-off`) этого сценария НЕТ: сторож с флагом выходит из тика, heal на буте awg0 не
# поднимает даже резервом. Демон держался ради дороги, которая запрещена, и стоило это:
#   * keepalive/handshake к VPS продолжали идти — на линии видно, что «выключенный» роутер
#     разговаривает с сервером, и объяснить это человеку было нечем;
#   * пул буферов amneziawg-go ядру НЕ возвращается (лечится только GOMEMLIMIT), а `down` его не
#     сбрасывает, а ЗАМОРАЖИВАЕТ на достигнутом: на 176-МБ моделях это замеренные 40+ МБ впустую;
#   * и главное — «выключено» означало РАЗНОЕ до ребута и после (на буте несущей уже нет).
# Маршрут/NAT/DNS здесь не трогаем: их отпустил `down`, у холодного снятия ровно одна работа.
cmd_cold() {
    awg_kill_daemon "$IFACE"
    # Демон — владелец TUN, интерфейс уходит следом. Остался ⇒ это зомби (демон умер раньше, чем
    # мы пришли): нести он всё равно не может — `setconf` применять некому, — а `ensure_carrier`
    # увидит «интерфейс есть» и НЕ пересоздаст его. Тогда `on` поднимет пустую несущую.
    if ip link show "$IFACE" >/dev/null 2>&1; then ip link del "$IFACE" 2>/dev/null; fi
    log "AmneziaWG-несущая погашена холодно ($IFACE снят вместе с демоном)."
}

# REWARM — the WARM RESERVE again, on the installed build (Components → «Перезапустить» while ANOTHER transport carries). A restart
# means «the same state on the new file»: heal raises awg0 as a reserve on purpose (section 1), and the watchdog reads its handshake
# to notice the home server is back (watchdog.sh::awg_watchable) — `cold` alone would end the return home until a reboot (review of
# bins-2026-10, round 2). The same bring-up as `up` (ensure_carrier), minus everything that carries: no routing, no DNS — they belong
# to the active transport. A reload awg_setup itself caused is replayed by its owner, `repair`, under the ACTIVE transport's flag.
# awg carrying (or implied: no flag) — refused: that is the main channel, `transport.sh restart`.
cmd_rewarm() {
    case "$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')" in
        ""|awg) log "rewarm: AmneziaWG сейчас несёт трафик — это основной канал, а не резерв"; return 1 ;;
    esac
    cmd_cold
    if ensure_carrier; then replay_fw3 repair; log "тёплый резерв AmneziaWG поднят заново ($IFACE)"; return 0; fi
    replay_fw3 repair
    log "rewarm: $IFACE не поднялся — резерв пропал до следующей загрузки"
    return 1
}

cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')
    [ "$t" = awg ] || return 0          # активен не awg — судить не нам
    carrier_up || { log "health: $IFACE не поднят"; return 1; }
    age=$(hs_age)
    if [ "$age" -ge "$HS_MAX" ]; then
        log "health: handshake устарел (${age}с >= ${HS_MAX}с)"
        return 1
    fi
    return 0
}

# Перебор awg-резервов делегируем в switch-vpn.sh failover — ЕДИНЫЙ источник правды
# (там safety_off -> перебор configs/*.conf -> apply_routing -> письма; DNS возвращаем мы,
# apply_routing зовёт `transport-awg.sh up`).
# Дублировать do_failover здесь нельзя (два источника правды по перебору, дрейф).
cmd_failover() {
    [ -f "$SWITCH" ] || { log "нет $SWITCH"; return 1; }
    sh "$SWITCH" failover
}

cmd_status() {
    # ФАКТ ФЛАГА, а не догадка. Прежнее `${t:-awg}` печатало «awg» на установке «только панель»,
    # где транспорт не выбирали НИ РАЗУ, — и печатало это в ДАМП, вчетвером с остальными плагинами.
    # Читатель разбора получал четыре независимых подтверждения того, чего нет. Что означает пустой
    # флаг (старый роутер или «только панель»), знает ОДИН верб — `transport.sh configured`; его и
    # спрашивает дамп в своей секции. Плагину положено сообщать факт: флаг пуст. Формулировка —
    # ОБЩАЯ с тремя остальными плагинами и БЕЗ ссылки на секцию дампа: срез читают и из SSH, где
    # никакой «секции выше» нет, а четыре разных текста про одно состояние читаются как четыре
    # разных состояния.
    t=; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')
    echo "--- transport-awg status ---"
    echo "активный транспорт (.transport): ${t:-(флаг пуст — транспорт не выбран)}"
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default || echo "(нет default — прямой режим)"   # raw-print: сырой вывод человеку в `status`, вердикта тут нет
    echo "--- $IFACE ---"; ip link show "$IFACE" >/dev/null 2>&1 && echo "поднят (handshake $(hs_age)с назад)" || echo "нет"
    echo "--- FORWARD $IFACE ---"; iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null && echo "ACCEPT есть" || echo "нет"
}

# СНЯТИЕ ПОДНЯТОГО, если VPN выключили по ходу подъёма (carrier_run): то же, что делает `vpn-toggle off` с этим транспортом, —
# отпустить маршрут и DNS и погасить демон (тёплый резерв при выключенном VPN не нужен).
carrier_undo() { cmd_down; cmd_cold; }

# ПОКОЛЕНИЕ ПРОТОКОЛА КОНФИГА — ЕДИНСТВЕННЫЙ ответ (бейдж «Серверов» через cgi-bin/list, строка status.sh): «имя⇥поколение» на
# файл, поколение — wg · 1.0 · 1.5 · 2.0 · 3.0 · 3.1. Номера версии в файле нет, судим по ПОЛЯМ, и решает самое старшее: 3.1 —
# RandomTrailers/DisableCookies (3.0 такой конфиг отвергает целиком); 3.0 — HeaderProtectionKey, ContentPaddingAddition, свои
# тайминги; 2.0 — S3/S4 или H1–H4 ДИАПАЗОНОМ; 1.5 — I1–I5 (пустые не в счёт: awg_setup.sh их вычищает), J1–J3, Itime; 1.0 —
# Jc/Jmin/Jmax/S1/S2/H1–H4; ни одного — обычный WireGuard. Все файлы — ОДНИМ проходом awk (список «Серверов» спрашивает разом);
# пустой файл строки не получает. Функций у busybox-awk нет — итог собираем в массив и печатаем в END.
cmd_conf_gen() {
    [ $# -gt 0 ] || return 0
    awk '
        FNR == 1 { n++; nm = FILENAME; sub(/^.*\//, "", nm); sub(/\.conf$/, "", nm); N[n] = nm; G[n] = 0 }
        { sub(/\r$/, "") }
        !/=/ { next }
        {
            k = $0; sub(/[ \t]*=.*$/, "", k); sub(/^[ \t]+/, "", k)
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            if (v == "") next
            r = 0
            if (k == "RandomTrailers" || k == "DisableCookies") r = 31
            else if (k == "HeaderProtectionKey" || k == "ContentPaddingAddition" || k == "RekeyAfterTime" || k == "RejectAfterTime" || k == "KeepaliveTimeout" || k == "MaxHandshakeAttempts") r = 30
            else if (k == "S3" || k == "S4") r = 20
            else if (k ~ /^H[1-4]$/ && v ~ /^[0-9]+[ \t]*-[ \t]*[0-9]+$/) r = 20
            else if (k ~ /^(I[1-5]|J[1-3]|Itime)$/) r = 15
            else if (k ~ /^(Jc|Jmin|Jmax|S1|S2|H[1-4])$/) r = 10
            if (r > G[n]) G[n] = r
        }
        END {
            for (i = 1; i <= n; i++) {
                g = "wg"
                if (G[i] == 31) g = "3.1"; else if (G[i] == 30) g = "3.0"; else if (G[i] == 20) g = "2.0"; else if (G[i] == 15) g = "1.5"; else if (G[i] == 10) g = "1.0"
                printf "%s\t%s\n", N[i], g
            }
        }' "$@" 2>/dev/null
}

case "$1" in
    # Вербы, которые БЕРУТ несущую, — через carrier_run (daemon-lib.sh): при выключенном вручную VPN отказ, а выключение, пришедшее
    # по ходу, отпускает поднятое. Перебор серверов (failover) проверяет флаг и сам — на каждом кандидате (switch-vpn.sh).
    up)       carrier_run carrier_undo cmd_up ;;
    down)     cmd_down ;;
    cold)     cmd_cold ;;                 # «выключили VPN» — гасим демон, тёплый резерв не нужен
    # тёплый резерв на установленной сборке (перезапуск в «Компонентах»); отпускаем поднятое тем же холодным снятием, не `down`:
    # `down` снял бы маршрут и DNS — а они чужие, активного транспорта
    rewarm)   carrier_run cmd_cold cmd_rewarm ;;
    status)   cmd_status ;;
    health)   cmd_health ;;
    failover) carrier_run carrier_undo cmd_failover ;;
    # DNS активной несущей (DoH toggle/смена резолвера) — через doh_apply_dns. При выключенном VPN туннельного DNS нет: адрес в awg0,
    # которого нет, оставил бы без имён весь дом — ставим прямой, как `down`.
    dns)      if carrier_barred; then set_public_dns; else restore_vpn_dns; fi ;;
    slot-up)   carrier_run cmd_slot_down cmd_slot_up "$2" "$3" ;;   # доп-выход (Ф2): поднять awgN в table 100N
    slot-down) cmd_slot_down "$2" ;;      # доп-выход: снять awgN (-> fallback-политика mark-core)
    slot-probe) carrier_run cmd_slot_down cmd_slot_probe "$2" "$3" ;;   # снятый выход: проба сервера без перепроводки, жив — вернуть
    # ИМЯ НЕСУЩЕЙ СЛОТА — ТОЛЬКО ОТСЮДА. Спрашивает учёт трафика (traffic-acct.sh через
    # transport.sh slot-iface): «сколько прошло через выход №N» считается по счётчикам ЕГО
    # интерфейса, и третьей копии формулы «id -> awgN» в проекте быть не должно — она уже
    # живёт в двух местах (здесь и slot_tun в slot-tun-lib.sh), и разъехались бы они молча.
    slot-iface) slot_iface "$2" ;;
    conf-gen)   shift; cmd_conf_gen "$@" ;;   # поколение протокола конфигов (разбор у cmd_conf_gen)
    *) echo "usage: $0 up|down|cold|rewarm|status|health|failover|dns|slot-up <id> <cfg>|slot-down <id>|slot-probe <id> <cfg>|slot-iface <id>|conf-gen <файл>…"; exit 2 ;;
esac
