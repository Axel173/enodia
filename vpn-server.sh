#!/bin/sh
# vpn-server.sh — РОУТЕР КАК VPN-СЕРВЕР («доступ домой»): телефон/ноутбук снаружи подключается
# К СВОЕМУ роутеру, а дальше едет по ДОМАШНИМ правилам сплита.
#
# ЗАЧЕМ. Всё остальное в проекте — КЛИЕНТСКАЯ сторона (роутер идёт наружу к VPS). Здесь обратное
# направление: роутер ПРИНИМАЕТ подключение. Это закрывает три хотелки разом — «панель и домашние
# устройства снаружи», «двойной хоп: телефон → дом → зарубежный VPS», «выход с домашнего IP»
# (банки/госуслуги, где зарубежный адрес мешает).
#
# ПОЧЕМУ AmneziaWG, А НЕ ГОЛЫЙ WireGuard. Голый WG режется по сигнатуре хендшейка. У AWG та же
# криптография, но хендшейк обвешан мусором (Jc/Jmin/Jmax — junk-пакеты до рукопожатия, S1/S2 —
# мусор в init/response, H1..H4 — подмена типов заголовков): для DPI это не WG. Параметры
# генерятся УНИКАЛЬНЫМИ для установки (общий пресет со временем сам становится сигнатурой).
# Бинари amneziawg-go + awg уже стоят ради клиентской стороны ⇒ фича не стоит НИ БАЙТА флеша.
#
# ЧТО ЗДЕСЬ НЕ ПИШЕТСЯ ЗАНОВО (главное архитектурное решение). Режим маршрутизации пира — это
# РОВНО те три состояния, которые ядро уже умеет для домашних устройств, только ключом выступает
# адрес пира в туннеле:
#   split  — ничего не делаем: mark-core метит по dst-ipset независимо от входного интерфейса,
#            телефон получает ТОТ ЖЕ сплит, что и дом;
#   vpn    — apply-bypass force-add-ip <ip пира> (цепочка VPN_FORCE, «целиком через VPS»);
#   direct — apply-bypass add-ip <ip пира> (цепочка VPN_EXCLUDE, «мимо VPN, с домашнего адреса»).
# Поэтому пер-пир режимы переживают ребут и переигрываются штатным apply-bypass apply — своего
# персиста и своих mangle-правил у сервера НЕТ. Туда же бесплатно ложатся правила по портам.
#
# DNS ПИРА — НАШ dnsmasq (10.77.0.1). Без этого доменные правила (ipset=/дом/enodia_list) для
# телефона не работают вовсе: сет наполняет резолвер, и клиент с чужим DNS получит сплит только
# по CIDR-пулу. Та же грабля, что с ТВ со своим DNS.
#
# СЕКРЕТЫ. Приватный ключ пира хранится на роутере: конфиг телефона нужно уметь показать ПОВТОРНО
# (человек меняет телефон, теряет QR), а генерация на клиенте этого не даёт. Каталог server/ —
# только в бэкап с secrets=1, в diag не отдаём.
#
# БУДУЩЕЕ РАЗДЕЛЕНИЕ. Пока несущая одна (AmneziaWG), она живёт здесь в секции «НЕСУЩАЯ». Появится
# второй способ впустить (xray/Reality для сетей, где душат UDP) — секция уезжает в server-awg.sh
# по контракту up|down|health, как сделано с транспорт-плагинами. Абстракцию до второго кейса не
# заводим намеренно.
#
# СЕРЫЙ АДРЕС — ГЛАВНЫЙ СПОСОБ ЭТОЙ ФИЧИ НЕ ЗАРАБОТАТЬ, и он маскируется под успех. У провайдера с
# NAT адрес WAN-интерфейса приватный (172.16/12, 10/8, 100.64/10); положив его в Endpoint, мы
# выдаём конфиг, который ПРОВЕРЯЕТСЯ УСПЕШНО с домашнего Wi-Fi (адрес свой же, локальный) и не
# подключается из мобильной сети вообще. Поэтому адрес выбирает endpoint_auto (лучшее из
# возможного), а «почему так» и что делать — обязанность панели: она получает в json сразу wan,
# wan_private и ext. Молча класть заведомо мёртвый адрес нельзя — человек уходит искать баг в
# конфиге вместо разговора с провайдером (разбор с тестером 12.08.2026).
#
# ВЕРБЫ:
#   init                      — ключи сервера, параметры обфускации, порт, подсеть (идемпотентно)
#   up | down | status | json — несущая awgs0 + правила фаервола
#   rules | unrules           — только правила (переигрыш после fw3 reload, из heal/repair)
#   peer-add <имя>            — новый пир (печатает МАШИННОЕ «id<TAB>ip»)
#   peer-del <id> | peer-list | peer-conf <id> | peer-rename <id> <имя>
#   peer-mode <id> <split|vpn|direct> | peer-lan <id> <on|off> | peer-toggle <id> <on|off>
#   json                      — ЕДИНЫЙ срез состояния для веб-панели
#   endpoint-set [хост]       — адрес для клиентских конфигов вручную (DDNS); пусто = по WAN

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
if ! command -v ct_flush_src >/dev/null 2>&1; then
    ct_flush_src()  { [ -n "$1" ] && conntrack -D --src "$1" >/dev/null 2>&1; return 0; }
    ct_flush_dst()  { [ -n "$1" ] && conntrack -D -d "$1" >/dev/null 2>&1; return 0; }
fi
SRV="$ENODIA_STATE/server"
IFACE=awgs0
PEERS="$SRV/peers.tsv"         # id<TAB>имя_b64<TAB>priv<TAB>pub<TAB>psk<TAB>mode<TAB>lan<TAB>on
ON_FLAG="$SRV/.on"
APPLY_BYPASS="$ENODIA_DIR/apply-bypass.sh"
IFCONF=/tmp/enodia-$IFACE.conf # конфиг для setconf — в RAM: несёт приватные ключи всех пиров
WAN_HOOK=input_wan_rule        # штатный пустой хук fw3 (тот же, что у панели)
WAN_CHAIN=VPNSRV_WAN
IN_CHAIN=VPNSRV_IN
FWD_CHAIN=VPNSRV_FWD
PEER_MAX=8                     # пиры = последний октет 2..9
MTU_PEER=1280                  # клиенту консервативно: его пакеты могут ехать ВТОРЫМ хопом в awg0
MTU_IFACE=1420
KEEPALIVE=25
RATE_NEW=30                    # новых хендшейков в минуту с одного адреса
# Порты САМОГО РОУТЕРА, открытые пиру с «доступом в домашнюю сеть». Всё остальное на роутере
# закрыто default-deny'ем в конце VPNSRV_IN, поэтому список = единственное место, где решается
# «чем пир может управлять из туннеля»: 80 — штатная вебморда Xiaomi (человек, включивший доступ
# домой, ждёт именно её: домашние устройства едут через FORWARD и доступны, а сам роутер — нет),
# 8088/8443 — наша панель (http и TLS). SSH (22) НЕ открываем: dropbear на стоке пускает по
# ПАРОЛЮ root, а туннель здесь — путь из интернета; кому нужно, добавит сюда осознанно.
LAN_PORTS="80 8088 8443"

# umask ДО первой записи чего бы то ни было, а не `chmod 600` после неё: между `>` и `chmod`
# файл с приватным ключом (server.key, peers.tsv, $IFCONF со связкой ключей ВСЕХ пиров) уже
# существует с правами по умолчанию. Все файлы этого скрипта — служебные и читаются только
# root'ом, поэтому маска ставится один раз на весь скрипт, а не по месту (три места забыть легче,
# чем одно). chmod'ы ниже оставлены: они чинят права у файлов, созданных прежними версиями.
umask 077

# ip-lib: «публичный ли адрес WAN» (is_private_ip) и «какой у нас внешний IPv4 НА САМОМ ДЕЛЕ»
# (probe_ext_ip). Обе нужны endpoint'у для клиентских конфигов — см. endpoint_auto ниже. Форма
# сорсинга общая по проекту: провалившийся `.` в ash — фатальная ошибка спецбилтина (шелл выходит
# на месте), поэтому только через `if [ -f ]`, а шим повторяет ПРЕЖНЕЕ поведение.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }
command -v is_private_ip >/dev/null 2>&1 || is_private_ip() {
    case "$1" in
        10.*|127.*|169.254.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
    esac
    return 1
}

# clock-lib: возраст отметки времени. Голая разность `now - отметка` врёт ровно на величину скачка
# часов (RTC нет, стоковый ntp доезжает через ~13 мин после загрузки) — тут это выглядело бы как
# «телефон на связи был 21 час назад» у пира, подключившегося минуту назад.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

log() { echo "[vpn-server] $*"; }

# Сброс conntrack по адресу ОДНОГО пира. Зачем отдельной функцией: правила пира (доступ в дом,
# режим) меняются точечно, а NSS/ECM-offload держит УЖЕ УСТАНОВЛЕННЫЙ поток по старому вердикту —
# без этого «выключил доступ в домашнюю сеть» не рвало открытую сессию к панели/NAS, и человек
# видел бы, что запрет не действует (инвариант проекта: ветка, меняющая правила, сбрасывает
# conntrack). Глобальный флаш здесь запрещён — он рвёт трансляции всему дому.
peer_conntrack() {   # $1=id
    _cip=$(peer_ip "$1"); [ -n "$_cip" ] || return 0
    ct_flush_src "$_cip"
    ct_flush_dst "$_cip"
    return 0
}

awg_bin() { if [ -x "$ENODIA_BIN/awg" ]; then echo "$ENODIA_BIN/awg"; else command -v awg; fi; }

# WAN-интерфейс по дефолт-маршруту (пусто = WAN не настроен). Владелец — ip-lib.sh::wan_iface
# (сорсится выше); здесь ШИМ на случай старой библиотеки, а не вторая копия: безусловное
# определение перебивало бы библиотечное и давало ДРУГОЙ ответ (без гарда «дефолт смотрит в туннель»).
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }
wan_addr()  { ip -4 addr show dev "$(wan_iface)" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1; }

subnet()    { cat "$SRV/subnet" 2>/dev/null || echo 10.77.0; }      # /24, без последнего октета
router_ip() { echo "$(subnet).1"; }
peer_ip()   { echo "$(subnet).$1"; }
srv_port()  { cat "$SRV/port" 2>/dev/null | tr -cd '0-9'; }
# Адрес для конфига клиента: ручной override (домен от DDNS) важнее автодетекта — у DDNS-имени
# конфиг не протухает при смене IP, а это главная боль endpoint'а по голому адресу.
endpoint_host() { cat "$SRV/endpoint" 2>/dev/null | tr -d ' \t\r\n' || true; }

# --- «ПО КАКОМУ АДРЕСУ НАС НАЙДУТ СНАРУЖИ» -------------------------------------------------
EXT_CACHE=/tmp/.enodia-vpnsrv-ext # строка 1 = внешний IPv4 (может быть пустой), строка 2 = отметка
EXT_TTL=600                       # удачную пробу держим 10 мин: конфиг и QR открывают подряд
EXT_TTL_BAD=120                   # неудачную — 2 мин: WAN мог подняться только что

# Реальный внешний IPv4 — тот, что видит удалённая сторона. Пусто = проба не ответила.
# `--interface` ОБЯЗАТЕЛЕН: при живом туннеле проба «как есть» уходит через VPS и вернула бы адрес
# VPS, то есть ответ на совсем другой вопрос (та же грабля, что в web-ui.sh и cgi-bin/ip).
wan_ext_addr() {
    _xc=$(sed -n 1p "$EXT_CACHE" 2>/dev/null | tr -d ' \t\r\n')
    _xs=$(sed -n 2p "$EXT_CACHE" 2>/dev/null | tr -d ' \t\r\n')
    case "$_xs" in ''|*[!0-9]*) _xs=0 ;; esac
    if [ "$_xs" -gt 0 ]; then
        _xt="$EXT_TTL_BAD"; [ -n "$_xc" ] && _xt="$EXT_TTL"
        # age_since, а не «now - отметка»: отметка рождается ПОСЛЕ загрузки, и скачок часов иначе
        # обнулял бы кэш каждым вызовом (clock-lib.sh).
        [ "$(age_since "$_xs")" -lt "$_xt" ] && { printf '%s' "$_xc"; return 0; }
    fi
    _xi=$(wan_iface); [ -n "$_xi" ] || return 0
    _xe=$(probe_ext_ip "--interface $_xi" 5)
    # ФОРМУ ответа проверяем У СЕБЯ, а не надеемся на поставщика. Канонический ip-lib якорит IPv4
    # сам, но ШИМ (частичная установка без либы) отдаёт тело curl как есть: страница
    # captive-portal или 5xx уехала бы и в `"ext":"…"` среза — кавычка рвёт JSON ЦЕЛИКОМ, а
    # cgi-bin/data берёт последнюю `^{`-строку, то есть экран не деградирует, а умирает, — и в
    # `Endpoint = …` конфига телефона. Тот же приём стоит у соседа (web/cgi-bin/ip).
    printf '%s' "$_xe" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || _xe=""
    printf '%s\n%s\n' "$_xe" "$(date +%s)" > "$EXT_CACHE"
    printf '%s' "$_xe"
}

# Автоадрес для клиентских конфигов, когда ручного (DDNS) нет.
# ПОЧЕМУ НЕ ПРОСТО `wan_addr`. Адрес WAN-интерфейса — самый честный и бесплатный ответ, но ТОЛЬКО
# пока он публичный. У провайдера с NAT интерфейсу достаётся приватный адрес (172.16/12, 10/8,
# 100.64/10), и такой конфиг НЕ ПОДКЛЮЧИТСЯ СНАРУЖИ НИКОГДА — при этом с домашнего Wi-Fi он
# работает (адрес-то свой, локальный), человек считает фичу исправной и упирается в стену уже в
# мобильной сети. Ровно этот сценарий пришёл от тестера 12.08.2026 (Endpoint = 172.20.40.111).
# Внешний адрес тоже не гарантия: при CGNAT он общий на многих абонентов и порт на нас не
# отобразится. Но при ДОМАШНЕМ двойном NAT (наш роутер за роутером провайдера или за ONT) он
# ЕДИНСТВЕННЫЙ рабочий — остаётся проброс UDP-порта на вышестоящем устройстве. Поэтому подставляем
# лучшее из возможного, а честный диагноз («адрес серый, нужно то-то») показывает панель по полям
# wan/wan_private/ext: врать конфигом нельзя, но и молча класть заведомо мёртвый адрес — тоже.
endpoint_auto() {
    _ea=$(wan_addr)
    if [ -n "$_ea" ] && ! is_private_ip "$_ea"; then printf '%s' "$_ea"; return 0; fi
    _ee=$(wan_ext_addr)
    if [ -n "$_ee" ]; then printf '%s' "$_ee"; return 0; fi
    printf '%s' "$_ea"
}

# --- случайные числа без od (его на busybox НЕТ) ------------------------------------------
# 7 hex-цифр (макс 268435455) — заведомо влезают в 32-битную арифметику ash без ухода в минус.
rnd() {   # $1=min $2=max
    _h=$(head -c 16 /dev/urandom 2>/dev/null | md5sum | cut -c1-7)
    [ -n "$_h" ] || _h=$(date +%s | md5sum | cut -c1-7)
    echo $(( $1 + (0x$_h % ($2 - $1 + 1)) ))
}

# ================= ИНИЦИАЛИЗАЦИЯ (ключи, обфускация, порт) =================
gen_params() {
    # S1 + 56 == S2 запрещено: init-пакет с мусором совпал бы по размеру с response и обфускация
    # сама стала бы отличительным признаком. H1..H4 обязаны быть РАЗНЫМИ и не 1..4 (это штатные
    # типы WG — совпадение вернуло бы узнаваемый заголовок).
    _jc=$(rnd 4 10); _jmin=$(rnd 40 70); _jmax=$(rnd 800 1200)
    _s1=$(rnd 15 150); _s2=$(rnd 15 150)
    [ "$((_s1 + 56))" = "$_s2" ] && _s2=$((_s2 + 1))
    _h1=$(rnd 100000 900000000); _h2=$(rnd 100000 900000000)
    _h3=$(rnd 100000 900000000); _h4=$(rnd 100000 900000000)
    while [ "$_h2" = "$_h1" ]; do _h2=$(rnd 100000 900000000); done
    while [ "$_h3" = "$_h1" ] || [ "$_h3" = "$_h2" ]; do _h3=$(rnd 100000 900000000); done
    while [ "$_h4" = "$_h1" ] || [ "$_h4" = "$_h2" ] || [ "$_h4" = "$_h3" ]; do _h4=$(rnd 100000 900000000); done
    printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' \
        "$_jc" "$_jmin" "$_jmax" "$_s1" "$_s2" "$_h1" "$_h2" "$_h3" "$_h4"
}

cmd_init() {
    mkdir -p "$SRV" 2>/dev/null
    chmod 700 "$SRV" 2>/dev/null
    _awg=$(awg_bin)
    [ -x "$ENODIA_BIN/amneziawg-go" ] && [ -n "$_awg" ] || { log "нет бинарей amneziawg-go/awg — сервер не поднять"; return 1; }
    if [ ! -s "$SRV/server.key" ]; then
        "$_awg" genkey > "$SRV/server.key" 2>/dev/null || { log "не удалось сгенерировать ключ"; return 1; }
        chmod 600 "$SRV/server.key"
        "$_awg" pubkey < "$SRV/server.key" > "$SRV/server.pub"
        log "ключ сервера создан"
    fi
    [ -s "$SRV/params" ] || { gen_params > "$SRV/params"; log "параметры обфускации сгенерированы (уникальны для этой установки)"; }
    if [ -z "$(srv_port)" ]; then
        # Порт случайный высокий: 51820 узнаётся эвристикой «по порту» ещё до разбора пакета.
        _p=$(rnd 20000 60000)
        while netstat -lun 2>/dev/null | grep -q ":$_p "; do _p=$(rnd 20000 60000); done
        echo "$_p" > "$SRV/port"
        log "порт сервера: $_p"
    fi
    [ -f "$PEERS" ] || : > "$PEERS"
    chmod 600 "$PEERS" 2>/dev/null
    return 0
}

# ================= РЕЕСТР ПИРОВ =================
b64()   { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }
unb64() { printf '%s' "$1" | base64 -d 2>/dev/null; }

peer_field() {   # $1=id $2=номер поля -> значение
    awk -F'\t' -v id="$1" -v f="$2" '$1==id {print $f}' "$PEERS" 2>/dev/null | head -1
}
peer_exists() { [ -n "$(peer_field "$1" 1)" ]; }

next_free_id() {
    _i=2
    while [ "$_i" -le $((PEER_MAX + 1)) ]; do
        peer_exists "$_i" || { echo "$_i"; return 0; }
        _i=$((_i + 1))
    done
    return 1
}

peer_del_line() {   # $1=id ; переписываем файл целиком (sed -i по TAB на busybox капризен)
    awk -F'\t' -v id="$1" '$1!=id' "$PEERS" > "$PEERS.tmp" 2>/dev/null && mv "$PEERS.tmp" "$PEERS"
}

cmd_peer_add() {
    cmd_init || return 1
    _name="$1"
    [ -n "$_name" ] || { log "нужно имя устройства"; return 1; }
    _id=$(next_free_id) || { log "достигнут лимит $PEER_MAX устройств"; return 1; }
    _awg=$(awg_bin)
    _priv=$("$_awg" genkey 2>/dev/null)
    _pub=$(printf '%s' "$_priv" | "$_awg" pubkey 2>/dev/null)
    _psk=$("$_awg" genpsk 2>/dev/null)
    [ -n "$_priv" ] && [ -n "$_pub" ] || { log "не удалось сгенерировать ключи пира"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_id" "$(b64 "$_name")" "$_priv" "$_pub" "$_psk" "split" "off" "on" >> "$PEERS"
    # Машинный вывод: человеческий текст переводится i18n, парсить его нельзя (урок groups.sh new).
    printf '%s\t%s\n' "$_id" "$(peer_ip "$_id")"
    srv_running && { srv_setconf; srv_rules; }
    return 0
}

cmd_peer_del() {
    _id="$1"; peer_exists "$_id" || { log "нет устройства №$_id"; return 1; }
    peer_mode_apply "$_id" split          # снять вырез/форс, иначе адрес останется в персисте apply-bypass
    peer_del_line "$_id"
    srv_running && { srv_setconf; srv_rules; }
    peer_conntrack "$_id"                 # адрес свободен и достанется СЛЕДУЮЩЕМУ пиру — чужих потоков он унаследовать не должен
    log "устройство №$_id удалено"
}

cmd_peer_list() {
    [ -f "$PEERS" ] || return 0
    while IFS="$(printf '\t')" read -r _id _nb _pv _pb _pk _md _ln _on; do
        [ -n "$_id" ] || continue
        printf '%s\t%s\t%s\t%s\tlan=%s\t%s\n' "$_id" "$(peer_ip "$_id")" "$(unb64 "$_nb")" "$_md" "$_ln" "$_on"
    done < "$PEERS"
}

# Какой режим у адреса СЕЙЧАС — по персисту apply-bypass (он владелец). Идиомы чтения взяты
# один-в-один у другого читателя, `web/cgi-bin/data` (в `.fullvpn-ips` вторым полем бывает доп-выход,
# поэтому там awk по первому полю, а не grep по строке) — третьей трактовки формата не заводим.
peer_cur_mode() {   # $1=ip -> split|direct|vpn
    grep -qxF "$1" "$ENODIA_STATE/.bypass-ips" 2>/dev/null && { echo direct; return 0; }
    awk -F'\t' -v want="$1" '$1==want{f=1} END{exit f?0:1}' "$ENODIA_STATE/.fullvpn-ips" 2>/dev/null && { echo vpn; return 0; }
    echo split
}

# Режим пира = состояние в apply-bypass по его адресу. Своих mangle-правил не держим (см. шапку).
# ГЕЙТ «уже применено» обязателен, и вот почему: КАЖДАЯ ветка apply-bypass кончается ГЛОБАЛЬНЫМ
# `conntrack -F`, а `srv_rules` переигрывает режимы ВСЕХ включённых пиров — то есть один клик по
# тумблеру устройства в панели рвал соединения ВСЕМУ ДОМУ (у split — дважды на пира: del-ip +
# force-del-ip). Ровно от этого cmd_up отказывается тремя строками ниже («флаш всей таблицы рвёт
# трансляции всему дому ради нулевого эффекта») — а через apply-bypass оно приезжало обратно.
# Замерено на живом роутере: посторонний поток LAN-устройства исчезал при `peer-lan off`.
peer_mode_apply() {   # $1=id $2=mode
    [ -n "$1" ] || return 0            # без id адрес выродился бы в «10.77.0.» — молча не трогаем чужое
    _ip=$(peer_ip "$1")
    # -f, а не -x: скрипт зовётся через `sh` (класс Б5-9) — снятый бит иначе тихо отменял бы режим.
    [ -f "$APPLY_BYPASS" ] || return 0
    _want="$2"; case "$_want" in vpn|direct) ;; *) _want=split ;; esac
    [ "$(peer_cur_mode "$_ip")" = "$_want" ] && return 0
    case "$2" in
        vpn)    sh "$APPLY_BYPASS" del-ip "$_ip" >/dev/null 2>&1
                sh "$APPLY_BYPASS" force-add-ip "$_ip" >/dev/null 2>&1 ;;
        direct) sh "$APPLY_BYPASS" force-del-ip "$_ip" >/dev/null 2>&1
                sh "$APPLY_BYPASS" add-ip "$_ip" >/dev/null 2>&1 ;;
        *)      sh "$APPLY_BYPASS" del-ip "$_ip" >/dev/null 2>&1
                sh "$APPLY_BYPASS" force-del-ip "$_ip" >/dev/null 2>&1 ;;
    esac
}

peer_set_field() {   # $1=id $2=номер поля $3=значение
    awk -F'\t' -v OFS='\t' -v id="$1" -v f="$2" -v v="$3" '$1==id {$f=v} {print}' "$PEERS" > "$PEERS.tmp" \
        && mv "$PEERS.tmp" "$PEERS"
}

cmd_peer_mode() {
    _id="$1"; peer_exists "$_id" || { log "нет устройства №$_id"; return 1; }
    case "$2" in split|vpn|direct) ;; *) log "режим: split|vpn|direct"; return 1 ;; esac
    peer_set_field "$_id" 6 "$2"
    # Выключенному устройству и при выключенном СЕРВЕРЕ режим только ЗАПОМИНАЕМ: применят его `peer-toggle on` и `srv_rules` на
    # подъёме. Иначе смена режима дёргала бы apply-bypass — его ветки кончаются ГЛОБАЛЬНЫМ сбросом conntrack (рвали соединения всему
    # дому ради адреса, которым никто не пользуется), а при снятом сервере адрес пира остался бы в персисте apply-bypass вопреки
    # `cmd_down` и всплыл бы на чужом устройстве с тем же IP (ревью шага 3c-3, круг 2).
    [ "$(peer_field "$_id" 8)" = on ] && srv_running && peer_mode_apply "$_id" "$2"
    log "устройство №$_id: режим $2"
}

cmd_peer_lan() {
    _id="$1"; peer_exists "$_id" || { log "нет устройства №$_id"; return 1; }
    case "$2" in on|off) ;; *) log "нужно on|off"; return 1 ;; esac
    peer_set_field "$_id" 7 "$2"
    srv_running && srv_rules
    # Правило меняется точечно, а УЖЕ ОТКРЫТЫЕ сессии пира едут по offload'у мимо новых правил:
    # без сброса «доступ в домашнюю сеть выключен» не рвал открытую вкладку панели/сессию к NAS,
    # то есть запрет не действовал ровно там, где его включают — после потери телефона.
    peer_conntrack "$_id"
    log "устройство №$_id: доступ в домашнюю сеть $2"
}

cmd_peer_rename() {
    _id="$1"; peer_exists "$_id" || { log "нет устройства №$_id"; return 1; }
    [ -n "$2" ] || { log "нужно имя"; return 1; }
    peer_set_field "$_id" 2 "$(b64 "$2")"
    log "устройство №$_id переименовано"
}

cmd_peer_toggle() {
    _id="$1"; peer_exists "$_id" || { log "нет устройства №$_id"; return 1; }
    case "$2" in on|off) ;; *) log "нужно on|off"; return 1 ;; esac
    peer_set_field "$_id" 8 "$2"
    [ "$2" = off ] && peer_mode_apply "$_id" split
    [ "$2" = on ] && srv_running && peer_mode_apply "$_id" "$(peer_field "$_id" 6)"
    srv_running && { srv_setconf; srv_rules; }
    peer_conntrack "$_id"    # выключенный пир не должен доигрывать открытые сессии (см. peer_conntrack)
    log "устройство №$_id: $2"
}

# Конфиг для телефона. AllowedIPs ВСЕГДА 0.0.0.0/0 — какой трафик куда пойдёт, решает РОУТЕР
# (режим пира), поэтому смена режима не требует переиздавать конфиг и пересканировать QR.
cmd_peer_conf() {
    _id="$1"; peer_exists "$_id" || { log "нет устройства №$_id"; return 1; }
    _host=$(endpoint_host); [ -n "$_host" ] || _host=$(endpoint_auto)
    [ -n "$_host" ] || { log "не определён внешний адрес — WAN не настроен?"; return 1; }
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = %s\nMTU = %s\n' \
        "$(peer_field "$_id" 3)" "$(peer_ip "$_id")" "$(router_ip)" "$MTU_PEER"
    cat "$SRV/params"
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = %s:%s\nPersistentKeepalive = %s\n' \
        "$(cat "$SRV/server.pub")" "$(peer_field "$_id" 5)" "$_host" "$(srv_port)" "$KEEPALIVE"
}

# ================= НЕСУЩАЯ (AmneziaWG) =================
srv_daemon_pids() {   # матчим по /proc/*/cmdline — killall убил бы awg0 и слот-выходы
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        case "$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline") " in
            *"amneziawg-go $IFACE "*) echo "${_p#/proc/}" ;;
        esac
    done
}
srv_kill_daemon() {
    for _pid in $(srv_daemon_pids); do kill "$_pid" 2>/dev/null; done
    _i=0
    while [ -n "$(srv_daemon_pids)" ] && [ "$_i" -lt 8 ]; do
        [ "$_i" = 3 ] && for _pid in $(srv_daemon_pids); do kill -9 "$_pid" 2>/dev/null; done
        sleep 1; _i=$((_i + 1))
    done
    rm -f "/var/run/amneziawg/$IFACE.sock" "/var/run/wireguard/$IFACE.sock" 2>/dev/null
}
srv_running() { ip link show "$IFACE" >/dev/null 2>&1; }

# Конфиг для setconf собирается ИЗ РЕЕСТРА при каждом изменении: единственный источник правды —
# peers.tsv, отдельной копии состава в файле не держим (разошлись бы).
# ВАЖНО про имена переменных цикла: в busybox sh нет `local`, а эту функцию (и srv_rules) зовут
# КОМАНДЫ, держащие номер пира в `_id`. Пока цикл читал в `_id`, он затирал его у вызвавшего:
# в логе появлялось «устройство №: доступ в домашнюю сеть off» без номера, а добавленный сюда
# сброс conntrack получал пустой id. Поэтому у циклов-callee имена СВОИ (`_r*`). Та же грабля и
# то же лечение, что записаны в шапке support.sh про `proc_alive`/`_ap`.
srv_setconf() {
    printf '[Interface]\nPrivateKey = %s\nListenPort = %s\n' "$(cat "$SRV/server.key")" "$(srv_port)" > "$IFCONF"
    cat "$SRV/params" >> "$IFCONF"
    while IFS="$(printf '\t')" read -r _rid _rnb _rpv _rpb _rpk _rmd _rln _ron; do
        [ -n "$_rid" ] || continue
        [ "$_ron" = on ] || continue
        printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
            "$_rpb" "$_rpk" "$(peer_ip "$_rid")" >> "$IFCONF"
    done < "$PEERS"
    chmod 600 "$IFCONF" 2>/dev/null
    "$(awg_bin)" setconf "$IFACE" "$IFCONF" 2>&1 | grep -v '^$' || true
}

srv_carrier_up() {
    srv_running && { ip link set "$IFACE" up 2>/dev/null; return 0; }
    srv_kill_daemon
    # GOMEMLIMIT — см. разбор в шапке net-tune.sh (единственный владелец значения). Несущая
    # «доступа домой» — такой же демон Go с тем же безлимитным пулом буферов.
    # grep по ФОРМЕ — гард на рассинхрон версий: старый net-tune.sh печатает на этот верб `usage: …`
    # в stdout, и оно стало бы первым аргументом env (демон не стартует). См. шапку net-tune.sh.
    env $(sh "$ENODIA_DIR/net-tune.sh" memlimit-env 2>/dev/null | grep -E '^GOMEMLIMIT=[0-9]+MiB$') "$ENODIA_BIN/amneziawg-go" "$IFACE" || { log "amneziawg-go $IFACE не стартовал"; return 1; }
    _i=0; while ! srv_running && [ "$_i" -lt 10 ]; do sleep 1; _i=$((_i + 1)); done
    srv_running || { log "$IFACE не появился"; srv_kill_daemon; return 1; }
    srv_setconf
    ip a add "$(router_ip)/24" dev "$IFACE" 2>/dev/null
    ip link set dev "$IFACE" mtu "$MTU_IFACE" 2>/dev/null
    ip link set up "$IFACE"
    return 0
}

# ================= ПРАВИЛА ФАЕРВОЛА =================
# Пересобираем цепочки С НУЛЯ: порт мог смениться, а старое правило осталось бы открытой дырой в
# интернет — тот же довод, что у панели (досборка опаснее пересборки).
srv_rules() {
    _p=$(srv_port); [ -n "$_p" ] || { log "порт не задан"; return 1; }
    _wan=$(wan_iface)
    _sub="$(subnet).0/24"

    # 1) ВХОД снаружи: единственный порт, который эта фича открывает наружу. Ограничитель темпа —
    #    по новым пакетам с одного адреса: перебор ключей бессмыслен, но флуд хендшейками жрёт CPU.
    iptables -L "$WAN_HOOK" -n >/dev/null 2>&1 || { log "нет цепочки $WAN_HOOK (fw3 не поднят?)"; return 1; }
    iptables -N "$WAN_CHAIN" 2>/dev/null; iptables -F "$WAN_CHAIN" 2>/dev/null
    iptables -A "$WAN_CHAIN" -p udp --dport "$_p" -m conntrack --ctstate NEW -m hashlimit \
        --hashlimit-above "$RATE_NEW/min" --hashlimit-burst 20 --hashlimit-mode srcip \
        --hashlimit-name vpnsrv -j DROP 2>/dev/null
    iptables -A "$WAN_CHAIN" -p udp --dport "$_p" -j ACCEPT || { log "не удалось открыть порт"; return 1; }
    iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || iptables -I "$WAN_HOOK" 1 -j "$WAN_CHAIN"

    # 2) INPUT с туннеля. DNS — ВСЕГДА (без нашего резолвера у пира нет доменного сплита), ICMP —
    #    ради диагностики «дошёл ли я до роутера». Управление роутером ($LAN_PORTS: штатная
    #    вебморда + наша панель) — только пирам с доступом в дом.
    iptables -N "$IN_CHAIN" 2>/dev/null; iptables -F "$IN_CHAIN" 2>/dev/null
    iptables -A "$IN_CHAIN" -i "$IFACE" -p udp --dport 53 -j ACCEPT
    iptables -A "$IN_CHAIN" -i "$IFACE" -p tcp --dport 53 -j ACCEPT
    iptables -A "$IN_CHAIN" -i "$IFACE" -p icmp -j ACCEPT
    while IFS="$(printf '\t')" read -r _rid _rnb _rpv _rpb _rpk _rmd _rln _ron; do
        [ -n "$_rid" ] || continue
        [ "$_ron" = on ] && [ "$_rln" = on ] || continue
        for _port in $LAN_PORTS; do
            iptables -A "$IN_CHAIN" -i "$IFACE" -s "$(peer_ip "$_rid")" -p tcp --dport "$_port" -j ACCEPT
        done
    done < "$PEERS"
    # DEFAULT-DENY на САМ РОУТЕР. Обязателен: стоковая политика INPUT здесь ACCEPT, а DROP'ы
    # доступа в дом стоят в FORWARD и трафик к адресам роутера не ловят вовсе. Без этой строки
    # «доступ в домашнюю сеть выключен» — ложь: пир открывает панель, SSH и всё остальное, что
    # слушает роутер (поймано на железе первым же подключением телефона).
    iptables -A "$IN_CHAIN" -i "$IFACE" -j DROP
    ipt_top INPUT -j "$IN_CHAIN"

    # 3) FORWARD. У fw3 policy DROP, а awgs0 не в зоне ⇒ без своих правил трафик пира не поедет
    #    никуда. Пир без доступа в дом не должен видеть домашние подсети — режем ПРИВАТКУ явным
    #    DROP выше общего ACCEPT (гостевая/miot тоже приватные, отдельного перечисления не нужно).
    iptables -N "$FWD_CHAIN" 2>/dev/null; iptables -F "$FWD_CHAIN" 2>/dev/null
    iptables -A "$FWD_CHAIN" -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    while IFS="$(printf '\t')" read -r _rid _rnb _rpv _rpb _rpk _rmd _rln _ron; do
        [ -n "$_rid" ] || continue
        [ "$_rln" = on ] && continue
        for _net in 192.168.0.0/16 172.16.0.0/12 10.0.0.0/8; do
            iptables -A "$FWD_CHAIN" -i "$IFACE" -s "$(peer_ip "$_rid")" -d "$_net" -j DROP
        done
    done < "$PEERS"
    iptables -A "$FWD_CHAIN" -i "$IFACE" -j ACCEPT
    ipt_top FORWARD -j "$FWD_CHAIN"

    # 4) Прямой путь пира наружу: подсеть туннеля не в зоне fw3 ⇒ стоковый маскарад её не берёт.
    #    Путь «в VPN» маскарадит плагин несущей (-o awg0), тут только WAN.
    if [ -n "$_wan" ]; then
        iptables -t nat -C POSTROUTING -s "$_sub" -o "$_wan" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$_sub" -o "$_wan" -j MASQUERADE
    fi

    # Режимы пиров переигрываем здесь же: apply-bypass — владелец правил, мы лишь напоминаем
    # состав (после fw3 reload его цепочки тоже могли смыться).
    while IFS="$(printf '\t')" read -r _rid _rnb _rpv _rpb _rpk _rmd _rln _ron; do
        [ -n "$_rid" ] || continue
        [ "$_ron" = on ] || continue
        peer_mode_apply "$_rid" "$_rmd"
    done < "$PEERS"
    return 0
}

srv_unrules() {
    while iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null; do iptables -D "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || break; done
    iptables -F "$WAN_CHAIN" 2>/dev/null; iptables -X "$WAN_CHAIN" 2>/dev/null
    while iptables -C INPUT -j "$IN_CHAIN" 2>/dev/null; do iptables -D INPUT -j "$IN_CHAIN" 2>/dev/null || break; done
    iptables -F "$IN_CHAIN" 2>/dev/null; iptables -X "$IN_CHAIN" 2>/dev/null
    while iptables -C FORWARD -j "$FWD_CHAIN" 2>/dev/null; do iptables -D FORWARD -j "$FWD_CHAIN" 2>/dev/null || break; done
    iptables -F "$FWD_CHAIN" 2>/dev/null; iptables -X "$FWD_CHAIN" 2>/dev/null
    _wan=$(wan_iface); _sub="$(subnet).0/24"
    [ -n "$_wan" ] && iptables -t nat -D POSTROUTING -s "$_sub" -o "$_wan" -j MASQUERADE 2>/dev/null
    return 0
}

cmd_up() {
    cmd_init || return 1
    srv_carrier_up || return 1
    # Правила не встали — снимаем ВСЁ, а не только демона: srv_rules падает пошагово, и на середине
    # (например, INPUT-цепочка не создалась) порт наружу УЖЕ открыт. Погасив одну несущую, мы бы
    # оставили в интернет открытый UDP-порт, за которым никто не слушает, — ровно «полуоткрытый
    # сервер», от которого эта ветка и защищает. Порядок: сначала правила, потом демон.
    srv_rules || { log "правила не встали — снимаю правила и гашу несущую, полуоткрытым сервер не оставляем"; srv_unrules; srv_kill_daemon; return 1; }
    : > "$ON_FLAG"
    # Переигрываем ЯДРО маркировки. Гард «ответы сервера идут мимо туннеля» (vpnsrv-guard) живёт
    # в mark-core.sh и читает server/port В МОМЕНТ СВОЕГО ЗАПУСКА, а мы этот файл только что и
    # создали. Пока ядро не пробежало, гарда в mangle OUTPUT НЕТ — и ответ на рукопожатие пиру,
    # чей мобильный адрес попал в iplist_set/geo_vpn, уезжает В ТУННЕЛЬ: снаружи сервер выглядит
    # мёртвым при идеальном на вид файрволе, а из дома работает (приватный адрес ни в одном сете
    # не лежит). Раньше гард появлялся лишь со следующим прогоном ядра — ребут, heal, repair или
    # смена транспорта, то есть «сразу после включения не работает, а назавтра работает само».
    # Зовём ПОСЛЕ srv_rules: порядок цепочек mark-core не трогает (это владение
    # ensure_prerouting_order в apply-bypass), conntrack не флашит — соединениям дома ничего.
    [ -f "$ENODIA_DIR/mark-core.sh" ] && sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1 || true
    # ГЛОБАЛЬНОГО conntrack -F здесь НЕТ намеренно: интерфейс только что создан, своих соединений
    # у него быть не может, а флаш всей таблицы рвёт трансляции всему дому ради нулевого эффекта.
    # Режимы пиров сбрасывают conntrack сами (это делает apply-bypass в каждой своей ветке).
    log "сервер поднят: $IFACE $(router_ip)/24, порт UDP $(srv_port)"
    return 0
}

cmd_down() {
    # …и отложенное деактивацией намерение (`.on-deact`, разбор у uninstall.sh): выключил человек — «включить обратно» его не вернёт.
    rm -f "$ON_FLAG" "$SRV/.on-deact"
    srv_unrules
    # Режимы пиров — это адреса в персисте apply-bypass; сервер выключен, значит их там быть не
    # должно, иначе вырез/форс переживёт выключение и всплывёт на чужом устройстве с тем же IP.
    if [ -f "$PEERS" ]; then
        while IFS="$(printf '\t')" read -r _rid _rnb _rpv _rpb _rpk _rmd _rln _ron; do
            [ -n "$_rid" ] || continue
            peer_mode_apply "$_rid" split
        done < "$PEERS"
    fi
    srv_kill_daemon
    ip link del "$IFACE" 2>/dev/null
    rm -f "$IFCONF"
    # Точечно: гасим трансляции ТОЛЬКО подсети пиров (иначе «выключил сервер» рвёт соединения
    # всему дому). Ключ -s с маской понимает conntrack-tools; нет его — молча пропускаем.
    ct_flush_src "$(subnet).0/24"
    log "сервер снят"
    return 0
}

# Ручной endpoint (DDNS-имя вместо голого IP). Пустая строка = снять override и вернуться к
# автодетекту по WAN. Конфиги уже выданных пиров при этом НЕ переиздаются молча — панель честно
# говорит, что после смены адреса QR надо пересканировать.
cmd_endpoint_set() {
    mkdir -p "$SRV" 2>/dev/null
    _h=$(printf '%s' "$1" | tr -d ' \t\r\n')
    case "$_h" in
        '') rm -f "$SRV/endpoint"; log "адрес для клиентов: автоматически (WAN)" ;;
        *[!A-Za-z0-9.:_-]*) log "недопустимый адрес"; return 1 ;;
        *)  printf '%s\n' "$_h" > "$SRV/endpoint"; log "адрес для клиентов: $_h" ;;
    esac
}

# ЕДИНЫЙ срез для панели. Своей копии «включено/работает» в CGI нет — тот же приём, что у
# `web-ui.sh json`: состояние знает владелец правил, а не тот, кто его рисует.
# Имя пира — base64 (name_b64), как у слотов: JSON-эскейпа на busybox нет, а имя пишет человек.
cmd_json() {
    _ready=false
    [ -x "$ENODIA_BIN/amneziawg-go" ] && [ -n "$(awg_bin)" ] && _ready=true
    _run=false;  srv_running && _run=true
    _on=false;   [ -f "$ON_FLAG" ] && _on=true
    _open=false; iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null && _open=true
    _man=$(endpoint_host)
    _wan=$(wan_addr)
    # «Достучатся ли снаружи» — по САМОМУ адресу WAN, без сетевой пробы (probe_ext_ip БЕЗ привязки
    # к WAN при живом туннеле отдаёт IP VPS и врала бы про CGNAT — грабля из web-ui.sh).
    _priv=false
    [ -n "$_wan" ] && is_private_ip "$_wan" && _priv=true
    # Внешний адрес запрашиваем ТОЛЬКО когда он что-то меняет, то есть при сером WAN: у роутера на
    # границе сети ответ известен заранее (это и есть адрес интерфейса), а проба стоит секунды.
    # Панель показывает ОБА адреса — без этого вопрос «откуда роутер взял этот IP» остаётся без
    # ответа, и человек ищет баг там, где его нет.
    _ext=""
    [ "$_priv" = true ] && _ext=$(wan_ext_addr)
    _host="$_man"; [ -n "$_host" ] || _host=$(endpoint_auto)
    # Рукопожатия/счётчики берём ОДНИМ `awg show dump` (по вызову на пира было бы 8 запусков).
    # Имя файла с ПИДом: срез зовёт панель, а вкладок у неё бывает две — на общем имени второй
    # опрос сносил бы файл из-под первого (`rm -f` в конце) и тот показывал бы нули вместо
    # рукопожатий. Дампу с ключами тут же ставим 600 (umask 077 в шапке).
    _dump=/tmp/.enodia-vpnsrv-dump.$$
    rm -f "$_dump"
    [ "$_run" = true ] && "$(awg_bin)" show "$IFACE" dump > "$_dump" 2>/dev/null
    _port=$(srv_port); [ -n "$_port" ] || _port=0
    printf '{"engine":true,"ready":%s,"on":%s,"running":%s,"port":%s,"subnet":"%s","max":%s,' \
        "$_ready" "$_on" "$_run" "$_port" "$(subnet)" "$PEER_MAX"
    printf '"endpoint":"%s","endpoint_manual":"%s","wan":"%s","wan_private":%s,"ext":"%s","port_open":%s,"peers":[' \
        "$_host" "$_man" "$_wan" "$_priv" "$_ext" "$_open"
    _first=1; _cnt=0
    if [ -f "$PEERS" ]; then
        while IFS="$(printf '\t')" read -r _id _nb _pv _pb _pk _md _ln _onp; do
            [ -n "$_id" ] || continue
            _cnt=$((_cnt + 1))
            # Строка пира в dump: pub psk endpoint allowed-ips latest-handshake rx tx keepalive.
            # -F обязателен: в ключах base64 есть «+» и «/» — как шаблон grep они бы поехали.
            # Пустой pubkey (битая строка реестра) — НЕ повод брать первую попавшуюся строку:
            # `grep -F ""` матчит всё, и пир получил бы счётчики СОСЕДА.
            _hs=0; _rx=0; _tx=0
            if [ -s "$_dump" ] && [ -n "$_pb" ]; then
                _line=$(grep -F "$_pb" "$_dump" 2>/dev/null | head -1)
                [ -n "$_line" ] && {
                    _hs=$(printf '%s' "$_line" | cut -f5); _rx=$(printf '%s' "$_line" | cut -f6)
                    _tx=$(printf '%s' "$_line" | cut -f7)
                }
            fi
            case "$_hs" in ''|*[!0-9]*) _hs=0 ;; esac
            case "$_rx" in ''|*[!0-9]*) _rx=0 ;; esac
            case "$_tx" in ''|*[!0-9]*) _tx=0 ;; esac
            # Возраст считаем ЗДЕСЬ (часы браузера и роутера расходятся, RTC нет) и ТОЛЬКО через
            # age_since: рукопожатие рождается ПОСЛЕ загрузки, а часы прыгают вперёд через ~13 мин
            # после неё ⇒ голая разность подписывала бы «на связи» как «21 ч назад» и человек шёл
            # чинить исправный туннель (clock-lib.sh). -1 = связи ещё не было.
            if [ "$_hs" -gt 0 ]; then _age=$(age_since "$_hs"); else _age=-1; fi
            [ "$_first" = 1 ] || printf ','
            _first=0
            printf '{"id":%s,"ip":"%s","name_b64":"%s","mode":"%s","lan":%s,"on":%s,"hs":%s,"age":%s,"rx":%s,"tx":%s}' \
                "$_id" "$(peer_ip "$_id")" "$_nb" "$_md" \
                "$([ "$_ln" = on ] && echo true || echo false)" \
                "$([ "$_onp" = on ] && echo true || echo false)" "$_hs" "$_age" "$_rx" "$_tx"
        done < "$PEERS"
    fi
    rm -f "$_dump"
    printf '],"count":%s,"full":%s}\n' "$_cnt" "$([ "$_cnt" -ge "$PEER_MAX" ] && echo true || echo false)"
}

cmd_status() {
    echo "=== VPN-сервер (доступ домой) ==="
    if srv_running; then
        echo "несущая: $IFACE UP, адрес $(router_ip)/24, порт UDP $(srv_port)"
    else
        echo "несущая: не поднята"
    fi
    # Тот же endpoint_auto, что уходит в конфиги пиров, а не своя копия «спроси wan_addr»: статус
    # читают, когда разбираются, ПОЧЕМУ телефон не подключается, и разойдись он с выданным конфигом
    # хоть на один адрес — диагностика уводила бы в сторону (сюда же смотрит dump.sh).
    _host=$(endpoint_host); [ -n "$_host" ] || _host=$(endpoint_auto)
    echo "endpoint для клиентов: $_host:$(srv_port)"
    # Разбивка «откуда адрес» — только когда она что-то объясняет: серый WAN и есть тот случай,
    # где выданный адрес и адрес интерфейса РАЗНЫЕ, а человек считает это багом выдачи конфига.
    _swan=$(wan_addr)
    if [ -n "$_swan" ] && is_private_ip "$_swan"; then
        echo "  адрес WAN-интерфейса: $_swan (ПРИВАТНЫЙ — снаружи по нему не подключиться)"
        _sext=$(wan_ext_addr)
        [ -n "$_sext" ] && echo "  реальный внешний адрес: $_sext (нужен проброс порта на вышестоящем роутере либо белый IP)"
    fi
    if iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null; then echo "порт наружу: открыт"; else echo "порт наружу: ЗАКРЫТ"; fi
    echo "--- устройства ---"
    cmd_peer_list
    if srv_running; then
        echo "--- рукопожатия ---"
        "$(awg_bin)" show "$IFACE" latest-handshakes 2>/dev/null
    fi
}

# restart — the SAME server on a fresh daemon (Components → «Перезапустить» after a binary update). Carrier only: the rules match
# the interface by NAME and peer modes live in apply-bypass by address, so both outlive the interface being recreated; the `.on`
# intent is never touched (down → up would clear it, and a failed `up` then would leave home access off for good). A failed start
# leaves `.on` with no awgs0 — exactly what the watchdog tick re-ups.
cmd_restart() {
    [ -f "$ON_FLAG" ] || { log "сервер выключен — перезапускать нечего"; return 0; }
    srv_kill_daemon
    ip link del "$IFACE" 2>/dev/null
    srv_carrier_up || { log "перезапуск: $IFACE не поднялся — сторож поднимет его на следующем тике"; return 1; }
    log "сервер перезапущен: $IFACE на новом демоне"
    return 0
}

case "$1" in
    init)        cmd_init ;;
    restart)     cmd_restart ;;
    enabled)     [ -f "$ON_FLAG" ] ;;   # код 0 — «доступ домой» включён (намерение); перезапуск в «Компонентах» отличает демон от сироты
    up)          cmd_up ;;
    down)        cmd_down ;;
    status)      cmd_status ;;
    # `a && b || c` печатал бы ОДНУ причину на два разных отказа: при живой несущей и провале
    # srv_rules в лог уезжало «несущая не поднята» — ложь ровно там, где отчёт читают (переигрыш
    # правил из heal/repair). Разводим ветки явно.
    rules)       if srv_running; then srv_rules || exit 1
                 else log "несущая не поднята — правила не ставлю"; exit 1; fi ;;
    unrules)     srv_unrules ;;
    # Снесены ли правила, которые обязаны стоять: 0 — стоят (или «доступ домой» выключен), 3 — снесены, иное — не знаю. Все три
    # прыжка: порт наружу (хук fw3 reload пересоздаёт ПУСТЫМ), INPUT из туннеля, FORWARD. Спрашивает сторож при выключенном VPN
    # (хвост 10 ревью dev233); чинит `up`. Несущей awgs0 нет — «не знаю»: reload снимает правила, а не интерфейс, а без несущей
    # правил нет и после починки — «снесено» тут гнало бы сторожа чинить по кругу (каждая починка — сброс соединений).
    wired)       [ -f "$ON_FLAG" ] || exit 0
                 srv_running || exit 2
                 command -v ipt_jump_state >/dev/null 2>&1 || exit 2
                 _vwr=0
                 for _vwj in "$WAN_HOOK $WAN_CHAIN" "INPUT $IN_CHAIN" "FORWARD $FWD_CHAIN"; do
                     # shellcheck disable=SC2086
                     ipt_jump_state $_vwj; _vwc=$?
                     [ "$_vwc" = 2 ] && exit 2
                     [ "$_vwc" = 1 ] && _vwr=3
                 done
                 exit "$_vwr" ;;
    peer-add)    cmd_peer_add "$2" ;;
    peer-del)    cmd_peer_del "$2" ;;
    peer-list)   cmd_peer_list ;;
    peer-conf)   cmd_peer_conf "$2" ;;
    peer-mode)   cmd_peer_mode "$2" "$3" ;;
    peer-lan)    cmd_peer_lan "$2" "$3" ;;
    peer-toggle) cmd_peer_toggle "$2" "$3" ;;
    peer-rename) cmd_peer_rename "$2" "$3" ;;
    endpoint-set) cmd_endpoint_set "$2" ;;
    json)        cmd_json ;;
    *) echo "использование: $0 {init|up|down|status|json|rules|unrules|peer-add <имя>|peer-del <id>|peer-list|peer-conf <id>|peer-mode <id> <split|vpn|direct>|peer-lan <id> <on|off>|peer-toggle <id> <on|off>|peer-rename <id> <имя>|endpoint-set [хост]}" ;;
esac
