#!/bin/sh
# dns-hosts.sh — статические DNS-hosts: оверрайд «домен → конкретный IP» (как «DNS hosts» в
# v2rayNG / файле /etc/hosts, но для ВСЕЙ локалки через dnsmasq). Зачем: прибить домен к
# нужному IP (обход гео-CDN, локальный сервис, тест конкретного зеркала, фикс кривого резолва).
#
#   dns-hosts.sh add <домен> <ip>   — upsert (домен = ключ, IPv4 или IPv6)
#   dns-hosts.sh del <домен>        — убрать
#   dns-hosts.sh list               — JSON [{"domain":..,"ip":..,"solo":true|false}] для панели (solo — разбор у fam_solo)
#   dns-hosts.sh apply              — перегенерить живой conf из персиста + reload dnsmasq
#   dns-hosts.sh build              — только перегенерить conf (БЕЗ reload; для heal-цепочки)
#
# ГДЕ ЖИВЁТ (грабля adblock disable-leak — НЕ повторять):
#   персист-ИСТОЧНИК  $ENODIA_STATE/.dns-hosts       — строки "домен<TAB>ip", на /data (переживает ребут)
#   живой КОНФИГ      /tmp/dnsmasq.d/08-dns-hosts.conf  — address=/домен/ip, В ЖИВОМ conf-dir
#     (НЕ /etc/dnsmasq.d: стоковый init.d dnsmasq на рестарте cp -a /etc/* → /tmp АДДИТИВНО без
#      чистки → удаление из /etc не убирает копию из /tmp; пишем сразу в /tmp). /tmp=RAM → на
#      буте conf пересобирает heal.sh (`dns-hosts.sh apply`), персист на /data живёт.
#
# reload: `address=` SIGHUP НЕ перечитывает → нужен полный рестарт dnsmasq (как adblock). Блип
# DNS ~1с на весь LAN — терпимо (соединения не рвутся), делаем ТОЛЬКО при реальном изменении.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
SRC="$ENODIA_STATE/.dns-hosts"
CONFDIR=/tmp/dnsmasq.d
CONF="$CONFDIR/08-dns-hosts.conf"
TAB=$(printf '\t')

# Рестарт — ЧЕРЕЗ dns-merge.sh: он объявлен единственной точкой рестарта dnsmasq для подсистем,
# и вторая копия `/etc/init.d/dnsmasq restart` здесь была ровно тем дублем, который эта договорённость
# и запрещает. Прямой вызов остаётся ФОЛБЭКОМ — на роутере старше dns-merge.sh.
reload() {
	if [ -f "$ENODIA_DIR/dns-merge.sh" ]; then
		sh "$ENODIA_DIR/dns-merge.sh" reload >/dev/null 2>&1 && return 0
	fi
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# Спросить у dnsmasq, поднялся бы он с ЭТИМ файлом. Наш класс ошибки — ПОСТРОЧНЫЙ («Bad address in
# --address»), он виден и на изолированном файле, поэтому спрашивать о ЦЕЛОМ конфиге демона (как в
# dhcp-static.sh, где дубль `dhcp-host` межфайловый и в одиночку НЕ виден) здесь не требуется.
# Судим ПО ВЫВОДУ, а не по коду возврата: у dnsmasq есть классы, где он печатает «syntax check OK»
# и возвращает 0 на заведомо негодном значении (замерено 15.08.2026 на BE7000 и AX3600 — так ведут
# себя битый IP и дубль MAC в `dhcp-host`). Проверить нечем (нет бинаря) ⇒ не блокируем.
conf_test() {   # $1 = файл-кандидат
	[ -x /usr/sbin/dnsmasq ] || return 0
	_ct=$(/usr/sbin/dnsmasq --test -C "$1" 2>&1)
	case "$_ct" in
		*"syntax check OK"*) return 0 ;;
		"") return 0 ;;
	esac
	printf '%s' "$_ct" | tail -2 >&2
	return 1
}

# Валидация (значения уходят В ФАЙЛ конфига, не в шелл; всё равно строго — чтобы не сломать
# синтаксис dnsmasq и не пустить мусор). Домен: метки [A-Za-z0-9-], ≥2 (есть точка). IP: v4 или
# «голый» v6 (hex+двоеточия) — dnsmasq сам добьёт валидацию, нам важно отсечь спецсимволы/слэш.
# Проверка ЗДЕСЬ СТРОЖЕ общей `dns-lib.sh::dom_ok` (та — синтаксический пол для ЛЮБОЙ dnsmasq-строки:
# метка ≤63) и остаётся своей сознательно: `address=` прибивает домен к адресу на всю сеть, поэтому
# «_» и метку, начинающуюся с дефиса, тут не пускаем. Общий пол она не нарушает — те же 63.
valid_domain() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'; }
# IP. Регулярка отвечает только за ФОРМУ и про диапазон октета не знает — `192.168.31.999` ей
# нравится, а «dnsmasq сам добьёт валидацию» оказалось опасным допущением: он её добивает ОТКАЗОМ
# СТАРТОВАТЬ. ЗАМЕРЕНО 15.08.2026 на обоих роутерах (`dnsmasq --test`): `192.168.31.999`,
# `256.256.256.256`, `ffff`, `::::::::` и `deadbeef` старую проверку ПРОХОДИЛИ, а демон на таком
# `address=` падает с «Bad address in --address» — то есть ОДНА опечатка в поле «домен → IP»
# оставляла БЕЗ DNS всю локальную сеть, и лечилось это только по SSH. Путь из панели был открыт
# полностью: cgi-bin/action значение не проверяет вовсе и передаёт его сюда как есть.
# Поэтому: у IPv4 октеты сверяем ЧИСЛОМ, у IPv6 требуем хотя бы одно двоеточие (это отсекает
# `ffff`/`deadbeef`), а последнее слово всё равно за `conf_test` — он ловит и то, чего мы не учли.
valid_ipv4() {
	printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
	_vr="$1"
	for _vi in 1 2 3 4; do
		_vo=${_vr%%.*}; _vr=${_vr#*.}
		[ "$_vo" -ge 0 ] 2>/dev/null && [ "$_vo" -le 255 ] 2>/dev/null || return 1
	done
	return 0
}
valid_ip() {
	valid_ipv4 "$1" && return 0
	case "$1" in *:*) : ;; *) return 1 ;; esac
	printf '%s' "$1" | grep -qE '^[0-9A-Fa-f:]{2,45}$'
}

# Все строки, КРОМЕ домена $1, — ТОЧНЫМ сравнением поля, а не регуляркой `grep -v "^$d⇥"`: точка в домене у
# grep — «любой символ», и правка `a.b` молча сносила соседнее `axb` (ревью шага 5a, круг 1; стенд
# dev/dns-hosts-cgi-test.sh). Нет файла — пусто.
others_than() { [ -f "$SRC" ] && awk -F"$TAB" -v d="$1" '$1!=d' "$SRC"; }
# ДРУГАЯ СЕМЬЯ АДРЕСОВ. `address=/дом/<IPv4>` задаёт ответ на A, а что будет с AAAA, решает ВЕРСИЯ dnsmasq: с 2.86 запрос
# другой семьи уходит к upstream как обычно (замер BE7000, 2.86, 21.09.2026: заглушка 0.0.0.0 — AAAA от провайдера, `::` —
# A от провайдера); раньше, по документации, другая семья получала пустой ответ (AX3600 с 2.80 не замерен). Экран говорит
# «по IPv6 имя по-прежнему резолвится» ТОЛЬКО по этому ответу — на старом dnsmasq это было бы неправдой (ревью 5a, круг 2).
# 0 = с 2.86 и новее; 1 = старше или версию не разобрать (тогда экран о другой семье молчит).
fam_solo() {
	_fv=$(/usr/sbin/dnsmasq -v 2>/dev/null | sed -n '1s/^Dnsmasq version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
	[ -n "$_fv" ] || return 1
	set -- $_fv
	[ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "$2" -ge 86 ]; }
}

# Нормализация домена: срезать схему/www/путь, в нижний регистр.
norm_domain() { printf '%s' "$1" | sed -E 's|^https?://||; s|^www\.||; s|/.*$||' | tr 'A-Z' 'a-z'; }

build() {   # $1 = куда писать; по умолчанию ЖИВОЙ conf
	_bt="${1:-$CONF}"
	mkdir -p "$CONFDIR"
	if [ -s "$SRC" ]; then
		# каждая непустая строка "домен<TAB>ip" → address=/домен/ip
		awk -F"$TAB" 'NF>=2 && $1!="" && $2!=""{ printf "address=/%s/%s\n", $1, $2 }' "$SRC" > "$_bt.new" 2>/dev/null
		mv "$_bt.new" "$_bt" 2>/dev/null
	else
		rm -f "$_bt" 2>/dev/null
	fi
}

case "$1" in
	add)
		d=$(norm_domain "$2"); ip="$3"
		valid_domain "$d" || { echo "плохой домен"; exit 1; }
		valid_ip "$ip"    || { echo "плохой IP"; exit 1; }
		mkdir -p "$ENODIA_STATE"
		# Ступень отката: персист правим сразу, но КАНДИДАТА конфига собираем в /tmp и в живой
		# conf-dir кладём лишь после вердикта dnsmasq. Так негодная строка не появляется в
		# каталоге демона ВООБЩЕ — иначе чужой рестарт (нас зовут шесть подсистем) мог бы
		# подхватить её в это окно и оставить сеть без DNS.
		_dhb=/tmp/.enodia-dns-hosts.bak.$$
		[ -f "$SRC" ] && cp "$SRC" "$_dhb" 2>/dev/null
		{ others_than "$d"; printf '%s\t%s\n' "$d" "$ip"; } > "$SRC.new" 2>/dev/null
		mv "$SRC.new" "$SRC" 2>/dev/null
		_dhc=/tmp/.enodia-dns-hosts.cand.$$
		build "$_dhc"
		if [ -f "$_dhc" ] && ! conf_test "$_dhc"; then
			if [ -f "$_dhb" ]; then mv "$_dhb" "$SRC" 2>/dev/null; else rm -f "$SRC" 2>/dev/null; fi
			rm -f "$_dhc" "$_dhb" 2>/dev/null
			echo "dnsmasq не принял такой адрес — запись откачена, DNS не трогали"
			exit 1
		fi
		rm -f "$_dhc" "$_dhb" 2>/dev/null
		build; reload; echo "ok" ;;
	del)
		d=$(norm_domain "$2")
		[ -n "$d" ] || { echo "нет домена"; exit 1; }
		# Убирать НЕЧЕГО — так и сказать, а не «ок» с лишним рестартом DNS всей сети: панель писала «убрано» про
		# имя, которого уже не было (сняли с другого устройства). Сверка ТОЧНАЯ (awk по полю), а не регуляркой:
		# точка в домене у grep — «любой символ».
		awk -F"$TAB" -v d="$d" '$1==d{f=1} END{exit !f}' "$SRC" 2>/dev/null || { echo "такого имени нет"; exit 1; }
		if [ -f "$SRC" ]; then others_than "$d" > "$SRC.new" 2>/dev/null; mv "$SRC.new" "$SRC" 2>/dev/null; fi
		build; reload; echo "ok" ;;
	apply) build; reload; echo "ok" ;;
	build) build; echo "ok" ;;
	list)
		# `solo` — запрос ДРУГОЙ семьи по этому имени dnsmasq отвечает как обычно (разбор у fam_solo); нет поля — неизвестно.
		solo=false; fam_solo && solo=true
		printf '['
		first=1
		if [ -f "$SRC" ]; then
			while IFS="$TAB" read -r d ip; do
				[ -n "$d" ] || continue
				[ "$first" -eq 1 ] || printf ','
				printf '{"domain":"%s","ip":"%s","solo":%s}' "$d" "$ip" "$solo"
				first=0
			done < "$SRC"
		fi
		printf ']\n' ;;
	*) echo "usage: dns-hosts.sh add <домен> <ip> | del <домен> | list | apply | build" ;;
esac
