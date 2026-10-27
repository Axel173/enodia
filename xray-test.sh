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
command -v daemon_ram_room >/dev/null 2>&1 || { daemon_ram_room() { return 0; }; DAEMON_GO_NEED_KB=0; }   # old library: no RAM guard
command -v daemon_wait_gone >/dev/null 2>&1 || daemon_wait_gone() { _dwg=0; while [ -d "/proc/$1" ]; do [ "$_dwg" -ge "${2:-5}" ] && return 1; sleep 1; _dwg=$((_dwg+1)); done; return 0; }
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
xt_lock() {   # $1 = lock dir, $2 = who may hold it alive (regex, default a test run) → 0 taken (our pid in it); 1 held by a live run
	mkdir "$1" 2>/dev/null && { echo $$ > "$1/pid"; return 0; }
	_lp=$(cat "$1/pid" 2>/dev/null | tr -cd '0-9')
	[ -n "$_lp" ] || { sleep 1; _lp=$(cat "$1/pid" 2>/dev/null | tr -cd '0-9'); }
	if [ -n "$_lp" ] && pid_runs "$_lp" "${2:-xray-test}"; then return 1; fi
	mv "$1" "$1.stale.$$" 2>/dev/null && rm -rf "$1.stale.$$" 2>/dev/null
	mkdir "$1" 2>/dev/null && { echo $$ > "$1/pid"; return 0; }
	return 1
}
lock_take() { xt_lock "$TLOCK" && _lk=1; }
# RAM FOR ONE MORE XRAY (BE6500 tester, OOM 24.10.2026: the main xray 68 MB + a server test's own 39 MB on a 393-MB router, and the
# kernel killed the TUNNEL; the panel checks up to six servers side by side). A test's xray is let in by RAM (daemon-lib.sh::
# daemon_ram_room) and the admission is SERIAL: one start at a time, holding the admission until its port listens — the next asks
# what is left AFTER this one loaded; six at once would all read the same free memory and all pass. No room while other tests run —
# wait for them (a test lasts seconds), so a tight router checks one by one instead of falling; no room with nobody to wait for, or
# not within XT_ADMIT_MAX — refuse as `busy`: no verdict about the SERVER (the panel and premium.sh read busy as «not now»).
XT_ADMIT=/tmp/enodia-xray-test.admit
XT_ADMIT_MAX=${XT_ADMIT_MAX:-60}
_adm=0; XT_ADMIT_WHY=''; XT_ADMIT_MEM=0
# The admission is also held by a tight-flash update swapping xray in place (packages.sh::inpl_admit): its holder is the ENGINE, and
# read as a dead test it was taken from under the swap by a test already queued here — one that passed the swap marker before it
# existed started xray mid-swap (review s.166 r2).
XT_ADMIT_HOLDERS='xray-test|packages\.sh'
# Waited for is a test whose XRAY runs (its memory comes back when it ends) — not one waiting for the admission like us: counted, the
# waiters all waited for each other the full minute and refused «идут другие проверки» where the truth was «мало памяти» (review
# s.166 r1).
xt_others() {   # another run's test xray is alive → 0
	for _xo in /tmp/enodia-xray-test.1081[2-9].pid; do
		[ -f "$_xo" ] && [ "$_xo" != "$TPID" ] || continue
		_xop=$(cat "$_xo" 2>/dev/null | tr -cd '0-9')
		[ -n "$_xop" ] && pid_runs "$_xop" 'xray' && return 0
	done
	return 1
}
xt_admit() {
	_xai=0
	while :; do
		if xt_lock "$XT_ADMIT" "$XT_ADMIT_HOLDERS"; then
			_adm=1
			daemon_ram_room "$DAEMON_GO_NEED_KB" && return 0
			rm -rf "$XT_ADMIT" 2>/dev/null; _adm=0; XT_ADMIT_MEM=1
			xt_others || { XT_ADMIT_WHY="мало свободной памяти ($DAEMON_RAM_WHY): ещё один xray уронил бы туннель — проверка не начата"; return 1; }
		fi
		# «Short of memory» (`mem`) only when memory WAS the reason: a run that never got the admission within the minute waited for
		# other runs — the panel said «роутеру мало памяти» on a roomy router (review s.166 r2).
		if [ "$_xai" -ge "$XT_ADMIT_MAX" ]; then
			if [ "$XT_ADMIT_MEM" = 1 ]; then XT_ADMIT_WHY="мало свободной памяти ($DAEMON_RAM_WHY), идут другие проверки — повторите, когда они кончатся"
			else XT_ADMIT_WHY="идут другие проверки — повторите, когда они кончатся"; fi
			return 1
		fi
		sleep 1; _xai=$((_xai + 1))
	done
}
xt_admit_drop() { [ "$_adm" = 1 ] && rm -rf "$XT_ADMIT" 2>/dev/null; _adm=0; return 0; }
cleanup() {
	[ "$_lk" = 1 ] || return 0
	# The run's xray is GONE before the lock goes (xt_done removes it next): `kill` returns before the process dies, and a run
	# that took the freed lock at once found the port still held by the old xray (s.143: the stand's check 7 under a full run).
	# TERM not heard in 3 s — KILL, and only OUR xray (a pid from the file may have been reused), as slot-tun-lib.sh does with hev.
	_xp=$(cat "$TPID" 2>/dev/null | tr -cd '0-9')
	if [ -n "$_xp" ]; then
		kill "$_xp" 2>/dev/null
		if ! daemon_wait_gone "$_xp" 3; then
			pid_runs "$_xp" xray && { kill -9 "$_xp" 2>/dev/null; daemon_wait_gone "$_xp" 2; }
		fi
	fi
	rm -f "$TPID" "$TCONF" "$TOUT" "$TOUT".* "$TACC" 2>/dev/null
	return 0
}
# Замок снимаем ПОСЛЕДНИМ и только свой: чужой (держатель жив) не наш, и снять его — ровно та гонка, от которой он.
# Сигнал — выход после уборки: ловушка busybox на сигнале без `exit` вернула бы управление в середину скрипта.
xt_done() { cleanup; xt_admit_drop; [ "$_lk" = 1 ] && rm -rf "$TLOCK" 2>/dev/null; _lk=0; return 0; }
trap xt_done EXIT
trap 'exit 1' INT TERM HUP PIPE

[ -n "$name" ] || { emit '{"ok":false,"msg":"не задано имя конфига"}'; exit 0; }
src="$ENODIA_STATE/xray-configs/$name.json"
# A CONFIG NOT LAID OUT YET (premium.sh wait_live: a new Amnezia key is asked by the result BEFORE it replaces the file in use) — by
# its path in the caller's environment; the name stays the run's label. The CGI cannot set it: uhttpd passes no environment.
case "${XRAY_TEST_SRC:-}" in /*) src=$XRAY_TEST_SRC ;; esac
# A tight-flash update is putting the new xray in place of the old (packages.sh::inpl_swap): no verdict about any server now. The swap
# is live while its ENGINE runs — the marker carries packages.sh's pid: one left by an engine killed mid-swap (OOM on a tight model,
# no exit trap) answered «идёт замена» to every test until a reboot (review s.166 r2).
xt_swap_live() { _xsp=$(cut -d' ' -f1 /tmp/enodia-pkg-inplace 2>/dev/null | tr -cd '0-9'); [ -n "$_xsp" ] && pid_runs "$_xsp" 'packages\.sh'; }
xt_swap_live && { emit '{"ok":false,"busy":true,"msg":"идёт замена программы на месте — повторите через минуту"}'; exit 0; }
# No program — no verdict about the SERVER either (`nobin`: the panel neither caches nor counts it dead; premium.sh ends in these
# words). The swap's failed copy leaves exactly this, and «Удалять мёртвые» deleted live servers for it (review s.166 r2).
XT_NOBIN='{"ok":false,"nobin":true,"msg":"xray не установлен на роутере"}'
[ -x "$XRAY" ] || { emit "$XT_NOBIN"; exit 0; }
[ -s "$src" ]  || { emit '{"ok":false,"msg":"конфиг не найден"}'; exit 0; }

lock_take || { emit "{\"ok\":false,\"busy\":true,\"msg\":\"на временном порту $TPORT идёт другая проверка — повторите, когда она кончится\"}"; exit 0; }
cleanup   # снять возможный прошлый тест (замок наш — значит, прежний держатель мёртв)

# Копия конфига: socks-инбаунд 10808 -> временный $TPORT; лог-пути -> порт-уникальные *-test
# (не трогаем боевой /tmp/xray.log И не пересекаемся с параллельными тест-инстансами на др. портах).
# Access-лог гасим ВСЕГДА («none»), даже у СТАРОГО конфига с путём внутри: он пишет каждое
# соединение в ОЗУ и никем не ротируется (~15 МБ/сут, замер 29.08.2026), а тест его не читает —
# вердикт выносится по коду curl через временный socks. $TACC остаётся только в cleanup: подчищает
# файлы, оставшиеся от прогонов ДО этой правки.
# The copy holds the server's credential (an Amnezia Premium standby key among them, probed every ~15 s for minutes): born closed
# and new — the caller's umask made it 0644, and a name planted in shared /tmp would be followed by `>` (review s.136 r2, L5).
( umask 077; rm -f "$TCONF"; set -C
  sed -e "s/\"port\"[[:space:]]*:[[:space:]]*10808/\"port\": $TPORT/" \
      -e "s#/tmp/xray-access.log#none#g" \
      -e "s#/tmp/xray\.log#$TLOG#g" \
      "$src" > "$TCONF" ) 2>/dev/null
[ -s "$TCONF" ] || { emit '{"ok":false,"msg":"не удалось подготовить тест-конфиг"}'; exit 0; }

: > "$TLOG" 2>/dev/null
# The same Go heap ceiling as the working xray (owner net-tune.sh, form filtered next to the launch — its reader contract): up to
# eight tests run side by side, and each took memory with no ceiling (26.10.2026).
_tgc=$(sh "$ENODIA_DIR/net-tune.sh" memlimit-env 2>/dev/null | grep -E '^GOMEMLIMIT=[0-9]+MiB$')
# `mem` — the refusal is about the router's MEMORY, not a busy port: the panel counts it apart, premium.sh stops waiting on it.
# `queue` — not memory: other runs held the admission the whole minute; the panel checks such a server again, one at a time (s.166 r3).
xt_admit || { _xm=',"queue":true'; [ "$XT_ADMIT_MEM" = 1 ] && _xm=',"mem":true'; emit "{\"ok\":false,\"busy\":true$_xm,\"msg\":\"$XT_ADMIT_WHY\"}"; exit 0; }
# A swap that started while this run waited for the admission has ended (it held the admission) — on the new build, or with none.
[ -x "$XRAY" ] || { emit "$XT_NOBIN"; exit 0; }
start-stop-daemon -S -b -m -p "$TPID" -x /bin/sh -- -c "exec ${_tgc:+env $_tgc }'$XRAY' run -c '$TCONF' >>'$TLOG' 2>&1"

# Ждём тестовый socks, ПОКА ЖИВ ПРОЦЕСС (daemon-lib.sh). Прежний фиксированный срок делал
# ровно ту ошибку, ради которой библиотека и заведена: на накопителе бинарь читается дольше,
# чем мы ждали, и панель говорила «сервер не поднялся» про исправный сервер — с ПУСТЫМ логом,
# потому что демону нечего было сказать. Пустой лог теперь замещаем причиной отказа.
if ! daemon_wait_port "$TPID" xray 8 127.0.0.1 "$TPORT"; then
	err=$(tail -n 4 "$TLOG" 2>/dev/null | tr -d '\r\033' | sed 's/\[[0-9;]*m//g' | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-300)
	emit "{\"ok\":false,\"msg\":\"xray не поднялся с этим конфигом: ${err:-$DAEMON_WAIT_WHY}\"}"
	exit 0
fi
xt_admit_drop   # loaded and listening: the next test asks the memory left after this one

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
			# -k: the body is discarded, only its size counts — and on a build whose curl finds no issuer (AX3600: ANY https
			# = rc=60, dns-lib.sh::curl_ca_opt) every server measured «скачивание не пошло» (s.162, measured).
			got=$(curl -s -k --max-time "$rem" -o /dev/null --socks5-hostname "127.0.0.1:$TPORT" \
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
