#!/bin/sh
# subs-update.sh — HEADLESS обновление VLESS-подписок (cron), БЕЗ открытой панели.
#
# Зачем. Подписку умел обновлять только браузер: тело качал CGI `fetch_sub`, а разбор
# (base64/gzip/JSON-массив, vless://→xray JSON) жил в panel.js. Значит серверы обновлялись,
# только когда человек откроет панель и нажмёт ⟳ — а провайдеры подписок ротируют адреса и
# UUID, и «внезапно перестал работать VPN» = просто протухший конфиг. Этот скрипт — та же
# логика на busybox sh: fetch → разбор → раскладка `xray-configs/sub-<tag>-*.json` → `.sub-names`.
# THREE FAMILIES of configs since then: xray JSON, Hysteria2 YAML (`hy2-configs/`) and AmneziaWG/WireGuard .conf (`configs/`) —
# one subscription may carry all three; what differs between them sits in ONE table, `fam_set`.
#
# ЧТО СЧИТАЕТСЯ ИСТИНОЙ
#   - реестр `.subs` (tag⇥url⇥label) пишет ТОЛЬКО панель (CGI); здесь он read-only — иначе
#     гонка cron с человеком за один файл;
#   - `.sub-names` (имя-файла⇥настоящее имя с эмодзи) — ещё и КАРТА ИДЕНТИЧНОСТИ: имя файла
#     для уже известного сервера берём оттуда, а не генерим заново. Иначе панель (JS режет
#     не-латиницу по UTF-16-символам) и роутер (sed режет по БАЙТАМ) дали бы РАЗНЫЕ имена
#     одному серверу, и каждый прогон сносил бы файлы соседнего пути как «устаревшие»;
#   - файл конфига переписываем, только если сменилась СУТЬ (адрес/порт/креды/SNI). Побайтовое
#     сравнение не годится: панельный JSON.stringify и наш printf форматируют по-разному ⇒
#     каждый тик был бы «изменение» + лишняя запись на 20-МБ флеш.
#
# ЧЕГО НЕ ДЕЛАЕМ. Активный конфиг не удаляем никогда (даже если сервер исчез из подписки —
# только событие): оборвать несущую по расписанию хуже, чем оставить протухший сервер.
# The same for a config an EXIT stands on (slots.sh holders): the exit could not come up after a restart.
#
# Вербы:
#   update [tag]   — обновить все подписки (или одну). Это же зовёт cron.
#   drop <tag>     — the subscription is being removed (cgi-bin/action remove_sub, BEFORE its `.subs` line goes): its configs
#                    of all families and its lines of `.sub-names`. A config in use (active, under an exit) stays
#                    and becomes the person's own — its name moves to cfg-names.sh, the CGI then moves its FILE out of
#                    «sub-<tag>-». The `.subs` line is left without its link (no run lays the configs out again meanwhile).
#   fetch <tag>    — тело подписки в base64 (используется CGI: одна копия закачки).
#   list           — что в реестре (tag, метка, сколько конфигов сейчас).
#   client-json    — how each subscription presents itself to its provider (User-Agent, HWID masked) — for cgi-bin/list.
#   parse <ссылка> — конфиг из ОДНОЙ ссылки в stdout, ничего не записывая: роутерный канон
#                    разбора ссылок (xray + hy2 + AmneziaWG/WireGuard), его же сверяют стенды паритета с panel.js.
#   name <ссылка>  — the name this link gives its server (remark, container description, config comment); read-only.
#   parse-json <file> — the same JSON profile normalizer without the OS argument-size limit; read-only.
#   import-body <tag> <file> — the browser relay of an already downloaded subscription, under the run lock.
#   sched …        — расписание живёт в update-sched.sh (job `subs`), сюда не дублируем.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
CFGDIR="$ENODIA_STATE/xray-configs"
NAMES="$ENODIA_STATE/.sub-names"
ACTIVE_F="$ENODIA_STATE/.xray-active"
HY2DIR="$ENODIA_STATE/hy2-configs"
HY2_ACTIVE_F="$ENODIA_STATE/.hy2-active"
AWGDIR="$ENODIA_STATE/configs"
AWG_ACTIVE_F="$ENODIA_STATE/.active"
# «This text of the active AmneziaWG config was tried and did not come up» — `name⇥md5 of its substance`. In RAM on purpose: the
# attempt costs the tunnel half a minute, so the SAME text is not tried on every run, but a reboot is a fair reason to try again.
AWG_TRIED=/tmp/enodia-subs-awg-tried
# The watchdog's state (NORMAL / FAILOPEN): switch-vpn.sh keeps it in step when it leaves the router in direct mode (safety_off).
WD_STATE=/tmp/enodia-watchdog.state
LOG=/tmp/enodia-subs-update.log
LOCK=/tmp/enodia-subs-update.lock
TMPD=/tmp/enodia-subs-update.$$
TAB=$(printf '\t')
# Preserve enough space on the volume that actually holds the configs and labels.
MINFREE_KB=${MINFREE_KB:-2048}

if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi   # lbl_commit_out: a file replaced whole or not at all
command -v lbl_commit_out_as >/dev/null 2>&1 || { lbl_commit_out_as() { _lct=$1; _lcf=$2; shift 2; "$@" > "$_lct" && mv -f "$_lct" "$_lcf" && return 0; rm -f "$_lct"; return 1; }; lbl_commit_out() { _lcf=$1; shift; lbl_commit_out_as "$_lcf.$$.new" "$_lcf" "$@"; }; lbl_grep() { grep "$@" || [ "$?" -le 1 ]; }; lbl_without() { if [ -f "$1" ]; then lbl_grep -v -- "$2" "$1" || return 1; fi; [ -z "${3:-}" ] || printf '%s\n' "$3"; }; }   # write-blind: the shim of a missing library is the old line
# Возраст отметок (clock-lib.sh) — нужен ровно одному месту, локу в take_lock; шим = прежнее.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
# switch_hold — the carrier is restarted under the switching lock, as every other restarter does (refresh_active; review s.136, M5).
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v switch_hold >/dev/null 2>&1 || switch_hold() { ( set -C; echo $$ > "$1" ) 2>/dev/null; }
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] && tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -qE "$2"; }
SWITCH_LOCK=/tmp/enodia-switching.lock
# WHOSE NEWS a config in use carries — the owner's words and events. A subscription run: the server «изменился в подписке». An Amnezia
# Premium refresh (premium.sh put, SUBS_PUT_WHY=premium): the router took a NEW KEY itself — «изменился в подписке» read as if the
# provider had changed something (walk 14.10.2026).
CHG="изменился в подписке"; CHG_D=" (адрес/креды)"
case "${SUBS_PUT_WHY:-}" in premium) CHG="получил новый ключ Amnezia"; CHG_D="" ;; esac
# How long a restart of the active carrier waits for the switching lock (switch_hold: no tick, no heal, no foreign switch).
CARRIER_HOLD_MAX=${CARRIER_HOLD_MAX:-120}
command -v age_since >/dev/null 2>&1 || age_since() {
	case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
	[ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

# Общий слой подписок (реестр/закачка/SSRF). Шим-фолбэк: без файла работает только то, что
# не ходит в сеть, — сама закачка честно откажет, а не полезет мимо гарда.
if [ -f "$ENODIA_DIR/subs-lib.sh" ]; then
	. "$ENODIA_DIR/subs-lib.sh"
else
	sub_host_public() { return 1; }
	sub_fetch() { return 1; }
	# Счётчики подписки без библиотеки просто не появятся: карточка панели показывает «без
	# счётчика», а не пустую полосу (пустая читалась бы как «всё израсходовано»).
	sub_info_put() { return 0; }
	sub_tags() { [ -f "$ENODIA_STATE/.subs" ] && cut -d"$TAB" -f1 "$ENODIA_STATE/.subs" 2>/dev/null; }
	sub_url_of() { [ -f "$ENODIA_STATE/.subs" ] && grep "^$1$TAB" "$ENODIA_STATE/.subs" 2>/dev/null | head -1 | cut -d"$TAB" -f2; }
	sub_label_of() { [ -f "$ENODIA_STATE/.subs" ] && grep "^$1$TAB" "$ENODIA_STATE/.subs" 2>/dev/null | head -1 | cut -d"$TAB" -f3-; }
	sub_owner_tag() { printf '%s' ""; }
fi
# …и ОТДЕЛЬНО — на библиотеку СТАРЕЕ фичи: ветка `else` срабатывает, только когда файла нет ВОВСЕ,
# а при точечной заливке (обновили один скрипт из двух) он есть, и функции в нём нет. Без этой
# строки каждый прогон писал бы «sub_info_put: not found» в лог прямо человеку под нос.
command -v sub_info_put >/dev/null 2>&1 || sub_info_put() { return 0; }
# The client a subscription presents itself as (subs-lib.sh::sub_fetch_tag) — the same case: an older library downloads as before.
command -v sub_fetch_tag >/dev/null 2>&1 || sub_fetch_tag() { sub_fetch "$2" "$3"; }
# Сводка прогона для панели (subs-lib.sh::sub_sum_cut) — тот же случай: без функции третье поле `.subs-last` осталось бы
# ПУСТЫМ, и сводка пропала бы с экрана «Подписки». Шим — прежняя обрезка по байту: обрыв посреди слова, но строка будет.
command -v sub_sum_cut >/dev/null 2>&1 || sub_sum_cut() { tr -d '\t\r\n' | cut -c1-"$1"; }
# Карта имён (subs-lib.sh::sub_names_keep_other) — тот же случай, и он ОПАСНЕЕ: шим ОБЯЗАН быть прежним поведением, а не
# пустотой — write_names перекладывает вывод этой функции в .sub-names, и «команда не найдена» при старой библиотеке стёрла бы
# КАРТУ ИМЁН всех подписок разом (прежде шим стоял только на случай, когда файла нет вовсе; ревью приёмки, круг 1).
command -v sub_names_keep_other >/dev/null 2>&1 || sub_names_keep_other() { [ -f "$ENODIA_STATE/.sub-names" ] && grep -v "^sub-$1-" "$ENODIA_STATE/.sub-names"; return 0; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }
say() { echo "$*"; log "$*"; }

# jsonfilter (OpenWrt libubox) — нужен ТОЛЬКО для подписок-JSON (массив готовых xray-конфигов,
# панели Marzban/Remnawave). Ссылочные подписки (vless/vmess/trojan/ss) разбираются без него.
JF=""
[ -x /usr/bin/jsonfilter ] && JF=/usr/bin/jsonfilter
[ -n "$JF" ] || JF=$(command -v jsonfilter 2>/dev/null)
jf() { [ -n "$JF" ] || return 1; "$JF" -i "$1" -e "$2" 2>/dev/null; }
if [ -f "$ENODIA_DIR/xray-profile-lib.sh" ]; then . "$ENODIA_DIR/xray-profile-lib.sh"; fi
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
profile_xray_bin() {
    if command -v bin_path >/dev/null 2>&1; then bin_path xray
    else printf '%s/xray\n' "${ENODIA_BIN:-/data/usr/app/enodia-bin}"; fi
}
command -v xp_pool >/dev/null 2>&1 || xp_pool() { return 1; }

# --- мелкие примитивы -------------------------------------------------------
# ud <строка> — percent-decode (как decodeURIComponent в панели; «+» в пробел НЕ переводим —
# это правило форм, а не URI). Бэкслеши экранируем ДО printf %b, иначе он их съест.
ud() { printf '%b' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/%\(..\)/\\x\1/g')" 2>/dev/null; }
# san <строка> — привести значение к виду, годному ВНУТРЬ строки JSON/YAML: спецсимволы
# ЭКРАНИРУЕМ, а не вырезаем. Здесь стоял `tr -d '"\\'`, и это молча портило ДАННЫЕ: пароль
# trojan/ss и auth hy2 законно содержат кавычку или бэкслеш, а после вырезания в конфиг ложился
# ДРУГОЙ пароль — «конфиг на месте, соединения нет, причину не видно». Панель на своей стороне
# всегда экранировала (JSON.stringify / hy2Quote), то есть копии расходились ещё и в этом.
# Порядок замен ОБЯЗАТЕЛЕН: бэкслеш первым, иначе он удвоит тот, что мы сами ставим перед
# кавычкой. Паритет с панелью сверяет local/link-parity-test.js.
SAN_CR=$(printf '\r')
SAN_TAB=$(printf '\t')
san() {
	printf '%s' "$1" \
		| sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g; s/$SAN_CR/\\\\r/g; s/$SAN_TAB/\\\\t/g" \
		| awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}
# san_txt <строка> — для НАСТОЯЩЕГО ИМЕНИ сервера (P_REMARK). Оно не уезжает в конфиг: им
# ключуется `.sub-names` и по нему ищется уже заведённый файл. Экранировать его НЕЛЬЗЯ —
# в `.sub-names` имя кладёт ещё и панель, СЫРЫМ, и `Германия "Плюс"` перестало бы совпадать
# с самим собой: каждый прогон крона заводил бы серверу новый файл вместо своего. Снимаем
# ровно то, что порвало бы TSV-строку.
san_txt() { printf '%s' "$1" | tr -d '\r\n\t'; }
is_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_host() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9._:-]{1,253}$'; }

# --- параметры одного сервера (P_*) ----------------------------------------
# busybox sh без `local` ⇒ параметры живут в глобальных P_*, и КАЖДЫЙ разбор начинается со
# сброса. Иначе поле предыдущего сервера (sni/path/flow) молча утекает в следующий — класс
# ошибок «в подписке 51 сервер, у 50 чужой SNI».
p_reset() {
	P_PROTO=; P_UUID=; P_HOST=; P_PORT=; P_REMARK=; P_TYPE=; P_SEC=; P_SNI=; P_FP=
	P_PBK=; P_SID=; P_SPX=; P_PATH=; P_HHDR=; P_SVC=; P_ALPN=; P_MODE=; P_FLOW=
	P_ENC=; P_AID=; P_SCY=; P_PASS=; P_METHOD=
	P_INSECURE=; P_OBFS=; P_OBFSPASS=
	P_CONF=
	P_PROFILE=
}

# b64_dec — stdin: base64 OR base64url, with or without padding → bytes on stdout. Links carry both alphabets and drop the
# `=` as often as not, while busybox `base64 -d` knows one alphabet and loses the unpadded tail («truncated base64 input»,
# measured on BE7000) — a password or a port came out a character short.
b64_dec() {
	tr -d ' \t\r\n=' | tr '_-' '/+' > "$TMPD/b64.in" 2>/dev/null || return 1
	case $(( $(wc -c < "$TMPD/b64.in") % 4 )) in
		2) printf '==' >> "$TMPD/b64.in" ;;
		3) printf '=' >> "$TMPD/b64.in" ;;
	esac
	base64 -d < "$TMPD/b64.in" 2>/dev/null
}

# hp_split <host:port|[v6]:port> — HP_HOST/HP_PORT. Хвостовые слэши снимаем (…:443/?…),
# IPv6 — в скобках, у обычного хоста порт = после ПОСЛЕДНЕГО двоеточия (зеркало hostPort()).
hp_split() {
	HP_HOST=; HP_PORT=
	_s=$(printf '%s' "$1" | sed 's|/*$||')
	case "$_s" in
		\[*)
			HP_HOST=${_s#\[}; HP_HOST=${HP_HOST%%\]*}
			HP_PORT=${_s##*\]:}
			[ "$HP_PORT" = "$_s" ] && return 1 ;;
		*)
			case "$_s" in *:*) : ;; *) return 1 ;; esac
			HP_PORT=${_s##*:}; HP_HOST=${_s%:*} ;;
	esac
	is_host "$HP_HOST" && is_port "$HP_PORT"
}

# apply_query <query> — ключи ссылки (?type=…&security=…) в поля P_*. Один набор у vless и
# trojan (у них одинаковые transport/tls-ключи) — как applyXrayQuery в панели.
apply_query() {
	_oifs=$IFS; IFS='&'
	for _kv in $1; do
		[ -n "$_kv" ] || continue
		case "$_kv" in *=*) : ;; *) continue ;; esac
		_k=${_kv%%=*}; _v=$(san "$(ud "${_kv#*=}")")
		case "$_k" in
			type)        P_TYPE=$_v ;;
			security)    P_SEC=$_v ;;
			encryption)  P_ENC=$_v ;;
			flow)        P_FLOW=$_v ;;
			sni|serverName) P_SNI=$_v ;;
			fp)          P_FP=$_v ;;
			pbk)         P_PBK=$_v ;;
			sid)         P_SID=$_v ;;
			spx)         P_SPX=$_v ;;
			path)        P_PATH=$_v ;;
			host)        P_HHDR=$_v ;;
			serviceName) P_SVC=$_v ;;
			alpn)        P_ALPN=$_v ;;
			mode)        P_MODE=$_v ;;
		esac
	done
	IFS=$_oifs
}

# jflat <json> <ключ> — значение ключа ПЛОСКОГО JSON (формат vmess://base64 от v2rayN).
# Строку и число разбираем отдельно: порт/aid приезжают и как "443", и как 443. jsonfilter
# тут не зовём намеренно — ссылочные подписки должны работать и без libubox.
jflat() {
	_j="$1"; _k="$2"
	_r=$(printf '%s' "$_j" | sed -n "s/.*\"$_k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)
	[ -n "$_r" ] || _r=$(printf '%s' "$_j" | sed -n "s/.*\"$_k\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1)
	printf '%s' "$_r"
}

# parse_link <ссылка> — ссылка любого из 4 xray-протоколов → P_*. 0 = разобрали.
parse_link() {
	p_reset
	_l=$(printf '%s' "$1" | tr -d '\r')
	case "$_l" in
		vless://*)  P_PROTO=vless;  _rest=${_l#vless://} ;;
		trojan://*) P_PROTO=trojan; _rest=${_l#trojan://} ;;
		vmess://*)  parse_vmess "${_l#vmess://}"; return $? ;;
		ss://*)     parse_ss "${_l#ss://}"; return $? ;;
		*) return 1 ;;
	esac
	case "$_rest" in *#*) P_REMARK=$(san_txt "$(ud "${_rest#*#}")"); _rest=${_rest%%#*} ;; esac
	_q=""
	case "$_rest" in *\?*) _q=${_rest#*\?}; _rest=${_rest%%\?*} ;; esac
	case "$_rest" in *@*) : ;; *) return 1 ;; esac
	_ui=${_rest%%@*}; _hp=${_rest#*@}
	hp_split "$_hp" || return 1
	P_HOST=$HP_HOST; P_PORT=$HP_PORT
	apply_query "$_q"
	if [ "$P_PROTO" = trojan ]; then
		P_PASS=$(san "$(ud "$_ui")"); [ -n "$P_PASS" ] || return 1
		[ -n "$P_SEC" ] || P_SEC=tls
		[ -n "$P_TYPE" ] || P_TYPE=tcp
		[ -n "$P_SNI" ] || P_SNI=$P_HOST
	else
		P_UUID=$(san "$(ud "$_ui")"); [ -n "$P_UUID" ] || return 1
	fi
	return 0
}

# parse_vmess <base64-JSON> — формат v2rayN: net→type, tls-строка→security, grpc-serviceName
# лежит в поле path, ws/h2-Host — в поле host (зеркало parseVmess в панели).
parse_vmess() {
	p_reset; P_PROTO=vmess
	_j=$(printf '%s' "$1" | b64_dec)
	[ -n "$_j" ] || return 1
	P_HOST=$(san "$(jflat "$_j" add)"); P_PORT=$(jflat "$_j" port | tr -cd '0-9')
	P_UUID=$(san "$(jflat "$_j" id)")
	is_host "$P_HOST" && is_port "$P_PORT" && [ -n "$P_UUID" ] || return 1
	P_REMARK=$(san_txt "$(jflat "$_j" ps)")
	P_AID=$(jflat "$_j" aid | tr -cd '0-9'); [ -n "$P_AID" ] || P_AID=0
	P_SCY=$(san "$(jflat "$_j" scy)"); [ -n "$P_SCY" ] || P_SCY=auto
	P_TYPE=$(san "$(jflat "$_j" net)"); [ -n "$P_TYPE" ] || P_TYPE=tcp
	_tls=$(san "$(jflat "$_j" tls)")
	case "$_tls" in reality) P_SEC=reality ;; ?*) P_SEC=tls ;; *) P_SEC=none ;; esac
	P_SNI=$(san "$(jflat "$_j" sni)"); P_FP=$(san "$(jflat "$_j" fp)"); P_ALPN=$(san "$(jflat "$_j" alpn)")
	_hh=$(san "$(jflat "$_j" host)"); _pt=$(san "$(jflat "$_j" path)")
	if [ "$P_TYPE" = grpc ]; then P_SVC=$_pt; else P_PATH=$_pt; P_HHDR=$_hh; fi
	[ "$P_SEC" != none ] && [ -z "$P_SNI" ] && P_SNI=$_hh
	return 0
}

# parse_ss <тело ss://> — SIP002 (base64(method:pass)@host:port) и легаси
# (base64(method:pass@host:port) целиком). Плагины (?plugin=…) не поддерживаем — как в панели.
parse_ss() {
	p_reset; P_PROTO=shadowsocks; P_TYPE=tcp; P_SEC=none
	_s="$1"
	case "$_s" in *#*) P_REMARK=$(san_txt "$(ud "${_s#*#}")"); _s=${_s%%#*} ;; esac
	case "$_s" in *\?*) _s=${_s%%\?*} ;; esac
	if [ "${_s#*@}" != "$_s" ]; then
		_ui=${_s%@*}; _hp=${_s##*@}
		case "$_ui" in *:*) _ui=$(ud "$_ui") ;; *) _ui=$(printf '%s' "$_ui" | b64_dec) ;; esac
	else
		_d=$(printf '%s' "$_s" | b64_dec)
		[ -n "$_d" ] || return 1
		_ui=${_d%@*}; _hp=${_d##*@}
	fi
	case "$_ui" in *:*) : ;; *) return 1 ;; esac
	P_METHOD=$(san "${_ui%%:*}"); P_PASS=$(san "${_ui#*:}")
	hp_split "$_hp" || return 1
	P_HOST=$HP_HOST; P_PORT=$HP_PORT
	[ -n "$P_METHOD" ] || return 1
	return 0
}

# --- hy2:// (hysteria2) -----------------------------------------------------
# Разбор hy2-ссылки живёт ЗДЕСЬ, рядом с xray-ссылками, а не в transport-hy2.sh: роутерная
# копия разбора ссылок обязана быть ОДНА. Иначе повторяется история panel.js ↔ be7000.ps1,
# где правку «кавычим sni, иначе %0A вписывает свои ключи в YAML» пришлось ставить дважды,
# а IPv6-эндпоинт одна копия умела, вторая — нет.
#
# parse_hy2 <тело ссылки без схемы> — P_PROTO=hy2 + P_PASS(auth)/P_HOST/P_PORT/P_SNI/
# P_INSECURE/P_OBFS/P_OBFSPASS. Зеркало parseHy2() из panel.js: '@' внутри auth разрешён
# (делим по ПОСЛЕДНЕМУ), sni по умолчанию = host.
parse_hy2() {
	p_reset; P_PROTO=hy2; P_SEC=tls; P_TYPE=udp; P_INSECURE=false
	_s=$(printf '%s' "$1" | tr -d '\r')
	case "$_s" in *#*) P_REMARK=$(san_txt "$(ud "${_s#*#}")"); _s=${_s%%#*} ;; esac
	_q=""
	case "$_s" in *\?*) _q=${_s#*\?}; _s=${_s%%\?*} ;; esac
	case "$_s" in *@*) : ;; *) return 1 ;; esac
	_ui=${_s%@*}; _hp=${_s##*@}
	hp_split "$_hp" || return 1
	P_HOST=$HP_HOST; P_PORT=$HP_PORT
	P_PASS=$(san "$(ud "$_ui")")
	[ -n "$P_PASS" ] || return 1
	_oifs=$IFS; IFS='&'
	for _kv in $_q; do
		[ -n "$_kv" ] || continue
		case "$_kv" in *=*) : ;; *) continue ;; esac
		_k=${_kv%%=*}; _v=$(san "$(ud "${_kv#*=}")")
		case "$_k" in
			sni)                     P_SNI=$_v ;;
			insecure)                case "$_v" in 1|true) P_INSECURE=true ;; esac ;;
			obfs)                    P_OBFS=$_v ;;
			obfs-password|obfsParam) P_OBFSPASS=$_v ;;
		esac
	done
	IFS=$_oifs
	[ -n "$P_SNI" ] || P_SNI=$P_HOST
	return 0
}

# hq <значение> — значение hysteria.yaml ВСЕГДА в кавычках (зеркало hy2Quote в панели).
# Экранирование уже сделал san() на разборе (кавычка, бэкслеш, CR/TAB/перевод строки), здесь
# остаётся сама пара кавычек — и она обязательна: без неё YAML читает `sni: 1.2` числом, а
# пароль из одних цифр — тоже числом, и hysteria падает на типе поля.
hq() { printf '"%s"' "$1"; }

# emit_hy2 — hysteria-YAML из P_* (зеркало hy2Yaml из panel.js). Порядок и набор ключей
# держим тот же: конфиги из подписки и из панели должны быть неразличимы.
emit_hy2() {
	_hostp=$P_HOST
	case "$P_HOST" in *:*) _hostp="[$P_HOST]" ;; esac
	printf 'server: %s:%s\n' "$_hostp" "$P_PORT"
	printf 'auth: %s\n' "$(hq "$P_PASS")"
	printf 'tls:\n'
	printf '  sni: %s\n' "$(hq "$P_SNI")"
	printf '  insecure: %s\n' "${P_INSECURE:-false}"
	if [ "$P_OBFS" = salamander ] && [ -n "$P_OBFSPASS" ]; then
		printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$(hq "$P_OBFSPASS")"
	fi
	printf 'socks5:\n  listen: 127.0.0.1:10808\n'
}

# --- AmneziaWG and WireGuard: a link → a native .conf ------------------------
# The third family of links. A 3x-ui subscription (≥ 3.7) carries AmneziaWG as `vpn://` + base64url of a native .conf and
# plain WireGuard as `wireguard://key@host:port?…`; Amnezia's own `vpn://` is a JSON container, usually qCompress'ed (four
# bytes of length + a zlib stream). The panel decodes all of them in the browser (decodeAmneziaVpn, wgLinkConf) — this is
# the router's copy, and the two are held together by the differential stand dev/awg-link-parity-test.js, not by a comment.
# The config TEXT lives in a FILE ($P_CONF), not in a variable: it is multi-line and holds a private key.
# MEASURED on BE7000 (busybox 1.25.1, 13.10.2026):
#   * gunzip inflates a zlib stream put behind a gzip header byte for byte and THEN returns 1 «corrupted data» (the trailer
#     is adler32, not crc32 + size) ⇒ the verdict is the CONTENT, never the code;
#   * jsonfilter has no `..`; `[n]` and `.*` work. Several matches come out one after another, and a value with line breaks
#     in it cannot be told from two values ⇒ containers are asked BY INDEX, one value per call.
VPN_MAX=262144   # bytes of an inflated container we agree to hold in RAM: a zlib bomb in a subscription stops here
VPN_CONT=8       # containers of one `vpn://` we look through

# zlib_at <file> <offset> — «a zlib stream starts here»: deflate (low nibble 8) AND the header checksum (CMF·256+FLG is a
# multiple of 31). The first byte alone is not enough: plain text has an `x` there as often as not (panel: looksZlib).
# The two bytes are read through base64 (three characters and `=`), their number put together from the characters' places
# in the alphabet: no `od` on this busybox, and `hexdump` is not something every build has.
ZL_ABC=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
zlib_at() {
	_zb=$(tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | head -c 2 | base64 2>/dev/null | tr -d '\r\n')
	case "$_zb" in ??=*) return 1 ;; ???=) : ;; *) return 1 ;; esac     # `??==` is ONE byte: the file is shorter than a header
	_zr=${_zb#?}; _zq=${_zr#?}
	_z0=${ZL_ABC%%"${_zb%???}"*}; _z1=${ZL_ABC%%"${_zr%??}"*}; _z2=${ZL_ABC%%"${_zq%?}"*}
	_zv=$(( (${#_z0} << 10) | (${#_z1} << 4) | (${#_z2} >> 2) ))
	[ $(( _zv % 31 )) -eq 0 ] && [ $(( (_zv >> 8) & 15 )) -eq 8 ]
}

# zlib_inflate <file> <offset of the zlib header> <out> — the stream into <out>, up to VPN_MAX. Judged by the file.
zlib_inflate() {
	{ printf '\037\213\010\000\000\000\000\000\000\003'; tail -c +"$(( $2 + 3 ))" "$1"; } 2>/dev/null \
		| gunzip -c 2>/dev/null | head -c "$((VPN_MAX+1))" > "$3" 2>/dev/null
	if [ "$(wc -c < "$3")" -gt "$VPN_MAX" ]; then N_PARTIAL=1; return 1; fi
	[ -s "$3" ]
}

# vpn_val <json file> <path> <out> — ONE value by a path into <out>; 0 = something is there. The old <out> goes first: no
# match writes nothing, and the previous value would answer for this one.
vpn_val() { rm -f "$3" 2>/dev/null; lbl_commit_out "$3" jf "$1" "$2" 2>/dev/null && [ -s "$3" ]; }

# vpn_conf_in <value file> — the value is a config, or JSON text with one in `config` (Amnezia's last_config is a JSON
# document kept as a string). 0 = the config is in $_vd.conf; VPN_INNER says the value was JSON (its fields are read later).
vpn_conf_in() {
	_vf="$1"; VPN_INNER=
	case "$(head -c 64 "$_vf" 2>/dev/null | tr -d ' \t\r\n' | cut -c1)" in
		'{') vpn_val "$_vf" '@.config' "$_vd.inner" && { _vf="$_vd.inner"; VPN_INNER=1; } ;;
	esac
	grep -qF '[Interface]' "$_vf" 2>/dev/null && grep -qF '[Peer]' "$_vf" 2>/dev/null || return 1
	cp "$_vf" "$_vd.conf" 2>/dev/null
}

# vpn_meta <key> — a field of the container itself: the root first, then the chosen container's block, then the JSON kept
# inside it (the app keeps `mtu` only there). First line only: these are a name, two addresses and a number.
vpn_meta() {
	_vm=$(jf "$_vj" "@.$1" | head -1)
	if [ -z "$_vm" ] && [ "$_vfound" != root ]; then _vm=$(jf "$_vj" "@.containers[$_vfound].*.$1" | head -1); fi
	if [ -z "$_vm" ] && [ -n "$VPN_INNER" ]; then _vm=$(jf "$_vd.val" "@.$1" | head -1); fi
	printf '%s' "$_vm"
}
is_dns_ip() { case "$1" in ''|*[!0-9A-Fa-f:.]*) return 1 ;; esac; return 0; }

# vpn_from <decoded bytes> — a config out of them: a JSON container (Amnezia) or the config itself (3x-ui, bots).
# 0 = the finished text is in $_vd.fin, the container's name in VPN_NAME.
vpn_from() {
	_vj="$1"; _vfound=; VPN_INNER=; _vmtu=; _vdns1=; _vdns2=
	rm -f "$_vd.conf" "$_vd.inner" "$_vd.val" 2>/dev/null
	if jf "$_vj" '@' >/dev/null 2>&1; then
		for _vp in '@.config' '@.last_config'; do
			if vpn_val "$_vj" "$_vp" "$_vd.val" && vpn_conf_in "$_vd.val"; then _vfound=root; break; fi
		done
		_vi=0
		while [ -z "$_vfound" ] && [ "$_vi" -lt "$VPN_CONT" ]; do
			for _vp in "@.containers[$_vi].*.last_config" "@.containers[$_vi].*.config" "@.containers[$_vi].last_config" "@.containers[$_vi].config"; do
				if vpn_val "$_vj" "$_vp" "$_vd.val" && vpn_conf_in "$_vd.val"; then _vfound=$_vi; break; fi
			done
			_vi=$((_vi + 1))
		done
		if [ -z "$_vfound" ] && [ "$_vi" -eq "$VPN_CONT" ] && vpn_val "$_vj" "@.containers[$_vi]" "$_vd.val"; then N_PARTIAL=1; fi
		[ -n "$_vfound" ] || return 1
		VPN_NAME=$(vpn_meta description)
		_vdns1=$(vpn_meta dns1); _vdns2=$(vpn_meta dns2); _vmtu=$(vpn_meta mtu)
	else
		# Sections at LINE STARTS: inside a container «[Interface]» sits in the middle of a JSON string.
		grep -q "^[ $TAB]*\[Interface\][ $TAB$SAN_CR]*\$" "$_vj" 2>/dev/null \
			&& grep -q "^[ $TAB]*\[Peer\][ $TAB$SAN_CR]*\$" "$_vj" 2>/dev/null || return 1
		cp "$_vj" "$_vd.conf" 2>/dev/null || return 1
	fi
	# CRLF → LF and a lone CR → LF: `awg setconf` takes a trailing CR INTO THE VALUE and rejects the whole config.
	sed "s/$SAN_CR\$//" "$_vd.conf" 2>/dev/null | tr '\r' '\n' > "$_vd.fin" 2>/dev/null || return 1
	# $PRIMARY_DNS / $SECONDARY_DNS — the app's templates, filled from dns1/dns2 as the app does. The value goes into a
	# sed replacement ⇒ only what an address is made of; anything else — the default.
	# The gate knows the braces too: with BOTH templates written `${…}` it saw neither, and the line stayed a template.
	if grep -qE '\$[{]?(PRIMARY|SECONDARY)_DNS' "$_vd.fin" 2>/dev/null; then
		is_dns_ip "$_vdns1" || _vdns1=1.1.1.1
		is_dns_ip "$_vdns2" || _vdns2=1.0.0.1
		lbl_commit_out "$_vd.fin" sed "s/\\\$[{]\\{0,1\\}PRIMARY_DNS[}]\\{0,1\\}/$_vdns1/g; s/\\\$[{]\\{0,1\\}SECONDARY_DNS[}]\\{0,1\\}/$_vdns2/g" "$_vd.fin" 2>/dev/null || return 1
	fi
	# NO RESOLVER NAMED: 3x-ui writes `DNS =` only when its inbound has one (by default it has none). Without the line the carrier
	# falls back to Amnezia's internal resolver, which a 3x-ui server does not run — a handshake, a green panel, nothing resolves
	# (the twin of a wireguard:// link without dns, review s.134). The two addresses the templates above default to.
	if ! grep -qi "^[ $TAB]*DNS[ $TAB]*=" "$_vd.fin" 2>/dev/null; then
		iface_add "$_vd.fin" "DNS = 1.1.1.1, 1.0.0.1" || return 1
	fi
	# MTU: the app keeps it as a FIELD of the container and sets it on the interface itself — a native .conf has no such
	# line, and the router reads only the .conf. An own line wins.
	_vmtu=$(printf '%s' "$_vmtu" | sed 's/\..*//' | tr -cd '0-9' | sed 's/^0*//')
	if [ -n "$_vmtu" ] && [ "${#_vmtu}" -le 4 ] && [ "$_vmtu" -ge 1280 ] && [ "$_vmtu" -le 1500 ] \
	   && ! grep -qi "^[ $TAB]*MTU[ $TAB]*=" "$_vd.fin" 2>/dev/null; then
		iface_add "$_vd.fin" "MTU = $_vmtu" || return 1
	fi
	[ -s "$_vd.fin" ]
}

# iface_add <file> <line> — one line into the [Interface] section, where the app puts what it keeps as container fields: after
# Address, else right under [Interface]; no [Interface] — nothing. The file is replaced whole or not at all. The panel's twin is
# amneziaIfaceAdd (the parity stand holds the two together).
iface_add() {
	lbl_commit_out "$1" awk -v l="$2" '
		{ L[NR] = $0 }
		END {
			pos = 0
			for (i = 1; i <= NR; i++) {
				if (L[i] ~ /^[ \t]*\[[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\]/) pos = i
				else if (pos > 0 && L[i] ~ /^[ \t]*[Aa][Dd][Dd][Rr][Ee][Ss][Ss][ \t]*=/) { pos = i; break }
				else if (pos > 0 && L[i] ~ /^[ \t]*\[/) break
			}
			for (i = 1; i <= NR; i++) { print L[i]; if (i == pos) print l }
		}' "$1" 2>/dev/null
}

# vpn_decode <body of vpn://> — 0: the config text is in $_vd.fin. Four forms (qCompress · bare zlib · plain JSON · the
# config itself), and the zlib magic does not tell them apart: the inflated text is tried first, the bytes as they are
# second — a link that is NOT compressed must not suffer because its first bytes happen to look like a zlib header.
vpn_decode() {
	vpn_raw "$1" || return 1
	if [ -s "$_vd.un" ]; then vpn_from "$_vd.un" && return 0; fi
	vpn_from "$_vd.bin"
}
# vpn_raw <body of vpn://> — the link's bytes in $_vd.bin and, when they hold a zlib stream (qCompress or bare), that stream inflated
# in $_vd.un. One unpacking for the config decoder above and for Amnezia Premium's keys and answers (cmd_vpn_json).
vpn_raw() {
	VPN_NAME=; _vd="$TMPD/vpn"
	rm -f "$_vd".* 2>/dev/null
	printf '%s' "$1" | lbl_commit_out "$_vd.bin" b64_dec 2>/dev/null
	[ -s "$_vd.bin" ] || return 1
	_voff=
	if zlib_at "$_vd.bin" 4; then _voff=4; elif zlib_at "$_vd.bin" 0; then _voff=0; fi
	[ -z "$_voff" ] || zlib_inflate "$_vd.bin" "$_voff" "$_vd.un" || rm -f "$_vd.un" 2>/dev/null
	return 0
}
# vpn_body <file> — the body of the `vpn://` link a file holds (its first line; the scheme off). Secrets travel in FILES, not argv.
vpn_body() { head -n 1 "$1" 2>/dev/null | tr -d " \r\t" | sed 's#^vpn://##'; }

# awg_take <file> — accept the config a link gave: both sections at line starts, both keys, an endpoint. Fills
# P_HOST/P_PORT and puts the text into $P_CONF (blank tail off, one newline at the end: `while read` loses a last line
# without it).
awg_take() {
	grep -q "^[ $TAB]*\[Interface\][ $TAB]*\$" "$1" 2>/dev/null && grep -q "^[ $TAB]*\[Peer\][ $TAB]*\$" "$1" 2>/dev/null || return 1
	grep -qE "^[ $TAB]*PrivateKey[ $TAB]*=[ $TAB]*[A-Za-z0-9+/]{43}=[ $TAB]*\$" "$1" || return 1
	grep -qE "^[ $TAB]*PublicKey[ $TAB]*=[ $TAB]*[A-Za-z0-9+/]{43}=[ $TAB]*\$" "$1" || return 1
	_ae=$(sed -n "s/^[ $TAB]*Endpoint[ $TAB]*=[ $TAB]*//p" "$1" | head -1 | tr -d " $TAB")
	hp_split "$_ae" || return 1
	P_HOST=$HP_HOST; P_PORT=$HP_PORT
	lbl_commit_out "$TMPD/awg.conf" awk '{ L[NR] = $0 } END { n = NR; while (n > 0 && L[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print L[i] }' "$1" 2>/dev/null || return 1
	[ -s "$TMPD/awg.conf" ] || return 1
	P_CONF="$TMPD/awg.conf"
}

# awg_comment <config> — the server's name from the config's own comments: the FIRST one that is neither a commented-out
# directive (`# MTU = 1420`) nor a licence header (longer than 40 characters). 3x-ui writes the remark exactly so. The
# length is counted in characters, not bytes (UTF-8 continuation bytes are dropped before counting).
awg_comment() {
	sed -n "s/^[ $TAB]*#[ $TAB]*\([^ $TAB].*\)\$/\1/p" "$1" 2>/dev/null | sed "s/[ $TAB]*\$//" | grep -v '=' \
		| while IFS= read -r _ac; do
			[ "$(printf '%s' "$_ac" | tr -d '\200-\277' | wc -c)" -le 40 ] || continue
			printf '%s' "$_ac"
			break
		done
}

# parse_vpn <body of vpn://> — AmneziaWG (or WireGuard) out of an Amnezia link, any of its four forms.
parse_vpn() {
	p_reset; P_PROTO=awg
	vpn_decode "$1" || return 1
	awg_take "$_vd.fin" || return 1
	P_REMARK=$(san_txt "$VPN_NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$P_REMARK" ] || P_REMARK=$(san_txt "$(awg_comment "$P_CONF")")
	return 0
}

# wg_key <text> — a WireGuard key (32 bytes of base64: 43 characters and `=`) on stdout; 1 = not a key. A space is put
# back as `+`: a key has no spaces, and a `+` left bare in a query is read as one.
wg_key() {
	_wkk=$(printf '%s' "$1" | tr ' ' '+' | tr -d '\r\n\t')
	case "$_wkk" in *=) : ;; *) [ "${#_wkk}" -eq 43 ] && _wkk="$_wkk=" ;; esac
	printf '%s' "$_wkk" | grep -qE '^[A-Za-z0-9+/]{43}=$' || return 1
	printf '%s' "$_wkk"
}

# wg_list <query value> <allowed characters> — a LIST field (addresses, DNS): `+` is a space here (Go's url.Values),
# items go by comma or space, each is checked, the rest are joined back with «, ». Nothing valid — nothing.
wg_list() {
	ud "$(printf '%s' "$1" | tr '+' ' ')" | tr ', \t' '\n\n\n' | while IFS= read -r _wl || [ -n "$_wl" ]; do
		[ -n "$_wl" ] || continue
		case "$_wl" in *[!$2]*) continue ;; esac
		printf '%s\n' "$_wl"
	done | awk 'NR > 1 { printf ", " } { printf "%s", $0 }'
}

# parse_wg <body of wireguard://> — plain WireGuard in one line, as 3x-ui writes it:
#   <private key>@host:port?publickey=…&address=…&dns=…&mtu=…&presharedkey=…&keepalive=…#remark
# The text it becomes is laid out like 3x-ui's own AmneziaWG config (the remark — a comment above [Peer]).
parse_wg() {
	p_reset; P_PROTO=awg
	_s=$(printf '%s' "$1" | tr -d '\r')
	_wrem=
	case "$_s" in *#*) _wrem=$(san_txt "$(ud "${_s#*#}")"); _s=${_s%%#*} ;; esac
	_q=""
	case "$_s" in *\?*) _q=${_s#*\?}; _s=${_s%%\?*} ;; esac
	case "$_s" in *@*) : ;; *) return 1 ;; esac
	_ui=${_s%@*}; _hp=${_s##*@}
	hp_split "$_hp" || return 1
	_wep="$HP_HOST:$HP_PORT"
	case "$HP_HOST" in *:*) _wep="[$HP_HOST]:$HP_PORT" ;; esac
	_wk=$(wg_key "$(ud "$_ui")") || return 1
	_wpub=; _wpsk=; _waddr=; _wdns=; _wmtu=; _wka=; _wbad=
	_oifs=$IFS; IFS='&'
	for _kv in $_q; do
		[ -n "$_kv" ] || continue
		case "$_kv" in *=*) : ;; *) continue ;; esac
		_k=${_kv%%=*}; _v=${_kv#*=}
		case "$_k" in
			publickey)    _wpub=$(wg_key "$(ud "$_v")") || _wbad=1 ;;
			presharedkey) _wpsk=$(wg_key "$(ud "$_v")") || _wbad=1 ;;
			address)      _waddr=$(wg_list "$_v" '0-9A-Fa-f:./') ;;
			dns)          _wdns=$(wg_list "$_v" '0-9A-Za-z:.-') ;;
			mtu)          _wmtu=$(ud "$_v" | tr -cd '0-9' | sed 's/^0*//') ;;
			keepalive)    _wka=$(ud "$_v" | tr -cd '0-9' | sed 's/^0*//') ;;
		esac
	done
	IFS=$_oifs
	# A key that is there but is not a key — the link is broken: a config without its preshared key would come up «fine»
	# and never shake hands.
	[ -z "$_wbad" ] && [ -n "$_wpub" ] && [ -n "$_waddr" ] || return 1
	lbl_commit_out "$TMPD/wg.conf" wg_emit 2>/dev/null || return 1
	awg_take "$TMPD/wg.conf" || return 1
	P_REMARK=$_wrem
	return 0
}
# wg_emit — the config text of the link parse_wg has just read (its `_w*` fields), on stdout.
wg_emit() {
	printf '[Interface]\nPrivateKey = %s\nAddress = %s\n' "$_wk" "$_waddr"
	# A LINK THAT NAMES NO RESOLVER GETS ONE (3x-ui writes `dns` only when the inbound has it set — by default it has not). With
	# no `DNS =` line the carrier falls back to Amnezia's internal resolver (transport-awg.sh), which a plain WireGuard server does
	# not run: such a server chosen as the main one shook hands under a green panel and resolved nothing (review s.133). The
	# two addresses are the ones an Amnezia container's templates default to (vpn_from); the panel's wgLinkConf writes the same.
	printf 'DNS = %s\n' "${_wdns:-1.1.1.1, 1.0.0.1}"
	if [ -n "$_wmtu" ] && [ "${#_wmtu}" -le 4 ] && [ "$_wmtu" -ge 1280 ] && [ "$_wmtu" -le 1500 ]; then printf 'MTU = %s\n' "$_wmtu"; fi
	printf '\n'
	[ -z "$_wrem" ] || printf '# %s\n' "$_wrem"
	printf '[Peer]\nPublicKey = %s\n' "$_wpub"
	[ -z "$_wpsk" ] || printf 'PresharedKey = %s\n' "$_wpsk"
	printf 'AllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s\n' "$_wep"
	if [ -n "$_wka" ] && [ "${#_wka}" -le 5 ] && [ "$_wka" -le 65535 ]; then printf 'PersistentKeepalive = %s\n' "$_wka"; fi
	return 0
}

# parse_any <ссылка> — ЛЮБАЯ поддерживаемая ссылка → P_*. Отдельно от parse_link намеренно:
# цикл подписки (parse_links → put_server) умеет складывать только xray-конфиги, и hy2-ссылка,
# попав в него, легла бы YAML'ом в xray-configs/*.json.
parse_any() {
	_pl=$(printf '%s' "$1" | tr -d '\r')
	case "$_pl" in
		hy2://*)       parse_hy2 "${_pl#hy2://}" ;;
		hysteria2://*) parse_hy2 "${_pl#hysteria2://}" ;;
		vpn://*)       parse_vpn "${_pl#vpn://}" ;;
		wireguard://*) parse_wg "${_pl#wireguard://}" ;;
		*)             parse_link "$_pl" ;;
	esac
}

# --- сборка xray-конфига (зеркало xrayJson из panel.js) ---------------------
# Формат держим «ключ: значение в ОДНОЙ строке» и 2 пробела отступа — cgi-bin/list и
# гибрид-редактор панели читают поля sed'ом построчно (JSON на busybox никто не парсит).
# "access": "none" — и это НЕ экономия на диагностике: access-лог xray пишет КАЖДОЕ соединение,
# лежит в /tmp (то есть в ОЗУ) и не ротируется НИКЕМ. Замер на роутере тестера 29.08.2026 —
# 5.5 МБ за 9 ч, ~15 МБ/сут; 800-МБ BE7000 это терпит, 176-МБ BE3600 уносит в ребут. Разбираем
# мы error-лог (он остался), «кто куда ходил» показывает devwatch.sh. Пустая строка тут была бы
# ХУЖЕ пути: у xray это stdout, а stdout демона мы уводим в тот же /tmp/xray.log.
emit_cfg() {
	printf '{\n  "log": {\n    "access": "none",\n    "error": "/tmp/xray.log",\n    "loglevel": "warning"\n  },\n'
	printf '  "inbounds": [\n    {\n      "tag": "socks-in",\n      "listen": "127.0.0.1",\n      "port": 10808,\n      "protocol": "socks",\n      "settings": { "udp": true }\n    }\n  ],\n'
	printf '  "outbounds": [\n    {\n      "tag": "proxy",\n      "protocol": "%s",\n' "$P_PROTO"
	# --- settings по протоколу: vless/vmess держат креды в vnext.users, trojan/ss — в servers
	printf '      "settings": {\n'
	case "$P_PROTO" in
		vmess)
			printf '        "vnext": [\n          {\n            "address": "%s",\n            "port": %s,\n            "users": [\n              { "id": "%s", "alterId": %s, "security": "%s" }\n            ]\n          }\n        ]\n' \
				"$P_HOST" "$P_PORT" "$P_UUID" "${P_AID:-0}" "${P_SCY:-auto}" ;;
		trojan)
			printf '        "servers": [\n          {\n            "address": "%s",\n            "port": %s,\n            "password": "%s"%s\n          }\n        ]\n' \
				"$P_HOST" "$P_PORT" "$P_PASS" "$([ -n "$P_FLOW" ] && printf ',\n            "flow": "%s"' "$P_FLOW")" ;;
		shadowsocks)
			printf '        "servers": [\n          {\n            "address": "%s",\n            "port": %s,\n            "method": "%s",\n            "password": "%s"\n          }\n        ]\n' \
				"$P_HOST" "$P_PORT" "${P_METHOD:-aes-128-gcm}" "$P_PASS" ;;
		*)
			printf '        "vnext": [\n          {\n            "address": "%s",\n            "port": %s,\n            "users": [\n              { "id": "%s", "encryption": "%s"%s }\n            ]\n          }\n        ]\n' \
				"$P_HOST" "$P_PORT" "$P_UUID" "${P_ENC:-none}" "$([ -n "$P_FLOW" ] && printf ', "flow": "%s"' "$P_FLOW")" ;;
	esac
	printf '      },\n'
	# --- streamSettings: транспорт + защита. network нормализуем (splithttp→xhttp, http→h2)
	_net=${P_TYPE:-tcp}; _sec=${P_SEC:-none}
	case "$_net" in splithttp) _net=xhttp ;; http) _net=h2 ;; esac
	case "$_sec" in xtls) _sec=tls ;; esac
	printf '      "streamSettings": {\n        "network": "%s",\n        "security": "%s"' "$_net" "$_sec"
	if [ "$_sec" = reality ]; then
		printf ',\n        "realitySettings": {\n          "serverName": "%s",\n          "fingerprint": "%s",\n          "publicKey": "%s",\n          "shortId": "%s",\n          "spiderX": "%s"\n        }' \
			"$P_SNI" "${P_FP:-chrome}" "$P_PBK" "$P_SID" "$P_SPX"
	elif [ "$_sec" = tls ]; then
		printf ',\n        "tlsSettings": {\n          "serverName": "%s",\n          "fingerprint": "%s"' "$P_SNI" "${P_FP:-chrome}"
		if [ -n "$P_ALPN" ]; then
			printf ',\n          "alpn": ['
			_first=1; _oifs=$IFS; IFS=','
			for _a in $P_ALPN; do [ -n "$_a" ] || continue; [ $_first -eq 1 ] || printf ', '; printf '"%s"' "$_a"; _first=0; done
			IFS=$_oifs; printf ']'
		fi
		printf '\n        }'
	fi
	case "$_net" in
		ws)
			printf ',\n        "wsSettings": {\n          "path": "%s"' "${P_PATH:-/}"
			[ -n "$P_HHDR" ] && printf ',\n          "headers": { "Host": "%s" }' "$P_HHDR"
			printf '\n        }' ;;
		grpc)
			printf ',\n        "grpcSettings": {\n          "serviceName": "%s"\n        }' "$P_SVC" ;;
		xhttp)
			printf ',\n        "xhttpSettings": {\n          "path": "%s",\n          "mode": "%s"' "${P_PATH:-/}" "${P_MODE:-auto}"
			[ -n "$P_HHDR" ] && printf ',\n          "host": "%s"' "$P_HHDR"
			printf '\n        }' ;;
		httpupgrade)
			printf ',\n        "httpupgradeSettings": {\n          "path": "%s"' "${P_PATH:-/}"
			[ -n "$P_HHDR" ] && printf ',\n          "host": "%s"' "$P_HHDR"
			printf '\n        }' ;;
		h2)
			printf ',\n        "httpSettings": {\n          "path": "%s"' "${P_PATH:-/}"
			if [ -n "$P_HHDR" ]; then
				printf ',\n          "host": ['
				_first=1; _oifs=$IFS; IFS=','
				for _a in $P_HHDR; do [ -n "$_a" ] || continue; [ $_first -eq 1 ] || printf ', '; printf '"%s"' "$_a"; _first=0; done
				IFS=$_oifs; printf ']'
			fi
			printf '\n        }' ;;
	esac
	printf '\n      }\n    }\n  ]\n}\n'
}

# --- два семейства конфигов -------------------------------------------------
# Подписка несёт РАЗНЫЕ протоколы: vless/vmess/trojan/ss ложатся xray-JSON'ом, hysteria2 —
# YAML'ом для своего демона. Всё остальное — имена файлов, липкий выбор, чистка устаревших,
# защита активного — у них ОБЩЕЕ. Поэтому различия сведены в ОДНУ таблицу, а не в вилки по
# коду: иначе третий протокол снова расползётся по десятку мест (класс «вилка забыла альт»).
FAM_DIR=; FAM_EXT=; FAM_ACT=; FAM_LIVE=; FAM_TSH=; FAM_TNAME=
# Every per-family pass (pruning, the active config, counting, removal) walks THIS list: a family named in one loop and
# forgotten in another is the «fork forgot the alt» class.
FAMS="xray hy2 awg"
fam_set() {
	case "$1" in
		hy2)
			FAM_DIR="$HY2DIR"; FAM_EXT=yaml; FAM_ACT="$HY2_ACTIVE_F"
			FAM_LIVE="$ENODIA_STATE/hysteria.yaml"; FAM_TSH=transport-hy2.sh; FAM_TNAME=hy2 ;;
		awg)
			# AmneziaWG (plain WireGuard too): the working copy is THREE files (awg.conf, amnezia_for_awg.conf and the derived
			# awg0.conf) and only switch-vpn.sh lays them out ⇒ FAM_LIVE here is what the config is COMPARED with, never a
			# target of `cp` (refresh_awg).
			FAM_DIR="$AWGDIR";  FAM_EXT=conf; FAM_ACT="$AWG_ACTIVE_F"
			FAM_LIVE="$ENODIA_STATE/awg.conf";      FAM_TSH=switch-vpn.sh; FAM_TNAME=awg ;;
		*)
			FAM_DIR="$CFGDIR";  FAM_EXT=json; FAM_ACT="$ACTIVE_F"
			FAM_LIVE="$ENODIA_STATE/xray.json";     FAM_TSH=xray-transport.sh; FAM_TNAME=xray ;;
	esac
}
# name_elsewhere <name> — a file of this name lies in ANOTHER family's directory (FAM_* = the family being laid out).
name_elsewhere() {
	[ "$FAM_EXT" = json ] || [ ! -f "$CFGDIR/$1.json" ] || return 0
	[ "$FAM_EXT" = yaml ] || [ ! -f "$HY2DIR/$1.yaml" ] || return 0
	[ "$FAM_EXT" = conf ] || [ ! -f "$AWGDIR/$1.conf" ] || return 0
	return 1
}

# cfg_addr / cfg_port / cfg_cred <файл> — три поля, по которым решается «сервер тот же?».
# Отдельными функциями, потому что у xray это JSON, у hy2 — YAML, у AmneziaWG — .conf, а вся логика вокруг общая.
# conf_val <file> <key> — the first value of a WireGuard config's key, spaces and the CR out.
conf_val() { sed -n "s/^[ $TAB]*$2[ $TAB]*=[ $TAB]*//p" "$1" 2>/dev/null | head -1 | tr -d " $TAB\r"; }
cfg_addr() {
	case "$1" in
		*.yaml) sed -n 's/^server: *\(.*\):[0-9]\{1,5\}$/\1/p' "$1" 2>/dev/null | head -1 | tr -d '[]' ;;
		*.conf) conf_val "$1" Endpoint | sed 's/:[0-9]*$//' | tr -d '[]' ;;
		*)      xp_field "$1" address ;;
	esac
}
cfg_port() {
	case "$1" in
		*.yaml) sed -n 's/^server: .*:\([0-9]\{1,5\}\)$/\1/p' "$1" 2>/dev/null | head -1 ;;
		*.conf) conf_val "$1" Endpoint | sed -n 's/^.*:\([0-9]\{1,5\}\)$/\1/p' ;;
		*)      xp_field "$1" port ;;
	esac
}
cfg_cred() {
	case "$1" in
		*.yaml) sed -n 's/^auth: "\(.*\)"$/\1/p' "$1" 2>/dev/null | head -1 ;;
		*.conf) conf_val "$1" PrivateKey ;;
		*)      _cc=$(xp_field "$1" account.id); [ -n "$_cc" ] || _cc=$(xp_field "$1" account.password); san "$_cc" ;;
	esac
}

# cfg_sig <файл> — СУТЬ конфига (адрес/порт/креды/SNI/сеть) одной строкой. По ней решаем,
# менялся ли сервер: побайтовое сравнение врало бы (панель пишет JSON.stringify, мы — printf).
cfg_sig() {
	[ -f "$1" ] || return 1
	case "$1" in
		*.yaml)
			# У hysteria-YAML полей мало и все плоские — берём те же по смыслу: адрес+порт,
			# креды, sni/insecure и обфускацию. Отступ значим (`  sni:` — внутри tls:).
			grep -E '^(server:|auth:|  sni:|  insecure:|  type:|    password:)' "$1" 2>/dev/null \
				| tr -d ' \t' | sort | tr '\n' ';' ;;
		*.conf)
			# Every SETTING line in the file's own order, spaces out. Not the substance: comments (the remark lives there) and a
			# key with an EMPTY value — switch-vpn.sh cuts empty I1..I5 out of the working copy, and refresh_awg compares the
			# config with that copy: counted, a config that carries them would be «changed» forever. `^name=$` is exactly the
			# empty one: a line that ends with a key's own «=» has the separator before it.
			tr -d " $TAB\r" < "$1" 2>/dev/null | grep -vE '^(#|$)' | grep -vE '^[A-Za-z0-9]+=$' | tr '\n' ';' ;;
		*)
			_csg=$(xp_runtime "$1" 10808) || return 1
			printf '%s\n' "$_csg" | md5sum | cut -d' ' -f1 ;;
	esac
}

# Full identity is independent of the filename and display remark. Keep
# credentials out of the temporary index itself.
cfg_identity() {
	case "$1" in
		*.yaml|*.conf)
			_ci_host=$(cfg_addr "$1" | tr 'A-Z' 'a-z')
			_ci_port=$(cfg_port "$1")
			[ -n "$_ci_host" ] && [ -n "$_ci_port" ] || return 1
			_ci_text=$(printf '%s\n%s\n%s\n%s' "${1##*.}" "$_ci_host" "$_ci_port" "$(cfg_cred "$1")")
			if [ "${1##*.}" = conf ]; then _ci_text="$_ci_text$LBL_NL$(conf_val "$1" PublicKey)"; fi ;;
		*) _ci_text=$(xp_subscription_ids "$1"); [ -n "$_ci_text" ] || return 1 ;;
	esac
	printf '%s' "$_ci_text" | sha256sum | cut -d' ' -f1
}
identity_index() (
	for _ii_family in $FAMS; do
		fam_set "$_ii_family"
		for _ii_cfg in "$FAM_DIR"/sub-"$1"-*."$FAM_EXT"; do
			[ -f "$_ii_cfg" ] || continue
			_ii_name=${_ii_cfg##*/}; _ii_name=${_ii_name%.*}
			[ "$(sub_owner_tag "$_ii_name")" = "$1" ] || continue
			_ii_key=$(cfg_identity "$_ii_cfg") || continue
			printf '%s\t%s\t%s\n' "$_ii_key" "$FAM_TNAME" "$_ii_name"
		done
	done
)
stage_identities() {
	: > "$TMPD/old-names"
	[ ! -f "$NAMES" ] || cat "$NAMES" > "$TMPD/old-names"
	identity_index "$1" > "$TMPD/identities"
}
name_taken() {
	[ -e "$FAM_DIR/$1.$FAM_EXT" ] || name_elsewhere "$1" || grep -qxF "$1" "$TMPD/used"
}
name_for() {   # tag, remark, ordinal, full identity digest
	printf '%s\n' "$2" > "$TMPD/remark"
	_nm=$(awk -F "$TAB" -v id="$4" -v kind="$FAM_TNAME" '
		FILENAME==ARGV[1] {remark=$0; next}
		FILENAME==ARGV[2] {used[$1]=1; next}
		FILENAME==ARGV[3] {label[$1]=$2; next}
		$1==id && $2==kind && !used[$3] {
			if ((label[$3] "") == (remark "")) {pick=$3; exit}
			if (!first) first=$3
		}
		END {print (pick ? pick : first)}
	' "$TMPD/remark" "$TMPD/used" "$TMPD/old-names" "$TMPD/identities")
	if [ -z "$_nm" ]; then
		_rem=$(printf '%s' "$2" | sed 's/[^A-Za-z0-9._-]/-/g; s/^-*//; s/-*$//')
		_hp=$(printf '%s-%s' "$P_HOST" "$P_PORT" | sed 's/[^A-Za-z0-9]/-/g; s/^-*//; s/-*$//')
		if [ -n "$P_PROFILE" ]; then _hp="pool-$(printf '%.12s' "$4")"; fi
		case "$_rem" in
			'')        _rem="$_hp" ;;
			*[!0-9-]*) : ;;
			*)         _rem="$_hp-$_rem" ;;
		esac
		_nm=$(printf 'sub-%s-%s' "$1" "${_rem:-$3}" | cut -c1-48)
		if name_taken "$_nm"; then
			_base=$(printf '%s' "$_nm" | cut -c1-39)
			_h=$(printf '%.8s' "$4")
			_nm="$_base-$_h"
			_k=2
			while name_taken "$_nm"; do _nm="$_base-$_h-$_k"; _k=$((_k+1)); done
		fi
	fi
	echo "$_nm" >> "$TMPD/used"
	printf '%s' "$_nm"
}

# --- запись одного сервера --------------------------------------------------
# put_server <tag> <порядковый> — P_* уже заполнены. Пишет конфиг, копит имена и счётчики.
put_server() {
	_t="$1"; _i="$2"
	[ -n "$P_PROFILE" ] || { is_host "$P_HOST" && is_port "$P_PORT"; } || { N_BAD=$((N_BAD+1)); return 1; }
	# Семейство выбираем ДО name_for: тот ищет уже заведённый файл этого сервера, и искать его
	# надо в каталоге своего протокола (xray-configs/*.json против hy2-configs/*.yaml).
	fam_set "$P_PROTO"
	mkdir -p "$FAM_DIR" 2>/dev/null
	_raw=$(printf '%s' "$P_REMARK" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$_raw" ] || _raw="#$_i"
	# Расширение у ВРЕМЕННОГО файла обязательное: по нему cfg_sig/cfg_addr понимают, JSON перед
	# ними или YAML. Без него подпись новичка считалась json-веткой поверх YAML (пусто), не
	# совпадала никогда — и hy2-конфиги переписывались на флеш КАЖДЫЙ тик крона при нулевых
	# изменениях, а отчёт врал «изменено». Поймано песочницей local/subs-mixed-test.sh.
	case "$P_PROTO" in
		hy2) emit_hy2 > "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null ;;
		awg) cat "$P_CONF" > "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null ;;   # the link IS the config: awg_take has checked and trimmed it
		*)   if [ -n "$P_PROFILE" ]; then cat "$P_PROFILE"; else emit_cfg; fi > "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null ;;
	esac
	[ -s "$TMPD/cfg.new.$FAM_EXT" ] || { N_BAD=$((N_BAD+1)); return 1; }
	_new_id=$(cfg_identity "$TMPD/cfg.new.$FAM_EXT") || { N_BAD=$((N_BAD+1)); return 1; }
	_nm=$(name_for "$_t" "$_raw" "$_i" "$_new_id")
	_dst="$FAM_DIR/$_nm.$FAM_EXT"
	if [ ! -f "$_dst" ]; then
		cfg_put "$TMPD/cfg.new.$FAM_EXT" "$_dst" || return 1
		N_NEW=$((N_NEW+1))
	elif [ "$(cfg_sig "$TMPD/cfg.new.$FAM_EXT")" != "$(cfg_sig "$_dst")" ]; then
		cfg_put "$TMPD/cfg.new.$FAM_EXT" "$_dst" || return 1
		N_CHG=$((N_CHG+1))
		printf '%s\t%s\n' "$FAM_TNAME" "$_nm" >> "$TMPD/changed"
	else
		rm -f "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null
		N_SAME=$((N_SAME+1))
	fi
	keep_server
}

keep_server() {
	if ! { printf '%s\t%s\n' "$_nm" "$_raw" >> "$TMPD/names" && printf '%s\n' "$_nm" >> "$TMPD/keep"; }; then
		N_SPACE_STOP="не удалось сохранить имена серверов"
		return 1
	fi
	# Reserve the next atomic rewrite of the map alongside the staged config. Four bytes per character covers UTF-8.
	N_NAME_BYTES=$((N_NAME_BYTES+${#_nm}+4*${#_raw}+2))
}

sub_space() {
	_sfree=$(df -Pk "$ENODIA_STATE" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ { print $4 }')
	[ -n "$_sfree" ] && [ "$_sfree" -ge "$((MINFREE_KB+$1))" ]
}
sub_space_reason() {
	if [ -n "$_sfree" ]; then printf 'мало места на разделе настроек'; else printf 'не удалось проверить свободное место'; fi
}
# cfg_put <built config> <its place> — WHOLE OR NOT AT ALL (label-lib.sh), mode 600 from the first byte. It was `mv` from /tmp
# — a copy across file systems with nobody asking how it ended: on a full partition a stump took the config's place and the run
# counted it «изменено». A stump of an AmneziaWG config is a lost key, and of the active one — a tunnel that will not come up.
# The old config stays as it was; the run says so and counts the server as not laid out.
cfg_put() {
	_cpbytes=$(wc -c < "$1")
	if ! sub_space "$((4+(_cpbytes+N_NAME_BYTES+${#_nm}+4*${#_raw}+2+1023)/1024))"; then
		N_SPACE_STOP=$(sub_space_reason)
		rm -f "$1" 2>/dev/null
		return 1
	fi
	( umask 077; lbl_commit_out "$2" cat "$1" ) 2>/dev/null; _cpr=$?
	if [ "$_cpr" = 0 ] && [ "$FAM_EXT" = json ] && command -v xp_meta_stage >/dev/null 2>&1; then
		cfg_meta_stage "$1" >> "$TMPD/xray-meta" 2>/dev/null || N_META_BAD=1
	fi
	rm -f "$1" 2>/dev/null
	[ "$_cpr" = 0 ] && return 0
	say "  конфиг «$(basename "$2")» не записался (место на разделе?) — прежний оставлен"
	N_BAD=$((N_BAD+1))
	N_SPACE_STOP="не удалось записать конфиг"
	return 1
}
cfg_meta_stage() {
	# Link configs were just emitted from these values. Profile JSON and escaped display fields use the canonical reader.
	if [ -n "$P_PROFILE" ] || [ "$P_HOST" = null ]; then xp_meta_stage "$1"; return; fi
	_cms_flow=; _cms_sni=; _cms_fp=
	case "$P_PROTO" in vless|trojan) _cms_flow=$P_FLOW ;; esac
	case "$_sec" in tls|reality) _cms_sni=$P_SNI; _cms_fp=${P_FP:-chrome} ;; esac
	case "$_net$_sec$_cms_flow$_cms_sni$_cms_fp" in
		*[!A-Za-z0-9._:-]*) xp_meta_stage "$1" ;;
		*) xp_meta_stage "$1" "$P_PROTO" "$P_HOST" "$_cms_flow" "$_net" "$_sec" "$_cms_sni" "$_cms_fp" ;;
	esac
}

# --- разбор тела ------------------------------------------------------------
relay_read_progress() {
	[ -n "${SUB_RELAY_PROGRESS:-}" ] || return 0
	case "$N_READ" in 1|*0) ;;
		*) return 0 ;;
	esac
	printf '%s\n' "$N_READ" > "$SUB_RELAY_PROGRESS.new" && mv -f "$SUB_RELAY_PROGRESS.new" "$SUB_RELAY_PROGRESS"
}
# parse_links <файл> <tag> — тело как список ссылок (plaintext или base64 такого списка).
parse_links() {
	_f="$1"; _t="$2"; _i=0
	# `|| [ -n "$_line" ]` — тело подписки часто приходит БЕЗ хвостового перевода строки (у
	# base64-подписок это норма), а `read` в таком случае возвращает 1 и цикл бросает уже
	# прочитанную ПОСЛЕДНЮЮ строку. Замерено на busybox BE7000: 3 строки без \n → 2 итерации.
	while IFS= read -r _line || { [ "$SUB_FETCH_PARTIAL" = 0 ] && [ -n "$_line" ]; }; do
		case "$_line" in *://*) : ;; *) continue ;; esac
		_line=$(printf '%s' "$_line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		if parse_any "$_line"; then
			_i=$((_i+1)); N_READ=$_i; relay_read_progress; put_server "$_t" "$_i"
			[ -z "$N_SPACE_STOP" ] || break
		else
			N_SKIP=$((N_SKIP+1))
		fi
	done < "$_f"
	[ "$_i" -gt 0 ]
}

# One provider element is one complete Xray profile. A failed element
# never prevents the next element from being validated and stored.
parse_json() {
	_pj_file=$1; _pj_tag=$2; _pji=0; _n=0; _pj_geo=0
	[ -n "$JF" ] || { say '  подписка JSON требует jsonfilter'; return 1; }
	_pj_xray=$(profile_xray_bin)
	xp_profile_rows "$_pj_file" > "$TMPD/profiles" || return 1
	while IFS= read -r _pj_json; do
		_pji=$((_pji+1)); N_READ=$_pji; relay_read_progress
		printf '%s\n' "$_pj_json" > "$TMPD/el.json" || return 1
		if xp_prepare "$TMPD/el.json" "$TMPD/profile.json" "$_pj_xray"; then
			[ "$XP_GEO_REMOVED" != 1 ] || _pj_geo=1
			p_reset
			P_PROFILE="$TMPD/profile.json"
			P_PROTO=xray
			P_REMARK=$(jf "$TMPD/el.json" '@.remarks')
			[ -n "$P_REMARK" ] || P_REMARK=$(xp_field "$P_PROFILE" tag)
			_n=$((_n+1))
			put_server "$_pj_tag" "$_n"
			[ -z "$N_SPACE_STOP" ] || break
		else
			say "  профиль $_pji пропущен: $XP_REASON"
			N_BAD=$((N_BAD+1))
		fi
	done < "$TMPD/profiles"
	if [ "$_pj_geo" = 1 ]; then
		RUN_GEO=1
		say "  $(xp_geo_notice)"
	fi
	[ "$_n" -gt 0 ]
}

# --- уборка устаревших ------------------------------------------------------
# prune_stale <tag> — снять конфиги подписки, которых больше нет в свежем наборе.
# АКТИВНЫЙ не трогаем никогда (оборвать несущую по расписанию — хуже протухшего сервера);
# владельца файла определяем длиннейшим тегом (соседняя подписка с тегом-надмножеством).
prune_stale() {
	_t="$1"
	# Все семейства: подписка бывает смешанной, и «устаревшим» hy2-конфигом занимаемся так же,
	# как xray-овским. Активный НЕ трогаем ни в одном — рвать несущую по расписанию нельзя.
	for _psf in $FAMS; do
		fam_set "$_psf"
		_act=$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')
		# «ДОМ» РЕЗЕРВА (AmneziaWG, `.failover-home`) — the server the watchdog returns to from a reserve. While the router sits
		# on the reserve «active» is another name, and the home pruned left the watchdog a home that is gone (review s.133).
		_phome=""; [ "$_psf" != awg ] || _phome=$(cat "$ENODIA_STATE/.failover-home" 2>/dev/null | tr -d ' \r\n"\\')
		for _f in "$FAM_DIR"/sub-"$_t"-*."$FAM_EXT"; do
			[ -e "$_f" ] || continue
			_b=$(basename "$_f" ".$FAM_EXT")
			[ "$(sub_owner_tag "$_b")" = "$_t" ] || continue
			grep -qxF "$_b" "$TMPD/keep" 2>/dev/null && continue
			if [ -n "$_phome" ] && [ "$_b" = "$_phome" ] && [ "$_b" != "$_act" ]; then HOME_GONE="${HOME_GONE:+$HOME_GONE }$_b"; continue; fi
			if [ "$_b" = "$_act" ]; then
				# СПИСОК, а не одно имя: активные конфиги у семейств РАЗНЫЕ, и оба могут
				# исчезнуть в одном прогоне. Держали одно — второй оставался на диске, но
				# терял строку в .sub-names, то есть своё настоящее имя (панель показывала
				# «sub-tag-…»). Имена файлов пробелов не содержат — разделитель безопасен.
				ACT_GONE="${ACT_GONE:+$ACT_GONE }$_b"
				continue
			fi
			# AN EXIT STANDS ON IT — the same reason as the active one, and one more: the exit goes on by its working copy,
			# but after a restart or a reboot it would find no config and fall to its spare path with nothing said. An exit
			# that serves as a ROAD is covered by the same answer (a road is an exit). Asked only here, for a file about to
			# go: one fork of the registry per stale config, none on a quiet run.
			_hx=$(held_by "$FAM_TNAME" "$_b")
			if [ -n "$_hx" ]; then
				HELD_GONE="${HELD_GONE:+$HELD_GONE }$_b:$_hx"
				continue
			fi
			cfg_gone "$_f" "$_b"
			case "$?" in
				0) N_DEL=$((N_DEL+1)) ;;
				2)
					BUSY_GONE="$BUSY_GONE $_b"
					say "  сервер «$(disp_of "$_b")» оставлен: занят выходом/дорогой или выбран для подключения" ;;
				*) DEL_FAILED="$DEL_FAILED $_b" ;;
			esac
			[ "$SUBS_LOCK_MINE" = 1 ] || return 1
		done
	done
}
# held_by <transport> <config> [on] — the exits that name this config («3,5»; empty — none; `on` — switched-on only): the
# registry's own answer (slots.sh holders). Its output goes through a filter BY FORM: a copy older than the verb prints its
# usage line, and the digits picked out of that would «hold» every config. No slots.sh — nobody is held, as before the guard.
held_by() {
	[ -f "$ENODIA_DIR/slots.sh" ] || return 0
	sh "$ENODIA_DIR/slots.sh" holders "$1" "$2" ${3:+"$3"} 2>/dev/null </dev/null | grep -E '^[2-7](,[2-7])*$' | head -1
}
# Drop the state lock before entering the switch → road → registry → state
# order. Job admission still protects the import while the state lock is free.
prune_through_owner() (
	if [ -z "${ENODIA_SWITCH_HOLDER:-}" ] ||
	    [ "$(cat "$SWITCH_LOCK" 2>/dev/null)" != "$ENODIA_SWITCH_HOLDER" ]; then
		switch_hold "$SWITCH_LOCK" 0 0 || { echo 'идёт смена транспорта или сервера — повторите удаление'; exit 1; }
		trap 'rm -f "$SWITCH_LOCK"' EXIT
		trap 'exit 1' HUP INT TERM PIPE
	fi
	if [ -f "$ENODIA_DIR/road.sh" ]; then
		sh "$ENODIA_DIR/road.sh" prune-sub "$@"
	elif [ ! -s "$ENODIA_STATE/.cfg-via" ]; then
		sh "$ENODIA_DIR/slots.sh" prune-sub "$@"
	else
		return 1
	fi
)
cfg_gone() {
	_cg_digest=$(lbl_cfg_digest "$1") || return 1
	drop_lock
	_cg_out=$(prune_through_owner "$FAM_TNAME" "$2" "$_cg_digest" 2>&1 </dev/null); _cg_rc=$?
	take_lock || return 1
	if [ -n "$_cg_out" ] && [ "$_cg_rc" != 2 ]; then say "  $_cg_out" >&2; fi
	return "$_cg_rc"
}
# disp_of <file name> — the server as the person knows it: its real name from this run's lines, else from the map, else the
# file name. For the words of messages and events only — identity is the file name.
disp_of() {
	_dp=$(awk -F"$TAB" -v n="$1" '($1 "") == (n "") { print $2; exit }' "$TMPD/names" 2>/dev/null)
	[ -n "$_dp" ] || _dp=$(awk -F"$TAB" -v n="$1" '($1 "") == (n "") { print $2; exit }' "$NAMES" 2>/dev/null)
	printf '%s' "${_dp:-$1}"
}

# write_names <tag> — заменить блок этой подписки в .sub-names (имя-файла⇥настоящее имя).
# Чужие блоки снимает sub_names_keep_other (владелец = ДЛИННЕЙШИЙ тег), а не префикс: голый
# `^sub-<tag>-` уносил имена соседней подписки с тегом-надмножеством.
# Текст хранилища $2 после прогона подписки $1: чужие блоки, строки исчезнувшего активного, строки этого прогона ($3).
names_text() {
	if [ -n "$N_SPACE_STOP$N_PARTIAL" ]; then
		# Unprocessed servers are unknown, so retain their labels as well as their files.
		if [ -f "$2" ]; then
			awk -F "$TAB" 'FILENAME==ARGV[1] { new[$1]=1; next } !($1 in new)' "$3" "$2" || return 1
		fi
		cat "$3"
		return $?
	fi
	sub_names_keep_other "$1" "$2"
	# Активный конфиг, ИСЧЕЗНУВШИЙ из подписки, prune_stale намеренно оставляет на диске —
	# значит и строку имени надо оставить: иначе файл теряет идентичность (панель показывает
	# его именем файла), а вернувшийся сервер заведёт себе ВТОРОЙ файл вместо этого.
	# The same for a config left under an exit (HELD_GONE — «name:exits»).
	if [ -n "$ACT_GONE$HELD_GONE$HOME_GONE$BUSY_GONE$DEL_FAILED" ] && [ -f "$2" ]; then
		for _ag in $ACT_GONE $HELD_GONE $HOME_GONE $BUSY_GONE $DEL_FAILED; do grep "^${_ag%%:*}$TAB" "$2" 2>/dev/null | head -1; done
	fi
	if [ -s "$3" ]; then cat "$3"; fi
	return 0
}
# Целиком либо никак — label-lib.sh::lbl_commit_out: «записалось ли» говорит приёмник, а не код писателя (grep при полном
# разделе выходит с кодом 0, и обрубок карты идентичности заводил бы серверам вторые файлы).
write_names() {
	_t="$1"
	names_text "$_t" "$NAMES" "$TMPD/names" > "$TMPD/names.next" || return 1
	cmp -s "$TMPD/names.next" "$NAMES" && return 0
	if ! sub_space "$((4+($(wc -c < "$TMPD/names.next")+1023)/1024))"; then
		N_SPACE_STOP=$(sub_space_reason)
		return 1
	fi
	( umask 077; lbl_commit_out "$NAMES" cat "$TMPD/names.next" )
}

# --- активный сервер --------------------------------------------------------
# refresh_active — если у АКТИВНОГО конфига сменилась суть, поднять её в бой: xray.json —
# копия активного конфига, демон читает её на старте. Перезапускаем несущую ТОЛЬКО когда
# xray и есть активный транспорт (иначе просто обновили файл — применится при переключении).
refresh_active() {   # $1 = the subscription's tag
	_rat=$1
	# По разу на семейство: у каждого свои «активный конфиг», живой файл и плагин несущей.
	for _raf in $FAMS; do
		fam_set "$_raf"
		_act=$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')
		[ -n "$_act" ] || continue
		# AmneziaWG — its own way: the working copy is laid out by switch-vpn.sh alone, and judged by its STATE.
		if [ "$_raf" = awg ]; then refresh_awg "$_rat" "$_act"; continue; fi
		grep -qxF "$FAM_TNAME$TAB$_act" "$TMPD/changed" 2>/dev/null || continue
		cp "$FAM_DIR/$_act.$FAM_EXT" "$FAM_LIVE" 2>/dev/null && chmod 600 "$FAM_LIVE" 2>/dev/null
		if [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = "$FAM_TNAME" ]; then
			# Идёт смена транспорта — в это окно `.transport` уже/ещё указывает не туда, и наш
			# down+up поднял бы несущую ПОВЕРХ чужой (класс Б5-4: осиротевшие демоны на socks 10808).
			# Конфиг уже обновлён на диске, применится сам при следующем подъёме.
			if [ -e /tmp/enodia-switching.lock ]; then
				say "  активный сервер «$_act» изменился, но идёт смена транспорта — несущую не трогаю"
				continue
			fi
			# VPN ВЫКЛЮЧЕН ВРУЧНУЮ — несущей нет, и поднимать её обновление подписки не вправе (плагин при флаге и сам откажет,
			# daemon-lib.sh::carrier_run; здесь — чтобы не писать «несущая перезапущена» про то, чего не было).
			if [ -f "$ENODIA_STATE/.vpn-off" ]; then
				say "  активный сервер «$_act» $CHG — VPN выключен вручную, применится при включении"
				continue
			fi
			[ -f "$ENODIA_DIR/$FAM_TSH" ] || { say "  активный сервер «$_act» изменился, но $FAM_TSH не найден"; continue; }
			# UNDER THE SWITCHING LOCK, once no watchdog tick and no heal run drives the carrier (daemon-lib.sh::switch_hold): a
			# down+up beside the watchdog's ladder or a manual switch had two writers of the same live config and socks (review
			# s.136, M5). Not ours within the wait — the config is laid out already and comes up at the next raise.
			if ! switch_hold "$SWITCH_LOCK" "$CARRIER_HOLD_MAX"; then
				say "  активный сервер «$_act» $CHG, но роутер сейчас сам ведёт туннель — применится при следующем подъёме"
				continue
			fi
			say "  активный сервер «$_act» $CHG — перезапускаю несущую"
			sh "$ENODIA_DIR/$FAM_TSH" down >/dev/null 2>&1
			sh "$ENODIA_DIR/$FAM_TSH" up   >/dev/null 2>&1
			rm -f "$SWITCH_LOCK" 2>/dev/null
			ev "subs-active-changed" 3600 "Подписка обновила активный сервер" \
				"Сервер «$_act» $CHG$CHG_D. Конфиг обновлён, несущая перезапущена."
		else
			say "  активный конфиг «$_act» обновлён (применится при переключении на $FAM_TNAME)"
		fi
	done
}

# refresh_awg <tag> <active config> — the ACTIVE AmneziaWG config of THIS subscription against the working copy (FAM_* = awg).
# BY STATE, NOT BY THIS RUN'S NEWS. For Xray the news is enough: its working copy is one file, copied on the spot, and whoever
# raises the carrier next reads it. Here the copy is laid out by switch-vpn.sh alone, and a run that could not call it (a switch
# of transport in progress) would leave «the config is new, the tunnel runs the old one» for good — the next run sees no change.
# So every run asks the fact: does awg.conf carry the substance of configs/<active>.conf?
# THE SAME TEXT IS TRIED ONCE (AWG_TRIED): the new config that does not shake hands costs the tunnel half a minute before the
# previous copy is back (switch-vpn.sh), and without the mark every cron run would pay it again.
refresh_awg() {
	_rwa=$2
	[ "$(sub_owner_tag "$_rwa")" = "$1" ] || return 0
	_rwf="$AWGDIR/$_rwa.conf"
	# No working copy — AmneziaWG is not set up here (the config is only named): nothing to bring in line.
	[ -f "$_rwf" ] && [ -s "$FAM_LIVE" ] || return 0
	_rws=$(cfg_sig "$_rwf"); [ -n "$_rws" ] || return 0
	[ "$_rws" != "$(cfg_sig "$FAM_LIVE")" ] || return 0
	_rwd=$(disp_of "$_rwa")
	_rwm=$(printf '%s' "$_rws" | md5sum 2>/dev/null | cut -c1-32 | tr -cd 'a-f0-9')
	# AWG_LAGS — «the working copy stays behind the config» for the run's record (update_one): every exit below this line
	# that leaves it so sets it; the two that bring the copy in line, and «the active server is another one now», do not.
	if [ -n "$_rwm" ] && [ "$(cat "$AWG_TRIED" 2>/dev/null)" = "$_rwa$TAB$_rwm" ]; then
		if awg_direct; then
			say "  активный сервер «$_rwd»: новый конфиг из подписки уже пробовали — не применился; роутер в прямом режиме, мимо VPN"
			AWG_LAGS=2
		else
			say "  активный сервер «$_rwd»: новый конфиг из подписки уже пробовали — не применился, работает прежний"
			AWG_LAGS=1
		fi
		return 0
	fi
	[ -f "$ENODIA_DIR/switch-vpn.sh" ] || { say "  активный сервер «$_rwd» изменился, но switch-vpn.sh не найден"; return 0; }
	# UNDER THE SWITCHING LOCK, once no watchdog tick and no heal run drives the carrier (daemon-lib.sh::switch_hold) — the Xray
	# half's rule (review s.136, M5). A look at the lock FILE alone let this switch start beside a tick that had passed its own check
	# on its way to the ladder (review s.136 r2, L3). Not ours within the wait — most often the watchdog's failover, which begins
	# with safety_off: «работает прежний» would be the R4 lie here (review s.134, round 2). AWG_DEFER says so to the caller: a run
	# applies it next run, an Amnezia Premium job asks again once the switch is over (`settle`) — no run ever comes for a key
	# subscription, and «при следующем обновлении» was a promise nobody kept (review s.136 r2, H1).
	if ! switch_hold "$SWITCH_LOCK" "$CARRIER_HOLD_MAX"; then
		_rwn="применю при следующем обновлении"; [ "${SUBS_PUT_WHY:-}" = premium ] && _rwn="подниму, когда она закончится"
		if awg_direct; then
			say "  активный сервер «$_rwd» $CHG, но идёт смена транспорта или сервера, а роутер в прямом режиме — $_rwn"
			AWG_LAGS=2
		else
			say "  активный сервер «$_rwd» $CHG, но идёт смена транспорта или сервера — $_rwn"
			AWG_LAGS=1
		fi
		AWG_DEFER=1
		return 0
	fi
	# Does AmneziaWG carry right now — the same question `refresh` asks itself; here it only chooses the words.
	_rwt=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
	_rwc=0
	[ "$_rwt" = awg ] && [ ! -f "$ENODIA_STATE/.vpn-off" ] && _rwc=1
	[ "$_rwc" = 1 ] && say "  активный сервер «$_rwd» $CHG — поднимаю новый конфиг"
	# stdin from /dev/null: we run inside cmd_update's `while read` over the tags file, and a child that reads would eat it.
	sh "$ENODIA_DIR/switch-vpn.sh" refresh "$_rwa" > "$TMPD/refresh.out" 2>&1 </dev/null; _rwr=$?
	# THE WARM RESERVE: another transport carries and awg0 stands by for the return home (the watchdog reads ITS handshake) — on the
	# key it was raised with. A new key of the same server only stages awg.conf, and the reserve went on with a key the server no
	# longer takes: its handshake never came back, nor the return (review s.136 r2, M1). Raised again on the new copy — road.sh's
	# «warm» rule — under the same lock.
	_rwr2=""
	case "$_rwt" in ''|awg) ;; *)
		if [ "$(cfg_sig "$FAM_LIVE")" = "$_rws" ] && [ -e /sys/class/net/awg0 ] && [ ! -f "$ENODIA_STATE/.vpn-off" ] && [ -f "$ENODIA_DIR/transport.sh" ]; then
			sh "$ENODIA_DIR/transport.sh" rewarm awg >/dev/null 2>&1 </dev/null && _rwr2="; тёплый резерв AmneziaWG поднят на нём"
		fi ;;
	esac
	rm -f "$SWITCH_LOCK" 2>/dev/null
	# THE VERDICT IS THE WORKING COPY, not the code: the code of a switch speaks of the carrier, and the copy may have been laid
	# out with the carrier left alone (another transport, the VPN switched off in the middle).
	if [ "$(cfg_sig "$FAM_LIVE")" = "$_rws" ]; then
		rm -f "$AWG_TRIED" 2>/dev/null
		if [ "$_rwc" = 1 ] && [ "$_rwr" = 0 ]; then
			say "  новый конфиг сервера «$_rwd» поднят"
			ev "subs-active-changed" 3600 "Подписка обновила активный сервер" \
				"Сервер «$_rwd» $CHG. Роутер поднял его новый конфиг."
		elif [ "$_rwt" = awg ]; then
			say "  активный конфиг «$_rwd» обновлён (поднимется при включении VPN)"
		else
			say "  активный конфиг «$_rwd» обновлён (применится при переключении на awg$_rwr2)"
		fi
		return 0
	fi
	# Code 3 — the active server changed while we worked (the watchdog stepped onto a reserve): not ours to touch, no mark.
	if [ "$_rwr" = 3 ]; then
		say "  активный сервер сменился, пока шло обновление, — конфиг «$_rwd» лежит новым, рабочую копию не трогаю"
		return 0
	fi
	# The reason in switch-vpn.sh's own words (its first [FAIL] line, colours off).
	_rww=$(grep 'FAIL' "$TMPD/refresh.out" 2>/dev/null | head -1 | tr -d '\033' | sed 's/\[[0-9;]*m//g; s/^[[:space:]]*\[FAIL\][[:space:]]*//' | tr -d '\r\n\t')
	AWG_LAGS=1
	[ -z "$_rwm" ] || lbl_commit_out "$AWG_TRIED" printf '%s\t%s\n' "$_rwa" "$_rwm" 2>/dev/null
	# Two different refusals, and the person checks them differently: the tunnel was raised on the new text and did not come up
	# (the previous copy is back) — or nothing was raised at all and the new text could not even be laid out (a key held by an
	# exit, no room on the partition).
	if [ "$_rwc" = 1 ] && awg_direct; then
		say "  новый конфиг сервера «$_rwd» не поднялся, прежний тоже — роутер в прямом режиме, мимо VPN${_rww:+ ($_rww)}"
		_rwx="с новым конфигом туннель не поднялся, прежний тоже не отвечает — роутер в прямом режиме, мимо VPN"
		AWG_LAGS=2
	elif [ "$_rwc" = 1 ]; then
		say "  новый конфиг сервера «$_rwd» не поднялся — работает прежний${_rww:+ ($_rww)}"
		_rwx="с новым конфигом туннель не поднялся — роутер вернул прежний"
	else
		say "  новый конфиг сервера «$_rwd» не разложен — рабочая копия прежняя${_rww:+ ($_rww)}"
		_rwx="разложить его новый конфиг не удалось — рабочая копия осталась прежней"
	fi
	ev "subs-active-refused" 21600 "Новый конфиг активного сервера не применён" \
		"Сервер «$_rwd» $CHG, но $_rwx.${_rww:+ Причина: $_rww.} Роутер попробует снова после перезагрузки или когда конфиг в подписке изменится ещё раз; сразу — выберите этот сервер в панели заново."
	return 0
}

# awg_direct — «the router is in direct mode right now». A refused config's words used to end «работает прежний» whatever
# came of the return: the previous copy may be dead as well (its server changed for a reason), the switch then leaves the router
# in direct mode — and the journal, the event and the run's record said the tunnel was back (review s.133).
awg_direct() { [ "$(head -n 1 "$WD_STATE" 2>/dev/null | tr -d ' \r\n')" = FAILOPEN ]; }

# reup_exits — the configs this run CHANGED that switched-on exits stand on: each such exit is taken down and brought up by the
# new text. The way is the registry's own «set the config» (slots.sh cmd_set: down, write, up; its guards and its words) — there
# is no second way to restart an exit. Before this an exit ran on the old server until the watchdog found it dead.
# With the VPN switched off by hand the registry raises nothing and says so. Its last line is relayed as it is.
reup_exits() {
	[ -s "$TMPD/changed" ] && [ -f "$ENODIA_DIR/slots.sh" ] || return 0
	while IFS="$TAB" read -r _rxt _rxn || [ -n "$_rxt" ]; do
		[ -n "$_rxn" ] || continue
		_rxh=$(held_by "$_rxt" "$_rxn" on)
		[ -n "$_rxh" ] || continue
		_oifs=$IFS; IFS=','
		for _rxi in $_rxh; do
			IFS=$_oifs
			_rxo=$(sh "$ENODIA_DIR/slots.sh" refresh-config "$_rxi" "$_rxt" "$_rxn" 2>&1 </dev/null); _rxr=$?
			_rxl=$(printf '%s\n' "$_rxo" | tail -n 1 | sed 's/^\[slots\] //' | tr -d '\r\n\t')
			say "  выход №$_rxi: сервер «$(disp_of "$_rxn")» $CHG — ${_rxl:-перезапущен}"
			if [ "$_rxr" != 0 ] || printf '%s' "$_rxo" | grep -q 'не поднялась'; then
				ev_log "subs-exit-reup" 3600 "Выход №$_rxi не поднялся после обновления подписки" \
					"Сервер «$(disp_of "$_rxn")» $CHG, выход №$_rxi перезапущен с новым конфигом и не поднялся: ${_rxl:-причина не названа}."
			fi
		done
		IFS=$_oifs
	done < "$TMPD/changed"
	return 0
}

# ev <key> <throttle> <тема> <текст> — событие в журнал панели + письмо (notify-event сам
# держит throttle и .notify-off). Для рутинных обновлений письма не шлём — только журнал.
# Гард `-f`, а не `-x`: зовём через `sh`, и снятый бит выполнения тихо выключал бы уведомления
# о подписках целиком (класс Б7-2).
ev() { [ -f "$ENODIA_DIR/notify-event.sh" ] && sh "$ENODIA_DIR/notify-event.sh" "$1" "$2" "$3" "$4" >/dev/null 2>&1; return 0; }
ev_log() { [ -f "$ENODIA_DIR/events.sh" ] && sh "$ENODIA_DIR/events.sh" add "$1" "$2" "$3" "$4" >/dev/null 2>&1; return 0; }

# --- обновление одной подписки ----------------------------------------------
partial_note() {
	_partial_note="прочитано $N_READ, остальное не дошло — прежние серверы сохранены"
	say "  $_partial_note"
	ev_log subs-partial 300 "Подписка прочитана частично" "«$_lab»: $_partial_note"
}
update_fetch_failed() {
	say "  $1"
	SUMMARY="$SUMMARY«$_lab»: $1. "
	FAILED=$((FAILED+1))
	sub_info_put "$_t" fail
}
update_one() {
	_t="$1"
	_url=$(sub_url_of "$_t"); _lab=$(sub_label_of "$_t"); [ -n "$_lab" ] || _lab="$_t"
	# AMNEZIA PREMIUM — the link field holds the service's key: nothing to download, its servers are the countries the person
	# picked (premium.sh). A run asks the service about the subscription (date, devices) and leaves the configs alone: a new config
	# is a new key, and taking one on every run would restart a tunnel that works.
	case "$_url" in
		vpn://*)
			say "подписка «$_lab» ($_t): Amnezia Premium — спрашиваю о подписке"
			if [ ! -f "$ENODIA_DIR/premium.sh" ]; then
				say "  premium.sh не установлен — пропуск"; SUMMARY="$SUMMARY«$_lab»: нет premium.sh. "; FAILED=$((FAILED+1)); return 1
			fi
			_pmo=$(sh "$ENODIA_DIR/premium.sh" update "$_t" 2>&1 </dev/null); _pmr=$?
			_pmo=$(printf '%s\n' "$_pmo" | tail -n 1 | tr -d '\r\t')
			say "  $_pmo"
			if [ "$_pmr" = 0 ]; then SUMMARY="$SUMMARY«$_lab»: $_pmo. "; return 0; fi
			# Busy Premium work also leaves this subscription unrefreshed.
			SUMMARY="$SUMMARY«$_lab»: не обновилась ($_pmo). "; FAILED=$((FAILED+1))
			return 1 ;;
	esac
	case "$_url" in http://*|https://*) : ;; *) update_fetch_failed 'нет ссылки в реестре'; return 1 ;; esac
	sub_host_public "$_url" || { update_fetch_failed 'ссылка ведёт на приватный адрес'; return 1; }
	SUB_FETCH_PARTIAL=0
	if [ -n "${2:-}" ]; then
		cp "$2" "$TMPD/body" || { update_fetch_failed 'не удалось прочитать скачанную подписку'; return 1; }
		if command -v sub_unpack_body >/dev/null 2>&1; then sub_unpack_body "$TMPD/body" || :; fi
	else
		say "подписка «$_lab» ($_t): скачиваю"
		SUB_FETCH_VIA=""
		if ! sub_fetch_tag "$_t" "$_url" "$TMPD/body" && [ "$SUB_FETCH_PARTIAL" = 0 ]; then
			update_fetch_failed 'не скачалась: недоступна или пуста'
			return 1
		fi
		# ОТМЕТКА — СРАЗУ ПОСЛЕ ЗАКАЧКИ, А НЕ В КОНЦЕ. Остаток трафика приезжает заголовком ответа, и
		# он верен независимо от того, разберём ли мы тело: подписка, у которой «ключи кончились»,
		# отдаёт как раз ошибку в теле И честные счётчики в заголовке. Разбор провалится ниже — тогда
		# рядом с числами встанет ещё и отметка сбоя (два разных вопроса, две отметки).
		sub_info_put "$_t" ok
		# «через WAN» = хост подписки лежит в iplist_set и обычным путём ушёл бы в туннель.
		[ -n "$SUB_FETCH_VIA" ] && say "  (скачано напрямую через $SUB_FETCH_VIA — хост подписки маршрутизировался в туннель)"
	fi
	: > "$TMPD/keep"; : > "$TMPD/names"; : > "$TMPD/used"; : > "$TMPD/changed"; : > "$TMPD/xray-meta"; N_META_BAD=0
	stage_identities "$_t"
	N_NEW=0; N_CHG=0; N_SAME=0; N_DEL=0; N_SKIP=0; N_BAD=0; N_SPACE_STOP=""; ACT_GONE=""; HELD_GONE=""; HOME_GONE=""; BUSY_GONE=""; _pj_geo=0
	N_READ=0; N_PARTIAL=""; [ "$SUB_FETCH_PARTIAL" = 0 ] || N_PARTIAL=1
	N_NAME_BYTES=0; [ ! -f "$NAMES" ] || N_NAME_BYTES=$(wc -c < "$NAMES")
	DEL_FAILED=""

	# Strip a UTF-8 BOM before classifying the body.
	if [ "$(head -c 3 "$TMPD/body" 2>/dev/null)" = "$(printf '\357\273\277')" ]; then
		tail -c +4 "$TMPD/body" > "$TMPD/body.no-bom" && mv "$TMPD/body.no-bom" "$TMPD/body"
	fi
	# Provider JSON profiles, links, or a base64 list of links.
	_head=$(head -c 400 "$TMPD/body" 2>/dev/null | tr -d ' \t\r\n' | cut -c1-1)
	_ok=1
	if [ ! -s "$TMPD/body" ]; then
		_ok=0
	elif [ "$_head" = "[" ] || [ "$_head" = "{" ]; then
		parse_json "$TMPD/body" "$_t" || _ok=0
	else
		if ! grep -q '://' "$TMPD/body" 2>/dev/null; then
			( b64_dec < "$TMPD/body"; echo "$?" > "$TMPD/body.status" ) | cat > "$TMPD/body.d" 2>/dev/null || rm -f "$TMPD/body.d" 2>/dev/null
			if [ -s "$TMPD/body.d" ] && grep -q '://' "$TMPD/body.d" 2>/dev/null; then
				mv "$TMPD/body.d" "$TMPD/body"
				if [ "$(cat "$TMPD/body.status" 2>/dev/null)" != 0 ]; then N_PARTIAL=1; SUB_FETCH_PARTIAL=1; fi
			else
				rm -f "$TMPD/body.d" 2>/dev/null
			fi
		fi
		parse_links "$TMPD/body" "$_t" || _ok=0
	fi
	if [ "$_ok" != 1 ]; then
		if [ -n "$N_PARTIAL" ]; then
			partial_note
			SUMMARY="$SUMMARY«$_lab»: $_partial_note. "
			FAILED=$((FAILED+1)); sub_info_put "$_t" fail
			return 1
		fi
		# Пустой ответ провайдера («ключи кончились», протухший токен) выглядит как наша ошибка
		# разбора. Если тело — короткий JSON с detail/error/message, показываем ЕГО СЛОВА: иначе
		# человек ищет баг у себя, а подписку надо просто перевыпустить.
		_why=""
		[ "$(wc -c < "$TMPD/body")" -lt 512 ] && _why=$(sed -n 's/.*"\(detail\|error\|message\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p' "$TMPD/body" 2>/dev/null | head -1)
		say "  серверов не распознано${_why:+ — подписка ответила: $_why} — реестр конфигов НЕ трогаю"
		SUMMARY="$SUMMARY«$_lab»: не обновилась${_why:+ ($_why)}. "
		FAILED=$((FAILED+1))
		sub_info_put "$_t" fail
		return 1
	fi
	# Before any pruning, reserve enough for the largest possible map (including retained labels).
	if [ -z "$N_SPACE_STOP" ] && ! sub_space "$((4+(N_NAME_BYTES+1023)/1024))"; then N_SPACE_STOP=$(sub_space_reason); fi
	[ -n "$N_SPACE_STOP$N_PARTIAL" ] || prune_stale "$_t"
	[ "$SUBS_LOCK_MINE" = 1 ] || return 1
	if [ "${N_META_BAD:-0}" = 0 ] && [ -s "$TMPD/xray-meta" ] && command -v xp_meta_publish >/dev/null 2>&1; then
		_meta_stage=$(cat "$TMPD/xray-meta") && xp_meta_publish "$_meta_stage"
	fi
	_names_failed=0
	if [ -s "$TMPD/names" ] || [ -z "$N_SPACE_STOP$N_PARTIAL" ]; then write_names "$_t" || _names_failed=1; fi
	_tot=$((N_NEW+N_CHG+N_SAME))
	say "  серверов $_tot (новых $N_NEW, изменено $N_CHG, снято $N_DEL, пропущено $((N_SKIP+N_BAD)))"
	CH_TOTAL=$((CH_TOTAL+N_NEW+N_CHG+N_DEL))
	SRV_TOTAL=$((SRV_TOTAL+_tot))
	# The run's record for the panel (the toast of «Обновить серверы», the «Автообновление» card, the journal) is put together
	# BELOW, after the active config and the exits: the hardware walk of 13.10.2026 showed a green «серверов 3 (… изменено 1 …)»
	# over a run whose new config of the ACTIVE server had not come up — the person learnt of it from the bell alone.
	_sumrec="«$_lab»: серверов $_tot (новых $N_NEW, изменено $N_CHG, снято $N_DEL)"
	if [ -n "$ACT_GONE" ]; then
		for _ag in $ACT_GONE; do
			say "  ВНИМАНИЕ: активный сервер «$_ag» исчез из подписки — конфиг ОСТАВЛЕН"
			ev "subs-active-gone" 21600 "Активный сервер исчез из подписки" \
				"Сервер «$_ag» больше не приходит в подписке «$_lab». Конфиг на роутере оставлен (несущую по расписанию не рвём) — выберите другой сервер в панели."
		done
	fi
	# The same for a config left under an exit («name:exits»): it stays, and the person is told which exit to look at.
	if [ -n "$HELD_GONE" ]; then
		for _hg in $HELD_GONE; do
			_hgd=$(disp_of "${_hg%%:*}"); _hgx=$(printf '%s' "${_hg#*:}" | sed 's/,/, №/g')
			say "  ВНИМАНИЕ: сервер «$_hgd» исчез из подписки — конфиг ОСТАВЛЕН: на нём выход №$_hgx"
			ev "subs-held-gone" 21600 "Сервер выхода исчез из подписки" \
				"Сервер «$_hgd» больше не приходит в подписке «$_lab», а на нём стоит выход №$_hgx. Конфиг на роутере оставлен (выход по расписанию не рвём) — выберите выходу другой сервер в «Дополнительных выходах»."
		done
	fi
	# …and for the reserve's «home»: the journal says it, the record counts it among the kept; no letter — nothing is wrong yet.
	for _hm in $HOME_GONE; do
		say "  ВНИМАНИЕ: сервер «$(disp_of "$_hm")» исчез из подписки — конфиг ОСТАВЛЕН: он «дом» резерва, сторож вернётся на него"
	done
	AWG_LAGS=0
	drop_lock
	refresh_active "$_t"
	reup_exits
	take_lock || return 1
	# Two facts a person must not miss, said in the record itself (each after «;» — the record's own clause stays whole for
	# the panel's translation): servers that left the subscription and were KEPT because they are in use, and a new config of
	# the active server that is NOT applied (refused now or earlier — said on every run while the working copy lags).
	_sumk=0; for _sk in $ACT_GONE $HELD_GONE $HOME_GONE $BUSY_GONE; do _sumk=$((_sumk+1)); done
	[ "$_sumk" = 0 ] || _sumrec="$_sumrec; занятых оставлено $_sumk"
	case "$AWG_LAGS" in
		1) _sumrec="$_sumrec; новый конфиг активного сервера не применён — работает прежний" ;;
		2) _sumrec="$_sumrec; новый конфиг активного сервера не применён, прежний не отвечает — роутер в прямом режиме" ;;
	esac
	if [ -n "$N_SPACE_STOP" ]; then
		_space_result="сохранено $_tot серверов; остальные не сохранены: $N_SPACE_STOP"
		say "  $_space_result"
		_sumrec="$_sumrec; $_space_result"
	fi
	if [ -n "$N_PARTIAL" ]; then partial_note; _sumrec="$_sumrec; $_partial_note"; fi
	[ "$_names_failed" = 0 ] || _sumrec="$_sumrec; не удалось сохранить имена серверов"
	if [ -n "$N_SPACE_STOP$N_PARTIAL" ] || [ "$_names_failed" = 1 ]; then
		FAILED=$((FAILED+1))
		sub_info_put "$_t" fail
		SUMMARY="$SUMMARY$_sumrec. "
		return 1
	fi
	if [ -n "$DEL_FAILED" ]; then
		FAILED=$((FAILED+1))
		sub_info_put "$_t" fail
		SUMMARY="$SUMMARY$_sumrec; не удалось снять устаревшие конфиги. "
		return 1
	fi
	SUMMARY="$SUMMARY$_sumrec. "
	return 0
}

# --- вербы ------------------------------------------------------------------
sub_run_record() {
	# One small flash write for the panel and a result for the browser relay.
	_record=$(printf '%s' "${SUMMARY:-нет подписок}" | sub_sum_cut 1000)
	_run_ts=$(date +%s 2>/dev/null)
	case "$_run_ts" in ''|*[!0-9]*) _run_ts=1 ;; esac
	_run_prev=$(cut -f1 "$ENODIA_STATE/.subs-last" 2>/dev/null)
	if [ "$_run_prev" = "$_run_ts" ]; then _run_ts=$((_run_ts+1)); fi
	_run_published=0
	if [ ! -d "$ENODIA_STATE/.subs-last" ] &&
	   lbl_commit_out "$ENODIA_STATE/.subs-last" printf '%s\t%s\t%s\t%s\n' \
		"$_run_ts" "$([ "$FAILED" -gt 0 ] && echo fail || echo ok)" "$_record" "${RUN_GEO:-0}"; then
		_run_published=1
	else
		SUMMARY="Не удалось сохранить результат обновления подписок. $SUMMARY"
		_record=$(printf '%s' "$SUMMARY" | sub_sum_cut 1000)
		say "$_record"
	fi
	[ -z "$1" ] || printf 'relay-result\t%s\t%s\n' "${RUN_GEO:-0}" "$_record"
	[ "$_run_published" = 1 ]
}
cmd_update() {
	_one="$1"
	if [ -n "${3:-}" ] && [ "$(sub_url_revision "$(sub_url_of "$_one")")" != "$3" ]; then
		printf 'relay-result\t0\tСсылка подписки изменилась — скачайте подписку заново.\n'
		return 1
	fi
	if [ ! -f "$ENODIA_STATE/.subs" ]; then
		[ -z "$_one" ] && return 0
		SUMMARY="Подписка «$_one» не найдена в реестре."
		[ -z "${2:-}" ] || printf 'relay-result\t0\t%s\n' "$SUMMARY"
		return 1
	fi
	# место на флеше: конфиги подписки пишутся на /data, а переполнение UBIFS роняет DNS и туннель
	if ! sub_space 0; then
		SUMMARY="сохранено 0 серверов; остальные не сохранены: $(sub_space_reason)."
		FAILED=1
		say "$SUMMARY"
		sub_run_record "${2:-}"
		ev "subs-nospace" 21600 "Нет места для обновления подписок" "$SUMMARY"
		return 1
	fi
	mkdir -p "$CFGDIR" "$HY2DIR" 2>/dev/null
	CH_TOTAL=0; SRV_TOTAL=0; FAILED=0; DONE=0; SUMMARY=""; RUN_GEO=0
	# Список тегов снимаем ОДИН раз в файл: busybox sh без `local`, и вложенные функции
	# (update_one → parse_links → name_for) переиспользуют `_t` — цикл по подстановке
	# затирался бы изнутри собственного тела.
	sub_tags > "$TMPD/tags" 2>/dev/null
	while IFS= read -r _tg || [ -n "$_tg" ]; do
		case "$_tg" in ''|*[!a-z0-9-]*) continue ;; esac
		[ -n "$_one" ] && [ "$_one" != "$_tg" ] && continue
		update_one "$_tg" "${2:-}" && DONE=$((DONE+1))
		if [ "$SUBS_LOCK_MINE" != 1 ]; then
			say 'Идёт другая операция с подписками — повторите обновление.'
			[ -z "${2:-}" ] || printf 'relay-result\t0\tИдёт другая операция с подписками — повторите обновление.\n'
			return 1
		fi
	done < "$TMPD/tags"
	if [ -n "$_one" ] && [ "$DONE" = 0 ] && [ "$FAILED" = 0 ]; then
		SUMMARY="Подписка «$_one» не найдена в реестре."
		FAILED=1
	fi
	sub_run_record "${2:-}" || return 1
	if [ "$CH_TOTAL" -gt 0 ] && [ "$DONE" -gt 0 ]; then
		ev_log "subs-update" 300 "Подписки обновлены" "$SUMMARY"
	fi
	if [ -n "${2:-}" ] && [ "$DONE" = 0 ]; then return 1; fi
	if [ "$FAILED" -gt 0 ] && [ "$DONE" = 0 ]; then
		ev "subs-fail" 21600 "Подписки не обновились" "$SUMMARY"
		return 1
	fi
	return 0
}

# client-json — how each registry subscription presents itself to its provider (subs-lib.sh, `.sub-client`), for cgi-bin/list:
# {"presets":{"enodia":"…","happ":"…","v2rayng":"…"},"subs":{"<tag>":{"cl":"happ","ua":"","hwon":1,"hw":"7f3a…c91e","src":"gen"}}}.
# The HWID goes out MASKED: the panel shows WHICH one, never the value — a credential, as the link is, and the link never reaches
# the panel either. A custom line is the person's own and goes as is (escaped). The preset strings come from their one owner.
cmd_client_json() {
	command -v sub_client_read >/dev/null 2>&1 || { printf '{"presets":{},"subs":{}}'; return 0; }
	_cjo=""
	for _cjt in $(sub_tags); do
		case "$_cjt" in ''|*[!a-z0-9-]*) continue ;; esac
		sub_client_read "$_cjt"
		_cjh=""
		# A quarter of the value at most at each end (four at most): a short pasted HWID (4..16) showed whole or half (review s.171 r1);
		# the panel masks a pasted one the same way (subHwMask).
		[ -n "$SUB_CL_HWID" ] && _cjh="$(printf '%s' "$SUB_CL_HWID" | awk '{ n = length($0); k = int(n / 4); if (k > 4) k = 4; print substr($0, 1, k) "…" substr($0, n - k + 1) }')"
		_cju=$(printf '%s' "$SUB_CL_UA" | sed 's/\\/\\\\/g; s/"/\\"/g')
		_cjo="$_cjo${_cjo:+,}\"$_cjt\":{\"cl\":\"$SUB_CL\",\"ua\":\"$_cju\",\"hwon\":$SUB_CL_HWON,\"hw\":\"$_cjh\",\"src\":\"$SUB_CL_HWSRC\"}"
	done
	printf '{"presets":{"enodia":"%s","happ":"%s","v2rayng":"%s"},"subs":{%s}}' \
		"$(sub_client_ua enodia | sed 's/\\/\\\\/g; s/"/\\"/g')" "$(sub_client_ua happ | sed 's/\\/\\\\/g; s/"/\\"/g')" \
		"$(sub_client_ua v2rayng | sed 's/\\/\\\\/g; s/"/\\"/g')" "$_cjo"
}

cmd_fetch() {
	_t="$1"
	case "$_t" in ''|*[!a-z0-9-]*) echo "плохая метка подписки" >&2; return 1 ;; esac
	_url=$(sub_url_of "$_t")
	[ -z "${2:-}" ] || [ "$(sub_url_revision "$_url")" = "$2" ] || return 4
	case "$_url" in http://*|https://*) : ;; *) echo "подписка не найдена на роутере" >&2; return 1 ;; esac
	sub_host_public "$_url" || { echo "URL подписки ведёт на приватный/локальный адрес — отказ (SSRF)" >&2; return 1; }
	# СЧЁТЧИКИ ПИШЕМ И ЗДЕСЬ. Этим вербом панель забирает тело при импорте — то есть в тот самый
	# момент, когда подписку ЗАВОДЯТ, а до первого прогона cron может быть неделя (расписание по
	# умолчанию выключено). Без отметки карточка неделю говорила бы «роутер её ещё не скачивал» о
	# подписке, тело которой панель только что показала.
	# ЛОКА ТУТ НЕТ НАМЕРЕННО: это чтение, а не прогон, и брать общий лок значило бы отказывать
	# импорту, пока cron обновляет соседнюю подписку. Цена — гонка в единственном исходе: если
	# запись cron'а придётся ровно в окно между нашим чтением файла и mv, потеряется ОТМЕТКА
	# одной подписки (не файл: mv атомарен), и её вернёт ближайшее обновление.
	SUB_FETCH_PARTIAL=0
	sub_fetch_tag "$_t" "$_url" "$TMPD/body"; _fetched=$?
	if [ "$SUB_FETCH_PARTIAL" = 1 ]; then sub_info_put "$_t" fail; return 3; fi
	if [ "$_fetched" != 0 ]; then
		sub_info_put "$_t" fail
		echo "подписка недоступна или пустая" >&2; return 1
	fi
	sub_info_put "$_t" ok
	base64 < "$TMPD/body" | tr -d '\r\n'
}

# cmd_parse <ссылка> — напечатать конфиг, который дал бы этой ссылке РОУТЕР (xray-JSON или
# hysteria-YAML). Точка входа наружу нужна по двум причинам: (1) стенд паритета
# dev/link-parity-test.js сверяет наш вывод с панельным, иначе «зеркало panel.js» держится
# на честном слове комментария; (2) при разборе «почему ссылка не встала» результат раньше
# можно было увидеть только дождавшись cron. Ничего не пишет и не трогает реестры.
cmd_parse() {
	[ -n "$1" ] || { echo "usage: subs-update.sh parse <ссылка>" >&2; return 1; }
	case "$1" in
		\{*)
			printf '%s\n' "$1" > "$TMPD/el.json" || return 1
			cmd_parse_json "$TMPD/el.json"; return ;;
	esac
	parse_any "$1" || { echo "не разобрал ссылку" >&2; return 1; }
	is_host "$P_HOST" && is_port "$P_PORT" || { echo "плохой адрес или порт в ссылке" >&2; return 1; }
	case "$P_PROTO" in
		awg) cat "$P_CONF" ;;
		hy2) emit_hy2 ;;
		*)   emit_cfg ;;
	esac
}

# File input avoids the OS argument-size limit. The CGI uses the same path.
cmd_parse_json() {
	if ! xp_prepare "$1" "$TMPD/profile.json" "$(profile_xray_bin)"; then
		printf '%s\n' "$XP_REASON" >&2
		return 1
	fi
	[ "$XP_GEO_REMOVED" != 1 ] || xp_geo_notice >&2
	cat "$TMPD/profile.json"
}

# cmd_name <link> — the name the link gives its server: the remark (`#…`), for Amnezia's `vpn://` — the container's
# description, else the config's own comment. Empty = the link names nothing (the file is then named by address).
cmd_name() {
	[ -n "$1" ] || { echo "usage: subs-update.sh name <ссылка>" >&2; return 1; }
	parse_any "$1" || { echo "не разобрал ссылку" >&2; return 1; }
	printf '%s\n' "$P_REMARK"
}

cmd_list() {
	[ -f "$ENODIA_STATE/.subs" ] || { echo "подписок нет"; return 0; }
	for _t in $(sub_tags); do
		_n=0; _nfam=""
		# Считаем ВСЕ семейства: подписка бывает смешанной, и «серверов 0» при живых
		# hy2-конфигах читалось бы как «подписка сломалась».
		# After the total — the count of each family in the order of FAMS (xray, hy2, awg): the panel's line names the
		# families of a mixed subscription («7 серверов: Xray 4, AmneziaWG 2, Hysteria2 1»). The reader is cgi-bin/data.
		for _clf in $FAMS; do
			fam_set "$_clf"; _nf=0
			for _f in "$FAM_DIR"/sub-"$_t"-*."$FAM_EXT"; do
				[ -e "$_f" ] || continue
				[ "$(sub_owner_tag "$(basename "$_f" ".$FAM_EXT")")" = "$_t" ] && _nf=$((_nf+1))
			done
			_n=$((_n+_nf)); _nfam="$_nfam$TAB$_nf"
		done
		# …and last, the KIND: `premium` — the link field holds an Amnezia Premium key (premium.sh), `link` — a subscription by URL.
		# The panel draws the two differently (a Premium one has countries and devices, no link to show or edit).
		_kind=link; case "$(sub_url_of "$_t")" in vpn://*) _kind=premium ;; esac
		printf '%s\t%s\t%s%s\t%s\n' "$_t" "$(sub_label_of "$_t")" "$_n" "$_nfam" "$_kind"
	done
}

# cmd_drop <tag> — THE SUBSCRIPTION IS BEING REMOVED: its configs of every family and its lines of the name maps. Called by
# cgi-bin/action remove_sub BEFORE the `.subs` line goes (the owner of a file is the LONGEST tag of the registry). The CGI had
# its own copy of this, with its own list of directories — the third family would have been the third place to forget.
# A CONFIG IN USE STAYS — the active one of its family, and one an exit stands on: removing a subscription must not cut what
# carries traffic (the old copy deleted both; the exit then could not come up after a restart). It stays as the PERSON'S OWN
# config: its real name moves to cfg-names.sh — where own configs keep theirs — and the CGI renames its file out of the
# subscription's namespace (cfg_mv): under «sub-<tag>-» a subscription whose tag is a prefix of this one would own it.
# Prints «kind/file» of each kept config, one per line; the CGI moves them and turns them into words.
cmd_drop() {
	_dt="$1"
	case "$_dt" in ''|*[!a-z0-9-]*) echo "плохая метка подписки" >&2; return 1 ;; esac
	# AN AMNEZIA PREMIUM WORK RUNS (a pick, a new key): it would take the router's place again after the give-back below — a place
	# held with no config on the router and no subscription to free it from (review s.136 r2, L7). Code 3, the caller says it.
	case "$(sub_url_of "$_dt")" in vpn://*)
		if [ -f "$ENODIA_DIR/premium.sh" ] && sh "$ENODIA_DIR/premium.sh" busy </dev/null >/dev/null 2>&1; then
			echo "идёт работа с Amnezia Premium"; return 3
		fi ;;
	esac
	_dkept=0
	for _dfam in $FAMS; do
		fam_set "$_dfam"
		_act=$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')
		_dhome=""; [ "$_dfam" != awg ] || _dhome=$(cat "$ENODIA_STATE/.failover-home" 2>/dev/null | tr -d ' \r\n"\\')
		for _f in "$FAM_DIR"/sub-"$_dt"-*."$FAM_EXT"; do
			[ -e "$_f" ] || continue
			_b=$(basename "$_f" ".$FAM_EXT")
			# The owner — by the registry PLUS this tag: a retry after the registry line is already gone must still know its own.
			_do=$(sub_owner_tag "$_b"); [ "${#_dt}" -gt "${#_do}" ] && _do=$_dt
			[ "$_do" = "$_dt" ] || continue
			if [ "$_b" = "$_act" ] || { [ -n "$_dhome" ] && [ "$_b" = "$_dhome" ]; } || [ -n "$(held_by "$FAM_TNAME" "$_b")" ]; then
				_dd=$(awk -F"$TAB" -v n="$_b" '($1 "") == (n "") { print $2; exit }' "$NAMES" 2>/dev/null)
				if [ -n "$_dd" ] && [ -f "$ENODIA_DIR/cfg-names.sh" ]; then
					sh "$ENODIA_DIR/cfg-names.sh" set "$FAM_TNAME" "$_b" "$_dd" >/dev/null 2>&1 </dev/null
				fi
				printf '%s/%s\n' "$FAM_TNAME" "$_b"
				_dkept=$((_dkept+1))
				continue
			fi
			cfg_gone "$_f" "$_b" || return 4
		done
	done
	# AMNEZIA PREMIUM: its cache goes and — nothing kept — the router's place in the subscription is given back. premium.sh reads
	# the key from the registry, so BEFORE the link is cleared below.
	case "$(sub_url_of "$_dt")" in
		vpn://*) [ ! -f "$ENODIA_DIR/premium.sh" ] || sh "$ENODIA_DIR/premium.sh" drop "$_dt" "$_dkept" >/dev/null 2>&1 </dev/null ;;
	esac
	# The registry line stays, WITHOUT its link: the caller (cgi-bin/action remove_sub) still moves the kept servers out of the
	# subscription's namespace and removes the line only then — a run that starts in between (cron, another tab's button) sees no
	# link and skips the subscription instead of laying all its configs out again (review s.134, round 2). Until it is moved, the
	# owner of a kept file is still this tag. «-», not an empty field: readers split the line with `IFS=TAB read`, and two tabs in a
	# row are ONE separator there — the label slid into the link's place (review s.134, round 3). The registry keeps the other
	# subscriptions' tokens: written closed, as its writer does (cgi-bin/action::subs_put).
	[ ! -f "$ENODIA_STATE/.subs" ] || ( umask 077; lbl_commit_out "$ENODIA_STATE/.subs" \
		awk -F"$TAB" -v t="$_dt" 'BEGIN { OFS = FS } ($1 "") == (t "") { $2 = "-" } { print }' "$ENODIA_STATE/.subs" ) 2>/dev/null
	return 0
}

# vpn-json <in> <out> — the JSON a `vpn://` link holds (the link — the first line of <in>), whole, into <out> (600). For Amnezia
# Premium (premium.sh): its key and its answers are such containers, and their fields are read by the caller.
cmd_vpn_json() {
	_vjb=$(vpn_body "$1"); [ -n "$_vjb" ] || return 1
	vpn_raw "$_vjb" || return 1
	for _vjf in "$_vd.un" "$_vd.bin"; do
		[ -s "$_vjf" ] && jf "$_vjf" '@' >/dev/null 2>&1 || continue
		( umask 077; lbl_commit_out "$2" cat "$_vjf" ) 2>/dev/null || return 1
		return 0
	done
	return 1
}
# vpn-conf <in> <out> [<private key file>] — the AmneziaWG config of a `vpn://` container, by the SAME decoder as a subscription's
# link (vpn_from: templates of the resolver, MTU, a resolver when none is named; awg_take: both keys, an endpoint) → <out> (600).
# The key file fills the template the API leaves for the key the CLIENT made (`$WIREGUARD_CLIENT_PRIVATE_KEY` — Amnezia Premium's
# config answer): the substitution is a sed SCRIPT in the run's closed dir, the key never in argv.
cmd_vpn_conf() {
	_vcb=$(vpn_body "$1"); [ -n "$_vcb" ] || return 1
	vpn_raw "$_vcb" || return 1
	if [ -n "${3:-}" ]; then
		_vck=$(head -n 1 "$3" 2>/dev/null | tr -d " \r\n$TAB")
		printf '%s' "$_vck" | grep -qE '^[A-Za-z0-9+/]{43}=$' || return 1
		printf 's#\\$WIREGUARD_CLIENT_PRIVATE_KEY#%s#g\n' "$_vck" > "$TMPD/key.sed" || return 1
		for _vcf in "$_vd.un" "$_vd.bin"; do
			[ ! -s "$_vcf" ] || lbl_commit_out "$_vcf" sed -f "$TMPD/key.sed" "$_vcf" 2>/dev/null || return 1
		done
		rm -f "$TMPD/key.sed"
	fi
	if ! { [ -s "$_vd.un" ] && vpn_from "$_vd.un"; }; then vpn_from "$_vd.bin" || return 1; fi
	awg_take "$_vd.fin" || return 1
	( umask 077; lbl_commit_out "$2" cat "$P_CONF" ) 2>/dev/null
}

# put <tag> <family> <name> <src> <display> — ONE server laid out by a source that brings them one at a time (Amnezia Premium:
# premium.sh asks the API, this owner lays the file out): the config whole or not at all (600), its real name in `.sub-names`, and —
# when the name is in use (the active server, an exit) — brought into service the way a run does it (refresh_active, reup_exits),
# with the same refusals and events. Under the run's lock (the caller takes it): the same files as a run.
cmd_put() {
	_put=$1; _pufam=$2; _pun=$3; _pus=$4
	case "$_put" in ''|*[!a-z0-9-]*) echo "плохая метка подписки"; return 1 ;; esac
	case "$_pufam" in xray|awg) ;; *) echo "плохое семейство конфига"; return 1 ;; esac
	printf '%s' "$_pun" | grep -qE '^sub-[a-z0-9-]{1,80}$' || { echo "плохое имя конфига"; return 1; }
	[ "$(sub_owner_tag "$_pun")" = "$_put" ] || { echo "имя «$_pun» не принадлежит подписке «$_put»"; return 1; }
	[ -s "$_pus" ] || { echo "нет конфига"; return 1; }
	_pud=$(san_txt "$5" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'); [ -n "$_pud" ] || _pud=$_pun
	fam_set "$_pufam"
	# A Premium work that ends after its subscription was removed (the removal holds this lock; the work waited for it) lays out
	# nothing: a half-removed line keeps «-» for its link, and the file would be a country of a key that is gone (review s.136, L5).
	case "${SUBS_PUT_WHY:-}" in premium)
		case "$(sub_url_of "$_put")" in vpn://*) ;; *) echo "подписки «$_put» уже нет — конфиг не разложен"; return 1 ;; esac ;;
	esac
	if name_elsewhere "$_pun"; then echo "имя «$_pun» занято конфигом другого протокола"; return 1; fi
	( umask 077; mkdir -p "$FAM_DIR" ) 2>/dev/null
	_puf="$FAM_DIR/$_pun.$FAM_EXT"
	( umask 077; lbl_commit_out "$_puf" cat "$_pus" ) 2>/dev/null || { echo "не удалось записать конфиг — нет места?"; return 1; }
	chmod 600 "$_puf" 2>/dev/null
	lbl_commit_out "$NAMES" lbl_without "$NAMES" "^$_pun$TAB" "$_pun$TAB$_pud" 2>/dev/null && chmod 600 "$NAMES" 2>/dev/null
	printf '%s\t%s\n' "$FAM_TNAME" "$_pun" > "$TMPD/changed"
	AWG_DEFER=0
	drop_lock
	refresh_active "$_put"
	reup_exits
	echo "конфиг «$_pud» на месте"
	# Code 4 — laid out, but the ACTIVE AmneziaWG copy waits for a switch to end: the caller asks again (`settle`).
	[ "$AWG_DEFER" = 1 ] && return 4
	return 0
}
# settle <tag> — the ACTIVE AmneziaWG config of this subscription brought into the working copy BY STATE (refresh_awg), nothing
# else: no file written, no exit restarted. The Amnezia Premium job's second ask after `put` answered 4 (review s.136 r2, H1).
# Code 4 — a switch still holds the lock; 0 — in line, refused in words, or the active server is not this subscription's now.
cmd_settle() {
	case "$1" in ''|*[!a-z0-9-]*) echo "плохая метка подписки"; return 1 ;; esac
	fam_set awg
	_sta=$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')
	[ -n "$_sta" ] || return 0
	AWG_DEFER=0
	refresh_awg "$1" "$_sta"
	[ "$AWG_DEFER" = 1 ] && return 4
	return 0
}
# unput <tag> <family> <name> — that server removed. A config in use stays: the active server, the reserve's home, an exit's — the
# same three guards a run keeps (prune_stale), said in words and code 2.
cmd_unput() {
	_unt=$1; _unfam=$2; _unn=$3
	case "$_unt" in ''|*[!a-z0-9-]*) echo "плохая метка подписки"; return 1 ;; esac
	case "$_unfam" in xray|awg) ;; *) echo "плохое семейство конфига"; return 1 ;; esac
	printf '%s' "$_unn" | grep -qE '^sub-[a-z0-9-]{1,80}$' || { echo "плохое имя конфига"; return 1; }
	[ "$(sub_owner_tag "$_unn")" = "$_unt" ] || { echo "имя «$_unn» не принадлежит подписке «$_unt»"; return 1; }
	fam_set "$_unfam"
	_unf="$FAM_DIR/$_unn.$FAM_EXT"
	_und=$(disp_of "$_unn")
	if [ -e "$_unf" ]; then
		[ "$_unn" != "$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')" ] || { echo "«$_und» — активный сервер: сперва выберите другой"; return 2; }
		if [ "$_unfam" = awg ] && [ "$_unn" = "$(cat "$ENODIA_STATE/.failover-home" 2>/dev/null | tr -d ' \r\n"\\')" ]; then
			echo "«$_und» — «дом» резерва: сторож вернётся на него; сперва выберите основным другой сервер"; return 2
		fi
		_unx=$(held_by "$FAM_TNAME" "$_unn")
		[ -z "$_unx" ] || { echo "на «$_und» стоит выход №$(printf '%s' "$_unx" | sed 's/,/, №/g') — сперва смените выходу сервер"; return 2; }
		cfg_gone "$_unf" "$_unn"
		case "$?" in
			0) : ;;
			2) echo "сервер «$_und» оставлен: занят выходом/дорогой или выбран для подключения"; return 2 ;;
			*) echo "не удалось удалить «$_und»"; return 1 ;;
		esac
	fi
	echo "сервер «$_und» убран"
}

# Config deletion is one commit: the unlink. Road and registry locks are
# already held by their owners, in order, before subscription admission.
delete_wire_take() {
	[ -n "$1" ] || return 0
	case "$1" in *[!0-9]*) return 1 ;; esac
	[ -n "${ENODIA_DELETE_WIRE_LOCK:-}" ] && lbl_lock_take "$ENODIA_DELETE_WIRE_LOCK" 'road\.sh' "$1" ||
		{ echo '[road] правила дорог сейчас пересобирает другая операция — повторите'; return 1; }
}
delete_saved_cfg() (   # kind, file, expected digest, wire lock pid, manual|prune
	_da_kind=$1; _da_name=$2; _da_expected=$3
	lbl_cfg_key "$_da_kind/$_da_name" || exit 1
	fam_set "$_da_kind"
	_da_cfg="$FAM_DIR/$_da_name.$FAM_EXT"
	[ -f "$_da_cfg" ] || { echo "нет конфига $_da_name"; exit 1; }
	lbl_cfg_matches "$_da_cfg" "$_da_expected" ||
		{ echo 'Конфиг изменился или его версия неизвестна. Обновите список серверов.'; exit 1; }
	_da_active=$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')
	_da_reserve=""
	_da_at=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
	if [ "$_da_name" = "$_da_active" ]; then
		[ "$5" != prune ] || exit 2
		if [ "$_da_kind" = awg ]; then
			if [ "${_da_at:-awg}" = awg ] && [ ! -f "$ENODIA_STATE/.vpn-off" ]; then
				echo "нельзя удалить активный конфиг ($_da_name) — сначала переключитесь на другой"; exit 2
			fi
			# Phase two stops the selected reserve. Other live keys still hold the file.
			_da_reserve=stop-selected-reserve
		elif [ "$_da_kind" = "$_da_at" ]; then
			case "$_da_kind" in
				xray) echo 'это активный конфиг при включённом Xray — сначала переключитесь на другой транспорт' ;;
				hy2) echo 'это активный конфиг при включённой Hysteria2 — сначала переключитесь на другой транспорт' ;;
			esac
			exit 2
		fi
	fi
	if [ "$_da_kind" = awg ]; then
		if [ "$_da_name" != "$_da_active" ] && [ "$_da_name" = "$(cat "$ENODIA_STATE/.failover-home" 2>/dev/null | tr -d ' \r\n')" ]; then
			echo "«$_da_name» — «дом» резерва: сторож вернётся на него; сперва выберите основным другой сервер"; exit 2
		fi
		if [ -f "$ENODIA_DIR/road.sh" ]; then
			_da_road=$(sh "$ENODIA_DIR/road.sh" serves awg "$_da_name" 2>/dev/null | tr -cd '0-9')
			[ -z "$_da_road" ] || { echo "конфиг $_da_name служит дорогой (выход №$_da_road) — сначала переключите дорогу его пассажиров на «напрямую»"; exit 2; }
		fi
		_da_holder=$(sh "$ENODIA_DIR/slots.sh" key-holder "$_da_name" main enabled "$_da_reserve" 2>/dev/null)
		case "$?" in
			0) echo "$_da_holder"; exit 2 ;;
			1) : ;;
			*) echo 'Не удалось проверить ключ работающего AmneziaWG — повторите удаление.'; exit 1 ;;
		esac
	fi
	# Preserve disabled bindings for subscription removals and the non-AWG manual actions.
	if [ "$5" = prune ] || [ "$_da_kind" != awg ]; then
		_da_holder=$(held_by "$_da_kind" "$_da_name")
		[ -z "$_da_holder" ] || { echo "конфиг $_da_name держит выход №${_da_holder%%,*} — сначала удалите выход или смените его сервер"; exit 2; }
	fi
	_da_names="$ENODIA_STATE/.cfg-names"; _da_favs="$ENODIA_STATE/.server-favs"
	_da_names_stage="$_da_names.$$.delete.new"
	_da_favs_stage="$_da_favs.$$.delete.new"
	_da_sub_stage="$NAMES.$$.delete.new"
	_da_names_locked=0; _da_favs_locked=0
	delete_saved_cleanup() {
		rm -f "$_da_names_stage" "$_da_favs_stage" "$_da_sub_stage"
		[ "$_da_favs_locked" = 0 ] || lbl_lock_drop "$LBL_FAV_LOCK"
		[ "$_da_names_locked" = 0 ] || lbl_lock_drop "$LBL_CFG_NAMES_LOCK"
	}
	trap 'delete_saved_cleanup' EXIT
	trap 'exit 1' HUP INT TERM PIPE
	lbl_lock_take "$LBL_CFG_NAMES_LOCK" "$LBL_CFG_NAMES_HOLDERS" ||
		{ echo 'Имена серверов сейчас меняются — повторите удаление.'; exit 1; }
	_da_names_locked=1
	lbl_lock_take "$LBL_FAV_LOCK" "$LBL_FAV_HOLDERS" ||
		{ echo 'Избранное сейчас меняется — повторите удаление.'; exit 1; }
	_da_favs_locked=1
	lbl_stage_drop "$_da_names" "$_da_kind/$_da_name" "$_da_names_stage" &&
		lbl_stage_drop "$_da_favs" "$_da_kind/$_da_name" "$_da_favs_stage" ||
		{ echo 'Не удалось подготовить обновление имён и избранного.'; exit 1; }
	if ! name_elsewhere "$_da_name"; then
		lbl_stage_drop "$NAMES" "$_da_name" "$_da_sub_stage" ||
			{ echo 'Не удалось подготовить удаление имени сервера подписки.'; exit 1; }
	fi
	delete_wire_take "${4:-}" || exit 1
	lbl_cfg_matches "$_da_cfg" "$_da_expected" ||
		{ echo 'Конфиг изменился или его версия неизвестна. Обновите список серверов.'; exit 1; }

	{ rm -f "$_da_cfg" 2>/dev/null && [ ! -e "$_da_cfg" ]; } || { echo "не удалось удалить $_da_name"; exit 1; }
	_da_warn=0
	if [ -f "$ENODIA_DIR/server-checks-lib.sh" ]; then
		( . "$ENODIA_DIR/server-checks-lib.sh"; sc_drop "$_da_kind" "$_da_cfg" ) >/dev/null 2>&1
	fi
	if [ "$_da_name" = "$_da_active" ]; then
		if [ "$_da_kind" = awg ]; then
			sh "$ENODIA_DIR/switch-vpn.sh" clear-selection "$_da_name" >/dev/null 2>&1 || _da_warn=1
		else
			rm -f "$FAM_ACT" || _da_warn=1
		fi
	fi
	lbl_publish_drop "$NAMES" "$_da_sub_stage" || _da_warn=1
	lbl_publish_drop "$_da_names" "$_da_names_stage" || _da_warn=1
	lbl_publish_drop "$_da_favs" "$_da_favs_stage" || _da_warn=1
	if [ "$_da_kind" = awg ] && [ -f "$ENODIA_DIR/warp.sh" ]; then
		sh "$ENODIA_DIR/warp.sh" prune give >/dev/null 2>&1 || _da_warn=1
	fi
	[ "$_da_warn" = 0 ] || echo 'Конфиг удалён. Не удалось полностью обновить список серверов.'
	exit 0
)

# Лок: параллельный прогон (cron + кнопка в панели) топтал бы один набор файлов. Устаревший
# лок снимаем `rm -rf` — внутри pid-файл, rmdir его не возьмёт (грабля do_update в lists).
take_lock() {
	if ! mkdir "$LOCK" 2>/dev/null; then
		_p=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')
		if [ -n "$_p" ] && [ -d "/proc/$_p" ]; then
			say "уже идёт обновление подписок (pid $_p) — выхожу"
			return 1
		fi
		# «Пид-файла нет» ≠ «лок брошен» (грабля Б8-4 из lists-lib): между mkdir и записью ПИДа
		# есть окно в микросекунды, и конкурент, заставший ровно его, снёс бы ЖИВОЙ лок — в
		# критическую секцию зашли бы ОБА (cron и кнопка панели пишут один набор файлов).
		# Без ПИДа судим ТОЛЬКО по возрасту каталога; не смогли узнать возраст — считаем свежим.
		# Возраст — через age_since (clock-lib): лок в /tmp рождается после загрузки, а скачок
		# часов вперёд объявил бы СВЕЖИЙ лок протухшим — то есть ровно тот исход, от которого
		# оберегает абзац выше, только по другой причине.
		if [ -z "$_p" ]; then
			if unpublished_lock_live "$LOCK"; then
				say "лок обновления подписок свежий, но без pid — жду следующего запуска"
				return 1
			fi
		fi
		say "лок обновления подписок протух — перехватываю"
		rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || return 1
	fi
	echo "${1:-$$}" > "$LOCK/pid" 2>/dev/null || { rm -rf "$LOCK"; return 1; }
	SUBS_LOCK_MINE=1
	return 0
}
unpublished_lock_live() {
	_ul_time=$(date -r "$1" +%s 2>/dev/null)
	case "$_ul_time" in ''|*[!0-9]*) return 0 ;; esac
	[ "$(age_since "$_ul_time")" -lt 1800 ]
}
drop_lock() { [ "$SUBS_LOCK_MINE" != 1 ] || rm -rf "$LOCK" 2>/dev/null; SUBS_LOCK_MINE=0; }
# One subscription job retains admission even while its short state lock
# is released to acquire earlier locks for pruning or carrier replay.
take_job() {
	_sj_state_lock=$LOCK
	LOCK="$LOCK.run"
	take_lock; _sj_rc=$?
	LOCK=$_sj_state_lock
	[ "$_sj_rc" = 0 ] || return 1
	SUBS_LOCK_MINE=0; SUBS_JOB_MINE=1
}
subs_job_live() {
	[ -d "$LOCK.run" ] || return 1
	_sj_pid=$(cat "$LOCK.run/pid" 2>/dev/null | tr -cd '0-9')
	if [ -n "$_sj_pid" ]; then [ -d "/proc/$_sj_pid" ]; else unpublished_lock_live "$LOCK.run"; fi
}
drop_job() { [ "$SUBS_JOB_MINE" = 0 ] || rm -rf "$LOCK.run"; SUBS_JOB_MINE=0; }

# The CGI owns launch until spawn_bg publishes the worker PID. Only the
# small terminal receipts have a retention period for repeated polls.
subs_work_sweep() {
	command -v store_tmp_pid_sweep >/dev/null 2>&1 || return 0
	store_tmp_pid_sweep "${TMPD%.*}"
	store_tmp_pid_sweep "${TMPD%/*}/enodia-cgi-in"
	for _sw_dir in "${TMPD%/*}"/enodia-subs-relay.* "${TMPD%/*}"/enodia-subs-refresh.*; do
		_sw_token=${_sw_dir##*.}
		case "$_sw_token" in *[!A-Za-z0-9]*) continue ;; esac
		[ "${#_sw_token}" = 6 ] && [ -d "$_sw_dir" ] && [ ! -L "$_sw_dir" ] || continue
		if store_pid_live "$(cat "$_sw_dir/launch" 2>/dev/null)" ||
		   store_pid_live "$(cat "$_sw_dir/pid" 2>/dev/null)"; then continue; fi
		if [ -e "$_sw_dir/body" ] || store_tmp_dir_expired "$_sw_dir" 900; then rm -rf "$_sw_dir"; fi
	done
	return 0
}

refresh_path() {
	case "$1" in *[!A-Za-z0-9]*) return 1 ;; esac
	[ "${#1}" = 6 ] || return 1
	_refresh_dir="/tmp/enodia-subs-refresh.$1"
	[ -d "$_refresh_dir" ] && [ ! -L "$_refresh_dir" ]
}
refresh_status() {
	if refresh_path "$1"; then
		[ ! -s "$_refresh_dir/result" ] || { cat "$_refresh_dir/result"; return; }
		if pid_runs "$(cat "$_refresh_dir/pid" 2>/dev/null)" 'subs-import\.sh.*refresh-job'; then
			printf 'running\n'; return
		fi
		[ ! -s "$_refresh_dir/result" ] || { cat "$_refresh_dir/result"; return; }
	fi
	printf 'error\t0\t0\tОбновление подписки прервано.\n'
}
refresh_job() {
	refresh_path "$2" || return 1
	_refresh_ok=0; _refresh_state=refused; RUN_GEO=0
	SUMMARY='Уже идёт обновление подписок. Повторите после его завершения.'
	if take_job && take_lock; then
		SUMMARY=; FAILED=0; DONE=0; _refresh_state=done
		if cmd_update "$1" >/dev/null && [ "$FAILED" = 0 ] && [ "$DONE" -gt 0 ]; then _refresh_ok=1; fi
		[ -n "$SUMMARY" ] || SUMMARY='Нет подписок для обновления.'
	fi
	drop_lock; drop_job
	_refresh_msg=$(printf '%s' "${SUMMARY:-Нет результата обновления подписки.}" | sub_sum_cut 1000)
	( umask 077; lbl_commit_out "$_refresh_dir/result" printf '%s\t%s\t%s\t%s\n' \
		"$_refresh_state" "$_refresh_ok" "${RUN_GEO:-0}" "$_refresh_msg" )
}
import_body_run() {
	case "$1" in ''|*[!a-z0-9-]*) return 1 ;; esac
	[ -s "$2" ] || return 1
	if ! { take_job && take_lock; }; then
		printf 'relay-result\t0\tУже идёт обновление подписок. Повторите после его завершения.\n'
		return 1
	fi
	cmd_update "$1" "$2" "${3:-}"; _ibr_rc=$?
	drop_lock
	return "$_ibr_rc"
}

# Лог в /tmp (RAM, ротации в проекте нет) — но подрезаем, чтобы частый cron не съел память.
trim_log() {
	[ -f "$LOG" ] || return 0
	_sz=$(wc -c < "$LOG" 2>/dev/null); [ -n "$_sz" ] || return 0
	[ "$_sz" -lt 131072 ] && return 0
	tail -n 300 "$LOG" > "$LOG.new" 2>/dev/null && mv "$LOG.new" "$LOG" 2>/dev/null
}

# Public status shares the real job admission, including the unpublished lock.
if [ "$1" = running ]; then subs_job_live; exit $?; fi
if [ "$1" = refresh-status ]; then refresh_status "$2"; exit $?; fi
case "$1" in
	workspace-sweep) subs_work_sweep; exit $? ;;  # the relay CGI calls before allocating its body
	update|""|refresh-job|relay-job|import-body) subs_work_sweep ;;
esac

# THE RUN'S FILES CARRY PRIVATE KEYS (a decoded link, a config on its way to its place): the dir is the run's OWN and CLOSED —
# made, not «made or found». `mkdir -p` under the caller's umask left them readable to every process of the router, in a dir a
# stranger could have put there first (review s.133; the same care as cap_run of cgi-bin/action).
rm -rf "$TMPD" 2>/dev/null
( umask 077; mkdir "$TMPD" ) 2>/dev/null || { echo "не удалось создать каталог работы $TMPD" >&2; exit 1; }
# PIPE/HUP в списке не для красоты: прогон пишет прогресс в stdout, и оборванный читатель
# (панель закрыла трубу, `| head`) убивает нас сигналом — EXIT-ловушка тогда не срабатывает,
# и каталог остаётся в /tmp, то есть в ОЗУ. Замерено на живом роутере: такой каталог (тогда он звался
# /tmp/enodia-subs-update.7007) пережил обрыв и не убирался ничем. Сигнал — ВЫХОД (C121): ловушка без
# `exit` убирала каталог, а прогон шёл дальше — уже без него.
# Свой лок — тоже здесь: строку `drop_lock` после cmd_update выход по сигналу пропускает.
SUBS_LOCK_MINE=0; SUBS_JOB_MINE=0
trap 'rm -rf "$TMPD" 2>/dev/null; drop_lock; drop_job' EXIT
trap 'exit 1' INT TERM HUP PIPE
trim_log

case "$1" in
	refresh-job) refresh_job "$2" "$3"; exit $? ;;
	relay-job)
		# One process owns the queued body, progress and importer workspace.
		SUB_RELAY_PROGRESS="$3/progress"
		import_body_run "$2" "$3/body" "$4" > "$3/result" 2>&1; rc=$?
		rm -f "$3/body"
		printf '%s\n' "$rc" > "$3/exit.new" && mv -f "$3/exit.new" "$3/exit"
		exit "$rc" ;;
	import-body)
		import_body_run "$2" "$3" "${4:-}"; exit $? ;;
	update|"")
		take_job && take_lock || exit 0
		cmd_update "$2"; rc=$?
		drop_lock
		exit $rc ;;
	fetch) cmd_fetch "$2" "${3:-}" ;;
	registry-put|registry-del)
		case "$2" in ''|*[!a-z0-9-]*) exit 1 ;; esac
		take_job >/dev/null && take_lock >/dev/null || exit 2
		_reg_row=''
		if [ "$1" = registry-put ]; then
			_reg_row="$2$TAB$3$TAB$4"
		elif [ -f "$NAMES" ]; then
			# The caller has moved the kept servers out of this subscription.
			lbl_commit_out "$NAMES" sub_names_keep_other "$2" "$NAMES" || exit 1
		fi
		( umask 077; lbl_commit_out "$ENODIA_STATE/.subs" lbl_without "$ENODIA_STATE/.subs" "^$2$TAB" "$_reg_row" )
		exit $? ;;
	names-replace)
		case "$2" in ''|*[!a-z0-9-]*) exit 1 ;; esac
		take_job >/dev/null && take_lock >/dev/null || exit 2
		lbl_commit_out "$NAMES" sub_names_from_form "$2" "$3" "$NAMES"
		exit $? ;;
	restore-lock|row-lock)
		case "$2" in ''|*[!0-9]*) exit 1 ;; esac
		case "$1" in restore-lock) _lease_proc='cgi-bin/backup' ;; row-lock) _lease_proc='cgi-bin/action|road\.sh|warp\.sh' ;; esac
		pid_runs "$2" "$_lease_proc" && ! subs_job_live && take_lock "$2" >/dev/null || exit 1
		SUBS_LOCK_MINE=0   # The caller now owns the lease.
		exit 0 ;;
	restore-unlock|row-unlock)
		[ -n "$2" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$2" ] || exit 1
		SUBS_LOCK_MINE=1
		drop_lock
		exit 0 ;;
	list)  cmd_list ;;
	client-json) cmd_client_json ;;
	parse) cmd_parse "$2" ;;
	parse-json) cmd_parse_json "$2" ;;
	name)  cmd_name "$2" ;;
	vpn-json) cmd_vpn_json "$2" "$3" ;;
	vpn-conf) cmd_vpn_conf "$2" "$3" "$4" ;;
	delete-config)
		! subs_job_live && take_lock >/dev/null || { echo 'Идёт обновление подписок — повторите удаление.'; exit 1; }
		delete_saved_cfg "$2" "$3" "$4" "${5:-}" manual; exit $? ;;
	prune-sub)
		take_lock >/dev/null || exit 1
		delete_saved_cfg "$2" "$3" "$4" "${5:-}" prune; exit $? ;;
	settle) cmd_settle "$2"; exit $? ;;
	put|unput)
		# The run's lock, as `drop`: these write a run's files. Its refusal is the caller's answer (code 1, words on stdout).
		take_job && take_lock || exit 1
		case "$1" in
			put) cmd_put "$2" "$3" "$4" "$5" "$6" ;;
			unput) cmd_unput "$2" "$3" "$4" ;;
		esac
		rc=$?
		drop_lock
		exit $rc ;;
	drop)
		# Under the run's own lock: a run in progress would lay the subscription's configs out again right after us. Its
		# refusal is the caller's answer (code 1, the words on stdout), not a silent «done».
		take_job && take_lock || exit 1
		cmd_drop "$2"; rc=$?
		drop_lock
		exit $rc ;;
	*)
		echo "usage: subs-update.sh update [tag] | fetch <tag> | list | drop <tag> | parse <ссылка> | name <ссылка> | vpn-json <in> <out> | vpn-conf <in> <out> [key] | put <tag> <fam> <name> <src> <имя> | unput <tag> <fam> <name> | settle <tag>" >&2
		echo "       расписание — update-sched.sh set subs <off|6h|12h|daily|weekly>" >&2
		exit 1 ;;
esac
