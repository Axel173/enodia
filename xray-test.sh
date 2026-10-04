#!/bin/sh
# xray-test.sh <config-name> — РЕАЛЬНЫЙ тест xray-конфига (не только пинг!).
#
# ЗАЧЕМ: пинг меряет лишь TCP-достижимость host:port — конфиг может «пинговаться», но НЕ
# работать как прокси (битые ключи Reality, сервер спец-назначения «белый список», мёртвый
# backend за живым CDN). Этот тест поднимает xray с конфигом на ОТДЕЛЬНОМ временном socks-порту
# (10812), НЕ трогая активный транспорт (боевой socks 10808 / xtun / .transport / .xray-active),
# и гонит curl ЧЕРЕЗ него на api.ipify.org → подтверждает реальный выход в интернет + внешний IP.
# Печатает JSON: {"ok":true,"ip":"…","ms":N} или {"ok":false,"msg":"…"}.
#
# ГРАБЛИ (busybox): нет nohup/setsid → демон через start-stop-daemon -b -m -p; латентность
# берём из curl %{time_total} (date +%N ненадёжен). Лог-пути конфига переписываем на *-test,
# чтобы не затирать боевой /tmp/xray.log. Второй инстанс xray на 10812 не конфликтует с боевым
# 10808. Изолированность: тест — throwaway, чистим за собой (cleanup по pidfile + trap).

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# Тот же bin_path, что у боевого плагина (store-lib.sh): тест обязан гонять ТОТ ЖЕ бинарь,
# который поднимется несущей, — иначе «сервер проверен» ничего не значит.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Ожидание СТАРТА демона (daemon-lib.sh) — тот же владелец, что у боевого плагина: тест обязан
# ждать бинарь СТОЛЬКО ЖЕ, сколько ждёт несущая, иначе «сервер не поднялся» приезжает от медленного
# накопителя, а не от сервера (замер 448 КБ/с ⇒ 8-МБ xray читается 18 с при пороге 8).
# Нет файла (частичный apply-scripts) — шим повторяет ПРЕЖНИЙ путь: фиксированный срок.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v daemon_wait_port >/dev/null 2>&1 || daemon_wait_port() {
    DAEMON_WAIT_WHY=''; _dwi=0; while [ "$_dwi" -lt "$3" ]; do netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0; sleep 1; _dwi=$((_dwi+1)); done
    netstat -ltn 2>/dev/null | grep -q "$4:$5 " && return 0
    DAEMON_WAIT_WHY="не появился за $3 с"; return 1; }
XRAY=$(bin_path xray)
# Канонический IP-литерал trace (ip-lib.sh): DNS-free, отвечает и на ядре 4.4, где hostname
# api.ipify.org молча пустел (egress-тест ложно рапортовал «нет выхода»). Тут нужен ещё и
# time_total (-w), которого probe_ext_ip не отдаёт → берём URL из lib, парс IP инлайн. :- на случай
# запуска без установленной lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
IP_PROBE_TRACE="${IP_PROBE_TRACE:-https://1.1.1.1/cdn-cgi/trace}"

# РЕЖИМ: обычный вызов `xray-test.sh <name> [port]` = egress-тест (выход+внешний IP, деф.).
# `xray-test.sh speed <name> [port] [streams] [dur]` = тест СКОРОСТИ: МНОГОПОТОЧНО (несколько
# соединений, как speedtest.net) DUR секунд через socks конфига → агрегатные Мбит/с. Общий каркас
# temp-socks — один (DRY);
# отличается лишь финальная проба. Egress-ветка байт-в-байт прежняя (проверенный путь не трогаем).
# Режим — ЯВНЫМ словом первым аргументом: конфиг с именем `speed` иначе читался как режим, а номер порта — как имя (ревью
# пачки 2, круг 3: такой конфиг «не найден» навсегда и уезжал в «удалить мёртвые»). Без слова — прежний вызов, egress.
MODE=egress
case "$1" in speed) MODE=speed; shift ;; egress) shift ;; esac
name="$1"
# Порт временного socks-инбаунда. По умолчанию 10812; вторым аргументом можно задать другой
# (10812..10819). ЗАЧЕМ: панель гоняет ПАКЕТНЫЙ тест группы серверов ПАРАЛЛЕЛЬНО — каждый
# throwaway-инстанс xray на СВОЁМ порту, иначе они столкнулись бы на одном socks-порту и общих
# /tmp-файлах (конфиг/pid/лог/access-лог). Порт входит в имена ВСЕХ temp-файлов → изоляция
# параллельных прогонов. Диапазон валидируем — порт идёт в sed/netstat, мусор не пропускаем.
TPORT="$2"; case "$TPORT" in 1081[2-9]) : ;; *) TPORT=10812 ;; esac
# Параметры speed-режима: 3-й арг = число ПОТОКОВ (1..8, деф. 4), 4-й = ДЛИТЕЛЬНОСТЬ секунд
# (5..30, деф. 12). Многопоточно + подольше = ближе к speedtest.net (одиночный поток на дальнем
# VPS занижает). Кап бережёт трафик/время (тест жжёт реальные байты через VPS).
STREAMS="$3"; case "$STREAMS" in ''|*[!0-9]*) STREAMS=4 ;; esac
[ "$STREAMS" -lt 1 ] 2>/dev/null && STREAMS=1; [ "$STREAMS" -gt 8 ] 2>/dev/null && STREAMS=8
DUR="$4"; case "$DUR" in ''|*[!0-9]*) DUR=12 ;; esac
[ "$DUR" -lt 5 ] 2>/dev/null && DUR=5; [ "$DUR" -gt 30 ] 2>/dev/null && DUR=30
TCONF=/tmp/enodia-xray-test.$TPORT.json
TPID=/tmp/enodia-xray-test.$TPORT.pid
TLOG=/tmp/xray-test.$TPORT.log
TOUT=/tmp/enodia-xray-test.$TPORT.out
TACC=/tmp/xray-test.$TPORT.access.log

TLOCK=/tmp/enodia-xray-test.$TPORT.lock

emit() { printf '%s\n' "$1"; }
# ЗАМОК ПОРТА — СВОЙ У КАЖДОГО ПОРТА, И ДЕРЖИТ ЕГО ЖИВОЙ ПРОГОН. Прежде второй прогон на том же порту начинал с `cleanup` и
# убивал xray первого: тот писал «недоступен» про живой сервер, а на выходе его ловушка гасила уже xray второго — два живых
# сервера мёртвыми (ревью пачки 2, круг 2: одиночные проверки двух разных серверов идут на один порт по умолчанию). Теперь занятый
# ЖИВЫМ держателем порт — отказ словами (`busy` — панель не пишет вердикт); держатель мёртв (CGI убит, прогон оборван) — замок наш.
_lk=0
# Живость держателя — владельцем `daemon-lib.sh::pid_runs` (NUL строки запуска → пробел: busybox без EXTRA_COMPAT видит в сыром
# cmdline только argv[0], и живой прогон считался бы мёртвым). Замок без pid-файла — это держатель между `mkdir` и записью pid:
# ждём его секунду, а не уводим. Увод мёртвого — ПЕРЕИМЕНОВАНИЕМ (атомарно: из двух одновременных уводов удаётся один), а не `rm`,
# который снёс бы замок, только что взятый соседом (ревью пачки 2, круг 3).
command -v pid_runs >/dev/null 2>&1 || pid_runs() { [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] && tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -qE "$2"; }
lock_take() {
	mkdir "$TLOCK" 2>/dev/null && { echo $$ > "$TLOCK/pid"; _lk=1; return 0; }
	_lp=$(cat "$TLOCK/pid" 2>/dev/null | tr -cd '0-9')
	[ -n "$_lp" ] || { sleep 1; _lp=$(cat "$TLOCK/pid" 2>/dev/null | tr -cd '0-9'); }
	if [ -n "$_lp" ] && pid_runs "$_lp" 'xray-test'; then return 1; fi
	mv "$TLOCK" "$TLOCK.stale.$$" 2>/dev/null && rm -rf "$TLOCK.stale.$$" 2>/dev/null
	mkdir "$TLOCK" 2>/dev/null && { echo $$ > "$TLOCK/pid"; _lk=1; return 0; }
	return 1
}
cleanup() {
	[ "$_lk" = 1 ] || return 0
	[ -f "$TPID" ] && kill "$(cat "$TPID" 2>/dev/null)" 2>/dev/null
	rm -f "$TPID" "$TCONF" "$TOUT" "$TOUT".* "$TACC" 2>/dev/null
}
# Замок снимаем ПОСЛЕДНИМ и только свой: чужой (держатель жив) не наш, и снять его — ровно та гонка, от которой он.
# Сигнал — выход после уборки: ловушка busybox на сигнале без `exit` вернула бы управление в середину скрипта.
xt_done() { cleanup; [ "$_lk" = 1 ] && rm -rf "$TLOCK" 2>/dev/null; _lk=0; return 0; }
trap xt_done EXIT
trap 'exit 1' INT TERM HUP PIPE

[ -n "$name" ] || { emit '{"ok":false,"msg":"не задано имя конфига"}'; exit 0; }
src="$ENODIA_STATE/xray-configs/$name.json"
[ -x "$XRAY" ] || { emit '{"ok":false,"msg":"xray не установлен на роутере"}'; exit 0; }
[ -s "$src" ]  || { emit '{"ok":false,"msg":"конфиг не найден"}'; exit 0; }

lock_take || { emit "{\"ok\":false,\"busy\":true,\"msg\":\"на временном порту $TPORT идёт другая проверка — повторите, когда она кончится\"}"; exit 0; }
cleanup   # снять возможный прошлый тест (замок наш — значит, прежний держатель мёртв)

# Копия конфига: socks-инбаунд 10808 -> временный $TPORT; лог-пути -> порт-уникальные *-test
# (не трогаем боевой /tmp/xray.log И не пересекаемся с параллельными тест-инстансами на др. портах).
# Access-лог гасим ВСЕГДА («none»), даже у СТАРОГО конфига с путём внутри: он пишет каждое
# соединение в ОЗУ и никем не ротируется (~15 МБ/сут, замер 29.08.2026), а тест его не читает —
# вердикт выносится по коду curl через временный socks. $TACC остаётся только в cleanup: подчищает
# файлы, оставшиеся от прогонов ДО этой правки.
sed -e "s/\"port\"[[:space:]]*:[[:space:]]*10808/\"port\": $TPORT/" \
    -e "s#/tmp/xray-access.log#none#g" \
    -e "s#/tmp/xray\.log#$TLOG#g" \
    "$src" > "$TCONF" 2>/dev/null
[ -s "$TCONF" ] || { emit '{"ok":false,"msg":"не удалось подготовить тест-конфиг"}'; exit 0; }

: > "$TLOG" 2>/dev/null
start-stop-daemon -S -b -m -p "$TPID" -x /bin/sh -- -c "exec '$XRAY' run -c '$TCONF' >>'$TLOG' 2>&1"

# Ждём тестовый socks, ПОКА ЖИВ ПРОЦЕСС (daemon-lib.sh). Прежний фиксированный срок делал
# ровно ту ошибку, ради которой библиотека и заведена: на накопителе бинарь читается дольше,
# чем мы ждали, и панель говорила «сервер не поднялся» про исправный сервер — с ПУСТЫМ логом,
# потому что демону нечего было сказать. Пустой лог теперь замещаем причиной отказа.
if ! daemon_wait_port "$TPID" xray 8 127.0.0.1 "$TPORT"; then
	err=$(tail -n 4 "$TLOG" 2>/dev/null | tr -d '\r\033' | sed 's/\[[0-9;]*m//g' | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-300)
	emit "{\"ok\":false,\"msg\":\"xray не поднялся с этим конфигом: ${err:-$DAEMON_WAIT_WHY}\"}"
	exit 0
fi

# SPEED-режим: качаем известный размер через socks конфига (сервер тянет файл из CDN → мерим
# ПРОПУСКНУЮ способность выхода). speed.cloudflare.com/__down?bytes=N отдаёт ровно N байт (HTTPS,
# без авторизации). Среднюю скорость берём из curl %{speed_download} (байт/с) — точна и при
# недокачке по --max-time. Мбит/с = speed*8/1e6. Потолок = throughput роутера (оговорено в UI).
if [ "$MODE" = speed ]; then
	# Многопоточно + ПО ВРЕМЕНИ (как speedtest.net): STREAMS воркеров-подоболочек качают чанки в ЦИКЛЕ
	# до дедлайна t0+DUR, лимит curl по ОСТАТКУ времени → быстрый канал делает много чанков, медленный
	# один частичный (без потерь). CHUNK=75МБ — предел cloudflare __down (100МБ отдаёт 403). Каждый
	# воркер копит байты в свой файл; агрегат = сумма/факт.время (awk double: сумма сотен МБ вне 32-бит).
	CHUNK=$((75*1024*1024))
	rm -f "$TOUT".* 2>/dev/null
	t0=$(date +%s); deadline=$((t0+DUR)); k=0
	while [ "$k" -lt "$STREAMS" ]; do
		( tot=0
		  while now=$(date +%s); [ "$now" -lt "$deadline" ]; do
			rem=$((deadline-now)); [ "$rem" -lt 1 ] && break
			got=$(curl -s --max-time "$rem" -o /dev/null --socks5-hostname "127.0.0.1:$TPORT" \
			      -w '%{size_download}' "https://speed.cloudflare.com/__down?bytes=$CHUNK" 2>/dev/null)
			got=${got%.*}; case "$got" in ''|*[!0-9]*) got=0 ;; esac
			tot=$((tot+got))
		  done
		  echo "$tot" > "$TOUT.$k" ) &
		k=$((k+1))
	done
	wait
	# clock-raw: длительность ВНУТРИ одного прогона (обе точки сняты этими же часами за секунды) —
	# кламп по аптайму тут нечего исправлять, а age_since требует отметку-эпоху, не интервал.
	t1=$(date +%s); el=$((t1-t0)); [ "$el" -lt 1 ] && el=1
	total=$(cat "$TOUT".* 2>/dev/null | awk '{s=s+$1} END{printf "%.0f", s+0}')
	rm -f "$TOUT".* 2>/dev/null
	if [ "${total:-0}" -gt 0 ] 2>/dev/null; then
		mbps=$(awk -v b="$total" -v t="$el" 'BEGIN{ if(t>0) printf "%.1f", b*8/t/1000000 }')
		emit "{\"ok\":true,\"mbps\":${mbps:-0},\"bytes\":$total,\"streams\":$STREAMS,\"secs\":$el}"
	else
		emit '{"ok":false,"msg":"скачивание через этот сервер не пошло"}'
	fi
	exit 0
fi

# реальная egress-проба ЧЕРЕЗ socks конфига (--socks5-hostname: имя резолвит xray на выходе).
# -w добавляет '|<time_total>' в хвост тела trace; IP выдёргиваем из строки `ip=...`. -k: старый
# OpenSSL к 1.1.1.1 по IP не всегда валиден, из ответа берём лишь IP (не секрет).
out=$(curl -s -k --max-time 12 --socks5-hostname "127.0.0.1:$TPORT" -w '|%{time_total}' "$IP_PROBE_TRACE" 2>/dev/null)
tt=${out##*|}; body=${out%|*}
ip=$(printf '%s\n' "$body" | sed -n 's/^ip=\([0-9.]*\).*/\1/p' | head -1)
if echo "$ip" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
	ms=$(awk -v t="$tt" 'BEGIN{ if(t+0>0) printf "%.0f", t*1000 }')
	emit "{\"ok\":true,\"ip\":\"$ip\",\"ms\":${ms:-0}}"
else
	emit '{"ok":false,"msg":"нет реального выхода через этот сервер (пинг не значит рабочий)"}'
fi
exit 0
