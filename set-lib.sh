#!/bin/sh
# set-lib.sh — ОБЩИЙ слой пересборки ipset-набора, у которого ДВА источника наполнения.
#
# ЗАЧЕМ ОТДЕЛЬНАЯ БИБЛИОТЕКА. Набор правил маршрутизации наполняется с двух сторон:
#   СТАТИКА  — CIDR-члены, которые человек записал в состав (группа, гео-категория);
#   ДИНАМИКА — A-записи, которые кладёт dnsmasq по `ipset=`-правилу В МОМЕНТ РЕЗОЛВА.
# Пересборка «с нуля из статики» (прежний fill_set, СВОЯ КОПИЯ в groups.sh и в geo.sh) на каждом
# apply ДИНАМИКУ ОБНУЛЯЛА. Прогрев резолвом это закрывает лишь частично: он знает имена ИЗ
# СОСТАВА, а у CDN резолвятся не они, а живые хосты, известные одним клиентам (`googlevideo.com`
# A-записи не имеет вовсе). Плюс следом идёт `conntrack -F`, и клиент переподключается НЕМЕДЛЕННО
# — пока набор ещё пуст.
#
# Чем это кончилось на железе 03.08.2026: правка ЛЮБОЙ группы (даже соседней, пустой) гасила
# ютуб на телевизоре — адрес кэша провайдера, осевший в наборе за день, исчезал, а ТВ держал его
# в своём кэше и уезжал НАПРЯМУЮ под нож DPI. Браузеры не страдали: они перерезолвивают быстро.
# Разбор — в заметках разработки «грабли-история».
#
# КОНТРАКТ. `set_sync <набор> <файл CIDR> [файл доменов]` — три ветки:
#   состав не изменился        → набор НЕ ТРОГАЕМ вовсе (самый частый случай: apply от heal, от
#                                слотов, от правки СОСЕДНЕЙ записи — именно он и ронял ютуб);
#   изменились только CIDR     → статику пересобираем, динамику ВОЗВРАЩАЕМ (домены-то те же);
#   изменился список доменов   → полная пересборка: адреса снятого домена висеть не должны.
# Снимка нет (первый apply после загрузки или обновления скриптов) → полная пересборка, как раньше.
#
# ПОЧЕМУ СНИМОК В /tmp: он ОБЯЗАН умирать вместе с наборами. И то и другое живёт в ОЗУ, так что
# после ребута снимка нет — иначе мы бы «сохраняли динамику» набора, которого уже не существует.
#
# Размер набора задаёт ПОТРЕБИТЕЛЬ (`SET_HASHSIZE`/`SET_MAXELEM`): у групп наборы мелкие, у гео —
# агрегаты стран на сотни тысяч подсетей. Читаются В МОМЕНТ ВЫЗОВА, поэтому порядок «сорснуть
# библиотеку / выставить переменные» значения не имеет. The family is the consumer's too
# (`SET_FAMILY=inet6`; empty = inet, the former form byte for byte): the access schedules' address sets live in both families.
#
# Потребители: groups.sh, geo.sh (у каждого guarded-source + шим на прежнее поведение — файла
# может не оказаться после частичного apply-scripts); access-sched.sh (static only — its sets have no dnsmasq side).

SET_SNAP=${SET_SNAP:-/tmp/.enodia-set-snap}

# Чем сравнивать снимок с текущим составом. `cmp` есть НЕ во всякой сборке busybox — в проекте его
# везде гардят (gh-update.sh, install.sh), и здесь гард нужен ОСОБЕННО: без него оба
# сравнения ниже возвращали бы «не совпало» (код 127), обе умные ветки не срабатывали бы никогда,
# и слой тихо выродился бы в прежний flush — то есть вернулась бы ровно та потеря динамики, ради
# которой он написан, и БЕЗ единого сообщения. Порядок фолбэков: md5sum потоковый (у гео агрегаты
# на сотни тысяч строк, их нельзя затаскивать в переменную), cat — последний рубеж.
if command -v cmp >/dev/null 2>&1; then _SL_EQ=cmp
elif command -v md5sum >/dev/null 2>&1; then _SL_EQ=md5
else _SL_EQ=cat; fi
_sl_same() {  # _sl_same <файл> <файл> — «содержимое одинаково»
	case "$_SL_EQ" in
		cmp) cmp -s "$1" "$2" ;;
		md5) [ "$(md5sum < "$1" 2>/dev/null)" = "$(md5sum < "$2" 2>/dev/null)" ] ;;
		*)   [ "$(cat "$1" 2>/dev/null)" = "$(cat "$2" 2>/dev/null)" ] ;;
	esac
}

set_drop() {  # set_drop <set> — the set and its snapshot away (a set recreated later must not inherit «the content is the same»)
	ipset destroy "$1" 2>/dev/null; _sl_dr=$?
	rm -f "$SET_SNAP-$1.cidr" "$SET_SNAP-$1.dom" 2>/dev/null
	return $_sl_dr
}

# v4 values a hash:net takes (v6 lines pass as they are: their form is the writer's); busybox awk: -F splits, no split()
# …a leading zero normalised to its decimal, as lists-lib.sh::cidr4_ok does (ipset would read `076` as octal and `08` as a host name)
_sl_vals() { awk -F'[./]' '/:/ { print; next } NF >= 4 && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 && (NF == 4 || ($5 >= 1 && $5 <= 32)) {
	if ($0 ~ /(^|[.\/])0[0-9]/) { o = ($1 + 0) "." ($2 + 0) "." ($3 + 0) "." ($4 + 0); if (NF >= 5) o = o "/" ($5 + 0); print o } else print }'; }

set_ensure() {  # set_ensure <набор> — создать, если его ещё нет
	ipset list -n 2>/dev/null | grep -qx "$1" && return 0
	ipset create "$1" hash:net ${SET_FAMILY:+family "$SET_FAMILY"} hashsize "${SET_HASHSIZE:-1024}" maxelem "${SET_MAXELEM:-65536}" 2>/dev/null
}

# set_fill <набор> <файл CIDR> [файл динамики] — атомарная замена содержимого.
# Пустой файл = пустой набор: это ВОЛЯ пользователя («убрал все адреса»), а не сбой закачки —
# тем и отличается от apply_ipset() в lists-lib.sh, который при нуле записей набор НЕ трогает.
# Заливка одним `ipset restore` (цикл add = форк на строку), swap на боевое имя, чтобы не было
# окна «набор пуст». Динамику льём в ТОТ ЖЕ новый набор ДО swap: дозаливка ПОСЛЕ него оставила бы
# окно, в котором маршрут уже обеднён.
set_fill() {
	# ${3:-}: библиотеку могут сорснуть из скрипта с `set -u`, где голый $3 = падение.
	_sl_s="$1"; _sl_f="$2"; _sl_x="${3:-}"
	set_ensure "$_sl_s"
	ipset destroy "${_sl_s}_new" 2>/dev/null
	ipset create "${_sl_s}_new" hash:net ${SET_FAMILY:+family "$SET_FAMILY"} hashsize "${SET_HASHSIZE:-1024}" maxelem "${SET_MAXELEM:-65536}" 2>/dev/null || return 1
	# A restore that stopped at a line it could not read filled the new set in HALF: that is not a set to swap in (review s.112 —
	# one typo among own addresses emptied the rest, Telegram's network included). The old one stays, the caller writes no
	# snapshot, the next call tries again. The pipe's status is ipset's (the last command).
	# Values ipset cannot read never reach it (_sl_vals: an octet over 255, a mask over 32 or /0 — groups.sh stores what is shaped
	# like an address): restore STOPS at such a line, so one typo in one group emptied the set every «in VPN» group shares
	# (review s.112, round 2). What is left and still refused is refused whole.
	if [ -s "$_sl_f" ]; then
		awk '/^[0-9]/{print $1}' "$_sl_f" | _sl_vals | awk -v s="${_sl_s}_new" '{print "add " s " " $0}' | ipset restore -exist 2>/dev/null || { ipset destroy "${_sl_s}_new" 2>/dev/null; return 1; }
	fi
	if [ -n "$_sl_x" ] && [ -s "$_sl_x" ]; then
		awk '/^[0-9]/{print $1}' "$_sl_x" | _sl_vals | awk -v s="${_sl_s}_new" '{print "add " s " " $0}' | ipset restore -exist 2>/dev/null || { ipset destroy "${_sl_s}_new" 2>/dev/null; return 1; }
	fi
	# Код возврата ЧЕСТНЫЙ и решает swap, а не последующий destroy: по нему вызывающий понимает,
	# можно ли записывать снимок «состав такой-то». Провалившийся swap (нет памяти, чужой набор с
	# тем же именем) оставляет боевой набор СТАРЫМ — и снимок о новом составе означал бы «дальше
	# не трогаем», то есть залипание до перезагрузки.
	if ! ipset swap "${_sl_s}_new" "$_sl_s" 2>/dev/null; then
		ipset destroy "${_sl_s}_new" 2>/dev/null
		return 1
	fi
	ipset destroy "${_sl_s}_new" 2>/dev/null
	return 0
}

# set_sync <набор> <файл CIDR> [файл доменов] — пересборка, НЕ теряющая адресов от dnsmasq.
# Файл доменов не передан/пуст = «динамики у набора не бывает» (напр. geo_block: его домены идут
# в dnsmasq через address=, а не ipset=) ⇒ ведёт себя как обычный set_fill со снимком.
set_sync() {
	_sl_ss="$1"; _sl_sf="$2"; _sl_sd="${3:-}"
	_sl_pc="$SET_SNAP-$_sl_ss.cidr"; _sl_pd="$SET_SNAP-$_sl_ss.dom"
	# ПИД в имени временных: apply групп и apply гео — РАЗНЫЕ процессы и могут идти одновременно
	# (общего лока у них нет), а на общих именах они топтали бы файлы друг друга.
	_sl_nc="/tmp/.enodia-set-sync.$$.cidr"; _sl_nd="/tmp/.enodia-set-sync.$$.dom"
	_sl_dy="/tmp/.enodia-set-sync.$$.dyn"; _sl_cur="/tmp/.enodia-set-sync.$$.cur"
	sort "$_sl_sf" 2>/dev/null > "$_sl_nc" || : > "$_sl_nc"
	if [ -n "$_sl_sd" ] && [ -f "$_sl_sd" ]; then sort "$_sl_sd" 2>/dev/null > "$_sl_nd" || : > "$_sl_nd"
	else : > "$_sl_nd"; fi
	: > "$_sl_dy"
	# Набор мог исчезнуть мимо нас (ребут, `slots.sh del`, чужой flush) — тогда снимок не аргумент.
	if [ -f "$_sl_pc" ] && [ -f "$_sl_pd" ] && ipset list -n 2>/dev/null | grep -qx "$_sl_ss" \
	   && _sl_same "$_sl_pc" "$_sl_nc" && _sl_same "$_sl_pd" "$_sl_nd"; then
		rm -f "$_sl_nc" "$_sl_nd" "$_sl_dy" "$_sl_cur" 2>/dev/null
		return 0
	fi
	# `-s "$_sl_nd"` обязателен: у набора БЕЗ доменов динамики не бывает по построению (наполнять
	# некому), и всё лишнее в нём — чужое. Без этого условия «пустой список доменов» совпадал бы
	# сам с собой, и мы бы бережно сохраняли мусор вместо честной пересборки (поймано стендом).
	if [ -s "$_sl_nd" ] && [ -f "$_sl_pc" ] && [ -f "$_sl_pd" ] && _sl_same "$_sl_pd" "$_sl_nd"; then
		# Всё, чего НЕ БЫЛО в прошлой статике, положил dnsmasq — домены те же, значит адреса живые.
		# Пустая прошлая статика = динамика ЦЕЛИКОМ, и это ОТДЕЛЬНАЯ ветка: идиома
		# `awk 'NR==FNR{a[$0]=1;next} !($0 in a)'` при ПУСТОМ первом файле считает своим весь
		# второй и молча съедает всё — потеря динамики ровно как в чинимом баге (поймано стендом).
		ipset save "$_sl_ss" 2>/dev/null | awk -v s="$_sl_ss" '$1=="add" && $2==s{print $3}' > "$_sl_cur"
		if [ -s "$_sl_pc" ]; then grep -Fxv -f "$_sl_pc" "$_sl_cur" > "$_sl_dy" 2>/dev/null || : > "$_sl_dy"
		else cat "$_sl_cur" > "$_sl_dy"; fi
	fi
	# Снимок пишем ТОЛЬКО после удачной заливки: иначе провал (нет памяти, набор занят) выглядел бы
	# как «состав применён», следующий apply ушёл бы в ветку «ничего не менялось» и набор остался бы
	# старым до перезагрузки — молча.
	if set_fill "$_sl_ss" "$_sl_sf" "$_sl_dy"; then
		cp "$_sl_nc" "$_sl_pc" 2>/dev/null; cp "$_sl_nd" "$_sl_pd" 2>/dev/null
		_sl_rc=0
	else
		rm -f "$_sl_pc" "$_sl_pd" 2>/dev/null   # снимка нет = следующий вызов пересоберёт честно
		_sl_rc=1
	fi
	rm -f "$_sl_nc" "$_sl_nd" "$_sl_dy" "$_sl_cur" 2>/dev/null
	# Код ВОЗВРАЩАЕМ честно. Раньше последней командой был `rm -f`, и функция всегда давала 0:
	# заливка провалилась (нет памяти, набор занят), снимок мы уже удалили — а вызывающий печатал
	# «набор собран». Ровно тот класс «правило вижу, эффекта нет», который вычищаем везде.
	return $_sl_rc
}
