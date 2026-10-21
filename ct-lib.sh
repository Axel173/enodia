#!/bin/sh
# ct-lib.sh — ЕДИНСТВЕННЫЙ ответ проекта на вопрос «сбросить УЖЕ УСТАНОВЛЕННЫЕ соединения»,
# чтобы только что поставленное правило начало действовать СЕЙЧАС, а не когда сайт отвиснет сам.
# Сорсится (`. ct-lib.sh`), сам ничего не печатает и не меняет.
# Owns ONE kernel rule (`ct_mark_save`: the packet mark copied into the ct mark) — only so a flush can be scoped to one path
# (`ct_flush_slot`/`ct_flush_route`, the section below).
#
# ЗАЧЕМ ВООБЩЕ. Qualcomm NSS/ECM ускоряет уже установленные потоки в железе: пакеты такого потока
# netfilter БОЛЬШЕ НЕ ВИДИТ. Поэтому у нас инвариант: любая ветка, меняющая mangle/ipset, обязана
# сбросить соединения — иначе правило есть, а эффекта ноль (см. карту проекта, «Грабли»).
#
# ГЛАВНАЯ ГРАБЛЯ (поймано на живом AX3600 17.08.2026). Строчка `conntrack -F >/dev/null 2>&1 ||
# true` жила россыпью по двум десяткам скриптов и МОЛЧА НИЧЕГО НЕ ДЕЛАЛА на ядре 4.4: в стоковой
# прошивке AX3600 утилиты conntrack НЕТ ВООБЩЕ (`sh: conntrack: not found`; на BE7000 она есть —
# /usr/sbin/conntrack). Гасилка `|| true` превращала отсутствие инструмента в «успех», а ускоритель
# при этом жив и работает — замерено в тот же момент: `ecm_db/connection_count` = 25 ускоренных
# потоков, `front_end_ipv4_stop` = 0. То есть на целом классе роутеров КАЖДОЕ изменение правил
# доезжало только до НОВЫХ соединений, а диагностировать это было нечем: ни строчки в логе.
#
# ЧЕМ ЛЕЧИМ БЕЗ УТИЛИТЫ. У самого ускорителя есть ручка `ecm_db/defunct_all` (debugfs): она снимает
# акселерацию со всех потоков, и пакеты возвращаются в медленный путь, где netfilter пересматривает
# их нашими свежими правилами. ЧЕСТНЫЕ ГРАНИЦЫ фолбэка, чтобы не выдавать его за равноценную
# замену: (1) записи conntrack он НЕ удаляет — привязки NAT у живых сессий остаются, то есть
# «жёсткого» разрыва, как у `conntrack -F`, не будет; (2) он ГЛОБАЛЬНЫЙ — точечные вербы
# (`ct_flush_src`/`ct_flush_dst`) на таком роутере вырождаются в общий сброс акселерации. Цена
# вырождения мала: соединения не рвутся, ускорение возвращается за секунды, — а вот обратная
# ошибка (правило «в VPN» не применилось) видна человеку сразу.
#
# ПОЧЕМУ НЕ ЗОВЁМ ЭТУ РУЧКУ ТАМ, ГДЕ УТИЛИТА ЕСТЬ: `conntrack -F` сам дёргает ECM через
# ecm_conntrack_notifier, то есть на BE7000 путь остаётся ПРЕЖНИМ БАЙТ-В-БАЙТ. Новое поведение
# появляется ровно там, где раньше не было никакого.

CT_ECM_DEFUNCT=/sys/kernel/debug/ecm/ecm_db/defunct_all   # ручка ускорителя (debugfs, root, 0644)
CT_PROC=/proc/net/nf_conntrack                            # таблица соединений — читается и без утилиты

_ct_have_tool() { command -v conntrack >/dev/null 2>&1; }

# Снять акселерацию со всех потоков. Молча возвращает 1, если ручки нет (не-NSS сборка) —
# вызывающие это не разбирают: сброс всегда best-effort, ронять из-за него ветку правил нельзя.
_ct_ecm_defunct() {
	[ -w "$CT_ECM_DEFUNCT" ] || return 1
	echo 1 > "$CT_ECM_DEFUNCT" 2>/dev/null || return 1
}

# ct_flush — сбросить ВСЁ. Прежний `conntrack -F >/dev/null 2>&1 || true` слово в слово.
ct_flush() {
	if _ct_have_tool; then conntrack -F >/dev/null 2>&1 || true; return 0; fi
	_ct_ecm_defunct || true
	return 0
}

# --- A FLUSH SCOPED TO ONE PATH (tester 20.10.2026: «one exit falls — games and RDP of the whole house drop») ---------------
# Every exit's slot-up/slot-down ended with ct_flush: one episode «exit dies → returns» was two house-wide `conntrack -F`. The
# stock wan zone answers an unknown packet with `tcp-reset`, so a server packet that arrived before the client's next one met no
# entry and got an RST: video reconnects quietly, a game or an RDP session drops. The flows that really change path on an exit's
# flap are the exit's own (its mark) and the carriers riding it as a road (`ip rule to <server> lookup 100N`).
#
# HOW A FLOW IS TOLD APART AFTER THE FACT. The packet mark (MARK 0xN in mangle) lives on packets, not on the connection; the ct
# mark is the connection's. ONE rule copies the low byte of the packet mark into the ct mark on every ORIGINAL-direction packet
# (mangle POSTROUTING, the last hook every forwarded and local packet passes — after any MARK+ACCEPT pair, so no family of rules
# changes). Original direction only: a reply carries mark 0 and would wipe the flow's mark. The low byte only: our marks are
# 0x1 (main) and 0x2..0xN (exits); nfqws's own 0x40000000 and anything the stock puts above stay out. Measured 20.10.2026: BE7000
# (5.4, iptables 1.6.2, conntrack 1.4.4) and AX3600 (4.4) take the rule; the ct mark was free on both (every entry mark=0).
#
# FAIL-SAFE. A scoped flush that finds no such rule in the kernel (an fw3 reload wiped mangle, an old mark-core, the rule refused)
# would delete NOTHING — every flow would read mark 0 — so it falls back to the global flush: never less than before. Flows that
# began before the rule went in carry mark 0 too; the kernel paths that put it in (boot heal, repair after an update) flush
# globally themselves. Without the conntrack tool (kernel 4.4) everything degrades to the accelerator knob, as the rest of this file.
#
# WHO STILL FLUSHES GLOBALLY, AND WHY: a transport switch, FAILOPEN, «Отключить VPN» and repair change more than one path at once
# (the DoH anchors' mark form, the tunnel resolver's route, every rule) — unmarked flows move there too; zapret marks nothing.
CT_MARK_MASK=0xff
# The rule goes in through ipt-lib.sh's wait for the xtables lock (ENODIA_DIR is the includer's, as for doh-lib/slot-tun-lib): a
# lock held by a stock cron would otherwise refuse it silently — and every scoped flush would fall back to the global one.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
CT_SAVE_CHAIN=POSTROUTING
CT_SAVE_SPEC="-m conntrack --ctdir ORIGINAL -m comment --comment enodia-ctmark -j CONNMARK --save-mark --nfmask $CT_MARK_MASK --ctmask $CT_MARK_MASK"

# ct_mark_save on|off|check — the ONLY owner of that rule. `on` (mark-core, every wiring) keeps it FIRST in the chain: zapret's
# wiring inserts its NFQUEUE at 1 too (after mark-core at boot), and NFQUEUE's verdict ends the chain for the packets it takes — a
# rule found lower is moved back to the top (review s.153 r1). `off` (mark-core unwire) removes every copy. `check` answers 0 only
# when the rule is there; any other answer of `-C` (lock, no module) is «not there» — the safe direction.
ct_mark_save() {
	case "$1" in
		on)    case "$(iptables -t mangle -S "$CT_SAVE_CHAIN" 2>/dev/null | sed -n 2p)" in *"--comment enodia-ctmark "*) return 0 ;; esac
		       while iptables -t mangle -D "$CT_SAVE_CHAIN" $CT_SAVE_SPEC 2>/dev/null; do :; done
		       iptables -t mangle -I "$CT_SAVE_CHAIN" 1 $CT_SAVE_SPEC 2>/dev/null ;;
		off)   while iptables -t mangle -D "$CT_SAVE_CHAIN" $CT_SAVE_SPEC 2>/dev/null; do :; done; return 0 ;;
		check) iptables -t mangle -C "$CT_SAVE_CHAIN" $CT_SAVE_SPEC 2>/dev/null ;;
		*)     return 1 ;;
	esac
}

# ct_flush_mark <mark> — the flows whose ct mark (its low byte) is <mark>.
ct_flush_mark() {
	[ -n "$1" ] || return 0
	if _ct_have_tool; then conntrack -D --mark "$1/$CT_MARK_MASK" >/dev/null 2>&1 || true; return 0; fi
	_ct_ecm_defunct || true
	return 0
}

# ct_flush_route <mark> <table> — the flows whose path goes through <table>: <mark> itself (asked even when its ip rule points
# elsewhere right now — a down exit with fallback=main sends its mark to 1000 until it is back) and, by the kernel's own rules
# (`ip rule`), every other mark and every destination (a road: `to <server> lookup 100N`) that leads into <table>.
ct_flush_route() {
	if ! _ct_have_tool || ! ct_mark_save check; then ct_flush; return 0; fi
	ct_flush_mark "$1"
	[ -n "$2" ] || return 0
	ip rule show 2>/dev/null | awk -v t="$2" '{
		l = ""; m = ""; d = ""
		for (i = 1; i < NF; i++) {
			if ($i == "lookup" || $i == "table") l = $(i + 1)
			if ($i == "fwmark") m = $(i + 1)
			if ($i == "to") d = $(i + 1)
		}
		if (l != t) next
		if (m != "") print "m " m; else if (d != "") print "d " d
	}' | while read -r _ctk _ctv; do
		case "$_ctk" in
			m) ct_flush_mark "${_ctv%%/*}" ;;
			d) ct_flush_dst "${_ctv%/32}" ;;
		esac
	done
	return 0
}

# ct_flush_slot <id> — an exit's flap: its mark 0x<id> and whatever rides its table 100<id>. A word that is not a number is a
# caller's error — the global flush, not a silent no-op.
ct_flush_slot() {
	case "$1" in ''|*[!0-9]*) ct_flush; return 0 ;; esac
	ct_flush_route "0x$1" "100$1"
}

# ct_flush_src <ip> — точечно по ИСТОЧНИКУ (не рвём сессии всей сети). Без утилиты вырождается в
# общий сброс акселерации — см. «честные границы» в шапке.
ct_flush_src() {
	[ -n "$1" ] || return 0
	if _ct_have_tool; then conntrack -D --src "$1" >/dev/null 2>&1 || true; return 0; fi
	_ct_ecm_defunct || true
	return 0
}

# ct_flush_src_n <ip> — то же, что ct_flush_src, но ПЕЧАТАЕТ число снятых записей. Отдельный верб,
# потому что число есть только у утилиты: без неё печатаем ПУСТО, и вызывающий не показывает
# человеку строку вовсе (прежний код печатал «Сброшено conntrack-записей: 0» там, где не сбрасывал
# ничего и сбросить не мог, — это ровно та ложь, которой в проекте не место).
ct_flush_src_n() {
	[ -n "$1" ] || return 0
	if _ct_have_tool; then conntrack -D --src "$1" 2>/dev/null | wc -l; return 0; fi
	_ct_ecm_defunct || true
	return 0
}

# ct_flush_dst <ip> [порт] — точечно по НАЗНАЧЕНИЮ (зациклившиеся сессии к endpoint'у VPS; с портом
# — конкретный сервис, напр. обратный SSH релея поддержки).
ct_flush_dst() {
	[ -n "$1" ] || return 0
	if _ct_have_tool; then
		if [ -n "$2" ]; then conntrack -D -p tcp -d "$1" --dport "$2" >/dev/null 2>&1 || true
		else                 conntrack -D -d "$1" >/dev/null 2>&1 || true; fi
		return 0
	fi
	_ct_ecm_defunct || true
	return 0
}

# ct_flush_dport <порт> — по ПОРТУ НАЗНАЧЕНИЯ, адрес не важен (сессии к сервису самого роутера:
# «закрыл доступ снаружи» обязан оборвать уже открытые снаружи соединения, иначе закрытие ложное).
ct_flush_dport() {
	[ -n "$1" ] || return 0
	if _ct_have_tool; then conntrack -D -p tcp --dport "$1" >/dev/null 2>&1 || true; return 0; fi
	_ct_ecm_defunct || true
	return 0
}

# ct_list_src <ip> — строки активных соединений клиента в формате `conntrack -L`. Без утилиты
# читаем ту же таблицу из /proc: строка там несёт те же поля `src=/dst=/sport=/dport=` плюс два
# ЛИШНИХ впереди (`ipv4 2`), а все потребители разбирают поля ПО ИМЕНИ, а не по номеру, — поэтому
# отдаём как есть. Фильтруем по ПЕРВОМУ `src=` (исходное направление), как `-s` у утилиты: полей
# src= в строке ДВА (оригинал и обратка), и голый grep поднял бы ещё и соединения, где наш адрес —
# ОТВЕТНАЯ сторона. У клиента за NAT это безобидно (первым dst= там идёт его же приватный адрес и
# он отсеется), но при порт-форварде снаружи первым dst= стоит WAN-адрес РОУТЕРА — и в списке
# устройства появился бы сам роутер. awk без index()/split() — busybox (см. карту проекта).
ct_list_src() {
	[ -n "$1" ] || return 0
	if _ct_have_tool; then conntrack -L -s "$1" 2>/dev/null; return 0; fi
	[ -r "$CT_PROC" ] || return 0
	awk -v ip="$1" '{ for(i=1;i<=NF;i++) if (substr($i,1,4)=="src=") { if (substr($i,5)==ip) print; break } }' \
		"$CT_PROC" 2>/dev/null
	return 0
}

# ct_list_all — ВСЕ строки таблицы, без фильтра по источнику. Нужен тем, кто смотрит за СЕТЬЮ, а
# не за одним клиентом (сэмплер окна наблюдения в devwatch.sh). Отдельный верб, а не «ct_list_src
# без аргумента»: пустой аргумент у ct_list_src — это ошибка вызова, и молча возвращать ВСЮ таблицу
# вместо соединений одного клиента опаснее, чем ничего.
ct_list_all() {
	if _ct_have_tool; then conntrack -L 2>/dev/null; return 0; fi
	[ -r "$CT_PROC" ] || return 0
	cat "$CT_PROC" 2>/dev/null
	return 0
}

# ct_tool — ЧЕМ мы вообще умеем сбрасывать на этом роутере: conntrack | ecm | none. Нужен тем, кто
# ОБЪЯСНЯЕТ человеку («список соединений недоступен»), а не тем, кто сбрасывает: у сброса ответ
# один — best-effort. Печатает одно слово.
ct_tool() {
	if _ct_have_tool; then echo conntrack
	elif [ -w "$CT_ECM_DEFUNCT" ]; then echo ecm
	else echo none; fi
}
