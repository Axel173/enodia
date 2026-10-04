#!/bin/sh
# transport-byedpi.sh — плагин ТРАНСПОРТА ByeDPI (ciadpi): DPI-десинк БЕЗ VPS.
#
# ИДЕЯ. Это близкий клон xray-transport.sh / transport-hy2.sh, но с принципиальным отличием:
# byedpi НЕ ходит к VPS-серверу. ciadpi — локальный SOCKS5-десинкер: он коннектится НАПРЯМУЮ
# к реальному адресу и десинхронизирует первые сегменты (TLS ClientHello / SNI) так, что DPI
# не успевает заблокировать. То есть «несущая» здесь = прямой выход с обходом DPI, без тоннеля
# и без оплаты VPS. Переиспользуем тот же tun2socks-слой (hev → xtun → socks 10808), что и
# xray/hy2: для hev безразлично, КТО слушает 127.0.0.1:10808 — туда сажаем ciadpi.
#
# ПЕТЛЯ (главное отличие от xray/hy2). У xray/hy2 один VPS-endpoint, который мы исключаем из
# маркировки. У byedpi endpoint'а нет — он коннектится к САМИМ заблок-сайтам, а их IP лежат в
# iplist_set. Значит ИСХОДЯЩИЙ сокет ciadpi (роутер-origin, OUTPUT) попал бы под mark-core OUTPUT
# → table 1000 → xtun → hev → ciadpi → ∞. Исключить по endpoint нельзя (endpoint = сам сайт).
# Различитель — uid процесса: ciadpi гоняем под nobody (65534), а в mangle OUTPUT перед
# маркировкой ставим `-m owner --uid-owner 65534 -j RETURN`. Тогда egress ciadpi НЕ метится →
# main → напрямую (десинкнуто). LAN-форвард не задет: он в PREROUTING, где owner неприменим.
# (owner работает только для локально-порождённых пакетов в OUTPUT/POSTROUTING — ровно наш кейс.)
# Проверено на железе 2026-06-17: xt_owner есть+загружен, nobody есть, ssd -c поддержан.
#
# DNS. Тоннеля нет → DNS ведём НАПРЯМУЮ (публичный резолвер, БЕЗ маркировки в туннель), чтобы
# получать реальные IP (ciadpi коннектится по IP, который ему отдаёт hev). Зеркало set_direct_dns
# из xray/hy2. (Ограничение v1: если провайдер ПОДМЕНЯЕТ DNS-ответы для заблок-доменов, ciadpi
# получит чужой IP и десинк не поможет — это адресуется DoH/own-resolve позже.)
#
# ДЕСИНК-ПАРАМЕТРЫ. Они ISP-специфичны (у каждого провайдера свой DPI). Читаем из
# $ENODIA_STATE/.byedpi-args (пишет панель/ПК); нет файла → дефолт $DEFAULT_ARGS = `-A auto` с набором
# стратегий (split/disorder/split+fake/tlsrec), который byedpi сам перебирает и кэширует по IP.
# На железе подтверждено: discord ← disorder (-d 1+s), youtube ← split+fake (-s 1+s -f 2+s -t 4);
# жёсткому ISP часть сайтов нужен ручной тюнинг — для того и .byedpi-args + advanced в панели.
#
# БЕЗОПАСНОСТЬ. Всё на ip rule fwmark→table 1000. Если xtun исчезнет (hev/ciadpi умер) — маршрут
# уходит с устройством, table 1000 пустеет, fwmark-трафик падает в main → НАПРЯМУЮ (fail-open, не
# блэкхол). awg0 НЕ опускаем (тёплый резерв). Ребут = сброс к awg (heal). owner-RETURN снимаем в down.
#
# ГРАБЛИ (как у xray/hy2): нет nohup/setsid → демон через start-stop-daemon -b; есть полноценный
# curl (--socks5-hostname) для health-пробы. ciadpi под -c nobody: лог в /tmp писать в файл с
# правами на запись для nobody (предсоздаём chmod 666).
#
# Использование:
#   transport-byedpi.sh up        — активировать ByeDPI-транспорт (весь дом)
#   transport-byedpi.sh down      — ЧИСТО отпустить несущую → fail-open в прямой (релинквиш)
#   transport-byedpi.sh status    — показать состояние
#   transport-byedpi.sh health    — здоровье транспорта (для watchdog): 0 здоров / 1 нет
#   transport-byedpi.sh failover  — нет резервов-конфигов (десинк локальный) → 1 (watchdog эскалирует cross)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
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
# Где лежит бинарь (store-lib.sh): без накопителя — прежний путь байт-в-байт. Шим на случай
# установки без lib.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
# Возраст lock'а свипа — через age_since (clock-lib.sh): lock в /tmp рождается после загрузки, а часы
# без RTC прыгают вперёд ⇒ голая разность делает идущий свип «протухшим», и health восстанавливает
# стратегию из-под браузера. Шим = прежнее поведение. [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
# Шим отметки подъёма несущей: старая установка без свежей clock-lib не должна падать на
# неизвестной команде посреди cmd_up — просто останется без грейса, то есть с прежним поведением.
command -v carrier_up_mark >/dev/null 2>&1 || carrier_up_mark() { return 0; }
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Ожидание СТАРТА демона (daemon-lib.sh). Фиксированный срок мерил не то: он подобран под флеш
# (1.4 ГБ/с) и заведомо мал для накопителя (замер 448 КБ/с ⇒ 8-МБ бинарь читается 18 с) — исправный
# демон объявлялся мёртвым и убивался. Владелец судит по ЖИЗНИ ПРОЦЕССА, потолок берёт от носителя.
# Нет файла (частичный apply-scripts) — шим повторяет ПРЕЖНИЙ путь: фиксированный срок и никакого
# различения «умер»/«жив, но не готов».
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
# «VPN выключен вручную — несущую не берёт никто» (carrier_barred/carrier_run, разбор в daemon-lib.sh). Нет — прежний путь.
command -v carrier_barred >/dev/null 2>&1 || carrier_barred() { return 1; }
command -v carrier_run >/dev/null 2>&1 || carrier_run() { shift; "$@"; }
command -v daemon_wait_port >/dev/null 2>&1 || daemon_wait_port() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0; sleep 1; _dwi=$((_dwi+1)); done
    netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0
    DAEMON_WAIT_WHY="не появился за $3 с"; return 1; }
command -v daemon_wait_dev >/dev/null 2>&1 || daemon_wait_dev() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do ip link show "$4" >/dev/null 2>&1 && return 0; sleep 1; _dwi=$((_dwi+1)); done
    ip link show "$4" >/dev/null 2>&1 && return 0
    DAEMON_WAIT_WHY="не появился за $3 с"; return 1; }
TABLE=1000
TUN=xtun
SOCKS_ADDR=127.0.0.1
SOCKS_PORT=10808                                # ТОТ ЖЕ порт, что у xray/hy2 → общий hev.yaml несёт любого
CIADPI=$(bin_path byedpi)        # самосборный статик-бинарь ciadpi (bin/byedpi.user)
HEV=$(bin_path hev)
HEV_YAML="$ENODIA_DIR/hev.yaml"
ARGS_FILE="$ENODIA_STATE/.byedpi-args"          # десинк-аргументы (пишет панель/ПК); нет → DEFAULT_ARGS
CIADPI_PID=/tmp/enodia-byedpi.pid
HEV_PID=/tmp/enodia-hev.pid
CIADPI_LOG=/tmp/enodia-byedpi.log
HEV_LOG=/tmp/enodia-hev.log
TRANSPORT_FLAG="$ENODIA_STATE/.transport"
SWITCH_LOCK=/tmp/enodia-switching.lock          # ручная смена транспорта (панель/меню/оркестратор) держит его → health/failover не вмешиваются
DNS1=1.1.1.1
DNS2=8.8.8.8
FWMARK=0x1
BYEDPI_UID=65534                                # nobody (см. /etc/passwd) — под ним гоняем ciadpi, его egress мимо маркировки
SWEEP_LOCK=/tmp/enodia-byedpi-sweep.lock        # браузер-свип идёт (timestamp). Свежий → health/failover НЕ вмешиваются
SWEEP_BAK="$ENODIA_STATE/.byedpi-args.sweepbak" # бэкап исходной стратегии на время свипа (пустой файл = исходная была авто)
SWEEP_TTL=150                                   # свежесть lock (сек): браузер рефрешит на каждом apply; протух → свип брошен

# Дефолтный набор стратегий для авто-режима. byedpi перебирает их и кэширует рабочую по IP
# ($-u сек). Стратегия 0 (ДО первого -A) = split+fake — на железе берёт YouTube; альты:
# disorder (берёт Discord) / split / tlsrec. -L 3 = auto-mode sort+post_resp, -T 5 = триггер по
# таймауту. Проверено на железе 2026-06-17: этот дефолт даёт YouTube+Discord на агрессивном ISP
# (Meta/Telegram/rutracker там IP-блок/throttle — десинк не лечит, нужен VPS). Тюнится .byedpi-args / панель.
DEFAULT_ARGS="-L 3 -T 5 -u 3600 -s 1+s -f 2+s -t 4 -A torst,redirect,ssl_err -d 1+s -A torst,redirect,ssl_err -s 1+s -A torst,redirect,ssl_err -r 1+s"

# Общий примитив «внешний IPv4» (ip-lib.sh) для status-пробы egress: IP-литерал, DNS-free — на
# ядре 4.4 hostname api.ipify.org молча пустел. Шим на случай частичной установки без lib.
# (health ниже НЕ трогаем — там намеренно проба ПО IP через --socks5, а не по имени.)
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }
# Слой шифрованного DNS (doh-lib.sh): при включённом DoH резолв идёт через локальный прокси
# (dnsmasq→127.0.0.1#5053), :443 резолвера держим МИМО маркировки (иначе xtun→ciadpi десинкал
# бы HTTPS/2 DoH). ВЫКЛ (дефолт) → doh_apply_dns даёт 1, прежний прямой путь байт-в-байт. Шим — без lib.
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
command -v doh_apply_dns >/dev/null 2>&1 || doh_apply_dns() { return 1; }
# Наш upstream dnsmasq пишет ОДИН владелец (doh-lib.sh, разбор там). Нет библиотеки — прежняя пара «записать + рестарт».
command -v dns_upstream_put >/dev/null 2>&1 || dns_upstream_put() { mkdir -p /etc/dnsmasq.d; { echo no-resolv; for _dus in "$@"; do echo "server=$_dus"; done; } > /etc/dnsmasq.d/00-upstream.conf; /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }

log() { echo "[byedpi-transport] $*"; }

# Пустой/0-байтовый пидфайл = НЕ жив (busybox `kill -0 ""` врёт «жив»). Зеркало xray/hy2.
proc_alive() { p=$(cat "$1" 2>/dev/null | tr -d ' \r\n'); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
# «Порт слушает» ≠ «слушает НАШ демон»: уходящий предшественник держит бинд ещё несколько секунд,
# а чужой (осиротевший xray/hysteria после свопа альта) — сколько угодно; проверка по одному
# netstat рапортовала бы успех, хотя наш демон не забиндил и умер, и трафик пошёл бы через ЧУЖОГО
# провайдера socks. Владельца сверяет ОДНА реализация на проект — slot_socks_is_ours
# (slot-tun-lib.sh: параметризована портом+пидфайлом, «держатель не определился» = наш, рабочий
# путь из-за отсутствия netstat -p не роняем). Тут — просто её применение к БОЕВОМУ порту.
socks_ours() { slot_socks_is_ours "$SOCKS_PORT" "$CIADPI_PID"; }

# Ядро BE7000 собрано БЕЗ CONFIG_TCP_MD5SIG (проверено на железе 2026-06-18) → setsockopt(TCP_MD5SIG)
# падает, и при паре `-f … -S` ciadpi ОБРЫВАЕТ отправку фейка (send_fake → -1) = десинк ломается.
# Поэтому выкусываем неподдерживаемый флаг md5sig (-S/--md5sig) из ЛЮБЫХ аргументов: `-S` без `-f`
# и так инертен, а фейк гасится по TTL (`-t`). Токен-wise (busybox grep -vx), чтобы не задеть `-s`
# (split — другой регистр) и прочие флаги.
strip_unsupported() {
    printf '%s' "$1" | tr ' ' '\n' | grep -vxE '\-S|--md5sig' | tr '\n' ' ' \
        | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
}

# Десинк-аргументы: из .byedpi-args (непустой) либо дефолт. Файл — одна строка флагов ciadpi.
# Разбор ОДНОГО файла стратегии: комментарии долой, всё в одну строку, снять неподдерживаемые
# флаги. Нет файла/пусто/остались одни комментарии → пустая строка; решение о фолбэке принимает
# вызывающий (у основной несущей и у доп-выхода цепочки фолбэка РАЗНЫЕ, см. slot_desync_args).
args_from_file() {   # $1 = путь
    [ -s "$1" ] || return 0
    _af=$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    strip_unsupported "$_af"
}
desync_args() {
    _da=$(args_from_file "$ARGS_FILE"); [ -n "$_da" ] && { echo "$_da"; return; }
    strip_unsupported "$DEFAULT_ARGS"
}

# ---- анти-петля: egress ciadpi (uid nobody) мимо маркировки -----------------
# Ставим RETURN ПЕРЕД mark-core'овскими MARK-правилами (-I OUTPUT 1). Идемпотентно.
owner_rule_add() {
    iptables -t mangle -C OUTPUT -m owner --uid-owner "$BYEDPI_UID" -j RETURN 2>/dev/null || \
        iptables -t mangle -I OUTPUT 1 -m owner --uid-owner "$BYEDPI_UID" -j RETURN
}
owner_rule_del() {
    while iptables -t mangle -C OUTPUT -m owner --uid-owner "$BYEDPI_UID" -j RETURN 2>/dev/null; do
        iptables -t mangle -D OUTPUT -m owner --uid-owner "$BYEDPI_UID" -j RETURN 2>/dev/null || break
    done
}

# ---- DNS (прямой, без тоннеля) ----------------------------------------------
# DNS-резолверы ДОЛЖНЫ идти МИМО маркировки: их IP (1.1.1.1=Cloudflare и т.п.) часто лежат в
# iplist_set → иначе апстрим-запросы dnsmasq метятся → table 1000 → xtun → ciadpi, где `-a1`
# (udp-fake) ещё и ДЕСИНКАЛ БЫ DNS-пакеты → резолв рвётся («not resolved» в логе). Ставим RETURN
# ПЕРВЫМ в OUTPUT (запросы dnsmasq — локальные) и PREROUTING (на всякий — форвард-DNS). Идемпотентно.
# (Прежний вариант `-D OUTPUT -d $d -j MARK` удалял несуществующее правило — маркировка идёт через
# match-set iplist_set, а не -d, — то есть фактически НЕ исключал DNS. Это и был корень «not resolved».)
dns_direct_rules() {   # $1 = add|del
    for d in "$DNS1" "$DNS2"; do
        for ch in OUTPUT PREROUTING; do
            if [ "$1" = del ]; then
                while iptables -t mangle -C "$ch" -d "$d" -j RETURN 2>/dev/null; do
                    iptables -t mangle -D "$ch" -d "$d" -j RETURN 2>/dev/null || break
                done
            else
                iptables -t mangle -C "$ch" -d "$d" -j RETURN 2>/dev/null || \
                    iptables -t mangle -I "$ch" 1 -d "$d" -j RETURN
            fi
        done
    done
}
set_dnsmasq_direct() {
    dns_upstream_put "$DNS1" "$DNS2"
}
set_direct_dns() {
    doh_apply_dns direct && return 0    # DoH ВКЛ/авто → резолв через локальный прокси (резолвер :443 мимо марки); иначе → ниже
    dns_direct_rules add
    set_dnsmasq_direct
}

# ---- демоны -----------------------------------------------------------------
# Освободить socks-порт, если его держит ЧУЖОЙ процесс (xray/hysteria/прошлый ciadpi).
# Зеркало free_foreign_socks из xray/hy2 — провайдер socks РОВНО один.
free_foreign_socks() {
    own=$(cat "$CIADPI_PID" 2>/dev/null | tr -d ' \r\n')
    holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$SOCKS_PORT " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$holder" in ''|*[!0-9]*) return 0 ;; esac
    [ "$holder" = "$own" ] && return 0
    log "socks $SOCKS_PORT держит чужой pid $holder — освобождаю (своп транспорта/рестарт)"
    kill "$holder" 2>/dev/null
    i=0; while [ $i -lt 5 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || break; sleep 1; i=$((i+1)); done
}
# Запуск ciadpi под nobody с захватом вывода. Обёртка sh -c 'exec … >>log 2>&1' переоткрывает
# stdio ПОСЛЕ демонизации (-b уводит в /dev/null) → виден лог при сбое. -c nobody = egress под
# uid 65534 (его ловит owner-RETURN). -x /bin/sh безопасен: дедуп на proc_alive (по пидфайлу).
spawn_byedpi() {
    : > "$CIADPI_LOG" 2>/dev/null || true
    chmod 666 "$CIADPI_LOG" 2>/dev/null || true   # nobody должен дописывать
    args=$(desync_args)
    start-stop-daemon -S -b -c nobody -m -p "$CIADPI_PID" -x /bin/sh -- -c "exec '$CIADPI' -i $SOCKS_ADDR -p $SOCKS_PORT $args >>'$CIADPI_LOG' 2>&1"
}
# --- СЛУЖЕБНЫЙ socks (аварийный канал апдейтера) ---------------------------------------------
# ЗАЧЕМ. После реформы «ставим только панель» ВСЕ протоколы роутер добирает сам, с GitHub — и
# упирается ровно в то, ради чего его и ставят: raw.githubusercontent у части провайдеров душится
# по SNI. Обойти это умеет ciadpi, который лежит рядом с панелью с первой минуты (0.13 МБ) — но
# только как ТРАНСПОРТ, а транспорт в этот момент не выбран. Отсюда отдельный вход: поднять ciadpi
# РОВНО как socks-прокси, без hev, без tun, без правил и без записи `.transport` — то есть ничего
# не меняя в маршрутизации. Знание «как правильно запустить ciadpi» (uid nobody, вырезанные
# `-S`/md5sig, лестница стратегий) остаётся ЗДЕСЬ, в плагине; апдейтер спрашивает адрес и всё.
#
# Порт СВОЙ (не 10808): основной socks может в этот момент нести живой byedpi/xray/hy2, и занять
# его чужим инстансом значило бы уронить несущую ради закачки. Пидфайл тоже свой — `socks-down`
# обязан гасить ТОЛЬКО наш временный демон (инвариант проекта «гасим свой pid, не killall»).
TMP_SOCKS_PORT=10809
TMP_SOCKS_PID=/tmp/enodia-byedpi-fetch.pid
TMP_SOCKS_LOG=/tmp/enodia-byedpi-fetch.log
# РЕФ-СЧЁТ. Служебный socks — РАЗДЕЛЯЕМЫЙ ресурс: `gh-update.sh` живёт в НЕСКОЛЬКИХ процессах
# одновременно (панельные «Обновить скрипты» и установка компонента общего лока не имеют), и
# второй из них штатно ПЕРЕИСПОЛЬЗУЕТ уже поднятый демон вместо своего. Без счёта тот, кто
# закончил первым, гасил бы прокси посреди чужой многомегабайтной закачки (xray — 8 МБ). Идиома
# в проекте уже есть — ref-count у hev и `zt_any_src_wired`. Метка = pid вызывающего: смерть
# владельца (kill -9 мимо ловушки) видна по /proc, иначе его метка держала бы демона до ребута.
TMP_SOCKS_REF=/tmp/enodia-byedpi-fetch.users
_ref_add() {   # $1 = метка (pid вызывающего)
    mkdir -p "$TMP_SOCKS_REF" 2>/dev/null || return 0
    : > "$TMP_SOCKS_REF/${1:-anon}" 2>/dev/null || true
    return 0
}
_ref_others_alive() {   # $1 = снимаемая метка; 0 = демон нужен ещё кому-то
    rm -f "$TMP_SOCKS_REF/${1:-anon}" 2>/dev/null
    [ -d "$TMP_SOCKS_REF" ] || return 1
    _rl=1
    for _rf in "$TMP_SOCKS_REF"/*; do
        [ -e "$_rf" ] || continue
        _rt=${_rf##*/}
        case "$_rt" in
            # Метка не-pid («anon») приходит от СТАРОЙ копии апдейтера: аргумента она не передаёт,
            # значит и жива ли она — не спросить. Считать такую метку живой НЕЛЬЗЯ: она бессмертна,
            # и первый же прогон старого gh-update оставлял бы демона на 10809 до ребута, причём
            # снять его уже некому (поймано на железе AX3600 15.08.2026 — регрессия ref-счёта).
            # Untrackable = не считаем и удаляем: для старого вызывателя это его прежнее поведение.
            ''|*[!0-9]*) rm -f "$_rf" 2>/dev/null ;;
            *) if [ -d "/proc/$_rt" ]; then _rl=0; else rm -f "$_rf" 2>/dev/null; fi ;;
        esac
    done
    return "$_rl"
}
# 0 = socks есть, его адрес НАПЕЧАТАН (127.0.0.1:порт). Уже поднятая ОСНОВНАЯ несущая byedpi
# годится как есть — второй демон в этом случае лишний расход памяти на 176-МБ моделях.
cmd_socks_up() {   # $1 = метка вызывающего (pid) для ref-счёта
    if proc_alive "$CIADPI_PID" && socks_ours; then
        _ref_add "$1"
        echo "$SOCKS_ADDR:$SOCKS_PORT"; return 0
    fi
    [ -x "$CIADPI" ] || { log "нет бинаря ciadpi — служебный socks не поднять"; return 1; }
    if ! proc_alive "$TMP_SOCKS_PID"; then
        : > "$TMP_SOCKS_LOG" 2>/dev/null || true
        chmod 666 "$TMP_SOCKS_LOG" 2>/dev/null || true
        start-stop-daemon -S -b -c nobody -m -p "$TMP_SOCKS_PID" -x /bin/sh -- \
            -c "exec '$CIADPI' -i $SOCKS_ADDR -p $TMP_SOCKS_PORT $(desync_args) >>'$TMP_SOCKS_LOG' 2>&1"
    fi
    # «Порт слушает» ≠ «слушает НАШ» — инвариант проекта, тот же, что в start_daemons.
    if daemon_wait_port "$TMP_SOCKS_PID" byedpi 8 "$SOCKS_ADDR" "$TMP_SOCKS_PORT" \
       && slot_socks_is_ours "$TMP_SOCKS_PORT" "$TMP_SOCKS_PID"; then
        _ref_add "$1"
        echo "$SOCKS_ADDR:$TMP_SOCKS_PORT"; return 0
    fi
    log "служебный ciadpi не забиндил $TMP_SOCKS_PORT (${DAEMON_WAIT_WHY:-порт держит ЧУЖОЙ демон}). Лог:"; tail -n 10 "$TMP_SOCKS_LOG" 2>/dev/null
    cmd_socks_down "$1"
    return 1
}
# Гасим ТОЛЬКО временный демон и ТОЛЬКО когда он больше никому не нужен. Основную несущую (10808)
# не трогаем никогда — она могла быть поднята задолго до нас и к закачке отношения не имеет.
cmd_socks_down() {   # $1 = метка вызывающего
    _ref_others_alive "$1" && return 0        # прокси занят другой закачкой — не наше дело
    # Владельца сверяем ДО сигнала: pid из файла мог быть переиспользован ядром после смерти
    # ciadpi, и голый `kill` тогда бьёт по постороннему процессу (инвариант проекта «гасим свой
    # pid, а не что попало»). Держателя порта спрашивает та же единственная реализация, что и
    # везде; «не определился» = считаем нашим, рабочий путь на этом не рушим.
    if proc_alive "$TMP_SOCKS_PID" && slot_socks_is_ours "$TMP_SOCKS_PORT" "$TMP_SOCKS_PID"; then
        start-stop-daemon -K -p "$TMP_SOCKS_PID" >/dev/null 2>&1 || true
    fi
    rm -f "$TMP_SOCKS_PID"
    rmdir "$TMP_SOCKS_REF" 2>/dev/null || true
    return 0
}

start_daemons() {
    [ -x "$CIADPI" ] || { log "НЕТ бинаря $CIADPI — поставьте его в панели: «Компоненты»"; return 1; }
    [ -x "$HEV" ]    || { log "НЕТ бинаря $HEV"; return 1; }
    [ -s "$HEV_YAML" ] || { log "НЕТ $HEV_YAML"; return 1; }

    free_foreign_socks
    if ! proc_alive "$CIADPI_PID"; then
        log "запускаю ciadpi (десинк: $(desync_args))…"
        spawn_byedpi
    fi
    if ! daemon_wait_port "$CIADPI_PID" byedpi 8 "$SOCKS_ADDR" "$SOCKS_PORT"; then
        log "ciadpi не слушает $SOCKS_PORT: $DAEMON_WAIT_WHY. Лог:"; tail -n 15 "$CIADPI_LOG" 2>/dev/null
        return 1
    fi
    socks_ours || { log "socks $SOCKS_PORT держит ЧУЖОЙ демон — наш ciadpi не забиндил (не поднимаю несущую поверх чужого socks)"; return 1; }
    if ! proc_alive "$HEV_PID"; then
        log "запускаю hev (tun2socks)…"
        start-stop-daemon -S -b -m -p "$HEV_PID" -x "$HEV" -- "$HEV_YAML"
    fi
    daemon_wait_dev "$HEV_PID" hev 6 "$TUN" || {
        log "tun $TUN не создан: $DAEMON_WAIT_WHY. Лог hev:"; tail -n 15 "$HEV_LOG" 2>/dev/null; return 1; }
    return 0
}
stop_daemons() {
    start-stop-daemon -K -p "$HEV_PID"    2>/dev/null
    start-stop-daemon -K -p "$CIADPI_PID" 2>/dev/null
    ip link del "$TUN" 2>/dev/null
    # Пидфайлы убираем СРАЗУ (как slot_stop_daemons/slot_hev_down): busybox start-stop-daemon -K
    # их не чистит, а по stale-пидфайлу `proc_alive` рано или поздно попадёт в ПЕРЕИСПОЛЬЗОВАННЫЙ
    # системой pid и решит «демон жив» — start_daemons тогда его не поднимет, а несущей нет.
    rm -f "$HEV_PID" "$CIADPI_PID" 2>/dev/null
}

# Перезапустить ТОЛЬКО ciadpi с текущими args (hev/xtun не трогаем — тот же socks-порт).
# Для применения новых .byedpi-args из панели без обрыва xtun.
# ГОНКА (поймана на слоте, dev43; здесь тот же класс): ciadpi умирает на SIGTERM не мгновенно и
# порт отпускает ещё позже. Спавнить, пока предшественник держит бинд, — значит получить молча
# вышедший новый демон и ЛОЖНЫЙ успех проверки (netstat видит старого). Ждём смерти процесса,
# добиваем держателя порта (free_foreign_socks: своего пидфайла уже нет ⇒ держатель «чужой»),
# и только потом поднимаем; успехом считаем «порт слушает И это НАШ pid».
restart_byedpi() {
    start-stop-daemon -K -p "$CIADPI_PID" 2>/dev/null
    i=0; while [ $i -lt 6 ] && proc_alive "$CIADPI_PID"; do sleep 1; i=$((i+1)); done
    rm -f "$CIADPI_PID" 2>/dev/null
    free_foreign_socks
    spawn_byedpi
    daemon_wait_port "$CIADPI_PID" byedpi 8 "$SOCKS_ADDR" "$SOCKS_PORT" || { log "restart_byedpi: $DAEMON_WAIT_WHY"; return 1; }
    socks_ours          # успех = порт слушает И держит НАШ pid (иначе ложно-положительный, см. выше)
}

# ПЕРЕПОДНЯТЬ несущую byedpi НА МЕСТЕ (само-излечение). ciadpi известно самовыключается на
# `accept: Invalid argument` после серии соединений (хрупкость ByeDPI, не наш баг, проверено
# на железе 2026-06-18: socks 10808 умолкает → health падал → watchdog уводил byedpi на awg).
# Это ЛОКАЛЬНЫЙ процесс: правильная реакция — перезапустить его, а НЕ убегать на VPS/awg.
# Идемпотентно: поднимает только умершее (ciadpi и/или hev) и переутверждает owner/routing.
# 0 = несущая снова жива, 1 = переподнять не удалось (тогда оркестратор эскалирует cross/прямой).
reup_carrier() {
    free_foreign_socks
    if ! proc_alive "$CIADPI_PID"; then
        log "reup: ciadpi мёртв (accept-EINVAL?) — перезапускаю на месте"
        spawn_byedpi
    fi
    daemon_wait_port "$CIADPI_PID" byedpi 8 "$SOCKS_ADDR" "$SOCKS_PORT" || { log "reup: socks $SOCKS_PORT не поднялся — $DAEMON_WAIT_WHY"; return 1; }
    socks_ours || { log "reup: socks $SOCKS_PORT держит чужой демон — несущую не считаю поднятой"; return 1; }
    if ! proc_alive "$HEV_PID"; then
        log "reup: hev мёртв — перезапускаю"
        start-stop-daemon -S -b -m -p "$HEV_PID" -x "$HEV" -- "$HEV_YAML"
        daemon_wait_dev "$HEV_PID" hev 6 "$TUN" || log "reup: $DAEMON_WAIT_WHY"
    fi
    ip link show "$TUN" >/dev/null 2>&1 || { log "reup: нет $TUN"; return 1; }
    owner_rule_add          # анти-петля могла слететь? переутверждаем (идемпотентно)
    apply_byedpi_routing
    ct_flush   # сбросить залипшие маршруты (грабля NSS/conntrack)
    return 0
}

# ---- маршрутизация (xtun-слой поверх общих правил) --------------------------
apply_byedpi_routing() {
    ip link set "$TUN" up 2>/dev/null
    ipt_top FORWARD -o "$TUN" -j ACCEPT
    ipt_top FORWARD -i "$TUN" -j ACCEPT
    ip route replace default dev "$TUN" table "$TABLE"
}

# ============================================================
cmd_up() {
    [ -f "$SWEEP_BAK" ] && sweep_restore   # подчистить брошенный браузер-свип (вернуть исходную стратегию)
    owner_rule_add          # анти-петля ДО подъёма (egress ciadpi мимо маркировки)
    if ! start_daemons; then
        log "запуск не удался — несущая не поднята (оркестратор решит, что дальше)"
        stop_daemons
        bd_any_byedpi_slot || owner_rule_del   # ref-count: анти-петля общая с byedpi-ВЫХОДАМИ (см. cmd_down)
        return 1
    fi
    apply_byedpi_routing
    set_direct_dns
    echo byedpi > "$TRANSPORT_FLAG"
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    carrier_up_mark         # грейс сторожу: демоны стартовали, но egress поднимается ещё секунды (clock-lib.sh)
    # Отметка «путь через hev мёртв» (slot-tun-lib.sh) — про ПРЕЖНЮЮ несущую: она общая на xray/hy2/byedpi, и без снятия до получаса
    # отказывала бы перебору только что поднятого транспорта (ревью с.93, круг 3). Свежий путь судит следующий health тика.
    if command -v hev_dead_clear >/dev/null 2>&1; then hev_dead_clear main; fi
    ct_flush
    log "транспорт = BYEDPI (default table $TABLE -> $TUN, десинк напрямую). Общие правила сохранены."
    cmd_status
}

cmd_down() {
    # ЧИСТЫЙ РЕЛИНКВИШ (симметрично xray/hy2): отпускаем ТОЛЬКО свою несущую (xtun) → fail-open
    # в прямой. НЕ решаем, что поднять следом, и НЕ трогаем .transport — забота ОРКЕСТРАТОРА.
    [ -f "$SWEEP_BAK" ] && sweep_restore   # свип шёл при down → вернуть исходную стратегию, снять lock
    stop_daemons
    iptables -D FORWARD -o "$TUN" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$TUN" -j ACCEPT 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null || true
    # Анти-петлю снимаем ПО REF-COUNT (зеркало cmd_slot_down): owner-RETURN общий у ОСНОВНОГО
    # byedpi и у byedpi-ВЫХОДОВ. Снять её при живом выходе = вернуть egress его ciadpi (uid
    # nobody) под маркировку: трафик выхода уедет в table 1000 — то есть через ОСНОВНОЙ туннель
    # ВМЕСТО десинка напрямую (а при основном byedpi это ещё и петля xtun→ciadpi→xtun).
    # Себя из счёта исключаем не по id, а по смыслу: `.transport` на момент down всё ещё byedpi
    # (флаг переписывает оркестратор ПОСЛЕ), поэтому спрашиваем ТОЛЬКО про выходы.
    bd_any_byedpi_slot || owner_rule_del
    dns_direct_rules del    # снять наши DNS-RETURN (следующий транспорт поставит свой DNS)
    set_dnsmasq_direct      # dnsmasq на прямой резолвер — fail-open до подъёма следующего транспорта
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    ct_flush
    log "ByeDPI-несущая снята (релинквиш) -> прямой режим (fail-open). Следующий транспорт ставит оркестратор."
}

cmd_status() {
    # ФАКТ ФЛАГА, а не догадка: `t=awg` по умолчанию печатало «транспорт: awg» на установке «только
    # панель», где транспорта нет вовсе (и так делали ВСЕ ЧЕТЫРЕ плагина — в дампе выходило четыре
    # подтверждения несуществующего awg). Что значит пустой флаг, знает `transport.sh configured`.
    # Сравнения ниже (`[ "$t" = byedpi ]`) от смены умолчания не меняются: пусто ≠ byedpi.
    t=; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    echo "=== транспорт: ${t:-(флаг пуст — транспорт не выбран)} ==="
    # `; echo` обязателен: заводская ветка desync_args печатает строку через strip_unsupported,
    # а тот перевод строки не ставит (его вывод подставляют в $(...), где хвостовой \n лишний).
    # Без echo следующий заголовок приклеивался к аргументам ОДНОЙ строкой — в дампе это читалось
    # как «--- default в table 1000 ---» внутри стратегии. Тот же класс, что `tr -cd` в граблях.
    echo "--- десинк-аргументы ---"; desync_args; echo
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default   # raw-print: сырой вывод человеку в `status`, вердикта тут нет
    echo "--- демоны ---"
    proc_alive "$CIADPI_PID" && echo "ciadpi: pid $(cat $CIADPI_PID) жив" || echo "ciadpi: не запущен"
    proc_alive "$HEV_PID"    && echo "hev:    pid $(cat $HEV_PID) жив"    || echo "hev:    не запущен"
    echo "--- tun $TUN ---"; ip -o link show "$TUN" 2>/dev/null || echo "нет"
    echo "--- socks $SOCKS_PORT ---"; netstat -ltn 2>/dev/null | grep "$SOCKS_PORT" || echo "не слушает"
    echo "--- owner-RETURN (анти-петля) ---"; iptables -t mangle -S OUTPUT 2>/dev/null | grep "owner" || echo "нет"
    if [ "$t" = byedpi ]; then
        echo "--- egress через ciadpi socks ---"
        probe_ext_ip "--socks5-hostname $SOCKS_ADDR:$SOCKS_PORT" 8; echo
    fi
    echo "--- awg0 (тёплый резерв) ---"; ip link show awg0 >/dev/null 2>&1 && echo "поднят" || echo "нет"
}

# health для watchdog: 0 = здоров ИЛИ транспорт не byedpi; 1 = byedpi нездоров.
# Проба egress к НЕйтральному хосту (ipify): подтверждает, что ciadpi форвардит наружу. «Десинк
# не пробил конкретный сайт» — НЕ событие «транспорт упал» (это per-site), потому health здесь =
# демоны живы + xtun + ciadpi реально что-то отдаёт.
# «ciadpi форвардит наружу?» — ОДИН критерий на socks-пробу несущей, socks-пробу выхода и пробу пути клиентов через TUN (почему по
# IP, любой код ≠ 000 и с `-k` — разбор в cmd_health ниже). $1 — сетевые аргументы curl: `--socks5 адрес:порт` | `--interface <TUN>`.
bd_egress_ok() {
    for _beh in 1.1.1.1 8.8.8.8; do
        _bec=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 $1 "https://$_beh" 2>/dev/null)   # $1 НАМЕРЕННО без кавычек — это аргументы
        case "$_bec" in ''|000) ;; *) return 0 ;; esac
    done
    return 1
}
cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    [ "$t" = byedpi ] || return 0
    # ИДЁТ РУЧНАЯ СМЕНА ТРАНСПОРТА (панель/оркестратор держат lock). Несущая byedpi сейчас
    # снимается ШТАТНО, а `.transport` ещё указывает на нас (флаг переписывают после down) ⇒
    # судить нельзя: reup_carrier поднял бы ciadpi+hev обратно и вернул `default dev xtun` в
    # table 1000 ПОВЕРХ уже поднятой новой несущей — осиротевшие демоны на socks 10808 и чужая
    # таблица маршрутов (класс Б4-5). У xray/hy2 такой гард есть с 2026-07-09, у нас не было.
    [ -e "$SWITCH_LOCK" ] && { log "health: идёт смена транспорта (lock) — не вмешиваюсь"; return 0; }
    # БРАУЗЕР-СВИП идёт → панель сама рулит ciadpi (применяет стратегии вживую). Не вмешиваемся,
    # иначе reup/cross подрались бы с рестартами. Lock протух (браузер закрыли, не завершив свип) →
    # восстанавливаем исходную стратегию и снимаем lock (нет «застрявшей» плохой стратегии).
    if sweep_fresh; then return 0; fi
    if [ -f "$SWEEP_LOCK" ]; then
        log "health: браузер-свип брошен (lock протух) — восстанавливаю исходную стратегию"
        sweep_restore; restart_byedpi >/dev/null 2>&1; ct_flush
    fi
    # САМО-ИЗЛЕЧЕНИЕ (2026-06-18). Раньше любая смерть демона → return 1 → watchdog уводил
    # byedpi на awg (cross). Но ciadpi известно самовыключается на `accept: Invalid argument`
    # — это локальный процесс, его надо ПЕРЕПОДНЯТЬ, а не бросать выбранный пользователем
    # транспорт. Если что-то из несущей просело — переподнимаем НА МЕСТЕ и только при неудаче
    # сообщаем «нездоров» (watchdog тогда уже законно эскалирует cross/прямой).
    if ! proc_alive "$CIADPI_PID" || ! proc_alive "$HEV_PID" || ! ip link show "$TUN" >/dev/null 2>&1; then
        log "health: несущая byedpi просела (ciadpi/hev/tun) — переподнимаю на месте"
        reup_carrier || { log "health: переподнять byedpi не удалось — отдаю эскалацию оркестратору"; return 1; }
    fi
    # Проба egress ПО IP (без резолва!): даём ciadpi готовый IP, не имя → не зависит от DNS.
    # Раньше била --socks5-hostname api.ipify.org → ciadpi не мог зарезолвить (DNS прямой, его
    # сервер не в туннеле) → ложный fail → watchdog уводил byedpi обратно на awg, byedpi «не
    # держался». Бьём по 1.1.1.1/8.8.8.8 (всегда подняты): любой HTTP-код != 000 = ciadpi
    # реально форвардит наружу. Десинк здесь не важен (эти хосты не блокируют).
    # `-k` ОБЯЗАТЕЛЕН: мы спрашиваем «ciadpi форвардит наружу?», а не «подлинный ли это узел» —
    # тело ответа не читаем вовсе, важен лишь код != 000. Без него на старых сборках проба врёт
    # ВСЕГДА: замерено на AX3600 (ядро 4.4, CA-бандл Feb 2023, OpenSSL 1.0.2q) — без `-k` оба
    # хоста дают 000 (rc=60), с `-k` — 301 и 302. Значит byedpi там вечно «нездоров», и сторож
    # уводит его на awg: ровно симптом «byedpi не держится», уже ловленный по другой причине.
    if bd_egress_ok "--socks5 $SOCKS_ADDR:$SOCKS_PORT"; then
        # Сервер жив — а путь КЛИЕНТОВ (TUN → hev → socks)? Мимо hev проба выше не видит залипшего hev (разбор и лечение —
        # slot-tun-lib.sh::hev_path_check). Нет функции (старый слой) — как раньше.
        command -v hev_path_check >/dev/null 2>&1 || return 0
        hev_path_check apply_byedpi_routing; return $?
    fi
    log "health: проба egress по IP не прошла (ciadpi не форвардит наружу)"; return 1
}

# «Failover» для ЛОКАЛЬНОГО десинка ≠ перебор VPS-серверов (их нет). Демон ciadpi мог
# самовыключиться (`accept: Invalid argument`) — правильная реакция watchdog'а НЕ «увести
# byedpi на awg», а ПЕРЕПОДНЯТЬ десинк на месте. Поэтому failover пробует reup_carrier и
# возвращает 0 при успехе → watchdog остаётся на byedpi (а не делает cross на VPS). Только
# если переподнять реально не вышло (бинарь пропал/порт занят навсегда) → 1 → cross/прямой.
# (Перебор десинк-ПРЕСЕТОВ при стойком провале — возможная доработка позже.)
cmd_failover() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    [ "$t" = byedpi ] || { log "byedpi-failover: byedpi не активен → эскалация на оркестраторе"; return 1; }
    # Ручная смена транспорта в процессе (lock) — не переподнимаем то, что сейчас штатно снимают
    # (иначе осиротевшие ciadpi/hev + чужой default в table 1000; см. тот же гард в cmd_health).
    # Отвечаем 0 = «не вмешиваюсь», а не 1: «эскалируй cross» посреди ручного switch — худшее.
    [ -e "$SWITCH_LOCK" ] && { log "byedpi-failover: идёт смена транспорта (lock) — не вмешиваюсь"; return 0; }
    if sweep_fresh; then log "byedpi-failover: идёт браузер-свип — остаёмся на byedpi"; return 0; fi
    # Путь клиентов через hev мёртв, и перезапуск hev не помог: переподъём ниже (тот же перезапуск ciadpi+hev со сбросом соединений)
    # каждые 4 минуты ничего не меняет — отдаём эскалацию сторожу (разбор — xray-transport.sh cmd_failover; ревью с.93, круг 2).
    if command -v hev_path_dead >/dev/null 2>&1 && hev_path_dead main; then
        log "byedpi-failover: путь клиентов через hev мёртв и перезапуск hev не помог → эскалация на оркестраторе (cross/прямой)"; return 1; fi
    log "byedpi-failover: переподнимаю локальный десинк на месте (без ухода на VPS/awg)…"
    if reup_carrier; then
        log "byedpi-failover: ciadpi/hev снова подняты — остаёмся на byedpi"
        return 0
    fi
    log "byedpi-failover: переподнять не удалось → эскалация на оркестраторе (cross/прямой)"
    return 1
}

# reload — перечитать .byedpi-args и перезапустить ТОЛЬКО ciadpi (hev/xtun не трогаем) → без
# обрыва несущей. Зовёт панель/ПК после смены десинк-аргументов. byedpi не активен → no-op (0):
# новые args применятся при следующем up. conntrack -F после рестарта, чтобы новый десинк
# подхватили уже открытые соединения (грабля NSS/conntrack — старый маршрут залипает).
cmd_reload() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    [ "$t" = byedpi ] || { log "reload: byedpi не активен — новые args применятся при следующем up"; return 0; }
    if restart_byedpi; then
        ct_flush
        log "ciadpi перезапущен (десинк: $(desync_args))"
        return 0
    fi
    log "reload: ciadpi не перезапустился. Лог:"; tail -n 15 "$CIADPI_LOG" 2>/dev/null
    return 1
}

# presets — КУРИРОВАННАЯ библиотека готовых стратегий десинка (формат `label|args`, по строке).
# Источник — встроенные стратегии Android-приложения ByeByeDPI (proxytest_strategies.list). Взяты
# только те, что НЕ требуют подстановки домена (без `{sni}`/`{list:}` — у нас ciadpi видит IP, не имя,
# и charset панели их бы отверг) и БЕЗ `-S` (md5sig не поддержан ядром BE7000). Питает выпадашку
# пресетов и тестер стратегий (byedpi-test.sh). Порядок: от простых к сложным.
cmd_presets() {
    cat <<'PRESETS'
Авто (по умолчанию)|
ByeDPI стандарт (oob+tlsrec)|-o1 -a1 -r-5+se
Disorder+split простой|-d1 -s3+s
Split+fake (на тесте брал YouTube)|-s1+s -f2+s -t4
Disorder по SNI (Discord)|-d1+s
OOB+tlsrec лёгкий|-o1 -r-5+se
Disorder+split+tlsrec+fake|-d1 -s1+s -r1+s -f-1 -t8
OOB+disorder авто (лёгкий)|-o1 -a1 -At,r,s -d1 -a1
Лесенка сплитов по SNI|-d1 -s1+s -s3+s -s6+s -s9+s -s12+s -s15+s -s20+s -s30+s -a1
Чередование disorder/split по SNI|-d1 -s1+s -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -a1
Мульти-сплит+tlsrec (YouTube, тест-пресет №2)|-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -a1 -As -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -a1
OOB+disorder авто-эскалация|-o1 -d1 -a1 -At,r,s -s1 -d1 -s5+s -s10+s -s15+s -s20+s -r1+s -a1 -As -s1 -d1 -s5+s -s10+s -s15+s -s20+s -a1
Disorder+fake многоступенчатый|-d1+s -s50+s -a1 -As -f20 -r2+s -a1 -At -d2 -s1+s -s5+s -s10+s -s15+s -s25+s -s35+s -s50+s -s60+s -a1
tlsrec+сплит авто|-r5+s -s25+s -a1 -At,r,s -s50 -r5+s -s50+s -a1
OOB+fake авто по триггерам|-o1 -a1 -At,r,s -f-1 -a1 -Ar,s -o1 -a1 -At -r1+s -f-1 -t6 -a1
Сплит+tlsrec+mod-http (агрессивный)|-q2 -s2 -s3+s -r3 -s4 -r4 -s5+s -r5+s -s6 -s7+s -r8 -s9+s -Qr -Mh,d,r -a1 -At,r -s2+s -r2 -d2 -s3 -r3 -r4 -s4 -d5+s -r5 -d6 -s7+s -d7 -a1
Disorder+oob+fake авто|-d1 -o1 -a1 -Ar -o1 -a1 -At -f-1 -r1+s -a1
disoob+oob+tlsrec|-r8 -o2 -s7 -q4+s -a1
OOB+split+tlsrec короткий|-o1+s -d3+s -a1
Disorder@7 + split@2|-d7 -s2 -a1
OOB@3 + disorder@7|-o3 -d7 -a1
tlsrec глубокий (r25)|-q1 -r25+s -a1
OOB + двойной split|-o1 -s4 -s6 -a1
Двойной split + mod|-s5+s -s35+s -m4 -a1
Disorder + fake-http + OOB|-d6+s -q4+hm -o2 -a1
Disorder+OOB+split+tlsrec|-d1+s -o2 -s5 -r5 -a1
Split+disorder, авто-tlsrec|-s1 -d3+s -a1 -At -r1+s -a1
Лесенка disorder→split|-d1 -d3+s -s6+s -d9+s -s20+s -d25+s -s30+s -a1
Чередование (плотное)|-d1 -s4 -d8 -s1+s -d5+s -s10+s -d20+s -a1
Полный набор (disorder+split+tlsrec+oob+fake)|-d1 -s1+s -r1+s -e1 -m1 -o1+s -f-1 -t2 -a1
Плотные сплиты + TTL12 авто|-d1 -d3+s -s6+s -d6+s -s7+s -d8+s -s10+s -a1 -t12 -At,s -r3
PRESETS
}

# ============================================================
# БРАУЗЕР-СВИП (управляется панелью ИЗ БРАУЗЕРА — реальный путь hev+QUIC). Тестер byedpi-test.sh
# меряет curl'ом ПРЯМО в socks (минуя hev): split+fake «выигрывает» на ЦЕЛОМ ClientHello, но дома
# через hev (ClientHello приходит кусками) и по QUIC картина другая → результат может ИНВЕРТИРОВАТЬ
# реальность. Браузер-свип честнее: панель применяет КАЖДУЮ стратегию ВЖИВУЮ к боевому ciadpi, а
# реальный браузер пользователя грузит ассеты заблок-сайтов через активный ByeDPI (тот же путь, что
# у сайтов). Здесь — только router-сторона: применить стратегию + восстановить исходную.
#
# СТРАХОВКА. Пока идёт свип, watchdog/health НЕ должны вмешиваться (рестарты ciadpi приняли бы за
# падение и увели на awg). Признак — СВЕЖИЙ $SWEEP_LOCK (timestamp; браузер рефрешит на каждом apply).
# Lock протух (браузер закрыли, не завершив свип) → cmd_health сам ВОССТАНОВИТ исходную стратегию из
# $SWEEP_BAK и снимет lock (нет «застрявшей» плохой стратегии = само-восстановление).
sweep_fresh() {   # 0 = идёт свежий свип → не вмешиваться
    [ -f "$SWEEP_LOCK" ] || return 1
    ts=$(cat "$SWEEP_LOCK" 2>/dev/null | tr -d ' \r\n'); case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    [ "$(age_since "$ts")" -lt "$SWEEP_TTL" ]
}
sweep_touch() { date +%s > "$SWEEP_LOCK"; }
# ЦЕЛЬ свипа: основная несущая (пусто) либо ДОП-ВЫХОД №id — у него своя стратегия
# (.byedpi-args-s<id>) и свой ciadpi, значит и бэкап отдельный. Лок ОДИН на обе цели
# намеренно: он говорит watchdog «byedpi сейчас дёргают, это не падение», а дёргаем мы
# в любом случае ciadpi (пусть и чужой инстанс) — два лока лишь усложнили бы гарды.
# Ставит $SW_ARGS/$SW_BAK; 1 = битая цель.
sweep_target() {
    case "${1:-}" in
        '')      SW_ARGS="$ARGS_FILE"; SW_BAK="$SWEEP_BAK"; SW_SLOT="" ;;
        2|3|4)   SW_ARGS="$ENODIA_STATE/.byedpi-args-s$1"; SW_BAK="$ENODIA_STATE/.byedpi-args-s$1.sweepbak"; SW_SLOT="$1" ;;
        *)       return 1 ;;
    esac
    return 0
}
# Цель свипа готова нести пробы? Основная — byedpi должен быть АКТИВНЫМ транспортом; выход —
# он должен быть ВКЛЮЧЁН (несущая выхода живёт независимо от того, что стоит основным).
sweep_target_live() {
    if [ -z "$SW_SLOT" ]; then
        t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
        [ "$t" = byedpi ] && return 0
        return 1
    fi
    sh "$ENODIA_DIR/slots.sh" list-enabled 2>/dev/null | grep -q "^$SW_SLOT	byedpi	"
}
# Перезапустить ciadpi ЦЕЛИ: у выхода — только его демон (slot-reload; маршрут не мигает).
sweep_restart() {
    if [ -z "$SW_SLOT" ]; then restart_byedpi; return $?; fi
    cmd_slot_reload "$SW_SLOT" >/dev/null 2>&1
}
# Восстановить исходную стратегию из бэкапа + снять флаги свипа (конец свипа / брошенный свип).
# Пустой бэкап = исходная стратегия была АВТО (файла аргументов не было) → удаляем файл.
sweep_restore() {
    _ba="${SW_BAK:-$SWEEP_BAK}"; _aa="${SW_ARGS:-$ARGS_FILE}"
    if [ -f "$_ba" ]; then
        if [ -s "$_ba" ]; then mv "$_ba" "$_aa" 2>/dev/null
        else rm -f "$_aa" 2>/dev/null; fi
    fi
    rm -f "$SWEEP_LOCK" "$_ba" 2>/dev/null
}
# ЧЕЙ брошенный свип кто чинит (чтобы не заводить второй механизм): ОСНОВНУЮ несущую — cmd_health
# ниже (sweep_restore + restart_byedpi), ВЫХОДЫ — watchdog.sh::slot_health_sweep вербом
# `sweep-end <id>` (он один ходит по реестру включённых выходов и умеет перезапустить ciadpi
# именно того выхода; функция «подчистить все формы бэкапа разом» здесь была, но её никто не
# звал — восстановление БЕЗ перезапуска демона всё равно оставило бы выход на тестовой стратегии).
cmd_sweep_begin() {
    sweep_target "$1" || { log "sweep-begin: битая цель '$1'"; return 1; }
    sweep_target_live || { log "sweep-begin: цель не несёт трафик — свип возможен только на боевой несущей/включённом выходе"; return 1; }
    if [ ! -f "$SW_BAK" ]; then
        if [ -f "$SW_ARGS" ]; then cp "$SW_ARGS" "$SW_BAK" 2>/dev/null; else : > "$SW_BAK"; fi
    fi
    sweep_touch
    log "sweep-begin: браузер-свип начат (исходная стратегия сохранена в $SW_BAK)"
    return 0
}
# применить ОДНУ стратегию к боевому ciadpi ЦЕЛИ. $1 = args (санитизированы в CGI), $2 = id выхода
# (пусто = основная). 0 = socks снова слушает (можно пробовать в браузере), 1 = не поднялся.
cmd_sweep_apply() {
    sweep_target "$2" || { log "sweep-apply: битая цель '$2'"; return 1; }
    sweep_target_live || { log "sweep-apply: цель не несёт трафик"; return 1; }
    [ -f "$SW_BAK" ] || { log "sweep-apply: свип не начат (нет бэкапа) — отказ"; return 1; }
    sweep_touch
    a=$(printf '%s' "$1" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g')
    if [ -n "$a" ]; then printf '%s\n' "$a" > "$SW_ARGS.new" && mv "$SW_ARGS.new" "$SW_ARGS"; else rm -f "$SW_ARGS"; fi
    if sweep_restart; then
        ct_flush
        sweep_touch          # рестарт занял время — обновляем lock, чтобы не протух среди пробы
        log "sweep-apply: применена стратегия${SW_SLOT:+ выхода №$SW_SLOT} ($a)"
        return 0
    fi
    sweep_touch
    log "sweep-apply: ciadpi не поднялся на этой стратегии (провал)"
    return 1
}
# Стратегию возвращаем ВСЕГДА, а перезапуск ciadpi — это ПОДЪЁМ (restart_byedpi поднимает и мёртвый демон), значит под carrier_run:
# свип, прерванный «Отключить VPN», панель всё равно завершает (`byedpi_sweep_end`), и прежде этот верб поднимал ciadpi на socks
# 10808 при выключенном VPN — до ребута, а `transport.sh live` его не видит (ревью ветки, круг 3). Снятие — sweep_undo (id вторым).
sweep_end_restart() {
    if [ -n "$SW_SLOT" ]; then
        sweep_restart >/dev/null 2>&1; ct_flush
    else
        t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
        if [ "$t" = byedpi ]; then restart_byedpi >/dev/null 2>&1; ct_flush; fi
    fi
    return 0
}
cmd_sweep_end() {
    sweep_target "$1" || sweep_target ''
    sweep_restore
    carrier_run sweep_undo sweep_end_restart '' "$SW_SLOT"
    log "sweep-end: исходная стратегия восстановлена, свип завершён"
    return 0
}

# ============================================================
# byedpi-СЛОТ (доп-выход мульти-транспорта, Ф1c) ------------------------------------------
# Дизайн: заметки разработки «мультитранспорт-дизайн». «Выход» byedpi-слота = ЛОКАЛЬНЫЙ десинк РЯДОМ
# с основным VPN (не «весь дом», как основной byedpi-транспорт). Отличия от основного byedpi и
# от awg-СЛОТА (Ф2, transport-awg.sh):
#   * СВОЙ socks-порт (10830+id), СВОЙ tun (xtunN), СВОЯ table 100N, свои pid/log/yaml — чтобы
#     N слотов + возможный основной byedpi сосуществовали. Инвариант «один socks на систему»
#     ОСЛАБЛЕН до «один socks на слот»: free_foreign_socks параметризован портом (slot_free_socks).
#   * endpoint'а НЕТ (ciadpi коннектится к самим сайтам) ⇒ анти-петля НЕ через endpoint-bypass
#     (как у awg-слота), а через ОБЩИЙ owner-RETURN (egress uid nobody мимо маркировки — тот же
#     механизм основного byedpi). owner-RETURN РЕФ-СЧИТАЕМ: держим, пока нужен ОСНОВНОМУ byedpi
#     ИЛИ любому byedpi-слоту (зеркало ref-count nfqws в zapret.sh); снимаем, когда не нужен никому.
#   * БЕЗ DNS (один dnsmasq через основной слот, дизайн §DNS) и БЕЗ MASQUERADE (tun2socks
#     терминирует). Марку 0xN + `ip rule fwmark→table 100N` ставит mark-core: byedpi-слот —
#     ОБЫЧНЫЙ карриер (в отличие от zapret-слота, mark-core его НЕ пропускает).
# Резолв доменов слота идёт через ОСНОВНОЙ транспорт (честный dnsmasq) ⇒ ciadpi получает верные
# IP даже при awg-main — надёжнее, чем byedpi «весь дом» с прямым (потенциально подменяемым) DNS.
SLOTS_SH="$ENODIA_DIR/slots.sh"
# Общий per-slot слой tun2socks (порт/tun/table/hev-yaml/подъём hev/карриер-маршруты) — ОДНА
# копия на byedpi/xray/hy2 (slot-tun-lib.sh). Тут остаётся только ciadpi-специфика.
# Под `[ -f ]`: провалившийся `.` убил бы весь плагин (вместе с ОСНОВНОЙ несущей) из-за отсутствия
# слотового слоя. Нет файла ⇒ деградация по контракту: слот-вербы отвечают «не умею» (код 2).
if [ -f "$ENODIA_DIR/slot-tun-lib.sh" ]; then . "$ENODIA_DIR/slot-tun-lib.sh"; else SLOT_LIB_MISSING=1; fi
slot_lib_ok() { [ -z "$SLOT_LIB_MISSING" ] && return 0
    echo "[byedpi] слот-слой недоступен: нет $ENODIA_DIR/slot-tun-lib.sh — обновите скрипты" >&2; return 1; }
# Сверка «порт держит НАШ pid» нужна и ОСНОВНОМУ пути (socks_ours в шапке), а единственная
# реализация живёт в слот-слое. Нет библиотеки (старая установка) → шим «считаем наш»:
# диагностики нет, зато прежнее поведение основной несущей сохраняется байт-в-байт.
command -v slot_socks_is_ours >/dev/null 2>&1 || slot_socks_is_ours() { return 0; }
# Проба пути клиентов через TUN (slot-tun-lib.sh::hev_stuck) — ТЕМ ЖЕ критерием, что socks-проба: строже (Cloudflare trace) — и
# «залипание» рождалось бы из ничего на сети, где 1.1.1.1 через ciadpi не проходит, а 8.8.8.8 проходит (ревью с.93).
hev_tun_ok() { bd_egress_ok "--interface $1"; }
slot_ciadpi_pid() { echo "/tmp/enodia-byedpi-s$1.pid"; }
slot_ciadpi_log() { echo "/tmp/enodia-byedpi-s$1.log"; }
slot_args_file()  { echo "$ENODIA_STATE/.byedpi-args-s$1"; }   # per-slot стратегия (нет → общий DEFAULT_ARGS)

# Десинк-аргументы слота — ТРИ ступени: своя (.byedpi-args-s<id>) → ОБЩАЯ (.byedpi-args) →
# заводская. Средняя ступень принципиальна: общую человек подбирал под СВОЕГО провайдера (тем же
# свипом), и выход без собственной стратегии обязан наследовать её, а не падать в заводскую —
# иначе «у основного десинк работает, а у выхода нет» на ровном месте (дефект найден 27.07).
slot_desync_args() {   # $1 = id
    _sa=$(args_from_file "$(slot_args_file "$1")"); [ -n "$_sa" ] && { echo "$_sa"; return; }
    _sa=$(args_from_file "$ARGS_FILE");             [ -n "$_sa" ] && { echo "$_sa"; return; }
    strip_unsupported "$DEFAULT_ARGS"
}

# --- owner-RETURN ref-count: держим анти-петлю, пока её ждёт хоть один byedpi-потребитель ------
bd_transport_active() { [ "$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')" = byedpi ]; }
# Есть ли ВКЛЮЧЁННЫЙ byedpi-слот (опц. исключая один id). На момент slot-down реестр slots.sh ещё
# держит слот on (slots.sh пишет off ПОСЛЕ slot-down) ⇒ гасимый исключаем по id (как zt_any_slot).
# Зовём ЧЕРЕЗ `sh` и проверяем `-f`, а не `-x`: снятый бит выполнения (дрейф деплоя, распаковка
# без прав) — не повод ответить «byedpi-выходов нет». Цена ошибки несимметрична: ложное «нет»
# снимает общий owner-RETURN при живом выходе (его ciadpi снова метится в туннель).
bd_any_byedpi_slot() {   # $1 = exclude id (опц.)
    [ -f "$SLOTS_SH" ] || return 1
    sh "$SLOTS_SH" list-enabled 2>/dev/null | while IFS="$(printf '\t')" read -r _sid _st _rest; do
        [ "$_st" = byedpi ] || continue
        { [ -n "$1" ] && [ "$_sid" = "$1" ]; } && continue
        echo hit
    done | grep -q hit
}
owner_rule_needed() {   # $1 = exclude slot id (опц.); код 0 = ещё нужна (НЕ снимать)
    bd_transport_active && return 0
    bd_any_byedpi_slot "$1" && return 0
    return 1
}

# Запуск ciadpi слота под nobody (egress ловит ОБЩИЙ owner-RETURN). Свой порт/pid/log. Зеркало spawn_byedpi.
slot_spawn_ciadpi() {   # $1 = id
    _id="$1"; _port=$(slot_socks_port "$_id"); _log=$(slot_ciadpi_log "$_id")
    : > "$_log" 2>/dev/null || true
    chmod 666 "$_log" 2>/dev/null || true          # nobody должен дописывать
    _a=$(slot_desync_args "$_id")
    start-stop-daemon -S -b -c nobody -m -p "$(slot_ciadpi_pid "$_id")" -x /bin/sh -- -c "exec '$CIADPI' -i $SOCKS_ADDR -p $_port $_a >>'$_log' 2>&1"
}

slot_start_daemons() {   # $1 = id ; 0 = ciadpi+hev+tun подняты
    [ -x "$CIADPI" ] || { log "слот №$1: НЕТ бинаря ciadpi ($CIADPI) — установите ByeDPI"; return 1; }
    [ -x "$HEV" ]    || { log "слот №$1: НЕТ бинаря hev"; return 1; }   # проверяем ДО старта ciadpi (не плодим лишний демон)
    _id="$1"; _port=$(slot_socks_port "$_id")
    slot_free_socks "$_id" "$(slot_ciadpi_pid "$_id")"
    if ! proc_alive "$(slot_ciadpi_pid "$_id")"; then
        log "слот №$_id: запускаю ciadpi на :$_port (десинк: $(slot_desync_args "$_id"))…"
        slot_spawn_ciadpi "$_id"
    fi
    if ! slot_wait_socks "$_port" "$(slot_ciadpi_pid "$_id")" byedpi; then
        log "слот №$_id: ciadpi не слушает :$_port ($DAEMON_WAIT_WHY). Лог:"; tail -n 15 "$(slot_ciadpi_log "$_id")" 2>/dev/null
        return 1
    fi
    slot_hev_up "$_id"          # hev + ожидание xtunN (общий слой)
}
slot_stop_daemons() {   # $1 = id
    _id="$1"
    slot_hev_down "$_id"        # hev + снятие xtunN + чистка пидфайла (общий слой)
    start-stop-daemon -K -p "$(slot_ciadpi_pid "$_id")" 2>/dev/null
    rm -f "$(slot_ciadpi_pid "$_id")" 2>/dev/null   # не копить stale-пидфайлы (риск переиспользования pid)
}

# Контракт слота (transport.sh _slot_dispatch): slot-up <id> [cfg] / slot-down <id>. У byedpi
# конфига НЕТ (десинк локальный, config='-') — cfg игнорируем. Идемпотентно (reup: watchdog зовёт slot-up).
cmd_slot_up() {   # $1 = id ; $2 = cfg (игнор)
    _id="$1"
    case "$_id" in 2|3|4) ;; *) log "слот: id = 2..4"; return 1 ;; esac
    owner_rule_add          # анти-петля (egress ciadpi мимо маркировки) ДО подъёма; ref-count держит её
    if ! slot_start_daemons "$_id"; then
        log "слот №$_id: несущая byedpi не поднялась -> выход живёт по fallback-политике (mark-core)"
        slot_stop_daemons "$_id"
        owner_rule_needed "$_id" || owner_rule_del
        return 1
    fi
    slot_apply_routing "$_id"
    ct_flush
    log "слот №$_id: byedpi-несущая $(slot_tun "$_id") в table $(slot_table "$_id") (десинк напрямую)"
    return 0
}
cmd_slot_down() {   # $1 = id
    _id="$1"
    case "$_id" in 2|3|4) ;; *) log "слот: id = 2..4"; return 1 ;; esac
    slot_remove_routing "$_id"
    slot_stop_daemons "$_id"
    owner_rule_needed "$_id" || owner_rule_del   # снять анти-петлю, если не нужна ни транспорту, ни др. byedpi-слоту
    rm -f "$(slot_hev_yaml "$_id")" 2>/dev/null
    ct_flush
    log "слот №$_id: byedpi-несущая снята"
    return 0
}

# slot-reload <id> — применить новую per-slot стратегию (.byedpi-args-s<id>) БЕЗ обрыва выхода:
# перезапускаем ТОЛЬКО ciadpi слота, а hev/xtun/table 100<id> остаются на месте (тот же socks-порт)
# ⇒ маршрут не мигает и fallback не срабатывает. Зеркало cmd_reload для основной несущей.
# Слот не поднят → no-op 0: стратегия лежит в файле и применится при slot-up (тот читает её сам).
cmd_slot_reload() {   # $1 = id
    _id="$1"
    case "$_id" in 2|3|4) ;; *) log "слот: id = 2..4"; return 1 ;; esac
    _pid=$(slot_ciadpi_pid "$_id"); _port=$(slot_socks_port "$_id")
    proc_alive "$_pid" || { log "слот №$_id: ciadpi не запущен — новая стратегия применится при включении выхода"; return 0; }
    # ГОНКА (поймана на железе dev43): ciadpi отвечает на SIGTERM не мгновенно, а порт отпускает
    # ещё позже. Если просто «подождать, пока порт освободится, и спавнить», новый демон упирается
    # в занятый :port, молча выходит — а netstat всё ещё видит СТАРОГО слушателя, и проверка
    # «поднялся» отвечает ЛОЖНО-ПОЛОЖИТЕЛЬНО. Через десяток секунд старый дожимает выход, socks
    # исчезает вместе с hev/tun — выход «сам падает» после смены стратегии (лечил только watchdog).
    # Поэтому: ждём РЕАЛЬНОЙ смерти процесса, затем добиваем держателя порта (slot_free_socks
    # считает чужим любого, раз своего пидфайла уже нет), и лишь потом поднимаем новый.
    start-stop-daemon -K -p "$_pid" 2>/dev/null
    i=0; while [ $i -lt 6 ] && proc_alive "$_pid"; do sleep 1; i=$((i+1)); done
    rm -f "$_pid" 2>/dev/null
    slot_free_socks "$_id" "$_pid"
    slot_spawn_ciadpi "$_id"
    # Успех = порт слушает И его держит НАШ новый pid (иначе см. ложно-положительный выше).
    if slot_wait_socks "$_port" "$_pid" byedpi && slot_socks_is_ours "$_port" "$_pid"; then
        # NSS/conntrack: без сброса уже установленные соединения пула так и шли бы старым десинком.
        ct_flush
        log "слот №$_id: ciadpi перезапущен (десинк: $(slot_desync_args "$_id"))"
        return 0
    fi
    # Не оставляем выход без несущей до тика watchdog: idem-slot-up поднимет ciadpi+hev+маршруты
    # (а если и он не смог — выход честно падает в свою fallback-политику, как при любом сбое).
    log "слот №$_id: ciadpi не перезапустился — пробую поднять выход целиком. Лог:"; tail -n 15 "$(slot_ciadpi_log "$_id")" 2>/dev/null
    cmd_slot_up "$_id" && return 0
    return 1
}

# slot-health <id> — жив ли ДОП-ВЫХОД. Контракт (transport.sh): 0 жив / 1 просел / 2 «не умею».
# ЗАЧЕМ, если сторож и так смотрит pid+tun: ciadpi умеет БЫТЬ ЖИВЫМ ПРОЦЕССОМ и при этом не
# форвардить (известная смерть `accept: Invalid argument` роняет приём соединений, а процесс и
# xtunN остаются на месте) — тогда выход тихо блэкхолит трафик своей группы, а лёгкая проба
# рапортует «здоров». Egress-проба ловит ровно этот случай, как у xray/hy2-слотов.
# Проба ПО IP, а НЕ по имени: резолв внутри ciadpi хрупок, `--socks5-hostname` уже давал ложный
# fail и уводил транспорт на awg (та же грабля, что в основном cmd_health).
cmd_slot_health() {   # $1 = id
    _id="$1"
    case "$_id" in 2|3|4) ;; *) return 1 ;; esac
    # Свип (панель применяет стратегии вживую) = штатные рестарты ciadpi. Не судим — иначе
    # сторож принял бы подбор стратегии за падение выхода и погасил бы его посреди свипа.
    sweep_fresh && return 0
    proc_alive "$(slot_ciadpi_pid "$_id")" || { log "слот №$_id health: ciadpi не жив"; return 1; }
    proc_alive "$(slot_hev_pid "$_id")"    || { log "слот №$_id health: hev не жив"; return 1; }
    ip link show "$(slot_tun "$_id")" >/dev/null 2>&1 || { log "слот №$_id health: нет $(slot_tun "$_id")"; return 1; }
    if bd_egress_ok "--socks5 $SOCKS_ADDR:$(slot_socks_port "$_id")"; then
        # ciadpi форвардит — а путь клиентов выхода через его hev? (slot-tun-lib.sh::slot_hev_path_check; нет функции — как раньше)
        command -v slot_hev_path_check >/dev/null 2>&1 || return 0
        slot_hev_path_check "$_id"; return $?
    fi
    log "слот №$_id health: проба egress не прошла (ciadpi не форвардит наружу)"
    return 1
}

# Снятие поднятого свипом, если VPN выключили по ходу: у выхода — его несущая, у основной — `down` (carrier_run зовёт с теми же аргументами).
sweep_undo() { if [ -n "$2" ]; then cmd_slot_down "$2"; else cmd_down; fi; }

case "$1" in
    # Вербы, которые ПОДНИМАЮТ ciadpi/hev, — через carrier_run (daemon-lib.sh): при выключенном вручную VPN отказ, а выключение,
    # пришедшее по ходу, отпускает поднятое. `health` тоже здесь: он не только проба — просевшую несущую он ПЕРЕПОДНИМАЕТ на месте
    # (reup_carrier), и диагностика (dump.sh) при выключенном VPN поднимала бы ByeDPI обратно.
    up)       carrier_run cmd_down cmd_up ;;
    down)     cmd_down ;;
    cold)     : ;;                        # тёплого резерва нет: демонов гасит сам `down` (stop_daemons)
    status)   cmd_status ;;
    health)   carrier_run cmd_down cmd_health ;;
    failover) carrier_run cmd_down cmd_failover ;;
    dns)      set_direct_dns ;;      # переиграть DNS (DoH toggle/смена резолвера) — прямой режим через doh_apply_dns
    reload)   carrier_run cmd_down cmd_reload ;;   # перезапустить ciadpi с текущими .byedpi-args (без обрыва несущей)
    defaults) strip_unsupported "$DEFAULT_ARGS" ;;  # дефолтный авто-набор (для показа в панели; -S вырезан)
    presets)  cmd_presets ;;         # курированная библиотека готовых стратегий (label|args)
    # Служебный socks для АПДЕЙТЕРА (gh-update.sh): десинк без несущей, правил и tun. Печатает
    # адрес; socks-down гасит только временный демон. Транспортом от этого byedpi НЕ становится.
    socks-up)   cmd_socks_up "$2" ;;      # $2 = pid вызывающего (ref-счёт: прокси общий на процессы)
    socks-down) cmd_socks_down "$2" ;;
    # Браузер-свип. 3-й/2-й аргумент = id ДОП-ВЫХОДА (пусто = основная несущая): у выхода своя
    # стратегия и свой ciadpi, значит и бэкап/рестарт его собственные.
    sweep-begin) cmd_sweep_begin "$2" ;;      # снять бэкап исходной стратегии + поставить lock
    sweep-apply) carrier_run sweep_undo cmd_sweep_apply "$2" "$3" ;; # применить ОДНУ стратегию вживую (0=поднялся,1=нет)
    sweep-end)   cmd_sweep_end "$2" ;;        # восстановить исходную стратегию, снять lock
    # Слот-вербы ОПЦИОНАЛЬНЫ: нет слот-слоя → код 2 «не умею», основная несущая не страдает.
    slot-up)   slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_up "$2" "$3" ;;   # доп-выход (Ф1c): поднять ciadpi+hev+xtunN в table 100N (cfg игнор)
    slot-down) slot_lib_ok || exit 2; cmd_slot_down "$2" ;;      # доп-выход: снять несущую слота (-> fallback-политика mark-core)
    slot-health) slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_health "$2" ;;  # доп-выход: жив ли (watchdog; egress-проба, не только pid); залипший hev выхода перезапускает — берёт несущую
    slot-reload) slot_lib_ok || exit 2; carrier_run cmd_slot_down cmd_slot_reload "$2" ;;  # доп-выход: перечитать .byedpi-args-s<id> (перезапуск только ciadpi слота)
    slot-iface)  slot_lib_ok || exit 2; slot_tun "$2" ;;         # имя несущей слота — учёту трафика (владелец имени один: slot-tun-lib.sh)
    *) echo "usage: $0 up|down|cold|status|health|failover|reload|defaults|presets|socks-up [pid]|socks-down [pid]|sweep-begin|sweep-apply|sweep-end|slot-up <id>|slot-down <id>|slot-health <id>|slot-reload <id>|slot-iface <id>"; exit 2 ;;
esac
