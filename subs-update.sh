#!/bin/sh
# subs-update.sh — HEADLESS обновление VLESS-подписок (cron), БЕЗ открытой панели.
#
# Зачем. Подписку умел обновлять только браузер: тело качал CGI `fetch_sub`, а разбор
# (base64/gzip/JSON-массив, vless://→xray JSON) жил в panel.js. Значит серверы обновлялись,
# только когда человек откроет панель и нажмёт ⟳ — а провайдеры подписок ротируют адреса и
# UUID, и «внезапно перестал работать VPN» = просто протухший конфиг. Этот скрипт — та же
# логика на busybox sh: fetch → разбор → раскладка `xray-configs/sub-<tag>-*.json` → `.sub-names`.
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
#
# Вербы:
#   update [tag]   — обновить все подписки (или одну). Это же зовёт cron.
#   fetch <tag>    — тело подписки в base64 (используется CGI: одна копия закачки).
#   list           — что в реестре (tag, метка, сколько конфигов сейчас).
#   parse <ссылка> — конфиг из ОДНОЙ ссылки в stdout, ничего не записывая: роутерный канон
#                    разбора ссылок (xray + hy2), его же сверяет стенд паритета с panel.js.
#   sched …        — расписание живёт в update-sched.sh (job `subs`), сюда не дублируем.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
CFGDIR="$ENODIA_STATE/xray-configs"
NAMES="$ENODIA_STATE/.sub-names"
# .sub-picks — СЕМЕЙСТВО ВЫХОДА, выбранного для конфига (имя⇥семейство). Почему отдельным
# файлом, а не третьей колонкой .sub-names: тот файл — ОБЩИЙ контракт с панелью, и панель
# переписывает его ЦЕЛИКОМ при переименовании сервера (действие set_sub_names шлёт весь блок
# строк). Чужую колонку она бы просто потеряла, а три читателя (cgi-bin/list, iplist-update,
# сама панель) идут `read -r file rem` и получили бы семейство приклеенным к имени сервера.
PICKS="$ENODIA_STATE/.sub-picks"
ACTIVE_F="$ENODIA_STATE/.xray-active"
HY2DIR="$ENODIA_STATE/hy2-configs"
HY2_ACTIVE_F="$ENODIA_STATE/.hy2-active"
LOG=/tmp/enodia-subs-update.log
LOCK=/tmp/enodia-subs-update.lock
TMPD=/tmp/enodia-subs-update.$$
TAB=$(printf '\t')
# Кап серверов на подписку: 20-МБ /data + ~1 КБ на конфиг. Больше 200 — это не подписка,
# а выгрузка всего пула провайдера; лучше честно обрезать, чем забить флеш.
MAXSRV=${MAXSRV:-200}
# Ниже этого свободного места на /data (КБ) обновление не начинаем: переполнение флеша роняет
# DNS и туннель (грабля «всё тяжёлое — в ОЗУ»), а подписка того не стоит.
MINFREE_KB=${MINFREE_KB:-2048}

# Возраст отметок (clock-lib.sh) — нужен ровно одному месту, локу в take_lock; шим = прежнее.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
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
	_j=$(printf '%s' "$1" | tr -d ' \r\n' | base64 -d 2>/dev/null)
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
		case "$_ui" in *:*) _ui=$(ud "$_ui") ;; *) _ui=$(printf '%s' "$_ui" | base64 -d 2>/dev/null) ;; esac
	else
		_d=$(printf '%s' "$_s" | tr -d ' \r\n' | base64 -d 2>/dev/null)
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

# parse_any <ссылка> — ЛЮБАЯ поддерживаемая ссылка → P_*. Отдельно от parse_link намеренно:
# цикл подписки (parse_links → put_server) умеет складывать только xray-конфиги, и hy2-ссылка,
# попав в него, легла бы YAML'ом в xray-configs/*.json.
parse_any() {
	_pl=$(printf '%s' "$1" | tr -d '\r')
	case "$_pl" in
		hy2://*)       parse_hy2 "${_pl#hy2://}" ;;
		hysteria2://*) parse_hy2 "${_pl#hysteria2://}" ;;
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
fam_set() {
	case "$1" in
		hy2)
			FAM_DIR="$HY2DIR"; FAM_EXT=yaml; FAM_ACT="$HY2_ACTIVE_F"
			FAM_LIVE="$ENODIA_STATE/hysteria.yaml"; FAM_TSH=transport-hy2.sh; FAM_TNAME=hy2 ;;
		*)
			FAM_DIR="$CFGDIR";  FAM_EXT=json; FAM_ACT="$ACTIVE_F"
			FAM_LIVE="$ENODIA_STATE/xray.json";     FAM_TSH=xray-transport.sh; FAM_TNAME=xray ;;
	esac
}

# cfg_addr / cfg_port / cfg_cred <файл> — три поля, по которым решается «сервер тот же?».
# Отдельными функциями, потому что у xray это JSON, у hy2 — YAML, а вся логика вокруг общая.
cfg_addr() {
	case "$1" in
		*.yaml) sed -n 's/^server: *\(.*\):[0-9]\{1,5\}$/\1/p' "$1" 2>/dev/null | head -1 | tr -d '[]' ;;
		*)      grep -o '"address": "[^"]*"' "$1" 2>/dev/null | head -1 | cut -d'"' -f4 ;;
	esac
}
cfg_port() {
	case "$1" in
		*.yaml) sed -n 's/^server: .*:\([0-9]\{1,5\}\)$/\1/p' "$1" 2>/dev/null | head -1 ;;
		*)      grep -o '"port": [0-9]*' "$1" 2>/dev/null | sed -n 2p | tr -cd '0-9' ;;
	esac
}
cfg_cred() {
	case "$1" in
		*.yaml) sed -n 's/^auth: "\(.*\)"$/\1/p' "$1" 2>/dev/null | head -1 ;;
		*)      grep -oE '"(id|password)": "[^"]*"' "$1" 2>/dev/null | head -1 | cut -d'"' -f4 ;;
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
		*)
			grep -oE '"(address|port|id|password|method|serverName|publicKey|shortId|path|serviceName|network|security|flow|host)"[[:space:]]*:[[:space:]]*("[^"]*"|[0-9]+|\[[^]]*\])' "$1" 2>/dev/null \
				| tr -d ' \t' | sort | tr '\n' ';' ;;
	esac
}

# --- имена файлов -----------------------------------------------------------
# name_for <tag> <настоящее имя> <порядковый> — имя файла конфига.
# СНАЧАЛА ищем уже существующее имя этого же сервера в .sub-names: так конфиг, заведённый
# панелью, остаётся собой (панель режет не-латиницу по UTF-16-символам, sed — по байтам ⇒
# сгенерённые имена у двух путей РАЗНЫЕ, и каждый счёл бы чужие файлы «устаревшими»).
name_for() {
	_t="$1"; _raw="$2"; _idx="$3"
	_nm=""; _free=""
	if [ -f "$NAMES" ] && [ -n "$_raw" ]; then
		# Кандидатов с одним и тем же настоящим именем бывает НЕСКОЛЬКО: у провайдеров
		# «🇩🇪⚡Германия» встречается по два-три раза. Берём того, чей конфиг несёт ТОТ ЖЕ
		# адрес, — иначе одинаковые имена перетасовывают серверы между файлами каждый прогон.
		awk -F"$TAB" -v r="$_raw" -v p="sub-$_t-" '$1 ~ "^"p && $2==r {print $1}' "$NAMES" 2>/dev/null > "$TMPD/cand"
		while IFS= read -r _c; do
			[ -n "$_c" ] || continue
			grep -qxF "$_c" "$TMPD/used" 2>/dev/null && continue
			# ВЛАДЕЛЬЦА СПРАШИВАЕМ ЯВНО. Отбор кандидатов выше — голый префикс `^sub-<tag>-`, а теги
			# бывают префиксами друг друга («liberty» ⊂ «liberty-vpn»), и `-` встречается ВНУТРИ тега.
			# Без этой строки подписка «liberty» брала имена соседки и писала свои серверы прямо в её
			# файлы: замерено на живом BE7000 24.08.2026 — 16 конфигов «liberty-vpn» переписаны,
			# в `.sub-names` 16 дублирующихся ключей. Тот же владелец (ДЛИННЕЙШИЙ тег), что у
			# prune_stale, del_sub_configs и ownerTag() в панели — четвёртое место, где он нужен.
			[ "$(sub_owner_tag "$_c")" = "$_t" ] || continue
			# ИМЯ — ОДНО ПРОСТРАНСТВО НА ОБА СЕМЕЙСТВА (`.sub-names` и `$TMPD/keep` знают только
			# имя, а файлов у имени может быть два: xray-configs/x.json и hy2-configs/x.yaml).
			# Кандидат, чей файл лежит в ЧУЖОМ каталоге, ЗАНЯТ — в запасные его брать нельзя.
			# Замерено песочницей 24.08.2026: смешанная подписка, два сервера с ОДНИМ настоящим
			# именем (провайдер выдаёт узел и по vless, и по hysteria2), провайдер перетасовал
			# порядок и сменил адрес — vless забирал имя hy2-конфига, hy2 забирал имя xray-шного,
			# и на два сервера оставалось ЧЕТЫРЕ файла: два живых и два призрака. Призраки не
			# удалить никогда (их имя каждый прогон лежит в `keep`), панель показывает дубли, а
			# если такое имя было АКТИВНЫМ — активный конфиг молча начинал указывать на ДРУГОЙ
			# сервер, ровно то, от чего защищает липкий выбор.
			if [ "$FAM_EXT" = json ]; then
				[ -f "$HY2DIR/$_c.yaml" ] && continue
			else
				[ -f "$CFGDIR/$_c.json" ] && continue
			fi
			if [ "$(cfg_addr "$FAM_DIR/$_c.$FAM_EXT")" = "$P_HOST" ]; then _nm="$_c"; break; fi
			# В запасные — только имя, за которым НЕТ файла ни в одном каталоге (сервер сменил
			# адрес ⇒ переиспользуем его собственный файл) или наш собственный.
			[ -n "$_free" ] || _free="$_c"
		done < "$TMPD/cand"
		[ -n "$_nm" ] || _nm="$_free"
	fi
	if [ -z "$_nm" ]; then
		_rem=$(printf '%s' "$_raw" | sed 's/[^A-Za-z0-9._-]/-/g; s/^-*//; s/-*$//')
		# ПОРЯДКОВЫЙ НОМЕР в имени — мина (поймана на живой подписке 29.07.2026): у имён из
		# одних эмодзи/кириллицы латиницы не остаётся, имя вырождалось в номер, а номера съезжают
		# от прогона к прогону (провайдер пропускает элементы) ⇒ сервер попадал в ЧУЖОЙ файл,
		# «изменено 30» на ровном месте — а окажись среди них активный, был бы ещё и рестарт
		# несущей каждый тик cron. Запасное имя берём из host+port: детерминированно и читаемо.
		# …И ТА ЖЕ МИНА, ЕСЛИ ОТ ИМЕНИ ОСТАЛАСЬ ГОЛАЯ ЦИФРА. Гард выше ловил только ПУСТОЕ имя,
		# а «🇨🇭⚡Швейцария-2» после чистки — это «2», и «🇨🇭⚪Швейцария (БС-2)☁️» тоже «2»:
		# два РАЗНЫХ сервера дерутся за одно имя, и кто получит суффикс, решает ПОРЯДОК в теле
		# подписки. Провайдер порядок тасует ⇒ имена скачут. Замерено на живом BE7000 24.08.2026
		# (пул «liberty», 38 серверов): каждый прогон крона 5 файлов удаляются и заводятся заново
		# под другими именами — лишние записи на 20-МБ флеш, дубли в панели, а окажись среди них
		# активный, был бы и рестарт несущей. Номер СОХРАНЯЕМ (он различает «БС-2» и «БС-3»), но
		# приклеиваем к адресу: адрес+порт+номер зависят только от самого сервера, не от порядка.
		_hp=$(printf '%s-%s' "$P_HOST" "$P_PORT" | sed 's/[^A-Za-z0-9]/-/g; s/^-*//; s/-*$//')
		case "$_rem" in
			'')        _rem="$_hp" ;;
			*[!0-9-]*) : ;;
			*)         _rem="$_hp-$_rem" ;;
		esac
		[ -n "$_rem" ] || _rem="$_idx"
		_nm=$(printf 'sub-%s-%s' "$_t" "$_rem" | cut -c1-48)
		# КОЛЛИЗИЮ РАЗВОДИМ ОТПЕЧАТКОМ НАСТОЯЩЕГО ИМЕНИ, а не бегущим счётчиком: счётчик — это
		# опять «кто пришёл первым», то есть порядок. Отпечаток зависит только от сервера, и при
		# перетасовке пула имя остаётся тем же. Счётчик оставлен ПОСЛЕ отпечатка — на случай двух
		# серверов с одинаковым именем НА ОДНОМ адресе (тогда различать уже нечем).
		if grep -qxF "$_nm" "$TMPD/used" 2>/dev/null; then
			_base=$(printf '%s' "$_nm" | cut -c1-42)
			_h=$(printf '%s' "$_raw" | md5sum 2>/dev/null | cut -c1-4 | tr -cd 'a-f0-9')
			# Нет md5sum — берём порядковый номер: в пределах ОДНОГО прогона он различает, а имя без
			# отпечатка вовсе дало бы «base--2» (двойной дефис) и всё ту же зависимость от порядка.
			[ -n "$_h" ] || _h=$_idx
			_nm="$_base-$_h"
			_k=2
			while grep -qxF "$_nm" "$TMPD/used" 2>/dev/null; do _nm="$_base-$_h-$_k"; _k=$((_k+1)); done
		fi
	fi
	echo "$_nm" >> "$TMPD/used"
	printf '%s' "$_nm"
}

# --- запись одного сервера --------------------------------------------------
# put_server <tag> <порядковый> — P_* уже заполнены. Пишет конфиг, копит имена и счётчики.
put_server() {
	_t="$1"; _i="$2"
	is_host "$P_HOST" && is_port "$P_PORT" || { N_BAD=$((N_BAD+1)); return 1; }
	# Семейство выбираем ДО name_for: тот ищет уже заведённый файл этого сервера, и искать его
	# надо в каталоге своего протокола (xray-configs/*.json против hy2-configs/*.yaml).
	fam_set "$P_PROTO"
	mkdir -p "$FAM_DIR" 2>/dev/null
	_raw=$(printf '%s' "$P_REMARK" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$_raw" ] || _raw="#$_i"
	_nm=$(name_for "$_t" "$_raw" "$_i")
	_dst="$FAM_DIR/$_nm.$FAM_EXT"
	# Расширение у ВРЕМЕННОГО файла обязательное: по нему cfg_sig/cfg_addr понимают, JSON перед
	# ними или YAML. Без него подпись новичка считалась json-веткой поверх YAML (пусто), не
	# совпадала никогда — и hy2-конфиги переписывались на флеш КАЖДЫЙ тик крона при нулевых
	# изменениях, а отчёт врал «изменено». Поймано песочницей local/subs-mixed-test.sh.
	if [ "$P_PROTO" = hy2 ]; then emit_hy2 > "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null
	else emit_cfg > "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null; fi
	[ -s "$TMPD/cfg.new.$FAM_EXT" ] || { N_BAD=$((N_BAD+1)); return 1; }
	printf '%s\t%s\n' "$_nm" "$_raw" >> "$TMPD/names"
	# Семейство выхода — только для подписок-JSON: у ссылочных пула нет, липнуть не к чему.
	[ -n "$PICK_FAM" ] && printf '%s\t%s\n' "$_nm" "$PICK_FAM" >> "$TMPD/picks"
	echo "$_nm" >> "$TMPD/keep"
	# АКТИВНЫЙ конфиг не переписываем, пока его сервер ЕЩЁ ЕСТЬ в свежей подписке. У провайдеров
	# с пулом (адрес под одним и тем же именем меняется на каждой закачке) иначе выходило бы:
	# каждый тик cron = новый сервер у несущей = ежедневный рестарт туннеля на ровном месте.
	# Сверяем ТРИ поля (адрес+порт+креды): если провайдер сменил хоть одно — сервер действительно
	# другой, и конфиг надо обновить, иначе несущая останется с протухшими кредами.
	if [ -f "$_dst" ] && [ "$_nm" = "$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n\"\\')" ]; then
		_oa=$(cfg_addr "$_dst")
		_op=$(cfg_port "$_dst")
		_oc=$(cfg_cred "$_dst")
		if [ -n "$_oa" ] && grep -qF "$_oa" "$TMPD/body" 2>/dev/null \
		   && { [ -z "$_op" ] || grep -qF "$_op" "$TMPD/body" 2>/dev/null; } \
		   && { [ -z "$_oc" ] || grep -qF "$_oc" "$TMPD/body" 2>/dev/null; }; then
			rm -f "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null
			N_SAME=$((N_SAME+1))
			return 0
		fi
	fi
	if [ ! -f "$_dst" ]; then
		mv "$TMPD/cfg.new.$FAM_EXT" "$_dst" 2>/dev/null && chmod 600 "$_dst" 2>/dev/null
		N_NEW=$((N_NEW+1))
	elif [ "$(cfg_sig "$TMPD/cfg.new.$FAM_EXT")" != "$(cfg_sig "$_dst")" ]; then
		mv "$TMPD/cfg.new.$FAM_EXT" "$_dst" 2>/dev/null && chmod 600 "$_dst" 2>/dev/null
		N_CHG=$((N_CHG+1))
		echo "$_nm" >> "$TMPD/changed"
	else
		rm -f "$TMPD/cfg.new.$FAM_EXT" 2>/dev/null
		N_SAME=$((N_SAME+1))
	fi
	return 0
}

# --- разбор тела ------------------------------------------------------------
# parse_links <файл> <tag> — тело как список ссылок (plaintext или base64 такого списка).
parse_links() {
	_f="$1"; _t="$2"; _i=0
	# `|| [ -n "$_line" ]` — тело подписки часто приходит БЕЗ хвостового перевода строки (у
	# base64-подписок это норма), а `read` в таком случае возвращает 1 и цикл бросает уже
	# прочитанную ПОСЛЕДНЮЮ строку. Замерено на busybox BE7000: 3 строки без \n → 2 итерации.
	while IFS= read -r _line || [ -n "$_line" ]; do
		case "$_line" in *://*) : ;; *) continue ;; esac
		_line=$(printf '%s' "$_line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ "$_i" -ge "$MAXSRV" ] && { N_CUT=1; break; }
		PICK_FAM=""   # у ссылки пула нет — семейство прошлого элемента сюда не наследуем
		if parse_any "$_line"; then
			_i=$((_i+1)); put_server "$_t" "$_i"
		else
			N_SKIP=$((N_SKIP+1))
		fi
	done < "$_f"
	[ "$_i" -gt 0 ]
}

# fam_of <тег> — СЕМЕЙСТВО выхода: тег с вырезанными числами. У этого класса провайдеров тег
# несёт адрес (`proxy-decoy-45-196-208-251-direct`), а адрес переезжает на каждой закачке —
# значит сам тег идентичностью быть не может, а семейство (`proxy-decoy-#-#-#-#-direct`)
# может. У провайдеров, где тег адреса не несёт, семейство равно тегу — то есть липкость по
# семейству вырождается в липкость по тегу, что и требовалось.
fam_of() { printf '%s' "$1" | sed 's/[0-9][0-9]*/#/g'; }
PICK_FAM=""   # семейство, выбранное последним pick_outbound (пишет put_server)

# pick_outbound <файл-элемента> <tag> <настоящее имя> — индекс прокси-outbound'а, который
# станет нашим конфигом. Печатает индекс (или пусто).
#
# Почему не «первый в массиве» (так делает панель) — замер на живой подписке 29.07.2026:
# один элемент несёт ПУЛ из 15 прокси-выходов, и провайдер отдаёт его РАЗНЫМ на каждой
# закачке (порядок и сам состав). Любой позиционный выбор ⇒ адрес в конфиге меняется каждый
# прогон: «изменено 30» на ровном месте, а для АКТИВНОГО конфига это ещё и рестарт несущей
# на каждый тик cron. Поэтому выбор ЛИПКИЙ: если сервер, который уже прописан в нашем файле,
# всё ещё есть в пуле — оставляем именно его. Нечему липнуть (новый сервер) — берём
# минимальный ТЕГ: детерминированно, а у таких провайдеров тег ещё и несёт адрес.
pick_outbound() {
	_el="$1"; _pt="$2"; _pr_rem="$3"; _pfam=""
	: > "$TMPD/obs"
	_j=0
	while [ "$_j" -lt 24 ]; do
		_pr=$(jf "$_el" "@.outbounds[$_j].protocol")
		[ -n "$_pr" ] || break
		case "$_pr" in
			vless|vmess|trojan|shadowsocks)
				_tg=$(jf "$_el" "@.outbounds[$_j].tag")
				printf '%s\t%s\n' "${_tg:-~$_j}" "$_j" >> "$TMPD/obs" ;;
		esac
		_j=$((_j+1))
	done
	[ -s "$TMPD/obs" ] || return 0
	# адреса конфигов, которые сейчас носят это же имя сервера (их бывает несколько — у
	# провайдеров «🇩🇪⚡Германия» встречается по два-три раза); занятые в этом прогоне пропускаем
	: > "$TMPD/want"
	if [ -f "$NAMES" ] && [ -n "$_pr_rem" ]; then
		awk -F"$TAB" -v r="$_pr_rem" -v p="sub-$_pt-" '$1 ~ "^"p && $2==r {print $1}' "$NAMES" 2>/dev/null > "$TMPD/cand0"
		while IFS= read -r _c0; do
			[ -n "$_c0" ] || continue
			grep -qxF "$_c0" "$TMPD/used" 2>/dev/null && continue
			# ВЛАДЕЛЬЦА СПРАШИВАЕМ ЯВНО — пятое место, где нужен тот же ответ, что у name_for,
			# prune_stale, del_sub_configs и ownerTag() в панели. Отбор выше идёт голым префиксом
			# `^sub-<tag>-`, а теги бывают префиксами друг друга. Замерено на живом BE7000
			# 24.08.2026: у тега «liberty» под этот префикс попадает 76 имён, из них 38 — чужой
			# подписки «liberty-vpn», и 37 имён серверов у них СОВПАДАЮТ дословно (провайдер один,
			# подписки две). Значит в «чего хотим» ложились адреса СОСЕДКИ, липкость цеплялась за
			# чужой сервер, и наш конфиг переписывался чужим адресом.
			[ "$(sub_owner_tag "$_c0")" = "$_pt" ] || continue
			# Кандидат бывает и hy2-шный (смешанная подписка) — адрес у него в YAML.
			if [ -f "$CFGDIR/$_c0.json" ]; then cfg_addr "$CFGDIR/$_c0.json" >> "$TMPD/want"
			elif [ -f "$HY2DIR/$_c0.yaml" ]; then cfg_addr "$HY2DIR/$_c0.yaml" >> "$TMPD/want"; fi
			# …и СЕМЕЙСТВО, которое мы выбрали для него в прошлый раз (см. fam_of и .sub-picks).
			[ -n "$_pfam" ] || _pfam=$(awk -F"$TAB" -v n="$_c0" '$1==n{print $2; exit}' "$PICKS" 2>/dev/null)
		done < "$TMPD/cand0"
	fi
	# ОБХОД ПУЛА — В НАШЕМ ПОРЯДКЕ, А НЕ В ПРОВАЙДЕРСКОМ. Пул приходит перетасованным на каждой
	# закачке, а «первый совпавший» из него — это «кому повезло сегодня»: при двух подходящих
	# адресах (одно имя сервера встречается у провайдера по два-четыре раза) выбор скакал от
	# прогона к прогону, конфиг переписывался, а был бы он активным — рестарт несущей каждый тик
	# крона. Сортировка по ТЕГУ делает обход детерминированным; тем же порядком идёт и запасная
	# ветка ниже, так что «нечему липнуть» и «липнем» согласованы.
	sort "$TMPD/obs" 2>/dev/null > "$TMPD/obs.s"
	if [ -s "$TMPD/want" ]; then
		while IFS= read -r _line; do
			_idx0=${_line#*"$TAB"}
			_ad=$(jf "$_el" "@.outbounds[$_idx0].settings.vnext[0].address")
			[ -n "$_ad" ] || _ad=$(jf "$_el" "@.outbounds[$_idx0].settings.servers[0].address")
			if [ -n "$_ad" ] && grep -qxF "$_ad" "$TMPD/want" 2>/dev/null; then
				printf '%s%s%s' "$_idx0" "$TAB" "$(fam_of "${_line%%"$TAB"*}")"; return 0
			fi
		done < "$TMPD/obs.s"
	fi
	# АДРЕС НЕ СОШЁЛСЯ — ЛИПНЕМ К СЕМЕЙСТВУ. Замерено на живом BE7000 24.08.2026: у элемента ДВА
	# выхода, `proxy-decoy-<адрес>-direct` и `proxy-wl-<адрес>-direct`, и у decoy адрес МЕНЯЕТСЯ
	# на каждой закачке ⇒ прошлого адреса в пуле уже нет. Дальше шла запасная ветка «минимальный
	# тег», то есть ЛОТЕРЕЯ: человек, сидевший на «wl», молча переезжал на «decoy» — сервер
	# другой, а в панели то же имя. Семейство переживает переезд адреса и отвечает на вопрос
	# «какой из выходов этого сервера человек уже выбрал».
	# ЧЕГО ЗДЕСЬ СОЗНАТЕЛЬНО НЕТ: попытки угадать, какое семейство «лучше» (например, уйти с
	# переезжающего decoy на стабильный wl). Это разные СЕРВЕРЫ у провайдера, и «wl» по имени
	# похож на выход только для белых списков — молча пересадить туда человека хуже, чем лишняя
	# перезапись раз в неделю. Меняет выход человек, в панели.
	if [ -n "$_pfam" ]; then
		while IFS= read -r _line; do
			_idx1=${_line#*"$TAB"}
			if [ "$(fam_of "${_line%%"$TAB"*}")" = "$_pfam" ]; then
				printf '%s%s%s' "$_idx1" "$TAB" "$_pfam"; return 0
			fi
		done < "$TMPD/obs.s"
	fi
	_first=$(head -1 "$TMPD/obs.s" 2>/dev/null)
	[ -n "$_first" ] || return 0
	printf '%s%s%s' "${_first#*"$TAB"}" "$TAB" "$(fam_of "${_first%%"$TAB"*}")"
}

# parse_json <файл> <tag> — тело как готовый xray-конфиг или МАССИВ конфигов (Marzban/
# Remnawave). Нужен jsonfilter: руками такой JSON на busybox не разобрать. Из каждого элемента
# берём основной прокси-outbound (тег «proxy…», иначе первый из четырёх протоколов) и сводим
# к тем же P_* — дальше путь общий с ссылками (обратная карта emit_cfg, как xraySubToParams).
parse_json() {
	_f="$1"; _t="$2"
	[ -n "$JF" ] || { say "  подписка-JSON, но jsonfilter не найден — пропускаю"; return 1; }
	# массив или одиночный объект: у массива есть элемент [0]
	if [ -n "$(jf "$_f" '@[0]')" ]; then _arr=1; else _arr=0; fi
	_i=0; _n=0
	while :; do
		[ "$_n" -ge "$MAXSRV" ] && { N_CUT=1; break; }
		if [ "$_arr" = 1 ]; then _sel="@[$_i]"; else _sel="@"; fi
		jf "$_f" "$_sel" > "$TMPD/el.json" 2>/dev/null
		[ -s "$TMPD/el.json" ] || break
		_rem=$(jf "$TMPD/el.json" '@.remarks')
		# Ответ — «индекс⇥семейство» ОДНОЙ строкой: pick_outbound зовут через $( ), то есть в
		# ПОДОБОЛОЧКЕ, и присваивание глобальной переменной внутри неё до нас не доезжает.
		_pickraw=$(pick_outbound "$TMPD/el.json" "$_t" "$_rem")
		_pick=${_pickraw%%"$TAB"*}; PICK_FAM=""
		case "$_pickraw" in *"$TAB"*) PICK_FAM=${_pickraw#*"$TAB"} ;; esac
		case "$_pick" in ''|*[!0-9]*) _pick=-1 ;; esac
		if [ "$_pick" -ge 0 ] && jf "$TMPD/el.json" "@.outbounds[$_pick]" > "$TMPD/ob.json" 2>/dev/null && [ -s "$TMPD/ob.json" ]; then
			if json_ob_to_p "$TMPD/ob.json" "$_rem"; then _n=$((_n+1)); put_server "$_t" "$_n"; else N_SKIP=$((N_SKIP+1)); fi
		else
			N_SKIP=$((N_SKIP+1))
		fi
		[ "$_arr" = 1 ] || break
		_i=$((_i+1))
	done
	[ "$_n" -gt 0 ]
}

# json_ob_to_p <файл-outbound> <remarks> — outbound готового конфига → P_*.
json_ob_to_p() {
	p_reset
	_o="$1"; P_REMARK=$(san_txt "$2")
	P_PROTO=$(san "$(jf "$_o" '@.protocol')")
	case "$P_PROTO" in vless|vmess|trojan|shadowsocks) : ;; *) return 1 ;; esac
	[ -n "$P_REMARK" ] || P_REMARK=$(san_txt "$(jf "$_o" '@.tag')")
	if [ "$P_PROTO" = vless ] || [ "$P_PROTO" = vmess ]; then
		P_HOST=$(san "$(jf "$_o" '@.settings.vnext[0].address')")
		P_PORT=$(jf "$_o" '@.settings.vnext[0].port' | tr -cd '0-9')
		P_UUID=$(san "$(jf "$_o" '@.settings.vnext[0].users[0].id')")
		[ -n "$P_UUID" ] || return 1
		if [ "$P_PROTO" = vmess ]; then
			P_AID=$(jf "$_o" '@.settings.vnext[0].users[0].alterId' | tr -cd '0-9'); [ -n "$P_AID" ] || P_AID=0
			P_SCY=$(san "$(jf "$_o" '@.settings.vnext[0].users[0].security')"); [ -n "$P_SCY" ] || P_SCY=auto
		else
			P_ENC=$(san "$(jf "$_o" '@.settings.vnext[0].users[0].encryption')"); [ -n "$P_ENC" ] || P_ENC=none
			P_FLOW=$(san "$(jf "$_o" '@.settings.vnext[0].users[0].flow')")
		fi
	else
		P_HOST=$(san "$(jf "$_o" '@.settings.servers[0].address')")
		P_PORT=$(jf "$_o" '@.settings.servers[0].port' | tr -cd '0-9')
		P_PASS=$(san "$(jf "$_o" '@.settings.servers[0].password')")
		[ "$P_PROTO" = shadowsocks ] && P_METHOD=$(san "$(jf "$_o" '@.settings.servers[0].method')")
		[ "$P_PROTO" = trojan ] && P_FLOW=$(san "$(jf "$_o" '@.settings.servers[0].flow')")
	fi
	is_host "$P_HOST" && is_port "$P_PORT" || return 1
	P_TYPE=$(san "$(jf "$_o" '@.streamSettings.network')"); [ -n "$P_TYPE" ] || P_TYPE=tcp
	P_SEC=$(san "$(jf "$_o" '@.streamSettings.security')"); [ -n "$P_SEC" ] || P_SEC=none
	_r=$(jf "$_o" '@.streamSettings.realitySettings.publicKey')
	if [ -n "$_r" ]; then
		P_PBK=$(san "$_r"); P_SNI=$(san "$(jf "$_o" '@.streamSettings.realitySettings.serverName')")
		P_FP=$(san "$(jf "$_o" '@.streamSettings.realitySettings.fingerprint')")
		P_SID=$(san "$(jf "$_o" '@.streamSettings.realitySettings.shortId')")
		P_SPX=$(san "$(jf "$_o" '@.streamSettings.realitySettings.spiderX')")
	else
		_s=$(jf "$_o" '@.streamSettings.tlsSettings.serverName')
		[ -n "$_s" ] && P_SNI=$(san "$_s")
		_s=$(jf "$_o" '@.streamSettings.tlsSettings.fingerprint')
		[ -n "$_s" ] && P_FP=$(san "$_s")
		_s=$(jf "$_o" '@.streamSettings.tlsSettings.alpn[*]' | tr '\n' ',' | sed 's/,$//')
		[ -n "$_s" ] && P_ALPN=$(san "$_s")
	fi
	case "$P_TYPE" in
		ws)  P_PATH=$(san "$(jf "$_o" '@.streamSettings.wsSettings.path')")
		     P_HHDR=$(san "$(jf "$_o" '@.streamSettings.wsSettings.headers.Host')") ;;
		grpc) P_SVC=$(san "$(jf "$_o" '@.streamSettings.grpcSettings.serviceName')") ;;
		xhttp|splithttp)
		     P_PATH=$(san "$(jf "$_o" '@.streamSettings.xhttpSettings.path')")
		     [ -n "$P_PATH" ] || P_PATH=$(san "$(jf "$_o" '@.streamSettings.splithttpSettings.path')")
		     P_HHDR=$(san "$(jf "$_o" '@.streamSettings.xhttpSettings.host')")
		     P_MODE=$(san "$(jf "$_o" '@.streamSettings.xhttpSettings.mode')") ;;
		httpupgrade)
		     P_PATH=$(san "$(jf "$_o" '@.streamSettings.httpupgradeSettings.path')")
		     P_HHDR=$(san "$(jf "$_o" '@.streamSettings.httpupgradeSettings.host')") ;;
		h2|http)
		     P_PATH=$(san "$(jf "$_o" '@.streamSettings.httpSettings.path')")
		     P_HHDR=$(san "$(jf "$_o" '@.streamSettings.httpSettings.host[*]' | tr '\n' ',' | sed 's/,$//')") ;;
	esac
	return 0
}

# --- уборка устаревших ------------------------------------------------------
# prune_stale <tag> — снять конфиги подписки, которых больше нет в свежем наборе.
# АКТИВНЫЙ не трогаем никогда (оборвать несущую по расписанию — хуже протухшего сервера);
# владельца файла определяем длиннейшим тегом (соседняя подписка с тегом-надмножеством).
prune_stale() {
	_t="$1"
	# Оба семейства: подписка бывает смешанной, и «устаревшим» hy2-конфигом занимаемся так же,
	# как xray-овским. Активный НЕ трогаем ни в одном — рвать несущую по расписанию нельзя.
	for _psf in xray hy2; do
		fam_set "$_psf"
		_act=$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')
		for _f in "$FAM_DIR"/sub-"$_t"-*."$FAM_EXT"; do
			[ -e "$_f" ] || continue
			_b=$(basename "$_f" ".$FAM_EXT")
			[ "$(sub_owner_tag "$_b")" = "$_t" ] || continue
			grep -qxF "$_b" "$TMPD/keep" 2>/dev/null && continue
			if [ "$_b" = "$_act" ]; then
				# СПИСОК, а не одно имя: активные конфиги у семейств РАЗНЫЕ, и оба могут
				# исчезнуть в одном прогоне. Держали одно — второй оставался на диске, но
				# терял строку в .sub-names, то есть своё настоящее имя (панель показывала
				# «sub-tag-…»). Имена файлов пробелов не содержат — разделитель безопасен.
				ACT_GONE="${ACT_GONE:+$ACT_GONE }$_b"
				continue
			fi
			rm -f "$_f" 2>/dev/null && N_DEL=$((N_DEL+1))
		done
	done
}

# write_names <tag> — заменить блок этой подписки в .sub-names (имя-файла⇥настоящее имя).
# Чужие блоки снимает sub_names_keep_other (владелец = ДЛИННЕЙШИЙ тег), а не префикс: голый
# `^sub-<tag>-` уносил имена соседней подписки с тегом-надмножеством.
write_names() {
	_t="$1"
	{ sub_names_keep_other "$_t"
	  # Активный конфиг, ИСЧЕЗНУВШИЙ из подписки, prune_stale намеренно оставляет на диске —
	  # значит и строку имени надо оставить: иначе файл теряет идентичность (панель показывает
	  # его именем файла), а вернувшийся сервер заведёт себе ВТОРОЙ файл вместо этого.
	  if [ -n "$ACT_GONE" ] && [ -f "$NAMES" ]; then
		for _ag in $ACT_GONE; do grep "^$_ag$TAB" "$NAMES" 2>/dev/null | head -1; done
	  fi
	  [ -s "$TMPD/names" ] && cat "$TMPD/names"; } > "$NAMES.new" 2>/dev/null
	mv "$NAMES.new" "$NAMES" 2>/dev/null && chmod 600 "$NAMES" 2>/dev/null
	# .sub-picks — тем же порядком и тем же владельцем (см. константу PICKS наверху). Строку
	# исчезнувшего активного тоже сохраняем: конфиг остаётся на диске, и когда сервер вернётся,
	# он обязан вернуться на СВОЙ выход, а не в лотерею «минимальный тег».
	{ sub_names_keep_other "$_t" "$PICKS"
	  if [ -n "$ACT_GONE" ] && [ -f "$PICKS" ]; then
		for _ag in $ACT_GONE; do grep "^$_ag$TAB" "$PICKS" 2>/dev/null | head -1; done
	  fi
	  [ -s "$TMPD/picks" ] && cat "$TMPD/picks"; } > "$PICKS.new" 2>/dev/null
	mv "$PICKS.new" "$PICKS" 2>/dev/null && chmod 600 "$PICKS" 2>/dev/null
}

# --- активный сервер --------------------------------------------------------
# refresh_active — если у АКТИВНОГО конфига сменилась суть, поднять её в бой: xray.json —
# копия активного конфига, демон читает её на старте. Перезапускаем несущую ТОЛЬКО когда
# xray и есть активный транспорт (иначе просто обновили файл — применится при переключении).
refresh_active() {
	# По разу на семейство: у xray и hy2 свои «активный конфиг», живой файл и плагин несущей.
	for _raf in xray hy2; do
		fam_set "$_raf"
		_act=$(cat "$FAM_ACT" 2>/dev/null | tr -d ' \r\n"\\')
		[ -n "$_act" ] || continue
		grep -qxF "$_act" "$TMPD/changed" 2>/dev/null || continue
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
				say "  активный сервер «$_act» изменился в подписке — VPN выключен вручную, применится при включении"
				continue
			fi
			[ -f "$ENODIA_DIR/$FAM_TSH" ] || { say "  активный сервер «$_act» изменился, но $FAM_TSH не найден"; continue; }
			say "  активный сервер «$_act» изменился в подписке — перезапускаю несущую"
			sh "$ENODIA_DIR/$FAM_TSH" down >/dev/null 2>&1
			sh "$ENODIA_DIR/$FAM_TSH" up   >/dev/null 2>&1
			ev "subs-active-changed" 3600 "Подписка обновила активный сервер" \
				"Сервер «$_act» изменился в подписке (адрес/креды). Конфиг обновлён, несущая перезапущена."
		else
			say "  активный конфиг «$_act» обновлён (применится при переключении на $FAM_TNAME)"
		fi
	done
}

# ev <key> <throttle> <тема> <текст> — событие в журнал панели + письмо (notify-event сам
# держит throttle и .notify-off). Для рутинных обновлений письма не шлём — только журнал.
# Гард `-f`, а не `-x`: зовём через `sh`, и снятый бит выполнения тихо выключал бы уведомления
# о подписках целиком (класс Б7-2).
ev() { [ -f "$ENODIA_DIR/notify-event.sh" ] && sh "$ENODIA_DIR/notify-event.sh" "$1" "$2" "$3" "$4" >/dev/null 2>&1; return 0; }
ev_log() { [ -f "$ENODIA_DIR/events.sh" ] && sh "$ENODIA_DIR/events.sh" add "$1" "$2" "$3" "$4" >/dev/null 2>&1; return 0; }

# --- обновление одной подписки ----------------------------------------------
update_one() {
	_t="$1"
	_url=$(sub_url_of "$_t"); _lab=$(sub_label_of "$_t"); [ -n "$_lab" ] || _lab="$_t"
	case "$_url" in http://*|https://*) : ;; *) say "подписка «$_lab»: нет ссылки в реестре — пропуск"; return 1 ;; esac
	sub_host_public "$_url" || { say "подписка «$_lab»: ссылка ведёт на приватный адрес — отказ (SSRF)"; return 1; }
	say "подписка «$_lab» ($_t): скачиваю"
	SUB_FETCH_VIA=""
	if ! sub_fetch "$_url" "$TMPD/body"; then
		say "  недоступна или пустая"
		SUMMARY="$SUMMARY«$_lab»: не скачалась. "
		FAILED=$((FAILED+1))
		sub_info_put "$_t" fail
		return 1
	fi
	# ОТМЕТКА — СРАЗУ ПОСЛЕ ЗАКАЧКИ, А НЕ В КОНЦЕ. Остаток трафика приезжает заголовком ответа, и
	# он верен независимо от того, разберём ли мы тело: подписка, у которой «ключи кончились»,
	# отдаёт как раз ошибку в теле И честные счётчики в заголовке. Разбор провалится ниже — тогда
	# рядом с числами встанет ещё и отметка сбоя (два разных вопроса, две отметки).
	sub_info_put "$_t" ok
	# «через WAN» = хост подписки лежит в iplist_set и обычным путём ушёл бы в туннель.
	[ -n "$SUB_FETCH_VIA" ] && say "  (скачано напрямую через $SUB_FETCH_VIA — хост подписки маршрутизировался в туннель)"
	: > "$TMPD/keep"; : > "$TMPD/names"; : > "$TMPD/used"; : > "$TMPD/changed"
	N_NEW=0; N_CHG=0; N_SAME=0; N_DEL=0; N_SKIP=0; N_BAD=0; N_CUT=0; ACT_GONE=""
	# Вид тела: JSON-конфиги / список ссылок / base64 такого списка (детект как в панели).
	_head=$(head -c 400 "$TMPD/body" 2>/dev/null | tr -d ' \t\r\n' | cut -c1-1)
	_ok=1
	if [ "$_head" = "[" ] || [ "$_head" = "{" ]; then
		parse_json "$TMPD/body" "$_t" || _ok=0
	else
		if ! grep -q '://' "$TMPD/body" 2>/dev/null; then
			tr -d ' \r\n' < "$TMPD/body" | base64 -d > "$TMPD/body.d" 2>/dev/null
			if [ -s "$TMPD/body.d" ] && grep -q '://' "$TMPD/body.d" 2>/dev/null; then
				mv "$TMPD/body.d" "$TMPD/body"
			else
				rm -f "$TMPD/body.d" 2>/dev/null
			fi
		fi
		parse_links "$TMPD/body" "$_t" || _ok=0
	fi
	if [ "$_ok" != 1 ]; then
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
	prune_stale "$_t"
	write_names "$_t"
	_tot=$((N_NEW+N_CHG+N_SAME))
	say "  серверов $_tot (новых $N_NEW, изменено $N_CHG, снято $N_DEL, пропущено $((N_SKIP+N_BAD)))$([ "$N_CUT" = 1 ] && printf ', обрезано по капу %s' "$MAXSRV")"
	CH_TOTAL=$((CH_TOTAL+N_NEW+N_CHG+N_DEL))
	SRV_TOTAL=$((SRV_TOTAL+_tot))
	SUMMARY="$SUMMARY«$_lab»: серверов $_tot (новых $N_NEW, изменено $N_CHG, снято $N_DEL). "
	if [ -n "$ACT_GONE" ]; then
		for _ag in $ACT_GONE; do
			say "  ВНИМАНИЕ: активный сервер «$_ag» исчез из подписки — конфиг ОСТАВЛЕН"
			ev "subs-active-gone" 21600 "Активный сервер исчез из подписки" \
				"Сервер «$_ag» больше не приходит в подписке «$_lab». Конфиг на роутере оставлен (несущую по расписанию не рвём) — выберите другой сервер в панели."
		done
	fi
	refresh_active
	return 0
}

# --- вербы ------------------------------------------------------------------
cmd_update() {
	_one="$1"
	[ -f "$ENODIA_STATE/.subs" ] || { say "подписок нет (.subs пуст)"; return 0; }
	# место на флеше: конфиги подписки пишутся на /data, а переполнение UBIFS роняет DNS и туннель
	_free=$(df -k "$ENODIA_DIR" 2>/dev/null | awk 'NR==2{print $4+0}')
	if [ -n "$_free" ] && [ "$_free" -lt "$MINFREE_KB" ]; then
		say "мало места на /data (${_free} КБ) — обновление подписок отменено"
		ev "subs-nospace" 21600 "Нет места для обновления подписок" \
			"На /data свободно ${_free} КБ — обновление подписок отменено, чтобы не переполнить флеш."
		return 1
	fi
	mkdir -p "$CFGDIR" "$HY2DIR" 2>/dev/null
	CH_TOTAL=0; SRV_TOTAL=0; FAILED=0; DONE=0; SUMMARY=""
	# Список тегов снимаем ОДИН раз в файл: busybox sh без `local`, и вложенные функции
	# (update_one → parse_links → name_for) переиспользуют `_t` — цикл по подстановке
	# затирался бы изнутри собственного тела.
	sub_tags > "$TMPD/tags" 2>/dev/null
	while IFS= read -r _tg || [ -n "$_tg" ]; do
		case "$_tg" in ''|*[!a-z0-9-]*) continue ;; esac
		[ -n "$_one" ] && [ "$_one" != "$_tg" ] && continue
		update_one "$_tg" && DONE=$((DONE+1))
	done < "$TMPD/tags"
	[ -n "$_one" ] && [ "$DONE" = 0 ] && [ "$FAILED" = 0 ] && say "подписка «$_one» не найдена в реестре"
	if [ "$CH_TOTAL" -gt 0 ]; then
		ev_log "subs-update" 300 "Подписки обновлены" "$SUMMARY"
	fi
	# Отметка последнего прогона для панели («обновлено N минут назад») — ts⇥итог⇥сводка.
	# Пишем РАЗ за прогон: /data — флеш, а cron ходит сюда каждые несколько часов.
	printf '%s\t%s\t%s\n' "$(date +%s 2>/dev/null)" \
		"$([ "$FAILED" -gt 0 ] && echo fail || echo ok)" \
		"$(printf '%s' "${SUMMARY:-нет подписок}" | sub_sum_cut 1000)" \
		> "$ENODIA_STATE/.subs-last" 2>/dev/null
	if [ "$FAILED" -gt 0 ] && [ "$DONE" = 0 ]; then
		ev "subs-fail" 21600 "Подписки не обновились" \
			"Ни одна подписка не скачалась ($FAILED шт.). Проверьте интернет и ссылки подписок в панели."
		return 1
	fi
	return 0
}

cmd_fetch() {
	_t="$1"
	case "$_t" in ''|*[!a-z0-9-]*) echo "плохая метка подписки" >&2; return 1 ;; esac
	_url=$(sub_url_of "$_t")
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
	if ! sub_fetch "$_url" "$TMPD/body"; then
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
	parse_any "$1" || { echo "не разобрал ссылку" >&2; return 1; }
	is_host "$P_HOST" && is_port "$P_PORT" || { echo "плохой адрес или порт в ссылке" >&2; return 1; }
	if [ "$P_PROTO" = hy2 ]; then emit_hy2; else emit_cfg; fi
}

cmd_list() {
	[ -f "$ENODIA_STATE/.subs" ] || { echo "подписок нет"; return 0; }
	for _t in $(sub_tags); do
		_n=0
		# Считаем ОБА семейства: подписка бывает смешанной, и «серверов 0» при живых
		# hy2-конфигах читалось бы как «подписка сломалась».
		for _clf in xray hy2; do
			fam_set "$_clf"
			for _f in "$FAM_DIR"/sub-"$_t"-*."$FAM_EXT"; do
				[ -e "$_f" ] || continue
				[ "$(sub_owner_tag "$(basename "$_f" ".$FAM_EXT")")" = "$_t" ] && _n=$((_n+1))
			done
		done
		printf '%s\t%s\t%s\n' "$_t" "$(sub_label_of "$_t")" "$_n"
	done
}

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
			# Пустой `_lt` (нет `date -r` в этой сборке) обязан значить «СЧИТАЕМ СВЕЖИМ», как и было:
			# age_since на пустом отдаёт 999999, то есть «протух» — и мы снесли бы ЖИВОЙ лок ровно
			# там, где абзац выше это запрещает.
			_lt=$(date -r "$LOCK" +%s 2>/dev/null)
			case "$_lt" in ''|*[!0-9]*) _lt="" ;; esac
			if [ -z "$_lt" ] || [ "$(age_since "$_lt")" -lt 1800 ]; then
				say "лок обновления подписок свежий, но без pid — жду следующего запуска"
				return 1
			fi
		fi
		say "лок обновления подписок протух — перехватываю"
		rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || return 1
	fi
	echo $$ > "$LOCK/pid" 2>/dev/null
	SUBS_LOCK_MINE=1
	return 0
}
drop_lock() { rm -rf "$LOCK" 2>/dev/null; SUBS_LOCK_MINE=0; }

# Лог в /tmp (RAM, ротации в проекте нет) — но подрезаем, чтобы частый cron не съел память.
trim_log() {
	[ -f "$LOG" ] || return 0
	_sz=$(wc -c < "$LOG" 2>/dev/null); [ -n "$_sz" ] || return 0
	[ "$_sz" -lt 131072 ] && return 0
	tail -n 300 "$LOG" > "$LOG.new" 2>/dev/null && mv "$LOG.new" "$LOG" 2>/dev/null
}

mkdir -p "$TMPD" 2>/dev/null
# PIPE/HUP в списке не для красоты: прогон пишет прогресс в stdout, и оборванный читатель
# (панель закрыла трубу, `| head`) убивает нас сигналом — EXIT-ловушка тогда не срабатывает,
# и каталог остаётся в /tmp, то есть в ОЗУ. Замерено на живом роутере: такой каталог (тогда он звался
# /tmp/enodia-subs-update.7007) пережил обрыв и не убирался ничем. Сигнал — ВЫХОД (C121): ловушка без
# `exit` убирала каталог, а прогон шёл дальше — уже без него.
# Свой лок — тоже здесь: строку `drop_lock` после cmd_update выход по сигналу пропускает.
SUBS_LOCK_MINE=0
trap 'rm -rf "$TMPD" 2>/dev/null; [ "$SUBS_LOCK_MINE" = 1 ] && drop_lock' EXIT
trap 'exit 1' INT TERM HUP PIPE
trim_log

case "$1" in
	update|"")
		take_lock || exit 0
		cmd_update "$2"; rc=$?
		drop_lock
		exit $rc ;;
	fetch) cmd_fetch "$2" ;;
	list)  cmd_list ;;
	parse) cmd_parse "$2" ;;
	*)
		echo "usage: subs-update.sh update [tag] | fetch <tag> | list | parse <ссылка>" >&2
		echo "       расписание — update-sched.sh set subs <off|6h|12h|daily|weekly>" >&2
		exit 1 ;;
esac
