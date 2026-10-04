#!/bin/sh
# slots.sh — РЕЕСТР «выходов» (слотов) мульти-транспорта. Ф0 фундамента.
#
# «Выход» (slot) = (транспорт, конфиг): доп-туннель/десинк, через который едут ПРИВЯЗАННЫЕ
# к нему группы (groups.sh) и гео-категории (geo.sh). Основной транспорт (.transport) — это
# неявный слот №1, ЕГО этот реестр НЕ описывает (истина по-прежнему .transport/transport.sh).
# Здесь живут только ДОП-слоты: id 2..4 (лимит 3; марки под маской 0x7 — запас на вырост).
#
# Дизайн целиком: заметки разработки «мультитранспорт-дизайн». Ключевое:
#   * марка слота = его id (0x2..0x4) -> ip rule pref 9<id> -> table 100<id>;
#   * слот-сеты grp_vpn_s<id> / geo_vpn_s<id> МЕТИТ mark-core.sh (инвариант проекта: логика
#     «выше miwifi/NFQUEUE» живёт в ОДНОМ месте — там). Этот скрипт правила НЕ СТАВИТ;
#   * а вот СНИМАЕТ правила своего слота — он (unwire): del/disable обязаны прибрать за собой,
#     mark-core чужие похороны не делает (он только переигрывает ВКЛЮЧЁННЫЕ слоты);
#   * пустая table 100<id> (несущая слота не поднята) => fwmark проваливается в main =
#     fail-open напрямую. Безопасно by construction — как и всё ядро.
#
# Персист: /data/usr/app/enodia-state/.slots — TSV, строка: id<TAB>name_b64<TAB>transport<TAB>config<TAB>fallback<TAB>on|off
#   name_b64 — имя слота в base64 (кириллица/пробелы/эмодзи; JSON/TSV-эскейпа на busybox нет —
#   тот же паттерн, что title/text в events.sh);
#   transport — из SELECTABLE transport.sh (awg|xray|hy2|byedpi|zapret);
#   config    — имя конфига несущей (для awg: configs/<имя>.conf; для xray: xray-configs/<имя>;
#               для byedpi/zapret: '-' — конфига нет, стратегия своя);
#   fallback  — main (деф.; при сбое слота его трафик через ОСНОВНОЙ выход) | direct (напрямую).
#
# Команды:
#   slots.sh list                — все слоты (человеко-TSV: id, имя, транспорт, конфиг, fallback, вкл)
#   slots.sh list-enabled        — только включённые, машинный TSV: id<TAB>transport<TAB>config<TAB>fallback
#                                  (его читает mark-core.sh — формат менять ОСТОРОЖНО)
#   slots.sh show <id>           — одна строка реестра (сырая)
#   slots.sh domains <id|0|zapret> [кап] — ДОМЕНЫ привязок выхода (0 = основной, zapret = всё,
#                                  что десинкает общий nfqws), по одному на строку; единый
#                                  источник для пула проб панели и byedpi-test.sh
#   slots.sh route <id|0|zapret> <домен> — «а ЭТОТ домен едет через выход?»: резолв + ipset test
#                                  по сетам цели. TSV: hit|miss|noresolve|badhost<TAB>ip<TAB>сет
#   slots.sh add <имя> <транспорт> [конфиг] [fallback]  — создать (id = первый свободный 2..4)
#   slots.sh set <id> <name|transport|config|fallback> <значение>
#   slots.sh enable <id> / disable <id>
#   slots.sh del <id>            — снять правила (unwire) + удалить из реестра
#   slots.sh unwire <id>         — только снять iptables/ip rule слота (без правки реестра)
#   slots.sh rename-config <транспорт> <старое> <новое> — конфиг ПЕРЕИМЕНОВАН: поле config выходов этого транспорта
#                                  со старым именем → новое (печатает, сколько строк переписано)
#   slots.sh key-holder <конфиг> <main|2|3|4> [live] — занят ли КЛЮЧ этого awg-конфига основным каналом или
#                                  другим выходом (0 = занят, причина словами; 1 = свободен; 2 = не судить);
#                                  без `live` — «можно ли назначить», с `live` — «поднимать ли сейчас» (см. блок ключей)
#   slots.sh key-map             — «конфиг⇥держатель» по занятым ключам configs/ (пометки в выборе панели)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
# Сброс УЖЕ УСТАНОВЛЕННЫХ соединений — только через ct-lib.sh: на ядре 4.4 (AX3600/BE3600)
# утилиты conntrack в прошивке НЕТ ВООБЩЕ, и прежний `conntrack -F || true` был тихим no-op —
# правило стояло, а поток шёл по-старому через NSS/ECM. Шим = прежнее поведение (частичный
# apply-scripts не должен падать), полноценный сброс живёт в самой библиотеке.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v ct_flush >/dev/null 2>&1 || ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
SLOTS_FILE="$ENODIA_STATE/.slots"
MIN_ID=2
MAX_ID=4
TAB=$(printf '\t')

# Где лежит бинарь (store-lib.sh): накопитель = ОПЦИЯ, но если он включён — альт-бинари живут
# НА НЁМ, и проверка `-x "$ENODIA_BIN/byedpi"` отвечает «нет» при установленном ciadpi (поймано на
# железе 04.08: панель прятала «Тест стратегий по пулу»). Нет маркера накопителя ⇒ bin_path
# отдаёт прежний путь БАЙТ-В-БАЙТ. Шим — на случай установки без lib.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# Порт socks доп-выхода считает ОДИН владелец — slot-tun-lib.sh (там же диапазон и его разбор).
# Своей арифметики 10830+id тут не держим: это была третья копия. Библиотека — только функции,
# исполняемого кода в ней нет, поэтому source безопасен и вне плагинов.
if [ -f "$ENODIA_DIR/slot-tun-lib.sh" ]; then . "$ENODIA_DIR/slot-tun-lib.sh"; fi
command -v slot_socks_port >/dev/null 2>&1 || slot_socks_port() { echo $((10830 + $1)); }

b64e() { printf '%s' "$1" | base64 | tr -d '\n'; }
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

valid_id() { case "$1" in 2|3|4) return 0 ;; *) return 1 ;; esac; }

# Транспорт слота должен быть известен оркестратору (SELECTABLE transport.sh). Дублировать
# список не хотим (DRY) — но и сорсить transport.sh нельзя (он исполняемый, не либа), поэтому
# СПРАШИВАЕМ ЕГО САМОГО (верб `names` = SELECTABLE). Готовность здесь НЕ требуем (слот можно
# завести до установки бинаря — как deferred-config), требуем лишь ИЗВЕСТНОСТЬ имени.
# Фолбэк на вшитый список — для дрейфа деплоя (старый transport.sh без верба `names`): пустой
# ответ означал бы «любой транспорт неизвестен», т.е. невозможность завести выход вообще.
valid_transport() {
    _known=""
    [ -f "$ENODIA_DIR/transport.sh" ] && _known=$(sh "$ENODIA_DIR/transport.sh" names 2>/dev/null)
    case "$_known" in ''|*usage*) _known="awg xray hy2 byedpi zapret" ;; esac
    for _kt in $_known; do [ "$1" = "$_kt" ] && return 0; done
    return 1
}

slot_line() { grep "^$1$TAB" "$SLOTS_FILE" 2>/dev/null | head -n1; }

# --- ЗАПИСЬ В РЕЕСТР: лок + атомарная подмена ------------------------------------------------
# Реестр правят НЕСКОЛЬКО потребителей (клик в панели, второй клик, slot-* из сторожа/heal), а
# запись — read-modify-write ЦЕЛОГО файла ⇒ без лока два одновременных вызова склеивают строки
# или теряют выход; cmd_add вдобавок выбирает id ЧТЕНИЕМ (TOCTOU). Лок — КАТАЛОГ (mkdir атомарен
# на любой ФС, идиома groups/geo/dns-merge), устаревший снимаем `rm -rf`: внутри пид-файл, rmdir
# его не возьмёт. Временный файл — со СВОИМ ПИДом: общее имя `.new` два процесса делили бы.
SLOTS_LOCK=/tmp/.enodia-slots.lock
slots_lock_take() {   # $1 = сколько секунд ждать (деф. 10)
    _lw="${1:-10}"; _li=0
    while ! mkdir "$SLOTS_LOCK" 2>/dev/null; do
        _lp=$(cat "$SLOTS_LOCK/pid" 2>/dev/null | tr -d ' \r\n')
        if [ -z "$_lp" ] || ! kill -0 "$_lp" 2>/dev/null; then
            rm -rf "$SLOTS_LOCK" 2>/dev/null; continue        # держатель умер — лок протух
        fi
        _li=$((_li+1)); [ "$_li" -ge "$_lw" ] && return 1
        sleep 1
    done
    echo $$ > "$SLOTS_LOCK/pid" 2>/dev/null
    return 0
}
slots_lock_drop() { rm -rf "$SLOTS_LOCK" 2>/dev/null; }
# Переписать (или УДАЛИТЬ, если полей нет) строку слота. Звать ТОЛЬКО под локом.
_slots_write() {   # $1 = id ; [$2..$6 = name_b64 transport config fallback en]
    _wid="$1"; _wtmp="$SLOTS_FILE.$$"
    grep -v "^$_wid$TAB" "$SLOTS_FILE" > "$_wtmp" 2>/dev/null || true
    [ "$#" -gt 1 ] && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_wid" "$2" "$3" "$4" "$5" "$6" >> "$_wtmp"
    if [ -s "$_wtmp" ]; then mv "$_wtmp" "$SLOTS_FILE"
    else rm -f "$_wtmp" "$SLOTS_FILE"; fi
}

# carriers — какие ТРАНСПОРТЫ несут доп-выходы (уникальные значения 3-й колонки, по слову в строке).
# ЗАЧЕМ вербом: это единственный ответ на вопрос «можно ли сносить бинарь транспорта», а спрашивают
# его РАЗНЫЕ подсистемы (установщик в purge-alt, движок компонентов packages.sh). Берём ВСЕ строки,
# включая ВЫКЛЮЧЕННЫЕ: выключенный выход — это запись с конфигом и привязками, снесённый бинарь
# сделал бы её невоскресимой (и «включить» молча не сработало бы).
cmd_carriers() { [ -s "$SLOTS_FILE" ] || return 0; cut -f3 "$SLOTS_FILE" 2>/dev/null | grep -v '^$' | sort -u; }

cmd_list() {
    [ -s "$SLOTS_FILE" ] || return 0
    while IFS="$TAB" read -r id nb t cfg fb en; do
        [ -n "$id" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(b64d "$nb")" "$t" "$cfg" "$fb" "$en"
    done < "$SLOTS_FILE"
}

cmd_list_enabled() {
    [ -s "$SLOTS_FILE" ] || return 0
    while IFS="$TAB" read -r id nb t cfg fb en; do
        [ "$en" = on ] || continue
        printf '%s\t%s\t%s\t%s\n' "$id" "$t" "$cfg" "$fb"
    done < "$SLOTS_FILE"
}

# --- ДОМЕНЫ ПРИВЯЗОК ВЫХОДА -----------------------------------------------------------------
# «Какие домены реально едут через выход №N» — ЕДИНЫЙ ответ на всех потребителей: кандидаты
# пула проб браузер-свипа (панель) и пул тестера стратегий (byedpi-test.sh). id 0 = ОСНОВНОЙ
# выход (привязки без слота). Только ДОМЕНЫ: проба ходит по имени (SNI/TLS), CIDR десинку не
# проба, поэтому адреса отбрасываем.
#
# Два источника, объединяются (дедуп), потому что отвечают на РАЗНЫЕ вопросы:
#   (а) РЕЕСТР (groups.tsv + geo/actions.tsv + гео-кэш в ОЗУ) — «что человек привязал»; работает
#       и у ВЫКЛЮЧЕННОГО выхода (иначе пул проб нельзя собрать до первого включения: пока слот
#       выключен, гейт groups/geo уводит домены в основной сет и слот-строк в dnsmasq НЕТ);
#   (б) ЖИВОЙ dnsmasq (`ipset=/дом/<сет>`) — «что реально зашито в сет выхода»; ловит то, чего
#       в реестре групп нет вовсе: пулы zapret (zapret_set/zapret_dom) у основной несущей.
slot_pool_sets() {   # <id> -> имена ipset, наполняемые dnsmasq для этого выхода
    case "$1" in
        0) _ss="grp_vpn geo_vpn enodia_list"
           [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && _ss="$_ss zapret_set zapret_dom geo_zapret"
           echo "$_ss" ;;
        *) echo "grp_vpn_s$1 geo_vpn_s$1" ;;
    esac
}
collect_domains() {   # <id> -> дописать домены привязок выхода в $_raw
    _c="$1"
    # (а) реестр групп: включённые, «в VPN», привязанные к этому выходу
    _gtsv="$ENODIA_STATE/groups/groups.tsv"
    if [ -f "$_gtsv" ]; then
        while IFS="$TAB" read -r _gid _gen _gdir _gslot _gname _gsrc; do
            [ "$_gen" = 1 ] && [ "$_gdir" = vpn ] && [ "${_gslot:-0}" = "$_c" ] || continue
            [ -f "$ENODIA_STATE/groups/$_gid.list" ] && cat "$ENODIA_STATE/groups/$_gid.list" >> "$_raw"
        done < "$_gtsv"
    fi
    # (а) реестр гео: доменные категории «в VPN» этого выхода (кэш в ОЗУ уже нормализован;
    # нет кэша = категория не резолвлена — путь (б) её всё равно подберёт из dnsmasq)
    _geor="$ENODIA_STATE/geo/actions.tsv"
    if [ -f "$_geor" ]; then
        while IFS="$TAB" read -r _gk _ga _gc _gt _gs; do
            [ "$_ga" = vpn ] && [ "${_gs:-0}" = "$_c" ] || continue
            [ -f "/tmp/enodia-geo/cache/$_gk" ] && cat "/tmp/enodia-geo/cache/$_gk" >> "$_raw"
        done < "$_geor"
    fi
    # (б) живой dnsmasq: `ipset=/дом/сет[,сет2]` -> домен. Хвост после последнего «/» — СПИСОК
    # сетов через запятую (groups.sh агрегирует строки: dnsmasq применяет к домену ровно одну).
    # Поэтому спрашиваем ЧЛЕНСТВО в списке, а не «сет в конце строки»: анкор `[/,]сет$` видел бы
    # только последний сет, и выход, попавший в середину, читался бы как «доменов нет».
    for _s in $(slot_pool_sets "$_c"); do
        awk -F/ -v s="$_s" '/^ipset=/ && NF==3 && ("," $3 ",") ~ ("," s ",") {print $2}' \
            /tmp/dnsmasq.d/*.conf 2>/dev/null >> "$_raw"
    done
}
cmd_domains() {
    _id="$1"; [ -n "$_id" ] || _id=0
    case "$_id" in
        zapret|0) ;;
        *) valid_id "$_id" || { echo "[slots] domains: битый id '$_id'" >&2; return 1; } ;;
    esac
    _cap="$2"; case "$_cap" in ''|*[!0-9]*) _cap=24 ;; esac
    _raw="/tmp/.enodia-slot-doms.$$"; : > "$_raw"
    if [ "$_id" = zapret ]; then
        # Особый «выход» для карточки Zapret: nfqws ОДИН на очередь 212 ⇒ стратегия у транспорта
        # и у всех zapret-выходов ОБЩАЯ, значит честный пул проверки — всё, что он десинкает.
        # Транспорт учитываем, только если zapret и правда активен (иначе его сеты не в игре).
        [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && collect_domains 0
        if [ -s "$SLOTS_FILE" ]; then
            while IFS="$TAB" read -r _zi _zn _zt _zc _zf _ze; do
                [ "$_ze" = on ] && [ "$_zt" = zapret ] && collect_domains "$_zi"
            done < "$SLOTS_FILE"
        fi
    else
        collect_domains "$_id"
    fi
    # Домены 2-го уровня — ВПЕРЁД (у них выше шанс отдать favicon: у CDN-поддоменов его обычно
    # нет вовсе, а «нет картинки» неотличимо от «DPI зарезал»), затем остальные; кап общий.
    _d2='^[A-Za-z0-9-]+\.[A-Za-z][A-Za-z]+$'
    _dn='^[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+$'
    { grep -E "$_d2" "$_raw" 2>/dev/null | sort -u
      grep -E "$_dn" "$_raw" 2>/dev/null | grep -Ev "$_d2" | sort -u
    } > "$_raw.s"
    # Поддомен под живым родителем — ЛИШНЯЯ проба: dnsmasq матчит поддомены сам (инвариант
    # «маска *.дом не нужна») ⇒ ntl.service.konami.net при konami.net в списке едет ТЕМ ЖЕ
    # маршрутом, но фавикона у сервисного поддомена обычно нет вовсе = ложный «красный» в
    # калибровке. Родитель в отсортированном списке всегда ВЫШЕ (домены 2-го уровня идут
    # первыми), поэтому хватает одного прохода. Кап считаем ПОСЛЕ схлопывания — иначе места в
    # пуле занимали клоны одного сайта (железо 28.07: 3 кандидата = 1 сайт).
    _acc=""; _n=0
    while read -r _d; do
        [ -n "$_d" ] || continue
        _skip=""
        for _p in $_acc; do case "$_d" in *".$_p") _skip=1; break ;; esac; done
        [ -n "$_skip" ] && continue
        _acc="$_acc $_d"; echo "$_d"
        _n=$((_n+1)); [ "$_n" -ge "$_cap" ] && break
    done < "$_raw.s"
    rm -f "$_raw" "$_raw.s" 2>/dev/null
    return 0
}

# --- МАРШРУТ ОДНОГО ИМЕНИ («а ЭТОТ домен вообще едет через десинк?») ------------------------
# Вопрос ОТДЕЛЬНЫЙ от `domains`, и реестром на него не ответить: у основного выхода почти весь
# трафик метится по CIDR (iplist_set — тысячи подсетей opencck), доменов у этих сетей нет ВООБЩЕ.
# Значит имя, которого нет ни в одной группе, всё равно может честно ехать через десинк — и без
# этой проверки браузер-тест доступен только тому, кто завёл доменные правила руками, а всем
# остальным недоступен как класс (железо 28.07). Отвечаем ФАКТОМ ЯДРА: резолв + ipset test.
#
# Резолвим СИСТЕМНЫМ резолвером (dnsmasq), намеренно без DoH-обхода из dns-lib: сеты наполняет
# ровно он и клиенты ходят через него же, поэтому чужой ответ дал бы IP, которого в сете нет, —
# вердикт был бы про несуществующий маршрут.
slot_route_sets() {   # <id|0|zapret> -> сеты, попадание в которые = «едет через эту цель»
    case "$1" in
        0)  _rs="enodia_list grp_vpn geo_vpn iplist_set"
            [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && _rs="$_rs zapret_set zapret_cidr zapret_dom geo_zapret"
            echo "$_rs" ;;
        zapret)
            _rs=""
            [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null)" = zapret ] && _rs="zapret_set zapret_cidr zapret_dom geo_zapret"
            if [ -s "$SLOTS_FILE" ]; then
                while IFS="$TAB" read -r _zi _zn _zt _zc _zf _ze; do
                    [ "$_ze" = on ] && [ "$_zt" = zapret ] && _rs="$_rs grp_vpn_s$_zi geo_vpn_s$_zi"
                done < "$SLOTS_FILE"
            fi
            echo "$_rs" ;;
        *)  echo "grp_vpn_s$1 geo_vpn_s$1" ;;
    esac
}
cmd_route() {   # <id|0|zapret> <домен>
    _rid="$1"; [ -n "$_rid" ] || _rid=0
    case "$_rid" in
        zapret|0) ;;
        *) valid_id "$_rid" || { printf 'badhost\t-\t-\n'; return 1; } ;;
    esac
    _rh="$2"
    printf '%s' "$_rh" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$' || { printf 'badhost\t-\t-\n'; return 1; }
    # ВСЕ A-записи имени, а не первую: у CDN/anycast в сете может лежать лишь часть адресов. Разбор
    # вывода busybox nslookup — у dns-lib.sh::ns_ips (там же, почему `$NF` врёт): копий этого awk было
    # две, и третья просилась в проверялку «что победит». БИБЛИОТЕКУ СОРСИМ ЗДЕСЬ, А НЕ В ШАПКЕ: её
    # 47 КБ разбора платил бы КАЖДЫЙ `list-json`, а его зовёт опрос панели. Нет библиотеки (частично
    # доехавший apply-scripts) — прежний путь байт-в-байт.
    if ! command -v ns_ips >/dev/null 2>&1 && [ -f "$ENODIA_DIR/dns-lib.sh" ]; then . "$ENODIA_DIR/dns-lib.sh"; fi
    if command -v ns_ips >/dev/null 2>&1; then _rips=$(ns_ips "$_rh")
    else _rips=$(nslookup "$_rh" 2>/dev/null | awk '/^Name:/{f=1} f&&/^Address/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}'); fi
    [ -n "$_rips" ] || { printf 'noresolve\t-\t-\n'; return 0; }
    _rsets=$(slot_route_sets "$_rid")
    for _ri in $_rips; do
        for _rss in $_rsets; do
            ipset test "$_rss" "$_ri" >/dev/null 2>&1 && { printf 'hit\t%s\t%s\n' "$_ri" "$_rss"; return 0; }
        done
    done
    printf 'miss\t%s\t-\n' "$(echo "$_rips" | head -n1)"
    return 0
}

# JSON для панели: слоты + счётчик привязанных ГРУПП на слот (гео — Ф1b, пока 0) + флаг «мест
# нет». name уезжает как name_b64 (в реестре уже base64: кириллица/эмодзи без JSON-эскейпа, как
# title/text в events.sh — панель декодирует b64toUtf8). transport/fallback из whitelist,
# config — имя файла (панель выбирает из готового списка cgi-bin/list, инъекции нет).
# ЧЕСТНЫЙ СТАТУС ВЫХОДА. «on» в реестре — НАМЕРЕНИЕ, а не факт: несущая слота могла не подняться
# (битый конфиг/мёртвый VPS), умереть между тиками watchdog (лаг до 2 мин) или потерять правила
# после fw3-reload. Панель рисовала зелёную точку прямо по строке реестра — тот же класс вранья,
# что «шапка врёт про протокол». Читаем ФАКТЫ ЯДРА, дёшево и БЕЗ egress-проб (блок выходов
# рисуется синхронно, а `transport.sh slot-health` у xray/hy2 — проба на секунды):
#   карриер (awg/xray/hy2/byedpi): есть ip rule метки 0x<id> + default в table 100<id>;
#   zapret:                        марки нет вовсе (mark-core его пропускает) — судим по ОБЩЕМУ
#                                  nfqws + scoped NFQUEUE на сетах слота.
# Ответы: up (несёт свой трафик) · dead (маршрут есть, но демон выхода не слушает — сайты выхода
#         не откроются, чинит сторож) · fallback (несущей нет, метка уведена в основной туннель) ·
#         direct (несущей нет, метка проваливается в main ⇒ трафик выхода идёт НАПРЯМУЮ мимо VPN) ·
#         down (правил выхода нет вовсе — лечит «Починить правила») ·
#         idle (zapret-выход без привязок: десинкать нечего, это не поломка).
slot_state() {   # <id> <transport> <fallback>
    _sid="$1"; _stp="$2"
    if [ "$_stp" = zapret ]; then
        _sets=0
        ipset list -n 2>/dev/null | grep -qx "grp_vpn_s$_sid" && _sets=1
        ipset list -n 2>/dev/null | grep -qx "geo_vpn_s$_sid" && _sets=1
        [ "$_sets" = 1 ] || { echo idle; return 0; }
        _srul=0
        iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q -- "--match-set grp_vpn_s$_sid dst" && _srul=1
        iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q -- "--match-set geo_vpn_s$_sid dst" && _srul=1
        _spid=$(cat /tmp/enodia-zapret-nfqws.pid 2>/dev/null | tr -d ' \r\n')
        if [ "$_srul" = 1 ] && [ -n "$_spid" ] && kill -0 "$_spid" 2>/dev/null; then echo up; else echo down; fi
        return 0
    fi
    _srl=$(ip rule show 2>/dev/null | grep "fwmark 0x$_sid " | head -n1)
    [ -n "$_srl" ] || { echo down; return 0; }
    if ip route show table "100$_sid" 2>/dev/null | grep -q '^default'; then   # not-wan: несущая СЛОТА (table 100N), а не основная и не WAN
        # Маршрут есть — но у socks-выходов (byedpi/xray/hy2) он ведёт в tun2socks, а тот без
        # ЖИВОГО socks просто глотает пакеты: «маршрут на месте» ≠ «выход везёт». Демон мог
        # умереть между тиками сторожа (ciadpi самовыключается на accept-EINVAL) — тогда сайты
        # выхода не откроются ВООБЩЕ (не «поедут другим путём»), и это отдельный ответ.
        case "$_stp" in
            byedpi|xray|hy2)
                netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$(slot_socks_port "$_sid")" || { echo dead; return 0; } ;;
        esac
        echo up; return 0
    fi
    # Несущей нет. Куда РЕАЛЬНО едет метка сейчас: правило на table 1000 = в основной туннель;
    # иначе метка проваливается в main = напрямую (даже если в реестре fallback=main — mark-core
    # переиграет правило лишь следующим проходом/тиком сторожа, а трафик идёт уже сейчас).
    case "$_srl" in *"lookup 1000"*) echo fallback ;; *) echo direct ;; esac
}

# Машинный срез состояний: id⇥state по КАЖДОМУ слоту реестра (выключенный = off). Читают
# cgi-bin/status (индикатор «выход не работает» в шапке) и диагностика.
cmd_state() {
    [ -s "$SLOTS_FILE" ] || return 0
    while IFS="$TAB" read -r id nb t cfg fb en; do
        [ -n "$id" ] || continue
        if [ "$en" = on ]; then _st=$(slot_state "$id" "$t" "$fb"); else _st=off; fi
        printf '%s%s%s\n' "$id" "$TAB" "$_st"
    done < "$SLOTS_FILE"
}

cmd_list_json() {
    _gtsv="$ENODIA_STATE/groups/groups.tsv"
    _c2=0; _c3=0; _c4=0
    if [ -f "$_gtsv" ]; then
        while IFS="$TAB" read -r _gid _gen _gdir _gslot _gname _gsrc; do
            case "$_gslot" in 2) _c2=$((_c2+1)) ;; 3) _c3=$((_c3+1)) ;; 4) _c4=$((_c4+1)) ;; esac
        done < "$_gtsv"
    fi
    # Гео-привязки (Ф1b): 5-я колонка geo/actions.tsv (key⇥action⇥cnt⇥ts⇥slot); считаем только
    # действующие строки (в реестре нет off), slot валиден лишь при action=vpn — geo.sh это блюдёт.
    # Заодно СОБИРАЕМ сами ключи на слот (geo_keys) — панель по ним подсвечивает чипы-пресеты
    # (v2fly-youtube/… привязан ли к этому выходу). Ключи гео = [a-z0-9._!-] (JSON-эскейп не нужен,
    # как и для name_b64: кавычек/бэкслешей в наборе нет; CGI дополнительно санирует их charset'ом).
    _g2=0; _g3=0; _g4=0
    _gk2=''; _gk3=''; _gk4=''
    _geor="$ENODIA_STATE/geo/actions.tsv"
    if [ -f "$_geor" ]; then
        while IFS="$TAB" read -r _gk _ga _gc _gt _gs; do
            [ "$_ga" = vpn ] || continue
            case "$_gs" in
                2) _g2=$((_g2+1)); _gk2="$_gk2${_gk2:+,}\"$_gk\"" ;;
                3) _g3=$((_g3+1)); _gk3="$_gk3${_gk3:+,}\"$_gk\"" ;;
                4) _g4=$((_g4+1)); _gk4="$_gk4${_gk4:+,}\"$_gk\"" ;;
            esac
        done < "$_geor"
    fi
    _n=0; _first=1; _krlx=0; _krix=0   # держатели ключей — один раз на ответ, а не на выход (живой ключ = вызовы awg)
    printf '{"slots":['
    if [ -s "$SLOTS_FILE" ]; then
        while IFS="$TAB" read -r id nb t cfg fb en; do
            [ -n "$id" ] || continue
            _n=$((_n+1))
            [ "$_first" = 1 ] || printf ','
            _first=0
            case "$id" in 2) _gc=$_c2 ;; 3) _gc=$_c3 ;; 4) _gc=$_c4 ;; *) _gc=0 ;; esac
            case "$id" in 2) _ge=$_g2 ;; 3) _ge=$_g3 ;; 4) _ge=$_g4 ;; *) _ge=0 ;; esac
            case "$id" in 2) _gk=$_gk2 ;; 3) _gk=$_gk3 ;; 4) _gk=$_gk4 ;; *) _gk='' ;; esac
            # state — честный статус (см. slot_state): панель красит точку и объясняет, почему
            # включённый выход не везёт трафик. Выключенный не щупаем (правил у него нет).
            if [ "$en" = on ]; then _st=$(slot_state "$id" "$t" "$fb"); else _st=off; fi
            # key_clash — КТО МЕШАЕТ этому awg-выходу (main | s<N> | пусто), и вопрос у включённого и выключенного разный:
            # включённому — «почему не поднимается» (live: держатель занимает сессию СЕЙЧАС — cmd_slot_up откажет, а состояние
            # скажет лишь «несущая не поднялась»), выключенному — «почему не включится» (intent: откажет форма). Иначе работающий
            # выход носил бы плашку «не поднимется», пока ключ лишь числится за выключенным соседом (ревью 27.09.2026).
            # Попадают сюда мимо формы: импорт бэкапа, ручная правка `.slots`, выход, заведённый до гарда.
            _kcl=''
            if [ "$t" = awg ] && [ -f "$AWG_CONFIGS/$cfg.conf" ]; then
                if [ "$en" = on ]; then [ "$_krlx" = 1 ] || { _krl=$(key_rows live); _krlx=1; }; _kr=$_krl
                else [ "$_krix" = 1 ] || { _kri=$(key_rows intent); _krix=1; }; _kr=$_kri; fi
                _kcl=$(awg_ids "$AWG_CONFIGS/$cfg.conf" | key_match "$_kr" "s$id" | head -n1 | cut -f2)
            fi
            printf '{"id":%s,"name_b64":"%s","transport":"%s","config":"%s","fallback":"%s","enabled":%s,"state":"%s","groups":%s,"geo":%s,"geo_keys":[%s],"key_clash":"%s"}' \
                "$id" "$nb" "$t" "$cfg" "$fb" "$([ "$en" = on ] && echo true || echo false)" "$_st" "$_gc" "$_ge" "$_gk" "$_kcl"
        done < "$SLOTS_FILE"
    fi
    # Транспорты, готовые нести ДОП-ВЫХОД, — от ОРКЕСТРАТОРА (`transport.sh slot-list`),
    # единственная истина, дублировать не хотим. Именно slot-list, а НЕ list: у выхода свой
    # сервер из каталога, активный конфиг ему не нужен (см. slot_ready в transport.sh) —
    # по `list` xray/hy2 без активации основным в пикер бы не попали. Фолбэк на `list` —
    # для дрейфа деплоя (старый transport.sh без верба: пусто лучше не отдавать).
    # configs для формы панель берёт из /cgi-bin/list (тот же ответ, что у экрана «Серверы»).
    _ready=''
    # `-f`, а не `-x`: зовём через `sh` (класс Б5-9). Снятый бит выключал бы ВЕСЬ пикер
    # транспортов в форме «добавить выход» — панель показала бы «нечего добавить» при живом
    # transport.sh. Так же теперь и все соседние вызовы: форма в проекте ОДНА (см. C27).
    if [ -f "$ENODIA_DIR/transport.sh" ]; then
        _rl=$(sh "$ENODIA_DIR/transport.sh" slot-list 2>/dev/null) || _rl=$(sh "$ENODIA_DIR/transport.sh" list 2>/dev/null)
        for _rt in $_rl; do
            _ready="$_ready${_ready:+,}\"$_rt\""
        done
    fi
    # byedpi = установлен ли бинарь ciadpi (для ⋮ «Тест стратегий по пулу» — тестер гоняет
    # ciadpi-стратегии по доменам привязок слота; без бинаря пункт панель прячет). Путь — через
    # bin_path: с включённым накопителем бинарь лежит НА НЁМ, и прежнее `-x "$ENODIA_BIN/byedpi"`
    # врало «не установлен» (железо 04.08 — тот же класс, что geo.sh и nfqws).
    printf '],"count":%s,"max":%s,"full":%s,"ready":[%s],"byedpi":%s}\n' \
        "$_n" "$((MAX_ID-MIN_ID+1))" "$([ "$_n" -ge $((MAX_ID-MIN_ID+1)) ] && echo true || echo false)" "$_ready" \
        "$([ -x "$(bin_path byedpi)" ] && echo true || echo false)"
}

# Имя конфига несущей: обязана быть ОДНА TSV-колонка. Значение с табом/переводом строки
# разъехалось бы по полям реестра (и утащило бы за собой fallback/en — read их схлопывает),
# а поле пишут и CLI, и панель ⇒ валидируем здесь, как transport/fallback: движок обязан быть
# безопасен и из CLI. '-' = «конфига нет» (byedpi/zapret).
# Имя — ОДНОЙ строкой: `grep ^…$` судит построчно, и имя с переводом строки внутри проходило бы по первой строке — а в реестр
# (TSV) легла бы лишняя строка и обрезанная эта (ревью пачки 2: POST переименования с `%0A` дописывал в .slots выход №7).
valid_config() {
    case "$1" in
        -) return 0 ;;
        '') return 1 ;;
        *) [ "$(printf '%s' "$1" | wc -l)" -eq 0 ] && printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$' ;;
    esac
}

# --- «ЭТОТ КЛЮЧ AmneziaWG УЖЕ ЗАНЯТ?» — ЕДИНСТВЕННЫЙ ответ на роутер ----------------------------------
# Сервер WireGuard/AmneziaWG опознаёт клиента по КЛЮЧУ, и сессия у ключа ОДНА: два наших демона на одном
# ключе (основной awg0 — живой или ТЁПЛЫМ РЕЗЕРВОМ — и выход awgN, либо два выхода) перетягивают её, и
# выход переустанавливает рукопожатие каждые 25–40 с (замер на BE3600 тестера 10.09.2026: конфиг
# выхода был тем же файлом, что у основного). Человек видит «выход не работает» и письмо про мёртвый
# сервер, а сервер жив — связать это сам он не может: в панели нет ни строчки о занятом ключе.
# Сверяем КЛЮЧ, а НЕ имя файла: первое, что сделает человек, которому сказали «заведите выходу свой
# конфиг», — скопирует файл под новым именем, и сверка имён пропустила бы ту же беду. ИДЕНТИЧНОСТЬ
# СЕССИИ — пара «PrivateKey : PublicKey пира»: один клиентский ключ на ДВУХ РАЗНЫХ серверах (пира
# переносят между своими серверами) — две независимые сессии, и отказ был бы ложным (ревью 27.09.2026).
# Пира нет с одной из сторон — судим по одному приватнику. Сам ключ не печатаем НИКОГДА — наружу
# уходят только имена.
# ДВА РЕЖИМА, потому что вопросов два:
#   intent — «можно ли НАЗНАЧИТЬ» (форма: add/set/enable, смена сервера основного, пометки в выборе).
#            Держатели — всё, что поднимется: `awg.conf` основного (его поднимает AmneziaWG основным и
#            держит тёплым резервом, даже когда основной транспорт другой), ключ ЖИВОГО awg0 (резерв мог
#            остаться от прежнего сервера — warm-carrier-keeps-old-server), «дом» режима «Домой»
#            (`.failover-home`: сторож вернётся на него, и возврат упёрся бы в выход) и awg-выходы,
#            ВКЛЮЧЁННЫЕ И НЕТ (выключенный включат позже — беда проявилась бы вдали от места, где её назвать).
#   live   — «поднимать ли СЕЙЧАС» (подъём выхода, transport-awg.sh cmd_slot_up — последний рубеж).
#            Держатели — только те, кто ЗАНИМАЕТ сессию: живой awg0, `awg.conf`, когда основной — AmneziaWG
#            (awg0 встанет с минуты на минуту: порядок подъёма на буте не наш), и ЖИВЫЕ соседние выходы. По
#            намерению тут судить нельзя: выход, заведённый до гарда при основном VLESS и `awg.conf` от
#            прежнего AmneziaWG, работал — и снимался бы на первом же ребуте без письма (ревью 27.09.2026).
#            Два включённых выхода на одном ключе: поднимается первый, второй получает отказ.
# Потребители: add/set/enable (здесь), смена сервера основного канала и перебор его резервов
# (switch-vpn.sh), подъём выхода (transport-awg.sh), пометки «занят» (cgi-bin/list → панель) и
# `key_clash` выхода (list-json). Своих копий не заводить.
# Только AmneziaWG: у VLESS/Hysteria один UUID обычно держит несколько подключений (не замерено ⇒ не
# запрещаем), у byedpi/zapret конфига нет вовсе.
AWG_CONFIGS="$ENODIA_STATE/configs"
# Разбор конфигов — ОДНИМ awk на любое их число (прежний путь звал ~19 процессов на конфиг, а `cgi-bin/list` — это меню
# «Сервер»: 30 конфигов = 571 процесс; ревью 27.09.2026). Имя ключа — без учёта регистра (как у wg), комментарий `# …` после
# значения — вон, префикс ОТРЕЗАЕМ, а не делим по «=»: ключ — base64 с «=» на конце (грабля 27.09.2026 у сверки пира).
# ПИРОВ МОЖЕТ БЫТЬ НЕСКОЛЬКО, и порядок их у userspace-демона случаен (обход Go-map) ⇒ никакого «первого пира»: на каждый пир —
# своя строка «C⇥имя⇥ключ:пир» (пиров нет — «ключ»), и совпадение ЛЮБОЙ пары — одна сессия на двоих (ревью 28.09.2026, круг 2).
# ПРИВАТНИК — В «ПРИЖАТОЙ» ФОРМЕ. Демон хранит ключ после clamping Curve25519 (у первого байта сброшены 3 младших бита, у последнего —
# старший, а соседний взведён), а в конфиге он бывает сырым — сгенерирован не `wg genkey`. Тогда живой ключ (`show private-key`) ≠
# строке файла при ТОМ ЖЕ ключе (замер BE7000 02.10.2026: расходился один знак base64), и «занят ли ключ ЖИВЫМ держателем» не
# находил держателя НИКОГДА: последний рубеж подъёма выхода молчал. Приводим ОБЕ стороны к прижатой форме — она у ключа одна.
# Прижатие трогает ровно три знака base64 (0, 1 и 41 — биты первого и последнего байта), и делается АРИФМЕТИКОЙ, без and()/or():
# битовых функций у busybox awk может не быть. Неканоничная строка (не 44 знака, чужой алфавит) остаётся как есть.
AWG_CLAMP_BEGIN='BEGIN { B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; for (i = 0; i < 64; i++) b64[substr(B, i + 1, 1)] = i }'
AWG_CLAMP='if (length(v) == 44 && (substr(v, 1, 1) in b64) && (substr(v, 2, 1) in b64) && (substr(v, 42, 1) in b64)) { c0 = b64[substr(v, 1, 1)]; c1 = b64[substr(v, 2, 1)]; c41 = b64[substr(v, 42, 1)]; c0 = c0 - c0 % 2; c1 = c1 % 16; c41 = int(c41 / 16) * 16 + 4 + c41 % 4; v = substr(B, c0 + 1, 1) substr(B, c1 + 1, 1) substr(v, 3, 39) substr(B, c41 + 1, 1) substr(v, 43) }'
AWG_ID_AWK="$AWG_CLAMP_BEGIN"'
FNR == 1 && NR > 1 && pk != "" { if (np == 0) print "C\t" nm "\t" pk; for (k = 1; k <= np; k++) print "C\t" nm "\t" pk ":" pe[k] }
FNR == 1 { nm = FILENAME; sub(/.*\//, "", nm); sub(/\.conf$/, "", nm); pk = ""; np = 0 }
{ l = $0; sub(/\r$/, "", l); t = tolower(l) }
t ~ /^[ \t]*privatekey[ \t]*=/ && pk == "" { v = l; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v); gsub(/[ \t]/, "", v); '"$AWG_CLAMP"'; pk = v }
t ~ /^[ \t]*publickey[ \t]*=/ { v = l; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v); gsub(/[ \t]/, "", v); if (v != "") pe[++np] = v }
END { if (pk != "") { if (np == 0) print "C\t" nm "\t" pk; for (k = 1; k <= np; k++) print "C\t" nm "\t" pk ":" pe[k] } }'
awg_ids() { awk "$AWG_ID_AWK" "$@" 2>/dev/null; }             # файлы .conf -> «C⇥имя⇥идентичность» (строка на пир)
awg_key_file() { [ -f "$1" ] || return 0; awg_ids "$1" | cut -f3; }
awg_key_live() {   # $1 = iface -> «ключ:пир» живого демона строкой на пир (пусто, если его нет или нечем спросить)
    ip link show "$1" >/dev/null 2>&1 || return 0
    _kb=$(bin_path awg); [ -x "$_kb" ] || return 0
    # Та же прижатая форма, что у файлов (AWG_CLAMP): демон и так отдаёт прижатый, но правило «обе стороны — через одно» дешевле
    # доверия к чужой реализации.
    _kl=$("$_kb" show "$1" private-key 2>/dev/null | head -n1 | tr -d ' \t\r' | awk "$AWG_CLAMP_BEGIN"' { v = $0; '"$AWG_CLAMP"'; print v }')
    [ -n "$_kl" ] || return 0
    _kp=$("$_kb" show "$1" peers 2>/dev/null | tr -d ' \t\r')
    if [ -z "$_kp" ]; then printf '%s\n' "$_kl"; return 0; fi
    printf '%s\n' "$_kp" | while IFS= read -r _kq; do [ -n "$_kq" ] && printf '%s:%s\n' "$_kl" "$_kq"; done
    return 0
}
key_row() {   # $1 = кто, $2 = имя, $3 = идентичности строками -> R-строки
    printf '%s\n' "$3" | while IFS= read -r _kr1; do [ -n "$_kr1" ] && printf 'R\t%s\t%s\t%s\n' "$1" "$2" "$_kr1"; done
    return 0
}
# key_rows <intent|live> -> держатели строками «R⇥кто⇥имя⇥идентичность» (кто = main | s<N>). Считаются ОДИН раз на вопрос:
# живой ключ — это два вызова `awg` на интерфейс. Имена переменных — СВОИ (`_r*`): `local` в busybox sh нет.
key_rows() {
    _rmode="$1"
    _rm=$(awg_key_file "$ENODIA_STATE/awg.conf"); _ra=$(cat "$ENODIA_STATE/.active" 2>/dev/null | tr -d ' \r\n')
    if [ "$_rmode" = intent ] || [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" = awg ]; then
        key_row main "$_ra" "$_rm"
    fi
    # Живой awg0: имя из `.active` — ТОЛЬКО когда он на ключе конфига основного; иначе это резерв ПРЕЖНЕГО сервера, и имя из
    # `.active` назвало бы чужой конфиг. Пустое имя = «неизвестно» (принято в проекте). Сверяем приватник (до «:»).
    _rl=$(awg_key_live awg0)
    if [ -n "$_rl" ]; then
        if [ "$(printf '%s\n' "$_rl" | head -n1 | cut -d: -f1)" = "$(printf '%s\n' "$_rm" | head -n1 | cut -d: -f1)" ]; then
            key_row main "$_ra" "$_rl"
        else key_row main '' "$_rl"; fi
    fi
    if [ "$_rmode" = intent ] && [ "$(cat "$ENODIA_STATE/.failover-mode" 2>/dev/null | tr -d ' \t\r\n')" = home ]; then
        _rh=$(cat "$ENODIA_STATE/.failover-home" 2>/dev/null | tr -d ' \r\n')
        if [ -n "$_rh" ] && [ "$_rh" != "$_ra" ] && valid_config "$_rh"; then
            key_row main "$_rh" "$(awg_key_file "$AWG_CONFIGS/$_rh.conf")"
        fi
    fi
    [ -s "$SLOTS_FILE" ] || return 0
    # `|| [ -n ]` — последняя строка без перевода строки не теряется (busybox read).
    while IFS="$TAB" read -r _ri _rn _rt _rc _rf _re || [ -n "$_ri" ]; do
        [ "$_rt" = awg ] || continue
        if [ "$_rmode" = intent ]; then _rk=$(awg_key_file "$AWG_CONFIGS/$_rc.conf")
        else [ "$_re" = on ] || continue; _rk=$(awg_key_live "awg$_ri"); fi
        key_row "s$_ri" "$_rc" "$_rk"
    done < "$SLOTS_FILE"
}
# СВЕРКА — ОДНА на все вопросы: stdin = R-строки держателей, затем C-строки конфигов; -v self = кто спрашивает (main | s<N> |
# none — «все»; себя пропускаем: выход не конфликтует сам с собой, основной — сам с собой). Печатает «конфиг⇥кто⇥имя» на каждое
# совпадение: приватники равны И пиры равны (или пира нет с одной из сторон). Без split()/функций — busybox awk их не умеет.
KEY_MATCH_AWK='
$1 == "R" { n++; rw[n] = $2; rn[n] = $3; rp[n] = $4; next }
$1 == "C" {
    ck = $3; sub(/:.*/, "", ck); ce = ""; if ($3 ~ /:/) { ce = $3; sub(/^[^:]*:/, "", ce) }
    for (i = 1; i <= n; i++) {
        if (rw[i] == self) continue
        rk = rp[i]; sub(/:.*/, "", rk)
        if (rk == "" || rk != ck) continue
        re = ""; if (rp[i] ~ /:/) { re = rp[i]; sub(/^[^:]*:/, "", re) }
        if (ce != "" && re != "" && ce != re) continue
        print $2 "\t" rw[i] "\t" rn[i]
    }
}'
key_match() {   # $1 = R-строки (key_rows), $2 = self; stdin — C-строки
    { printf '%s\n' "$1"; cat; } | awk -F"$TAB" -v self="$2" "$KEY_MATCH_AWK"
}
# Человеческая причина отказа — ОДНА формулировка на все точки (выход и основной канал говорят одно).
# $1 = имя конфига, $2 = «main⇥имя» | «s<N>⇥имя» (держатель).
key_busy_msg() {
    _mh=$(printf '%s' "$2" | cut -f1); _mhn=$(printf '%s' "$2" | cut -f2)
    # Держатель «main» — СЕРВЕР AmneziaWG основного канала, и называем его так: он занят и тогда, когда основной сейчас
    # другой протокол (резервом и для возврата AmneziaWG держит именно его), и «занят основным каналом» при xray сбивало бы.
    case "$_mh" in
        main) _mwho="сервер AmneziaWG основного канала" ;;
        *)    _mwho="конфиг выхода №${_mh#s}" ;;
    esac
    if [ "$_mhn" = "$1" ]; then
        _mwhat="конфиг «$1» уже занят: это $_mwho"
    elif [ -n "$_mhn" ]; then
        _mwhat="у конфига «$1» тот же ключ, что у «$_mhn», а это $_mwho"
    else
        _mwhat="у конфига «$1» тот же ключ, что у $(printf '%s' "$_mwho" | sed 's/^сервер /сервера /; s/^конфиг /конфига /')"
    fi
    echo "$_mwhat. Один ключ AmneziaWG не держит два подключения: сервер оставит одно, и второе будет постоянно отваливаться. Заведите отдельный конфиг (с другим ключом)."
}
key_self() { case "$1" in main|none) printf '%s' "$1" ;; *) printf 's%s' "$1" ;; esac; }
# key-holder <имя конфига> <main|2|3|4> [live] — CLI-вход для switch-vpn.sh (intent) и transport-awg.sh (live).
# Код: 0 — ЗАНЯТ (в stdout причина словами), 1 — свободен, 2 — судить не по чему (нет файла/ключа).
cmd_key_holder() {
    _kc="$1"; _ks=$(key_self "$2"); _kmode=intent; [ "$3" = live ] && _kmode=live
    valid_config "$_kc" && [ "$_kc" != '-' ] || return 2
    [ -f "$AWG_CONFIGS/$_kc.conf" ] || return 2
    _kid=$(awg_ids "$AWG_CONFIGS/$_kc.conf"); [ -n "$_kid" ] || return 2
    _kh=$(printf '%s\n' "$_kid" | key_match "$(key_rows "$_kmode")" "$_ks" | head -n1 | cut -f2-)
    [ -n "$_kh" ] || return 1
    key_busy_msg "$_kc" "$_kh"
    return 0
}
# key-map — ПОМЕТКИ для выбора конфига в панели: «имя⇥держатели» (через запятую: main, s2…) по каждому
# конфигу configs/, чей ключ держит основной канал или выход (intent). Сами их конфиги — тоже: панель вычтет
# «себя» и отличит «это мой» от «занят чужим»; ВСЕ держатели, а не первый — иначе при двух выходах на
# одном ключе (импорт бэкапа, ручная правка) предупреждение досталось бы только одному. Незанятые не печатаем.
cmd_key_map() {
    [ -d "$AWG_CONFIGS" ] || return 0
    # Только читаемые файлы: busybox awk на первом же нечитаемом (каталог с именем *.conf, битые права) бросает ВЕСЬ проход, и
    # пометок не осталось бы ни у одного конфига.
    set --; for _kf in "$AWG_CONFIGS"/*.conf; do [ -f "$_kf" ] && [ -r "$_kf" ] && set -- "$@" "$_kf"; done
    [ $# -gt 0 ] || return 0
    awg_ids "$@" | key_match "$(key_rows intent)" none | awk -F"$TAB" '
        { kk = $1 "\t" $2; if (kk in s) next; s[kk] = 1
          if ($1 in h) h[$1] = h[$1] "," $2; else { k++; o[k] = $1; h[$1] = $2 } }
        END { for (i = 1; i <= k; i++) print o[i] "\t" h[o[i]] }'
}
# Гард назначения конфига ВЫХОДУ (add/set config/enable): занят — отказ причиной. $1 = транспорт,
# $2 = конфиг, $3 = id выхода (у add — «new»: себя в реестре ещё нет).
slot_key_guard() {
    [ "$1" = awg ] || return 0
    _kg=$(cmd_key_holder "$2" "$3") || return 0
    echo "[slots] $_kg"
    return 1
}

cmd_add() {
    name="$1"; t="$2"; cfg="${3:--}"; fb="${4:-main}"
    [ -n "$name" ] || { echo "[slots] имя обязательно"; return 1; }
    valid_transport "$t" || { echo "[slots] неизвестный транспорт '$t' (awg|xray|hy2|byedpi|zapret)"; return 1; }
    valid_config "$cfg" || { echo "[slots] недопустимое имя конфига (буквы, цифры, . _ - или '-')"; return 1; }
    case "$fb" in main|direct) ;; *) echo "[slots] fallback = main|direct"; return 1 ;; esac
    # Лок держим на ВЕСЬ выбор id + запись: без него два клика панели выбрали бы ОДИН свободный
    # id и второй затёр бы первый (или строки склеились). Сверка ключа — ПОД ТЕМ ЖЕ локом: два одновременных add на один
    # свободный конфиг иначе оба прошли бы гард (ревью 27.09.2026). У set/enable гонку добирает последний рубеж — подъём
    # выхода (live): из двух выходов на одном ключе встаёт первый.
    slots_lock_take || { echo "[slots] реестр занят другой операцией — повторите"; return 1; }
    slot_key_guard "$t" "$cfg" new || { slots_lock_drop; return 1; }
    id=""
    i=$MIN_ID
    while [ "$i" -le "$MAX_ID" ]; do
        [ -z "$(slot_line "$i")" ] && { id=$i; break; }
        i=$((i+1))
    done
    [ -n "$id" ] || { slots_lock_drop; echo "[slots] мест нет (лимит $((MAX_ID-MIN_ID+1)) доп-выхода)"; return 1; }
    _slots_write "$id" "$(b64e "$name")" "$t" "$cfg" "$fb" on
    slots_lock_drop
    # Строка пишется сразу en=on ⇒ выход ОБЯЗАН начать работать здесь же, а не через тик
    # watchdog: поднимаем несущую и переигрываем владельцев (ровно как enable) — см. slot_activate.
    slot_activate "$id"
    # «-» = «конфига нет» (zapret) — в сообщении не показываем, иначе «(zapret · -)».
    if [ "$cfg" = '-' ]; then _cfgh=""; else _cfgh=" · $cfg"; fi
    echo "[slots] выход №$id «$name» ($t$_cfgh) создан, fallback=$fb"
}

# rename-config <транспорт> <старое> <новое> — конфиг ПЕРЕИМЕНОВАН (cgi-bin/action::rename_config): у всех выходов этого
# транспорта со старым именем поле config → новое. Несущую НЕ трогаем: работающий демон держит уже прочитанный конфиг, а его
# рабочая копия названа по НОМЕРУ слота. Без правки реестра первый же переподъём (сторож, heal, ребут) не нашёл бы конфиг и увёл
# выход на запасной путь. Печатает число переписанных строк (0 — выходов на этом конфиге нет).
cmd_rename_config() {
    t="$1"; old="$2"; new="$3"
    valid_transport "$t" || { echo "[slots] неизвестный транспорт '$t'"; return 1; }
    { [ "$old" != '-' ] && valid_config "$old" && [ "$new" != '-' ] && valid_config "$new"; } \
        || { echo "[slots] недопустимое имя конфига"; return 1; }
    [ -f "$SLOTS_FILE" ] || { echo 0; return 0; }
    slots_lock_take || { echo "[slots] реестр занят другой операцией — повторите"; return 1; }
    # Новое имя уже указано у выхода (его сервер удалили, а ссылка осталась) — переименование ТИХО привязало бы этот выход к
    # переименованному серверу. Отказ словами. Откат (обратное переименование, когда `mv` файла не удался) проходит ту же проверку,
    # но старого имени у выходов после прямого прохода уже нет — отказа не будет.
    _rdup=$(awk -F"$TAB" -v t="$t" -v n="$new" '$3==t && $4==n { print $1; exit }' "$SLOTS_FILE" 2>/dev/null)
    if [ -n "$_rdup" ]; then slots_lock_drop; echo "[slots] имя «$new» уже указано у выхода №$_rdup — выберите другое"; return 1; fi
    _rn=0; _rtmp="$SLOTS_FILE.$$"
    : > "$_rtmp"
    # `|| [ -n ]` — последняя строка без перевода строки не теряется (busybox read).
    while IFS="$TAB" read -r _i _nb _t _c _f _e || [ -n "$_i" ]; do
        [ -n "$_i" ] || continue
        if [ "$_t" = "$t" ] && [ "$_c" = "$old" ]; then _c="$new"; _rn=$((_rn+1)); fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_i" "$_nb" "$_t" "$_c" "$_f" "$_e" >> "$_rtmp"
    done < "$SLOTS_FILE"
    if [ "$_rn" -gt 0 ]; then mv "$_rtmp" "$SLOTS_FILE"; else rm -f "$_rtmp"; fi
    slots_lock_drop
    echo "$_rn"
}

# Переписать одно поле строки id. Правка через временный файл + mv (атомарно на /data,
# как весь персист проекта) — sed по TSV с base64 внутри хрупок, собираем строку заново.
cmd_set() {
    id="$1"; field="$2"; val="$3"
    valid_id "$id" || { echo "[slots] id = 2..4"; return 1; }
    line=$(slot_line "$id"); [ -n "$line" ] || { echo "[slots] нет слота №$id"; return 1; }
    old_nb=$(echo "$line" | cut -f2); old_t=$(echo "$line" | cut -f3)
    old_cfg=$(echo "$line" | cut -f4); old_fb=$(echo "$line" | cut -f5); old_en=$(echo "$line" | cut -f6)
    case "$field" in
        name)      old_nb=$(b64e "$val") ;;
        transport) valid_transport "$val" || { echo "[slots] неизвестный транспорт '$val'"; return 1; }
                   old_t="$val" ;;
        config)    valid_config "$val" || { echo "[slots] недопустимое имя конфига (буквы, цифры, . _ - или '-')"; return 1; }
                   old_cfg="$val" ;;
        fallback)  case "$val" in main|direct) ;; *) echo "[slots] fallback = main|direct"; return 1 ;; esac
                   old_fb="$val" ;;
        *) echo "[slots] поле = name|transport|config|fallback"; return 1 ;;
    esac
    # Сверка ключа — и при смене КОНФИГА, и при смене ТРАНСПОРТА на awg (конфиг тот, что уже записан).
    case "$field" in transport|config) slot_key_guard "$old_t" "$old_cfg" "$id" || return 1 ;; esac
    # Несущая ВКЛЮЧЁННОГО выхода уже поднята по СТАРЫМ (транспорт, конфиг) — одной записи в реестр
    # мало: демон продолжил бы ходить прежним сервером («сменил сервер, а выход тот же»), а смена
    # ТРАНСПОРТА ещё и осиротила бы старую несущую (следующий slot-down ушёл бы уже в НОВЫЙ плагин,
    # и демон/tun/table прежнего остались бы жить). Поэтому: down СТАРЫМ плагином (реестр ещё
    # старый и en=on — диспетч требует именно этого) → запись → up НОВЫМ.
    reup=0
    case "$field" in transport|config) [ "$old_en" = on ] && reup=1 ;; esac
    [ "$reup" = 1 ] && [ -f "$ENODIA_DIR/transport.sh" ] && sh "$ENODIA_DIR/transport.sh" slot-down "$id" >/dev/null 2>&1
    slots_lock_take || { echo "[slots] реестр занят другой операцией — повторите"; return 1; }
    _slots_write "$id" "$old_nb" "$old_t" "$old_cfg" "$old_fb" "$old_en"
    slots_lock_drop
    # VPN выключен вручную — несущая выхода не поднимется (плагин при флаге отказывает, daemon-lib.sh::carrier_run), и «идёт по
    # запасному пути» было бы неправдой: при выключенном VPN выход не ведёт никуда. Поднимет «Включить VPN».
    if [ "$reup" = 1 ] && [ -f "$ENODIA_STATE/.vpn-off" ]; then
        echo "[slots] слот №$id: $field обновлён; VPN выключен вручную — выход поднимется при включении"
        return 0
    fi
    if [ "$reup" = 1 ]; then
        if [ -f "$ENODIA_DIR/transport.sh" ] && sh "$ENODIA_DIR/transport.sh" slot-up "$id" >/dev/null 2>&1; then
            echo "[slots] слот №$id: $field обновлён, несущая перезапущена"
        else
            echo "[slots] слот №$id: $field обновлён, но несущая не поднялась — выход идёт по запасному пути"
        fi
        return 0
    fi
    # fallback — политику ip rule держит mark-core (владелец правил слота): без переигровки у
    # выхода с УПАВШЕЙ несущей осталась бы прежняя политика (main вместо direct и наоборот).
    if [ "$field" = fallback ] && [ "$old_en" = on ] && [ -f "$ENODIA_DIR/mark-core.sh" ]; then
        sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1
    fi
    echo "[slots] слот №$id: $field обновлён"
}

# Переписать поле en (6-е) строки слота id: под локом, атомарно tmp+mv (как cmd_set).
write_en() {
    slots_lock_take || { echo "[slots] реестр занят другой операцией — повторите"; return 1; }
    line=$(slot_line "$1")
    [ -n "$line" ] || { slots_lock_drop; return 1; }
    _slots_write "$1" "$(printf '%s' "$line" | cut -f2)" "$(printf '%s' "$line" | cut -f3)" \
                 "$(printf '%s' "$line" | cut -f4)" "$(printf '%s' "$line" | cut -f5)" "$2"
    slots_lock_drop
}
# Переиграть ВЛАДЕЛЬЦЕВ слот-сетов после смены состояния слота (enable/disable/del).
# ЗАЧЕМ (грабля, поймана на железе 2026-07-26): «какой сет наполнять» решают groups.sh/geo.sh в
# своём do_apply — гейт «привязка к ВЫКЛЮЧЕННОМУ слоту → основной сет (grp_vpn/geo_vpn)». Сам по
# себе disable этот гейт не переигрывает: правила слота мы сняли (unwire), а члены остались в
# осиротевшем grp_vpn_s<N>/geo_vpn_s<N>, на который уже нет НИ ОДНОГО mangle-правила ⇒ пул идёт
# НАПРЯМУЮ (fail-open мимо VPN), хотя fallback=main обещает основной выход; чинилось лишь
# следующим редактированием правил/ребутом. Симметрично на enable: члены сидят в общем grp_vpn и
# едут основным выходом, пока владелец не пересоберётся — «включил выход, а пул не поехал».
# Зовём ТОЛЬКО тех владельцев, у кого реально есть привязка к этому слоту (иначе даром гоняем
# сборку): groups — синхронно (дёшево, ровно как при правке группы), geo — ФОНОМ через тот же
# пидфайл /tmp/enodia-geo.pid, что и CGI geo_apply (пересбор каталога ~1600 элементов держать в
# CGI-запросе нельзя; geo.sh сам сериализуется ls_lock).
rebind_owners() {
    id="$1"
    # Гарды `-f`, а НЕ `-x` (класс Б5-9): все три зовутся через `sh`, бит выполнения им не нужен,
    # а снятый (заливка по scp/base64, ручная копия, чужой архиватор) означал бы ТИХИЙ пропуск
    # пересборки — привязанные к выходу группы/гео/устройства остались бы в осиротевшем сете без
    # mangle, то есть молча поехали мимо выхода. Ровно ради этого rebind_owners и существует.
    if [ -f "$ENODIA_DIR/groups.sh" ] && [ -s "$ENODIA_STATE/groups/groups.tsv" ] &&
       awk -F"$TAB" -v s="$id" '$4==s{f=1} END{exit !f}' "$ENODIA_STATE/groups/groups.tsv" 2>/dev/null; then
        sh "$ENODIA_DIR/groups.sh" apply >/dev/null 2>&1 || true
    fi
    # Устройства, целиком привязанные к ЭТОМУ выходу (.fullvpn-ips, 2-я колонка): их марку ставит
    # VPN_FORCE, и без пересборки выключение выхода означало бы «марка есть, ip rule нет» =
    # устройство молча ушло НАПРЯМУЮ мимо VPN. Дёшево и синхронно, как groups.
    if [ -f "$ENODIA_DIR/apply-bypass.sh" ] && [ -s "$ENODIA_STATE/.fullvpn-ips" ] &&
       awk -F"$TAB" -v s="s$id" '$2==s{f=1} END{exit !f}' "$ENODIA_STATE/.fullvpn-ips" 2>/dev/null; then
        sh "$ENODIA_DIR/apply-bypass.sh" force-rebind >/dev/null 2>&1 || true
    fi
    if [ -f "$ENODIA_DIR/geo.sh" ] && [ -s "$ENODIA_STATE/geo/actions.tsv" ] &&
       awk -F"$TAB" -v s="$id" '$5==s{f=1} END{exit !f}' "$ENODIA_STATE/geo/actions.tsv" 2>/dev/null; then
        if [ -x /sbin/start-stop-daemon ]; then
            rm -f /tmp/enodia-geo.pid 2>/dev/null
            start-stop-daemon -S -b -m -p /tmp/enodia-geo.pid -x /bin/sh -- "$ENODIA_DIR/geo.sh" apply >/dev/null 2>&1
        else
            ( sh "$ENODIA_DIR/geo.sh" apply >/dev/null 2>&1 & )
        fi
    fi
}

# Ввести слот В СТРОЙ: поднять несущую + переиграть владельцев слот-сетов. ОБЩЕЕ для создания
# (cmd_add пишет строку сразу en=on) и включения (cmd_toggle on) — «выход есть и он on» обязан
# означать одно и то же независимо от пути; звать ТОЛЬКО когда в реестре уже лежит en=on
# (диспетч slot-up в плагин читает поле en — _slot_dispatch). Оркестратор сам переиграет
# mark-core (и марку non-zapret-слота, и врайринг zapret-слота).
# Грабля (железо, 2026-07-26): cmd_add ЭТОГО не делал — «удалил выход и создал заново» (а это
# был ЕДИНСТВЕННЫЙ способ сменить сервер до dev51) оставляло привязанные группы/гео в ОСНОВНОМ
# сете: del честно вернул их в grp_vpn, а add обратно в grp_vpn_s<N> не забрал. Правила слота
# стояли, сет был ПУСТ ⇒ пул молча ехал основным VPN. Несущую тем временем поднимал лишь
# следующий тик watchdog (idem-slot-up) — до него выход не работал вовсе.
slot_activate() {
    id="$1"
    if [ -f "$ENODIA_DIR/transport.sh" ]; then sh "$ENODIA_DIR/transport.sh" slot-up "$id" >/dev/null 2>&1
    else [ -f "$ENODIA_DIR/mark-core.sh" ] && sh "$ENODIA_DIR/mark-core.sh" >/dev/null 2>&1; fi
    rebind_owners "$id"   # привязанные пулы обязаны переехать в сет ЭТОГО выхода
}

cmd_toggle() {
    id="$1"; en="$2"
    valid_id "$id" || { echo "[slots] id = 2..4"; return 1; }
    [ -n "$(slot_line "$id")" ] || { echo "[slots] нет слота №$id"; return 1; }
    TRANSPORT_SH="$ENODIA_DIR/transport.sh"
    if [ "$en" = on ]; then
        # Выход, заведённый ДО гарда (или приехавший импортом бэкапа), мог получить занятый ключ: включение
        # — та же точка назначения, что add/set, и отказывает той же причиной, не трогая реестр.
        _tl=$(slot_line "$id")
        slot_key_guard "$(printf '%s' "$_tl" | cut -f3)" "$(printf '%s' "$_tl" | cut -f4)" "$id" || return 1
        # Порядок: сперва пишем on (диспетч slot-up в плагин ТРЕБУЕТ включённый слот —
        # _slot_dispatch читает поле en), затем ввод в строй. Запись не прошла (реестр занят) —
        # НЕ активируем: диспетч всё равно увидел бы off, а мы отрапортовали бы «включён».
        write_en "$id" on || return 1
        slot_activate "$id"
        echo "[slots] слот №$id включён"
    else
        # Порядок: slot-down ПОКА слот ещё on (диспетч требует on: плагин снимает свою несущую/
        # десинк), ПОТОМ пишем off и снимаем ядро-следы (mark/ip rule) — cmd_unwire.
        [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-down "$id" >/dev/null 2>&1
        write_en "$id" off || return 1
        cmd_unwire "$id"
        rebind_owners "$id"   # иначе пул выхода останется в осиротевшем сете = НАПРЯМУЮ мимо VPN
        echo "[slots] слот №$id выключен"
    fi
}

# Снять СЛЕДЫ слота из ядра: MARK/ACCEPT его сетов в mangle + ip rule его марки. Сеты и
# таблицу НЕ трогаем (сеты — собственность groups/geo, несущую слота опустит её плагин в Ф1+).
# После снятия mangle-правил ОБЯЗАТЕЛЕН conntrack -F: NSS/ECM-offload держит старый маршрут
# для установленных соединений (грабля проекта). Дешёвого точечного -D по сету нет — флашим.
cmd_unwire() {
    id="$1"
    valid_id "$id" || { echo "[slots] id = 2..4"; return 1; }
    for sset in "grp_vpn_s$id" "geo_vpn_s$id"; do
        for chain in PREROUTING OUTPUT; do
            while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j ACCEPT 2>/dev/null; do :; done
            while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j MARK --set-mark "0x$id" 2>/dev/null; do :; done
        done
    done
    ip rule del fwmark "0x$id" table "100$id" 2>/dev/null || true
    # fallback=main держит правило слота в table 1000 (FALLBACK-AWARE в mark-core) — снимаем
    # ОБЕ формы (без pref: матч по fwmark 0xN однозначен, основной 0x1 не заденем).
    ip rule del fwmark "0x$id" table 1000 2>/dev/null || true
    ct_flush
}

cmd_del() {
    id="$1"
    valid_id "$id" || { echo "[slots] id = 2..4"; return 1; }
    line=$(slot_line "$id"); [ -n "$line" ] || { echo "[slots] нет слота №$id"; return 1; }
    # Включённый слот — сперва опустить несущую/десинк через оркестратор (строка ещё on, диспетч
    # работает), потом снять ядро-следы и удалить из реестра.
    if [ "$(printf '%s' "$line" | cut -f6)" = on ] && [ -f "$ENODIA_DIR/transport.sh" ]; then
        sh "$ENODIA_DIR/transport.sh" slot-down "$id" >/dev/null 2>&1
    fi
    cmd_unwire "$id"
    slots_lock_take || { echo "[slots] реестр занят другой операцией — повторите"; return 1; }
    _slots_write "$id"          # без полей = удалить строку (последняя ⇒ файл убираем целиком)
    slots_lock_drop
    # Реестра слота больше нет — привязки (groups.slot/geo.slot) осиротели: переигрываем
    # владельцев ПОСЛЕ удаления строки, чтобы гейт увидел «слота нет» и вернул пул на основной.
    rebind_owners "$id"
    echo "[slots] слот №$id удалён (правила сняты)"
}

case "$1" in
    list)         cmd_list ;;
    list-enabled) cmd_list_enabled ;;
    list-json)    cmd_list_json ;;
    state)        cmd_state ;;
    carriers)     cmd_carriers ;;
    show)         slot_line "$2" ;;
    domains)      cmd_domains "$2" "$3" ;;
    route)        cmd_route "$2" "$3" ;;
    add)          cmd_add "$2" "$3" "$4" "$5" ;;
    set)          cmd_set "$2" "$3" "$4" ;;
    enable)       cmd_toggle "$2" on ;;
    disable)      cmd_toggle "$2" off ;;
    del)          cmd_del "$2" ;;
    unwire)       cmd_unwire "$2" ;;
    rename-config) cmd_rename_config "$2" "$3" "$4" ;;
    key-holder)   cmd_key_holder "$2" "$3" "$4" ;;
    key-map)      cmd_key_map ;;
    *) echo "usage: $0 list|list-enabled|list-json|state|carriers|show <id>|domains <id|0> [кап]|route <id|0> <домен>|add <имя> <транспорт> [конфиг] [fallback]|set <id> <поле> <знач>|enable <id>|disable <id>|del <id>|unwire <id>|rename-config <транспорт> <старое> <новое>|key-holder <конфиг> <main|2..4> [live]|key-map"; exit 2 ;;
esac
