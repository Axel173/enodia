#!/bin/sh
# doh-lib.sh — ОБЩИЙ слой «шифрованный DNS» (DoH) для всех транспортов/режимов.
# СОРСИТСЯ (не исполняется): dns-настройщики транспортов зовут отсюда supervise-хелперы,
# cgi-bin/data|action — читалки состояния. Ноль сайд-эффектов при простом `. doh-lib.sh`.
#
# ЗАЧЕМ отдельный слой (а не 5-я ветка транспорта): DNS во ВСЕХ режимах должен ходить одной
# дорогой — при включённом DoH dnsmasq форвардит на локальный https_dns_proxy (127.0.0.1:5053),
# а тот резолвит по HTTPS/2 к выбранному резолверу. Это закрывает последний плейн-хоп
# VPS→резолвер (tunnel-режимы awg/xray/hy2) и plain UDP:53→ISP-спуф (прямые zapret/byedpi/
# fail-open). По умолчанию ВЫКЛ — тогда каждый транспорт держит прежнее поведение байт-в-байт.
# Полный план интеграции (шаги B–F) — заметки разработки «DoH-план».
#
# ГРАБЛИ спайка (2026-07-19, железо✔ BE7000) вшиты в doh_start/doh_stop ниже:
#  - `-4` ОБЯЗАТЕЛЕН: нет IPv6-аплинка ⇒ AAAA-путь резолвера = мгновенный EACCES «after 1ms».
#  - IP-литеральный резолвер (cloudflare `https://1.1.1.1/dns-query`) убирает bootstrap-резолв
#    вовсе; hostname-резолверы (google/quad9/adguard/nextdns) делают ОДИН плейн :53-lookup через
#    `-b <bootstrap>` при старте — компромисс осознан, дефолт=cloudflare без утечки.
#  - ДВЕ РАЗНЫЕ сборки бинаря (см. заметки разработки «DoH-план»), рантайм об этом знать не обязан:
#    arm64 (BE7000/AX3600) — ДИНАМИКА против стоковых libcurl/c-ares/libev, 20 КБ; портативность
#    между ядрами 5.4/4.4 дал отказ от `curl_url*` (≥7.62) в hostname_from_url. armv7 (BE3600/
#    BE6500) — ПОЛНЫЙ СТАТИК (mbedTLS+nghttp2+c-ares+libev внутри), 563 КБ: железки в руках нет,
#    а значит неизвестны ни интерпретатор musl, ни версии стоковых .so — статик снимает вопрос.
#  - `-C <ca-bundle>` ОБЯЗАТЕЛЕН для статик-сборки: у неё нет вкомпилированного CA-пути (curl
#    определяет его только при нативной сборке) ⇒ без него сертификат резолвера не проверить.
#    Путь ищем на месте (doh_ca_file) — стоковому arm64-curl он тоже не мешает (тот же файл).
#  - busybox `start-stop-daemon -K` пишет результат в STDOUT ⇒ глушим (иначе строка рвёт JSON
#    зовущего CGI). Нет nohup/setsid ⇒ фон только через `start-stop-daemon -b`, `-m -p` обязательны.

: "${ENODIA_DIR:=/data/usr/app/enodia}"
: "${ENODIA_BIN:=/data/usr/app/enodia-bin}"
: "${ENODIA_STATE:=/data/usr/app/enodia-state}"

# Где лежит бинарь (store-lib.sh): без внешнего накопителя — прежний плоский путь в $ENODIA_DIR
# байт-в-байт (install.sh переносит из стейджа bin/*.user). Шим на случай установки без lib.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Ожидание СТАРТА демона (daemon-lib.sh). «Дождаться, пока поднятый демон станет готов» — один
# вопрос на проект: у несущих это socks, здесь UDP-порт резолвера. Вторая реализация разошлась бы
# с первой (у нас это уже случалось с resolve_ipv4 и probe_ext_ip). Нет файла (частичный
# apply-scripts) — шим повторяет ПРЕЖНИЙ путь байт-в-байт: фиксированный потолок + свой гард жизни.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v daemon_wait_uport >/dev/null 2>&1 || daemon_wait_uport() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do
        netstat -lnu 2>/dev/null | grep -q "$4:$5 " && return 0
        _dwp=$(cat "$1" 2>/dev/null); [ -d "/proc/${_dwp:-none}" ] || break
        sleep 1; _dwi=$((_dwi+1))
    done
    DAEMON_WAIT_WHY="порт $5 не появился за $_dwi с (или процесс умер)"; return 1; }

# Свой резолвер (`custom`) требует ДВУХ чужих умений, и оба уже написаны — копий не заводим:
# резолв его ИМЕНИ мимо туннеля/через DoH-по-IP (dns-lib: на буте системный резолвер заперт в
# ещё не поднятую несущую) и возраст отметки с поправкой на скачок часов (clock-lib). Обе
# библиотеки — чистые наборы функций без глобальных присваиваний, сорсить их сюда безопасно.
# Шимы = прежнее поведение при частичной установке: без dns-lib якоря своего резолвера просто
# не переоткрываются (каталожные резолверы от этих библиотек не зависят вовсе).
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# Устройство несущей (`default` в table 1000) — у владельца ip-lib.sh::carrier_iface (следит C81):
# по нему doh_direct_regime судит «прямой ли режим». Шим той же строки — на случай частичной установки.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v carrier_iface >/dev/null 2>&1 || carrier_iface() { ip route show table 1000 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
command -v age_since >/dev/null 2>&1 || age_since() {
	case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
	[ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
DOH_BIN=$(bin_path https-dns-proxy)  # рантайм-бинарь https-dns-proxy (стейдж bin/https-dns-proxy.user)
DOT_BIN=$(bin_path dot-proxy)        # DoT-альтернатива (наш mbedTLS-статик, RFC 7858; стейдж bin/dot-proxy.user)
# DoQ and DoH3 (RFC 9250, RFC 8484 over HTTP/3) — our quic-dns-proxy, its own component («DoQ и DoH3») on its own TLS stack (wolfSSL):
# QUIC needs a TLS library with a QUIC API, which the mbedTLS of the two above has not (dev notes «DoQ-DoH3-дизайн» §1).
QUIC_BIN=$(bin_path quic-dns-proxy)
DOH_ADDR="127.0.0.1"
DOH_PORT="5053"
DOH_PID="/tmp/enodia-doh.pid"      # /tmp=RAM ⇒ демон переигрывается heal-ом на буте (как прочие альты)
DOH_LOG="/tmp/enodia-doh.log"
DOH_LOG_MAX=524288                 # порог ротации, байт (см. doh_log_rotate)
DOH_LOG_KEEP=131072                # сколько ХВОСТА оставляем при ротации
DOH_UPSTREAM="$DOH_ADDR#$DOH_PORT" # токен для dnsmasq `server=` (зовёт step-B dns_set_upstream)

# --- Состояние (персист на /data, переживает ребут) ---
#   .doh-on         — тумблер ("on" = включён ВСЕГДА, в любом режиме; иначе выкл)
#   .doh-auto       — авто-режим ("off" = запрещён; ЛЮБОЕ другое/отсутствие = разрешён, деф. ВКЛ)
#   .doh-proto      — протокол шифрования: doh (HTTPS/:443, деф.) | dot (TLS/:853, dot-proxy) | odoh | doq (QUIC/udp 853) |
#                     doh3 (HTTP/3, udp 443) — the last two by quic-dns-proxy
#   .doh-resolver   — имя резолвера из каталога (деф. cloudflare)
#   .doh-nextdns-id — профиль NextDNS (только при resolver=nextdns; в DoT едет внутри SNI)
#   .doh-custom-url — DoH-URL СВОЕГО резолвера (только при resolver=custom)
#   .doh-custom-sni — его же имя для DoT (пусто = введён IP-литерал ⇒ DoT недоступен)
#   .doh-custom-ips — ЯКОРНЫЕ адреса своего резолвера, по одному в строке (см. doh_custom_refresh)
# --- Рантайм (/tmp = RAM, переигрывается на буте) ---
#   $DOH_AUTO_STAMP     — «DNS сейчас держит АВТО-DoH» (тумблер выключен, но режим прямой). Нужен
#                         keepalive-ам (watchdog/heal): без него doh_enabled=false и упавший прокси
#                         никто бы не поднял, а dnsmasq продолжал бы стучать в мёртвый :5053.
#   $DOH_HEALTH_STAMP   — когда в последний раз щупали живость авто-DoH (троттл, см. doh_health_tick)
#   $DOH_HEALTH_MISS    — промахов пробы ПОДРЯД (успех обнуляет)
#   $DOH_AUTO_COOLDOWN  — до какой отметки времени авто-режим не пере-взводим после отката
#   $DOH_DOT_FALLBACK   — «выбран DoT, а порт 853 через текущий путь не проходит ⇒ прокси шифрует по
#                         DoH того же резолвера» (эпоха переезда; см. doh_proto_now и doh_dot_fallback)
#   $DOH_PORT_STAMP     — когда в последний раз сверяли порт DoT на текущем пути (троттл doh_port_tick)
DOH_AUTO_STAMP="/tmp/.enodia-doh-auto-on"
DOH_HEALTH_STAMP="/tmp/.enodia-doh-health.stamp"
DOH_HEALTH_MISS="/tmp/.enodia-doh-health.miss"
DOH_AUTO_COOLDOWN="/tmp/.enodia-doh-auto-cooldown"
DOH_HEALTH_EVERY=${DOH_HEALTH_EVERY:-600}         # как часто щупаем авто-DoH (сек)
DOH_HEALTH_MISS_MAX=${DOH_HEALTH_MISS_MAX:-2}     # столько промахов ПОДРЯД = деградация, откат
DOH_COOLDOWN_SEC=${DOH_COOLDOWN_SEC:-3600}        # на сколько после отката запрещаем авто-режим
DOH_PLAIN_DNS1=${DOH_PLAIN_DNS1:-1.1.1.1}         # открытый upstream прямого режима (как в safety_off)
DOH_PLAIN_DNS2=${DOH_PLAIN_DNS2:-8.8.8.8}

# --- Протокол: doh (HTTPS/:443, дефолт) | dot (TLS/:853) | odoh (Oblivious DoH, RFC 9230 — та же программа DoH через
# ретранслятор, блок «OBLIVIOUS DoH» ниже). Один слой, один порт 5053, один pidfile — меняется ТОЛЬКО запускаемый бинарь,
# его аргументы и порт форс-марки. Whitelist как у резолвера.
# ДВА ВОПРОСА — ДВЕ ФУНКЦИИ, и путать их нельзя (разбор — у doh_dot_fallback):
#   doh_proto     — НАМЕРЕНИЕ человека (`.doh-proto`): что выбрано на экране и куда возвращаться;
#   doh_proto_now — чем прокси шифрует СЕЙЧАС. Выбран DoT, а порт 853 через текущий путь не проходит
#                   (замер 09.09.2026: у VLESS-выхода 853 не выпускает сервер, 443 идеален) ⇒ DoH ТОГО
#                   ЖЕ резолвера, пока DoT не заработает снова. Нет программы DoH — переезжать не на что.
#                   Выбран ODoH, а ни один ретранслятор не отвечает ⇒ DoH напрямую к ТОЙ ЖЕ цели (решение человека 16.10.2026:
#                   шифрование сохранено, цель видит адрес — doh_odoh_rescue), пока ретранслятор не оживёт.
# Всё, что поднимает демона и ставит правила, спрашивает doh_proto_now; экран выбора и вербы смены — doh_proto.
#                   Выбран DoQ или DoH3, а QUIC этим путём не проходит ⇒ ступень ниже на ДРУГОМ стеке TLS: DoQ → DoT → DoH, DoH3 → DoH
#                   того же резолвера (уровень `quic` лестницы, doh_lv_fallback); ступень — второе слово отметки DOH_QUIC_FALLBACK.
DOH_DOT_FALLBACK="/tmp/.enodia-dot-fallback.stamp"
DOH_ODOH_FALLBACK="/tmp/.enodia-odoh-fallback.stamp"
DOH_QUIC_FALLBACK="/tmp/.enodia-quic-fallback.stamp"   # «<epoch> <rung>»: the QUIC level moved the proxy down to <rung> (dot|doh)
doh_proto() {
	case "$(cat "$ENODIA_STATE/.doh-proto" 2>/dev/null)" in dot) echo dot ;; odoh) echo odoh ;; doq) echo doq ;; doh3) echo doh3 ;; *) echo doh ;; esac
}
doh_proto_now() {
	case "$(doh_proto)" in
		dot)  [ -f "$DOH_DOT_FALLBACK" ] && [ -x "$DOH_BIN" ] && { echo doh; return 0; }; echo dot ;;
		odoh) [ -f "$DOH_ODOH_FALLBACK" ] && { echo doh; return 0; }; echo odoh ;;
		doq|doh3)
			# On the QUIC level's rung: the one in the flag, while its program is here; a flag without a known rung (an older form,
			# a removed program) — the first rung there is; no rung at all — nowhere to be, the chosen protocol (doh_lv_rungs).
			[ -f "$DOH_QUIC_FALLBACK" ] || { doh_proto; return 0; }
			_dpnr=$(awk '{print $2; exit}' "$DOH_QUIC_FALLBACK" 2>/dev/null); _dpnl=$(doh_lv_rungs quic)
			case " $_dpnl " in *" $_dpnr "*) [ -n "$_dpnr" ] && { echo "$_dpnr"; return 0; } ;; esac
			[ -n "$_dpnl" ] && { echo "${_dpnl%% *}"; return 0; }
			doh_proto ;;
		*)    echo doh ;;
	esac
}
doh_bin_for() {
	case "${1:-$(doh_proto_now)}" in dot) echo "$DOT_BIN" ;; doq|doh3) echo "$QUIC_BIN" ;; *) echo "$DOH_BIN" ;; esac
}
# The transport under a protocol's wire — every rule of the resolver (mark, RETURN, the probe's) carries it: QUIC rides UDP.
doh_wire_l4() { case "${1:-$(doh_proto_now)}" in doq|doh3) echo udp ;; *) echo tcp ;; esac; }
# ДЕЙСТВУЮЩИЙ РЕЗОЛВЕР — тот, чьи адреса несут правила и чей URL у прокси. Выбран ODoH — псевдоимя `odoh`: адреса — все
# ретрансляторы списка и цель (doh_odoh_ips), DoH-URL — сама цель (её берёт откат «DoH напрямую к цели»). Иначе — выбор
# человека для DoH/DoT (doh_resolver_name): его ODoH не трогает, и вернуться на DoH — значит вернуться к нему.
doh_eff() { [ "$(doh_proto)" = odoh ] && echo odoh || doh_resolver_name; }

# ПОРТ И ИМЯ НА ПРОВОДЕ — ЕДИНСТВЕННЫЙ ответ «куда прокси протокола X ходит» (форс-марка/RETURN, проба провода,
# переезд порта). Прежде порт был литералом по протоколу (DoT=853, DoH=443), и свой резолвер с портом в адресе
# (`https://хост:8443/…` — AdGuard Home на нестандартном порту) получал марку и RETURN на :443, а прокси ходил на
# :8443 мимо обоих: в туннельном режиме — мимо туннеля, в прямом — под десинк (бэклог ветки fix/dot-port-fallback, (3)).
# DoH — порт из URL (https-dns-proxy берёт его оттуда же: main.c, CURLUPART_PORT); DoT — 853, у своего резолвера —
# порт из `tls://хост:порт` (doh_custom_parse кладёт его в `.doh-custom-dot-port`). $2 — имя резолвера (деф. текущий).
doh_url_port() {
	_dup=${1#https://}; _dup=${_dup%%/*}
	case "$_dup" in *:*) _dup=${_dup##*:} ;; *) _dup=443 ;; esac
	case "$_dup" in ''|*[!0-9]*) echo 443 ;; *) echo "$_dup" ;; esac
}
doh_url_host() { _duh=${1#https://}; _duh=${_duh%%/*}; printf '%s\n' "${_duh%%:*}"; }
doh_proto_port() {
	# ODoH: прокси ходит к РЕТРАНСЛЯТОРУ (запросы) и к цели (ключ) — обоим по 443: свой адрес верб берёт только без порта
	# (относительно RFC 9230 цель и так названа ретранслятору без порта).
	if [ "$1" = odoh ]; then doh_url_port "$(doh_odoh_relay_url)"; return 0; fi
	# DoQ — DoT's port (RFC 9250 took 853 over UDP; the own resolver's `tls://хост:порт` serves both), DoH3 — the URL's (the same
	# origin over HTTP/3).
	if [ "$1" = dot ] || [ "$1" = doq ]; then
		if [ "${2:-$(doh_eff)}" = custom ]; then
			_dpp=$(cat "$ENODIA_STATE/.doh-custom-dot-port" 2>/dev/null | tr -cd '0-9')
			[ -n "$_dpp" ] && { echo "$_dpp"; return 0; }
		fi
		echo 853; return 0
	fi
	_dpps=$(doh_resolver_spec "$2"); doh_url_port "${_dpps%%$(printf '\t')*}"
}
# Имя, которое прокси протокола $1 предъявляет в SNI: DoT — dot_resolver_sni, DoH — хост URL (пусто у IP-литерала:
# curl его в SNI не шлёт, и проба провода обязана вести себя так же).
doh_proto_sni() {
	if [ "$1" = dot ] || [ "$1" = doq ]; then dot_resolver_sni "$2"; return 0; fi
	# DoH3: the URL's host, and where the URL carries an IP literal (cloudflare by 1.1.1.1) — the row's DoT name: our QUIC program
	# checks the certificate by NAME (it does not match IP SANs), and the resolver serves its DoH under that name too (measured).
	if [ "$1" = doh3 ]; then
		_dpsn=$(doh_resolver_spec "$2"); _dpsn=$(doh_url_host "${_dpsn%%$(printf '\t')*}")
		case "$_dpsn" in *[!0-9.]*) printf '%s\n' "$_dpsn" ;; *) dot_resolver_sni "$2" ;; esac
		return 0
	fi
	if [ "$1" = odoh ]; then _dpsn=$(doh_url_host "$(doh_odoh_relay_url)"); case "$_dpsn" in *[!0-9.]*) printf '%s\n' "$_dpsn" ;; esac; return 0; fi
	_dpsn=$(doh_resolver_spec "$2"); _dpsn=$(doh_url_host "${_dpsn%%$(printf '\t')*}")
	case "$_dpsn" in *[!0-9.]*) printf '%s\n' "$_dpsn" ;; esac
	return 0
}
# DoH3's request path — the DoH URL's (NextDNS: `/<profile>`; the own resolver: as entered), `/dns-query` when the URL has none.
doh_quic_path() {
	_dqp=$(doh_resolver_spec "$1"); _dqp=${_dqp%%$(printf '\t')*}; _dqp=${_dqp#https://}
	case "$_dqp" in */*) printf '/%s\n' "${_dqp#*/}" ;; *) echo /dns-query ;; esac
}
# doh_quic_can <doq|doh3> [resolver] — 0 = that QUIC protocol MAY BE TRIED with the resolver: what holds on every path — the own
# resolver needs a NAME (the certificate is checked by it: DoH3 on its URL, DoQ under its DoT name), ODoH never (its own protocol).
# Whether QUIC answers HERE is asked of this router's own path — doh_wire_ok, before the switch (cgi-bin/action set_doh_proto/
# set_doh_resolver): it depends on the country and the ISP, and a list measured from the project's routers would refuse a person
# elsewhere what works for them (user, s.151).
doh_quic_can() {
	_dqcr=${2:-$(doh_resolver_name)}
	case "$1" in doq|doh3) : ;; *) return 1 ;; esac
	case "$_dqcr" in
		odoh)   return 1 ;;
		custom) [ -n "$(doh_custom_host)" ]; return $? ;;
	esac
	return 0
}
# Порт резолвера на проводе у АКТИВНОГО протокола (для форс-марки/RETURN).
doh_wire_port() { doh_proto_port "$(doh_proto_now)"; }
# ВСЕ порты, на которых у резолвера $1 могли стоять наши правила: снятие обязано быть proto-agnostic (смена протокола не
# оставляет марку прежнего порта) и переживать смену ПОРТА (правило :443 версии, не знавшей порта из URL, снимается тоже).
doh_all_ports() { printf '%s\n' 443 853 "$(doh_proto_port doh "$1")" "$(doh_proto_port dot "$1")" | sort -u | tr '\n' ' '; }

# «Установлен» = есть бинарь АКТИВНОГО протокола (гейт doh_enabled/doh_auto: выбрал dot без
# бинаря → шифрование честно не включается, DNS остаётся на прежнем пути транспорта). У ODoH — ещё и УМЕЕТ ли он ODoH:
# прежняя сборка программы DoH ключа -O не знает и не стартует вовсе (doh_odoh_capable).
doh_installed() {
	[ -x "$(doh_bin_for)" ] || return 1
	[ "$(doh_proto_now)" != odoh ] || doh_odoh_capable
}
# doh_on_intent — the person switched encryption on («Шифровать всегда», `.doh-on`), whatever is installed. Asked alone where the
# protocol is about to change: doh_installed is about the CURRENT protocol's program (set_doh_proto's precheck, review s.151 r2 L4).
doh_on_intent() { [ "$(cat "$ENODIA_STATE/.doh-on" 2>/dev/null)" = on ]; }
doh_enabled()   { doh_on_intent && doh_installed; }
doh_upstream()  { echo "$DOH_UPSTREAM"; }

# НАШ UPSTREAM dnsmasq ПИШЕТ ОДИН ВЛАДЕЛЕЦ — И ПЕРЕЗАПУСКАЕТ ДЕМОН ТОЛЬКО ПО ДЕЛУ. `/etc/init.d/dnsmasq restart`
# возвращается за 0.3 с, а демон с нашими ipset-строками и списками встаёт ещё ~2.5 с — и всё это время у ВСЕЙ сети
# нет имён, а первый запрос после него ждёт (замер BE7000 02.10.2026: проба DoH 2.8 с после рестарта против 0.26 без).
# Платили это на КАЖДОЙ смене сервера, хотя upstream у AmneziaWG почти всегда тот же (172.29.172.254, а при DoH — сам
# прокси). Поэтому сверяем с ОБЕИМИ копиями (init копирует /etc→/tmp аддитивно, и демон читает обе): совпало и демон
# жив — не трогаем; иначе пишем и перезапускаем, как раньше. Аргументы — адреса `server=` в нужном порядке.
# Пишут не все: heal.sh на буте (там рестарт — отдельным шагом) и аварийный safety_off (своя шапка-комментарий) — разбор у них.
# HUP перечитывает hosts и сбрасывает кэш, но НЕ конфиг: снятый перед нами сид сервера (`address=`, dns-lib.sh::seed_host_clear —
# снятие несущей xray/hy2, сервер IP-литералом) остался бы в памяти демона. Тот, кто снял, кладёт отметку DNS_RELOAD_MARK — при
# ней перезапускаем и при том же upstream (ревью с.95).
DNS_RELOAD_MARK=${DNS_RELOAD_MARK:-/tmp/enodia-dns-reload}
dns_upstream_put() {
	_dup=$( { echo no-resolv; for _dua in "$@"; do echo "server=$_dua"; done; } )
	if [ ! -e "$DNS_RELOAD_MARK" ] && [ "$(cat /etc/dnsmasq.d/00-upstream.conf 2>/dev/null)" = "$_dup" ] \
	   && [ "$(cat /tmp/dnsmasq.d/00-upstream.conf 2>/dev/null)" = "$_dup" ] && pidof dnsmasq >/dev/null 2>&1; then
		killall -HUP dnsmasq 2>/dev/null   # кэш прежнего пути — сбросить (дёшево: демон не встаёт заново)
		return 0
	fi
	rm -f "$DNS_RELOAD_MARK" 2>/dev/null
	mkdir -p /etc/dnsmasq.d
	printf '%s\n' "$_dup" > /etc/dnsmasq.d/00-upstream.conf
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ЧЕМ РОУТЕР РЕЗОЛВИТ ПРЯМО СЕЙЧАС — ОДИН ответ на проект. Спрашивают ДВОЕ: карточка «Шифрованный
# DNS» (там это строка «Сейчас DNS») и лента технического состояния «Обзора» — и обе обязаны
# говорить одно и то же, иначе панель спорит сама с собой на соседних экранах. Живёт ЗДЕСЬ,
# потому что владелец DNS-пути во всех режимах — этот слой: он же и переставляет upstream.
# Истина ровно там, где живёт dnsmasq: наш `00-upstream.conf` идёт с `no-resolv` и перебивает
# всё; нет его — работает стоковый resolv.conf.auto. Живую копию (/tmp) спрашиваем ПЕРВОЙ:
# init копирует /etc→/tmp, расходятся они ровно в окне правки.
# Печатаем КЛАСС пути (doh|ours|stock) и адреса — фразу подбирает панель, вердиктов тут нет.
# Формат — строки `ключ=значение` (как у `net-tune.sh detect`): адресов бывает несколько, и
# разделителем в одной строке они бы слиплись с ключом.
dns_now() {
	_dnsrc=stock; _dnadr=""; _dnupf=""
	for _dnf in /tmp/dnsmasq.d/00-upstream.conf /etc/dnsmasq.d/00-upstream.conf; do
		if [ -f "$_dnf" ]; then _dnupf="$_dnf"; break; fi
	done
	if [ -n "$_dnupf" ]; then
		_dnsrc=ours
		_dnadr=$(sed -n 's/^server=//p' "$_dnupf" | grep -v '^/' | tr '\n' ' ' | sed 's/ *$//')
		# Локальный прокси в upstream = DNS уходит шифрованным (порт 5053 держит doh/dot-proxy).
		case "$_dnadr" in *127.0.0.1#*) _dnsrc=doh ;; esac
	else
		for _dnf in /tmp/resolv.conf.auto /tmp/resolv.conf.d/resolv.conf.auto; do
			if [ -f "$_dnf" ]; then
				_dnadr=$(sed -n 's/^nameserver *//p' "$_dnf" | tr '\n' ' ' | sed 's/ *$//'); break
			fi
		done
	fi
	# КУДА ЭТИ ЗАПРОСЫ ИДУТ — вторая половина вопроса. Класс пути говорит, КТО отвечает, но не говорит,
	# видит ли их провайдер: `ours` — это и туннельный резолвер VPS, и открытый 1.1.1.1 прямого режима,
	# у которых ответ противоположный. Судим ТЕМ ЖЕ, чем решает сам слой, своей арифметики не заводим:
	# прямой режим — `doh_direct_regime` (он же выбирает якорь резолвера), уведённый мимо несущей
	# резолвер — флаг `DOH_UNTUNNELED` (по нему doh_anchor_apply ставит RETURN вместо марки). Сток — мимо
	# туннеля по определению: наших правил DNS нет вовсе.
	_dnvia=tunnel
	if [ "$_dnsrc" = stock ] || doh_direct_regime; then _dnvia=direct
	elif [ "$_dnsrc" = doh ] && [ -f "$DOH_UNTUNNELED" ]; then _dnvia=direct; fi
	printf 'src=%s\naddr=%s\nvia=%s\n' "$_dnsrc" "$_dnadr" "$_dnvia"
}

# АВТО-РЕЖИМ: в прямых режимах (byedpi/zapret/fail-open) туннеля НЕТ ⇒ dnsmasq форвардит на
# 1.1.1.1/8.8.8.8 ОТКРЫТЫМ UDP:53 — ровно там, где агрессивный ISP спуфит/травит DNS. В
# tunnel-режимах DNS и так спрятан в туннеле, авто там не нужен (не трогаем проверенный путь).
# Дефолт ВКЛ: «юзеру настраивать не надо» — но обвязан функциональной пробой (см. doh_apply_dns),
# так что заблокированный/битый DoH-резолвер откатывает нас на прежний DNS, а не рвёт его.
# Часы: RTC на роутере НЕТ, до синхронизации `date +%s` показывает мусор ⇒ всё, что судит по
# отметкам времени, обязано этот случай пропускать (общий инвариант проекта). Порог — у владельца
# (clock-lib.sh::clock_sane, следит C82); шим той же строки объявлен в шапке файла.
doh_clock_ok() { clock_sane; }
# КАРАНТИН после отката (doh_health_tick): авто-режим взводит КАЖДЫЙ dns-сеттер транспорта, и без
# карантина откат жил бы до первого же switch/repair — резолвер, который мы только что признали
# мёртвым, тут же вернулся бы на место. Часы не выставлены → отметке верим (карантин держим), а не
# снимаем её раньше срока: ошибиться в сторону обычного DNS дешевле, чем в сторону мёртвого.
doh_auto_cooling() {
	_dcu=$(cat "$DOH_AUTO_COOLDOWN" 2>/dev/null | tr -cd '0-9')
	[ -n "$_dcu" ] || return 1
	doh_clock_ok || return 0
	[ "$(date +%s)" -lt "$_dcu" ] && return 0
	rm -f "$DOH_AUTO_COOLDOWN" 2>/dev/null
	return 1
}
doh_auto() {
	[ "$(cat "$ENODIA_STATE/.doh-auto" 2>/dev/null)" != off ] || return 1
	doh_auto_cooling && return 1
	doh_installed
}
doh_auto_active() { [ -f "$DOH_AUTO_STAMP" ]; }
# «DoH должен быть поднят» = тумблер ИЛИ активный авто-режим. Гейт для doh_start/keepalive.
doh_want()        { doh_enabled || doh_auto_active; }

# КАТАЛОГ РЕЗОЛВЕРОВ — ОДНА ТАБЛИЦА. Прежде он жил в четырёх `case` (список, URL+bootstrap, якоря, SNI DoT) и ещё в
# подписях панели — новый резолвер был шестью правками, и любая забытая давала резолвер без якорей (марка и RETURN мимо)
# или без SNI (DoT не встаёт). Теперь каждая строка — всё, что слой знает о резолвере; панель берёт подписи отсюда же
# (cgi-bin/data, `catalog`). Поля через `|` (в URL и адресах его не бывает):
#   ключ | имя | владелец — кто видит запросы (пусто = он и есть имя) | страна (ISO) | DoH URL | якоря (через пробел) |
#   SNI DoT | bootstrap. No QUIC column (s.151): whether a resolver answers DoQ/DoH3 depends on the country and the ISP, and the
#   router asks ITS path on the choice (cgi-bin/action); what the project measured is the probe tool's record
#   (dev/quic/quic-probe-router.sh MEASURED), not the product's.
# ЯКОРЯ — адреса, на которых стоят правила резолвера и куда doh_pin_hosts прибивает его имя (c-ares читает /etc/hosts
# раньше DNS): у резолвера по ИМЕНИ прокси ходит ровно туда. BOOTSTRAP поэтому почти не спрашивается, но обязан отвечать
# ОБЫЧНЫМ :53: у резолверов «только DoH/DoT» (Wikimedia, Mullvad, Applied Privacy) их собственный адрес на :53 молчит
# (замер 16.10.2026, заметки разработки «ODoH-дизайн» §1) — им bootstrap 1.1.1.1.
# NextDNS и `custom` — строки с особым полем (профиль / свой адрес), их разбирают функции ниже. `custom` — СВОЙ резолвер:
# адрес вводит человек, мы за него не ручаемся; он намеренно ПОСЛЕДНИЙ и намеренно НЕ пресет — рекомендовать чужой
# SNI-прокси, который видит весь DNS дома, мы не готовы (разбор — заметки разработки «DoH-план»).
# Каждая каталожная строка замерена на роутере нашими программами (dev/doh/resolver-probe-router.sh, тот же набор строк).
DOH_CATALOG='cloudflare|Cloudflare (1.1.1.1)||US|https://1.1.1.1/dns-query|1.1.1.1 1.0.0.1|cloudflare-dns.com|1.1.1.1
google|Google (dns.google)||US|https://dns.google/dns-query|8.8.8.8 8.8.4.4|dns.google|8.8.8.8
quad9|Quad9 (9.9.9.9)||CH|https://dns.quad9.net/dns-query|9.9.9.9 149.112.112.112|dns.quad9.net|9.9.9.9
adguard|AdGuard DNS||CY|https://dns.adguard-dns.com/dns-query|94.140.14.14 94.140.15.15|dns.adguard-dns.com|94.140.14.14
controld|Control D||CA|https://freedns.controld.com/p0|76.76.2.11|p0.freedns.controld.com|1.1.1.1
dnssb|DNS.SB|xTom|DE|https://doh.dns.sb/dns-query|185.222.222.222 45.11.45.11|dot.sb|185.222.222.222
mullvad|Mullvad DNS||SE|https://dns.mullvad.net/dns-query|194.242.2.2|dns.mullvad.net|1.1.1.1
wikimedia|Wikimedia DNS||US|https://wikimedia-dns.org/dns-query|185.71.138.138|wikimedia-dns.org|1.1.1.1
dns4eu|DNS4EU|Whalebone|CZ|https://unfiltered.joindns4.eu/dns-query|86.54.11.100 86.54.11.200|unfiltered.joindns4.eu|86.54.11.100
opendns|OpenDNS|Cisco|US|https://doh.opendns.com/dns-query|208.67.222.222 208.67.220.220|dns.opendns.com|208.67.222.222
appliedprivacy|Applied Privacy||AT|https://doh.applied-privacy.net/query|146.255.56.98|dot1.applied-privacy.net|1.1.1.1
libredns|LibreDNS|LibreOps|GR|https://doh.libredns.gr/dns-query|116.202.176.26|dot.libredns.gr|1.1.1.1
nextdns|NextDNS||US|https://dns.nextdns.io/|45.90.28.0 45.90.30.0|dns.nextdns.io|45.90.28.0
custom|||||||'
# doh_cat <ключ> <поле 1..8> — поле строки каталога; нет ключа — пусто. Ключ сравнивается ТЕКСТОМ (`($1 "")`): awk сравнивает
# похожее на число значение `-v` как число (грабля проекта).
doh_tab() { printf '%s\n' "$1" | awk -F'|' -v k="$2" -v f="$3" '($1 "") == (k "") { print $f; exit }'; }   # <таблица> <ключ> <поле>
doh_cat() { doh_tab "$DOH_CATALOG" "$1" "$2"; }
# Ключи таблицы по порядку, без `custom` (его выбирают отдельно).
doh_tab_keys() { printf '%s\n' "$1" | awk -F'|' 'NF > 1 && ($1 "") != "custom" { printf "%s%s", (n++ ? " " : ""), $1 } END { print "" }'; }
# Каталог резолверов (whitelist для верба set_doh_resolver; неизвестное имя → cloudflare) — ключи в порядке таблицы.
doh_resolver_list() { printf '%s\n' "$DOH_CATALOG" | awk -F'|' 'NF > 1 { printf "%s%s", (n++ ? " " : ""), $1 } END { print "" }'; }

# --- СВОЙ резолвер: разбор ввода -------------------------------------------------------------
# ОДНО поле на всё, тип выводим сами (человеку незачем знать, что DoH — это URL, а DoT — имя+SNI):
#   https://хост[:порт][/путь]  → берём как есть (порт — DoH-порт, его знает URL); SNI = хост
#   tls://хост[:порт] | хост[:порт] → URL достраиваем как https://хост/dns-query (де-факто стандарт
#                                 пути у всех известных резолверов), SNI = хост; ПОРТ — DoT-порт
#   хост[:порт]/путь (без схемы) → это URL без `https://` — достраиваем схему, порт уходит в URL
#   IP-литерал в любой форме   → URL по литералу, SNI ПУСТ ⇒ DoT недоступен (нечего предъявить
#                                 в SNI, а `-s` у dot-proxy обязателен)
# ПОРТ БЕЗ СХЕМЫ — ПОРТ DoT, А НЕ DoH (бэклог ветки fix/dot-port-fallback, (3)). Прежде `tls://хост:8853` уезжал в URL
# DoH (`https://хост:8853/dns-query` — DoH на порт DoT), а сам DoT шёл на 853: порт, который человек ввёл ради DoT,
# доставался не тому протоколу. Так пишут адрес DoT все известные клиенты (AdGuard Home: `tls://хост:853`), а DoH —
# полным URL. Путь без схемы (`хост/dns-query`) раньше получал ВТОРОЙ `/dns-query` в хвост — теперь берётся как есть.
# Печатает "<url>\t<sni>\t<хост>\t<порт DoT|пусто>" или НИЧЕГО при негодном вводе. Валидация СТРОГАЯ и живёт ЗДЕСЬ, а не в
# CGI: значение уезжает и в argv демона, и в файлы конфига, а потребителей у него уже двое.
doh_custom_parse() {
	# ЛЮБОЕ склеивание введённого — ошибка одного класса, и обе её формы поймала песочница
	# parse-test.sh, а не глаз. Поэтому:
	#  * перевод строки = отказ СРАЗУ. Поле однострочное, так что он там не от человека; вдобавок
	#    grep судит ПОСТРОЧНО — многострочный ввод, где годна каждая строка, прошёл бы проверку,
	#    а склейка `dns.example.com\nevil.com` дала бы правдоподобный `dns.example.comevil.com`;
	#  * пробелы режем ТОЛЬКО ПО КРАЯМ. Снять их все (`tr -d ' \t'`) — ловушка: `dns.example.com
	#    -l /etc/passwd` склеивается в годный на вид хост. Внутренний пробел обязан ронять разбор.
	case "$1" in *"
"*) return 1 ;; esac
	_dcp=$(printf '%s' "$1" | tr -d '\r' | sed 's#^[[:space:]]*##; s#[[:space:]]*$##')
	[ -n "$_dcp" ] || return 1
	# Общая форма: необязательная схема + хост + необязательные порт и путь. Всё, чего тут нет
	# (пробелы, кавычки, ;, &, $, обратные кавычки, юникод), отсекается ЦЕЛИКОМ — не чинится.
	echo "$_dcp" | grep -qE '^(https://|tls://)?[A-Za-z0-9]([A-Za-z0-9._-]{0,251}[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$' || return 1
	# Схемы срезаем ДВУМЯ подстановками, а не альтернацией: `|` — и разделитель s-команды, и знак
	# альтернации, из-за чего `s|^(https|tls)://||` разбирается как «unknown option to `s'» (поймано
	# песочницей parse-test.sh). Заодно уходит нужда в `sed -E` — форма годится любому sed.
	_dch=$(printf '%s' "$_dcp" | sed 's#^https://##; s#^tls://##; s#/.*$##; s#:[0-9][0-9]*$##')
	[ -n "$_dch" ] || return 1
	# Порт из ввода (цифры после хоста) — чей он, решает форма ниже.
	_dcr=${_dcp#https://}; _dcr=${_dcr#tls://}; _dcr=${_dcr%%/*}; _dcpt=''
	case "$_dcr" in *:*) _dcpt=${_dcr##*:} ;; esac
	# Порт — число 1..65535: разбор выше пропускает до пяти цифр, а `:0`/`:99999` уронили бы демона на старте.
	case "$_dcpt" in '') : ;; *) [ "$_dcpt" -ge 1 ] 2>/dev/null && [ "$_dcpt" -le 65535 ] 2>/dev/null || return 1 ;; esac
	# Ведущий ноль — ОТКАЗ, а не подрезка (ревью ветки, круг 1): dot-proxy и curl читают `0853` десятичным, а iptables разбирает
	# `--dport` с основанием 0 — `0853` отвергает, `0443` делает портом 291. Марка и RETURN встали бы не на тот порт, и прокси
	# ходил бы мимо правил. Та же грабля уже лечилась в panel_tls_on.
	case "$_dcpt" in 0*) return 1 ;; esac
	_dcdp=''
	case "$_dcp" in
		https://*) _dcu="$_dcp" ;;
		tls://*)   _dcu="https://$_dch/dns-query"; _dcdp=$_dcpt ;;
		*/*)       _dcu="https://$_dcp" ;;
		*)         _dcu="https://$_dch/dns-query"; _dcdp=$_dcpt ;;
	esac
	# 853 — порт DoT по умолчанию: писать его в файл незачем (пусто = 853 у doh_proto_port).
	[ "$_dcdp" = 853 ] && _dcdp=''
	# SNI только для ИМЕНИ: у IP-литерала предъявлять в SNI нечего (сертификат на IP — редкость,
	# а dot-proxy без -s не стартует; честнее отдать пусто и отказать в DoT, чем врать TLS-ом).
	if command -v is_ipv4 >/dev/null 2>&1 && is_ipv4 "$_dch"; then _dcs=""; else _dcs="$_dch"; fi
	# Третьим полем — ХОСТ как есть (имя или литерал). Он нужен зовущему, чтобы посчитать якоря:
	# у имени их даёт резолв, у литерала якорь — сам литерал. Выводить его из URL повторно было бы
	# второй копией разбора, а разбор тут ровно один. Четвёртым — порт DoT (пусто = 853).
	printf '%s\t%s\t%s\t%s\n' "$_dcu" "$_dcs" "$_dch" "$_dcdp"
}

# Хост своего резолвера (для перерезолва якорей). Пусто = не custom / введён IP-литерал.
doh_custom_host() { cat "$ENODIA_STATE/.doh-custom-sni" 2>/dev/null | tr -d ' \r\n'; }

doh_resolver_name() {
	n=$(cat "$ENODIA_STATE/.doh-resolver" 2>/dev/null)
	case " $(doh_resolver_list) " in *" $n "*) echo "$n" ;; *) echo cloudflare ;; esac
}

# echo "<DoH-URL>\t<bootstrap-IP>" для текущего (или заданного $1) резолвера. Bootstrap = сервер,
# которым c-ares резолвит ИМЯ резолвера при старте (для IP-литеральных URL не используется).
doh_resolver_spec() {
	name="${1:-$(doh_eff)}"
	case "$name" in
		# ODoH: DoH-URL — сама цель (его зовёт лишь откат «DoH напрямую к цели»); bootstrap не нужен — имена прибиты (doh_pin_hosts).
		odoh)    printf '%s\t%s\n' "$(doh_odoh_target_url)" '1.1.1.1' ;;
		nextdns)
			id=$(cat "$ENODIA_STATE/.doh-nextdns-id" 2>/dev/null | tr -cd 'a-f0-9')
			printf '%s%s\t%s\n' "$(doh_cat nextdns 5)" "$id" "$(doh_cat nextdns 8)" ;;
		custom)
			# Bootstrap своему резолверу нужен не всегда (URL по IP-литералу его не использует), а
			# когда нужен — берём ПЕРВЫЙ якорный адрес: он уже посчитан и это ОН САМ, то есть ни
			# одного лишнего имени наружу. Нет якорей (не сохранился/стёрли) — тогда публичный
			# 1.1.1.1, иначе c-ares не разрешит имя и демон не поднимется вовсе.
			curl_url=$(cat "$ENODIA_STATE/.doh-custom-url" 2>/dev/null | tr -d ' \r\n')
			[ -n "$curl_url" ] || { printf '%s\t%s\n' 'https://1.1.1.1/dns-query' '1.1.1.1'; return 0; }
			# ПЕРВОЕ СЛОВО, а не первая строка: doh_resolver_ips отдаёт адреса ОДНОЙ строкой через
			# пробел, поэтому `head -1` возвращал их ВСЕ — и в `-b` демона уезжало «8.8.8.8 8.8.4.4»
			# одним аргументом (поймано на железе 14.08.2026; bootstrap ждёт один адрес).
			cboot=$(doh_resolver_ips custom | awk '{print $1; exit}')
			[ -n "$cboot" ] || cboot=1.1.1.1
			printf '%s\t%s\n' "$curl_url" "$cboot" ;;
		*)
			# Каталожная строка; ключа нет в таблице (doh_resolver_name такого не отдаст, но спрашивают и с аргументом) — cloudflare.
			_drsn=$name; [ -n "$(doh_cat "$_drsn" 5)" ] || _drsn=cloudflare
			printf '%s\t%s\n' "$(doh_cat "$_drsn" 5)" "$(doh_cat "$_drsn" 8)" ;;
	esac
}

# ВСЕ известные anycast-IP резолвера — якоря форс-марки/RETURN :443. Одного bootstrap-IP МАЛО:
# у hostname-резолверов (google/quad9/adguard/nextdns) адресов ДВА, и c-ares может выбрать любой —
# соединение на второй (немаркированный) IP в tunnel-режиме уходило МИМО туннеля (провайдер видит/
# режет :443 резолвера), в direct-режиме могло попасть под десинк ciadpi. Списки статичны — это
# публичные anycast-адреса самих резолверов (2026-07; сменятся — DoH не падает, деградирует якорь).
# Каталожные — колонка якорей таблицы; у cloudflare DoH-URL литеральный (только 1.1.1.1), но DoT ходит на оба.
doh_resolver_ips() {
	case "${1:-$(doh_eff)}" in
		# ODoH: ВСЕ ретрансляторы списка и цель — правила не переставляются ни при смене ретранслятора, ни на откате к цели.
		odoh)    doh_odoh_ips ;;
		# Свой резолвер: адреса ТОЛЬКО из файла, никакого резолва ЗДЕСЬ. Эту функцию крутят в
		# цикле `for _ip in $(doh_resolver_ips)` при расстановке правил — сетевой вызов внутри
		# сделал бы iptables-проход платным и (в busybox нет `local`) затёр бы `_ip` вызывающему.
		# Кто наполняет файл — doh_custom_refresh; пустой = якорей нет, см. его же шапку.
		# Ответ — РОВНО «адрес пробел адрес», без хвоста: файл построчный, и `tr '\n' ' '` оставлял хвостовой пробел, а doh_start
		# превращает пробелы в запятые — dot-proxy получал `-r 1.0.0.1,1.1.1.1,` (замер 29.09.2026; пустой элемент он пропускал,
		# но другой потребитель вправе не прощать).
		custom)  cat "$ENODIA_STATE/.doh-custom-ips" 2>/dev/null | tr -s '\r\n\t ' '    ' | sed 's/^ //; s/ $//' ;;
		*)
			_drik=${1:-$(doh_eff)}; _drii=$(doh_cat "$_drik" 6)
			[ -n "$_drii" ] || _drii=$(doh_cat cloudflare 6)   # нет такого ключа — как у doh_resolver_spec: cloudflare
			echo "$_drii" ;;
	esac
}

# --- ЯКОРНЫЕ АДРЕСА СВОЕГО РЕЗОЛВЕРА -----------------------------------------------------------
# ЗАЧЕМ ВООБЩЕ: doh_resolver_ips кормит троих — форс-марку :443/853 в туннель, RETURN мимо
# маркировки в прямом режиме и проволочную пробу здоровья. У каталожных резолверов адреса вписаны
# руками (публичный anycast), у своего их знает только DNS. Последствия ПРОТУХШЕГО якоря
# АСИММЕТРИЧНЫ, и это главная причина, почему перерезолв тут вообще есть:
#   * туннельный режим — марка не встала, запрос к резолверу ушёл общим путём. Просела приватность,
#     DNS ЖИВ (та же деградация, что у каталожных при смене их anycast — она признана приемлемой);
#   * ПРЯМОЙ режим (byedpi/zapret) — не встал RETURN, и HTTPS/2-сессия к резолверу попадает ПОД
#     ДЕСИНК. Это уже не деградация, а мёртвый DNS всего дома.
# Поэтому: успех = адреса ЕСТЬ. Ничего не нарезолвили — СТАРЫЕ НЕ ТРОГАЕМ (протухший якорь всё
# равно лучше пустого: пустой снимает и марку, и RETURN разом), просто уходим ни с чем.
# Смена набора обязана быть ПРИМЕНЕНА, а не только записана: правила висят на СТАРЫХ адресах, и
# снять их можно лишь пока файл ещё старый ⇒ порядок «teardown → запись → расстановка» жёсткий.
DOH_CUSTOM_STAMP="/tmp/.enodia-doh-custom.stamp"
DOH_CUSTOM_EVERY=${DOH_CUSTOM_EVERY:-3600}   # как часто перерезолвим в тике сторожа (сек)

# doh_anchor_ips <host> — якорные адреса ИМЕНИ, КАНОНИЗИРОВАННЫЕ. Копия одна на двоих: считает их
# и панельный верб `set_doh_resolver` (там же и отказ, если пусто), и перерезолв ниже.
# СОРТИРОВКА — НЕ КОСМЕТИКА. Резолвер с несколькими A-записями отдаёт их в ПРОИЗВОЛЬНОМ порядке
# (round-robin — его штатное поведение, а не сбой), а сравниваем мы СТРОКУ целиком. Без канонизации
# «набор сменился» срабатывало почти на каждом перерезолве: запись на UBIFS раз в час и снятие/
# постановка правил в mangle ради ТЕХ ЖЕ САМЫХ адресов. `sort -u` на busybox есть (ключей `-k`/`-t`
# у него нет, но здесь и не нужно — сортируем строки целиком). `head` ПОСЛЕ сортировки: у резолвера
# с пятью адресами иначе и «первые четыре» тасовались бы вместе с порядком.
doh_anchor_ips() {
	command -v doh_ips >/dev/null 2>&1 || return 1
	doh_ips "$1" "" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | head -4
}

doh_custom_refresh() {
	# ODoH: его имена — ретрансляторы и цель, у Fastly anycast ⇒ перерезолв того же склада (doh_odoh_refresh).
	if [ "$(doh_proto)" = odoh ]; then doh_odoh_refresh "$1"; return 0; fi
	[ "$(doh_resolver_name)" = custom ] || return 0
	_dcr_h=$(doh_custom_host)
	[ -n "$_dcr_h" ] || return 0          # IP-литерал: якорь известен из самого URL, дрейфа нет
	# $1 = force: на doh_start (бут, смена резолвера, подъём после падения) считаем всегда, в
	# тике сторожа — по троттлу. Возраст ТОЛЬКО через age_since: отметка рождается после загрузки,
	# а часы на этом железе прыгают вперёд через ~13 мин (голая разность врёт на величину шага).
	if [ "$1" != force ]; then
		_dcr_t=$(cat "$DOH_CUSTOM_STAMP" 2>/dev/null | tr -cd '0-9')
		[ -n "$_dcr_t" ] && [ "$(age_since "$_dcr_t")" -lt "$DOH_CUSTOM_EVERY" ] && return 0
	fi
	# Резолвим ЧУЖИМ проверенным путём (dns-lib: система → DoH через WAN → DoH как есть). Нет
	# библиотеки — тихо уходим: пусть якорь протухает, но своего цикла резолва мы не заводим.
	_dcr_new=$(doh_anchor_ips "$_dcr_h")
	[ -n "$_dcr_new" ] || return 0
	doh_clock_ok && date +%s > "$DOH_CUSTOM_STAMP" 2>/dev/null
	# Старый файл тоже канонизируем: он мог быть записан ДО появления сортировки (или руками), и
	# сравнение «отсортированное против как пришло» вечно давало бы «набор сменился».
	# ЧЕРЕЗ `cat`, а не `sort -u ФАЙЛ`: файла обычно НЕТ (резолвер только что стал своим), и тогда
	# `sort` возвращает ненулевой код — а это присваивание из $() и есть последняя команда.
	# ЗАМЕРЕНО: `sh -c 'set -e; x=$(sort -u /нет-файла 2>/dev/null); echo ВЫЖИЛ'` не печатает
	# ничего, rc=2; форма через `cat` печатает. Сегодня библиотеку под `set -e` не сорсит никто
	# (в установщике мы лишь упомянуты в комментарии) — но список потребителей растёт, а цена
	# ошибки чужая. Пайплайн кончается `sort` с пустого stdin, то есть всегда нулём (идиома dns-lib).
	_dcr_old=$(cat "$ENODIA_STATE/.doh-custom-ips" 2>/dev/null | sort -u)
	[ "$_dcr_new" = "$_dcr_old" ] && return 0
	# Набор сменился. Снимаем правила ПО СТАРОМУ файлу, пишем новый, ставим по новому — и только
	# если DNS сейчас реально держим мы (иначе расставили бы марки под выключенным шифрованием).
	# КАКОЕ правило ставить — не наше решение (doh_anchor_apply): своя вилка «прямой ⇒ RETURN, иначе
	# МАРКА» здесь не знала про «резолвер уведён мимо несущей» и возвращала марку в ту самую
	# несущую, которой сторож только что не поверил, — причём молча, флаг оставался на месте.
	if doh_want; then
		doh_resolver_mark del; doh_resolver_bypass del
		echo "$_dcr_new" > "$ENODIA_STATE/.doh-custom-ips"
		doh_anchor_apply
		# …и закрепление имени — за новыми якорями: c-ares прокси перечитывает hosts по mtime на следующем опросе,
		# иначе прокси ходил бы на старые адреса, а правила стояли бы уже на новых.
		doh_pin_hosts
		# DoT ИМЕНИ НЕ РЕЗОЛВИТ: адреса dot-proxy получил аргументом `-r` при старте, и живая сессия к СТАРОМУ якорю осталась
		# без марки/RETURN — в туннеле это чёрная дыра (conntrack держит подмену адреса на awg0, а пакеты уходят в WAN), в
		# прямом режиме — сессия под десинк. Прокси молчит до TCP-таймаута ядра, провод к НОВЫМ якорям жив — «DoT здоров»
		# (ревью ветки fix/dot-tails, круг 2). Рестарт под новый `-r`: прокси встаёт за доли секунды, dnsmasq смотрит тот же порт.
		# The QUIC program takes its addresses the same way (`-r` IP literals) — the same restart.
		case "$(doh_proto_now)" in dot|doq|doh3) doh_running && doh_restart ;; esac
	else
		echo "$_dcr_new" > "$ENODIA_STATE/.doh-custom-ips"
	fi
	return 0
}

# SNI-имя резолвера для DoT (dot-proxy: IP-литералы из doh_resolver_ips + это имя ⇒ bootstrap-DNS
# не нужен ВООБЩЕ). NextDNS: профиль зашит в SNI (<id>.dns.nextdns.io); нет ID → пусто ⇒
# doh_start откажется поднимать (валидацию ID делает панельный верб, это лишь страховка).
dot_resolver_sni() {
	case "${1:-$(doh_eff)}" in
		odoh)    return 0 ;;   # у ODoH DoT нет
		nextdns) _id=$(cat "$ENODIA_STATE/.doh-nextdns-id" 2>/dev/null | tr -cd 'a-f0-9')
		         [ -n "$_id" ] && echo "$_id.$(doh_cat nextdns 7)" ;;
		# Свой резолвер: пусто = введён IP-литерал ⇒ doh_start честно откажется поднимать DoT
		# (та же логика, что у NextDNS без ID: предъявлять в SNI нечего, а `-s` обязателен).
		custom)  doh_custom_host ;;
		*)
			_drsk=${1:-$(doh_eff)}; _drss=$(doh_cat "$_drsk" 7)
			[ -n "$_drss" ] || _drss=$(doh_cat cloudflare 7)   # нет такого ключа — cloudflare, как у соседей
			echo "$_drss" ;;
	esac
}

# --- OBLIVIOUS DoH (RFC 9230): цель и ретранслятор -------------------------------------------------------------------------
# ЗАЧЕМ (заметки разработки «ODoH-дизайн»). DoH/DoT прячут DNS от провайдера, но резолвер видит и вопросы, и адрес — в прямом
# режиме адрес дома, в туннельном адрес своего VPS (тоже твой). ODoH разносит это на двоих: запрос запечатан для ЦЕЛИ и идёт
# через РЕТРАНСЛЯТОР — тот видит адрес, но не вопрос, цель видит вопрос, но не адрес. Свойство держится, только пока у них
# РАЗНЫЕ владельцы: свою пару одного владельца верб не примет (doh_odoh_same_owner).
# Программа — та же https-dns-proxy (наш патч, dev/doh/odoh/: -O цель, -W её адрес, -r ретранслятор, -R его адрес).
# Таблицы — как DOH_CATALOG: ключ | имя | владелец (пусто = он и есть имя) | страна | URL | стартовые якоря (замер 16.10.2026;
# живые — перерезолвом doh_odoh_refresh: у Fastly anycast). `custom` — адрес вводит человек (файлы .doh-odoh-custom-*).
DOH_ODOH_TARGETS='cloudflare|Cloudflare||US|https://odoh.cloudflare-dns.com/dns-query|162.159.62.1 172.64.42.1
dnscryptpt|dnscry.pt||DE|https://fra01.dnscry.pt/dns-query|45.82.120.61
custom|||||'
DOH_ODOH_RELAYS='fastly|crypto.sx|Fastly|US|https://odoh-relay.edgecompute.app/|151.101.1.51 151.101.65.51 151.101.129.51 151.101.193.51
numa|numa||DE|https://odoh-relay.numa.rs/relay|178.104.229.30
custom|||||'
DOH_ODOH_RELAY_NOW="/tmp/.enodia-odoh-relay"       # через какой ретранслятор списка идём СЕЙЧАС (лестница doh_odoh_rescue)
DOH_ODOH_TRY="/tmp/.enodia-odoh-try.stamp"         # когда в последний раз пробовали вернуться с отката на ODoH (эпоха)
DOH_ODOH_STAMP="/tmp/.enodia-doh-odoh.stamp"       # когда перерезолвили якоря (троттл, как у своего резолвера)
DOH_ODOH_CAP="/tmp/.enodia-doh-odoh-cap"           # «размер mtime да|нет»: умеет ли ODoH программа DoH (doh_odoh_capable)
DOH_ODOH_RETRY=${DOH_ODOH_RETRY:-900}              # через сколько с отката пробовать ретрансляторы снова (сек)…
DOH_ODOH_RETRY_MAX=${DOH_ODOH_RETRY_MAX:-3600}     # …а после каждой неудачной попытки — вдвое дольше, не больше этого
DOH_ODOH_TRIES="/tmp/.enodia-odoh-tries"          # неудачных попыток возврата подряд (счёт, не эпоха — потому не *.stamp)
DOH_ODOH_RESCUE="/tmp/.enodia-odoh-rescue.stamp"  # when the ladder last found nothing alive (epoch): not climbed again before DOH_ODOH_RETRY
DOH_PIN_RELAY=enodia-doh-relay                     # владельцы закрепления имён ретрансляторов: …1, …2 (doh_pin_hosts)

doh_odoh_target() {
	_dot=$(cat "$ENODIA_STATE/.doh-odoh-target" 2>/dev/null | tr -d ' \r\n')
	[ -n "$_dot" ] && { [ "$_dot" = custom ] || [ -n "$(doh_tab "$DOH_ODOH_TARGETS" "$_dot" 5)" ]; } && { echo "$_dot"; return 0; }
	echo cloudflare
}
# WHO ANSWERS by the person's choice, one key: the ODoH target under ODoH, the resolver otherwise — the ribbon, the toasts and the
# journal name the same one (review s.147: the toasts and the failure event named the DoH resolver under ODoH).
doh_named() { if [ "$(doh_proto)" = odoh ]; then doh_odoh_target; else doh_resolver_name; fi; }
# Выбор ретранслятора: auto (все списка по очереди) | ключ | custom.
doh_odoh_relay_pick() {
	_dor=$(cat "$ENODIA_STATE/.doh-odoh-relay" 2>/dev/null | tr -d ' \r\n')
	case "$_dor" in ''|auto) echo auto; return 0 ;; custom) echo custom; return 0 ;; esac
	[ -n "$(doh_tab "$DOH_ODOH_RELAYS" "$_dor" 5)" ] && echo "$_dor" || echo auto
}
# Ретрансляторы, через которые прокси вправе ходить, в порядке попыток: «авто» — все каталожные, иначе — выбранный.
doh_odoh_relays() { _dorp=$(doh_odoh_relay_pick); if [ "$_dorp" = auto ]; then doh_tab_keys "$DOH_ODOH_RELAYS"; else echo "$_dorp"; fi; }
doh_odoh_relay_now() {
	_drn=$(cat "$DOH_ODOH_RELAY_NOW" 2>/dev/null | tr -d ' \r\n')
	for _drk in $(doh_odoh_relays); do [ "$_drk" = "$_drn" ] && { echo "$_drk"; return 0; }; done
	doh_odoh_relays | awk '{print $1}'
}
# doh_odoh_url <relay|target> <ключ> — URL из таблицы или из файла своего адреса.
doh_odoh_url() {
	if [ "$2" = custom ]; then cat "$ENODIA_STATE/.doh-odoh-custom-$1" 2>/dev/null | tr -d ' \r\n'; return 0; fi
	if [ "$1" = relay ]; then doh_tab "$DOH_ODOH_RELAYS" "$2" 5; else doh_tab "$DOH_ODOH_TARGETS" "$2" 5; fi
}
doh_odoh_target_url() { doh_odoh_url target "$(doh_odoh_target)"; }
doh_odoh_relay_url()  { doh_odoh_url relay "${1:-$(doh_odoh_relay_now)}"; }
# Refresh identity includes custom URL contents even while ODoH is using fallback DoH.
doh_odoh_config_sig() {
    [ "$(doh_proto)" = odoh ] || return 0
    printf '%s\n%s\n' "$(doh_odoh_target_url)" "$(doh_odoh_relay_url)" | md5sum | cut -d' ' -f1
}
# Якоря ИМЕНИ ретранслятора или цели: перерезолвленные (файл .doh-odoh-ips: «имя адрес адрес…»), иначе стартовые из таблицы.
# IP-литерал — сам себе якорь.
doh_odoh_host_ips() {
	case "$1" in '') return 0 ;; *[!0-9.]*) : ;; *) echo "$1"; return 0 ;; esac
	_dhi=$(awk -v h="$1" '($1 "") == (h "") { $1 = ""; sub(/^ +/, ""); print; exit }' "$ENODIA_STATE/.doh-odoh-ips" 2>/dev/null)
	[ -n "$_dhi" ] && { echo "$_dhi"; return 0; }
	printf '%s\n%s\n' "$DOH_ODOH_TARGETS" "$DOH_ODOH_RELAYS" | \
		awk -F'|' -v h="$1" '{ u = $5; sub(/^https:\/\//, "", u); sub(/[:\/].*$/, "", u) } (u "") == (h "") && $6 != "" { print $6; exit }'
}
# Все имена, к которым ходит прокси ODoH: ретрансляторы списка, затем цель.
doh_odoh_hosts() {
	for _dok in $(doh_odoh_relays); do doh_url_host "$(doh_odoh_relay_url "$_dok")"; done
	doh_url_host "$(doh_odoh_target_url)"
}
# Адреса для правил — РОВНО «адрес пробел адрес» (как у doh_resolver_ips: её крутят в `for _ip in $(…)`).
doh_odoh_ips() {
	for _doh in $(doh_odoh_hosts); do doh_odoh_host_ips "$_doh"; done | tr ' ' '\n' | \
		grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# doh_odoh_parse_url <ввод> <target|relay> — свой адрес цели или ретранслятора: строго https://имя[/путь], БЕЗ порта (RFC 9230
# называет цель ретранслятору без порта, а правила резолвера стоят на одном порту — doh_proto_port) и без IP-литерала (сертификат
# на IP — редкость, а закрепление имени — наш путь мимо системного резолвера). Цели без пути — /dns-query (де-факто стандарт),
# ретранслятору — «/». Печатает канонический URL или НИЧЕГО. Валидация строгая и живёт ЗДЕСЬ: значение уезжает в argv демона.
doh_odoh_parse_url() {
	case "$1" in *"
"*) return 1 ;; esac
	_dpu=$(printf '%s' "$1" | tr -d '\r' | sed 's#^[[:space:]]*##; s#[[:space:]]*$##')
	echo "$_dpu" | grep -qE '^https://[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(/[A-Za-z0-9._~/-]*)?$' || return 1
	_dpuh=$(doh_url_host "$_dpu")
	case "$_dpuh" in *.*) : ;; *) return 1 ;; esac
	case "$_dpuh" in *[!0-9.]*) : ;; *) return 1 ;; esac
	case "$_dpu" in
		https://*/?*) printf '%s\n' "$_dpu" ;;
		*) _dpu=${_dpu%/}; if [ "$2" = target ]; then printf '%s/dns-query\n' "$_dpu"; else printf '%s/\n' "$_dpu"; fi ;;
	esac
}
# Цель и ретранслятор одного владельца? Сравниваем РЕГИСТРИРУЕМЫЙ домен (два последних слова имени): odoh.cloudflare-dns.com и
# relay.cloudflare-dns.com — один владелец. Каталожные пары — разных владельцев по построению; это судит своих.
# Регистр имени роли не играет (ODOH.Example.com — тот же владелец, ревью с.145); у двухбуквенной страны с короткой второй
# меткой (co.uk, com.au) регистрируемый домен — три метки, иначе любые два сервиса под .co.uk «одного владельца».
doh_odoh_owner() {
	doh_url_host "$1" | tr 'A-Z' 'a-z' | awk -F. 'NF >= 3 && length($NF) == 2 && length($(NF-1)) <= 3 { print $(NF-2) "." $(NF-1) "." $NF; next }
		NF >= 2 { print $(NF-1) "." $NF }'
}
doh_odoh_same_owner() {
	_dsa=$(doh_odoh_owner "$1"); _dsb=$(doh_odoh_owner "$2")
	[ -n "$_dsa" ] && [ "$_dsa" = "$_dsb" ]
}
# УМЕЕТ ЛИ программа DoH ODoH — ПО ФАКТУ: её справка называет -O. Прежняя сборка ключа не знает и не стартует; ответ кэшируем
# по размеру и mtime бинаря (справка — запуск программы, а спрашивают нас из горячих путей: data, heal, сторож).
doh_odoh_capable() {
	[ -x "$DOH_BIN" ] || return 1
	_doc_k=$(stat -c '%s %Y' "$DOH_BIN" 2>/dev/null)
	_doc_c=$(cat "$DOH_ODOH_CAP" 2>/dev/null)
	if [ -n "$_doc_k" ] && [ "${_doc_c% *}" = "$_doc_k" ]; then [ "${_doc_c##* }" = yes ]; return $?; fi
	# «Не умеет» запоминаем, только когда справка НАПЕЧАТАНА (в ней `-r resolver_url`), а ключа нет: запуск, не удавшийся сам
	# (память, накопитель переподключают), иначе записал бы «не умеет» до смены бинаря — ODoH молча стоял бы до перезагрузки.
	_doc_h=$("$DOH_BIN" -h 2>&1)
	case "$_doc_h" in
		*'-O odoh_target_url'*) _doc_v=yes ;;
		*'-r resolver_url'*)    _doc_v=no ;;
		*)                      return 1 ;;
	esac
	[ -n "$_doc_k" ] && echo "$_doc_k $_doc_v" > "$DOH_ODOH_CAP" 2>/dev/null
	[ "$_doc_v" = yes ]
}

# Перерезолв якорей ODoH — того же склада, что doh_custom_refresh (разбор асимметрии протухшего якоря — у него): успех = адреса
# ЕСТЬ, не нарезолвилось имя — его прежние адреса остаются; сменился набор — правила снимаются ПО СТАРОМУ файлу, пишется новый,
# ставятся по новому, имена перезакрепляются, живой прокси ODoH перезапускается (адрес ретранслятора у него в -R с запуска).
doh_odoh_refresh() {
	[ "$(doh_proto)" = odoh ] || return 0
	# СТАРТ ПРОКСИ (force) НЕ ЖДЁТ СЕТИ, когда у каждого текущего имени якорь уже есть (стартовые таблицы, файл якорей): три имени
	# через doh_ips — до 36 запросов curl и минут ожидания, когда DoH к 1.1.1.1/8.8.8.8 не соединяется, а старт этот — бут, подъём
	# несущей под локом смены и каждая ступень лестницы (замер ревью с.145, круг 1: 8 стартов и 24 перерезолва на одну перепроводку).
	# Свежесть якорей — забота часового тика (без force). Сеть спрашиваем, только если у какого-то имени якоря нет вовсе.
	if [ "$1" = force ]; then
		_dorf_miss=0
		for _dorf_h in $(doh_odoh_hosts); do [ -n "$(doh_odoh_host_ips "$_dorf_h")" ] || { _dorf_miss=1; break; }; done
		[ "$_dorf_miss" = 1 ] || return 0
	else
		_dorf_t=$(cat "$DOH_ODOH_STAMP" 2>/dev/null | tr -cd '0-9')
		[ -n "$_dorf_t" ] && [ "$(age_since "$_dorf_t")" -lt "$DOH_CUSTOM_EVERY" ] && return 0
	fi
	_dorf_new=''
	for _dorf_h in $(doh_odoh_hosts); do
		case "$_dorf_h" in *[!0-9.]*) : ;; *) continue ;; esac
		_dorf_i=$(doh_anchor_ips "$_dorf_h" | tr '\n' ' ' | sed 's/ $//')
		[ -n "$_dorf_i" ] || _dorf_i=$(awk -v h="$_dorf_h" '($1 "") == (h "") { $1 = ""; sub(/^ +/, ""); print; exit }' "$ENODIA_STATE/.doh-odoh-ips" 2>/dev/null)
		[ -n "$_dorf_i" ] && _dorf_new="$_dorf_new$_dorf_h $_dorf_i
"
	done
	_dorf_new=$(printf '%s' "$_dorf_new" | sort -u)
	[ -n "$_dorf_new" ] || return 0
	doh_clock_ok && date +%s > "$DOH_ODOH_STAMP" 2>/dev/null
	[ "$_dorf_new" = "$(cat "$ENODIA_STATE/.doh-odoh-ips" 2>/dev/null)" ] && return 0
	if doh_want; then
		doh_resolver_mark del; doh_resolver_bypass del
		printf '%s\n' "$_dorf_new" > "$ENODIA_STATE/.doh-odoh-ips"
		doh_anchor_apply
		doh_pin_hosts
		if [ "$(doh_proto_now)" = odoh ] && doh_running; then doh_restart; fi
	else
		printf '%s\n' "$_dorf_new" > "$ENODIA_STATE/.doh-odoh-ips"
	fi
	return 0
}

doh_running() {
	p=$(cat "$DOH_PID" 2>/dev/null)
	[ -n "$p" ] && [ -d "/proc/$p" ]
}

# CA-бандл стока (первый существующий). ОБЯЗАТЕЛЕН ОБЕИМ аркам: с 12.08.2026 и arm64 собран
# статиком (апстрим требует c-ares ≥1.22, а сток несёт 1.14.0 — разбор в
# заметки разработки «сборка-бинарей»), а у статика своего CA-пути нет ни у кого. Раньше arm64
# линковалась на стоковый libcurl и жила с его вкомпилированным дефолтом — этой подпорки
# больше нет. Ничего не найдено → НЕ СТАРТУЕМ (см. doh_start): демон без CA живой, но
# не резолвит НИКОГДА, а «жив ≠ работает» мы ловим дорого и поздно.
doh_ca_file() {
	for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem \
	         /etc/ssl/ca-bundle.pem /usr/share/ca-certificates/ca-certificates.crt; do
		[ -f "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

# Прибить «осиротевший» экземпляр прокси — тот, что ЖИВ и держит :5053, но НЕ описан pidfile'ом
# (pidfile перезаписан вторым стартом, потерян, или прошлый экземпляр завис на graceful shutdown —
# видели на железе AX3600: процесс залогировал «Shutting down gracefully», сокет не отдал и на
# запросы не отвечал). Без реапа получается тупик: doh_running=false (pidfile врёт) ⇒ doh_start
# поднимает ВТОРОЙ, тот падает «Error binding: Address in use», dnsmasq при этом уже смотрит на
# :5053 — DNS мёртв, а лечить некому (keepalive watchdog'а повторяет тот же цикл).
# $1 — pid, который НЕ трогать (наш живой); без аргумента — гасим всё.
doh_reap_stray() {
	_left=
	for _p in $(pidof https-dns-proxy 2>/dev/null) $(pidof dot-proxy 2>/dev/null) $(pidof quic-dns-proxy 2>/dev/null); do
		[ -n "$1" ] && [ "$_p" = "$1" ] && continue
		# The QUIC program is also the layer's WIRE PROBE (`-Q`, doh_wire_ok): it holds no :5053 and ends by itself within its -T. A
		# start or stop elsewhere (a CGI does not take the watchdog's lock) killed a probe in flight, and its exit 1 read «wire dead» —
		# a false move or a refused return (review s.150, round 1).
		case " $(tr '\000' ' ' 2>/dev/null < "/proc/$_p/cmdline") " in *" -Q "*) continue ;; esac
		kill "$_p" 2>/dev/null && _left="$_left $_p"
	done
	[ -n "$_left" ] || return 0
	sleep 1
	for _p in $_left; do [ -d "/proc/$_p" ] && kill -9 "$_p" 2>/dev/null; done
	return 0
}

# РОТАЦИЯ ЛОГА. `-v -v` ниже обязателен для форензики, но лог живёт в /tmp = ОЗУ и НЕ ротировался
# вовсе: прежняя оценка «рестарты редки, рост пренебрежим» ОШИБОЧНА. Замерено на живом BE7000
# 2026-08-04: демон поднят 2.86 суток, `pos` его fd = 8 845 589 байт ⇒ ~3 МБ В СУТКИ (варнинги
# curl/TLS идут постоянно, а не «редко»); в шапке clean.sh с прошлого замера стоит 1.1 МБ —
# за месяц аптайма это ~90 МБ, больше 10% ОЗУ роутера, и единственным лечением была РУЧНАЯ кнопка
# «очистить логи». Оставляем ХВОСТ, а не чистим в ноль: смысл лога — последние варнинги.
#
# Обрезать файл, который держит открытым живой демон, здесь БЕЗОПАСНО: fd проверен на железе —
# флаги 02402001, то есть O_APPEND стоит, и следующая запись уходит в НОВЫЙ конец, а не по старому
# смещению (иначе получили бы разреженный файл, который «весит» столько же). Гонка с записью в
# момент подмены максимум смажет одну строку — платить за неё локом на пути DNS незачем.
#
# ЗОВУТ НАС ДВА МЕСТА, и оба обязательны: doh_start (бут/смена резолвера) и ТИК СТОРОЖА. Одного
# doh_start мало ровно потому, что он же и был бы бесполезен: watchdog вызывает его ТОЛЬКО когда
# демон УПАЛ (`doh_want && ! doh_running`), а растит лог как раз живой демон.
doh_log_rotate() {
	_sz=$(stat -c%s "$DOH_LOG" 2>/dev/null)
	case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_sz" -gt "$DOH_LOG_MAX" ] || return 0
	if tail -c "$DOH_LOG_KEEP" "$DOH_LOG" > "$DOH_LOG.tmp" 2>/dev/null && [ -s "$DOH_LOG.tmp" ]; then
		cat "$DOH_LOG.tmp" > "$DOH_LOG" 2>/dev/null
	else
		: > "$DOH_LOG" 2>/dev/null   # нет `tail -c` в этой сборке busybox — лучше пустой лог, чем ОЗУ
	fi
	rm -f "$DOH_LOG.tmp" 2>/dev/null
	return 0
}

# ИМЯ РЕЗОЛВЕРА → ЕГО ЯКОРЯ, В /etc/hosts (закрепление). ЗАЧЕМ (замер 29.09.2026, бэклог ветки fix/dot-port-fallback,
# (6)): правила резолвера (марка в несущую / RETURN мимо неё) стоят на ЯКОРНЫХ адресах (doh_resolver_ips), а
# https-dns-proxy ходит туда, куда c-ares резолвит имя из URL. У NextDNS это РАЗНЫЕ адреса: dns.nextdns.io отдаёт ближний
# узел (95.179.134.211/188.172.219.167 через 1.1.1.1, 45.11.106.155 через 8.8.8.8), якоря — anycast 45.90.28.0/
# 45.90.30.0. Прокси ходил мимо обоих правил — в туннельном режиме мимо туннеля, в прямом под десинк, — а проба провода
# щупала якоря и «доказывала» чужой путь. c-ares читает /etc/hosts РАНЬШЕ DNS (порядок «fb» по умолчанию; nsswitch.conf/
# host.conf на BE7000 нет — замер 29.09.2026), и строка «якорь имя» ставит прокси ровно туда, где стоят правила
# (проверено: наш https-dns-proxy под qemu с подменённым /etc/hosts ходит на 45.90.28.0/45.90.30.0, TLS с SNI
# dns.nextdns.io встаёт, имена идут). Заодно уходит plain :53 bootstrap-запрос имени резолвера — c-ares в сеть не идёт
# вовсе; у google/quad9/adguard якоря и есть их A-записи, так что меняется только это. dnsmasq читает тот же файл ⇒
# клиенты сети получают на имя резолвера те же якоря — это его же официальные адреса.
# `CARES_HOSTS` НЕ годится: c-ares читает его лишь с флагом ARES_AI_ENVHOSTS, а прокси флаг не ставит (замер там же).
# Владелец строк — dns-lib.sh::seed_hosts_put (метка общая с сидами несущих ⇒ uninstall.sh снимает и эти); пишет, только
# если набор сменился (на AX3600 /etc — флеш). IP-литерал в URL (cloudflare, свой по IP) и DoT закреплять нечего —
# строки снимаем. Нет dns-lib — прежний путь (bootstrap) байт-в-байт.
DOH_PIN_OWNER=enodia-doh-resolver
# ODoH: имён ДВА рода — цель (владелец DOH_PIN_OWNER, как у резолвера: на откате DoH идёт к ней) и ретрансляторы списка (свои
# владельцы DOH_PIN_RELAY1/2: метка сравнивается ПОДСТРОКОЙ, и «enodia-doh-resolver-r1» снималась бы вместе с основной).
# Закреплены ВСЕ ретрансляторы списка — смена ретранслятора лестницей не трогает /etc/hosts.
doh_pin_relays() {   # $1 = put | clear
	_dpr_n=0
	if [ "$1" = put ]; then
		for _dpr_k in $(doh_odoh_relays); do
			_dpr_n=$((_dpr_n + 1)); _dpr_h=$(doh_url_host "$(doh_odoh_relay_url "$_dpr_k")")
			case "$_dpr_h" in
				*[!0-9.]*) seed_hosts_put "$_dpr_h" "$(doh_odoh_host_ips "$_dpr_h")" "$DOH_PIN_RELAY$_dpr_n" ;;
				*)         seed_hosts_clear "$DOH_PIN_RELAY$_dpr_n" >/dev/null 2>&1 ;;
			esac
		done
	fi
	while [ "$_dpr_n" -lt 2 ]; do _dpr_n=$((_dpr_n + 1)); seed_hosts_clear "$DOH_PIN_RELAY$_dpr_n" >/dev/null 2>&1; done
	return 0
}
doh_pin_hosts() {
	command -v seed_hosts_put >/dev/null 2>&1 || return 0
	if [ "$(doh_proto)" = odoh ]; then
		doh_pin_relays put
		_dph_h=$(doh_url_host "$(doh_odoh_target_url)")
		case "$_dph_h" in
			*[!0-9.]*) seed_hosts_put "$_dph_h" "$(doh_odoh_host_ips "$_dph_h")" "$DOH_PIN_OWNER" ;;
			*)         seed_hosts_clear "$DOH_PIN_OWNER" >/dev/null 2>&1 ;;
		esac
		return 0
	fi
	doh_pin_relays clear
	# The QUIC program resolves no name either (IP literals + the TLS name, as DoT) — nothing to pin, the pin goes.
	_dph_h=''; [ "$(doh_proto_now)" = dot ] || _dph_h=$(doh_proto_sni doh)
	case "$(doh_proto_now)" in doq|doh3) _dph_h='' ;; esac
	_dph_i=$(doh_resolver_ips)
	if [ -n "$_dph_h" ] && [ -n "$(printf '%s' "$_dph_i" | tr -d ' ')" ]; then
		seed_hosts_put "$_dph_h" "$_dph_i" "$DOH_PIN_OWNER"
	else
		seed_hosts_clear "$DOH_PIN_OWNER" >/dev/null 2>&1
	fi
	return 0
}

# Поднять демон идемпотентно: только если нужен (тумблер ИЛИ авто), установлен и ещё не бежит.
# `-v -v` (loglevel INFO) ОБЯЗАТЕЛЕН для живой диагностики: дефолт бинаря — LOG_ERROR, при нём
# ВСЕ curl/TLS-варнинги (таймауты, No response, SSL verify) МОЛЧА глотаются, а INFO-строки старта
# не пишутся вовсе — лог живого экземпляра пуст, форензика инцидентов слепа (поймано 2026-07-23 на
# разборе «смены резолвера»: 11 часов работы = 0 строк). INFO тих (нет per-query строк): ~7 строк
# на старт + редкие варнинги; W/E флашатся мгновенно, INFO — таймером бинаря раз в 10с. Лог в /tmp
# (RAM, append) и РОТИРУЕТСЯ (doh_log_rotate): замер показал ~3 МБ/сутки, «пренебрежимо» это не.
doh_start() {
	doh_log_rotate            # первым делом: сюда приходят и бут, и смена резолвера
	doh_want || return 0
	doh_installed || return 0
	doh_running && return 0
	# Свой резолвер — пересчитать якоря БЕЗ троттла: сюда приходят бут (адреса могли смениться,
	# пока роутер был выключен), смена резолвера и подъём после падения демона. Каталожных не
	# касается вовсе (внутри первая же строка отсеивает по имени).
	doh_custom_refresh force
	doh_reap_stray            # порт держит неучтённый экземпляр ⇒ иначе наш старт упадёт «Address in use»
	if [ "$(doh_proto_now)" = dot ]; then
		# DoT: наш dot-proxy — IP-литералы + SNI, bootstrap-DNS не нужен. CA ОБЯЗАТЕЛЕН
		# (бинарь без -C честно отказывается — непроверенный TLS хуже открытого UDP-осознанного).
		_ips=$(doh_resolver_ips | tr ' ' ',')
		_sni=$(dot_resolver_sni)
		_ca=$(doh_ca_file) || return 1
		[ -n "$_ips" ] && [ -n "$_sni" ] || return 1
		# Имя DoT-прокси не резолвит вовсе (IP-литералы + SNI) — закрепление для DoH ему не нужно и снимается.
		doh_pin_hosts
		# `-P` — порт резолвера (свой `tls://хост:порт`); 853 передаём тоже: ключ знают все сборки dot-proxy.
		start-stop-daemon -S -b -m -p "$DOH_PID" -x "$DOT_BIN" -- \
			-a "$DOH_ADDR" -p "$DOH_PORT" -r "$_ips" -P "$(doh_proto_port dot)" -s "$_sni" -C "$_ca" -l "$DOH_LOG"
		return $?
	fi
	case "$(doh_proto_now)" in doq|doh3)
		# DoQ/DoH3 — the QUIC program, dot-proxy's shape: IP literals + the TLS name, no bootstrap; `-m`, and for HTTP/3 the path. The
		# CA is as mandatory (the program refuses without it). A resolver without the name the certificate is checked by — refused.
		_dsq_p=$(doh_proto_now)
		_ips=$(doh_resolver_ips | tr ' ' ',')
		_sni=$(doh_proto_sni "$_dsq_p")
		_ca=$(doh_ca_file) || return 1
		[ -n "$_ips" ] && [ -n "$_sni" ] || return 1
		doh_pin_hosts
		if [ "$_dsq_p" = doq ]; then set -- -m doq; else set -- -m h3 -u "$(doh_quic_path)"; fi
		start-stop-daemon -S -b -m -p "$DOH_PID" -x "$QUIC_BIN" -- "$@" \
			-a "$DOH_ADDR" -p "$DOH_PORT" -r "$_ips" -P "$(doh_proto_port "$_dsq_p")" -s "$_sni" -C "$_ca" -l "$DOH_LOG"
		return $? ;;
	esac
	if [ "$(doh_proto_now)" = odoh ]; then
		# ODoH: -r — РЕТРАНСЛЯТОР (текущий по лестнице), -O — цель. Адреса обоих — АРГУМЕНТАМИ (-R/-W), а не только закреплением:
		# ключ цели программа берёт сама, и без -W её имя спрашивалось бы у системы — то есть у dnsmasq, который смотрит на ЭТОТ
		# прокси, ещё не знающий ключа (тупик; разбор — заметки разработки «ODoH-дизайн» §4). Программа, не умеющая ODoH, сюда не
		# доходит: её отсекает doh_installed первой строкой doh_start.
		_dso_r=$(doh_odoh_relay_url); _dso_t=$(doh_odoh_target_url)
		[ -n "$_dso_r" ] && [ -n "$_dso_t" ] || return 1
		_dso_ca=$(doh_ca_file) || return 1
		doh_pin_hosts
		set -- -C "$_dso_ca"
		_dso_i=$(doh_odoh_host_ips "$(doh_url_host "$_dso_r")" | awk '{$1=$1; gsub(/ /,","); print}'); [ -n "$_dso_i" ] && set -- "$@" -R "$_dso_i"
		_dso_i=$(doh_odoh_host_ips "$(doh_url_host "$_dso_t")" | awk '{$1=$1; gsub(/ /,","); print}'); [ -n "$_dso_i" ] && set -- "$@" -W "$_dso_i"
		start-stop-daemon -S -b -m -p "$DOH_PID" -x "$DOH_BIN" -- \
			-a "$DOH_ADDR" -p "$DOH_PORT" -4 -v -v -r "$_dso_r" -O "$_dso_t" -b 1.1.1.1 -l "$DOH_LOG" "$@"
		return $?
	fi
	spec=$(doh_resolver_spec)
	url=$(printf '%s' "$spec" | cut -f1)
	boot=$(printf '%s' "$spec" | cut -f2)
	[ -n "$url" ] || return 1
	ca=$(doh_ca_file) || return 1   # без CA статик-сборка не проверит сертификат ⇒ старт бессмыслен
	doh_pin_hosts                   # имя резолвера → его якоря, ДО старта: первый же резолв c-ares читает hosts
	set -- -C "$ca"
	start-stop-daemon -S -b -m -p "$DOH_PID" -x "$DOH_BIN" -- \
		-a "$DOH_ADDR" -p "$DOH_PORT" -4 -v -v -r "$url" -b "$boot" -l "$DOH_LOG" "$@"
}

doh_stop() {
	start-stop-daemon -K -p "$DOH_PID" >/dev/null 2>&1
	rm -f "$DOH_PID" 2>/dev/null
	doh_reap_stray            # добить всё, что не описано pidfile'ом: «выключил, а порт занят» недопустимо
}

# Перезапуск под новый резолвер / после transport switch (форс-марку резолвера ставит зовущий).
doh_restart() { doh_stop; doh_start; }

# ПОРТ, А НЕ ПРОЦЕСС. Живой pid не значит «готов принимать»: ЗАМЕРЕНО на железе 31.08.2026 —
# между стартом и «Listening» у https-dns-proxy проходит ~26-28 с (BE7000 и AX3600 одинаково),
# у dot-proxy столько же. Всё это время dnsmasq, уже уведённый на 127.0.0.1#5053, форвардит в
# никуда: сеть без имён, а функциональная проба честно проваливается и откатывает ИСПРАВНЫЙ DoH.
# Поэтому порядок такой: подняли -> ДОЖДАЛИСЬ порта -> и только потом трогаем DNS. Не дождались
# (умер или завис на инициализации) — DNS не трогаем ВООБЩЕ, и окна без имён не возникает.
# Умер по дороге — выходим сразу, ждать нечего.
# $1 — потолок ожидания в секундах (деф. 45: замеренные 28 + запас на медленный флеш). Само
# ожидание ведёт ОБЩИЙ владелец (daemon-lib.sh): «умер ⇒ отказ сразу, жив ⇒ ждём до потолка», и
# потолок он поднимет сам, если бинарь окажется на медленном накопителе. Причина отказа —
# в $DAEMON_WAIT_WHY (её печатает вызывающий).
doh_wait_listen() {
	_dwlb=$(doh_bin_for)
	daemon_wait_uport "$DOH_PID" "${_dwlb##*/}" "${1:-45}" "$DOH_ADDR" "$DOH_PORT"
}

# ПЕРЕЗАПУСК С ОЖИДАНИЕМ ПОРТА — по процессу, без секундомера. Было `doh_restart; sleep 1; doh_running || doh_start`:
# секунду давали «упасть сразу», и её платил КАЖДЫЙ подъём несущей (смена сервера, переподъём сторожа). Ожидание порта
# само судит по процессу (daemon-lib): умер — отвечает сразу, и тогда один повторный старт, как и раньше. 0 — слушает.
doh_restart_wait() {   # $1 — потолок ожидания порта, с (пусто — как у doh_wait_listen)
	doh_restart
	doh_wait_listen "$1" && return 0
	doh_running && return 1
	doh_start
	doh_wait_listen "$1"
}

# --- Применение DNS через DoH (единая точка входа для dns-сеттеров транспортов) ---
# Маркировка/RETURN :443 резолвера идут через ту же mangle-OUTPUT-цепочку, что и mark-core:
#  - tunnel-режим (awg/xray/hy2): форсим :443 резолвера в table 1000 — DoH-запрос уходит
#    ВНУТРЬ туннеля (как xray/hy2 форсят публичный :53), провайдер не видит даже резолвера;
#  - direct-режим (byedpi/zapret/релинквиш): держим :443 резолвера МИМО маркировки, иначе
#    его перехватил бы xtun→ciadpi и ДЕСИНКАЛ HTTPS/2-соединение DoH (резолв бы рвался).
# NB: марка/RETURN привязаны к IP ТЕКУЩЕГО резолвера; смену резолвера (teardown старого IP)
# делает панельный verb set_doh_resolver через doh_restart — здесь чистим лишь противоположный
# режим для того же резолвера (idempotent). Полный план — заметки разработки «DoH-план».
DOH_MARK=0x1                       # та же метка «в table 1000», что FWMARK транспортов

# Форс-марка порта резолвера текущего (или $2) резолвера в туннель. $1 = add|del. Идемпотентно,
# по ВСЕМ IP резолвера (doh_resolver_ips). add — порт АКТИВНОГО протокола (doh_wire_port);
# del — ВСЕ порты (doh_all_ports: teardown обязан быть proto-agnostic — смена протокола не должна
# оставлять висеть марку прежнего порта; del несуществующего правила = no-op, это дёшево).
# The transport of the rule is the active protocol's (doh_wire_l4: QUIC rides UDP); del — BOTH transports, as it is all ports: a move
# between DoH3 and DoH keeps the port (443) and changes only the transport.
doh_resolver_mark() {
	_drmp=$(doh_wire_port); _drma=$(doh_all_ports "$2"); _drml=$(doh_wire_l4)
	for _ip in $(doh_resolver_ips "$2"); do
		case "$1" in
			add) _prt=$_drmp
				iptables -t mangle -C OUTPUT -d "$_ip" -p "$_drml" --dport "$_prt" -j MARK --set-mark $DOH_MARK 2>/dev/null || \
				iptables -t mangle -A OUTPUT -d "$_ip" -p "$_drml" --dport "$_prt" -j MARK --set-mark $DOH_MARK ;;
			del) for _prt in $_drma; do for _drmq in tcp udp; do
				while iptables -t mangle -C OUTPUT -d "$_ip" -p "$_drmq" --dport "$_prt" -j MARK --set-mark $DOH_MARK 2>/dev/null; do
					iptables -t mangle -D OUTPUT -d "$_ip" -p "$_drmq" --dport "$_prt" -j MARK --set-mark $DOH_MARK 2>/dev/null || break
				done
			done; done ;;
		esac
	done
}

# doh_bootstrap_ip [имя] [any] — bootstrap-адрес резолвера, и ТОЛЬКО когда он реально используется:
# у резолвера ПО ИМЕНИ (google/quad9/adguard/nextdns, свой по имени) прокси при КАЖДОМ старте
# резолвит имя резолвера plain-DNS на этот адрес (c-ares, `-b`). URL по IP-литералу (cloudflare,
# свой по IP) bootstrap не трогает — пусто. DoT — тоже пусто: наш `dot-proxy` ходит по IP-литералам
# с SNI и bootstrap не делает вовсе, а RETURN :53 стал бы правилом без владельца.
# `any` — ответ БЕЗ оглядки на протокол, для СНЯТИЯ (teardown proto-agnostic, как у портов): протокол
# теперь меняется и сам (doh_dot_fallback/doh_dot_back), и снимать пришлось бы в строго одном порядке
# «сначала правила, потом флаг» — иначе RETURN :53, поставленный на время DoH, пережил бы возврат на DoT.
doh_bootstrap_ip() {
	[ "$2" != any ] && [ "$(doh_proto_now)" = dot ] && return 0
	[ "$2" != any ] && case "$(doh_proto_now)" in doq|doh3) return 0 ;; esac   # the QUIC program: IP literals, as DoT
	[ "${1:-$(doh_eff)}" = odoh ] && return 0   # ODoH: адреса — аргументами и закреплением, bootstrap не спрашивается
	_dbs=$(doh_resolver_spec "$1")
	_dbu=${_dbs%%$(printf '\t')*}; _dbi=${_dbs#*$(printf '\t')}
	_dbh=${_dbu#https://}; _dbh=${_dbh%%/*}; _dbh=${_dbh%%:*}
	case "$_dbh" in *[!0-9.]*) printf '%s' "$_dbi" ;; esac
}

# RETURN :443/:853 текущего (или $2) резолвера МИМО маркировки. $1 = add|del. Ставим ПЕРВЫМ в
# OUTPUT (-I 1), чтобы обойти mark-core, как dns_direct_rules в byedpi/zapret. Идемпотентно.
# BOOTSTRAP :53 — ТОЙ ЖЕ ДОРОГОЙ (ревью 05.09.2026). Резолвер по имени сперва резолвится сам —
# plain-DNS к bootstrap-адресу, а 8.8.8.8/9.9.9.9 лежат в iplist_set ⇒ без RETURN этот UDP:53
# метится в table 1000: в прямом режиме — под десинк xtun (UDP через socks не проходит), при уводе
# «мимо несущей» — в ту самую мёртвую несущую, и прокси не поднимался вовсе: увод работал только
# у cloudflare по IP-литералу. del снимает оба протокола (кто ставил — неважно).
doh_resolver_bypass() {
	_drbp=$(doh_wire_port); _drba=$(doh_all_ports "$2"); _drbl=$(doh_wire_l4)
	for _ip in $(doh_resolver_ips "$2"); do
		case "$1" in
			add) _prt=$_drbp
				iptables -t mangle -C OUTPUT -d "$_ip" -p "$_drbl" --dport "$_prt" -j RETURN 2>/dev/null || \
				iptables -t mangle -I OUTPUT 1 -d "$_ip" -p "$_drbl" --dport "$_prt" -j RETURN ;;
			del) for _prt in $_drba; do for _drbq in tcp udp; do
				while iptables -t mangle -C OUTPUT -d "$_ip" -p "$_drbq" --dport "$_prt" -j RETURN 2>/dev/null; do
					iptables -t mangle -D OUTPUT -d "$_ip" -p "$_drbq" --dport "$_prt" -j RETURN 2>/dev/null || break
				done
			done; done ;;
		esac
	done
	if [ "$1" = del ]; then _dbp=$(doh_bootstrap_ip "$2" any); else _dbp=$(doh_bootstrap_ip "$2"); fi
	[ -n "$_dbp" ] || return 0
	for _pro in udp tcp; do
		case "$1" in
			add) iptables -t mangle -C OUTPUT -d "$_dbp" -p "$_pro" --dport 53 -j RETURN 2>/dev/null || \
			     iptables -t mangle -I OUTPUT 1 -d "$_dbp" -p "$_pro" --dport 53 -j RETURN ;;
			del) while iptables -t mangle -C OUTPUT -d "$_dbp" -p "$_pro" --dport 53 -j RETURN 2>/dev/null; do
			         iptables -t mangle -D OUTPUT -d "$_dbp" -p "$_pro" --dport 53 -j RETURN 2>/dev/null || break
			     done ;;
		esac
	done
}

# doh_anchor_state [имя] — что стоит В ЯДРЕ СЕЙЧАС: `mark` | `bypass` | `none`. Спрашиваем по
# ПЕРВОМУ адресу резолвера: обе формы ставятся и снимаются по ВСЕМ его адресам разом, так что
# одного `iptables -C` довольно. Нужно ровно для одного вопроса — «якорь МЕНЯЕТСЯ?» (см.
# doh_apply_dns): смена якоря переносит живую TLS-сессию прокси на ДРУГОЙ путь, и её надо рвать.
# ПОРЯДОК ОПРОСА — ПОРЯДОК ЯДРА, А НЕ АЛФАВИТ (ревью 3, 06.09.2026). RETURN ставится `-I OUTPUT 1`,
# марка — `-A` (в конец): если в цепочке лежат ОБА (снятие марки не прошло из-за занятого
# xtables-лока, оборванный switch), выигрывает RETURN — и функция обязана назвать ЕГО, иначе
# `doh_apply_dns` решит «якорь не менялся» там, где путь резолвера реально переезжает. По той же
# причине АКТИВНЫЙ порт спрашиваем первым: осиротевшая `MARK :443` от прежней DoH-конфигурации не
# должна перебивать живой `RETURN :853` у DoT. Прочие порты (doh_all_ports) — следом, в любом порядке.
doh_anchor_state() {
	_das_ip=$(doh_resolver_ips "$1" | awk '{print $1; exit}')
	[ -n "$_das_ip" ] || { echo none; return 0; }
	_das_act=$(doh_wire_port); _das_l=$(doh_wire_l4)
	# The active transport first too (a leftover TCP rule of DoH must not outvote DoH3's live UDP one), then the other.
	for _das_q in "$_das_l" tcp udp; do
		for _das_p in "$_das_act" $(doh_all_ports "$1"); do
			iptables -t mangle -C OUTPUT -d "$_das_ip" -p "$_das_q" --dport "$_das_p" -j RETURN 2>/dev/null && { echo bypass; return 0; }
			iptables -t mangle -C OUTPUT -d "$_das_ip" -p "$_das_q" --dport "$_das_p" -j MARK --set-mark $DOH_MARK 2>/dev/null && { echo mark; return 0; }
		done
	done
	echo none
}

# doh_anchor_apply — ЕДИНСТВЕННЫЙ ответ «какое из двух правил резолвера должно стоять ПРЯМО СЕЙЧАС».
#
# ЗАЧЕМ ОДНИМ ВЛАДЕЛЬЦЕМ (ревью 15.08.2026). Правила два и они взаимоисключающие — форс-марка в
# несущую (tunnel) и RETURN мимо маркировки (direct), — а спрашивающих ТРОЕ: `doh_apply_dns` (ему
# режим называет плагин), `doh_retunnel` и `doh_custom_refresh`. Последние двое решали сами и решали
# ОДИНАКОВО НЕВЕРНО — ставили МАРКУ, потому что писались под awg/xray, где другого режима не бывает.
# Цена ошибки НЕСИММЕТРИЧНА (разбор — у doh_resolver_bypass): лишний RETURN = просевшая приватность,
# лишняя МАРКА в ПРЯМОМ режиме = HTTPS/2-сессия резолвера уезжает в xtun→ciadpi и десинкается, то
# есть мёртвый DNS у всего дома.
# Флаг «уведён мимо несущей» тут РАВНОСИЛЕН прямому режиму: несущая есть, но сторож ей не верит —
# значит резолверу в ней не место, и решение об этом принимает не вызывающий, а эта функция.
# А ВОТ `doh_apply_dns` НА ЭТУ ФУНКЦИЮ ПЕРЕВОДИТЬ НЕЛЬЗЯ (выглядит как напрашивающийся DRY, но
# сломает подъём): его зовут ИЗ up-пути несущей, когда `default` в table 1000 ещё не поставлен, —
# doh_direct_regime в этот момент честно ответит «прямой», и туннельный якорь не встанет никогда.
# Там режим называет ПЛАГИН, и он знает лучше сети.
doh_anchor_apply() {
	if doh_direct_regime || [ -f "$DOH_UNTUNNELED" ]; then
		doh_resolver_mark del; doh_resolver_bypass add
	else
		doh_resolver_bypass del; doh_resolver_mark add
	fi
}

# ---- РЕЗОЛВЕР МИМО НЕСУЩЕЙ, ПОКА ТА НЕ ВЕЗЁТ ------------------------------------------------
# ЗАЧЕМ (разобрано и замерено на BE7000 14.08.2026). В tunnel-режиме мы уводим :443 резолвера в
# table 1000 — в этом и смысл «шифрованный DNS через свой VPS». Но при DoH у dnsmasq остаётся
# РОВНО ОДИН upstream и никакого plain-фолбэка, поэтому «несущая не везёт» означает «DNS нет у
# всего дома». Дальше круг: конфиг ПО ИМЕНИ без DNS не поднимается — сеть не может починиться
# сама. На железе дом сидел без DNS 10+ минут при ЖИВОМ WAN: `doh_health_tick` сюда не доходит,
# он работает только в АВТО-режиме, а ручной тумблер не присматривает никто.
# РЕШЕНИЕ. Как только сторож усомнился в несущей — резолвер уходит МИМО неё. Это НЕ откат DoH:
# запросы по-прежнему шифрованы (тот же TLS к тому же резолверу), теряется лишь «провайдер не
# видит, чьим резолвером мы пользуемся» — цена, несопоставимая с домом без DNS. Возврат в туннель
# — на первом же тике, где health прошёл (и штатно, на любом `doh_apply_dns tunnel`).
# Флаг «резолвер уведён мимо несущей»; RAM ⇒ на буте состояние переберётся заново. Имя кончается
# на `.stamp`, и это НЕ косметика: содержимое — эпоха, а маску `*.stamp` обходит clock_rebase_stamps,
# то есть после сдвига часов на буте возраст флага в дампе остаётся честным (ревью 2, 06.09.2026).
DOH_UNTUNNELED="/tmp/.enodia-doh-untunneled.stamp"
# Возврат в несущую доказал, что ЧЕРЕЗ неё резолвер не отвечает (VPS не достаёт до 1.1.1.1:443) —
# отметка держит паузу перед следующей попыткой, иначе флип-флоп по два рестарта прокси каждый тик.
# Эпоха в /tmp ⇒ возраст через age_since, сдвиг часов переносит её clock_rebase_stamps.
DOH_RETUNNEL_STAMP="/tmp/enodia-doh-retunnel.stamp"
DOH_RETUNNEL_BACKOFF=${DOH_RETUNNEL_BACKOFF:-1800}

# doh_untunnel_apply — САМ УВОД, без гейтов «есть ли что уводить» (они у doh_untunnel; up-путь
# несущей зовёт увод без них — см. doh_apply_dns: там режим назвал плагин, и он знает лучше сети).
# Флаг ДО расстановки: правило выбирает doh_anchor_apply, и решает он именно по флагу. Затем
# РЕСТАРТ ПРОКСИ: у него ЖИВОЕ TLS/HTTP-2 соединение по УМЕРШЕМУ пути, правило маршрутизации его
# не разрывает, и без рестарта он молчал бы до своего внутреннего таймаута — то есть ровно те
# минуты без DNS, ради которых всё это и делается. dnsmasq смотрит на прокси ⇒ оставить его
# лежащим нельзя. И ДОЖДАТЬСЯ ПОРТА (doh_wait_listen): у прокси прежних сборок между стартом и
# «Listening» 26–46 с (блокирующий /dev/random, см. шапку doh_wait_listen), и проба сразу после
# рестарта ложилась бы в не слушающий порт — увод «не сработал бы» ровно там, где нужен; с новым
# бинарём ожидание — ноль. Код = слушает ли прокси после рестарта.
# `$1 = nowait` — НЕ ждать порта. Ждать имеет смысл ровно там, где СРАЗУ ЗА уводом идёт проба
# (up-путь): она и есть потребитель ожидания. Там, где пробы нет (сторож на SUSPECT, повторный
# увод после неудачного возврата), ожидание не защищает ничего, а на прежних сборках прокси
# СЪЕДАЕТ до 46 с тика — и в паре с возвратом это два ожидания подряд, больше двух минут под
# локом сторожа, то есть пропущенный следующий тик (ревью 2, 06.09.2026).
doh_untunnel_apply() {
	date +%s > "$DOH_UNTUNNELED" 2>/dev/null || : > "$DOH_UNTUNNELED"   # содержимое = эпоха увода (дамп печатает возраст)
	doh_anchor_apply
	doh_restart; sleep 1
	doh_running || doh_start
	[ "$1" = nowait ] && { doh_running; return $?; }
	doh_wait_listen
}

# doh_untunnel — увести резолвер мимо несущей. Код 0 = реально увели (вызывающему есть что сказать).
doh_untunnel() {
	doh_want || return 1                     # DNS держит не DoH — уводить нечего
	# ИЗ ПРЯМОГО РЕЖИМА УВОДИТЬ НЕКУДА И НЕЗАЧЕМ. Сторож зовёт нас из ОБЩЕЙ ветки «несущая под
	# подозрением», а в ней живут и byedpi с zapret — там резолвер и так стоит МИМО маркировки.
	# Без этого гарда КАЖДАЯ осечка health десинк-транспорта стоила рестарта прокси (секундный
	# провал DNS + холодный TLS) ради перестановки правил, которые уже стоят как надо, и оставляла
	# флаг, по которому doh_retunnel потом уводил резолвер ПОД ДЕСИНК (см. doh_anchor_apply).
	doh_direct_regime && return 1
	[ -f "$DOH_UNTUNNELED" ] && return 1     # уже уведён
	doh_untunnel_apply nowait                # пробы за уводом нет ⇒ и ждать порта незачем: не жжём тик
	return 0
}

# doh_retunnel — вернуть резолвер в несущую (health снова проходит). Код 0 = реально вернули;
# 2 = несущая везёт, а резолвер ЧЕРЕЗ неё не отвечает — оставлен мимо, пауза DOH_RETUNNEL_BACKOFF;
# 1 = делать нечего (флага нет, DoH выключен, пауза не вышла).
doh_retunnel() {
	[ -f "$DOH_UNTUNNELED" ] || return 1
	# doh_want спрашиваем ДО снятия флага: между уводом и возвратом DoH могли выключить, и тогда
	# стёртый флаг оставил бы RETURN :443 без единого напоминания о нём. Порядок «сначала проверить,
	# потом стирать» дороже ноль, а путаницы состояний не оставляет.
	doh_want || return 1
	[ "$(age_since "$(cat "$DOH_RETUNNEL_STAMP" 2>/dev/null | tr -cd '0-9')")" -ge "$DOH_RETUNNEL_BACKOFF" ] || return 1
	# ВОЗВРАЩАТЬ НЕКУДА, ПОКА МАРШРУТА НЕТ. Сторож зовёт нас на «health прошёл», а health
	# tunnel-транспорта идёт через socks и НЕ ЗНАЕТ, что `default` из table 1000 пропал (это чинит
	# heal_carrier_route НИЖЕ в том же тике). Сняв флаг в этот момент, мы получили бы «прямой» ответ
	# doh_anchor_apply, RETURN на месте и лог «резолвер вернулся в туннель» — враньё; вернёмся
	# следующим тиком, когда маршрут уже на месте (ревью 2, 06.09.2026). Спрашиваем ИМЕННО
	# `doh_direct_by_name`, а не `doh_direct_regime`: второй у транспорта с ПОТЕРЯННЫМ маршрутом
	# честно отвечает «прямой» — то есть ровно в чинимом случае разрешил бы возврат (ревью 3).
	doh_direct_by_name || [ -n "$(carrier_iface)" ] || return 1
	rm -f "$DOH_UNTUNNELED" 2>/dev/null
	# ЧТО ставить — спрашиваем владельца, а не «раз вернулись, значит марка». Флага уже нет, так что
	# в туннельном режиме это ровно прежнее поведение; в прямом (сюда доезжает лишь флаг, оставшийся
	# от версии ДО гарда в doh_untunnel) резолвер честно останется мимо маркировки.
	doh_anchor_apply
	if ! doh_direct_regime; then
		# ПРОКСИ — ТА ЖЕ БЕДА, ЧТО ПРИ УВОДЕ, ЗЕРКАЛЬНО: его сессия к резолверу поднята ПО WAN с
		# WAN-адресом источника, а после возврата марки те же пакеты уходят в несущую с этим адресом —
		# сервер WireGuard/AWG молча отбрасывает источник вне AllowedIPs пира, у tun2socks чужой
		# мид-стрим не имеет соединения (NAT для УЖЕ установленного соединения не пересчитывается).
		# Сессия висела бы до внутреннего таймаута прокси = возврат в туннель стоил бы минуту без DNS.
		# Рестарт + ожидание порта (у прежних сборок прокси до 46 с до «Listening», у новых — ноль).
		# Только в ТУННЕЛЬНОМ режиме: в прямом якорь не менялся, дёргать нечего.
		doh_restart_wait
		# ПРОВЕРИТЬ, А НЕ ПОВЕРИТЬ (ревью 05.09.2026). Up-путь мог увести резолвер потому, что ЧЕРЕЗ
		# несущую он не отвечает ВООБЩЕ (VPS не достаёт до 1.1.1.1:443, DPI на его стороне) при живом
		# рукопожатии — health несущей DNS-независим и не усомнится никогда, а вслепую вернувшийся
		# резолвер = дом без DNS при зелёном тумблере до следующего switch. Не пошли имена — уводим
		# обратно и молчим бэкофф.
		# ПРОБА ПРОВОЛОКИ ПЕРВОЙ, И БЕЗ НЕЁ ВСЯ ВЕТКА — ПУСТЫШКА (ревью 2, 06.09.2026): `doh_probe`
		# спрашивает ИМЯ через dnsmasq, а `example.com` тот закэшировал минуты назад — пробой up-пути,
		# которая шла МИМО несущей. Кэш живёт по TTL записи (заведомо дольше двух тиков), dnsmasq мы
		# здесь не рестартим ⇒ ответ пришёл бы из памяти и «доказал» бы работоспособность мёртвого
		# пути. `doh_wire_ok` идёт curl'ом на IP резолвера БЕЗ бинда — то есть ровно под только что
		# вернувшуюся марку, в несущую, и кэшировать там нечего.
		# …НО ПРОВОД ГОВОРИТ ЛИШЬ «TLS ВСТАЛ» (29.09.2026): у DoT через VPS рукопожатие встаёт за 4.3 с, а dot-proxy
		# до 1.2 рвал его через 3 с — провод жив, имён нет, и кэш «доказал» бы мёртвый путь. 1.2 ждёт 8 с, но старый
		# бинарь живёт на роутере до переустановки компонента, а «TLS встал ≠ прокси отвечает» верно и без него.
		# Поэтому имена — МИМО кэша (doh_names_ok), это редкая ветка, сброс кэша здесь дёшев (ревью ветки
		# fix/dot-port-fallback, круг 2).
		if ! doh_wire_ok || ! doh_names_ok 3; then
			# ПОРТ, А НЕ ПУТЬ? Несущая везёт (health прошёл, маршрут на месте), а резолвер через неё молчит — у
			# альт-выхода это закрытый сервером 853 при живом 443 (09.09.2026). Тогда в туннель возвращаемся
			# по DoH того же резолвера, а не уходим обратно мимо несущей на полчаса.
			if doh_dot_rescue || doh_odoh_rescue || doh_quic_rescue; then rm -f "$DOH_RETUNNEL_STAMP" 2>/dev/null; return 0; fi
			# Отказ увода не глотаем МОЛЧА: dnsmasq в этот момент уже смотрит в :5053, и «прокси не
			# поднялся» — единственный след того, почему дом остался без имён (ревью 3, 06.09.2026).
			# Пишем в лог самого прокси: своего лога у библиотеки нет, а вызывающий (сторож) видит
			# только код возврата.
			doh_untunnel_apply nowait || echo "$(date '+%Y-%m-%d %H:%M:%S') [doh] возврат не удался: прокси после увода обратно не слушает — DNS молчит до следующего тика" >> "$DOH_LOG" 2>/dev/null
			# ФОЛБЭК ОБЯЗАТЕЛЕН: пустая отметка читается как возраст 999999, то есть «пауза вышла» —
			# и получился бы флип-флоп каждые две минуты вместо паузы (ревью 3, 06.09.2026).
			date +%s > "$DOH_RETUNNEL_STAMP" 2>/dev/null || : > "$DOH_RETUNNEL_STAMP" 2>/dev/null
			return 2
		fi
	fi
	rm -f "$DOH_RETUNNEL_STAMP" 2>/dev/null
	return 0
}

# Откат авто-режима: снять RETURN :443 резолвера, погасить прокси, снять стамп. Зовущий получает 1
# и дальше пишет СВОЙ прежний upstream (plain 1.1.1.1/8.8.8.8) + рестартит dnsmasq ⇒ DNS не остаётся
# висеть на мёртвом/глухом прокси. Ручной режим (тумблер) не откатываем — там выбор пользователя.
# ОБЩИЙ ОТКАТ «DoH не взял DNS»: снять правила резолвера (ставим одну форму из двух — какую,
# зависит от режима, поэтому чистим обе; удаление идемпотентно) и погасить бесполезный прокси.
# Флаг `.doh-on` НЕ трогаем: это НАМЕРЕНИЕ пользователя, и решать его судьбу — не библиотеке, а
# тому, кто видит человека (панельный верб doh_on). Осиротевшая форс-марка резолвера, найденная
# на AX3600 31.08.2026, приехала ровно отсюда — прежний откат чистил только bypass.
doh_dns_bailout() {
	doh_resolver_mark del
	doh_resolver_bypass del
	doh_stop
	# Флаг «уведён» и пауза возврата — состояние ТОЙ проводки, которой больше нет: стейл-флаг доезжал
	# бы до doh_anchor_apply через keepalive сторожа и ставил RETURN вместо марки.
	rm -f "$DOH_UNTUNNELED" "$DOH_RETUNNEL_STAMP" 2>/dev/null
	# Закрепление имени резолвера — проводка того же прокси: DNS отдан прежнему пути, и держать имя прибитым незачем.
	command -v seed_hosts_clear >/dev/null 2>&1 && { seed_hosts_clear "$DOH_PIN_OWNER" >/dev/null 2>&1; doh_pin_relays clear; }
	return 0
}

doh_auto_rollback() {
	rm -f "$DOH_AUTO_STAMP" 2>/dev/null
	doh_dns_bailout
}

# ПАУЗА ПОСЛЕ НЕУДАЧНОЙ ПЕРЕПРОВОДКИ РУЧНОГО DoH (бэклог ветки fix/dot-port-fallback, (4)). Резолвер мёртв на ОБОИХ путях
# (в несущей и мимо неё): doh_apply_dns честно откатывается (doh_dns_bailout гасит прокси, плагин пишет свой DNS), а тумблер
# остаётся — это намерение человека. Дальше круг на КАЖДОМ тике сторожа: keepalive видит «DoH нужен, прокси не бежит» и
# поднимает его, сверка указателя видит «прокси жив, dnsmasq мимо» и зовёт `transport.sh dns` — то есть снова три пробы
# имён, пробы провода, увод, откат: до минуты под локом сторожа и ДВА рестарта dnsmasq всему дому каждые две минуты. У
# авто-режима тот же круг разрывает свой карантин (DOH_AUTO_COOLDOWN), у ручного разрывать было нечем. Отметку ставит
# провал doh_apply_dns в ручном режиме, снимает — ЛЮБАЯ перепроводка (она и есть попытка): бут, тумблер, смена
# транспорта и резолвера приходят через doh_apply_dns и пробуют сразу; сторож ждёт срок. DNS в паузе цел — его держит
# прежний путь транспорта, прокси ему не нужен.
DOH_BAIL_STAMP="/tmp/.enodia-doh-bail.stamp"
DOH_BAIL_BACKOFF=${DOH_BAIL_BACKOFF:-900}
# ОТКАТ ПРОВАЛИВШЕЙСЯ ПЕРЕПРОВОДКИ — одна ветка на все провалы doh_apply_dns (не встал, не слушает, имён нет): авто-режим
# уходит в свой карантин, ручной — в эту паузу. `_doh_auto` — режим, названный doh_apply_dns в начале вызова.
doh_apply_fail() {
	doh_quic_preset_settle fail   # a provisional rung that never gave names goes (doh_quic_preset)
	if [ "$_doh_auto" = 1 ]; then doh_auto_rollback; return 0; fi
	doh_dns_bailout
	# ПАУЗА — ТОЛЬКО КОГДА ВИНОВАТ РЕЗОЛВЕР, а не мёртвый WAN (ревью ветки fix/dot-tails, круг 1): провал перепроводки в провал
	# провайдера ставил 15 минут открытого DNS ПОСЛЕ возврата связи — сторож до ветки возвращал DoH за ≤2 мин. Судим локальными
	# признаками владельца (`ip-lib.sh::wan_up`: линк и дефолт, без пробы); «линк есть, интернета нет» так не отличить — ту паузу
	# снимает сторож, когда подтверждённая авария провайдера кончилась (doh_bail_forget ниже). Нет библиотеки — пауза как была.
	if command -v wan_up >/dev/null 2>&1 && ! wan_up; then return 0; fi
	date +%s > "$DOH_BAIL_STAMP" 2>/dev/null
	return 0
}
# ЗАБЫТЬ ПАУЗУ — зовёт сторож, когда ПОДТВЕРЖДЁННАЯ авария провайдера («линк есть, интернета нет») кончилась (watchdog.sh::
# wan_out_clear). Пауза отвечает на «резолвер не отвечает», а в аварии не отвечал весь интернет: не сними её, и после возврата
# связи дом ещё до 15 минут резолвил бы открыто — сторож до паузы возвращал DoH за ≤2 мин (остаток ревью ветки fix/dot-tails,
# круг 1). Звать ТОЛЬКО на конце эпизода, а не на каждом здоровом тике: иначе пауза не держала бы ничего, и вернулся бы круг
# «поднять → перепровести → пробы → откат» каждые две минуты.
doh_bail_forget() { rm -f "$DOH_BAIL_STAMP" 2>/dev/null; return 0; }
# Код 0 = сторожу сейчас уместно поднимать прокси и возвращать на него dnsmasq (паузы нет или она вышла).
doh_rearm_due() {
	[ -f "$DOH_BAIL_STAMP" ] || return 0
	[ "$(age_since "$(cat "$DOH_BAIL_STAMP" 2>/dev/null | tr -cd '0-9')")" -ge "$DOH_BAIL_BACKOFF" ]
}

# Функциональная проба резолва через УЖЕ переключённый dnsmasq→прокси. Живого pid мало: резолвер
# может быть недостижим (ISP режет :443 к 1.1.1.1, VPS лежит) — прокси бежит, ответов нет, DNS
# всего дома мёртв. $1 — число попыток (деф. 2: HTTP/2-сессия прокси и рестарт dnsmasq не мгновенны).
# Каждая попытка ОГРАНИЧЕНА 4 с: busybox nslookup сам ждёт до ~10 с, а нам ценнее дать прокси ЕЩЁ
# попытку, чем досидеть одну (у DoT цена холодного старта — рукопожатие; на железе 2026-07-27 первый
# же медленный anycast-узел Cloudflare:853 давал ЛОЖНОЕ «протокол не заработал» и откат, хотя через
# минуту тот же переключатель проходил). Две попытки покрывают рукопожатие до ~9 с: вторая стартует
# на 6-й секунде, её запрос ждёт в очереди UDP, пока dot-proxy (срок рукопожатия 8 с с версии 1.2)
# не поднимет TLS, — а через VPS оно встаёт за 4.3–4.7 с (замер 29.09.2026).
# ИМЯ — СВЕЖЕЕ НА КАЖДУЮ ПОПЫТКУ (doh_probe_name), и ответить на него может только апстрим. Прежде спрашивали сам
# `example.com` — а его dnsmasq отдаёт из КЭША (смена резолвера, протокола, пары ODoH при включённом шифровании upstream-строку
# не меняет, и dnsmasq не рестартует) и из /etc/hosts, когда имя закреплено нами (свой ретранслятор ODoH `https://example.com/`
# — его якоря doh_pin_hosts пишет туда). ЗАМЕР BE7000 16.10.2026: set_odoh с таким ретранслятором прошёл пробу, и дом остался
# без имён, хотя ни одного ответа прокси не дал. Отрицательный ответ на свежее имя кэшу взять неоткуда.
# ВЕРДИКТ — по тексту busybox nslookup (он печатает ошибку резолвера libc): «Name does not resolve» (musl: NXDOMAIN; замер BE7000
# и AX3600 16.10.2026; «Name or service not known» — uclibc/glibc) = апстрим ответил; «Try again» (SERVFAIL, молчащий апстрим) и
# обрыв по сроку — нет. Адрес на выдуманное имя — тоже ответ апстрима (подстановка), КРОМЕ заглушки 0.0.0.0/:: — её отдаёт сам
# dnsmasq по `address=` блок-списка, не спросив никого.
# musl 1.2.5 (busybox 1.36.1 — BE10000 Pro RP04, the new 6.6-kernel Xiaomi builds) prints the same NXDOMAIN as «Name has no usable
# address» (its EAI_NODATA text): unknown here, EVERY probe read «резолвер не ответил» over a working proxy, and «Шифровать всегда»
# never stayed on (21 refusals in the tester's journal, 29.10.2026). SERVFAIL there is still «Try again» (measured: dnssec-failed.org).
doh_probe() {
	_pn=${1:-2}; _pi=0
	while [ "$_pi" -lt "$_pn" ]; do
		_pi=$((_pi+1))
		_po=$(timeout -t 4 nslookup "$(doh_probe_name)" 2>&1); _prc=$?
		case "$_po" in *'Name does not resolve'*|*'Name or service not known'*|*'Name has no usable address'*|*NXDOMAIN*) return 0 ;; esac
		# Адреса ответа — строки ПОСЛЕ «Name:» (выше — адрес самого сервера, 127.0.0.1).
		[ "$_prc" = 0 ] && printf '%s\n' "$_po" | awk '/^Name:/ { n = 1; next } n && /^Address/ && $NF != "0.0.0.0" && $NF != "::" { f = 1 } END { exit !f }' && return 0
		[ "$_pi" -lt "$_pn" ] && sleep 2
	done
	return 1
}
# Свежее имя пробы: метка — 12 случайных hex-знаков ядра (uuid; нет его — pid и эпоха), домен — example.com: зарезервирован
# (RFC 2606), подстановки у него нет — на любую метку NXDOMAIN (замер BE7000 и AX3600 16.10.2026).
doh_probe_name() {
	_pnr=$(cut -c1-13 /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
	[ -n "$_pnr" ] || _pnr="$$$(date +%s)"
	echo "p$_pnr.example.com"
}

# ДОСТИЖИМ ЛИ САМ РЕЗОЛВЕР — проба МИМО dnsmasq и его кэша, дополнение к doh_probe. Нужна потому,
# что doh_probe спрашивает ИМЯ через dnsmasq, а тот кэширует: ответ из кэша означает лишь «имя
# когда-то резолвилось», и деградация резолвера пряталась бы до истечения TTL записи. Тут щупаем
# ТУ ЖЕ проволоку, которой ходит прокси (IP резолвера + его порт) — а именно её и душит ISP в
# инциденте 09.08.2026. Адрес — ЛИТЕРАЛ, DNS для самой пробы не нужен.
# Бинда к WAN здесь НЕТ и быть не должно (в отличие от фолбэка резолва в dns-lib): мы меряем путь
# ПРОКСИ, а он ходит как есть.
# ВЕРДИКТ — «TLS СОСТОЯЛСЯ» (`time_appconnect` > 0), а НЕ КОД ВЫХОДА curl. Прежде «мертво» читали по кодам
# 7/28/35 в расчёте, что DoT-сервер на HTTP-запрос рвёт соединение (52/56). ЗАМЕР BE7000 29.09.2026: не рвёт —
# Cloudflare :853 после рукопожатия за 0.19 с молча ждёт свой DNS-кадр, curl досиживает до --max-time и выходит
# с 28, то есть ЖИВОЙ DoT объявлялся мёртвым (и авто-режиму, и возврату в несущую, и переезду порта). Ждать тела
# незачем вовсе: `--speed-time 2 --speed-limit 1` снимает curl через 2 с тишины ПОСЛЕ рукопожатия (на самом
# рукопожатии этот предел не действует — замерено: TLS 4.3 с прошёл целиком). У DoH :443 ответ 301/404 приходит
# сразу. Ошибиться в сторону «жив» дёшево — рядом работает doh_probe; ошибка в другую сторону снесла бы РАБОЧИЙ
# резолвер и посадила дом на открытый DNS.
# ТАЙМАУТ ЩЕДРЫЙ, и это ЗАМЕР, а не осторожность: на BE7000 09.08.2026 при ЗАВЕДОМО живом
# резолвере (его `/dns-query` отвечал 200 пять раз из пяти) TCP-коннект к 1.1.1.1:443 занимал
# 0.06 с, а TLS-хендшейк — 4.35..4.45 с (один прогон из пяти уложился в 0.18 с); 29.09.2026 — то же у
# 1.0.0.1:853 и :443 через awg0 (4.3–4.5 с). С кэпом 4 с функция давала «мертво» 3 раза из 3, то есть ровно ту
# дорогую ошибку, от которой сама же и страхует. Цена щедрости платится только в аварии.
# ЧЕСТНО ПРО ЗАМЕР: медленное рукопожатие — путь VPS (мы не биндимся к WAN, curl уходит в несущую); мимо туннеля
# тот же путь укладывается в ~0.1 с. Кэп обязан переживать ОБА: бинда у нас нет намеренно.
# $1 — ПРОТОКОЛ doh|dot (деф. активный): порт и имя берём у владельца (doh_proto_port/doh_proto_sni), а не литералом
# — у своего резолвера порт бывает нестандартным, и проба «443 жив» при прокси на :8443 мерила бы не тот провод.
# ИМЯ — В SNI (`--resolve имя:порт:IP`): резолвер, которому SNI обязателен (NextDNS отдаёт профиль по имени, часть
# своих резолверов без SNI рвёт рукопожатие), без имени «мёртв на проводе» ВСЕГДА — а прокси, предъявляющий имя,
# при этом работал бы. У IP-литерала (cloudflare по 1.1.1.1) имени нет и у прокси — щупаем так же, по адресу.
# ДРУГОЙ порт щупаем ТЕМ ЖЕ ПУТЁМ, что ходит прокси: ставим на
# время пробы правило той же формы (марка в несущую / RETURN мимо неё) и снимаем после. Без него «443 жив»
# мерил бы общий путь, а не тот, на который мы собрались переезжать (doh_dot_rescue).
# ПРАВИЛО ПРОБЫ ОТЛИЧИМО от настоящего: оно ловит только порты источника DOH_PROBE_SPORTS, а curl пробы
# берёт порт оттуда же (`--local-port`). Побайтная копия настоящего правила снималась бы ВМЕСТЕ с ним: CGI
# смены протокола лока сторожа не берут, и настоящий RETURN :443, поставленный в окно пробы, пропадал бы —
# в прямом режиме это DoH-сессия под десинком (ревью ветки, круг 1). Заодно проба не трогает путь живого прокси.
# АДРЕСА — ПАРАЛЛЕЛЬНО, а не по очереди: у мёртвого порта каждый адрес съедает весь кэп, и два адреса
# по очереди стоили 20 с — а ждут этого ответа при уже переведённом на прокси dnsmasq, то есть дом без
# имён (up-путь) или тик сторожа под локом. Параллельно — один кэп на любое число адресов. `wait <pid>`
# отдаёт код ИМЕННО этого задания и для уже закончившегося (замер busybox 1.25.1 на BE7000, 29.09.2026);
# голый `wait` ждал бы и чужие фоновые задания вызывающего.
# АДРЕСА — ОДНИМ СНИМКОМ на весь вызов (ревью ветки, круг 3): CGI смены резолвера лока сторожа не берёт, и снятие по
# НОВЫМ адресам оставляло правила пробы на старых навсегда.
# $2 — THE FORM of the probe rule (mark|bypass), forced: a resolver whose addresses have no anchors yet (the CGI asks a NEW
# resolver's QUIC before switching to it, its rules are laid only after) is probed the way it WILL travel, not the default way of
# its addresses — the caller reads the form from the anchors it is about to replace (s.151: the router checks DoQ/DoH3 itself).
DOH_WIRE_TIMEOUT=${DOH_WIRE_TIMEOUT:-10}
DOH_PROBE_SPORTS=${DOH_PROBE_SPORTS:-40000:40099}   # `--sport` правила пробы; curl получает тот же диапазон через «-»
doh_wire_ok() {
	_dwpr=${1:-$(doh_proto_now)}
	# WHOSE wire: while ODoH is chosen only ODoH's own (odoh, its DoH fallback) are ODoH's — a DoQ/DoH3/DoT probe asked then (the CGI's
	# check before leaving it) is the RESOLVER's: its addresses, name and port (review s.151 r2 L1, r3 L2 — the name and the port came
	# from ODoH too, and a DoQ probe had no name at all).
	_dwk=''
	if [ "$(doh_eff)" = odoh ]; then case "$_dwpr" in odoh|doh) : ;; *) _dwk=$(doh_resolver_name) ;; esac; fi
	# $_dwk — без кавычек намеренно: пусто = «как выбрано» (doh_eff), иначе ключ резолвера.
	_dwp=$(doh_proto_port "$_dwpr" $_dwk); _dwsn=$(doh_proto_sni "$_dwpr" $_dwk)
	_dwt=''; _dwl=''; _dwips=$(doh_resolver_ips $_dwk)
	# ODoH: адресов у «резолвера» два рода — проводом протокола ходят к одному из них: ODoH — к ретранслятору, его откат DoH — к цели.
	# Чужой адрес с этим SNI «доказал» бы жизнь не того провода.
	if [ -z "$_dwk" ] && [ "$(doh_eff)" = odoh ]; then
		case "$_dwpr" in
			odoh) _dwips=$(doh_odoh_host_ips "$(doh_url_host "$(doh_odoh_relay_url)")") ;;
			doh)  _dwips=$(doh_odoh_host_ips "$(doh_url_host "$(doh_odoh_target_url)")") ;;
		esac
	fi
	# Another wire = another port OR another transport: DoH3 and DoH share 443, and a TCP rule does not carry QUIC's UDP.
	_dwq=$(doh_wire_l4 "$_dwpr")
	if [ -n "${2:-}" ] || [ "$_dwp" != "$(doh_wire_port)" ] || [ "$_dwq" != "$(doh_wire_l4)" ]; then
		_dwt=${2:-$(doh_anchor_state)}
		case "$_dwt" in
			mark|bypass) doh_probe_rule add "$_dwt" "$_dwp" "$_dwips" "$_dwq"; _dwl="--local-port ${DOH_PROBE_SPORTS%:*}-${DOH_PROBE_SPORTS#*:}" ;;
			*)           _dwt='' ;;
		esac
	fi
	_dwj=''
	# QUIC: no HTTP/3 in the router's curl — the program itself is the probe (`-Q`: the handshake completed — curl's time_appconnect),
	# from the probe's source ports (`-L`), with the same name and port the proxy uses; addresses in parallel, one ceiling, as below.
	case "$_dwpr" in doq|doh3)
		# Every early return takes the probe rule with it (the CA branch had left one per call — review s.150, round 1).
		_dwca=$(doh_ca_file) && [ -n "$_dwsn" ] || { [ -n "$_dwt" ] && doh_probe_rule del "$_dwt" "$_dwp" "$_dwips" "$_dwq"; return 1; }
		_dwm=doq; [ "$_dwpr" = doh3 ] && _dwm=h3
		# The program binds the FIRST free port from -L's start: a fixed start put every probe on 40000, and conntrack keeps a UDP entry
		# 30–180 s — a probe in the other form (mark ↔ RETURN) on the same port rode the old entry's NAT out of the wrong interface and
		# read «QUIC dead» (review s.150, round 1). A random start, with room for the parallel probes (one per address) below the top.
		_dwlq=''
		if [ -n "$_dwl" ]; then
			_dwlo=${DOH_PROBE_SPORTS%:*}; _dwhi=${DOH_PROBE_SPORTS#*:}; _dwsp=$((_dwhi - _dwlo - 7)); [ "$_dwsp" -gt 0 ] || _dwsp=1
			_dwrn=$(tr -cd 1-9 < /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-4); _dwrn=${_dwrn:-$$}   # 1-9: no octal
			_dwlq="-L $((_dwlo + _dwrn % _dwsp)):$_dwhi"
		fi
		for _dwi in $_dwips; do
			# $_dwlq — без кавычек намеренно: пусто или два слова.
			"$QUIC_BIN" -Q -m "$_dwm" -r "$_dwi" -s "$_dwsn" -P "$_dwp" -T $((DOH_WIRE_TIMEOUT * 1000)) $_dwlq -C "$_dwca" >/dev/null 2>&1 &
			_dwj="$_dwj $!"
		done
		_dwr=1
		for _dwk in $_dwj; do wait "$_dwk" && _dwr=0; done
		[ -n "$_dwt" ] && doh_probe_rule del "$_dwt" "$_dwp" "$_dwips" "$_dwq"
		return $_dwr ;;
	esac
	for _dwi in $_dwips; do
		if [ -n "$_dwsn" ]; then _dwu="https://$_dwsn:$_dwp/"; _dwrs="--resolve $_dwsn:$_dwp:$_dwi"; else _dwu="https://$_dwi:$_dwp/"; _dwrs=''; fi
		# $_dwl/$_dwrs — без кавычек намеренно: пусто или два слова (`--local-port A-B`, `--resolve имя:порт:IP`;
		# имя прошло строгий разбор — пробелов в нём нет).
		( _dwa=$(curl -s -k -o /dev/null $_dwl $_dwrs -w '%{time_appconnect}' --connect-timeout "$DOH_WIRE_TIMEOUT" \
		         --max-time "$DOH_WIRE_TIMEOUT" --speed-time 2 --speed-limit 1 "$_dwu" 2>/dev/null)
		  awk -v a="$_dwa" 'BEGIN{exit !(a+0 > 0)}' ) &
		_dwj="$_dwj $!"
	done
	_dwr=1
	for _dwk in $_dwj; do wait "$_dwk" && _dwr=0; done
	[ -n "$_dwt" ] && doh_probe_rule del "$_dwt" "$_dwp" "$_dwips" "$_dwq"
	return $_dwr
}

# Правило ПРОБЫ порта $3 в форме $2 (mark|bypass), $1 = add|del, $4 — адреса (снимок вызывающего; пусто — текущие).
# Место в цепочке — как у настоящего той же формы (марка — в конец, RETURN — первым), чтобы проба шла ровно тем
# путём, которым пойдёт прокси.
# $5 — the transport (tcp, the default; udp for a QUIC probe).
doh_probe_rule() {
	case "$2" in mark) _dprj="MARK --set-mark $DOH_MARK"; _dpra="-A OUTPUT" ;; bypass) _dprj=RETURN; _dpra="-I OUTPUT 1" ;; *) return 0 ;; esac
	_dprq=${5:-tcp}
	for _dpri in ${4:-$(doh_resolver_ips)}; do
		# $_dprj/$_dpra — без кавычек намеренно: цель и место — по нескольку слов.
		if [ "$1" = add ]; then
			iptables -t mangle -C OUTPUT -d "$_dpri" -p "$_dprq" --dport "$3" --sport "$DOH_PROBE_SPORTS" -j $_dprj 2>/dev/null || \
			iptables -t mangle $_dpra -d "$_dpri" -p "$_dprq" --dport "$3" --sport "$DOH_PROBE_SPORTS" -j $_dprj
		else
			while iptables -t mangle -C OUTPUT -d "$_dpri" -p "$_dprq" --dport "$3" --sport "$DOH_PROBE_SPORTS" -j $_dprj 2>/dev/null; do
				iptables -t mangle -D OUTPUT -d "$_dpri" -p "$_dprq" --dport "$3" --sport "$DOH_PROBE_SPORTS" -j $_dprj 2>/dev/null || break
			done
		fi
	done
}

# ---- ПЕРЕЕЗД ПОРТА: DoT → DoH ТОГО ЖЕ резолвера ПО ТОМУ ЖЕ пути ------------------------------
# ЗАЧЕМ (замер 09.09.2026, жалоба «xray не пашет»). Выбран DoT, активен VLESS-выход: 853 через него не
# проходит ни к одному резолверу, 443 идеален. dnsmasq отдан прокси ⇒ DNS мёртв у всего дома, кроме рунета
# (его уводит раздельный резолв), — человек видит зелёную панель, рабочий рунет и мёртвый ютуб и винит
# транспорт. Прокси при этом жив и вторые сутки пишет таймауты в лог: «демон жив ≠ сервис работает», и
# рестарт не лечит ничего — лечит смена ПОРТА. Увод мимо несущей меняет ПУТЬ и от этой беды не спасает:
# несущая здорова, а мимо неё 853 у провайдера тоже под вопросом.
# ПОЧЕМУ DoH, А НЕ ОТКАТ ШИФРОВАНИЯ: тот же резолвер и тот же путь (форма якоря сохраняется: марка в несущую
# остаётся маркой, RETURN — RETURN'ом), шифрование на месте, а для нашей модели угроз DoH не слабее DoT —
# он неотличим от веб-трафика (разбор — заметки разработки «DoH-план»). НАМЕРЕНИЕ человека (`.doh-proto=dot`) не
# трогаем: флаг живёт в ОЗУ, а сторож раз в DOH_DOT_RETRY щупает 853 и возвращает DoT сам (doh_port_tick).
# ВЛАДЕЛЕЦ ПЕРЕЕЗДА ОДИН — doh_dot_fallback/doh_dot_back: они же пишут событие в журнал. Только журнал, без
# письма: связь и шифрование сохранены, это объяснение, а не авария (тот же выбор, что у clock_step_event).
DOH_DOT_RETRY=${DOH_DOT_RETRY:-3600}   # через сколько после переезда (или прошлой попытки) снова щупать DoT (сек)
# How often the watchdog's tick looks for trouble of the chosen protocol (DoT port, ODoH relays), sec: EVERY tick (cron 2 min; 90 —
# room for the tick's start jitter). It was 600, and «Шифровать всегда» with a mute relay or 853 left the house without names
# 10–12 min. Looking is cheap: the proxy's journal and a fresh name — and for DoT one TLS handshake to the resolver per tick
# (doh_dot_troubled: an idle path writes no errors to the journal). What costs — a move, the ladder, a return — has its own back-off.
DOH_PORT_EVERY=${DOH_PORT_EVERY:-90}
DOH_PORT_STAMP="/tmp/.enodia-doh-port.stamp"
# Когда в последний раз ПРОБОВАЛИ вернуть DoT (эпоха). Отдельно от флага: флаг хранит ВРЕМЯ ПЕРЕЕЗДА, и
# неудачная попытка, переписывая его, раз в час обнуляла бы «переведён на DoH N назад» на экране и в дампе.
DOH_DOT_TRY="/tmp/.enodia-dot-try.stamp"
# НА КАКОМ ПУТИ случился переезд: «<транспорт> <форма якоря>» (бэклог ветки fix/dot-port-fallback, (10)). Вердикт «853
# не проходит» — про ПУТЬ, а жил он дольше пути: сменили транспорт (xray с закрытым 853 → awg, где DoT жив), включили
# авто-режим в прямом режиме, резолвер увели мимо несущей — и до часа роутер шифровал по DoH там, где DoT работает.
# Путь сменился ⇒ вердикт устарел: перепроводка (doh_apply_dns) пробует DoT сразу, тик сторожа — не дожидаясь
# DOH_DOT_RETRY. Файла нет (переезд прежней версии) — вердикт живёт по часам, как раньше.
DOH_DOT_PATH="/tmp/.enodia-dot-path"
doh_dot_path_id() { printf '%s %s\n' "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" "$1"; }

# ---- TWO LEVELS OF ONE LADDER (dev notes «DoQ-DoH3-дизайн» §4) ------------------------------------------------------------------
# A move is the same at both: the resolver's rules move to the other protocol's port (and transport) in the SAME form — a mark stays a
# mark, a RETURN a RETURN — the proxy restarts on the other program, and the move counts only when names go, else back where it was.
#   dot  — DoT → DoH of the same resolver (the 09.09.2026 case above); the chosen protocol dot.
#   quic — DoQ → DoT → DoH, DoH3 → DoH (2026-10-19): QUIC is dropped on the way more often than TCP, and the rungs below run on the
#          OTHER TLS stack. The rung the proxy stands on is the flag's second word («<epoch> <rung>»), and a mute rung falls further.
# Files per level — doh_lv; the mechanism is one. The QUIC level keeps a second stamp, of failed MOVES (`_lvd`): on a rung it both
# tries to go back up and may have to fall further, and one stamp for both would let a failed look up hold a mute rung for an hour.
# At the DoT level the two are one file — its behaviour of before byte for byte.
DOH_QUIC_RETRY=${DOH_QUIC_RETRY:-3600}   # how long after a move (or the last try) the QUIC protocol is tried again (sec)
DOH_QUIC_TRY="/tmp/.enodia-quic-try.stamp"
DOH_QUIC_DOWN="/tmp/.enodia-quic-down.stamp"
DOH_QUIC_PATH="/tmp/.enodia-quic-path"
# A CLIMB to a middle rung (doh_lv_up) — at most one per DOH_QUIC_RETRY; falls stay immediate. Without it a lossy path switched DoT ↔ DoH
# on every tick, a proxy restart each (review s.150, round 3).
DOH_QUIC_UP="/tmp/.enodia-quic-up.stamp"
doh_lv_climb_ok() { _dlc=$(cat "$DOH_QUIC_UP" 2>/dev/null | tr -cd '0-9'); [ -z "$_dlc" ] || [ "$(age_since "$_dlc")" -ge "$DOH_QUIC_RETRY" ]; }
doh_lv() {   # <level> → _lvf (flag) _lvt (last try back) _lvd (last failed move) _lvp (path of the verdict) _lvr (retry, sec)
	case "$1" in
		quic) _lvf=$DOH_QUIC_FALLBACK; _lvt=$DOH_QUIC_TRY; _lvd=$DOH_QUIC_DOWN; _lvp=$DOH_QUIC_PATH; _lvr=$DOH_QUIC_RETRY ;;
		*)    _lvf=$DOH_DOT_FALLBACK;  _lvt=$DOH_DOT_TRY;  _lvd=$DOH_DOT_TRY;   _lvp=$DOH_DOT_PATH;  _lvr=$DOH_DOT_RETRY ;;
	esac
}
# The level of the chosen protocol: dot | quic | empty (doh and odoh have no port ladder — ODoH's own is below).
doh_lv_of() { case "$(doh_proto)" in dot) echo dot ;; doq|doh3) echo quic ;; esac; }
# The rungs a level falls to, in order, whose program is here: dot → doh; quic → DoQ: dot doh, DoH3: doh.
doh_lv_rungs() {
	_dlg=''
	case "$1" in
		quic) case "$(doh_proto)" in
			doq)  [ -x "$DOT_BIN" ] && _dlg=dot; [ -x "$DOH_BIN" ] && _dlg="${_dlg:+$_dlg }doh" ;;
			doh3) [ -x "$DOH_BIN" ] && _dlg=doh ;;
		esac ;;
		*) [ -x "$DOH_BIN" ] && _dlg=doh ;;
	esac
	printf '%s\n' "$_dlg"
}
# The rung the level stands on now — empty: on the chosen protocol.
doh_lv_rung() { doh_lv "$1"; [ -f "$_lvf" ] || return 0; [ "$1" = quic ] || { echo doh; return 0; }; doh_proto_now; }
# Rungs BELOW the current one whose wire is alive on this path, in order — the candidates of a move.
doh_lv_live() {
	_dll_c=$(doh_lv_rung "$1"); _dll_o=''; _dll_s=1; [ -n "$_dll_c" ] || _dll_s=0
	for _dll_r in $(doh_lv_rungs "$1"); do
		if [ "$_dll_s" = 1 ]; then [ "$_dll_r" = "$_dll_c" ] && _dll_s=0; continue; fi
		doh_wire_ok "$_dll_r" && _dll_o="${_dll_o:+$_dll_o }$_dll_r"
	done
	printf '%s\n' "$_dll_o"
}
# Rungs ABOVE the current one, below the chosen protocol (doh_lv_back is the chosen's way up), whose wire is alive — top first. DoQ fell
# DoQ → DoT → DoH; later 853 came back and 443 went, QUIC still cut: every way up went straight to DoQ, every way down only below,
# and the house sat on the dead DoH rung — no names — until a reboot (review s.150, round 2). The DoT level has no middle rung: empty.
doh_lv_up() {
	_dlu_c=$(doh_lv_rung "$1"); _dlu_o=''
	if [ -n "$_dlu_c" ]; then
		for _dlu_r in $(doh_lv_rungs "$1"); do
			[ "$_dlu_r" = "$_dlu_c" ] && break
			doh_wire_ok "$_dlu_r" && _dlu_o="${_dlu_o:+$_dlu_o }$_dlu_r"
		done
	fi
	printf '%s\n' "$_dlu_o"
}
# Код 0 = переезд есть, путь его записан и ОТЛИЧАЕТСЯ от пути с формой $2 (mark|bypass|none).
doh_lv_path_stale() {
	doh_lv "$1"
	[ -f "$_lvf" ] && [ -f "$_lvp" ] || return 1
	[ "$(cat "$_lvp" 2>/dev/null)" != "$(doh_dot_path_id "$2")" ]
}
doh_dot_path_stale() { doh_lv_path_stale dot "$1"; }

# Переставить правила резолвера на порт АКТИВНОГО протокола в той же форме ($1 = mark|bypass|none) и
# перезапустить прокси другим бинарём. Решения «какую форму ставить» тут нет и быть не должно: путь не меняется.
doh_port_move() {
	doh_resolver_mark del; doh_resolver_bypass del
	case "$1" in mark) doh_resolver_mark add ;; bypass) doh_resolver_bypass add ;; esac
	doh_restart   # ДРУГОЙ бинарь: без рестарта прежний протокол жил бы под правилами нового порта
	sleep 1; doh_running || doh_start
}

# (С 16.10.2026 doh_probe спрашивает свежее имя и кэшу неподвластна сама — SIGHUP здесь лишний; снять его вместе с поиском
# dhcp-script — в бэклоге, вместе с миром стенда doh-anchor-test, где кэш смоделирован заглушкой пробы.)
# ИМЕНА ПОШЛИ? — проба БЕЗ КЭША dnsmasq. `example.com` мог остаться в его памяти от прежнего протокола, и
# переезд «доказал» бы себя ответом, которого новый прокси не давал (та же ловушка, что разобрана у
# doh_wire_ok). SIGHUP чистит кэш dnsmasq, не роняя сервис; нет процесса — проба идёт как есть.
# НО у dnsmasq с `--dhcp-script` тот же SIGHUP зовёт скрипт для ВСЕХ аренд (man dnsmasq), а на OpenWrt это буря
# hotplug-событий `dhcp` по каждому устройству (ревью ветки, круг 2). На BE7000 скрипта нет (замер 29.09.2026), на
# прочих прошивках не знаем — там кэш не трогаем, и проба честна лишь настолько, насколько свеж кэш. Зовут нас
# редко: при признаках беды (doh_dot_troubled), при переезде и при возврате в несущую — не на каждом тике.
doh_names_ok() {
	doh_dhcp_script_set || killall -HUP dnsmasq 2>/dev/null
	doh_probe "${1:-2}"
}

# ЗАДАН ЛИ У dnsmasq `dhcp-script`? Ищем ТАМ, ОТКУДА ДЕМОН ЧИТАЕТ КОНФИГ, а не в одном угаданном файле (бэклог ветки
# fix/dot-port-fallback, (9)): прежде смотрели только `/var/etc/dnsmasq.conf*` (отрисовка uci на OpenWrt), а скрипт
# кладут и ключом в командной строке, и в `conf-file=`, и в сниппет `conf-dir=` — там SIGHUP звал бы его по всем арендам.
# Порядок: argv живого процесса (`-6`/`--dhcp-script` прямо в нём; `-C`/`--conf-file` — какой файл он читает), затем
# `conf-file=`/`conf-dir=` из этих файлов (замер BE7000 29.09.2026: argv `-C /var/etc/dnsmasq.conf.cfg01411c`, в нём
# `conf-file=/etc/dnsmasq.conf` и `conf-dir=/tmp/dnsmasq.d`) и оба наших conf-dir. argv читаем ЦЕЛИКОМ через `tr`:
# grep по /proc/*/cmdline видит только argv[0] (C115). Процесса нет — смотрим прежние файлы: вреда от лишней проверки нет.
# Код 0 = скрипт задан (кэш не трогаем); 1 = не задан.
doh_dhcp_script_set() {
	_dds_f=''
	for _dds_p in $(pidof dnsmasq 2>/dev/null); do
		_dds_a=$(tr '\0' '\n' 2>/dev/null < "/proc/$_dds_p/cmdline")
		printf '%s\n' "$_dds_a" | grep -qE '^(-6|--dhcp-script|--dhcp-luascript)' && return 0
		_dds_f="$_dds_f $(printf '%s\n' "$_dds_a" | awk 'c {print; c=0; next} $0=="-C" || $0=="--conf-file" {c=1; next} /^--conf-file=/ {sub(/^--conf-file=/, ""); print; next} /^-C./ {print substr($0, 3)}')"
	done
	_dds_f="$_dds_f /var/etc/dnsmasq.conf* /etc/dnsmasq.conf"
	# $_dds_f — без кавычек намеренно: список путей (и маска прежних файлов), пробелов в путях dnsmasq нет.
	_dds_f="$_dds_f $(cat $_dds_f 2>/dev/null | sed -n 's/^[[:space:]]*conf-file=//p')"
	for _dds_d in /etc/dnsmasq.d /tmp/dnsmasq.d $(cat $_dds_f 2>/dev/null | sed -n 's/^[[:space:]]*conf-dir=\([^,]*\).*/\1/p'); do
		_dds_f="$_dds_f $_dds_d/*"
	done
	cat $_dds_f 2>/dev/null | grep -qE '^[[:space:]]*dhcp-(lua)?script'
}

# ПРИЗНАК БЕДЫ У DoT — без пробы имён, то есть без сброса кэша у здорового DoT на каждой сверке: TLS к 853 этим путём
# не встаёт, ИЛИ dot-proxy с $1 (эпоха прошлой сверки; 0 — с начала лога) писал ошибки. Ошибка dot-proxy — ровно та
# беда, что пришла с железа 29.09.2026 (рукопожатие рвётся по его сроку при живом TLS). Лог наш, формат «[E] <эпоха> …»
# стабилен; строки старше отметки (в том числе от https-dns-proxy до смены протокола) не считаются.
# НЕ ЛЮБАЯ `[E]` (бэклог ветки fix/dot-port-fallback, (7)): `tls read: …` — это обрыв УЖЕ ЖИВОГО соединения, и
# резолверы рвут простаивающие соединения сбросом так же штатно, как close_notify; прежняя «любая [E]» на шумном пути
# сбрасывала кэш dnsmasq всему дому раз в 10 мин ради здорового DoT. Беда — только НЕ ПОЛУЧИЛОСЬ СОЕДИНИТЬСЯ (`connect`,
# `handshake`; у 1.2 и «no reply within N ms (-T)») или ответы не приходят (`inflight table full`), и лишь пока после
# неё не было `connected`: DoT, переподключившийся сам, здоров. Третье слово строки — событие (формат dot-proxy
# стабилен: «[E] <эпоха> <событие> …»).
doh_dot_troubled() {
	doh_wire_ok || return 0
	case "$1" in ''|*[!0-9]*) return 0 ;; esac
	# `inflight` (запрос снят: соединение умирало на нём раз за разом; таблица ждущих полна) — беда, которую `connected` НЕ
	# снимает: рукопожатие тут и не было проблемой, путь рвёт соединение на первой же записи данных. Прогрев 1.3 пишет
	# `connected` через 10–25 с после обрыва, и прежняя форма читала «здоров» при мёртвом DNS (ревью ветки, круг 2).
	# `silent` (1.4: соединение живо, а не отвечает НИЧЕГО, даже пробе) `connected` тоже не снимает — рукопожатие тут как раз
	# проходит; снимает ответ по соединению (`answering`) или СТАРТ нового процесса (`[I] … dot-proxy … listening`): у нового
	# `answering` не будет никогда — он о прежней тишине не знает (ревью ветки fix/dot-proxy-tails, круг 1).
	# The QUIC program speaks the same journal (dev/quic/quic-dns-proxy.c, «LOG»): its start line is `quic-dns-proxy … listening`, and
	# its own refusals of a LIVE connection — an HTTP status, a wrong content-type, a reset query, a send the kernel refused — are
	# `inflight`'s kind: a new connection does not cure them, only the next sweep's window forgets them.
	awk -v t="$1" '$2+0 < t {next}
		$1=="[E]" && ($3=="handshake" || $3=="connect") {bad=1}
		$1=="[E]" && $3=="inflight" {inf=1}
		$1=="[E]" && ($3=="status" || $3=="content-type" || $3=="reset" || $3=="send") {inf=1}
		$1=="[E]" && $3=="silent" {sil=1}
		$1=="[I]" && $3=="connected" {bad=0}
		$1=="[I]" && ($3=="answering" || $3=="dot-proxy" || $3=="quic-dns-proxy") {sil=0}
		END{exit !(bad || inf || sil)}' "$DOH_LOG" 2>/dev/null
}

# Событие переезда — в журнал панели. $1 = fallback|back, $2 = форма якоря (каким путём это выяснилось).
doh_dot_event() {
	[ -n "$ENODIA_DIR" ] && [ -f "$ENODIA_DIR/events.sh" ] || return 0
	case "$2" in mark) _dde_via='через туннель' ;; bypass) _dde_via='напрямую через провайдера' ;; *) _dde_via='текущий' ;; esac
	if [ "$1" = fallback ]; then
		sh "$ENODIA_DIR/events.sh" add doh-dot-fallback 86400 "DoT не работает — DNS шифруется по DoH" \
"Резолвер $(doh_resolver_name) не отвечает по DoT (путь: $_dde_via), а по DoH того же резолвера отвечает: порт 853 закрыт по дороге или рукопожатие DoT не укладывается в срок. Роутер перевёл шифрованный DNS на DoH: запросы по-прежнему шифруются, выбор DoT сохранён. Раз в $((DOH_DOT_RETRY / 60)) мин роутер проверяет DoT и вернётся на него сам, когда тот заработает." >/dev/null 2>&1 || true
	else
		sh "$ENODIA_DIR/events.sh" add doh-dot-back 86400 "DoT снова работает" \
"Резолвер $(doh_resolver_name) снова отвечает по DoT (путь: $_dde_via) — шифрованный DNS вернулся с DoH на выбранный DoT." >/dev/null 2>&1 || true
	fi
	return 0
}

# The QUIC level's move into the journal. $1 = fallback|back, $2 = the anchor form, $3 = the rung (fallback), $4 = the rung it fell
# FROM (a rung that went mute in its turn: DoQ → DoT → DoH) — then the journal says both protocols are dead on this path.
doh_quic_event() {
	[ -n "$ENODIA_DIR" ] && [ -f "$ENODIA_DIR/events.sh" ] || return 0
	case "$2" in mark) _dqe_via='через туннель' ;; bypass) _dqe_via='напрямую через провайдера' ;; *) _dqe_via='текущий' ;; esac
	_dqe_p=$(doh_proto_label "$(doh_proto)")
	if [ "$1" = fallback ] && [ -n "$4" ]; then
		_dqe_r=$(doh_proto_label "$3"); _dqe_o=$(doh_proto_label "$4")
		sh "$ENODIA_DIR/events.sh" add doh-quic-fallback 86400 "$_dqe_p и $_dqe_o не работают — DNS шифруется по $_dqe_r" \
"Резолвер $(doh_resolver_name) не отвечает ни по $_dqe_p, ни по $_dqe_o (путь: $_dqe_via), а по $_dqe_r того же резолвера отвечает. Роутер перевёл шифрованный DNS на $_dqe_r: запросы по-прежнему шифруются, выбор $_dqe_p сохранён. Раз в $((DOH_QUIC_RETRY / 60)) мин роутер проверяет $_dqe_p и вернётся на него сам, когда тот заработает." >/dev/null 2>&1 || true
	elif [ "$1" = fallback ]; then
		_dqe_r=$(doh_proto_label "$3")
		sh "$ENODIA_DIR/events.sh" add doh-quic-fallback 86400 "$_dqe_p не работает — DNS шифруется по $_dqe_r" \
"Резолвер $(doh_resolver_name) не отвечает по $_dqe_p (путь: $_dqe_via), а по $_dqe_r того же резолвера отвечает: QUIC режут по дороге или его порт закрыт. Роутер перевёл шифрованный DNS на $_dqe_r: запросы по-прежнему шифруются, выбор $_dqe_p сохранён. Раз в $((DOH_QUIC_RETRY / 60)) мин роутер проверяет $_dqe_p и вернётся на него сам, когда тот заработает." >/dev/null 2>&1 || true
	else
		sh "$ENODIA_DIR/events.sh" add doh-quic-back 86400 "$_dqe_p снова работает" \
"Резолвер $(doh_resolver_name) снова отвечает по $_dqe_p (путь: $_dqe_via) — шифрованный DNS вернулся на выбранный $_dqe_p." >/dev/null 2>&1 || true
	fi
	return 0
}
# A protocol's name for people (journal, notes): one table for every phrase of this file.
doh_proto_label() { case "$1" in dot) echo DoT ;; doq) echo DoQ ;; doh3) echo DoH3 ;; odoh) echo ODoH ;; *) echo DoH ;; esac; }
# Names went? — the DoT level keeps its probe through a flushed cache (doh_names_ok, below); the QUIC level asks a FRESH name and
# leaves the cache alone (doh_probe — the ODoH sweep's lesson, s.145: a sweep that runs every tick must not wipe the house's cache).
doh_lv_names() { if [ "$1" = quic ]; then doh_probe 3; else doh_names_ok; fi; }
doh_lv_event() { if [ "$1" = quic ]; then doh_quic_event "$2" "$3" "$4" "$5"; else doh_dot_event "$2" "$3"; fi; }

# DoT → DoH, И ПЕРЕЕЗД ЗАСЧИТЫВАЕТСЯ, ТОЛЬКО ЕСЛИ ИМЕНА ПОШЛИ. Живой провод 443 доказывает лишь, что TLS к IP:443
# встаёт, но не что там DoH: у своего резолвера, введённого как tls://имя, адрес https://имя/dns-query достроен
# угадыванием (на 443 там может быть просто сайт); у резолвера по имени может не пройти bootstrap; программа DoH
# бывает битой. Без отката такой переезд оставлял дом без DNS до следующей проверки DoT (до часа), а увод мимо
# несущей шёл бы уже на мёртвом DoH, хотя DoT там работал (ревью ветки, круг 1). Поэтому не пошли — возвращаем
# DoT той же формой пути. Форму читаем ДО флага: флаг меняет активный порт, а с ним и ответ doh_anchor_state.
# ФОРМУ ОТКАТА — ЗАНОВО, ИЗ ЯДРА (ревью ветки, круг 3): между переездом и откатом до ~100 с (ожидание порта, проба
# имён), лока смены сторож тут не держит, и человек успевает сменить транспорт — xray (марка) на byedpi (RETURN).
# Откат запомненной МАРКОЙ оставил бы в прямом режиме сессию DoT в xtun→ciadpi, то есть дом без DNS до следующей
# перепроводки. doh_anchor_state спрашивает оба порта, так что правило, поставленное плагином на :443 в окне, найдёт.
# doh_lv_fallback <level> <rungs> — down to the first of <rungs> (their wire proven by the caller, doh_lv_live) on which names go. Code
# 0 = names go (the event is written); 1 = none did — back where the proxy was: the chosen protocol, or the rung it stood on (a QUIC
# rung that fell mute falls further, and a further move that finds no names leaves it on that rung, as the flag said).
doh_lv_fallback() {
	_dlf_l=$1; doh_lv "$_dlf_l"
	_ddf_f=$(doh_anchor_state)
	_dlf_was=$(cat "$_lvf" 2>/dev/null)
	# $3 — a CLIMB (doh_lv_up): `up` from a rung that went mute, `climb` the hourly one from a rung that works. Both count against the
	# climb limit (DOH_QUIC_UP); a `climb` leaves a rung that works, so the journal does not call it dead (DOH_LV_FROM below).
	case "${3:-}" in up|climb) date +%s > "$DOH_QUIC_UP" 2>/dev/null ;; esac
	# The QUIC level keeps its «last try back» apart from its failed moves (`_lvt` ≠ `_lvd`): a further fall that finds no names
	# must not reset it, or the next sweep tried QUIC again at once instead of after the level's retry (review s.150, round 1).
	_dlf_try=''; [ "$_lvt" = "$_lvd" ] || _dlf_try=$(cat "$_lvt" 2>/dev/null)
	# Falling from a RUNG — that rung went mute too: the journal and the watchdog name it (DOH_LV_FROM), not only the chosen protocol.
	DOH_LV_FROM=''; [ "$_dlf_l" = quic ] && [ -n "$_dlf_was" ] && [ "${3:-}" != climb ] && DOH_LV_FROM=$(printf '%s\n' "$_dlf_was" | awk '{print $2; exit}')
	for _dlf_r in $2; do
		doh_lv "$_dlf_l"
		{ echo "$(date +%s) $_dlf_r" > "$_lvf"; } 2>/dev/null || : > "$_lvf"
		rm -f "$_lvt" 2>/dev/null
		doh_port_move "$_ddf_f"
		if doh_wait_listen && doh_lv_names "$_dlf_l"; then
			doh_lv "$_dlf_l"
			rm -f "$_lvd" 2>/dev/null
			doh_dot_path_id "$_ddf_f" > "$_lvp" 2>/dev/null   # вердикт — про ЭТОТ путь (см. DOH_DOT_PATH)
			doh_lv_event "$_dlf_l" fallback "$_ddf_f" "$_dlf_r" "$DOH_LV_FROM"
			return 0
		fi
	done
	doh_lv "$_dlf_l"
	if [ -n "$_dlf_was" ]; then printf '%s\n' "$_dlf_was" > "$_lvf" 2>/dev/null; else rm -f "$_lvf" "$_lvp" 2>/dev/null; fi
	[ -n "$_dlf_try" ] && printf '%s\n' "$_dlf_try" > "$_lvt" 2>/dev/null
	doh_port_move "$(doh_anchor_state)"
	doh_wait_listen
	return 1
}
doh_dot_fallback() { doh_lv_fallback dot doh; }

# Обратно на выбранный протокол, с той же проверкой. Код 0 = имена пошли (событие); 1 = не пошли — возвращаем ступень
# (она работала: так её и засчитали) с ПРЕЖНИМ временем переезда и отметкой попытки, следующая — через полный срок уровня.
# Форма отката — заново из ядра, как у doh_lv_fallback.
doh_lv_back() {
	_dlb_l=$1; doh_lv "$_dlb_l"
	_ddb_f=$(doh_anchor_state)
	_ddb_t=$(cat "$_lvf" 2>/dev/null)
	rm -f "$_lvf" "$_lvt" "$_lvp" 2>/dev/null
	doh_port_move "$_ddb_f"
	if doh_wait_listen && doh_lv_names "$_dlb_l"; then
		doh_lv "$_dlb_l"; rm -f "$_lvd" 2>/dev/null
		doh_lv_event "$_dlb_l" back "$_ddb_f"
		return 0
	fi
	doh_lv "$_dlb_l"
	if [ -n "$_ddb_t" ]; then printf '%s\n' "$_ddb_t" > "$_lvf" 2>/dev/null; else date +%s > "$_lvf" 2>/dev/null; fi
	date +%s > "$_lvt" 2>/dev/null
	doh_dot_path_id "$_ddb_f" > "$_lvp" 2>/dev/null   # вердикт подтверждён на ЭТОМ пути
	doh_port_move "$(doh_anchor_state)"
	doh_wait_listen
	return 1
}
doh_dot_back() { doh_lv_back dot; }

# Забыть переезд — это НОВОЕ НАМЕРЕНИЕ человека (включил шифрование, сменил протокол или резолвер): прежний
# вердикт был про другой выбор или другой путь, и подъём обязан сперва попробовать выбранное. Код 0 = переезд БЫЛ и
# забыт: живой прокси при этом ещё на ступени, и перезапустить его под выбранным — дело вызывающего (вербы смены
# протокола и резолвера перезапускают его и так). doh_dns_bailout флаг НЕ трогает намеренно: «порт этим путём закрыт»
# остаётся правдой и после снятия проводки, а забытый вердикт стоил бы лишней проверки (секунды без имён) на каждой
# перепроводке.
doh_lv_forget() {
	doh_lv "$1"
	[ "$1" = quic ] && rm -f "$DOH_QUIC_UP" 2>/dev/null   # a new intent: the climb limit was about the old verdict
	[ -f "$_lvf" ] || { rm -f "$_lvt" "$_lvd" "$_lvp" 2>/dev/null; return 1; }
	rm -f "$_lvf" "$_lvt" "$_lvd" "$_lvp" 2>/dev/null
	return 0
}
doh_dot_forget() { doh_lv_forget dot; }
# The ladder's state of BOTH levels as it is now — saved before a CGI tries a NEW resolver and given back when it takes the old one
# back (review s.151 r3 L1): the old resolver returns to ITS rungs and tries, not to a forgotten state (it would rise on QUIC its path
# cuts and fall down the ladder again inside the CGI) nor to what the new resolver's attempt wrote. One directory per CGI, next to the
# stamps (RAM); restore removes it.
DOH_LV_SNAP=${DOH_LV_SNAP:-${DOH_QUIC_FALLBACK%/*}/.enodia-doh-lvsnap}
doh_lv_save() {
	_dlsd="$DOH_LV_SNAP.$$"; rm -rf "$_dlsd"; mkdir -p "$_dlsd" || return 1
	for _dlsl in dot quic; do
		doh_lv "$_dlsl"
		for _dlsf in "$_lvf" "$_lvt" "$_lvd" "$_lvp"; do [ -f "$_dlsf" ] && cp -p "$_dlsf" "$_dlsd/${_dlsf##*/}"; done
	done
	[ -f "$DOH_QUIC_UP" ] && cp -p "$DOH_QUIC_UP" "$_dlsd/${DOH_QUIC_UP##*/}"
	return 0
}
doh_lv_restore() {
	_dlrd="$DOH_LV_SNAP.$$"; [ -d "$_dlrd" ] || return 1
	for _dlrl in dot quic; do
		doh_lv "$_dlrl"
		for _dlrf in "$_lvf" "$_lvt" "$_lvd" "$_lvp"; do
			rm -f "$_dlrf"; [ -f "$_dlrd/${_dlrf##*/}" ] && cp -p "$_dlrd/${_dlrf##*/}" "$_dlrf"
		done
	done
	rm -f "$DOH_QUIC_UP"; [ -f "$_dlrd/${DOH_QUIC_UP##*/}" ] && cp -p "$_dlrd/${DOH_QUIC_UP##*/}" "$DOH_QUIC_UP"
	rm -rf "$_dlrd"
	return 0
}
doh_lv_drop() { rm -rf "$DOH_LV_SNAP.$$"; }
# A new intent forgets BOTH levels (the CGI verbs): 0 = some move was forgotten.
doh_fb_forget() { _dff=1; doh_lv_forget dot && _dff=0; doh_lv_forget quic && _dff=0; return $_dff; }

# «Имена не идут — а этот же путь вообще жив?» Зовут там, где проба резолва уже провалилась: up-путь
# (doh_apply_dns) и возврат в несущую (doh_retunnel). Решаем по ИМЕНАМ, а не по проводу 853: живой TLS к 853 не
# доказывает рабочий DoT — ЗАМЕР BE7000 29.09.2026: через awg0 рукопожатие к 853 встаёт за 0.19–4.3 с, а наш
# dot-proxy до 1.2 рвал его через 3 с и молчал, пока DoH того же резолвера тем же путём работал (1.2 ждёт 8 с,
# но путь бывает и медленнее, а старый бинарь живёт до переустановки компонента). Вопрос
# «порт или путь» сводится к одному: ступень ниже ЭТИМ ЖЕ путём жива? Жива — пробуем её (doh_lv_fallback засчитает
# переезд, только если имена пошли, иначе вернёт прежнее); мертвы все — путь мёртв целиком (несущая ещё не везёт), и это
# дело прежней логики увода, не наше. Код 0 = переехали, и имена пошли; 1 — прокси там же, где был.
# ОБРАТНЫЙ ХОД: прокси на ступени после прежнего переезда, и молчит уже она. Путь мог смениться так, что 443 к
# резолверу закрыт, а 853 открыт (провайдер душил :443 к 1.1.1.1 — 09.08.2026). Без этой ветки DoH «прилипал» до
# ребута: переезд переживает bailout намеренно, а тик сверки до прокси, мимо которого идёт DNS, не доходит (гард
# doh_upstream_set) — ревью ветки, круг 2. Возврат проверяется именами (doh_lv_back), не пошли — ступень ниже (у QUIC), иначе как было.
doh_lv_rescue() {
	[ -n "$1" ] && [ "$(doh_lv_of)" = "$1" ] || return 1     # выбран протокол без этого уровня — менять нечего
	_dlr_l=$1; doh_lv "$_dlr_l"
	if [ -f "$_lvf" ] && doh_wire_ok "$(doh_proto)"; then
		doh_lv_back "$_dlr_l" && return 0
	fi
	_dlr_c=$(doh_lv_live "$_dlr_l"); _dlr_m=''
	[ -n "$_dlr_c" ] || { _dlr_c=$(doh_lv_up "$_dlr_l"); _dlr_m=up; }   # nothing alive below — a middle rung above may live again
	[ -n "$_dlr_c" ] || return 1                  # переезжать некуда, или путь мёртв целиком — не порт
	doh_lv_fallback "$_dlr_l" "$_dlr_c" "$_dlr_m"
}
doh_dot_rescue() { doh_lv_rescue dot; }
doh_quic_rescue() { doh_lv_rescue quic; }

# The anchor form the rewire (`transport.sh dns` → the plugin's DNS setter → doh_apply_dns) lays NOW — transport.sh::cmd_dns's own
# dispatch: VPN switched off by hand, byedpi/zapret, no transport, awg without its route (FAILOPEN) → `direct` (bypass); awg with its
# carrier, xray/hy2 with or WITHOUT one → `tunnel` (mark: their DNS setter is the tunnel's, a carrier-less mark falls to main — review
# s.152 r1 L1 found doh_direct_regime guessing bypass there). Not doh_anchor_apply: the untunneled flag it honours is cleared by that
# very rewire. A wrong guess costs only the old behaviour — doh_apply_dns forgets a rung recorded for another path.
doh_rewire_form() {
	if [ -f "$ENODIA_STATE/.vpn-off" ] || doh_direct_by_name; then echo bypass; return 0; fi
	case "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" in
		''|awg) if [ -n "$(carrier_iface)" ]; then echo mark; else echo bypass; fi ;;
		*)      echo mark ;;
	esac
}
# doh_wire_via <proto> <form> — does <proto>'s wire answer on the path the switch's rewire lays (<form> = doh_rewire_form, asked by
# the caller: it reads `.transport`/`.vpn-off`, which a caller probing from a snapshot of `.doh-*` does not carry)? With the resolver
# UNTUNNELED now (DOH_UNTUNNELED: the carrier does not reach it) the tunnel form is asked both ways, mark first — the order
# doh_apply_dns tunnel follows (mark, then its fallback past the carrier): mark alone refused a resolver the rewire reaches (review
# s.153 r1 B4), bypass alone asked past a carrier that is back (s.151 r3 L4).
doh_wire_via() {
	doh_wire_ok "$1" "$2" && return 0
	[ "$2" = mark ] && [ -f "$DOH_UNTUNNELED" ] && doh_wire_ok "$1" bypass
}
# doh_quic_preset <mark|bypass> — the proxy is about to rise on the chosen DoQ/DoH3 (switching encryption on, the direct up-path of
# doh_apply_dns): does QUIC answer on the path that rewire lays? Silent — the QUIC level stands at once on the first rung below whose wire
# is alive on that path (the flag «<epoch> <rung>» and its path, as doh_lv_fallback writes them), so the proxy rises THERE: the house does
# not sit on a mute QUIC proxy while the ladder falls, 20–40 s without names (review s.151 r3 L3; set_doh_proto/set_doh_resolver ask the
# same before their switch).
# THE RUNG IS PROVISIONAL until names go on it (review s.152 r2 B-L1): only the wire was asked, and a live 853 handshake does not prove
# a working DoT (the project's own measurement). The marker DOH_QUIC_PRESET carries it to doh_apply_dns, which settles it
# (doh_quic_preset_settle): names went on the rung — the journal says it (the climb back an hour later then has its pair); the ladder
# moved further — its own line said it; the rewire ended in doh_apply_fail — the rung is dropped, so neither the journal, the panel nor
# the dump claims «шифрует по DoT» over the plain path, and no rung pins the path for DOH_QUIC_RETRY.
# Nothing here when a rung already stands (the ladder's verdict lives), without the QUIC program (that is «no component», not «QUIC
# silent»), with a resolver QUIC cannot be tried with, with the uplink down by the owner's local signs (every wire would read dead and the
# ladder asks them again anyway) — and in the mark form over a carrier seconds old: through a fresh tunnel QUIC reads dead for 5–9 s (the
# tunnel's up-path itself never asks for that reason; the bypass form rides WAN, no carrier in it). Code 0 = stood on a rung (a running
# proxy is the caller's to restart); 1 = nothing changed (QUIC answers, not ours to ask, or nothing alive on this path — the rewire's
# ladder answers then).
DOH_QUIC_PRESET="/tmp/.enodia-quic-preset"
doh_quic_preset() {
	case "$(doh_proto)" in doq|doh3) : ;; *) return 1 ;; esac
	case "$1" in mark|bypass) : ;; *) return 1 ;; esac
	[ -f "$DOH_QUIC_FALLBACK" ] && return 1
	[ -x "$QUIC_BIN" ] && doh_quic_can "$(doh_proto)" || return 1
	if command -v wan_up >/dev/null 2>&1 && ! wan_up; then return 1; fi
	if [ "$1" = mark ] && [ "$(age_since "$(cat "${CARRIER_UP_STAMP:-/tmp/.enodia-carrier-up.stamp}" 2>/dev/null | tr -cd '0-9')")" -lt 60 ]; then
		return 1
	fi
	doh_wire_ok "$(doh_proto)" "$1" && return 1
	for _dqps in $(doh_lv_rungs quic); do
		doh_wire_ok "$_dqps" "$1" || continue
		doh_lv quic
		{ echo "$(date +%s) $_dqps" > "$_lvf"; } 2>/dev/null || : > "$_lvf"
		rm -f "$_lvt" "$_lvd" 2>/dev/null
		doh_dot_path_id "$1" > "$_lvp" 2>/dev/null   # the verdict is about THIS path (DOH_DOT_PATH)
		echo "$_dqps" > "$DOH_QUIC_PRESET" 2>/dev/null
		return 0
	done
	return 1
}
# doh_quic_preset_settle ok|fail — the end of a rewire that may have risen on a provisional rung (doh_quic_preset). ok: names went — a
# rung still standing WHERE THE PRESET PUT IT is journalled now (every success return asks it: the ladder that moved further changed the
# flag and said it itself, so nothing is said twice — review s.152 r3 B-L1 found the untunnel branch silent); fail: the rewire fell
# back (doh_apply_fail) — the rung still standing where the preset put it is dropped. The marker goes in every case.
doh_quic_preset_settle() {
	[ -f "$DOH_QUIC_PRESET" ] || return 0
	_dqss=$(cat "$DOH_QUIC_PRESET" 2>/dev/null); rm -f "$DOH_QUIC_PRESET" 2>/dev/null
	doh_lv quic
	[ -n "$_dqss" ] && [ -f "$_lvf" ] && [ "$(awk '{print $2; exit}' "$_lvf" 2>/dev/null)" = "$_dqss" ] || return 0
	case "$1" in
		ok)   doh_lv_event quic fallback "$(awk '{print $NF; exit}' "$_lvp" 2>/dev/null)" "$_dqss" ;;   # «<transport> <form>», transport may be empty
		fail) rm -f "$_lvf" "$_lvp" 2>/dev/null ;;
	esac
	return 0
}

# ---- ЛЕСТНИЦА ODoH: другой ретранслятор → DoH напрямую к цели → прежний путь ---------------------------------------------
# Ретранслятор — чужой сервис, и их всего два публичных: один лёг или его режет провайдер — естественный шаг сперва ДРУГОЙ
# ретранслятор (цель по-прежнему не видит адреса), потом — РЕШЕНИЕ ЧЕЛОВЕКА 16.10.2026: DoH напрямую к ТОЙ ЖЕ цели (шифрование
# сохранено, цель видит адрес роутера, в туннеле — адрес VPS), и лишь затем прежний откат слоя (doh_apply_fail). Намерение
# (`.doh-proto=odoh`) не трогаем: откат живёт в ОЗУ, и сторож раз в DOH_ODOH_RETRY пробует ретрансляторы снова (doh_odoh_tick).
# Каждый шаг засчитывается, только если ИМЕНА ПОШЛИ (doh_names_ok, мимо кэша dnsmasq) — по той же причине, что у переезда DoT.
# Правила не переставляются ни на одном шаге: их адреса — все ретрансляторы списка и цель (doh_odoh_ips).

# Событие — в журнал панели. $1 = relay|fallback|back, $2 — ключ ретранслятора (relay/back).
doh_odoh_event() {
	[ -n "$ENODIA_DIR" ] && [ -f "$ENODIA_DIR/events.sh" ] || return 0
	_doe_t=$(doh_odoh_target); _doe_tn=$(doh_tab "$DOH_ODOH_TARGETS" "$_doe_t" 2); [ -n "$_doe_tn" ] || _doe_tn=$(doh_url_host "$(doh_odoh_target_url)")
	_doe_rn=''; [ -n "$2" ] && { _doe_rn=$(doh_tab "$DOH_ODOH_RELAYS" "$2" 2); [ -n "$_doe_rn" ] || _doe_rn=$(doh_url_host "$(doh_odoh_relay_url "$2")"); }
	case "$1" in
		relay)
			sh "$ENODIA_DIR/events.sh" add odoh-relay 86400 "ODoH идёт через другой ретранслятор" \
"Прежний ретранслятор не ответил — запросы к $_doe_tn идут через $_doe_rn. Цель по-прежнему не видит адреса роутера." >/dev/null 2>&1 || true ;;
		fallback)
			sh "$ENODIA_DIR/events.sh" add odoh-fallback 86400 "ODoH не работает — DNS шифруется по DoH напрямую к $_doe_tn" \
"Ни один ретранслятор не ответил. Роутер перевёл шифрованный DNS на обычный DoH к той же цели ($_doe_tn): запросы по-прежнему шифруются, но цель видит адрес роутера (в туннеле — адрес сервера VPN). Через $((DOH_ODOH_RETRY / 60)) мин роутер проверит ретрансляторы (не ответят — дальше реже, до раза в час) и вернётся на ODoH сам." >/dev/null 2>&1 || true ;;
		back)
			sh "$ENODIA_DIR/events.sh" add odoh-back 86400 "ODoH снова работает" \
"Ретранслятор $_doe_rn снова отвечает — шифрованный DNS к $_doe_tn вернулся на ODoH." >/dev/null 2>&1 || true ;;
	esac
	return 0
}

# Прокси под текущую ступень (перезапуск с ожиданием порта — по процессу, doh_restart_wait) и проба свежим именем. 0 = имена пошли.
# doh_probe, а не doh_names_ok: свежее имя кэшу неподвластно, а SIGHUP сбрасывал бы кэш dnsmasq всему дому на КАЖДОЙ ступени (ревью
# с.145, круг 1). Попыток ТРИ: холодной ступени ODoH до первого ответа нужны два TLS-рукопожатия подряд (ключ цели, потом ретранслятор),
# а через VPS одно стоит 4.3–4.5 с (замер 29.09.2026) — две попытки хоронили бы живой ретранслятор.
doh_odoh_step_ok() { doh_restart_wait && doh_probe 3; }


# Сколько ждать с отката (или прошлой попытки) до следующей попытки вернуться: DOH_ODOH_RETRY, после каждой неудачной — вдвое, не
# больше DOH_ODOH_RETRY_MAX. Неудачная попытка — это рестарты прокси под домом и пауза имён (ODoH сломан выше TLS: ключа нет,
# ретранслятор отвечает 403/502) — раз в 15 минут вечно было бы ценой, которую дом платит за ничто (ревью с.145, круг 1).
doh_odoh_retry_wait() {
	_dorw_n=$(cat "$DOH_ODOH_TRIES" 2>/dev/null | tr -cd '0-9'); _dorw_w=$DOH_ODOH_RETRY
	while [ "${_dorw_n:-0}" -gt 0 ] && [ "$_dorw_w" -lt "$DOH_ODOH_RETRY_MAX" ]; do _dorw_w=$((_dorw_w * 2)); _dorw_n=$((_dorw_n - 1)); done
	[ "$_dorw_w" -le "$DOH_ODOH_RETRY_MAX" ] || [ "$_dorw_w" = "$DOH_ODOH_RETRY" ] || _dorw_w=$DOH_ODOH_RETRY_MAX
	echo "$_dorw_w"
}

# doh_odoh_rescue — имена не пошли при выбранном ODoH. Код 0 = после шага имена идут; 1 = не помогло ничто (вызывающему —
# его прежний путь: увод мимо несущей, откат).
doh_odoh_rescue() {
	[ "$(doh_proto)" = odoh ] || return 1
	doh_odoh_capable || return 1
	if [ "$(doh_proto_now)" = doh ]; then
		# Уже на откате, и молчит уже DoH к цели: путь мог смениться так, что ретранслятор доступен, а цель напрямую — нет.
		doh_odoh_back
		return $?
	fi
	# ГЕЙТЫ ПРОВОДА НА КАЖДОЙ СТУПЕНИ: прокси под домом перезапускаем только под ретранслятор (цель), до которого этим путём встаёт
	# TLS. Без них мёртвый путь стоил до восьми стартов на одну перепроводку (ревью с.145, круг 1); с ними путь, мёртвый целиком, —
	# ни одного, и вызывающему остаётся его путь (увод мимо несущей, откат).
	_dor_cur=$(doh_odoh_relay_now); _dor_tried=0
	for _dor_k in $(doh_odoh_relays); do
		[ "$_dor_k" = "$_dor_cur" ] && continue
		echo "$_dor_k" > "$DOH_ODOH_RELAY_NOW" 2>/dev/null
		doh_wire_ok odoh || continue          # провод к нему не встаёт — перезапускать под ним прокси незачем
		_dor_tried=1
		if doh_odoh_step_ok; then doh_odoh_event relay "$_dor_k"; return 0; fi
	done
	echo "$_dor_cur" > "$DOH_ODOH_RELAY_NOW" 2>/dev/null
	# DoH напрямую к цели — только если до неё этим путём встаёт TLS.
	if doh_wire_ok doh; then
		date +%s > "$DOH_ODOH_FALLBACK" 2>/dev/null || : > "$DOH_ODOH_FALLBACK"
		rm -f "$DOH_ODOH_TRY" "$DOH_ODOH_TRIES" 2>/dev/null
		if doh_odoh_step_ok; then doh_odoh_event fallback; return 0; fi
		rm -f "$DOH_ODOH_FALLBACK" 2>/dev/null
		_dor_tried=1
	fi
	# Прокси перезапускали — вернуть его к ступени, с которой начали.
	[ "$_dor_tried" = 1 ] && doh_odoh_step_ok >/dev/null 2>&1
	return 1
}

# С отката — обратно на ODoH, с первого ретранслятора списка, до которого встаёт TLS. Не пошли имена — откат остаётся с ПРЕЖНИМ
# временем, попытка отмечена, а если прокси под домом перезапускали — следующая вдвое позже (doh_odoh_retry_wait). Код 0 = вернулись.
doh_odoh_back() {
	_dob_t=$(cat "$DOH_ODOH_FALLBACK" 2>/dev/null | tr -cd '0-9'); _dob_tried=0
	rm -f "$DOH_ODOH_FALLBACK" "$DOH_ODOH_RELAY_NOW" 2>/dev/null
	for _dob_k in $(doh_odoh_relays); do
		echo "$_dob_k" > "$DOH_ODOH_RELAY_NOW" 2>/dev/null
		doh_wire_ok odoh || continue
		_dob_tried=1
		if doh_odoh_step_ok; then rm -f "$DOH_ODOH_TRY" "$DOH_ODOH_TRIES" 2>/dev/null; doh_odoh_event back "$_dob_k"; return 0; fi
	done
	rm -f "$DOH_ODOH_RELAY_NOW" 2>/dev/null
	if [ -n "$_dob_t" ]; then echo "$_dob_t" > "$DOH_ODOH_FALLBACK" 2>/dev/null; else date +%s > "$DOH_ODOH_FALLBACK" 2>/dev/null; fi
	date +%s > "$DOH_ODOH_TRY" 2>/dev/null
	if [ "$_dob_tried" = 1 ]; then
		_dob_n=$(cat "$DOH_ODOH_TRIES" 2>/dev/null | tr -cd '0-9'); echo $(( ${_dob_n:-0} + 1 )) > "$DOH_ODOH_TRIES" 2>/dev/null
		doh_odoh_step_ok >/dev/null 2>&1
	fi
	return 1
}

# Забыть лестницу — НОВОЕ НАМЕРЕНИЕ человека (сменил цель, ретранслятор или протокол): прежние вердикты были про другую пару.
doh_odoh_forget() { rm -f "$DOH_ODOH_FALLBACK" "$DOH_ODOH_TRY" "$DOH_ODOH_TRIES" "$DOH_ODOH_RELAY_NOW" "$DOH_ODOH_RESCUE" 2>/dev/null; return 0; }

# ПРИЗНАК БЕДЫ У ODoH — по журналу прокси (дёшево: без пробы имён и сброса кэша dnsmasq у здорового ODoH): с эпохи $1 прокси
# выбрасывал запросы без ключа, ключ не грузился, ответ не открывался, цель отказывала или ретранслятор не отвечал. Формат
# журнала https-dns-proxy: «[W] <эпоха> src/… текст».
# МОЛЧАЩИЙ РЕТРАНСЛЯТОР ПРОГРАММА ПИШЕТ НЕ ПРЕДУПРЕЖДЕНИЕМ (замер AX3600 16.10.2026, оба ретранслятора под DROP): `[I] … curl
# request failed with 28: Timeout was reached (recoverable…)`, `[I] … but no response was sent back` и `[W] … Request was aborted`
# — а прежний разбор брал только [W]/[E] с «curl request failed» и сверка 20 минут считала ODoH здоровым при доме без имён. Ложная
# «беда» стоит одной пробы свежим именем (doh_odoh_tick зовёт doh_probe, без сброса кэша dnsmasq), а пропущенная — дома без DNS.
doh_odoh_troubled() {
	case "$1" in ''|*[!0-9]*) return 0 ;; esac
	awk -v t="$1" '$2+0 < t {next}
		($1 == "[W]" || $1 == "[E]") && /target key not loaded|no usable target key|did not open|refused the sealed query|curl request failed|No response|Request was aborted|Invalid response Content-Type|curl response code: [013-9]/ {bad = 1}
		$1 == "[I]" && /curl request failed|no response was sent back|Response was faulty/ {bad = 1}
		END {exit !bad}' "$DOH_LOG" 2>/dev/null
}

# СВЕРКА ODoH — зовёт сторож (finish(), рядом с doh_port_tick). Два направления:
#   откат (DoH к цели)  — с отката (или прошлой попытки) прошло DOH_ODOH_RETRY и TLS к ретранслятору встаёт ⇒ назад на ODoH
#                         (код 4; не пошли имена — doh_odoh_back вернул откат и отметил попытку, код 0);
#   ODoH активен        — журнал прокси говорит о беде, и имена мимо кэша не идут ⇒ лестница (код 3 — помогла, 5 — нет; 6 — лестница
#                         ничего живого не нашла меньше DOH_ODOH_RETRY назад: ждём, ничего не трогая).
# $1 — ИМЯ функции «жив ли аплинк» (как у doh_health_tick): при мёртвом аплинке молчащий ретранслятор о себе не говорит.
DOH_ODOH_TICK_STAMP="/tmp/.enodia-odoh-tick.stamp"
doh_odoh_tick() {
	if [ "$(doh_proto)" != odoh ]; then doh_odoh_forget; return 0; fi
	doh_want && doh_running || return 0
	doh_upstream_set || return 0
	doh_odoh_capable || return 0
	doh_clock_ok || return 0
	_dotk=$(cat "$DOH_ODOH_TICK_STAMP" 2>/dev/null | tr -cd '0-9'); [ -n "$_dotk" ] || _dotk=0
	[ "$(age_since "$_dotk")" -ge "$DOH_PORT_EVERY" ] || return 0
	date +%s > "$DOH_ODOH_TICK_STAMP"
	if [ -f "$DOH_ODOH_FALLBACK" ]; then
		_dotl=$(cat "$DOH_ODOH_TRY" 2>/dev/null | tr -cd '0-9')
		[ -n "$_dotl" ] || _dotl=$(cat "$DOH_ODOH_FALLBACK" 2>/dev/null | tr -cd '0-9')
		[ "$(age_since "$_dotl")" -ge "$(doh_odoh_retry_wait)" ] || return 0
		# Провод щупает сам возврат — КАЖДЫЙ ретранслятор списка (при «авто» мёртвый первый не держит дом на откате, пока второй жив —
		# ревью с.145, круг 1), и без TLS ни к одному не перезапускает прокси и не удлиняет ожидание.
		doh_odoh_back && return 4
		return 0
	fi
	doh_odoh_troubled "$_dotk" || return 0
	# The sweep runs every tick: a ladder that found nothing alive is not climbed again before DOH_ODOH_RETRY — each climb costs proxy
	# restarts under the watchdog's lock, and while the path is dead the probes below would cost ~15 s of every tick.
	_dotr=$(cat "$DOH_ODOH_RESCUE" 2>/dev/null | tr -cd '0-9')
	[ -z "$_dotr" ] || [ "$(age_since "$_dotr")" -ge "$DOH_ODOH_RETRY" ] || return 6
	# Проба свежим именем (кэшу неподвластна) — БЕЗ doh_names_ok: тот шлёт dnsmasq SIGHUP, а признак беды по [I]-строкам бывает
	# и у здорового пути (перезаезд соединения), и кэш всего дома сбрасывался бы раз в DOH_PORT_EVERY.
	doh_probe && return 0
	if [ -n "$1" ] && ! "$1"; then return 0; fi
	if doh_odoh_rescue; then rm -f "$DOH_ODOH_RESCUE" 2>/dev/null; return 3; fi
	date +%s > "$DOH_ODOH_RESCUE" 2>/dev/null
	return 5
}

# ПЕРИОДИЧЕСКАЯ СВЕРКА DoT — зовёт сторож (finish(), РАНЬШЕ doh_health_tick: сперва чиним протокол, потом
# судим о резолвере). Разовой пробы при подъёме МАЛО по той же причине, что у авто-режима: путь меняется ПОД
# прокси (подписка сменила сервер, у нового выхода 853 закрыт), а ручной тумблер не проверял никто — дом
# сидел без имён при зелёной панели. Два направления в одной функции:
#   DoT активен      — имена по DoT не идут (проба МИМО кэша: doh_names_ok), а 443 этим путём жив ⇒ переезд на
#                      DoH (код 3); DoH имён тоже не отдал — остались на DoT (код 5: DNS мёртв, и сказать об этом
#                      обязан сторож; следующая попытка — не раньше DOH_DOT_RETRY). Судим по ИМЕНАМ, а не по
#                      проводу 853 (разбор — у doh_dot_rescue), но пробу имён — со сбросом кэша dnsmasq — зовём
#                      только при признаке беды (doh_dot_troubled): здоровый DoT кэш дома не трогает;
#   DoH вместо DoT   — с переезда (или прошлой попытки) прошло DOH_DOT_RETRY и TLS к 853 встаёт ⇒ возврат (код 4;
#                      не пошли имена — doh_dot_back сам вернул DoH и отметил попытку, код 0). Провод здесь —
#                      лишь дешёвый отсев: без живого TLS пробовать DoT незачем, а решает всё равно проба имён.
# Код 0 — делать нечего. Ручной и авто-режим одинаково: переезд ничего не выключает.
# $1 — ИМЯ функции «жив ли аплинк» (как у doh_health_tick): при мёртвом аплинке молчащий DoT о протоколе не говорит.
# doh_lv_sweep <level> <since> [wanfn] — one level's sweep (the body of doh_port_tick). Codes: 0 — nothing; 3 moved down, 4 back up,
# 5 a move that found no names; the QUIC level adds 3 (6, 7, 8), so the watchdog can say which protocol.
doh_lv_sweep() {
	_dls_l=$1; _dls_k=0; [ "$_dls_l" = quic ] && _dls_k=3
	doh_lv "$_dls_l"
	if [ -f "$_lvf" ]; then
		# Срок — от ПОСЛЕДНЕЙ попытки вернуться, а не было её — от переезда. ПУТЬ СМЕНИЛСЯ (увод мимо несущей и
		# обратно, смена транспорта без перепроводки DNS) — вердикт не про него, срок не ждём.
		_dpl=$(cat "$_lvt" 2>/dev/null | tr -cd '0-9')
		[ -n "$_dpl" ] || _dpl=$(cat "$_lvf" 2>/dev/null | tr -cd '0-9')
		if [ "$(age_since "$_dpl")" -ge "$_lvr" ] || doh_lv_path_stale "$_dls_l" "$(doh_anchor_state)"; then
			if doh_wire_ok "$(doh_proto)"; then
				doh_lv_back "$_dls_l" && return $((4 + _dls_k))
			else
				# Провод выбранного протокола не встаёт — следующая попытка через полный срок, а не на каждом тике: и вердикт
				# теперь про ЭТОТ путь (иначе «путь сменился» гнал бы пробу провода каждые DOH_PORT_EVERY).
				doh_lv "$_dls_l"
				date +%s > "$_lvt" 2>/dev/null
				[ -f "$_lvp" ] && doh_dot_path_id "$(doh_anchor_state)" > "$_lvp" 2>/dev/null
				# …and a MIDDLE rung above the current one may carry again (DoQ on DoH, 853 came back): the hourly look climbs to it, as
				# the DoT level's look back reaches its only other rung; names must go there, else the proxy stays. Without it a DoH rung
				# whose names died while TLS still passed never climbed — the troubled scan cannot read the DoH program's journal
				# (review s.150, round 3).
				_dls_u=$(doh_lv_up "$_dls_l")
				if [ -n "$_dls_u" ] && doh_lv_climb_ok; then doh_lv_fallback "$_dls_l" "$_dls_u" climb && return $((3 + _dls_k)); fi
			fi
		fi
		# The DoT level has one rung — it ends here. The QUIC level on a rung asks further: has THAT rung fallen mute (DoQ on DoT whose
		# 853 closed later)? Then down again, below.
		[ "$_dls_l" = quic ] || return 0
	fi
	doh_dot_troubled "$2" || return 0  # провод встаёт и прокси не жаловался — кэш не трогаем, протокол здоров
	# Неудачный переезд — не чаще раза в срок уровня: при мёртвом резолвере каждая попытка стоит двух рестартов
	# прокси под локом сторожа (ревью ветки, круг 2). Отметку снимает удачный переезд.
	# The wait stands BEFORE the name probe: the sweep runs every tick, and doh_names_ok flushes dnsmasq's cache — while both
	# protocols are dead that cache is all that still gives the house names.
	doh_lv "$_dls_l"
	_dpl=$(cat "$_lvd" 2>/dev/null | tr -cd '0-9')
	[ -z "$_dpl" ] || [ "$(age_since "$_dpl")" -ge "$_lvr" ] || return 0
	# The name probe only decides whether to move — with no live wire below either there is nowhere to move, and its cache flush
	# every tick would wipe what still feeds the house (review s.147: 5 ticks, 5 SIGHUPs).
	_dls_c=$(doh_lv_live "$_dls_l"); _dls_m=''
	# Nothing alive below — a middle rung above may live again (doh_lv_up), at most one climb per retry (DOH_QUIC_UP).
	[ -n "$_dls_c" ] || ! doh_lv_climb_ok || { _dls_c=$(doh_lv_up "$_dls_l"); _dls_m=up; }
	[ -n "$_dls_c" ] || return 0          # мертвы все ступени этим путём — это путь, его чинят несущая и увод
	doh_lv_names "$_dls_l" && return 0
	if [ -n "$3" ] && ! "$3"; then return 0; fi
	doh_lv_fallback "$_dls_l" "$_dls_c" "$_dls_m" && return $((3 + _dls_k))
	doh_lv "$_dls_l"; date +%s > "$_lvd" 2>/dev/null
	return $((5 + _dls_k))
}
doh_port_tick() {
	# Moves of a level not chosen go: the flags live in RAM, and the other level's would steer doh_proto_now after a switch back.
	[ "$(doh_lv_of)" = dot ] || rm -f "$DOH_DOT_FALLBACK" "$DOH_DOT_TRY" "$DOH_DOT_PATH" 2>/dev/null
	[ "$(doh_lv_of)" = quic ] || rm -f "$DOH_QUIC_FALLBACK" "$DOH_QUIC_TRY" "$DOH_QUIC_DOWN" "$DOH_QUIC_PATH" "$DOH_QUIC_UP" 2>/dev/null
	_dpk=$(doh_lv_of); [ -n "$_dpk" ] || return 0
	doh_want && doh_running || return 0
	doh_upstream_set || return 0          # DNS идёт мимо прокси — порт прокси ни на что не влияет
	[ -n "$(doh_lv_rungs "$_dpk")" ] || return 0   # переезжать не на что
	doh_clock_ok || return 0
	# Возраст отметок — ТОЛЬКО через age_since: все в /tmp и рождаются после загрузки, а часы тут прыгают.
	_dpt=$(cat "$DOH_PORT_STAMP" 2>/dev/null | tr -cd '0-9'); [ -n "$_dpt" ] || _dpt=0
	[ "$(age_since "$_dpt")" -ge "$DOH_PORT_EVERY" ] || return 0
	date +%s > "$DOH_PORT_STAMP"      # $_dpt остаётся эпохой ПРОШЛОЙ сверки — с неё doh_dot_troubled читает лог
	doh_lv_sweep "$_dpk" "$_dpt" "$1"
}

# ЕДИНСТВЕННОЕ место, где doh-lib зовёт плагин транспорта, и список ЗАКРЫТЫЙ. Верб `dns` ставит
# ПРЯМОЙ DNS только у byedpi и zapret: у них прямой режим — норма, и только они вешают RETURN'ы
# для 1.1.1.1/8.8.8.8 в mangle. У awg/xray/hy2 ТОТ ЖЕ верб ставит ТУННЕЛЬНЫЙ резолвер — позвать
# его в fail-open значило бы увести DNS в мёртвый туннель, то есть починить хуже, чем не чинить.
# Новый транспорт с прямым DNS обязан дописать себя СЮДА. Возврат 0 = плагин отработал.
# doh_direct_by_name — «у ЭТОГО транспорта прямой режим ПО ОПРЕДЕЛЕНИЮ» (десинк без несущей).
# ЕДИНСТВЕННЫЙ список на файл: тот же вопрос задают doh_plugin_direct_dns (кому можно отдать верб
# `dns`), doh_direct_regime (какой якорь ставить) и doh_retunnel (ждать ли маршрут). Три копии
# разъехались бы на шестом транспорте — забытая строка молча запретила бы ему возврат резолвера.
# Новый транспорт с прямым DNS дописывает себя СЮДА, и только сюда.
doh_direct_by_name() {
	case "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" in
		byedpi|zapret) return 0 ;;
	esac
	return 1
}
doh_plugin_direct_dns() {
	doh_direct_by_name || return 1
	[ -f "$ENODIA_DIR/transport.sh" ] || return 1
	sh "$ENODIA_DIR/transport.sh" dns >/dev/null 2>&1
}

# МЫ СЕЙЧАС В ПРЯМОМ РЕЖИМЕ DNS? Судим по ФАКТУ сети, а не по имени транспорта: несущая держит
# `default` в table 1000 ⇒ её DNS туннельный, и авто-режиму там места нет. byedpi/zapret —
# исключение: у них несущая (или её отсутствие) прямая по определению.
doh_direct_regime() {
	doh_direct_by_name && return 0
	[ -z "$(carrier_iface)" ]
}

# Вернуть DNS прямого режима. ГРАБЛЯ (ревью 09.08.2026): своя запись 00-upstream.conf чинила ровно
# половину. У byedpi (несущая ЖИВА, а режим прямой) адреса 1.1.1.1/8.8.8.8 лежат в iplist_set ⇒
# апстрим-запросы dnsmasq метятся → table 1000 → xtun → ciadpi, где UDP-DNS не проходит («not
# resolved»). RETURN'ы для них ставит dns_direct_rules внутри set_direct_dns плагина — но при
# взведённом авто-DoH тот выходит ПЕРВОЙ строкой (`doh_apply_dns direct && return 0`), то есть
# правил не было НИКОГДА, и «вернул обычный DNS» оставляло дом вообще без имён при письме
# «интернет должен заработать сразу». Рекурсии нет: карантин записан ДО нас ⇒ doh_apply_dns у
# плагина вернёт 1 и он честно пойдёт своим прежним путём.
# Там, где несущей нет (awg после safety_off, релинквиш xray/hy2), марка проваливается в main и
# открытого upstream ДОСТАТОЧНО — пишем сами, как раньше.
doh_restore_plain_dns() {
	doh_plugin_direct_dns && return 0
	dns_upstream_put "$DOH_PLAIN_DNS1" "$DOH_PLAIN_DNS2"
}

# dnsmasq ОТДАН ПРОКСИ? Истина — строка в конфиге, в ЛЮБОЙ из двух копий (init копирует /etc→/tmp
# аддитивно, расходятся они ровно в окне правки). Спрашивают двое: снятие указателя ниже и сверка порта
# (doh_port_tick) — там «DNS идёт мимо прокси» значит «порт прокси ни на что не влияет».
doh_upstream_set() {
	for _dus in /etc/dnsmasq.d/00-upstream.conf /tmp/dnsmasq.d/00-upstream.conf; do
		grep -q "server=$DOH_ADDR#$DOH_PORT" "$_dus" 2>/dev/null && return 0
	done
	return 1
}

# СНЯТЬ НАШ УКАЗАТЕЛЬ НА ЛОКАЛЬНЫЙ ПРОКСИ, когда владельца DNS не осталось вовсе.
# ГРАБЛЯ (живой AX3600, 31.08.2026, у пользователя дважды пропадал интернет): в установке
# «только панель» транспорта НЕТ, поэтому `transport.sh dns` делегировать некому, и вся его
# ветка сводится к `doh_apply_dns direct`. При включении тот пишет `server=127.0.0.1#5053` — а
# при ВЫКЛЮЧЕНИИ честно «оставляет прежний путь байт-в-байт», и прежний путь это та же строка,
# которую он сам и написал. Прокси к этому моменту уже погашен (`doh_stop` в doh_off) ⇒ dnsmasq
# форвардит в мёртвый порт, и ВСЯ сеть за роутером остаётся без имён до ручного вмешательства.
# У транспортов дыры нет: там DNS возвращает плагин.
# Возвращаем СТОКОВЫЙ резолв (снимаем файл), а не 1.1.1.1/8.8.8.8: в PANEL_ONLY DNS изначально
# стоковый, подменять его открытым upstream'ом не наше дело — install.sh на этом же месте файл
# именно СНИМАЕТ. Обе копии обязательны: init копирует /etc -> /tmp АДДИТИВНО, без чистки.
# Судим по СОДЕРЖИМОМУ: чужую строку (туннельный DNS, стоковый апстрим) не трогаем никогда.
# Возврат: 0 — сняли, 1 — трогать было нечего.
doh_release_upstream() {
	doh_upstream_set || return 1
	rm -f /etc/dnsmasq.d/00-upstream.conf /tmp/dnsmasq.d/00-upstream.conf 2>/dev/null
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
	return 0
}

# ВЗВОД АВТО-РЕЖИМА ПОСЛЕ КАРАНТИНА. Письмо об откате обещает «через час роутер попробует снова»,
# и до этой функции обещание было ложным: карантин по истечении лишь РАЗРЕШАЕТ авто-режим, а
# взводит его только doh_apply_dns — то есть dns-сеттер транспорта, которого при проходящем health
# больше никто не зовёт (byedpi/zapret живут тиками без смены DNS, у awg safety_off отрабатывает
# ОДИН раз на переходе). Итог: шифрованный DNS выключался до ближайшего switch/repair/ребута.
# Гейт `-f` на файле карантина ОБЯЗАТЕЛЕН: без него мы дёргали бы взвод (а это рестарт dnsmasq)
# каждые 10 минут на КАЖДОМ роутере, где авто-режим просто неприменим. Срок считаем ЗДЕСЬ, а не
# через doh_auto_cooling: та снимает файл, а нам он нужен до САМОЙ попытки — иначе отказ по
# аплинку (или по регламенту) съел бы карантин, и второго шанса не было бы никогда.
# $1 — имя функции «жив ли аплинк» (см. doh_health_tick).
# Возврат: 0 — взвели (зовущий сообщит), 1 — нечего делать. Судим по ФАКТУ стампа: сам взвод
# обвязан функциональной пробой и мог откатиться снова.
doh_rearm_after_cooldown() {
	[ -f "$DOH_AUTO_COOLDOWN" ] || return 1
	_drc=$(cat "$DOH_AUTO_COOLDOWN" 2>/dev/null | tr -cd '0-9')
	[ -n "$_drc" ] || { rm -f "$DOH_AUTO_COOLDOWN" 2>/dev/null; return 1; }
	doh_clock_ok || return 1                     # часы не выставлены — судить о сроке нечем
	[ "$(date +%s)" -ge "$_drc" ] || return 1    # карантин ещё держится
	doh_installed || return 1
	[ "$(cat "$ENODIA_STATE/.doh-auto" 2>/dev/null)" != off ] || return 1
	doh_enabled && return 1                      # DNS держит тумблер — авто-режим тут ни при чём
	doh_direct_regime || return 1                # успели уйти в туннель — авто-режим там не живёт
	if [ -n "$1" ] && ! "$1"; then return 1; fi  # аплинка нет — карантин НЕ снимаем, попробуем позже
	rm -f "$DOH_AUTO_COOLDOWN" 2>/dev/null       # ДО попытки: иначе doh_auto её же и запретит
	# byedpi/zapret: плагин и взведёт (через doh_apply_dns direct), и починит прямой DNS, если не
	# встало. Прочие: взводим сами, а на провале ОБЯЗАНЫ вернуть открытый upstream — doh_apply_dns
	# на неудачной пробе гасит прокси, но dnsmasq оставляет смотреть в уже мёртвый :5053.
	if ! doh_plugin_direct_dns; then
		doh_apply_dns direct || doh_restore_plain_dns
	fi
	doh_auto_active
}

# ПЕРИОДИЧЕСКАЯ ЖИВОСТЬ АВТО-DoH. Зовёт сторож (finish()), политика и троттл — здесь, второй копии
# нет. Возврат: 0 — щупать не время / резолвер жив; 1 — ОТКАТИЛИ (зовущий пишет в лог и шлёт
# письмо); 2 — карантин истёк и авто-режим ВЗВЕДЁН обратно (зовущий пишет в лог, письма не надо).
#
# ЗАЧЕМ. doh_apply_dns пробит резолвер РОВНО ОДИН РАЗ — в момент, когда авто-режим взводится.
# Дальше следить некому, а деградирует он как раз потом. Поймано 09.08.2026 на дампе тестера
# (МГТС, прямой режим после fail-open): авто-DoH встал штатно, а через минуты ISP начал душить
# :443 к 1.1.1.1 — 92 провала резолва за 25 минут при ЖИВОМ демоне. Человек видит «интернет есть,
# пинг есть, но ничего не открывается», причём даже то, что открылось бы напрямую, — и никакой
# подсказки: и панель, и keepalive сторожа считают DoH здоровым, раз процесс на месте.
#
# ПОЧЕМУ ОТКАТ, А НЕ ПЕРЕБОР РЕЗОЛВЕРОВ. Авто-режим — наша инициатива, а не просьба пользователя
# (тумблер выключен). Его цена — спрятать DNS от ISP; если платой стал мёртвый DNS, честнее вернуть
# прежний путь, чем вслепую перебирать резолверы, пока дом сидит без имён. РУЧНОЙ режим не трогаем
# вовсе (гейт doh_auto_active — стамп ставит только авто): там DoH попросили явно, и молча его
# выключить = сделать не то, о чём просили. Ровно та же граница, что у отката в doh_apply_dns.
doh_health_tick() {
	# $1 — ИМЯ функции «жив ли аплинк» (у сторожа это wan_probe_ok). Зовём её ТОЛЬКО когда проба
	# уже провалилась: она платная (curl с таймаутом), а в норме тут должно быть тихо.
	if ! doh_auto_active; then
		rm -f "$DOH_HEALTH_MISS" "$DOH_HEALTH_STAMP" 2>/dev/null
		doh_rearm_after_cooldown "$1" && return 2
		return 0
	fi
	doh_clock_ok || return 0
	_dhn=$(date +%s)
	# Возраст отметки — ТОЛЬКО через age_since. Отметка лежит в /tmp (рождается после загрузки), а
	# часы на этом железе прыгают вперёд через ~13 мин: голая разность врёт ровно на величину шага,
	# и троттл «раз в 10 минут» открывался бы разом вместе со всеми прочими. Тот же инвариант, что
	# у doh_custom_refresh выше; шим age_since объявлен в шапке файла.
	_dhl=$(cat "$DOH_HEALTH_STAMP" 2>/dev/null | tr -cd '0-9'); [ -n "$_dhl" ] || _dhl=0
	[ "$(age_since "$_dhl")" -ge "$DOH_HEALTH_EVERY" ] || return 0
	echo "$_dhn" > "$DOH_HEALTH_STAMP"
	# Успех обнуляет счётчик: реагируем на УСТОЙЧИВУЮ деградацию, а не на одиночный таймаут
	# (у DoH их хватает и на здоровой сети — HTTP/2-сессия перезаезжает, anycast-узел тормозит).
	# Здоровьем считаем ОБА признака: имя резолвится через dnsmasq И проволока до резолвера жива.
	# Одного doh_probe мало — ответ мог прийти из кэша dnsmasq (см. doh_wire_ok).
	if doh_probe 2 && doh_wire_ok; then rm -f "$DOH_HEALTH_MISS" 2>/dev/null; return 0; fi
	# Аплинка нет ⇒ провалилась бы ЛЮБАЯ проба, и резолвер тут ни при чём: промах не засчитываем.
	# Иначе авария у провайдера выключала бы исправный DoH на час (у транспортов с ЛОКАЛЬНЫМ
	# health — zapret — тик доходит сюда и при мёртвом WAN).
	if [ -n "$1" ] && ! "$1"; then return 0; fi
	_dhm=$(cat "$DOH_HEALTH_MISS" 2>/dev/null | tr -cd '0-9'); [ -n "$_dhm" ] || _dhm=0
	_dhm=$((_dhm + 1)); echo "$_dhm" > "$DOH_HEALTH_MISS"
	[ "$_dhm" -ge "$DOH_HEALTH_MISS_MAX" ] || return 0
	# Пробы шли до ~10 с — за это время транспорт мог смениться, и DNS уже держит не авто-режим
	# (стамп снимает doh_apply_dns). Откатывать тогда нечего, а plain-upstream затёр бы только что
	# выставленный туннельный.
	doh_auto_active || return 0
	rm -f "$DOH_HEALTH_MISS" 2>/dev/null
	echo $((_dhn + DOH_COOLDOWN_SEC)) > "$DOH_AUTO_COOLDOWN"
	doh_auto_rollback
	doh_restore_plain_dns
	return 1
}

# ЗДОРОВЬЕ СЛОЯ ОДНИМ ОТВЕТОМ — для экрана «Шифрованный DNS». Всё это слой УЖЕ знает (флаги в /tmp выше),
# но до сих пор рассказывал только сторожу и письмам: панель видела «прокси работает» там, где резолвер
# ушёл мимо туннеля, откатился на час или копит промахи к откату. «Демон жив» ≠ «сервис работает» —
# инвариант проекта, и отвечать на него обязан тот, кто принимает решения, а не читатель его файлов:
# сроки (пауза возврата, карантин) — константы ЭТОГО файла, у панели своей арифметики над ними нет.
# Формат — строки `ключ=значение` (как у dns_now); числа — секунды, `-1` = «нет такого состояния».
#   untun=0|1      резолвер уведён мимо несущей (туннель не прошёл проверку сторожа)
#   untun_age=N    сколько секунд назад увели; -1 — отметка без времени (часы или старая версия)
#   retun_in=N     возврат в туннель уже пробовали и через туннель резолвер НЕ ответил — до следующей попытки
#   cool=N         авто-режим на карантине после отката — осталось; -2 — карантин держится, срок неизвестен
#                  (часы не выставлены: тот же выбор, что у doh_auto_cooling, — верим отметке)
#   miss=N         промахов проверки авто-режима подряд (из DOH_HEALTH_MISS_MAX)
#   miss_max=N     после скольких промахов откат
#   dotfb=0|1      выбран DoT, а прокси шифрует по DoH: порт 853 этим путём не проходит (doh_dot_fallback)
#   dotfb_age=N    сколько секунд назад переехали; -1 — отметка без времени
#   dotfb_retry=N  через сколько секунд сторож снова пощупает DoT (0 — на ближайшей сверке); -1 — неизвестно
#   quicfb=0|1     DoQ/DoH3 chosen, the proxy encrypts on a rung below (the QUIC level of the ladder); quicfb_to — which (dot|doh)
#   quicfb_age=N, quicfb_retry=N — as dotfb's
doh_health_state() {
	_hsu=0; _hsua=-1; _hsri=-1; _hsc=-1
	if [ -f "$DOH_UNTUNNELED" ]; then
		_hsu=1
		_hsua=$(age_since "$(cat "$DOH_UNTUNNELED" 2>/dev/null | tr -cd '0-9')")
		[ "$_hsua" -lt 999999 ] 2>/dev/null || _hsua=-1
		# Пауза возврата — только пока резолвер ещё уведён: после удачного возврата отметку снимает doh_retunnel.
		if [ -f "$DOH_RETUNNEL_STAMP" ]; then
			_hsra=$(age_since "$(cat "$DOH_RETUNNEL_STAMP" 2>/dev/null | tr -cd '0-9')")
			if [ "$_hsra" -lt 999999 ] 2>/dev/null; then
				_hsri=$((DOH_RETUNNEL_BACKOFF - _hsra)); [ "$_hsri" -ge 0 ] || _hsri=0
			fi
		fi
	fi
	if [ -f "$DOH_AUTO_COOLDOWN" ]; then
		_hscu=$(cat "$DOH_AUTO_COOLDOWN" 2>/dev/null | tr -cd '0-9')
		if [ -n "$_hscu" ]; then
			# Отметка — эпоха КОНЦА карантина, и сравнение с «сейчас» ровно то, что делает doh_auto_cooling
			# (владелец решения): без выставленных часов срок неизвестен, но карантин держится.
			if doh_clock_ok; then
				_hsc=$(( _hscu - $(date +%s) ))   # clock-raw: тот же вопрос, что у doh_auto_cooling, — «истёк ли срок»
				[ "$_hsc" -ge 0 ] || _hsc=-1
			else
				_hsc=-2
			fi
		fi
	fi
	_hsm=$(cat "$DOH_HEALTH_MISS" 2>/dev/null | tr -cd '0-9'); [ -n "$_hsm" ] || _hsm=0
	# Переезд порта — по ТОМУ ЖЕ вопросу, что задаёт демон (doh_proto_now), а не по голому файлу: флаг без
	# программы DoH ничего не меняет, и экран не должен говорить «шифрую по DoH», когда шифрует DoT. И только
	# пока шифрованный DNS вообще нужен (doh_want): флаг переживает выключение, а «шифрует DoH» при выключенном
	# шифровании было бы неправдой в дампе.
	_hsf=0; _hsfa=-1; _hsfr=-1
	if doh_want && doh_upstream_set && [ "$(doh_proto)" = dot ] && [ "$(doh_proto_now)" = doh ]; then
		_hsf=1
		_hsfa=$(age_since "$(cat "$DOH_DOT_FALLBACK" 2>/dev/null | tr -cd '0-9')")
		[ "$_hsfa" -lt 999999 ] 2>/dev/null || _hsfa=-1
		# Срок следующей попытки — тем же правилом, что у doh_port_tick: от прошлой попытки, а не было её — от переезда.
		_hsfl=$(cat "$DOH_DOT_TRY" 2>/dev/null | tr -cd '0-9')
		[ -n "$_hsfl" ] || _hsfl=$(cat "$DOH_DOT_FALLBACK" 2>/dev/null | tr -cd '0-9')
		_hsfl=$(age_since "$_hsfl")
		if [ "$_hsfl" -lt 999999 ] 2>/dev/null; then
			_hsfr=$((DOH_DOT_RETRY - _hsfl)); [ "$_hsfr" -ge 0 ] || _hsfr=0
		fi
	fi
	# Пауза ручного DoH после неудачной перепроводки (doh_rearm_due): сколько до следующей попытки сторожа, -1 — паузы нет.
	# Только пока тумблер включён и dnsmasq смотрит мимо прокси: иначе пауза ни на что не влияет.
	_hsb=-1
	if [ -f "$DOH_BAIL_STAMP" ] && doh_enabled && ! doh_upstream_set; then
		_hsba=$(age_since "$(cat "$DOH_BAIL_STAMP" 2>/dev/null | tr -cd '0-9')")
		if [ "$_hsba" -lt 999999 ] 2>/dev/null; then _hsb=$((DOH_BAIL_BACKOFF - _hsba)); [ "$_hsb" -ge 0 ] || _hsb=0; fi
	fi
	# ODoH: откат «DoH напрямую к цели» — с какого времени и через сколько сторож попробует ретрансляторы; ретранслятор сейчас.
	_hso=0; _hsoa=-1; _hsor=-1; _hsrn=''
	if [ "$(doh_proto)" = odoh ]; then
		_hsrn=$(doh_odoh_relay_now)
		if doh_want && doh_upstream_set && [ -f "$DOH_ODOH_FALLBACK" ]; then
			_hso=1
			_hsoa=$(age_since "$(cat "$DOH_ODOH_FALLBACK" 2>/dev/null | tr -cd '0-9')")
			[ "$_hsoa" -lt 999999 ] 2>/dev/null || _hsoa=-1
			_hsol=$(cat "$DOH_ODOH_TRY" 2>/dev/null | tr -cd '0-9'); [ -n "$_hsol" ] || _hsol=$(cat "$DOH_ODOH_FALLBACK" 2>/dev/null | tr -cd '0-9')
			_hsol=$(age_since "$_hsol")
			if [ "$_hsol" -lt 999999 ] 2>/dev/null; then _hsor=$(( $(doh_odoh_retry_wait) - _hsol )); [ "$_hsor" -ge 0 ] || _hsor=0; fi
		fi
	fi
	# DoQ/DoH3 on a rung below (the QUIC level): since when, through how much the watchdog tries the QUIC protocol again, which rung —
	# by the same question the daemon asks (doh_proto_now), as dotfb.
	_hsq=0; _hsqa=-1; _hsqr=-1; _hsqn=''
	if doh_want && doh_upstream_set && [ "$(doh_lv_of)" = quic ] && [ "$(doh_proto_now)" != "$(doh_proto)" ]; then
		_hsq=1; _hsqn=$(doh_proto_now)
		_hsqa=$(age_since "$(cat "$DOH_QUIC_FALLBACK" 2>/dev/null | tr -cd '0-9')")
		[ "$_hsqa" -lt 999999 ] 2>/dev/null || _hsqa=-1
		_hsql=$(cat "$DOH_QUIC_TRY" 2>/dev/null | tr -cd '0-9')
		[ -n "$_hsql" ] || _hsql=$(cat "$DOH_QUIC_FALLBACK" 2>/dev/null | tr -cd '0-9')
		_hsql=$(age_since "$_hsql")
		if [ "$_hsql" -lt 999999 ] 2>/dev/null; then _hsqr=$((DOH_QUIC_RETRY - _hsql)); [ "$_hsqr" -ge 0 ] || _hsqr=0; fi
	fi
	printf 'untun=%s\nuntun_age=%s\nretun_in=%s\ncool=%s\nmiss=%s\nmiss_max=%s\ndotfb=%s\ndotfb_age=%s\ndotfb_retry=%s\nbail_in=%s\nodohfb=%s\nodohfb_age=%s\nodohfb_retry=%s\nodoh_relay=%s\nquicfb=%s\nquicfb_age=%s\nquicfb_retry=%s\nquicfb_to=%s\n' \
		"$_hsu" "$_hsua" "$_hsri" "$_hsc" "$_hsm" "$DOH_HEALTH_MISS_MAX" "$_hsf" "$_hsfa" "$_hsfr" "$_hsb" "$_hso" "$_hsoa" "$_hsor" "$_hsrn" \
		"$_hsq" "$_hsqa" "$_hsqr" "$_hsqn"
}

# doh_apply_dns <tunnel|direct> — ЗОВУТ dns-сеттеры транспортов ПЕРВОЙ строкой.
#   Тумблер ВКЛ → поднять прокси, dnsmasq→127.0.0.1#5053, :443 резолвера (tunnel=форс-марка в
#              туннель / direct=RETURN мимо марки), рестарт dnsmasq; возврат 0 ⇒ зовущий `return 0`.
#   Тумблер ВЫКЛ + режим DIRECT + авто разрешён → то же самое, но с ФУНКЦИОНАЛЬНОЙ ПРОБОЙ и
#              откатом при неудаче (авто не имеет права рвать DNS — юзер его не просил).
#   Иначе    → возврат 1 ⇒ зовущий продолжает СВОЙ прежний путь (байт-в-байт, НОЛЬ регрессий).
# Гарантия нулевой регрессии для TUNNEL-режимов сохраняется: без .doh-on функция там даёт 1 сразу.
doh_apply_dns() {
	_doh_auto=0; DOH_APPLY_NOTE=
	if doh_enabled; then
		rm -f "$DOH_AUTO_STAMP" 2>/dev/null       # DNS держит тумблер, а не авто-режим
	elif [ "$1" = direct ] && doh_auto; then
		_doh_auto=1
		: > "$DOH_AUTO_STAMP"                     # ДО doh_start: гейт doh_want обязан пропустить
	else
		rm -f "$DOH_AUTO_STAMP" 2>/dev/null       # авто больше не держит DNS (ушли в туннель/запрещён)
		rm -f "$DOH_UNTUNNELED" "$DOH_RETUNNEL_STAMP" 2>/dev/null   # DoH выключен ⇒ и «уведён» не про что
		return 1
	fi
	# Мы и есть перепроводка: пауза после прошлой неудачи (DOH_BAIL_STAMP) своё отслужила — провал ниже поставит её заново.
	rm -f "$DOH_BAIL_STAMP" 2>/dev/null
	# ВЕРДИКТ ПЕРЕЕЗДА — ПРО ПУТЬ (DOH_DOT_PATH): перепроводка на другой путь (сменили транспорт, авто-режим в прямом режиме)
	# обязана сперва попробовать выбранный DoT. Прокси при этом ещё на DoH — гасим, ниже он встанет под DoT, а не пошли
	# имена — проба ниже отдаст решение doh_dot_rescue, как на любом подъёме. Путь тот же — вердикт живёт, цена ноль.
	if doh_dot_path_stale "$([ "$1" = tunnel ] && echo mark || echo bypass)"; then
		doh_dot_forget
		doh_running && { doh_resolver_mark del; doh_resolver_bypass del; doh_stop; }
	fi
	# The QUIC level's verdict is about the path the same way: another path — try the chosen DoQ/DoH3 first.
	if doh_lv_path_stale quic "$([ "$1" = tunnel ] && echo mark || echo bypass)"; then
		doh_lv_forget quic
		doh_running && { doh_resolver_mark del; doh_resolver_bypass del; doh_stop; }
	fi
	# THE DIRECT PATH ASKS QUIC BEFORE THE PROXY RISES ON IT (review s.152 r1 M1): «Отключить VPN», FAILOPEN, a switch to ByeDPI/Zapret
	# and the auto mode come here, and on a WAN that cuts QUIC (the common Russian case) the proxy rose on DoQ, dnsmasq was pointed at it
	# and the ladder fell with the house without names — on every off/on cycle, since the tunnel's return forgets the bypass rung. Asked
	# BEFORE dnsmasq is pointed at the proxy (where the previous path still works — a CGI, a switch to ByeDPI — the house keeps its names
	# during the probe; after «Отключить VPN»/FAILOPEN the old path is gone anyway); a rung found — the proxy rises there (a running one is
	# stopped first, as above). Not over a proxy ALREADY on the chosen QUIC with its RETURN anchors standing (a repeated direct rewire:
	# the watchdog's pointer return, a second «Отключить VPN» pass): its names are judged by the probe below as before, and one transient
	# wire timeout must not pin a rung for DOH_QUIC_RETRY (review s.152 r2). A proxy without anchors yet (boot heal over doh-early's, a
	# CGI that just changed the resolver) IS asked — skipping «none» would skip the new resolver's question too (review s.152 r3 A-L1);
	# there a transient timeout costs an hour on the rung, encrypted still. The tunnel form does not ask here: this up-path runs right
	# after a carrier raise, when QUIC reads dead for 5–9 s.
	if [ "$1" = direct ] && ! { doh_running && [ "$(doh_proto_now)" = "$(doh_proto)" ] && [ "$(doh_anchor_state)" = bypass ]; } \
	   && doh_quic_preset bypass; then
		doh_running && { doh_resolver_mark del; doh_resolver_bypass del; doh_stop; }
	fi
	# Прокси должен РЕАЛЬНО работать, прежде чем уводить на него dnsmasq: несовместимый/битый
	# бинарь (напр. version skew ядра 4.4 на AX3600 — libcurl<7.62) форкается и тут же падает,
	# start-stop-daemon -b об этом не знает (вернул 0 после fork). Без проверки dnsmasq указал бы
	# на мёртвый 127.0.0.1:5053 и DNS всего дома лёг бы. Уже бежит → без задержки; только что
	# стартовали → секунда на подняться/упасть + проверка pid. Не встал → откат на прежний DNS-путь
	# транспорта (return 1), DNS цел. Так DoH self-protecting на платформах без рабочего бинаря.
	_doh_started=0
	if ! doh_running; then
		doh_start
		sleep 1
		if ! doh_running; then
			doh_apply_fail
			return 1
		fi
		_doh_started=1
	fi
	# ДОЖДАТЬСЯ ПОРТА до того, как трогать DNS (см. doh_wait_listen): иначе окно в
	# полминуты, где dnsmasq уже уведён на ещё не слушающий прокси, а сеть без имён.
	if ! doh_wait_listen; then
		doh_apply_fail
		return 1
	fi
	# Штатная перепроводка отменяет «уведён мимо несущей»: сюда приходят с ПОДНЯТОЙ несущей
	# (up/switch/repair/тумблер), то есть повод, по которому уводили, снят. Иначе флаг пережил бы
	# починку и сторож больше никогда не вернул бы резолвер в туннель.
	rm -f "$DOH_UNTUNNELED" "$DOH_RETUNNEL_STAMP" 2>/dev/null
	_doh_was=$(doh_anchor_state)
	if [ "$1" = tunnel ]; then
		doh_resolver_bypass del      # если оставался RETURN прямого режима — снять
		doh_resolver_mark add
		_doh_now=mark
	else
		doh_resolver_mark del        # если оставалась форс-марка туннельного режима — снять
		doh_resolver_bypass add
		_doh_now=bypass
	fi
	# ЯКОРЬ СМЕНИЛСЯ ПОД ЖИВЫМ ПРОКСИ ⇒ РВЁМ ЕГО СЕССИЮ (ревью 2, 06.09.2026). Прокси мы застали
	# поднятым (`_doh_started=0`) — типичный бут: его поднял ранний старт или heal 5.14 ДО несущей,
	# и TLS/HTTP-2 к резолверу установлен ПО WAN с WAN-адресом источника. Свежая марка уводит те же
	# пакеты в несущую с тем же адресом: сервер WireGuard/AWG отбрасывает источник вне AllowedIPs,
	# у tun2socks чужой мид-стрим соединения не имеет — сессия молчит до внутреннего таймаута. Без
	# рестарта проба ниже валится ПО ВИНЕ ПРОКСИ, а причиной в лог уезжает «несущая ещё не везёт».
	# Тот же приём и по той же причине стоит в doh_untunnel_apply / doh_retunnel. Якорь не менялся
	# И несущую не трогали (штатный повторный `dns`) ⇒ рестарта нет: цена ноль.
	# …А НЕСУЩАЯ — ВТОРАЯ ПОЛОВИНА ТОГО ЖЕ ВОПРОСА (ревью 3, 06.09.2026): нас зовут из `cmd_up`
	# плагина СРАЗУ после пересоздания awg0/xtun (reup сторожа, failover, switch, repair). Якорь при
	# этом был `mark` и остался `mark`, а сокет прокси всё равно мёртв — он висел на СНЕСЁННОМ
	# устройстве. Без рестарта проба ниже валилась по вине прокси, и в лог плагина уезжал ложный
	# диагноз «несущая ещё не везёт» плюс лишний увод. Признак «несущую только что подняли» уже
	# есть — отметка плагинов $CARRIER_UP_STAMP (clock-lib.sh).
	_doh_fresh=0
	[ "$(age_since "$(cat "${CARRIER_UP_STAMP:-/tmp/.enodia-carrier-up.stamp}" 2>/dev/null | tr -cd '0-9')")" -lt 60 ] && _doh_fresh=1
	if [ "$_doh_started" = 0 ] && { [ "$_doh_was" != "$_doh_now" ] || [ "$_doh_fresh" = 1 ]; }; then
		# Потолок КОРОТКИЙ: порт слушал секунду назад, значит бинарь уже прогрет и «Listening»
		# приходит мгновенно. Полные 45 с тут были бы третьим ожиданием в одном вызове (ревью 3).
		doh_restart_wait 10 || { doh_apply_fail; return 1; }
	fi
	dns_upstream_put "$DOH_UPSTREAM"
	# ПРОВЕРЯЕМ, ЧТО ИМЕНА ДЕЙСТВИТЕЛЬНО РЕЗОЛВЯТСЯ — В ОБОИХ РЕЖИМАХ. Раньше ручной не пробили
	# намеренно («DoH — осознанный выбор пользователя»), и это стоило всей сети за роутером:
	# на AX3600 прокси запускается, слушает порт и НЕ отвечает ни на один запрос, а dnsmasq к
	# этому моменту уже нацелен на него ⇒ дом без имён, и ловит это только health-тик через ~10
	# минут (поймано 31.08.2026, у пользователя дважды пропадал интернет). Согласие «шифровать
	# DNS» не есть согласие «остаться без DNS»: не смогли — возвращаем прежний путь СРАЗУ.
	# Цена платится только в аварии: на здоровом роутере первый же nslookup отвечает за миллисекунды.
	# Проба заодно РАБОТАЕТ ПРОГРЕВОМ (первый запрос платит за TCP+TLS+HTTP/2, busybox-клиенты
	# столько не ждут) — отдельной строки прогрева больше нет.
	# В ТУННЕЛЬНОМ режиме пробе дают ТРИ попытки, а не две: сюда приходят СРАЗУ после подъёма
	# несущей, а рукопожатие awg занимает 5–9 с (замер 05.09.2026) — резолвер, увезённый маркой в
	# туннель, эти секунды честно молчит, и две попытки (≈10 с) ложились на самую границу.
	# ODoH gets three as well: its cold start pays two handshakes (relay, and the target's key), and two tries took a slow first
	# start for a dead relay — the ladder then left for another relay or DoH straight to the target, which sees our address.
	_doh_pn=2; { [ "$1" = tunnel ] || [ "$(doh_proto_now)" = odoh ]; } && _doh_pn=3
	if ! doh_probe "$_doh_pn"; then
		# НЕСУЩАЯ ЕЩЁ НЕ ВЕЗЁТ (сервер молчит, рукопожатие отброшено, DPI), а резолвер уже в ней —
		# ровно тот дедлок, который сторож разрывает `doh_untunnel`. Но сторож приходит после
		# boot-grace и двух тиков гистерезиса (до ~7 минут), а откат ОТСЮДА гасил DoH целиком:
		# плагин писал plain-upstream в ту же мёртвую несущую (дом без DNS те же минуты), а когда
		# несущая вставала, резолв шёл ОТКРЫТЫМ при зелёном «шифрованный DNS: вкл» — до следующего
		# switch/repair (heal 5.14 поднимал прокси обратно, но dnsmasq на него уже не смотрел).
		# Делаем то, что сделал бы сторож, СРАЗУ: резолвер МИМО несущей (шифрование сохранено, флаг
		# стоит) — пошли имена ТАК, значит DNS у дома жив, а сторож вернёт резолвер в туннель первым
		# же здоровым тиком (doh_retunnel). Не пошли и так — дорога мертва целиком, откат прежний.
		# Слово об уводе — вызывающему (DOH_APPLY_NOTE): в лог плагина, а не в журнал событий —
		# на медленном рукопожатии это штатный бут, а не авария.
		# ПОРТ — РАНЬШЕ ПУТИ (09.09.2026, xray у тестера): несущая везёт, а её сервер не выпускает 853. Увод
		# мимо несущей тут лечит не то, а откат гасит шифрование при живом 443. «Порт или путь» решает
		# doh_dot_rescue (443 этим путём жив — пробуем DoH с проверкой имён); путь мёртв целиком — прежний увод.
		# После увода — тот же вопрос ещё раз: мимо несущей 853 у провайдера бывает закрыт, а 443 открыт.
		# DoQ/DoH3: QUIC is dropped on the way more often than TCP — a rung below on the other TLS stack (doh_lv_rescue quic), or
		# back to the chosen QUIC protocol when the proxy stood on a rung that is now the mute one.
		if doh_quic_rescue; then
			_doh_qp=$(doh_proto_label "$(doh_proto)"); _doh_qn=$(doh_proto_label "$(doh_proto_now)")
			if [ "$(doh_proto_now)" = "$(doh_proto)" ]; then
				DOH_APPLY_NOTE="$_doh_qp этим путём снова отдаёт имена — вернулся на выбранный $_doh_qp"
			else
				DOH_APPLY_NOTE="$_doh_qp этим путём не отдаёт имён, а $_doh_qn того же резолвера отдаёт — шифрую по $_doh_qn; сторож проверит $_doh_qp и вернётся на него сам"
			fi
			doh_quic_preset_settle ok; return 0
		fi
		if doh_dot_rescue; then
			if [ "$(doh_proto_now)" = dot ]; then
				DOH_APPLY_NOTE="DoH этим путём не отдаёт имён, а выбранный DoT отдаёт — вернулся на DoT"
			else
				DOH_APPLY_NOTE="DoT этим путём не отдаёт имён, а DoH того же резолвера отдаёт — шифрую по DoH; сторож проверит DoT и вернётся на него сам"
			fi
			doh_quic_preset_settle ok; return 0
		fi
		# ODoH: другой ретранслятор, затем DoH напрямую к цели (doh_odoh_rescue) — тот же вопрос «порт/посредник или путь».
		if doh_odoh_rescue; then
			if [ "$(doh_proto_now)" = odoh ]; then
				DOH_APPLY_NOTE="ретранслятор ODoH не отдавал имён — иду через другой"
			else
				DOH_APPLY_NOTE="ни один ретранслятор ODoH не отдаёт имён — шифрую по DoH напрямую к цели; сторож проверит ретрансляторы и вернётся на ODoH сам"
			fi
			doh_quic_preset_settle ok; return 0
		fi
		_doh_pb=$(doh_proto_now)
		if [ "$1" = tunnel ] && doh_untunnel_apply && { doh_probe || doh_dot_rescue || doh_odoh_rescue || doh_quic_rescue; }; then
			DOH_APPLY_NOTE="резолвер уведён мимо несущей — та ещё не везёт (рукопожатие/сервер); сторож вернёт его в туннель, когда health пройдёт"
			# …И О ПРОТОКОЛЕ (бэклог ветки fix/dot-port-fallback, (11)): после увода имена мог дать только ДРУГОЙ протокол
			# (doh_dot_rescue), и слово «уведён» молчало бы о том, что DNS теперь шифруется не тем, что выбрано.
			# Прокси был на DoH ещё ДО увода (прежний переезд) — DoT мимо несущей никто не щупал, и говорить «не отдаёт»
			# было бы неправдой: сторож проверит его сам (путь сменился — срок DOH_DOT_RETRY не ждёт).
			_doh_pa=$(doh_proto_now)
			_doh_qp=$(doh_proto_label "$(doh_proto)"); _doh_qn=$(doh_proto_label "$_doh_pa")
			if [ "$_doh_pa" != "$_doh_pb" ] && [ "$(doh_lv_of)" = quic ]; then
				if [ "$_doh_pa" = "$(doh_proto)" ]; then
					DOH_APPLY_NOTE="$DOH_APPLY_NOTE; мимо несущей $_doh_qp отдаёт имена — вернулся на выбранный $_doh_qp"
				else
					DOH_APPLY_NOTE="$DOH_APPLY_NOTE; мимо несущей $_doh_qp не отдаёт имён, а $_doh_qn того же резолвера отдаёт — шифрую по $_doh_qn, сторож проверит $_doh_qp и вернётся на него сам"
				fi
			elif [ "$(doh_lv_of)" = quic ] && [ "$_doh_pa" != "$(doh_proto)" ]; then
				DOH_APPLY_NOTE="$DOH_APPLY_NOTE; шифрую по $_doh_qn, как и до увода, хотя выбран $_doh_qp — сторож проверит $_doh_qp на новом пути и вернётся на него сам"
			elif [ "$_doh_pa" != "$_doh_pb" ]; then
				if [ "$(doh_proto)" = odoh ]; then
					if [ "$_doh_pa" = odoh ]; then
						DOH_APPLY_NOTE="$DOH_APPLY_NOTE; мимо несущей ретранслятор отвечает — вернулся на выбранный ODoH"
					else
						DOH_APPLY_NOTE="$DOH_APPLY_NOTE; мимо несущей ретрансляторы ODoH не отдают имён — шифрую по DoH напрямую к цели, сторож проверит ретрансляторы и вернётся на ODoH сам"
					fi
				elif [ "$_doh_pa" = dot ]; then
					DOH_APPLY_NOTE="$DOH_APPLY_NOTE; мимо несущей DoH не отдал имён, а выбранный DoT отдаёт — вернулся на DoT"
				else
					DOH_APPLY_NOTE="$DOH_APPLY_NOTE; мимо несущей DoT не отдаёт имён, а DoH того же резолвера отдаёт — шифрую по DoH, сторож проверит DoT и вернётся на него сам"
				fi
			elif [ "$_doh_pa" = doh ] && [ "$(doh_proto)" = dot ]; then
				DOH_APPLY_NOTE="$DOH_APPLY_NOTE; шифрую по DoH, как и до увода, хотя выбран DoT — сторож проверит DoT на новом пути и вернётся на него сам"
			elif [ "$_doh_pa" = doh ] && [ "$(doh_proto)" = odoh ]; then
				DOH_APPLY_NOTE="$DOH_APPLY_NOTE; шифрую по DoH напрямую к цели, как и до увода — сторож проверит ретрансляторы на новом пути и вернётся на ODoH сам"
			fi
			doh_quic_preset_settle ok; return 0
		fi
		rm -f "$DOH_UNTUNNELED" 2>/dev/null
		doh_apply_fail
		return 1
	fi
	# Names went: a provisional rung the preset stood on is a verdict now — the journal says it (doh_quic_preset).
	doh_quic_preset_settle ok
	return 0
}


# --- ЕДИНСТВЕННЫЙ CLI-ВЕРБ: `sh doh-lib.sh start` --------------------------------------------
# Библиотека, которую МОЖНО запустить, — и это не небрежность. Прокси надо поднимать РАНЬШЕ, чем
# отработает первый тик cron: там, где /etc персистентен (AX3600, BE3600), dnsmasq стартует со
# ссылкой на 127.0.0.1#5053 (наш сниппет пережил ребут), а прокси до сих пор поднимал именно
# первый тик — до минуты локалка без имён (замерено 31.08.2026: на 60-й секунде аптайма порт
# ещё не слушает, на 107-й уже слушает).
# Зовёт его init-скрипт `/etc/init.d/enodia-early`, а тот не вправе знать порядок загрузки наших
# библиотек и имена внутренних функций. Верб делает РОВНО то же, что секция 5.14 heal.sh, — тем
# же кодом: гейты `doh_want`/`doh_running` внутри doh_start, так что выключенный DoH это no-op.
# ЗВАТЬ heal.sh ЦЕЛИКОМ ОТТУДА НЕЛЬЗЯ: у него бутовый лок 1×/boot, и слишком ранний прогон СЪЕЛ
# бы его — тик cron через минуту пропустил бы восстановление, и роутер остался бы полуподнятым.
# Гард по `$0`: файл СОРСЯТ полтора десятка скриптов, у каждого свой `$1`, и без проверки
# «нас запустили, а не подключили» любой `web-ui.sh start` поднимал бы DoH побочным эффектом.
case "$0" in
	*doh-lib.sh)
		case "${1:-}" in
			start) doh_start ;;
			# restart — the running proxy on a fresh process from the installed file (Components → «Перезапустить»). Not running =
			# nothing to do: whether DoH SHOULD run is doh_want's call at its own start, not ours. Same pidfile for DoH and DoT.
			# The code is the restart's verdict (packages.sh::cmd_restart): 0 — the proxy is back AND names resolve through it, judged
			# WITHOUT dnsmasq's cache (doh_names_ok: a cached example.com would «prove» a mute proxy). Not back, or back but mute: dnsmasq
			# keeps forwarding to it, and the whole home is without names — so DNS is re-wired by its OWNER (`transport.sh dns` → plugin
			# → doh_apply_dns), which tries the proxy once more and otherwise falls back to the transport's plain path: encrypted DNS
			# must never mean no DNS — the rule of every DoH up-path (review of bins-2026-10, round 2). 1 — DoH is not working now.
			restart) doh_running || exit 0
			         doh_restart_wait && doh_names_ok && exit 0
			         [ -f "$ENODIA_DIR/transport.sh" ] && sh "$ENODIA_DIR/transport.sh" dns >/dev/null 2>&1
			         doh_running && doh_names_ok 1 && exit 0
			         exit 1 ;;
			"")    : ;;
			*)     echo "usage: $0 start|restart" >&2; exit 2 ;;
		esac
		;;
esac
