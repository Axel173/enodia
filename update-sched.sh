#!/bin/sh
# update-sched.sh — ПЕРИОДИЧНОСТЬ фоновых обновлений: списки источников и VLESS-подписки.
#
# Владелец cron-строк в /etc/crontabs/root для ДВУХ задач («job»):
#   lists (деф.) — `iplist-update.sh` (iplist + включённые adblock/ipblock). Раньше расписание
#                  было ЗАХАРДКОЖЕНО в установщике (`0 5 * * *`), теперь выбирается в панели.
#   subs         — `subs-update.sh update` (headless-обновление подписок). До него подписка
#                  обновлялась ТОЛЬКО из открытой панели по кнопке ⟳ ⇒ ротация серверов у
#                  провайдера = «внезапно перестал работать VPN» до следующего захода человека.
# Второй cron-владелец заводить не стали намеренно: тогда сняли/переписали бы чужую строку при
# первой же неаккуратной правке — расписание одно, кода один.
#
# Значения интервала:  off | 6h | 12h | daily | weekly.
#   - у lists суточный/недельный запуск несёт --notify (утренняя сводка), 6h/12h — молча;
#   - все запуски lists несут --lists → обновятся и ВКЛЮЧЁННЫЕ adblock/ipblock;
#   - subs всегда молчит (письмо шлёт только сам subs-update.sh и только на сбой/смену активного).
# Времена суток у задач РАЗНЫЕ (5:00 против 4:40, минуты :00 против :20): одновременный старт
# двух сетевых задач на 20-МБ флеше и слабом CPU — лишняя пиковая нагрузка на ровном месте.
#
# ИСТИНА интервала — маркер на /data (переживает ребут): .update-interval / .subs-interval. Сам
# cron живёт в /etc/crontabs (ubi1:cfg — тоже персист), но при ПЕРЕустановке установщик хардкодит
# daily для списков; поэтому он зовёт `update-sched.sh apply`, который переигрывает ОБЕ строки по
# маркерам → выбранное расписание не теряется.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BOOT=${ENODIA_BOOT:-/data/usr/app/enodia-boot}
CRON_RUN="$ENODIA_BOOT/boot.sh"    # единственная цель cron-строк: код может уехать на накопитель
CRON=/etc/crontabs/root

# --- таблица задач ----------------------------------------------------------
# job → маркер на флеше / что запускать / дефолт (нет маркера).
# Дефолт subs = off СОЗНАТЕЛЬНО: на существующих установках подписки до сих пор обновлялись
# только руками, и молча начать ходить в интернет по чужой ссылке — не наше решение.
job_valid() { case "$1" in lists|subs) return 0 ;; *) return 1 ;; esac; }
job_mark()  { case "$1" in subs) echo "$ENODIA_STATE/.subs-interval" ;; *) echo "$ENODIA_STATE/.update-interval" ;; esac; }
# ИМЯ скрипта, а не путь: cron зовёт цель ЧЕРЕЗ бутстрап ($CRON_RUN), потому что код может
# лежать на внешнем накопителе, и прямой $ENODIA_DIR/... указывал бы в пустоту (следит C58).
# Имя же служит ключом СНЯТИЯ строки — под него попадает и прежняя форма с полным путём.
job_script() { case "$1" in subs) echo "subs-update.sh" ;; *) echo "iplist-update.sh" ;; esac; }
job_def()   { case "$1" in subs) echo off ;; *) echo daily ;; esac; }

# интервал → cron-расписание («мин час дом мес дов»); пусто = off (строки нет).
sched_for() {
	if [ "$1" = subs ]; then
		case "$2" in
			off)    echo "" ;;
			6h)     echo "20 */6 * * *" ;;
			12h)    echo "20 */12 * * *" ;;
			weekly) echo "40 4 * * 1" ;;
			*)      echo "40 4 * * *" ;;
		esac
		return 0
	fi
	case "$2" in
		off)    echo "" ;;
		6h)     echo "0 */6 * * *" ;;
		12h)    echo "0 */12 * * *" ;;
		weekly) echo "0 5 * * 1" ;;   # понедельник 05:00
		*)      echo "0 5 * * *" ;;   # daily (дефолт)
	esac
}
# аргументы запуска. У списков письмо-сводка только на суточном/недельном (частый апдейт → спам).
args_for() {
	if [ "$1" = subs ]; then echo "update"; return 0; fi
	case "$2" in daily|weekly) echo "--notify --lists" ;; *) echo "--lists" ;; esac
}
# нормализация: мусор → дефолт задачи (безопасный).
norm_iv() { case "$2" in off|6h|12h|daily|weekly) echo "$2" ;; *) job_def "$1" ;; esac; }

restart_cron() {
	/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/crond restart >/dev/null 2>&1 \
		|| killall -HUP crond 2>/dev/null || true
}

# write_cron <job> <interval> — снять ЛЮБУЮ прежнюю строку задачи и записать новую по интервалу.
write_cron() {
	_j="$1"; _iv=$(norm_iv "$_j" "$2"); _bin=$(job_script "$_j")
	mkdir -p /etc/crontabs 2>/dev/null; touch "$CRON" 2>/dev/null
	# чистая переустановка строки: удаляем любую (любой график/набор флагов), затем добавляем нужную.
	sed -i "\|$_bin|d" "$CRON" 2>/dev/null
	_s=$(sched_for "$_j" "$_iv")
	if [ -n "$_s" ]; then
		echo "$_s $CRON_RUN $_bin $(args_for "$_j" "$_iv") >/dev/null 2>&1" >> "$CRON"
	fi
	restart_cron
}

# прочитать текущий интервал задачи: маркер (истина) → иначе вывести из cron-строки → иначе дефолт.
read_iv() {
	_j="$1"; _m=$(job_mark "$_j")
	if [ -f "$_m" ]; then
		norm_iv "$_j" "$(tr -cd 'a-z0-9' < "$_m" 2>/dev/null)"
		return 0
	fi
	_l=$(grep "$(job_script "$_j")" "$CRON" 2>/dev/null | head -1)
	case "$_l" in
		'')                        job_def "$_j" ;;   # строки нет вовсе → дефолт задачи
		"0 */6 "*|"20 */6 "*)      echo 6h ;;
		"0 */12 "*|"20 */12 "*)    echo 12h ;;
		"0 5 * * 1 "*|"40 4 * * 1 "*) echo weekly ;;
		*)                         echo daily ;;
	esac
}

# CLI обратно совместим: без имени задачи — «lists» (так его зовут установщик, heal и CGI
# set_update_interval, которые про подписки ничего не знают).
cmd="$1"; shift 2>/dev/null
job=lists; job_explicit=0
if job_valid "$1"; then job="$1"; job_explicit=1; shift 2>/dev/null; fi

case "$cmd" in
	set)
		iv=$(norm_iv "$job" "$1")
		printf '%s\n' "$iv" > "$(job_mark "$job")"
		write_cron "$job" "$iv"
		echo "$iv" ;;
	get)
		read_iv "$job" ;;
	apply)   # установщик/heal: применить cron по маркерам. Без имени задачи — ОБЕ (иначе после
		 # переустановки подписки молча остались бы без расписания, хотя маркер выбран).
		if [ "$job_explicit" = 1 ]; then
			write_cron "$job" "$(read_iv "$job")"
		else
			write_cron lists "$(read_iv lists)"
			write_cron subs  "$(read_iv subs)"
		fi ;;
	*)
		echo "usage: update-sched.sh set [lists|subs] <off|6h|12h|daily|weekly> | get [job] | apply [job]" >&2
		exit 1 ;;
esac
