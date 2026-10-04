#!/bin/sh
# lists-update.sh — генерик-драйвер «менеджера источников списков» (см. lists-lib.sh).
#
# Одна точка входа для ВСЕХ списков роутера. Категория = набор источников (url/файл/текст),
# наполняющих одну цель. Реализованные категории:
#   tunnel-cidr — ipset iplist_set   (CIDR через VPN; интегрируется с iplist-update.sh);
#   ipblock     — ipset blocklist_set + iptables DROP (блок вредоносных IP; off по умолчанию);
#   adblock     — dnsmasq address=/домен/0.0.0.0 (блок рекламы/трекеров; off по умолчанию);
#   zapret-cidr — ipset zapret_cidr  (пул десинка ПО IP для zapret.sh; off по умолчанию);
#   zapret-dom  — dnsmasq ipset=/домен/zapret_dom (СВОЙ пул десинка по доменам; off по умолчанию).
# (tunnel-domains / bypass-* — следующая фаза; реестр их уже держит, apply добавится.)
#
# Подкоманды:
#   update <cat>                         — собрать источники → нормализовать → дедуп → применить;
#   add-url <cat> <url> [fmt] [label]    — добавить источник-URL;
#   add-blob <cat> file|text <fmt> <label> <path> — добавить источник-файл/текст (содержимое в path);
#   del <cat> <id> | toggle <cat> <id> <0|1> | set-format <cat> <id> <fmt>;
#   enable <cat> <0|1>                   — мастер-переключатель категории (adblock/ipblock);
#   allow-set <cat> <path>               — задать исключения из файла (adblock — домены, ipblock —
#                                          IPv4/CIDR) и сразу применить; печатает kept/dropped/applied;
#   allow-sync                           — пересобрать набор «не блокировать» (blocklist_allow), если он есть;
#   guard-begin <cat>                    — начать проверку связи синхронно (код 1 — уже идёт), затем safe-enable;
#   list <cat>                           — JSON состояния для панели;
#   presets <cat>                        — JSON каталога готовых источников.
#
# update ДОЛГИЙ (закачки) → CGI запускает его фоном (spawn_bg) и опрашивает .update.state.
# Мутации реестра (add/del/toggle) мгновенные. Всё на /data — переживает ребут.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
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
# Под `[ -f ]` (инвариант проекта): провалившийся `.` в ash — фатальная ошибка спецбилтина, шелл
# выходит НА МЕСТЕ и молча. Библиотека здесь — весь движок, шима быть не может ⇒ честный отказ.
if [ -f "$ENODIA_DIR/lists-lib.sh" ]; then . "$ENODIA_DIR/lists-lib.sh"; else
	echo "нет $ENODIA_DIR/lists-lib.sh — обновите установку (панель → «Обновление» или переустановка с компьютера)" >&2; exit 1
fi

CMD="$1"; CAT="$2"

valid_cat() {
	case "$1" in tunnel-cidr|tunnel-domains|bypass-ip|adblock|ipblock|zapret-cidr|zapret-dom) return 0 ;; *) return 1 ;; esac
}
kind_of() {  # «вид» результата категории
	case "$1" in adblock|tunnel-domains|zapret-dom) echo domains ;; *) echo cidr ;; esac
}
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Миграция старого iplist.conf/iplist.custom в реестр tunnel-cidr (ОДНОКРАТНО). Делает систему
# самосогласованной: и панель (list), и iplist-update (update) видят ОДИН реестр независимо от
# того, кто обратился первым. Реестр уже есть → ничего не делает. custom-mode: only → url-источник
# не заводим (только файл); merge → оба включены; off/пусто → файл заводим ВЫКЛЮЧЕННЫМ (сохраняем,
# но не активен, как было). Источник-URL = как в iplist-update (URL / сайты / дефолт opencck).
migrate_tunnel_cidr() {
	_reg=$(reg_path tunnel-cidr); [ -f "$_reg" ] && return 0
	IPLIST_URL=''; IPLIST_SITES=''; IPLIST_CUSTOM_MODE=''; IPLIST_CUSTOM_FILE="$ENODIA_STATE/iplist.custom"
	[ -f "$ENODIA_STATE/iplist.conf" ] && . "$ENODIA_STATE/iplist.conf"
	_base='https://iplist.opencck.org/?format=text&data=cidr4'
	if   [ -n "$IPLIST_URL" ];   then _u="$IPLIST_URL"; _l="свой URL"
	elif [ -n "$IPLIST_SITES" ]; then _u="$_base"; for _s in $IPLIST_SITES; do _u="$_u&site=$_s"; done; _l="сайты: $IPLIST_SITES"
	else _u="$_base"; _l="весь список opencck"; fi
	[ "$IPLIST_CUSTOM_MODE" = only ] || reg_add tunnel-cidr url 1 cidr "$_l" "$_u" >/dev/null
	if [ -s "$IPLIST_CUSTOM_FILE" ]; then
		_en=0; [ -n "$IPLIST_CUSTOM_MODE" ] && _en=1
		_cid=$(reg_add tunnel-cidr file "$_en" cidr "iplist.custom" "")
		cp "$IPLIST_CUSTOM_FILE" "$(blob_path tunnel-cidr "$_cid")" 2>/dev/null
	fi
}
# tunnel-cidr всегда самомигрируется при первом обращении любой подкомандой.
[ "$CAT" = tunnel-cidr ] && migrate_tunnel_cidr

# --- Правила iptables/ipset для целей блокировки/маршрутизации (идемпотентно) ---
ensure_mark_rule() {  # tunnel-cidr: mangle MARK по iplist_set (как в iplist-update.sh)
	# ...кроме установки «только панель»: транспорта нет, `ip rule` никто не ставил, и метка
	# ложится в пустоту — зато В MANGLE ПОЯВЛЯЕТСЯ НАШЕ ПРАВИЛО на роутере, который обещан
	# человеку «как сток». Поймано на железе (AX3600, 15.08.2026): гард стоял в iplist-update.sh,
	# а наполнение делегировано СЮДА — и правило приходило этим путём. Владелец ответа один
	# (transport.sh configured); код 2 = старая копия скрипта ⇒ ведём себя как раньше.
	if [ -f "$ENODIA_DIR/transport.sh" ]; then
		sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1
		[ "$?" = 1 ] && return 0
	fi
	# ...и ТО ЖЕ САМОЕ, когда человек выключил VPN тумблером (.vpn-off, персист с 02.09.2026).
	# ЭТА ДВЕРЬ ВТОРАЯ, и ровно на ней 15.08.2026 уже обожглись с «только панелью»: гард стоял в
	# iplist-update.sh, а наполнение делегировано СЮДА. Замерено на живом AX3600 02.09.2026 —
	# при выключенном VPN метка вернулась именно этим путём.
	[ -f "$ENODIA_STATE/.vpn-off" ] && return 0
	iptables -t mangle -C PREROUTING -m set --match-set iplist_set dst -j MARK --set-mark 0x1 2>/dev/null || \
		iptables -t mangle -A PREROUTING -m set --match-set iplist_set dst -j MARK --set-mark 0x1 2>/dev/null
}
# ipblock: DROP трафика к/от вредоносных IP через ЕДИНУЮ цепочку ENODIA_BLK (джамп из INPUT+FORWARD).
# Порядок ВНУТРИ цепочки = 3 слоя защиты связи (см. lists-lib.sh collect_critical/ensure_allow_set):
#   1) blocklist_allow (VPS/WAN/DNS/LAN) → RETURN — критичные IP НИКОГДА не дропаем, даже если в списке;
#   2) DROP по SOURCE только с WAN-интерфейса (-i $wan) — LAN-источник структурно не отвалится;
#   3) DROP по DST (LAN/роутер → вредоносный адрес) — это и есть цель блокировки.
# Отдельная цепочка → teardown чистый (флаш+удаление), порядок правил гарантирован при любом апдейте.
ensure_block_rules() {
	ipset list -n 2>/dev/null | grep -qx blocklist_set || \
		ipset create blocklist_set hash:net hashsize 4096 maxelem 1000000 2>/dev/null
	ensure_allow_set                                   # слой 1: критичные IP в blocklist_allow
	_wif=$(wan_iface)
	del_legacy_block_rules                             # снять прямые правила старых версий (до ENODIA_BLK)
	if iptables -nL ENODIA_BLK >/dev/null 2>&1; then iptables -F ENODIA_BLK 2>/dev/null
	else iptables -N ENODIA_BLK 2>/dev/null; fi
	iptables -A ENODIA_BLK -m set --match-set blocklist_allow src -j RETURN 2>/dev/null
	iptables -A ENODIA_BLK -m set --match-set blocklist_allow dst -j RETURN 2>/dev/null
	[ -n "$_wif" ] && iptables -A ENODIA_BLK -i "$_wif" -m set --match-set blocklist_set src -j DROP 2>/dev/null
	iptables -A ENODIA_BLK -m set --match-set blocklist_set dst -j DROP 2>/dev/null
	iptables -C INPUT   -j ENODIA_BLK 2>/dev/null || iptables -I INPUT   -j ENODIA_BLK 2>/dev/null
	iptables -C FORWARD -j ENODIA_BLK 2>/dev/null || iptables -I FORWARD -j ENODIA_BLK 2>/dev/null
}
del_legacy_block_rules() {  # прямые INPUT/FORWARD-правила версий ДО цепочки ENODIA_BLK
	for spec in "FORWARD dst" "FORWARD src" "INPUT src"; do
		ch=${spec% *}; dir=${spec#* }
		while iptables -C "$ch" -m set --match-set blocklist_set "$dir" -j DROP 2>/dev/null; do
			iptables -D "$ch" -m set --match-set blocklist_set "$dir" -j DROP 2>/dev/null || break
		done
	done
}
del_block_rules() {
	iptables -D INPUT   -j ENODIA_BLK 2>/dev/null
	iptables -D FORWARD -j ENODIA_BLK 2>/dev/null
	iptables -F ENODIA_BLK 2>/dev/null
	iptables -X ENODIA_BLK 2>/dev/null
	del_legacy_block_rules
}
# ВАЖНО: пишем в ЖИВОЙ conf-dir dnsmasq (/tmp/dnsmasq.d), НЕ в /etc/dnsmasq.d. Стоковый
# init на рестарте делает `cp -a /etc/dnsmasq.d/* /tmp/dnsmasq.d/` (АДДИТИВНО, без чистки) —
# файл из /etc копируется в /tmp, но при ВЫКЛючении rm из /etc НЕ убирает стухшую копию в /tmp,
# и dnsmasq продолжал блокировать домены с adblock=off (поймано на железе 2026-07-11). Живём
# в /tmp: apply/teardown/count работают с ОДНИМ файлом, что реально читает dnsmasq. /tmp=RAM,
# на ребуте чистится → adblock переигрывает heal.sh (снимок тоже в RAM). SIGHUP address= не
# перечитывает → dnsmasq_reload делает полный рестарт (он и так конф-дир перечитывает).
adblock_conf() { echo /tmp/dnsmasq.d/06-adblock.conf; }

# zapret-cidr: пул десинка ПО IP. Сам ipset и правила (ACCEPT мимо туннеля + scoped NFQUEUE) ведёт
# zapret.sh — здесь ТОЛЬКО наполнение, чтобы не разъезжались два владельца одних правил. После
# заливки зовём идемпотентный `zapret.sh rewire`: он создаст сет, если его ещё нет, и довесит на
# него правила, когда zapret — активный транспорт. zapret не установлен → no-op: пул спокойно
# лежит на флеше и заработает при первом включении десинка.
ZAPRET_CIDR_SET=zapret_cidr
# Гард `-f`, а НЕ `-x`: зовём через `sh`, бит выполнения тут ничего не решает, а снятый (заливка
# по scp/base64, обновление скриптов) тихо выключал бы довеску правил на пул — класс Б5-9/Б6-7.
zapret_rewire() { [ -f "$ENODIA_DIR/zapret.sh" ] && sh "$ENODIA_DIR/zapret.sh" rewire >/dev/null 2>&1; return 0; }

# zapret-dom: СВОЙ пул десинка ПО ДОМЕНАМ (файл/URL/текст) рядом с курированной четвёркой категорий
# zapret.sh. Своя цель — свой сниппет dnsmasq и свой набор: «выключил свой пул» не должно задевать
# категории (и наоборот — teardown транспорта флашит только их набор). Сниппет живёт в ЖИВОМ
# /tmp/dnsmasq.d по той же грабле, что adblock (init копирует /etc→/tmp АДДИТИВНО, и rm из /etc не
# убирает стухшую копию ⇒ выключение не доезжало); на ребуте его переигрывает heal.sh 5.8 из
# ФЛЕШ-снимка (офлайн, без закачки — ровно как у zapret-cidr: десинк обязан работать без сервера).
ZAPRET_DOM_SET=zapret_dom
zapret_dom_conf() { echo /tmp/dnsmasq.d/07-zapret-dom.conf; }
# Набор ОБЯЗАН существовать до записи ipset=-строк: dnsmasq сам его НЕ создаёт (кладёт записи лишь в
# существующий). Параметры совпадают с ensure_set в zapret.sh — кто первый, тот и создал.
ensure_dom_set() {
	ipset list -n 2>/dev/null | grep -qx "$ZAPRET_DOM_SET" || \
		ipset create "$ZAPRET_DOM_SET" hash:net family inet hashsize 1024 maxelem 1000000 2>/dev/null
	return 0
}

applied_count() {  # текущий размер результата в цели (для UI)
	case "$1" in
		tunnel-cidr) ipset_count iplist_set ;;
		ipblock)     ipset_count blocklist_set ;;
		zapret-cidr) ipset_count "$ZAPRET_CIDR_SET" ;;
		zapret-dom)  grep -c '^ipset=/' "$(zapret_dom_conf)" 2>/dev/null ;;    # доменов в пуле = ipset=-строк
		adblock)     grep -c '/0\.0\.0\.0$' "$(adblock_conf)" 2>/dev/null ;;   # доменов = A-строк (не всех, их 2×)
		*) echo 0 ;;
	esac
}

# --- teardown при выключении категории --------------------------------------
teardown() {
	case "$1" in
		adblock) rm -f "$(adblock_conf)" 2>/dev/null; dnsmasq_reload ;;
		ipblock) del_block_rules; ipset flush blocklist_set 2>/dev/null; ipset destroy blocklist_allow 2>/dev/null; ct_flush ;;
		# zapret-cidr: сет ОПУСТОШАЕМ, но НЕ уничтожаем и правила НЕ трогаем — их владелец zapret.sh,
		# и он же держит на сете ссылку (destroy при живом правиле вернул бы «set is in use»).
		# Пустой сет = ноль совпадений = десинка по IP нет, ровно семантика «категория выключена».
		zapret-cidr) ipset flush "$ZAPRET_CIDR_SET" 2>/dev/null; ct_flush ;;
		# zapret-dom: снять сниппет (иначе dnsmasq продолжит наполнять пул) И опустошить СВОЙ набор —
		# он наш целиком, в отличие от zapret_set категорий. Правила на нём не трогаем: их владелец
		# zapret.sh, а пустой набор = ноль совпадений = ровно семантика «пул выключен».
		zapret-dom)  rm -f "$(zapret_dom_conf)" 2>/dev/null; dnsmasq_reload
		             ipset flush "$ZAPRET_DOM_SET" 2>/dev/null; ct_flush ;;
	esac
}

# --- update: собрать → нормализовать → применить ----------------------------
# Файл ПРОГРЕССА, который опрашивает панель, пишем АТОМАРНО (рядом + `mv`): `>` сперва обрезает, и опрос в это окно читал пусто —
# «кончилось» до конца (разбор у packages.sh::set_state; следит C105).
ustate() { _usd=$(ram_dir "$CAT"); echo "$1" > "$_usd/.update.state.new" && mv -f "$_usd/.update.state.new" "$_usd/.update.state"; }  # прогресс/лог — в ОЗУ (панель читает через list)
# gstate <каталог категории> <состояние> — вердикт проверки «Блокировки» по адресам (панель опрашивает его так же).
gstate() { echo "$2" > "$1/.guard.state.new" && mv -f "$1/.guard.state.new" "$1/.guard.state"; }
ulog()   { echo "$*" >> "$(ram_dir "$CAT")/.update.log"; }

# _update_pass: ОДИН проход — собрать источники реестра → нормализовать → применить в цель.
# Пишет в рабочие файлы ОЗУ $W (задан вызывающим do_update). Всегда под локом do_update; если
# реестр менялся во время прохода — do_update переиграет его ещё раз (dirty-повтор).
_update_pass() {
	echo "===== $(date) update $CAT ====="

	# Категория выключена (adblock/ipblock без .enabled) → снести цель, выйти.
	if ! cat_enabled "$CAT"; then
		echo "category disabled → teardown"
		teardown "$CAT"; return 0
	fi

	kind=$(kind_of "$CAT")
	reg=$(reg_path "$CAT")
	work=$W/.work; : > "$work"
	nsrc=0    # источников, реально давших данные в этом проходе
	# ВКЛЮЧЁННЫХ источников в реестре — независимо от того, скачались ли они. Разводит два разных
	# случая, которые по пустому результату не отличить: «источник умер/не скачался» (nen>0 — цель
	# НЕ обнуляем, поднимаем из снимка) и «пользователь удалил/выключил все источники» (nen=0 — цель
	# обязана опустеть, иначе снимок вернёт список, который человек только что убрал = «удалил, а всё
	# на месте»). Считается для ВСЕХ целей: доменный пул десинка, tunnel-cidr и zapret-cidr.
	# Про CIDR-цели раньше стояло «снимок всегда» с доводом «от опустошения зависит МАРШРУТИЗАЦИЯ,
	# цена ошибочного обнуления выше цены лишнего списка». Довод верен для СБОЯ и там сохранён
	# (nen>0 → снимок), но на выключение руками он не распространяется: там ошибки нет, есть
	# явное решение человека, а пустой пул — fail-open, а не блэкхол. Поймано пользователем
	# 14.08.2026: снял галку с opencck, панель сказала «применяю», iplist_set остался 3530 —
	# ровно снимок, и пережил бы ребут.
	nen=0

	if [ -f "$reg" ]; then
		while IFS="$TAB" read -r id type en fmt cnt ts label value; do
			[ -n "$id" ] || continue
			[ "$en" = 1 ] || { echo "skip $id (disabled)"; continue; }
			nen=$((nen + 1))
			raw=$W/.raw.$id; : > "$raw"
			case "$type" in
				url)
					# ОТМЕТКА ИСТОЧНИКА = время последней СВЕЖЕЙ закачки (шаг 5c): «обновлено N назад» у категории считается
					# по ней, и прежняя отметка на сбое (и на откате к кэшу) ставила «только что» списку, который сегодня не
					# скачался. Сбой без кэша: записей 0, отметка прежняя (никогда не качался — так и остаётся «не скачано»).
					fresh=1
					if fetch_url "$value" "$raw"; then
						cp "$raw" "$(cache_path "$CAT" "$id")" 2>/dev/null
						echo "src $id url ok: $value"
					elif [ -s "$(cache_path "$CAT" "$id")" ]; then
						cp "$(cache_path "$CAT" "$id")" "$raw"; fresh=0
						echo "src $id url FAILED → cache: $value"
					else
						echo "src $id url FAILED, no cache: $value"; reg_set_meta "$CAT" "$id" 0 "$ts"; rm -f "$raw"; continue
					fi ;;
				file|text)
					fresh=1
					if [ -s "$(blob_path "$CAT" "$id")" ]; then cp "$(blob_path "$CAT" "$id")" "$raw"
					else echo "src $id blob missing"; rm -f "$raw"; continue; fi ;;
				*) rm -f "$raw"; continue ;;
			esac
			# auto-формат: распознать для показа в UI (нормализация всё равно kind-driven).
			[ "$fmt" = auto ] || [ -z "$fmt" ] && { det=$(detect_format < "$raw"); reg_set_format "$CAT" "$id" "$det"; }
			norm=$W/.norm.$id
			normalize "$kind" "$fmt" < "$raw" | sort -u > "$norm"
			scnt=$(grep -c '' "$norm" 2>/dev/null); case "$scnt" in ''|*[!0-9]*) scnt=0 ;; esac
			cat "$norm" >> "$work"
			if [ "$fresh" = 1 ]; then reg_set_meta "$CAT" "$id" "$scnt" "$(date +%s)"; else reg_set_meta "$CAT" "$id" "$scnt" "$ts"; fi
			echo "src $id: $scnt записей ($kind)"
			nsrc=$((nsrc + 1)); rm -f "$raw" "$norm"
		done < "$reg"
	fi

	# Дедуп общего результата.
	all=$W/.all; sort -u "$work" > "$all" 2>/dev/null; rm -f "$work"
	total=$(grep -c '' "$all" 2>/dev/null); case "$total" in ''|*[!0-9]*) total=0 ;; esac
	echo "источников: $nsrc, суммарно уникальных: $total"

	# КАТЕГОРИЮ ВЫКЛЮЧИЛИ ПОСРЕДИ ПРОХОДА (закачка идёт минутами): выключение уже сняло правила, а этот проход поставил бы
	# их обратно — экран «выключена», а DROP работает до следующего прохода.
	if ! cat_enabled "$CAT"; then echo "category disabled during pass → teardown"; teardown "$CAT"; return 0; fi

	# Применить в цель.
	case "$CAT" in
		tunnel-cidr)
			# ЗАЩИТА ЛОКАЛКИ — третья причина для того же фильтра (у ipblock это DROP, у zapret-cidr
			# ACCEPT мимо туннеля, здесь — МАРКИРОВКА dst в туннель). Приватка/CGNAT/мультикаст в этом
			# пуле уводит в awg0 ровно то, что обязано жить в локалке: ответы роутера клиентам
			# (mangle OUTPUT метится по тому же сету), mDNS/SSDP-мультикаст, а у абонента за CGNAT —
			# его собственный WAN-шлюз 100.64/10. Хуже прочих тем, что снимок лежит на ФЛЕШЕ ⇒
			# переживает ребут. Не гипотеза: замерено 04.08.2026 на живом BE7000 — в текущем
			# opencck-листе 6 адресов 100.64/10, и тот же фильтр на zapret-cidr режет 884→880.
			# Свою приватку «в VPN» человек задаёт правилом адреса или группой (enodia_ip_vpn/grp_vpn) —
			# эти пути идут мимо фильтра, так что сценарий «корпоративная сеть 10.x через VPN» цел.
			_b=$(grep -c '' "$all" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
			strip_bogon 4 < "$all" > "$all.safe" && mv "$all.safe" "$all"   # порог 4, а не 8 — см. strip_bogon
			_a=$(grep -c '' "$all" 2>/dev/null); case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
			echo "tunnel-cidr bogon-фильтр: $_b → $_a CIDR (приватка/CGNAT вырезаны — защита LAN)"
			if n=$(apply_ipset iplist_set "$all"); then
				ensure_mark_rule; snap_write "$CAT" "$all"
				echo "iplist_set: $n записей"
			elif [ "$nen" = 0 ]; then
				# ВЫКЛЮЧИЛИ/УДАЛИЛИ ВСЕ ИСТОЧНИКИ РУКАМИ — это решение человека, а не авария.
				# Раньше сюда падал общий снимок-фолбэк и возвращал РОВНО ТОТ список, который
				# только что убрали: панель отвечала «Источник выключен — применяю», а пул
				# оставался прежним и переживал ребут (heal → iplist-update → сюда же). Снимок
				# обнуляем ВМЕСТЕ с сетом — иначе он воскресит список на следующем же прогоне.
				# Пустой пул безопасен: это fail-open (ничего не метится в туннель), не блэкхол.
				ipset flush iplist_set 2>/dev/null; ensure_mark_rule; snap_write "$CAT" "$all"
				echo "включённых источников нет → iplist_set очищен"
			else
				# пусто/сбой ПРИ ЖИВЫХ источниках — поднять из снимка (фолбэк, как в iplist-update.sh)
				if [ -s "$(snap_path "$CAT")" ]; then apply_ipset iplist_set "$(snap_path "$CAT")" >/dev/null && ensure_mark_rule; echo "источники пусты → снимок"
				else echo "источники пусты, снимка нет — set не тронут"; fi
			fi ;;
		ipblock)
			# ЗАЩИТА LAN: вырезать приватку/богоны/широкие маски ДО заливки в set и снимка — иначе
			# DROP по blocklist_set (INPUT/FORWARD) убьёт локалку (см. strip_bogon в lists-lib.sh).
			_b=$(grep -c '' "$all" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
			strip_bogon < "$all" > "$all.safe" && mv "$all.safe" "$all"
			_a=$(grep -c '' "$all" 2>/dev/null); case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
			echo "ipblock bogon-фильтр: $_b → $_a CIDR (приватка/широкие вырезаны — защита LAN)"
			ensure_block_rules
			if n=$(apply_ipset blocklist_set "$all"); then echo "blocklist_set: $n записей"
			else ipset flush blocklist_set 2>/dev/null; echo "blocklist пуст"; fi
			ct_flush
			snap_write "$CAT" "$all" ;;
		zapret-cidr)
			# ЗАЩИТА LAN — обязательна, причина ДРУГАЯ, чем у ipblock: на этот сет zapret вешает
			# `PREROUTING -m set --match-set … dst -j ACCEPT` ВЫШЕ маркировки mark-core. Приватка
			# или широкая маска в пуле вывела бы весь LAN-трафик мимо VPN (тихая утечка, а не
			# обрыв — заметить труднее, чем FireHOL-инцидент). strip_bogon режет то же самое.
			_b=$(grep -c '' "$all" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
			strip_bogon < "$all" > "$all.safe" && mv "$all.safe" "$all"
			_a=$(grep -c '' "$all" 2>/dev/null); case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
			echo "zapret-cidr bogon-фильтр: $_b → $_a CIDR (приватка/широкие вырезаны — защита LAN)"
			if n=$(apply_ipset "$ZAPRET_CIDR_SET" "$all"); then
				zapret_rewire; snap_write "$CAT" "$all"
				echo "$ZAPRET_CIDR_SET: $n записей"
			elif [ "$nen" = 0 ]; then
				# Симметрично tunnel-cidr: «выключил» обязано значить выключил (разбор — там же).
				ipset flush "$ZAPRET_CIDR_SET" 2>/dev/null; zapret_rewire; snap_write "$CAT" "$all"
				echo "включённых источников нет → $ZAPRET_CIDR_SET очищен"
			else
				# Источники пусты/сбой ПРИ ЖИВЫХ источниках — поднять из флеш-снимка (как
				# tunnel-cidr): мёртвый источник не должен молча обнулять пул десинка.
				if [ -s "$(snap_path "$CAT")" ]; then apply_ipset "$ZAPRET_CIDR_SET" "$(snap_path "$CAT")" >/dev/null && zapret_rewire; echo "источники пусты → снимок"
				else echo "источники пусты, снимка нет — set не тронут"; fi
			fi
			ct_flush ;;
		adblock)
			n=$(apply_dnsmasq_block "$(adblock_conf)" "$all" "$(allow_path "$CAT")")
			echo "adblock: $n доменов заблокировано"
			snap_write "$CAT" "$all" ;;
		zapret-dom)
			# Набор — ДО сниппета (dnsmasq иначе будет ругаться на несуществующий), правила — ПОСЛЕ
			# (rewire идемпотентен и молчит, когда десинк выключен: наполнение пула не «включает» zapret).
			ensure_dom_set
			if [ -s "$all" ]; then
				n=$(apply_dnsmasq_ipset "$(zapret_dom_conf)" "$all" "$ZAPRET_DOM_SET" "$(allow_path "$CAT")")
				zapret_rewire; snap_write "$CAT" "$all"
				echo "$ZAPRET_DOM_SET: $n доменов в пуле десинка"
			elif [ "$nen" = 0 ]; then
				# Включённых источников нет ВООБЩЕ (пользователь удалил/выключил все) → пул обязан
				# опустеть: снимаем сниппет и флашим свой набор. Снимок на флеше НЕ трогаем — вернуть
				# источник и не потерять офлайн-состав дороже, чем лишний файл.
				rm -f "$(zapret_dom_conf)" 2>/dev/null; dnsmasq_reload
				ipset flush "$ZAPRET_DOM_SET" 2>/dev/null
				echo "включённых источников нет → пул очищен"
			else
				# Источники пусты/сбой — поднять из флеш-снимка (как zapret-cidr): мёртвый источник не
				# должен молча обнулять пул десинка (для доменов «обнулить» = снять правила dnsmasq).
				if [ -s "$(snap_path "$CAT")" ]; then
					n=$(apply_dnsmasq_ipset "$(zapret_dom_conf)" "$(snap_path "$CAT")" "$ZAPRET_DOM_SET" "$(allow_path "$CAT")")
					zapret_rewire; echo "источники пусты → снимок ($n доменов)"
				else echo "источники пусты, снимка нет — пул не тронут"; fi
			fi ;;
	esac
	rm -f "$all"
	return 0
}

# do_update: сериализованная обёртка над _update_pass. Два прохода в один момент писали в ОДНИ
# рабочие файлы ОЗУ и реестр → врали счётчики в UI (spawn_bg в CGI сам rm-ил pidfile → дедуп
# start-stop-daemon не срабатывал; reconcile-триггеры src_add/del/toggle участили перекрытие).
# Первый берёт атомарный mkdir-лок; конкуренты помечают .update.dirty и выходят — держатель после
# прохода переиграет под свежий реестр, схлопнув N кликов в ОДИН доп. проход (тяжёлые закачки блок-
# листов второй раз не тянем). Лок в ОЗУ (/tmp) — на ребуте чистится сам; убитый PID детектим по /proc.
# Механика лока — общая `ls_lock_take`/`ls_lock_drop` в lists-lib.sh (её же использует geo.sh do_build).
do_update() {
	valid_cat "$CAT" || { echo "unknown category: $CAT" >&2; return 2; }
	W=$(ram_dir "$CAT")                       # ОЗУ: сюда ВСЕ закачки/рабочие файлы (не на флеш!)
	lock="$W/.update.lock"
	ls_lock_take "$lock" "$W/.update.dirty" || return 0   # держатель жив → он переиграет под свежий реестр
	trap 'ls_lock_drop "$lock"' EXIT
	trap 'exit 1' INT TERM HUP PIPE

	: > "$W/.update.log"; ustate RUNNING
	exec >>"$W/.update.log" 2>&1
	while :; do
		rm -f "$W/.update.dirty"   # сброс ДО чтения реестра: пойманный dirty ⇒ реестр прочитан ПОСЛЕ мутации
		_update_pass
		[ -f "$W/.update.dirty" ] || break
		echo "--- реестр менялся во время обновления → переигрываю проход ---"
	done
	ustate DONE
	trap - EXIT INT TERM HUP PIPE
	ls_lock_drop "$lock"
	return 0
}

# reapply: БЫСТРОЕ восстановление цели из снимка БЕЗ скачивания (для boot-хука heal.sh:
# dnsmasq-conf adblock и ipset/DROP ipblock живут в RAM и стираются на ребуте, а .enabled+.snapshot
# на /data переживают). Офлайн-безопасно (не ходит в сеть). Категория выключена → teardown.
do_reapply() {
	valid_cat "$CAT" || return 2
	if ! cat_enabled "$CAT"; then teardown "$CAT"; return 0; fi
	_snap=$(snap_path "$CAT"); [ -s "$_snap" ] || return 0
	case "$CAT" in
		# Снимок на флеше мог быть записан ДО появления фильтра (или руками) ⇒ чистим и на reapply,
		# как это делают ipblock/zapret-cidr ниже: боевой набор не должен зависеть от возраста снимка.
		tunnel-cidr) _ts=$(ram_dir "$CAT")/.reapply.safe; strip_bogon 4 < "$_snap" > "$_ts"
		             apply_ipset iplist_set "$_ts" >/dev/null 2>&1 && ensure_mark_rule
		             rm -f "$_ts" ;;
		ipblock)     ensure_block_rules
		             _ss=$(ram_dir "$CAT")/.reapply.safe; strip_bogon < "$_snap" > "$_ss"   # защита LAN и на reapply
		             apply_ipset blocklist_set "$_ss" >/dev/null 2>&1; rm -f "$_ss"
		             ct_flush ;;
		zapret-cidr) _zs=$(ram_dir "$CAT")/.reapply.safe; strip_bogon < "$_snap" > "$_zs"   # защита LAN и на reapply
		             apply_ipset "$ZAPRET_CIDR_SET" "$_zs" >/dev/null 2>&1; rm -f "$_zs"
		             zapret_rewire ;;
		adblock)     apply_dnsmasq_block "$(adblock_conf)" "$_snap" "$(allow_path "$CAT")" >/dev/null 2>&1 ;;
		zapret-dom)  ensure_dom_set
		             apply_dnsmasq_ipset "$(zapret_dom_conf)" "$_snap" "$ZAPRET_DOM_SET" "$(allow_path "$CAT")" >/dev/null 2>&1
		             zapret_rewire ;;
	esac
	return 0
}

# wire: вернуть ЦЕПОЧКУ блокировки после сноса правил (firewall reload: вебморда Xiaomi, наш awg_setup), НЕ трогая набор — он
# в ОЗУ и reload переживает. Зовёт починка правил (`vpn-toggle.sh repair|rules`) на КАЖДЫЙ reload, поэтому `reapply` не годится:
# он заливает набор из снимка заново. Своя цепочка iptables есть только у ipblock (реклама и пулы десинка живут в dnsmasq и
# у zapret) — прочие категории молча выходят. Идёт проверка связи — цепочкой владеет она (откат снимет её сам); выключена,
# откачена (откат снимает `.enabled`) или набор пуст — ставить нечего.
wire_due() {   # 0 — цепочка блокировки ОБЯЗАНА стоять; гейты общие у `wire` и `wired`, иначе вопрос и починка разъедутся
	[ "$CAT" = ipblock ] || return 1
	cat_enabled ipblock || return 1
	guard_live ipblock && return 1
	[ "$(ipset_count blocklist_set)" -gt 0 ] 2>/dev/null
}
do_wire() {
	wire_due || return 0
	# ПОД ЛОКОМ ОБНОВЛЕНИЯ категории: проход обновления зовёт тот же `ensure_block_rules` (flush + `-C || -I` прыжков), и
	# параллельно оба `-C` могли промахнуться — ДВА прыжка в ENODIA_BLK, после чего выключение блокировки снимало один, а `-X`
	# не проходил (ревью хвостов dev233). Лок занят ⇒ dirty: держатель пройдёт ещё раз и проведёт цепочку сам — и после reload,
	# пришедшего посреди его прохода. Цена — повторная закачка, но совпадение починки с обновлением блок-листа редкое.
	_wlk="$(ram_dir ipblock)/.update.lock"
	ls_lock_take "$_wlk" "$(ram_dir ipblock)/.update.dirty" || return 0
	trap 'ls_lock_drop "$_wlk"' EXIT
	trap 'exit 1' INT TERM HUP PIPE
	ensure_block_rules
	trap - EXIT INT TERM HUP PIPE; ls_lock_drop "$_wlk"
}
# wired: снесена ли цепочка, которая обязана стоять — 0 стоит (или ставить нечего), 3 снесена, иное — не знаю. Спрашивает сторож,
# когда VPN выключен и чужой reload заметить больше не по чему (правила несущей в этом состоянии нет вовсе; хвост 10 ревью dev233).
# «Снесено» — НЕ 1: единицу отдаёт любой общий отказ (нет библиотеки, старая копия без верба), и сторож чинил бы по кругу.
do_wired() {
	wire_due || return 0
	command -v ipt_jump_state >/dev/null 2>&1 || return 2
	ipt_jump_state INPUT ENODIA_BLK; _wdi=$?
	ipt_jump_state FORWARD ENODIA_BLK; _wdf=$?
	[ "$_wdi" = 2 ] || [ "$_wdf" = 2 ] && return 2
	[ "$_wdi" = 0 ] && [ "$_wdf" = 0 ] && return 0
	return 3
}

# guarded_enable: включить категорию С АВТО-ОТКАТОМ при обрыве связи (слой 3 защиты). Для ipblock
# «глухой» DROP теоретически может оборвать роутер/резолв — после apply делаем self-test и, если
# связь/резолв упали ИЛИ приватка просочилась в блок-сет, откатываем (тот же отсоединённый guard-
# рецепт, что раньше гоняли вручную start-stop-daemon -b). Пишем вердикт в .guard.state для панели.
# НАЧАЛО ПРОВЕРКИ — СИНХРОННО, из CGI до фонового запуска (шаг 5c): панель перечитывает экран сразу после ответа, и
# прежде первый ответ мог прийти раньше, чем фон записал `.enabled` и APPLYING, — экран рисовал выключенный тумблер с
# прошлым «откачено», не запускал опрос, а повторный клик пускал ВТОРУЮ проверку параллельно. Отметка времени даёт фону
# минуту на то, чтобы записать свой пид (до неё «пида нет» ≠ «прогон умер»). Код 1 — проверка уже идёт (не начинаем).
GUARD_GRACE=60
guard_live() {  # guard_live <cat> → 0, если проверка связи идёт (пид жив ИЛИ только что начата)
	_gl=$(ram_dir "$1")
	[ "$(cat "$_gl/.guard.state" 2>/dev/null | tr -d ' \r\n')" = APPLYING ] || return 1
	_gp=$(cat "$_gl/.guard.pid" 2>/dev/null | tr -cd '0-9')
	# cmdline — через tr: аргументы там разделены NUL, и grep busybox-сборки без EXTRA_COMPAT видит лишь первый (`/bin/sh`).
	[ -n "$_gp" ] && cat "/proc/$_gp/cmdline" 2>/dev/null | tr '\0' ' ' | grep -q lists-update && return 0
	_gt=$(cat "$_gl/.guard.ts" 2>/dev/null | tr -cd '0-9')
	[ -n "$_gt" ] && [ "$(age_since "$_gt")" -lt "$GUARD_GRACE" ]
}
# `.enabled` здесь НЕ пишем: фон мог не стартовать, а флаг на флеше пережил бы ребут — heal поставил бы DROP без проверки
# связи. «Включается» экран видит по самой проверке (emit_list: enabled — флаг ИЛИ идущая проверка).
guard_begin() {
	guard_live "$1" && return 1
	_gb=$(ram_dir "$1")
	# Отменённая проверка ещё доигрывает свой проход (закачка идёт минутами): вторая поверх неё писала бы в те же файлы, и
	# первая, дойдя до конца, увидела бы APPLYING второй как свою. Код 2 — «прежняя ещё завершается».
	if guard_cancelled "$1"; then
		_gp=$(cat "$_gb/.guard.pid" 2>/dev/null | tr -cd '0-9')
		[ -n "$_gp" ] && cat "/proc/$_gp/cmdline" 2>/dev/null | tr '\0' ' ' | grep -q lists-update && return 2
	fi
	rm -f "$_gb/.guard.pid" 2>/dev/null
	date +%s > "$_gb/.guard.ts"
	gstate "$_gb" APPLYING
	return 0
}
# Шлюз и интернет отвечали ДО включения? Иначе их молчание после — не вердикт списку: шлюз провайдера, не отвечающий на
# ICMP, откатывал КАЖДОЕ включение словами «после включения перестал отвечать шлюз» (к тому же шлюз стоит в наборе
# «не блокировать» — список его не рвёт). Роутер→интернет — ПО TCP (curl), а НЕ ICMP: 1.1.1.1/8.8.8.8 лежат в
# iplist_set и маркируются в туннель, а на socks-транспортах (xray/hy2/byedpi) несущая = tun2socks, который ICMP НЕ
# проксирует → ping ВСЕГДА FAIL → ipblock откатывался при каждом включении. Проверено на железе 2026-07-14.
guard_gw_ok()  { _gg=$(wan_gateway); [ -n "$_gg" ] && ping -c 1 -W 3 "$_gg" >/dev/null 2>&1; }
guard_net_ok() {
	for _h in 1.1.1.1 8.8.8.8; do
		curl -sk -o /dev/null -m 6 --connect-timeout 5 "https://$_h" 2>/dev/null && return 0
	done
	return 1
}
# ВЫКЛЮЧИЛИ ПОСРЕДИ ПРОВЕРКИ — проверка ОТМЕНЕНА (`enable 0` пишет CANCELLED): без этого «включена» держалось до конца
# прогона (флаг ИЛИ идущая проверка), тумблер на экране возвращался включённым, а в конце приходило «Проверка связи
# прошла — блокировка включена» при выключенной (ревью шага 5c, круг 3). Отменённая проверка вердикта не пишет, флаг не
# ставит и правил не держит: снял их `enable 0`, а свой проход (do_update) видит «выключена» и не ставит.
# ОТКАТ — СОБЫТИЕМ В ЖУРНАЛ (и письмом, если почта настроена): опрос вердикта живёт только на экране, и человек, ушедший с
# него, не узнавал, что включённая блокировка снялась сама — чип двери просто терял «адреса».
guard_notify() {
	[ -f "$ENODIA_DIR/notify-event.sh" ] || return 0
	if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
	command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
	if [ "$(nf_lang)" = en ]; then
		case "$1" in
			lan) _gn="the list contained home network addresses" ;; gw) _gn="after enabling, the provider gateway stopped answering" ;;
			net) _gn="after enabling, the router could not reach the internet" ;; nonet) _gn="the internet was not answering even before enabling" ;;
			*) _gn="connectivity dropped while enabling" ;;
		esac
		sh "$ENODIA_DIR/notify-event.sh" ipblock-reverted 3600 "Blocking by address was removed automatically" \
			"Reason: $_gn. The network works as before; the lists and your exceptions are kept." >/dev/null 2>&1
	else
		case "$1" in
			lan) _gn="в список попали адреса домашней сети" ;; gw) _gn="после включения перестал отвечать шлюз провайдера" ;;
			net) _gn="после включения роутер не достучался до интернета" ;; nonet) _gn="интернет не отвечал ещё до включения" ;;
			*) _gn="при включении прерывалась связь" ;;
		esac
		sh "$ENODIA_DIR/notify-event.sh" ipblock-reverted 3600 "Блокировка по адресам снята автоматически" \
			"Причина: $_gn. Сеть работает как прежде; списки и ваши исключения сохранены." >/dev/null 2>&1
	fi
	return 0
}
guard_cancelled() { [ "$(cat "$(ram_dir "$1")/.guard.state" 2>/dev/null | tr -d ' \r\n')" = CANCELLED ]; }
guarded_enable() {
	_c="$1"
	_g=$(ram_dir "$_c")
	# Выключили ещё до старта фона (между guard-begin CGI и этой строкой) — флаг не пишем, иначе включили бы заново.
	guard_cancelled "$_c" && return 0   # до флага
	: > "$(enable_path "$_c")"
	# СВОЙ ПИД — для панели: «Проверяю связь…» висело на экране вечно, если прогон убили посреди (OOM, перезапуск uhttpd
	# с детьми). Пидфайл spawn_bg не годится в свидетели — его перезаписывает ЛЮБОЙ следующий фоновый прогон категории.
	# ПРИЧИНУ отката (.guard.why) пишет каждый откат заново, а читается она только при REVERTED — старую чистить незачем.
	echo $$ > "$_g/.guard.pid"
	gstate "$_g" APPLYING
	[ -f "$_g/.guard.ts" ] || date +%s > "$_g/.guard.ts"
	_gw0=0; _net0=0
	if [ "$_c" = ipblock ]; then guard_gw_ok && _gw0=1; guard_net_ok && _net0=1; fi
	CAT="$_c" do_update
	# Лок держал ЧУЖОЙ проход (обновление по расписанию, кнопка): do_update пометил dirty и вышел сразу, а применит список
	# тот проход. Проверять связь по прежнему состоянию значило бы написать OK до того, как DROP вообще встал. Потолок —
	# против зависшего держателя; вышел — проверки не было, и так и сказано (ABORTED: «включена, но не проверена»).
	# Число шагов — ручка стенда (`LISTS_GUARD_WAIT`, dev/lists-block-test.sh): «потолок вышел» он ждал 600 шагами заглушки sleep —
	# треть его времени на каждую копию-порчу. На роутере переменную не задаёт никто: 600 с. Шесть цифр и больше — тоже 600:
	# число сверх разрядности busybox `[ -lt ]` роняет сравнение, и ожидания не было бы вовсе.
	_gw_n=0; _gw_max=${LISTS_GUARD_WAIT:-600}; case "$_gw_max" in ''|*[!0-9]*|??????*) _gw_max=600 ;; esac
	while [ -d "$_g/.update.lock" ] && ! _lock_stale "$_g/.update.lock" && [ "$_gw_n" -lt "$_gw_max" ] && ! guard_cancelled "$_c"; do sleep 1; _gw_n=$((_gw_n + 1)); done
	guard_cancelled "$_c" && return 0   # ждали чужой проход
	if [ -d "$_g/.update.lock" ] && ! _lock_stale "$_g/.update.lock"; then gstate "$_g" ABORTED; return 1; fi
	[ "$_c" = ipblock ] || { gstate "$_g" OK; return 0; }
	sleep 3
	_ok=1; _why=''
	# (а) приватка/LAN в блок-сете = катастрофа (ровно инцидент FireHOL) → откат безусловно.
	for _p in 192.168.31.1 192.168.31.0 10.0.0.1 100.64.0.1; do
		ipset test blocklist_set "$_p" >/dev/null 2>&1 && { _ok=0; [ -n "$_why" ] || _why=lan; }
	done
	# (б) роутер потерял WAN-шлюз — только если до включения он отвечал.
	[ "$_gw0" = 1 ] && { guard_gw_ok || { _ok=0; [ -n "$_why" ] || _why=gw; }; }
	# (в) интернет. Не отвечал и ДО включения — проверить нечем: блокировку не оставляем (связи нет — «защиту» не проверить),
	# но и не валим на список — своя причина.
	if [ "$_net0" = 1 ]; then guard_net_ok || { _ok=0; [ -n "$_why" ] || _why=net; }
	else _ok=0; [ -n "$_why" ] || _why=nonet; fi
	guard_cancelled "$_c" && return 0   # до вердикта
	if [ "$_ok" != 1 ]; then
		ulog "SELF-TEST FAILED ($_why) → авто-откат ipblock (связь/резолв или приватка в сете)"
		rm -f "$(enable_path "$_c")"; teardown "$_c"; ct_flush
		echo "$_why" > "$_g/.guard.why"
		gstate "$_g" REVERTED
		guard_notify "$_why"
		return 1
	fi
	gstate "$_g" OK
	return 0
}

# --- Каталог готовых источников (пресеты) -----------------------------------
# URL берём через CDN-зеркала (jsdelivr — на роутере надёжнее github-raw anycast; в iplist_set).
# Поля (через |): label|url|format|group|approx|site|desc
#   group  — rec (рекомендуемые, лёгкие/безопасные) | aggr (агрессивнее, тяжелее/больше ложных);
#   approx — примерный размер для UI-бюджета (человекочитаемо, «~48k»);
#   site   — страница проекта (кнопка-ссылка у пресета, чтобы юзер посмотрел, что за сервис);
#   desc   — короткое описание (последнее поле, может содержать пробелы).
presets_lines() {
	case "$1" in
		adblock)
			cat <<'EOF'
Hagezi Light|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/light.txt|dnsmasq|rec|~44k|https://github.com/hagezi/dns-blocklists|мягкий, почти без ложных срабатываний
OISD Small|https://small.oisd.nl/dnsmasq|dnsmasq|rec|~56k|https://oisd.nl|реклама, трекеры, фишинг — сбалансированно
Peter Lowe|https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext|hosts|rec|~3.5k|https://pgl.yoyo.org|только рекламные серверы, очень лёгкий
AdGuard DNS filter|https://cdn.jsdelivr.net/gh/AdguardTeam/AdGuardSDNSFilter@gh-pages/Filters/filter.txt|adblock|rec|~155k|https://github.com/AdguardTeam/AdGuardSDNSFilter|базовый фильтр AdGuard DNS
Hagezi Normal|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/multi.txt|dnsmasq|aggr|~160k|https://github.com/hagezi/dns-blocklists|сбалансированный, шире охват
Hagezi Pro|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/pro.txt|dnsmasq|aggr|~230k|https://github.com/hagezi/dns-blocklists|жёсткий, максимум охвата
OISD Big|https://big.oisd.nl/dnsmasq|dnsmasq|aggr|~500k|https://oisd.nl|расширенный список OISD
StevenBlack hosts|https://cdn.jsdelivr.net/gh/StevenBlack/hosts@master/hosts|hosts|aggr|~78k|https://github.com/StevenBlack/hosts|классический hosts-список
EOF
			;;
		ipblock)
			cat <<'EOF'
FireHOL level1|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/firehol_level1.netset|cidr|rec|~4.6k|https://iplists.firehol.org|минимум ложных срабатываний, базовые угрозы
Spamhaus DROP|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/spamhaus_drop.netset|cidr|rec|~1.6k|https://www.spamhaus.org/blocklists/do-not-route-or-peer/|заведомо враждебные сети (спам, малварь)
Spamhaus EDROP|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/spamhaus_edrop.netset|cidr|rec|~0.3k|https://www.spamhaus.org/blocklists/do-not-route-or-peer/|дополнение к DROP
FireHOL level2|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/firehol_level2.netset|cidr|aggr|~29k|https://iplists.firehol.org|+ атакующие сети и ботнеты за сутки
FireHOL level3|https://cdn.jsdelivr.net/gh/firehol/blocklist-ipsets@master/firehol_level3.netset|cidr|aggr|~13k|https://iplists.firehol.org|более широкий охват угроз
EOF
			;;
		# zapret-cidr: пул десинка ПО IP. Категории зеркалят ДОМЕННЫЕ категории zapret.sh
		# (youtube/google/discord/meta), чтобы «включил YouTube» значило одно и то же в обоих пулах.
		# Каждый URL ПРОВЕРЕН на железе 2026-07-25 (отдаёт непустой CIDR); мёртвые варианты не
		# положены сознательно: `site=google.com`/`googlevideo.com` у opencck отдают ПУСТО, а
		# runetfreedom не имеет youtube/discord/instagram — источник, который молча приезжает
		# нулевым, выглядит в UI как «включил, а не работает».
		# ПОЧЕМУ Google-пресет главный: список YouTube у opencck НЕ накрывает часть googlevideo
		# (живой поток телевизора шёл с 173.194.153.35, его там нет), а официальный goog.json
		# несёт 173.194.0.0/16 — и всего в 99 префиксах. Именно он закрывает исходную жалобу.
		# Cloudflare НЕ предлагаем: по граблям проекта десинк её всё равно не берёт, а вывод
		# 607 её подсетей мимо туннеля утащил бы пол-интернета из VPN ради нулевого эффекта.
		zapret-cidr)
			cat <<'EOF'
Google + googlevideo (официальный)|https://www.gstatic.com/ipranges/goog.json|cidr|rec|~99|https://www.gstatic.com/ipranges/goog.json|официальные диапазоны Google — накрывают googlevideo целиком
YouTube (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=youtube.com|cidr|rec|~0.8k|https://iplist.opencck.org|подсети YouTube — точнее, но без части googlevideo
Discord (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=discord.com|cidr|rec|~0.1k|https://iplist.opencck.org|подсети Discord (сайт и медиа)
Google (runetfreedom geoip)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geoip@release/text/google.txt|cidr|aggr|~2.9k|https://github.com/runetfreedom/russia-blocked-geoip|шире официального: весь Google по данным РКН-списков
Instagram (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=instagram.com|cidr|aggr|~0.1k|https://iplist.opencck.org|подсети Instagram/Meta CDN
Facebook (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=facebook.com|cidr|aggr|~0.2k|https://iplist.opencck.org|подсети Facebook/Meta CDN
X / Twitter (opencck)|https://iplist.opencck.org/?format=text&data=cidr4&site=x.com|cidr|aggr|~16|https://iplist.opencck.org|подсети X (бывший Twitter)
EOF
			;;
		# zapret-dom: СВОИ домены в тот же десинк. Источники — те же каталоги, что уже питают
		# «Гео-списки» (runetfreedom geosite = РКН-домены, v2fly domain-list-community): пиновка и
		# формат ровно как в geo.sh, поэтому доверенность источников уже подтверждена железом.
		# Плоские `domain:`/`full:`-префиксы понимает norm_domains (lists-lib.sh).
		# КАЖДЫЙ URL проверен с роутера 2026-07-26 (HTTP 200 + непустое тело; instagram.txt/
		# telegram.txt у runetfreedom НЕ существуют — 404, поэтому эти сервисы взяты из v2fly).
		# ru-blocked.txt (~79.5k доменов) — в aggr и с предупреждением: столько ipset=-строк dnsmasq
		# держит, но снимок на флеш не поместится (кап MAX_FLASH_CIDR) ⇒ после ребута нужен re-fetch.
		zapret-dom)
			cat <<'EOF'
YouTube (RU-блокировки)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/youtube.txt|domain|rec|~178|https://github.com/runetfreedom/russia-blocked-geosite|домены YouTube из РКН-списков
Google (RU-блокировки)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/google.txt|domain|rec|~1.1k|https://github.com/runetfreedom/russia-blocked-geosite|домены Google (поиск, сервисы, Gemini)
Discord (RU-блокировки)|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/discord.txt|domain|rec|~28|https://github.com/runetfreedom/russia-blocked-geosite|домены Discord (сайт, медиа, вложения)
Telegram (v2fly)|https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@master/data/telegram|domain|rec|~21|https://github.com/v2fly/domain-list-community|домены Telegram (веб, API, CDN)
Instagram (v2fly)|https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@master/data/instagram|domain|rec|~76|https://github.com/v2fly/domain-list-community|домены Instagram/Meta CDN
OpenAI / ChatGPT (v2fly)|https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@master/data/openai|domain|rec|~30|https://github.com/v2fly/domain-list-community|домены OpenAI (ChatGPT, API)
Все домены, заблокированные в РФ|https://cdn.jsdelivr.net/gh/runetfreedom/russia-blocked-geosite@release/ru-blocked.txt|domain|aggr|~79.5k|https://github.com/runetfreedom/russia-blocked-geosite|весь РКН-реестр доменов — тяжёлый, снимок на флеш не поместится
EOF
			;;
	esac
}
emit_presets() {
	printf '['
	first=1
	while IFS='|' read -r lbl url fmt grp approx site desc; do
		[ -n "$lbl" ] || continue
		[ "$first" = 1 ] || printf ','
		first=0
		[ -n "$grp" ] || grp=rec
		printf '{"label":"%s","url":"%s","format":"%s","group":"%s","approx":"%s","site":"%s","desc":"%s"}' \
			"$(jesc "$lbl")" "$(jesc "$url")" "$(jesc "$fmt")" "$(jesc "$grp")" "$(jesc "$approx")" "$(jesc "$site")" "$(jesc "$desc")"
	done <<EOF
$(presets_lines "$1")
EOF
	printf ']'
}

# --- list: JSON состояния категории для панели ------------------------------
# СОСТОЯНИЕ КАТЕГОРИИ — включена ли, идёт ли обновление, чем кончилась проверка связи (ставит en/st/gs/gw). Одно на `list` и на
# лёгкий `state`: чипу двери раздела «Сеть» не нужны ни список защиты с `ipset test` по каждому адресу, ни каталог пресетов, а
# спрашивает он на КАЖДЫЙ показ раздела (ревью шага 5c, круг 2).
cat_state() {
	# «Включена» — флаг ИЛИ идущая проверка связи (guard_begin флаг не пишет — разбор там).
	en=true; cat_enabled "$CAT" || { [ "$CAT" = ipblock ] && guard_live ipblock; } || en=false
	st=$(cat "$(ram_dir "$CAT")/.update.state" 2>/dev/null | tr -d ' \r\n'); [ -n "$st" ] || st=IDLE
	# «Идёт» — ТОЛЬКО пока жив держатель лока: убитый посреди прогон (OOM, SIGKILL — ловушка EXIT на
	# сигнале не срабатывает) оставлял RUNNING навсегда, и панель держала «обновляю…» с запертой
	# кнопкой до перезагрузки роутера. Судим тем же, чем лок снимают (_lock_stale).
	# Держатель мог ЗАКОНЧИТЬ между чтением состояния и проверкой лока (DONE и снятие лока) — это не «прервано»:
	# состояние перечитывается, и прерванным считается, только если в файле по-прежнему RUNNING.
	_lk="$(ram_dir "$CAT")/.update.lock"
	if [ "$st" = RUNNING ] && { [ ! -d "$_lk" ] || _lock_stale "$_lk"; }; then
		st=$(cat "$(ram_dir "$CAT")/.update.state" 2>/dev/null | tr -d ' \r\n'); [ "$st" = RUNNING ] && st=ABORTED; [ -n "$st" ] || st=IDLE
	fi
	gs=$(cat "$(ram_dir "$CAT")/.guard.state" 2>/dev/null | tr -d ' \r\n'); [ -n "$gs" ] || gs=NONE
	# То же у проверки связи: APPLYING, а прогона нет (свой пид мёртв и начата не только что) = проверка прервалась.
	if [ "$gs" = APPLYING ] && ! guard_live "$CAT"; then
		gs=$(cat "$(ram_dir "$CAT")/.guard.state" 2>/dev/null | tr -d ' \r\n'); [ "$gs" = APPLYING ] && gs=ABORTED; [ -n "$gs" ] || gs=NONE
	fi
	gw=''; [ "$gs" = REVERTED ] && gw=$(cat "$(ram_dir "$CAT")/.guard.why" 2>/dev/null | tr -cd 'a-z')
	# Блокировка ИМЕННО СПИСКАМИ живая (цепочка ENODIA_BLK в ядре) — отдельно от `addr_live` (списки ИЛИ гео-«Блок»): строка
	# категории, итог прерванной проверки и чип двери говорят о СВОЕЙ блокировке, а гео-«Блок» живёт своей цепочкой — после
	# сноса правил (fw3 reload) вернувшаяся с правкой гео цепочка выдавала бы «заблокировано: N» у списков, не дропающих ничего.
	bl=null; [ "$CAT" = ipblock ] && { bl=false; iptables -C INPUT -j ENODIA_BLK 2>/dev/null && bl=true; }
	return 0
}

emit_state() {
	cat_state
	# Сколько ВКЛЮЧЁННЫХ источников — чип двери: «реклама» при пустом наборе списков была бы неправдой.
	_ns=0; [ -f "$(reg_path "$CAT")" ] && _ns=$(awk -F"$TAB" '$1!="" && $3==1' "$(reg_path "$CAT")" 2>/dev/null | grep -c '' || true)
	case "$_ns" in ''|*[!0-9]*) _ns=0 ;; esac
	# Сколько записей в ЦЕЛИ — число строки категории в хабе «Источники списков» (пять категорий на одном экране: полный
	# `list` у ipblock собирает защиту с `ipset test` по каждому адресу). Цена — та же `applied_count`, что у `list`
	# (замер на BE7000: `ipset list` набора на 3638 записей — 20 мс).
	_ac=$(applied_count "$CAT"); case "$_ac" in ''|*[!0-9]*) _ac=0 ;; esac
	printf '{"cat":"%s","kind":"%s","enabled":%s,"update_state":"%s","guard_state":"%s","guard_why":"%s","blk_live":%s,"nsrc":%s,"count":%s}\n' \
		"$CAT" "$(kind_of "$CAT")" "$en" "$st" "$gs" "$gw" "$bl" "$_ns" "$_ac"
}

emit_list() {
	cat_state
	ac=$(applied_count "$CAT"); case "$ac" in ''|*[!0-9]*) ac=0 ;; esac
	al=0; [ -s "$(allow_path "$CAT")" ] && { al=$(grep -c '' "$(allow_path "$CAT")" 2>/dev/null); case "$al" in ''|*[!0-9]*) al=0 ;; esac; }
	# blocklist_allow — число критичных IP под защитой (для UI «Защита сети»); 0 если сет не создан.
	# ГАРД обязателен: если ipset_count вернёт пусто (напр. рассинхрон deploy — старый lists-lib.sh
	# без функции), пустое поле %s ломает JSON целиком («critical_count»:,) → панель «не удалось
	# получить источники» + мастер-тумблер блокировки не рисуется. Ни одно числовое поле не должно
	# уезжать пустым — как ac/al выше (поймано на железе 2026-07-18, BE7000: lists-lib.sh был stale).
	ca=$(ipset_count blocklist_allow 2>/dev/null); case "$ca" in ''|*[!0-9]*) ca=0 ;; esac
	# СОДЕРЖИМОЕ allowlist'а, а не только счётчик: верб `allow-set` ЗАМЕНЯЕТ файл целиком, а панель
	# показывала лишь «исключений: N» и однострочное поле — то есть человек, дописав туда один
	# домен, стирал все прежние и узнавал об этом только по вернувшейся рекламе. Отдаём то, что
	# он на самом деле правит. base64 — потому что домены идут построчно, а JSON-эскейпа на
	# busybox нет (та же причина, что у name_b64 слотов и полей events.sh).
	# Потолок 32 КБ: список рукописный (десятки строк), но панель обязана ЗНАТЬ, что он не влез,
	# и не дать сохранить обрезок поверх целого — иначе лечение стало бы той же болезнью.
	ab=''; acut=false
	if [ -s "$(allow_path "$CAT")" ]; then
		if [ "$(wc -c < "$(allow_path "$CAT")" 2>/dev/null || echo 0)" -gt 32768 ]; then acut=true
		else ab=$(base64 < "$(allow_path "$CAT")" 2>/dev/null | tr -d '\n\r'); fi
	fi
	printf '{"cat":"%s","kind":"%s","enabled":%s,"count":%s,"allow_count":%s,"allow_b64":"%s","allow_cut":%s,"update_state":"%s","guard_state":"%s","guard_why":"%s","critical_count":%s,' \
		"$CAT" "$(kind_of "$CAT")" "$en" "$ac" "$al" "$ab" "$acut" "$st" "$gs" "$gw" "$ca"
	# ЧТО ЗАЩИЩЕНО И ПОЧЕМУ (только ipblock — экран «Блокировка»): строками владельца (collect_critical),
	# ЖИВЫМ сбором — это ответ «что роутер не заблокирует», и он верен и до включения. Свои исключения
	# человека здесь не повторяем — они едут полем allow_b64. Дубли адреса схлопываем: первая причина
	# в порядке сбора (сервер туннеля важнее «адреса DNS», если это один IP).
	# Какой интерфейс — домашняя сеть и какой — провайдер: словами строки подсети («домашняя сеть», «сеть
	# провайдера») панель обязана называть по ответу роутера, а не по литералу br-lan (следит C40).
	_bl=''; _bw=''
	if [ "$CAT" = ipblock ]; then
		if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi
		command -v lan_if >/dev/null 2>&1 || lan_if() { echo br-lan; }   # lan-lit: шим без router-lib.sh
		_bl=$(lan_if 2>/dev/null | tr -cd 'A-Za-z0-9._-'); _bw=$(wan_iface 2>/dev/null | tr -cd 'A-Za-z0-9._-')
	fi
	# БЛОКИРОВКА ПО АДРЕСАМ ЖИВАЯ (цепочки в ядре) и ЕСТЬ ЛИ АДРЕС В НАБОРЕ СЕЙЧАС: список собирается живьём, а набор ядра —
	# только на обновлении и смене сервера; переподключённый PPPoE (новый адрес и шлюз) показывался бы «всегда», хотя в
	# ядре его ещё нет. Набора нет — признака нет (null: про ядро сказать нечего).
	_al=false; addr_block_live && _al=true
	_as=0; ipset list -n 2>/dev/null | grep -qx blocklist_allow && _as=1
	printf '"lan":"%s","wan":"%s","addr_live":%s,"blk_live":%s,"critical":[' "$_bl" "$_bw" "$_al" "$bl"
	if [ "$CAT" = ipblock ]; then
		collect_critical 2>/dev/null | awk -F"$TAB" '$1!="" && $2!="user" && !s[$1]++' | while IFS="$TAB" read -r _ci _cw _cd; do
			_cin=null
			if [ "$_as" = 1 ]; then _cin=false; ipset test blocklist_allow "$_ci" >/dev/null 2>&1 && _cin=true; fi
			printf '%s\t%s\t%s\t%s\n' "$_ci" "$_cw" "$_cd" "$_cin"
		done | awk -F"$TAB" '{ gsub(/[\\"]/,"",$3); if (n++) printf ","
			printf "{\"ip\":\"%s\",\"why\":\"%s\",\"dev\":\"%s\",\"in\":%s}", $1, $2, $3, $4 }'
	fi
	printf '],"sources":['
	first=1; reg=$(reg_path "$CAT"); mx=0
	if [ -f "$reg" ]; then
		while IFS="$TAB" read -r id type enb fmt cnt ts label value; do
			[ -n "$id" ] || continue
			eb=false; [ "$enb" = 1 ] && eb=true
			case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
			case "$ts"  in ''|*[!0-9]*) ts=0 ;; esac
			[ "$enb" = 1 ] && [ "$ts" -gt "$mx" ] && mx=$ts
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"id":"%s","type":"%s","enabled":%s,"format":"%s","count":%s,"ts":%s,"label":"%s","value":"%s"}' \
				"$(jesc "$id")" "$(jesc "$type")" "$eb" "$(jesc "$fmt")" "$cnt" "$ts" "$(jesc "$label")" "$(jesc "$value")"
		done < "$reg"
	fi
	# ВОЗРАСТ СВЕЖАЙШЕГО включённого источника — «обновлено N назад» у категории. Считает РОУТЕР: обе
	# точки из одних часов (панель от своих часов соврала бы на величину расхождения). -1 = не качалось.
	# clock-raw: НЕ через age_since — отметка источника лежит на флеше и ребут ПЕРЕЖИВАЕТ, её возраст
	# законно больше аптайма (кламп clock-lib соврал бы «только что»). Скачок часов — неточная подпись.
	ua=-1; [ "$mx" -gt 0 ] && { ua=$(( $(date +%s) - mx )); [ "$ua" -ge 0 ] || ua=0; }
	printf '],"upd_age":%s,"presets":' "$ua"; emit_presets "$CAT"; printf '}\n'
}

# --- Исключения категории (allow-set) ------------------------------------------
# Поле панели — ВЕСЬ список (верб ЗАМЕНЯЕТ файл), и сохранённое обязано начать действовать СРАЗУ, а
# не «при следующем обновлении»: прежний ответ «применится при обновлении» значил перекачку мегабайт
# по расписанию — сутки или неделю реклама на исключённом домене оставалась закрытой.
#   adblock — домены (norm_domains: хост из URL, hosts-строки, ABP); применяем переигрыванием снимка
#             из ОЗУ (без закачки); снимка нет (роутер только загрузился) — применится обновлением.
#   ipblock — IPv4/CIDR, СТРОГО по октетам и маске: адрес уходит в ipset, мусор там молча не встанет.
#             Действуют на ВСЮ блокировку по адресам — и списки, и гео-категории «Блок»: набор
#             blocklist_allow у них общий. Убрали исключение при живой блокировке ⇒ сброс соединений:
#             ускоритель NSS/ECM иначе продолжит пропускать уже установленный поток к этому адресу.
# Печатает одну строку «kept=N dropped=M applied=now|later|off» (dropped — записи, не ставшие исключением). В поле ни
# одной годной записи, а прежний список не пуст — ОТКАЗ (applied=reject, код 1): вставили домены в поле адресов — и
# прежний список молча стирался бы (со сбросом соединений всего дома).
# Маска не шире /8 — как у strip_bogon: `0.0.0.0/0` ipset молча отвергает (а экран сказал бы «уже действуют»), а
# `1.0.0.0/1` встал бы и снял половину всей блокировки по адресам.
ALLOW_IP_RE='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(/([89]|[12][0-9]|3[0-2]))?$'
# Фоновый проход категории ИЗ-ПОД CGI — отвязанным, тем же пидфайлом, что у кнопок панели (spawn_bg в action): голый `&`
# остаётся ребёнком uhttpd, а тот гасит своих детей по таймауту CGI. Нет start-stop-daemon — прежний путь.
bg_update() {
	rm -f "/tmp/enodia-lists-$1.pid" 2>/dev/null   # как spawn_bg: протухший пидфайл не должен запретить запуск
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -S -b -m -p "/tmp/enodia-lists-$1.pid" -x /bin/sh -- "$ENODIA_DIR/lists-update.sh" update "$1" >/dev/null 2>&1
	else ( sh "$ENODIA_DIR/lists-update.sh" update "$1" >/dev/null 2>&1 & ); fi
	return 0
}
allow_set() {  # allow_set <cat> <файл>
	_af=$(allow_path "$1"); _ai="$(ram_dir "$1")/.allow.in"
	# Значимое — без комментариев (# и ;), и записи разделяет ЛЮБОЙ пробел или запятая: «a.com, b.com» в
	# одной строке — две записи, а не одна (norm_domains взял бы первое слово и молча потерял второе). Каждую
	# запись и считаем «прислано» — отброшенное называется числом.
	# У рекламы строка hosts «0.0.0.0 ads.com» — ОДНА запись (адрес — столбец формата, не исключение), а «@@» AdGuard — пометка
	# «разрешить», не часть домена: иначе первое считалось двумя записями с одной «отброшенной», второе терялось целиком.
	if [ "$1" = adblock ]; then
		tr -d '\r' < "$2" | sed 's/[#;].*$//; s/^[[:space:]]*@@//; s/^[[:space:]]*0\.0\.0\.0[[:space:]][[:space:]]*//; s/^[[:space:]]*127\.0\.0\.1[[:space:]][[:space:]]*//; s/^[[:space:]]*::1*[[:space:]][[:space:]]*//'
	else tr -d '\r' < "$2" | sed 's/[#;].*$//'; fi | tr ', \t' '\n\n\n' | grep -v '^$' > "$_ai"
	_tot=$(grep -c '' "$_ai" 2>/dev/null); case "$_tot" in ''|*[!0-9]*) _tot=0 ;; esac
	# В поле был ТЕКСТ, но ни одной записи (одни комментарии) — это не «очистить список»: очистка — пустое поле.
	_raw=$(tr -d '\r' < "$2" | grep -c '[^[:space:]]'); case "$_raw" in ''|*[!0-9]*) _raw=0 ;; esac
	[ "$_tot" = 0 ] && [ "$_raw" -gt 0 ] && _tot=$_raw
	if [ "$1" = ipblock ]; then grep -E "$ALLOW_IP_RE" "$_ai" > "$_ai.ok" 2>/dev/null
	else norm_domains < "$_ai" > "$_ai.ok"; fi
	_val=$(grep -c '' "$_ai.ok" 2>/dev/null); case "$_val" in ''|*[!0-9]*) _val=0 ;; esac
	if [ "$_val" = 0 ] && [ "$_tot" -gt 0 ] && [ -s "$_af" ]; then
		rm -f "$_ai" "$_ai.ok"; echo "kept=0 dropped=$_tot applied=reject"; return 1
	fi
	# Что было до записи — снятое исключение IP (адрес был разрешён, теперь нет) требует сброса соединений.
	_gone=0
	if [ "$1" = ipblock ] && [ -s "$_af" ]; then
		sort -u "$_ai.ok" > "$_ai.new"
		# Пустой новый список = сняты все. `grep -f` с ПУСТЫМ файлом шаблонов у busybox совпадает со ВСЕМ
		# (замер BE7000 22.09.2026: `-v` не печатает ничего), у GNU — ни с чем: туда его не пускаем.
		if [ ! -s "$_ai.new" ]; then _gone=1
		else grep -vxF -f "$_ai.new" "$_af" 2>/dev/null | grep -q . && _gone=1; fi
		rm -f "$_ai.new"
	fi
	sort -u "$_ai.ok" > "$_af.new" && mv "$_af.new" "$_af"
	_kept=$(grep -c '' "$_af" 2>/dev/null); case "$_kept" in ''|*[!0-9]*) _kept=0 ;; esac
	rm -f "$_ai" "$_ai.ok"
	_app=off
	if [ "$1" = ipblock ]; then
		# Блокировка по адресам ЖИВАЯ (цепочки ipblock или гео-«Блока» в ядре): исключение действует сразу на обе.
		# Не живая, но включена (идёт проверка связи, ребут до переигрывания) — подействует, когда правила встанут.
		if addr_block_live; then ensure_allow_set; [ "$_gone" = 1 ] && ct_flush; _app=now
		elif cat_enabled ipblock; then _app=later; fi
	elif cat_enabled "$1"; then
		# Идёт проход обновления — переигрывать снимок параллельно нельзя (оба пишут один сниппет, и позже записавший
		# вернул бы список без новых исключений): помечаем dirty — держатель пройдёт ещё раз, уже с ними.
		_alk="$(ram_dir "$1")/.update.lock"
		if ls_lock_take "$_alk" "$(ram_dir "$1")/.update.dirty"; then
			if [ -s "$(snap_path "$1")" ]; then CAT="$1" do_reapply; _app=now; else _app=later; fi
			ls_lock_drop "$_alk"
			# Пока лок держали МЫ, проход (расписание, «Обновить», включение) мог пометить dirty и уйти — контракт лока
			# «держатель переиграет»: переигрываем фоном, иначе это обновление потеряно до следующего расписания.
			if [ -f "$(ram_dir "$1")/.update.dirty" ] && [ -f "$ENODIA_DIR/lists-update.sh" ]; then bg_update "$1"; fi
		else _app=later; fi
	fi
	echo "kept=$_kept dropped=$((_tot - _val)) applied=$_app"
}

# --- Диспетчер подкоманд -----------------------------------------------------
case "$CMD" in
	update)   do_update ;;
	reapply)  do_reapply ;;
	wire)     do_wire ;;
	wired)    do_wired; exit $? ;;
	list)    valid_cat "$CAT" || { echo '{"error":"unknown category"}'; exit 1; }; emit_list ;;
	state)    valid_cat "$CAT" || { echo '{"error":"unknown category"}'; exit 1; }; emit_state ;;
	presets)  valid_cat "$CAT" || { printf '[]\n'; exit 1; }; emit_presets "$CAT"; echo ;;
	add-url)
		valid_cat "$CAT" || { echo "unknown category" >&2; exit 1; }
		url="$3"; fmt="${4:-auto}"; label="$5"
		case "$url" in http://*|https://*) ;; *) echo "bad url" >&2; exit 1 ;; esac
		[ -n "$label" ] || label="$url"
		reg_add "$CAT" url 1 "$fmt" "$label" "$url" ;;
	add-blob)
		valid_cat "$CAT" || { echo "unknown category" >&2; exit 1; }
		btype="$3"; fmt="${4:-auto}"; label="$5"; path="$6"
		case "$btype" in file|text) ;; *) echo "bad type" >&2; exit 1 ;; esac
		[ -s "$path" ] || { echo "empty blob" >&2; exit 1; }
		id=$(reg_add "$CAT" "$btype" 1 "$fmt" "$label" "")
		cp "$path" "$(blob_path "$CAT" "$id")" && printf '%s' "$id" ;;
	get-blob)   # вывести содержимое blob file/text-источника (для просмотра/правки в панели)
		valid_cat "$CAT" || exit 1
		f=$(blob_path "$CAT" "$3"); [ -f "$f" ] || { echo "no blob" >&2; exit 1; }
		cat "$f" ;;
	set-blob)   # перезаписать содержимое СУЩЕСТВУЮЩЕГО blob (правка вставленного текста/файла)
		valid_cat "$CAT" || exit 1
		id="$3"; path="$4"
		[ -s "$path" ] || { echo "empty blob" >&2; exit 1; }
		[ -f "$(blob_path "$CAT" "$id")" ] || { echo "no such blob" >&2; exit 1; }
		cp "$path" "$(blob_path "$CAT" "$id")" ;;
	del)      valid_cat "$CAT" || exit 1; reg_del "$CAT" "$3" ;;
	toggle)   valid_cat "$CAT" || exit 1; case "$4" in 0|1) reg_toggle "$CAT" "$3" "$4" ;; *) exit 1 ;; esac ;;
	set-format) valid_cat "$CAT" || exit 1; reg_set_format "$CAT" "$3" "$4" ;;
	enable)
		valid_cat "$CAT" || exit 1
		case "$3" in
			1) : > "$(enable_path "$CAT")" ;;
			# Идёт проход — он мог проверить «включена» раньше этого выключения и поставит правила ПОСЛЕ teardown: помечаем
			# dirty, держатель пройдёт ещё раз и снимет их (проход начинается с проверки «включена»).
			0) rm -f "$(enable_path "$CAT")"; teardown "$CAT"
			   # Идёт проверка связи — отменяем её (разбор у guard_cancelled).
			   [ "$(cat "$(ram_dir "$CAT")/.guard.state" 2>/dev/null | tr -d ' \r\n')" = APPLYING ] && gstate "$(ram_dir "$CAT")" CANCELLED
			   _elk="$(ram_dir "$CAT")/.update.lock"
			   if [ -d "$_elk" ] && ! _lock_stale "$_elk"; then : > "$(ram_dir "$CAT")/.update.dirty"; fi ;;
			*) exit 1 ;;
		esac ;;
	safe-enable)   # включить + собрать/применить + self-test с авто-откатом (слой 3); зовётся CGI фоном
		valid_cat "$CAT" || exit 1
		guarded_enable "$CAT" ;;
	guard-begin)   # синхронное начало проверки связи (CGI — до фонового safe-enable); код 1 — проверка уже идёт
		valid_cat "$CAT" || exit 1
		guard_begin "$CAT" ;;
	allow-set)
		case "$CAT" in adblock|ipblock) ;; *) echo "исключения есть только у adblock и ipblock" >&2; exit 1 ;; esac
		[ -f "$3" ] || { echo "no file" >&2; exit 1; }
		allow_set "$CAT" "$3" ;;
	# Набор «не блокировать» устарел, когда сменился сервер туннеля или выхода: адрес нового VPS в нём
	# появлялся только на следующем обновлении списков (сутки-неделя), и сервер из списка FireHOL рвал
	# туннель при включённой блокировке. Зовёт apply-bypass.sh на смене endpoint'а. Набора нет (блокировки
	# по адресам нет) — нечего и пересобирать.
	allow-sync)
		ipset list -n 2>/dev/null | grep -qx blocklist_allow && ensure_allow_set
		exit 0 ;;
	*) echo "usage: lists-update.sh update|list|presets|add-url|add-blob|get-blob|set-blob|del|toggle|set-format|enable|allow-set <cat> … | allow-sync" >&2; exit 2 ;;
esac
