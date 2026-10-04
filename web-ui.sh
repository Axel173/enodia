#!/bin/sh
# web-ui.sh — поднимает ОТДЕЛЬНЫЙ веб-сервер (второй экземпляр uhttpd) под нашу
# панель управления VPN. НЕ трогает стоковый nginx (вебморду Xiaomi): слушает свой
# порт на LAN-IP. Отдаёт статику web/ + CGI web/cgi-bin/; вход — своей формой (cgi-bin/login).
#
# Почему uhttpd, а не busybox httpd: applet httpd в busybox этого роутера НЕ собран
# ("httpd: applet not found"), а бинарь uhttpd уже лежит в /usr/sbin (стоковый
# образ) — 0 байт флеша. Почему запуск из CLI без UCI-конфига в /etc: /etc
# сбрасывается при ребуте, конфиг там не переживёт перезагрузку — все параметры
# передаём аргументами. Демонизация — через start-stop-daemon -b -m (как у
# transport-плагинов): -f держит uhttpd на переднем плане, ssd уводит в фон и
# пишет pidfile (у uhttpd своего флага pidfile нет).
#
# АВТОРИЗАЦИЯ — СВОЯ ФОРМА ВХОДА, НЕ HTTP-Basic (с 03.09.2026). uhttpd стартует БЕЗ `-c`: статику
# он отдаёт всем (секретов в ней нет), а данные и действия закрыты гейтом сессии в КАЖДОМ CGI
# (totp.sh). Пароль сверяет cgi-bin/login: хэш (сильнейший, что умеет openssl прошивки: $6$ на
# BE7000, $1$ на AX3600 — замер 03.09.2026) лежит ОДНОЙ строкой в
# $ENODIA_STATE/.panel-pass (600), владелец — totp.sh (pw_*). Прежний $DOCROOT/uhttpd.conf
# `start` переносит туда и СНОСИТ: без Basic он скачивался бы по /uhttpd.conf. Зачем ушли от
# Basic: перебор не тормозился (401 отдавал uhttpd внутри keep-alive), хэш был прибит к $1$
# (musl-crypt панели умирал на $6$ — C38 теперь сторожит ОТСУТСТВИЕ -c), «выйти» не бывало.
# Пароль задаёт установщик (или вручную по SSH: sh /data/usr/app/enodia-boot/boot.sh web-ui.sh setpass — пароль команда
# спросит сама, см. setpass) — файл читается на каждом
# входе, перезапуск не нужен. Забыл пароль — задать заново с ПК или по SSH. Без пароля сервер
# НЕ стартует (не отдаём панель, в которую нельзя войти).
#
# БЕЗОПАСНОСТЬ: слушаем ТОЛЬКО основной LAN-IP (br-lan), не 0.0.0.0 → недоступно
# с WAN и из гостевой сети; -D запрещает листинг каталогов (403), -S не пускает по
# симлинкам за пределы docroot. CGI пока read-only (статус). Управляющие действия
# (Фаза 2) пойдут ТОЛЬКО через существующие безопасные скрипты с санитизацией ввода.
#
# HTTPS (verbs tls-on/tls-off) — ОТДЕЛЬНЫМ процессом `panel-tls`, а не самим uhttpd:
# [клиент] --TLS--> panel-tls:8443 --plain--> этот uhttpd на LAN-IP:8088. Стоковый uhttpd
# HTTPS формально умеет, но грузит крипто плагином `libustream-ssl.so`, которого в прошивке
# нет, а собранный нами не заводится: uhttpd Xiaomi собран с ПАТЧЕНЫМ `struct ustream`
# (пишет notify_* по смещениям 184/192/200 против апстримовых 168/176/184 — проверено
# зондом на железе и перебором всех коммитов libubox), т.е. плагин пришлось бы подгонять
# под вендорский ABI и ломать от каждого обновления прошивки. Разбор — dev/tls/NOTES.md.
# Сам по себе tls-on ничего в интернет не открывает — TLS слушает тот же LAN-IP.
#
# ДОСТУП СНАРУЖИ (verbs wan-on/wan-off) — правило в ШТАТНОМ хуке fw3 `input_wan_rule` (у стока
# он пуст и ровно для этого предназначен), своя цепочка PANEL_WAN. Наружу открываем ТОЛЬКО
# TLS-порт и ТОЛЬКО при включённом HTTPS: пароль поверх голого HTTP в интернете = отдать
# роутер первому, кто слушает канал. Правило смывает `fw3 reload` (вебморда Xiaomi) — переигрывает
# его `start`, который и так бежит из cron каждые 5 минут ради самой панели (той же ценой лечится
# и panel-tls). Отдельной строки в cron и правок в heal/watchdog не нужно. Тем же правилом внешний
# адрес открывается И из дома (hairpin/NAT loopback) — см. wan_rule_apply.
#
# ВТОРОЙ ФАКТОР (TOTP) — в том же totp.sh: код из приложения проверяет cgi-bin/2fa и ПОВЫШАЕТ
# парольную сессию до уровня 2, которого требуют все остальные CGI. Здесь только зеркалим
# состояние (json/status), чтобы у панели был ОДИН источник среза «доступ к панели».
# Аварийное отключение: sh totp.sh disable --force

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
DOCROOT="$ENODIA_DIR/web"
# Пароль панели — у владельца (totp.sh: pw_set/pw_verify/pw_migrate, файл .panel-pass). Сорсим
# как библиотеку; без неё (payload старее) setpass откажет, а start не поднимет панель без пароля.
TOTP_LIB=1
if [ -f "$ENODIA_DIR/totp.sh" ]; then . "$ENODIA_DIR/totp.sh"; fi
# router-lib.sh — ради lan_if ниже (имя LAN-моста спрашиваем у владельца, см. LISTEN).
if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi
# ip-lib.sh — имя WAN (wan_iface) и «приватный ли адрес» (is_private_ip) для вердикта «достучатся
# ли снаружи»; clock-lib.sh — «настоящие ли часы» (clock_sane) для выписки сертификата. Владельцы
# ответов — там (следят C81/C82); шимы стоят у мест использования.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
# Аптайм — у владельца (clock-lib.sh::uptime_s, следит C83); ниже шим. ПОВЕДЕНИЕ БЕЗ БИБЛИОТЕКИ
# СТАЛО ЧЕСТНЕЕ, а не «как было»: прежний шим отвечал 999999999 ВСЕГДА, то есть на буте без lib
# печаталось «ВНИМАНИЕ: WAN не определён»; теперь читаем /proc сами и говорим «идёт бут».
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
# LISTEN — реальный LAN-IP роутера, НЕ хардкод: роутер не всегда на .1 (бывает
# .100/.31), а захардкоженный .1 → uhttpd не забиндится на несуществующий адрес и панель
# не поднимется. Берём адрес основного LAN-бриджа; фолбэк на .1, если детект не удался.
# Имя моста спрашиваем у владельца (router-lib.sh::lan_if): им берётся не только LISTEN — это же
# имя уезжает в hairpin-правило NAT ниже (`-i "$LAN_IF"`), поэтому источник ответа обязан быть один.
LAN_IF=br-lan   # lan-lit: фолбэк на payload БЕЗ router-lib.sh — прежняя строка байт-в-байт
command -v lan_if >/dev/null 2>&1 && LAN_IF=$(lan_if)
LISTEN=$(ip -4 addr show "$LAN_IF" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
[ -n "$LISTEN" ] || LISTEN=192.168.31.1
PORT=8088
PIDFILE=/tmp/enodia-uhttpd-web.pid
UHTTPD=/usr/sbin/uhttpd

# --- HTTPS-терминатор -------------------------------------------------------
# Где лежит бинарь (store-lib.sh): без накопителя — прежний путь байт-в-байт. Выносить panel-tls
# на съёмный носитель нельзя (выдернул флешку — потерял вход в панель, в том числе снаружи), и
# держит это не проверка здесь, а БЕЛЫЙ список $STORE_MOVABLE в store-lib.sh, куда panel-tls
# сознательно не входит: движку оффлоада просто нечего с ним делать. Здесь мы читаем факт.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
TLS_BIN=$(bin_path panel-tls)
TLS_FLAG="$ENODIA_STATE/.panel-tls"      # есть файл = HTTPS включён; содержимое = порт (персист на /data)
TLS_CERT="$ENODIA_STATE/panel-cert.pem"
TLS_KEY="$ENODIA_STATE/panel-key.pem"
TLS_PID=/tmp/enodia-panel-tls.pid
TLS_LOG=/tmp/enodia-panel-tls.log
TLS_PORT_DEF=8443                   # 443 занят стоковым nginx — его не трогаем

# --- Доступ снаружи (WAN) ---------------------------------------------------
WAN_FLAG="$ENODIA_STATE/.panel-wan"      # есть файл = порт открыт наружу (персист на /data)
WAN_CHAIN=PANEL_WAN                 # СВОЯ цепочка (как ENODIA_GEOBLK/VPN_PORTS) — снимается целиком
WAN_DNAT=PANEL_WAN_DNAT             # она же в nat: заводит пакет с WAN на LAN-сокет panel-tls
WAN_HOOK=input_wan_rule             # штатный пустой хук fw3 внутри zone_wan_input
WAN_CONN_MAX=12                     # одновременных соединений с ОДНОГО адреса (у panel-tls всего 32
                                    # слотов ⇒ без этого один клиент занимает все и запирает хозяина)
WAN_RATE=30/min                     # новых соединений с адреса: браузер держит keep-alive, ему хватает
WAN_BURST=60                        # запас на первый заход (панель тянет статику+CGI параллельно)
WAN_IP_FILE="$ENODIA_STATE/.panel-wan-ip"  # последний известный внешний адрес (персист) — см. wan_ip_watch

# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений (ct-lib.sh) — нужен ровно одному месту: «закрыл доступ
# снаружи» обязано оборвать уже открытые снаружи сессии. Шим = прежнее поведение.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# «Слушает ли кто-то порт» — у владельца (daemon-lib.sh::daemon_port_listens); шим — та же строка.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v daemon_port_listens >/dev/null 2>&1 || daemon_port_listens() { netstat -ltn 2>/dev/null | grep -q "$1:$2 "; }
command -v daemon_wait_gone >/dev/null 2>&1 || daemon_wait_gone() { return 0; }   # старая библиотека — не ждём, как раньше
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v ct_flush_dport >/dev/null 2>&1 || ct_flush_dport() { [ -n "$1" ] && conntrack -D -p tcp --dport "$1" >/dev/null 2>&1; return 0; }

# Язык событийных писем — общий с остальными скриптами (шим, если файла ещё нет).
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }

# «Текст роутера → строка внутри JSON» (cmd_json ниже) — одна копия на проект, в json-lib.sh.
if [ -f "$ENODIA_DIR/json-lib.sh" ]; then . "$ENODIA_DIR/json-lib.sh"; fi
command -v jesc >/dev/null 2>&1 || {
	jesc() { tr -d '\033\r' | tr '\n\t' '  ' | cut -c1-"$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
}

is_running() {
	[ -f "$PIDFILE" ] || return 1
	pid=$(cat "$PIDFILE" 2>/dev/null)
	[ -n "$pid" ] && [ -d "/proc/$pid" ]
}

tls_enabled() { [ -f "$TLS_FLAG" ]; }
# ПОРТ — ЧИСЛО 1..65535 БЕЗ ВЕДУЩИХ НУЛЕЙ (ревью шага 7a, круг 2). «08443» проходил всё: `test` busybox считает по основанию 10,
# panel-tls читает `atoi` и садился на 8443, а в `json` уходило `"tls_port":08443` — невалидный JSON, и экраны доступа и второго
# фактора переставали открываться вовсе (чинилось только по SSH); iptables `--dport` читает ведущий ноль как восьмеричное.
# Поэтому форма одна — отсюда, и `tls_port` отдаёт только её: испорченный флаг = порт по умолчанию, а не битый ответ.
port_norm() {   # $1 — строка; печатает порт без ведущих нулей, код 1 — не порт
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	_pn=$(printf '%s' "$1" | sed 's/^0*//')
	case "$_pn" in ''|??????*) return 1 ;; esac
	[ "$_pn" -le 65535 ] || return 1
	echo "$_pn"
}
tls_port()    { _tp=$(port_norm "$(cat "$TLS_FLAG" 2>/dev/null)") || _tp=$TLS_PORT_DEF; echo "$_tp"; }

tls_running() {
	[ -f "$TLS_PID" ] || return 1
	pid=$(cat "$TLS_PID" 2>/dev/null)
	[ -n "$pid" ] && [ -d "/proc/$pid" ]
}

# ПОРТ ЗАНЯТ ЧУЖИМ? (ревью шага 7a). Порт, на который DNAT заводит трафик снаружи (`LISTEN:<порт>`), слушает не обязательно
# panel-tls: заводская веб-морда держит 0.0.0.0:80 и :443, dropbear — :22. Смена порта HTTPS на такой порт кончалась так:
# terminator не встаёт (порт занят), а правило наружу пересобиралось под новый порт — и в интернет уходила ЧУЖАЯ служба, а
# cron (*/5) ставил правило заново. Поэтому смену на занятый порт отказываем ДО записи флага. Наш же живой терминатор на этом
# порту — не «чужой». Адреса — те, куда попадёт трафик на LAN-адрес: сам он, любой IPv4 и любой IPv6.
tls_port_foreign() {   # $1 — порт; код 0 = его слушает кто-то, кроме нашего терминатора
	tls_running && [ "$1" = "$(tls_port)" ] && return 1
	for _pa in "$LISTEN" 0.0.0.0 "::"; do
		daemon_port_listens "$_pa" "$1" || continue
		tls_orphan_on "$1" && return 1     # слушает НАШ осиротевший терминатор — его снимет tls_stop (разбор у tls_orphans)
		return 0
	done
	return 1
}

# СВОИ ОСИРОТЕВШИЕ ТЕРМИНАТОРЫ (ревью шага 7a, круг 3). `ssd -K -x` у busybox сверяет бинарь по inode: заменили файл panel-tls под
# живым процессом (переустановка, доставка компонента) — старый процесс не гасится, а пидфайл обнулялся. Сирота держит порт, и
# `tls_port_foreign` называл его «другой службой роутера», а `wan_rule_apply` каждые пять минут закрывал вход снаружи — до ребута.
# Своего узнаём по argv (программа + наш `-l <LAN>:`), а не по пидфайлу. Шаблон со скобкой — иначе grep нашёл бы себя.
tls_orphans() {   # pid терминаторов panel-tls на нашем адресе, кроме записанного в пидфайле
	_tpo=$(cat "$TLS_PID" 2>/dev/null)
	for _tpf in $(grep -l "[p]anel-tls" /proc/[0-9]*/cmdline 2>/dev/null); do   # argv0: ищем САМУ программу (argv[0] — путь panel-tls); busybox grep видит его до первого NUL (C115)
		_tpp=${_tpf#/proc/}; _tpp=${_tpp%/cmdline}
		[ "$_tpp" = "$_tpo" ] && continue
		tr '\000' ' ' 2>/dev/null < "$_tpf" | grep -q -- "-l $LISTEN:" && echo "$_tpp"
	done
}
tls_orphan_on() {   # $1 — порт: его держит наш сирота?
	for _to in $(tls_orphans); do tr '\000' ' ' 2>/dev/null < "/proc/$_to/cmdline" | grep -q -- "-l $LISTEN:$1 " && return 0; done
	return 1
}
tls_pid_ours() { [ -n "$1" ] && tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -q "panel-tls"; }

# Самоподписанный сертификат живёт на /data (переживает ребут; /etc = ramfs).
# ГЕЙТ ПО ЧАСАМ ОБЯЗАТЕЛЕН: RTC на роутере нет, до ntpsetclock время = 1970, и выписанный
# тогда сертификат протух бы (notAfter = 1970+10 лет) ровно в момент, когда часы догонят
# реальность. Не выписываем — cron панели (*/5) вернётся сюда, когда время встанет.
tls_ensure_cert() {
	[ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] && return 0
	# Порог «часы настоящие» — у владельца (clock-lib.sh::clock_sane, следит C82).
	clock_sane || {
		echo "часы не синхронизированы — сертификат не выписан (повтор после ntp)"; return 1; }
	command -v openssl >/dev/null 2>&1 || { echo "нет openssl — сертификат не выписать"; return 1; }
	cn=$(cat /proc/sys/kernel/hostname 2>/dev/null)
	[ -n "$cn" ] || cn="$LISTEN"
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout "$TLS_KEY.tmp" -out "$TLS_CERT.tmp" -subj "/CN=$cn" >/dev/null 2>&1 || {
		rm -f "$TLS_KEY.tmp" "$TLS_CERT.tmp"; echo "не удалось выписать сертификат"; return 1; }
	mv "$TLS_KEY.tmp" "$TLS_KEY"; mv "$TLS_CERT.tmp" "$TLS_CERT"
	chmod 600 "$TLS_KEY"; chmod 644 "$TLS_CERT"
	echo "сертификат выписан (CN=$cn, самоподписанный)"
}

tls_start() {
	tls_enabled || return 0
	tls_running && return 0
	[ -x "$TLS_BIN" ] || { echo "нет $TLS_BIN — HTTPS пропущен"; return 1; }
	is_running || { echo "панель не поднята — HTTPS пропущен"; return 1; }
	tls_ensure_cert || return 1
	[ -f "$TLS_PID" ] && : > "$TLS_PID"
	# pidfile ведёт start-stop-daemon (как у uhttpd), поэтому своего -p демону не даём.
	start-stop-daemon -S -b -m -p "$TLS_PID" -x "$TLS_BIN" -- \
		-l "$LISTEN:$(tls_port)" -b "$LISTEN:$PORT" \
		-c "$TLS_CERT" -k "$TLS_KEY" -L "$TLS_LOG" >/dev/null 2>&1
	sleep 1
	if tls_running; then echo "HTTPS: https://$LISTEN:$(tls_port)  (pid $(cat "$TLS_PID"))"
	else echo "не удалось поднять panel-tls (см. $TLS_LOG)"; return 1; fi
}

tls_stop() {
	_tsw=0; tls_running && _tsw=1
	_tso=$(tls_orphans)
	[ "$_tsw" = 1 ] || [ -n "$_tso" ] || return 0
	_tsp=$(cat "$TLS_PID" 2>/dev/null)
	_tsour=0; tls_pid_ours "$_tsp" && _tsour=1
	# busybox ssd -K пишет результат в STDOUT — глушим, иначе строка протечёт в вывод CGI
	[ "$_tsw" = 1 ] && start-stop-daemon -K -p "$TLS_PID" -x "$TLS_BIN" >/dev/null 2>&1
	# ssd сверяет бинарь по inode и после замены файла не гасит (разбор у tls_orphans) — добиваем по pid, проверив, что он НАШ:
	# pid могли переиспользовать, чужой процесс по одному номеру не бьём.
	tls_pid_ours "$_tsp" && kill "$_tsp" 2>/dev/null
	for _o in $_tso; do kill "$_o" 2>/dev/null; done
	# Порт отпускает только мёртвый: перезапуск (перевыпуск и перечитывание сертификата) биндит ТОТ ЖЕ порт сразу за нами.
	[ "$_tsour" = 1 ] && daemon_wait_gone "$_tsp" 5
	for _o in $_tso; do daemon_wait_gone "$_o" 5; done
	: > "$TLS_PID"
	echo "HTTPS остановлен"
}

wan_enabled() { [ -f "$WAN_FLAG" ]; }

# WAN-интерфейс — у владельца (ip-lib.sh::wan_iface, сорсится в шапке; следит C81): dev дефолта
# main, свои несущие исключены. До 05.09.2026 тут жила СВОЯ версия — uci, а фолбэком `ip route
# get 1.1.1.1`: uci отвечает именем и при мёртвом WAN (адрес тогда протухший), а `ip route get`
# искажён тем, что мы чиним (awg-режим кладёт /32-маршруты, 1.1.1.1 ∈ iplist_set). Шим = та же
# строка владельца, на случай payload без библиотеки.
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }
wan_addr() {
	i=$(wan_iface); [ -n "$i" ] || return 1
	ip -4 addr show dev "$i" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1
}

# Вердикт «достучатся ли снаружи» — БЕЗ сетевой пробы, по самому WAN-адресу.
# Почему не `probe_ext_ip`: на роутере с живым туннелем она меряет выход ЧЕРЕЗ VPS и возвращает
# IP сервера (проверено: WAN 198.51.100.114, а проба отдаёт 192.0.2.198) ⇒ гард на ней ВСЕГДА
# врал бы «ты за NAT». Публичный адрес на WAN-интерфейсе = роутер и есть граница, проба избыточна
# (ровно замысел is_private_ip в ip-lib.sh); приватный = CGNAT или двойной NAT, и там внешний IP
# всё равно не наш — честно говорим, что автоматически не дотянемся.
#   public <ip> | private <ip> | none
wan_verdict() {
	a=$(wan_addr)
	[ -n "$a" ] || { echo none; return 0; }
	command -v is_private_ip >/dev/null 2>&1 && is_private_ip "$a" && { echo "private $a"; return 0; }
	echo "public $a"
}

# Внешний адрес ДИНАМИЧЕСКИЙ: после переподключения провайдер даёт другой, ссылка «снаружи»
# протухает МОЛЧА, и узнать об этом можно только вернувшись домой — ровно наоборот тому, ради
# чего доступ снаружи включали. Следим лишь пока он включён (иначе внешний адрес пользователю
# не нужен) и на ТОМ ЖЕ тике cron, что чинит правило: своей строки в crontab не заводим.
wan_ip_watch() {
	new="$1"
	[ -n "$new" ] || return 0
	old=$(cat "$WAN_IP_FILE" 2>/dev/null)
	[ "$old" = "$new" ] && return 0
	echo "$new" > "$WAN_IP_FILE"
	# Первый прогон (файла не было) — НЕ событие: сравнивать было не с чем, а письмо
	# «адрес сменился» сразу после включения только путает.
	[ -n "$old" ] || return 0
	[ -f "$ENODIA_DIR/notify-event.sh" ] || return 0
	# Приватный адрес (CGNAT) в письме = ссылка, которая никуда не ведёт: смену отмечаем в
	# файле, но молчим — панель об этом честно предупреждает своей плашкой.
	v=$(wan_verdict); set -- $v
	[ "$1" = public ] || return 0
	p=$(tls_port)
	if [ "$(nf_lang)" = en ]; then
		sh "$ENODIA_DIR/notify-event.sh" panel-wan-ip 3600 "BE7000: router external address changed" \
"The ISP gave the router a new external address, so the old panel link no longer works.

Was:  $old
Now:  $new

Panel from outside: https://$new:$p
Access from outside is still on, the login is still the panel password." >/dev/null 2>&1
	else
		sh "$ENODIA_DIR/notify-event.sh" panel-wan-ip 3600 "BE7000: внешний адрес роутера сменился" \
"Провайдер выдал роутеру новый внешний адрес — старая ссылка на панель больше не работает.

Было:  $old
Стало: $new

Панель снаружи: https://$new:$p
Доступ снаружи по-прежнему открыт, вход — под тем же паролем панели." >/dev/null 2>&1
	fi
	return 0
}

# Правило ставим ИДЕМПОТЕНТНО и пересобираем цепочку с нуля: TLS-порт мог смениться, а старое
# правило осталось бы открытым портом в интернет — ровно тот случай, где «досборка» опаснее пересборки.
wan_rule_apply() {
	wan_enabled || return 0
	tls_enabled || return 0     # без HTTPS наружу не открываем НИКОГДА (см. шапку)
	# …И БЕЗ ЖИВОГО ТЕРМИНАТОРА ТОЖЕ (ревью шага 7a): флаг HTTPS ещё не значит, что порт слушает НАШ panel-tls. Не поднялся — порт
	# наружу закрываем (снятое правило вернёт следующий тик, когда терминатор встанет), а не заводим трафик в пустоту или в
	# чужую службу на том же порту.
	if ! tls_running; then
		if iptables -L "$WAN_CHAIN" -n >/dev/null 2>&1 || wan_rule_active; then wan_rule_clear; fi
		echo "HTTPS не работает — порт наружу закрыт до его подъёма"
		return 0
	fi
	iptables -L "$WAN_HOOK" -n >/dev/null 2>&1 || { echo "нет цепочки $WAN_HOOK (fw3 не поднят?)"; return 1; }
	p=$(tls_port)
	iptables -N "$WAN_CHAIN" 2>/dev/null
	iptables -F "$WAN_CHAIN" 2>/dev/null
	# Порядок внутри цепочки = порядок отказов: сперва потолок одновременных, затем темп новых,
	# и только потом ACCEPT. Не попавшее в ACCEPT проваливается обратно в zone_wan_input → REJECT.
	# Код возврата лимитов ПРОВЕРЯЕМ: `-m hashlimit --help` доказывает лишь наличие библиотеки
	# расширения, а вставка может упасть на отсутствующем модуле ядра — молча открыть порт БЕЗ
	# ограничителя нельзя, это ровно та защита, ради которой порт вообще решились открыть.
	lim=1
	iptables -A "$WAN_CHAIN" -p tcp --dport "$p" -m connlimit \
		--connlimit-above "$WAN_CONN_MAX" --connlimit-mask 32 -j DROP 2>/dev/null || lim=0
	iptables -A "$WAN_CHAIN" -p tcp --dport "$p" -m conntrack --ctstate NEW -m hashlimit \
		--hashlimit-above "$WAN_RATE" --hashlimit-burst "$WAN_BURST" \
		--hashlimit-mode srcip --hashlimit-name paneltls -j DROP 2>/dev/null || lim=0
	iptables -A "$WAN_CHAIN" -p tcp --dport "$p" -j ACCEPT || { wan_rule_clear; echo "не удалось поставить правило"; return 1; }
	iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || iptables -I "$WAN_HOOK" 1 -j "$WAN_CHAIN"
	[ "$lim" = 1 ] || echo "ВНИМАНИЕ: ограничитель частоты подключений не встал — порт открыт без защиты от перебора"
	# panel-tls слушает ЛОКАЛЬНЫЙ LAN-адрес, и пакет, пришедший на WAN-адрес, до этого сокета сам
	# не доедет: разрешающего правила мало, слушателя на внешнем адресе просто нет («порт закрыт»
	# снаружи при идеальном на вид файрволе). Bind до 0.0.0.0 НЕ расширяем — тот же сокет стал бы
	# виден гостевой сети и любому будущему интерфейсу, а инвариант панели ровно обратный. Вместо
	# этого заводим трафик DNAT'ом на LAN-адрес: слушатель прежний, путь снаружи один и явный.
	wi=$(wan_iface)
	if [ -n "$wi" ]; then
		iptables -t nat -N "$WAN_DNAT" 2>/dev/null
		iptables -t nat -F "$WAN_DNAT" 2>/dev/null
		iptables -t nat -A "$WAN_DNAT" -i "$wi" -p tcp --dport "$p" -j DNAT --to-destination "$LISTEN:$p" 2>/dev/null \
			|| echo "ВНИМАНИЕ: не удалось завернуть WAN-трафик на панель (DNAT) — снаружи не откроется"
		# HAIRPIN (NAT loopback): ИЗ ДОМА внешний адрес не открывался — пакет к WAN-IP приходит на
		# br-lan, правило выше его не ловит (`-i <wan>`), слушателя на внешнем адресе нет ⇒ RST.
		# Одна и та же ссылка обязана работать в любой сети, иначе «снаружи открывается, а дома нет»
		# читается как поломка панели. SNAT здесь НЕ нужен: сервер — сам роутер, ответ разворачивает
		# та же запись conntrack (маскарад понадобился бы, стой за DNAT другой хост LAN). Гостевую
		# сеть НЕ пускаем — вход в панель только из основной, инвариант тот же, что у bind'а.
		ha=$(wan_addr)
		wan_ip_watch "$ha"
		if [ -n "$ha" ]; then
			iptables -t nat -A "$WAN_DNAT" -i "$LAN_IF" -d "$ha" -p tcp --dport "$p" \
				-j DNAT --to-destination "$LISTEN:$p" 2>/dev/null \
				|| echo "ВНИМАНИЕ: не удалось завернуть домашний трафик на внешний адрес (hairpin)"
		fi
		iptables -t nat -C PREROUTING -j "$WAN_DNAT" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$WAN_DNAT"
	else
		# На буте WAN (PPPoE, медленный DHCP) может ещё не подняться: heal зовёт нас в 5.17 раньше
		# дозвона, а cron `start` (*/5) переиграет правило, как только дефолт появится — это ожидание,
		# а не авария, и «ВНИМАНИЕ» здесь пугало бы на каждом ребуте.
		# Аптайм — у владельца (clock-lib.sh::uptime_s, сорсится в шапке; следит C83): своей копии
		# чтения /proc/uptime тут нет и быть не должно.
		if [ "$(uptime_s)" -lt 300 ] 2>/dev/null; then
			echo "WAN-интерфейс ещё не поднят (бут) — правило доступа снаружи поставлю следующим тиком"
		else
			echo "ВНИМАНИЕ: WAN-интерфейс не определён — снаружи не откроется"
		fi
	fi
	return 0
}

# Лимиты стоят? Считаем DROP'ы в цепочке (их ровно два, когда оба модуля зашли). Панель по этому
# полю честно предупреждает: «открыто, но без ограничителя» — а не делает вид, что всё в порядке.
wan_limits_ok() {
	n=$(iptables -S "$WAN_CHAIN" 2>/dev/null | grep -c 'j DROP')
	[ "${n:-0}" -ge 2 ] 2>/dev/null
}

wan_rule_clear() {
	# Ссылок может быть несколько (переигрыш поверх недоснятой) — снимаем, пока снимается.
	while iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null; do
		iptables -D "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || break
	done
	iptables -F "$WAN_CHAIN" 2>/dev/null
	iptables -X "$WAN_CHAIN" 2>/dev/null
	while iptables -t nat -C PREROUTING -j "$WAN_DNAT" 2>/dev/null; do
		iptables -t nat -D PREROUTING -j "$WAN_DNAT" 2>/dev/null || break
	done
	iptables -t nat -F "$WAN_DNAT" 2>/dev/null
	iptables -t nat -X "$WAN_DNAT" 2>/dev/null
	# Старые соединения переживают снятие правил (NSS/conntrack держит трансляцию) — гасим их,
	# иначе уже открытая снаружи сессия продолжает работать после «закрыл доступ». Владелец
	# сброса один — ct-lib.sh: на ядре 4.4 утилиты conntrack нет, и проверка `command -v` честно
	# отказывалась, оставляя чужую сессию живой; там сброс делает ручка ускорителя.
	ct_flush_dport "$(tls_port)"
	return 0
}

# «Правило стоит» = ОБА звена: разрешение в filter И заворот в nat. Без второго снаружи будет
# «закрыто» при зелёном статусе — ровно та ложь, которую панель обязана не показывать.
wan_rule_active() {
	iptables -C "$WAN_HOOK" -j "$WAN_CHAIN" 2>/dev/null || return 1
	iptables -t nat -C PREROUTING -j "$WAN_DNAT" 2>/dev/null
}

# «Второй фактор включён?» — спрашиваем ВЛАДЕЛЬЦА (totp.sh), своей копии состояния тут нет
# (та же причина, что у tls_*/wan_*: две копии разъезжаются). Нет движка — ответ «нет».
totp_on() {
	[ -f "$ENODIA_DIR/totp.sh" ] || return 1
	case "$(sh "$ENODIA_DIR/totp.sh" status 2>/dev/null | grep '^{' | tail -1)" in
		*'"on":true'*) return 0 ;;
	esac
	return 1
}

# ОТКРЫТИЕ ПОРТА НАРУЖУ ТРЕБУЕТ ВТОРОГО ФАКТОРА. За паролем здесь стоит не «страница настроек»,
# а действие `console` в cgi-bin/action — root-shell по замыслу; в интернете один лишь пароль
# его не удержит даже с паузой после неудач (с формы входа неудачи считает totp_lock_bump — тот
# же счётчик, что у кода, и за panel-tls он ОДИН на всех пришедших снаружи): пароли люди
# переиспользуют, код из приложения — нет.
# `--force` оставлен сознательно: это CLI, и хозяин вправе открыть порт зная цену (например,
# чтобы починить панель, когда телефон с приложением потерян). Панель `--force` не передаёт
# НИКОГДА — там путь один: сперва включи 2FA.
# УЖЕ ОТКРЫТЫЙ доступ этот гард не закрывает: `wan_rule_apply` (его зовёт cron каждые 5 минут)
# сюда не заходит. Иначе обновление панели молча отбирало бы вход снаружи у того, кто настроил
# его раньше этой проверки, — и выяснилось бы это в отъезде. Для таких установок панель показывает
# предупреждение рядом с тумблером.
wan_on() {
	tls_enabled || { echo "сперва включите HTTPS ($0 tls-on) — наружу открываем только его"; return 1; }
	tls_running || { echo "HTTPS включён, но panel-tls не работает — сперва почините его"; return 1; }
	_2fa=0; totp_on && _2fa=1
	if [ "$1" != "--force" ] && [ "$_2fa" = 0 ]; then
		echo "сперва включите второй фактор (2FA) — наружу открываем только под ним:"
		echo "панель → «Панель» → «Доступ к панели» → «Второй фактор»."
		echo "осознанно открыть без него: $0 wan-on --force"
		return 1
	fi
	: > "$WAN_FLAG"
	wan_rule_apply || { rm -f "$WAN_FLAG"; return 1; }
	# ГОНКА С «ВЫКЛЮЧИТЬ ВТОРОЙ ФАКТОР» ИЗ ДРУГОЙ ВКЛАДКИ (ревью шага 7a, круг 2): тот проверил «снаружи закрыто», пока мы
	# проверяли «второй фактор есть», — и оба прошли. Проверка ПОСЛЕ записи с обеих сторон (там — после снятия) закрывает окно:
	# кто кончил последним, тот и видит чужой итог.
	if [ "$_2fa" = 1 ] && ! totp_on; then
		wan_off >/dev/null 2>&1
		echo "второй фактор сняли в эту же минуту — вход снаружи не открыт"
		return 1
	fi
	v=$(wan_verdict); set -- $v
	case "$1" in
		public)  echo "открыт доступ снаружи: https://$2:$(tls_port)" ;;
		private) echo "правило поставлено, но WAN-адрес $2 приватный (CGNAT/двойной NAT) —"
		         echo "снаружи панель не откроется, пока провайдер не даст белый IP" ;;
		*)       echo "правило поставлено, но WAN-адрес определить не вышло" ;;
	esac
	# Итоговая строка обязана называть ФАКТ, а не намерение: под `--force` порт открыт БЕЗ второго
	# фактора, и «вход по-прежнему под паролем панели» звучало бы как «всё в порядке».
	if [ "$_2fa" = 1 ]; then
		echo "вход — пароль панели плюс код из приложения"
	else
		echo "ВТОРОГО ФАКТОРА НЕТ: вход держит один только пароль — он должен быть длинным"
	fi
}

wan_off() {
	rm -f "$WAN_FLAG"
	wan_rule_clear
	echo "доступ снаружи закрыт"
}

# --- Состояние для панели ОДНИМ JSON. Копию этой логики в cgi-bin/data не заводим: два места,
# считающие «включено/работает» по одним и тем же файлам, разъезжаются (проверено на подписках).
# Прогресс доустановки бинаря по воздуху отдаём отсюда же — panel-tls принадлежит этому скрипту.
cmd_json() {
	ti=false; [ -x "$TLS_BIN" ] && ti=true
	to=false; tls_enabled && to=true
	tr_=false; tls_running && tr_=true
	wo=false; wan_enabled && wo=true
	wr=false; wan_rule_active && wr=true
	wl=true; wan_rule_active && { wan_limits_ok || wl=false; }
	up=false; is_running && up=true
	cert=false; [ -s "$TLS_CERT" ] && [ -s "$TLS_KEY" ] && cert=true
	# ПОЧЕМУ ВКЛЮЧЁННЫЙ HTTPS НЕ РАБОТАЕТ — у роутера, а не догадкой панели (ревью шага 7a, круг 2): «поднимет сам в течение пяти
	# минут» верно не всегда — порт, занятый чужой службой, расписание не освободит, а сертификат ждёт часов. port · clock · bin ·
	# пусто (причина не видна — расписание пробует снова).
	twhy=""
	if [ "$to" = true ] && [ "$tr_" = false ]; then
		if [ "$ti" = false ]; then twhy=bin
		elif tls_port_foreign "$(tls_port)"; then twhy=port
		elif [ "$cert" = false ] && ! clock_sane; then twhy=clock
		fi
	fi
	v=$(wan_verdict); set -- $v; wkind="$1"; waddr="$2"
	# Прогресс доустановки panel-tls по воздуху. Источник — ОБЩИЕ файлы движка компонентов
	# (.proto-install.{state,log}): кнопка «Установить» зовёт packages.sh, своего лога у неё нет.
	ing=false; imsg=""; pkb=false; _imine=0
	# «Идёт ли установка» — вопрос К ДВИЖКУ (packages.sh busy), а не к pid-файлу: своя копия
	# критерия здесь и была одной из трёх, которые разъехались (карточка предлагала кнопку, а
	# гард панели на неё отказывал). Нет packages.sh (старая копия) — прежний ответ «не идёт».
	# ЧЬЯ операция — тоже ответ движка (`busy tls` → mine): установка Xray из «Компонентов» читалась
	# карточкой как «Устанавливаю…» HTTPS, а под кнопкой стояла чужая строка лога (ревью шага 5a, круг 3).
	# `installing` — ставится именно tls; `pkg_busy` — движок занят (любой операцией: он откажет в новой).
	if [ -f "$ENODIA_DIR/packages.sh" ]; then
		_ibj=$(sh "$ENODIA_DIR/packages.sh" busy tls 2>/dev/null); _ibc=$?
		[ "$_ibc" = 0 ] && pkb=true
		case "$_ibj" in *'"mine":true'*) _imine=1 ;; esac
		[ "$pkb" = true ] && [ "$_imine" = 1 ] && ing=true
		# rc=2 — СТАРАЯ копия движка, верба не знает: тогда прежний признак, байт-в-байт.
		# Обновление пофайловое, и пара «новый web-ui + старый packages.sh» реальна; без этой
		# ветки карточка в такой паре звала бы «Установить» поверх идущей установки.
		if [ "$_ibc" = 2 ] && [ -f /tmp/enodia-proto-install.pid ]; then
			[ -d "/proc/$(cat /tmp/enodia-proto-install.pid 2>/dev/null)" ] && { ing=true; pkb=true; }
		fi
	fi
	# jesc вместо прежнего «вырезать кавычки + cut -c»: тот резал БАЙТАМИ (лог по-русски ⇒ обрыв
	# посреди буквы) и не снимал сырой TAB. Одна копия на проект — json-lib.sh; шим ниже у либы.
	# Строка лога — только когда последняя операция НАША (при провале в ней причина); у чужой это строка про другой протокол.
	# Старый движок (rc=2, плана нет) — как раньше: строка есть.
	if [ "$_imine" = 1 ] || [ "${_ibc:-}" = 2 ]; then
		[ -f "$ENODIA_STATE/.proto-install.log" ] && imsg=$(tail -n1 "$ENODIA_STATE/.proto-install.log" 2>/dev/null | jesc 160)
	fi
	# Второй фактор входа живёт в totp.sh — он и отдаёт свой срез. Своей копии «включено/сколько
	# кодов осталось» тут нет по той же причине, что и у TLS: две копии состояния разъезжаются.
	tf=""
	[ -f "$ENODIA_DIR/totp.sh" ] && tf=$(sh "$ENODIA_DIR/totp.sh" status 2>/dev/null | grep '^{' | tail -1)
	[ -n "$tf" ] || tf='{"on":false,"pending":false,"clock":true,"recovery":0,"sessions":0,"lock":0,"engine":false}'
	printf '{"up":%s,"lan":"%s","port":%s,"installed":%s,"cert":%s,"tls_on":%s,"tls_running":%s,"tls_why":"%s","tls_port":%s,"wan_on":%s,"wan_rule":%s,"wan_limits":%s,"wan_kind":"%s","wan_addr":"%s","installing":%s,"pkg_busy":%s,"install_msg":"%s","totp":%s}\n' \
		"$up" "$LISTEN" "$PORT" "$ti" "$cert" "$to" "$tr_" "$twhy" "$(tls_port)" "$wo" "$wr" "$wl" "$wkind" "$waddr" "$ing" "$pkb" "$imsg" "$tf"
}

setpass() {
	pass="$1"; _sp_flag="$2"
	# `setpass --no-restart` БЕЗ ПАРОЛЯ — флаг, а не пароль: 12 символов проходят проверку формы, и паролем панели молча
	# становилась строка «--no-restart» (usage сам подсказывает форму `setpass [пароль] [--no-restart]`; ревью шага 8a).
	# Флаг — только ОДИН: `setpass --no-restart --no-restart` (так панель передала бы такой пароль) — это пароль и флаг.
	if [ "$pass" = "--no-restart" ] && [ -z "$_sp_flag" ]; then pass=""; _sp_flag="--no-restart"; fi
	# БЕЗ ПАРОЛЯ В АРГУМЕНТЕ — СПРАШИВАЕМ САМИ. Так его подсказывают форма входа и отказ cgi-bin/login («забыли пароль»):
	# пароль в argv виден в /proc и оседает в истории шелла, а без кавычек ash его ещё и портит молча (`Pa$$w0rd` → PID
	# вместо `$$`, `my pass` → `my`) — человек получал «пароль панели задан» и оставался снаружи. С терминала — скрытым
	# вводом дважды (`read -s`: stty в busybox роутера НЕТ, замер 24.09.2026); без терминала — одной строкой со stdin.
	if [ -z "$pass" ]; then
		if [ -t 0 ]; then
			printf 'Новый пароль панели: '; IFS= read -r -s pass; echo
			printf 'Ещё раз: '; IFS= read -r -s _sp_again; echo
			[ -n "$pass" ] || { echo "пароль не введён — пароль НЕ сменён"; return 1; }
			[ "$pass" = "$_sp_again" ] || { echo "пароли не совпадают — пароль НЕ сменён"; return 1; }
		else
			# Терминала нет (`ssh роутер 'команда'` без -t, труба) — скрыть ввод и спросить второй раз нечем. Говорим это В stderr:
			# человек иначе смотрел бы на пустой курсор, а скрипту, подающему пароль трубой, строка не мешает.
			echo "терминала нет — пароль читаю одной строкой со stdin, без скрытия и без повтора (скрытый ввод — по ssh с терминалом: ssh -t)" >&2
			IFS= read -r pass || true
			[ -n "$pass" ] || { echo "пароль не получен: stdin пуст — пароль НЕ сменён (с терминалом команда спросит его сама: sh ${ENODIA_BOOT:-/data/usr/app/enodia-boot}/boot.sh web-ui.sh setpass)"; return 1; }
		fi
	fi
	# ФОРМА ПАРОЛЯ — ЗДЕСЬ, у владельца записи, и на ЛЮБОМ пути: панель (cgi-bin/action) и ПК (enodia.py, PANEL_PW_RE)
	# проверяют то же правило сами, а ввод с терминала не проверял никто — пароль с пробелом или кириллицей записывался,
	# и войти им было нельзя (форма входа кириллицу не отправит вовсе).
	# grep судит ПОСТРОЧНО — пароль с переводом строки (аргументом) иначе прошёл бы по своей годной строке целиком.
	case "$pass" in *'
'*) echo "пароль: одна строка, без перевода строки — пароль НЕ сменён"; return 1 ;; esac
	printf '%s' "$pass" | grep -qE '^[!-~]{8,64}$' || { echo "пароль: 8..64 символов, латиница/цифры/знаки, без пробелов — пароль НЕ сменён"; return 1; }
	# Хэш, соль и файл — у totp.sh (pw_set): $6$ от openssl с солью из /dev/urandom, где он есть,
	# иначе фолбэк $1$ и
	# `uhttpd -m`, запись атомарная в 600. Прежний файл Basic сносит НЕ он, а pw_migrate. Сверяет
	# тот же файл cgi-bin/login на КАЖДОМ входе — перезапуск панели НЕ нужен. Пароль приходит от
	# вызывателей (enodia.py, action — они проверяют форму и сами) либо с терминала/stdin (проверка выше).
	command -v pw_set >/dev/null 2>&1 || { echo "нет totp.sh (обновите панель)"; return 1; }
	# «ПАРОЛЬ ТОТ ЖЕ?» — спрашиваем ДО записи (после неё старый хэш уже не у кого спросить), и
	# «спросить нечем» считаем ТЕМ ЖЕ паролем: без pw_verify (смешанная выкладка — новый
	# web-ui.sh, старый totp.sh) гашение сработало бы у того, кто просто переустановил систему
	# с прежним паролем. Код 2 («пароля ещё нет») — наоборот, «другой»: гасить там нечего, и
	# ветка ниже всё равно требует непустой файл сессий.
	_sp_same=1; command -v pw_verify >/dev/null 2>&1 && { pw_verify "$pass" || _sp_same=0; }
	pw_set "$pass" || { echo "не удалось записать хэш пароля"; return 1; }
	echo "пароль панели задан"
	# СМЕНА ПАРОЛЯ ГАСИТ ВСЕ ВХОДЫ. Панельная ветка (cgi-bin/action) оставляет своё устройство —
	# там человек стоит за гейтом и сам себя выкидывать не должен. Здесь «своего» нет: сюда приходят
	# с ПК, из мастера и по SSH, и приходят чаще всего ровно с мыслью «пароль мог утечь». Оставить
	# чужие куки живыми значило бы, что пароль сменили, а доступ у того, кого боятся, остался — с
	# «Запомнить меня» это ГОД. Первичная установка от этого не страдает: гасить там нечего.
	# ИЗ ПАНЕЛИ СЮДА НЕ ЛЕЗЕМ: там (cgi-bin/action) сессии гасит своя строка, которая ОСТАВЛЯЕТ
	# текущее устройство — иначе человек выкидывал бы сам себя тем же кликом, которым сменил пароль.
	# «МЫ ИЗ ПАНЕЛИ» — ЛЮБОЙ ИЗ ДВУХ ПРИЗНАКОВ (флаг `--no-restart` ИЛИ окружение CGI), и это
	# осознанно консервативно: панель шлёт оба, а путь, где доехал только один (отладка по SSH,
	# фоновая задача с вычищенным окружением), получил бы массовый разлогин, которого не заказывал.
	# И ГЛАВНОЕ: гасим ТОЛЬКО когда пароль ДЕЙСТВИТЕЛЬНО другой. Сюда приходит и «переустановить/
	# починить» с ПК, где человек вводит ТОТ ЖЕ пароль, — выкидывать за это телефон и планшет не за
	# что. Сверку делаем ДО записи: после неё старый хэш уже не спросишь.
	if [ "$_sp_flag" != "--no-restart" ] && [ -z "${GATEWAY_INTERFACE:-}" ] && [ "$_sp_same" != 1 ] &&
	   command -v totp_sess_clear >/dev/null 2>&1 && [ -s "$TOTP_SESS" ]; then
		totp_sess_clear && echo "вошедшие устройства разлогинены (пароль сменился)"
	fi
	# Единственный случай, когда перезапуск всё же нужен: живой uhttpd поднят ещё С HTTP-Basic
	# (кодом до формы входа) — браузер спрашивал бы пароль дважды, и первый раз — старый. Из CGI
	# не перезапускаем (мы его потомок, унесли бы собственный ответ): это сделает cron-овский start.
	if [ "$_sp_flag" = "--no-restart" ] || [ -n "$GATEWAY_INTERFACE" ]; then return 0; fi
	if basic_running; then echo "снимаю HTTP-Basic (вход теперь формой) — перезапуск"; stop >/dev/null 2>&1; start; fi
}

# uhttpd поднят ещё с Basic? ` -c ` в его cmdline (NUL-разделённой).
basic_running() {
	is_running || return 1
	tr '\0' ' ' 2>/dev/null < "/proc/$(cat "$PIDFILE" 2>/dev/null)/cmdline" | grep -q ' -c '
}

# ПОЧЕМУ панель не поднялась. `start-stop-daemon -b` заворачивает stdio демона в /dev/null
# (грабля проекта: «в логе пусто» ≠ «ошибок нет»), поэтому настоящая причина до сих пор
# терялась, а наверх уезжало голое «не удалось поднять uhttpd» — с ним нечего делать ни
# тестеру, ни ПК-скрипту, ни установщику, который зовёт нас последним шагом. Судим по ФАКТАМ,
# а последним шагом спрашиваем сам uhttpd: гоняем его пару секунд В ПЕРЕДНЕМ ПЛАНЕ (порт
# заведомо свободен — фоновая попытка только что провалилась) и ловим stderr.
# Аргументы приходят ТЕ ЖЕ, что уехали в start-stop-daemon ("$@" от start): вторая копия
# строки запуска разъехалась бы с первой, и диагностика начала бы врать.
start_why() {
	# №1 по частоте: адреса ещё нет. LISTEN берётся из br-lan, а на буте бридж поднимается
	# позже нас — uhttpd молча падает на bind. Тот же случай — смена LAN-подсети роутера.
	if ! ip -4 addr show 2>/dev/null | grep -q "inet ${LISTEN}[/ ]"; then
		echo "адреса $LISTEN нет ни на одном интерфейсе — сеть ещё не поднялась или LAN-IP роутера сменился"
		return 0
	fi
	_wb=$(netstat -ltn 2>/dev/null | grep "[.:]$PORT " | head -1)
	if [ -n "$_wb" ]; then
		echo "порт $PORT уже занят другим процессом ($_wb)"
		return 0
	fi
	_we=$(timeout -t 2 "$UHTTPD" "$@" 2>&1 | grep -v '^[[:space:]]*$' | head -2 | tr '\n' ' ')
	[ -n "$_we" ] && { echo "uhttpd отказался стартовать: $_we"; return 0; }
	echo "вручную uhttpd стартует, а фоновый запуск не удержался — проверьте $PIDFILE и место в /tmp"
}

start() {
	[ -x "$UHTTPD" ] || { echo "нет $UHTTPD"; return 1; }
	[ -f "$DOCROOT/index.html" ] || { echo "нет $DOCROOT/index.html"; return 1; }
	# Пароль — у владельца (totp.sh): миграция прежнего web/uhttpd.conf в .panel-pass бежит ЗДЕСЬ
	# (start зовёт cron каждые 5 минут — обновление доедет само), а панель без пароля не отдаём.
	command -v pw_migrate >/dev/null 2>&1 || { echo "нет totp.sh — обновите панель"; return 1; }
	# СКАЧОК ЧАСОВ (RTC нет; сток ставит время по mtime, NTP приходит через ~13 минут и прыгает
	# вперёд) убивает сессии, выданные в это окно: метка «истекает» посчитана от ложного «сейчас».
	# Чинит totp.sh, а зовём ОТСЮДА — это единственная наша цель, которую cron дёргает раз в пять
	# минут, то есть починка успевает к первому же тику после синхронизации.
	command -v totp_sess_clock_fix >/dev/null 2>&1 && totp_sess_clock_fix
	pw_migrate >/dev/null 2>&1 || true
	# ПРОВАЛ МИГРАЦИИ НЕ ИМЕЕМ ПРАВА ПРОГЛОТИТЬ, и судим о нём ПО ФАКТУ — лежит ли ещё прежний файл
	# Basic в докруте. Почему не по коду `pw_migrate`: `pw_exists` ниже смотрит И в него, поэтому при
	# непрошедшей записи `.panel-pass` (кончилось место на 20-МБ /data — у нас это штатная беда) он
	# всё равно скажет «пароль есть», старт продолжится, uhttpd встанет БЕЗ `-c`, и хэш пароля начнёт
	# отдаваться СТАТИКОЙ любому в локалке — ровно та утечка, ради которой файл и сносят, только молча.
	# А УДАЛИТЬ его до переноса нельзя: в нём тогда ЕДИНСТВЕННАЯ копия пароля, и «почистили» означало
	# бы «панель потеряна навсегда». Поэтому: перенос не состоялся — отказ и причина вслух.
	# Путь спрашиваем у владельца ($TOTP_LEGACY_PASS в totp.sh) — своей копии имени здесь не держим.
	if [ -n "${TOTP_LEGACY_PASS:-}" ] && [ -e "$TOTP_LEGACY_PASS" ]; then
		# ПУСТОЙ легаси-файл (обрыв прежней записи) — не «перенос не удался», а «переносить нечего»:
		# судим о наличии пароля тем же `-s`, что и pw_stored, иначе человек получил бы совет чинить
		# место на флеше вместо действенного «задай пароль».
		if [ -s "$TOTP_LEGACY_PASS" ] && [ ! -s "$TOTP_PASS" ]; then
			echo "пароль не перенесён в $TOTP_PASS (место на /data?) — без переноса панель отдала бы хэш статикой, не поднимаю"; return 1
		fi
		rm -f "$TOTP_LEGACY_PASS" 2>/dev/null
		[ -e "$TOTP_LEGACY_PASS" ] && { echo "не убрать $TOTP_LEGACY_PASS — хэш пароля утёк бы статикой, панель не поднимаю"; return 1; }
	fi
	pw_exists || { echo "сначала задайте пароль: sh ${ENODIA_BOOT:-/data/usr/app/enodia-boot}/boot.sh web-ui.sh setpass"; return 1; }
	# ВАЖНО: при живом uhttpd не выходим, а идём дальше к tls_start — этот же start зовёт
	# cron каждые 5 минут, и он обязан лечить ОБА процесса, а не только первый. Сюда же прицеплен
	# переигрыш WAN-правила: его смывает fw3 reload, и другого сторожа у него нет.
	if is_running; then
		# Живой uhttpd ещё с HTTP-Basic (` -c ` в cmdline — поднят кодом до формы входа): браузер
		# спрашивал бы пароль ДВАЖДЫ, и первый раз — старый. Перезапускаем без -c; из CGI нельзя
		# (мы его потомок — унесём собственный ответ), это сделает cron-овский start.
		if basic_running && [ -z "$GATEWAY_INTERFACE" ]; then
			echo "снимаю HTTP-Basic (вход теперь формой) — перезапуск"; stop >/dev/null 2>&1
		else
			echo "уже работает (pid $(cat "$PIDFILE"))"; tls_start; wan_rule_apply; return 0
		fi
	fi
	[ -f "$PIDFILE" ] && : > "$PIDFILE"
	# -i .html=htmlwrap — отдавать ДОКУМЕНТ панели с `Cache-Control: no-cache` (заголовков у uhttpd
	# нет, но есть интерпретатор по расширению). Без этого браузер кэширует index.html эвристически
	# и после обновления держит СТАРЫЙ документ со СТАРОЙ ссылкой `?v=` ⇒ «фича не приехала»,
	# невоспроизводимо (поймано на железе 2026-07-21). Подробности — в шапке web/htmlwrap.
	# Нет файла (установка старее фичи) → стартуем как раньше, панель важнее заголовка.
	[ -x "$DOCROOT/htmlwrap" ] && set -- -i ".html=$DOCROOT/htmlwrap" || set --
	# -t/-T подняты над дефолтами uhttpd (60 с скрипт, 30 с сеть) РАДИ ОДНОГО потребителя —
	# `cgi-bin/diag?full=1`: он собирает архив с логами синхронно, и это единственная страница
	# панели, которая заведомо думает десятки секунд (замер на BE7000 — 19 с, на armv7 дольше).
	# Сетевой таймаут важен не меньше скриптового: до первого байта tar клиент ждёт молча, а
	# 30-секундный дефолт рвал бы соединение ровно на слабом роутере, где архив и нужен.
	# ПОТОЛОК задаёт именно -T, а не -t: молчащий CGI умрёт на 120 с, до 180 не дойдёт никогда
	# (по HTTPS та же цифра — IDLE_TO в panel-tls.c). Понадобится больше — поднимать ВСЕ ТРИ.
	# Полный список аргументов собираем В "$@" ОДИН раз — его же дословно повторяет диагностика
	# отказа (start_why гоняет uhttpd в переднем плане теми же ключами).
	# БЕЗ -c/-r: пароль сверяет cgi-bin/login (totp.sh), uhttpd отдаёт статику всем — секретов в
	# ней нет, а данные и действия закрыты гейтом сессии в каждом CGI. Вернуть -c нельзя: с $6$
	# uhttpd умирает на первом входе (C38 сторожит именно эту строку).
	set -- -f -h "$DOCROOT" -x /cgi-bin \
		-t 180 -T 120 \
		-p "$LISTEN:$PORT" -I index.html -D -S "$@"
	start-stop-daemon -S -b -m -p "$PIDFILE" -x "$UHTTPD" -- "$@"
	sleep 1
	if is_running; then echo "поднят: http://$LISTEN:$PORT  (pid $(cat "$PIDFILE"))"
	else echo "не удалось поднять uhttpd: $(start_why "$@")"; return 1; fi
	tls_start
	wan_rule_apply
}

stop() {
	wan_rule_clear     # порт наружу без живой панели не держим (флаг остаётся — start вернёт)
	tls_stop           # сперва терминатор: без бэкенда он всё равно бесполезен
	if is_running; then
		start-stop-daemon -K -p "$PIDFILE" -x "$UHTTPD" 2>/dev/null
		# Сигнал ушёл — это ещё не выход: за stop идут бинд того же порта (restart) и снос docroot с настройками (смена раскладки),
		# и живой ещё сервер отвечал из полуснесённого каталога «нужен вход» (разбор у daemon_wait_gone).
		daemon_wait_gone "$pid" 5
		: > "$PIDFILE"
		echo "остановлен"
	else
		echo "не запущен"
	fi
}

tls_on() {
	port="$1"
	[ -n "$port" ] || port=$(tls_port)
	port=$(port_norm "$port") || { echo "порт — число от 1 до 65535"; return 1; }
	[ "$port" = "$PORT" ] && { echo "порт $port занят самой панелью"; return 1; }
	[ -x "$TLS_BIN" ] || { echo "нет $TLS_BIN (обновите установку)"; return 1; }
	tls_port_foreign "$port" && { echo "порт $port уже занят другой службой роутера — выберите другой"; return 1; }
	# ТОТ ЖЕ ПОРТ У ЖИВОГО — БЕЗ ПЕРЕЗАПУСКА (ревью шага 7a, круг 3): перезапуск рвал все HTTPS-сессии, включая входы снаружи, ради
	# «переноса», которого не было. Правило наружу и защиту ответов — сверить (дёшево и идемпотентно).
	if tls_running && [ "$port" = "$(tls_port)" ]; then
		wan_rule_apply >/dev/null 2>&1; panel_guard_move "$port" "$port"
		echo "HTTPS уже работает на порту $port"; return 0
	fi
	_gold=""; tls_enabled && _gold=$(tls_port)
	# Прежний ЖИВОЙ порт помним: не встал терминатор на новом — возвращаем прежний, а не оставляем панель без HTTPS (и без входа
	# снаружи) до ручной починки. Не было живого — флаг остаётся: cron вернётся, когда причина уйдёт (часы, сертификат).
	_old=""; tls_running && _old=$(tls_port)
	echo "$port" > "$TLS_FLAG"
	tls_stop >/dev/null 2>&1     # порт мог смениться — поднимаем заново
	# ПРИЧИНА ОТКАЗА — ПОСЛЕДНЕЙ СТРОКОЙ (ревью шага 7a, круг 2): её читает панель (`panel_tls_on` берёт последнюю строку), а
	# после неё шли замечания `wan_rule_apply` («ВНИМАНИЕ: ограничитель…», «WAN-интерфейс не определён») — и человек читал их
	# вместо «часы не синхронизированы». Поэтому вывод подъёма держим и печатаем причину в самом конце.
	_rc=0; _st=$(tls_start 2>&1) || _rc=1
	[ "$_rc" = 0 ] && [ -n "$_st" ] && echo "$_st"
	if [ "$_rc" != 0 ] && [ -n "$_old" ] && [ "$_old" != "$port" ]; then
		echo "$_old" > "$TLS_FLAG"; tls_start >/dev/null 2>&1 && echo "вернул прежний порт $_old"
	fi
	wan_rule_apply               # порт открыт наружу — правило пересобрать под ТОТ порт, что слушает терминатор
	panel_guard_move "$_gold" "$(tls_port)"
	[ "$_rc" = 0 ] || printf '%s\n' "$_st" | tail -n 1
	return "$_rc"
}

# ОТВЕТЫ ПАНЕЛИ МИМО ТУННЕЛЯ (panel-guard в mark-core.sh: `mangle OUTPUT --sport <порт TLS> -j ACCEPT`). Ставит его ядро на каждом
# переигрыше, а зовут ядро лишь смена транспорта, repair и бут — и смена порта HTTPS (или первое включение) оставляла защиту на
# старом порту или без неё: ответы клиентам из iplist_set метились в туннель, снаружи соединение висло при зелёном «открыт» (ревью
# шага 7a, круг 3). Здесь — только ПЕРЕСТАНОВКА: старое снять, новое поставить, если маркировка ядра сейчас есть (`-j MARK` в
# mangle OUTPUT); без неё гард не нужен, а ядро при следующем переигрыше само поставит его по флагу.
panel_guard_move() {   # $1 — прежний порт (пусто — не было), $2 — новый (пусто — HTTPS выключен)
	if [ -n "$1" ]; then while iptables -t mangle -D OUTPUT -p tcp --sport "$1" -j ACCEPT 2>/dev/null; do :; done; fi
	[ -n "$2" ] || return 0
	iptables -t mangle -S OUTPUT 2>/dev/null | grep -q -- '-j MARK' || return 0
	iptables -t mangle -C OUTPUT -p tcp --sport "$2" -j ACCEPT 2>/dev/null || iptables -t mangle -I OUTPUT 1 -p tcp --sport "$2" -j ACCEPT 2>/dev/null
	return 0
}

# ПЕРЕВЫПУСК СЕРТИФИКАТА — терминатор поднимается заново, и правило наружу обязано судить о НЁМ (ревью шага 7a, круг 2): прежний
# верб правило не трогал, и не вставший терминатор до пяти минут стоял за открытым портом.
tls_cert_renew() {
	# Рабочий сертификат НЕ стираем, пока новый не выписан (ревью шага 7a, круг 3): перевыпуск при несинхронизированных часах оставлял
	# роутер без сертификата вовсе, и первый же перезапуск терминатора до синхронизации ронял HTTPS и вход снаружи.
	[ -s "$TLS_CERT" ] && mv -f "$TLS_CERT" "$TLS_CERT.old"
	[ -s "$TLS_KEY" ] && mv -f "$TLS_KEY" "$TLS_KEY.old"
	_rc=0
	if tls_ensure_cert; then
		rm -f "$TLS_CERT.old" "$TLS_KEY.old"
		tls_stop >/dev/null 2>&1; tls_start || _rc=1
	else
		_rc=1
		[ -s "$TLS_CERT.old" ] && mv -f "$TLS_CERT.old" "$TLS_CERT"
		[ -s "$TLS_KEY.old" ] && mv -f "$TLS_KEY.old" "$TLS_KEY"
	fi
	wan_rule_apply >/dev/null 2>&1
	return "$_rc"
}

# Сертификат на диске сменился (импорт бэкапа) — терминатор держит прежний в памяти, пока не перезапущен. Не бежит — нечего
# перечитывать: включение HTTPS возьмёт то, что лежит. Правило входа снаружи — следом, как у перевыпуска (оно сверяет живой порт).
tls_reload() {
	tls_running || return 0
	tls_stop >/dev/null 2>&1
	_rc=0; tls_start || _rc=1
	wan_rule_apply >/dev/null 2>&1
	return "$_rc"
}

# Выключение HTTPS снимает и доступ снаружи, причём ВМЕСТЕ с флагом: иначе следующий tls-on
# молча вернул бы панель в интернет — неожиданное самораскрытие хуже лишнего клика.
tls_off() {
	wan_enabled && { wan_off; echo "(доступ снаружи снят вместе с HTTPS)"; }
	tls_enabled && panel_guard_move "$(tls_port)" ""
	tls_stop
	rm -f "$TLS_FLAG"
	echo "HTTPS выключен"
}

case "$1" in
	start)     start ;;
	stop)      stop ;;
	restart)   stop; start ;;
	setpass)   setpass "$2" "$3" ;;
	haspass)   pw_exists ;;        # код 0 — пароль задан (ПК при переустановке: Enter = «оставить прежний»)
	tls-on)    tls_on "$2" ;;
	tls-off)   tls_off ;;
	tls-cert)  tls_cert_renew ;;
	tls-reload) tls_reload ;;      # перечитать сертификат с диска (импорт бэкапа привёз свой)
	tls-running) tls_running ;;    # код 0 — терминатор бежит; пидфайл знает только этот файл
	wan-on)    wan_on "$2" ;;      # "$2" = --force: открыть порт БЕЗ второго фактора (только из CLI)
	wan-off)   wan_off ;;
	wan-rule)  wan_rule_apply ;;   # ручной переигрыш (после fw3 reload), тот же путь, что из start
	wan-enabled) wan_enabled ;;    # код 0 — вход снаружи включён (флаг); путь флага знает только этот файл
	json)      cmd_json ;;         # состояние для панели (cgi-bin/data?section=panel_access)
	status|"") if is_running; then echo "работает (pid $(cat "$PIDFILE")) на http://$LISTEN:$PORT"; else echo "не запущен"; fi
	           if tls_enabled; then
	                   if tls_running; then echo "HTTPS: работает (pid $(cat "$TLS_PID")) на https://$LISTEN:$(tls_port)"
	                   else echo "HTTPS: включён, но НЕ работает (порт $(tls_port); см. $TLS_LOG)"; fi
	           else echo "HTTPS: выключен"; fi
	           if wan_enabled; then
	                   v=$(wan_verdict); set -- $v
	                   if wan_rule_active; then st="правило стоит"; else st="ВКЛЮЧЁН, но правила НЕТ (fw3 смыл?)"; fi
	                   case "$1" in
	                           public)  echo "Снаружи: $st — https://$2:$(tls_port)" ;;
	                           private) echo "Снаружи: $st, но WAN-адрес $2 приватный — извне не достучаться" ;;
	                           *)       echo "Снаружи: $st, WAN-адрес не определён" ;;
	                   esac
	           else echo "Снаружи: закрыт"; fi
	           # Второй фактор (totp.sh) — печатаем и здесь: это первое, что смотрят по SSH, когда
	           # «панель просит какой-то код». Аварийное отключение: sh totp.sh disable --force
	           if [ -f "$ENODIA_DIR/totp.sh" ]; then
	                   case "$(sh "$ENODIA_DIR/totp.sh" status 2>/dev/null)" in
	                           *'"on":true'*) echo "Второй фактор (TOTP): включён" ;;
	                           *)             echo "Второй фактор (TOTP): выключен" ;;
	                   esac
	           fi ;;
	# Руками скрипт зовут ТОЛЬКО через бутстрап (он один экспортирует пути) — так и подсказываем, а не прямым `$0`.
	*) echo "usage: sh ${ENODIA_BOOT:-/data/usr/app/enodia-boot}/boot.sh web-ui.sh {start|stop|restart|status|setpass [пароль] [--no-restart]|tls-on [порт]|tls-off|tls-cert|wan-on [--force]|wan-off|wan-rule|json}"; exit 1 ;;
esac
