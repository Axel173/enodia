#!/bin/sh
# events.sh — ЖУРНАЛ СОБЫТИЙ роутера («центр уведомлений» веб-панели).
#
# Зачем отдельно от notify-event.sh:
#   notify-event.sh решает «слать ли ПИСЬМО» (throttle + .notify-off). Но панель
#   должна показывать, что происходило, ДАЖЕ когда почта не настроена, выключена
#   или письмо задушено throttle'ом. Это два разных вопроса: «уведомить наружу»
#   и «запомнить для истории». Поэтому журнал — свой скрипт, а notify-event.sh
#   зовёт его ДО своих гейтов. Побочный плюс: журнал переиспользуем — любой
#   скрипт может писать событие, не втягивая SMTP.
#
# Использование:
#   events.sh add <key> <dedup_sec> "Тема" "Текст"
#   events.sh list [n]        — JSON для панели (по умолчанию все, кольцо ≤ MAX)
#   events.sh mark-read [ts]  — пометить прочитанным до ts (показанное панелью; нет/негодное — «сейчас»)
#   events.sh clear           — очистить журнал
#   events.sh class <key>     — повод письма (класс) события
#   events.sh classes         — «класс on|off» построчно, в порядке экрана «О чём писать»
#   events.sh mail <класс> on|off — выбор человека: слать ли письма о поводе
#   events.sh mail-ok <key>   — слать ли письмо о событии: код 0 — да, 3 — повод выключен
#
# ПОЧЕМУ ВЫБОР ПИСЕМ ЗДЕСЬ, а не в notify-event.sh: класс — такой же СМЫСЛ события, как уровень, и
# выводится из того же ключа (владелец один — этот файл). notify-event.sh спрашивает `mail-ok` и не
# знает ни классов, ни формата файла выбора; CGI панели — тоже (`classes`/`mail`), как и с журналом.
# Журнал выбор НЕ глушит: «письмо» и «история» — разные вопросы (разбор ниже, у notify-event.sh).
#
# dedup_sec — окно СХЛОПЫВАНИЯ повторов того же key (передаём тот же throttle,
#   что и у письма: событие, письмо о котором задушено, не должно плодить строки).
#   Повтор в окне не добавляет строку, а обновляет существующую: count+1 и свежий
#   ts/текст. 0 = не схлопывать (редкие события: boot, утренняя сводка).
#
# Хранилище — на /data (переживает ребут): журнал ценен именно после ребута
# («что было ночью, пока меня не было»), в /tmp он бы стирался ровно тогда, когда
# нужен. Запись идёт только по событию (boot / switch / failover / сводка) —
# несколько строк в сутки, флеш это не изнашивает.
#
# Формат строки — TSV, ровно 6 полей:
#   ts \t key \t level \t count \t base64(title) \t base64(text)
# ПОЧЕМУ base64 у текста: тело события многострочное и содержит кавычки/юникод, а
# JSON-экранирования на busybox нет (нет ни jq, ни awk-функций). Плоский TSV с
# base64-полями и разбирается awk'ом в одну строку, и в JSON уезжает без единого
# спецсимвола — панель декодирует своим b64toUtf8 (уже есть у редактора списков).
# Побочно это защищает CGI-JSON от порчи чужим текстом.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
EV="$ENODIA_STATE/.events"
READ_MARK="$ENODIA_STATE/.events-read"
MUTE="$ENODIA_STATE/.notify-mute"   # выключенные поводы писем, по классу в строке; нет файла — пишем обо всех
LOCK=/tmp/enodia-events.lock
MAX=100            # кольцо: держим последние N событий (≈20 КБ) — панели больше не нужно

# Единый детект модели: заголовки событий callers хардкодят «BE7000:» — на AX3600/BE3600
# журнал панели врал моделью. router_relabel переписывает лидирующий код на реальный.
if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi

# Возраст ЛОКА — через age_since (clock-lib.sh): лок живёт в /tmp, то есть рождается после
# загрузки, а скачок часов вперёд делает СВЕЖИЙ лок «протухшим» — и в журнал полезли бы два
# писателя разом. Возраст записи в самом журнале считается иначе, там отметка переживает ребут
# (см. `# clock-raw:` ниже). Шим = прежнее поведение для установки без библиотеки.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
	case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
	[ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

now=$(date +%s)

# --- Лок: cron-скрипты (heal/watchdog) могут писать событие одновременно ------
# mkdir — атомарный на busybox (паттерн lists-update.sh). Устаревший лок (скрипт
# умер, не убрав) снимаем по возрасту, иначе журнал замолчал бы навсегда.
lock_take() {
	i=0
	while [ "$i" -lt 30 ]; do
		mkdir "$LOCK" 2>/dev/null && return 0
		i=$((i + 1))
		if [ -d "$LOCK" ]; then
			# Возраст лока. `date -r` есть не в каждой сборке busybox (на BE7000 есть — проверено
			# 04.08.2026), и прежний фолбэк `|| echo 0` в этом случае давал возраст «эпоха» ⇒ ЖИВОЙ
			# лок сносился на ПЕРВОЙ же итерации, то есть на сборке без `-r` лока не было вовсе.
			# Не смогли узнать возраст — считаем лок свежим: подождать безопаснее, чем топтать журнал.
			lt=$(date -r "$LOCK" +%s 2>/dev/null)
			case "$lt" in ''|*[!0-9]*) lt=$now ;; esac
			[ "$(age_since "$lt")" -gt 60 ] && { rm -rf "$LOCK" 2>/dev/null; continue; }
		fi
		sleep 1
	done
	return 1
}
lock_free() { rm -rf "$LOCK" 2>/dev/null; }

# --- Уровень события выводим ИЗ КЛЮЧА ----------------------------------------
# Так вызывающим (их 10 мест) не надо менять сигнатуру и помнить про уровни —
# ключ у события и так есть. Порядок веток ЗНАЧИМ: «failover-ok» содержит «fail»,
# поэтому -ok/rollback разбираются РАНЬШЕ общей fail-ветки.
level_of() {
	case "$1" in
		*failover-ok|*rollback)   echo warn ;;   # работает, но не штатно (ушли на резерв / откатились)
		# Возврат домой — ШТАТНОЕ событие, а в имени ключа есть «fail»: без этой строки глоб ниже красил бы успешный
		# возврат «сбоем» (ревью шага 3c-2, круг 1).
		failback|failback-server) echo info ;;
		wan-down)                 echo warn ;;   # интернета нет ВООБЩЕ: авария у провайдера, VPN ни при чём
		# «fail» ГДЕ УГОДНО в ключе, а не только в конце: ключ доп-выхода — `slot-fail-2`, он
		# кончается НОМЕРОМ, и прежние глобы (*-fail|*fail) его не брали ⇒ письмо «доп-выход
		# недоступен» лежало в центре уведомлений нейтральным info. Замерено на AX3600 17.08.2026.
		*fail*|awg0-down|awg-noraise|subs-nospace) echo err ;;
		# Ключи, у которых беда не названа словом «fail». Их НЕ выводит никакой глоб — только
		# перечисление, и новый ключ по умолчанию попадает в info: заводя событие о поломке или
		# деградации, впиши его СЮДА, иначе панель покажет его наравне с «подписки обновлены».
		# cross-switch — несущую сменил АВТОМАТ (awg↔альт): связь есть, но не та, что выбрал
		# человек. rule-heal — правила сплита кто-то снёс (fw3-reload), роутер вернул их сам.
		# Оба «работает, но не штатно» — тот же уровень, что у failover-ok\rollback выше;
		# тревожного слова в ключе нет, значит глоб их не возьмёт — только это перечисление.
		# doh-dot-fallback — выбран DoT, а порт 853 не проходит: DNS шифруется, но по DoH (doh-lib.sh).
		# hev-restart-* — залипшую прослойку TUN→прокси сторож перезапустил сам (slot-tun-lib.sh): работает, но соединения рвались.
		transport-missing|geo-snap-skip|doh-auto-off|doh-dot-fallback|subs-active-gone|cross-switch|rule-heal|hev-restart-*) echo warn ;;
		*)                        echo info ;;
	esac
}

# --- ПОВОД ПИСЬМА (класс) — тоже ИЗ КЛЮЧА ------------------------------------
# Ключей три десятка, и решать о каждом человек не станет: он решает о ПОВОДАХ — «сбой VPN», «утренняя
# сводка списков». Выбор «О чём писать» (панель → Уведомления) ведётся по классам, порядок CLASSES —
# порядок строк на экране. ПАРА «БЕДА + ЕЁ КОНЕЦ» — ОДИН КЛАСС (vpn-failopen/vpn-restored, wan-down/
# wan-up): выключив падения, человек не должен получать «восстановлено» о падении, о котором ему не
# написали. Загрузка, после которой VPN НЕ поднялся (boot-fail), — сбой VPN, а не «роутер загрузился».
# Ключ без своей ветки уходит в `system`, и C107 краснеет на таком ключе у любого вызывателя: молчаливый
# дефолт сделал бы новый ключ о поломке «служебным», и выключенное «служебное» глушило бы его письмо.
CLASSES="down switch wan boot addr subs lists system"
class_of() {
	case "$1" in
		vpn-failopen|switch-failopen|failover-fail|awg0-down|awg-noraise|transport-missing|boot-fail|vpn-restored|slot-fail-*|slot-ok-*) echo down ;;
		cross-switch|cross-rollback|failover-ok|xray-failover-ok|hy2-failover-ok|failback|failback-server|switch-rollback) echo switch ;;
		wan-down|wan-up)          echo wan ;;
		boot-ok)                  echo boot ;;
		panel-wan-ip)             echo addr ;;   # шлёт только открытый «вход снаружи»: в письме — новая ссылка на панель
		subs-*)                   echo subs ;;
		iplist-*|ipblock-*|geo-*) echo lists ;;
		rule-heal|clock-step|store-mode-fail|doh-auto-off|doh-enable-failed|doh-dot-fallback|doh-dot-back|hev-restart-*) echo system ;;
		*)                        echo system ;;
	esac
}
muted() { grep -q "^$1\$" "$MUTE" 2>/dev/null; }   # $1 — класс из CLASSES (буквы), в регулярке безопасен

cmd_classes() {
	for c in $CLASSES; do
		if muted "$c"; then echo "$c off"; else echo "$c on"; fi
	done
}

# Код 3, а не 1: у events.sh СТАРШЕ этого верба неизвестный верб = usage и код 1, и notify-event.sh новее
# events.sh (смешанное обновление) читал бы это как «повод выключен» — письма о сбое молча пропали бы.
cmd_mail_ok() {
	muted "$(class_of "$1")" && return 3
	# VPN ВЫКЛЮЧЕН ЧЕЛОВЕКОМ — письма о его состоянии (падение, уход на резерв, возврат: классы down и switch) говорят о том, что
	# он сам только что отменил. Их шлёт автоматика, начатая ДО выключения: перебор серверов, досчитав до живого, писал «VPN снова
	# работает» при «выключенном вами» VPN (ревью ветки, круг 1). Журнал записан раньше гейтов — молчит только почта. Код СВОЙ (4):
	# notify-event.sh старше этого гейта читает его как «можно» — ровно прежнее поведение.
	if [ -f "$ENODIA_STATE/.vpn-off" ]; then
		case "$(class_of "$1")" in down|switch) return 4 ;; esac
	fi
	return 0
}

# Незнакомый класс — отказ, а не новая строка: опечатка или панель новее роутера молча копили бы в файле
# выбор, который никто не читает. Класс — ОДНО слово: `case` по списку пропускал «lists system» (два известных
# подряд) мусорной строкой. Коды: 0 — записано, 2 — не понял просьбу, 4 — журнал занят, 5 — не записалось.
# Код 1 НЕ наш: его отдаёт events.sh старше верба (usage), и CGI читает его как «обновите скрипты».
cmd_mail() {
	case "$1" in ''|*[!a-z]*) echo "неизвестный повод письма: $1"; return 2 ;; esac
	case " $CLASSES " in *" $1 "*) ;; *) echo "неизвестный повод письма: $1"; return 2 ;; esac
	case "$2" in on|off) ;; *) echo "выбор письма — on или off"; return 2 ;; esac
	lock_take || { echo "журнал событий занят — повторите"; return 4; }
	# Итог считаем В ПАМЯТИ и пишем с проверкой: при полном /data пустой .new читался как «всё включено», файл выбора
	# стирался с кодом 0, и выключенные поводы молча возвращались (ревью шага 7b). Записанное сверяем чтением.
	# Атомарно (.new + mv): notify-event.sh может читать выбор ровно в этот момент. Пустой итог — файла нет вовсе.
	_mn=$(grep -v "^$1\$" "$MUTE" 2>/dev/null; [ "$2" = off ] && echo "$1")
	if [ -n "$_mn" ]; then
		printf '%s\n' "$_mn" > "$MUTE.new" 2>/dev/null && [ "$(cat "$MUTE.new" 2>/dev/null)" = "$_mn" ] && mv "$MUTE.new" "$MUTE" 2>/dev/null
		_mr=$?
	else
		rm -f "$MUTE" 2>/dev/null; [ ! -e "$MUTE" ]; _mr=$?
	fi
	[ "$_mr" = 0 ] || rm -f "$MUTE.new" 2>/dev/null
	lock_free
	[ "$_mr" = 0 ] || { echo "не удалось записать выбор писем"; return 5; }
	return 0
}

b64() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\r\n'; }

cmd_add() {
	key="$1"; dedup="$2"; title="$3"; text="$4"
	[ -n "$key" ] || return 0
	command -v router_relabel >/dev/null 2>&1 && title=$(router_relabel "$title")
	# Ключ санитизируем: он уезжает в TSV и в JSON без экранирования.
	key=$(printf '%s' "$key" | tr -c 'a-zA-Z0-9_-' '_')
	case "$dedup" in ''|*[!0-9]*) dedup=0 ;; esac
	lvl=$(level_of "$key")

	lock_take || return 1
	touch "$EV" 2>/dev/null

	cnt=1
	if [ "$dedup" -gt 0 ]; then
		# Последнее событие этого класса: в окне — схлопываем (count+1), строку
		# пересоздаём в конце, чтобы порядок журнала оставался хронологическим.
		old=$(awk -F'\t' -v k="$key" '$2==k{l=$0} END{print l}' "$EV" 2>/dev/null)
		if [ -n "$old" ]; then
			old_ts=$(printf '%s' "$old" | cut -f1)
			old_cnt=$(printf '%s' "$old" | cut -f4)
			case "$old_ts"  in ''|*[!0-9]*) old_ts=0 ;; esac
			case "$old_cnt" in ''|*[!0-9]*) old_cnt=1 ;; esac
			# clock-raw: отметка лежит в САМОМ журнале на /data и переживает ребут ⇒ её возраст
			# законно больше аптайма, а age_since сказал бы «только что» про вчерашнее событие и
			# схлопнул бы его с сегодняшним. Судим голой разностью сознательно.
			if [ "$old_ts" -gt 0 ] && [ "$((now - old_ts))" -lt "$dedup" ]; then
				cnt=$((old_cnt + 1))
				awk -F'\t' -v k="$key" -v t="$old_ts" '!($2==k && $1==t)' "$EV" > "$EV.new" 2>/dev/null
				mv "$EV.new" "$EV" 2>/dev/null
			fi
		fi
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$key" "$lvl" "$cnt" "$(b64 "$title")" "$(b64 "$text")" >> "$EV"
	# Кольцо. Атомарно (.new + mv): CGI может читать журнал ровно в этот момент.
	if [ "$(wc -l < "$EV" 2>/dev/null || echo 0)" -gt "$MAX" ]; then
		tail -n "$MAX" "$EV" > "$EV.new" 2>/dev/null && mv "$EV.new" "$EV" 2>/dev/null
	fi
	lock_free
}

cmd_list() {
	n="$1"
	case "$n" in ''|*[!0-9]*) n=$MAX ;; esac
	rd=$(cat "$READ_MARK" 2>/dev/null)
	case "$rd" in ''|*[!0-9]*) rd=0 ;; esac
	# now отдаём часами РОУТЕРА: у него нет RTC, браузерное «сколько назад» без
	# этого врёт (та же причина, что в emit_sites у iplist_updated).
	printf '{"now":%s,"read_at":%s,"events":[' "$now" "$rd"
	if [ -s "$EV" ]; then
		tail -n "$n" "$EV" 2>/dev/null | awk -F'\t' -v OFS='' '
			NF>=6 {
				if (c++) printf ","
				printf "{\"ts\":%s,\"key\":\"%s\",\"level\":\"%s\",\"count\":%s,\"title\":\"%s\",\"text\":\"%s\"}", $1, $2, $3, $4, $5, $6
			}'
	fi
	printf '],"unread":%s}\n' "$(cmd_unread "$rd")"
}

# Непрочитанные = события свежее отметки. Отметка одна на журнал (а не флаг на
# строку): панель читает список целиком, поштучный read только плодил бы записи
# на флеш.
cmd_unread() {
	rd="$1"
	if [ -z "$rd" ]; then
		rd=$(cat "$READ_MARK" 2>/dev/null)
		case "$rd" in ''|*[!0-9]*) rd=0 ;; esac
	fi
	[ -s "$EV" ] || { echo 0; return; }
	awk -F'\t' -v r="$rd" '$1+0>r{n++} END{print n+0}' "$EV" 2>/dev/null || echo 0
}

case "$1" in
	add)        shift; cmd_add "$1" "$2" "$3" "$4" ;;
	list)       cmd_list "$2" ;;
	unread)     cmd_unread ;;
	# Отметка — ДО самого свежего ПОКАЗАННОГО события, а не «до сейчас»: событие, пришедшее между ответом списка и отметкой,
	# иначе числилось бы прочитанным, так и не показавшись (ревью шага 7b). Отметка назад не едет (две вкладки), в будущее — тоже.
	# Прежняя отметка ИЗ БУДУЩЕГО (записана, пока часы убегали, потом их вернули) — негодная: «назад не едет» сделало бы её вечной,
	# и все новые события, включая падение VPN, рождались бы прочитанными (ревью шага 7b, круг 2).
	# Чтение прежней отметки и запись новой — под локом журнала: две вкладки, отметившие разом, иначе могли откатить её назад.
	# Лок не взят (занят чужим прогоном дольше потолка) — пишем всё равно: отметка прочтения не стоит того, чтобы её терять.
	mark-read)  _rt=$2; case "$_rt" in ''|*[!0-9]*) _rt=$now ;; esac; [ "$_rt" -le "$now" ] || _rt=$now
	            lock_take; _rl=$?
	            _ro=$(cat "$READ_MARK" 2>/dev/null); case "$_ro" in ''|*[!0-9]*) _ro=0 ;; esac; [ "$_ro" -le "$now" ] || _ro=0
	            [ "$_rt" -ge "$_ro" ] || _rt=$_ro
	            echo "$_rt" > "$READ_MARK" 2>/dev/null; _rw=$?; [ "$_rl" = 0 ] && lock_free
	            # Не записалась (полный /data) — так и сказать: панель, решив «отмечено», перечитывала бы экран за экраном.
	            if [ "$_rw" = 0 ]; then printf '{"ok":true,"read_at":%s}\n' "$_rt"; else printf '{"ok":false}\n'; fi ;;
	clear)      lock_take && { : > "$EV"; echo "$now" > "$READ_MARK"; lock_free; }; printf '{"ok":true}\n' ;;
	class)      class_of "$2" ;;
	classes)    cmd_classes ;;
	mail)       cmd_mail "$2" "$3"; exit $? ;;
	mail-ok)    cmd_mail_ok "$2"; exit $? ;;
	*)          echo "usage: $0 add <key> <dedup_sec> <title> <text> | list [n] | unread | mark-read | clear | class <key> | classes | mail <class> on|off | mail-ok <key>" >&2; exit 1 ;;
esac
