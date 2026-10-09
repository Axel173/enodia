#!/bin/sh
# geo.sh — GEO-КАТЕГОРИИ: страны, сервисы и «заблокировано в РФ» → в VPN / мимо VPN / БЛОК.
#
# ЗАЧЕМ. Пользователь v2rayNG привык к geosite/geoip: «Google → в VPN», «страна RU → мимо».
# У нас роутинг ЯДРОМ (iptables MARK по ipset), а не xray-роутером — поэтому упакованный .dat
# (protobuf, читает только xray-core) не годится. Берём ТЕ ЖЕ данные в ТЕКСТЕ и кладём на НАШИ
# рельсы. Для пользователя — знакомый опыт: каталог категорий с выбором действия; под капотом —
# те же примитивы, что у групп/менеджера списков.
#
# ДВА ВИДА ИСТОЧНИКА (kind в каталоге), архитектура как в v2ray:
#   • cidr   — страны (geoip/ipdeny = весь пул IP страны) и «заблок-в-РФ» (runetfreedom geoip).
#              CIDR льём в ipset → mark-core метит / apply-bypass ACCEPT'ит / цепочка DROP'ает.
#   • domain — СЕРВИСЫ (geosite: Netflix/YouTube/Discord/… ловятся ЦЕЛИКОМ по доменам, а не по
#              обрывочным заблокированным диапазонам). Домены НЕ резолвим в снимок — пишем dnsmasq
#              `ipset=/дом/geo_vpn|geo_out` (маршрут: dnsmasq сам кладёт живой A-адрес в сет —
#              динамика, а не фотография) либо `address=/дом/0.0.0.0` (блок). Рельсы — те же сеты.
#
# ПРОВАЙДЕРЫ (реестр на тип, выбор персист). Один тип может отдаваться разными проектами: сервисы —
# runetfreedom-geosite (RU-блокировки, плоские) ИЛИ v2fly (глобальный, с include-рекурсией); страны —
# ipdeny; заблок-в-РФ — runetfreedom-geoip. Пользователь выбирает провайдера из дропдауна; рядом
# показываем дату последнего апстрим-коммита (видно заброшенный проект). Смена провайдера сервисов
# меняет НАБОР ключей каталога (у каждого провайдера свой) — выбор действия хранится per-key, поэтому
# переключение туда-обратно возвращает прежние отметки.
#
# АРХИТЕКТУРА — кладём на СУЩЕСТВУЮЩИЕ рельсы, нового слоя маршрутизации НЕ вводим (как groups.sh):
#   Каталог (catalog_lines) = курируемый список { тип: blocked|service|country, ключ, имя, kind, URL }.
#   Пользователь выбирает ДЕЙСТВИЕ на элемент: vpn | bypass | block | off (по умолч. off).
#   Реестр (actions.tsv на /data, переживает ребут) = выбор действия + доп-выход:
#   key<TAB>action<TAB>cnt<TAB>ts<TAB>slot. slot (Ф1b, зеркало groups.sh) — доп-ВЫХОД категории:
#   0 = основной (geo_vpn как раньше), 2..7 = слот (geo_vpn_s<N>, метит mark-core / врайрит
#   zapret-слот); ТОЛЬКО для action=vpn. Поле ПОСЛЕДНЕЕ — cut -f2..4 и awk $3/$4 не задеты.
#   URL/имя/тип/kind берём из каталога по ключу (каталог — источник истины по источникам).
#   Все включённые CIDR-элементы сводятся в ТРИ ipset (geo_vpn/geo_out/geo_block); все включённые
#   ДОМЕН-элементы — в dnsmasq-conf (маршрут 11-geo.conf, блок 12-geo-block.conf). Оба питают ОДНИ
#   и те же сеты/цепочки, что уже проведены в mark-core.sh / apply-bypass.sh / ENODIA_GEOBLK.
#
# DRY. Примитивы (fetch_url с DoH-фолбэком, norm_cidr, ipset_count, strip_bogon, ensure_allow_set)
# сорсим из lists-lib.sh. Домен-нормализация (norm_geosite) и v2fly-резолвер живут тут (специфика
# geosite-формата). Пересборка наборов — общий set-lib.sh (одна копия с groups.sh).
#
# ХРАНЕНИЕ. Кэш фетча каждого ключа — в ОЗУ (/tmp/enodia-geo/cache/<key>; на ребуте перекачаем). СНИМКИ
# агрегатов (CIDR-сеты + доменные dnsmasq-conf) — на ФЛЕШЕ (geo/.snap-*) с КАПОМ MAX_FLASH_CIDR:
# маршрутизация обязана пережить ОФЛАЙН-ребут. На буте heal.sh зовёт reapply (офлайн из снимков) +
# фоновый update (перекачка + свежесть апстрима).
#
# ГРАБЛИ (busybox — см. карту проекта): grep -c на нуле = код 1 (всегда case-гардим число); awk без
# split/index; dnsmasq ipset=/дом/geo_vpn ТРЕБУЕТ существующий сет ДО рестарта (иначе демон ругается);
# ipset=-строки dnsmasq не перечитывает по SIGHUP → рестарт; conf в ЖИВОЙ /tmp/dnsmasq.d (не /etc:
# стоковый init аддитивно копирует /etc→/tmp без чистки — выключенная категория воскресала бы).

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
command -v ct_flush >/dev/null 2>&1 || ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
# fetch_url, norm_cidr, ipset_count, strip_bogon, ensure_allow_set, MAX_FLASH_CIDR, TAB.
# Сорсим ТОЛЬКО под `[ -f ]` (инвариант проекта): провалившийся `.` в ash — фатальная ошибка
# спецбилтина, шелл выходит НА МЕСТЕ с кодом 2, и никакой `|| true` этого не ловит. Библиотека тут
# НЕ опциональна (шима нет и быть не может — половина файла на ней), поэтому вместо тихой смерти
# отказываем ЧЕСТНО. Особая цена молчания: отсюда же приходит $TAB, а с пустым TAB `grep "^$k$TAB"`
# вырождается в ПРЕФИКСНЫЙ матч ключей реестра (v2fly-meta нашёл бы v2fly-meta-cdn).
if [ -f "$ENODIA_DIR/lists-lib.sh" ]; then
	. "$ENODIA_DIR/lists-lib.sh"
else
	echo "geo: нет $ENODIA_DIR/lists-lib.sh — обновите установку (панель → «Обновление» или переустановка с компьютера)" >&2
	exit 1
fi
# Где лежит бинарь (store-lib.sh): с накопителем nfqws живёт НЕ в $ENODIA_DIR, и проверка по прежнему
# пути врала бы панели «zapret не установлен» (ровно тот класс, что чинили в CGI, коммит 26263af).
# Нет lib — шим отдаёт прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }

GEO="$ENODIA_STATE/geo"       # ПЕРСИСТ на флеше: реестр действий/провайдеров + снимки агрегатов
REG="$GEO/actions.tsv"
PROV="$GEO/providers.tsv"     # выбор провайдера на тип: type<TAB>pid (дормант — оставлен на возможный возврат)
SHAS="$GEO/.shas"             # SHA-пиновка фетча: repo_id<TAB>sha<TAB>upstream_iso (иммутабельный jsDelivr — убирает 12ч-эдж-лаг)
RAM="/tmp/enodia-geo"         # ОЗУ: кэш фетча + рабочие файлы + состояние обновления
CACHE="$RAM/cache"
GEO_LOCK="$RAM/.build.lock"   # сериализация сборки (apply/update/provider-set) — ls_lock_take
GEO_DIRTY="$RAM/.build.dirty" # «пока собирали, попросили ещё раз»; содержимое = запрошенный refetch (0|1)
SET_VPN=geo_vpn
SET_OUT=geo_out
SET_BLK=geo_block
# Четвёртое действие — «в десинк»: категория едет НАПРЯМУЮ, но её рукопожатия ломает nfqws. Пул
# отдельный (не zapret_set категорий и не zapret_dom «своих» источников) ради ВЛАДЕНИЯ: собирает и
# чистит его ТОЛЬКО гео, zapret лишь вешает правила циклом по ZAPRET_SETS («новый пул = одно слово»).
SET_DSY=geo_zapret
SNAP_VPN="$GEO/.snap-vpn"                 # флеш-снимки CIDR-агрегатов
SNAP_OUT="$GEO/.snap-out"
SNAP_BLK="$GEO/.snap-blk"
SNAP_DSY="$GEO/.snap-dsy"
DNSCONF=/tmp/dnsmasq.d/11-geo.conf        # ЖИВОЙ conf: ipset=/дом/geo_vpn|geo_out (маршрут доменов)
DNSBLK=/tmp/dnsmasq.d/12-geo-block.conf   # ЖИВОЙ conf: address=/дом/0.0.0.0 (блок доменов; отдельно от adblock/ipblock)
SNAP_DNS="$GEO/.snap-dns"                 # флеш-снимки доменных conf (офлайн-ребут переживает)
SNAP_DNSBLK="$GEO/.snap-dnsblk"
V2CAT_SNAP="$GEO/.cat-v2fly"              # флеш-снимок ПЕРЕЧИСЛЕНИЯ категорий v2fly (свежий, с апстрима)
V2CAT_BAKED="$ENODIA_DIR/geo-v2fly-catalog.txt"  # baked-фолбэк в комплекте скриптов (панель не пуста до первого update/офлайн)
V2CAT_URL='https://data.jsdelivr.com/v1/packages/gh/v2fly/domain-list-community@master?structure=flat'  # листинг data/<категория>
# runetfreedom «заблокировано в РФ»: geoip (CIDR по категориям) + geosite (домены). Каталог КАТЕГОРИЙ — из
# baked-файла в комплекте (geo-*-catalog.txt): jsDelivr data-API перечислить репо НЕ может (geoip >50 МБ из-за
# .dat/.mmdb → data-API отвечает 403 "Package size exceeded 50 MB"), а набор категорий runetfreedom практически
# статичен (ISO-коды стран + фиксированный блок/сервис-набор) ⇒ baked-снимка достаточно, панель не пуста
# офлайн. Свежие ДАННЫЕ тянутся по SHA-пину (cat_url → $RF/$RF_GEOSITE). SNAP-переменные оставлены на будущее
# (при желании перечислять — через GitHub tree API @sha, он не имеет 50-МБ лимита; сейчас не нужно).
RFIP_SNAP="$GEO/.cat-rfip"; RFIP_BAKED="$ENODIA_DIR/geo-rfip-catalog.txt"
RFGS_SNAP="$GEO/.cat-rfgs"; RFGS_BAKED="$ENODIA_DIR/geo-rfgs-catalog.txt"
# Версия ЛОГИКИ РЕЗОЛВЕРА доменов (fetch_v2fly/norm_geosite). Доменный кэш (RAM) и флеш-снимок keyed
# ТОЛЬКО по имени ключа → после смены логики резолвера они молча устаревают (напр. до v2 include:X @attr
# тянул весь X, category-ads-all блокировал apex google.com). Первый do_build после смены версии ФОРСИТ
# refetch и чинит разом и RAM-кэш, и флеш-снимок. БАМПАТЬ при ЛЮБОЙ правке fetch_v2fly/norm_geosite.
RESOLVER_VER=2
RVER="$GEO/.rver"                         # последняя применённая версия резолвера (флеш)

mkdir -p "$GEO" "$CACHE" 2>/dev/null
[ -f "$REG" ] || : > "$REG"

# --- ИСТОЧНИКИ (базовые URL, SHA-пиновка) -------------------------------------------
# Фетч ДАННЫХ пиновим на КОММИТ (@<sha>), а не на мутабельную ветку (@release/@master): эджи jsDelivr
# кэшируют изменяемую ветку до 12ч (s-maxage=43200) ⇒ «апстрим обновился 2ч назад», а данные ещё старые,
# метка свежести расходится с реальностью. @<sha> иммутабелен И свеж (SHA из GitHub API коммита — реалтайм).
# SHA кладём в $SHAS (resolve_upstream при update/freshness); jsd_ref подставляет @<sha> либо @<ветка>
# (фолбэк на первый запуск / провал API). URL — globals, пересобираем set_source_urls'ом (cat_url их читает).
jsd_ref() {   # jsd_ref <repo_id> <ветка-фолбэк> → "@<sha>" (если известен) или "@<ветка>"
	_s=$(grep "^$1$TAB" "$SHAS" 2>/dev/null | head -1 | cut -f2)
	case "$_s" in [0-9a-f][0-9a-f]*) printf '@%s' "$_s" ;; *) printf '@%s' "$2" ;; esac
}
set_source_urls() {   # (пере)собрать пиновку в globals — на старте (из прежнего $SHAS) и после resolve_upstream
	RF="https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geoip$(jsd_ref rfip release)/text"       # CIDR РКН (geoip, per-category)
	RF_GEOSITE="https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite$(jsd_ref rfgs release)"   # домены РКН (geosite, плоские domain:/full:)
	V2FLY="https://cdn.jsdelivr.net/gh/v2fly/domain-list-community$(jsd_ref v2fly master)/data"           # домены v2fly (include-рекурсия)
}
set_source_urls
IPDENY='https://www.ipdeny.com/ipblocks/data/aggregated'                                  # CIDR стран (весь пул IP страны; дормант — из панели выведено)

# --- РЕЕСТР ПРОВАЙДЕРОВ (на тип; курируемый) ----------------------------------------
# type|pid|label|freshness_url  — freshness_url = GitHub API последнего коммита (пусто = без даты).
# Первый provider типа = дефолт. Выбор персист в PROV; смена меняет каталог ключей типа.
# v2fly ПЕРВЫЙ (дефолт) — полный глобальный geosite (~1400 категорий); rf-geosite = узкий RU-срез.
provider_lines() {
	cat <<EOF
service|v2fly|v2fly community (глобальный)|https://api.github.com/repos/v2fly/domain-list-community/commits/master
service|rf-geosite|runetfreedom (RU-блокировки)|https://api.github.com/repos/runetfreedom/russia-blocked-geosite/commits/release
country|ipdeny|ipdeny.com|
blocked|rf-geoip|runetfreedom (РКН)|https://api.github.com/repos/runetfreedom/russia-blocked-geoip/commits/release
EOF
}
provider_default() { provider_lines | awk -F'|' -v t="$1" '$1==t{print $2; exit}'; }
provider_get() {   # provider_get <type> → выбранный pid (валидный) или дефолт
	_p=$(grep "^$1$TAB" "$PROV" 2>/dev/null | head -1 | cut -f2)
	if [ -n "$_p" ] && provider_lines | grep -q "^$1|$_p|"; then printf '%s' "$_p"; return; fi
	provider_default "$1"
}
provider_set() {   # provider_set <type> <pid> → валидация + персист
	provider_lines | grep -q "^$1|$2|" || { echo "неизвестный провайдер: $1/$2"; return 1; }
	grep -v "^$1$TAB" "$PROV" 2>/dev/null > "$PROV.new"
	printf '%s\t%s\n' "$1" "$2" >> "$PROV.new"
	mv "$PROV.new" "$PROV"
}
prov_fresh_url() { provider_lines | awk -F'|' -v t="$1" -v p="$2" '$1==t&&$2==p{print $4; exit}'; }

# --- КАТАЛОГ гео-элементов (курируемый; поля через |) -------------------------------
# type|key|label|kind|url|approx|desc
#   type  — blocked | service | country (для вкладок панели);
#   key   — уникальный ключ элемента (он же имя cache-файла и строки реестра);
#   kind  — cidr | domain (cidr → ipset; domain → dnsmasq ipset=/address=);
#   url   — CDN-источник (для domain-v2fly = маркер «v2fly:<имя>», резолвится спец-фетчем);
#   approx— примерный размер для UI-бюджета; desc — короткое пояснение.
#
# ИСТОЧНИКИ проверены на роутере 2026-07-18 (живые). geoip: runetfreedom @release/text (per-category,
# автообновл. 6ч) + ipdeny aggregated (весь пул страны). geosite (домены): runetfreedom @release
# (плоские full:/domain:) + v2fly (include-рекурсия, ~1000+ файлов). ЗАБРАКОВАНЫ: opencck per-site=0,
# country-ip-blocks=404/таймаут. Мёртвый ключ страховки ради не роняет остальные (update пропускает
# источник без строк).

# СТРАНЫ: полный ISO 3166-1 alpha-2 -> ipdeny aggregated zone (весь пул IP страны). Имена СЫРЫЕ =
# код страны как в data-файле `<cc>-aggregated.zone` (просьба пользователя «пусть все будет сырым» —
# без курируемых русских названий). Список кодов статичен (перечисление ipdeny не нужно): мёртвый код
# (у территории нет IP-блока) безвреден — fetch пуст -> 0 адр., build пропустит, в панели «—».
country_codes() {
	cat <<'EOF'
ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bv bw by bz ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg eh er es et fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sj sk sl sm sn so sr ss st sv sx sy sz tc td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug um us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw
EOF
}
country_lines() {
	for _cc in $(country_codes); do
		[ -n "$_cc" ] || continue
		printf 'country|%s|%s|cidr|%s/%s-aggregated.zone||IP-пул страны (ipdeny)\n' \
			"$_cc" "$_cc" "$IPDENY" "$_cc"
	done
}

# ЗАБЛОКИРОВАНО В РФ (runetfreedom) — ПОЛНЫЙ каталог, ОБА вида: geoip (CIDR, per-category) + geosite
# (домены). Перечисление динамическое (снимок с апстрима ∨ baked-фолбэк), лейблы СЫРЫЕ = имя файла
# категории (как v2fly). geoip text/ содержит и коды стран (ad/ae/…ru/us ~245), и осмысленные категории
# (ru-blocked/re-filter/сервисы) — отдаём ВСЁ (просьба «буквально всё»); коды стран панель прячет как
# служебные (regex rfip-<2буквы>). Ключи rfip-<имя> (CIDR) / rfgs-<имя> (домены) — резолв в cat_* ниже.
_blk_rfip() {
	_src="$RFIP_SNAP"; [ -s "$_src" ] || _src="$RFIP_BAKED"; [ -s "$_src" ] || return 0
	tr -d '\r' < "$_src" | while IFS= read -r _n; do
		[ -n "$_n" ] || continue
		printf 'blocked|rfip-%s|%s|cidr|%s/%s.txt|—|runetfreedom geoip: %s\n' "$_n" "$_n" "$RF" "$_n" "$_n"
	done
}
_blk_rfgs() {
	_src="$RFGS_SNAP"; [ -s "$_src" ] || _src="$RFGS_BAKED"; [ -s "$_src" ] || return 0
	tr -d '\r' < "$_src" | while IFS= read -r _n; do
		[ -n "$_n" ] || continue
		printf 'blocked|rfgs-%s|%s|domain|%s/%s.txt|—|runetfreedom geosite: %s\n' "$_n" "$_n" "$RF_GEOSITE" "$_n" "$_n"
	done
}
blocked_lines() { _blk_rfip; _blk_rfgs; }

# СЕРВИСЫ (провайдер-зависимо; kind=domain). Каталог ключей зависит от выбранного service-провайдера.
# Лейблы СЫРЫЕ = имя категории как в data-файле (без «(домены)» и курируемых названий — просьба
# пользователя). Эскейп JSON не нужен: имена geosite в наборе [a-z0-9._!-].
# Источник сервисов — ТОЛЬКО v2fly (панель без дропдаунов провайдера, решение юзера 2026-07-19
# «пока единственный источник — v2fly»). _svc_rf и provider-машинерия оставлены для возможного
# возврата, но каталог их больше не отдаёт (даже при стухшем PROV=rf-geosite).
svc_lines() { _svc_v2fly; }
# runetfreedom-geosite: плоские файлы <имя>.txt (full:/domain:), без include. Ключ rf-<имя>, лейбл сырой.
_svc_rf() {
	for _n in youtube google discord; do
		printf 'service|rf-%s|%s|domain|%s/%s.txt|—|geosite runetfreedom: %s\n' \
			"$_n" "$_n" "$RF_GEOSITE" "$_n" "$_n"
	done
}
# v2fly: ПОЛНОЕ перечисление data/<имя> (~1400 категорий). Источник имён — свежий снимок с апстрима
# (V2CAT_SNAP), иначе baked-фолбэк в комплекте (V2CAT_BAKED) — панель не пуста до первого update/офлайн.
# Ключ v2fly-<имя>, url-маркер «v2fly:<имя>» (резолвится fetch_v2fly с include-рекурсией). Лейбл сырой.
# Печать — printf-builtin в цикле (без форков на элемент); \r чистим (baked-файл мог доехать с CRLF).
_svc_v2fly() {
	_src="$V2CAT_SNAP"; [ -s "$_src" ] || _src="$V2CAT_BAKED"
	[ -s "$_src" ] || return 0
	tr -d '\r' < "$_src" | while IFS= read -r _n; do
		[ -n "$_n" ] || continue
		printf 'service|v2fly-%s|%s|domain|v2fly:%s|—|geosite v2fly: %s\n' "$_n" "$_n" "$_n" "$_n"
	done
}

# ТРИ источника каталога: v2fly-geosite (сервисы/категории, ~1381 домен-файл) + runetfreedom «заблок-в-РФ»
# (geoip-CIDR + geosite-домены) + страны-CIDR (ipdeny, ВЕСЬ пул IP страны).
# СТРАНЫ ВЕРНУЛИ В ПАНЕЛЬ: их выводили как «редко нужные» (dev21), но это верно лишь для модели «по
# умолчанию напрямую, список блокировок — в VPN». В ПЕРЕВЁРНУТОЙ модели («полный туннель», а RU+CN
# напрямую) страна — ЦЕНТРАЛЬНАЯ сущность, и настраивать её только из CLI нельзя. Рельсы cat_url всё
# это время были целы, скрыт был ровно каталог.
# Ключи уникальны по префиксу (v2fly-/rfip-/rfgs-/rf-/2-букв) ⇒ cat_type/cat_kind/cat_url резолвят их
# за O(1) без скана каталога. ВНИМАНИЕ: у страны `ru` и у runetfreedom-категории `rfip-ru` ОДИНАКОВЫЙ
# лейбл (`ru`) — это РАЗНЫЕ наборы (весь пул страны против «заблокированного в РФ»), различает их
# поле desc и вкладка «Страны» в панели.
catalog_lines() {
	svc_lines            # v2fly geosite (сервисы/категории, домены)
	blocked_lines        # runetfreedom «заблок-в-РФ»: geoip (CIDR) + geosite (домены)
	country_lines        # страны-CIDR (ipdeny): весь пул IP страны — вкладка «Страны»
}
# Резолв URL/типа/kind ключа — ПАТТЕРНОМ по префиксу (не сканом каталога): do_build/ensure_cache
# резолвят включённый ключ за O(1), полностью офлайн и НЕЗАВИСИМО от выбранного провайдера (уходит
# прежний костыль catalog_lines_all — при 1400 v2fly-строках его скан на каждый ключ был бы дорог).
# Ключи уникальны по префиксу: v2fly-*/rf-* = сервис-домены; ru-blocked|re-filter|ru-blocked-community
# = заблок-CIDR; двухбуквенный код = страна-CIDR (ipdeny). Это ЕДИНСТВЕННЫЙ источник истины по
# источнику ключа — совпадает со схемой имён в catalog_lines/country_lines/_svc_* выше.
cat_type() {
	case "$1" in
		rfip-*|rfgs-*|ru-blocked|re-filter|ru-blocked-community) echo blocked ;;
		v2fly-*|rf-*) echo service ;;
		??) echo country ;;
		*) echo '' ;;
	esac
}
# kind — ПАТТЕРНОМ (не через cat_type): blocked теперь смешанный (rfip=CIDR, rfgs=домены).
cat_kind() {
	case "$1" in
		v2fly-*|rf-*|rfgs-*) echo domain ;;
		rfip-*|ru-blocked|re-filter|ru-blocked-community|??) echo cidr ;;
		*) echo '' ;;
	esac
}
# ПОДПИСЬ ключа — тем же паттерном (для `active`, который каталог не читает): лейблы каталога СЫРЫЕ, то есть
# это имя категории без префикса источника (схема `catalog_lines` выше). Держим рядом с cat_type/cat_kind —
# схема имён одна, и третья её копия в чужом месте разъехалась бы с этими двумя.
cat_label() {
	case "$1" in
		v2fly-*) echo "${1#v2fly-}" ;;
		rfip-*)  echo "${1#rfip-}" ;;
		rfgs-*)  echo "${1#rfgs-}" ;;
		rf-*)    echo "${1#rf-}" ;;
		*)       echo "$1" ;;
	esac
}
cat_url() {
	case "$1" in
		v2fly-*) echo "v2fly:${1#v2fly-}" ;;
		rfip-*)  echo "$RF/${1#rfip-}.txt" ;;
		rfgs-*)  echo "$RF_GEOSITE/${1#rfgs-}.txt" ;;
		rf-*)    echo "$RF_GEOSITE/${1#rf-}.txt" ;;
		ru-blocked)           echo "$RF/ru-blocked.txt" ;;
		re-filter)            echo "$RF/re-filter.txt" ;;
		ru-blocked-community) echo "$RF/ru-blocked-community.txt" ;;
		??)      echo "$IPDENY/$1-aggregated.zone" ;;
		*) echo '' ;;
	esac
}
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- реестр действий (TSV на /data): key<TAB>action<TAB>cnt<TAB>ts ------------------
reg_get()    { grep "^$1$TAB" "$REG" 2>/dev/null | head -1; }
reg_action() { reg_get "$1" | cut -f2; }
reg_write()  { cat > "$REG.new" && mv "$REG.new" "$REG"; }   # атомарно (обрыв не бьёт файл)
# reg_set <key> <action>: upsert строки. off — строку УБИРАЕМ (нет строки = нет действия).
reg_set() {
	_k="$1"; _a="$2"
	# сохраняем прежние cnt/ts, если строка была (чтобы UI не мигал нулём до следующего update)
	_old=$(reg_get "$_k"); _c=$(printf '%s' "$_old" | cut -f3); _t=$(printf '%s' "$_old" | cut -f4)
	case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
	case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
	# slot переживает смену действия ТОЛЬКО пока действие vpn (слот применим лишь к «в VPN»);
	# уход в bypass/block сбрасывает в 0 — вернувшись в vpn, юзер выбирает выход заново.
	_s=$(printf '%s' "$_old" | cut -f5)
	case "$_s" in [2-7]) ;; *) _s=0 ;; esac
	[ "$_a" = vpn ] || _s=0
	grep -v "^$_k$TAB" "$REG" 2>/dev/null > "$REG.tmp"
	[ "$_a" = off ] || printf '%s\t%s\t%s\t%s\t%s\n' "$_k" "$_a" "$_c" "$_t" "$_s" >> "$REG.tmp"
	mv "$REG.tmp" "$REG"
}
reg_set_meta() {  # reg_set_meta <key> <cnt> <ts>
	awk -F"$TAB" -v OFS="$TAB" -v k="$1" -v c="$2" -v t="$3" '$1==k{$3=c;$4=t} {print}' "$REG" > "$REG.new" 2>/dev/null && mv "$REG.new" "$REG"
}
# Миграция реестра 4-col → 5-col (slot добавлен ПОСЛЕДНИМ полем — прежние позиции не задеты).
# Идемпотентна (5-col строки проходят как есть), атомарна (tmp+mv); зеркало migrate_reg groups.sh.
migrate_reg() {
	[ -s "$REG" ] || return 0
	awk -F"$TAB" 'NF>0 && NF!=5{c=1} END{exit c?0:1}' "$REG" || return 0
	awk -F"$TAB" -v OFS="$TAB" 'NF==4{print $1,$2,$3,$4,"0"; next} NF>0{print}' "$REG" > "$REG.mig" \
		&& mv "$REG.mig" "$REG"
}
migrate_reg

# --- сеты -----------------------------------------------------------------------------
# Пересборка живёт в ОБЩЕМ слое set-lib.sh (одна копия на groups.sh и geo.sh; там же — почему
# нельзя пересобирать «с нуля из статики»: наборы наполняют ДВА источника, CIDR категорий и
# A-записи от dnsmasq по ipset=-строкам сервисных категорий).
# Гео-агрегаты на порядки крупнее групповых (страны — сотни тысяч подсетей) ⇒ свои параметры
# набора; слой читает их В МОМЕНТ ВЫЗОВА, поэтому порядок с source значения не имеет.
SET_HASHSIZE=4096
SET_MAXELEM=1000000
# Сорсим ТОЛЬКО под `[ -f ]`: провалившийся `.` в ash фатален — шелл выходит на месте.
if [ -f "$ENODIA_DIR/set-lib.sh" ]; then . "$ENODIA_DIR/set-lib.sh"; fi
# Шим на случай частичного apply-scripts: гео продолжает работать, но как до 03.08.2026 —
# динамика dnsmasq теряется на каждом apply (осознанная деградация, не мёртвый код).
if ! command -v set_sync >/dev/null 2>&1; then
	set_ensure() { ipset list -n 2>/dev/null | grep -qx "$1" || ipset create "$1" hash:net hashsize 4096 maxelem 1000000 2>/dev/null; }
	set_fill() {
		_s="$1"; _f="$2"
		set_ensure "$_s"
		ipset destroy "${_s}_new" 2>/dev/null
		ipset create "${_s}_new" hash:net hashsize 4096 maxelem 1000000 2>/dev/null || return 1
		if [ -s "$_f" ]; then
			awk -v s="${_s}_new" '/^[0-9]/{print "add " s " " $1}' "$_f" | ipset restore -exist 2>/dev/null
		fi
		ipset swap "${_s}_new" "$_s" 2>/dev/null
		ipset destroy "${_s}_new" 2>/dev/null
	}
	set_sync() { set_fill "$1" "$2"; }
fi
# Снимок агрегата на ФЛЕШ с капом (аномально большой — не раздуваем 20-МБ флеш; маршрутизация
# живёт в ipset/dnsmasq RAM и перекачается на буте). Мелкие страны/сервисы влезают.
snap_flash() {
	_dst="$1"; _src="$2"
	_ln=$(grep -c '' "$_src" 2>/dev/null); case "$_ln" in ''|*[!0-9]*) _ln=0 ;; esac
	if [ "$_ln" -gt "$MAX_FLASH_CIDR" ]; then
		echo "снимок гео на флеш пропущен: $_ln строк > лимита $MAX_FLASH_CIDR (маршрут в RAM работает, офлайн-ребут не переживёт)"
		# …и ТОЛЬКО `echo` тут мало. Пересборка почти всегда идёт ФОНОМ (`start-stop-daemon -b` в
		# heal.sh 5.13 и в цепочке импорта), а `-b` заворачивает stdout в /dev/null — то есть
		# единственное предупреждение о том, что после ребута категории не будет ~10 минут,
		# исчезало бесследно. Замерено 17.08 на AX3600: `category-ads-all` (148872 домена) →
		# `.snap-dnsblk` удалён, в логах об этом НИ СЛОВА. Дублируем в журнал событий — он и
		# заведён как «то, что случилось в фоне, а человек обязан увидеть»; свой лог гео не
		# заводим (это четвёртый реестр логов: RAM_LOGS, DUMP_LOGS и дамп). Схлопывание повторов
		# — сутки: пересборка бежит на каждом буте и по расписанию.
		if [ -f "$ENODIA_DIR/events.sh" ]; then
			sh "$ENODIA_DIR/events.sh" add geo-snap-skip 86400 \
				"Гео-категория не переживёт перезагрузку" \
				"Категория слишком велика для снимка на флеш ($_ln строк при лимите $MAX_FLASH_CIDR). Сейчас она работает, но после перезагрузки роутера начнёт действовать не сразу — сперва её нужно будет заново скачать (несколько минут). Уменьшить ожидание можно, отключив самые крупные категории." >/dev/null 2>&1
		fi
		rm -f "$_dst" 2>/dev/null; return 0
	fi
	cp "$_src" "$_dst" 2>/dev/null
}

# Перечитать dnsmasq — через агрегатор ipset=-строк (dns-merge.sh): домен гео-категории может
# быть назван и в группе, и в правиле устройства, а dnsmasq применяет к домену РОВНО ОДНУ строку.
# Нет агрегатора → прежний путь: рестарт (не SIGHUP — ipset=/address= по HUP не перечитываются).
dns_reload() { sh "$ENODIA_DIR/dns-merge.sh" reload 2>/dev/null \
	|| /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }

# Файл ПРОГРЕССА, который опрашивает панель, пишем АТОМАРНО (рядом + `mv`): `>` сперва обрезает, и опрос в это окно читал пусто —
# «кончилось» до конца (разбор у packages.sh::set_state; следит C105).
ustate() { { echo "$1" > "$RAM/.update.state.new" && mv -f "$RAM/.update.state.new" "$RAM/.update.state"; } 2>/dev/null; }
# uprogress <обработано> <в очереди> — счётчик долгой распаковки дерева include (см. fetch_v2fly).
# Пустые аргументы = «прогресса нет», файл убираем: панель тогда рисует обычное «обновляю…».
uprogress() {
	if [ -n "$1" ] && [ -n "$2" ]; then printf '%s\t%s\n' "$1" "$2" > "$RAM/.update.progress" 2>/dev/null
	else rm -f "$RAM/.update.progress" 2>/dev/null; fi
	return 0
}

# --- нормализация geosite-доменов ---------------------------------------------------
# Снять префиксы full:/domain:, отсеять regexp:/keyword:/include: и мусор, оставить голые домены.
# include: РЕЗОЛВИМ отдельно (fetch_v2fly), тут просто игнорим строку. @attr (напр. "youtube @cn")
# режется взятием первого токена ($1).
norm_geosite() {  # stdin (geosite-текст) → stdout (домен на строку)
	tr 'A-Z' 'a-z' | tr -d '\r' | awk '
		/^[[:space:]]*#/ {next}
		/^[[:space:]]*$/ {next}
		/^include:/ {next}
		/^regexp:/ {next}
		/^keyword:/ {next}
		{
			d=$1
			sub(/^full:/,"",d); sub(/^domain:/,"",d)
			# Метка ≤63 ({0,61} между граничными знаками) — тот же гард, что в lists-lib.sh:
			# geosite приезжает чужим файлом, а одна строка с длинной меткой роняет ВЕСЬ конфиг
			# dnsmasq (замер — в шапке dns-lib.sh::dom_ok).
			if (d ~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/) print d
		}'
}

# v2fly-резолвер include: ИТЕРАТИВНЫЙ + АТРИБУТ-AWARE (v2ray-семантика). Очередь = «имя<TAB>фильтр»,
# где фильтр — требуемый атрибут (@ads/@cn/…) или пусто. `include:X @a` = взять из X ТОЛЬКО записи с
# атрибутом @a (НЕ весь X!). Без этого `category-ads` через `include:google @ads` / `include:yandex @ads`
# затягивал ВЕСЬ google/yandex (включая apex google.com, yandex.ru, ya.ru) → блок category-ads-all
# ронял Google и Яндекс целиком (пойм. тестером 2026-07-19). Фильтр НАСЛЕДУЕТСЯ вниз по include:
# запись выживает, лишь если несёт требуемый атрибут на ЛЮБОЙ глубине (совпадает с dlc-компилятором
# v2fly). Без рекурсии (под-оболочка пайпа клоббит переменные) и без split/index/user-func (busybox-awk).
# Один awk-проход на файл: домены (D<TAB>дом, с учётом фильтра) + include-директивы (Q<TAB>имя<TAB>атрибут).
# seen ключуется по паре имя|фильтр (один файл под разными фильтрами = разные наборы). Кап — предохранитель.
# --- пачечная закачка include-файлов ------------------------------------------------
# ЗАМЕР на живом BE7000 18.08.2026: один запрос к jsDelivr стоит ~4.4 с ВНЕ ЗАВИСИМОСТИ ОТ РАЗМЕРА
# (файл 107 Б и файл 3378 Б — поровну), то есть платим за TLS-рукопожатие, а не за данные. Дерево
# `category-ads` раскрывается в ~183 файла ⇒ 13 из 15 минут сборки категории уходили в рукопожатия,
# и ВСЁ это время лок гео держит любые другие правки (в худшем случае, при потолке 800 итераций, —
# час). Лечится тем, что curl принимает несколько URL за один вызов и держит соединение открытым.
#
# `fetch_url` НЕ трогаем: это общий примитив с DoH-фолбэком и второй попыткой без сверки TLS
# (lists-lib.sh). Здесь — только БЫСТРЫЙ путь, а всё, что им не приехало, добирается ПОШТУЧНО
# через fetch_url, то есть ровно прежним поведением. Провал пачки целиком = просто медленный
# прогон, а не сломанная категория.

# v2_name_ok <имя> — имя категории приезжает из ЧУЖОГО файла и попадает в командную строку curl
# НЕЭКРАНИРОВАННЫМ (иначе пары «-o файл url» не собрать) ⇒ набор символов закрытый, тот же, которым
# чистится каталог в v2fly_enumerate. Всё остальное молча пропускаем.
v2_name_ok() { case "$1" in ''|*[!a-z0-9._!-]*) return 1 ;; esac; return 0; }

# v2_raw_dir — каталог сырых include-файлов, ключуется ПИНОМ коммита ($V2FLY несёт @sha): при том же
# пине содержимое файла неизменно, значит скачанное один раз годится и соседней категории (деревья
# пересекаются: `category-ads` ⊂ `category-ads-all`), и повторному apply. Каталог в ОЗУ вместе с
# остальным кэшем фетча — переживает прогон и соседние категории, но не ребут.
v2_raw_dir() {
	_vrk=$(printf '%s' "$V2FLY" | md5sum 2>/dev/null | cut -c1-8 | tr -cd 'a-f0-9')
	[ -n "$_vrk" ] || _vrk=nopin
	# Каталоги ПРОШЛЫХ пинов сносим: они уже никогда не понадобятся, а лежат в ОЗУ — на роутере
	# со 176 МБ это не «пустяк на /tmp», а прямой путь к тому же OOM, из-за которого мы держим
	# всё тяжёлое в RAM с оглядкой. Своей GC у кэша гео нет, так что чистим ровно за собой.
	for _vro in "$RAM"/.v2raw.*; do
		[ -d "$_vro" ] || continue
		[ "$_vro" = "$RAM/.v2raw.$_vrk" ] && continue
		rm -rf "$_vro" 2>/dev/null
	done
	printf '%s/.v2raw.%s' "$RAM" "$_vrk"
}

# v2_fetch_level <каталог> <файл-со-списком-имён> — докачать в каталог всё, чего там ещё нет.
# Пачками по 24: длина командной строки конечна, а разбивка ещё и ограничивает цену одного таймаута.
v2_fetch_level() {
	_vd="$1"; _vargs=""; _vn=0; _vgot="$RAM/.v2got.$$"; : > "$_vgot"
	while IFS= read -r _v || [ -n "$_v" ]; do
		[ -n "$_v" ] || continue
		[ -s "$_vd/$_v" ] && continue
		_vargs="$_vargs -o $_vd/$_v $V2FLY/$_v"
		echo "$_v" >> "$_vgot"
		_vn=$((_vn + 1))
		if [ "$_vn" -ge 24 ]; then
			curl -sfL --max-time 120 $_vargs >/dev/null 2>&1
			_vargs=""; _vn=0
		fi
	done < "$2"
	[ "$_vn" -gt 0 ] && curl -sfL --max-time 120 $_vargs >/dev/null 2>&1
	# ОБРЫВ ЗАКАЧКИ ОСТАВЛЯЕТ ФАЙЛ, КОТОРЫЙ ВЫГЛЯДИТ ЖИВЫМ. Пачка идёт одним curl'ом, её код
	# возврата относится к последнему переносу и всё равно проглочен, а половина файла на диске
	# непустая ⇒ разбор ниже возьмёт её гардом `[ -s ]` и не позовёт `fetch_url`. Категория молча
	# соберётся из огрызка, и это не разовая осечка: сырьё кэшируется ПО ПИНУ коммита, значит тем
	# же огрызком питаются соседние категории и все повторные apply до ребута.
	# Признак целого файла у ЭТОГО источника — хвостовой перевод строки (проверено на v2fly:
	# category-ads/youtube/google-scholar — все три кончаются им). `tail -c 1 | wc -l` busybox
	# умеет (проверено на BE7000). Огрызок удаляем: дальше он честно доедет поштучно через
	# fetch_url, то есть ровно прежним поведением.
	while IFS= read -r _v || [ -n "$_v" ]; do
		[ -n "$_v" ] || continue
		[ -s "$_vd/$_v" ] || continue
		[ "$(tail -c 1 "$_vd/$_v" 2>/dev/null | wc -l | tr -cd '0-9')" = 1 ] && continue
		rm -f "$_vd/$_v" 2>/dev/null
	done < "$_vgot"
	rm -f "$_vgot" 2>/dev/null
	return 0
}

fetch_v2fly() {  # fetch_v2fly <имя> <outfile>
	_seen="$RAM/.v2seen.$$"; _queue="$RAM/.v2q.$$"; : > "$_seen"; : > "$2"
	_vdir=$(v2_raw_dir); mkdir -p "$_vdir" 2>/dev/null
	printf '%s\t\n' "$1" > "$_queue"; _it=0
	while [ -s "$_queue" ]; do
		# Уровень BFS забираем ЦЕЛИКОМ и качаем одним заходом, потом разбираем по порядку.
		# Порядок обхода и содержимое результата прежние — меняется только число рукопожатий.
		mv "$_queue" "$_queue.lvl" 2>/dev/null; : > "$_queue"; : > "$_queue.names"
		while IFS= read -r _ln || [ -n "$_ln" ]; do
			_nm=${_ln%%"$TAB"*}
			v2_name_ok "$_nm" || continue
			grep -qxF "$_nm" "$_queue.names" 2>/dev/null || echo "$_nm" >> "$_queue.names"
		done < "$_queue.lvl"
		[ -s "$_queue.names" ] && v2_fetch_level "$_vdir" "$_queue.names"
		while IFS= read -r _ln || [ -n "$_ln" ]; do
			_it=$((_it + 1)); [ "$_it" -gt 800 ] && break
			_nm=${_ln%%"$TAB"*}; _req=${_ln#*"$TAB"}
			v2_name_ok "$_nm" || continue
			grep -qxF "$_nm|$_req" "$_seen" 2>/dev/null && continue
			echo "$_nm|$_req" >> "$_seen"
			_tf="$_vdir/$_nm"
			[ -s "$_tf" ] || fetch_url "$V2FLY/$_nm" "$_tf" || { rm -f "$_tf"; continue; }
			tr 'A-Z' 'a-z' < "$_tf" | tr -d '\r' | awk -v req="$_req" '
				/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
				/^include:/ {
					name=$1; sub(/^include:/,"",name)
					ia=""; if (NF>=2 && $2 ~ /^@/) { ia=$2; sub(/^@/,"",ia) }
					nr=req; if (req=="") nr=ia          # фильтр родителя пуст → берём фильтр include; иначе наследуем родителя
					print "Q\t" name "\t" nr; next
				}
				/^regexp:/ {next} /^keyword:/ {next}
				{
					d=$1; sub(/^full:/,"",d); sub(/^domain:/,"",d)
					# {0,61} = метка ≤63: одна длинная метка из ЧУЖОГО geosite роняет весь конфиг
					# dnsmasq (замер — в шапке dns-lib.sh::dom_ok). Второй проход того же гарда:
					# сюда домены приезжают мимо norm_geosite.
					if (d !~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/) next
					pass=(req=="")
					if (req!="") { for(i=2;i<=NF;i++) if($i=="@" req) pass=1 }
					if (pass) print "D\t" d
				}' > "$RAM/.v2p.$$"
			grep "^D$TAB" "$RAM/.v2p.$$" 2>/dev/null | cut -f2 >> "$2"
			grep "^Q$TAB" "$RAM/.v2p.$$" 2>/dev/null | cut -f2,3 >> "$_queue"
			rm -f "$RAM/.v2p.$$"
		done < "$_queue.lvl"
		[ "$_it" -gt 800 ] && break
		# Прогресс для панели: на 15-минутной операции «обновляю списки…» без цифр неотличимо
		# от зависшей. Обработано / осталось в очереди — ровно то, что у нас уже есть под рукой.
		uprogress "$(wc -l < "$_seen" 2>/dev/null | tr -cd '0-9')" "$(wc -l < "$_queue" 2>/dev/null | tr -cd '0-9')"
	done
	uprogress "" ""
	rm -f "$_seen" "$_queue" "$_queue.lvl" "$_queue.names"
}

# Перечисление ПОЛНОГО каталога v2fly: листинг data/<категория> через jsDelivr data-API → снимок имён
# на флеш (V2CAT_SNAP). Формат: "name": "/data/<имя>" (прямые файлы категорий — без вложенных слэшей).
# Провал сети НЕ трогает снимок (панель остаётся на прежнем/baked). Имена чистим до [a-z0-9._!-].
# Зовёт `update` (перекачка источников); отдельно НЕ трогаем на каждый list — каталог статичен.
v2fly_enumerate() {
	_tmp="$RAM/.v2list.$$"
	fetch_url "$V2CAT_URL" "$_tmp" || { rm -f "$_tmp" 2>/dev/null; return 0; }
	grep -oE '"/data/[^"/]+"' "$_tmp" 2>/dev/null | sed 's|"/data/||; s|"$||' \
		| grep -E '^[a-z0-9._!-]+$' | sort -u > "$_tmp.n"
	[ -s "$_tmp.n" ] && mv "$_tmp.n" "$V2CAT_SNAP"
	rm -f "$_tmp" "$_tmp.n" 2>/dev/null
}
# (runetfreedom-каталог не перечисляем в рантайме — baked-only, см. коммент у RFIP_SNAP выше: data-API 403
#  на >50-МБ репо, а набор категорий статичен.)

# ensure_cache <key>: гарантировать кэш ключа в ОЗУ (CIDR-строки ИЛИ домены — по kind). refetch=1 —
# перекачать даже при наличии. Печатает путь к кэш-файлу (может быть пустым при провале без прежнего кэша).
ensure_cache() {
	_k="$1"; _refetch="$2"; _cf="$CACHE/$_k"
	if [ "$_refetch" = 1 ] || [ ! -s "$_cf" ]; then
		_u=$(cat_url "$_k"); [ -n "$_u" ] || { printf '%s' "$_cf"; return 0; }
		_kind=$(cat_kind "$_k")
		if [ "$_kind" = domain ]; then
			_raw="$RAM/.raw.$_k"
			case "$_u" in
				v2fly:*) fetch_v2fly "${_u#v2fly:}" "$_raw" ;;       # уже norm_geosite'нуто внутри
				*)       fetch_url "$_u" "$_raw.dl" && norm_geosite < "$_raw.dl" > "$_raw"; rm -f "$_raw.dl" 2>/dev/null ;;
			esac
			# rename, never rewrite in place: `>` truncates first, and the schedules' filter reloading in that window would
			# load half a category — or none (review s.112)
			[ -s "$_raw" ] && sort -u "$_raw" > "$_cf.$$" && mv -f "$_cf.$$" "$_cf"
			rm -f "$_raw" "$_cf.$$" 2>/dev/null
		else
			_raw="$RAM/.raw.$_k"
			if fetch_url "$_u" "$_raw"; then
				norm_cidr < "$_raw" | sort -u > "$_cf.$$" && mv -f "$_cf.$$" "$_cf"
				# the IPv6 lines beside it, bogons cut (`<key>@6`): norm_cidr keeps IPv4 only, and a consumer closes a messenger by its
				# network in both families. Written even empty — «fetched, the source has no v6» (CONSUMERS below)
				norm_cidr6 < "$_raw" | strip_bogon6 | sort -u > "$_cf@6.$$" && mv -f "$_cf@6.$$" "$_cf@6"
				rm -f "$_cf.$$" "$_cf@6.$$" 2>/dev/null
			fi
			rm -f "$_raw" 2>/dev/null
		fi
	fi
	printf '%s' "$_cf"
}

# --- проводка правил (mark-core для geo_vpn + apply-bypass для geo_out) --------------
# Как в groups.sh: mark-core ставит MARK для СУЩЕСТВУЮЩЕГО сета (с логикой «выше miwifi/NFQUEUE» —
# дублировать её нельзя, это ядро). Сет создаётся тут, до этого правила нет → зовём mark-core.
wire_rules() {
	iptables -t mangle -C PREROUTING -m set --match-set "$SET_VPN" dst -j MARK --set-mark 0x1 2>/dev/null \
		|| iptables -t mangle -C PREROUTING -m set --match-set "$SET_VPN" dst -j ACCEPT 2>/dev/null \
		|| sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1 || true
	sh "$ENODIA_DIR/apply-bypass.sh" set-dst-ensure "$SET_OUT" >/dev/null 2>&1 || true
}

# geo_block (CIDR-блок): DROP по dst (и src с WAN) через ОТДЕЛЬНУЮ цепочку ENODIA_GEOBLK. Точное зеркало
# ensure_block_rules из lists-update.sh — 3 слоя защиты связи: blocklist_allow RETURN (VPS/WAN/DNS/LAN
# никогда не дропаем) → DROP по source ТОЛЬКО с WAN-iface → DROP по dst. Наполнение geo_block СТРОГО
# strip_bogon'ится в do_build. ДОМЕН-блок идёт через dnsmasq address= (не эту цепочку) — независимо.
geo_block_wire() {
	set_ensure "$SET_BLK"
	ensure_allow_set
	_wif=$(wan_iface)
	if iptables -nL ENODIA_GEOBLK >/dev/null 2>&1; then iptables -F ENODIA_GEOBLK 2>/dev/null
	else iptables -N ENODIA_GEOBLK 2>/dev/null; fi
	iptables -A ENODIA_GEOBLK -m set --match-set blocklist_allow src -j RETURN 2>/dev/null
	iptables -A ENODIA_GEOBLK -m set --match-set blocklist_allow dst -j RETURN 2>/dev/null
	[ -n "$_wif" ] && iptables -A ENODIA_GEOBLK -i "$_wif" -m set --match-set "$SET_BLK" src -j DROP 2>/dev/null
	iptables -A ENODIA_GEOBLK -m set --match-set "$SET_BLK" dst -j DROP 2>/dev/null
	iptables -C INPUT   -j ENODIA_GEOBLK 2>/dev/null || iptables -I INPUT   -j ENODIA_GEOBLK 2>/dev/null
	iptables -C FORWARD -j ENODIA_GEOBLK 2>/dev/null || iptables -I FORWARD -j ENODIA_GEOBLK 2>/dev/null
}
geo_block_teardown() {
	iptables -D INPUT   -j ENODIA_GEOBLK 2>/dev/null
	iptables -D FORWARD -j ENODIA_GEOBLK 2>/dev/null
	iptables -F ENODIA_GEOBLK 2>/dev/null
	iptables -X ENODIA_GEOBLK 2>/dev/null
	# Набор «не блокировать» общий с блокировкой списками (lists-update.sh): её цепочки нет — набор ничей, снимаем. Иначе
	# он жил до ребута, и снятие ipblock его уничтожить не могло (набор держала ЭТА цепочка) — лишний хвост в ядре.
	# Блокировка списками ВКЛЮЧЕНА, но её цепочки ещё нет (первое включение, бут: heal зовёт обе сборки параллельно) — набор
	# НЕ её сирота: снятый в этом окне, он оставил бы её DROP без правила RETURN, то есть без защиты сервера и шлюза.
	iptables -nL ENODIA_BLK >/dev/null 2>&1 || cat_enabled ipblock 2>/dev/null || ipset destroy blocklist_allow 2>/dev/null
	return 0
}

# ИСКЛЮЧЕНИЯ РЕКЛАМЫ ЗАВИСЯТ ОТ ГЕО-«БЛОКА»: `server=/исключение/#` под закрытым родителем пишется, только если родителя не
# закрывает ещё и гео (иначе строка длиннее и пробила бы его), — а решение принималось по сниппету гео НА МОМЕНТ применения
# рекламы. Поставили «Блок» позже — исключение-поддомен пробивало его вопреки словам экрана; сняли «Блок» по совету экрана —
# поддомен оставался закрытым рекламой до её следующего обновления (при расписании «Выкл» — до ребута). Переигрываем снимок
# рекламы (он в ОЗУ, без закачки) ПОСЛЕ смены сниппета гео и без своей перезагрузки DNS — её делает сборка гео.
adblock_resync() {
	cat_enabled adblock 2>/dev/null && [ -s "$(allow_path adblock)" ] || return 0
	[ -f "$ENODIA_DIR/lists-update.sh" ] && LISTS_NO_RELOAD=1 sh "$ENODIA_DIR/lists-update.sh" reapply adblock >/dev/null 2>&1
	return 0
}

# --- доменные dnsmasq-conf (маршрут ipset=/ + блок address=) -------------------------
# ipset=/дом/geo_vpn|geo_out → dnsmasq кладёт живую A-запись в сет (динамика). address=/дом/0.0.0.0
# И /:: → блок обеих семей (только 0.0.0.0 не режет IPv6 — грабля adblock). Пустой источник → пустой
# conf (dnsmasq без правил). Одним sed-проходом (не цикл sh) — на тысячах доменов (v2fly-google ~1000)
# критично. Снимок на флеш → офлайн-ребут переживает (reapply копирует обратно).
build_dns() {  # build_dns <домены-vpn> <домены-out> <домены-blk> [домены-десинк]
	mkdir -p /tmp/dnsmasq.d 2>/dev/null
	: > "$DNSCONF.new"
	[ -s "$1" ] && sed "s|.*|ipset=/&/$SET_VPN|" "$1" >> "$DNSCONF.new"
	[ -s "$2" ] && sed "s|.*|ipset=/&/$SET_OUT|" "$2" >> "$DNSCONF.new"
	# Домены «в десинк» — в ТОТ ЖЕ conf (снимок SNAP_DNS накрывает их сам, как слот-домены).
	[ -n "$4" ] && [ -s "$4" ] && sed "s|.*|ipset=/&/$SET_DSY|" "$4" >> "$DNSCONF.new"
	# Домены слот-категорий (Ф1b): ipset=/дом/geo_vpn_s<N> — dnsmasq кладёт живые A-записи в сет
	# слота. Едут в тот же conf ⇒ снимок SNAP_DNS накрывает их автоматически (офлайн-ребут).
	for _bn in 2 3 4 5 6 7; do
		[ -s "$RAM/.dom-vpn-s$_bn" ] && sed "s|.*|ipset=/&/geo_vpn_s$_bn|" "$RAM/.dom-vpn-s$_bn" >> "$DNSCONF.new"
	done
	mv "$DNSCONF.new" "$DNSCONF"
	: > "$DNSBLK.new"
	if [ -s "$3" ]; then
		{ sed 's|.*|address=/&/0.0.0.0|' "$3"; sed 's|.*|address=/&/::|' "$3"; } >> "$DNSBLK.new"
	fi
	mv "$DNSBLK.new" "$DNSBLK"
	snap_flash "$SNAP_DNS" "$DNSCONF"; snap_flash "$SNAP_DNSBLK" "$DNSBLK"
}
dns_dom_count() {  # число доменов-маршрутов в живом conf
	_n=$(grep -c '^ipset=/' "$DNSCONF" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac; printf '%s' "$_n"
}
dns_blk_count() {  # число доменов-блоков (A-строк; их вдвое меньше всех)
	_n=$(grep -c '/0\.0\.0\.0$' "$DNSBLK" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac; printf '%s' "$_n"
}

# snap_flash при превышении капа ПЕЧАТАЕТ предупреждение — а весь stdout _build_pass уходит одной
# строкой сводки в `.msg` панели, и вторая строка сбивает накладной перевод (ровно то, чего просит
# избегать комментарий у do_build). Копим такие предупреждения и вешаем ХВОСТОМ к той же строке:
# молчать нельзя — «снимка нет» означает, что офлайн-ребут потеряет маршрут.
snap_q() {
	_sq=$(snap_flash "$1" "$2")
	[ -n "$_sq" ] && GEO_SNAPW="$GEO_SNAPW; $_sq"
	return 0
}

# --- CONSUMERS: category data for other subsystems (access schedules' «Ограничено») ------------------------------------
# geo.sh is the ONE owner of category DATA (fetch, the v2fly include tree, snapshots); another subsystem must not grow a second
# copy. A consumer names the keys it needs (`want`) and reads READY files (`ready`) — never a fetch on its own path: the
# schedule tick runs every minute and must not wait on an include tree that takes minutes. The fetch runs in geo's own jobs:
# `wanted` (the consumer's save starts it in the background) and every `update` (boot, daily, the panel) refreshes them.
# Not through do_build: its pass ends with a dnsmasq restart — ~2.5 s without names for the whole house per schedule save.
# A key's consumer FORMS (want_forms): a domain key — its cache file; a cidr key — `<key>@4` and `<key>@6` beside its cache, bogons
# cut HERE (the consumer fills sets from them, and the data owner cuts once — not a per-minute tick); `@6` may be empty.
WANT_DIR="$GEO/want"                    # one file per consumer: a key per line
WSNAP="$GEO/.wsnap.$RESOLVER_VER"       # gz snapshots of wanted keys; keyed by the resolver version (new logic = stale data)
WSNAP_MAX=1048576                       # bytes of one gz snapshot; a bigger key lives in RAM only (a journal line, as snap_flash)
WSNAP_TOTAL=${WSNAP_TOTAL:-4194304}                     # bytes of all of them (32 pools × 16 schedules could not reach /data's 20 MB otherwise)
WSNAP_RESERVE=2097152                   # free bytes the volume keeps after a snapshot (store-lib.sh fs_free_b; none = no check)
want_keys() { cat "$WANT_DIR"/* 2>/dev/null | tr -d '\r' | grep . | sort -u; }
# Is the key one the catalogue OFFERS? The patterns of cat_url/cat_kind take any name after a prefix (v2fly-anything would pass and
# stay «downloading» for ever), so the enumerated lists are asked too — the same files catalog_lines reads, no list built.
cat_known() {
	case "$1" in
		v2fly-*) _ckf="$V2CAT_SNAP"; [ -s "$_ckf" ] || _ckf="$V2CAT_BAKED"; tr -d '\r' < "$_ckf" 2>/dev/null | grep -qxF -- "${1#v2fly-}" ;;
		rfip-*)  _ckf="$RFIP_SNAP"; [ -s "$_ckf" ] || _ckf="$RFIP_BAKED"; tr -d '\r' < "$_ckf" 2>/dev/null | grep -qxF -- "${1#rfip-}" ;;
		rfgs-*)  _ckf="$RFGS_SNAP"; [ -s "$_ckf" ] || _ckf="$RFGS_BAKED"; tr -d '\r' < "$_ckf" 2>/dev/null | grep -qxF -- "${1#rfgs-}" ;;
		??)      country_codes | tr ' ' '\n' | grep -qxF -- "$1" ;;
		*)       [ -n "$(cat_url "$1")" ] && [ -n "$(cat_kind "$1")" ] ;;
	esac
}
want_forms() {   # <key> → «<file name in CACHE> <kind>» per consumer form
	case "$(cat_kind "$1")" in
		domain) echo "$1 domain" ;;
		cidr)   echo "$1@4 cidr"; echo "$1@6 cidr6" ;;
	esac
}
# _wanted_pass <refetch> — under GEO_LOCK: every wanted key into the RAM cache (refetch=1: again) and its snapshot to the flash;
# snapshots of keys nobody wants any more, and of older resolver versions, go away
_wanted_pass() {
	_wk=$(want_keys)
	for _wo in "$GEO"/.wsnap.*; do [ -d "$_wo" ] && [ "$_wo" != "$WSNAP" ] && rm -rf "$_wo"; done
	for _ws in "$WSNAP"/*.gz; do
		[ -f "$_ws" ] || continue
		_wn=${_ws##*/}; _wn=${_wn%.gz}; _wn=${_wn%@[46]}
		printf '%s\n' "$_wk" | grep -qxF "$_wn" || rm -f "$_ws"
	done
	[ -n "$_wk" ] || return 0
	mkdir -p "$WSNAP" 2>/dev/null
	for _wn in $_wk; do
		_wr=$1; _wkd=$(cat_kind "$_wn")
		# a cidr key cached without its v6 form (the main path fetched it before that form existed): fetched again, once
		[ "$_wkd" = cidr ] && [ ! -f "$CACHE/$_wn@6" ] && _wr=1
		_wc=$(ensure_cache "$_wn" "$_wr")
		if [ "$_wkd" = cidr ]; then
			# `@4` only from a cache that is here: after a reboot `ready` put the forms back from the snapshots while the cache is
			# gone, and an offline pass must not empty them
			if [ -f "$_wc" ]; then
				strip_bogon < "$_wc" 2>/dev/null | sort -u > "$_wc@4.$$" && mv -f "$_wc@4.$$" "$_wc@4"
				rm -f "$_wc@4.$$" 2>/dev/null
			fi
			[ -f "$_wc@4" ] || continue
			[ -f "$_wc@6" ] || : > "$_wc@6"
		else
			[ -s "$_wc" ] || continue
		fi
		for _wf in $(want_forms "$_wn" | awk '{ print $1 }'); do
			# a snapshot is rewritten only when the data changed: the flash is written by content, not by the clock
			gzip -c "$CACHE/$_wf" > "$RAM/.wsnap.$$" 2>/dev/null || { rm -f "$RAM/.wsnap.$$"; continue; }
			_wsz=$(wc -c < "$RAM/.wsnap.$$" | tr -d ' ')
			# the total of the OTHER snapshots + this one, and the volume's reserve — over either: RAM only, said like a big key
			_wtot=$(for _wq in "$WSNAP"/*.gz; do [ -f "$_wq" ] && [ "$_wq" != "$WSNAP/$_wf.gz" ] && wc -c < "$_wq"; done | awk '{ t += $1 } END { print t + 0 }')
			_wfree=$(command -v fs_free_b >/dev/null 2>&1 && fs_free_b "$WSNAP")
			if [ "$_wsz" -gt "$WSNAP_MAX" ] || [ $(( _wtot + _wsz )) -gt "$WSNAP_TOTAL" ] || { [ -n "$_wfree" ] && [ "$_wfree" -gt 0 ] && [ "$_wfree" -lt $(( _wsz + WSNAP_RESERVE )) ]; }; then
				rm -f "$RAM/.wsnap.$$" "$WSNAP/$_wf.gz"
				if [ -f "$ENODIA_DIR/events.sh" ]; then
					sh "$ENODIA_DIR/events.sh" add geo-want-snap-skip 86400 \
						"Категория расписания не переживёт перезагрузку" \
						"Категория «$_wn» слишком велика для снимка на флеш. Сейчас она работает, но после перезагрузки роутера начнёт закрываться не сразу — сперва её нужно будет заново скачать (несколько минут)." >/dev/null 2>&1
				fi
				continue
			fi
			# by md5: a busybox without `cmp` would rewrite every snapshot on every pass (the flash is written by content)
			if [ -f "$WSNAP/$_wf.gz" ] && [ "$(gunzip -c "$WSNAP/$_wf.gz" 2>/dev/null | md5sum)" = "$(md5sum < "$CACHE/$_wf" 2>/dev/null)" ]; then
				rm -f "$RAM/.wsnap.$$"
			else
				mv -f "$RAM/.wsnap.$$" "$WSNAP/$_wf.gz"
			fi
		done
	done
	return 0
}

# --- сборка: агрегировать включённые ключи → сеты/conf → снимки → правила -------------
# refetch=1 (update) перекачивает кэш; refetch=0 (apply) собирает из существующего кэша (быстро).
# _build_pass — ОДИН проход; ВСЕГДА под локом do_build (см. ниже).
_build_pass() {
	_refetch="$1"
	GEO_SNAPW=""
	# Инвалидация по версии резолвера: сменилась логика fetch_v2fly → устаревший доменный кэш/снимок
	# молча отдал бы старый результат (напр. переблок category-ads-all с apex google.com). Первый build
	# после смены версии форсит refetch — чинит и RAM-кэш, и флеш-снимок, дальше кэш снова используется.
	_rv=$(cat "$RVER" 2>/dev/null | tr -d ' \r\n')
	[ "$_rv" = "$RESOLVER_VER" ] || _refetch=1
	echo "$RESOLVER_VER" > "$RVER" 2>/dev/null
	ustate RUNNING
	# CIDR-агрегаты (в ipset) и ДОМЕН-агрегаты (в dnsmasq-conf) — раздельно по kind.
	_vpn="$RAM/.agg-vpn"; _out="$RAM/.agg-out"; _blk="$RAM/.agg-blk"; _dsy="$RAM/.agg-dsy"
	_dv="$RAM/.dom-vpn"; _do="$RAM/.dom-out"; _db="$RAM/.dom-blk"; _dd="$RAM/.dom-dsy"
	: > "$_vpn"; : > "$_out"; : > "$_blk"; : > "$_dsy"; : > "$_dv"; : > "$_do"; : > "$_db"; : > "$_dd"
	# Доп-выходы (Ф1b, зеркало groups.sh do_apply): vpn-категория со slot=N идёт в СВОЙ агрегат
	# (CIDR → geo_vpn_s<N>, домены → dnsmasq ipset=/дом/geo_vpn_s<N>), а не в общий geo_vpn.
	# Привязка к выключенному/удалённому слоту → категория едет ОСНОВНЫМ выходом (geo_vpn), а не
	# молча напрямую: слот = альтернативный выход, его отказ не роняет приватность (fallback=main).
	for _sn in 2 3 4 5 6 7; do : > "$RAM/.agg-vpn-s$_sn"; : > "$RAM/.dom-vpn-s$_sn"; done
	_any_slot=0
	_en_slots=" "
	[ -f "$ENODIA_DIR/slots.sh" ] && _en_slots=" $(sh "$ENODIA_DIR/slots.sh" list-enabled 2>/dev/null | cut -f1 | tr '\n' ' ') "
	if [ -s "$REG" ]; then
		while IFS="$TAB" read -r _k _a _c _t _s; do
			[ -n "$_k" ] || continue
			[ -n "$(cat_url "$_k")" ] || continue        # ключа нет НИ У ОДНОГО провайдера (реально устарел) — игнор
			case "$_s" in [2-7]) ;; *) _s=0 ;; esac
			[ "$_s" != 0 ] && case "$_en_slots" in *" $_s "*) ;; *) _s=0 ;; esac
			if [ "$(cat_kind "$_k")" = domain ]; then
				case "$_a" in
					vpn)    if [ "$_s" != 0 ]; then _dst="$RAM/.dom-vpn-s$_s"; _any_slot=1; else _dst="$_dv"; fi ;;
					bypass) _dst="$_do" ;; block) _dst="$_db" ;; desync) _dst="$_dd" ;; *) continue ;;
				esac
			else
				case "$_a" in
					vpn)    if [ "$_s" != 0 ]; then _dst="$RAM/.agg-vpn-s$_s"; _any_slot=1; else _dst="$_vpn"; fi ;;
					bypass) _dst="$_out" ;; block) _dst="$_blk" ;; desync) _dst="$_dsy" ;; *) continue ;;
				esac
			fi
			_cf=$(ensure_cache "$_k" "$_refetch")
			_n=0
			if [ -s "$_cf" ]; then
				cat "$_cf" >> "$_dst"
				_n=$(grep -c '' "$_cf" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
			fi
			reg_set_meta "$_k" "$_n" "$(date +%s)"
		done < "$REG"
	fi
	# CIDR: busybox sort БЕЗ -o (дампит в stdout) → сорт+дедуп через tmp+mv. Блок-агрегат СТРОГО
	# strip_bogon (защита LAN от «глухого» DROP; зеркало ipblock).
	sort -u "$_vpn" > "$_vpn.s" 2>/dev/null && mv "$_vpn.s" "$_vpn"
	sort -u "$_out" > "$_out.s" 2>/dev/null && mv "$_out.s" "$_out"
	strip_bogon < "$_blk" 2>/dev/null | sort -u > "$_blk.s" 2>/dev/null; mv "$_blk.s" "$_blk"
	# Десинк-пул тоже СТРОГО strip_bogon: zapret вешает на него NFQUEUE (а слот — ещё и ACCEPT выше
	# маркировки) ⇒ приватка в пуле = LAN мимо VPN. Зеркало zapret_cidr.
	strip_bogon < "$_dsy" 2>/dev/null | sort -u > "$_dsy.s" 2>/dev/null; mv "$_dsy.s" "$_dsy"
	# geo_block домены НЕ наполняют (они уходят в dnsmasq через address=, а не ipset=) ⇒ ему
	# файл доменов не передаём: динамики у набора не бывает, но снимок даёт «не изменилось —
	# не трогаем» и на нём (агрегат страны пересобирать вхолостую дорого).
	# Провал ЗАЛИВКИ набора копим: набор остался СТАРЫМ, и «гео применено» было бы враньём.
	_gfail=""
	set_sync "$SET_VPN" "$_vpn" "$_dv" || _gfail="$_gfail $SET_VPN"
	set_sync "$SET_OUT" "$_out" "$_do" || _gfail="$_gfail $SET_OUT"
	set_sync "$SET_BLK" "$_blk"        || _gfail="$_gfail $SET_BLK"
	set_sync "$SET_DSY" "$_dsy" "$_dd" || _gfail="$_gfail $SET_DSY"
	snap_q "$SNAP_VPN" "$_vpn"; snap_q "$SNAP_OUT" "$_out"; snap_q "$SNAP_BLK" "$_blk"
	snap_q "$SNAP_DSY" "$_dsy"
	# Слот-агрегаты: сорт+дедуп, сет наполняем если есть члены (CIDR или домены — dnsmasq требует
	# СУЩЕСТВУЮЩИЙ сет до рестарта, set_sync его создаёт и пустым) ИЛИ сет уже жив (иначе IP отвязанной
	# категории залипли бы в старом сете — зеркало groups.sh). Снимок на флеш — офлайн-ребут переживает.
	for _sn in 2 3 4 5 6 7; do
		_sf="$RAM/.agg-vpn-s$_sn"; _df="$RAM/.dom-vpn-s$_sn"
		sort -u "$_sf" > "$_sf.s" 2>/dev/null && mv "$_sf.s" "$_sf"
		sort -u "$_df" > "$_df.s" 2>/dev/null && mv "$_df.s" "$_df"
		if [ -s "$_sf" ] || [ -s "$_df" ] || ipset list -n 2>/dev/null | grep -qx "geo_vpn_s$_sn"; then
			set_sync "geo_vpn_s$_sn" "$_sf" "$_df" || _gfail="$_gfail geo_vpn_s$_sn"
		fi
		snap_q "$GEO/.snap-vpn-s$_sn" "$_sf"
	done
	# ДОМЕНЫ: дедуп + dnsmasq-conf (сеты geo_vpn/geo_out уже созданы set_sync выше — dnsmasq требует их).
	sort -u "$_dv" > "$_dv.s" 2>/dev/null && mv "$_dv.s" "$_dv"
	sort -u "$_do" > "$_do.s" 2>/dev/null && mv "$_do.s" "$_do"
	sort -u "$_db" > "$_db.s" 2>/dev/null && mv "$_db.s" "$_db"
	sort -u "$_dd" > "$_dd.s" 2>/dev/null && mv "$_dd.s" "$_dd"
	build_dns "$_dv" "$_do" "$_db" "$_dd"
	adblock_resync
	# ПЕРЕСЕЧЕНИЕ «в VPN» × «мимо» — считаем ЗДЕСЬ, пока агрегаты ещё не удалены, и кладём
	# вердикт на флеш: панель обязана показывать факт с роутера, а не свою арифметику.
	overlap_scan "$_vpn" "$SET_OUT" "$_dv" "$_do" > "$GEO/.overlap.new" 2>/dev/null \
		&& mv "$GEO/.overlap.new" "$GEO/.overlap" || rm -f "$GEO/.overlap.new" 2>/dev/null
	wire_rules
	# Пул десинка изменился → досборка правил nfqws (zapret сам о нашем сете не узнает). Верб rewire
	# идемпотентен и НЕ поднимает демон, когда десинк выключен, — звать безопасно всегда.
	[ -f "$ENODIA_DIR/zapret.sh" ] && sh "$ENODIA_DIR/zapret.sh" rewire >/dev/null 2>&1
	# Есть привязки к слотам → переиграть слоты через ОРКЕСТРАТОР (zapret-слот ставит ACCEPT+NFQUEUE
	# на geo_vpn_s<N>). stdout глушим: _build_pass бежит в $(...) do_build — чужой вывод сбил бы сводку.
	if [ "$_any_slot" = 1 ] && [ -f "$ENODIA_DIR/transport.sh" ]; then
		sh "$ENODIA_DIR/transport.sh" slots-up >/dev/null 2>&1
	fi
	# Цепочку CIDR-DROP держим только пока есть что блокировать по CIDR (домен-блок независим — dnsmasq).
	_bn=$(grep -c '' "$_blk" 2>/dev/null); case "$_bn" in ''|*[!0-9]*) _bn=0 ;; esac
	if [ "$_bn" -gt 0 ]; then geo_block_wire; else geo_block_teardown; fi
	dns_reload
	# NSS/ECM-offload держит установленные соединения на старом маршруте до таймаута — сброс обязателен.
	ct_flush
	# the consumers' keys ride every refetch (boot, daily, «Обновить»); AFTER the routing above — they must not delay it
	if [ "$_refetch" = 1 ]; then _wanted_pass 1 >/dev/null 2>&1; fi
	rm -f "$_vpn" "$_out" "$_blk" "$_dsy" "$_dv" "$_do" "$_db" "$_dd" 2>/dev/null
	for _sn in 2 3 4 5 6 7; do rm -f "$RAM/.agg-vpn-s$_sn" "$RAM/.dom-vpn-s$_sn" 2>/dev/null; done
	# ustate DONE ставит ОБЁРТКА (do_build) после ПОСЛЕДНЕГО прохода: иначе dirty-повтор мигнул бы
	# панели «готово» в середине работы и та перестала бы поллить.
	printf 'гео применено: CIDR в VPN %s / мимо %s / блок %s / десинк %s; домены маршрут %s / блок %s%s%s\n' \
		"$(ipset_count "$SET_VPN")" "$(ipset_count "$SET_OUT")" "$(ipset_count "$SET_BLK")" "$(ipset_count "$SET_DSY")" "$(dns_dom_count)" "$(dns_blk_count)" \
		"${_gfail:+; НЕ удалось залить наборы:$_gfail (маршрут для них остался прежним)}" "$GEO_SNAPW"
	[ -z "$_gfail" ]
}

# do_build: СЕРИАЛИЗОВАННАЯ обёртка над _build_pass (лок/dirty — общая пара из lists-lib.sh, как у
# движка списков). Панель после каждого клика шлёт geo_apply, а расписание/кнопка «Обновить списки»
# — geo_update: два прохода в один момент топтали бы ОДНИ рабочие файлы ОЗУ (.agg-*/.dom-*, имена
# фиксированные) и общий реестр ⇒ сеты собрались бы из полу-данных, счётчики в UI соврали.
# Конкурент помечает dirty ПРИЗНАКОМ REFETCH и выходит — держатель переигрывает проход, причём
# запрошенная перекачка не теряется (dirty=1 ⇒ повтор с refetch, а не «тихий apply из кэша»).
# Печатаем сводку ПОСЛЕДНЕГО прохода (панель кладёт stdout в .msg — две строки сбили бы i18n).
do_build() {
	_want="$1"
	if ! ls_lock_take "$GEO_LOCK" "$GEO_DIRTY" "$_want"; then
		echo 'гео: сборка уже идёт — учту свежий выбор в ней'
		return 0
	fi
	trap 'ls_lock_drop "$GEO_LOCK"' EXIT
	trap 'exit 1' INT TERM HUP PIPE
	_sum=''; _rc=0
	while :; do
		rm -f "$GEO_DIRTY" 2>/dev/null   # сброс ДО чтения реестра: пойманный dirty ⇒ реестр прочитан ПОСЛЕ мутации
		_sum=$(_build_pass "$_want"); _rc=$?
		[ -f "$GEO_DIRTY" ] || break
		_want=$(cat "$GEO_DIRTY" 2>/dev/null | tr -d ' \r\n'); [ "$_want" = 1 ] || _want=0
	done
	ustate DONE
	trap - EXIT INT TERM HUP PIPE
	ls_lock_drop "$GEO_LOCK"
	[ -z "$_sum" ] || echo "$_sum"
	return $_rc   # провал заливки набора не должен читаться как «применено» (сводка это же и говорит)
}

# reapply: ОФЛАЙН-восстановление из ФЛЕШ-снимков (boot-хук heal.sh; в сеть не ходит). Снимков нет
# (гео не настроено) → no-op. Свежесть даст фоновый update, что heal.sh пускает следом.
do_reapply() {
	_any=0
	[ -s "$SNAP_VPN" ] && { set_fill "$SET_VPN" "$SNAP_VPN"; _any=1; }
	[ -s "$SNAP_OUT" ] && { set_fill "$SET_OUT" "$SNAP_OUT"; _any=1; }
	[ -s "$SNAP_BLK" ] && { set_fill "$SET_BLK" "$SNAP_BLK"; _any=1; }
	[ -s "$SNAP_DSY" ] && { set_fill "$SET_DSY" "$SNAP_DSY"; _any=1; }
	mkdir -p /tmp/dnsmasq.d 2>/dev/null
	[ -s "$SNAP_DNS" ]    && { cp "$SNAP_DNS" "$DNSCONF" 2>/dev/null; _any=1; }
	[ -s "$SNAP_DNSBLK" ] && { cp "$SNAP_DNSBLK" "$DNSBLK" 2>/dev/null; _any=1; adblock_resync; }
	# Слот-снимки (Ф1b): CIDR слота обратно в geo_vpn_s<N>. Врайринг (марка/NFQUEUE) — забота
	# heal 5.13b (transport.sh slots-up идёт ПОСЛЕ geo-reapply — порядок уже правильный).
	for _sn in 2 3 4 5 6 7; do
		[ -s "$GEO/.snap-vpn-s$_sn" ] && { set_fill "geo_vpn_s$_sn" "$GEO/.snap-vpn-s$_sn"; _any=1; }
	done
	[ "$_any" = 1 ] || return 0
	# dnsmasq ipset=/дом/geo_vpn ТРЕБУЕТ существующий сет ДО рестарта — гарантируем (снимка CIDR могло не быть).
	set_ensure "$SET_VPN"; set_ensure "$SET_OUT"
	# Категория «в десинк» может быть ЧИСТО ДОМЕННОЙ (CIDR-снимка нет, ipset=-строка есть) — без сета
	# dnsmasq ругается и правило мертво. Правила nfqws дособерёт zapret (rewire зовёт heal/apply).
	grep -q "/$SET_DSY\$" "$DNSCONF" 2>/dev/null && set_ensure "$SET_DSY"
	# То же для слот-сетов, на которые ссылается DNS-снимок (категория из одних доменов: CIDR-снимка
	# слота нет, а ipset=-строка есть — без сета dnsmasq ругается и правило мертво).
	for _sn in 2 3 4 5 6 7; do
		grep -q "/geo_vpn_s$_sn\$" "$DNSCONF" 2>/dev/null && set_ensure "geo_vpn_s$_sn"
	done
	wire_rules
	if [ -s "$SNAP_BLK" ]; then geo_block_wire; else geo_block_teardown; fi
	dns_reload
	ct_flush
	return 0
}

geo_enabled() { [ -s "$REG" ]; }   # есть хоть один выбранный элемент → гео активно

# --- свежесть + SHA апстрима (last-commit через GitHub API → $SHAS) ------------------
# Один вызов на репозиторий-источник: из ответа коммита берём И sha (для пиновки фетча — jsd_ref), И дату
# (для метки «апстрим N назад» в панели). $SHAS = repo_id<TAB>sha<TAB>iso. Провал по репо → сохраняем
# прежнюю строку (последнее известное). Зовут: update (перед сборкой) и панель (async при пустом кэше дат).
resolve_upstream() {
	: > "$SHAS.new"
	for _row in \
		"v2fly|https://api.github.com/repos/v2fly/domain-list-community/commits/master" \
		"rfip|https://api.github.com/repos/runetfreedom/russia-blocked-geoip/commits/release" \
		"rfgs|https://api.github.com/repos/runetfreedom/russia-blocked-geosite/commits/release"; do
		_rid=${_row%%|*}; _api=${_row#*|}; _sha=''; _iso=''
		_tmp="$RAM/.sha.$$"
		if fetch_url "$_api" "$_tmp"; then
			# GitHub API отдаёт PRETTY-JSON с пробелом после двоеточия ("sha": "…") → паттерн допускает
			# ` *` (иначе извлечение молча пустело и .shas не наполнялся — пойм. на железе dev23).
			_sha=$(grep -o '"sha": *"[^"]*"' "$_tmp" 2>/dev/null | head -1 | cut -d'"' -f4)
			_iso=$(grep -o '"date": *"[^"]*"' "$_tmp" 2>/dev/null | head -1 | cut -d'"' -f4)
		fi
		rm -f "$_tmp" 2>/dev/null
		case "$_sha" in
			[0-9a-f][0-9a-f]*) printf '%s\t%s\t%s\n' "$_rid" "$_sha" "$_iso" >> "$SHAS.new" ;;
			*) grep "^$_rid$TAB" "$SHAS" 2>/dev/null >> "$SHAS.new" ;;   # провал API — держим прежний sha/дату
		esac
	done
	# ipdeny — НЕ git, коммитов у него нет, но свежесть измерима: `Last-Modified` отдаётся на КАЖДОЙ
	# зоне и совпадает с «Zone files last updated» на главной (проверено на железе 13.08.2026 —
	# зоны обновлены в тот же день). Без этого вкладка «Страны» была единственной БЕЗ признака
	# актуальности, то есть человек не мог отличить живой источник от заброшенного.
	# SHA-поле держим прочерком: пиновать нечего, а формат строки $SHAS общий.
	_ipd=$(ipdeny_iso 2>/dev/null)
	if [ -n "$_ipd" ]; then printf 'ipdeny\t-\t%s\n' "$_ipd" >> "$SHAS.new"
	else grep "^ipdeny$TAB" "$SHAS" 2>/dev/null >> "$SHAS.new"; fi
	[ -s "$SHAS.new" ] && mv "$SHAS.new" "$SHAS" || rm -f "$SHAS.new" 2>/dev/null
}
# Last-Modified зоны ipdeny → ISO. Приводим ЗДЕСЬ, а не в панели: `geoFreshLabel` режет дату как
# `iso.slice(0,10)`, и RFC-1123 («Thu, 13 Aug 2026 …») превратился бы в «Thu, 13 A». Одна ветка
# формата на весь проект — во фронте второй не заводим. САМ РАЗБОР RFC-1123 — у владельца
# (clock-lib.sh::http_date_iso, единственный разборщик формата на роутер; до 05.09.2026 здесь жила
# своя таблица месяцев — вторая копия того, что уже умел clock_http_date). Нет библиотеки —
# свежести нет (панель покажет вкладку без даты): единственное, что теряется при частичной установке.
ipdeny_iso() {
	command -v http_date_iso >/dev/null 2>&1 || return 1
	_lm=$(curl -sI --max-time 20 "$IPDENY/ru-aggregated.zone" 2>/dev/null \
	      | grep -i '^last-modified:' | head -1 | sed 's/^[Ll]ast-[Mm]odified:[ ]*//')
	[ -n "$_lm" ] || return 1
	http_date_iso "$_lm"
}
upstream_iso() { grep "^$1$TAB" "$SHAS" 2>/dev/null | head -1 | cut -f3; }   # дата апстрима репо (для панели)

# --- ПЕРЕСЕЧЕНИЕ КАТЕГОРИЙ (кто кого молча отменяет) ---------------------------------
# ЗАЧЕМ. Наборы гео наполняются НЕЗАВИСИМО, вычитания пересечений нет нигде, а спор решает
# iptables: ACCEPT из `geo_out` стоит в mangle ВЫШЕ маркировки (порядок задаёт
# ensure_prerouting_order), поэтому адрес, попавший И в «в VPN», И в «мимо», уходит НАПРЯМУЮ —
# проигравшая категория умирает МОЛЧА. Радиус шире гео: тот же ACCEPT перебивает `enodia_list`
# (домены руками), `enodia_ip_vpn`, `grp_vpn`, `iplist_set` и даже VPN_FORCE («устройство целиком
# в VPN») с глобальным full-tunnel. Ровно на этом сгорел тестер, перенёсший список из v2rayA,
# где ПОРЯДОК СТРОК = приоритет: у него `ru → мимо` тихо отменял `ru-blocked → в VPN`.
#
# ПОЧЕМУ ВЫБОРКОЙ. Честное пересечение CIDR-множеств (с вложенностью: /8-агрегат страны
# содержит /32 из «заблокированных») на busybox посчитать нечем — зато это умеет ядро:
# `ipset test` по hash:net находит совпадение по ЛЮБОЙ охватывающей сети. Гоняем равномерную
# выборку и печатаем ЧЕСТНО, сколько проверили: «конфликтов 0» из 200 проб не доказывает их
# отсутствия, и панель обязана говорить «не найдено», а не «их нет».
# Домены проще: там пересечение — это дословное совпадение имени в обоих списках.
OVERLAP_PROBES=200
overlap_scan() {   # $1=CIDR-агрегат «в VPN»  $2=набор «мимо»  $3/$4=домены vpn/out
	_ot=0; _oc=0; _od=0
	_on=$(grep -c '' "$1" 2>/dev/null); case "$_on" in ''|*[!0-9]*) _on=0 ;; esac
	if [ "$_on" -gt 0 ]; then
		_ostep=$(( (_on + OVERLAP_PROBES - 1) / OVERLAP_PROBES )); [ "$_ostep" -gt 0 ] || _ostep=1
		for _oa in $(awk -v s="$_ostep" 'NR%s==0{print $1}' "$1" 2>/dev/null); do
			_oa=${_oa%%/*}
			case "$_oa" in ''|*[!0-9.]*) continue ;; esac
			_ot=$((_ot+1))
			ipset test "$2" "$_oa" >/dev/null 2>&1 && _oc=$((_oc+1))
		done
	fi
	# Оба файла уже sort -u поодиночке ⇒ дубль в объединении = домен ровно в обоих списках.
	if [ -s "$3" ] && [ -s "$4" ]; then
		_od=$(sort "$3" "$4" 2>/dev/null | uniq -d | grep -c '' 2>/dev/null)
		case "$_od" in ''|*[!0-9]*) _od=0 ;; esac
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' "$_on" "$_ot" "$_oc" "$_od" "$(date +%s)"
}

# --- JSON для панели ----------------------------------------------------------------
# Состояние сборки — одна строка на оба ответа (`list` и `active`): прочитанное по-разному, оно назвало бы одну
# сборку двумя словами.
upd_state() {
	_us=$(cat "$RAM/.update.state" 2>/dev/null | tr -d ' \r\n')
	# «Идёт» — ТОЛЬКО пока жив держатель лока (тот же разбор, что lists-update.sh::cat_state): сборка, вышедшая по сигналу (ловушка
	# теперь ВЫХОДИТ, C121) или убитая -9, оставляла RUNNING до следующей сборки — панель держала «обновляю…». Держатель мог
	# ЗАКОНЧИТЬ между чтением и проверкой лока — перечитываем, и прерванной считаем, только если в файле по-прежнему RUNNING.
	if [ "$_us" = RUNNING ] && { [ ! -d "$GEO_LOCK" ] || _lock_stale "$GEO_LOCK"; }; then
		_us=$(cat "$RAM/.update.state" 2>/dev/null | tr -d ' \r\n'); [ "$_us" = RUNNING ] && _us=ABORTED
	fi
	printf '%s' "${_us:-IDLE}"
}
# ГОЛОВА ОТВЕТА `list`: состояние сборки, счётчики сетов и признаки десинка. Печатает `{` и поля с хвостовой
# запятой; дальше вызыватель дописывает своё.
emit_head() {
	st=$(upd_state)
	# zapret: можно ли ВООБЩЕ десинкать на этом роутере. Панель прячет действие «в десинк», пока
	# ответ нет — иначе оно выбиралось бы в пустоту. Прогрессивное раскрытие, как у доп-выходов.
	# Признаков ДВА, и бинаря МАЛО: на ядре 4.4 (AX3600) nfqws стоит из бутстрапа, а NFQUEUE в
	# ядре вырезан ⇒ действие лишь уводило бы категорию МИМО туннеля, ничего не пробивая, — то
	# есть худший из режимов под подписью «обход блокировок». Второй признак у плагина (verb
	# nfq-ok, проба кэширована), своей копии пробы не заводим; rc=2 = старая копия верба не знает
	# ⇒ НЕ сужу, прежнее поведение байт-в-байт (та же идиома, что в transport.sh и cgi-bin/data).
	_zi=false
	if [ -x "$(bin_path nfqws)" ]; then
		_zi=true
		if [ -f "$ENODIA_DIR/zapret.sh" ]; then
			sh "$ENODIA_DIR/zapret.sh" nfq-ok >/dev/null 2>&1 || [ "$?" = 2 ] || _zi=false
		fi
	fi
	# ЦЕНА КАТЕГОРИИ В ОЗУ — коэффициенты ЗДЕСЬ, у владельца формата, а не во фронте: панель их
	# только умножает на счётчик и рисует. Оба ЗАМЕРЕНЫ на живом железе 17.08.2026 (AX3600):
	#   домен — ЧИСТЫЙ замер: выключили `category-ads-all` (148872 домена, действие «блок») и
	#     пересобрали. MemFree 28128 → 100552 КБ, то есть вернулось 70.7 МБ ⇒ ~498 Б на домен.
	#     Разложение: dnsmasq 64516 → 1776 КБ (−61.3 МБ, и это ВЕСЬ его вес — без списка демон
	#     занимает 1.7 МБ) плюс конфиг в tmpfs 10.0 МБ (по две строки `address=` на домен).
	#     Прежняя оценка 415 Б бралась из наблюдения «свободная 88 → 29 МБ» и ЗАНИЖАЛА: в те 59 МБ
	#     попадало не только это. Предупреждение, занижающее цену, — худший вид предупреждения.
	#   CIDR  — `iplist_set`, 3472 подсети = 146 КБ памяти ЯДРА под ipset ⇒ ~43 Б на подсеть.
	# Домен в «в VPN/мимо» дешевле блок-домена (одна строка `ipset=` вместо двух `address=`), но
	# отдельного замера у него нет — поэтому число ОДНО и панель обязана писать «ДО ~N МБ»:
	# для предупреждения ошибка в безопасную сторону — единственная допустимая.
	# Прогресс распаковки дерева include (см. uprogress): 0/0 = «нечего показывать».
	_pdone=0; _pq=0
	if [ -f "$RAM/.update.progress" ]; then
		_pdone=$(cut -f1 "$RAM/.update.progress" 2>/dev/null | tr -cd '0-9')
		_pq=$(cut -f2 "$RAM/.update.progress" 2>/dev/null | tr -cd '0-9')
		[ -n "$_pdone" ] || _pdone=0; [ -n "$_pq" ] || _pq=0
	fi
	# «МОЖЕТ ЛИ РОУТЕР ДЕСИНК» (_zi) И «РАБОТАЕТ ЛИ ДЕЙСТВИЕ „в десинк"» — РАЗНЫЕ ВОПРОСЫ, и до
	# 09.09.2026 панель знала только первый. Правила этого действия ставит `zapret.sh cmd_apply`, а
	# он при отсутствии `.zapret-on` делает teardown и выходит: при VPN-основном с zapret-ВЫХОДОМ
	# выбор «Десинк» у категории не проводнялся вообще — правило выглядело живым и молчало
	# (вопрос подписчика 07.09.2026). Отдаём второй признак отдельным полем, чтобы панель могла не
	# предлагать действие, которого сейчас нет. Читаем ТОТ ЖЕ файл, что и владелец-гейт.
	_zon=false; [ -f "$ENODIA_STATE/.zapret-on" ] && _zon=true
	printf '{"update_state":"%s","upd_done":%s,"upd_queue":%s,"now":%s,"set_vpn":%s,"set_out":%s,"set_blk":%s,"set_dsy":%s,"zapret":%s,"zapret_on":%s,"dns_route":%s,"dns_block":%s,' \
		"$st" "$_pdone" "$_pq" "$(date +%s)" "$(ipset_count "$SET_VPN")" "$(ipset_count "$SET_OUT")" "$(ipset_count "$SET_BLK")" "$(ipset_count "$SET_DSY")" "$_zi" "$_zon" "$(dns_dom_count)" "$(dns_blk_count)"
}
# Вердикт о взаимном перекрытии категорий — СЧИТАЕТ РОУТЕР (в момент сборки), панель только
# показывает. Своей арифметики во фронте не заводить: ACCEPT-приоритет — свойство цепочек
# mangle, а не интерфейса, и вторая его модель разъехалась бы с первой на первой же правке.
# Файла нет (сборки после обновления ещё не было) — отдаём probed:0, и панель молчит, а не
# рапортует «конфликтов нет»: это РАЗНЫЕ утверждения.
emit_overlap() {
	_ovl=$(cat "$GEO/.overlap" 2>/dev/null | head -1)
	_ov_t=$(printf '%s' "$_ovl" | cut -f1); _ov_p=$(printf '%s' "$_ovl" | cut -f2)
	_ov_h=$(printf '%s' "$_ovl" | cut -f3); _ov_d=$(printf '%s' "$_ovl" | cut -f4)
	for _v in _ov_t _ov_p _ov_h _ov_d; do
		eval "_vv=\$$_v"; case "$_vv" in ''|*[!0-9]*) eval "$_v=0" ;; esac
	done
	printf ',"overlap":{"total":%s,"probed":%s,"hits":%s,"domains":%s}' "$_ov_t" "$_ov_p" "$_ov_h" "$_ov_d"
}
emit_json() {
	emit_head
	_ramtot=$(awk '/^MemTotal:/{print $2*1024; exit}' /proc/meminfo 2>/dev/null)
	case "$_ramtot" in ''|*[!0-9]*) _ramtot=0 ;; esac
	printf '"ram":{"per_dom_b":498,"per_cidr_b":43,"total_b":%s},"items":[' "$_ramtot"
	# items: каталог (до ~1600 строк при v2fly) мёржим с реестром действий ОДНИМ awk-проходом — без
	# форков на элемент (иначе ~1400 сервисов × reg_get/jesc = десятки секунд на открытие панели).
	# catalog_lines использует '|' → конвертируем в TAB (ни одно поле каталога '|' не содержит), REG уже
	# TAB. FILENAME-дискриминатор (не FNR==NR: пустой REG сбил бы счётчик первого файла). JSON-эскейп не
	# нужен: имена/лейблы/desc каталога в безопасном наборе, кавычек/бэкслешей нет (busybox/gawk давятся
	# gsub(/\\/) — см. providers-блок ниже, там та же причина).
	_cf="$RAM/.emit-cat.$$"
	catalog_lines | tr '|' '\t' > "$_cf" 2>/dev/null
	awk -F'\t' -v RG="$REG" '
		FILENAME==RG { act[$1]=$2; cnt[$1]=$3; ts[$1]=$4; slt[$1]=$5; next }
		{
			if($2=="") next
			a=act[$2]; if(a=="") a="off"
			c=cnt[$2]; if(c !~ /^[0-9]+$/) c=0
			t=ts[$2];  if(t !~ /^[0-9]+$/) t=0
			s=slt[$2]; if(s !~ /^[2-7]$/) s=0
			if(f) printf(","); f=1
			printf("{\"type\":\"%s\",\"key\":\"%s\",\"label\":\"%s\",\"kind\":\"%s\",\"approx\":\"%s\",\"desc\":\"%s\",\"action\":\"%s\",\"count\":%s,\"ts\":%s,\"slot\":%s}",$1,$2,$3,$4,$6,$7,a,c,t,s)
		}
	' "$REG" "$_cf"
	rm -f "$_cf" 2>/dev/null
	printf ']'
	# Апстрим-даты источников (из $SHAS): панель показывает дату по активной вкладке (v2fly / runetfreedom).
	printf ',"upstreams":{"v2fly":"%s","rfip":"%s","rfgs":"%s","ipdeny":"%s"}' \
		"$(jesc "$(upstream_iso v2fly)")" "$(jesc "$(upstream_iso rfip)")" "$(jesc "$(upstream_iso rfgs)")" \
		"$(jesc "$(upstream_iso ipdeny)")"
	emit_overlap
	printf '}\n'
}
# ТОЛЬКО ВКЛЮЧЁННЫЕ КАТЕГОРИИ — для страницы «Маршрутизации», которая спрашивает их на КАЖДЫЙ показ раздела.
# `list` для этого не годится: каталог — это ~1900 строк через циклы sh, замер на BE7000 — 1,5 с и 305 КБ,
# а странице из них нужны три-пять. Реестр действий уже несёт всё, кроме подписи и типа, а их даёт ПРЕФИКС ключа
# (cat_type/cat_kind/cat_label — тот же резолв, что у сборки), поэтому каталог не читаем вовсе. Форма элемента —
# та же, что у `list` (без approx/desc, которые живут только в каталоге): у панели один разбор на оба ответа.
# ГОЛОВА `list` СЮДА НЕ ИДЁТ, и это замер, а не экономия на спичках: её счётчики сетов — это `ipset list` со ВСЕМ
# составом набора (на ядре 4.4 иначе не посчитать), а счётчики dnsmasq — grep по живому конфигу в 10 МБ при
# включённой рекламе; с ней верб отвечал 1 с вместо десятков мс (BE7000, 18.09.2026). Странице они не нужны.
# Ключ, чей префикс не знаем (реестр из будущей версии), пропускаем — вслепую его не назвать и не собрать.
emit_active() {
	printf '{"update_state":"%s","now":%s,"items":[' "$(upd_state)" "$(date +%s)"
	_af=0
	if [ -f "$REG" ]; then
		# ПУСТОЕ ПОЛЕ — ЗАГЛУШКОЙ `-` ДО `read`: таб для `read` — пробельный разделитель, и два таба подряд он СКЛЕИВАЕТ —
		# пустой счётчик сдвинул бы время в графу счётчика, а выход — во время (поймал стенд geo-active-test). awk поле
		# не теряет; заглушку ниже сводит к нулю та же проверка, что и мусор. Он же дописывает перевод строки последней
		# строке реестра — без него busybox `read` её бы потерял.
		awk -F"$TAB" -v OFS="$TAB" '{ for(i=1;i<=5;i++) if($i=="") $i="-"; print }' "$REG" 2>/dev/null | \
		while IFS="$TAB" read -r _ak _aa _ac _at _as _arest; do
			case "$_aa" in vpn|bypass|block|desync) ;; *) continue ;; esac
			# Ключ уходит в JSON без экранирования — пропускаем всё, что не из набора имён каталога.
			case "$_ak" in ''|*[!A-Za-z0-9._!-]*) continue ;; esac
			_aty=$(cat_type "$_ak"); [ -n "$_aty" ] || continue
			case "$_ac" in ''|*[!0-9]*) _ac=0 ;; esac
			case "$_at" in ''|*[!0-9]*) _at=0 ;; esac
			case "$_as" in [2-7]) ;; *) _as=0 ;; esac
			[ "$_af" = 1 ] && printf ','
			_af=1
			printf '{"type":"%s","key":"%s","label":"%s","kind":"%s","action":"%s","count":%s,"ts":%s,"slot":%s}' \
				"$_aty" "$_ak" "$(cat_label "$_ak")" "$(cat_kind "$_ak")" "$_aa" "$_ac" "$_at" "$_as"
		done
	fi
	printf ']'
	emit_overlap
	printf '}\n'
}

case "$1" in
	list) emit_json ;;
	active) emit_active ;;
	set)   # set <key> <vpn|bypass|block|desync|off> — записать выбор действия (мгновенно), сборку зовёт update/apply
		[ -n "$(cat_url "$2")" ] || { echo "неизвестный ключ гео"; exit 1; }
		case "$3" in vpn|bypass|block|desync|off) ;; *) echo "действие: vpn|bypass|block|desync|off"; exit 1 ;; esac
		reg_set "$2" "$3"
		echo "гео «$2»: $(case "$3" in vpn) echo 'в VPN' ;; bypass) echo 'мимо VPN' ;; block) echo 'заблокировано' ;; desync) echo 'в десинк' ;; *) echo 'выкл' ;; esac)"
		;;
	desync-list)   # что выбрано «в десинк» — key|label|доменов/адресов. Читает карточка Zapret:
		# вшитых категорий у неё больше нет, единственный источник выбора — этот реестр.
		_cf="$RAM/.dsy-cat.$$"
		catalog_lines | tr '|' '\t' > "$_cf" 2>/dev/null
		awk -F'\t' -v RG="$REG" '
			FILENAME==RG { if($2=="desync"){ act[$1]=1; cnt[$1]=$3 } next }
			{ if($2=="" || !act[$2]) next
			  c=cnt[$2]; if(c !~ /^[0-9]+$/) c=0
			  printf("%s|%s|%s\n",$2,$3,c) }
		' "$REG" "$_cf" 2>/dev/null
		rm -f "$_cf" 2>/dev/null
		;;
	slot)  # slot <key> <0|2..7> — привязать категорию к доп-выходу (0 = основной; только action=vpn).
	       # Пишет ТОЛЬКО реестр (мгновенно, как set) — пересборку зовёт фронт следом (geo_apply).
		[ -n "$(cat_url "$2")" ] || { echo "неизвестный ключ гео"; exit 1; }
		case "$3" in 0|[2-7]) ;; *) echo "слот: 0|2..7"; exit 1 ;; esac
		_ln=$(reg_get "$2"); [ -n "$_ln" ] || { echo "категория выключена — сначала выберите действие"; exit 1; }
		if [ "$3" != 0 ] && [ "$(printf '%s' "$_ln" | cut -f2)" != vpn ]; then
			echo "доп-выход только для действия «в VPN»"; exit 1
		fi
		awk -F"$TAB" -v OFS="$TAB" -v k="$2" -v s="$3" '$1==k{$5=s} {print}' "$REG" > "$REG.new" && mv "$REG.new" "$REG"
		echo "выход: $([ "$3" = 0 ] && echo 'Основной' || echo "слот №$3")"
		;;
	# want <consumer> [<key>…] — the consumer's whole set of keys (none = it wants nothing); domain and cidr keys alike — each
	# kind comes to the consumer in its own forms (want_forms)
	want)
		case "$2" in ''|*[!a-z0-9-]*) echo "потребитель: [a-z0-9-]"; exit 1 ;; esac
		_wc="$2"; shift 2
		# a key the catalogue does not know is SKIPPED (said once on stdout), not a refusal of all: one stale or hand-edited pool
		# of a schedule stopped the downloads of every schedule's categories (review s.112, round 3)
		_wok=""; _wbad=""
		for _wn in "$@"; do
			case "$_wn" in */*|.*|*[!a-z0-9._!-]*) _wbad="$_wbad $_wn"; continue ;; esac   # a key becomes a file name
			if [ -n "$(cat_url "$_wn")" ] && [ -n "$(cat_kind "$_wn")" ]; then _wok="$_wok $_wn"; else _wbad="$_wbad $_wn"; fi
		done
		[ -z "$_wbad" ] || echo "неизвестный ключ гео:$_wbad — пропущен"
		mkdir -p "$WANT_DIR" 2>/dev/null
		if [ -z "$_wok" ]; then rm -f "$WANT_DIR/$_wc"; exit 0; fi
		printf '%s\n' $_wok | sort -u > "$WANT_DIR/.$_wc.$$" && mv -f "$WANT_DIR/.$_wc.$$" "$WANT_DIR/$_wc" ;;
	# ready <key>… — «<key><TAB><kind><TAB><path>» for every READY form of the keys (want_forms): the RAM cache, or the flash
	# snapshot put back into it. A key with neither is left out (the consumer goes without it until `wanted` brings it) — never a
	# fetch here. A cidr key is ready by its `@4` (a `cidr` line); its `cidr6` line follows only then, and only when `@6` is not
	# empty. One call for all keys: the schedule tick asks every minute while a device is limited.
	ready)
		shift
		for _wn in "$@"; do
			case "$_wn" in */*|.*|*[!a-z0-9._!-]*) continue ;; esac
			[ -n "$(cat_url "$_wn")" ] || continue
			_wrd=0
			for _wf in $(want_forms "$_wn" | awk '{ print $1 }'); do
				_wc="$CACHE/$_wf"
				if [ ! -f "$_wc" ] && [ -f "$WSNAP/$_wf.gz" ]; then
					gunzip -c "$WSNAP/$_wf.gz" > "$_wc.$$" 2>/dev/null && mv -f "$_wc.$$" "$_wc"
					rm -f "$_wc.$$" 2>/dev/null
				fi
				case "$_wf" in
					*@4) if [ -f "$_wc" ]; then _wrd=1; printf '%s\tcidr\t%s\n' "$_wn" "$_wc"; fi ;;
					*@6) if [ "$_wrd" = 1 ] && [ -s "$_wc" ]; then printf '%s\tcidr6\t%s\n' "$_wn" "$_wc"; fi ;;
					*)   if [ -s "$_wc" ]; then printf '%s\tdomain\t%s\n' "$_wn" "$_wc"; fi ;;
				esac
			done
		done
		exit 0 ;;
	# about <key>… — «<key><TAB><kind><TAB><type><TAB><label>» for every key the catalogue offers (cat_known): what a consumer
	# checks a key by before keeping it, and shows it as — without reading the whole catalogue (`list` is 1.5 s on BE7000)
	about)
		shift
		for _wn in "$@"; do
			case "$_wn" in */*|.*|*[!a-z0-9._!-]*) continue ;; esac
			cat_known "$_wn" || continue
			printf '%s\t%s\t%s\t%s\n' "$_wn" "$(cat_kind "$_wn")" "$(cat_type "$_wn")" "$(cat_label "$_wn")"
		done
		exit 0 ;;
	# wanted — fetch what the consumers want and is not in RAM yet (a background job of the consumer's save). Waits for the geo
	# lock instead of riding a build: a build pass ends with a dnsmasq restart the save must not cost the house.
	wanted)
		_wi=0
		until ls_lock_take "$GEO_LOCK" "$RAM/.wanted.wait" 1; do
			_wi=$((_wi + 1)); [ "$_wi" -le 720 ] || exit 1   # an hour: an update of everything is the longest holder
			sleep 5
		done
		rm -f "$RAM/.wanted.wait" 2>/dev/null
		trap 'ls_lock_drop "$GEO_LOCK"' EXIT
		trap 'exit 1' INT TERM HUP PIPE
		# `refresh` — every wanted key fetched AGAIN: the daily lists job on a router with no Гео action (an `update` refreshes
		# them in its pass; without actions nothing ran it, and Telegram's network stayed at its first download — review s.112)
		# …and AGAINST THE UPSTREAM'S NEWEST COMMIT, as `update` does: the URLs are pinned to the commit in $SHAS (jsDelivr
		# `@<sha>` never changes), and without moving the pin «again» re-fetched the same bytes every day (review s.113, round 4)
		_wpr=0; if [ "${2:-}" = refresh ]; then resolve_upstream; set_source_urls; _wpr=1; fi
		# A consumer that saved WHILE we ran (its `wanted` found us running and left) — a pass reads the keys once at its start, and
		# the new key waited for the daily job (review s.113, round 4): the pass again while the wanted set moved, refetch only once
		_wpi=0
		while :; do
			_wps=$(want_keys | md5sum)
			_wanted_pass "$_wpr"; _wpr=0
			[ "$(want_keys | md5sum)" = "$_wps" ] && break
			_wpi=$((_wpi + 1)); [ "$_wpi" -lt 8 ] || break
		done
		trap - EXIT INT TERM HUP PIPE; ls_lock_drop "$GEO_LOCK"
		# A build that arrived while we held the lock only left its mark (do_build: «учту свежий выбор в ней») and returned — the
		# holder is the one to run it, and that holder was us: a «Гео» action, «Обновить», the 5:00 update or `wire` after a
		# reload was lost otherwise (review s.112, round 3). A fresh build of the mark's kind; do_build loops on a new mark itself.
		if [ -f "$GEO_DIRTY" ]; then
			case "$(cat "$GEO_DIRTY" 2>/dev/null | tr -d ' \r\n')" in 1) exec sh "$0" update ;; *) exec sh "$0" apply ;; esac
		fi
		exit 0 ;;
	apply)   do_build 0 ;;     # собрать из кэша (быстро; после смены действия)
	update)  resolve_upstream; set_source_urls; v2fly_enumerate; do_build 1 ;;   # SHA+даты → пиновка URL → перечислить v2fly (rf=baked) → перекачать (пиновано) + собрать
	reapply) do_reapply ;;     # офлайн из снимка (boot)
	# Только ЦЕПОЧКА «Блока» после сноса правил (firewall reload) — зовёт починка правил (`vpn-toggle.sh repair|rules`). Наборы в
	# ОЗУ reload переживают, марку и «мимо» возвращают mark-core и apply-bypass той же починки; `reapply` перезалил бы наборы и
	# перезапустил dnsmasq на каждый reload. Признак «блок есть» — тот же снимок, по которому его ставит reapply.
	# ПОД ЛОКОМ СБОРКИ: `geo_block_wire` — это flush цепочки и `-C || -I` прыжков, и параллельно с проходом сборки (он зовёт то же)
	# оба `-C` могли промахнуться — ДВА прыжка в ENODIA_GEOBLK; тогда снятие «Блока» убирало один, `-X` не проходил, и цепочка с
	# прыжком жила до ребута (ревью хвостов dev233). Лок занят ⇒ метим dirty (прежнее значение не понижаем — «1» = просили
	# перекачку): держатель пройдёт ещё раз из кэша и проведёт цепочку сам — и после reload, пришедшего посреди его прохода.
	wire)
		[ -s "$SNAP_BLK" ] || exit 0
		_gwd=$(cat "$GEO_DIRTY" 2>/dev/null | tr -d ' \r\n'); [ "$_gwd" = 1 ] || _gwd=0
		ls_lock_take "$GEO_LOCK" "$GEO_DIRTY" "$_gwd" || exit 0
		trap 'ls_lock_drop "$GEO_LOCK"' EXIT
		trap 'exit 1' INT TERM HUP PIPE
		geo_block_wire
		trap - EXIT INT TERM HUP PIPE; ls_lock_drop "$GEO_LOCK"
		exit 0 ;;
	# Снесена ли цепочка «Блока», которая обязана стоять: 0 — стоит (или «Блока» нет), 3 — снесена, иное — не знаю (1 отдаёт любой
	# общий отказ скрипта — «снесено» им быть не может). Признак «обязана» —
	# ТОТ ЖЕ снимок, что у `wire`. Спрашивает сторож при выключенном VPN (хвост 10 ревью dev233).
	wired)
		[ -s "$SNAP_BLK" ] || exit 0
		command -v ipt_jump_state >/dev/null 2>&1 || exit 2
		ipt_jump_state INPUT ENODIA_GEOBLK; _gwi=$?
		ipt_jump_state FORWARD ENODIA_GEOBLK; _gwf=$?
		[ "$_gwi" = 2 ] || [ "$_gwf" = 2 ] && exit 2
		[ "$_gwi" = 0 ] && [ "$_gwf" = 0 ] && exit 0
		exit 3 ;;
	enabled) geo_enabled && echo 1 || echo 0 ;;
	provider)     provider_get "$2" ;;         # provider <type> → выбранный pid (дормант)
	provider-set)                              # provider-set <type> <pid> → дормант (панель без дропдауна)
		provider_set "$2" "$3" || exit 1
		do_build 0 >/dev/null 2>&1
		echo "провайдер [$2] → $3"
		;;
	freshness) resolve_upstream; echo ok ;;    # обновить $SHAS (sha+даты; панель зовёт async при открытии)
	*)
		echo "geo.sh — гео-категории (страны/сервисы/заблок-в-РФ → в VPN / мимо VPN / блок)"
		echo "  list | active | set <key> <vpn|bypass|block|desync|off> | slot <key> <0|2..7> | apply | update | reapply | enabled"
		echo "  desync-list | want <consumer> [<key>…] | ready <key>… | about <key>… | wanted"
		echo "  provider <type> | provider-set <type> <pid> | freshness"
		exit 1
		;;
esac
