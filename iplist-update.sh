#!/bin/sh
# iplist-update.sh — скачивает CIDR с iplist.opencck.org и заливает в ipset iplist_set.
# Запускается из cron раз в сутки (с --notify) + из heal.sh после ребута.
#
# Источник НАСТРАИВАЕТСЯ опциональным $ENODIA_STATE/iplist.conf (нет файла → весь
# cidr4 с opencck, как было). Можно сузить до конкретных сайтов (IPLIST_SITES)
# или задать свой URL (IPLIST_URL) — см. iplist.conf.example.
#
# КАСТОМНЫЙ ЛОКАЛЬНЫЙ СПИСОК (IPLIST_CUSTOM_MODE, ортогонален источнику скачивания):
#   only  — НЕ качаем вообще, set наполняется ТОЛЬКО из $IPLIST_CUSTOM_FILE (офлайн);
#   merge — качаем как обычно, потом доклеиваем $IPLIST_CUSTOM_FILE поверх;
#   пусто — кастома нет (поведение как раньше). Файл (CIDR/IP построчно) лежит на
#   /data → переживает ребут; на ПК заливается через be7000 (Источник списка IP).
#
# УСТОЙЧИВОСТЬ к недоступности источника (важно для крона в 5:00 и для boot):
# боевой ipset трогаем ТОЛЬКО после удачного скачивания (атомарный swap), поэтому
# сбой источника НЕ рушит маршрутизацию. set наполнен → остаётся прошлый список;
# set пуст (типично после РЕБУТА при мёртвом источнике) → поднимаем из локального
# снимка .iplist.snapshot (обновляется при каждом удачном скачивании). Роутер и
# интернет при недоступности источника не страдают.
#
# Флаг --notify — слать на почту итог запуска (утренняя сводка: сколько CIDR,
# дельта к прошлому разу, краткий статус VPN; либо письмо о провале закачки).
# Cron (5:00) зовёт С флагом; heal.sh зовёт БЕЗ — при каждом ребуте сводка не
# нужна, о загрузке heal шлёт своё письмо. Письма идут через notify-event.sh
# (он уважает .notify-off и throttle; здесь throttle 0 — события и так редкие).

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
SET=iplist_set
TMP=/tmp/enodia-iplist.txt
LOG=/tmp/enodia-iplist-update.log
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"
COUNT_FILE="$ENODIA_STATE/.iplist.count"   # прошлое число подсетей (для дельты; переживает ребут)
SNAP_FILE="$ENODIA_STATE/.iplist.snapshot" # последний удачно скачанный список — fallback на boot при мёртвом источнике (переживает ребут)

# Общий примитив «внешний IPv4» (ip-lib.sh) для строки «Внешний IP» в утренней сводке: IP-литерал,
# DNS-free — на ядре 4.4 hostname api.ipify.org молча пустел. Шим на случай установки без lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }

# DoH-резолв для fetch_url ниже — общий `doh_ips` (dns-lib.sh): он биндится к WAN, а собственная
# копия цикла этого не делала и потому на мёртвой несущей уходила в тот же мёртвый туннель
# (ГРАБЛЯ №2 в шапке dns-lib.sh). Шим-фолбэк = прежнее поведение, DoH без bind'а.
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
command -v doh_ips >/dev/null 2>&1 || doh_ips() { _r=$(curl -s --connect-timeout 3 --max-time 15 $2 "https://1.1.1.1/dns-query?name=$1&type=A" -H 'accept: application/dns-json' 2>/dev/null); [ -n "$_r" ] || _r=$(curl -sk --connect-timeout 3 --max-time 15 $2 "https://1.1.1.1/dns-query?name=$1&type=A" -H 'accept: application/dns-json' 2>/dev/null); printf '%s' "$_r" | grep -o '"data":"[0-9.]*"' | cut -d'"' -f4; }

# Язык уведомлений (письмо-сводка + запись в «центр уведомлений» панели) — панельный pref lang.
# Русская ветка каждого сообщения — байт-в-байт прежняя; en — параллельный перевод.
# Возраст рукопожатия для дайджест-письма — через age_since (clock-lib.sh), иначе после скачка
# часов письмо сообщало бы «handshake 77000 сек назад» о живом туннеле. Шим = прежнее поведение.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}

if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
NF_LANG=$(nf_lang)
# Чья подписка у активного сервера — у ВЛАДЕЛЬЦА ответа (subs-lib.sh::sub_owner_tag: ДЛИННЕЙШИЙ подходящий тег). Своя копия резала
# имя до первого дефиса, а теги бывают префиксами друг друга и сами с дефисом («liberty» ⊂ «liberty-vpn»): утреннее письмо
# подписывало сервер ЧУЖОЙ подпиской, а сервер подписки с дефисом в теге — никакой (ревью приёмки, 25.09.2026). Без библиотеки
# (частичная установка) письмо честно уходит без метки подписки.
if [ -f "$ENODIA_DIR/subs-lib.sh" ]; then . "$ENODIA_DIR/subs-lib.sh"; fi
command -v sub_owner_tag >/dev/null 2>&1 || sub_owner_tag() { :; }
command -v sub_label_of  >/dev/null 2>&1 || sub_label_of()  { :; }

# --- Источник списка: настраивается опциональным $ENODIA_STATE/iplist.conf ----------
# Файл на /data → переживает ребут. Нет файла → дефолт (весь cidr4 с opencck),
# поведение как раньше. Переменные (все опциональны, см. iplist.conf.example):
#   IPLIST_URL       — полный URL, используется как есть (escape hatch / др. источник);
#   IPLIST_SITES     — список сайтов через пробел → собирается &site=... к IPLIST_BASE
#                      (игнорируется, если задан IPLIST_URL);
#   IPLIST_BASE        — база для режима сайтов (по умолчанию opencck cidr4);
#   IPLIST_MIN_LINES   — порог «подозрительно мало строк» (деф. 10; снизь при узком списке);
#   IPLIST_CUSTOM_MODE — only|merge|'' — кастомный локальный список (ортогонален источнику);
#   IPLIST_CUSTOM_FILE — путь к файлу кастомного списка (деф. $ENODIA_STATE/iplist.custom).
IPLIST_BASE='https://iplist.opencck.org/?format=text&data=cidr4'
IPLIST_URL=''
IPLIST_SITES=''
IPLIST_MIN_LINES=10
IPLIST_CUSTOM_MODE=''                        # only|merge|'' — кастомный локальный список (ортогонален источнику скачивания)
IPLIST_CUSTOM_FILE="$ENODIA_STATE/iplist.custom"  # файл кастомного списка (CIDR/IP построчно), переживает ребут
[ -f "$ENODIA_STATE/iplist.conf" ] && . "$ENODIA_STATE/iplist.conf"
case "$IPLIST_MIN_LINES" in ''|*[!0-9]*) IPLIST_MIN_LINES=10 ;; esac   # защита от мусора в конфиге
case "$IPLIST_CUSTOM_MODE" in only|merge) ;; *) IPLIST_CUSTOM_MODE='' ;; esac   # только эти два режима, иначе off
[ -n "$IPLIST_CUSTOM_FILE" ] || IPLIST_CUSTOM_FILE="$ENODIA_STATE/iplist.custom"

if [ -n "$IPLIST_URL" ]; then
    URL="$IPLIST_URL"
elif [ -n "$IPLIST_SITES" ]; then
    URL="$IPLIST_BASE"
    for s in $IPLIST_SITES; do URL="$URL&site=$s"; done
else
    URL="$IPLIST_BASE"
fi

# Менеджер источников (lists-update.sh): если движок установлен, наполнение iplist_set ведём
# ЧЕРЕЗ НЕГО (мультиисточник url/файл/текст + миграция старого iplist.conf/iplist.custom внутри
# lists-update). mark-правило, дельта и дайджест-письмо остаются здесь. Нет движка → legacy-путь.
# Гард по НАЛИЧИЮ файла (зовём через `sh`), а не по биту выполнения: снятый бит у lists-update.sh
# тихо ронял нас в LEGACY-путь — реестр источников панели при этом остаётся на месте и показывает
# свои источники, а пул наполняется из старого iplist.conf. «Список тот, да не тот» без единой
# жалобы в логе. Класс Б5-9/Б6-7 (гарды `-x` вокруг вызовов через `sh`).
DELEGATED=0
[ -f "$ENODIA_DIR/lists-update.sh" ] && [ -f "$ENODIA_DIR/lists-lib.sh" ] && DELEGATED=1

# Число членов ipset. Канон — ipset_count() в lists-lib.sh; тут ЛОКАЛЬНАЯ копия (lib не source-им
# ради одной функции, как devwatch.sh). «Number of entries:» печатают НЕ все ядра: на 4.4
# (AX3600/BE3600) её нет → фолбэк на подсчёт строк-членов (член ipset начинается с цифры).
ipset_count() {  # ipset_count <set> → число (0 если пусто/нет набора)
	_c=$(ipset list "$1" 2>/dev/null | sed -n 's/^Number of entries:[[:space:]]*//p' | head -1)
	case "$_c" in ''|*[!0-9]*) _c=$(ipset list "$1" 2>/dev/null | grep -cE '^[0-9]') ;; esac
	case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
	printf '%s' "$_c"
}

# Залить CIDR-список из ОДНОГО ИЛИ НЕСКОЛЬКИХ файлов в боевой ipset атомарно
# (через временный _new). Единый код для скачанного списка, кастомного файла
# (merge: оба сразу) и fallback-снимка.
# СТРАХОВКА: swap делаем ТОЛЬКО если в _new реально легло >0 записей — иначе
# кривой/пустой источник (формат не распознан, ipset отбросил всё) молча обнулил
# бы боевой set и увёл CDN-подсети мимо VPN. Возвращает 0 (swap сделан) / 1 (set не тронут).
load_set_from_files() {
    ipset list -n 2>/dev/null | grep -qx "$SET" || \
        ipset create "$SET" hash:net hashsize 4096 maxelem 1000000
    ipset destroy "${SET}_new" 2>/dev/null
    ipset create "${SET}_new" hash:net hashsize 4096 maxelem 1000000
    for f in "$@"; do
        [ -f "$f" ] || continue
        while IFS= read -r cidr; do
            case "$cidr" in
                ''|'#'*) continue ;;
            esac
            ipset add "${SET}_new" "$cidr" 2>/dev/null
        done < "$f"
    done
    n=$(ipset_count "${SET}_new")
    if [ "$n" -eq 0 ]; then
        echo "load: 0 валидных записей из [$*] — боевой set НЕ тронут"
        ipset destroy "${SET}_new" 2>/dev/null
        return 1
    fi
    ipset swap "${SET}_new" "$SET"
    ipset destroy "${SET}_new"
    echo "load: $n записей из [$*]"
    return 0
}

# fetch_url URL OUTFILE — скачать с устойчивостью к МЁРТВОМУ туннельному DNS.
# Штатно curl резолвит через системный dnsmasq. НО на УСТАНОВКЕ (вызов из
# install.sh ДО подъёма несущей) и на boot dnsmasq заперт во внутренний
# DNS туннеля ('no-resolv; server=<VPN_DNS>'), а туннель ещё НЕ несёт → резолв
# ЛЮБОГО имени мёртв → curl падает 'download failed', а на fresh-install снимка
# нет → iplist_set остаётся ПУСТЫМ до ручного «обновить список» / ребута / 5:00
# (поймано на железе 2026-06-24, лог /tmp/enodia-iplist-update.log). Трафик к opencck
# всё равно идёт ПРЯМО (мимо туннеля, до mark-core), поэтому при сбое штатного пути
# резолвим хост ЧЕРЕЗ DoH ПО IP-ЛИТЕРАЛУ (самим адресам 1.1.1.1/8.8.8.8 DNS не нужен —
# dnsmasq в цепочке нет) и тянем по curl --resolve.
#   ПОЧЕМУ DoH, А НЕ nslookup: busybox v1.25.1 `nslookup HOST SERVER` ИГНОРИРУЕТ
#   аргумент SERVER и всегда бьёт в системный resolver (= dnsmasq). Прежний nslookup-
#   фолбэк думал, что обходит dnsmasq, а на деле шёл через тот же мёртвый dnsmasq и НЕ
#   работал — поймано на железе 2026-06-25 (byedpi-only install: `download failed` и НИ
#   ОДНОЙ строки `fallback resolve`, хотя nslookup в системе есть). DoH-по-IP — рабочий
#   обход на этом busybox (curl 8.4.0 с TLS; у 1.1.1.1/8.8.8.8 валидный IP-SAN-сертификат).
# Возвращает 0 + непустой OUTFILE при успехе. На суточном кроне (туннель жив)
# срабатывает шаг 1 — поведение прежнее, фолбэк не трогается.
fetch_url() {
    _u="$1"; _o="$2"
    # 1) штатный путь (туннель уже несёт — обычный суточный апдейт)
    # -f/-L как в lists-lib.sh: без `--fail` страница 404/«переехали» — это код 0 и непустой файл,
    # то есть «скачалось» (дальше её спасает лишь порог IPLIST_MIN_LINES); без `--location` тело
    # 301-редиректа приехало бы вместо списка.
    if curl -sfL --max-time 120 "$_u" -o "$_o" && [ -s "$_o" ]; then return 0; fi
    # 2) фолбэк: резолв мимо dnsmasq через DoH по IP-литералу, забор по --resolve
    # делитель sed — '|' (его нет в URL), т.к. в классах есть '#'/'/'/'?'
    _host=$(printf '%s' "$_u" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|[/?#].*$||' -e 's|^[^@]*@||' -e 's|:.*$||')
    [ -n "$_host" ] || return 1
    case "$_u" in http://*) _port=80 ;; *) _port=443 ;; esac
    # Парс DoH-json и порядок «через WAN → как есть» живут в dns-lib.sh::doh_ips (одна копия на
    # роутер). Таймаут DoH-пробы держим прежним (15 с) — здесь холодный путь: cron/установка.
    _ips=$(doh_ips "$_host" "--max-time 15")
    [ -n "$_ips" ] || return 1
    for _ip in $_ips; do
        case "$_ip" in *.*.*.*) ;; *) continue ;; esac   # только IPv4-вид
        echo "fallback resolve via DoH: $_host -> $_ip"
        if curl -sfL --max-time 120 --resolve "$_host:$_port:$_ip" "$_u" -o "$_o" && [ -s "$_o" ]; then
            return 0
        fi
    done
    return 1
}

# Флаги (порядок-независимо): --notify = слать сводку; --lists = после iplist обновить и другие
# ВКЛЮЧЁННЫЕ категории источников (adblock/ipblock) на том же расписании. Ставит их cron-строка
# (update-sched.sh); heal.sh зовёт БЕЗ --lists (на буте adblock/ipblock и так re-fetch'ит heal 5.8).
NOTIFY=0
REFRESH_LISTS=0
for _a in "$@"; do
    case "$_a" in
        --notify) NOTIFY=1 ;;
        --lists)  REFRESH_LISTS=1 ;;
    esac
done

# Письмо (только при --notify и наличии обёртки)
mail_event() {
    [ "$NOTIFY" = 1 ] && [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

exec >>"$LOG" 2>&1
echo "===== $(date) (notify=$NOTIFY) ====="
echo "custom mode: ${IPLIST_CUSTOM_MODE:-off} (file: $IPLIST_CUSTOM_FILE)"

# 1+2. Наполнение боевого ipset. Боевой set трогаем ТОЛЬКО валидным набором
#      (>0 записей, см. load_set_from_files), поэтому сбой/кривой источник не
#      рушит маршрутизацию.
USED_FALLBACK=0
LINES=0
SRC_DESC="$URL"   # описание источника для письма-сводки

if [ "$DELEGATED" = 1 ]; then
    # Наполнение делает менеджер источников: сам мигрирует старый конфиг, качает ВСЕ источники,
    # атомарно заливает iplist_set и держит свои snapshot/cache-фолбэки. Дайджест ниже — наш.
    echo "delegating fill to lists-update.sh (tunnel-cidr)"
    sh "$ENODIA_DIR/lists-update.sh" update tunnel-cidr
    SRC_DESC="менеджер источников (lists)"
    [ "$NF_LANG" = en ] && SRC_DESC="source manager (lists)"
elif [ "$IPLIST_CUSTOM_MODE" = only ]; then
    # ----- only: интернет НЕ трогаем, наполняем ТОЛЬКО из локального файла -----
    SRC_DESC="локальный файл $IPLIST_CUSTOM_FILE (режим only)"
    [ "$NF_LANG" = en ] && SRC_DESC="local file $IPLIST_CUSTOM_FILE (only mode)"
    echo "source: $SRC_DESC"
    if [ -s "$IPLIST_CUSTOM_FILE" ]; then
        LINES=$(wc -l < "$IPLIST_CUSTOM_FILE")
        if ! load_set_from_files "$IPLIST_CUSTOM_FILE"; then
            if [ "$NF_LANG" = en ]; then
                mail_event iplist-fail 0 "BE7000: custom list has no valid subnets" \
"Mode 'only' (local file only), but $IPLIST_CUSTOM_FILE yielded no valid
subnets. Routing was left on the PREVIOUS iplist_set list."
            else
                mail_event iplist-fail 0 "BE7000: кастомный список без валидных подсетей" \
"Режим 'only' (только локальный файл), но $IPLIST_CUSTOM_FILE не дал ни одной
валидной подсети. Маршрутизация оставлена на ПРОШЛОМ списке iplist_set."
            fi
        fi
    else
        echo "only-mode: нет/пуст $IPLIST_CUSTOM_FILE"
        if [ "$NF_LANG" = en ]; then
            mail_event iplist-fail 0 "BE7000: custom list is missing" \
"Mode 'only', but file $IPLIST_CUSTOM_FILE is missing or empty. Put a list into
that file, or switch the sources in the panel («Sites, domains, IP»). The live
set was left untouched."
        else
            mail_event iplist-fail 0 "BE7000: кастомный список отсутствует" \
"Режим 'only', но файла $IPLIST_CUSTOM_FILE нет или он пуст. Положите список в этот
файл либо переключите источники в панели («Сайты, домены, IP»). Боевой set не тронут."
        fi
    fi
else
    # ----- скачиваем (как раньше); merge доклеит локальный файл поверх -----
    echo "source: $URL"
    DOWNLOAD_OK=0
    if fetch_url "$URL" "$TMP"; then
        LINES=$(wc -l < "$TMP")
        echo "downloaded: $LINES lines"
        if [ "$LINES" -ge "$IPLIST_MIN_LINES" ]; then
            DOWNLOAD_OK=1
        else
            echo "suspicious size ($LINES < $IPLIST_MIN_LINES) — reject"
        fi
    else
        echo "download failed"
    fi

    HAVE_CUSTOM=0
    [ "$IPLIST_CUSTOM_MODE" = merge ] && [ -s "$IPLIST_CUSTOM_FILE" ] && HAVE_CUSTOM=1

    if [ "$DOWNLOAD_OK" = 1 ]; then
        # Удачно. merge → скачанное + локальный файл; иначе только скачанное.
        if [ "$HAVE_CUSTOM" = 1 ]; then
            SRC_DESC="$URL + локальный файл $IPLIST_CUSTOM_FILE (режим merge)"
            [ "$NF_LANG" = en ] && SRC_DESC="$URL + local file $IPLIST_CUSTOM_FILE (merge mode)"
            load_set_from_files "$TMP" "$IPLIST_CUSTOM_FILE"
        else
            load_set_from_files "$TMP"
        fi
        cp "$TMP" "$SNAP_FILE" 2>/dev/null   # снимок = ТОЛЬКО скачанная часть (на boot домержим custom)
    else
        # Сбой источника. Решаем по состоянию боевого set:
        CUR=$(ipset_count "$SET")
        if [ "$CUR" -gt 0 ]; then
            # set наполнен (обычный суточный апдейт при мёртвом источнике) — НЕ трогаем.
            echo "keep existing set ($CUR entries)"
            if [ "$NF_LANG" = en ]; then
                mail_event iplist-fail 0 "BE7000: IP list did NOT update" \
"Could not update the IP subnet list.
Source: $URL
Routing works on the PREVIOUS list ($CUR subnets) — nothing broke,
no new subnets were added. If this repeats for several
days, check that the source is reachable."
            else
                mail_event iplist-fail 0 "BE7000: НЕ обновился список IP" \
"Не удалось обновить список IP-подсетей.
Источник: $URL
Маршрутизация работает на ПРОШЛОМ списке ($CUR подсетей) — ничего не
сломалось, новых подсетей не добавилось. Если повторяется несколько
дней — проверьте доступность источника."
            fi
            exit 1
        elif [ -s "$SNAP_FILE" ] || [ "$HAVE_CUSTOM" = 1 ]; then
            # set пуст (типично после ребута при мёртвом источнике) — поднимаем из
            # снимка (+ локальный файл в merge). Custom — встроенная страховка на boot.
            if [ "$HAVE_CUSTOM" = 1 ]; then
                echo "set empty — loading fallback (snapshot + custom)"
                load_set_from_files "$SNAP_FILE" "$IPLIST_CUSTOM_FILE"
            else
                echo "set empty — loading fallback snapshot $SNAP_FILE"
                load_set_from_files "$SNAP_FILE"
            fi
            USED_FALLBACK=1
        else
            # set пуст и снимка нет — сделать нечего, оставляем пустым (как было до фолбэка).
            echo "set empty and no snapshot — nothing to load"
            if [ "$NF_LANG" = en ]; then
                mail_event iplist-fail 0 "BE7000: IP list is empty" \
"Source unreachable and no local snapshot yet — ipset iplist_set is empty.
Source: $URL
Runet and domains (enodia_list) work, but CDN subnets from CIDR are temporarily
NOT routed into the VPN. It will fill on the next successful update
(nearest reboot or 5:00)."
            else
                mail_event iplist-fail 0 "BE7000: список IP пуст" \
"Источник недоступен, локального снимка ещё нет — ipset iplist_set пуст.
Источник: $URL
Рунет и домены (enodia_list) работают, но CDN-подсети из CIDR временно НЕ
заворачиваются в VPN. Наполнится при следующем удачном обновлении
(ближайший ребут или 5:00)."
            fi
            exit 1
        fi
    fi
fi

COUNT=$(ipset_count "$SET")
echo "ipset $SET: $COUNT entries (fallback=$USED_FALLBACK)"
[ "$DELEGATED" = 1 ] && LINES=$COUNT   # в делегированном режиме «строк с источника» = итог в set

# Провал НАПОЛНЕНИЯ в делегированном режиме виден только по пустому набору: lists-update.sh всегда
# возвращает 0 (у него свои фолбэки — кэш источника в ОЗУ и снимок на флеше), своего кода «не
# смог» у него нет. Без этой ветки утренняя сводка бодро рапортовала «список IP обновлён — 0
# подсетей», хотя это ровно та авария, ради которой в legacy-пути написаны три разных письма:
# сплит по CIDR мёртв целиком (едут только домены через enodia_list), и человек об этом не узнаёт.
# …НО ПУСТОЙ НАБОР БЫВАЕТ И РЕШЕНИЕМ: человек выключил в «Источниках списков» все источники CIDR — и тогда пул пуст
# намеренно (lists-update.sh при nen=0 сам его очищает, снимок не поднимает). Письмо «источники недоступны, наполнится при
# следующем обновлении» с уровнем «сбой» врало тут дважды: источников нет вовсе, и само не наполнится никогда (тестер,
# 06.09.2026 — при полностью рабочем роутере). Число включённых — у владельца реестра (lists-lib.sh reg_nen); старый
# lists-lib без функции даёт пусто — судим по-прежнему, как об аварии.
DELEG_EMPTY=0; DELEG_OFF=0
if [ "$DELEGATED" = 1 ] && [ "$COUNT" = 0 ]; then
    _nen=""
    [ -f "$ENODIA_DIR/lists-lib.sh" ] && _nen=$( . "$ENODIA_DIR/lists-lib.sh" 2>/dev/null; command -v reg_nen >/dev/null 2>&1 && reg_nen tunnel-cidr 2>/dev/null )
    if [ "$_nen" = 0 ]; then
        DELEG_OFF=1
        echo "$SET пуст намеренно: все источники CIDR-списка выключены"
    else
        DELEG_EMPTY=1
        echo "ВНИМАНИЕ: делегированное наполнение дало ПУСТОЙ $SET (источники недоступны, снимка нет)"
    fi
fi

# 4. Правило маркировки (идемпотентно — добавляем если нет).
# ...но НЕ на установке «только панель»: транспорта там нет, наших правил в ядре нет вовсе, и
# маркировка была бы единственным нашим следом в mangle — при том, что метить некуда (`ip rule`
# ставит mark-core, а его не звали). Набор при этом наполняем как обычно: он живёт в RAM, и когда
# человек выберет транспорт в панели, маркировке будет что метить сразу, а не с утреннего cron.
# Ответ спрашиваем у оркестратора; код 2 (старая копия) = ведём себя как раньше.
_tcfg=0; [ -f "$ENODIA_DIR/transport.sh" ] && { sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1; [ "$?" = 1 ] && _tcfg=1; }
# …и ТО ЖЕ САМОЕ, когда человек ВЫКЛЮЧИЛ VPN тумблером (.vpn-off переживает ребут с 02.09.2026):
# `vpn-toggle off` снимает ip rule, heal при флаге не зовёт mark-core — значит метить снова некуда,
# а наше правило было бы единственным следом в mangle. Замерено на живом AX3600: без этой ветки
# после ребута выключенный роутер получал обратно `MARK --set-mark 0x1` для iplist_set. Обратно
# правило кладёт mark-core на `on` — тем же путём, что и после «только панели».
_voff=0; [ -f "$ENODIA_STATE/.vpn-off" ] && _voff=1
if [ "$_tcfg" = 1 ] || [ "$_voff" = 1 ]; then
    if [ "$_voff" = 1 ]; then
        echo "VPN выключен человеком — правило маркировки не ставлю (вернёт vpn-toggle.sh on)"
    else
        echo "транспорт не настроен (установка «только панель») — правило маркировки не ставлю"
    fi
elif ! iptables -t mangle -C PREROUTING -m set --match-set "$SET" dst -j MARK --set-mark 0x1 2>/dev/null; then
    iptables -t mangle -A PREROUTING -m set --match-set "$SET" dst -j MARK --set-mark 0x1
    echo "mangle rule added for $SET"
fi

# 5. Дельта к прошлому разу (для сводки) + сохранение текущего значения.
#    COUNT_FILE в $ENODIA_DIR (не /tmp) — переживает ребут, иначе дельта терялась бы.
#    При fallback из снимка дельту и COUNT_FILE НЕ трогаем — это не «обновление»,
#    иначе дельта следующего удачного запуска сравнивалась бы со снимком.
if [ "$USED_FALLBACK" = 1 ]; then
    delta="из локального снимка"
    [ "$NF_LANG" = en ] && delta="from local snapshot"
else
    PREV=$(cat "$COUNT_FILE" 2>/dev/null)
    case "$PREV" in ''|*[!0-9]*) PREV="" ;; esac
    echo "$COUNT" > "$COUNT_FILE"
    if [ -n "$PREV" ]; then
        d=$((COUNT - PREV))
        if   [ "$d" -gt 0 ]; then delta="было $PREV, +$d"
        elif [ "$d" -lt 0 ]; then delta="было $PREV, $d"
        else                      delta="без изменений"; fi
        if [ "$NF_LANG" = en ]; then
            if   [ "$d" -gt 0 ]; then delta="was $PREV, +$d"
            elif [ "$d" -lt 0 ]; then delta="was $PREV, $d"
            else                      delta="no change"; fi
        fi
    else
        delta="первое измерение"
        [ "$NF_LANG" = en ] && delta="first measurement"
    fi
fi
echo "delta: $delta"

# 6. Утренняя сводка на почту (только при --notify). Собираем краткий
#    статус VPN — curl/awg дёргаем лишь здесь, чтобы вызов из heal.sh был лёгким.
if [ "$NOTIFY" = 1 ]; then
    # Статус VPN — TRANSPORT-AWARE (как в heal.sh). Раньше дайджест ХАРДКОДИЛ awg0+.active:
    # при активном альте (xray/hy2) письмо показывало ТЁПЛЫЙ awg-резерв (awg0 up, handshake …) и
    # awg-конфиг из .active вместо реальной несущей → «неактуальный VPN/конфиг». Читаем .transport:
    # awg → handshake awg0; альт/zapret → health активного транспорта + его .<t>-active.
    # Пустой флаг — ДВА разных состояния, и подставлять awg вслепую нельзя: на установке «только
    # панель» письмо утверждало бы «Транспорт: AmneziaWG · awg0 не поднят» на роутере, где VPN
    # никогда не настраивали. Это ровно та дезинформация, ради которой погашен бутовый вердикт
    # heal. Ответ уже посчитан выше (`_tcfg`, п. 4) — второй раз оркестратор не дёргаем.
    dg_t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    if [ -z "$dg_t" ]; then
        dg_t=awg                                   # исторический фолбэк: роутер старше флага
        [ "$_tcfg" = 1 ] && dg_t=none
    fi
    dg_label=$(case "$dg_t" in xray) echo "Xray" ;; hy2) echo "Hysteria2" ;; byedpi) echo "ByeDPI" ;; zapret) echo "Zapret" ;; awg) echo "AmneziaWG" ;; none) echo "не выбран" ;; *) echo "$dg_t" ;; esac)
    # xray несёт любой из vless/vmess/trojan/ss — помечаем в письме (vless=норма → без пометки),
    # чтобы «Транспорт: Xray · VMESS» не путал с предположением про vless. Живой конфиг = xray.json.
    if [ "$dg_t" = xray ]; then
        _xp=$(grep -oE '"protocol"[[:space:]]*:[[:space:]]*"(vless|vmess|trojan|shadowsocks)"' "$ENODIA_STATE/xray.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        case "$_xp" in vmess) dg_label="Xray · VMESS" ;; trojan) dg_label="Xray · Trojan" ;; shadowsocks) dg_label="Xray · Shadowsocks" ;; esac
    fi
    if [ "$dg_t" = none ]; then
        # Транспорта нет вовсе: ни несущей, ни серверного конфига — щупать нечего, и «проба не
        # прошла» здесь значило бы «сломано», а не «не настроено».
        vpn_state="транспорт не выбран — трафик идёт напрямую"
        [ "$NF_LANG" = en ] && vpn_state="no transport selected — traffic goes direct"
        active=""
    elif [ "$dg_t" = awg ]; then
        WG=""
        command -v wg >/dev/null 2>&1 && WG=wg
        [ -z "$WG" ] && [ -x "$ENODIA_BIN/awg" ] && WG="$ENODIA_BIN/awg"
        vpn_state="awg0 не поднят"
        [ "$NF_LANG" = en ] && vpn_state="awg0 not up"
        if ip link show awg0 >/dev/null 2>&1; then
            vpn_state="awg0 up"
            if [ -n "$WG" ]; then
                hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
                case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
                if [ "$hs" -gt 0 ]; then
                    vpn_state="awg0 up, handshake $(age_since "$hs") сек назад"
                    [ "$NF_LANG" = en ] && vpn_state="awg0 up, handshake $(age_since "$hs") s ago"
                else
                    vpn_state="awg0 up, handshake ещё нет"
                    [ "$NF_LANG" = en ] && vpn_state="awg0 up, no handshake yet"
                fi
            fi
        fi
        active=$(cat "$ENODIA_STATE/.active" 2>/dev/null)
    else
        # альт/zapret: живость от health активного транспорта (awg0 может быть лишь тёплым резервом)
        if [ -f "$ENODIA_DIR/transport.sh" ] && sh "$ENODIA_DIR/transport.sh" health "$dg_t" >/dev/null 2>&1; then
            vpn_state="$dg_label — связь OK"
            [ "$NF_LANG" = en ] && vpn_state="$dg_label — link OK"
        else
            vpn_state="$dg_label — проба не прошла"
            [ "$NF_LANG" = en ] && vpn_state="$dg_label — probe failed"
        fi
        active=$(cat "$ENODIA_STATE/.$dg_t-active" 2>/dev/null)   # byedpi/zapret не имеют серверного конфига → пусто
    fi
    # Человеческое имя для сервера ПОДПИСКИ (sub-<tag>-…): вместо служебного имени файла показываем
    # remark из .sub-names (напр. «🇵🇱⚡Польша») + ярлык подписки из .subs («тег⇥url⇥label»). Иначе в
    # письме мелькали непонятные «sub-svpq96g-30». Не-подписочные (awg-страны, «свои» xray) — как есть.
    active_disp="$active"
    case "$active" in
        sub-*)
            TAB=$(printf '\t'); disp=""; lbl=""
            if [ -f "$ENODIA_STATE/.sub-names" ]; then
                while IFS="$TAB" read -r _f _r; do [ "$_f" = "$active" ] && { disp="$_r"; break; }; done < "$ENODIA_STATE/.sub-names"
            fi
            _tag=$(sub_owner_tag "$active")
            [ -n "$_tag" ] && lbl=$(sub_label_of "$_tag")
            [ -n "$disp" ] || disp="$active"
            if [ -n "$lbl" ]; then active_disp="$disp (подписка «$lbl»)"; else active_disp="$disp"; fi
            [ "$NF_LANG" = en ] && [ -n "$lbl" ] && active_disp="$disp (subscription «$lbl»)"
            ;;
    esac
    ip=$(probe_ext_ip "" 5)
    if [ "$NF_LANG" = en ]; then
        BODY=$(printf '%s\n' \
"Morning update of the IP subnet list." \
"" \
"Subnets in iplist_set: $COUNT ($delta)." \
"Source: $SRC_DESC." \
"Lines from source: $LINES." \
"" \
"Transport: $dg_label." \
"VPN: $vpn_state." \
"Active config: ${active_disp:-—}." \
"External IP now: ${ip:-unknown}.")
        subj="BE7000: IP list updated — $COUNT subnets"
        [ "$USED_FALLBACK" = 1 ] && subj="BE7000: IP list restored from snapshot — $COUNT subnets"
    else
        BODY=$(printf '%s\n' \
"Утреннее обновление списка IP-подсетей." \
"" \
"Подсетей в iplist_set: $COUNT ($delta)." \
"Источник: $SRC_DESC." \
"Строк с источника: $LINES." \
"" \
"Транспорт: $dg_label." \
"VPN: $vpn_state." \
"Активный конфиг: ${active_disp:-—}." \
"Внешний IP сейчас: ${ip:-неизвестен}.")
        subj="BE7000: список IP обновлён — $COUNT подсетей"
        [ "$USED_FALLBACK" = 1 ] && subj="BE7000: список IP поднят из снимка — $COUNT подсетей"
    fi
    # Пустой набор в делегированном режиме — это ОТКАЗ, а не «сводка с нулём»: и тема, и ключ
    # события (iplist-fail → уровень err в центре уведомлений) должны говорить то же, что сказал
    # бы legacy-путь. Статус транспорта/IP оставляем — по нему видно, почему не скачалось.
    ev_key=iplist-digest
    if [ "$DELEG_EMPTY" = 1 ]; then
        ev_key=iplist-fail
        if [ "$NF_LANG" = en ]; then
            subj="BE7000: IP list is empty"
            BODY=$(printf '%s\n' \
"Sources are unreachable and there is no local snapshot — ipset iplist_set is EMPTY." \
"Source: $SRC_DESC." \
"" \
"Runet and domains (enodia_list) still work, but CDN subnets from the CIDR list are" \
"temporarily NOT routed into the VPN. It will fill on the next successful update" \
"(nearest reboot or 5:00)." \
"" \
"Transport: $dg_label." \
"VPN: $vpn_state." \
"External IP now: ${ip:-unknown}.")
        else
            subj="BE7000: список IP пуст"
            BODY=$(printf '%s\n' \
"Источники недоступны, локального снимка нет — ipset iplist_set ПУСТ." \
"Источник: $SRC_DESC." \
"" \
"Рунет и домены (enodia_list) работают, но CDN-подсети из CIDR-списка временно НЕ" \
"заворачиваются в VPN. Наполнится при следующем удачном обновлении" \
"(ближайший ребут или 5:00)." \
"" \
"Транспорт: $dg_label." \
"VPN: $vpn_state." \
"Внешний IP сейчас: ${ip:-неизвестен}.")
        fi
    fi
    # Источники выключены человеком — не авария и не «обновлено — 0 подсетей»: сводка говорит, что CIDR-пул не используется
    # и почему, и как вернуть. Ключ — обычной сводки (уровень «инфо»): письмо про решение человека не «сбой».
    if [ "$DELEG_OFF" = 1 ]; then
        if [ "$NF_LANG" = en ]; then
            subj="BE7000: IP list is not used — all sources are off"
            BODY=$(printf '%s\n' \
"All sources of the shared IP list (CIDR) are turned off, so iplist_set is empty on purpose." \
"Nothing is broken: domain rules (enodia_list), groups and geo categories work as usual;" \
"only subnets from the CIDR list are not routed into the VPN." \
"To use the list again, turn a source on in «Routing» → «List sources»." \
"" \
"Transport: $dg_label." \
"VPN: $vpn_state." \
"External IP now: ${ip:-unknown}.")
        else
            subj="BE7000: список IP не используется — все источники выключены"
            BODY=$(printf '%s\n' \
"Все источники общего списка IP (CIDR) выключены — поэтому iplist_set пуст намеренно." \
"Ничего не сломано: доменные правила (enodia_list), группы и гео-категории работают как" \
"обычно; не заворачиваются в VPN только подсети из CIDR-списка." \
"Чтобы вернуть список, включите источник в «Маршрутизация» → «Источники списков»." \
"" \
"Транспорт: $dg_label." \
"VPN: $vpn_state." \
"Внешний IP сейчас: ${ip:-неизвестен}.")
        fi
    fi
    mail_event "$ev_key" 0 "$subj" "$BODY"
fi

# 7. Обновить и ДРУГИЕ включённые категории источников на том же расписании (adblock/ipblock).
#    Ставит флаг --lists cron-строка update-sched.sh; heal/ручной запуск без флага сюда не заходят.
#    Выключенная категория = no-op (lists-update do_update тут же делает teardown). Best-effort:
#    сбой одной категории не влияет на iplist (маршрутизация уже применена выше).
if [ "$REFRESH_LISTS" = 1 ] && [ -f "$ENODIA_DIR/lists-update.sh" ] && [ -f "$ENODIA_DIR/lists-lib.sh" ]; then
    # Список категорий — ЕДИНЫЙ (ls_opt_cats в lists-lib.sh), см. тот же приём в heal.sh 5.8.
    _optc=$( . "$ENODIA_DIR/lists-lib.sh" 2>/dev/null; ls_opt_cats 2>/dev/null )
    [ -n "$_optc" ] || _optc="adblock ipblock zapret-cidr zapret-dom"   # шим-фолбэк: старый lists-lib.sh
    for _lc in $_optc; do
        echo "refresh other list: $_lc"
        sh "$ENODIA_DIR/lists-update.sh" update "$_lc" >/dev/null 2>&1 || true
    done
fi

# 7b. Гео-категории (geo.sh) — на том же расписании «как opencck». Перекачиваем источники и
#     пересобираем сеты ТОЛЬКО если гео настроено (реестр непуст); иначе network-фетч впустую.
#     Best-effort: сбой гео не влияет на iplist (маршрутизация уже применена выше).
if [ "$REFRESH_LISTS" = 1 ] && [ -f "$ENODIA_DIR/geo.sh" ] && [ -s "$ENODIA_STATE/geo/actions.tsv" ]; then
    echo "refresh geo categories"
    sh "$ENODIA_DIR/geo.sh" update >/dev/null 2>&1 || true
# …without Гео actions the categories other subsystems want (access schedules: «Ограничено», Telegram's network) are refreshed
# alone — `update` carried them, and on a router without actions nothing did (review s.112, round 2)
elif [ "$REFRESH_LISTS" = 1 ] && [ -f "$ENODIA_DIR/geo.sh" ] && [ -n "$(cat "$ENODIA_STATE"/geo/want/* 2>/dev/null | grep .)" ]; then
    echo "refresh categories wanted by other subsystems"
    sh "$ENODIA_DIR/geo.sh" wanted refresh >/dev/null 2>&1 || true
fi

echo "done"
