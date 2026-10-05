#!/bin/sh
#
# dump.sh — единый диагностический СРЕЗ (логи + состояние) одним текстовым
# потоком на stdout. Назначение: при «не работает / непонятно почему» снять
# «всё и сразу» и разобрать самому либо приложить к обращению в чат сообщества.
#
# ПК-сторона (`enodia-diag.py`, он же пункт «Диагностика» в enodia.py) несёт ЭТОТ файл в base64,
# гонит его на роутер через 'base64 -d | sh' и складывает вывод в локальный enodia-diag-<дата>.txt
# — поэтому скрипт самодостаточен и не зависит от того, установлен ли он уже. Правил его —
# пересобери коллектор (`dev/build-router-diag.py`), иначе тестер снимет дамп ПРОШЛОЙ версии.
#
# БЕЗОПАСНОСТЬ (дамп задуман как ШАРИНГ-артефакт — он НЕ должен слить секреты):
#   1. НЕ читаем секретные файлы (awg.conf / configs/*.conf / awg0.conf /
#      amnezia_for_awg.conf / notify.conf) — только факт наличия + права (ls -l).
#      Раз приватный ключ не читаем — он физически не может попасть в дамп.
#      `awg show` приватный ключ не печатает (дизайн wireguard), но печатает
#      peer-pubkey/endpoint — их добивает redact() ниже.
#   2. Финальный фильтр redact() поверх ВСЕГО вывода:
#        * base64-ключи (43 символа + '=')  -> [KEY-REDACTED];
#        * endpoint-строки                  -> [REDACTED] (вдруг endpoint — хост);
#        * публичные IPv4 -> первые 2 октета + .x.x. Приватные/служебные
#          (10/172.16-31/192.168/127/169.254/0) ОСТАВЛЯЕМ — без них не разобрать
#          LAN и маршруты. Так не утекут endpoint/внешний IP VPS и домашний IP.
#   ВСЁ РАВНО просмотрите файл перед публикацией — маскировка эвристическая.
#
# Вывод — ЧИСТЫЙ текст без ANSI-цветов (артефакт идёт в файл/мессенджер).
# Все команды защищены (2>/dev/null / || echo) — на голом/недонастроенном
# роутере скрипт не падает, а честно показывает «нет / не поднят».

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# ...А ЕСЛИ ПО ЛИТЕРАЛАМ НИЧЕГО НЕТ — СПРОСИМ ВЛАДЕЛЬЦА. Нас зовут ТРИ разных места, и одно из
# них — самодостаточный инструмент тестера (enodia-diag.py / enodia-clean.py): он исполняет нас
# через `base64 -d | sh`, то есть БЕЗ единой переменной окружения. В режиме «всё на накопителе»
# каталоги на флеше пусты, и артефакт описал бы НЕ ТУ систему: «нет VERSION», «каталог пуст»,
# «транспорт не выбран» при живом туннеле. Спрашиваем бутстрап и только по ФАКТУ отсутствия —
# у роутера с обычной раскладкой не тратится ни одного форка.
ENODIA_BOOT=${ENODIA_BOOT:-/data/usr/app/enodia-boot}
if [ ! -f "$ENODIA_DIR/VERSION" ] && [ -f "$ENODIA_BOOT/boot.sh" ]; then
    _bp=$(sh "$ENODIA_BOOT/boot.sh" paths 2>/dev/null)
    _bd=$(printf '%s\n' "$_bp" | sed -n 's/^dir=//p' | tail -1)
    _bs=$(printf '%s\n' "$_bp" | sed -n 's/^state=//p' | tail -1)
    _bb=$(printf '%s\n' "$_bp" | sed -n 's/^bin=//p' | tail -1)
    case "$_bd" in /*) ENODIA_DIR="$_bd" ;; esac
    case "$_bs" in /*) ENODIA_STATE="$_bs" ;; esac
    case "$_bb" in /*) ENODIA_BIN="$_bb" ;; esac
    unset _bp _bd _bs _bb
fi
# …И ЭКСПОРТИРУЕМ НАЙДЕННОЕ: дамп зовёт наши скрипты (`transport.sh configured`, `watchdog.sh standing`),
# а их `${ENODIA_DIR:-литерал}` без окружения читает ЛИТЕРАЛЫ флеша — в раскладке full это пустое
# чужое состояние («транспорт не выбран», «дома» при живом резерве). Найдено независимым ревью.
export ENODIA_DIR ENODIA_STATE ENODIA_BIN ENODIA_BOOT

# Возраст отметки времени (clock-lib.sh) — дампу он нужен, чтобы не выдавать скачок часов за
# «VPS не отвечает» и чтобы САМ факт скачка попадал в артефакт. Шим = прежнее поведение.
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
# Имя WAN-интерфейса и шлюз — у владельца (ip-lib.sh::wan_iface / wan_gateway, следит C81): по ним
# идут пробы прямого пути ниже. Шимы = прежние строки: дамп ОБЯЗАН работать и на поломанной
# установке, где библиотеки нет, — это то, что присылают при разборе.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }
command -v wan_gateway >/dev/null 2>&1 || wan_gateway() { ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }
# Ожидание xtables-лока (ipt-lib.sh) — нужно САМОМУ дампу: секции iptables ниже читают правила,
# а при занятом локе чтение падает так же молча, как и запись.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
# 999999999 — это СЛОВО владельца «не прочитал /proc/uptime» (clock-lib.sh), и в дампе оно читалось
# бы как настоящие 31 год аптайма. Перевод в слово — ОДИН на файл: было два разных, в 12 строках
# друг от друга (ревью 5, 06.09.2026).
dmp_uptime() { _du=$(uptime_s); [ "$_du" = 999999999 ] && _du="не прочитан"; echo "$_du"; }

# --- маскировка «окружения»: имена сетей и имена клиентов ---------------------
# Нужна с появлением архива (verb `archive`): в СВОЁМ выводе дамп имён не печатает, а вот
# системный лог роутера несёт их пачками (hostapd, miwifi-roam, dnsmasq, odhcpd). Артефакт
# по-прежнему кидают в чат сообщества ⇒ «одна кнопка» не должна выкладывать карту дома.
# Выражения строим В РАНТАЙМЕ (имена у каждого свои) и кладём в sed-скрипт: собрать их в
# аргументы одной командной строки на busybox не выйдет — кавычки и спецсимволы в SSID.
# Короче 4 символов не берём: имя «TV» встретится в логе сотню раз не про клиента.
# Имя с PID и уборка в конце КАЖДОГО режима: файл — не кэш между запусками, а рабочий срез.
# Переживший вызов .sed означал бы маскировку по СТАРЫМ именам сетей (сеть переименовали —
# новое имя уехало бы в архив как есть), да ещё и в /tmp, то есть в ОЗУ.
#
# Заменяем НУМЕРОВАННЫМ псевдонимом, а не одним словом на всех: дамп печатает таблицу
# «wlN -> SSID» и хранилища правил, которые с 013a017 держат ИМЕНА СЕТЕЙ, — общий токен
# [SSID] схлопнул бы их в неразличимое «wl0 -> [SSID] / wl1 -> [SSID]», то есть убил бы
# ровно ту секцию, ради которой её и завели (04.08: правило уехало на чужую сеть).
# Одно имя = один номер на весь прогон ⇒ по архиву видно, ЧТО куда приземлилось.
ENV_SED=/tmp/.enodia-diag-env.$$.sed
build_env_sed() {
    : > "$ENV_SED" 2>/dev/null || return 0
    # эскейп значения под BRE и под разделитель '#'
    _esc() { printf '%s' "$1" | sed 's|[]\\.*^$&#[]|\\&|g'; }
    # ДЛИННОЕ имя — ПЕРВЫМ правилом: у стока имя гостевой/5 ГГц это имя основной плюс суффикс
    # («Xiaomi_1234» ⊂ «Xiaomi_1234_5G»), и короткое правило, применённое раньше, оставило бы
    # от длинного хвост «[SSID-1]_5G» — то есть половину имени В АРХИВЕ. Тот же урок, что
    # ownerTag() у подписок: побеждает ДЛИННЕЙШЕЕ совпадение. Ключ сортировки считаем awk'ом —
    # у busybox sort нет ни -k, ни -t, а неизвестные ключи он молча игнорирует.
    _n=0
    uci -q show wireless 2>/dev/null | sed -n "s/.*\.ssid='\(.*\)'\$/\1/p" | sort -u |
    awk '{print length($0) "\t" $0}' | sort -nr | cut -f2- |
    while read -r _s; do
        [ -n "$_s" ] && [ "${#_s}" -ge 4 ] || continue
        _n=$((_n+1))
        printf 's#%s#[SSID-%s]#g\n' "$(_esc "$_s")" "$_n" >> "$ENV_SED"
    done
    # Имена клиентов из аренд dnsmasq. '*' = имя не сообщено, такие строки пропускаем.
    if [ -f /tmp/dhcp.leases ]; then
        _n=0
        awk '{print $4}' /tmp/dhcp.leases 2>/dev/null | sort -u |
        awk '{print length($0) "\t" $0}' | sort -nr | cut -f2- |
        while read -r _h; do
            [ -n "$_h" ] && [ "$_h" != "*" ] && [ "${#_h}" -ge 4 ] || continue
            _n=$((_n+1))
            printf 's#%s#[HOST-%s]#g\n' "$(_esc "$_h")" "$_n" >> "$ENV_SED"
        done
    fi
    [ -s "$ENV_SED" ] || rm -f "$ENV_SED"
    return 0
}

# --- редактор секретов: ключи + endpoint + MAC + публичные IPv4 (см. шапку) ----
# MAC режем ЧАСТИЧНО: первые три октета (OUI) — это вендор устройства, он для разбора нужен
# («что за железка отвалилась от Wi-Fi»), а последние три и есть идентичность. Время вида
# 12:22:25 под шаблон не попадает — нужно ШЕСТЬ пар hex подряд. IPv6 попасть МОЖЕТ (группы
# бывают и по две цифры) — это не беда: хвост чужого адреса в шаринг-артефакте не нужен, а
# префикс, по которому и разбирают маршрутизацию, шаблон не трогает.
redact() {
    [ -f "$ENV_SED" ] || build_env_sed
    sed -e 's#[A-Za-z0-9+/]\{43\}=#[KEY-REDACTED]#g' \
        -e 's#PrivateKey *=.*#PrivateKey = [KEY-REDACTED]#g' \
        -e 's#PublicKey *=.*#PublicKey = [KEY-REDACTED]#g' \
        -e 's#PresharedKey *=.*#PresharedKey = [KEY-REDACTED]#g' \
        -e 's#endpoint: .*#endpoint: [REDACTED]#g' \
        -e 's#Endpoint *=.*#Endpoint = [REDACTED]#g' \
        -e 's#\([0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:\)[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}#\1xx:xx:xx#g' \
    | { [ -s "$ENV_SED" ] && sed -f "$ENV_SED" || cat; } \
    | awk '
    {
        line = $0; out = ""
        while (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
            ip   = substr(line, RSTART, RLENGTH)
            out  = out substr(line, 1, RSTART - 1)
            line = substr(line, RSTART + RLENGTH)
            split(ip, o, ".")
            if (o[1]=="10" || o[1]=="127" || o[1]=="0" || \
                (o[1]=="192" && o[2]=="168") || \
                (o[1]=="169" && o[2]=="254") || \
                (o[1]=="172" && o[2]>=16 && o[2]<=31)) {
                out = out ip                     # приватный/служебный — оставляем
            } else {
                out = out o[1] "." o[2] ".x.x"   # публичный — маскируем хвост
            }
        }
        print out line
    }'
}

sec() { echo ""; echo "==================================================================="; echo "## $1"; echo "==================================================================="; }
sub() { echo ""; echo "----- $1 -----"; }

# несекретный файл: показать содержимое целиком (или пометить отсутствие)
showf() {
    if [ -f "$1" ]; then echo "[$1]"; cat "$1" 2>/dev/null; echo "[/$1]"
    else echo "[$1] — нет"; fi
}
# секрет: ТОЛЬКО права/владелец/размер/имя, без содержимого
showmeta() {
    if [ -e "$1" ]; then ls -ld "$1" 2>/dev/null | awk '{print $1, $3, $5, $NF}'
    else echo "$1 — нет"; fi
}
# Версия прошивки Xiaomi лежит в UCI-файле /usr/share/xiaoqiang/xiaoqiang_version
# (строки вида: option ROM '1.1.38' / HARDWARE 'RC06' / CHANNEL / BUILDTIME).
# xqver KEY -> вернуть значение в кавычках. Это и есть «версия прошивки роутера».
xqver() { grep -E "^[[:space:]]*option $1 " /usr/share/xiaoqiang/xiaoqiang_version 2>/dev/null | head -1 | sed "s/.*'\(.*\)'.*/\1/"; }

# Логи подсистем проекта в /tmp — перечень зеркалит RAM_LOGS из clean.sh (разбор — у места
# использования, в секции «ЛОГИ /tmp»). Объявлен здесь, а не внутри main: этот же список нужен
# режиму archive как фолбэк, когда clean.sh на роутере отсутствует.
#
# ЗЕРКАЛО ОБЯЗАНО БЫТЬ ПОЛНЫМ, и это не педантизм: расхождение уже случилось — здесь не хватало
# `enodia-restore`, `ussl-dbg`, `xiaomi-bypass`. Логи-то в ОЗУ есть (их знает clean.sh), но в
# диаг-архив они не попадали ⇒ при разборе чужой аварии не хватало ровно того лога, который
# описывает восстановление из бэкапа. Проверку «RAM_LOGS ⊆ DUMP_LOGS» делает local/check-consistency.ps1.
DUMP_LOGS="enodia-startup enodia-watchdog enodia-switch-vpn-setup enodia-transport-awg-setup
enodia-iplist-update enodia-subs-update enodia-notify enodia-notify-event enodia-hev
enodia-hysteria enodia-byedpi enodia-byedpi-test-run enodia-byedpi-fetch enodia-zapret-nfqws
enodia-doh enodia-panel-tls enodia-support enodia-xiaomi-bypass enodia-dnsq enodia-restore
enodia-store-mode enodia-pkg-restart xray xray-access hytest ussl-dbg
switch-vpn-setup transport-awg-setup iplist-update subs-update notify notify-event hev hysteria
byedpi byedpi-test-run zapret-nfqws doh panel-tls support xiaomi-bypass"
# ХВОСТ — имена ДО 02.09.2026 (префикс `enodia-`), и он тут не ради симметрии со списком чистки:
# демон, переживший обновление скриптов, пишет по СТАРОМУ пути до своего перезапуска, а дамп
# снимают именно тогда, когда что-то сломалось, — то есть ровно в этот момент. `xray*` префикса
# не получил намеренно: его путь лежит ВНУТРИ пользовательских конфигов на /data.

# Пути НАШИХ непустых логов в ОЗУ, по одному в строке. Владелец перечня ОДИН — clean.sh
# (верб ramlogs-list), DUMP_LOGS выше — фолбэк для роутера, куда clean.sh ещё не залит.
# МАСКУ `/tmp/*.log` не берём НИГДЕ: рядом лежат СТОКОВЫЕ логи Xiaomi (wifi_analysis, ssh_patch,
# *.bootcheck, stat_points_*, lang_patch). Тот же дефект уже чинили в status.sh (dev156), но
# вторая копия осталась здесь: замер на свежем AX3600 17.08.2026 — дамп писал «Логи /tmp: 8 КБ в
# 10 файлах», статус в ту же секунду «4 КБ в 2 файл(ах)», и половину «нашего» объёма давал чужой
# 2944.bootcheck.log. Артефакт противоречил сам себе: ниже, в срезе clean.sh dryrun, честно
# перечислены только наши. Функция объявлена ВЫШЕ main — её зовут и main, и cmd_archive.
our_ramlogs() {
    if [ -f "$ENODIA_DIR/clean.sh" ]; then
        sh "$ENODIA_DIR/clean.sh" ramlogs-list 2>/dev/null
    else
        for _lg in $DUMP_LOGS; do [ -s "/tmp/$_lg.log" ] && echo "/tmp/$_lg.log"; done
    fi
    return 0
}

main() {

sec "ОБЗОР РОУТЕРА (железо / прошивка / нагрузка)"
rom=$(xqver ROM); ch=$(xqver CHANNEL); hw=$(xqver HARDWARE); bt=$(xqver BUILDTIME)
echo "Прошивка (ROM):  ${rom:-?} (${ch:-?})   сборка: ${bt:-?}"
echo "Модель:          Xiaomi ${hw:-?}  /  $(cat /proc/device-tree/model 2>/dev/null | tr -d '\000')"
echo "Ядро:            $(uname -s 2>/dev/null) $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"
echo "BusyBox:         $(busybox 2>&1 | head -1)"
ncpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
la=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
# % загрузки — ТОЛЬКО дельта /proc/stat (router-lib.sh::cpu_busy_pct, +1 с к дампу). Прежняя
# формула load1/ядра*100 печатала «~25%» на роутере, занятом на 0-1% (замер 16.08.2026 на
# BE7000 и AX3600): loadavg тут держится около 1.0 из-за фонового демона. Дамп присылают
# ИМЕННО тогда, когда «роутер тормозит», — выдуманная нагрузка уводила разбор в ложный след.
# Сырой load average оставляем в скобках: он честен сам по себе и привычен разбирающему.
if [ -f "$ENODIA_DIR/router-lib.sh" ]; then . "$ENODIA_DIR/router-lib.sh"; fi
pct=$(command -v cpu_busy_pct >/dev/null 2>&1 && cpu_busy_pct)
echo "CPU:             ${ncpu:-?} ядра · загрузка ~${pct:-?}% (load average: ${la:-?})"
awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf "RAM:             %d МБ свободно из %d МБ (доступно %s)\n", f/1024, t/1024, (a==""?"?":sprintf("%d МБ", a/1024))}' /proc/meminfo 2>/dev/null
# ПЗУ = постоянная память /data (ubifs, переживает ребут — туда ставится AWG/конфиги/
# логи). df|awk печатает строку сам (НЕ внутри echo "$(...)": awk-овский $(NF-2)
# схлестнулся бы с шелловским $(...) внутри двойных кавычек). / squashfs-корень не
# берём — он всегда 100% по природе сжатого ro-образа (мнимое «забито», пугает зря).
# «ЗАНЯТО» СЧИТАЕМ САМИ, колонку `Use%` у df не берём: она считает used/(used+avail), то есть
# БЕЗ неснижаемого резерва UBIFS, и расходится с панелью на 3-4 пункта (замер 17.08.2026 на
# AX3600: `Use%` = 31%, панель и status.sh = 35% про один и тот же /data). Дамп кладут в
# отчёт рядом со скриншотом панели — два числа про одно место читаются как «одно из них врёт».
# Владелец формулы «занято = total − available» — status.sh; отсюда df в КИЛОБАЙТАХ и
# «%.1fM» руками. Гард `$(NF-4)+0>0` — от деления на ноль, от переноса длинного имени устройства
# и от СТРОКИ-ЗАГОЛОВКА (её печатает df, когда пути нет; `+0` обязателен — см. store-lib.sh).
# ТОМ спрашиваем ПО ПУТИ каталога и ИМ ЖЕ подписываем строку: `df /data` — литерал, а на
# BE10000 (RC01) флеш поделён на ТРИ ubifs и `/data` там ЧУЖОЙ (стоковый cfg 4.7 МБ). Дамп с
# чужим томом в шапке уводит разбор по ложному следу с первой же строки (следит C50).
# ШИРИНА ПОЛЯ — 20, А НЕ 17. Шапка — колонка: у соседей («RAM:», «Uptime:») подпись занимает
# 17 ЗНАКОВ. Но `%-Ns` у awk считает БАЙТЫ (та же грабля, что у `cut -c`), а «ПЗУ» — три
# двухбайтовые буквы ⇒ на три байта больше. Имя тома длиннее поля колонку всё равно сдвинет:
# это данные df, и врать про них ради ровного края мы не станем. Поэтому поле 19 + ЯВНЫЙ
# пробел, а не 20: у коротких подписей колонка та же, а у длинной («Накопитель (/mnt/usb-…):»)
# число не слипается с двоеточием — %-Ns при переполнении не добавляет ни одного пробела.
# …И ЭТО ФЛЕШ РОУТЕРА, а не «том, где лежит код»: в режиме «всё на накопителе» $ENODIA_DIR
# указывает на флешку, и строка «ПЗУ (/mnt/usb-…): 28.7G свободно» отвечала НЕ ПРО РОУТЕР —
# при том что слово «ПЗУ» читается как «флеш роутера» и никак иначе. Про флеш дамп при этом
# не говорил вовсе, хотя «чем занят флеш» — один из четырёх вопросов, ради которых его и шлют.
# Якорь — бутстрап: он резидентен на /data ПО ОПРЕДЕЛЕНИЮ, а в обычной раскладке это тот же
# том, что и код. Откат на $ENODIA_DIR — для установок старее бутстрапа.
DUMP_FLASH="$ENODIA_BOOT"; [ -d "$DUMP_FLASH" ] || DUMP_FLASH="$ENODIA_DIR"
df -k "$DUMP_FLASH" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{printf "%-19s %.1fM свободно из %.1fM (занято %.0f%%)\n", "ПЗУ (" $NF "):", $(NF-2)/1024,$(NF-4)/1024,($(NF-4)-$(NF-2))*100/$(NF-4)}'
# Накопитель — ОТДЕЛЬНОЙ строкой и только когда код лежит НЕ на флеше: у роутера без флешки
# лишней строки в шапке быть не должно (то же правило, что у карточки хранилища в панели).
DUMP_CODE_MP=$(df -k "$ENODIA_DIR" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{print $NF}')
DUMP_FLASH_MP=$(df -k "$DUMP_FLASH" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{print $NF}')
if [ -n "$DUMP_CODE_MP" ] && [ "$DUMP_CODE_MP" != "$DUMP_FLASH_MP" ]; then
    df -k "$ENODIA_DIR" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{printf "%-19s %.1fM свободно из %.1fM (занято %.0f%%)\n", "Накопитель (" $NF "):", $(NF-2)/1024,$(NF-4)/1024,($(NF-4)-$(NF-2))*100/$(NF-4)}'
fi
echo "Uptime:          $(uptime 2>/dev/null)"   # raw-uptime: busybox-апплет, печать человеку — вердикта по строке нет
echo "Дата (роутер):   $(date 2>/dev/null)"
# Сверка часов на буте (clock-lib.sh::clock_http_sync). Отвечает на «почему после ребута VPN на другом
# сервере»: `step=N` = часы отставали на N с и сдвинуты; `step=0` = были верны; нет отметки =
# сверка не прошла (нет WAN или источники молчат) — тогда рукопожатие мог отбросить сам сервер.
echo "Часы на буте:    $(cat "${CLOCK_SYNC_MARK:-/tmp/enodia-clock.synced}" 2>/dev/null || echo 'сверки не было (нет отметки)') · сток ntp: $(cat /tmp/ntp.status 2>/dev/null || echo '—')"
echo "Hostname:        $(cat /proc/sys/kernel/hostname 2>/dev/null)"
echo "ENODIA_DIR:      $ENODIA_DIR"
# Версия НАШИХ скриптов. Без неё разбор чужого дампа начинается с угадывания «а что у него
# вообще стоит»: по составу цепочек и по usage-строкам вербов это восстанавливается, но дорого
# и ненадёжно, а у тестеров живут сборки месячной давности. VERSION кладёт в $ENODIA_DIR
# установщик и обновляет апдейтер (формат: VERSION=/CODE=). НЕ сорсим, а вычитываем sed'ом:
# дамп гоняют через `base64 -d | sh`, и выполнять содержимое чужого файла ему незачем.
_ver=$(sed -n 's/^VERSION=//p' "$ENODIA_DIR/VERSION" 2>/dev/null | head -1)
_code=$(sed -n 's/^CODE=//p'   "$ENODIA_DIR/VERSION" 2>/dev/null | head -1)
if [ -n "$_ver" ]; then
    echo "Версия скриптов: $_ver (CODE ${_code:-?})"
else
    echo "Версия скриптов: (нет $ENODIA_DIR/VERSION — установка старее апдейтера)"
fi
# ОТКУДА этот роутер берёт код и бинари. Три файла-оверрайда молча меняют источник: `.gh-repo`
# — целиком ДРУГОЙ репозиторий, `.gh-ref` — ветку/тег, `.gh-bin-tag` — тег ассетов. Забытый на
# роутере `.gh-repo` (их кладут при отладке) выглядит потом как «обновление не предлагается» и
# «компонент не ставится» — то есть как сетевая беда, и по дампу без этой строки его не найти.
# Печатаем ВСЕГДА, в том числе «по умолчанию»: молчание читалось бы как «оверрайдов нет», а
# отличить его от «секции нет в этой версии дампа» нельзя.
_ghrepo=$(cat "$ENODIA_STATE/.gh-repo" 2>/dev/null | tr -d ' \r\n')
_ghref=$(cat "$ENODIA_STATE/.gh-ref" 2>/dev/null | tr -d ' \r\n')
_ghbin=$(cat "$ENODIA_STATE/.gh-bin-tag" 2>/dev/null | tr -d ' \r\n')
echo "Источник обновлений: репо ${_ghrepo:-(по умолчанию)} · ветка/тег ${_ghref:-(по умолчанию)} · тег бинарей ${_ghbin:-(по умолчанию)}"

sec "ИНТЕРФЕЙС awg0"
ip addr show awg0 2>/dev/null || echo "(awg0 не поднят)"
sub "ip link"
ip link show awg0 2>/dev/null || echo "(нет)"

sec "СОСТОЯНИЕ AWG (awg show — ключи/endpoint замаскированы)"
if [ -x "$ENODIA_BIN/awg" ]; then
    "$ENODIA_BIN/awg" show awg0 2>/dev/null || echo "(awg show awg0 не отработал)"
    sub "возраст handshake"
    hs=$("$ENODIA_BIN/awg" show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    case "$hs" in
        ''|*[!0-9]*) echo "handshake: нет / никогда — VPS не отвечает?" ;;
        0)           echo "handshake: 0 — никогда" ;;
        *)           # Печатаем ОБА числа, когда они разошлись: расхождение = часы шагнули после
                     # рукопожатия (RTC нет, стоковый ntp доходит через ~13 мин после загрузки), и
                     # сырая разность в дампе увела бы разбор в «VPS не отвечает».
                     _dmp_raw=$(( $(date +%s) - hs ))   # clock-raw: сырая разность нужна как раз для сравнения с age_since
                     _dmp_age=$(age_since "$hs")
                     if [ "$_dmp_raw" != "$_dmp_age" ]; then
                         echo "handshake: $_dmp_age сек назад (ЧАСЫ ШАГНУЛИ: сырая разность $_dmp_raw с при аптайме $(dmp_uptime) с)"
                     else
                         echo "handshake: $_dmp_age сек назад"
                     fi ;;
    esac
else
    echo "(бинарь $ENODIA_BIN/awg не найден)"
fi

sec "АКТИВНЫЙ ТРАНСПОРТ (что реально несёт трафик)"
# Пустой `.transport` — ДВА РАЗНЫХ мира, и «awg по умолчанию» верно лишь в одном: роутер СТАРШЕ
# флага (историческое умолчание) ЛИБО установка «только панель», где транспорта нет ВООБЩЕ.
# Дамп присылают при разборе, и «awg по умолчанию» на стоковом роутере уводит читателя искать
# мёртвый awg0 там, где ничего, кроме панели, не ставили. Отличать их самим НЕЛЬЗЯ: единственный
# ответ — верб `configured` у оркестратора (0 настроен · 1 НЕТ ни одного · 2 старая копия скрипта),
# ровно как в status.sh. Своей копии признака (пусто .transport И нет awg.conf) не заводим.
_dmp_t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
if [ -n "$_dmp_t" ]; then
    echo "Файл .transport:  $_dmp_t"
elif [ -f "$ENODIA_DIR/transport.sh" ]; then
    sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1
    case "$?" in
        1) echo "Файл .transport:  (пуст — установка «только панель»: транспорт не выбран НИ РАЗУ, правил в роутере нет)" ;;
        2) echo "Файл .transport:  (пуст — старая копия transport.sh, судить о транспорте нечем)" ;;
        *) echo "Файл .transport:  (пуст, но транспорт НАСТРОЕН — роутер старше флага, несущая awg)" ;;
    esac
else
    echo "Файл .transport:  (пуст — transport.sh нет, установка до рефактора плагинов)"
fi
# ПУСТОЙ файл — это ответ «имя неизвестно» (так его пишет install_config, когда имени неоткуда
# взять), и `|| echo '?'` его НЕ ловит: у пустого `cat` возвращает 0. Дамп — то, что присылают при
# разборе, и обрезанная строка читалась бы как «дамп сломался».
_dp_act=$(cat "$ENODIA_STATE/.active" 2>/dev/null | tr -d '\r')
echo "Файл .active:     ${_dp_act:-?}"
# `.vpn-off` — ПЕРВЫМ в строке: это ответ на самый частый вопрос разбора «почему ничего не
# поднялось» (человек выключил VPN, а с 02.09.2026 выключение переживает ребут).
echo "Прочее: .vpn-off=$( [ -f "$ENODIA_STATE/.vpn-off" ] && echo "ДА — VPN выключен человеком" || echo нет )  .zapret-on=$( [ -f "$ENODIA_STATE/.zapret-on" ] && echo да || echo нет )  .full-tunnel=$( [ -f "$ENODIA_STATE/.full-tunnel" ] && echo да || echo нет )"
if [ -f "$ENODIA_DIR/transport.sh" ]; then
    sub "transport.sh active"
    sh "$ENODIA_DIR/transport.sh" active 2>/dev/null || echo "(active не отработал)"
    sub "transport.sh list (готовность транспортов)"
    sh "$ENODIA_DIR/transport.sh" list 2>/dev/null || echo "(list не отработал)"
    # Верба `status` у ОРКЕСТРАТОРА нет и не было НИКОГДА (его вербы: active|names|list|next|
    # up|down|switch|health|failover|dns|slot-*) — секция печатала usage вместо статуса, то есть
    # ровно ноль информации. Спрашиваем то, что он умеет: вердикт health АКТИВНОГО транспорта.
    # Причину плагин пишет в СВОЙ лог (он ниже в дампе), на stdout не печатает ничего — поэтому
    # вердикт печатаем сами по коду возврата. Срез самой несущей дают плагинные `status` ниже.
    sub "transport.sh health (жива ли несущая активного транспорта)"
    # VPN выключен человеком — несущей НЕТ по его воле, и проба её не зовётся вовсе: у ByeDPI `health` переподнимает ciadpi и при
    # флаге отказывает (daemon-lib.sh::carrier_run), а «НЕ ОК» читалось бы как поломка (ревью ветки, круг 3).
    _rc=0
    if [ -f "$ENODIA_STATE/.vpn-off" ]; then _rc=off
    else sh "$ENODIA_DIR/transport.sh" health >/dev/null 2>&1 || _rc=$?; fi
    if [ "$_rc" = off ]; then
        echo "health: не проверялась — VPN выключен человеком, несущей нет по его воле"
    elif [ "$_rc" = 0 ]; then
        echo "health: OK — несущая активного транспорта жива"
    else
        echo "health: НЕ ОК (код $_rc) — несущая просела ЛИБО активного транспорта нет (fail-open); причина в логе транспорта ниже"
    fi
else
    echo "(transport.sh нет — установка до рефактора плагинов)"
fi

# Подсистемы, появившиеся ПОСЛЕ первой версии дампа. Без них артефакт описывал роутер образца
# «awg + xray», хотя разбирать чаще приходится ровно их: десинк, доп-выходы и «доступ домой».
# Все три верба read-only и печатают состояние, а не секреты (ключи пиров дамп не читает — см.
# шапку: у vpn-server.sh для этого есть `status`, который их не показывает).
sec "ДОП-ВЫХОДЫ (слоты 2..4 — свой транспорт и свой сервер у каждого)"
if [ -f "$ENODIA_DIR/slots.sh" ]; then
    sh "$ENODIA_DIR/slots.sh" state 2>/dev/null || echo "(state не отработал)"
    sub "несущие выходов (carriers)"
    sh "$ENODIA_DIR/slots.sh" carriers 2>/dev/null || echo "(нет)"
    sub "слот-марки и таблицы (ip rule)"
    ip rule 2>/dev/null | grep -E 'fwmark 0x[2-4]' || echo "(слот-правил в ip rule нет)"
    # УЧЁТ ПО ВЫХОДАМ — сюда же, а не в «ресурсы»: разбирают его вместе с самими выходами
    # («карточка показывает не то»), и ответ на это ровно два файла: СЫРОЙ последний замер
    # (первая строка — несущая и WAN, ниже по строке на выход: "s<id> <iface> <rx> <tx>") и
    # СЕГОДНЯШНЯЯ строка посуточной истории (поля $7..$12 — те же выходы по номерам).
    # Строки выхода НЕТ = «считать нечем»: у zapret-выхода своей несущей не бывает вовсе, а у
    # выключенного её уже нет — и это ОТВЕТ, а не пропажа.
    sub "учёт трафика по выходам (сырой замер + сегодня)"
    if [ -f "$ENODIA_STATE/.traffic-last" ]; then cat "$ENODIA_STATE/.traffic-last"
    else echo "(.traffic-last нет — учёт ещё не тикал)"; fi
    awk -v d="$(date +%F 2>/dev/null)" '$2==d{print "сегодня: "$0; f=1} END{if(!f)print "(сегодняшней строки в .traffic-daily ещё нет)"}' \
        "$ENODIA_STATE/.traffic-daily" 2>/dev/null || echo "(.traffic-daily нет)"
else
    echo "(slots.sh нет — установка до мульти-транспорта)"
fi

sec "ZAPRET / ДЕСИНК (nfqws, NFQUEUE, пулы)"
if [ -f "$ENODIA_DIR/zapret.sh" ]; then
    # БЕЗ `head`: срез zapret растёт с числом выбранных категорий и правил в ENODIA_ZAPRET, а резали
    # мы его на 30-й строке — ровно там, где начинаются «правила mangle», то есть ответ на «почему
    # десинк мёртв при живом демоне». Обрезка была ТИХОЙ: читатель видел законченный текст.
    sh "$ENODIA_DIR/zapret.sh" status 2>/dev/null || echo "(status не отработал)"
    sub "проводка: jump ENODIA_ZAPRET + NFQUEUE (по нему сторож судит, жив ли десинк)"
    iptables -t mangle -S PREROUTING 2>/dev/null | grep -i zapret || echo "(jump ENODIA_ZAPRET в mangle PREROUTING НЕТ)"
    iptables -t mangle -S POSTROUTING 2>/dev/null | grep -i NFQUEUE || echo "(правил NFQUEUE нет)"
    sub "устройства целиком в десинк (NFQUEUE по источнику)"
    sh "$ENODIA_DIR/zapret.sh" src-list 2>/dev/null || echo "(нет)"
else
    echo "(zapret.sh нет)"
fi

sec "ДОСТУП ДОМОЙ (роутер как VPN-сервер; ключи пиров НЕ читаем)"
if [ -f "$ENODIA_DIR/vpn-server.sh" ]; then
    sh "$ENODIA_DIR/vpn-server.sh" status 2>/dev/null || echo "(status не отработал)"
    sub "цепочки VPNSRV_* (порт наружу / вход из туннеля / форвард)"
    for c in VPNSRV_WAN VPNSRV_IN VPNSRV_FWD; do
        iptables -S "$c" 2>/dev/null || echo "(цепочки $c нет)"
    done
else
    echo "(vpn-server.sh нет)"
fi

sec "ШИФРОВАННЫЙ DNS (DoH/DoT — прокси на 127.0.0.1:5053)"
# Тумблер — ЗНАЧЕНИЕ файла ("on"), а не факт его наличия: `.doh-on` остаётся на диске и после
# выключения (та же семантика, что у doh_enabled в doh-lib.sh — второй трактовки не заводим).
echo "Тумблер (.doh-on): $( [ "$(cat "$ENODIA_STATE/.doh-on" 2>/dev/null)" = on ] && echo вкл || echo выкл )   авто в прямых режимах: $( [ "$(cat "$ENODIA_STATE/.doh-auto" 2>/dev/null)" = off ] && echo запрещён || echo разрешён )$( [ -f /tmp/.enodia-doh-auto-on ] && echo ' (СЕЙЧАС активен)' )"
echo "Протокол: $(cat "$ENODIA_STATE/.doh-proto" 2>/dev/null || echo doh)   резолвер: $(cat "$ENODIA_STATE/.doh-resolver" 2>/dev/null || echo '(деф. cloudflare)')"
# «Уведён мимо несущей» — иначе по дампу не отличить «резолвер через WAN» от штатного (флаг ставят
# сторож на SUSPECT и up-путь несущей при провале пробы; пауза возврата — после провала возврата).
[ -f /tmp/.enodia-doh-untunneled.stamp ] && echo "Резолвер УВЕДЁН МИМО несущей (RETURN вместо марки), уведён $(age_since "$(cat /tmp/.enodia-doh-untunneled.stamp 2>/dev/null | tr -cd '0-9')") с назад"
_drs=$(cat /tmp/enodia-doh-retunnel.stamp 2>/dev/null | tr -cd '0-9')
[ -n "$_drs" ] && echo "Возврат в несущую ПРОВАЛИЛСЯ (резолвер через неё не отвечает) $(age_since "$_drs") с назад — пауза до повтора"
# ВЫБРАН DoT, А ШИФРУЕТ DoH — спрашиваем владельца (doh-lib.sh::doh_health_state), а не файл: переезд значит что-то
# только при установленной программе DoH, и «протокол: dot» строкой выше без этой строки спорил бы со списком
# процессов ниже (там https_dns_proxy). Подоболочка: библиотека сорсится без побочек, но дампу её имена ни к чему.
_dhs=$( [ -f "$ENODIA_DIR/doh-lib.sh" ] && . "$ENODIA_DIR/doh-lib.sh" && command -v doh_health_state >/dev/null 2>&1 && doh_health_state )
case "$_dhs" in *dotfb=1*)
    echo "Выбран DoT, а шифрует DoH: порт 853 текущим путём не проходил — переехал $(printf '%s\n' "$_dhs" | sed -n 's/^dotfb_age=//p') с назад, повтор DoT через $(printf '%s\n' "$_dhs" | sed -n 's/^dotfb_retry=//p') с (-1 = неизвестно)" ;;
esac
ps 2>/dev/null | grep -E '[h]ttps_dns_proxy|[d]ot-proxy' | head -4 || echo "(прокси шифрованного DNS не запущен)"
# Живость АВТО-режима: демон бежит ≠ резолвер отвечает. Ровно этот разрыв съел вечер 09.08.2026 —
# https_dns_proxy жив, лог полон «curl request failed», а по дампу DoH выглядел здоровым. Печатаем
# карантин (его ставит doh_health_tick после отката) и СВОДКУ ЛОГА: строка «сколько провалов» тут
# отвечает на «почему ничего не открывается» быстрее, чем чтение 200 КБ /tmp/enodia-doh.log глазами.
_dhc=$(cat /tmp/.enodia-doh-auto-cooldown 2>/dev/null | tr -cd '0-9')
_dhl=$(( ${_dhc:-0} - $(date +%s) ))
[ "$_dhl" -gt 0 ] && echo "Авто-режим В КАРАНТИНЕ после отката: ещё $(( _dhl / 60 )) мин (резолвер не отвечал)"
[ -s /tmp/enodia-doh.log ] && echo "Лог прокси: $(wc -c < /tmp/enodia-doh.log) Б, провалов резолва: $(grep -c 'curl request failed' /tmp/enodia-doh.log 2>/dev/null || true)"

sec "МАРШРУТИЗАЦИЯ (fwmark / таблицы / прямой путь)"
sub "ip rule"
ip rule 2>/dev/null
sub "ip route show table 1000 (VPN-таблица — несущая)"
ip route show table 1000 2>/dev/null || echo "(таблица 1000 пуста)"
sub "default route (main) + WAN-интерфейс"
ip route show default 2>/dev/null
# WAN-интерфейс и шлюз — у владельца (ip-lib.sh): дефолт main, свои несущие WAN-ом не считаются
# (дефолт в awg0/xtun ⇒ пусто — прямой egress и правда мёртв; сырой маршрут напечатан строкой выше).
WANDEV=$(wan_iface)
WANGW=$(wan_gateway)
echo "WAN dev: ${WANDEV:-'(дефолта в main НЕТ либо он смотрит в туннель — прямой egress мёртв!)'}   шлюз: ${WANGW:-?}"
sub "ip route get 8.8.8.8 (обычно маркируется в туннель)"
ip route get 8.8.8.8 2>/dev/null
sub "ip route get 77.88.55.242 (ya.ru — РУНЕТ, должен идти ПРЯМО через main/WAN)"
ip route get 77.88.55.242 2>/dev/null
sub "ip route get 1.1.1.1"
ip route get 1.1.1.1 2>/dev/null
sub "ip route get 8.8.8.8 mark 0x1 (МАРКИРОВАННЫЙ — должен уходить в table 1000/несущую)"
# Без mark route get идёт по main (покажет WAN и введёт в заблуждение). С mark 0x1 видно
# реальный путь помеченного трафика: жива ли несущая как default в table 1000.
ip route get 8.8.8.8 mark 0x1 2>/dev/null || echo "(mark-роут не разобран)"

sec "IPTABLES mangle (метки в туннель)"
# «Правило не поставили» и «правило не встало» в дампе выглядят ОДИНАКОВО. Разница — умеет ли
# сборка ждать xtables-лок; ответ спрашиваем у владельца (ipt-lib.sh), а не гадаем по версии.
_iptwait=$(command -v ipt_wait_mode >/dev/null 2>&1 && ipt_wait_mode)
case "$_iptwait" in
    [1-9]*) echo "xtables-лок: ждём до ${_iptwait} с (ipt-lib.sh)" ;;
    no)     echo "xtables-лок: ЖДАТЬ НЕ УМЕЕМ — сборка iptables без \`-w <сек>\`; при занятом локе правило молча не встанет" ;;
    *)      echo "xtables-лок: ipt-lib.sh не загружен (старая установка) — ожидания нет" ;;
esac
iptables -t mangle -S 2>/dev/null || echo "(mangle недоступен)"
# Потолок НАЗВАН в заголовке, как у соседей ниже: цепочка растёт с гео/группами/устройствами и на
# нагруженном роутере за 30 строк уходит, а молчаливый обрыв тут читается как «правил больше нет» —
# то есть ровно как отсутствие маркировки, которую в этой секции и ищут.
sub "PREROUTING со счётчиками (первые 30 — видно, бьют ли правила трафик)"
iptables -t mangle -L PREROUTING -v -n 2>/dev/null | head -30
sub "VPN_EXCLUDE / VPN_FORCE со счётчиками"
iptables -t mangle -L VPN_EXCLUDE -v -n 2>/dev/null || echo "(цепочки VPN_EXCLUDE нет)"
iptables -t mangle -L VPN_FORCE   -v -n 2>/dev/null || echo "(цепочки VPN_FORCE нет)"

sec "IPTABLES nat (MASQUERADE — прямой И туннельный egress)"
sub "POSTROUTING полностью (masq нужен и на WAN для рунета, и на awg0/xtun)"
iptables -t nat -S POSTROUTING 2>/dev/null || echo "(nat недоступен)"
sub "PREROUTING (nat, первые 20)"
iptables -t nat -S PREROUTING 2>/dev/null | head -20

sec "IPTABLES filter FORWARD (у fw3 policy DROP — без ACCEPT форвард мёртв)"
sub "FORWARD -S полностью (policy + все правила)"
iptables -S FORWARD 2>/dev/null || echo "(filter недоступен)"
sub "FORWARD со счётчиками (первые 25 — видно, кто дропает пакеты)"
iptables -L FORWARD -v -n 2>/dev/null | head -25

sec "IPSET (наполнение списков)"
echo "Наборы: $(ipset list -n 2>/dev/null | tr '\n' ' ')"
for s in enodia_list iplist_set; do
    if ipset list -n 2>/dev/null | grep -qx "$s"; then
        # «Number of entries:» печатают НЕ все ядра: на 4.4 (AX3600/BE3600) её нет →
        # фолбэк на подсчёт строк-членов (см. канон ipset_count в lists-lib.sh).
        n=$(ipset list "$s" 2>/dev/null | sed -n 's/^Number of entries:[[:space:]]*//p' | head -1)
        case "$n" in ''|*[!0-9]*) n=$(ipset list "$s" 2>/dev/null | grep -cE '^[0-9]') ;; esac
        echo "  $s: ${n:-0}"
    else
        echo "  $s: нет набора"
    fi
done

sec "CONNTRACK"
# ЧЕМ роутер вообще умеет сбрасывать соединения — первым делом: без этого весь раздел читается
# как «правила есть, соединения есть», и не видно, что применяться к УЖЕ УСТАНОВЛЕННЫМ им нечем.
# На стоке AX3600 (ядро 4.4) утилиты conntrack в прошивке НЕТ, сброс делает ручка ускорителя.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
if command -v ct_tool >/dev/null 2>&1; then
    case "$(ct_tool)" in
        conntrack) echo "Сброс соединений: утилита conntrack" ;;
        ecm)       echo "Сброс соединений: ручка ускорителя ($CT_ECM_DEFUNCT) — утилиты conntrack в прошивке НЕТ" ;;
        *)         echo "Сброс соединений: НЕЧЕМ (ни утилиты conntrack, ни ручки ускорителя) — правила применятся только к НОВЫМ соединениям" ;;
    esac
fi
echo "Ускоренных потоков (NSS/ECM): $(cat /sys/kernel/debug/ecm/ecm_db/connection_count 2>/dev/null || echo 'н/д')"
echo "Активных соединений: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || conntrack -C 2>/dev/null || echo '?')"
sub "срез TCP:443 (видно, доходит ли SYN-ACK / держится ли ESTABLISHED)"
{ conntrack -L -p tcp --dport 443 2>/dev/null || grep -E 'dport=443' /proc/net/nf_conntrack 2>/dev/null; } | head -12 || echo "(conntrack-срез недоступен)"
sub "TCP-строгость conntrack (ключ к 'SYN-ACK дошёл до роутера, но дропнут')"
# be_liberal=0 (строго): out-of-window пакеты (частый эффект CGNAT-реордера / NSS-офлоада на
# ПРЯМОМ пути) помечаются INVALID и рубятся правилом fw3 'ctstate INVALID -j DROP' в FORWARD.
# Туннельный трафик это правило НЕ задевает (accept -i/-o xtun выше по цепочке) → прямой рунет
# рвётся, а VPN-сайты живут. Лечится be_liberal=1. Счётчик INVALID-дропа ниже = растёт при сбое.
echo "nf_conntrack_tcp_be_liberal = $(cat /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal 2>/dev/null || echo '?')  (0 = строго, дропает out-of-window как INVALID)"
echo "FORWARD 'ctstate INVALID -j DROP' бьёт: $(iptables -L FORWARD -v -n 2>/dev/null | awk '/ctstate INVALID/{print $1" пакетов / "$2" байт"; exit}')"

sec "ПРЯМОЙ ПУТЬ — ПРОБА С РОУТЕРА (жив ли egress мимо туннеля)"
# ya.ru по IP + заголовок Host: тестирует TCP/TLS до Яндекса БЕЗ dnsmasq — изолирует
# МАРШРУТ от DNS. 000 = роутер сам не достаёт рунет напрямую (прямой egress мёртв).
printf 'Рунет напрямую (ya.ru 77.88.55.242, мимо DNS): '
c=$(curl -s -k --max-time 6 -o /dev/null -w '%{http_code}' -H 'Host: ya.ru' https://77.88.55.242/ 2>/dev/null); echo "HTTP ${c:-000}"
# IPv4-выход РОУТЕРА в обход туннеля: bind к WAN-iface (без bind проба к 1.1.1.1 ушла бы в туннель
# — Cloudflare ∈ iplist_set). IP-литерал trace, а не api.ipify.org: на ядре 4.4 hostname молча пустел.
printf 'Инет напрямую (IPv4-выход роутера, IP-литерал trace): '
_di=$(curl -s -k ${WANDEV:+--interface $WANDEV} --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=\([0-9.]*\).*/\1/p'); echo "${_di:-(нет ответа)}"
if [ -n "$WANGW" ]; then
    printf 'Пинг WAN-шлюза: '
    ping -c2 -W2 "$WANGW" 2>/dev/null | tail -2 || echo "(шлюз не пингуется)"
fi

sec "АЛЬТ-НЕСУЩАЯ (xray / hev / tun2socks / socks 10808)"
sub "процессы транспортов"
ps 2>/dev/null | grep -E '[x]ray|[h]ev|tun2socks|[h]ysteria|[b]yedpi|[c]iadpi|[a]mneziawg-go' | head -12 || echo "(процессов альт-несущих нет)"
sub "интерфейс xtun (tun2socks)"
ip addr show xtun 2>/dev/null | grep -E 'inet|state' || echo "(xtun нет — не xray/hy2)"
sub "socks 10808 — живая проба (curl --socks5 к 1.1.1.1 по IP)"
c=$(curl -s --max-time 6 --socks5 127.0.0.1:10808 -o /dev/null -w '%{http_code}' http://1.1.1.1/ 2>/dev/null); echo "socks5 127.0.0.1:10808 -> HTTP ${c:-000}  (000 = socks не отвечает / curl без socks)"
# Срез несущей спрашиваем у КАЖДОГО установленного плагина, а не у одного xray-transport.sh:
# верб `status` есть у всех по контракту (up|down|status|health|failover), и прежняя жёсткая
# привязка означала, что на роутере с byedpi/hy2 (или awg без xray) статуса несущей в дампе НЕТ
# вовсе. Перебираем по МАСКЕ файлов, а не по вшитому списку имён, — шестой плагин попадёт в дамп
# сам. zapret здесь пропускаем сознательно: он не альт-несущая, у него своя секция ниже.
_np=0
for _p in "$ENODIA_DIR"/transport-*.sh "$ENODIA_DIR"/xray-transport.sh; do
    [ -f "$_p" ] || continue
    _np=1
    sub "$(basename "$_p") status"
    # БЕЗ `head -20` — по той же причине, что снят `head -30` у zapret ниже: срез плагина растёт
    # вместе с маршрутами в table 1000 и правилами анти-петли, а резали мы его молча, ровно на
    # хвосте («awg0 — тёплый резерв»). Вывод каждого плагина ограничен по конструкции.
    sh "$_p" status 2>/dev/null || echo "(status не отработал)"
done
[ "$_np" = 0 ] && echo "(плагинов несущих нет — установка до рефактора транспортов)"

sec "OFFLOAD (Qualcomm NSS / SFE / ECM — влияет на conntrack и десинк)"
found=0
for k in /sys/kernel/debug/ecm /sys/module/shortcut_fe /sys/module/qca_nss_drv /proc/sys/dev/nss; do
    [ -e "$k" ] && { echo "есть: $k"; found=1; }
done
for f in /sys/kernel/debug/ecm/front_end_ipv4_stop /sys/kernel/debug/ecm/front_end_ipv6_stop; do
    [ -e "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
done
[ "$found" = 0 ] && echo "(маркеров NSS/SFE/ECM не найдено — офлоад иной или выключен)"

sec "IPv6 В LAN (раздаётся ли клиентам / утечка мимо IPv4-сплита)"
_lanif=$(command -v lan_if >/dev/null 2>&1 && lan_if || echo br-lan)   # lan-lit: шим без router-lib.sh
sub "адреса $_lanif (глобальный 2…/3… = роутер раздаёт клиентам рабочий v6)"
ip -6 addr show "$_lanif" 2>/dev/null | grep -E 'inet6' || echo "(v6 на $_lanif нет)"
sub "v6 default (есть ли у ISP рабочий v6-upstream)"
ip -6 route show default 2>/dev/null || echo "(v6-дефолта нет — v6-утечки быть не может)"
sub "uci dhcp.lan (ra/dhcpv6 — анонсирует ли роутер v6 в LAN)"
uci show dhcp.lan 2>/dev/null | grep -E '\.ra=|\.dhcpv6=|\.ra_' || echo "(ra/dhcpv6 в uci не задано)"

sec "КЛИЕНТЫ ЛОКАЛЬНОЙ СЕТИ (аренды + кто реально в сети)"
# ЗАЧЕМ ОТДЕЛЬНАЯ СЕКЦИЯ. Жалоба «устройства нет в списке панели» разбиралась по SSH руками
# (04.09.2026, телевизор тестера со статическим адресом): список устройств растёт из аренд, а
# аренды у клиента со статикой, прописанной НА НЁМ САМОМ, не бывает вовсе. Дамп обязан отвечать
# на этот вопрос сам — иначе каждый такой случай стоит сессии удалённого доступа.
sub "аренды dnsmasq (/tmp/dhcp.leases)"
if [ -f /tmp/dhcp.leases ]; then
    printf 'строк: %s\n' "$(grep -c . /tmp/dhcp.leases 2>/dev/null || echo 0)"
    awk '{print $3"\t"$2"\t"$4}' /tmp/dhcp.leases 2>/dev/null | sort -n
else
    echo "(файла нет — dnsmasq ещё не выдавал адресов в эту загрузку)"
fi
sub "кто в сети СЕЙЧАС (ARP на клиентских мостах)"
if [ -f "$ENODIA_DIR/lease-lib.sh" ]; then . "$ENODIA_DIR/lease-lib.sh"; fi
if command -v neigh_pairs >/dev/null 2>&1; then
    neigh_pairs | sort -n
    sub "в сети, но БЕЗ АРЕНДЫ (адрес задан на самом устройстве)"
    # Печатаем разностью, а не «глазами»: именно эти строки список устройств не показывал вовсе
    # до 04.09.2026, и именно их не хватало, когда человек говорит «телевизора в панели нет».
    _dnb=$(neigh_pairs | while IFS='	' read -r _ni _nm; do
        awk -v w="$_ni" '$3==w{f=1} END{exit f?0:1}' /tmp/dhcp.leases 2>/dev/null || printf '%s\t%s\n' "$_ni" "$_nm"
    done)
    [ -n "$_dnb" ] && printf '%s\n' "$_dnb" || echo "(таких нет — у всех клиентов есть аренда)"
else
    echo "(нет lease-lib.sh — обновите установку)"
fi

sec "DNS (dnsmasq)"
# КАТАЛОГОВ ДВА (грабля проекта): /etc — персист, /tmp — живой, init копирует /etc→/tmp
# аддитивно и без чистки. Показывать один — значит не заметить ровно ту половину расхождения,
# из-за которой правило «включилось, а выключиться не смогло» (или наоборот).
for _dd in /etc/dnsmasq.d /tmp/dnsmasq.d; do
    sub "$_dd/ (наши файлы)"
    ls -la "$_dd/" 2>/dev/null | grep -E "awg|upstream|^-.*[0-9][0-9]-" || echo "(наших файлов нет)"
done
sub "00-upstream.conf (форвард upstream в туннель)"
showf /etc/dnsmasq.d/00-upstream.conf
# ТРЕТЬЯ копия ответа для server-host (dns-lib.sh::seed_hosts_put). Её отсутствие означает, что
# несущая ПО ИМЕНИ не встанет при мёртвом DNS, а лишняя/устаревшая строка прибивает имя к чужому
# адресу сильнее любого сида: Go-демоны (xray, hysteria) читают hosts ДО резолвера.
sub "сид server-host в /etc/hosts"
grep -F "# awg-seed" /etc/hosts 2>/dev/null || echo "(наших строк нет)"
sub "счётчики доменов"
# ОБА хвоста `grep -c` тут стреляли (грабля проекта, оба конца): на СУЩЕСТВУЮЩЕМ файле с нулём
# совпадений busybox печатает `0` и возвращает код 1 ⇒ `|| echo 0` дописывал ВТОРОЙ ноль
# отдельной строкой; на ОТСУТСТВУЮЩЕМ файле grep не печатает ничего ⇒ `|| true` оставлял поле
# пустым. Оба варианта видел на живом BE7000 08.08.2026. Считаем через гард числа.
dom_count() {   # число строк ipset= в файле; нет файла = 0
    [ -f "$1" ] || { echo 0; return 0; }
    _dc=$(grep -c '^ipset=' "$1" 2>/dev/null); case "$_dc" in ''|*[!0-9]*) _dc=0 ;; esac
    echo "$_dc"
}
echo "awg-domains: $(dom_count /etc/dnsmasq.d/enodia-domains.conf)"
echo "awg-custom:  $(dom_count /etc/dnsmasq.d/enodia-custom.conf)"
sub "dnsmasq запущен? (процесс + аргументы)"
# Матч ПО cmdline, а не `ps | grep dnsmasq`: тот ловил init-скрипт (`/bin/sh /etc/rc.common
# /etc/init.d/dnsmasq`) и обрезал строку на ширине терминала ⇒ аргументов демона, ради которых
# всё и печаталось, в артефакте не было НИ РАЗУ.
# Матчим ПЕРВЫЙ ТОКЕН cmdline (сам исполняемый файл), а не всю строку: подстрочный матч
# `*/dnsmasq *` ловит любой процесс, у которого «/dnsmasq» встретилось в АРГУМЕНТАХ — на живом
# роутере в эту сеть попал даже `sed -n /dnsmasq запущен/p`, которым читали этот самый дамп.
_dmq=""
for _p in /proc/[0-9]*; do
    [ -r "$_p/cmdline" ] || continue
    _cl=$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline")
    case "${_cl%% *}" in
        */dnsmasq|dnsmasq) echo "pid ${_p#/proc/}: $_cl"; _dmq="$_cl" ;;
    esac
done
[ -n "$_dmq" ] || echo "(демон dnsmasq НЕ найден среди процессов?!)"
sub "какие каталоги dnsmasq РЕАЛЬНО читает (conf-dir из его -C файла)"
# ЕДИНСТВЕННЫЙ способ узнать это без догадок: путь до сгенерённого конфига стоит в argv демона
# (-C), а conf-dir — внутри него. Без этой строки «правило есть в /etc, а в ядре пусто»
# неотличимо от «dnsmasq наш каталог вообще не читает», и разбор упирается в стену.
_dmc=""
case "$_dmq" in *" -C "*) _dmc=${_dmq#*" -C "}; _dmc=${_dmc%% *} ;; esac
if [ -n "$_dmc" ] && [ -f "$_dmc" ]; then
    echo "конфиг демона: $_dmc"
    grep -E '^(conf-dir|conf-file|addn-hosts)' "$_dmc" 2>/dev/null || echo "(conf-dir в нём не задан — каталоги не подключены!)"
    # ВЕРДИКТ словами. Замерено на BE7000 (ROM 1.1.38): conf-dir РОВНО ОДИН — /tmp/dnsmasq.d,
    # то есть /etc/dnsmasq.d демон не читает вовсе, это ПЕРСИСТ, который стоковый init копирует
    # в /tmp на буте. Без этой строки «файл лежит в /etc, а правила нет» читается как мистика —
    # хотя ответ ровно здесь: до живого каталога правка не доехала.
    if grep -q '^conf-dir=.*etc/dnsmasq\.d' "$_dmc" 2>/dev/null; then
        echo "⇒ /etc/dnsmasq.d демон читает НАПРЯМУЮ"
    else
        echo "⇒ /etc/dnsmasq.d демон НЕ читает: это персист, в живой /tmp его копирует init на буте"
        echo "  (правка только в /etc без рестарта dnsmasq = правила в ядре НЕТ)"
    fi
else
    grep -hE '^(conf-dir|conf-file)' /var/etc/dnsmasq.conf.* 2>/dev/null || echo "(конфиг демона не найден)"
fi
sub "ДОМЕННЫЕ ПРАВИЛА: заявлено в dnsmasq → лежит ли в ядре"
# САМЫЙ ЧАСТЫЙ вопрос тестеров — «правило по домену не работает», и до сих пор дамп на него не
# отвечал: он печатал ЧИСЛО строк, но ни самих строк, ни того, доехали ли адреса до набора.
# Набор наполняет ТОЛЬКО dnsmasq по ответам, которые прошли через него, поэтому проверка
# двухступенчатая, и обе ступени нужны, чтобы различить ТРИ разных диагноза:
#   было 0 → стало >0 : строка рабочая, просто НИКТО не резолвил домен через наш dnsmasq
#                       (устройство со своим DNS — AdGuard/DoH; лечится upstream'ом на роутер);
#   было 0 → 0 при живом резолве : строка НЕ ПРИМЕНЯЕТСЯ (каталог не читается, либо домен
#                       заявлен дважды и dnsmasq кладёт адрес в ОДИН набор — грабля проекта);
#   было >0            : правило живо, причину искать в маршрутизации, а не в DNS.
# ПОБОЧНЫЙ ЭФФЕКТ ОСОЗНАННЫЙ: проба резолвит домен и тем самым наполняет набор — то есть дамп
# слегка «лечит» то, что измеряет. Поэтому печатаем ОБА числа: в следующем артефакте набор
# будет непустым, и без колонки «было» разбор ушёл бы по ложному следу.
_dtmp=/tmp/enodia-dump-dom.$$
: > "$_dtmp"
for _dmf in /etc/dnsmasq.d/enodia-custom.conf /etc/dnsmasq.d/enodia-domains.conf \
            /etc/dnsmasq.d/[0-9][0-9]-*.conf /tmp/dnsmasq.d/[0-9][0-9]-*.conf; do
    [ -f "$_dmf" ] || continue
    grep '^ipset=' "$_dmf" 2>/dev/null >> "$_dtmp"
done
if [ -s "$_dtmp" ]; then
    echo "всего строк ipset=: $(grep -c . "$_dtmp" 2>/dev/null || echo 0)   (проверяем первые 6)"
    _i=0
    while [ "$_i" -lt 6 ]; do
        _i=$((_i+1))
        _ln=$(awk -v n="$_i" 'NR==n{print; exit}' "$_dtmp")
        [ -n "$_ln" ] || break
        # ipset=/дом[/дом...]/сет[,сет] — сеты это ПОСЛЕДНИЙ сегмент, остальное домены.
        _rest=${_ln#ipset=/}
        _sets=${_rest##*/}; _doms=${_rest%/*}
        _d1=${_doms%%/*}; _s1=${_sets%%,*}
        _was=$(ipset list -t "$_s1" 2>/dev/null | grep 'Number of entries' | awk '{print $NF}')
        [ -n "$_was" ] || _was="нет набора"
        # Первый адрес берём ПОСЛЕ строки Name: — до неё busybox печатает адрес САМОГО резолвера.
        _ip=$(nslookup "$_d1" 2>/dev/null | awk '/^Name:/{f=1} f&&/^Address /{print $3; exit}')
        _now=$(ipset list -t "$_s1" 2>/dev/null | grep 'Number of entries' | awk '{print $NF}')
        [ -n "$_now" ] || _now="-"
        if [ -n "$_ip" ] && ipset test "$_s1" "$_ip" >/dev/null 2>&1; then _v="В НАБОРЕ ✔"
        elif [ -z "$_ip" ]; then _v="НЕ РЕЗОЛВИТСЯ (нет A-записи или DNS мёртв)"
        else _v="НЕ В НАБОРЕ ✘ — правило по этому домену НЕ РАБОТАЕТ"; fi
        echo "$_d1 → $_s1: было $_was, стало $_now, резолв ${_ip:-—} ⇒ $_v"
    done
else
    echo "(строк ipset= нет вовсе — доменных правил не заявлено)"
fi
rm -f "$_dtmp"
sub "ЖИВАЯ проба dnsmasq: nslookup ya.ru (busybox шлёт на систему = dnsmasq)"
# Таймаут-гард: если dnsmasq молчит (upstream в дохлом туннеле) — nslookup сам отвалится ~2с×2.
nslookup ya.ru 2>&1 | head -8
sub "upstream МИМО dnsmasq: DoH к 1.1.1.1 по IP (жив ли путь до резолвера)"
# Отделяет «dnsmasq мёртв» от «путь до upstream мёртв»: если тут ответ есть, а nslookup молчит —
# проблема в dnsmasq/его форварде; если и тут пусто — мёртв прямой/туннельный путь до DNS.
# `-k` здесь ОБЯЗАТЕЛЕН, иначе диагностика врёт на старых сборках: на AX3600 (ядро 4.4, CA-бандл
# Feb 2023) строгий curl даёт rc=60 при полностью живом пути до резолвера — в дампе это читалось бы
# как «мёртв прямой/туннельный путь до DNS», то есть ровно наоборот. Строку ниже (через dns-lib)
# оставляем как есть: она показывает, что видит САМ фолбэк резолва.
curl -sk --max-time 6 'https://1.1.1.1/dns-query?name=ya.ru&type=A' -H 'accept: application/dns-json' 2>/dev/null | head -c 400; echo
sub "тот же DoH, но ПРИНУДИТЕЛЬНО через WAN (так ходит фолбэк резолва — dns-lib doh_ips)"
# Разделяет «интернета нет вовсе» и «прямой путь до резолвера завёрнут в мёртвый туннель»: именно
# второе прятало отказ подъёма резервных серверов до 01.08.2026 (ГРАБЛЯ №2 в шапке dns-lib.sh).
# Пусто ЗДЕСЬ при живом ответе выше = наоборот, мёртв провайдерский путь, а туннель несёт.
if [ -f "$ENODIA_DIR/dns-lib.sh" ]; then
    . "$ENODIA_DIR/dns-lib.sh"
    echo "WAN-dev: $(_dnslib_wan 2>/dev/null || echo '?')  →  $(doh_ips ya.ru '' 2>/dev/null | tr '\n' ' ')"
else
    echo "(нет dns-lib.sh — старая установка)"
fi
sub "/etc/resolv.conf"
cat /etc/resolv.conf 2>/dev/null

sec "СОСТОЯНИЕ (persist-файлы в ENODIA_STATE — несекретные)"
_dp_act2=$(cat "$ENODIA_STATE/.active" 2>/dev/null | tr -d '\r')   # пустой файл = «неизвестно», см. выше
echo "Активный конфиг (.active): ${_dp_act2:-?}"
for f in .vpn-off .failover-mode .failover-home .full-tunnel .bypass-ips .bypass-dst \
         .bypass-ifaces .bypass-guest .fullvpn-ips .fullvpn-ifaces \
         .fullvpn-guest .iplist.count; do
    showf "$ENODIA_STATE/$f"
done
sub "Wi-Fi: какая сеть на каком интерфейсе (правила .bypass-ifaces/.fullvpn-ifaces ставятся по wlN)"
# Без этой таблицы строки хранилищ выше нечитаемы: сток ПЕРЕКЛЕИВАЕТ пары ifname↔SSID при правке
# Wi-Fi (04.08.2026 трёхдиапазонный режим увёл основную сеть с wl0 на wl2 — и вместе с ней всех
# клиентов мимо туннеля). Именно здесь видно, на какую сеть правило приземлилось НА САМОМ ДЕЛЕ.
if [ -f "$ENODIA_DIR/wifi-lib.sh" ]; then
    . "$ENODIA_DIR/wifi-lib.sh"
    for _di in $(wifi_iface_list); do
        echo "  $_di  ->  $(wifi_ssid_of "$_di" 2>/dev/null || echo '?')"
    done
else
    echo "(нет wifi-lib.sh — старая установка)"
fi
sub "Wi-Fi: клиенты в эфире (скорость линка / стандарт / ширина / RSSI)"
# ЗАЧЕМ в диаг-архиве. Половина жалоб «медленно» и «отваливается» — это радио, а не туннель:
# клиент на 2.4 ГГц с HT20, RSSI -75 и потолком 86 Мбит/с ведёт себя как «сломанный VPN».
# Различить это по нашим логам невозможно, а спрашивать у человека бесполезно.
# Верб именно `tsv`: `text` у этого движка нет, он вернул бы usage и код 1 — секция была бы пуста.
# MAC маскирует общий redact() ниже по конвейеру, своего маскировщика тут не заводим.
if [ -f "$ENODIA_DIR/wifi-stats.sh" ]; then
    sh "$ENODIA_DIR/wifi-stats.sh" tsv 2>&1 | head -40
else
    echo "(нет wifi-stats.sh — старая установка)"
fi
sub "iplist.conf (источник списка IP — несекретно)"
showf "$ENODIA_STATE/iplist.conf"

sec "ВХОД В ПАНЕЛЬ (форма входа, сессии, пауза после неудач)"
# ЗАЧЕМ ЭТА СЕКЦИЯ. С 03.09.2026 вход держит НАШ код, а не uhttpd: хэш пароля в .panel-pass, сессии
# в .totp-sessions, пауза после неудач — в /tmp. Дамп присылают ровно тогда, когда «панель не
# пускает» / «просит какой-то код», а ответить на это прежними секциями было НЕЧЕМ. Сетевых проб
# здесь нет намеренно (web-ui.sh status при открытом WAN лезет за внешним адресом) — только факты
# с роутера. Срез второго фактора спрашиваем у ВЛАДЕЛЬЦА (totp.sh), своей копии тут не заводим.
if [ -f "$ENODIA_DIR/totp.sh" ]; then
    echo "totp.sh status: $(sh "$ENODIA_DIR/totp.sh" status 2>&1 | grep '^{' | tail -1)"
else
    echo "(нет totp.sh — установка старее формы входа)"
fi
# СХЕМА ХЭША — не украшение: `openssl passwd -6` есть не на всякой прошивке (замер 03.09.2026:
# BE7000 1.1.1l — есть, AX3600 1.0.2q — НЕТ, и пароль там лежит MD5-crypt `$1$`). Роутер бывает
# выставлен наружу, и «чем именно закрыт вход» обязано быть видно. Печатаем ТОЛЬКО префикс схемы,
# сам хэш не читаем никогда.
_dmp_sch=$(cut -d'$' -f2 "$ENODIA_STATE/.panel-pass" 2>/dev/null | head -1)
if [ -n "$_dmp_sch" ]; then _dmp_sch="\$$_dmp_sch\$"; else _dmp_sch="(пароля нет — панель не поднимется)"; fi
echo "Схема хэша пароля: $_dmp_sch  (openssl прошивки: $(openssl version 2>/dev/null | cut -d' ' -f1-2))"
# СРОКИ ВХОДОВ И ОТМЕТКА ЧАСОВ. Новый режим отказа звучит как «вошёл после ребута — минут через
# десять выкинуло»: RTC нет, часы на буте врут и прыгают вперёд, а метка «истекает» абсолютная.
# Чинит это totp_sess_clock_fix, и диагностируется оно ровно этими двумя строками: сколько каждой
# сессии осталось жить и с какой базы считали. Хэши сессий НЕ печатаем — это ключи от панели.
sub "Входы в панель (сколько осталось жить)"
# ОДНА awk-программа В ОДНУ СТРОКУ и БЕЗ strftime: у busybox её нет вовсе, а перевод строки внутри
# кавычек программу рвёт («unterminated string») — первая редакция этой секции не работала НИ
# ОДНОЙ веткой и уже уехала в enodia-diag.py. Даты не печатаем: важен ОСТАТОК, а «вошли когда» и
# так видно в панели. Хэши сессий не печатаем никогда — это ключи от панели.
if [ -s "$ENODIA_STATE/.totp-sessions" ]; then
	# Часы, а не только сутки: со снятой галочкой «Запомнить меня» сессия живёт 12 часов, и
	# «осталось 0 суток» неотличимо от протухшей строки — а это штатный режим, а не поломка.
	# clock-raw: остаток жизни считаем ГОЛОЙ разностью — метка сессии АБСОЛЮТНАЯ и рождается не
	# «после загрузки», так что age_since тут неприменим. В первые ~13 минут после ребута цифра
	# завышена на величину будущего скачка часов; рядом печатается отметка, по которой это видно.
	awk -F'\t' -v n="$(date +%s)" '{ lv=$6+0; if(lv<1) lv=2; d=$2-n; if (d <= 0) printf "уровень %s · ИСТЕКЛА · %s\n", lv, substr($4,1,40); else if (d < 172800) printf "уровень %s · осталось %s ч · %s\n", lv, int(d/3600), substr($4,1,40); else printf "уровень %s · осталось %s суток · %s\n", lv, int(d/86400), substr($4,1,40) }' "$ENODIA_STATE/.totp-sessions" 2>/dev/null
else echo "(входов нет)"; fi
echo "Отметка часов (/tmp/.enodia-clock-base): $(cat /tmp/.enodia-clock-base 2>/dev/null || echo "нет — ещё не бежал web-ui.sh start")  сейчас=$(date +%s) аптайм=$(dmp_uptime)"
# Файл паузы — ПО СТРОКЕ НА ИСТОЧНИК: "адрес неудач разблокировка отметка". Печатаем блоком, а не
# в одну строку: строк бывает несколько, и слипшиеся они нечитаемы. За panel-tls источник у всех
# один (адрес терминатора) — по этому и видно, пришли снаружи или из локалки.
sub "Пауза после неудач (/tmp/.enodia-totp-fail: адрес · неудач · разблокировка · отметка)"
if [ -s /tmp/.enodia-totp-fail ]; then cat /tmp/.enodia-totp-fail 2>/dev/null; else echo "(пусто — счётчик чист)"; fi
echo "Флаги: .panel-tls=$( [ -f "$ENODIA_STATE/.panel-tls" ] && echo да || echo нет )  .panel-wan=$( [ -f "$ENODIA_STATE/.panel-wan" ] && echo да || echo нет )"
sub "Строка запуска uhttpd панели"
# ` -c ` в ней = панель ЕЩЁ под HTTP-Basic: либо обновление доехало не целиком (новые CGI + старый
# web-ui.sh), либо cron-овский start после обновления ещё не бежал. Заодно видно docroot — в
# раскладке `full` он не на флеше, и «панель не отдаёт наши файлы» объясняется прямо здесь.
_dmp_wpid=$(cat /tmp/enodia-uhttpd-web.pid 2>/dev/null)
if [ -n "$_dmp_wpid" ] && [ -d "/proc/$_dmp_wpid" ]; then
    tr '\0' ' ' 2>/dev/null < "/proc/$_dmp_wpid/cmdline"; echo
else
    echo "(uhttpd панели не запущен — pid-файл /tmp/enodia-uhttpd-web.pid пуст или процесса нет)"
fi

sec "СЕКРЕТНЫЕ ФАЙЛЫ — ТОЛЬКО НАЛИЧИЕ / ПРАВА (содержимое НЕ читаем)"
echo "(режим / владелец / размер / имя)"
showmeta "$ENODIA_STATE/awg.conf"
showmeta "$ENODIA_STATE/awg0.conf"
showmeta "$ENODIA_STATE/amnezia_for_awg.conf"
showmeta "$ENODIA_STATE/notify.conf"
showmeta "$ENODIA_STATE/.subs"
showmeta "$ENODIA_STATE/.sub-names"
showmeta "$ENODIA_STATE/.cfg-names"   # свои имена конфигов (cfg-names.sh): в бэкапе — с конфигами; содержимое — имена человека
showmeta "$ENODIA_STATE/.sub-picks"
# Вход в панель: только режим/размер. Содержимое — ключи от панели (хэш пароля вскрывают офлайн,
# .totp-recovery = коды восстановления, .totp-sessions = живые сессии), и в дамп оно не едет.
# Здесь важен сам ФАКТ: нет .panel-pass ⇒ панель не поднимется вовсе, а «войти» будет нечем.
showmeta "$ENODIA_STATE/.panel-pass"
showmeta "$ENODIA_STATE/.totp"
showmeta "$ENODIA_STATE/.totp-recovery"
showmeta "$ENODIA_STATE/.totp-sessions"
if [ -d "$ENODIA_STATE/configs" ]; then
    for c in "$ENODIA_STATE"/configs/*.conf; do [ -e "$c" ] && showmeta "$c"; done
fi

sec "ПИСЬМА: ВЫКЛЮЧАТЕЛЬ И ПОВОДЫ"
# «Почему письмо не пришло» — первый вопрос дампа про почту: выключены ли письма целиком (.notify-off) и какие поводы
# выключены человеком («О чём писать»). Поводы и их файл знает events.sh — спрашиваем его, своей копии разбора нет.
# Старый events.sh верба не знает — так и сказано. Хвост лога отправок — в логах (enodia-notify-event).
if [ -f "$ENODIA_STATE/.notify-off" ]; then echo "письма: выключены целиком (.notify-off)"; else echo "письма: включены"; fi
_dmp_cls=$( [ -f "$ENODIA_DIR/events.sh" ] && sh "$ENODIA_DIR/events.sh" classes 2>/dev/null | tr '\n' ' ')
echo "поводы: ${_dmp_cls:-(events.sh не ответил вербом classes — установка старше шага 7b)}"

sec "ЛОКИ / СТЕЙТ В /tmp"
# enodia-heal-kick.tries — сколько раз сторож будил heal ради пересоздания awg0. Строка отвечает
# на «почему awg0 не возвращается»: дойдя до потолка, сторож будит heal раз в час, а не раз в две
# минуты, и молчание в логе — это НЕ поломка сторожа (см. HEAL_KICK_TRIES в watchdog.sh).
# СОСЕДИ ОБЯЗАТЕЛЬНЫ: по одному счётчику пробуждений «почему VPN не поднимается» не собрать —
# нужны причина последнего прогона heal, вердикт сторожа, эпизод перебора и «видели ли awg0 живым»
# (по ним отличается «упало» от «не поднималось ни разу»). Ревью 3, 06.09.2026.
# enodia-heal.skipped — «был прогон heal, но он вышел по switching-локу»: именно этот файл решает,
# советует ли письмо «проверь cron» — без него разбор не объяснит, почему диагноз был таким.
# enodia-domwarm.stamp — троттл прогрева доменных правил (общий у heal и сторожа): дамп ОБЯЗАН
# отвечать на «почему доменное правило мертво», а без отметки видно только «прогрев не бежал».
# enodia-proto-install.lock — идёт смена набора протоколов: объясняет, почему подсистемы в этот
# момент вели себя тихо. enodia-byedpi-sweep.lock — идёт браузерный свип стратегий, и пока он
# свеж, сторож в byedpi НЕ вмешивается: без строки разбор не поймёт, почему тик молчал.
# enodia-subs-update.lock и enodia-gh-update.lock — «обновление подписок/скриптов ИДЁТ»: по ним
# CGI панели отказывает во втором запуске, и без строки разбор читает отказ как поломку кнопки.
# Первые нашла проверка C84 (файл-состояние в /tmp, о котором договорились два скрипта); у
# gh-update акторы в ОДНОМ файле (форграунд против фоновой задачи), его дописали руками.
# .enodia-carrier-up.stamp — «когда несущая последний раз везла» (пишет clock-lib, читают сторож
# для boot-grace и doh-lib); .enodia-support-active — открыт ли удалённый доступ. Точка в начале
# имени прятала их от первой редакции C84, а решения по ним принимают трое (ревью 5).
# enodia-pkg-install.lock — идёт установка кода из пакета (pkg-install.sh): по нему отказывают смена
# раскладки и вторая установка — без строки разбор читает «отказано» как поломку кнопки.
# enodia-dns-reload — снят сид сервера несущей (dns-lib.sh::seed_host_clear), и следующий DNS-сеттер обязан ПЕРЕЗАПУСТИТЬ
# dnsmasq даже при том же upstream (HUP `address=` не перечитывает). Висит — значит сеттер после снятия не звали: имя сервера
# ещё может отдаваться прежним адресом.
for l in enodia-heal.lock enodia-heal.reason enodia-heal.skipped enodia-heal-kick.tries enodia-heal-kick.stamp \
         enodia-heal-kick.said enodia-heal-kick.mailed enodia-heal-kick.cfg enodia-switching.lock enodia-watchdog.lock enodia-watchdog.pid \
         enodia-watchdog.state enodia-watchdog.xstate enodia-failover.stamp enodia-failover.backoff \
         enodia-failover-episode enodia-awg0.seen enodia-awg0.firstup \
         enodia-domwarm.stamp enodia-proto-install.lock enodia-byedpi-sweep.lock \
         enodia-subs-update.lock enodia-gh-update.lock enodia-pkg-install.lock enodia-uninstall.mode \
         enodia-wanout.valve enodia-wanout.event enodia-wanout.sweep enodia-dns-reload \
         .enodia-carrier-up.stamp .enodia-support-active; do
    if [ -e "/tmp/$l" ]; then
        # mkdir-ЛОК — КАТАЛОГ, и `cat` по нему пуст: держатель лежит внутри, в `<lock>/pid`
        # (так делают packages.sh, proto-install.sh и subs-update.sh). Без этой ветки строка
        # выходила «есть -> » и теряла единственное, ради чего лок в разборе и смотрят (ревью 5).
        if [ -d "/tmp/$l" ]; then
            echo "/tmp/$l: есть (каталог-лок)$( [ -s "/tmp/$l/pid" ] && echo " -> держит pid $(cat "/tmp/$l/pid" 2>/dev/null)" )"
        else
            echo "/tmp/$l: есть$( [ -s "/tmp/$l" ] && echo " -> $(cat "/tmp/$l" 2>/dev/null)" )"
        fi
    else
        echo "/tmp/$l: нет"
    fi
done
# enodia-slot-down.<id> — сторож объявил «доп-выход №id недоступен» (внутри — сервер выхода); письмо «снова работает» ждёт именно
# её. Номеров заранее не знаем — маской, и молчим, когда эпизодов нет.
for l in /tmp/enodia-slot-down.*; do [ -f "$l" ] && echo "$l: есть -> $(cat "$l" 2>/dev/null)"; done
# ВЕРДИКТ ВЛАДЕЛЬЦА рядом с его сырьём: «дом / резерв / прямой и вернётся ли» — тот же ответ, что видит
# шапка панели. Собирать его заново по файлам выше разбор не должен (своя сборка разошлась бы с тиком).
# Гард — по строке верба, как в cgi-bin/status: старая копия сторожа на `standing` прогнала бы тик.
if [ -f "$ENODIA_DIR/watchdog.sh" ] && grep -q '^\[ "\$1" = standing \]' "$ENODIA_DIR/watchdog.sh"; then
    echo "вердикт сторожа (watchdog.sh standing): $(sh "$ENODIA_DIR/watchdog.sh" standing 2>/dev/null | tr '\n' ' ')"
else
    echo "вердикт сторожа: верба standing нет (старая копия watchdog.sh)"
fi

sec "CRON (автозапуск — без него после ребута не поднимется)"
cat /etc/crontabs/root 2>/dev/null || echo "(crontab пуст?!)"

sec "РАСКЛАДКА (в каком режиме стоит система и откуда идёт cron)"
# ЗАЧЕМ ЭТА СЕКЦИЯ. Дамп присылают, когда «что-то не работает», а раскладок теперь три: всё на
# флеше роутера (data), бинари на накопителе (bins) и ВСЁ на накопителе (full). В последней
# случае каталог кода — не /data/usr/app/enodia, и без этой строки разбирающий будет искать
# файлы там, где их нет, а «cron пуст» прочитает как «установка сломана».
# Спрашиваем ВЛАДЕЛЬЦА (boot.sh paths/status) — своей копии рассуждения «где сейчас код» дамп
# держать не вправе: она разошлась бы с бутстрапом ровно тогда, когда важнее всего.
# Сам $ENODIA_BOOT объявлен В ШАПКЕ — там же, где разбор путей: две копии объявления разъехались
# бы ровно так, как это уже случалось с каталогом кода.
if [ -f "$ENODIA_BOOT/boot.sh" ]; then
    sh "$ENODIA_BOOT/boot.sh" status 2>&1
    # Хук вставки на ходу: /etc/hotplug.d — ramfs, и его отсутствие после ребута нормально
    # ровно до первого тика cron. Пустая строка тут означает «тика ещё не было».
    [ -f /etc/hotplug.d/block/99-enodia-usb ] && echo "hotplug-хук: на месте" || echo "hotplug-хук: нет (до первого тика cron это норма)"
else
    echo "(бутстрапа нет — установка старее фичи режимов; код на флеше роутера)"
fi
# «ВКЛЮЧЁН, НО НЕ НАЙДЕН» — ОТДЕЛЬНОЙ СТРОКОЙ, и это не дубль строки выше. Бутстрап говорит о
# накопителе только в раскладке `full` (там без него не найти сам код). В раскладке `bins`
# resolve успешен — код на флеше, — и строка выше честно скажет «бинари на накопителе», хотя
# накопителя сейчас нет и ни xray, ни hysteria не поднимутся. Разбирающий прочитает это как
# «бинари на месте» и пойдёт искать причину не там. Ответ у вопроса ОДИН владелец
# (store-lib.sh::store_state) — печатаем его, своей копии условия дамп не держит.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
if command -v store_state >/dev/null 2>&1; then
    case "$(store_state)" in
        ok)   echo "Хранилище: включено и доступно ($(store_root))" ;;
        lost) echo "Хранилище: ВКЛЮЧЕНО, НО НЕ НАЙДЕНО — бинари протоколов с него не запустятся" ;;
        *)    echo "Хранилище: не используется" ;;
    esac
else
    echo "Хранилище: (store-lib.sh старее фичи — состояние неизвестно)"
fi
# ПРАВА НА НАШИ КАТАЛОГИ — В ДАМП. Замер 02.09.2026 (BE7000): после круга exFAT → флеш → ext4
# каталоги `enodia`, `web` и `web/cgi-bin` оказались 0777, и проба из-под `nobody` СОЗДАЛА файл
# в cgi-bin — а CGI оттуда uhttpd запускает ОТ ROOT. Права приезжают с ФС, которая их не хранит,
# и на той, которая хранит, становятся настоящими; чинит это `store-lib.sh::harden_perms` на
# установке и после каждого переезда. Но дамп обязан УМЕТЬ ЭТО ПОКАЗАТЬ: без строки ниже
# разбирающий не отличит «права восстановлены» от «мы просто не смотрели».
sub "права на каталоги (0777 = приехало с exFAT, лечится переустановкой скриптов)"
for _pd in "$ENODIA_DIR" "$ENODIA_DIR/web" "$ENODIA_DIR/web/cgi-bin" "$ENODIA_STATE" "$ENODIA_BIN"; do
    showmeta "$_pd"
done

sec "БИНАРНИКИ + ВЕРСИИ (что реально установлено и ГДЕ лежит)"
# Секция знала ДВА бинаря из десяти и искала их по ЖЁСТКОМУ пути в $ENODIA_DIR. Два следствия,
# оба пойманы на живом роутере 17.08.2026:
#   * установка «только панель» (byedpi+hev+nfqws) давала «(бинарников нет)» — при том, что
#     двадцатью строками ниже, в разбивке du, эти же файлы перечислены поимённо. Артефакт
#     противоречил сам себе, а читатель делал вывод «не доехал payload»;
#   * с внешним накопителем (`.bin-store`) тяжёлые бинари живут НЕ в $ENODIA_DIR ⇒ «нет» соврало бы
#     и про xray/hysteria. «Где лежит бинарь» — вопрос с ОДНИМ владельцем (store-lib.sh), своей
#     копии `[ -x "$ENODIA_DIR/…" ]` дамп держать не вправе.
# Список имён ЯВНЫЙ (идиома RAM_LOGS в clean.sh): вывести его из кода нельзя — половина имён
# приезжает из bin-manifest.txt, которого у кода, поставленного не пакетом, может не быть. Новый бинарь дописывает СЕБЯ.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path  >/dev/null 2>&1 || bin_path()  { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_where >/dev/null 2>&1 || bin_where() { [ -x "$ENODIA_BIN/$1" ] && printf 'router'; }
# «В каком КАТАЛОГЕ» и «на каком ТОМЕ» — РАЗНЫЕ ответы, и дамп читает человек: в раскладке
# «всё на накопителе» каталог бинарей и ЕСТЬ накопитель, а bin_where честно говорит «router»
# про файл на флешке. Печатаем ТОМ. Шим на старую библиотеку: «не на накопителе» = как было.
command -v bin_on_store >/dev/null 2>&1 || bin_on_store() { return 1; }
# Закрепление — ВТОРОЙ ответ на «почему он лежит именно тут». Без него дамп с включённым
# накопителем показывает «xray · роутер» и не объясняет НИЧЕГО: читатель решает, что переезд
# сломался, и лечит здоровое. Шим на старую библиотеку: «не закреплён».
command -v bin_pinned >/dev/null 2>&1 || bin_pinned() { return 1; }
DMP_BINS="amneziawg-go awg xray hysteria hev byedpi nfqws https-dns-proxy dot-proxy panel-tls"
# СВЕЖА ЛИ СБОРКА — вопрос с одним владельцем (gh-update.sh bin-status: sha стоящего против манифеста, без сети). Без него
# дамп отвечал «какая версия кода», но не «какая сборка бинаря»: жалоба «DoT уводит на DoH» на dot-proxy до 1.2 и после
# выглядела одинаково. Прежний апдейтер верба не знает — тогда колонки нет, а не выдуманный ответ.
_dmp_bst=""; [ -f "$ENODIA_DIR/gh-update.sh" ] && _dmp_bst=$(sh "$ENODIA_DIR/gh-update.sh" bin-status $DMP_BINS 2>/dev/null)
_dmp_any=0
for _b in $DMP_BINS; do
    _w=$(bin_where "$_b")
    [ -n "$_w" ] || continue
    if bin_on_store "$_b"; then _w=store; fi
    _dmp_any=1
    _p=$(bin_path "$_b")
    # Размер и дата — из ls самого файла: по ним видно и «доехал ли целиком» (обрыв закачки), и
    # «когда его положили» (после обновления или с прошлой установки).
    # ШИРИНУ printf задаём только ASCII-полям: busybox считает её В БАЙТАХ, и «накопитель» (20 Б)
    # с «роутер» (12 Б) разъехались бы колонкой при одинаковой длине на экране. Место жительства —
    # ПОСЛЕДНИМ полем: рваный хвост не виден, рваная середина ломает всю таблицу.
    # Сборка — словами владельца: свежая / устарела (стоит → доступна) / сверить не с чем; «работает прежняя» — файл заменили
    # под живым демоном. Хвостом строки: как и место жительства, поле кириллическое и переменной длины.
    _bst=$(printf '%s\n' "$_dmp_bst" | awk -F'\t' -v n="$_b" '$1 == n {
        s = ($2 == "current") ? "свежая " $3 : ($2 == "outdated") ? "УСТАРЕЛА " ($3 == "" ? "?" : $3) " → " $4 : ($2 == "unknown") ? "сборка не сверена" : ""
        if ($5 == "old") s = s " · РАБОТАЕТ ПРЕЖНЯЯ до перезапуска"
        if (s != "") print " · " s; exit }')
    printf '%-16s %s  %s\n' "$_b" \
        "$(ls -l "$_p" 2>/dev/null | awk '{printf "%10s байт  %s %s %s", $5, $6, $7, $8}')" \
        "$( [ "$_w" = store ] && echo '· накопитель' || echo '· роутер' )$( bin_pinned "$_b" && echo ' · закреплён' )$_bst"
done
[ "$_dmp_any" = 1 ] || echo "(бинарников нет — установка «только панель» без бутстрапа либо payload не доехал)"
# СКОЛЬКО ЖДЁМ СТАРТА — тот же вопрос, что «где лежит бинарь», только с другой стороны: с
# накопителя демон читается секундами, и «не успел» приезжает в лог как «не поднялся» (разбор
# 01.09.2026: 448 КБ/с ⇒ 8-МБ xray читается 18 с). Спрашиваем ВЛАДЕЛЬЦА (daemon-lib.sh), а не
# пересказываем числа своей копией — она разъедется.
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
if command -v daemon_wait_secs >/dev/null 2>&1; then
    printf 'ждём старта: xray %s с · hysteria %s с · byedpi %s с · hev %s с (daemon-lib.sh; потолок по носителю, за трупом не ждём вовсе)\n' \
        "$(daemon_wait_secs xray 8)" "$(daemon_wait_secs hysteria 25)" "$(daemon_wait_secs byedpi 8)" "$(daemon_wait_secs hev 6)"
else
    echo "ждём старта: daemon-lib.sh не загружен (старая установка) — фиксированные 8 с независимо от носителя"
fi
# ЛОК РАССТАНОВКИ. Живёт секунды (перенос) — в норме его тут нет вовсе. А вот ОСИРОТЕВШИЙ лок
# (движок убили на середине) виден только здесь: снаружи он выглядит как «кнопка накопителя
# отвечает „занят другой операцией“ и не проходит никогда», и без этой строки разбирать такое
# нечем. Держателя называем по pid: если процесс мёртв, движок снимет лок сам на следующем
# заходе, и это тоже видно.
if [ -d /tmp/enodia-usb.lock ]; then
    _dlp=$(cat /tmp/enodia-usb.lock/pid 2>/dev/null)
    echo "лок расстановки бинарей ЗАНЯТ: pid ${_dlp:-?} ($([ -n "$_dlp" ] && [ -d "/proc/$_dlp" ] && echo 'держатель жив' || echo 'ДЕРЖАТЕЛЬ МЁРТВ — снимется на следующем заходе'))"
fi
# `--version` спрашиваем ТОЛЬКО у тех, про кого замерено, что они его понимают: у остальных флаг
# уводит демон в работу (hev/nfqws читают argv как конфиг) или печатает usage — в дампе это мусор,
# а в худшем случае запущенный процесс. Версии прочих даёт панель из bin-manifest.txt.
for _b in amneziawg-go awg; do
    _p=$(bin_path "$_b")
    if [ -x "$_p" ]; then printf '%s: ' "$_b"; "$_p" --version 2>&1 | head -1; fi
done

sec "РЕСУРСЫ (RAM / диск / размер логов)"
awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf "RAM: %d МБ свободно из %d МБ (доступно %s)\n", f/1024, t/1024, (a==""?"?":sprintf("%d МБ", a/1024))}' /proc/meminfo 2>/dev/null
# НАШ том — по ПУТИ каталога (на BE10000 `/data` чужой), плюс /tmp = ОЗУ.
# ГАРД ЧИСЛОВОЙ (`+0`). `df` по НЕСУЩЕСТВУЮЩЕМУ пути печатает в stdout один ЗАГОЛОВОК, и
# `tail -1` отдаёт его как строку данных ($NF="on", $(NF-4)="Used"). Прежний `$(NF-4)>0`
# его НЕ отсекал: у awk сравнение нечислового поля с числом идёт как СТРОКОВОЕ, а
# "Used" > "0" истинно (замерено на busybox awk 1.25.1 31.08.2026) — отсюда «Флеш on» в
# панели и «Division by zero» в дампе. `+0` принуждает поле к числу.
_ourdf=$(df -k "$ENODIA_DIR" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{print $NF" "$1}')
_ourmp=${_ourdf% *}; _ourdev=${_ourdf#* }
for m in "${_ourmp:-/data}" /tmp; do
    # Та же формула, что в шапке дампа и у владельца (status.sh): `Use%` у df не берём.
    df "$m" 2>/dev/null | tail -1 | awk -v mp="$m" 'NF>=5 && $(NF-4)+0>0{printf "Диск %s: %.1fM своб из %.1fM (занято %.0f%%)\n", mp, $(NF-2)/1024, $(NF-4)/1024, ($(NF-4)-$(NF-2))*100/$(NF-4)}'
done
# ВСЕ настоящие тома флеша одной таблицей. Зачем: на BE10000 их ТРИ (cfg 4.7 / user 18.6 /
# plugin 29 МБ), и вопрос «сколько свободно» имеет три разных ответа — разбор чужого дампа
# начинался с гадания, о каком из них речь. Дубли (один ubifs в /data, /etc, /ini)
# схлопываем ПО УСТРОЙСТВУ, ro-образы (avail=0) и tmpfs не показываем вовсе.
sub "тома флеша (* — тот, на котором живём мы)"
df -k 2>/dev/null | awk -v od="${_ourdev:-none}" 'NR>1 && NF>=5 && $(NF-4)+0>0 && $(NF-2)+0>0 && $1!="tmpfs" && $1!="devtmpfs" && $1!="none" { if (seen[$1]++) next; printf "%s %s: %.1fM своб из %.1fM (%s)\n", ($1==od?"*":" "), $NF, $(NF-2)/1024, $(NF-4)/1024, $1 }'
our_ramlogs | while read -r _lp; do ls -l "$_lp" 2>/dev/null; done \
  | awk '{s+=$5}END{if(NR>0)printf "Логи /tmp (НАШИ): %d КБ в %d файлах\n",(s+1023)/1024,NR; else print "Логи /tmp (НАШИ): нет"}'
echo "NB: /tmp — это ОЗУ (tmpfs), занятое там вычитается из свободной памяти. Считаем ТОЛЬКО свои"
echo "    логи: рядом лежат стоковые логи Xiaomi, и они к нашему расходу ОЗУ отношения не имеют."

# «Почему флеш забит?» — тот же по частоте вопрос, что и про ОЗУ, а до 09.08.2026 дамп отвечал на
# него ОДНОЙ строкой df: «занято 92%» — и всё, дальше начинались догадки (наше это или стоковое,
# xray или логи прошивки). Разбивку не считаем сами: единственная истина «что чем занято и что
# считается мусором» — clean.sh, второй копии списков не заводим (та же причина, что у
# ram-usage.sh выше и у ramlogs-list). Верб ИМЕННО `dryrun`: он печатает топ потребителей внутри
# НАШИХ каталогов (код + состояние + бинари), корень /data (там и видно стоковый ротированный
# syslog) и кандидатов на чистку с
# размерами — и при этом НИЧЕГО НЕ УДАЛЯЕТ. Дамп обязан быть read-only; безаргументный режим
# clean.sh чистит по-настоящему, и звать его отсюда нельзя.
sub "чем занят наш том флеша (clean.sh dryrun — только показывает, не удаляет)"
if [ -f "$ENODIA_DIR/clean.sh" ]; then
    sh "$ENODIA_DIR/clean.sh" dryrun 2>/dev/null || echo "(clean.sh dryrun не отработал)"
else
    echo "(clean.sh нет — установка до разбивки места)"
fi
# NB для читателя дампа: UBIFS СЖИМАЕТ, поэтому суммы du выше и «занято» из df — РАЗНЫЕ единицы,
# вычитать одно из другого нельзя (на BE7000 замерено du 21046 КБ при df-занято 15888 КБ).
echo "NB: du (разбивка выше) — ЛОГИЧЕСКИЙ размер, df — реально занятые блоки; UBIFS жмёт, разница штатна."

# «Не забивается ли память?» — самый частый вопрос по дампу, и ОДНОЙ строкой free на него не
# ответить: MemFree штатно падает под страничный кэш и на роутере с ним всё в порядке. Судить
# можно по MemAvailable (выше) + по тому, КТО держит RSS, + по факту OOM. Разбивку не считаем
# сами — её единственная истина ram-usage.sh (та же, что в панели «Что занимает память»).
sub "кто занимает ОЗУ (ram-usage.sh)"
if [ -f "$ENODIA_DIR/ram-usage.sh" ]; then
    sh "$ENODIA_DIR/ram-usage.sh" 2>/dev/null | head -40 || echo "(ram-usage.sh не отработал)"
else
    echo "(ram-usage.sh нет — установка до разбивки ОЗУ)"
fi
sub "OOM: убивало ли ядро процессы из-за нехватки памяти"
# dmesg — единственный след OOM, и он живёт лишь с последнего ребута: если роутер уже
# перезагрузился, «пусто» здесь НЕ означает «OOM не было» (так и написано в выводе).
_oom=$(dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process|lowmemorykiller' | tail -8)
if [ -n "$_oom" ]; then
    echo "$_oom"
else
    echo "следов OOM нет (буфер dmesg живёт с последнего ребута — после перезагрузки он пуст в любом случае)"
fi

sec "ЛОГИ /tmp (хвосты по 40 строк)"
# Список ведём ПО ТОМУ ЖЕ перечню, что `clean.sh` (RAM_LOGS + пер-слотовые): дамп — это то,
# что человек присылает при разборе, и прежний список остановился на awg/xray/hysteria. На живом
# роутере с byedpi/zapret/DoH это значило, что в артефакте НЕТ логов ровно тех подсистем, из-за
# которых его и снимают (замер 04.08.2026: из 9 имён списка на роутере существовало 7, а мимо
# дампа проходило 13 реальных логов — byedpi, doh, zapret-nfqws, subs-update, support, panel-tls,
# enodia-dnsq, transport-awg-setup и пер-слотовые xray-s3/hev-s3/byedpi-s3).
# Отсутствующие файлы не печатаем вовсе (кроме «классики» ниже) — иначе полдампа = «(нет)».
# Само объявление DUMP_LOGS живёт ВЫШЕ main: тот же список — фолбэк режима archive на роутере,
# где clean.sh (владелец перечня) ещё не залит, а внутри функции он бы туда не достался.
for lg in $DUMP_LOGS; do
    [ -s "/tmp/$lg.log" ] || continue
    sub "$lg.log"
    tail -40 "/tmp/$lg.log" 2>/dev/null
done
# Пер-слотовые (у доп-выхода СВОЙ инстанс демона и свой лог) — их не было вовсе.
for i in 2 3 4; do
    for lg in xray hev hysteria byedpi; do
        [ -s "/tmp/$lg-s$i.log" ] || continue
        sub "$lg-s$i.log (доп-выход №$i)"
        tail -25 "/tmp/$lg-s$i.log" 2>/dev/null
    done
done

sec "ВНЕШНИЙ IP (тест маршрута — IP замаскированы redact)"
# Прямой = bind к WAN-iface (обход туннеля); через awg0 = bind к туннелю. IP-литерал trace вместо
# api.ipify.org — DNS-free, отвечает и на ядре 4.4 (где hostname api.ipify.org молча пустел).
printf 'Прямой IP:  '; _d=$(curl -s -k ${WANDEV:+--interface $WANDEV} --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=\([0-9.]*\).*/\1/p'); echo "${_d:-(нет ответа)}"
if ip link show awg0 >/dev/null 2>&1; then
    printf 'Через awg0: '; _v=$(curl -s -k --interface awg0 --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=\([0-9.]*\).*/\1/p'); echo "${_v:-(нет ответа через туннель)}"
fi

echo ""
echo "==================================================================="
echo "## КОНЕЦ ДАМПА"
echo "==================================================================="
}

# =============================================================================
# РЕЖИМ archive — .tar.gz со ВСЕМИ логами в stdout (кнопка «Скачать диагностику»).
# =============================================================================
# ЗАЧЕМ отдельно от текстового среза: текст отвечает на «что сейчас», а на «почему роутер
# ушёл в ребут ночью» — только логи, причём ЧУЖИЕ: наши живут в /tmp и гибнут с ним, а
# системный лог Xiaomi ротируется на флеш (/data/usr/log/messages*) и переживает перезагрузку.
# Собрать их руками может не всякий, поэтому кнопка одна и кладёт всё сразу.
#
# ТРИ ограничения, из которых вырос этот вид:
#   1. Приватность. Системный лог несёт имена сетей, имена и MAC клиентов ⇒ КАЖДЫЙ файл идёт
#      через redact(), включая распакованные архивы. Второго маскировщика в проекте нет и
#      быть не должно — CGI зовёт этот верб, а не копирует логику (см. `redact` ниже).
#   2. Память. /tmp — это ОЗУ, а на BE3600 её 176 МБ ⇒ хвосты ограничены, при нехватке
#      MemAvailable берём короткий хвост и не трогаем старые .gz (распаковка стоит дороже).
#   3. Мусор. Каталог сборки снимаем trap'ом с HUP/PIPE: клиент, оборвавший скачивание, даёт
#      SIGPIPE, а на сигнале EXIT-ловушка не срабатывает (грабля busybox) — остались бы мегабайты в ОЗУ.
# Объём считаем ОТ СВОБОДНОЙ ОЗУ, а не фиксированным числом строк: замерено на BE7000 —
# 20 000 строк × 7 файлов дают 13,6 МБ распакованных в /tmp, и это ровно та память, которой у
# BE3600 (176 МБ всего, ~40 свободных) нет. Ступени грубые намеренно: точность тут не нужна,
# нужен потолок, ниже которого сборка диагностики физически не может уронить роутер.
# Старые ротированные .gz берём только на просторной машине — свежий лог отвечает на «почему
# ребутнулся» в подавляющем большинстве случаев, а распаковка семи архивов стоит и памяти, и
# времени (CGI-таймаут uhttpd — не бесконечный).
# MEMINFO подменяем ТОЛЬКО ради проверки: ветку «мало памяти» иначе не пройти на роутере с
# гигабайтом, а именно она защищает BE3600, где архив и опаснее всего.
sys_budget() {
    _a=$(awk '/^MemAvailable:/{print $2}' "${MEMINFO:-/proc/meminfo}" 2>/dev/null)
    case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
    # Цена строки замерена на живом логе: ~100 байт ⇒ 10 000 строк это ~1 МБ на файл, и на
    # BE3600 (замер по дампу тестера — 46 МБ доступно) такой пик занимает единицы процентов.
    # Первый порог отделяет «гигабайтные» роутеры, где не жалко и полной истории с архивами.
    if   [ "$_a" -gt 131072 ]; then SYS_TAIL=20000; SYS_OLD=1   # >128 МБ: всё, включая .gz
    elif [ "$_a" -gt  32768 ]; then SYS_TAIL=10000; SYS_OLD=0   # >32 МБ: часы истории, ~2 МБ пик
    else                            SYS_TAIL=3000;  SYS_OLD=0   # тесно: только хвосты
    fi
}
OUR_TAIL=3000           # строк из каждого нашего лога (они мелкие, десятки КБ)

cmd_archive() {
    ts=$(date +%Y%m%d-%H%M%S 2>/dev/null); case "$ts" in ''|*[!0-9-]*) ts=diag ;; esac
    base="enodia-diag-$ts"
    td="/tmp/.enodia-diag-$$"
    # Только EXIT: сигнал ведёт ловушка уровня файла (`exit 141`, ниже), а её `exit` и зовёт эту уборку (C121).
    trap 'rm -rf "$td" "$ENV_SED"' EXIT
    rm -rf "$td"; mkdir -p "$td/$base/logs" "$td/$base/system" 2>/dev/null || return 1

    sys_budget; st=$SYS_TAIL; olds=$SYS_OLD

    build_env_sed
    main 2>&1 | redact > "$td/$base/dump.txt"

    # Наши логи. Перечень спрашиваем у ЕДИНСТВЕННОГО владельца списка (our_ramlogs выше:
    # clean.sh ramlogs-list, фолбэк DUMP_LOGS), свою копию не заводим: она уже расходилась.
    our_ramlogs | while read -r p; do
        [ -s "$p" ] || continue
        tail -$OUR_TAIL "$p" 2>/dev/null | redact > "$td/$base/logs/$(basename "$p")"
    done

    # Системный лог роутера: живой в /tmp (ОЗУ), ротированный — на флеше (переживает ребут).
    [ -s /tmp/messages ] && tail -$st /tmp/messages 2>/dev/null | redact > "$td/$base/system/messages"
    [ -s /data/usr/log/messages.0 ] && tail -$st /data/usr/log/messages.0 2>/dev/null | redact > "$td/$base/system/messages.0"
    if [ "$olds" = 1 ]; then
        for g in /data/usr/log/messages.*.gz; do
            [ -s "$g" ] || continue
            n=$(basename "$g" .gz)
            zcat "$g" 2>/dev/null | tail -$st | redact > "$td/$base/system/$n"
        done
    fi
    # Kernel panic переживает ребут в mtd-разделах crash/crash_syslog; стоковый mtd_crash_log
    # выкладывает его сюда. САМИ утилиту не зовём (её ключи -u/-a шлют крэш на сервер Xiaomi) —
    # берём файл, если он уже есть.
    [ -s /tmp/panic.message ] && redact < /tmp/panic.message > "$td/$base/system/panic.message"

    {
        echo "Диагностический архив роутера, собран: $(date 2>/dev/null)"
        echo ""
        echo "dump.txt        — состояние роутера на момент сборки (то же, что «текстовая диагностика»)"
        echo "logs/           — логи подсистем проекта (/tmp, живут до перезагрузки), хвост $OUR_TAIL строк"
        echo "system/messages — системный лог роутера, живой (/tmp, до перезагрузки)"
        echo "system/messages.0…N — он же, ротированный на флеш: ПЕРЕЖИВАЕТ перезагрузку"
        echo "system/panic.message — kernel panic из mtd-раздела, если стоковая утилита его выложила"
        echo ""
        echo "Хвост системных логов: $st строк на файл (объём выбран по свободной ОЗУ роутера)."
        echo "Старые ротированные архивы .gz: $( [ "$olds" = 1 ] && echo "включены" || echo "пропущены — на этом роутере мало свободной памяти" )."
        echo ""
        echo "ЧТО ЗАМАСКИРОВАНО во всех файлах: ключи и endpoint VPN, публичные IPv4 (первые два"
        echo "октета), последние три октета MAC-адресов, имена Wi-Fi-сетей, имена клиентов из аренд"
        echo "DHCP. Имена заменены на [SSID-N] / [HOST-N]: одно и то же имя — один и тот же номер,"
        echo "так что по архиву видно, какое правило на какой сети, но не как сеть называется."
        echo "Маскировка эвристическая — просмотрите архив перед публикацией."
        echo ""
        echo "Где искать причину перезагрузки: в system/messages* по словам"
        echo "  «Linux version»            — старт ядра (сама загрузка)"
        echo "  «procd: - shutdown -»      — штатное выключение/перезагрузка"
        echo "  «Out of memory» / «oom-kill» — нехватка памяти, ядро убило процесс"
        echo "  «kernel panic»             — падение ядра"
    } > "$td/$base/README.txt"

    tar -cz -C "$td" "$base" 2>/dev/null
    rm -rf "$td" "$ENV_SED"; trap 'rm -f "$ENV_SED"' EXIT
    return 0
}

# Уборка ENV_SED и в ТЕКСТОВЫХ режимах (у archive она своя, вместе с каталогом сборки):
# оборванная выгрузка = SIGPIPE, а на сигнале EXIT-ловушка не срабатывает (грабля busybox) —
# в /tmp, то есть в ОЗУ, копился бы файл с КАЖДОГО обрыва (имя-то с PID). На сигнале выходим
# ЯВНО: трап без exit только гасит смерть по SIGPIPE, и дамп домалывал бы диагностику в уже
# закрытый сокет — минуты работы роутера впустую.
trap 'exit 141' HUP INT TERM PIPE
trap 'rm -f "$ENV_SED"' EXIT

case "${1:-}" in
    ''|text) main 2>&1 | redact ;;
    archive) cmd_archive ;;
    # Фильтр stdin→stdout: ЕДИНСТВЕННАЯ точка маскировки на весь проект. Заведён, чтобы у
    # потребителей (CGI, будущие экспортёры) не появилось второй копии redact() — она бы
    # разошлась с этой ровно тогда, когда цена ошибки максимальна.
    redact)  build_env_sed; redact ;;
    *) echo "usage: $0 [text|archive|redact]" >&2; exit 2 ;;
esac
