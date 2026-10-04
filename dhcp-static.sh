#!/bin/sh
# dhcp-static.sh — ЗАКРЕПЛЕНИЕ АДРЕСА ЗА УСТРОЙСТВОМ (DHCP-резервация).
#
# ЗАЧЕМ. Вся политика проекта висит на IPv4 клиента (см. шапку lease-lib.sh): вырезы, «целиком в
# VPN», доп-выход, порты, правила устройства — ключ везде адрес. А адрес dnsmasq выдаёт на 12 часов
# и при переподключении может выдать другой. Тогда правило остаётся на старом адресе: у устройства
# политики больше нет, а сосед, получивший освободившийся адрес, получил и чужие правила. Молча —
# ни одна проверка проекта такое не ловит, iptables продолжает исправно тикать.
#
# ЧТО ДЕЛАЕМ. Пишем dnsmasq строку `dhcp-host=<mac>,<ip>` — «этому MAC всегда вот этот адрес».
# Закрепляем ТЕКУЩИЙ адрес устройства: тогда закрепление ничего не двигает прямо сейчас и не может
# оборвать живые соединения, а правила перестают уезжать в будущем.
#
# ГРАНИЦА ЧЕСТНОСТИ: privacy-MAC. Телефон с рандомизированным MAC (`mac_is_random`) при следующей
# смене адреса придёт под ДРУГИМ MAC — и резервация к нему не относится. Мы такое закрепление
# разрешаем (MAC живёт до смены, обычно недели), но ОБЯЗАНЫ сказать словами: лечится это не у нас,
# а в настройках Wi-Fi самого телефона («Частный адрес Wi-Fi» → выключить для этой сети).
#
# ГДЕ ЖИВЁТ — ДВА места, и ровно два:
#   .dhcp-static (на /data)              — ПЕРСИСТ, единственная истина, переживает ребут
#   /tmp/dnsmasq.d/05-dhcp-static.conf   — ЖИВОЙ каталог, тот самый `conf-dir` демона
# /tmp гибнет на ребуте, поэтому на буте нас переигрывает heal.sh (шаг 2c).
#
# !!! В /etc/dnsmasq.d ЭТОТ ФАЙЛ КЛАСТЬ НЕЛЬЗЯ — поймано на живом роутере 10.08.2026, ценой
# упавшего DNS всей сети. Остальные подсистемы проекта пишут сниппеты в ОБЕ копии, и это
# правильно для них, но не для нас. Разбор:
#   * демон запущен как `-C /var/etc/dnsmasq.conf.cfgXXXX`, а тот несёт СРАЗУ ОБЕ строки:
#     `conf-file=/etc/dnsmasq.conf` (внутри — `conf-dir=/etc/dnsmasq.d,*.conf`) и
#     `conf-dir=/tmp/dnsmasq.d`. То есть читаются ОБА каталога, всегда;
#   * для `ipset=`/`address=` дубль безвреден — dnsmasq их складывает;
#   * для `dhcp-host` дубль ФАТАЛЕН: «duplicate dhcp-host IP address» и демон НЕ СТАРТУЕТ.
#     Сеть остаётся вообще без DNS — и лечится это только руками по SSH.
# Файла в /etc нет ⇒ стоковый `cp -a /etc/dnsmasq.d/* /tmp/dnsmasq.d` (init.d/dnsmasq:1214) его
# не размножит, и дублю взяться неоткуда.
#
# ПОЧЕМУ НЕ /etc/ethers. Он у dnsmasq включён (`read-ethers`), формат проще, но файл ЧУЖОЙ (сток
# кладёт туда свои примеры и может писать своё), перечитывается только по HUP и живёт в ramfs всё
# равно. Свой conf-файл ни с кем не делится и снимается целиком.
#
# DNS — ЕДИНАЯ ТОЧКА ОТКАЗА ВСЕЙ СЕТИ, поэтому выкладка параноидальна:
#   * строгая валидация MAC/IP (в конфиг уходит только то, что прошло регулярку);
#   * `dnsmasq --test` ДО рестарта — но НА РЕАЛЬНОМ конфиге демона, а не на нашем файле в
#     одиночку: ровно тот дубль, что уронил сеть, в изолированной проверке НЕ ВИДЕН;
#   * судим по ВЫВОДУ, а не по коду возврата: на «duplicate dhcp-host» --test печатает ошибку
#     и всё равно возвращает 0 (замерено там же);
#   * рестарт — только если содержимое реально изменилось (рестарт = секундный провал DNS у всех);
#   * после рестарта демон обязан быть жив, иначе ОТКАТ и рестарт назад.
#
# busybox-замечания: нет `local` ⇒ префикс `_d`; `grep -c` на нуле возвращает код 1; черновик
# держим В /tmp, а не в /tmp/dnsmasq.d — `conf-dir` там идёт БЕЗ маски `*.conf`, и демон прочитал
# бы любой хвост; /tmp и /tmp/dnsmasq.d — одна ФС, так что `mv` всё равно атомарен.

ENODIA_DIR="${ENODIA_DIR:-$(cd "$(dirname "$0")" && pwd)}"
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
STORE="$ENODIA_STATE/.dhcp-static"
CONF_NAME=05-dhcp-static.conf
CONF_LIVE="${CONF_LIVE:-/tmp/dnsmasq.d/$CONF_NAME}"
CONF_ETC="/etc/dnsmasq.d/$CONF_NAME"      # НЕ пишем — только сносим: см. разбор в шапке
TAB=$(printf '\t')

if [ -f "$ENODIA_DIR/lease-lib.sh" ]; then . "$ENODIA_DIR/lease-lib.sh"; fi
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi

# Разбор MAC — у lease-lib.sh (одна копия на проект); шим той же строки — на payload без библиотеки.
command -v mac_ok >/dev/null 2>&1 || mac_ok() { printf '%s' "$1" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; }
ip_ok()  { printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

# Резервировать имеет смысл только адрес НАШЕЙ сети. Гард не про синтаксис, а про смысл: публичный
# адрес в `dhcp-host=` означал бы, что мы обещаем выдать клиенту чужой адрес.
lan_ip_ok() {
    ip_ok "$1" || return 1
    if command -v is_private_ip >/dev/null 2>&1; then is_private_ip "$1" || return 1; fi
    case "$1" in *.0|*.255) return 1 ;; esac
    return 0
}

if command -v mac_norm >/dev/null 2>&1; then norm_mac() { mac_norm "$1"; }
else norm_mac() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n'; }; fi

# Строка персиста, у которой поле $1 равно $2 (awk умеет динамический номер поля).
store_row_by() { [ -f "$STORE" ] || return 1; awk -F'\t' -v c="$1" -v w="$2" '$c==w{print; exit}' "$STORE" 2>/dev/null; }

# --- сборка конфига из персиста ---------------------------------------------------------
# В dnsmasq уходит ТОЛЬКО `mac,ip`: имя устройства из аренды может быть каким угодно (пробелы,
# кириллица, эмодзи), а `dhcp-host` требует валидное DNS-имя — на мусоре демон НЕ СТАРТУЕТ, то есть
# сеть остаётся без DNS. Имя держим в персисте, оно нужно только панели для показа.
build_conf() {   # $1 = куда писать
    # Группировка `{ … } > файл` — НЕ подшелл: `exit` внутри убил бы весь скрипт (а нам тут всего
    # лишь «персиста нет ⇒ конфиг пустой»), поэтому цикл гейтим условием, а не выходом.
    {
        echo "# создан dhcp-static.sh — не править руками, истина в $STORE"
        if [ -f "$STORE" ]; then
            # `|| [ -n "$_dm" ]` — busybox `read` теряет последнюю строку файла без хвостового
            # перевода строки; файл могли поправить руками или обрезать по месту на флеше.
            # Имена переменных СВОИ (`_b*`), а не общие `_d*`: в busybox нет `local`, и цикл
            # затирал бы `_di`/`_dm` у ВЫЗВАВШЕГО. Именно так и вышло на первом же прогоне —
            # cmd_add после apply напечатал «закреплён  за» с пустыми адресом и MAC (тот же класс,
            # что грабля с `_id` в vpn-server.sh).
            while IFS="$TAB" read -r _bm _bi _bh || [ -n "$_bm" ]; do
                mac_ok "$_bm" || continue
                lan_ip_ok "$_bi" || continue
                printf 'dhcp-host=%s,%s\n' "$_bm" "$_bi"
            done < "$STORE"
        fi
    } > "$1" 2>/dev/null
}

# Конфиг, с которым РЕАЛЬНО запущен демон (`-C` в его cmdline). Именно он тянет оба conf-dir, и
# только на нём видны межфайловые конфликты. Демон не бежит — берём стоковый путь.
real_cfg() {
    for _dp in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2>/dev/null < "$_dp/cmdline")" in
            *dnsmasq*-C\ *)
                _dc2=$(tr '\0' '\n' 2>/dev/null < "$_dp/cmdline" | awk '$0=="-C"{f=1;next} f{print;exit}')
                [ -f "$_dc2" ] && { printf '%s' "$_dc2"; return 0; } ;;
        esac
    done
    printf '/etc/dnsmasq.conf'
}

# Проверка ИТОГОВОГО конфига: файл уже лежит на месте, спрашиваем демона «ты бы с этим поднялся?».
# Судим ПО ВЫВОДУ: на «duplicate dhcp-host» dnsmasq 2.86 печатает ошибку и возвращает 0 — код
# возврата тут не свидетель (замерено на железе). Проверить нечем ⇒ не блокируем.
conf_test() {
    [ -x /usr/sbin/dnsmasq ] || return 0
    _dt=$(/usr/sbin/dnsmasq --test -C "$(real_cfg)" 2>&1)
    case "$_dt" in
        *"syntax check OK"*) return 0 ;;
        "") return 0 ;;
    esac
    printf '%s' "$_dt" | tail -2 >&2
    return 1
}

# «Демон жив» НЕ значит «DNS работает» — общий закон проекта, и здесь он поймал нас за руку
# (10.08.2026): procd перезапускает падающий dnsmasq по кругу, `pidof` застаёт очередную попытку
# и рапортует успех, а сеть в это время без резолва. Поэтому судим по РЕЗУЛЬТАТУ: имя, которое
# dnsmasq отдаёт из своих же данных (`localhost` из /etc/hosts) и которому не нужен аплинк.
# `nslookup` в busybox всегда идёт в системный резолвер, то есть ровно в наш dnsmasq, — что тут
# как раз и требуется.
dns_ok() {
    _dwk=0
    while [ "$_dwk" -lt 8 ]; do
        if pidof dnsmasq >/dev/null 2>&1 && nslookup localhost 2>/dev/null | grep -q '^Address'; then
            return 0
        fi
        _dwk=$((_dwk + 1)); sleep 1
    done
    return 1
}

dns_reload() {
    # Рестарт, а не HUP: `dhcp-host` из conf-dir демон по сигналу не перечитывает (та же грабля,
    # что с ipset=/address=). Ходим через dns-merge.sh — это ЕДИНАЯ точка рестарта проекта, и
    # заводить здесь шестую копию `/etc/init.d/dnsmasq restart` незачем.
    if [ -f "$ENODIA_DIR/dns-merge.sh" ]; then
        sh "$ENODIA_DIR/dns-merge.sh" reload >/dev/null 2>&1 && return 0
    fi
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

same_file() { [ -f "$1" ] && [ -f "$2" ] && [ "$(md5sum < "$1" 2>/dev/null)" = "$(md5sum < "$2" 2>/dev/null)" ]; }

# Выложить ЖИВУЮ копию (и только её). Ступень в /tmp — та же ФС, что /tmp/dnsmasq.d, значит `mv`
# атомарен и демон, перечитанный чужим вызовом ровно в этот момент, половины файла не увидит.
place_conf() {   # $1 = готовый кандидат
    mkdir -p /tmp/dnsmasq.d 2>/dev/null
    cp "$1" "/tmp/.enodia-$CONF_NAME.stage" 2>/dev/null && mv "/tmp/.enodia-$CONF_NAME.stage" "$CONF_LIVE" 2>/dev/null || return 1
    # Копию в /etc сносим ВСЕГДА: она могла остаться от версии, которая писала обе (до 10.08.2026),
    # и тогда init размножил бы её в /tmp — тот самый дубль, от которого демон не стартует.
    rm -f "$CONF_ETC" 2>/dev/null
    return 0
}

drop_conf() { rm -f "$CONF_ETC" "$CONF_LIVE" "/tmp/.enodia-$CONF_NAME.stage" 2>/dev/null; }

# $1 = "norestart": выложить файлы, но не трогать демона. Нужен ровно одному вызывающему —
# heal.sh на буте: там dnsmasq всё равно рестартуют ниже одной общей строкой, а лишний рестарт
# посреди подъёма это ещё одна секунда без DNS для всей сети.
cmd_apply() {
    _dc=/tmp/.enodia-dhcp-static.cand.$$
    build_conf "$_dc"
    # Резерваций не осталось — файла быть не должно. Пустой сниппет (один заголовок) работает так
    # же, но врёт диагностике: «файл есть» читается как «что-то закреплено».
    if ! grep -q '^dhcp-host=' "$_dc" 2>/dev/null; then
        rm -f "$_dc" 2>/dev/null
        [ -f "$CONF_LIVE" ] || [ -f "$CONF_ETC" ] || return 0
        drop_conf
        [ "$1" = norestart ] || dns_reload
        return 0
    fi
    # Ничего не изменилось — выходим ДО всякой возни: рестарт был бы провалом DNS впустую.
    # Сверяем ЖИВУЮ копию и заодно требуем, чтобы копии в /etc не было (её мог оставить старый
    # apply, а она размножится в /tmp на ближайшем рестарте и уронит демона дублем).
    if same_file "$_dc" "$CONF_LIVE" && [ ! -f "$CONF_ETC" ]; then
        rm -f "$_dc" 2>/dev/null
        return 0
    fi
    # Копия на случай отката: вернуть сеть в прежнее состояние важнее, чем применить резервацию.
    _dbl=/tmp/.enodia-dhcp-static.bak-live.$$
    [ -f "$CONF_LIVE" ] && cp "$CONF_LIVE" "$_dbl" 2>/dev/null
    if ! place_conf "$_dc"; then
        rm -f "$_dc" "$_dbl" 2>/dev/null
        echo "[dhcp-static] не удалось выложить $CONF_NAME" >&2
        return 1
    fi
    # ПРОВЕРКА ПОСЛЕ ВЫКЛАДКИ, А НЕ ДО: dnsmasq спрашиваем о ЦЕЛОМ конфиге, и наш файл обязан уже
    # быть на месте. Изолированная проверка кандидата пропускала межфайловый конфликт — им и был
    # дубль dhcp-host, из-за которого демон не поднялся (10.08.2026, разбор в шапке).
    if ! conf_test; then
        drop_conf
        [ -f "$_dbl" ] && place_conf "$_dbl" >/dev/null 2>&1
        rm -f "$_dc" "$_dbl" 2>/dev/null
        echo "[dhcp-static] dnsmasq отверг такой конфиг — резервация НЕ применена, DNS не тронут" >&2
        return 1
    fi
    if [ "$1" = norestart ]; then
        rm -f "$_dc" "$_dbl" 2>/dev/null
        return 0
    fi
    dns_reload
    if ! dns_ok; then
        drop_conf
        [ -f "$_dbl" ] && place_conf "$_dbl" >/dev/null 2>&1
        dns_reload
        rm -f "$_dc" "$_dbl" 2>/dev/null
        echo "[dhcp-static] dnsmasq не поднялся с резервациями — откатил, DNS восстановлен" >&2
        return 1
    fi
    rm -f "$_dc" "$_dbl" 2>/dev/null
    return 0
}

cmd_add() {   # $1 = IP, $2 = MAC (необязателен: возьмём нынешнего владельца адреса)
    _di="$1"; _dm=$(norm_mac "$2")
    lan_ip_ok "$_di" || { echo "[dhcp-static] не адрес локальной сети: $1" >&2; return 1; }
    if [ -z "$_dm" ] && command -v ip_owner_now >/dev/null 2>&1; then _dm=$(ip_owner_now "$_di"); fi
    mac_ok "$_dm" || { echo "[dhcp-static] не знаю MAC устройства на $_di (нет аренды и молчит в сети) — закреплять нечего" >&2; return 1; }
    # СТОК УЖЕ ЗАКРЕПИЛ ЭТОТ АДРЕС ИЛИ ЭТОТ MAC. Отказываем ЗДЕСЬ, а не у dnsmasq: дубль
    # `dhcp-host` он считает фатальным и не стартует вовсе (сеть без DNS). Наша выкладка это
    # ловит и откатывает, но ответ известен заранее, и «уже закреплено» человеку понятнее, чем
    # «dnsmasq отверг конфиг». Панель кнопку в таком случае не рисует, но путей к нам больше
    # одного (CLI, чужой скрипт), поэтому гард стоит у ВЛАДЕЛЬЦА.
    _dst=$(cmd_stock 2>/dev/null)
    if [ -n "$_dst" ]; then
    	_dsi=$(printf '%s
' "$_dst" | awk -F'	' -v i="$_di" '$2==i{print $1; exit}')
    	if [ -n "$_dsi" ]; then
    		echo "[dhcp-static] $_di уже закреплён в настройках роутера (за $_dsi) — снимите там" >&2
    		return 1
    	fi
    	_dsm=$(printf '%s
' "$_dst" | awk -F'	' -v m="$_dm" 'toupper($1)==toupper(m){print $2; exit}')
    	if [ -n "$_dsm" ]; then
    		echo "[dhcp-static] у этого устройства уже есть закреплённый адрес в настройках роутера: $_dsm" >&2
    		return 1
    	fi
    fi
    # Адрес уже обещан ДРУГОМУ MAC — молча переписать значит увести адрес у того устройства.
    _dex=$(store_row_by 2 "$_di")
    if [ -n "$_dex" ]; then
        _dexm=$(printf '%s' "$_dex" | cut -f1)
        [ "$_dexm" = "$_dm" ] && { echo "уже закреплён: $_di за $_dm"; return 0; }
        echo "[dhcp-static] $_di уже закреплён за $_dexm — сначала снимите закрепление" >&2
        return 1
    fi
    _dh=""
    command -v lease_host_of >/dev/null 2>&1 && _dh=$(lease_host_of "$_di")
    _dtmp="$STORE.tmp.$$"
    # Тот же MAC на другом адресе — это ПЕРЕЕЗД: старую строку снимаем, иначе dnsmasq получит два
    # `dhcp-host` на один MAC и выдаст устройству не тот адрес, который человек только что выбрал.
    { [ -f "$STORE" ] && awk -F'\t' -v m="$_dm" '$1!=m' "$STORE" 2>/dev/null
      printf '%s\t%s\t%s\n' "$_dm" "$_di" "$_dh"
    } > "$_dtmp" 2>/dev/null && mv "$_dtmp" "$STORE" 2>/dev/null || { rm -f "$_dtmp" 2>/dev/null; echo "[dhcp-static] не записать $STORE" >&2; return 1; }
    if cmd_apply; then
        if command -v mac_is_random >/dev/null 2>&1 && mac_is_random "$_dm"; then
            echo "закреплён $_di за $_dm; ВНИМАНИЕ: это случайный (приватный) MAC — устройство меняет его само, и тогда закрепление перестанет действовать"
        else
            echo "закреплён $_di за $_dm"
        fi
        return 0
    fi
    # Применить не вышло — персист не должен обещать того, чего нет в dnsmasq.
    cmd_del "$_di" >/dev/null 2>&1
    return 1
}

cmd_del() {   # $1 = IP либо MAC
    _dk="$1"; _dkm=$(norm_mac "$1")
    [ -f "$STORE" ] || { echo "нечего снимать"; return 0; }
    _dtmp="$STORE.tmp.$$"
    awk -F'\t' -v k="$_dk" -v m="$_dkm" '$1!=m && $2!=k' "$STORE" 2>/dev/null > "$_dtmp" || { rm -f "$_dtmp" 2>/dev/null; return 1; }
    mv "$_dtmp" "$STORE" 2>/dev/null || { rm -f "$_dtmp" 2>/dev/null; return 1; }
    cmd_apply || return 1
    echo "закрепление снято: $1"
    return 0
}

# СТОКОВЫЕ РЕЗЕРВАЦИИ — ЧУЖОЕ ХРАНИЛИЩЕ, КОТОРОЕ МЫ ОБЯЗАНЫ ЗНАТЬ. Родная морда Xiaomi держит
# свои закрепления в `/etc/config/dhcp` секциями `config host`; у тестера их 100+. Читаем, но
# НИКОГДА не пишем — это не наш файл.
# Знать о них надо по двум причинам, и обе стоили бы дорого:
#   1. dnsmasq читает ОБА conf-dir, и ДУБЛЬ `dhcp-host` для него ФАТАЛЕН («duplicate dhcp-host»,
#      демон не стартует — сеть без DNS). Наша выкладка это ловит и откатывает, но человек видит
#      техническую ошибку там, где ответ известен заранее: адрес уже закреплён, закреплять нечего.
#   2. Панель иначе пишет «адрес может уехать после переподключения» про адрес, закреплённый
#      НАВСЕГДА — то есть пугает без причины и предлагает кнопку, которая обязана упереться.
# Печатаем TSV `mac⇥ip`, тем же порядком полей, что и наш персист.
STOCK_CFG="${STOCK_CFG:-/etc/config/dhcp}"
cmd_stock() {
	[ -f "$STOCK_CFG" ] || return 0
	# Секция кончается СЛЕДУЮЩЕЙ `config` или концом файла — печатаем накопленное в обоих местах.
	# `list mac` тоже берём: в UCI один хост бывает с несколькими MAC.
	awk '
		/^[ 	]*config[ 	]+host([ 	]|$)/ { if (inh && m != "" && i != "") print m "	" i; inh=1; m=""; i=""; next }
		/^[ 	]*config[ 	]/ { if (inh && m != "" && i != "") print m "	" i; inh=0; next }
		inh && /^[ 	]*(option|list)[ 	]+mac[ 	]/ { m=$3 }
		inh && /^[ 	]*option[ 	]+ip[ 	]/ { i=$3 }
		END { if (inh && m != "" && i != "") print m "	" i }
	' "$STOCK_CFG" 2>/dev/null | tr -d "'\""
}

cmd_json() {
    printf '{"pins":['
    _df=1
    if [ -f "$STORE" ]; then
        # Свои имена (`_j*`) — по той же причине, что в build_conf: у функции-callee они обязаны
        # быть собственными, иначе она затирает переменные вызывающего.
        while IFS="$TAB" read -r _jm _ji _jh || [ -n "$_jm" ]; do
            mac_ok "$_jm" || continue
            [ "$_df" -eq 1 ] || printf ','
            _df=0
            printf '{"mac":"%s","ip":"%s","host":"%s"}' "$_jm" "$_ji" "$(printf '%s' "$_jh" | tr -d '"\\')"
        done < "$STORE"
    fi
    printf ']}\n'
}

case "$1" in
    add)    cmd_add "$2" "$3" ;;
    del|rm) cmd_del "$2" ;;
    apply)  cmd_apply "$2" ;;
    list)   [ -f "$STORE" ] && cat "$STORE" || true ;;
    stock)  cmd_stock ;;   # чужие (стоковые) резервации из /etc/config/dhcp, только чтение
    json)   cmd_json ;;
    clear)  rm -f "$STORE" 2>/dev/null; drop_conf; dns_reload; echo "все закрепления сняты" ;;
    *)      echo "usage: $0 {add <ip> [mac]|del <ip|mac>|apply [norestart]|list|stock|json|clear}" >&2; exit 1 ;;
esac
