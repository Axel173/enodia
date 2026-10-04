#!/bin/sh
# lists-lib.sh — общие примитивы «менеджера источников списков».
#
# ИДЕЯ (DRY, единый движок под все списки роутера). Список любой категории наполняется
# из НАБОРА источников, где источник = { тип: url|file|text, значение, формат, вкл/выкл }.
# Категория задаёт ЦЕЛЬ, куда лёг результат (ipset или dnsmasq-conf). Этот файл — только
# библиотека: он НЕ исполняется сам, его сорсят lists-update.sh (генерик-драйвер) и,
# после интеграции, iplist-update.sh. Здесь живёт всё, что переиспользуется:
#   - fetch_url  — устойчивая закачка (DoH-фолбэк по IP-литералу мимо dnsmasq);
#   - detect_format / norm_cidr / norm_domains — распознавание и нормализация форматов
#     (hosts / dnsmasq / adblock-ABP / CIDR / plain) в один из двух «видов» (cidr|domains);
#   - apply_ipset / apply_dnsmasq_block — атомарная заливка результата в цель;
#   - reg_* — чтение/запись TSV-реестра источников на /data (переживает ребут).
#
# БУСИБОКС-ГРАБЛИ (см. карту проекта): grep -c на нуле печатает 0 и КОД 1; нет od; awk БЕЗ
# split()/index()/user-функций (только поля $N/NF/sub/gsub/match); nslookup игнорит SERVER
# → обход мёртвого dnsmasq только DoH-по-IP; timeout старого синтаксиса. Здесь всё это учтено.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
LISTS_DIR="$ENODIA_STATE/lists"             # ПЕРСИСТ на флеше: РЕЕСТР источников + мелкий персист.
# ОЗУ (tmpfs) под ВСЁ тяжёлое: закачки, нормализация, дедуп, кэш-фолбэк, снимок block-категорий.
# Флеш роутера ~20 МБ — сырьё блоклистов (StevenBlack/OISD/Hagezi = мегабайты) на /data НЕЛЬЗЯ:
# переполняло флеш → падал DNS и туннель. Тяжёлое живёт здесь и стирается на ребуте (перекачиваем).
LISTS_RAM="${LISTS_RAM:-/tmp/enodia-lists}"
# Кап размера ФЛЕШ-снимка tunnel-cidr (строк CIDR). Аномально крупный список (де-агрегированный
# opencck data=ip4 = 220k отдельных IP вместо cidr4=3.5k подсетей) раздул бы 20-МБ флеш на мегабайты
# → почти-полный флеш = падение DNS/туннеля. Свыше кап — снимок на флеш НЕ пишем (см. snap_write).
MAX_FLASH_CIDR="${MAX_FLASH_CIDR:-40000}"
TAB=$(printf '\t')

# DoH-резолв для fetch_url — ЕДИНАЯ копия в dns-lib.sh (`doh_ips`): фолбэк, написанный ради обхода
# мёртвого туннельного DNS, обязан биндиться к WAN, иначе он уходит в тот самый мёртвый туннель
# (ГРАБЛЯ №2 в шапке dns-lib.sh). Гард `if [ -f ]` обязателен: провалившийся `.` в busybox ash —
# фатальная ошибка спецбилтина, шелл выходит НА МЕСТЕ, и шим ниже не выполнился бы никогда.
# Шим-фолбэк (нет библиотеки = поломанная установка) = прежнее поведение: DoH без bind'а.
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
# Возраст лока — через age_since (clock-lib.sh): часы без RTC прыгают вперёд через ~13 мин после
# загрузки, и голая разность объявляет ЖИВОЙ лок протухшим ⇒ его сносят из-под работающего
# держателя и в категорию заходят двое. Локи наши все в /tmp (рождаются после загрузки), поэтому
# кламп по аптайму тут законен. Шим = прежнее поведение. [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
	case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
	[ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
# Имя WAN-интерфейса и шлюз — у владельца (ip-lib.sh::wan_iface / wan_gateway, следит C81): по ним
# собирается allowlist критичных адресов (collect_critical) и гард отката ipblock. Шимы = прежние
# строки: без них частичная установка молча ПОТЕРЯЛА бы шлюз из allowlist'а, и DROP по списку мог
# отрубить сам аплинк.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }
command -v wan_gateway >/dev/null 2>&1 || wan_gateway() { ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }
command -v doh_ips >/dev/null 2>&1 || doh_ips() { _r=$(curl -s --connect-timeout 3 --max-time 15 $2 "https://1.1.1.1/dns-query?name=$1&type=A" -H 'accept: application/dns-json' 2>/dev/null); [ -n "$_r" ] || _r=$(curl -sk --connect-timeout 3 --max-time 15 $2 "https://1.1.1.1/dns-query?name=$1&type=A" -H 'accept: application/dns-json' 2>/dev/null); printf '%s' "$_r" | grep -o '"data":"[0-9.]*"' | cut -d'"' -f4; }

# --- Реестр источников (TSV на /data) ----------------------------------------
# Одна строка = один источник, поля через TAB в фиксированном порядке:
#   id  type  enabled  format  count  ts  label  value
# id     — короткий уникальный (s1,s2,…), он же имя blob-файла для file/text.
# type   — url | file | text.
# enabled— 1|0.
# format — auto|cidr|hosts|dnsmasq|adblock|domain (auto = распознать при обновлении).
# count  — сколько записей дал источник в последнем удачном обновлении (для UI).
# ts     — epoch последнего обновления (0 = ещё не обновлялся).
# label  — человекочитаемое имя (для file — исходное имя файла; для url — можно хост).
# value  — для url: сам URL; для file/text: пусто (содержимое лежит в blob/<id>).
# Спецсимволы TAB/CR/LF из полей вырезаем при записи (_san), поэтому read -F TAB надёжен.

ls_dir() {  # ls_dir <cat> → каталог ПЕРСИСТА категории на флеше (реестр + blob пользователя)
	_d="$LISTS_DIR/$1"
	mkdir -p "$_d/blob" 2>/dev/null
	printf '%s' "$_d"
}
ram_dir() {  # ram_dir <cat> → каталог ОЗУ категории (закачки/кэш/рабочие файлы; стирается на ребуте)
	_d="$LISTS_RAM/$1"
	mkdir -p "$_d/cache" 2>/dev/null
	printf '%s' "$_d"
}
reg_path()   { printf '%s/sources.tsv' "$(ls_dir "$1")"; }   # флеш: реестр (переживает ребут)
# СКОЛЬКО ИСТОЧНИКОВ КАТЕГОРИИ ВКЛЮЧЕНО (колонка enabled = 1) — независимо от того, скачались ли они. Тот же признак, что у
# прохода обновления (lists-update.sh _update_pass, счётчик nen): разводит «источники не ответили» (авария, пул поднимается
# из снимка) и «человек выключил все» (решение: пул пуст НАМЕРЕННО). Спрашивает iplist-update.sh, чтобы не слать письмо
# «источники недоступны, наполнится само» тому, кто их выключил (тестер, 06.09.2026). Нет реестра — пусто: судить не по чему.
reg_nen() {
	_rgp=$(reg_path "$1"); [ -f "$_rgp" ] || return 0
	awk -F"$TAB" '$1 != "" && $3 == "1" { n++ } END { print n + 0 }' "$_rgp"
}
blob_path()  { printf '%s/blob/%s'  "$(ls_dir "$1")" "$2"; }  # флеш: контент file/text-источника (нет URL для перекачки)
cache_path() { printf '%s/cache/%s' "$(ram_dir "$1")" "$2"; } # ОЗУ: фолбэк последней удачной закачки URL
allow_path() { printf '%s/allow' "$(ls_dir "$1")"; }       # флеш: исключения категории (adblock — домены, ipblock — IPv4/CIDR)
enable_path(){ printf '%s/.enabled' "$(ls_dir "$1")"; }    # флеш: мастер-флаг (adblock/ipblock off по умолч.)
# Снимок последнего результата. tunnel-cidr — на ФЛЕШЕ (маршрутизация обязана пережить ребут ОФЛАЙН,
# ~3000 CIDR = десятки КБ). adblock/ipblock — в ОЗУ (списки мегабайтные; на ребуте re-fetch, heal.sh 5.8).
# zapret-cidr/zapret-dom — тоже на ФЛЕШЕ и по той же причине, что tunnel-cidr: zapret работает БЕЗ
# VPS, и его смысл — «интернет жив, даже когда сервера нет»; пул на пару сотен CIDR/доменов должен
# подниматься офлайн, а не ждать успешной закачки. Кап MAX_FLASH_CIDR ниже страхует ВСЕ флеш-снимки.
snap_path()  {
	case "$1" in
		tunnel-cidr|zapret-cidr|zapret-dom) printf '%s/.snapshot' "$(ls_dir "$1")" ;;
		*)                       printf '%s/.snapshot' "$(ram_dir "$1")" ;;
	esac
}
# snap_write <cat> <srcfile>: записать снимок результата. Для ФЛЕШ-снимка (tunnel-cidr) — с КАПОМ:
# свыше MAX_FLASH_CIDR строк снимок НЕ пишем (не раздуваем 20-МБ флеш; маршрутизация живёт в ipset
# RAM и на ребуте перекачается через iplist-update/heal.sh), печатаем подсказку в лог вызывающего.
# RAM-снимки (adblock/ipblock — снапшот в /tmp) кап не трогает: там памяти вдоволь. DRY: единая
# точка записи снимка вместо голого cp — тут же ловим оба сценария (флеш-кап / RAM-без-капа).
snap_write() {
	_c="$1"; _sf="$2"; _dst=$(snap_path "$_c")
	case "$_dst" in
		"$LISTS_DIR"/*)
			_ln=$(grep -c '' "$_sf" 2>/dev/null); case "$_ln" in ''|*[!0-9]*) _ln=0 ;; esac
			if [ "$_ln" -gt "$MAX_FLASH_CIDR" ]; then
				# Совет зависит от ВИДА списка: у CIDR-целей лечится агрегированным источником
				# (cidr4 вместо ip4), у доменного пула агрегировать нечего — только список поменьше.
				case "$_c" in
					*-dom|*domains) _hint="возьмите список поменьше" ;;
					*)              _hint="используйте агрегированный CIDR (data=cidr4)" ;;
				esac
				echo "снимок на флеш ПРОПУЩЕН: $_ln строк > лимита $MAX_FLASH_CIDR — $_hint. В RAM список работает, но не переживёт офлайн-ребут"
				return 0
			fi ;;
	esac
	cp "$_sf" "$_dst" 2>/dev/null
}

# --- сериализация тяжёлых проходов (лок в ОЗУ) ---------------------------------------
# Общая пара для ЛЮБОГО «пересобрать всё из реестра» (движок списков do_update, гео do_build).
# Два прохода одновременно пишут в ОДНИ рабочие файлы ОЗУ и общий реестр → врут счётчики в UI и
# собирают сеты из полу-данных. Первый берёт АТОМАРНЫЙ mkdir-лок; конкурент помечает <dirty> и
# выходит — держатель после прохода переиграет под свежее состояние, схлопнув N кликов в ОДИН
# доп. проход (тяжёлые закачки второй раз не тянем). Лок в /tmp (ребут чистит сам); убитого
# держателя детектим по /proc — устаревший лок снимаем `rm -rf` (внутри pid-файл, rmdir не возьмёт).
# ls_lock_take <lockdir> <dirtyfile> [payload] → 0 = лок взят (вызывающий обязан ls_lock_drop),
#                                               1 = держатель жив/лок не взять (dirty помечен).
# _lock_stale <lockdir> [окно_сек] → 0 = лок ТОЧНО протух (держатель мёртв / каталог старше окна),
#                                    1 = считаем живым.
# ПОЧЕМУ не прежнее «нет pid-файла ⇒ протух»: между `mkdir` и записью ПИДа есть окно в несколько
# микросекунд, и конкурент, заставший ровно его, сносил ЖИВОЙ лок — в критическую секцию заходили
# ОБА. Не теория: замерено 04.08.2026 на BE7000 — шесть одновременных `add-url` дали ДВА источника
# с одним id (s1). Нет ПИДа = «ещё не записан», и судить тут можно только по ВОЗРАСТУ каталога;
# когда ПИД есть, возраст не важен вовсе (обновление блоклистов законно идёт минутами).
_lock_stale() {
	_lp=$(cat "$1/pid" 2>/dev/null)
	if [ -n "$_lp" ]; then
		[ -d "/proc/$_lp" ] && return 1
		return 0
	fi
	_la=$(date -r "$1" +%s 2>/dev/null)
	case "$_la" in ''|*[!0-9]*) return 1 ;; esac   # busybox без `date -r` → не гадаем, считаем живым
	[ "$(age_since "$_la")" -gt "${2:-120}" ]
}
ls_lock_take() {
	_ld="$1"; _df="$2"; _dp="$3"
	if ! mkdir "$_ld" 2>/dev/null; then
		if ! _lock_stale "$_ld"; then
			printf '%s' "$_dp" > "$_df" 2>/dev/null; return 1   # держатель жив → он переиграет
		fi
		rm -rf "$_ld" 2>/dev/null
		mkdir "$_ld" 2>/dev/null || { printf '%s' "$_dp" > "$_df" 2>/dev/null; return 1; }
	fi
	echo $$ > "$_ld/pid"
	return 0
}
ls_lock_drop() { rm -f "$1/pid" 2>/dev/null; rmdir "$1" 2>/dev/null; }

_san() { printf '%s' "$1" | tr -d "$TAB\r\n"; }

# --- Лок РЕЕСТРА источников ---------------------------------------------------
# Писателей у одного sources.tsv ДВОЕ и они пересекаются штатно: фоновый do_update дёргает
# reg_set_meta/reg_set_format на КАЖДЫЙ источник (закачка блоклиста = минуты), а панель в это же
# время может добавить/удалить/переключить источник — она же сама и триггерит update следом.
# Все они переписывали файл через ОБЩЕЕ имя "$_f.new" БЕЗ лока ⇒ два awk'а писали в один черновик,
# и `mv` победителя терял чужую правку (источник «вернулся» после удаления, счётчик уехал в чужую
# строку). Тот же класс, что реестр слотов (`slots.sh`, лок-каталог + ПИД в черновике) — лечим так же:
# атомарный mkdir-лок в ОЗУ + временный файл С ПИДом. Лок не взять (держатель жив дольше окна) —
# работаем как раньше: потерять правку хуже, чем подождать, но насмерть вставать реестру нельзя.
_reg_lock_dir() { printf '/tmp/.enodia-lists-reg.%s.lock' "$1"; }   # /tmp: ребут снимает лок сам
reg_lock_take() {  # reg_lock_take <cat> → 0 = взят (обязателен reg_lock_drop) | 1 = не удалось
	_rl=$(_reg_lock_dir "$1"); _ri=0
	while [ "$_ri" -lt 15 ]; do
		mkdir "$_rl" 2>/dev/null && { echo $$ > "$_rl/pid"; return 0; }
		_ri=$((_ri + 1))
		# «Держателя нет» судим ОБЩЕЙ _lock_stale (пид в /proc, иначе возраст): мутация реестра
		# короткая, поэтому окно протухания здесь маленькое — 30 с против 120 у прохода обновления.
		if _lock_stale "$_rl" 30; then rm -rf "$_rl" 2>/dev/null; continue; fi
		sleep 1
	done
	return 1
}
reg_lock_drop() { rm -rf "$(_reg_lock_dir "$1")" 2>/dev/null; }

# _reg_rewrite <cat> <awk-аргументы…> — перезапись реестра ПОД ЛОКОМ и через черновик С ПИДом.
# Единая точка для всех reg_*-мутаций: своей копии «awk > .new && mv» больше нигде не заводить.
_reg_rewrite() {
	_rc="$1"; shift
	_rf=$(reg_path "$_rc"); [ -f "$_rf" ] || return 1
	reg_lock_take "$_rc"; _rlk=$?
	_rt="$_rf.new.$$"
	if awk -F"$TAB" -v OFS="$TAB" "$@" "$_rf" > "$_rt" 2>/dev/null; then
		mv "$_rt" "$_rf"; _rr=0
	else
		rm -f "$_rt" 2>/dev/null; _rr=1   # awk упал (нет места/битый файл) — реестр НЕ трогаем
	fi
	[ "$_rlk" = 0 ] && reg_lock_drop "$_rc"
	return $_rr
}

# ОПЦИОНАЛЬНЫЕ категории: выключены по умолчанию (нужен .enabled) и обновляются по общему
# расписанию «как opencck». ЕДИНЫЙ СПИСОК — «новая опциональная категория = ОДНО слово здесь»:
# отсюда его берут cat_enabled (ниже), iplist-update.sh (периодика 7) и heal.sh (boot 5.8),
# иначе категорию пришлось бы дописывать в три разных цикла и один из них неизбежно бы отстал.
# zapret-cidr — пул десинка ПО IP (ipset zapret_cidr): домены наполняют пул только для клиентов,
# спрашивающих наш dnsmasq, а телевизор/приставка с собственным DNS в доменный сет не попадает
# НИКОГДА (замерено на железе 2026-07-25) — CIDR-пул закрывает ровно эту дыру.
# zapret-dom — пул десинка ПО ДОМЕНАМ (ipset zapret_dom): СВОИ домены файлом/URL/текстом рядом с
# курированной четвёркой категорий zapret.sh (youtube/google/discord/meta). Та четвёрка вшита в код
# ⇒ добавить домен = правка скрипта, а не действие в панели; этот пул закрывает ровно это.
ls_opt_cats() { echo "adblock ipblock zapret-cidr zapret-dom"; }

# Категория «включена»? tunnel-cidr/tunnel-domains всегда on (это не блокировка, а маршрутизация);
# опциональные (ls_opt_cats) — только если есть .enabled (по умолчанию выключено).
cat_enabled() {
	case " $(ls_opt_cats) " in
		*" $1 "*) [ -f "$(enable_path "$1")" ] ;;
		*) return 0 ;;
	esac
}

reg_next_id() {  # следующий свободный sN (детерминированно, max+1)
	_f=$(reg_path "$1"); _max=0
	if [ -f "$_f" ]; then
		_max=$(awk -F"$TAB" '$1 ~ /^s[0-9]+$/{n=substr($1,2)+0; if(n>m)m=n} END{print m+0}' "$_f")
		case "$_max" in ''|*[!0-9]*) _max=0 ;; esac
	fi
	printf 's%s' "$((_max + 1))"
}

reg_add() {  # reg_add <cat> <type> <enabled> <format> <label> <value> → печатает новый id
	_cat="$1"; _type="$2"; _en="$3"; _fmt="$4"; _lbl="$5"; _val="$6"
	# Выбор id и дозапись — ПОД ОДНИМ локом: два одновременных «добавить» читали max+1 из одного
	# состояния и получали ОДИН id на двоих (две строки s3 ⇒ удаление сносит обе, blob общий).
	reg_lock_take "$_cat"; _alk=$?
	_id=$(reg_next_id "$_cat"); _f=$(reg_path "$_cat")
	printf '%s\t%s\t%s\t%s\t0\t0\t%s\t%s\n' \
		"$_id" "$_type" "$_en" "$_fmt" "$(_san "$_lbl")" "$(_san "$_val")" >> "$_f"
	[ "$_alk" = 0 ] && reg_lock_drop "$_cat"
	printf '%s' "$_id"
}
reg_del() {  # reg_del <cat> <id> — убрать строку + blob/cache
	_f=$(reg_path "$1"); [ -f "$_f" ] || return 0
	_reg_rewrite "$1" -v id="$2" '$1!=id'
	rm -f "$(blob_path "$1" "$2")" "$(cache_path "$1" "$2")" 2>/dev/null
}
reg_toggle() {  # reg_toggle <cat> <id> <0|1>
	_reg_rewrite "$1" -v id="$2" -v v="$3" '$1==id{$3=v} {print}'
}
reg_set_format() {  # reg_set_format <cat> <id> <fmt>
	_reg_rewrite "$1" -v id="$2" -v v="$3" '$1==id{$4=v} {print}'
}
reg_set_meta() {  # reg_set_meta <cat> <id> <count> <ts>
	_reg_rewrite "$1" -v id="$2" -v c="$3" -v t="$4" '$1==id{$5=c;$6=t} {print}'
}

# --- Закачка URL с устойчивостью к мёртвому туннельному DNS (перенос из iplist-update.sh) ---
# Штатно curl резолвит через dnsmasq. Но на установке/boot dnsmasq заперт во внутренний DNS
# туннеля, который ещё не несёт → резолв мёртв. Трафик к источнику идёт ПРЯМО (мимо туннеля),
# поэтому при сбое штатного пути резолвим хост через DoH ПО IP-ЛИТЕРАЛУ (самим 1.1.1.1/8.8.8.8
# DNS не нужен) и тянем по --resolve. nslookup НЕ годится (busybox игнорит SERVER-аргумент).
fetch_url() {  # fetch_url <url> <outfile> → 0 + непустой outfile при успехе
	# Два прохода: сперва СО сверкой TLS (штатно), затем — при полном провале — с -k.
	# Часть роутеров несёт устаревший CA-бандл (нет ISRG Root X1): curl рвёт валидные
	# Let's Encrypt-серты «unable to get local issuer certificate», а DoH-фолбэк ниже
	# (тоже HTTPS) глохнет по той же причине → у fetch не оставалось ни одного живого
	# пути. Списки — публичные фильтр-данные (задают лишь МАРШРУТ IP, не секреты), поэтому
	# -k как последний шанс допустим. На BE7000/BE10000 Pro сверка проходит → -k не нужен.
	_u="$1"; _o="$2"
	_fetch_try '' && return 0
	_fetch_try '-k' && return 0
	return 1
}

_fetch_try() {  # $1 = '' | '-k' (сверка/без); берёт _u/_o из fetch_url; 0 + непустой _o при успехе
	# ПОЧЕМУ -f и -L (добавлены 04.08.2026 ревью). Без `--fail` curl отдаёт код 0 на ЛЮБОЙ HTTP-ответ:
	# страница 404/403/«репозиторий переехал» — это «удачная закачка» непустого файла. Дальше она
	# (а) кладётся в кэш ПОВЕРХ последней ХОРОШЕЙ копии, то есть ломает сам фолбэк «источник умер →
	# берём кэш», и (б) нормализуется в 0 записей ⇒ пул поднимается из снимка, а в логе «src ok».
	# Без `--location` 301/302 (типовой ответ jsdelivr/зеркал при переезде) читался бы как ТЕЛО
	# ответа-редиректа. Оба флага применяем и к DoH-ветке ниже — путь один, разница только в резолве.
	_k="$1"
	if curl $_k -sfL --max-time 120 "$_u" -o "$_o" && [ -s "$_o" ]; then return 0; fi
	_host=$(printf '%s' "$_u" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|[/?#].*$||' -e 's|^[^@]*@||' -e 's|:.*$||')
	[ -n "$_host" ] || return 1
	case "$_u" in http://*) _port=80 ;; *) _port=443 ;; esac
	# doh_ips сам ходит СНАЧАЛА через WAN, потом как есть; `-k` передаём и в DoH-пробу — устаревший
	# CA-бандл ломает её ровно так же, как основную закачку. `--max-time` держим прежним (15 с):
	# закачка списков — холодный путь по cron, а не подъём несущей, где секунды на счету.
	_ips=$(doh_ips "$_host" "$_k --max-time 15")
	[ -n "$_ips" ] || return 1
	for _ip in $_ips; do
		case "$_ip" in *.*.*.*) ;; *) continue ;; esac
		if curl $_k -sfL --max-time 120 --resolve "$_host:$_port:$_ip" "$_u" -o "$_o" && [ -s "$_o" ]; then
			return 0
		fi
	done
	return 1
}

# --- Распознавание формата (по образцу первых строк) -------------------------
detect_format() {  # stdin → echo cidr|hosts|dnsmasq|adblock|domain
	_s=$(grep -vE '^[[:space:]]*([#!].*)?$' 2>/dev/null | head -50)
	if   printf '%s' "$_s" | grep -qE '^\|\|';                                   then echo adblock
	elif printf '%s' "$_s" | grep -qE '^(address|server|ipset|local)=/';         then echo dnsmasq
	elif printf '%s' "$_s" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}[[:space:]]+[A-Za-z0-9]'; then echo hosts
	elif printf '%s' "$_s" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?[[:space:]]*$'; then echo cidr
	else echo domain
	fi
}

# --- ЗАЩИТА LAN: срезать приватные/зарезервированные/широкие CIDR из блок-списков ------------
# КРИТИЧНО для ipblock: правила `iptables DROP` по blocklist_set (INPUT/FORWARD src+dst) рубят ВСЮ
# сеть, если в set попадёт LAN/приватка. «Лёгкие» списки вредоносных IP (FireHOL level1 = fullbogons+…)
# СОДЕРЖАТ 192.168/16, 10/8, 172.16/12, 100.64/10 (=подсеть awg0!), 127/8, 169.254/16 → без фильтра
# DROP по src убивает LAN→роутер (DNS/DHCP/панель) и LAN→инет, переживая ребут. Пойман на железе:
# юзер выбрал «лёгкий» список вредоносных IP → умерла вся локалка → спас только сброс роутера.
# Парсим первые два октета и маску численно (busybox awk: только поля/сравнения, без split/index/функций).
# $1 — МИНИМАЛЬНАЯ допустимая длина маски (по умолчанию 8). Приватку/богоны режем всем одинаково, а
# вот «широкая маска» значит разное у разных целей. У БЛОК-целей (ipblock, zapret-cidr) /7 и шире —
# наверняка мусор, дороже разбираться. У МАРШРУТНОЙ (tunnel-cidr) — нет: агрегатор opencck законно
# отдаёт /7-блоки (замерено 04.08.2026 на живом листе: 38/7, 126/7, 210/7, 218/7 — 4 записи из 3543),
# и вырезать их значило бы молча увести часть заблокированных сайтов МИМО туннеля, то есть чинить
# утечку LAN ценой «сайт перестал открываться». Маршрутному пулу хватает порога 4: /0../3 — это уже
# «весь интернет», для чего в панели есть отдельный тумблер, а всё уже, чем /4, безопасно.
# Про 126.0.0.0/7 (внутри него 127/8): loopback не страдает — таблица `local` идёт с pref 0, то есть
# РАНЬШЕ нашего `fwmark 0x1 → table 1000` (pref 99), проверено на роутере.
strip_bogon() {  # strip_bogon [мин_маска] ; stdin (CIDR по строке) → stdout БЕЗ приватных/богонов
	awk -F'[./]' -v minm="${1:-8}" '
	{
		o1=$1+0; o2=$2+0
		mask = ($5=="") ? 32 : $5+0        # "a.b.c.d/m" → $5=m; "a.b.c.d" → нет $5 (=/32)
		if (mask < minm) next              # слишком широкая маска для этой цели (см. шапку функции)
		if (o1==0 || o1==10 || o1==127) next            # this-net / 10-я приватка / loopback
		if (o1>=224) next                               # multicast+reserved 224.0.0.0/3
		if (o1==169 && o2==254) next                    # link-local 169.254/16
		if (o1==172 && o2>=16 && o2<=31) next           # 172.16/12 приватка
		if (o1==192 && o2==168) next                    # 192.168/16 приватка (наш LAN)
		if (o1==100 && o2>=64 && o2<=127) next          # CGNAT 100.64/10 — подсеть awg0!
		if (o1==198 && (o2==18 || o2==19)) next         # 198.18/15 benchmark
		print
	}'
}

# --- ЗАЩИТА СВЯЗИ: динамический allowlist критичных ПУБЛИЧНЫХ IP -------------------------------
# strip_bogon режет ПРИВАТКУ, но критичные сущности — ПУБЛИЧНЫЕ IP: endpoint активной несущей (VPS),
# WAN-шлюз/WAN-IP, DNS-апстримы. Попади любой из них в блок-лист вредоносных IP — DROP оборвёт
# несущую/интернет/резолв (юзер: «а если в списки попадёт IP провайдера или VPS?»). Собираем их
# на КАЖДЫЙ apply в ipset blocklist_allow → правило `--match-set blocklist_allow -j RETURN` ПЕРЕД
# DROP (см. ensure_block_rules в lists-update.sh) → эти IP никогда не дропаются, даже если в списке.
# Набор общий у ДВУХ блокировок по адресам: списков (ipblock) и гео-категорий «Блок» (geo.sh).
#
# ФОРМАТ СТРОКИ — «адрес<TAB>причина[<TAB>уточнение]» (шаг 5c переноса панели). Экран «Блокировка»
# показывал только ЧИСЛО («4 адреса в обход»), а вопрос человека — КАКИЕ и почему; ответ обязан
# дать тот, кто список собирает, а не панель своей догадкой. Причины: vps (сервер основного туннеля) ·
# exit + номер выхода (сервер доп-выхода) · gw (шлюз провайдера) · wan (адрес роутера у провайдера) ·
# dns (апстрим dnsmasq) · net + интерфейс (подключённая подсеть) · user (исключение, заданное человеком).
# Потребителю набора нужно только первое поле (ensure_allow_set режет его сам).
# ДВЕ ДЫРЫ, закрытые здесь же: доп-выходы (у каждого СВОЙ VPS, файл `.endpoint-bypass-s<id>`) в
# набор не попадали вовсе — их сервер в списке FireHOL рвал выход; и исключений человека не было
# совсем: ложное срабатывание чужого списка лечилось только выключением списка целиком.
collect_critical() {  # stdout: «IP/CIDR<TAB>причина[<TAB>уточнение]» по строке — НИКОГДА не блокировать/не дропать
	# endpoint активной несущей (VPS) — авто-файл apply-bypass (та же анти-петля, что для mangle).
	[ -s "$ENODIA_STATE/.endpoint-bypass" ] && grep -E '^[0-9]' "$ENODIA_STATE/.endpoint-bypass" 2>/dev/null | sed "s/\$/${TAB}vps/"
	# endpoint'ы доп-выходов (slots.sh, apply-bypass endpoint-slot-set) — у каждого свой сервер.
	for _cs in 2 3 4; do
		[ -s "$ENODIA_STATE/.endpoint-bypass-s$_cs" ] && grep -E '^[0-9]' "$ENODIA_STATE/.endpoint-bypass-s$_cs" 2>/dev/null | sed "s/\$/${TAB}exit${TAB}$_cs/"
	done
	# Имя WAN и шлюз — у владельца (ip-lib.sh); до 05.09.2026 тут жила своя копия wan_iface,
	# и она НЕ исключала свои несущие — при дефолте main в туннеле «WAN-IP» был бы адресом awg0.
	_wif=$(wan_iface)
	if [ -n "$_wif" ]; then
		# WAN-шлюз (via) + WAN-IP интерфейса.
		wan_gateway | grep -E '^[0-9]' | sed "s/\$/${TAB}gw/"
		ip -4 addr show dev "$_wif" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | sed "s/\$/${TAB}wan/"
	fi
	# DNS-апстримы dnsmasq — числовые, из ОБОИХ каталогов (живой /tmp несёт сниппеты, которых в /etc нет: раздельный
	# резолв рунета) и в обеих формах: `server=IP` и `server=/домен/IP` (адрес — после последней «/»). Петлевой адрес
	# (локальный прокси шифрованного DNS, 127.0.0.1#5053) — сам роутер: списки его не несут (strip_bogon), и в «Защите
	# сети» он был бы строкой-шумом; настоящие адреса тогда — у резолвера шифрованного DNS (ниже).
	# Свои сниппеты блокировки (реклама, пул десинка, гео) — сотни тысяч строк address=/ipset=, апстримов там нет: экран
	# «Блокировка» спрашивает этот список на каждый показ и опрос, и grep по ним шёл бы каждый раз.
	for _ccd in /etc/dnsmasq.d /tmp/dnsmasq.d; do
		for _ccf in "$_ccd"/*.conf; do
			case "${_ccf##*/}" in 06-adblock.conf|07-zapret-dom.conf|1[0-9]-geo*.conf) continue ;; esac
			[ -f "$_ccf" ] && grep -hE '^[[:space:]]*server=' "$_ccf" 2>/dev/null
		done
	done \
		| sed 's/^[[:space:]]*server=//; s/[[:space:]]//g; s#.*/##; s/#.*$//' \
		| grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | grep -v '^127\.' | sed "s/\$/${TAB}dns/"
	# ЧЕМ РЕЗОЛВИТ РОУТЕР СЕЙЧАС — у владельца ответа (doh-lib.sh::dns_now, своей копии не держим): его `addr=` знает и
	# стоковые серверы провайдера из resolv.conf.auto (установка «только панель», своего апстрима нет), а при шифрованном
	# DNS — адреса резолвера (doh_resolver_ips). В подоболочке — библиотека не должна затереть переменные вызывающего.
	if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then
		( . "$ENODIA_DIR/doh-lib.sh" 2>/dev/null
		  if command -v dns_now >/dev/null 2>&1; then
			  _ccn=$(dns_now 2>/dev/null)
			  printf '%s\n' "$_ccn" | sed -n 's/^addr=//p' | tr ' ,' '\n\n' | sed 's/#.*$//'
			  printf '%s\n' "$_ccn" | grep -q '^src=doh' && doh_resolver_ips 2>/dev/null
		  fi ) \
			| tr ' ' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | grep -v '^127\.' | sed "s/\$/${TAB}dns/"
	fi
	# Подключённые подсети (LAN br-lan/guest/miot + локальная сеть WAN) — proto kernel даёт network/mask;
	# интерфейс — третьим полем: «домашняя сеть» и «сеть провайдера» для человека разные вещи.
	ip -4 route show 2>/dev/null | awk -v t="$TAB" '/proto kernel/ && $1 ~ /\//{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); print $1 t "net" t d}'   # not-wan: подсети НАШИХ мостов для allowlist, а не WAN
	# Исключения человека (экран «Блокировка»): только IPv4/CIDR, проверены при записи (allow-set ipblock).
	[ -s "$(allow_path ipblock)" ] && grep -E '^[0-9]' "$(allow_path ipblock)" 2>/dev/null | sed "s/\$/${TAB}user/"
	return 0
}

# ПИСАТЕЛЕЙ НАБОРА ЧЕТВЕРО, и локи у них разные: проход обновления списков, сборка гео, сохранение исключений из
# панели и allow-sync на смене сервера. Общее временное имя `_new` давало гонку: один уничтожал чужой черновик, а
# swap того, кто собирал ПОЗЖЕ, мог вернуть в работу набор из прежнего чтения — без нового сервера, ради которого
# allow-sync и звали. Поэтому: свой черновик (имя с пидом) И короткий лок на «прочитать → собрать → swap» — порядок
# писателей = порядок чтений. Держатель умер (пид не жив) — лок снимается; ждём недолго, дальше — без лока (набор
# «не блокировать» лучше собрать с риском гонки, чем не собрать вовсе).
# Лок — общий ls_lock_take (владелец: держатель жив по /proc, лок без пида снимается по ВОЗРАСТУ), ждём его недолго.
ALLOW_LOCK=/tmp/enodia-allowset.lock
_nap() { if command -v usleep >/dev/null 2>&1; then usleep 100000; else sleep 1; fi; }
ensure_allow_set() {  # создать/наполнить ipset blocklist_allow критичными IP (idемпотентно, атомарный swap)
	_ea_got=0; _ea_n=0
	while [ "$_ea_n" -lt 50 ]; do
		if ls_lock_take "$ALLOW_LOCK" /dev/null; then _ea_got=1; break; fi
		_nap; _ea_n=$((_ea_n + 1))
	done
	ipset list -n 2>/dev/null | grep -qx blocklist_allow || \
		ipset create blocklist_allow hash:net hashsize 1024 maxelem 65536 2>/dev/null
	# Черновики УБИТЫХ писателей (OOM, SIGKILL — ловушки нет) копились бы в ядре до ребута: снимаем те, чей пид мёртв.
	for _ea_o in $(ipset list -n 2>/dev/null | grep '^blocklist_allow_[0-9][0-9]*$'); do
		[ -d "/proc/${_ea_o#blocklist_allow_}" ] || ipset destroy "$_ea_o" 2>/dev/null
	done
	_ea_t="blocklist_allow_$$"
	ipset destroy "$_ea_t" 2>/dev/null
	ipset create "$_ea_t" hash:net hashsize 1024 maxelem 65536 2>/dev/null
	collect_critical | cut -f1 | while IFS= read -r _ip; do
		case "$_ip" in ''|'#'*) continue ;; esac
		ipset add "$_ea_t" "$_ip" 2>/dev/null
	done
	# swap даже пустого набора безопасен (пустой allow = нет исключений, но DROP всё равно под strip_bogon).
	ipset swap "$_ea_t" blocklist_allow 2>/dev/null
	ipset destroy "$_ea_t" 2>/dev/null
	[ "$_ea_got" = 1 ] && ls_lock_drop "$ALLOW_LOCK"
	return 0
}

# БЛОКИРОВКА ПО АДРЕСАМ СЕЙЧАС РАБОТАЕТ? — по цепочкам ядра, а не по существованию набора «не блокировать»: набор
# переживает свои цепочки (гео-«Блок» снят, а ipblock набор не уничтожить, пока на него ссылалась цепочка гео), и
# «набор есть» объявляло живой блокировку, которой в ядре нет: экран молчал про «ничего не блокируется», а снятое
# исключение рвало соединения всего дома впустую.
addr_block_live() {
	iptables -C INPUT -j ENODIA_BLK 2>/dev/null || iptables -C INPUT -j ENODIA_GEOBLK 2>/dev/null
}

# --- Нормализация в «вид» --------------------------------------------------
# norm_cidr: только строки, целиком являющиеся IPv4/CIDR (пробелы срезаем, комментарии — тоже).
# hosts-строка «0.0.0.0 domain» после сжатия пробелов не совпадёт с якорным regex → отсеётся
# (не заблокируем 0.0.0.0). Один проход sed+grep — быстро на больших списках.
norm_cidr() {  # stdin → stdout (по IP/CIDR на строку)
	# Комментарии: '#' (FireHOL) И ';' (Spamhaus DROP: «1.2.3.0/24 ; SBL123») — режем оба.
	_nc="${TMPDIR:-/tmp}/.normcidr.$$"
	tr -d '\r' | sed 's/[#;].*$//' > "$_nc"
	# 1) СТРОГИЙ проход: строка целиком = IP/CIDR. Так было всегда — не подхватываем IP-столбец
	#    hosts-файлов и прочий текст, где адрес лишь часть строки.
	_out=$(sed 's/[[:space:]]//g' "$_nc" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$')
	if [ -n "$_out" ]; then printf '%s\n' "$_out"; rm -f "$_nc"; return 0; fi
	# 2) ФОЛБЭК (только если строгий не дал НИ ОДНОЙ строки): источник структурный, а не плоский —
	#    официальные списки диапазонов публикуются в JSON (Google goog.json → "ipv4Prefix": "…",
	#    так же AWS/Azure/Cloudflare). Вынимаем CIDR-токены. Маска ОБЯЗАТЕЛЬНА: голый dotted-quad
	#    в структурном тексте — скорее пример/адрес в описании, чем диапазон.
	#    Порядок «строгий → фолбэк» выбран сознательно: для всех ныне работающих источников
	#    результат остаётся байт-в-байт прежним, фолбэк включается только там, где раньше был ноль.
	grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' "$_nc"
	rm -f "$_nc"
}

# norm_domains: из hosts / adblock-ABP / dnsmasq / geosite / plain вытащить голый домен (нижний
# регистр). busybox awk БЕЗ split()/index() — работаем полями $1/$2 и sub()/gsub() (доступны). Одним
# проходом обрабатываем все формы, отсекаем мусор/localhost/адрес-заглушку.
# GEOSITE-ФОРМЫ (v2fly domain-list-community, runetfreedom geosite): строка = `youtube.com`,
# `domain:youtube.com`, `full:www.youtube.com`, `keyword:youtube`, `regexp:…`, `include:другая-категория`
# (+ опциональный хвост-атрибут ` @ads`). Префиксы domain:/full: срезаем (это ровно домен), а
# keyword/regexp/include/ext ПРОПУСКАЕМ явно: они не домены, и dnsmasq их не примет. Раньше такие
# строки отсеивал финальный regex валидности — то есть файл категории v2fly приезжал почти пустым;
# теперь его можно скормить пулу как обычный источник-URL. Для живых источников (hosts/ABP/dnsmasq/
# plain) результат остаётся БАЙТ-В-БАЙТ прежним — новые ветки трогают только строки с этими префиксами.
norm_domains() {  # stdin → stdout (по домену на строку, дедуп снаружи)
	tr 'A-Z' 'a-z' | tr -d '\r' | awk '
		/^[[:space:]]*[#!]/ { next }
		/^[[:space:]]*(include|keyword|regexp|ext):/ { next }
		{
			line=$0; d=""
			if (line ~ /^\|\|/) {                       # adblock: ||domain^
				sub(/^\|\|/,"",line); sub(/[\^\/].*$/,"",line); d=line
			} else if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && NF>=2) {  # hosts: IP domain
				d=$2
			} else if (line ~ /^(address|server|ipset|local)=\//) {         # dnsmasq
				sub(/^[a-z]*=\//,"",line); sub(/\/.*$/,"",line); d=line
			} else {                                     # plain domain / geosite (первое слово)
				d=$1
				sub(/^(domain|full):/,"",d)              # v2fly/geosite: `domain:x` `full:www.x` = домен
			}
			# пользователь мог вставить URL целиком — тянем голый хост:
			sub(/^[a-z][a-z0-9+.-]*:\/\//,"",d)          # схема http:// https:// ftp:// …
			sub(/[\/?#].*$/,"",d)                         # хвост /path ?query #frag
			sub(/:[0-9]+$/,"",d)                          # :port
			gsub(/^\.+/,"",d); gsub(/\.+$/,"",d)
			if (d=="" || d=="localhost" || d=="local" || d=="localhost.localdomain") next
			if (d ~ /^[0-9.]+$/) next                     # голый IP — не домен
			# {0,61} — это метка ≤63 символов, и это НЕ косметика: dnsmasq отвергает ВЕСЬ конфиг
			# из-за одной такой строки (замер — в шапке dns-lib.sh::dom_ok), а сюда домены едут из
			# ЧУЖИХ списков на сотни тысяч строк. Один мусорный хост в источнике = сеть без DNS.
			if (d ~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/) print d
		}'
}

normalize() {  # normalize <kind cidr|domains> <format> < infile > outfile
	case "$1" in
		cidr)    norm_cidr ;;
		domains) norm_domains ;;
		*)       cat ;;
	esac
}

# --- Применение результата в цель -------------------------------------------
# apply_ipset: атомарный swap набора CIDR в боевой ipset через _new. СТРАХОВКА: swap только
# если в _new легло >0 записей (кривой/пустой источник НЕ обнулит боевой set). Печатает число
# записей и код 0 при удаче; код 1 (set не тронут) при нуле. Имя set — параметр (DRY для
# iplist_set / blocklist_set). Обобщение load_set_from_files из iplist-update.sh.
#
# ЗАЛИВКА — ЧЕРЕЗ `ipset restore` (ОДИН процесс), НЕ цикл `ipset add` (форк на строку). На больших
# списках это критично: де-агрегированный источник (opencck data=ip4 = 220k отдельных IP вместо
# cidr4=3.5k подсетей) циклом `ipset add` молотил МИНУТЫ (220k форков) и «вешал» панель на «обновляю…».
# restore читает пачку разом. `-exist` глотает дубли (иначе restore абортит на первой коллизии —
# напр. при нескольких входных файлах). Строки формируем ОДНИМ awk-проходом (не пер-строка sh):
# берём только начинающиеся с цифры (валидный IP/CIDR), мусор/комменты/пустые отсекаются. Restore-
# файл — в ОЗУ (/tmp), не на флеш; для 220k это ~8 МБ RAM, стирается сразу.
ipset_count() {  # ipset_count <setname> → число членов (0 если пусто/нет набора)
	# «Number of entries:» печатают НЕ все ядра: на kernel 4.4 (AX3600/BE3600) ipset её
	# НЕ выводит (только Size in memory/References/Members) → фолбэк на подсчёт строк-членов
	# (у inet-наборов член начинается с цифры; заголовки — с буквы, сама «Number…» — с N).
	# Сперва — ТОЛЬКО заголовок (`-t`, есть в ipset 6.38 BE7000): его зовёт и лёгкий ответ категории (`state`), а тот идёт
	# опросом раз в 2 с и пятью строками хаба «Источники списков» — полный дамп набора на 60 тыс. записей там лишний.
	# Заголовок молчит (4.4 или ipset без `-t`) — строки-члены полного вывода: второй полный вывод ради той же строки заголовка
	# ничего не дал бы — её нет ни там, ни тут.
	_c=$(ipset list -t "$1" 2>/dev/null | sed -n 's/^Number of entries:[[:space:]]*//p' | head -1)
	case "$_c" in ''|*[!0-9]*) _c=$(ipset list "$1" 2>/dev/null | grep -cE '^[0-9]') ;; esac
	case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
	printf '%s' "$_c"
}

apply_ipset() {  # apply_ipset <setname> <file...> → печатает count | код 1
	_set="$1"; shift
	ipset list -n 2>/dev/null | grep -qx "$_set" || \
		ipset create "$_set" hash:net hashsize 4096 maxelem 1000000 2>/dev/null
	ipset destroy "${_set}_new" 2>/dev/null
	ipset create "${_set}_new" hash:net hashsize 4096 maxelem 1000000 2>/dev/null
	_rf="${TMPDIR:-/tmp}/.ipset-restore.$$"; : > "$_rf"
	for _f in "$@"; do
		[ -f "$_f" ] || continue
		awk -v s="${_set}_new" '/^[0-9]/{print "add " s " " $1}' "$_f" >> "$_rf"
	done
	ipset restore -exist < "$_rf" 2>/dev/null
	rm -f "$_rf"
	_n=$(ipset_count "${_set}_new")
	if [ "$_n" -eq 0 ]; then ipset destroy "${_set}_new" 2>/dev/null; return 1; fi
	ipset swap "${_set}_new" "$_set"; ipset destroy "${_set}_new" 2>/dev/null
	printf '%s' "$_n"; return 0
}

# Перечитать dnsmasq — через агрегатор ipset=-строк (dns-merge.sh): доменный пул десинка
# (zapret-dom) перекрывается с личными правилами человека, а dnsmasq применяет к домену РОВНО
# ОДНУ строку — и пул выигрывал бы, потому что его файл читается раньше по алфавиту. Агрегатора
# нет/упал → прежний путь байт-в-байт (рестарт, не SIGHUP: address=/ipset= по HUP не перечитываются).
dnsmasq_reload() { sh "$ENODIA_DIR/dns-merge.sh" reload 2>/dev/null \
	|| /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }

# apply_dnsmasq_block: сгенерить conf «address=/домен/0.0.0.0» из файла доменов, ВЫЧТЯ исключения, одним проходом
# (100k доменов циклом sh были бы медленны). Печатает число заблокированных доменов. Пустой источник → пустой conf.
# ИСКЛЮЧЕНИЕ ДЕЙСТВУЕТ ВМЕСТЕ С ПОДДОМЕНАМИ — В ОБЕ СТОРОНЫ (шаг 5c; прежде вычиталось точное совпадение строки, а экран
# обещал «вместе с поддоменами»):
#   · строка списка — само исключение ИЛИ его поддомен (`ad.doubleclick.net` при исключении `doubleclick.net`) — не
#     блокируется: `address=/дом/` у dnsmasq закрывает и все поддомены, поэтому оставленный поддомен держал бы закрытым
#     то, что человек открыл;
#   · исключение — ПОДДОМЕН закрытого родителя (`login.example.com` при `example.com` в списке): строки родителя не
#     трогаем (он закрыт по делу), а для исключения пишем `server=/исключение/#` — «спрашивать обычные серверы». Замер
#     BE7000 22.09.2026 (dnsmasq 2.86): более длинное имя побеждает `address=` родителя. Только там, где родитель закрыт
#     на самом деле: лишняя строка перебила бы чужое правило зоны (раздельный резолв рунета для `mail.ru`).
# busybox awk без index/split — только sub() (он возвращает число замен). FNR==NR ломается на ПУСТОМ первом файле ⇒
# сюда приходим, только когда исключения есть.
apply_dnsmasq_block() {  # apply_dnsmasq_block <conf> <domainsfile> <allowfile|''> → печатает count доменов
	_conf="$1"; _dom="$2"; _allow="$3"
	mkdir -p "$(dirname "$_conf")" 2>/dev/null
	_eff="$_dom"; _dpar=''
	if [ -n "$_allow" ] && [ -s "$_allow" ]; then
		awk 'FNR==NR { if ($0!="") a[$0]=1; next }
		     { x=$0; while (1) { if (x in a) next; if (sub(/^[^.]*\./, "", x)==0) break } print }' "$_allow" "$_dom" > "$_dom.eff.$$"
		_eff="$_dom.eff.$$"
		# Исключения, чей родитель остался закрытым (по эффективному списку): только родители с точкой — «com» не домен.
		_dpar="$_dom.par.$$"
		awk 'FNR==NR { x=$0; while (sub(/^[^.]*\./, "", x)) { if (x ~ /\./) p[x]=p[x] " " $0 }; next }
		     ($0 in p) { print p[$0] }' "$_allow" "$_eff" | tr ' ' '\n' | grep . | sort -u > "$_dpar"
		# Родителя закрывает ещё и ЧУЖОЙ сниппет (гео-«Блок», своё имя с адресом): `server=/исключение/#` длиннее и его строки
		# и открыл бы поддомен, а экран обещает, что закрытое гео исключения рекламы не откроют. Такие исключения — без строки.
		if [ -s "$_dpar" ]; then
			for _dof in "$(dirname "$_conf")"/*; do
				[ "$_dof" = "$_conf" ] && continue; [ -f "$_dof" ] || continue
				sed -n 's#^address=/\([^/]*\)/.*#\1#p' "$_dof" 2>/dev/null
			done > "$_dom.oth.$$"
			if [ -s "$_dom.oth.$$" ]; then
				awk 'FNR==NR { o[$0]=1; next } { x=$0; k=1; while (sub(/^[^.]*\./, "", x)) if (x in o) { k=0; break }; if (k) print }' \
					"$_dom.oth.$$" "$_dpar" > "$_dpar.k" && mv "$_dpar.k" "$_dpar"
			fi
			rm -f "$_dom.oth.$$"
		fi
	fi
	# Блокируем ОБЕ семьи: A→0.0.0.0 И AAAA→:: . Только 0.0.0.0 НЕ режет IPv6 — dnsmasq
	# форвардит AAAA и домен открывается по IPv6 (поймано на железе 2026-07-10). Два прохода
	# sed (busybox `\n` в замене ненадёжен) → сперва все A-строки, потом все AAAA (порядок неважен).
	# Черновик — со своим пидом (пишут сюда проход обновления и сохранение исключений, и общий `.new` обрезал бы чужой
	# файл на полпути) и С ТОЧКОЙ ВПЕРЕДИ: каталог dnsmasq читается без маски, а файлы с точкой он пропускает. Иначе
	# рестарт dnsmasq посреди записи (его зовут шесть мест) читал бы недописанное — а черновик убитого прогона жил бы до
	# ребута и блокировал уже снятое.
	_cnew="$(dirname "$_conf")/.$(basename "$_conf").new.$$"
	{ sed 's|.*|address=/&/0.0.0.0|' "$_eff"; sed 's|.*|address=/&/::|' "$_eff"
	  [ -n "$_dpar" ] && [ -s "$_dpar" ] && sed 's|.*|server=/&/#|' "$_dpar"; } > "$_cnew"
	mv "$_cnew" "$_conf"
	rm -f "$_dom.eff.$$" "$_dpar" 2>/dev/null
	# Число ЗАБЛОКИРОВАННЫХ ДОМЕНОВ = число A-строк (не всех строк — их вдвое больше).
	_n=$(grep -c '/0\.0\.0\.0$' "$_conf" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
	# LISTS_NO_RELOAD — вызыватель перечитает dnsmasq сам (сборка гео: одна перезагрузка DNS сети на обе правки, а не две).
	[ -n "$LISTS_NO_RELOAD" ] || dnsmasq_reload
	printf '%s' "$_n"
}

# apply_dnsmasq_ipset: сгенерить conf «ipset=/домен/<набор>» из файла доменов, ВЫЧТЯ allowlist.
# Зеркало apply_dnsmasq_block, разница только в ЦЕЛИ: не блокировка, а НАПОЛНЕНИЕ ipset адресами
# домена — dnsmasq кладёт в набор IP из ответа резолвера (так же наполняются enodia_list/zapret_set).
# Строка ОДНА на домен (в отличие от блокировки, где нужны обе семьи A+AAAA): что именно попадёт в
# набор, решает family САМОГО набора, а не строка конфига. Набор должен СУЩЕСТВОВАТЬ — dnsmasq его
# НЕ создаёт (кладёт записи лишь в существующий; та же грабля, что у слот-сетов groups/geo).
# Печатает число доменов. Пустой источник → пустой conf (пул не наполняется).
apply_dnsmasq_ipset() {  # apply_dnsmasq_ipset <conf> <domainsfile> <setname> [allowfile] → печатает count
	_conf="$1"; _dom="$2"; _dset="$3"; _allow="$4"
	mkdir -p "$(dirname "$_conf")" 2>/dev/null
	_eff="$_dom"
	if [ -n "$_allow" ] && [ -s "$_allow" ]; then
		grep -vxF -f "$_allow" "$_dom" 2>/dev/null > "$_dom.eff"; _eff="$_dom.eff"
	fi
	_cnew="$(dirname "$_conf")/.$(basename "$_conf").new.$$"   # черновик вне поля зрения dnsmasq (разбор у apply_dnsmasq_block)
	sed "s|.*|ipset=/&/$_dset|" "$_eff" > "$_cnew"
	mv "$_cnew" "$_conf"
	rm -f "$_dom.eff" 2>/dev/null
	_n=$(grep -c '^ipset=/' "$_conf" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
	dnsmasq_reload
	printf '%s' "$_n"
}
