#!/bin/sh
# mark-core.sh — ТРАНСПОРТ-АГНОСТИЧНОЕ ядро PBR-маршрутизации.
#
# Часть плана «транспорт-агностичное ядро + плагины». Это бывшие
# ШАГИ 2-3 split-route.sh, вычищенные от всего, что привязано к КОНКРЕТНОЙ несущей:
# маркировка пакетов по ipset (mangle -m set -> MARK 0x1) + правило ip rule
# fwmark 0x1 -> table 1000. Больше НИЧЕГО.
#
# ПОЧЕМУ ОТДЕЛЬНО. Раньше split-route.sh мешал ядро и несущую в кучу и под set -e
# первой же строкой делал `ip route add default dev awg0` — без awg0 он аварийно
# падал, и маркировка (это ядро) не накладывалась ВООБЩЕ. Из-за этого нельзя было
# поднять VPN на одном лишь Xray (без awg). Теперь ядро не знает про несущую:
# `default dev <iface> table 1000` ставит активный transport-*.sh (awg0 / xtun / ...).
#
# ИДЕМПОТЕНТНО, БЕЗ set -e: сетов может ещё не быть (ipset живёт в RAM, на boot
# пуст до наполнения) — тогда соответствующую маркировку просто пропускаем, как
# делал split-route. Падать на отсутствии одного из сетов нельзя.
#
# БЕЗОПАСНОСТЬ. Само по себе ядро НЕ направляет трафик в туннель — оно лишь МЕТИТ
# и заводит ip rule на table 1000. Пока активный транспорт не положит туда default,
# table 1000 пуста -> fwmark-трафик уходит в main -> НАПРЯМУЮ (fail-open).

FWMARK=0x1
TABLE=1000

# `mark-core.sh unwire` — ТО ЖЕ САМОЕ, но без add: снять всё, что ставит ядро (деинсталляция,
# uninstall.sh). Второй копии списка правил быть не должно — она отстанет от этой при первой же
# правке (ровно так отставал инлайн-дубль в vpn-toggle.sh repair). Механика простая: каждый блок
# УЖЕ начинается с delete-петли ради идемпотентности, unwire просто пропускает вставку.
UNWIRE=0
[ "${1:-}" = unwire ] && UNWIRE=1

# --- ВЫКЛЮЧЕНО ЧЕЛОВЕКОМ: ядра НЕ СТАВИМ ВОВСЕ ------------------------------------------------
# `vpn-toggle.sh off` с 02.09.2026 — это СОСТОЯНИЕ (флаг на /data, переживает ребут). Гейт живёт
# ЗДЕСЬ, а не у вызывателей, потому что вызывателей у ядра ПЯТЕРО (heal, groups.sh, geo.sh,
# transport.sh switch, vpn-toggle repair) — держать проверку у каждого значит забыть её у
# шестого. Замерено 02.09.2026: `groups.sh apply` и `geo.sh reapply` зовут mark-core, когда их
# сет ещё без правила, — то есть на буте роутера С ГРУППАМИ выключенный VPN получил бы обратно
# и метки, И `ip rule`, и тумблер бы врал. Тот же класс, что «две двери к метке iplist_set».
# `unwire` НЕ гейтим НИКОГДА: снять правила при выключенном VPN — ровно то, чего человек хотел
# (иначе `uninstall.sh` не смог бы убрать за собой на выключенном роутере).
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# …И КАТАЛОГ КОДА — ТОЖЕ ПЕРЕМЕННОЙ. Раньше в этом файле переменных путей не было вовсе, и
# четыре места (ipt-lib, .panel-tls, server/port, slots.sh) читали ЛИТЕРАЛ ФЛЕША — «абсолютный,
# чтобы пустая переменная не превратилась в /ipt-lib.sh». Замер на живом BE7000 02.09.2026 в
# раскладке `full` (код и состояние на накопителе): литералов не существует, и ЯДРО МАРКИРОВКИ
# молча теряло разом слот-цикл (доп-выходы без марок и без своего `ip rule`), гард порта TLS
# панели, гард порта «доступа домой» и ОЖИДАНИЕ xtables-лока — при зелёном выводе «маркировка
# применена». Окружение к этому моменту УЖЕ правильное: единственные, кто нас зовёт, — cron
# через boot.sh и панель через cgi-paths.sh, а они экспортируют пути. Форма `${VAR:-литерал}`
# оставляет прежнее поведение там, где кода на накопителе нет (следит C60).
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
if [ "$UNWIRE" = 0 ] && [ -f "$ENODIA_STATE/.vpn-off" ]; then
    echo "[mark-core] VPN выключен человеком (.vpn-off) — правил не ставлю (вернёт vpn-toggle.sh on)"
    exit 0
fi

# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят чужим
# кроном ⇒ без ожидания правило МОЛЧА не встаёт, а ядро кладёт их десятками за один прогон. Путь
# ИЗ ПЕРЕМЕННОЙ (см. объявление выше): по литералу флеша в раскладке `full` файла нет, и
# ожидание лока пропадало молча — правило не встаёт, а stderr у половины вызовов заглушен.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi

# --- reply-guard: НЕ метим трафик, адресованный САМОМУ роутеру --------------------
# ГРАБЛЯ (найдено 08.07.2026 на железе тестера). Маркировка ниже бьёт по dst в mangle
# PREROUTING, а этот хук стоит РАНЬШЕ обратного NAT (приоритеты в PREROUTING: conntrack
# -200 -> mangle -150 -> nat/un-NAT -100). Для ОТВЕТНОГО пакета прямого соединения dst в
# этот момент ещё = наш WAN-IP (обратный SNAT вернёт его на клиента только на -100). Если
# WAN-IP провайдера попал в iplist_set (у части ISP их подсеть есть в opencck-листе — у
# тестера), ответ метится 0x1 и уезжает в table $TABLE -> в туннель вместо
# клиента. Итог — рвётся ВЕСЬ возврат прямого трафика (и рунет, и забугор), а не отдельный
# сайт. Лечим СТРУКТУРНО: пакеты к ЛЮБОМУ локальному адресу роутера (в т.ч. WAN-IP на
# обратном пути) выводим из mangle РАНЬШЕ MARK. Ключевое:
#   * -j ACCEPT, НЕ RETURN — в mangle RETURN не спасает от последующего MARK (та же грабля,
#     что у VPN_EXCLUDE); ACCEPT завершает обход ТОЛЬКО mangle-таблицы, un-NAT/routing идут
#     дальше штатно -> ответ возвращается клиенту;
#   * только PREROUTING — OUTPUT-маркировку роутер-локального трафика к CIDR (напр. gh-update
#     к raw.github) НЕ трогаем;
#   * идемпотентно (-I 1 = поверх MARK; delete-loop чистит старые дубли);
#   * требует модуля addrtype (у стокового fw3 обычно есть) — нет, честно кричим.
# ВНИМАНИЕ при отладке: после правки нужен conntrack -F (NSS/ECM-offload держит старый путь).
while iptables -t mangle -D PREROUTING -m addrtype --dst-type LOCAL -j ACCEPT 2>/dev/null; do :; done
if [ "$UNWIRE" = 0 ]; then
    if iptables -t mangle -I PREROUTING 1 -m addrtype --dst-type LOCAL -j ACCEPT 2>/dev/null; then
        echo "[mark-core] reply-guard: dst-LOCAL ACCEPT (обратный трафик к WAN-IP не метится)"
    else
        echo "[mark-core] ВНИМАНИЕ: addrtype недоступен — reply-guard НЕ поставлен (риск залипания возврата прямого трафика, если WAN-IP в iplist_set)"
    fi
fi

# --- notify-guard: письма-уведомления с САМОГО роутера ВСЕГДА мимо туннеля -------
# ГРАБЛЯ/ЗАЧЕМ. notify.sh шлёт письмо ИМЕННО когда VPN упал (его зовёт watchdog).
# Раньше «мимо awg0» держалось лишь на том, что Яндекс-SMTP — российский IP и не попадал
# в iplist_set. Но пользователь вправе взять ЛЮБОЙ SMTP (Gmail/Outlook/свой домен), а IP
# Gmail (=Google) ЛЕЖИТ в opencck-листе (iplist_set) → router-локальный пакет к нему метится
# 0x1 в mangle OUTPUT → уходит в table $TABLE → в ДОХЛЫЙ awg0 → письмо не уходит РОВНО когда
# нужно (а при живом VPN — светит SMTP-логин/пароль через VPS). Выводим router-локальный
# SMTP-submission из mangle OUTPUT РАНЬШЕ MARK → он остаётся немаркированным → main-таблица →
# напрямую через провайдера. Гарантия «100% мимо VPN» для ЛЮБОГО SMTP-хоста, не завися от его IP.
#   * -j ACCEPT, НЕ RETURN — в mangle RETURN не спасает от последующего MARK (та же грабля,
#     что у VPN_EXCLUDE / reply-guard); ACCEPT завершает обход ТОЛЬКО mangle → routing штатный;
#   * только OUTPUT + submission-порты (465/587/25) → затрагивает лишь трафик САМОГО роутера
#     (=notify.sh; клиенты идут PREROUTING/FORWARD, их SMTP это НЕ трогает);
#   * per-port `--dport` (без multiport-модуля) → работает на любом стоковом iptables;
#   * идемпотентно (-I 1 поверх MARK; delete-loop чистит дубли). Реплеится heal/repair —
#     значит переживает ребут и fw3-reload наравне с самой маркировкой, которую обгоняет.
for p in 465 587 25; do
    while iptables -t mangle -D OUTPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
    [ "$UNWIRE" = 0 ] && iptables -t mangle -I OUTPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null
done
[ "$UNWIRE" = 0 ] && echo "[mark-core] notify-guard: router SMTP (465/587/25) мимо туннеля (письма-уведомления всегда напрямую)"

# --- panel-guard: ОТВЕТЫ веб-панели наружу ВСЕГДА мимо туннеля --------------------
# ТА ЖЕ грабля с другого конца. При включённом «входе снаружи» (web-ui.sh wan-on) клиент приходит
# на TLS-порт панели, а ОТВЕТ рождается локально на роутере и идёт через mangle OUTPUT. Если IP
# пришедшего клиента лежит в iplist_set (это тысячи ЧУЖИХ подсетей — мобильный роуминг, зарубежный
# провайдер, сам под VPN), ответ пометится 0x1 и уедет В ТУННЕЛЬ: клиент не увидит ответа вовсе,
# соединение молча повиснет, и выглядеть это будет как «порт закрыт». Отсюда — вывод по SPORT
# (наш ответ узнаётся по ИСХОДНОМУ порту, адрес клиента заранее неизвестен). Порт читаем из
# персиста; HTTPS выключен — гарда нет, лишних правил не держим.
# Путь АБСОЛЮТНЫЙ (как SLOTS_SH ниже): переменных путей в этом скрипте нет вовсе, и подстановка
# пустой переменной молча читала бы /.panel-tls — гард не встал бы вовсе, а сообщение молчит.
# Каталог — СОСТОЯНИЯ (enodia-state), не кода: персист пережил обновление и уехал туда.
# Ведущие нули срезаем (форма порта — у web-ui.sh::port_norm): флаг прежней формы «08443» iptables читает как восьмеричное и отвергает.
_ptls_port=$(cat "$ENODIA_STATE/.panel-tls" 2>/dev/null | tr -cd '0-9' | sed 's/^0*//')
if [ -n "$_ptls_port" ]; then
    while iptables -t mangle -D OUTPUT -p tcp --sport "$_ptls_port" -j ACCEPT 2>/dev/null; do :; done
    if [ "$UNWIRE" = 0 ]; then
        iptables -t mangle -I OUTPUT 1 -p tcp --sport "$_ptls_port" -j ACCEPT 2>/dev/null
        echo "[mark-core] panel-guard: ответы панели с :$_ptls_port мимо туннеля"
    fi
fi

# --- vpnsrv-guard: ОТВЕТЫ VPN-СЕРВЕРА («доступ домой») пиру ВСЕГДА мимо туннеля --------------
# Ровно та же логика, что у panel-guard, но по UDP: клиент приходит снаружи на порт vpn-server.sh,
# а ОТВЕТ рождается локально и идёт через mangle OUTPUT. Адрес пришедшего телефона заранее
# неизвестен и запросто лежит в iplist_set (мобильный оператор, роуминг, чужой Wi-Fi) ⇒ ответ
# пометился бы 0x1 и уехал В ТУННЕЛЬ: рукопожатие не завершается никогда, а выглядит это как
# «сервер не отвечает» при идеальном на вид файрволе. Узнаём свой ответ по ИСХОДНОМУ порту.
# Гард живёт ЗДЕСЬ, а не в vpn-server.sh: mark-core пересобирает OUTPUT целиком, и гард,
# поставленный снаружи, был бы смыт первым же переигрышем ядра.
_vsrv_port=$(cat "$ENODIA_STATE/server/port" 2>/dev/null | tr -cd '0-9')
if [ -n "$_vsrv_port" ]; then
    while iptables -t mangle -D OUTPUT -p udp --sport "$_vsrv_port" -j ACCEPT 2>/dev/null; do :; done
    if [ "$UNWIRE" = 0 ]; then
        iptables -t mangle -I OUTPUT 1 -p udp --sport "$_vsrv_port" -j ACCEPT 2>/dev/null
        echo "[mark-core] vpnsrv-guard: ответы VPN-сервера с :$_vsrv_port мимо туннеля"
    fi
fi

# --- слот-марки (мульти-транспорт, Ф0; дизайн: заметки разработки «мультитранспорт-дизайн») -----
# ДОП-ВЫХОДЫ (slots.sh): группа/гео, привязанные к слоту N, едут через СВОЮ несущую —
# марка 0xN -> ip rule pref 9N -> table 100N. Сеты слота: grp_vpn_sN / geo_vpn_sN
# (наполняют groups.sh/geo.sh; нет сета — пропускаем, как в базовом цикле).
# ПОЧЕМУ ЭТОТ БЛОК СТОИТ ПЕРЕД БАЗОВЫМ ЦИКЛОМ И СТАВИТ MARK+ACCEPT В ОБЕИХ ВЕТКАХ:
# приоритет = порядок правил. Группа слота обязана ПЕРЕБИВАТЬ общий iplist_set/enodia_list (0x1):
#   * miwifi-ветка: наши вставки на mpos идут РАНЬШЕ базовых => базовые лягут НИЖЕ (их insert
#     на пересчитанный mpos кладёт под уже вставленные) => первый матч (слот) выигрывает;
#   * append-ветка: базовые MARK без ACCEPT, слот-ACCEPT терминирует mangle ДО них;
#   * OUTPUT: слот аппендится раньше базовых, ACCEPT терминирует => слот выигрывает.
# Нет slots.sh / реестр пуст => блок no-op, поведение файла байт-в-байт прежнее (инертность
# по паттерну doh-lib). Несущая слота не поднята => отрабатывает fallback-политика реестра
# (см. FALLBACK-AWARE у ip rule ниже); хуже прямого пути не бывает — fail-open by construction.
# zapret-слот марок НЕ получает (десинк на ПРЯМОМ пути:
# ACCEPT+scoped NFQUEUE — забота Ф1/zapret.sh, не ядра). Снятие правил при del/disable —
# slots.sh unwire (ставим только мы: логика «выше miwifi» живёт здесь и только здесь).
SLOTS_SH="$ENODIA_DIR/slots.sh"
# Гард `-f` и вызов через `sh`, а НЕ `-x` + прямой запуск: бит исполнения теряется (копирование,
# частично доехавший apply-scripts, распаковка чужого архива), и тогда весь слот-цикл молча
# пропускался бы — сеты `grp_vpn_s<N>`/`geo_vpn_s<N>` без марки, «выход №N» тихо мимо VPN при
# «включено» в панели. Цена гарда тут максимальная в проекте, поэтому судим по НАЛИЧИЮ файла.
if [ -f "$SLOTS_SH" ]; then
    sh "$SLOTS_SH" list-enabled 2>/dev/null | while IFS="$(printf '\t')" read -r sid stransport _scfg sfb; do
        case "$sid" in [2-7]) ;; *) continue ;; esac
        [ "$stransport" = zapret ] && continue
        for sset in "grp_vpn_s$sid" "geo_vpn_s$sid"; do
            ipset list -n 2>/dev/null | grep -qx "$sset" || continue
            # чистка прежних копий (идемпотентность, зеркало базового цикла)
            for chain in PREROUTING OUTPUT; do
                while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j ACCEPT 2>/dev/null; do :; done
                while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid" 2>/dev/null; do :; done
            done
            [ "$UNWIRE" = 1 ] && continue
            mpos=$(iptables -t mangle -nL PREROUTING --line-numbers 2>/dev/null | awk '/miwifi|ipt_compiler|NFQUEUE/{print $1; exit}')
            if [ -n "$mpos" ]; then
                iptables -t mangle -I PREROUTING "$mpos" -m set --match-set "$sset" dst -j ACCEPT
                iptables -t mangle -I PREROUTING "$mpos" -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid"
            else
                iptables -t mangle -A PREROUTING -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid"
                iptables -t mangle -A PREROUTING -m set --match-set "$sset" dst -j ACCEPT
            fi
            iptables -t mangle -A OUTPUT -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid"
            iptables -t mangle -A OUTPUT -m set --match-set "$sset" dst -j ACCEPT
        done
        # ip rule слота — FALLBACK-AWARE. Владелец правила — ТОЛЬКО mark-core (тот же
        # инвариант «правила ставит ядро»): transport.sh/watchdog после up/down несущей
        # слота просто переигрывают нас, и правило само встаёт куда надо. Куда смотрит:
        #   * несущая слота ЖИВА (есть default в table 100N) -> своя table 100N;
        #   * несущей нет, fallback=main   -> table 1000 (трафик слота через ОСНОВНОЙ
        #     выход — приватность группы не рвётся; семантика «main» из дизайна);
        #   * несущей нет, fallback=direct -> table 100N ПУСТАЯ: lookup проваливается в
        #     main => напрямую (семантика ip rule: пустая таблица НЕ обрывает поиск).
        # Сносим ОБЕ формы (100N и fallback-1000; без pref — busybox-совместимость, матч
        # по fwmark 0xN однозначен) — иначе повторный проход плодил бы дубли.
        ip rule del fwmark "0x$sid" table "100$sid" 2>/dev/null || true
        ip rule del fwmark "0x$sid" table 1000 2>/dev/null || true
        [ "$UNWIRE" = 1 ] && { echo "[mark-core] слот №$sid: марки и ip rule сняты"; continue; }
        starget="100$sid"
        if ! ip route show table "100$sid" 2>/dev/null | grep -q '^default'; then   # not-wan: несущая СЛОТА (table 100N), у неё свой владелец — slots.sh
            [ "$sfb" = main ] && starget=1000
        fi
        ip rule add fwmark "0x$sid" table "$starget" pref "9$sid"
        echo "[mark-core] слот №$sid ($stransport): марка 0x$sid -> table $starget (pref 9$sid)"
    done
fi

# Маркируем пакеты к IP из ipset: enodia_list — IP резолвленных доменов (dnsmasq),
# iplist_set — CIDR от opencck. Несущей это не касается — кто несёт (awg0/xtun),
# решает активный транспорт через default в table $TABLE.
#
# ГРАБЛЯ (найдено 12.07.2026 на железе тестера — [[mipctld-nfqueue-fwmark-split]]).
# Стоковый Xiaomi-демон mipctld (родконтроль/QoS/антивирус Antiy) инспектирует ФОРВАРДНЫЙ
# клиентский трафик через свои цепочки `ipt_compiler_*` (miwifi-connantiy --check-url /
# miwifi-xthostset / `-j NFQUEUE --queue-balance 0:3 --queue-bypass`) в mangle PREROUTING.
# NFQUEUE — ТЕРМИНИРУЮЩАЯ цель: демон принимает пакет и реинъектит его уже с fwmark=0. Наш
# MARK, если он стоит НИЖЕ этих цепочек (как делал прежний `-A PREROUTING` — аппенд в конец),
# до пакета ПРОСТО НЕ ДОХОДИТ → метка 0x1 не ставится → `ip rule fwmark 0x1 -> table $TABLE`
# не срабатывает → заблок-сайт уходит НАПРЯМУЮ в WAN. У клиента сплит молча не работает, хотя
# роутер сам ходит в туннель (его OUTPUT под инспекцию не подпадает — «роутер ходит, клиент нет»).
# Дев-роутеры без этой фичи Xiaomi работали, поэтому баг всплыл лишь у части пользователей.
# ЛЕЧИМ: если в mangle PREROUTING есть miwifi/ipt_compiler/NFQUEUE-инспекция — ставим MARK и
# СРАЗУ ACCEPT ВЫШЕ неё. ACCEPT завершает обход mangle PREROUTING ДО NFQUEUE → метка выживает →
# routing → туннель. Не-VPN трафик инспекцию Xiaomi проходит по-прежнему (наши правила бьют
# только по dst из iplist_set/enodia_list). Где фичи нет (дев-роутер) — прежний аппенд MARK.
# Проверено на живом роутере тестера 12.07.2026: MARK+ACCEPT выше miwifi → YouTube/api.ipify
# в туннель, egress = сервер; было direct=30/TUN=0, стало direct=18/TUN=41. Идемпотентно
# (delete-loop снимает и старый аппенд-MARK, и MARK+ACCEPT). ВНИМАНИЕ при отладке: после
# правки нужен conntrack -F/-D (NSS/ECM-offload держит старый путь).
# grp_vpn — сет ИМЕНОВАННЫХ ГРУПП «в VPN» (groups.sh): статика из членов-CIDR + адреса, которые
# dnsmasq кладёт туда сам по мере резолва доменов-членов. Для ядра это просто третий сет с той же
# семантикой «dst в сете → в туннель»; его может ещё не быть (создаётся при первой группе) —
# цикл это уже учитывает (правило ставится только для существующего сета).
# enodia_ip_vpn — одиночные IP/подсети «в VPN» (apply-bypass.sh add-vpn-dst, хранилище .vpn-dst).
# Ровно та же семантика, поэтому это ЧЕТВЁРТОЕ слово в списке, а не свой MARK-хук: логика
# «выше miwifi/NFQUEUE» (грабля mipctld) обязана жить в одном месте — здесь. Сет тоже
# появляется в рантайме (первое правило по адресу) → apply-bypass переспрашивает нас, если
# правила ещё нет (ensure_vpn_dst_mark), как это делает groups.sh для grp_vpn.
# geo_vpn — гео-категории «в VPN» (geo.sh: страны/сервисы из фетч-CIDR). ПЯТОЕ слово с той же
# семантикой «dst в сете → в туннель»; сет появляется при первом гео-элементе (geo.sh wire_rules
# переспрашивает нас, как groups.sh). Пуст/нет — цикл пропускает (fail-open, безвредно).
for set in enodia_list iplist_set grp_vpn enodia_ip_vpn geo_vpn; do
    if ipset list -n 2>/dev/null | grep -qx "$set"; then
        # чистим прежние копии (и старый аппенд-MARK, и MARK+ACCEPT) — идемпотентность
        while iptables -t mangle -D PREROUTING -m set --match-set "$set" dst -j ACCEPT 2>/dev/null; do :; done
        while iptables -t mangle -D PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $FWMARK 2>/dev/null; do :; done
        # Циклом, как в PREROUTING выше: одиночный `-D` снял бы РОВНО ОДИН дубль, а накопиться их
        # может сколько угодно (каждый прогон ядра до появления этой чистки добавлял свой).
        while iptables -t mangle -D OUTPUT -m set --match-set "$set" dst -j MARK --set-mark $FWMARK 2>/dev/null; do :; done
        [ "$UNWIRE" = 1 ] && continue
        # позиция первой miwifi/ipt_compiler-инспекции (её NFQUEUE стирает fwmark)
        mpos=$(iptables -t mangle -nL PREROUTING --line-numbers 2>/dev/null | awk '/miwifi|ipt_compiler|NFQUEUE/{print $1; exit}')
        if [ -n "$mpos" ]; then
            # ВЫШЕ miwifi: сперва ACCEPT на позицию mpos, затем MARK перед ним
            # (итог: MARK(mpos), ACCEPT(mpos+1) — оба выше инспекции Xiaomi)
            iptables -t mangle -I PREROUTING "$mpos" -m set --match-set "$set" dst -j ACCEPT
            iptables -t mangle -I PREROUTING "$mpos" -m set --match-set "$set" dst -j MARK --set-mark $FWMARK
        else
            iptables -t mangle -A PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $FWMARK
        fi
        iptables -t mangle -A OUTPUT -m set --match-set "$set" dst -j MARK --set-mark $FWMARK
    fi
done

# Помеченные пакеты — по таблице $TABLE (default в неё кладёт активный транспорт).
ip rule del fwmark $FWMARK table $TABLE 2>/dev/null || true
if [ "$UNWIRE" = 1 ]; then
    # Саму table $TABLE не чистим: default в ней — собственность несущей, её снимает
    # transport.sh down (uninstall.sh зовёт его ПЕРЕД нами). Здесь только правила ядра.
    echo "[mark-core] маркировка СНЯТА (правила ядра и ip rule убраны; сеты и default в table $TABLE — не наша забота)"
    exit 0
fi
ip rule add fwmark $FWMARK table $TABLE pref 99

# ВЫКЛЮЧИЛИ, ПОКА МЫ СТАВИЛИ: гейт в начале файла пройден, а `vpn-toggle off` успел отработать (и снять `ip rule`) раньше, чем мы
# их положили, — правила выходов и основного жили бы при выключенном VPN до ребута, и тумблер показывал бы «VPN: ON» (ревью ветки,
# круг 2). Снимаем СВОИМ ЖЕ вербом `unwire` — второй копии «что снимать» тут нет.
if [ -f "$ENODIA_STATE/.vpn-off" ]; then
    echo "[mark-core] VPN выключили вручную, пока ставилась маркировка, — снимаю"
    exec sh "$ENODIA_DIR/mark-core.sh" unwire
fi

echo "[mark-core] маркировка применена (table $TABLE, fwmark $FWMARK; default ставит транспорт)"
