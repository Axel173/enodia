#!/bin/sh
# watchdog.sh — сторож VPN-туннеля на Xiaomi BE7000.
#
# Запускается из cron каждые 2 минуты. Следит за живостью awg0 по возрасту
# последнего handshake (при PersistentKeepalive=25 «старше 180 сек» = VPS
# реально не отвечает, без ложных срабатываний) и переключает режимы:
#
#   NORMAL  → FAILOPEN  (VPS умер): зовёт switch-vpn.sh safety-off —
#             снимает fwmark/mangle/MASQUERADE и переводит DNS на публичный,
#             трафик идёт напрямую через провайдера. Интернет НЕ пропадает
#             (в т.ч. DNS-резолвинг, который у нас завязан на туннель —
#             см. историю инцидента). Сайты из списка на это время
#             недоступны. Шлёт письмо через notify.sh.
#
#   FAILOPEN → NORMAL   (VPS ожил): возвращает VPN-роутинг (mark-core + transport-awg)
#             и DNS-upstream обратно в туннель. Шлёт письмо.
#
# АВТО-FAILOVER (июнь 2026). Детекцию падения НЕ меняем (те же HS_DEAD/HS_ALIVE);
# меняется лишь ДЕЙСТВИЕ при смерти VPS — по режиму из $ENODIA_STATE/.failover-mode:
#   off    — как раньше: safety-off + письмо «VPN упал». У ТУННЕЛЯ (xray/hy2/byedpi/zapret) — фолбэк на
#            установленный AmneziaWG, не вышло — прямой режим и повтор фолбэка по троттлу (ветка «режим off»).
#   sticky — (дефолт, нет файла → sticky) зовёт `switch-vpn.sh failover`: перебор
#            configs/*.conf по алфавиту, встаём на первый рабочий и остаёмся.
#   home   — то же, плюс когда «основной» (`.failover-home`) снова доступен —
#            возвращаемся на него (ALIVE-ветка, троттл FAILBACK_INTERVAL).
# Если резервов нет (один конфиг) — любой режим вырождается в классический
# safety-off, поэтому дефолт-ВКЛ безопасен. Перебор в FAILOPEN повторяется не
# чаще fo_retry (БЭКОФФ: 10→20→40→80→120 мин, сброс при возврате здоровья).
# Письма failover-ok/failover-fail шлёт сам switch-vpn; watchdog по коду
# возврата лишь выставляет STATE.
#
# ГЕЙТ «ЕСТЬ ЛИ ИНТЕРНЕТ ВООБЩЕ» (август 2026). Перед КАЖДЫМ перебором сторож
# отличает «лёг VPS» от «лёг провайдер»: линк и дефолт-маршрут при аварии выше
# по сети остаются на месте, поэтому одного wan_up() мало — нужна egress-проба
# ЧЕРЕЗ WAN (inet_reachable). Подтверждённое отсутствие интернета подавляет
# перебор (все серверы физически недостижимы) и даёт СВОЁ событие wan-down,
# а не «VPN упал, резервы недоступны» — VPN там ни при чём. Промах пробы
# подтверждаем В ТОМ ЖЕ тике, а перед каждой следующей ступенью лестницы
# (cross, эскалация) аплинк спрашиваем снова — ladder_wan_gate (02.10.2026).
#
# Почему это решает инцидент «VPS отвалился → на ПК лёг даже рунет»:
#   DNS на роутере один на все сети и форвардится в туннель. Пока туннель
#   мёртв, не резолвится ничего. safety_off временно ставит публичный DNS —
#   рунет и весь остальной трафик продолжают работать.
#
# Состояние — в /tmp/enodia-watchdog.state (NORMAL/FAILOPEN). Письмо уходит
# ТОЛЬКО на смену режима, а не каждый тик. /tmp сбрасывается при ребуте —
# после загрузки считаем NORMAL, и watchdog переоценит ситуацию заново.
# После ребута выжидаем BOOT_GRACE сек (первичный подъём несущей — забота heal.sh,
# а не watchdog), иначе получаем самонаведённый failopen на буте (см. boot-grace ниже).
#
# Уведомления можно выключить, создав файл .notify-off (см. notify()).
# Туннель watchdog НЕ поднимает сам — если awg0 вообще нет, это территория
# heal.sh, мы просто выходим.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
ENODIA_BIN=${ENODIA_BIN:-/data/usr/app/enodia-bin}
STATE=/tmp/enodia-watchdog.state
LOCK=/tmp/enodia-watchdog.lock
# ПИД ДЕРЖАТЕЛЯ ЛОКА — своим файлом, а не внутри лока: в локе лежит ОТМЕТКА ВРЕМЕНИ, и `stamp_age`
# на любом нецифровом содержимом отвечает 0, то есть «возраст огромный» ⇒ гейт ниже перехватил бы
# ЖИВОЙ лок и запустил второй тик. Нужен ровно одному вопросу — «держатель жив или его унесло»
# (`tick_running`), и снимается ТЕМ ЖЕ трапом, что лок.
WD_PID=/tmp/enodia-watchdog.pid
SWITCH_LOCK=/tmp/enodia-switching.lock
HEAL_LOCK=/tmp/enodia-heal.lock    # лок heal.sh (1×/boot) — снимаем при мид-дэй смерти awg0, чтобы heal пересоздал
# ПРИЧИНА внепланового прогона heal. Снимая heal-лок, сторож запускает у heal ПОЛНЫЙ бутовый
# сценарий — вместе с письмом «загрузка OK, VPN поднят», которое человек читает как «роутер сам
# перезагрузился» (жалоба 30.07.2026; ровно поэтому `vpn-toggle repair` лок НЕ снимает). Здесь
# снятие ЗАКОННО — awg0 физически исчез, а пересоздавать интерфейс умеет только heal, — но письмо
# про загрузку было бы ложью: сторож уже прислал «awg0 упал» и пришлёт «VPN восстановлен».
# Маркер в /tmp: heal глушит по нему ИМЕННО бутовое письмо, всё остальное делает как всегда.
HEAL_REASON=/tmp/enodia-heal.reason
heal_reason() { echo "$1" > "$HEAL_REASON" 2>/dev/null; }
# «heal СТАРТОВАЛ, но вышел по switching-локу» — ставит сам heal (heal.sh::HEAL_SKIPPED), снимаем мы
# вместе с локом. Нужен ровно одному месту — диагнозу в письме «сторож перестал пересоздавать»:
# ранний выход heal не берёт лок и не съедает причину, то есть выглядит как «heal не запускался
# вовсе», и совет «проверь строку heal.sh в cron» уходил при исправном cron (хвост ревью 7).
HEAL_SKIPPED=/tmp/enodia-heal.skipped
LOG=/tmp/enodia-watchdog.log
NOTIFY="$ENODIA_DIR/notify.sh"
NOTIFY_OFF="$ENODIA_STATE/.notify-off"

# Общий примитив «внешний IPv4» (ip-lib.sh): IP-литерал-проба, DNS-free — чинит пустой egress на
# ядре 4.4 (hostname api.ipify.org там молча пустел). Шим на случай частичной установки без lib.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
command -v probe_ext_ip >/dev/null 2>&1 || probe_ext_ip() { curl -s $1 --max-time "${2:-7}" https://api.ipify.org 2>/dev/null; }

# Возраст отметки времени (clock-lib.sh): БЕЗ него весь этот файл судит по `now - ts`, а часы на
# роутере без RTC прыгают вперёд через ~13 мин после загрузки ⇒ живой туннель выглядит мёртвым, а
# все троттлы разом «протухают». Шим повторяет ПРЕЖНЕЕ поведение (частичная установка без lib —
# не хуже, чем было), но полноценная защита живёт в самой lib. [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
# «Ведёт ли кто-то смену» (daemon-lib.sh::switch_work_alive) — для лока смены с мёртвым пидом (switch_lock_held ниже). Нет библиотеки —
# прежнее «мёртвый пид = лок ничей».
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
command -v switch_work_alive >/dev/null 2>&1 || switch_work_alive() { return 1; }
command -v switch_holder_mark >/dev/null 2>&1 || switch_holder_mark() { ENODIA_SWITCH_HOLDER=$$; export ENODIA_SWITCH_HOLDER; }
command -v switch_lock_reap >/dev/null 2>&1 || switch_lock_reap() { [ "$(cat "$SWITCH_LOCK" 2>/dev/null | tr -d ' \r\n')" = "$1" ] && rm -f "$SWITCH_LOCK" 2>/dev/null; return 0; }
# Секунд с загрузки — оттуда же (uptime_s): своя копия `cut -d. -f1 /proc/uptime` жила тут под
# именем uptime_secs и была одной из ПЯТИ в проекте (следит C83). Смысл прежний: монотоника ядра,
# а не date (RTC нет); не прочитали — заведомо большое, то есть грейс не срабатывает, как и раньше.
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
# …и ЧИСЛО гарантируем у себя. Прежний uptime_secs кончался `printf '%d'` и вернуть не-число не
# мог; теперь ответ приходит из СОРСИМОЙ библиотеки, и обрезанная копия (частичное обновление,
# оборванная заливка) отдала бы пустую строку — а `[ "" -lt 180 ]` это не «ложь», а ошибка
# синтаксиса: весь блок boot-grace молча пропускается, и сторож лезет чинить несущую на первой
# секунде бута (ревью 2, 06.09.2026). Своего чтения /proc/uptime тут нет — только гард над ответом.
up_secs() { _ups=$(uptime_s); case "$_ups" in ''|*[!0-9]*) _ups=999999999 ;; esac; echo "$_ups"; }
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
# Возраст отметки АПТАЙМА (clock-lib.sh::up_age) — у пауз, живущих только в /tmp. Нет библиотеки — «давно»: пауза кончилась, попытка
# будет (лишняя проба лучше выхода, лежащего до ручного включения).
command -v up_age >/dev/null 2>&1 || up_age() { echo 999999; }

# Слой шифрованного DNS (doh-lib.sh): keepalive демона https_dns_proxy (ниже, после лока). Шим —
# без lib doh_want=false ⇒ keepalive no-op. [[doh-direct-modes-backlog]]
if [ -f "$ENODIA_DIR/doh-lib.sh" ]; then . "$ENODIA_DIR/doh-lib.sh"; fi
# Наш upstream dnsmasq пишет ОДИН владелец (doh-lib.sh, разбор там). Нет библиотеки — прежняя пара «записать + рестарт».
command -v dns_upstream_put >/dev/null 2>&1 || dns_upstream_put() { mkdir -p /etc/dnsmasq.d; { echo no-resolv; for _dus in "$@"; do echo "server=$_dus"; done; } > /etc/dnsmasq.d/00-upstream.conf; /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }
command -v doh_enabled >/dev/null 2>&1 || doh_enabled() { return 1; }
command -v doh_want >/dev/null 2>&1 || doh_want() { return 1; }   # старая lib без авто-режима
command -v doh_rearm_due >/dev/null 2>&1 || doh_rearm_due() { return 0; }   # lib без паузы ручного DoH — прежний путь

# Язык писем и событий сторожа — тот же панельный pref, что у heal/switch-vpn (nf-i18n.sh).
# Сторож был ПОСЛЕДНИМ отправителем, оставшимся только на русском: у человека с англоязычной
# панелью половина «центра уведомлений» приходила на чужом языке — и именно та половина, где
# написано, почему пропал VPN. Шим = ru, то есть прежнее поведение байт-в-байт.
if [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
command -v nf_lang >/dev/null 2>&1 || nf_lang() { echo ru; }
NF_LANG=$(nf_lang)

# Пороги можно переопределить через окружение (для тюнинга и тестов):
#   HS_DEAD=10 sh watchdog.sh   — заставит счесть VPS мёртвым
HS_DEAD=${HS_DEAD:-180}     # handshake старше этого (сек) => VPS не отвечает
HS_ALIVE=${HS_ALIVE:-120}   # handshake свежее этого (сек) => VPS жив (возврат)
                            # зазор 120..180 — гистерезис против «дребезга»
# keepalive awg-выхода длиннее этого — судить его по рукопожатию нельзя. Зеркало transport-awg.sh SLOT_KEEPALIVE (равенство
# держит dev/slots-key-test.sh, s_kamax).
SLOT_KA_MAX=25

# Грейс после подъёма несущей: столько секунд НЕ судим tunnel-транспорт по egress-пробе.
# ЗАЧЕМ (железо 14.08.2026): enodia-switching.lock отпускается, когда стартовали ДЕМОНЫ, а не когда
# заработал выход, и тик в этом зазоре пишет SUSPECT живому каналу (панель — «проверяю…»), а
# ВТОРАЯ такая осечка уходит в лестницу failover, отменяя ручной выбор сервера. Отметку кладёт
# каждый плагин в своём up (carrier_up_mark, clock-lib.sh). Цена грейса — максимум один
# пропущенный тик: реальная авария подтвердится на следующем, через 2 минуты.
# ЗАМЕР (BE7000, 14.08.2026, xray по имени на здоровой сети): полный подъём несущей до
# проходящего health — 7 с (6 с сам подъём + проба сразу). Наблюдённая осечка была на 19-й
# секунде после старта демона. 60 — это запас к замеру, а не круглое число с потолка: восьмикратно
# перекрывает норму и вдвое — худший наблюдённый случай, оставаясь много меньше тика (120 с).
CARRIER_GRACE=${CARRIER_GRACE:-60}
CARRIER_UP_STAMP="${CARRIER_UP_STAMP:-/tmp/.enodia-carrier-up.stamp}"   # нет свежей clock-lib → stamp_age даст 999999 ⇒ грейса нет, прежнее поведение

# Boot-grace: первые N сек после загрузки несущую поднимает heal.sh (cron */1), а НЕ
# watchdog. Пока идёт первичный подъём, health транспорта закономерно ещё не проходит —
# не даём watchdog'у объявить его мёртвым и свалиться в failover/safety_off (self-inflicted
# failopen на буте, пойман на железе 07.07.2026: xray health «сбой» в 21:13-21:14 ещё до
# того, как heal поднял xray в 21:14:21). Тюнится через окружение (тест/медленный бут).
BOOT_GRACE=${BOOT_GRACE:-180}

# --- Авто-failover на резервный конфиг (см. switch-vpn.sh failover) ---
ACTIVE_NAME="$ENODIA_STATE/.active"
CONFIGS_DIR="$ENODIA_STATE/configs"
SWITCH_VPN="$ENODIA_DIR/switch-vpn.sh"
VPN_TOGGLE="$ENODIA_DIR/vpn-toggle.sh"            # repair: полный переигрыш правил сплита (mark-core + несущая + FORWARD/MASQUERADE + DNS)
FAILOVER_MODE_FILE="$ENODIA_STATE/.failover-mode"   # off|sticky|home; нет файла → sticky
FAILOVER_HOME_FILE="$ENODIA_STATE/.failover-home"   # имя «основного» конфига для home
FAILOVER_ESCALATE_FILE="$ENODIA_STATE/.failover-escalate"  # cross|direct; нет файла → cross
FAILOVER_STAMP=/tmp/enodia-failover.stamp         # троттл повторного перебора в FAILOPEN
FO_MODE_SEEN=/tmp/enodia-failover.mode-seen       # режим резервирования, при котором копилась пауза (см. fo_mode_note)
FAILBACK_STAMP=/tmp/enodia-failback.stamp         # троттл попыток возврата на home
FAILOVER_RETRY=${FAILOVER_RETRY:-600}          # БАЗОВАЯ пауза (сек) между переборами в FAILOPEN; дальше — бэкофф (fo_retry)
FAILOVER_BACKOFF=/tmp/enodia-failover.backoff     # текущая пауза бэкоффа (удваивается на каждом безуспешном свипе пула)
FAILOVER_MAX=${FAILOVER_MAX:-7200}             # кап бэкоффа (сек): 10→20→40→80→120 мин
# Кап бэкоффа для TUNNEL-транспортов — НИЖЕ awg-шного, и вот почему. В fail-open несущая awg
# СОЗНАТЕЛЬНО остаётся поднятой (safety_off снимает лишь маршрут), поэтому оживление VPS видно
# по свежему handshake на КАЖДОМ тике, а длинная пауза стоит дёшево. У xray/hy2/byedpi несущая
# в прямом режиме СНЯТА (иначе её default в table 1000 = блэкхол, см. ensure_direct_mode) ⇒
# единственный детектор оживления — сама повторная попытка, и 120 мин означали бы «VPS вернулся,
# а VPN два часа не возвращается». Свип тут дешевле awg-шного (старт двух демонов + одна
# egress-проба, без wait_for_handshake по каждому конфигу), так что лестница 10→20→30 мин честнее.
TUNNEL_RETRY_MAX=${TUNNEL_RETRY_MAX:-1800}
FAILBACK_INTERVAL=${FAILBACK_INTERVAL:-900} # как часто (сек) пробовать возврат на home
WANOUT_EVENT=/tmp/enodia-wanout.event       # эпизод «интернета нет вообще» уже объявлен (гейт события/письма)
WANOUT_SWEEP=/tmp/enodia-wanout.sweep       # когда авария в последний раз ПОДТВЕРЖДЕНА (каждым тиком; по ней wan_out_now)
WANOUT_VALVE=/tmp/enodia-wanout.valve       # когда в последний раз пускали КОНТРОЛЬНЫЙ свип вопреки пробе (предохранитель)
WAN_BLIND=0                                 # 1 = этот тик идёт контрольным свипом: ступени лестницы аплинк не переспрашивают
WAN_RECHECK=${WAN_RECHECK:-10}              # пауза перед ПОДТВЕРЖДАЮЩЕЙ пробой аплинка (ip-lib.sh::wan_recheck; шим ниже)
WANOUT_MAX=${WANOUT_MAX:-3600}              # не реже раза в N сек всё же пробуем перебор вслепую (предохранитель)
REUP_STAMP=/tmp/enodia-reup.stamp           # троттл переподъёма awg-несущей ПЕРЕД перебором резервов (см. ниже)
REUP_RETRY=${REUP_RETRY:-1800}              # не чаще раза в N сек: reup рвёт awg0, крутить его каждый тик нельзя
RULEHEAL_STAMP=/tmp/enodia-ruleheal.stamp   # троттл письма о rule-heal (fw3-reload снёс правила сплита)
RULEHEAL_NOTIFY=${RULEHEAL_NOTIFY:-1800}    # не чаще раза в N сек слать письмо о восстановлении правил (анти-спам, если repair не помог)
WIPE_SEEN=/tmp/enodia-splitwipe.seen        # первый (ещё не подтверждённый) детект «правила сплита снесены»
ROUTELOST_SEEN=/tmp/enodia-routelost.seen   # то же для «пропал default несущей из table 1000» — счёт СВОЙ: болезни разные, путать их подтверждения нельзя
RULELOST_SEEN=/tmp/enodia-rulelost.seen     # …и для ЗЕРКАЛЬНОЙ болезни: маршрут на месте, а `ip rule fwmark→1000` пропал (см. carrier_rule_lost)
NONVPN_SEEN=/tmp/enodia-nonvpnwipe.seen     # то же для правил НЕ про VPN (блокировки, запрет IPv6, «доступ домой») при выключенном VPN — см. nonvpn_rules_sweep
NONVPN_TRIED=/tmp/enodia-nonvpnwipe.tried   # когда их чинили в последний раз (+ `.what` — что именно): починка не помогла ⇒ не по кругу
NONVPN_RETRY=${NONVPN_RETRY:-1800}          # не чаще раза в N сек чинить ТО ЖЕ САМОЕ, если прошлая починка его не вернула
AWG0_FIRSTUP=/tmp/enodia-awg0.firstup       # «FAILOPEN здесь поставили МЫ, ожидая ПЕРВЫЙ подъём awg0» — чтобы возврат из него не слал письмо «VPN восстановлен» (ставит ветка «awg0 не поднимался»; снимают гард «STATE не FAILOPEN», ветки «VPS мёртв» и «VPS жив»). По ней же вердикт `standing` судит `boot`
AWG0_SEEN=/tmp/enodia-awg0.seen           # «в ЭТУ загрузку awg0 хоть раз был живым» — отличает ПАДЕНИЕ несущей от «её ещё не поднимали» (см. ветку «awg0 ИСЧЕЗ»); в /tmp ⇒ умирает вместе с загрузкой, как и положено вопросу «в эту загрузку»
# То же наблюдение, но про TUNNEL-транспорты (xray/hy2/byedpi/zapret), и по ОДНОМУ файлу на
# транспорт: «несущая ИМЕННО ЭТОГО транспорта хоть раз везла в эту загрузку». Отметку кладёт
# сам сторож, когда health ПРОШЁЛ, — то есть по СВОИМ глазам, а не по чужому обещанию.
# ЗАЧЕМ ОТДЕЛЬНО ОТ CARRIER_UP_STAMP: тот один на все транспорты и отвечает на другой вопрос
# («несущую подняли только что» — грейс прогрева), а нам нужно «поднимали ли ВООБЩЕ».
CARRIER_SEEN_PFX=/tmp/enodia-carrier-          # <транспорт>.seen / <транспорт>.tries
CARRIER_UP_TRIES=${CARRIER_UP_TRIES:-3}        # сколько раз пробуем поднять НИ РАЗУ не поднимавшуюся несущую, прежде чем отдать вопрос обычной лестнице
# СКОЛЬКО РАЗ ПОДРЯД СНИМАЕМ heal-ЛОК РАДИ ПЕРЕСОЗДАНИЯ awg0 — и почему потолок вообще нужен.
# awg-ветка ниже кончается «снимаю heal-лок, heal пересоздаст awg0», и делала она это КАЖДЫЙ тик,
# пока интерфейса нет. Собственный потолок heal («три прогона подряд оборвались») тут не работает
# вовсе: каждый наш прогон ДОХОДИТ до конца и честно пишет «done» — обрыва нет, считать нечего.
# Значит при детерминированной причине (битый конфиг, ключи не те, ядро без модуля) роутер каждые
# две минуты гонял ПОЛНЫЙ бутовый сценарий, а в нём `awg_setup.sh` со своим `firewall reload` =
# снос ВСЕХ iptables с последующим восстановлением — и так до ребута. Три быстрые попытки честны
# (бинарь/накопитель/конфиг могли доехать позже), дальше пробуем РЕДКО: причина «доедет само»
# остаётся возможной, а флеш и правила больше не мучаем. Счётчик и отметка — в ОЗУ (ребут = чистый
# лист), сбрасываются, как только awg0 появился.
HEAL_KICK_TRIES=${HEAL_KICK_TRIES:-3}
HEAL_KICK_SLOW=${HEAL_KICK_SLOW:-3600}         # после потолка — не чаще раза в час
HEAL_KICK_CNT=/tmp/enodia-heal-kick.tries
HEAL_KICK_STAMP=/tmp/enodia-heal-kick.stamp
HEAL_KICK_SAID=/tmp/enodia-heal-kick.said      # «про потолок уже сказано» — строка в лог раз за эпизод, а не раз в тик; она же у вердикта `standing` — «потолок ОБЪЯВЛЕН», граница `boot`
# ТРОТТЛ ПИСЬМА «сторож перестал пересоздавать». Флаг `.mailed` гейтит ЭПИЗОД, но он снимается
# КАЖДЫМ появлением awg0 — а при OOM-флапе (поднялся → упал → три кика → потолок) эпизод
# повторяется каждые 10-15 минут, и без троттла это до сотни писем и столько же строк в кольце
# журнала за сутки (ревью 6). Шесть часов: постоянная поломка = одно письмо, а новость «починили,
# и сломалось снова» приходит в тот же день (суточный троттл её съедал).
NORAISE_THROTTLE=${NORAISE_THROTTLE:-21600}
WANOUT_FRESH=${WANOUT_FRESH:-900}              # «эпизод без интернета ещё свежий» — столько письмо про awg молчит (закрыть эпизод в этой ветке некому)
HEAL_KICK_MAILED=/tmp/enodia-heal-kick.mailed  # «письмо про потолок уже ушло» — свой флаг, потому что письмо уходит ПОСЛЕ лестницы, а строка в лог — до неё
HEAL_KICK_CFG=/tmp/enodia-heal-kick.cfg        # слепок mtime конфигов awg на момент последней попытки: правка ЧЕЛОВЕКОМ возвращает бюджет, наш же перебор — нет
WIPE_CONFIRM=${WIPE_CONFIRM:-420}              # окно (сек) подтверждения вторым тиком; больше периода cron (120) с запасом
DOMWARM_STAMP=/tmp/enodia-domwarm.stamp           # троттл периодического прогрева доменных правил
DOMWARM_INTERVAL=${DOMWARM_INTERVAL:-3600}     # не чаще раза в N сек: прогрев форкает nslookup на каждый домен
# Защита от «хождения по кругу» awg<->xray: какие протоколы уже перебраны в ТЕКУЩЕМ
# эпизоде аварии. cross-эскалация не прыгает в протокол, который уже пробовали →
# терминал всегда safety_off, без флаппинга. Чистится, когда транспорт снова здоров.
FAILOVER_EPISODE=/tmp/enodia-failover-episode
TRANSPORT_HOME_FILE="$ENODIA_STATE/.transport-home"  # awg|xray|hy2 — предпочитаемый транспорт (ручной выбор в меню); пусто → авто-возврат транспорта выключен
XT_AWG="$ENODIA_DIR/transport-awg.sh"              # плагин awg-несущей (возврат awg-роутинга вместо split-route)
MARK_CORE="$ENODIA_DIR/mark-core.sh"               # ядро маркировки (транспорт-агностично; было в split-route)
TRANSPORT_SH="$ENODIA_DIR/transport.sh"            # ОРКЕСТРАТОР: switch/up/down/health/failover/next — ВСЯ работа с tunnel-транспортами идёт через него (имя файла плагина знает только он)
XSTATE=/tmp/enodia-watchdog.xstate                 # состояние мониторинга tunnel-транспорта (xray/hy2/…): HEALTHY/SUSPECT/FAILED
SUPPORT_SH="$ENODIA_DIR/support.sh"                 # «режим поддержки»: reap гасит истёкший туннель (DRY — не плодим отдельный cron-демон)
SLOTS_SH="$ENODIA_DIR/slots.sh"                      # реестр доп-выходов (мульти-транспорт Ф2): health слотов ниже
VPNSRV_SH="$ENODIA_DIR/vpn-server.sh"                # «доступ домой» (роутер как VPN-сервер): keepalive несущей awgs0 ниже
NOTIFY_EVENT="$ENODIA_DIR/notify-event.sh"           # событийные письма (throttle по ключу) — для отказа доп-выхода
TAB=$(printf '\t')

# Вернуть ТОЛЬКО маркировку (mark-core), без несущей. Используется restore_awg_carrier
# (возврат awg при оживании VPS). Cross/home-переключения транспортов идут через
# transport.sh switch (тот сам кладёт mark-core). Зеркало бывшего split-route.sh, очищенного
# от awg0-несущей. Фолбэк на split-route — для старых роутеров без mark-core.
restore_marking() {
    if [ -f "$MARK_CORE" ]; then sh "$MARK_CORE" >>"$LOG" 2>&1
    elif [ -f "$ENODIA_DIR/split-route.sh" ]; then sh "$ENODIA_DIR/split-route.sh" >>"$LOG" 2>&1; fi
}
# Вернуть awg-несущую целиком (mark-core + transport-awg.sh up): default dev awg0 + FORWARD +
# MASQUERADE + туннельный DNS + .transport=awg. Замена split-route.sh для «awg снова активен».
restore_awg_carrier() {
    restore_marking
    if [ -f "$XT_AWG" ]; then sh "$XT_AWG" up >>"$LOG" 2>&1; fi
    off_bail "возврата несущей AmneziaWG"
}

# --- Rule-heal: несущая жива, но правила сплита снесены (fw3/firewall reload) ---
# ГРАБЛЯ [[boot-race-fw3-reload-wipes-rules]]: fw3 reload (изменение в веб-морде Xiaomi,
# /etc/init.d/firewall restart, пересборка на буте ПОСЛЕ heal.sh) флашит ВСЕ iptables. Туннель
# router→VPS цел (handshake/health «ок»), но mangle-MARK + FORWARD ACCEPT + MASQUERADE снесены →
# форвард клиента дропается (fw3 policy FORWARD=DROP) → сплит молча мёртв. Watchdog проверял
# ТОЛЬКО живость несущей, оттого был слеп к этому (heal.sh тоже не спасал — лок 1×/boot).
# Отпечаток (проверен на железе): fw3-reload флашит iptables, но `ip rule`/`ip route table 1000`
# ПЕРЕЖИВАЮТ → default table 1000 всё ещё указывает на несущую (awg0/xtun), а FORWARD ACCEPT для
# неё исчез. Сигнал = FORWARD -o <несущая> ACCEPT отсутствует. mipctld-guard (restore_marking) его
# НЕ маскирует — тот ставит лишь маркировку, FORWARD/MASQUERADE — забота несущей.
# ВЛАДЕЛЕЦ СПИСКА — ОРКЕСТРАТОР (`transport.sh marking`): «везёт ли по марке» спрашивает не
# только сторож, но и тумблер панели, а два списка в двух файлах разъедутся на шестом
# транспорте. Код 2 (старая копия без верба) или нет файла ⇒ прежний вшитый ответ, байт-в-байт.
# zapret — прямой DPI без маркировки, его rule-heal сторожит ОТДЕЛЬНОЙ веткой (jump ENODIA_ZAPRET).
uses_marking() {
    if [ -f "$ENODIA_DIR/transport.sh" ]; then
        sh "$ENODIA_DIR/transport.sh" marking "$1" >/dev/null 2>&1
        case "$?" in 0) return 0 ;; 1) return 1 ;; esac
    fi
    case "$1" in awg|xray|hy2|byedpi) return 0 ;; *) return 1 ;; esac
}
# Устройство несущей = dev у `default` в боевой table 1000. Ставит его ТОЛЬКО плагин несущей,
# поэтому это единственный честный признак «несущая держит маршрут»: пусто = lookup проваливается
# в main = трафик идёт ПРЯМО (ровно это и обещает fail-open, см. switch-vpn.sh safety_off).
# Доп-выходы живут в СВОИХ table 100N и сюда не попадают. Владелец ответа — ip-lib.sh::carrier_iface
# (та же строка спрашивается карточкой адаптеров панели); шим — на случай старой библиотеки.
command -v carrier_iface >/dev/null 2>&1 || carrier_iface() { ip route show table 1000 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
carrier_route_dev() {   # тело — отдельной строкой: стенд failopen-direct вырезает функцию по `^}`
    carrier_iface
}
# `iptables -C`. ГРАБЛЯ (июль 2026): на стоке iptables 1.6.2 берёт /run/xtables.lock, а стоковые
# демоны Xiaomi (sp_check.sh */5, mobile_accel.sh */3, startscene_crontab.lua ежеминутно, mipctld,
# upnp) дёргают iptables постоянно. Без ожидания вызов при занятом локе не ждёт, а СРАЗУ падает
# кодом 4 — и прежний код («любой ненулевой = правила снесены») по этому коллизионному коду
# запускал полный repair. Само ожидание (`-w 5` там, где сборка его умеет) и ретрай на код 2
# теперь ставит ipt-lib.sh — ЕДИНСТВЕННЫЙ владелец на все 255 мест проекта, эта функция стала его
# частным случаем. Здесь остаётся ровно то, ради чего она заводилась: возвращаем код КАК ЕСТЬ,
# чтобы вызывающий отличил «правила нет» (1) от «проверить не смог» (4/2/…).
ipt_check_t() {   # $1 = таблица, дальше — правило. `-t` ОБЯЗАН стоять ДО `-C`: у `-C` чейн идёт
                  # аргументом опции, и форма `-C -t mangle PREROUTING` разобралась бы как чейн «-t».
    _ipt="$1"; shift
    iptables -t "$_ipt" -C "$@" 2>/dev/null; _iprc=$?
    return "$_iprc"
}
ipt_check() { ipt_check_t filter "$@"; }
split_rules_wiped() {
    # $1 — активный транспорт. true(0) ⇔ ожидаемое правило транспорта пропало И это подтвердил
    # ВТОРОЙ тик подряд. «Не смог проверить»/«нечего проверять» → 1 (иначе ложный repair =
    # conntrack -F каждый тик = дребезг связи). Точность важнее полноты.
    _cif=""
    case "$1" in
        zapret)
            # У zapret НЕТ несущей (десинк идёт прямым путём) ⇒ признака «FORWARD -o dev» не
            # существует, и до 08.2026 этот транспорт был для rule-heal НЕВИДИМ: fw3-reload сносит
            # всю проводку десинка (jump ENODIA_ZAPRET, NFQUEUE в POSTROUTING, анти-петлю), а nfqws
            # остаётся жив ⇒ health «ок», панель показывает «Zapret активен», десинка нет до
            # ребута. Признак: jump на ENODIA_ZAPRET — `rules_add` ставит его БЕЗУСЛОВНО, пока
            # есть .zapret-on (гейт ниже отсекает «zapret ещё/уже не несёт»).
            [ -f "$ENODIA_STATE/.zapret-on" ] || return 1
            _what="mangle PREROUTING -j ENODIA_ZAPRET"
            ipt_check_t mangle PREROUTING -j ENODIA_ZAPRET; _rc=$?
            ;;
        *)
            # Маркирующий транспорт: несущая есть в table 1000, но FORWARD ACCEPT для неё снесён.
            # Пусто/нет default table 1000 → НЕ оцениваем.
            uses_marking "$1" || return 1
            _cif=$(carrier_route_dev)
            [ -n "$_cif" ] || return 1
            _what="FORWARD -o $_cif -j ACCEPT"
            ipt_check FORWARD -o "$_cif" -j ACCEPT; _rc=$?
            ;;
    esac
    if [ "$_rc" = 0 ]; then rm -f "$WIPE_SEEN" 2>/dev/null; return 1; fi          # правило есть → всё цело
    if [ "$_rc" != 1 ]; then                                                      # 4=лок занят, прочее=сбой вызова
        log "split-check: iptables -C дал код $_rc (лок занят/сбой) — НЕ сужу, жду следующего тика"
        return 1
    fi
    # ВТОРОЙ ТИК ПОДРЯД. Полный repair теперь стоит дорого (conntrack -F = дребезг связи), а
    # одиночный «нет правила» бывает и не от fw3-reload. Первый детект только запоминаем;
    # чиним, если через ~2 мин (WIPE_CONFIRM) правила всё ещё нет. Штамп протух → счёт заново.
    if [ "$(stamp_age "$WIPE_SEEN")" -le "$WIPE_CONFIRM" ]; then
        return 0                                                                  # подтверждено двумя тиками → wiped
    fi
    date +%s > "$WIPE_SEEN"
    # Отпечаток для разбора постфактум: реальный fw3-reload сносит ВСЁ (FORWARD схлопывается до
    # пары строк, MASQUERADE несущей тоже нет), а «пропало одно правило» — совсем другая болезнь.
    if [ -n "$_cif" ]; then
        log "split-check: $_what не найден (строк в FORWARD: $(iptables -S FORWARD 2>/dev/null | wc -l), MASQ несущей: $(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-o $_cif -j MASQUERADE")) — жду подтверждения на следующем тике"
    else
        log "split-check: $_what не найден (правил в mangle PREROUTING: $(iptables -t mangle -S PREROUTING 2>/dev/null | wc -l), NFQUEUE в POSTROUTING: $(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c -- '--queue-num')) — жду подтверждения на следующем тике"
    fi
    return 1
}
# --- Пропал САМ МАРШРУТ несущей: table 1000 пуста при живой несущей -------------------
# ГРАБЛЯ (замерено на AX3600 14.08.2026): ядро сносит `default dev awg0` ВМЕСТЕ с интерфейсом
# (`ip link set awg0 down` — так делает любой сбой/пересоздание несущей), а `up` маршрут НЕ
# возвращает. Итог: демон жив, handshake свежий, FORWARD -o awg0 ACCEPT на месте — и ВЕСЬ
# маркированный трафик уходит НАПРЯМУЮ (lookup 1000 проваливается в main), а следом умирает DNS
# роутера (upstream доступен только через туннель) ⇒ панель зелёная, «VPN включён», имена не
# резолвятся. split_rules_wiped этот случай не ловит СТРУКТУРНО: устройство несущей он берёт ИЗ
# table 1000 и на пустой таблице честно отвечает «не оцениваю» — там пустота означает намеренный
# fail-open. То есть в NORMAL никто не проверял, что несущая ДЕРЖИТ маршрут.
# ЧЕМ ОТЛИЧАЕМ ДЕФЕКТ ОТ НАМЕРЕННОГО ПРЯМОГО РЕЖИМА — ПО СЕТИ, а не по строке в файле (тот же
# принцип, что у ensure_direct_mode): и глобальное выключение (vpn-toggle off), и safety_off
# снимают САМО правило `ip rule fwmark 0x1 table 1000` — маркированному трафику некуда
# проваливаться, блэкхола нет, судить не о чем. Правило на месте + таблица пуста = дефект.
carrier_rule_present() {
    ip rule show 2>/dev/null | grep -qE 'fwmark 0x1(/\S+)? lookup 1000'
}
carrier_route_lost() {
    uses_marking "$1" || return 1                  # zapret несущей не держит — сторожить нечего
    # ПОВОД ИСЧЕЗ — СЧЁТ ПОДТВЕРЖДЕНИЙ СБРАСЫВАЕМ (симметрично split_rules_wiped, где это делает
    # ветка «правило есть»). Иначе отметка живёт WIPE_CONFIRM секунд после САМОСТОЯТЕЛЬНОГО
    # выздоровления (маршрут вернул heal/плагин/ручной repair), и СЛЕДУЮЩИЙ штатный однотиковый
    # провал — то самое окно «ip rule уже есть, маршрут ещё нет» — сработает СРАЗУ, без второго
    # тика: глобальный `conntrack -F` всему дому ровно там, где подтверждение и заводилось.
    if [ -n "$(carrier_route_dev)" ]; then rm -f "$ROUTELOST_SEEN" 2>/dev/null; return 1; fi
    carrier_rule_present || { rm -f "$ROUTELOST_SEEN" 2>/dev/null; return 1; }   # VPN выключен/safety_off — прямой режим НАСТОЯЩИЙ
    # ВТОРОЙ ТИК ПОДРЯД — как у split_rules_wiped: repair стоит conntrack -F (дребезг связи), а
    # окно «правило уже есть, маршрут ещё нет» бывает штатно (mark-core кладёт ip rule ДО того,
    # как плагин поставит default). Смену транспорта тик и так пропускает по SWITCH_LOCK.
    if [ "$(stamp_age "$ROUTELOST_SEEN")" -le "$WIPE_CONFIRM" ]; then return 0; fi
    date +%s > "$ROUTELOST_SEEN"
    log "route-check: table 1000 ПУСТА при живой несущей ($1) и целом ip rule — жду подтверждения на следующем тике"
    return 1
}
# ЗЕРКАЛО carrier_route_lost: маршрут несущей НА МЕСТЕ, а `ip rule fwmark 0x1 → 1000` пропал.
# ЗАМЕРЕНО на живом AX3600 03.09.2026 сценарием FAILOPEN→NORMAL: safety_off снимает И маршрут, И
# правило; выздоровление возвращает МАРШРУТ (его кладёт плагин несущей), а правило кладёт
# mark-core — и в этом пути его не зовёт НИКТО. Итог: пакеты метятся, table 1000 полна, а метке
# некуда вести ⇒ весь «VPN-трафик» идёт мимо туннеля при NORMAL/HEALTHY и зелёной панели, то есть
# УТЕЧКА при зелёном статусе. Соседи это состояние не видят СТРУКТУРНО: split_rules_wiped смотрит
# FORWARD, а carrier_route_lost на пустом ip rule СПЕЦИАЛЬНО молчит (там это признак честного
# прямого режима — но там и table 1000 ПУСТА, здесь она полна: болезни разные).
carrier_rule_lost() {
    uses_marking "$1" || return 1                  # zapret метку не ставит — сторожить нечего
    # Маршрута нет ⇒ либо честный прямой режим, либо болезнь соседа (carrier_route_lost). Не наш повод.
    [ -n "$(carrier_route_dev)" ] || { rm -f "$RULELOST_SEEN" 2>/dev/null; return 1; }
    if carrier_rule_present; then rm -f "$RULELOST_SEEN" 2>/dev/null; return 1; fi
    # ВТОРОЙ ТИК ПОДРЯД — по той же причине, что у обоих соседей: repair кончается conntrack -F,
    # то есть дребезгом связи всему дому, и платить им за одиночный мигающий детект нельзя.
    if [ "$(stamp_age "$RULELOST_SEEN")" -le "$WIPE_CONFIRM" ]; then return 0; fi
    date +%s > "$RULELOST_SEEN"
    log "rule-check: несущая ($1) держит маршрут, а ip rule fwmark→1000 пропал — жду подтверждения на следующем тике"
    return 1
}
# Полный repair (vpn-toggle): mark-core + несущая + FORWARD/MASQUERADE + DNS + apply-bypass +
# conntrack -F. Идемпотентен и транспорт-aware (vpn-toggle сам читает .transport). Письмо —
# throttl'ом (RULEHEAL_NOTIFY сек), чтобы патологический цикл «repair не помог» не спамил.
# Поводов ТРИ (снесены правила / пропал маршрут несущей / пропало ip rule при живом маршруте),
# действие и троттл — ОДНИ: второй копии `repair` + письма не заводим, иначе они разъедутся по
# условиям отправки.
do_rule_repair() {   # $1=строка в лог  $2=тема письма  $3=тело письма
    log "$1"
    rm -f "$WIPE_SEEN" "$ROUTELOST_SEEN" "$RULELOST_SEEN" 2>/dev/null   # счёт подтверждений — заново: следующий детект снова начнётся с первого тика
    [ -f "$VPN_TOGGLE" ] && sh "$VPN_TOGGLE" repair >>"$LOG" 2>&1
    if [ "$(stamp_age "$RULEHEAL_STAMP")" -ge "$RULEHEAL_NOTIFY" ]; then
        date +%s > "$RULEHEAL_STAMP"
        # Троттл тут СВОЙ (RULEHEAL_STAMP выше), поэтому окно обёртки 0: второго троттла не надо,
        # а журнал панели нужен — «роутер сам восстановил правила» человек должен увидеть в истории.
        notify_ev "rule-heal" 0 "$2" "$3"
    fi
}
heal_split_rules() {
    if [ "$NF_LANG" = en ]; then
        do_rule_repair "rule-heal: несущая ($1) жива, но FORWARD/сплит снесён (fw3-reload?) → vpn-toggle.sh repair" \
            "BE7000: VPN rules restored (firewall reset)" \
"Looks like the router firewall reloaded (a change in the Xiaomi web UI or a firewall
restart) and wiped the VPN routing rules, while the tunnel itself stayed up.
The watchdog noticed the carrier FORWARD rule was gone and replayed the rules (vpn-toggle repair):
marking, FORWARD/MASQUERADE and DNS-through-tunnel are back — split tunneling works again."
        return
    fi
    do_rule_repair "rule-heal: несущая ($1) жива, но FORWARD/сплит снесён (fw3-reload?) → vpn-toggle.sh repair" \
        "BE7000: восстановил правила VPN (сброс firewall)" \
"Похоже, firewall роутера перезагрузился (изменение в веб-панели Xiaomi или перезапуск
фаервола) и снёс правила маршрутизации VPN, хотя сам туннель остался жив.
Watchdog заметил пропажу FORWARD-правила несущей и переиграл правила (vpn-toggle repair):
маркировка, FORWARD/MASQUERADE и DNS-через-туннель восстановлены — сплит-туннель снова работает."
}
# ПРАВИЛА НЕ ПРО VPN, КОГДА VPN ВЫКЛЮЧЕН (или транспорта нет вовсе). Три rule-heal'а выше судят по НЕСУЩЕЙ, а в этом состоянии её
# нет — и чужой reload (вебморда Xiaomi, перезапуск фаервола) сносил блокировки по адресам, гео-«Блок», запрет IPv6 и «доступ
# домой» до ребута, при включённых тумблерах (хвост 10 ревью dev233). Ответ «обязано стоять, а нет» — у ВЛАДЕЛЬЦЕВ, верб `wired`
# (0 — стоит или ставить нечего, 3 — снесено, иное — «не знаю»; единицу отдаёт любой общий отказ скрипта — старая копия без
# верба, нет библиотеки, — и по ней сторож чинил бы по кругу): своей копии их гейтов тут нет, иначе вопрос и починка
# разъедутся. Чиним ТЕМ ЖЕ `repair` (с флагом он возвращает ровно эти правила, VPN не трогая) и ВТОРЫМ тиком подряд — как сплит:
# починка кончается сбросом соединений, а одиночное «нет» бывает и от пересборки цепочки владельцем.
nonvpn_q() {   # $1 — скрипт, $2 — что это для человека, дальше — верб с аргументами
    _nvf=$1; _nvl=$2; shift 2
    [ -f "$ENODIA_DIR/$_nvf" ] || return 0
    sh "$ENODIA_DIR/$_nvf" "$@" >/dev/null 2>&1
    [ "$?" = 3 ] && _nvw="${_nvw:+$_nvw, }$_nvl"
    return 0
}
nonvpn_rules_sweep() {
    _nvw=
    nonvpn_q lists-update.sh "блокировки по спискам" wired ipblock
    nonvpn_q geo.sh "гео-«Блок»" wired
    nonvpn_q net-tune.sh "запрет IPv6" wired
    nonvpn_q vpn-server.sh "«доступ домой»" wired
    if [ -z "$_nvw" ]; then rm -f "$NONVPN_SEEN" "$NONVPN_TRIED" "$NONVPN_TRIED.what" 2>/dev/null; return 0; fi
    # Первое «нет» — ОТМЕТКОЙ ВРЕМЕНИ, как у соседних *_SEEN: «второй тик подряд» — это WIPE_CONFIRM секунд, а не «когда-нибудь».
    # Бессрочная отметка доживала бы до следующего выключения VPN (дни), и разовое «нет» в окне пересборки цепочки владельцем
    # чинилось бы сразу, одним тиком — со сбросом соединений и письмом про сброс firewall, которого не было.
    if [ ! -f "$NONVPN_SEEN" ] || [ "$(stamp_age "$NONVPN_SEEN")" -gt "$WIPE_CONFIRM" ]; then
        date +%s > "$NONVPN_SEEN"
        log "nonvpn-check: в ядре нет ($_nvw) — жду подтверждения следующим тиком"
        return 0
    fi
    rm -f "$NONVPN_SEEN" 2>/dev/null
    # ПОЧИНКА НЕ ПОМОГЛА — НЕ ПО КРУГУ. Владелец может честно говорить «обязано стоять», а поставить не выходит (модуля ядра нет,
    # утилита отказывает) — и тогда каждые два тика шли бы починка, сброс соединений и строка в лог. То же самое после починки —
    # повтор не раньше NONVPN_RETRY; другое (снесли ещё что-то) — сразу.
    if [ -f "$NONVPN_TRIED" ] && [ "$(cat "$NONVPN_TRIED.what" 2>/dev/null)" = "$_nvw" ] \
       && [ "$(stamp_age "$NONVPN_TRIED")" -lt "$NONVPN_RETRY" ]; then
        log "nonvpn-check: после починки снова нет ($_nvw) — повтор не раньше чем через ${NONVPN_RETRY} с"
        return 0
    fi
    date +%s > "$NONVPN_TRIED" 2>/dev/null; printf '%s\n' "$_nvw" > "$NONVPN_TRIED.what" 2>/dev/null
    if [ "$NF_LANG" = en ]; then
        do_rule_repair "rule-heal: VPN выключен или не настроен, а снесено: $_nvw (fw3-reload?) → vpn-toggle.sh repair" \
            "BE7000: blocking and access rules restored (firewall reset)" \
"Looks like the router firewall reloaded (a change in the Xiaomi web UI or a firewall restart) and wiped
rules that live even with the VPN off: address blocking, the IPv6 block or home access.
The watchdog noticed and put them back (vpn-toggle repair). The VPN stays off."
        return 0
    fi
    do_rule_repair "rule-heal: VPN выключен или не настроен, а снесено: $_nvw (fw3-reload?) → vpn-toggle.sh repair" \
        "BE7000: восстановил блокировки и доступ (сброс firewall)" \
"Похоже, firewall роутера перезагрузился (изменение в веб-панели Xiaomi или перезапуск фаервола) и снёс
правила, которые живут и при выключенном VPN: $_nvw.
Watchdog заметил это и вернул их (vpn-toggle repair). VPN остаётся выключенным."
}
heal_carrier_route() {
    if [ "$NF_LANG" = en ]; then
        do_rule_repair "route-heal: несущая ($1) жива, но default из table 1000 пропал → vpn-toggle.sh repair" \
            "BE7000: VPN route restored" \
"The tunnel stayed up (the server answers), but the route into it disappeared from the VPN
routing table — all traffic that should go through the VPN went direct, and site names stopped
resolving. The watchdog noticed and replayed the rules (vpn-toggle repair): the route through the
tunnel and DNS are restored."
        return
    fi
    do_rule_repair "route-heal: несущая ($1) жива, но default из table 1000 пропал → vpn-toggle.sh repair" \
        "BE7000: восстановил маршрут VPN" \
"Туннель остался жив (сервер отвечает), но из таблицы маршрутизации VPN пропал сам маршрут в
него — весь трафик, который должен идти через VPN, уходил напрямую, а имена сайтов переставали
резолвиться. Watchdog заметил это и переиграл правила (vpn-toggle repair): маршрут через туннель
и DNS восстановлены."
}
heal_carrier_rule() {
    if [ "$NF_LANG" = en ]; then
        do_rule_repair "rule-heal: несущая ($1) держит маршрут, но ip rule fwmark→1000 пропал → vpn-toggle.sh repair" \
            "BE7000: VPN routing rule restored" \
"The tunnel is up and the route into it is in place, but the rule that sends marked traffic into
the VPN routing table was missing — so everything that should have gone through the VPN was going
direct, while the router still reported the VPN as working. The watchdog replayed the rules
(vpn-toggle repair): split tunneling works again."
        return
    fi
    do_rule_repair "rule-heal: несущая ($1) держит маршрут, но ip rule fwmark→1000 пропал → vpn-toggle.sh repair" \
        "BE7000: восстановил правило маршрутизации VPN" \
"Туннель поднят, маршрут в него на месте, но пропало правило, которое отправляет помеченный
трафик в таблицу маршрутизации VPN. Из-за этого всё, что должно идти через VPN, шло напрямую —
а роутер по-прежнему показывал, что VPN работает. Watchdog заметил расхождение и переиграл
правила (vpn-toggle repair): раздельное туннелирование снова работает."
}

# --- health ДОП-ВЫХОДОВ (слотов мульти-транспорта, Ф2) --------------------------------
# Основной транспорт сторожит весь цикл ниже (failover-лестница). Доп-выходы (slots.sh) — своя
# ЛЁГКАЯ проба БЕЗ авто-перебора серверов слота (v1, дизайн §«Отказ слота»): дохлую несущую слота
# гасим → table 100N пустеет → mark-core уводит трафик слота по его fallback-политике (main|direct),
# а не блэкхолит в мёртвый туннель. Сторожим awg-слоты (дохлую несущую гасим → fallback) и
# byedpi-слоты (Ф1c: ciadpi/hev самовыключаются → ПЕРЕПОДНИМАЕМ на месте idem-slot-up, иначе гасим)
# и xray/hy2-слоты (Ф3: здоровье спрашиваем у плагина вербом slot-health — там egress-проба).
# zapret-слоту сторож не нужен (несущей нет, десинк на прямом пути).
# Событие на слот — throttl'ом (не спамим).
slot_hs_age() {   # $1 = iface (awgN) -> возраст handshake в сек (999999 = нет)
    [ -n "$WG" ] || { echo 999999; return; }
    _hs=$($WG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    age_since "$_hs"          # не «now - hs»: скачок часов иначе хоронит живой выход (clock-lib.sh)
}
# ОКНО БУТА: судить доп-выход ещё рано. Тик со СНЯТЫМ грейсом доходит до свипа на 60–120-й секунде
# (раскладка `bins`: несущие слотов только что подняли — heal или мы сами), а egress-проба идёт по
# ХОЛОДНОМУ outbound'у: у основной несущей ради этого заведён прогревочный повтор (health_warm),
# у слота его нет. Приговор «выход недоступен» тут стоил бы гашения живого выхода и письма с
# часовым троттлом на КАЖДОМ буте. Поднять — поднимаем (это и есть польза раннего тика), а вердикт
# откладываем до первого честного тика после грейса (ревью 06.09.2026).
slot_boot_window() { [ "$(up_secs)" -lt "$BOOT_GRACE" ]; }
# «НЕДОСТУПЕН» И «СНОВА РАБОТАЕТ» — ДВЕ ПОЛОВИНЫ ОДНОГО ЭПИЗОДА (пожелание тестера 02.10.2026: журнал говорил только о падении
# выхода, и после каждого письма приходилось лезть проверять, вернулся ли он). Выходы xray/hy2/byedpi сторож переподнимает сам
# на каждом тике, и удачный подъём знал лишь его лог. Отметка эпизода — `$SLOT_DOWN.<id>`: падение объявляем ОДИН раз на эпизод
# (прежде — на каждом тике, пока выход лежит: ×N в журнале, письмо — по часовому троттлу), возврат — ТОЛЬКО у объявленного
# падения: штатный подъём на буте и переподъём, который помог до вердикта, письма не заслуживают. Ключи — пара одного повода
# (events.sh class_of: slot-fail-*/slot-ok-* = «сбой VPN»), иначе выключенные падения слали бы возвраты. ТРОТТЛ У ОБЕИХ — НОЛЬ:
# «раз на эпизод» и так держит отметка, а часовой троттл у «недоступен» (наследие писем на каждом тике) при втором падении в час
# глушил его, и «снова работает» приходило без пары (ревью с.93).
# Отметка в /tmp: ребут — новый эпизод (выходы поднимает heal, итог загрузки — своё событие boot-ok/boot-fail).
SLOT_DOWN=/tmp/enodia-slot-down
slot_fail_event() {   # $1=id $2=cfg $3=fallback $4=причина: desync|noanswer|gone|nocarrier|hevpath|hs:<сек> $5=транспорт выхода
    # VPN ВЫКЛЮЧИЛИ, ПОКА ШЁЛ СВИП: флаг свип смотрит один раз на входе, а дальше вербы несущих под carrier_run отказывают — и отказ
    # читался бы падением выхода («сервер не отвечает», а после «Включить VPN» — ещё и «снова работает»). Выход снял человек,
    # вместе со всем VPN: эпизода нет (ревью с.93, круг 2).
    [ -f "$ENODIA_STATE/.vpn-off" ] && return 0
    [ -f "$SLOT_DOWN.$1" ] && return 0
    echo "$2" > "$SLOT_DOWN.$1"
    [ -f "$NOTIFY_EVENT" ] || return 0
    case "$4" in
        desync)   _sfr="десинк не поднялся"; _sfe="desync did not come up" ;;
        noanswer) _sfr="сервер выхода не отвечает"; _sfe="the exit's server does not answer" ;;
        gone)     _sfr="несущая исчезла"; _sfe="the carrier is gone" ;;
        nocarrier) _sfr="несущая не поднялась — причина в логе сторожа"; _sfe="the carrier did not come up — the reason is in the watchdog log" ;;
        hevpath)  _sfr="сервер отвечает, но путь клиентов через прослойку hev не работает и перезапуск её не помог"
                  _sfe="the server answers, but the clients' path through the hev layer does not work and restarting it did not help" ;;
        hs:*)     _sfr="рукопожатие ${4#hs:} с назад"; _sfe="last handshake ${4#hs:} s ago" ;;
        *)        _sfr=$4; _sfe=$4 ;;
    esac
    # ЧТО БУДЕТ ДАЛЬШЕ — по ФАКТУ поведения свипа, а не одной фразой на всех: несущие xray/hy2/byedpi он поднимает заново каждый
    # тик, а снятый выход AmneziaWG пробует с растущей паузой (slot_awg_return) — и обещанные сроки обязаны совпадать с её
    # SLOT_RETRY_FIRST/SLOT_RETRY_MAX.
    case "$5" in
        awg) _sfn="Роутер проверяет его сервер, не трогая остальной трафик: сперва через 2 минуты, потом всё реже — до раза в полчаса. Когда сервер ответит, выход вернётся сам, и придёт письмо «снова работает»."
             _sfne="The router checks its server without touching the rest of the traffic: first in 2 minutes, then less and less often — down to once every half hour. Once the server answers, the exit comes back by itself and a \"works again\" email follows." ;;
        *)   _sfn="Роутер пробует поднять его заново каждые 2 минуты — когда сервер ответит, выход вернётся сам, и придёт письмо «снова работает»."
             _sfne="The router retries every 2 minutes — once the server answers, the exit comes back by itself and a \"works again\" email follows." ;;
    esac
    # Несущая не встала вовсе — сервер не судили, и обещать «когда сервер ответит» нельзя: мешает то, что на роутере.
    if [ "$4" = nocarrier ]; then
        _sfn="Сервер при этом не проверялся: мешает сам роутер. Проверьте в панели конфиг выхода и компонент AmneziaWG — роутер пробует снова с растущей паузой, и выход вернётся, как только несущая поднимется."
        _sfne="The server was not checked at all: the router itself is in the way. Check the exit's config and the AmneziaWG component in the panel — the router keeps retrying with a growing pause, and the exit comes back as soon as the carrier comes up."
    fi
    if [ "$4" = hevpath ]; then
        _sfn="Роутер поднимает выход заново с растущей паузой — сперва через 2 минуты, потом всё реже, до раза в полчаса; когда путь заработает, выход вернётся сам, и придёт письмо «снова работает»."
        _sfne="The router brings the exit up again with a growing pause — first in 2 minutes, then less and less often, down to once every half hour; once the path works, the exit comes back by itself and a \"works again\" email follows."
    fi
    if [ "$NF_LANG" = en ]; then
        _fbl=$([ "$3" = direct ] && echo "direct" || echo "through the main tunnel")
        sh "$NOTIFY_EVENT" "slot-fail-$1" 0 \
            "BE7000: extra exit #$1 is down" \
"Extra exit #$1 (server $2) does not respond ($_sfe).
Its traffic is switched to the fallback path: $_fbl.
$_sfne" >/dev/null 2>&1
    else
        _fbl=$([ "$3" = direct ] && echo "напрямую" || echo "через основной туннель")
        sh "$NOTIFY_EVENT" "slot-fail-$1" 0 \
            "BE7000: доп-выход №$1 недоступен" \
"Дополнительный выход №$1 (сервер $2) не отвечает ($_sfr).
Его трафик переключён на запасной путь: $_fbl.
$_sfn" >/dev/null 2>&1
    fi
}
slot_back_event() {   # $1=id $2=cfg — выход прошёл проверку; письмо, только если его падение было объявлено
    [ -f "$SLOT_DOWN.$1" ] || return 0
    rm -f "$SLOT_DOWN.$1" 2>/dev/null
    log "slot-health: выход №$1 ($2) снова работает — эпизод недоступности закрыт"
    [ -f "$NOTIFY_EVENT" ] || return 0
    if [ "$NF_LANG" = en ]; then
        sh "$NOTIFY_EVENT" "slot-ok-$1" 0 \
            "BE7000: extra exit #$1 works again" \
"Extra exit #$1 (server $2) responds again — its traffic goes through it again, not via the fallback path." >/dev/null 2>&1
    else
        sh "$NOTIFY_EVENT" "slot-ok-$1" 0 \
            "BE7000: доп-выход №$1 снова работает" \
"Дополнительный выход №$1 (сервер $2) снова отвечает — его трафик опять идёт через него, а не запасным путём." >/dev/null 2>&1
    fi
}
# АВТОВОЗВРАТ ВЫХОДА AmneziaWG. Снятый выход (рукопожатие умерло → slot-down, или демон упал сам) прежде лежал до ручного
# «выключить и включить» либо ребута: интерфейса нет, судить нечего, и свип проходил мимо. Пробует плагин (transport.sh slot-probe,
# разбор в transport-awg.sh cmd_slot_probe) БЕЗ перепроводки: неудачная попытка соединений дома не сбрасывает, поэтому пробуем
# сразу со следующего тика, а пауза растёт вдвое до потолка — лежащий долго сервер не стоит демона и 15 с тика каждые 2 минуты.
# Состояние — `<отметка> <пауза>` в $SLOT_RETRY.<id>: отметка ставится и при снятии (первая попытка — через SLOT_RETRY_FIRST),
# отметка — АПТАЙМ (uptime_s), возраст — up_age: часы роутера прыгают, а отметку в /tmp перенос часов не видит (clock-lib.sh, разбор
# у up_age — ревью с.93, круг 3: после скачка на сутки пауза «не кончалась» сутки). Сроки обещает письмо о падении
# (slot_fail_event) — правишь числа, правь и текст. «Сервер не ответил» — повод объявить эпизод (раз на эпизод: отметка
# SLOT_DOWN): прежде выход, снятый в окне бута, письма не получал вовсе — отложенный вердикт не доходил ни до какого тика.
SLOT_RETRY=/tmp/enodia-slot-retry
SLOT_RETRY_FIRST=120
SLOT_RETRY_MAX=1800
# Пауза — «<отметка> <пауза, с> <транспорт>»: у выхода сменили транспорт — чужая пауза новому не мешает (её и снимает slot_retry_wait).
# Ею пользуются ДВА случая: возврат снятого AmneziaWG-выхода (slot_awg_return) и выход xray/hy2/byedpi с мёртвым путём через hev
# (slot_hevpath_down) — оба про то, что переподъём каждые 2 минуты платил бы сбросом соединений дома, ничего не меняя.
slot_retry_arm() { echo "$(uptime_s) ${2:-$SLOT_RETRY_FIRST} ${3:-}" > "$SLOT_RETRY.$1"; }   # $1 = id ; $2 = пауза, с ; $3 = транспорт
# 0 — пауза ещё идёт. Запас 30 с: тики идут через 2 минуты с дрожанием, и пауза «120» без него пропускала бы целый тик.
slot_retry_wait() {   # $1 = id ; $2 = транспорт выхода. Разобранную паузу оставляет в _srti (её берёт slot_retry_next).
    _srt=$(cat "$SLOT_RETRY.$1" 2>/dev/null)
    _srts=$(printf '%s' "$_srt" | cut -d' ' -f1); _srti=$(printf '%s' "$_srt" | cut -d' ' -f2); _srtt=$(printf '%s' "$_srt" | cut -d' ' -f3)
    case "$_srti" in ''|*[!0-9]*) _srti=0 ;; esac
    if [ -n "$_srtt" ] && [ "$_srtt" != "$2" ]; then rm -f "$SLOT_RETRY.$1"; _srti=0; return 1; fi
    [ "$_srti" -gt 0 ] && [ $(( $(up_age "$_srts") + 30 )) -lt "$_srti" ]
}
slot_retry_next() {   # $1 = id ; $2 = транспорт — следующая пауза: вдвое от прежней (первая — SLOT_RETRY_FIRST), до потолка
    slot_retry_wait "$1" "$2"
    if [ "$_srti" -gt 0 ]; then _srti=$((_srti * 2)); else _srti=$SLOT_RETRY_FIRST; fi
    [ "$_srti" -gt "$SLOT_RETRY_MAX" ] && _srti=$SLOT_RETRY_MAX
    slot_retry_arm "$1" "$_srti" "$2"
}
slot_awg_return() {   # $1=id $2=cfg $3=fallback $4=транспорт выхода
    slot_boot_window && return 0    # на буте выходы поднимает heal: проба гонялась бы с его slot-up за один и тот же awgN
    slot_retry_wait "$1" "$4" && return 0
    sh "$TRANSPORT_SH" slot-probe "$1" >>"$LOG" 2>&1; _srr=$?
    case "$_srr" in
        0) rm -f "$SLOT_RETRY.$1"
           log "slot-health: awg-выход №$1 ($2) — сервер снова отвечает, выход возвращён"
           slot_back_event "$1" "$2"
           return 0 ;;
        2) return 0 ;;                  # плагин пробы не умеет (дрейф деплоя) — прежнее поведение: лежит до ручного включения
        5) return 0 ;;                  # несущая уже есть (подняли панель/heal) — не возврат; её судит awg-ветка свипа (и маршрут достроит)
        6) rm -f "$SLOT_RETRY.$1"; log "slot-health: выход №$1 выключили или сменили, пока шла проба возврата — вердикта нет"; return 0 ;;
    esac
    # Проба идёт до 15 с, а выключение/смену выхода в панели она не ждёт (лока у тех вербов нет): выход, который за это время
    # выключили или перевели на другой конфиг, не «сервер не отвечает» — не пишем и паузу не копим (ревью с.93).
    _srs=$(sh "$SLOTS_SH" show "$1" 2>/dev/null)
    if [ "$(printf '%s' "$_srs" | cut -f6)" != on ] || [ "$(printf '%s' "$_srs" | cut -f3)" != awg ] || [ "$(printf '%s' "$_srs" | cut -f4)" != "$2" ]; then
        rm -f "$SLOT_RETRY.$1"
        log "slot-health: выход №$1 выключили или сменили, пока шла проба возврата — вердикта нет"
        return 0
    fi
    case "$_srr" in
        3) ;;                           # ключ занят живым держателем: сервер ни при чём, письма нет, пауза растёт
        4) slot_fail_event "$1" "$2" "$3" nocarrier "$4" ;;   # несущая не встала: сервер не судили — и письмо говорит это
        *) slot_fail_event "$1" "$2" "$3" noanswer "$4" ;;
    esac
    slot_retry_next "$1" "$4"
}
# Выход xray/hy2/byedpi: сервер отвечает, а путь клиентов через ЕГО hev мёртв, и перезапуск hev не помог (slot-health код 5,
# slot-tun-lib.sh::slot_hev_path_check). Переподъём на каждом тике тут лишь рвал бы соединения дома (slot-up + slot-down, ревью с.93,
# круг 2) ⇒ снимаем выход (трафик — запасным путём) и ждём с растущей паузой; причина в письме — правдивая.
slot_hevpath_down() {   # $1=id $2=cfg $3=fallback $4=транспорт выхода
    log "slot-health: $4-выход №$1 ($2): сервер отвечает, а путь клиентов через hev мёртв и перезапуск hev не помог → гашу несущую (fallback=$3), следующая попытка — с растущей паузой"
    sh "$TRANSPORT_SH" slot-down "$1" >>"$LOG" 2>&1
    slot_retry_next "$1" "$4"
    slot_boot_window || slot_fail_event "$1" "$2" "$3" hevpath "$4"
}
# Свежий лок браузер-свипа byedpi = панель СЕЙЧАС применяет стратегии вживую (ciadpi перезапускается
# на каждой). Сторож обязан молчать: иначе принял бы штатный рестарт за падение и «переподнял» выход
# посреди пробы, испортив замер. Лок общий на основную несущую и выходы (см. transport-byedpi.sh).
bp_sweep_fresh() {
    [ -f /tmp/enodia-byedpi-sweep.lock ] || return 1
    _bts=$(cat /tmp/enodia-byedpi-sweep.lock 2>/dev/null | tr -d ' \r\n')
    case "$_bts" in ''|*[!0-9]*) return 1 ;; esac
    # Через age_since: голая разность после скачка часов делает СВЕЖИЙ лок «старым», сторож
    # перестаёт молчать и переподнимает выход посреди пробы — ровно то, от чего лок и заведён.
    [ "$(age_since "$_bts")" -lt 180 ]
}
slot_health_sweep() {
    # `-f`, а НЕ `-x`: зовём через `sh`, и снятый бит выполнения (дрейф деплоя) тихо выключал бы
    # сторож доп-выходов ЦЕЛИКОМ — ровно грабля Б5-9 (`bd_any_byedpi_slot`).
    [ -f "$SLOTS_SH" ] || return 0
    # Идёт смена транспорта (панель/CLI/cross сторожа держат enodia-switching.lock): несущие сейчас
    # снимаются и поднимаются штатно, и любая проба здоровья слота в этом окне читается как отказ.
    # Тот же гард стоит в health/failover byedpi (батч 5).
    [ -e "$SWITCH_LOCK" ] && return 0
    # VPN ВЫКЛЮЧЕН ЧЕЛОВЕКОМ — свип молчит. Гейт выше (TRANSPORT_OK=0) выводит тик через finish(),
    # а finish зовёт ИМЕННО ЭТОТ свип — то есть мимо гейта. Цена: после ребута с выключенным VPN
    # несущих слотов нет вовсе (heal их сознательно не поднимает), слот-health честно отвечает
    # «просел», и через две минуты свип поднимал бы их обратно вторым инстансом xray/ciadpi —
    # ровно жалоба «выключаю, а оно воскресает», только про доп-выходы: трафика в них нет (ip rule
    # снят `vpn-toggle off`), а ОЗУ и письма о падении слота есть. Найдено ревью 02.09.2026.
    [ -f "$ENODIA_STATE/.vpn-off" ] && return 0
    _sen=$(sh "$SLOTS_SH" list-enabled 2>/dev/null)
    # Выход выключили или удалили посреди эпизода «недоступен» — отметка осиротела: номер займёт НОВЫЙ выход, и его первый
    # здоровый тик назвался бы «снова работает» (slot_back_event).
    # То же у паузы возврата AmneziaWG-выхода (slot_awg_return): новый выход на этом номере ждал бы чужую паузу.
    for _sdm in "$SLOT_DOWN".* "$SLOT_RETRY".*; do
        [ -f "$_sdm" ] || continue
        printf '%s\n' "$_sen" | cut -f1 | grep -qx "${_sdm##*.}" || rm -f "$_sdm"
    done
    [ -n "$_sen" ] || return 0
    printf '%s\n' "$_sen" | while IFS="$TAB" read -r sid st scfg sfb; do
        if [ "$st" = byedpi ]; then
            bp_sweep_fresh && continue          # идёт браузер-свип — рестарты ciadpi штатны
            # Лок протух, а бэкап выхода остался = браузер закрыли, не завершив свип: на выходе
            # висит СЛУЧАЙНАЯ стратегия последнего раунда. Возвращаем исходную (у основной несущей
            # то же делает transport-byedpi.sh cmd_health, но он бежит, лишь когда byedpi — активный
            # транспорт, а выход живёт и при awg).
            if [ -f "$ENODIA_STATE/.byedpi-args-s$sid.sweepbak" ]; then
                log "slot-health: браузер-свип выхода №$sid брошен — восстанавливаю исходную стратегию"
                sh "$ENODIA_DIR/transport-byedpi.sh" sweep-end "$sid" >>"$LOG" 2>&1
            fi
            # byedpi-выход (Ф1c): несущая = ciadpi(pid)+hev+xtunN. Здоровье спрашиваем у ПЛАГИНА
            # (verb slot-health): он делает egress-пробу через socks выхода, а не только смотрит
            # pid+tun. Разница существенна: ciadpi умеет БЫТЬ ЖИВЫМ процессом и не форвардить
            # (accept-EINVAL рубит приём соединений, процесс и xtunN остаются) — по pid+tun выход
            # выглядел здоровым, а трафик группы уходил в никуда. rc=2 = плагин старой версии
            # (дрейф деплоя) -> судим по прежним лёгким признакам, чтобы не гасить выход вслепую.
            # Просел -> ПЕРЕПОДНИМАЮ на месте идемпотентным slot-up (он же переиграет mark-core).
            # Не вышло -> гашу -> fallback. Переподнять, а не бросить выход — как reup_carrier у
            # основного byedpi (ciadpi известно самовыключается).
            # Выход снят из-за мёртвого пути через hev (slot_hevpath_down) — до конца паузы не поднимаем: каждый подъём со сбросом
            # соединений дома, а hev, который не вылечил перезапуск, следующий тик не вылечит тоже.
            # Пауза — только пока несущей выхода НЕТ: выход, который за это время подняла панель (включила, сменила сервер), судим
            # сразу, иначе он до 30 минут жил бы без присмотра (ревью с.96, круг 2).
            slot_retry_wait "$sid" "$st" && ! ip link show "xtun$sid" >/dev/null 2>&1 && continue
            _rc=2
            [ -f "$TRANSPORT_SH" ] && { sh "$TRANSPORT_SH" slot-health "$sid" >>"$LOG" 2>&1; _rc=$?; }
            if [ "$_rc" = 0 ]; then
                rm -f "$SLOT_RETRY.$sid"
                slot_back_event "$sid" "$scfg"       # жив по пробе: объявленное падение закрыто (переподъём ниже — ещё не вердикт)
                continue                             # плагин: выход жив (демоны + egress) -> не трогаем
            elif [ "$_rc" = 5 ]; then
                slot_hevpath_down "$sid" "$scfg" "$sfb" "$st"   # сервер жив, путь через hev мёртв — не переподнимаем по кругу
                continue
            elif [ "$_rc" = 4 ]; then
                continue                             # путь через hev мёртв, но идёт смена транспорта — не судили, следующий тик спросит
            elif [ "$_rc" = 2 ]; then
                _bp=$(cat "/tmp/enodia-byedpi-s$sid.pid" 2>/dev/null | tr -d ' \r\n')
                if [ -n "$_bp" ] && kill -0 "$_bp" 2>/dev/null && ip link show "xtun$sid" >/dev/null 2>&1; then
                    slot_back_event "$sid" "$scfg"
                    continue                         # старый плагин: ciadpi жив + tun есть -> считаем живым
                fi
            fi
            log "slot-health: byedpi-выход №$sid просел (ciadpi/tun/egress) -> переподнимаю на месте"
            # Переподъём — ещё не вердикт, и проверяем его СРАЗУ, как у xray/hy2 ниже (ревью с.93, круг 3): выход, снятый из-за
            # мёртвого пути через hev, после паузы поднимается сюда же — и без пробы маршрут 100N вёл бы в тот же мёртвый hev до
            # следующего тика, а каждый цикл паузы стоил бы двух сбросов соединений дома.
            _rc=1
            if [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-up "$sid" >>"$LOG" 2>&1; then
                _rc=2; sh "$TRANSPORT_SH" slot-health "$sid" >>"$LOG" 2>&1; _rc=$?
            fi
            # 2 — плагин старой версии: подъём удался, судить пробой нечем (как раньше); 4 — путь через hev судить сейчас нельзя (смена транспорта)
            if [ "$_rc" = 0 ] || [ "$_rc" = 2 ] || [ "$_rc" = 4 ]; then
                log "slot-health: byedpi-выход №$sid переподнят"
                if [ "$_rc" = 0 ]; then rm -f "$SLOT_RETRY.$sid"; slot_back_event "$sid" "$scfg"; fi
            elif [ "$_rc" = 5 ]; then
                slot_hevpath_down "$sid" "$scfg" "$sfb" "$st"
            elif slot_boot_window; then
                log "slot-health: byedpi-выход №$sid не поднялся, но идёт бут — вердикт откладываю до тика после грейса"
            else
                [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-down "$sid" >>"$LOG" 2>&1
                slot_fail_event "$sid" "$scfg" "$sfb" desync "$st"
            fi
            continue
        fi
        if [ "$st" = xray ] || [ "$st" = hy2 ]; then
            # xray/hy2-выход (Ф3): несущая = демон+hev+xtunN, но смерть VPS видна ТОЛЬКО
            # egress-пробой (процесс и tun при мёртвом сервере живы) ⇒ здоровье спрашиваем у
            # САМОГО плагина вербом slot-health (он знает свои pid/порт) — в отличие от
            # awg/byedpi-веток, где сторож смотрит признаки сам. Живой -> не трогаем.
            # Просел -> ОДНА попытка переподнять на месте идемпотентным slot-up (типовой
            # случай: демон упал/socks умолк), не вышло -> гасим -> fallback-политика.
            # Перебора РЕЗЕРВОВ у слота нет by design (v1, дизайн §«Отказ слота»).
            [ -f "$TRANSPORT_SH" ] || continue
            slot_retry_wait "$sid" "$st" && ! ip link show "xtun$sid" >/dev/null 2>&1 && continue    # снят из-за мёртвого пути через hev — ждём паузу, пока его не подняли (как у byedpi выше)
            sh "$TRANSPORT_SH" slot-health "$sid" >>"$LOG" 2>&1; _rc=$?
            [ "$_rc" = 0 ] && { rm -f "$SLOT_RETRY.$sid"; slot_back_event "$sid" "$scfg"; continue; }   # выход жив
            [ "$_rc" = 2 ] && continue                  # плагин старой версии (дрейф деплоя) — судить не по чем, не трогаем
            [ "$_rc" = 5 ] && { slot_hevpath_down "$sid" "$scfg" "$sfb" "$st"; continue; }   # сервер жив, путь через hev мёртв
            [ "$_rc" = 4 ] && continue                  # путь через hev мёртв, но идёт смена транспорта — не судили (ни «жив», ни «упал»)
            log "slot-health: $st-выход №$sid ($scfg) не отвечает -> переподнимаю на месте"
            _rc=1
            if sh "$TRANSPORT_SH" slot-up "$sid" >>"$LOG" 2>&1; then sh "$TRANSPORT_SH" slot-health "$sid" >>"$LOG" 2>&1; _rc=$?; fi
            if [ "$_rc" = 0 ]; then
                log "slot-health: $st-выход №$sid переподнят"
                rm -f "$SLOT_RETRY.$sid"
                slot_back_event "$sid" "$scfg"          # подъём + проба прошли — это уже вердикт
            elif [ "$_rc" = 4 ]; then
                log "slot-health: $st-выход №$sid переподнят; путь клиентов через hev судить сейчас нельзя (смена транспорта) — следующим тиком"
            elif [ "$_rc" = 5 ]; then
                slot_hevpath_down "$sid" "$scfg" "$sfb" "$st"
            elif slot_boot_window; then
                log "slot-health: $st-выход №$sid ещё не отвечает, но идёт бут (outbound холодный) — вердикт откладываю до тика после грейса"
            else
                sh "$TRANSPORT_SH" slot-down "$sid" >>"$LOG" 2>&1
                slot_fail_event "$sid" "$scfg" "$sfb" noanswer "$st"
            fi
            continue
        fi
        [ "$st" = awg ] || continue                 # у zapret-слота несущей нет — сторожить нечего
        # Без бинаря awg возраст handshake не прочитать: slot_hs_age отдаёт 999999, и выход был бы
        # ПОГАШЕН по ложному «мёртв». Нечем судить — не трогаем (как rc=2 у плагинов выше).
        [ -n "$WG" ] || continue
        sif="awg$sid"
        if ! ip link show "$sif" >/dev/null 2>&1; then
            # несущая исчезла (демон упал). fallback=main требует ip rule -> table 1000, но mark-core
            # ставил её на 100N при живой несущей; пустая 100N проваливает трафик в main=НАПРЯМУЮ,
            # игнорируя main-политику. Переигрываем — ТОЛЬКО когда правило реально устарело (0xN->100N),
            # иначе churn каждый тик. fallback=direct пустую 100N уже трактует как «напрямую» — цель.
            # Правило чиним ДО пробы (она идёт до 15 с, и всё это время трафик выхода шёл бы напрямую), а объявляем падение ПОСЛЕ:
            # демон, упавший сам, проба обычно поднимает тем же тиком — и пара писем «недоступен»/«снова работает» о минуте,
            # которую никто не заметил, была бы шумом. Не поднялся — проба объявила эпизод сама (noanswer), `gone` её не дублирует.
            _sgone=0
            if [ "$sfb" = main ] && ip rule show 2>/dev/null | grep -qE "fwmark 0x$sid(/\S+)? lookup 100$sid"; then
                log "slot-health: awg-выход №$sid — несущая исчезла, fallback=main → переигрываю (table 1000)"
                restore_marking
                _sgone=1
            fi
            slot_awg_return "$sid" "$scfg" "$sfb" "$st"
            [ "$_sgone" = 1 ] && ! ip link show "$sif" >/dev/null 2>&1 && slot_fail_event "$sid" "$scfg" "$sfb" gone "$st"
            continue
        fi
        _age=$(slot_hs_age "$sif")
        if [ "$_age" -lt "$HS_DEAD" ]; then              # выход жив — не трогаем; пауза возврата больше не нужна
            rm -f "$SLOT_RETRY.$sid"
            # …но ЖИВОЙ awgN без маршрута в 100N (поднят, а не достроен: проба, убитая посреди, гонка с панелью) по рукопожатию не
            # отличить от рабочего — keepalive держит его свежим, и выход навсегда остался бы на запасном пути (ревью с.93, круг 2).
            # slot-up идемпотентен: несущую не пересоздаёт, только кладёт маршрут и правила.
            if ! ip route show table "100$sid" 2>/dev/null | grep -q '^default'; then   # not-wan: несущая СЛОТА (table 100N)
                log "slot-health: awg-выход №$sid жив, но маршрута в table 100$sid нет — достраиваю (slot-up)"
                sh "$TRANSPORT_SH" slot-up "$sid" >>"$LOG" 2>&1
            fi
            slot_back_event "$sid" "$scfg"
            continue
        fi
        # БЕЗ KEEPALIVE ВОЗРАСТ РУКОПОЖАТИЯ — НЕ СВИДЕТЕЛЬСТВО. WireGuard обновляет рукопожатие, лишь когда через туннель идут
        # пакеты; у выхода без трафика (привязок нет, устройство спит) возраст растёт линейно, и мы гасили ЖИВОЙ выход с письмом
        # «сервер не отвечает» — по кругу, каждые пару минут (замер 10.09.2026 на BE3600 тестера: исправный awg0 резервом рос
        # так же). Keepalive выходу ставит плагин при подъёме (transport-awg.sh slot_keepalive); без него живёт выход, поднятый
        # прежней версией. Такому — ОДИН идемпотентный slot-up за загрузку (тёплый путь плагина включит keepalive; пакет уйдёт
        # сразу, и истёкшие ключи обновятся), вердикт — следующим тиком. Не чаще раза: slot-up сбрасывает conntrack, и
        # несработавший `awg set` иначе превратился бы в сброс соединений каждые две минуты — такой выход просто не судим.
        # «Не годен» = нет вовсе ИЛИ длиннее нашего (при 100–120 с возраст без трафика доходит до 120 + keepalive ≥ HS_DEAD) —
        # тот же предикат, что у плагина (transport-awg.sh slot_keepalive: он такое опускает до SLOT_KEEPALIVE = SLOT_KA_MAX).
        if $WG show "$sif" persistent-keepalive 2>/dev/null | awk -v cap="$SLOT_KA_MAX" '$2=="off" || $2+0>cap {f=1} END {exit !f}'; then
            _ska="/tmp/enodia-slot-ka.$sid"
            if [ ! -f "$_ska" ]; then
                : > "$_ska"
                log "slot-health: awg-выход №$sid ($scfg): рукопожатию ${_age}с, но keepalive нет (или длиннее ${SLOT_KA_MAX}с) — без трафика это норма; переподнимаю на месте (плагин поставит keepalive; если ключ занят — откажет, причина строкой ниже), вердикт — следующим тиком"
                [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-up "$sid" >>"$LOG" 2>&1
            fi
            continue
        fi
        # несущая поднята, но handshake мёртв (сервер слота лёг) → трафик группы блэкхолит в дохлый
        # туннель. Гасим несущую (transport.sh slot-down: down awgN + mark-core -> fallback).
        # В БУТ-ОКНЕ ДЕЛАЕМ БЕЗОПАСНУЮ ПОЛОВИНУ, А НЕ НИЧЕГО (ревью 3, 06.09.2026). Прежняя правка
        # выходила `continue` ДО всякого действия — и мёртвая несущая слота оставалась в table 100N
        # блэкхолом на все ~3 минуты до честного тика, против инварианта «оставленный маршрут =
        # БЛЭКХОЛ вместо fail-open». Гасим (fallback заработает сразу), а откладываем ровно то, что
        # и должно ждать: ВЕРДИКТ человеку — письмо о падении выхода.
        log "slot-health: awg-выход №$sid ($scfg) мёртв (handshake ${_age}с) → гашу несущую → fallback=$sfb"
        if slot_boot_window; then
            [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-down "$sid" >>"$LOG" 2>&1
            slot_retry_arm "$sid" "" "$st"
            log "slot-health: идёт бут — письмо о выходе №$sid откладываю до тика после грейса (его скажет первая проба возврата)"
            continue
        fi
        [ -f "$TRANSPORT_SH" ] && sh "$TRANSPORT_SH" slot-down "$sid" >>"$LOG" 2>&1
        slot_retry_arm "$sid" "" "$st"
        slot_fail_event "$sid" "$scfg" "$sfb" "hs:$_age" "$st"
    done
}

# ВЫХОД ИЗ ТИКА, который НЕ теряет свип доп-выходов. ГРАБЛЯ (ревью 04.08.2026): сам свип стоял
# ОДИН РАЗ в самом низу файла, а ветка tunnel-транспорта (.transport != awg — то есть ВСЕ альты,
# ради которых выходы и заводят) кончается `exit 0` в КАЖДОМ из семи путей ⇒ при активном
# xray/hy2/byedpi/zapret доп-выходы не сторожились ВООБЩЕ: дохлая несущая слота держала трафик
# группы/устройства в блэкхоле до ребута или ручного клика в панели, хотя код сторожа для этого
# написан и работает. Здесь свип идёт ПОСЛЕДНИМ (как и раньше — после всех решений по основному
# транспорту), поэтому порядок действий не меняется. Ветки «интернета нет вообще» и boot-grace
# выходят обычным `exit 0` НАМЕРЕННО: без аплинка egress-пробы слотов провалятся все разом, и
# свип погасил бы живые выходы + прислал по письму на каждый. ИСКЛЮЧЕНИЕ — снятый грейс
# (boot_grace_waived): такой тик доходит сюда до 180 с аптайма, и свипы обязаны это знать —
# прогрев доменов в этом окне пропускается (heal только что прогрел сам), свипы слотов и DoH
# идут (слот с накопителя тут и поднимется, у DoH свой троттл и гейт авто-режима).
# ПЕРИОДИЧЕСКИЙ ПРОГРЕВ ДОМЕННЫХ ПРАВИЛ. Наборы enodia_list/enodia_bypass наполняет dnsmasq в момент,
# когда САМ резолвит домен. Там, где клиенты спрашивают наш dnsmasq, набор пополняется даром — и
# эта функция ничего не меняет. А там, где клиенты ходят мимо (свой AdGuard Home или Pi-hole на
# NAS, DoH в браузере, DNS вписан руками), наполнителей ровно два: прогрев при добавлении правила
# и прогрев на буте. Между ними адреса протухают по TTL и переезжают у CDN, а обновить их некому,
# и правило тихо перестаёт действовать — на ВСЕХ устройствах разом.
# Своей cron-строки не заводим (как у usb-offload): тик сторожа и так ходит каждые 2 минуты,
# троттл дешевле отдельного расписания. WARM_TRIES=1 — без повторов и пауз: свипу надо освежить
# адреса, а не дождаться демона, и задерживать тик на секунды за домен нельзя (следующий встанет
# на локе). Живёт в finish() СОЗНАТЕЛЬНО: сюда не попадают ветки «интернета нет» и boot-grace, а
# без аплинка резолв всё равно провалится и только сожжёт время тика. Тик со СНЯТЫМ грейсом сюда
# доходит — и прогрев пропускает по аптайму: heal прогрел домены секунды назад (5.16), второй
# шторм nslookup на буте ничего не освежит.
domain_warm_sweep() {
    [ -f "$ENODIA_DIR/domain.sh" ] || return 0
    # Отметку пишет и heal (5.16) — прогрев там и тут ОДНА операция, так что троттл ниже сам по
    # себе закрывает бутовое окно. Гейт по аптайму оставлен вторым рубежом: он честно говорит, что
    # тик со СНЯТЫМ грейсом (uptime < 180) греть не должен, даже если отметки почему-то нет.
    [ "$(up_secs)" -ge "$BOOT_GRACE" ] || return 0
    [ "$(stamp_age "$DOMWARM_STAMP")" -ge "$DOMWARM_INTERVAL" ] || return 0
    date +%s > "$DOMWARM_STAMP"
    _dw=$(WARM_TRIES=1 sh "$ENODIA_DIR/domain.sh" warm 2>&1)
    # В лог — только когда есть что сказать: в норме верб печатает одну строку «выполнен».
    case "$_dw" in
        *"не попал"*|*ПЕРЕПОЛНЕН*|*"не ответил"*)
            log "domain-warm: $(printf '%s' "$_dw" | tr '\n' ' ')" ;;
    esac
}

# ПЕРИОДИЧЕСКАЯ ЖИВОСТЬ АВТО-DoH. Политика, троттл и сам откат — в doh-lib.sh (второй копии тут
# нет), мы только зовём и рассказываем человеку. Живёт в finish() по той же причине, что и прогрев
# доменов: сюда не попадают ветки «интернета нет вообще» и boot-grace, а без аплинка проба
# провалилась бы вслепую и выключила бы исправный резолвер на час. Keepalive выше (doh_want +
# doh_start) отвечает на «демон упал», эта строка — на «демон жив, а ответов нет»: разные вопросы,
# и второй до 09.08.2026 не задавал никто. Старая установка без doh-lib → команды нет → no-op.
# РЕЗОЛВЕР МИМО НЕСУЩЕЙ, ПОКА ТА ПОД ПОДОЗРЕНИЕМ. Политика и сами правила — в doh-lib.sh (второй
# копии тут нет), мы только зовём в двух точках вердикта (несущая усомнилась / снова везёт) и
# рассказываем человеку. ЗАЧЕМ: при «Шифрованном DNS» upstream у dnsmasq ровно один и он сам
# заперт маркой в несущую ⇒ мёртвая несущая = дом без DNS, а конфиг по имени без DNS не поднять
# (замерено 14.08.2026: 10+ минут без DNS при живом WAN). Старая установка без doh-lib → no-op.
doh_follow_carrier() {   # $1 = suspect|ok
    command -v doh_untunnel >/dev/null 2>&1 || return 0
    if [ "$1" = suspect ]; then
        doh_untunnel && log "DoH: несущая под подозрением — резолвер уведён МИМО неё (шифрование сохранено, DNS дома жив)"
    else
        # Код 2 = несущая везёт, а резолвер ЧЕРЕЗ неё не отвечает (VPS не достаёт до резолвера):
        # библиотека вернула его мимо и молчит бэкофф — человеку об этом сказать обязаны мы.
        doh_retunnel; case $? in
            0) log "DoH: несущая снова везёт — резолвер вернулся в туннель" ;;
            2) log "DoH: несущая везёт, а резолвер ЧЕРЕЗ неё не отвечает — остаётся мимо неё (шифрование сохранено), повтор через $(( ${DOH_RETUNNEL_BACKOFF:-1800} / 60 )) мин" ;;
        esac
    fi
    return 0
}

doh_health_sweep() {
    command -v doh_health_tick >/dev/null 2>&1 || return 0
    # Идёт смена транспорта: DNS сейчас переставляют штатно, и проба в этом окне читается как
    # отказ резолвера (тот же гард и по той же причине стоит в slot_health_sweep).
    [ -e "$SWITCH_LOCK" ] && return 0
    # ГЕЙТ АПЛИНКА передаём ФУНКЦИЕЙ, а не флагом: политика живёт в doh-lib, а «жив ли аплинк»
    # умеет считать только сторож. Нужен потому, что обещание «в finish() не попадают ветки
    # „интернета нет“» держится не везде: у zapret health чисто локальный (nfqws жив), и при
    # аварии У ПРОВАЙДЕРА тик доходит сюда с ПРОЙДЕННЫМ health — проба валится, и через два
    # тика мы выключили бы исправный резолвер на час. wan_probe_ok платный (curl 4 с), поэтому
    # doh-lib зовёт его ТОЛЬКО когда проба уже провалилась. inet_reachable брать нельзя: он
    # ведёт счётчики эпизода wan-down и слал бы письма про провайдера из DNS-ветки.
    # ПОРТ DoT — ПЕРВЫМ: выбран DoT, а порт 853 текущим путём не проходит (у альт-выхода его не выпускает
    # сервер, 443 идеален — замер 09.09.2026) ⇒ doh-lib переводит прокси на DoH того же резолвера, а раз в
    # час пробует вернуть DoT. Раньше проверки резолвера: судить о нём надо уже на рабочем порте. Событие в
    # журнал пишет сама библиотека (владелец переезда), здесь — строка лога сторожа.
    if command -v doh_port_tick >/dev/null 2>&1; then
        doh_port_tick wan_probe_ok; case $? in
            3) log "DoH: DoT текущим путём не отдаёт имён, а DoH того же резолвера отдаёт — шифрованный DNS переведён на DoH" ;;
            4) log "DoH: DoT снова отдаёт имена — шифрованный DNS вернулся на выбранный DoT" ;;
            # Повтор — не на следующей сверке, а через DOH_DOT_RETRY (бэкофф doh_port_tick; ревью ветки, круг 3).
            5) log "DoH: DoT текущим путём не отдаёт имён, и DoH того же резолвера тоже — остаюсь на DoT, следующая попытка переезда — через $(( ${DOH_DOT_RETRY:-3600} / 60 )) мин" ;;
        esac
    fi
    doh_health_tick wan_probe_ok; _dhr=$?
    [ "$_dhr" = 0 ] && return 0
    if [ "$_dhr" = 2 ]; then
        log "DoH (авто): карантин истёк — пробую включить шифрованный DNS снова"
        return 0
    fi
    log "DoH (авто): резолвер перестал отвечать — вернул обычный DNS, авто-режим не трогаю час"
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "doh-auto-off" 3600 \
        "BE7000: шифрованный DNS не отвечает — вернул обычный" \
"Роутер сам включал шифрованный DNS (DoH), пока туннель не используется. Резолвер перестал
отвечать: имена не резолвились, и из-за этого не открывались даже те сайты, что работают напрямую.
DNS возвращён на обычный ($DOH_PLAIN_DNS1 / $DOH_PLAIN_DNS2), интернет должен заработать сразу.
Через час роутер попробует включить шифрованный DNS снова. Если это повторяется — смените
резолвер в панели (Сеть → Шифрованный DNS) или выключите там авто-режим." >/dev/null 2>&1
    return 0
}

# Порядок НЕ произволен: живость DNS проверяем ДО прогрева доменов. Прогрев БЕЗУСЛОВНО
# переставляет свой часовой штамп, и на тике отката он сжёг бы слот, резолвя через резолвер,
# который следующей же строкой признаётся мёртвым, — правила по доменам остались бы на протухших
# адресах ещё на час. Обратной зависимости нет: проба резолвера от прогрева не зависит.
finish() { slot_health_sweep; doh_health_sweep; domain_warm_sweep; exit "${1:-0}"; }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# tsw <транспорт> — ЕДИНСТВЕННЫЙ способ тика сменить транспорт. Флаг `.vpn-off` тик проверяет в начале, но человек может нажать
# «Отключить VPN», пока идёт фолбэк или cross: оркестратор тогда откажет сам (автомат флаг не снимает, а выключение, пришедшее
# по ходу подъёма, доводит владельцем — transport.sh::vpn_off_won). Тик же, дойди он до своей ветки «переход не удался», послал
# бы письмо о прямом режиме и записал FAILED про VPN, выключенный вручную. Уходим МОЛЧА — через finish(), как тик, заставший
# флаг в начале (хвост (7) ревью dev233).
tsw() {
    # Ручная смена идёт ПРЯМО СЕЙЧАС (лок появился после начала тика) — она побеждает: cross поверх неё переписал бы выбор человека.
    if [ -e "$SWITCH_LOCK" ]; then log "идёт смена транспорта (лок) — смену на $1 не делаю, тик дальше не ведёт"; finish; fi
    sh "$TRANSPORT_SH" switch "$1" >>"$LOG" 2>&1; _tswrc=$?
    off_bail "смены на $1"
    return "$_tswrc"
}
# ПОДЪЁМ НЕСУЩЕЙ СТОРОЖЕМ (`transport.sh up` — первый подъём и переподъём awg0) — ПОД ЛОКОМ СМЕНЫ ТРАНСПОРТА. `switch` берёт лок
# сам, а `up` — нет, и подъём на десятки секунд шёл без него. ГРАБЛЯ (BE7000 02.10.2026): сторож поднимал xray после аварии
# провайдера, человек в ту же минуту переключил панелью на AmneziaWG — `switch` погасил xray ДО того, как подъём дописал пидфайлы,
# и xray с hev остались жить сиротами при `.transport=awg`. Закончись подъём позже — он переписал бы флаг и маршрут, то есть
# отменил бы ручной выбор. Лок создаём АТОМАРНО (`set -C`: busybox ash умеет, замер BE7000) и кладём в него свой пид — по нему
# панель отличает живого держателя и ЖДЁТ его (cgi-bin/action hold_switch), а не идёт поверх. Снимает и ловушка выхода тика.
# Лок занят — ручная смена идёт сейчас, и она побеждает: тик уходит.
WD_SWL=0
wd_switch_take() {   # $1 — что собирались делать (в лог)
    # Метка держателя — потомкам (подъём несущей): тик унесут `kill -9`, а их работу лок обязан держать дальше (daemon-lib.sh).
    if ( set -C; echo $$ > "$SWITCH_LOCK" ) 2>/dev/null; then WD_SWL=1; switch_holder_mark; return 0; fi
    log "идёт смена транспорта (лок) — $1 не делаю, тик дальше не ведёт"
    finish
}
wd_switch_drop() { [ "$WD_SWL" = 1 ] && rm -f "$SWITCH_LOCK" 2>/dev/null; WD_SWL=0; return 0; }
# off_bail <что> — ТО ЖЕ для КАЖДОЙ долгой операции тика, а не только смены транспорта: перебор серверов (минуты), переподъём awg0,
# возврат несущей из прямого режима. Несущую при флаге плагин уже не поднимет (daemon-lib.sh::carrier_run), но тик после такой
# операции писал NORMAL/FAILOPEN, «встали на резерв» и событие «VPN восстановлен» про VPN, выключенный вручную (ревью ветки, круг 2).
off_bail() {
    [ -f "$ENODIA_STATE/.vpn-off" ] || return 0
    log "VPN выключили вручную посреди $1 — тик дальше не ведёт"
    finish
}

notify() {
    # $1 — тема, $2 — текст. Молчим, если уведомления выключены флагом
    # или notify.sh недоступен. notify.sh сам тихо выйдет, если почта ещё
    # не настроена (пустой notify.conf), так что watchdog от этого не падает.
    if [ -f "$NOTIFY_OFF" ]; then
        log "notify выключен флагом .notify-off — письмо не отправлено: '$1'"
        return
    fi
    [ -f "$NOTIFY" ] && sh "$NOTIFY" "$1" "$2" >>"$LOG" 2>&1
}

# То же письмо, но ЧЕРЕЗ обёртку событий: throttle по ключу + запись в «центр уведомлений» панели.
# notify() выше — прямой SMTP, без того и без другого, и для ПОВТОРЯЮЩЕГОСЯ повода это разом спам
# и слепая панель (письмо ушло, а в истории пусто). Нет обёртки (установка старше неё) — шлём как
# раньше: важное письмо не должно молча пропасть из-за порядка обновления файлов.
#
# ПОЧЕМУ ЧЕРЕЗ НЕЁ ИДУТ И РАЗОВЫЕ ПЕРЕХОДЫ (throttle 0). Падение VPN, уход на резерв и возврат —
# самые важные записи журнала, и панель прямо обещает их человеку («здесь появятся: падение VPN и
# уход на резерв, автооткат сервера»). Они звали notify() напрямую, то есть письмо уходило, а в
# истории роутера не оставалось НИЧЕГО — замерено на BE7000 18.08.2026: после импорта пришло письмо
# «VPN восстановлен», а файла `.events` на роутере не существовало вовсе. Троттл этим поводам не
# нужен и вреден (второе падение подряд — это НОВОСТЬ, а не спам): они и так edge-triggered по
# $STATE/$XSTATE, поэтому ключ есть, а окно 0 — почта ведёт себя ровно как раньше, журнал появился.
notify_ev() {   # $1 ключ, $2 throttle_sec, $3 тема, $4 текст
    if [ -f "$NOTIFY_EVENT" ]; then
        sh "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1
    else
        notify "$3" "$4"
    fi
}
# ПИСЬМО «ПРЯМОЙ РЕЖИМ» — РАЗ НА ЭПИЗОД АВАРИИ, а не на каждый переход в FAILED (хвост ревью с.96). У туннельных транспортов выход из
# FAILED молчит (письма «восстановлен» у них нет), и стойко мёртвый путь через hev давал письмо раз в 30–40 мин: истекла пауза —
# фаза 0 failover «встала» на свежем hev, тик спустя путь снова мёртв — «прямой режим». Эпизод открывает первое письмо; повтор внутри
# него идёт в журнал (notify-event пишет его ДО почтовых гейтов), а письмом — не чаще FAILOPEN_REMIND, напоминанием о затяжной беде.
# Закрывает эпизод письмо «VPN восстановлен» (вернулся AmneziaWG — vpn_ok_mailed) или ТИХОЕ восстановление, продержавшееся
# FAILOPEN_STABLE (vpn_ok_quiet на здоровом тике): короткое «встало» внутри цикла эпизод не закрывает. Отметки — в /tmp, возраст —
# аптайм (up_age): ребут начинает эпизоды заново, а скачок часов их не задевает.
VPN_DOWN_EP=/tmp/enodia-vpn-down.episode
VPN_OK_SINCE=/tmp/enodia-vpn-ok.since
FAILOPEN_STABLE=${FAILOPEN_STABLE:-1800}
FAILOPEN_REMIND=${FAILOPEN_REMIND:-86400}
failopen_mail() {   # $1 тема, $2 текст
    _fog=0; [ -f "$VPN_DOWN_EP" ] && _fog=$FAILOPEN_REMIND
    rm -f "$VPN_OK_SINCE"; : > "$VPN_DOWN_EP"
    notify_ev "vpn-failopen" "$_fog" "$1" "$2"
}
vpn_ok_mailed() { rm -f "$VPN_DOWN_EP" "$VPN_OK_SINCE"; }
vpn_ok_quiet() {
    [ -f "$VPN_DOWN_EP" ] || return 0
    _vos=$(cat "$VPN_OK_SINCE" 2>/dev/null)
    case "$_vos" in ''|*[!0-9]*) uptime_s > "$VPN_OK_SINCE"; return 0 ;; esac
    [ "$(up_age "$_vos")" -ge "$FAILOPEN_STABLE" ] && rm -f "$VPN_DOWN_EP" "$VPN_OK_SINCE"
    return 0
}

# ВОЗВРАТ ДОМОЙ — ТОЖЕ СОБЫТИЕ. До 16.09.2026 его знал только лог сторожа: журнал держал уход на
# резерв (cross-switch, failover-ok), а возврата в нём не было НИКОГДА, и история переключений на
# экране «Резервирование» читалась бы как «уехали и не вернулись». КЛЮЧЕЙ ДВА: `failback` — возврат
# протокола (туннель→AmneziaWG, AmneziaWG→туннель), `failback-server` — возврат сервера AmneziaWG. Один ключ с
# разными окнами глушил письмо о возврате сервера отметкой возврата протокола, а журнал сливал оба в одну
# строку ×2 (ревью шага 3c-2, круг 2). Оба ключа панель знает (FO_EV_KEYS) и журнал красит «событием»
# (events.sh level_of). Событие зовут только на УСПЕХЕ, судя по факту, а не по попытке.
failback_event() {   # $1 transport|server, $2 подпись дома (имя протокола либо сервера)
    ip=$(ext_ip)
    if [ "$1" = server ]; then
        # Окно — как у серверного УХОДА (failover-ok, 1800 с): мигающий домашний сервер иначе слал бы письмо о возврате
        # каждые FAILBACK_INTERVAL, а об уходе — вдвое реже. Протокольный возврат — окном 0, как cross-switch.
        if [ "$NF_LANG" = en ]; then
            notify_ev "failback-server" 1800 "BE7000: VPN is back on the main server $2" \
"The main server $2 answers again — the router returned to it from the backup.
External IP now: ${ip:-unknown}."
        else
            notify_ev "failback-server" 1800 "BE7000: VPN вернулся на основной сервер $2" \
"Основной сервер $2 снова отвечает — роутер вернулся на него с резервного.
Внешний IP сейчас: ${ip:-неизвестен}."
        fi
    elif [ "$NF_LANG" = en ]; then
        notify_ev "failback" 0 "BE7000: back on the home protocol $2" \
"The home protocol $2 carries traffic again — the router returned to it from the backup.
External IP now: ${ip:-unknown}."
    else
        notify_ev "failback" 0 "BE7000: вернулись на домашний протокол $2" \
"Домашний протокол $2 снова везёт — роутер вернулся на него с резервного.
Внешний IP сейчас: ${ip:-неизвестен}."
    fi
}

# ОТКАТ ВЕРНУЛ ПРЕЖНИЙ ТУННЕЛЬ, И ОН СНОВА ВЕЗЁТ (хвост (8) ревью dev233). Туннель провалил пробу, сторож попробовал уйти на
# другой протокол (фолбэк «Выкл» на AmneziaWG либо cross лестницы), тот не поднялся, а откат оркестратора поднял прежний туннель —
# и его VPS за время перехода ожил. Тик остаётся на нём, но до 28.09.2026 молча: письма и события не было ни о провале пробы, ни
# о неудачном переходе, ни о перерыве связи на время смены — история переключений на экране «Резервирование» его не знала. Ключ
# `cross-rollback`: уровень — «работает, но не штатно» (глоб `*rollback` в events.sh), класс — переключения. Окно 1800 с, как у
# ухода на резерв: мигающий VPS иначе слал бы письмо на каждую попытку (их держит пауза лестницы, 10–30 мин).
revived_event() {   # $1 — подпись протокола, на который не ушли
    ip=$(ext_ip)
    if [ "$NF_LANG" = en ]; then
        notify_ev "cross-rollback" 1800 "BE7000: $TLABEL carries traffic again — the move to $1 did not happen" \
"$TLABEL failed the health check, and the watchdog tried to move to $1 — it did not come up.
The rollback brought $TLABEL back, and it carries traffic again: its server apparently recovered
during the move. The connection was interrupted for the duration of the move.
External IP now: ${ip:-unknown}."
    else
        notify_ev "cross-rollback" 1800 "BE7000: $TLABEL снова везёт — переход на $1 не удался" \
"$TLABEL не прошёл проверку здоровья, и сторож попробовал перейти на $1 — тот не поднялся.
Откат вернул $TLABEL, и он снова везёт: похоже, его сервер ожил за время перехода. Связь на время
перехода прерывалась.
Внешний IP сейчас: ${ip:-неизвестен}."
    fi
}

# ВЫБРАН ТРАНСПОРТ, КОТОРОГО НА РОУТЕРЕ НЕТ. Повод общий у обеих веток ниже (tunnel и awg), потому
# и текст ОДИН: для человека разница между «Xray» и «AmneziaWG» здесь только в имени, а вопрос тот
# же — бэкап настроек переносит выбор сервера и правила, но не программы. Ключ тоже общий: два
# письма об одном и том же за сутки не нужны.
transport_missing_event() {   # $1 — человекочитаемое имя транспорта
    if [ "$NF_LANG" = en ]; then
        notify_ev "transport-missing" 86400 \
            "BE7000: a VPN is selected, but its component is not installed" \
"The router settings select transport $1, but the program itself is not on the router — this is
what a move looks like: a settings backup carries the server choice and the rules, but not the
programs (they are two orders of magnitude heavier).
Right now the router works DIRECTLY: the internet is there, listed sites bypass the VPN.
What to do: open the panel at :8088 → «Components» and install $1 — everything comes up by
itself after that, the settings are already in place."
        return
    fi
    notify_ev "transport-missing" 86400 \
        "BE7000: VPN выбран, но компонент не установлен" \
"В настройках роутера выбран транспорт $1, но самой программы на роутере нет — так бывает после
переезда: бэкап настроек переносит выбор сервера и правила, а программы (они на два порядка
тяжелее) не переносит.
Роутер сейчас работает НАПРЯМУЮ: интернет есть, сайты из списка идут мимо VPN.
Что сделать: откройте панель :8088 → «Компоненты» и поставьте $1 — дальше всё поднимется само,
настройки уже на месте."
}

ext_ip() { probe_ext_ip "" 5; }

# Режим failover: off|sticky|home. Нет файла/мусор → sticky (ВКЛ по умолчанию).
fo_mode() {
    m=$(cat "$FAILOVER_MODE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$m" in off|sticky|home) printf '%s' "$m" ;; *) printf 'sticky' ;; esac
}
# СМЕНА РЕЖИМА РЕЗЕРВИРОВАНИЯ — НОВАЯ ПОПЫТКА. Паузу (отметка попытки + лестница бэкоффа) у туннеля копят ДВЕ ветки — лестница
# резервов и фолбэк режима «Выкл» на AmneziaWG, — и она переживала смену режима: «Резерв» → «Выкл» не давал фолбэка до конца
# чужой паузы, «Выкл» → «Резерв» ждал до 30 мин (ревью dev233, круг 3). Человек сменил режим — он ждёт действия СЕЙЧАС.
# Владелец один — тик (он и копит паузу), а не CGI: режим меняет и импорт бэкапа. Первое знакомство (пустой /tmp) — не смена.
fo_mode_note() {
    _fmn=$(cat "$FO_MODE_SEEN" 2>/dev/null)
    [ "$_fmn" = "$1" ] && return 0
    echo "$1" > "$FO_MODE_SEEN"
    [ -n "$_fmn" ] || return 0
    rm -f "$FAILOVER_STAMP" "$FAILOVER_BACKOFF" 2>/dev/null
    log "режим резервирования сменился ($_fmn → $1) — пауза попыток сброшена"
    return 0
}

# Эскалация при исчерпании серверов активного протокола: cross|direct. Нет файла →
# cross (макс. устойчивость). cross — перебрать другой протокол; direct — прямой режим.
fo_escalate() {
    e=$(cat "$FAILOVER_ESCALATE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$e" in cross|direct) printf '%s' "$e" ;; *) printf 'cross' ;; esac
}

# Эпизод-гард (анти-петля): помечаем перебранные протоколы; cross не лезет в уже
# пробованный. busybox-safe (grep -w есть).
episode_has() { [ -f "$FAILOVER_EPISODE" ] && grep -qw "$1" "$FAILOVER_EPISODE" 2>/dev/null; }
episode_add() { episode_has "$1" || echo "$1" >> "$FAILOVER_EPISODE"; }
episode_reset() { : > "$FAILOVER_EPISODE"; }

# Предпочитаемый («домашний») транспорт: awg|xray|hy2. ПУСТО (нет файла) → авто-возврат
# транспорта выключен (пишется только ручным выбором человека в панели — авто-cross
# его НЕ трогает, иначе «дом» уехал бы за аварийным переключением).
transport_home() { cat "$TRANSPORT_HOME_FILE" 2>/dev/null | tr -d ' \t\r\n'; }

# Человекочитаемое имя транспорта для писем (под hy2 добавится строка). Generic-замена
# хардкоду «Xray» — теперь ветка обслуживает любой tunnel-транспорт.
transport_label() {
    case "$1" in
        awg)  echo "AmneziaWG" ;;
        xray) echo "Xray" ;;
        hy2)  echo "Hysteria2" ;;
        byedpi) echo "ByeDPI" ;;
        zapret) echo "Zapret" ;;
        *)    echo "$1" ;;
    esac
}
# Готов ли транспорт <name> к подъёму — спрашиваем ОРКЕСТРАТОР (его реестр + проверка
# плагина/секрет-конфига). Watchdog не знает имён файлов плагинов, только имена транспортов.
transport_ready() { sh "$TRANSPORT_SH" list 2>/dev/null | grep -qw "$1"; }
# Следующий готовый НЕ-awg транспорт для cross с awg (xray/hy2/… по реестру). Пусто → некуда.
cross_target_from_awg() { sh "$TRANSPORT_SH" next awg 2>/dev/null; }

# Установлен ли AmneziaWG (есть секрет-конфиг). В xray-only awg НЕТ — cross на него
# невозможен (нет awg0/awg.conf), эскалация вырождается в прямой режим. Зеркало
# HAVE_AWG установщика и have_awg из xray-transport.sh.
have_awg() { [ -f "$ENODIA_STATE/awg.conf" ]; }

# ПРАВИЛА ВОЗВРАТА ДОМОЙ — ОДНОЙ КОПИЕЙ НА ТИК И НА ВЕРДИКТ `standing` (ниже). Пока условия жили
# литералом внутри веток, ответ «вернётся ли роутер» было не у кого спросить, и экран панели сравнивал
# поля сам — и ошибался. Здесь — только «есть ли у тика такая ветка»: троттл и пробы живости дома
# (handshake, health, ping) остаются у самих веток, вердикт их не делает (он без сети).
# Имя домашнего сервера awg. Пусто → `default`: ровно так ветка возврата судила всегда.
failover_home_name() { _fhn=$(cat "$FAILOVER_HOME_FILE" 2>/dev/null); [ -n "$_fhn" ] || _fhn=default; printf '%s' "$_fhn"; }
# СТОРОЖ ВИДИТ awg0: интерфейс есть И есть чем читать handshake (`$WG`). Это ВХОД тика в awg-ветку (без
# awg0 — ветка «не поднимался / исчез», без бинаря — выход до замера) и единственный способ заметить
# оживление дома с туннеля. Один предикат на тик и на ВСЕ обещания возврата вердикта: пересказанный по
# местам, он расходился три круга подряд (ревью 3–5: то без awg0, то без бинаря, то на стороне awg).
# Бинарь пропадает не с накопителем (бинари awg резидентны), а при неполной установке или снятой утилите.
awg_watchable() { [ -n "$WG" ] && ip link show awg0 >/dev/null 2>&1; }
# Свежо ли рукопожатие настолько, что тик считает несущую живой (и только тогда идёт к веткам возврата).
awg_hs_alive() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -le "$HS_ALIVE" ]; }
# Возраст последнего рукопожатия awg0 (999999 = не было вовсе). Читает ЯДРО, без сети.
awg_hs_age() {
    _hsa=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    case "$_hsa" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$_hsa" -gt 0 ] && age_since "$_hsa" || echo 999999
}
# Вернёт ли тик домашний ТРАНСПОРТ, когда активен $1: с туннеля — только на awg и только если сторож
# видит awg0 (без него handshake читается как 0 и возврата не будет никогда: резерв снимает
# `vpn-toggle off` через `cold`, без компонента его не держит никто); с awg — на готовый туннель пробным
# подъёмом, и тоже лишь когда тик вообще входит в awg-ветку. Пары «туннель → туннель» у тика НЕТ, и
# обещать её нельзя.
# ПРИЧИНА ОТКАЗА — В `_htb_why`, и пишет её САМ предикат, шагом перед каждой проверкой: экран обязан
# назвать, почему роутер не вернётся, а причину, выведенную где-то рядом, пришлось бы снова пересказывать
# по условиям — ровно тот класс, что шесть кругов ревью ловил в вердикте. Тику переменная не нужна.
# mode — режим не возвращает · not_ready — домашний туннель не готов к запуску · pair — туннель на
# туннель · blind — сторож не видит awg0 (см. awg_watchable). У ветки «с awg» пустой или равный awg дом
# тоже даёт not_ready: вердикт зовёт предикат только при доме, отличном от активного, — туда не попадает.
# ПОРЯДОК ПРОВЕРОК = ПОРЯДОК ГЕЙТОВ ТИКА, и это не вкусовщина: называем ПЕРВУЮ помеху, значит она обязана
# быть первой и у тика — иначе человек чинит НЕ ТО (сменит режим там, где не хватает бинаря awg). На
# стороне awg тик выходит на `awg_watchable || finish` ДО ВСЕГО, включая режим, поэтому blind проверяем
# раньше и режима, и готовности дома; на стороне туннеля такого выхода нет — там первым идёт режим, за ним
# pair (без ветки «туннель → туннель» никакой awg0 не поможет) и лишь потом blind. Код возврата от
# перестановки не меняется: это та же конъюнкция (ревью подшага 2, круги 1 и 2).
fo_home_transport_back() {
    case "$1" in
        awg) _htb_why=blind; awg_watchable || return 1 ;;
    esac
    # ОРКЕСТРАТОР — ТОЖЕ ГЕЙТ ТИКА: туннельная ветка целиком гейтится `[ -f "$TRANSPORT_SH" ]`, и любой
    # возврат транспорта идёт через него. У СЕРВЕРНОЙ стороны такая проверка была всегда (`switch-vpn.sh`
    # в fo_awg_server_away), у транспортной — нет, и вердикт обещал возврат, которого тик сделать не
    # может: оборванное обновление, точечный --push, отвалившийся накопитель (ревью подшага 2, круг 4).
    _htb_why=no_orc; [ -f "$TRANSPORT_SH" ] || return 1
    # Причина — только про ПЛАНОВЫЙ возврат. «Куда уведёт падение» отвечает отдельное поле вердикта
    # (`fo_back_on_fail` ниже): это другой вопрос, и слитый с причиной он врал в обе стороны.
    _htb_why=mode; [ "$(fo_mode)" = home ] || return 1
    _htb=$(transport_home)
    case "$1" in
        awg) _htb_why=not_ready; [ -n "$_htb" ] && [ "$_htb" != awg ] && transport_ready "$_htb" ;;
        *)   _htb_why=pair; [ "$_htb" = awg ] && { _htb_why=blind; awg_watchable; } ;;
    esac
}
# ПОЛОЖЕНИЕ «стоим НЕ на домашнем сервере» — ОТДЕЛЬНО от ВОЗМОЖНОСТИ вернуться (предикат ниже): под
# одним вопросом пропажа `switch-vpn.sh` или конфига дома меняла бы САМО ПОЛОЖЕНИЕ, и роутер на чужом
# сервере звался бы «дома» либо «дом не задан» (ревью круга 2 нашло это для явного дома; при НЕявном —
# стенд подшага 2). Явный дом — сравнения имён достаточно; дом не выбран — судим как тик: без файла
# `default.conf` сравнивать не с чем.
fo_awg_server_off_home() {
    _aoh_h=$(failover_home_name); _aoh_a=$(cat "$ACTIVE_NAME" 2>/dev/null)
    [ -n "$_aoh_a" ] && [ "$_aoh_a" != "$_aoh_h" ] || return 1
    [ -n "$(cat "$FAILOVER_HOME_FILE" 2>/dev/null)" ] || [ -f "$CONFIGS_DIR/$_aoh_h.conf" ]
}
# Стоим ли НЕ на домашнем сервере awg — и есть ли куда вернуться (режим и троттл — у вызывающего).
# Причина отказа — в `_asa_why`, тем же приёмом: gone — конфига домашнего сервера нет · no_switch —
# нет switch-vpn.sh, возвращать нечем. ИМЕНА РАЗНЫЕ У РАЗНЫХ ФАЙЛОВ: одно значение на оба (прежнее
# `incomplete`) заставляло панель называть один файл за оба, и человек искал не то (ревью, круг 6). Первая проверка («стоим не на доме») причины НЕ называет: это
# ПОЛОЖЕНИЕ, его отдельно считает fo_awg_server_off_home выше, и вердикт зовёт нас уже стоя не на доме.
# Собственное имя у неё было бы значением, которое верб не печатает никогда, — и его пришлось бы
# вычитать руками в сверке «причины ⊂ белый список» (ревью подшага 2).
fo_awg_server_away() {
    _asa_h=$(failover_home_name); _asa_a=$(cat "$ACTIVE_NAME" 2>/dev/null)
    _asa_why=""; [ -n "$_asa_a" ] && [ "$_asa_a" != "$_asa_h" ] || return 1
    _asa_why=gone; [ -f "$CONFIGS_DIR/$_asa_h.conf" ] || return 1
    _asa_why=no_switch; [ -f "$SWITCH_VPN" ]
}
# КУДА УВЕДЁТ ПАДЕНИЕ АКТИВНОГО ТРАНСПОРТА — И НЕ ДОМОЙ ЛИ. Это ВТОРОЙ ФАКТ, а не причина: планового
# возврата может не быть (режим, пара туннель→туннель, не видно awg0), а роутер всё равно окажется дома,
# когда текущий транспорт перестанет везти. Печатаем ИМЯ транспорта, только если это ДОМ, — иначе молчим:
# «уедем куда-то» человеку не помогает. Слитый с причиной, этот факт врал в обе стороны (ревью, круг 5).
# СНАЧАЛА — гейты, общие для обоих путей (они выше по тику): программа АКТИВНОГО транспорта и, на
# стороне awg, достижимость лестницы вообще (см. fo_awg_ladder_reachable). Затем — гейты самих путей:
#   · режим off: туннель не прошёл health → `switch awg` (ветка «режим=off → фолбэк на AmneziaWG»);
#     только С ТУННЕЛЯ и только при установленном компоненте — иначе switch молча откажет;
#   · иначе: пул исчерпан → `cross` на ПЕРВЫЙ готовый по реестру (`transport.sh next <активный>`),
#     при эскалации cross. ГЕЙТ ЭПИЗОДА НЕ СПРАШИВАЕМ: тик обнуляет эпизод на ПЕРВОЙ осечке health и
#     доходит до эскалации лишь следующим тиком — вопрос «пробовали ли в этом эпизоде» к тому моменту
#     уже про ДРУГОЙ эпизод, и ответ «пробовали» заставил бы вердикт молчать там, где тик уходит домой
#     (ревью 7: правило «тот же гейт» имеет вторую половину — гейт обязан отвечать НА ТОТ ЖЕ МОМЕНТ).
# ВТОРОЕ СЛОВО ОТВЕТА — КОГДА: `now` (режим «Выкл»: фолбэк срабатывает сразу по падению) либо `pool`
# (сперва тик переберёт резервные серверы текущего протокола, и лишь потом эскалация).
# ЗОВЁТ ТОЛЬКО ВЕРДИКТ: у тика этот вопрос возникает лишь дойдя до эскалации, и ответ у него тот же.
# Дойдёт ли тик до awg-лестницы. Устройство тика тут несимметрично: при ЖИВОМ awg0 он входит в замер
# и гаснет на `awg_watchable || finish` (без бинаря `awg` читать handshake нечем), а при ОТСУТСТВУЮЩЕМ
# awg0 лестница живёт в else-ветке «не поднимался / исчез» и отрабатывает. Глухой `awg_watchable` соврал
# бы в обратную сторону — молчанием там, где тик уводит домой (ревью 8).
fo_awg_ladder_reachable() {
    if ip link show awg0 >/dev/null 2>&1; then [ -n "$WG" ]; else have_awg; fi
}
fo_back_on_fail() {
    _bof_h=$(transport_home); [ -n "$_bof_h" ] || return 1
    [ -f "$TRANSPORT_SH" ] || return 1
    # ПЕРВЫЙ гейт лестницы тика — программа АКТИВНОГО транспорта: без неё подтверждённый сбой кончается
    # `safety-off` + FAILOPEN и письмом «компонент не установлен», а не переходом куда бы то ни было.
    carrier_installed "$1" || return 1
    [ "$1" != awg ] || fo_awg_ladder_reachable || return 1
    if [ "$(fo_mode)" = off ]; then
        [ "$1" != awg ] && [ "$_bof_h" = awg ] && awg_fallback_ok && { printf 'awg now'; return 0; }
        return 1
    fi
    [ "$(fo_escalate)" = cross ] || return 1
    _bof_n=$(sh "$TRANSPORT_SH" next "$1" 2>/dev/null)
    [ -n "$_bof_n" ] && [ "$_bof_n" = "$_bof_h" ] && { printf '%s pool' "$_bof_n"; return 0; }
    return 1
}

# ЛЕЖИТ ЛИ НА РОУТЕРЕ САМА ПРОГРАММА транспорта — вопрос ОТДЕЛЬНЫЙ от have_awg выше: тот про
# КОНФИГ, то есть про намерение, а намерение приезжает и ИЗ БЭКАПА ЧУЖОГО роутера (`awg.conf` в
# архиве). Спрашиваем владельца ответа — оркестратор (верб `installed <t>`).
# Именно про БИНАРИ, а не про `ready`: «не готов» бывает от трёх причин (нет бинаря · нет конфига ·
# ядро не умеет), и совет «поставьте компонент» верен ровно для первой — на ядре 4.4 zapret не
# встанет НИКОГДА, и звать туда установку значило бы гонять человека по кругу.
# Код 2 = старая копия скрипта не знает верба ⇒ считаем, что программа есть, и ведём себя как
# раньше: обновление в любом порядке не должно выключать починку на рабочем роутере.
# Отдельно от transport_ready() выше СОЗНАТЕЛЬНО: та судит по СОДЕРЖИМОМУ `list`, и пустой вывод
# (старый скрипт) читает как «не готов» — для выбора цели cross это безопасно, а для «чинить или
# нет» дало бы ровно обратное, опасное умолчание.
# ПРОБА ВЕРСИИ — ОТДЕЛЬНЫМ вербом, и это не перестраховка: спросить сразу `installed <имя>` НЕЛЬЗЯ.
# Верб `installed` существовал и РАНЬШЕ, но БЕЗ аргумента: старая копия аргумент проглотит, напечатает
# СПИСОК и вернёт код ПОСЛЕДНЕЙ итерации своего цикла (SELECTABLE кончается zapret) — то есть 1 на
# любом роутере без nfqws. Вышло бы «программы нет» там, где стоит всё, и обновление ОДНОГО файла
# (точечный --push, частичный apply-scripts) выключало бы авто-починку awg0 до ребута. Верб `ready`
# приехал ВМЕСТЕ с `installed <имя>`, поэтому его код 2 = честный признак старой копии.
carrier_installed() {
    [ -f "$TRANSPORT_SH" ] || return 0
    sh "$TRANSPORT_SH" ready "$1" >/dev/null 2>&1
    [ "$?" = 2 ] && return 0
    sh "$TRANSPORT_SH" installed "$1" >/dev/null 2>&1; _circ=$?
    [ "$_circ" != 1 ]
}
# ЕСТЬ ЛИ КУДА УЙТИ НА AmneziaWG — КОНФИГ И ПРОГРАММА ВМЕСТЕ. Один `have_awg` (есть awg.conf) врал после импорта бэкапа на
# установку «только панель»: конфиг приехал, бинарей нет — ветка «режим off» звала `switch awg`, тот отказывал («не готов»), а
# тик писал FAILED и слал письмо «вернулись на AmneziaWG» КАЖДЫЙ тик, оставляя мёртвую несущую туннеля в table 1000
# (подтверждающий круг ревью пачки 5). Одна функция на тик, вердикт `standing` и «куда уведёт падение».
# Вопрос — РОВНО гейт `switch` (`transport.sh ready awg`: плагин, обе программы, awg.conf), а не своя сборка из двух половин:
# половины расходились с ним при оборванном обновлении без transport-awg.sh (ревью dev233). Код 2 = старая копия оркестратора
# верба не знает ⇒ прежний ответ по одному awg.conf (как у `carrier_installed`: обновление в любом порядке безопасно).
awg_fallback_ok() {
    [ -f "$TRANSPORT_SH" ] || { have_awg; return; }
    sh "$TRANSPORT_SH" ready awg >/dev/null 2>&1; _afo=$?
    if [ "$_afo" = 2 ]; then have_awg; return; fi
    [ "$_afo" = 0 ]
}

# --- «НЕСУЩАЯ ЭТОГО ТРАНСПОРТА ХОТЬ РАЗ ВЕЗЛА В ЭТУ ЗАГРУЗКУ?» -------------------------------
# Зеркало $AWG0_SEEN, но для tunnel-транспортов, и заведено ради ровно того же различия:
# «несущая УПАЛА» и «несущую ЕЩЁ НЕ ПОДНИМАЛИ» дают ОДИНАКОВЫЙ провал health, а лечатся
# по-разному. У awg этот вопрос был задан, у альтов — нет, и асимметрия стоила живого случая:
# бинарь альта лежит на USB-накопителе, на буте тот ещё не смонтирован ⇒ `heal.sh` печатает
# «транспорт выбран, но поднять его нечем» и БОЛЬШЕ НЕ БЕЖИТ (лок 1×/boot). Накопитель
# монтируется секундой позже (hotplug либо mount-ensure в начале нашего же тика) — и поднять
# несущую становится некому: сторож умеет чинить ПАДЕНИЕ, а падения не было.
# ОТМЕТКУ КЛАДЁМ ПО СВОИМ ГЛАЗАМ — когда health ПРОШЁЛ, а не когда кто-то позвал `up`: «демон
# жив» ≠ «сервис работает» — инвариант проекта, и здесь он тем более уместен, что цена ошибки —
# не поднять несущую вовсе.
carrier_seen()       { [ -f "$CARRIER_SEEN_PFX$1.seen" ]; }
carrier_seen_mark()  { : > "$CARRIER_SEEN_PFX$1.seen" 2>/dev/null || true; }
# Сколько раз мы уже пробовали поднять НИ РАЗУ не поднимавшуюся несущую. Счётчик — анти-петля:
# без него тик раз в 2 минуты дёргал бы `up` вечно на роутере, где несущей взяться неоткуда.
carrier_tries()      { _cts=$(cat "$CARRIER_SEEN_PFX$1.tries" 2>/dev/null | tr -d ' \r\n')
                       case "$_cts" in ''|*[!0-9]*) _cts=0 ;; esac; printf '%s' "$_cts"; }
carrier_tries_add()  { echo $(( $(carrier_tries "$1") + 1 )) > "$CARRIER_SEEN_PFX$1.tries" 2>/dev/null || true; }
carrier_tries_reset(){ rm -f "$CARRIER_SEEN_PFX$1.tries" 2>/dev/null || true; }

# --- «ГРЕЙСУ БОЛЬШЕ НЕЧЕГО ОХРАНЯТЬ» ---------------------------------------------------------
# Boot-grace (см. тик ниже) держит сторожа в стороне, пока heal поднимает несущую на буте. Но в
# раскладке `bins` бинари приезжают ПОЗЖЕ кода: heal бежит на 61-й секунде, сток монтирует
# накопитель на 90-й (тестер, 01.09.2026) — heal честно печатает «поднять нечем», ставит лок
# `done` и больше не возвращается. Хук hotplug монтирует хранилище и сразу спавнит наш тик, а тот
# до 180 с аптайма ГИБ на грейсе ⇒ несущую поднимал первый cron-тик ПОСЛЕ грейса: до двух минут
# без транспорта при живом накопителе (разобрано кодом 05.09.2026). Грейс охраняет ровно одно —
# ПЕРВИЧНЫЙ ПОДЪЁМ heal'ом; у отработавшего heal (лок `done*`, в том числе «три прогона
# оборвались») охранять уже нечего. Снимаем грейс ТОЛЬКО при трёх условиях разом, каждое куплено:
#   · heal ОТРАБОТАЛ (лок `done`). Бегущий (пид в локе) или ещё не стартовавший heal — грейс
#     держим: иначе два подъёма наперегонки, ровно то, от чего грейс и заведён;
#   · несущая этого транспорта в эту загрузку НИ РАЗУ не везла (carrier_seen / $AWG0_SEEN) —
#     иначе это ПАДЕНИЕ, а не «не поднимали», и его судит лестница после честного грейса;
#   · маршрута несущей НЕТ ВОВСЕ (пусто в table 1000): поднятая, но ещё не прошедшая health
#     несущая (рукопожатие идёт) под ранним тиком получила бы повторный `up` поверх живого старта.
# При всех трёх тик делает ровно то, что сделал бы после грейса, — ветку «не поднимали ни разу»
# (`transport.sh up`; у awg — safety_off + снятие heal-лока, и heal поднимет awg0 сам) — просто
# на две минуты раньше. Гейты «VPN выключен», «транспорт не настроен», «программы нет», WAN и
# интернет стоят НИЖЕ и работают как прежде. Признак «нас позвал hotplug» не заводим нарочно:
# cron-тик на 60-й/120-й секунде в том же состоянии ничем не хуже, а лишняя сущность — лишний
# способ разойтись. Сценарий 21 в dev/watchdog-tick-test.sh (+ мутант R).
# carrier_absent_unraised <транспорт> — «несущей нет ВОВСЕ, и подъём ещё в наших руках»: ни разу
# не везла, маршрута в table 1000 нет, попытки ветки «не поднимали ни разу» не исчерпаны. Это же
# условие снимает у такой несущей ГИСТЕРЕЗИС SUSPECT в tunnel-ветке: гистерезис охраняет ЖИВУЮ
# несущую от разовой осечки пробы, а тут пробовать нечего — «жду подтверждения» стоило бы ещё две
# минуты без транспорта ровно там, где грейс уже снят. Исчерпанные попытки возвращают прежний
# порядок (SUSPECT → лестница), чтобы лестница входила в том же состоянии, что и раньше.
carrier_absent_unraised() {
    carrier_seen "$1" && return 1
    [ -z "$(carrier_route_dev)" ] || return 1
    heal_running && return 1                       # heal ПРЯМО СЕЙЧАС её и поднимает — не наперегонки
    [ "$(carrier_tries "$1")" -lt "$CARRIER_UP_TRIES" ]
}
# --- HEAL ПРЯМО СЕЙЧАС РАБОТАЕТ? -------------------------------------------------------------
# Лок heal несёт ПИД (`<pid> try<N> <дата>`) либо слово `done`. Вопрос нужен ДВУМ решениям, и оба
# куплены (ревью 06.09.2026):
#   * не поднимать несущую ПАРАЛЛЕЛЬНО с heal. `transport.sh up` лока не берёт, а heal доходит до
#     подъёма на 100–200-й секунде (списки, гео, ожидание сети, медленный накопитель). Тик после
#     грейса, попавший в это окно, раньше ставил SUSPECT и давал две минуты форы; со снятым
#     гистерезисом он звал бы `up` ВТОРЫМ — два `set_*_dns` наперегонки, два `doh_apply_dns`, у
#     обоих проба падает под чужим рестартом прокси, и DoH сносится в откат;
#   * не снимать лок ЖИВОГО heal (три `rm -f` в awg-ветке): снятый лок = второй heal через минуту,
#     а его `ip link del awg0` сносит интерфейс, который первый только что создал, плюс два
#     `firewall reload` и две фоновые закачки списков.
# ПИД МОГ БЫТЬ ПЕРЕИСПОЛЬЗОВАН — спрашиваем cmdline, как это делает сам heal и как проект гасит
# СВОИ демоны. Не прочли cmdline ⇒ считаем живым: неизвестность трактуем в пользу «не мешать».
# ПОТОЛОК ОБЯЗАТЕЛЕН. У самого heal его нет: он отдаёт лок живому держателю без оглядки на возраст,
# а «три оборванных прогона» срабатывают только на МЁРТВОМ. Зависший навсегда heal (блокирующий
# резолв, TLS в чёрную дыру) сделал бы этот ответ вечно истинным — и сторож перестал бы чинить
# awg-ветку до ребута. HEAL_STALE берём с запасом к самому долгому штатному прогону (замер: heal в
# раскладке `full` с закачкой zapret-cidr — 170+ с).
HEAL_STALE=${HEAL_STALE:-900}
heal_running() {
    _hr=$(cat "$HEAL_LOCK" 2>/dev/null | tr -d '\r'); _hr=${_hr%% *}
    case "$_hr" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_hr" ] || return 1
    # ПУСТОЙ cmdline — это НЕ heal (ревью 3, 06.09.2026): так выглядят ядерные потоки, и протухший
    # лок с номером, переиспользованным kworker'ом, отвечал бы «heal жив» до самого ребута — то
    # есть выключил бы починку awg-ветки насовсем. У heal.sh та же форма безобидна (там это лишь
    # «не отнимать чужой лок»), здесь цена другая.
    case "$(tr '\000' ' ' 2>/dev/null < "/proc/$_hr/cmdline")" in
        *heal.sh*) ;;
        *) return 1 ;;
    esac
    [ "$(age_since "$(stat -c %Y "$HEAL_LOCK" 2>/dev/null)")" -lt "$HEAL_STALE" ]
}
heal_done() { case "$(cat "$HEAL_LOCK" 2>/dev/null | tr -d '\r')" in done*) return 0 ;; esac; return 1; }
# Счётчик «сколько раз мы будили heal ради awg0» — по образцу carrier_tries.
heal_kick()       { _hkc=$(cat "$HEAL_KICK_CNT" 2>/dev/null | tr -d ' \r\n')
                    case "$_hkc" in ''|*[!0-9]*) _hkc=0 ;; esac; echo "$_hkc"; }
heal_kick_add()   { echo $(( $(heal_kick) + 1 )) > "$HEAL_KICK_CNT" 2>/dev/null || true
                    date +%s > "$HEAL_KICK_STAMP" 2>/dev/null || true; heal_cfg_save; }
heal_kick_reset() { rm -f "$HEAL_KICK_CNT" "$HEAL_KICK_STAMP" "$HEAL_KICK_SAID" "$HEAL_KICK_MAILED" "$HEAL_KICK_CFG" "$HEAL_SKIPPED" 2>/dev/null || true; }
# 0 = будить heal можно. Пока попыток меньше потолка — можно всегда; дальше только по возрасту
# последней попытки, и возраст считает age_since (голая разность после скачка часов объявила бы
# час прошедшим на первом же тике — ровно та грабля, из-за которой заведена clock-lib).
# КОНФИГ ПОМЕНЯЛСЯ ПОСЛЕ ПОСЛЕДНЕЙ ПОПЫТКИ ⇒ повод честно новый: человек починил ключи в панели,
# приехал импорт бэкапа, сменился активный сервер. Бюджет возвращаем целиком — иначе следующий же
# тик уводил бы на другой транспорт, не дав heal ни одной попытки на НОВОМ конфиге (ревью 3).
# СЛЕПОК, А НЕ «mtime НОВЕЕ ОТМЕТКИ» (ревью 3, вторая волна): те же три файла переписывает НАШ ЖЕ
# перебор (`switch-vpn.sh install_config` — на каждого кандидата и ещё раз на возврате исходного),
# и сравнение с отметкой видело в этом «человека»: бюджет раздавался заново после КАЖДОГО
# неудачного свипа, часовая пауза не наступала никогда, а в лог уходило ложное «конфиг изменился».
# Сравнение НА РАВЕНСТВО снимает заодно и вопрос часов: mtime на флеше остался от прошлой сессии с
# верными часами, а `date +%s` до сверки может быть МЕНЬШЕ — с `-gt` это давало «изменился» на
# каждом тике. Слепок обновляем и в момент kick'а, и СРАЗУ ПОСЛЕ лестницы (её правки — не людские).
# САМИ РЕЗЕРВНЫЕ КОНФИГИ — В СЛЕПКЕ ПОИМЁННО, а не одним mtime каталога: каталог меняется на
# появление/удаление файла, а «человек починил ключи в резервном сервере» правит СОДЕРЖИМОЕ уже
# лежащего `configs/<имя>.conf` — та правка бюджета не возвращала (хвост ревью 8). Наш собственный
# перебор их не трогает (`install_config` пишет в awg.conf/amnezia_for_awg.conf/.active), так что
# ложных «человек починил» это не добавляет. ОДИН `stat` на все аргументы разом: цикл форкал по
# процессу на элемент, а зовётся слепок на КАЖДОМ тике этой ветки. Несуществующий путь stat молча
# пропускает (stderr гасим) — исчезновение файла тоже меняет слепок, и это правда «стало иначе».
# ОДНОЙ СТРОКОЙ (`tr`): слепок печатает dump.sh формой «файл: есть -> содержимое», и многострочное
# значение разорвало бы там колонку — разбирающий читает эту секцию глазами.
# ЗАМЕРЕНО 06.09.2026 на ОБОИХ ядрах (BE7000 5.4 и AX3600 4.4, busybox v1.25.1): многоаргументный
# `stat` печатает СТРОКУ НА ФАЙЛ, `%n` поддержан, нераскрывшийся glob не печатает ничего, а
# отсутствующий путь ПРОПУСКАЕТСЯ и обход продолжается — проверено с пропажей и первым, и средним
# аргументом (rc=1, ошибка в stderr). Это и был единственный фатальный вариант: «останавливается
# на первом отсутствующем» схлопнуло бы слепок в пустоту, едва пропал `awg.conf`, и правку резерва
# мы не заметили бы никогда. Первый такой вызов в проекте — прочие одноаргументные.
heal_cfg_fp() { stat -c '%n:%Y' "$ENODIA_STATE/awg.conf" "$ENODIA_STATE/.active" \
                     "$ENODIA_STATE/amnezia_for_awg.conf" "$CONFIGS_DIR" "$CONFIGS_DIR"/*.conf 2>/dev/null \
                | tr '\n' ' '; }
heal_cfg_save() { heal_cfg_fp > "$HEAL_KICK_CFG" 2>/dev/null || true; }
heal_cfg_changed() {
    [ -f "$HEAL_KICK_CFG" ] || return 1        # попыток ещё не было — и сбрасывать нечего
    _hcc=$(heal_cfg_fp)
    # ПУСТО = «не смог прочитать», а НЕ «человек всё удалил»: ветка выше уже убедилась, что
    # `awg.conf` на месте, значит непустым слепок обязан быть. Пустым он станет разве что при
    # отвале накопителя в раскладке `full` — и тогда «изменился» раздавал бы бюджет пробуждений
    # заново на КАЖДОМ тике, то есть неизвестность читалась бы как «человек починил» (ревью 2).
    [ -n "$_hcc" ] || return 1
    [ "$_hcc" != "$(cat "$HEAL_KICK_CFG" 2>/dev/null)" ]
}
heal_kick_ok() {
    if heal_cfg_changed; then
        log "конфиг awg изменился после последней попытки — счёт пробуждений heal обнуляю"
        heal_kick_reset
        return 0
    fi
    [ "$(heal_kick)" -lt "$HEAL_KICK_TRIES" ] && return 0
    # Возраст отметки — через stamp_age, как ВСЕ остальные троттлы этого файла: своя пара
    # «cat + age_since» вела бы себя так же ровно до первой правки семантики возраста (а её
    # уже правили — кламп по аптайму), и разошлась бы молча.
    [ "$(stamp_age "$HEAL_KICK_STAMP")" -ge "$HEAL_KICK_SLOW" ]
}
boot_grace_waived() {
    [ -f "$ENODIA_STATE/.vpn-off" ] && return 1   # выключил человек: поднимать не будем — и обещать нечего
    heal_done || return 1
    _bgw_t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    [ -n "$_bgw_t" ] || return 1
    # …и ЕСТЬ ЧЕМ поднимать. Бинарь ещё не приехал (накопитель определился позже heal) ⇒ грейс
    # держим: снятый грейс открыл бы ветку «компонента нет» — safety_off, письмо с суточным
    # троттлом — ровно на те секунды, что грейс и прикрывал (ревью 05.09.2026). Hotplug-тик придёт
    # вместе с накопителем, cron-тик после грейса — как прежде.
    carrier_installed "$_bgw_t" || return 1
    if [ "$_bgw_t" = awg ]; then
        # У awg «не поднимали» = нет ни отметки, ни САМОГО интерфейса: живой awg0 без маршрута
        # (ensure_carrier не дождался, интерфейс появился позже) ушёл бы в хэндшейк-путь и reup.
        [ ! -f "$AWG0_SEEN" ] && ! ip link show awg0 >/dev/null 2>&1 && [ -z "$(carrier_route_dev)" ]
    else carrier_absent_unraised "$_bgw_t"; fi
}

# Жив ли WAN-аплинк — локально, без интернета. Отличает «лёг провайдер/кабель» от
# «лёг VPS»: при мёртвом WAN перебор серверов/транспортов БЕССМЫСЛЕН (ни один сервер
# физически недостижим) → watchdog просто ждёт, не гоняя failover вхолостую (раньше при
# пропаже WAN он перебирал ВСЕ конфиги + cross на альт каждые FAILOVER_RETRY впустую).
# КОНСЕРВАТИВНО: считаем WAN мёртвым ТОЛЬКО при явном сигнале (нет дефолт-маршрута в
# main-таблице ИЛИ carrier=0 на WAN-iface) — чтобы НЕ подавить ЗАКОННЫЙ failover, если
# шлюз провайдера просто режет ICMP. Дефолт туннеля живёт в table 1000, поэтому дефолт
# из main = реальный WAN-iface (та же логика, что в cgi-bin/ip).
# Владелец — ip-lib.sh (wan_iface нужен и сверке часов); здесь шим на случай старой библиотеки.
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }

# --- Часы: сверка с HTTP-датой мимо туннеля (clock-lib.sh::clock_boot_sync) ---------------------
# ЗАЧЕМ ЗДЕСЬ, если то же делает heal (шаг 0a+) и плагин awg (cmd_up): heal бежит на ~47-й секунде
# аптайма и 1×/boot, а WAN к тому моменту мог не подняться (PPPoE, DHCP провайдера) — тогда отметки
# нет, и повторить сверку больше некому. Обвязка «когда сверять» (отметка, лимит неудач, пауза,
# лок) — в библиотеке, у сторожа только два места, оба «пока отметки нет»: до boot-grace (часы
# обязаны встать раньше первого честного тика) и перед лестницей туннельных транспортов (Reality/
# TLS сверяют время) — уже ЗА WAN-гейтом, чтобы при «интернета нет» не жечь curl впустую.
# Громко — только когда часы реально сдвинуты (в здоровом NORMAL сторож молчит). Нет библиотеки — no-op.
clock_tick_sync() {
    command -v clock_boot_sync >/dev/null 2>&1 || return 0
    if clock_boot_sync; then log "$CLOCK_MSG"; fi
    return 0
}
# «Жив ли аплинк» — у владельца (ip-lib.sh::wan_up, сорсится в шапке; следит C81): вопрос тот же,
# что у режима поддержки, а копий было две — тут и в support.sh с пометкой DRY. Ниже шим на случай
# старой библиотеки: нет дефолта вообще → WAN не настроен/отвалился; carrier=0 → физлинк опущен.
command -v wan_up >/dev/null 2>&1 || wan_up() { _wu=$(wan_iface); [ -n "$_wu" ] || return 1; if [ -r "/sys/class/net/$_wu/carrier" ]; then [ "$(cat "/sys/class/net/$_wu/carrier" 2>/dev/null)" = "1" ] || return 1; fi; return 0; }

# --- Гейт «есть ли интернет ВООБЩЕ», а не «жив ли VPS» ---------------------------------
# ГРАБЛЯ (железо 03.08.2026): при аварии У ПРОВАЙДЕРА линк и дефолт-маршрут на месте, а
# интернета нет. wan_up() такой случай ПРОПУСКАЕТ (он сознательно смотрит только на жёсткие
# локальные признаки) ⇒ сторож каждые FAILOVER_RETRY перебирал ВЕСЬ пул конфигов с
# wait_for_handshake на каждом: за ночь 63 повтора события «резервы недоступны», свип крутился
# впустую до утра. Перебор серверов без аплинка бессмыслен ФИЗИЧЕСКИ — ни один недостижим.
#
# Второй сигнал = РЕАЛЬНАЯ egress-проба, привязанная к WAN-интерфейсу (`--interface` обязателен —
# разбор у владельца, ip-lib.sh::wan_probe_ok; там же вторая проба после промаха — wan_recheck).
# Платим за пробу ТОЛЬКО в момент аварии (перед перебором); в здоровом состоянии сторож её не делает.
# Ниже шимы на случай старой библиотеки: без них сторож потерял бы весь гейт.
command -v wan_probe_ok >/dev/null 2>&1 || wan_probe_ok() { _wpi=$(wan_iface); [ -n "$_wpi" ] || return 1; [ -n "$(probe_ext_ip "--interface $_wpi" 4)" ] && return 0; curl -s -k -o /dev/null --interface "$_wpi" --max-time 4 https://8.8.8.8/ 2>/dev/null; }
command -v wan_recheck >/dev/null 2>&1 || wan_recheck() { sleep "${WAN_RECHECK:-10}"; wan_probe_ok; }

# Событие «нет связи с провайдером» — РОВНО ОДНО на эпизод (throttle notify-event тут вторичен:
# гейтит сам штамп). Прежде этот случай молча оседал строкой в логе, а пользователь видел лишь
# ×63 «VPN упал, резервы недоступны» — письмо про VPN там, где VPN ни при чём.
wan_out_event() {
    date +%s > "$WANOUT_SWEEP"
    [ -f "$WANOUT_EVENT" ] && return 0
    date +%s > "$WANOUT_EVENT"
    log "интернета нет ВООБЩЕ ($1) — перебор серверов подавлен, жду возвращения аплинка"
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "wan-down" 1800 \
        "BE7000: нет связи с провайдером" \
"Роутер не видит интернета от провайдера ($1) — недоступен НЕ только VPN, а сеть целиком.
Перебор VPN-серверов на это время приостановлен: без аплинка ни один сервер недостижим,
и перебор лишь греет флеш и засоряет журнал.
Роутер сам заметит возвращение связи и восстановит VPN — делать ничего не нужно." >/dev/null 2>&1
    return 0
}
wan_out_clear() {
    rm -f "$WANOUT_SWEEP" "$WANOUT_VALVE" 2>/dev/null
    [ -f "$WANOUT_EVENT" ] || return 0
    rm -f "$WANOUT_EVENT" 2>/dev/null
    log "аплинк вернулся — перебор серверов снова разрешён"   # wan_out_now ниже судит по $WANOUT_SWEEP
    # Пауза ручного DoH, поставленная в аварии, — про интернет, а не про резолвер: снять, и прокси вернётся этим же или
    # следующим тиком (разбор — doh-lib.sh::doh_bail_forget). Только здесь, ПОСЛЕ гарда эпизода: на каждом здоровом тике
    # снятие обнулило бы паузу вовсе.
    if command -v doh_bail_forget >/dev/null 2>&1; then doh_bail_forget; fi
    [ -f "$NOTIFY_EVENT" ] && sh "$NOTIFY_EVENT" "wan-up" 1800 \
        "BE7000: связь с провайдером вернулась" \
"Интернет от провайдера снова доступен. Роутер возобновил обычную работу:
если VPN всё ещё не поднят, сторож переберёт серверы на ближайшем тике." >/dev/null 2>&1
    return 0
}

# ИДЁТ ЛИ ЭПИЗОД «интернета нет» ПРЯМО СЕЙЧАС — вопрос ОТДЕЛЬНЫЙ от «когда он начался»: отметку начала
# (`$WANOUT_EVENT`) пишет РОВНО ОДИН раз `wan_out_event`, и через WANOUT_FRESH она протухает ПРИ ЖИВОЙ
# аварии — вердикт на ней говорил «загружаюсь» посреди аварии провайдера (ревью подшага 2, круг 13).
# Подтверждение идёт КАЖДЫМ тиком в `$WANOUT_SWEEP`, и его же снимает `wan_out_clear` вместе с эпизодом.
# Порог — два пропущенных тика (cron раз в 2 мин): старше = либо авария кончилась, либо тик до пробы не
# доходит (занят подъёмом несущей), и тогда это уже не «нет интернета».
WANOUT_NOW=${WANOUT_NOW:-300}
wan_out_now() { [ "$(stamp_age "$WANOUT_SWEEP")" -lt "$WANOUT_NOW" ]; }

# 0 = связь есть ЛИБО судить не берёмся (действуем как раньше); 1 = подтверждённое «интернета нет».
# Гистерезис: единичный промах пробы НЕ подавляет перебор — ровно та причина, по которой в wan_up
# отвергнут ICMP-пинг шлюза: пропустить ЗАКОННЫЙ failover при реально мёртвом VPS дороже, чем
# одна лишняя проба. Жёсткий локальный сигнал (нет дефолта/carrier=0) подтверждения не требует.
# ПОДТВЕРЖДАЕМ В ЭТОМ ЖЕ ВЫЗОВЕ (wan_recheck, пауза WAN_RECHECK), а НЕ СЛЕДУЮЩИМ ТИКОМ. ГРАБЛЯ (BE7000,
# 02.10.2026): счётчик промахов жил между тиками, а «один лишний свип», которым его оправдывали, на
# деле — вся лестница целиком: первый промах в 10:08 пропустил восемь серверов AmneziaWG, cross на
# xray и ~70 его конфигов, и тик держал лок 26 минут — второй промах, подтверждающий аварию
# провайдера, пришёл лишь в 10:36. Ложное подтверждение стоит дёшево: следующий тик проверит заново
# и, если сеть есть, откроет перебор через две минуты. Внутри уже объявленного эпизода промах один —
# авария не новость, и платить ещё одной паузой каждые две минуты незачем.
inet_reachable() {
    if ! wan_up; then
        wan_out_event "нет дефолт-маршрута или линк опущен"
        return 1
    fi
    if wan_probe_ok; then wan_out_clear; return 0; fi
    if [ ! -f "$WANOUT_EVENT" ]; then
        log "egress-проба через WAN не прошла — переспрашиваю через ${WAN_RECHECK}с, не дожидаясь следующего тика"
        if wan_recheck; then
            log "…вторая проба прошла — промах единичный, перебор НЕ подавляю"
            return 0
        fi
    fi
    # Предохранитель: проба тоже может врать (провайдер заворачивает/режет ОБА anycast-адреса) —
    # тогда подавление стало бы ВЕЧНЫМ и живой резерв не подняли бы никогда. Раз в WANOUT_MAX
    # пускаем ОДИН контрольный свип вслепую: цена — дорогой перебор раз в час, зато отказ временный.
    # Гейт `-f`: эпизод объявляет wan_out_event, т.е. с ПЕРВОГО подтверждённого отказа. Без него
    # «нет файла = возраст 999999» открывал бы клапан сразу на подтверждении — то есть первое же
    # подавление пропускало бы свип и не объявляло эпизод.
    # ОТМЕТКА СВОЯ, а не `$WANOUT_SWEEP`: ту обновляет КАЖДЫЙ подтверждённый тик (по ней вердикт судит «авария идёт сейчас»), и
    # её возраст при живой аварии не дорастал до часа НИКОГДА — клапан был мёртв (BE7000 02.10.2026: 2,5 ч аварии провайдера, ни
    # одного контрольного свипа). Час считаем от начала эпизода, дальше — от прошлого свипа.
    _wvs=$WANOUT_VALVE; [ -f "$_wvs" ] || _wvs=$WANOUT_EVENT
    if [ -f "$WANOUT_EVENT" ] && [ "$(stamp_age "$_wvs")" -ge "$WANOUT_MAX" ]; then
        date +%s > "$WANOUT_VALVE"; date +%s > "$WANOUT_SWEEP"   # эпизод не кончился: свип вслепую — не «связь вернулась»
        WAN_BLIND=1
        log "интернета нет по пробе, но подавление идёт ≥$((WANOUT_MAX / 60)) мин — пускаю ОДИН контрольный свип"
        return 0
    fi
    wan_out_event "egress-проба через WAN не отвечает"
    return 1
}

# ladder_wan_gate <ступень> — ГЕЙТ АПЛИНКА ПЕРЕД СЛЕДУЮЩЕЙ СТУПЕНЬЮ ЛЕСТНИЦЫ, а не только перед первой. Перебор пула идёт
# минутами (awg — по ~25 с на сервер, туннель — десятки конфигов подписки), и провайдер ложится ПОСРЕДИ него: без этого
# вопроса тик делал cross и перебирал ещё и пул ДРУГОГО транспорта при мёртвом аплинке (BE7000 02.10.2026). Контрольный свип
# (WAN_BLIND) идёт вслепую ДО КОНЦА — иначе проба, которую режет провайдер, обрывала бы его на первой же ступени.
# Аплинка нет ⇒ тик КОНЧАЕТСЯ — `exit 0`, как у гейтов в начале веток, а не finish(): свипы доп-выходов без интернета
# погасили бы живые выходы и прислали по письму на каждый (разбор — у finish). Состояние оставляем тем, что успела
# поставить пройденная ступень (прямой режим после пула awg; прежний конфиг — у туннеля).
ladder_wan_gate() {
    [ "$WAN_BLIND" = 1 ] && return 0
    inet_reachable && return 0
    log "интернета нет вообще — $1 не делаю, жду аплинка"
    exit 0
}

# --- Бэкофф перебора пула --------------------------------------------------------------
# Свип пула стоит дорого (по конфигу × wait_for_handshake) и рвёт awg0 на каждом кандидате.
# Пока авария длится, повторять его в одном и том же ритме незачем: удваиваем паузу до кап-а,
# а любое возвращение здоровья (или аплинка) сбрасывает лестницу в исходные FAILOVER_RETRY.
fo_retry() {
    _b=$(cat "$FAILOVER_BACKOFF" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
    [ "$_b" -lt "$FAILOVER_RETRY" ] && _b=$FAILOVER_RETRY
    [ "$_b" -gt "$FAILOVER_MAX" ] && _b=$FAILOVER_MAX
    printf '%d' "$_b"
}
fo_backoff_bump() {   # $1 — кап (сек) для ЭТОГО вызова; без него общий FAILOVER_MAX. Кап передаёт
                      # tunnel-ветка (TUNNEL_RETRY_MAX), иначе её лог обещал бы паузу, которой нет.
    _cap=${1:-$FAILOVER_MAX}
    # Бэкофф растёт от ПРОВАЛА ПЕРЕБОРА, а не от аварии провайдера. Посреди объявленной аварии сюда приходит только КОНТРОЛЬНЫЙ
    # свип (прочие ступени гасит гейт аплинка), его ритм — WANOUT_MAX; удвоение лишь съедало бы его окна (клапан открылся, а
    # пауза перебора ещё не вышла) и отодвинуло бы первую НАСТОЯЩУЮ попытку после возврата связи.
    if wan_out_now; then log "идёт авария провайдера — паузу перебора не наращиваю (ритм задаёт контрольный свип)"; return 0; fi
    _b=$(( $(fo_retry) * 2 ))
    [ "$_b" -gt "$_cap" ] && _b=$_cap
    echo "$_b" > "$FAILOVER_BACKOFF"
    log "перебор не помог → следующая попытка не раньше чем через $((_b / 60)) мин"
    return 0
}
fo_backoff_reset() {
    [ -f "$FAILOVER_BACKOFF" ] || return 0
    rm -f "$FAILOVER_BACKOFF" 2>/dev/null
    log "бэкофф перебора сброшен (здоровье вернулось)"
    return 0
}
# Здоровье вернулось: снять бэкофф и закрыть эпизод «интернета нет» (иначе письмо «связь
# вернулась» не ушло бы никогда — inet_reachable зовётся только в аварии). Здесь же — ТИХОЕ закрытие эпизода «прямой режим»
# (vpn_ok_quiet): health_back стоит в ОБЕИХ ветках здоровья, а несущую после аварии нередко везёт уже AmneziaWG — перебор,
# выбор сервера в панели, удачный cross пишут NORMAL мимо «VPS ОЖИЛ», и эпизод, закрываемый лишь в ветке туннелей, лежал до
# ребута: следующее падение уходило без письма (ревью с.97).
health_back() { fo_backoff_reset; wan_out_clear; vpn_ok_quiet; }

# FAILOPEN — это СОСТОЯНИЕ СЕТИ, а не строка в файле: пока в table 1000 висит default в дохлую
# несущую, «прямой режим» — блэкхол, а не fail-open. ГРАБЛЯ (диаг тестера 08.08.2026, VPS мёртв,
# провайдер жив): ФАЗА 0 плагина (`transport.sh failover` чинит несущую НА МЕСТЕ) поднимает
# демонов и ВОЗВРАЩАЕТ `default dev xtun` ещё до того, как выяснится, что сервер не отвечает, —
# а ветка «уже FAILOPEN — без изменений» несущую не трогала. Итог: весь маркированный трафик
# уезжал в никуда, и вместе с ним DNS (set_xray_dns метит 1.1.1.1/8.8.8.8 В туннель) ⇒ dnsmasq
# переставал резолвить ВООБЩЕ ВСЁ при живом WAN. Тем же путём откатывался и ручной
# `transport.sh down`: следующий тик поднимал несущую обратно.
# safety_off здесь не помощник — он снимает `default dev awg0` и про альт-несущую не знает;
# владелец релинквиша = ПЛАГИН (он же вернёт прямой DNS и снимет свои OUTPUT-марки).
# ПОЧЕМУ ЭТО НЕ ДЕРЁТСЯ С РУЧНЫМ ПОДЪЁМОМ: зовём только из состояния FAILED, а КАЖДЫЙ плагин на
# up/down чистит xstate (grep `enodia-watchdog.xstate` — все пять) ⇒ после ручного switch/heal мы
# видим HEALTHY и даём несущей нормально пройти лестницу. Новый плагин обязан делать так же.
ensure_direct_mode() {
    _edev=$(carrier_route_dev)
    [ -n "$_edev" ] || return 0    # table 1000 пуста → прямой режим НАСТОЯЩИЙ, тишина
    log "FAILOPEN, но несущая ($_edev) снова держит default в table 1000 → снимаю (fail-open, не блэкхол)"
    sh "$TRANSPORT_SH" down "$1" >>"$LOG" 2>&1
    echo "FAILOPEN" > "$STATE"
    # ВЕРДИКТ ВОЗВРАЩАЕМ СВОИМ ИМЕНЕМ. `down` у КАЖДОГО плагина делает `rm -f` по xstate (штатно:
    # так ручной switch не дерётся со сторожем — см. коммент выше), но здесь down зовём МЫ, и
    # вместе с ним теряется ровно то состояние, на котором держится троттл лестницы. Без этой
    # строки следующий тик читал пустой файл как HEALTHY ⇒ провал шёл «первой осечкой» → SUSPECT,
    # ещё через тик ветка `xcur != FAILED` заново крутила ВЕСЬ пул и ПОВТОРНО слала письмо
    # «резервы недоступны» (здешний notify() без throttle): пауза вместо 10→20→30 мин выходила
    # ~4 мин. Файл эпизода тем же rm тоже уходит, но он ПОАТТЕМПТНЫЙ (лестница начинается с
    # episode_reset), поэтому его не восстанавливаем — только вердикт.
    echo FAILED > "$XSTATE"
}

# Эскалация awg→другой транспорт (вариант A). Зовётся, когда awg-пул исчерпан и система
# уже в safety_off (прямой = SAFE-пол). Цель выбирает ОРКЕСТРАТОР (transport.sh next awg —
# первый готовый не-awg по реестру, обычно xray/hy2). Возвращает маркировку (safety_off её
# снял), поднимает цель, при нужде перебирает её пул. 0 — встали; 1 — цель тоже мёртва
# (прямой). Анти-петля: не лезет в транспорт, уже пробованный в этом эпизоде.
cross_awg_to_other() {
    [ "$(fo_escalate)" = "cross" ] || return 1
    other=$(cross_target_from_awg)
    [ -n "$other" ] || return 1
    episode_has "$other" && return 1
    # ДО отметки в эпизоде: цель, до которой из-за аварии провайдера дело не дошло, не «пробована».
    ladder_wan_gate "cross на $other"
    episode_add "$other"
    olbl=$(transport_label "$other")
    # «УПАЛ» — только если awg0 в эту загрузку ХОТЬ РАЗ был живым. Иначе падения не было: несущую
    # не смогли ПОДНЯТЬ (битый конфиг, ключи, бинарь), и письмо «AmneziaWG упал» отправляет
    # человека искать аварию там, где её нет, — тот же класс лжи, ради которого заведён AWG0_SEEN
    # (ревью 3, 06.09.2026).
    if [ -f "$AWG0_SEEN" ]; then
        _xw="упал"; _xwe="went down"
        _xwl="Все awg-серверы недоступны."; _xwle="All awg servers are unreachable."
    else
        _xw="не поднялся"; _xwe="failed to come up"
        _xwl="Интерфейс awg0 не удалось создать вовсе (конфиг, ключи или бинари)."
        _xwle="awg0 could not be created at all (config, keys or binaries)."
    fi
    log "awg-пул исчерпан → cross: пробую $other"
    _xsc=0; tsw "$other" || _xsc=1   # оркестратор: релинквиш awg + mark-core + подъём $other
    # ПЕРЕХОД — ПО ФАКТУ (код `switch` И флаг), как у cross туннеля: неудачный подъём цели `switch` откатывает флаг на awg и
    # поднимает awg0 обратно — с `default` в table 1000 к мёртвому VPS, — а `health <цель>` у НЕАКТИВНОГО транспорта отвечает 0.
    # Судом по одной пробе тик писал NORMAL/HEALTHY, слал письмо «перешли на $olbl» и оставлял блэкхол до следующей осечки awg.
    _xaw=1; _xafl=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
    [ "$_xafl" = "$other" ] || _xaw=0
    [ "$_xsc" = 0 ] || _xaw=0
    if [ "$_xaw" = 1 ] && { HEV_CHECK=1 sh "$TRANSPORT_SH" health "$other" >>"$LOG" 2>&1 || sh "$TRANSPORT_SH" failover "$other" >>"$LOG" 2>&1; }; then
        off_bail "перебора резервов $other"
        echo NORMAL > "$STATE"; echo HEALTHY > "$XSTATE"
        ip=$(ext_ip)
        # «be7000 меню -> Протокол» тут стояло с тех пор, когда протокол переключал ПК-скрипт.
        # Он этого давно не умеет (весь выбор — в панели), и письмо отправляло человека в
        # несуществующий пункт меню ровно в тот момент, когда он растерян. Адрес один: :8088.
        if [ "$NF_LANG" = en ]; then
            notify_ev "cross-switch" 0 "BE7000: AmneziaWG $_xwe -> switched to $olbl" \
"$_xwle The router switched over to $olbl automatically.
External IP: ${ip:-unknown}.
To go back to AmneziaWG: panel :8088 -> the VPN card."
        else
            notify_ev "cross-switch" 0 "BE7000: AmneziaWG $_xw -> перешли на $olbl" \
"$_xwl Роутер автоматически переключился на $olbl.
Внешний IP: ${ip:-неизвестен}.
Вернуться на AmneziaWG: панель :8088 -> карточка VPN."
        fi
        return 0
    fi
    off_bail "перебора резервов $other"
    # Снимаем ТО, что несёт по флагу: цель (встала, но не везёт; или подъём не удался, а откатываться не на что) — её `down`;
    # откат на awg — его маршрут снимает safety-off ниже, а `down` неактивной цели полез бы в чужую несущую.
    [ "$_xafl" != awg ] && sh "$TRANSPORT_SH" down "$other" >>"$LOG" 2>&1
    [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
    echo FAILOPEN > "$STATE"; echo FAILED > "$XSTATE"
    if [ "$_xaw" = 1 ]; then log "cross: $other тоже недоступен → прямой режим"
    else log "cross: $other не поднялся (флаг: ${_xafl:-—}) → прямой режим"; fi
    return 1
}

# Сколько резервных конфигов в configs/ (кроме активного). busybox-safe.
count_backups() {
    a=$(cat "$ACTIVE_NAME" 2>/dev/null)
    c=0
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$(basename "$f" .conf)" = "$a" ] && continue
        c=$((c+1))
    done
    printf '%d' "$c"
}

# Возраст (сек) с момента записи stamp-файла; нет файла → большое число.
# Возраст отметки-троттла. Штампы лежат в /tmp ⇒ рождаются ПОСЛЕ загрузки: «старше аптайма» —
# это скачок часов, а не давность, и age_since вернёт 0 (троттл НЕ истёк). Иначе один шаг часов
# разом открывал все окна: лестница failover, бэкофф, возврат домой — всё в одном тике.
stamp_age() {
    if [ -f "$1" ]; then
        t=$(cat "$1" 2>/dev/null); case "$t" in ''|*[!0-9]*) t=0 ;; esac
        age_since "$t"
    else
        echo 999999
    fi
}

# Запустить перебор резервов через switch-vpn.sh и выставить STATE по коду:
# 0 — встали на резерв (NORMAL); 1 — прямой режим (FAILOPEN). Письма шлёт switch-vpn.
run_failover() {
    date +%s > "$FAILOVER_STAMP"
    if sh "$SWITCH_VPN" failover >>"$LOG" 2>&1; then
        off_bail "перебора серверов AmneziaWG"
        echo "NORMAL" > "$STATE"
        log "failover: встали на резерв ($(cat "$ACTIVE_NAME" 2>/dev/null))"
        return 0
    else
        off_bail "перебора серверов AmneziaWG"
        echo "FAILOPEN" > "$STATE"
        log "failover: резервы недоступны → прямой режим"
        return 1
    fi
}

# Бинарь для чтения handshake. ПОРЯДОК: сперва НАШ awg, потом системный wg — инвариант проекта
# «handshake читает awg, НЕ wg» (`wg_bin()` в transport-awg.sh). На стоке wg нет, но там, где он
# есть (дев-роутер/чужая сборка), обычный wg не понимает A-параметры AmneziaWG.
WG=""
[ -x "$ENODIA_BIN/awg" ] && WG="$ENODIA_BIN/awg"
[ -z "$WG" ] && command -v wg >/dev/null 2>&1 && WG=wg

# Тест-хук/ручной вызов: только проход health доп-выходов (для железо-проверки Ф2 без ожидания
# 180с+тика; cron зовёт watchdog БЕЗ аргумента и идёт полным циклом ниже).
[ "$1" = slot-sweep ] && { slot_health_sweep; exit 0; }

# ИДЁТ ЛИ ПРЯМО СЕЙЧАС ЧУЖОЕ ПЕРЕКЛЮЧЕНИЕ — вопрос ОДИН на два места, и второе его не задавало.
# Гейт `SWITCH_LOCK` стоит у тика ПЕРВЫМ (ниже по файлу): выше boot-grace, выше WAN-гейта, выше
# любых веток возврата — пока лок жив, тик не делает НИЧЕГО. А вердикт обещал окно попытки, и
# панель писала «попытка на ближайшей проверке» посреди установки компонента (packages.sh держит
# лок на всю закачку с GitHub) или ручной смены сервера (switch-vpn.sh — на весь свип пула).
# Тот же класс, что закрывали круги 3, 8, 9 и 11: гейт, который тик проходит ПЕРЕД действием, у
# вердикта не спрошен (ревью подшага 2, круг 14).
# О ПРОТУХАНИИ СУДИМ ТЕМ ЖЕ СПОСОБОМ, ЧТО И ГЕЙТ, иначе разъедутся: возраст по MTIME файла, а не
# по содержимому (лок заводят через `: > файл`, внутри пусто — `stamp_age` прочитала бы там ноль,
# то есть «протух» СРАЗУ); нет `date -r` в сборке — НЕ ГАДАЕМ и считаем лок живым. Возраст
# считается ОДИН раз и здесь же: строке журнала у гейта хватает порога, число ей не нужно.
SWITCH_STALE=${SWITCH_STALE:-1800}      # дольше этого не длится ни одна наша операция (то же число, что у LOCK_STALE)
# ДЕРЖАТЕЛЬ С ПИДОМ ВНУТРИ (сторож — wd_switch_take, панель — hold_switch, с 02.10.2026) судится ещё и по ЖИЗНИ: CGI, у которого
# закрыли вкладку, uhttpd бьёт SIGKILL, ловушка молчит — и лок мёртвого держателя выключал сторожа на SWITCH_STALE (30 мин) без
# единой починки. Мёртв ⇒ не держит; жив — дальше прежний потолок по возрасту (зависший живой держатель тоже не вечен).
# …НО СМЕНУ CGI ВЕДЁТ ЕГО ПОТОМОК, и SIGKILL от uhttpd его не трогает (ревью с.96, круг 2): пид мёртв, а оркестратор или switch-vpn
# ещё работают — лок держит ИХ смену, и снять его значило бы вести лестницу поверх неё.
switch_lock_held() {
    [ -e "$SWITCH_LOCK" ] || return 1
    _slp=$(cat "$SWITCH_LOCK" 2>/dev/null | tr -cd '0-9')
    case "$_slp" in ''|*[!0-9]*) ;; *) [ -d "/proc/$_slp" ] || switch_work_alive "$_slp" || return 1 ;; esac
    _slm=$(date -r "$SWITCH_LOCK" +%s 2>/dev/null)
    case "$_slm" in ''|*[!0-9]*) return 0 ;; esac
    [ "$(age_since "$_slm")" -lt "$SWITCH_STALE" ]
}

# …И ВТОРОЙ ГЕЙТ ТИКА — СОБСТВЕННЫЙ ЛОК СТОРОЖА, он стоит СТРОКОЙ НИЖЕ первого (круг 15). Прошлый
# прогон, унесённый `kill -9`/OOM, оставляет лок, и тик выходит по нему до `LOCK_STALE` — полчаса
# без единой проверки: ни возврата, ни failover, ни rule-heal. Вердикт же обещал «попытку на
# ближайшей проверке» — то же враньё, что закрыл круг 14 строкой выше.
# ВОПРОС ОДИН — «ДЕРЖАТЕЛЬ ЖИВ ИЛИ ЕГО УНЕСЛО», и отвечает на него ПИД, а не возраст. Перебор
# туннельных резервов идёт БЕЗ switching-лока (его берёт только `transport.sh switch`, а `failover`
# уходит прямо в плагин) и на десятке конфигов подписки занимает минуты — по возрасту живой прогон
# неотличим от убитого (круг 16). Спрашиваем /proc, как проект спрашивает про heal; разбор cmdline
# здесь не нужен — у `heal_running` ложное «жив» выключало починку до ребута, а тут оно лишь
# промолчит, и это безопасная сторона.
# ВОЗРАСТ ОСТАЛСЯ РОВНО ДВУМ ВОПРОСАМ, и оба не про «идёт ли тик»:
#   · старше `LOCK_STALE` — не помеха ВООБЩЕ: такой лок тик перехватывает сам и работает дальше;
#   · пид НЕИЗВЕСТЕН (лок от прежней копии сторожа либо микросекундная щель между записью лока и
#     записью пида) — тогда судим по возрасту: пережил период проверок (`TICK_STUCK`, те же два
#     пропущенных тика, что у `wan_out_now`) ⇒ это уже не щель, а мёртвый держатель. Прежнее
#     «неизвестность ⇒ молчим» не самоисцелялось: запись пида стоит НИЖЕ гейта лока, и пока лок
#     жив, ни один тик до неё не доходит — молчание держалось столько же, сколько беда (круг 17).
# НИЖНЕГО ПОРОГА У ИЗВЕСТНОГО ПИДА НЕТ: он достался от круга 15, когда «идёт ли тик сейчас» отвечал
# ТОЛЬКО возраст, и после круга 16 просто слепил вердикт на первые пять минут после смерти прогона.
LOCK_STALE=${LOCK_STALE:-1800}
TICK_STUCK=${TICK_STUCK:-300}
tick_lock_stuck() {
    [ -e "$LOCK" ] || return 1
    _tla=$(stamp_age "$LOCK")
    [ "$_tla" -lt "$LOCK_STALE" ] || return 1
    _trp=$(cat "$WD_PID" 2>/dev/null | tr -d ' \r\n')
    case "$_trp" in
        ''|*[!0-9]*) [ "$_tla" -ge "$TICK_STUCK" ] ;;
        *) [ ! -d "/proc/$_trp" ] ;;
    esac
}

# ВЕРДИКТ «ГДЕ МЫ СТОИМ» — верб `standing` (его читает шапка панели через cgi-bin/status и дамп).
# ЗАЧЕМ. «На резерве ли роутер и вернётся ли домой» не считал НИКТО: экран «Резервирование» сравнивал
# сам транспорт с домашним и врал в трёх случаях — резерв по СЕРВЕРУ awg называл «дома» (сервер не
# сравнивался), прямой режим — тоже «дома» (туннельная ветка оставляет `.transport` прежним), а
# возврат обещал и для пары туннель→туннель, у которой ветки возврата нет. Правила возврата живут в
# ЭТОМ файле, значит и ответ отсюда — через те же предикаты, что у веток тика.
# БЕЗ СЕТИ И БЕЗ ЛОКА СТОРОЖА: зовут на каждом опросе шапки, и выходим ДО всего, что тик меняет. Кроме
# файлов — только лёгкие вопросы владельцам (`transport.sh configured/list/ready/installed/next`, `ip link`);
# `list` без кэша может разово пробовать NFQUEUE под xtables-локом — status зовёт его и сам, раньше нас.
# Ответ — строки `ключ=значение`, новое поле старого читателя не ломает:
#   standing  none | off | boot | direct | reserve | home | unset
#             (у ТУННЕЛЯ дом и резерв — только по транспорту: домашнего сервера у xray/hy2 нет, и xray на
#             резервном сервере здесь `home` — ограничение модели, выдумывать «дома по серверу» нельзя)
#   back      transport | server | none — есть ли у тика ветка возврата из этого положения
#   back_to   куда вернётся (транспорт или имя сервера awg); пусто при back=none
#   back_in   секунд до окна попытки (-1 — не будет): тик раз в 2 мин и сперва проверяет, жив ли
#             дом, так что это «не раньше», а не обещание
#   mode      off | sticky | home
#   back_why  ЧТО МЕШАЕТ ВОЗВРАТУ. При back=none — почему его не будет вовсе (значения ниже). При
#             back=transport|server — что мешает ПОПЫТКЕ прямо сейчас, В ПОРЯДКЕ ГЕЙТОВ ТИКА:
#             switching (идёт чужое переключение — тик выходит на этом ПЕРВЫМ) · stuck (прошлый тик
#             УНЕСЛО, и его лок держит проверки: судим по живости держателя через /proc, иначе
#             длинный перебор резервов был бы неотличим от смерти) ·
#             дальше СТОРОНЫ РАЗНЫЕ. У awg помеха одна: unhealthy (рукопожатие в зоне гистерезиса).
#             У ТУННЕЛЯ вся лестница лежит ЗА ПРОВАЛОМ ПРОБЫ (свидетели — `.xstate=SUSPECT` либо нет
#             отметки «везла»; проба прошла ⇒ тик уходит домой этим же тиком и помех нет), а внутри —
#             порядок тика: wan (интернета нет вообще) · raising (несущая в эту загрузку ещё не прошла
#             проверку, её поднимают — тик либо бегущий heal) · unwired (проводки нет: правило маркировки
#             снято — тик молча не делает ничего) · unhealthy (несущая не везёт, тик крутит лестницу
#             резервов). Пусто — помех нет.
#             Значения «почему не будет вовсе» (только при back=none):
#             mode (режим не возвращает) · pair (туннель→туннель) · not_ready (дом-туннель не готов) ·
#             blind (сторож не видит awg0: нет интерфейса или бинаря awg) · gone (конфига домашнего
#             сервера нет) · no_orc (не доехал оркестратор transport.sh) · no_switch (нет switch-vpn.sh).
#             РАЗНЫЕ ФАЙЛЫ — РАЗНЫЕ ЗНАЧЕНИЯ: одно на оба заставляло панель называть не тот файл
#             (ревью, круг 6). Пишут САМИ предикаты (`_htb_why`/`_asa_why`),
#             вердикт лишь выбирает: причина уровня ТРАНСПОРТА важнее серверной — при обеих называем её.
#             Экран «Резервирование» говорит ТОЛЬКО по этому полю; новое значение = строка в белом списке
#             cgi-bin/status и текст в панели (стенд сверяет, что верб не печатает неизвестного им)
#             В ПРЯМОМ РЕЖИМЕ (standing=direct) поле отвечает на свой вопрос — «выйдет ли роутер из него САМ»:
#             пусто — выйдет (awg0 подхватит сторож, туннель — лестница по троттлу, при «Выкл» — фолбэк на установленный awg, а не
#             везшую в эту загрузку несущую тик поднимает первым подъёмом в любом режиме),
#             `mode` — НЕ выйдет: туннель при режиме «Выкл» и без AmneziaWG (конфига или программы) ветка тика снимает и больше не поднимает
#             (терминальная ветка «режим off, awg не установлен»; письмо того же тика зовёт в панель). Без поля
#             экран обещал «сторож вернёт VPN сам» там, где тик не вернёт никогда (ревью пачки 5, круг 2)
#   home_why  ПОЧЕМУ НЕ ВЕРНЁТСЯ ДОМАШНИЙ ПРОТОКОЛ, когда обещан возврат СЕРВЕРА (иначе пусто):
#             значения те же, что у back_why при back=none. Отдельное поле, потому что при обещанном
#             возврате `back_why` отвечает на ДРУГОЙ вопрос — что мешает попытке прямо сейчас
#   back_on_fail  КУДА УВЕДЁТ ПАДЕНИЕ активного транспорта, если это ДОМ (иначе пусто) — второй факт,
#             а не причина: планового возврата может не быть, а роутер всё равно окажется дома, когда
#             текущий транспорт перестанет везти. Считается только при standing=reserve и back=none
#   back_on_fail_at  КОГДА это случится: now (сразу по падению — ветка режима «Выкл») либо pool (после
#             того, как кончатся резервные серверы текущего протокола: перебор идёт ДО эскалации).
#             Без него панель обещала бы переход домой при первом же падении (ревью 7)
# ПОРЯДОК: не настроено и выключено тик гасит раньше всего; прямой режим бьёт резерв (трафик мимо
# любого VPN, где бы ни был дом); `boot` — прямой режим, поставленный НАМИ в ожидании первого подъёма
# awg0, пока сторож ещё будит heal, — это не авария. `unset` — дом-транспорт не задан: его пишет только ручной выбор в панели, а
# авто-cross — нет, и после cross на туннель «дома» было бы той самой ложью, ради которой верб заведён.
fo_standing() {
    _fs_m=$(fo_mode); _fs_s=home; _fs_b=none; _fs_to=""; _fs_in=-1; _fs_why=""; _fs_of=""; _fs_ofa=""; _fs_hw=""
    _fs_t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n'); [ -n "$_fs_t" ] || _fs_t=awg
    _fs_h=$(transport_home)
    _fs_st=$(cat "$STATE" 2>/dev/null)
    _fs_tc=0; [ -f "$TRANSPORT_SH" ] && { sh "$TRANSPORT_SH" configured >/dev/null 2>&1; _fs_tc=$?; }
    if [ "$_fs_tc" = 1 ]; then
        _fs_s=none
    elif [ -f "$ENODIA_STATE/.vpn-off" ]; then
        _fs_s=off
    elif [ "$_fs_st" = FAILOPEN ]; then
        _fs_s=direct
        # `boot` — только у awg и только пока тик НЕ объявил потолок пробуждений heal. Отметка первого
        # подъёма живёт, пока тик не выведет роутер из прямого режима (awg0 может уже появиться, а handshake
        # — быть в гистерезисе или интернет лежать): и после потолка (ушло письмо «сторож перестал пересоздавать»),
        # и после неудачного cross на туннель — по ней одной авария звалась бы «не аварией» до ребута.
        # Граница — метка тика `HEAL_KICK_SAID`, а не счётчик: счётчик доходит до потолка на ПОСЛЕДНЕМ
        # пробуждении, пока heal ещё бежит, а исчерпание тик объявляет лишь следующим тиком (оба случая
        # — независимое ревью). И ТЕ ЖЕ ГЕЙТЫ, что тик проверяет перед пробуждением heal (`have_awg`,
        # `carrier_installed awg`): без конфига или компонента он молча выходит, heal не будит, метки
        # потолка не будет никогда — и `boot` висел бы до ребута (круг 4). Форки — только в этом положении.
        # …И ПЕРВЫЙ ИЗ ЭТИХ ГЕЙТОВ — `wan_up`: тик проверяет аплинк ДО всего остального и при лежащем
        # WAN выходит МОЛЧА — heal не будит, метку потолка не ставит. Без этого вопроса `boot` висел бы
        # до ребута у всякого, у кого пропал провайдер, и панель говорила бы «загружаюсь» вместо «прямой
        # режим» (ревью подшага 2, круг 3; ровно тот же класс, что нашли круги 2 и 4 подшага 1).
        [ "$_fs_t" = awg ] && [ -f "$AWG0_FIRSTUP" ] && [ ! -f "$HEAL_KICK_SAID" ] && wan_up && ! wan_out_now && have_awg && carrier_installed awg && _fs_s=boot
    elif [ "$_fs_t" != awg ] && [ "$(cat "$XSTATE" 2>/dev/null)" = FAILED ]; then
        # Прямой режим туннеля бывает и без строки STATE: ветка «режим off» (AmneziaWG не установлен
        # или не поднялся) снимает несущую и пишет только вердикт FAILED.
        _fs_s=direct
    else
        # Дом — ДВА уровня, и спрашиваем оба, как тик: транспорт и (у awg) сервер. «НЕ на домашнем
        # сервере» — это ПОЛОЖЕНИЕ, а «есть куда вернуться» — ВОЗМОЖНОСТЬ, у которой ещё и файл конфига
        # дома: под одним предикатом удалённый домашний сервер превращал резерв в «дома» (ревью). Дом
        # выбран явно — сравниваем с ним; не выбран — судим как тик (`default`, если такой конфиг есть).
        _fs_away=0
        if [ "$_fs_t" = awg ] && fo_awg_server_off_home; then _fs_away=1; fi
        if [ -n "$_fs_h" ] && [ "$_fs_h" != "$_fs_t" ]; then
            _fs_s=reserve
            if fo_home_transport_back "$_fs_t"; then _fs_b=transport; _fs_to=$_fs_h; else _fs_why=$_htb_why; fi
        elif [ "$_fs_away" = 1 ]; then
            _fs_s=reserve
        elif [ -z "$_fs_h" ]; then
            _fs_s=unset
        fi
        # Возврат СЕРВЕРА awg — «сверх», а не «иначе»: у тика это `elif` ПОСЛЕ ветки транспорта, и когда
        # та не сработала (дом-транспорт не готов), тик идёт на домашний сервер — даже при чужом доме-
        # транспорте (найдено независимым ревью: вердикт говорил «не вернёмся», а тик возвращал).
        # …и только если тик вообще входит в awg-ветку (`awg_watchable` — его же вход, см. выше).
        # Гейты — цепочкой, чтобы назвать ПЕРВЫЙ несработавший, И В ПОРЯДКЕ ТИКА: у него это вход в
        # awg-ветку (`awg_watchable || finish`), затем режим, затем «стоим не на доме и есть куда».
        # Порядок «режим раньше awg_watchable» называл бы причиной режим там, где тик не доходит до
        # веток возврата вовсе, — и человек чинил бы не то (ревью подшага 2, круг 2). Причина уровня
        # транспорта (уже в `_fs_why`) важнее серверной.
        if [ "$_fs_b" = none ] && [ "$_fs_away" = 1 ]; then
            _fs_w2=""
            if ! awg_watchable; then _fs_w2=blind
            elif [ "$_fs_m" != home ]; then _fs_w2=mode
            elif ! fo_awg_server_away; then _fs_w2=$_asa_why
            # ПОЛОВИНА ОТВЕТА — ТОЖЕ НЕПРАВДА. Сервер вернётся, а домашний ПРОТОКОЛ — нет, и
            # причина этого уже посчитана выше (`_fs_why` уровня транспорта). Выбрасывая её, экран
            # говорил «сторож вернёт домашний…», а рядом показывал домом протокол, которого не
            # вернёт никогда. Уносим причину в СВОЁ поле: `back_why` при обещанном возврате занят
            # другим вопросом — «что мешает ПОПЫТКЕ» (круг 17).
            else _fs_b=server; _fs_to=$(failover_home_name); _fs_hw=$_fs_why; _fs_why=""
            fi
            [ -n "$_fs_why" ] || _fs_why=$_fs_w2
        fi
    fi
    # ЧТО МЕШАЕТ ПОПЫТКЕ ПРЯМО СЕЙЧАС (при обещанном возврате). Сеть не трогаем: `wan_up` — локальные
    # признаки, свидетелей пробы (`.xstate`, отметку «везла») пишет сам тик, порог рукопожатия — общий
    # предикат с тиком. Отставание — не дольше одного тика (так его и сверяет стенд паритета: два
    # объявленных отставания подряд — провал), а молчание тут стоило бы человеку похода чинить
    # домашний VPS при лежащем провайдере (ревью 9).
    # ГРЕЙС ЗАГРУЗКИ — ОДИН ВОПРОС НА ДВА МЕСТА: им отодвигается окно попытки (ниже) и им же выключается
    # второй свидетель проваленной пробы (в цепочке). Тот же `up_secs` и та же отмена `boot_grace_waived`,
    # что у тика; спрашиваем только при обещанном возврате — отмена форкает оркестратор.
    _fs_grace=0
    if [ "$_fs_b" != none ]; then
        _fs_up=$(up_secs)
        if [ "$_fs_up" -lt "$BOOT_GRACE" ] && ! boot_grace_waived; then _fs_grace=1; fi
    fi
    if [ "$_fs_b" != none ]; then
        # ПОМЕХИ РАЗНЫЕ У РАЗНЫХ СТОРОН, и это не симметрия ради симметрии: у awg-ветки тика гейтов
        # «несущую ещё не поднимали» нет вовсе (отметку `carrier_seen` пишет ТОЛЬКО туннельная ветка),
        # а `wan_up` в путь возврата не входит — при свежем рукопожатии тик идёт пробовать даже с
        # лежащим аплинком. Заимствование туннельных гейтов на сторону awg давало ложную помеху в
        # мире «awg0 жив, маршрут снесён», где тик как раз чинит маршрут и возвращает дом (ревью 12).
        # ПЕРВОЙ — та помеха, на которой тик стоит ПЕРВЫМ, и она общая для обеих сторон: чужое
        # переключение (лок switch-vpn/packages/панели). Тик выходит на ней в самом начале файла,
        # до всего остального, поэтому и у вердикта она возглавляет цепочку (круг 14).
        if switch_lock_held; then _fs_why=switching
        elif tick_lock_stuck; then _fs_why=stuck
        elif [ "$_fs_t" = awg ]; then
            # Единственный гейт awg-пути: свежесть рукопожатия (ветки возврата живут за ней).
            awg_hs_alive "$(awg_hs_age)" || _fs_why=unhealthy
        elif [ "$(cat "$XSTATE" 2>/dev/null)" = SUSPECT ] || { [ "$_fs_grace" = 0 ] && ! carrier_seen "$_fs_t"; }; then
            # ВСЯ ЛЕСТНИЦА ТУННЕЛЯ ЛЕЖИТ ЗА ПРОВАЛОМ ПРОБЫ, и это не деталь, а порядок тика: `health`
            # прошёл ⇒ он тут же идёт веткой возврата и уходит домой ЭТИМ ЖЕ тиком, не заглядывая ни
            # в маршрут, ни в правило, ни в аплинк. У несущей, которая УЖЕ ВЕЗЛА, пустая table 1000
            # (болезнь carrier_route_lost, замерена на AX3600) и мёртвый аплинк при здоровой пробе
            # помехой не бывают (круг 15).
            # Пробу вердикт не делает (он без сети) ⇒ спрашивает СВИДЕТЕЛЕЙ, которых пишет сам тик, и
            # их ДВА:
            #   · `.xstate=SUSPECT` — несущая уже везла и дала осечку;
            #   · НЕТ отметки «везла» (`carrier_seen`) — проба в эту загрузку не проходила НИ РАЗУ.
            #     Одного `.xstate` мало: у такой несущей тик обходит гистерезис и SUSPECT не пишет, а
            #     `up` любого плагина `.xstate` стирает. На нём одном вердикт обещал «попытку на
            #     ближайшей проверке», пока тик молча выходил без правила маркировки ДО РЕБУТА или
            #     трижды подряд поднимал несущую zapret (ревью стенда паритета, 15.09.2026).
            #     Цена второго свидетеля — ложь не дольше тика там, где несущая уже поднята и здорова,
            #     а первой пробы ещё не было: отметку ставит первый же тик, ПРОШЕДШИЙ ГРЕЙС ЗАГРУЗКИ.
            #     ПОЭТОМУ В ГРЕЙСЕ ЭТОТ СВИДЕТЕЛЬ НЕ СПРАШИВАЕМ: /tmp после ребута пуст, отметки нет ни у
            #     кого, а тики грейса выходят ДО пробы. Спрошенный, он весь грейс называл «несущую
            #     поднимают» и прятал окно, хотя первый же тик после грейса уходил домой (ревью 2 стенда
            #     паритета). Окно в грейсе и так отодвинуто (`back_in`), а SUSPECT после ребута не бывает.
            # FAILED сюда не доходит — у туннеля это прямой режим выше по цепочке.
            # ВНУТРИ — порядок гейтов тика после осечки: интернета нет вообще (`inet_reachable`) →
            # несущая ещё не везла (ветка «не поднимали ни разу») → прочее (перебор серверов).
            # ВОПРОС ТОТ ЖЕ, ЧТО У ТИКА, И ЗАДАН ДВАЖДЫ. `wan_up` — жёсткие локальные признаки (нет
            # дефолта, carrier=0), и аварию «линк жив, а транзита нет» он пропускает СОЗНАТЕЛЬНО,
            # чтобы не подавлять законный failover. Тик же в этом месте стоит на `inet_reachable` и
            # выходит со словами «не перебираю, жду аплинка»: ни перебора, ни подъёма несущей не
            # будет. Ответ «идёт ли авария СЕЙЧАС» в стороже уже есть — `wan_out_now` по отметке,
            # которую пишет каждый подтверждающий тик; ею же судит `boot` выше (круги 13 и 16).
            if ! wan_up || wan_out_now; then _fs_why=wan
            elif ! carrier_seen "$_fs_t"; then
                # НЕСУЩАЯ В ЭТУ ЗАГРУЗКУ ЕЩЁ НЕ ВЕЗЛА — у тика дальше ветка «не поднимали ни разу», и её
                # гейты спрашиваем В ЕЁ ПОРЯДКЕ. Не через `carrier_absent_unraised`: тот отвечает на
                # ДРУГОЙ вопрос (снимать ли гистерезис и грейс) и требует пустого маршрута, а ветка тика
                # маршрут не спрашивает вовсе. Через него вердикт говорил «не везёт», пока тик поднимал
                # несущую поверх оставшегося маршрута, молча выходил без правила или ждал бегущий heal
                # (нашёл перебором миров стенд паритета dev/standing-parity-test.sh).
                # heal поднимает её прямо сейчас ⇒ подъём идёт, просто не руками тика.
                if heal_running; then _fs_why=raising
                # …правила `fwmark→1000` нет ⇒ проводки нет (VPN выключили мимо панели ЛИБО её в эту
                # загрузку так и не положили), и тик выходит МОЛЧА, не поднимая ничего. У тика этот гейт
                # стоит ДО счётчика попыток. Вторую половину его условия (`STATE=FAILOPEN` — «прямой
                # режим НАШ») не спрашиваем: с ней вердикт до цепочки не доходит — FAILOPEN выше
                # становится положением `direct`, где веток возврата нет вовсе.
                elif ! carrier_rule_present; then _fs_why=unwired
                elif [ "$(carrier_tries "$_fs_t")" -lt "$CARRIER_UP_TRIES" ]; then _fs_why=raising
                # …попытки исчерпаны ⇒ тик отдаёт вопрос обычной лестнице.
                else _fs_why=unhealthy
                fi
            else _fs_why=unhealthy
            fi
        fi
    fi
    # Выйдет ли туннель из прямого режима САМ — те же гейты, что у тика: при режиме «Выкл» лестницу он не крутит
    # (`[ "$mode" != off ]` у ветки повтора), а фолбэк на awg есть, только пока AmneziaWG есть — конфиг И программа (`awg_fallback_ok`).
    # …И ВЕТКА ПЕРВОГО ПОДЪЁМА стоит в тике РАНЬШЕ развилки по режиму: несущую, которая в эту загрузку ещё не везла
    # (`carrier_seen`), тик поднимает сам в ЛЮБОМ режиме, пока не исчерпал попыток (`carrier_tries`) — так прямой режим
    # «компонента нет» кончается сам, когда компонент поставили (подтверждающий круг ревью пачки 5).
    # Ничего из этого ⇒ терминальная ветка: несущая снята и сама не поднимется — так и говорим (`mode`).
    if [ "$_fs_s" = direct ] && [ "$_fs_t" != awg ] && [ "$_fs_m" = off ] && ! awg_fallback_ok \
       && { carrier_seen "$_fs_t" || [ "$(carrier_tries "$_fs_t")" -ge "$CARRIER_UP_TRIES" ]; }; then
        _fs_why=mode
    fi
    # …И ПРОГРАММЫ АКТИВНОГО ТУННЕЛЯ НЕТ ВОВСЕ. У тика этот гейт стоит СРАЗУ за проваленной пробой — раньше ветки первого подъёма,
    # развилки по режиму и фолбэка (`carrier_installed "$TRANSPORT"` → FAILED и выход), поэтому он и перебивает `mode`: из прямого
    # режима тик сам не выйдет, пока компонент не поставят, а «вернёт сам» было обещанием, которого никто не выполнит (хвост (2)
    # ревью dev233). Поставили — тик выходит сам веткой первого подъёма, и вердикт это видит тем же вопросом.
    # У AmneziaWG тот же тупик — своя ветка тика: `awg.conf` есть, программы нет ⇒ FAILOPEN и выход на КАЖДОМ тике, heal не будят
    # (ревью ветки, круг 1: вердикт отдавал пустую причину, и панель обещала «вернёт сам»). Без `awg.conf` это «не настроен» — не наш вопрос.
    if [ "$_fs_s" = direct ] && ! carrier_installed "$_fs_t" \
       && { [ "$_fs_t" != awg ] || [ -f "$ENODIA_STATE/awg.conf" ]; }; then
        _fs_why=noprog
    fi
    # «Планового возврата нет» — ещё не «домой не попадём»: падение активного транспорта может увести
    # РОВНО ДОМОЙ, и об этом надо сказать рядом с причиной, в любом режиме (ревью, круг 5).
    # `back=transport` исключён СОЗНАТЕЛЬНО: там домашний протокол вернётся и сам, говорить про
    # падение незачем. А вот при обещанном возврате СЕРВЕРА протокол не вернётся — факт нужен (круг 17).
    if [ "$_fs_s" = reserve ] && [ "$_fs_b" != transport ]; then
        _fs_ofr=$(fo_back_on_fail "$_fs_t")
        [ -n "$_fs_ofr" ] && { _fs_of=${_fs_ofr%% *}; _fs_ofa=${_fs_ofr##* }; }
    fi
    if [ "$_fs_b" != none ]; then
        _fs_in=$(( FAILBACK_INTERVAL - $(stamp_age "$FAILBACK_STAMP") )); [ "$_fs_in" -lt 0 ] && _fs_in=0
        # BOOT-GRACE: первые BOOT_GRACE секунд аптайма тик выходит ДО всего (первичный подъём несущей —
        # забота heal), значит «попытка на ближайшей проверке» в это время обещает раньше срока. Окно
        # меряем тем же up_secs, что и сам грейс, и спрашиваем ТУ ЖЕ отмену (`boot_grace_waived`):
        # с ней тик по грейсу не выходит, и отодвигать окно значило бы обещать ПОЗЖЕ срока (ревью 4–5).
        if [ "$_fs_grace" = 1 ]; then
            _fs_g=$(( BOOT_GRACE - _fs_up )); [ "$_fs_g" -gt "$_fs_in" ] && _fs_in=$_fs_g
        fi
    fi
    printf 'standing=%s\nback=%s\nback_to=%s\nback_in=%s\nmode=%s\nback_why=%s\nhome_why=%s\nback_on_fail=%s\nback_on_fail_at=%s\n' "$_fs_s" "$_fs_b" "$_fs_to" "$_fs_in" "$_fs_m" "$_fs_why" "$_fs_hw" "$_fs_of" "$_fs_ofa"
}
# ЧИТАТЕЛИ НАХОДЯТ ВЕРБ ПО ЭТОЙ СТРОКЕ (cgi-bin/status, dump.sh): старая копия файла аргументов не
# разбирает и на `standing` прогнала бы ПОЛНЫЙ ТИК. Меняешь строку — меняй их гард (сверяет стенд).
[ "$1" = standing ] && { fo_standing; exit 0; }

# Не лезем во время ручного переключения страны (switch-vpn.sh держит лок). ВОПРОС «лок жив или
# протух» задаёт общий предикат `switch_lock_held` (объявлен выше, вместе с SWITCH_STALE): его же
# спрашивает вердикт, потому что этот гейт у тика ПЕРВЫЙ — молчать о нём значило бы обещать
# попытку, которой не будет. Две копии суждения о протухании разъехались бы молча.
# …И У ЭТОГО ЛОКА РОВНО ТА ЖЕ БОЛЕЗНЬ, что описана ниже у нашего собственного: держателей
# несколько (панель, switch-vpn, packages/proto-install, а с 03.09.2026 и apply-scripts), любого
# из них может унести `kill -9` или OOM — и тогда пустой файл выключает сторожа НАВСЕГДА, до
# ребута. Это худший отказ живучести: подсистема, которая замечает чужие отказы, молча отказывает
# сама.
# Снимает владелец (daemon-lib.sh::switch_lock_reap) — по УВИДЕННОМУ: вкладка, забравшая тот же мёртвый лок между нашей сверкой и
# снятием, свой не потеряет; и тогда тик не ведём — смена уже идёт (хвост ревью с.96).
if [ -e "$SWITCH_LOCK" ]; then
    _slraw=$(cat "$SWITCH_LOCK" 2>/dev/null | tr -d ' \r\n'); _slm=""
    switch_lock_held && exit 0
    log "switching-лок протух (держатель мёртв или лок старше ${SWITCH_STALE}с) — снимаю"
    switch_lock_reap "$_slraw" "$_slm" || exit 0
    [ -e "$SWITCH_LOCK" ] && switch_lock_held && exit 0
fi

# Один экземпляр за раз. Лок с ОТМЕТКОЙ ВРЕМЕНИ, а не пустой: тик сторожа делает сетевые пробы и
# зовёт плагины (curl, awg setconf, перебор пула) — зависший или убитый -9 экземпляр оставлял бы
# файл НАВСЕГДА, и сторож молча умирал до ребута. Это худший из отказов «живучести»: подсистема,
# которая должна замечать чужие отказы, отказывает сама и никому об этом не говорит. Протухший
# (старше LOCK_STALE) лок перехватываем и пишем об этом в журнал. САМО ЧИСЛО объявлено ВЫШЕ, рядом
# с предикатом `tick_lock_stuck`: его спрашивает и вердикт, а тот считается раньше этой строки.
if [ -e "$LOCK" ]; then
    if [ "$(stamp_age "$LOCK")" -lt "$LOCK_STALE" ]; then exit 0; fi
    log "лок сторожа протух (возраст $(stamp_age "$LOCK")с ≥ ${LOCK_STALE}с) — прошлый тик завис/убит, перехватываю"
fi
date +%s > "$LOCK"
echo $$ > "$WD_PID"        # «держатель жив?» — вопрос вердикта, см. tick_running
# Сигнал — ВЫХОД (C121): ловушка без `exit` снимала лок, а тик шёл дальше — следующий тик входил в середину этого.
trap 'rm -f "$LOCK" "$WD_PID"; wd_switch_drop' EXIT   # лок смены транспорта — только СВОЙ (wd_switch_take)
trap 'exit 1' INT TERM HUP PIPE

# --- Режим поддержки: погасить истёкший туннель (до boot-grace — экспайр важнее) ---
# DRY: watchdog уже бежит cron */2, поэтому reap живёт здесь, а не отдельным демоном. Дёшево
# и идемпотентно (no-op, когда доступ не открыт — гейт [ -s .support-active ] внутри). Ставим
# ДО boot-grace-выхода, но после ребута /tmp сброшен → .support-active нет → сразу no-op.
[ -f "$SUPPORT_SH" ] && sh "$SUPPORT_SH" reap >/dev/null 2>&1

# --- DoH keepalive: демон https_dns_proxy мог упасть, а dnsmasq форвардит на 127.0.0.1:5053 ---
# Мёртвый прокси при включённом DoH = DNS всего дома лёг (dnsmasq стучит в пустой loopback-порт).
# Несущая при этом жива, DNS-сеттер транспорта не перевызывается ⇒ поднять некому, кроме нас.
# Ставим ДО boot-grace/WAN-гейта: dead-proxy рвёт DNS в ЛЮБОМ состоянии, а старт демона безвреден
# даже при мёртвом WAN (он просто не резолвит, пока WAN не вернётся). Идемпотентно; без .doh-on/
# бинаря doh_enabled=false ⇒ no-op. Независимо от transport-failover ниже. [[doh-direct-modes-backlog]]
# ПАУЗА ПОСЛЕ НЕУДАЧНОЙ ПЕРЕПРОВОДКИ (doh-lib.sh::doh_rearm_due): резолвер не ответил на обоих путях, doh_apply_dns
# откатился, DNS держит прежний путь транспорта — прокси сейчас не нужен никому. Без паузы этот блок и сверка указателя
# ниже гоняли круг «поднять → перепровести → проба → откат» на каждом тике (до минуты под локом и два рестарта dnsmasq).
if doh_want 2>/dev/null && ! doh_running 2>/dev/null && doh_rearm_due; then
    log "DoH: https_dns_proxy не запущен, а DoH нужен (тумблер/авто-режим) → поднимаю"
    doh_start >>"$LOG" 2>&1
fi
# …И ВТОРАЯ ПОЛОВИНА: «ДЕМОН ЖИВ» НЕ ЗНАЧИТ «НА НЕГО СМОТРЯТ». Указатель `00-upstream.conf`
# ставит ТОЛЬКО DNS-сеттер транспорта (первой строкой зовёт doh_apply_dns), а тот срабатывает по
# событию: подъём несущей, switch, тумблер, бут. Если `doh_apply_dns` в это событие не уложился
# (прокси в тот момент лежал, порт не успел), сеттер честно откатывался на прежний путь —
# ТУННЕЛЬНЫЙ или открытый DNS, — а поднявшийся секундой позже демон уже никого не интересовал.
# ЗАМЕРЕНО НА BE7000 02.09.2026 (пересоздание несущей): `.doh-on=on`, прокси слушает 5053 UDP+TCP,
# а весь дом резолвит через 172.29.172.254 при зелёной надписи «Шифрованный DNS: включён» — и так
# до следующего ребута или переключения. Блок выше поднимал демона и на этом останавливался
# («поднять некому, кроме нас») — половина ответа.
# Судим ПО ФАКТУ (строка в конфиге), возвращаем через ВЛАДЕЛЬЦА (`transport.sh dns` → плагин →
# doh_apply_dns), своей записи файла тут нет. Смену транспорта пропускаем: в её окне указатель
# законно чужой, и наш вызов гонялся бы с самим switch'ем.
# Константы адреса прокси берём У БИБЛИОТЕКИ и требуем НЕПУСТЫМИ: без них шаблон вырождался в
# `server=#`, не совпадал НИКОГДА, и тик звал бы сеттер (с рестартом dnsmasq) каждые две минуты —
# ровно это и поймала песочница на старой копии doh-lib.sh. Нечем судить ⇒ не трогаем.
if [ -n "$DOH_ADDR" ] && [ -n "$DOH_PORT" ] && [ ! -e "$SWITCH_LOCK" ] \
   && doh_want 2>/dev/null && doh_running 2>/dev/null && doh_rearm_due \
   && [ -f "$ENODIA_DIR/transport.sh" ] \
   && ! grep -q "server=$DOH_ADDR#$DOH_PORT" /etc/dnsmasq.d/00-upstream.conf 2>/dev/null; then
    log "DoH: резолвер жив, а dnsmasq смотрит мимо него → возвращаю указатель (transport.sh dns)"
    sh "$ENODIA_DIR/transport.sh" dns >>"$LOG" 2>&1
fi
# Ротация лога прокси — ОТДЕЛЬНОЙ строкой, а не внутри doh_start: тот зовётся только когда демон
# УПАЛ, а лог растит как раз ЖИВОЙ (замерено ~3 МБ/сутки в ОЗУ, ротации не было вовсе). Цена тика —
# один `stat`; порог и глубина хвоста заданы в doh-lib.sh, второй копии политики тут нет.
command -v doh_log_rotate >/dev/null 2>&1 && doh_log_rotate
# Якоря СВОЕГО резолвера: адрес чужого сервера может уехать под нами, а на нём висят марка/RETURN
# :443/853 в mangle. Тут — единственное место, где мы это заметим БЕЗ перезапуска демона (doh_start
# зовётся только когда тот упал). Троттл, гейт «резолвер вообще свой?» и сама перестановка правил —
# внутри функции, второй копии политики здесь нет. Каталожные резолверы = мгновенный no-op.
command -v doh_custom_refresh >/dev/null 2>&1 && doh_custom_refresh

# --- Внешний накопитель: вернуть хранилище, если оно пропало из-под ног ---
# Второй (и последний) хук монтирования: первый — heal.sh, но он отрабатывает 1×/boot, а
# флешку могли воткнуть ПОСЛЕ его тика, выдернуть и вставить обратно, или стоковый automount
# отвалился. Без хранилища bin_path отдаёт резидентный путь, транспорт становится «не
# установлен» и ветки ниже честно уводят в fail-open — вот только чинить это по-настоящему
# умеет ровно одно действие: смонтировать обратно. Ставим ДО boot-grace: на буте heal и
# watchdog идут вперемешку, а монтаж безвреден в любом состоянии. Нет маркера .bin-store
# (роутер без накопителя) ⇒ usb-offload выходит первой строкой, no-op.
[ -f "$ENODIA_DIR/usb-offload.sh" ] && sh "$ENODIA_DIR/usb-offload.sh" mount-ensure >>"$LOG" 2>&1

# --- Boot-grace: не мешаем heal.sh поднять несущую на буте ---
# Пойман 07.07.2026: сразу после ребута watchdog (ещё ДО того, как heal поднял xray)
# объявлял транспорт «подтверждённый сбой» → failover → пул исчерпан → safety_off, а
# спустя ~20с heal штатно поднимал xray. Итог — самонаведённый failopen-churn на каждом
# ребуте + залипший FAILOPEN (см. баг сброса STATE ниже). Первые $BOOT_GRACE сек просто
# пропускаем тик: на буте /tmp сброшен → STATE=NORMAL, терять нечего, а здоровый транспорт
# пройдёт health на первом же тике после грейса. Гейт общий — прикрывает и tunnel-, и awg-ветку.
up=$(up_secs)
# Часы — ДО выхода по boot-grace: heal мог сверить их раньше WAN (см. clock_tick_sync), а первый
# честный тик после грейса обязан судить рукопожатие уже с верными часами. Дёшево: после первой
# удачи это один `[ -f ]`, а неудачи библиотека сама ограничивает по числу и паузе.
clock_tick_sync
if [ "$up" -lt "$BOOT_GRACE" ]; then
    # Грейс снимается ТОЛЬКО когда охранять нечего (heal отработал, несущей нет вовсе, ни разу не
    # везла) — см. boot_grace_waived; тик тогда идёт дальше и поднимает несущую веткой «не
    # поднимали ни разу», как сделал бы после грейса.
    if boot_grace_waived; then
        log "boot-grace: uptime ${up}с < ${BOOT_GRACE}с, но heal уже отработал, а несущей нет вовсе — грейс снимаю (бинарь/накопитель приехали после heal, поднять несущую больше некому)"
    else
        log "boot-grace: uptime ${up}с < ${BOOT_GRACE}с — пропускаю тик (первичный подъём несущей за heal.sh)"
        exit 0
    fi
fi

# --- НАБЛЮДЕНИЕ (не решение): видели ли мы awg0 живым в эту загрузку ---
# «Интерфейса нет» — ДВА разных события с одинаковой сигнатурой: несущая УПАЛА (демон умер/OOM —
# про это шлём письмо) и несущую ЕЩЁ НЕ ПОДНИМАЛИ (намерение `.transport=awg` приехало импортом
# бэкапа, а компонент доставили из «Компонентов» — тот ставит, но не активирует). Второе — не
# авария: письмо «awg0 упал — прямой режим» описывает падение того, что не поднималось (замерено
# на AX3600 17.08.2026). Отличить их можно ТОЛЬКО по своей же памяти, поэтому отметку кладём тут,
# ДО всех веток: это наблюдение сторожа, оно не зависит ни от активного транспорта (при xray awg0
# — тёплый резерв, и он тоже считается «был живым»), ни от версии плагинов. Ветка awg0 читает её
# ниже. Мимо boot-grace: там тик выходит раньше, а на буте несущую поднимает heal.
if ip link show awg0 >/dev/null 2>&1; then date +%s > "$AWG0_SEEN" 2>/dev/null || true; fi
# …И ЗДЕСЬ ЖЕ ЗАКРЫВАЕМ ОЖИДАНИЕ ПЕРВОГО ПОДЪЁМА. Отметка `$AWG0_FIRSTUP` значит «прямой режим
# поставили МЫ, ожидая, что heal поднимет awg0 впервые». Снимала её только ветка-потребитель и
# ветка «VPS мёртв», а между ними есть третий путь: STATE успел уйти в NORMAL чужими руками
# (ручная смена сервера в панели пишет его сама) — и отметка доживала до СЛЕДУЮЩЕЙ, настоящей
# аварии, после которой возврат прошёл бы молча и с ложной строкой «поднят ВПЕРВЫЕ» (ревью 3,
# 06.09.2026). Признак «ожидание кончилось» тут ровно один: STATE больше не FAILOPEN — значит из
# прямого режима вышли не через нас. Отметку НЕ снимаем по «awg0 появился»: это как раз тот случай,
# ради которого она и заведена (её читает ветка «VPS жив» ниже, в этом же тике).
if [ -f "$AWG0_FIRSTUP" ] && [ "$(cat "$STATE" 2>/dev/null)" != "FAILOPEN" ]; then
    rm -f "$AWG0_FIRSTUP" 2>/dev/null
fi

# --- Настроен ли транспорт ВООБЩЕ (установка «только панель») ---
# Спрашиваем ОРКЕСТРАТОР (единственный владелец ответа; признак — пустой `.transport` И отсутствие
# awg.conf, см. transport.sh cmd_configured). Код 2 = старая копия скрипта, верб не знаком ⇒ ведём
# себя как раньше: обновление в любом порядке не должно выключать сторожа на рабочем роутере.
# Цена — один fork в два минуты; ответ нужен ДО mipctld-гарда, который иначе создаст маркировку
# с нуля там, где её сознательно не заводили.
TRANSPORT_OK=1
if [ -f "$TRANSPORT_SH" ]; then
    sh "$TRANSPORT_SH" configured >/dev/null 2>&1; _tc=$?
    [ "$_tc" = 1 ] && TRANSPORT_OK=0
fi
# --- …и ВЫКЛЮЧЕН ЛИ VPN ЧЕЛОВЕКОМ (`vpn-toggle.sh off`) -------------------------------------
# Это СОСТОЯНИЕ, а не разовое действие: флаг живёт на /data и переживает ребут (его же читает
# heal). Для сторожа «выключено» и «не настроено» — один и тот же ответ на вопрос «сторожить ли
# несущую»: сторожить нечего, и лезть в ядро нельзя. Поэтому ГАСИМ ТЕМ ЖЕ ФЛАГОМ — иначе пришлось
# бы дублировать оба его следствия (mipctld-гард ниже создал бы маркировку С НУЛЯ там, где её
# сознательно сняли, а лестница failover через две минуты подняла бы несущую обратно — ровно на
# это жаловались: «выключаю zapret, а он воскресает»). Слот-свипы и DoH за finish() остаются:
# «Шифрованный DNS» живёт и без VPN, а слоты свои правила потеряли вместе с `off`.
if [ -f "$ENODIA_STATE/.vpn-off" ]; then TRANSPORT_OK=0; fi

# --- mipctld-guard: наши MARK+ACCEPT должны стоять ВЫШЕ miwifi/NFQUEUE ---
# ГРАБЛЯ (тестер, 12.07.2026 — [[mipctld-nfqueue-fwmark-split]]): стоковый mipctld инспектирует
# ФОРВАРД через ipt_compiler/NFQUEUE в mangle PREROUTING и реинъектит пакет с mark=0. mark-core
# ставит MARK+ACCEPT ВЫШЕ этих цепочек, но durable-фикс может «сползти»:
#   (1) на буте heal.sh (1×/boot) мог отработать РАНЬШЕ, чем firewall построил ipt_compiler →
#       mark-core сфолбэчил аппендом НИЖЕ miwifi → метка стирается → клиент мимо туннеля;
#   (2) fw3/mipctld пересобирают цепочки и задвигают наши правила вниз.
# Тут (cron */2) дёшево сверяем позиции и, если наш iplist_set-MARK ОТСУТСТВУЕТ ИЛИ стоит НИЖЕ
# первой miwifi-цепочки — переигрываем mark-core (идемпотентно ставит выше). conntrack НЕ трогаем
# (флаш всех соединений раз в 2 мин = дребезг связи; правильный путь берут НОВЫЕ потоки, а гард
# в норме молчит). Где фичи Xiaomi нет (дев-роутер) — miwifi не найден → no-op.
mark_above_miwifi_ok() {
    mi=$(iptables -t mangle -nL PREROUTING --line-numbers 2>/dev/null | awk '/miwifi|ipt_compiler|NFQUEUE/{print $1; exit}')
    [ -z "$mi" ] && return 0   # фичи Xiaomi нет — сторожить нечего
    mk=$(iptables -t mangle -nL PREROUTING --line-numbers 2>/dev/null | awk '/match-set iplist_set dst/ && /MARK set/{print $1; exit}')
    # Маркировки нет ВООБЩЕ и транспорт не настроен («только панель») — сторожить тоже нечего:
    # правил в ядре не заводили, а «починка» их СОЗДАЛА БЫ, вернув маркировку в пустую table 1000
    # на роутере, где человек ещё ничего не выбрал. Различать «нет вовсе» и «сползло вниз»
    # обязательно: второе — настоящий баг, ради которого гард и написан, и он остаётся живым и
    # для слот-режима (доп-выход без основной несущей — правила есть, транспорта нет).
    [ -z "$mk" ] && [ "$TRANSPORT_OK" = 0 ] && return 0
    [ -n "$mk" ] && [ "$mk" -lt "$mi" ]   # MARK есть И выше первой miwifi-цепочки
}
if ! mark_above_miwifi_ok; then
    log "mipctld-guard: маркировка iplist_set ниже/мимо miwifi — переигрываю mark-core"
    restore_marking
fi

# --- Keepalive «доступа домой»: сервер включён, а несущей awgs0 нет ---
# Несущая сервера — такой же демон в userspace, как awg0: умер (OOM, чужой killall, ручной
# kill) — TUN уходит вместе с ним, и поднять его до следующего ребута НЕКОМУ (heal.sh заперт
# boot-локом 1×/boot, а `vpn-toggle repair` зовётся только по rule-heal). Снаружи это выглядит
# как «телефон вчера подключался, а сегодня нет», причём правила фаервола на месте и панель
# показывает «включено». Поймано на железе 30.07: failover звал switch-vpn → awg_setup.sh с
# `killall amneziawg-go` (сам killall вычищен, но страховка нужна и на прочие смерти демона).
# Дёшево (одна `ip link show` в тик) и идемпотентно; флаг server/.on = НАМЕРЕНИЕ человека,
# поэтому решение «поднимать» принимаем по нему, а не по наличию интерфейса.
if [ -f "$VPNSRV_SH" ] && [ -f "$ENODIA_STATE/server/.on" ] && ! ip link show awgs0 >/dev/null 2>&1; then
    log "доступ домой: сервер включён, но несущей awgs0 нет (демон умер?) → поднимаю"
    sh "$VPNSRV_SH" up >>"$LOG" 2>&1
fi

# Транспорт-aware. При активном TUNNEL-транспорте (.transport != awg: xray/hy2/…) awg-логику
# НЕ применяем (иначе watchdog зря гонял бы awg-failover, видя «старый» handshake awg0-резерва).
# ВСЯ работа с tunnel-транспортом идёт через ОРКЕСТРАТОР (transport.sh health/failover/switch/
# down/next) — имя файла плагина знает только он, поэтому ветка generic и hysteria2 станет
# drop-in (без правок watchdog). Лестница на сбой (НЕ цикл — каждый протокол ≤1 раза за эпизод,
# терминал = safety_off):
#   off            → вернуться на AmneziaWG (если установлен), иначе прямой режим.
#   sticky/home    → перебор резервов транспорта (transport.sh failover); исчерпан →
#                    по .failover-escalate: cross → следующий готовый транспорт (transport.sh
#                    next, обычно awg) + его перебор (анти-петля через episode-гард),
#                    direct → прямой режим.
# Анти-дребезг: первая осечка health = SUSPECT (без действий), реакция со 2-го тика.
# После фолбэка на awg .transport=awg → следующий тик идёт обычной awg-веткой.
# Транспорта нет вовсе (установка «только панель»): несущей никто не заводил, чинить нечего.
# Молча — а не строкой в лог каждые две минуты: тик здорового роутера обязан быть тихим, иначе
# лог в ОЗУ растёт ровно там, где ничего не происходит. Выходим ЧЕРЕЗ finish(), а не своим
# `exit 0`: доп-выход (слот) и «Шифрованный DNS» живут БЕЗ основной несущей, и их свипы —
# единственное, что в этом состоянии вообще осмысленно.
# …но ПРАВИЛА НЕ ПРО VPN сторожим и тут: блокировки, запрет IPv6 и «доступ домой» живут без несущей (см. nonvpn_rules_sweep).
if [ "$TRANSPORT_OK" = 0 ]; then nonvpn_rules_sweep; finish; fi

TRANSPORT=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
if [ -n "$TRANSPORT" ] && [ "$TRANSPORT" != "awg" ] && [ -f "$TRANSPORT_SH" ]; then
    TLABEL=$(transport_label "$TRANSPORT")
    xcur=HEALTHY; [ -f "$XSTATE" ] && xcur=$(cat "$XSTATE")

    # HEV_CHECK=1 — путь клиентов через hev судит главный health тика (slot-tun-lib.sh::hev_path_check) и ПРОВЕРКИ ТИКА «встали /
    # вернулись» (cross, возврат домой, откат на прежний): тот же health проверяет кандидатов перебора и прогрев, и залипший путь
    # там стоил бы перезапуска hev и сброса соединений на каждом конфиге. А проверка ПЕРЕХОДА без пути (ревью с.93, круг 3) читала
    # транспорт с мёртвым hev «вернувшимся»: возврат домой → через тик снова «упал» → cross — пара писем каждые 20 минут.
    if HEV_CHECK=1 sh "$TRANSPORT_SH" health "$TRANSPORT" >>"$LOG" 2>&1; then
        # ВИДЕЛИ СВОИМИ ГЛАЗАМИ: несущая этого транспорта в эту загрузку везёт. Дальше провал
        # health читается как ПАДЕНИЕ, а не как «её ещё не поднимали» (см. carrier_seen).
        # Счётчик попыток подъёма сбрасываем тут же: он про НЕЗАВЕРШЁННЫЙ СТАРТ, а старт
        # завершился — иначе первое же падение через неделю аптайма пришло бы с исчерпанным
        # счётчиком и «второй шанс» достался бы не тому случаю.
        carrier_seen_mark "$TRANSPORT"; carrier_tries_reset "$TRANSPORT"
        if [ "$xcur" != "HEALTHY" ]; then echo HEALTHY > "$XSTATE"; episode_reset; log "$TRANSPORT health: ок"; fi
        doh_follow_carrier ok       # несущая везёт ⇒ резолвер можно вернуть в туннель
        health_back   # бэкофф перебора, эпизоды «интернета нет» и (продержавшись FAILOPEN_STABLE) «прямого режима» закрыты
        # STATE обратно в NORMAL, если несущую подняли МИМО watchdog (типичный boot-race:
        # failopen поставил сам watchdog, а поднял транспорт heal.sh). В NORMAL его писали
        # ТОЛЬКО cross/failover-ветки → без этого STATE залипал в FAILOPEN на здоровом
        # туннеле, и статус/панель/меню врали «прямой режим». health прошёл → трафик идёт
        # через VPN = NORMAL. Идемпотентно: пишем, только если там не NORMAL.
        # ВОЗВРАТ ИЗ FAILOPEN — ЭТО НЕ СТРОКА В ФАЙЛЕ, А ВОССТАНОВЛЕНИЕ ЯДРА. safety_off снял и
        # маршрут, и `ip rule fwmark→1000`; маршрут вернул плагин несущей, а правило кладёт
        # mark-core — и здесь его не звал НИКТО (в awg-ветке это делает restore_awg_carrier, у
        # tunnel-транспортов аналога не было). Итог, ЗАМЕРЕННЫЙ на AX3600 03.09.2026: NORMAL +
        # HEALTHY + полная table 1000 + метки в mangle, а метке некуда вести — весь «VPN-трафик»
        # идёт мимо туннеля при зелёной панели. restore_marking идемпотентен и conntrack не трогает,
        # так что чиним СРАЗУ, а не двумя тиками rule-heal ниже (тот остаётся страховкой на случай,
        # когда правило пропало без смены состояния — fw3-reload, ручное `ip rule del`).
        if [ "$(cat "$STATE" 2>/dev/null)" != "NORMAL" ]; then
            # ...но ТОЛЬКО тем, кто везёт ПО МАРКЕ. У zapret марок нет вовсе (десинк идёт прямым
            # путём), и mark-core положил бы ему `ip rule` в ПУСТУЮ table 1000 — правила, которых
            # у этого транспорта не бывает по определению. Его проводку (jump ENODIA_ZAPRET)
            # сторожит отдельная ветка split_rules_wiped ниже.
            uses_marking "$TRANSPORT" && restore_marking
            echo NORMAL > "$STATE"
        fi
        # Rule-heal: health прошёл (несущая xtun жива), но fw3-reload мог снести FORWARD/сплит —
        # переиграть правила, иначе клиент молча идёт мимо туннеля. [[boot-race-fw3-reload-wipes-rules]]
        split_rules_wiped "$TRANSPORT" && heal_split_rules "$TRANSPORT"
        # …и вторая половина того же вопроса: правила на месте, а САМ МАРШРУТ несущей пропал
        # (table 1000 пуста) ⇒ маркированный трафик молча идёт напрямую. См. carrier_route_lost.
        carrier_route_lost "$TRANSPORT" && heal_carrier_route "$TRANSPORT"
        # …и ТРЕТЬЯ половина: маршрут на месте, а `ip rule fwmark→1000` пропал ⇒ метка никуда не
        # ведёт, трафик идёт мимо туннеля при зелёном статусе. См. carrier_rule_lost.
        carrier_rule_lost "$TRANSPORT" && heal_carrier_rule "$TRANSPORT"
        # A: домашний транспорт = awg, а мы на tunnel (после cross) → вернуться на awg,
        # когда awg0 снова жив (он держит handshake тёплым резервом). Только mode=home,
        # троттл FAILBACK_INTERVAL. transport_home пуст → не трогаем (юзер не задавал).
        if fo_home_transport_back "$TRANSPORT" \
           && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
            ahs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$ahs" in ''|*[!0-9]*) ahs=0 ;; esac
            if [ "$ahs" -gt 0 ] && awg_hs_alive "$(age_since "$ahs")"; then
                date +%s > "$FAILBACK_STAMP"
                log "home-transport: awg жив → возврат на AmneziaWG"
                # релинквиш tunnel + подъём awg-несущей; неудачный подъём оркестратор откатывает сам и отвечает 1
                if tsw awg; then
                    failback_event transport "$(transport_label awg)"
                fi
            fi
        fi
        finish
    fi

    # …health НЕ прошёл. ПЕРЕД лестницей спрашиваем, есть ли на роутере сама программа: переезд
    # (импорт бэкапа принёс `.transport`, а бинарей тут не было ни разу) кончался письмом
    # «$TLABEL упал, резервы недоступны» — о падении того, что никогда не поднималось, — и
    # бесконечным перебором серверов, который делу не помогает. Состояние ставим честное (мы вне
    # туннеля) и говорим ОДИН раз: лечится не перебором, а установкой компонента.
    # МЕСТО ВАЖНО — строго ПОСЛЕ пробы health, а не до неё: у альтов бинарь ищется через bin_path,
    # то есть «программы нет» и «накопитель отвалился» — ОДИН ответ, а демон в этот момент жив в
    # памяти и туннель может везти. Спроси мы раньше — тик снимал бы с маршрута РАБОЧУЮ несущую.
    if ! carrier_installed "$TRANSPORT"; then
        if [ "$xcur" != FAILED ]; then
            log "transport=$TRANSPORT, но компонент не установлен — лестницу не кручу (ставить в панели: «Компоненты»)"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
            transport_missing_event "$TLABEL"
        fi
        finish
    fi

    # НЕСУЩУЮ ТОЛЬКО ЧТО ПОДНЯЛИ — не судим её вовсе (ни SUSPECT, ни лестница). Лок смены
    # транспорта к этому моменту уже снят (он держится до старта демонов, а не до рабочего
    # egress), поэтому гард выше сюда не достаёт. Ровно этот зазор красил живой канал в
    # «проверяю…» и мог отменить ручной выбор сервера авто-резервом.
    _cg=$(stamp_age "$CARRIER_UP_STAMP")
    if [ "$_cg" -lt "$CARRIER_GRACE" ]; then
        log "$TRANSPORT health: осечка, но несущую подняли ${_cg}с назад (грейс ${CARRIER_GRACE}с) — жду прогрева"
        finish
    fi

    # Первая осечка → SUSPECT, без действий: ждём подтверждения на след. тике (≈2 мин;
    # зеркало гистерезиса awg-handshake, чтобы не флапать на разовой пробе). Это и
    # начало нового эпизода аварии — сбрасываем episode-гард.
    # КРОМЕ несущей, которой НЕТ ВОВСЕ (carrier_absent_unraised): подтверждать нечего, идём сразу
    # в ветку «не поднимали ни разу» ниже — её собственные гейты (интернет, программа, счётчик)
    # остаются. Сценарий 21 в dev/watchdog-tick-test.sh (+ мутант S).
    if [ "$xcur" = "HEALTHY" ] && ! carrier_absent_unraised "$TRANSPORT"; then
        echo SUSPECT > "$XSTATE"; episode_reset
        log "$TRANSPORT health: осечка (жду подтверждения на следующем тике)"
        # Резолвер уводим УЖЕ на первой осечке, не дожидаясь подтверждения: ждать нечего — если
        # несущая жива, вернём его следующим же тиком, а если мертва, то ровно в эти две минуты
        # человек и лезет менять сервер, и без DNS у него ничего не поднимется.
        doh_follow_carrier suspect
        finish
    fi

    # Интернета нет ВООБЩЕ (линк/дефолт лёг ИЛИ egress-проба через WAN не отвечает дважды
    # подряд) → ни один сервер/транспорт недостижим: перебор бессмыслен. Ждём восстановления
    # аплинка, не трогая транспорт (вернётся health сам).
    if ! inet_reachable; then
        log "$TRANSPORT health: провал, но интернета нет вообще — не перебираю, жду аплинка"
        exit 0
    fi
    # Часы — раньше лестницы, но ЗА WAN-гейтом: Reality/TLS сверяют время, и с отставшими часами
    # перебор резервов хоронил бы живые серверы один за другим (после первой удачи — no-op).
    clock_tick_sync

    # --- НЕСУЩУЮ В ЭТУ ЗАГРУЗКУ НЕ ПОДНИМАЛИ НИ РАЗУ: это НЕЗАВЕРШЁННЫЙ СТАРТ, а не падение ---
    # ЗАЧЕМ ОТДЕЛЬНАЯ ВЕТКА, если лестница ниже тоже кончается подъёмом. Лестница — это ответ на
    # вопрос «что делать, когда ЭТО СЛОМАЛОСЬ»: она жжёт эпизод, перебирает серверы и в конце
    # эскалации МЕНЯЕТ ТРАНСПОРТ (cross) либо уводит в прямой режим, попутно рассылая письма о
    # падении. Применить её к несущей, которую никто не поднимал, значит отменить выбор человека
    # из-за того, что в момент единственной попытки (heal, 1×/boot) бинарь лежал на ещё не
    # смонтированном накопителе. Правильное действие тут одно и простое: ПОДНЯТЬ.
    # ЗОВЁМ ОРКЕСТРАТОР (`transport.sh up`), а не плагин: имя файла плагина знает только он, и он
    # же переиграет mark-core. Это ровно то, что сделал бы heal, — но heal заперт локом 1×/boot.
    # ГЕЙТЫ, БЕЗ КОТОРЫХ ЭТА ВЕТКА ВРЕДНА, стоят ВЫШЕ и переиспользуются как есть:
    #   · boot-grace  — на буте несущую поднимает heal, мы не мешаем;
    #   · SWITCH_LOCK — идёт ручная смена транспорта, тик вышел ещё в начале файла;
    #   · carrier_installed — программы нет вовсе: поднимать нечем, об этом сказано выше;
    #   · inet_reachable — интернета нет: подъём заведомо не пройдёт health;
    #   · гистерезис SUSPECT — разовая осечка пробы не считается «не поднимали».
    # АНТИ-ПЕТЛЯ — счётчик попыток: несущая может не подниматься и по причинам, которых мы не
    # исправим (битый конфиг, чужая арка бинаря). Отдав вопрос лестнице после N попыток, мы
    # возвращаемся к сегодняшнему поведению — с эскалацией и письмами, — то есть человек всё же
    # получает рабочий туннель, пусть и не на выбранном транспорте.
    if ! carrier_seen "$TRANSPORT"; then
        # HEAL ПОДНИМАЕТ ЕЁ ПРЯМО СЕЙЧАС — не наперегонки (ревью 3, 06.09.2026). Гард обязан стоять
        # ЗДЕСЬ, а не только в гистерезисе выше: тот отсекает лишь ПЕРВЫЙ тик (xcur=HEALTHY), а
        # второй приходит с xcur=SUSPECT, падает сюда и зовёт `up` вторым — `transport.sh up` лока
        # не берёт, так что было куплено ровно две минуты отсрочки, а не защита.
        if heal_running; then log "$TRANSPORT: несущую поднимает heal (лок держит живой прогон) — не мешаю"; finish; fi
        # …И НЕ СПОРИМ С ЧЕЛОВЕКОМ. `vpn-toggle off` снимает `ip rule fwmark 0x1 table 1000`, у
        # немаркирующего транспорта (zapret) ещё и опускает несущую, а НАМЕРЕНИЕ `.transport` не
        # трогает СОЗНАТЕЛЬНО. Снаружи это неотличимо от «несущую не поднимали», и подъём вернул
        # бы выключенный человеком VPN через две минуты — ровно тот симптом «после некоторой
        # магии всё вернулось», который чинили 18.08.2026 со стороны самого тумблера.
        # ОТЛИЧАЕМ ПО СЕТИ ПЛЮС ПО СВОЕМУ ЖЕ ВЕРДИКТУ: то же правило снимает и наш safety_off
        # (ветка «компонента нет»), но он же ставит STATE=FAILOPEN — значит в прямом режиме МЫ,
        # и возвращаться оттуда можно. Правила нет, а FAILOPEN не наш ⇒ выключил человек.
        # МОЛЧА: выключенный VPN — не авария, а состояние, и тик в нём обязан быть тихим. Строка
        # раз в две минуты растила бы лог в ОЗУ ровно там, где ничего не происходит (инвариант
        # этого файла). Ответ «почему не поднимаем» и так виден в дампе — по отсутствию ip rule.
        if ! carrier_rule_present && [ "$(cat "$STATE" 2>/dev/null)" != "FAILOPEN" ]; then
            finish
        fi
        _cnt=$(carrier_tries "$TRANSPORT")
        if [ "$_cnt" -lt "$CARRIER_UP_TRIES" ]; then
            # Лок — ДО отметки попытки (как у переподъёма awg0): занятый лок кончает тик, и попытка, отмеченная раньше, сгорала бы
            # без подъёма — три занятых тика подряд, и несущую до ребута не поднимет никто (ревью с.93).
            wd_switch_take "подъём $TRANSPORT"
            carrier_tries_add "$TRANSPORT"
            log "$TRANSPORT: несущую в эту загрузку не поднимали ни разу (heal не смог — бинарь/накопитель приехали позже) → поднимаю, попытка $((_cnt + 1)) из $CARRIER_UP_TRIES"
            sh "$TRANSPORT_SH" up "$TRANSPORT" >>"$LOG" 2>&1
            wd_switch_drop
            finish
        fi
        # СКАЗАТЬ ОДИН РАЗ. Счётчик здесь уже не про попытки, а про «сообщили»: перешагиваем
        # потолок, и следующие тики проходят молча. Без этого строка уходила бы в лог каждые две
        # минуты до самого ребута — на роутере, где несущей взяться неоткуда, это единственное,
        # что в логе и осталось бы.
        if [ "$_cnt" = "$CARRIER_UP_TRIES" ]; then
            carrier_tries_add "$TRANSPORT"
            log "$TRANSPORT: несущая не поднялась за $CARRIER_UP_TRIES попытки — дальше обычная лестница"
        fi
    fi

    mode=$(fo_mode)
    fo_mode_note "$mode"

    # --- МЫ УЖЕ В ПРЯМОМ РЕЖИМЕ (xcur=FAILED): лестницу крутим ПО ТРОТТЛУ, а не каждый тик ---
    # Симметрия с awg-веткой («уже FAILOPEN → повторная попытка по fo_retry»), но кап паузы свой —
    # TUNNEL_RETRY_MAX (там несущая остаётся тёплой, у нас снята; см. коммент к константе).
    # Без троттла тик раз в 2 мин звал failover, тот ФАЗОЙ 0 поднимал несущую под мёртвым VPS,
    # health проваливался — и так по кругу, оставляя блэкхол (см. ensure_direct_mode). Порядок
    # важен: СНАЧАЛА гарантируем прямой режим, и только потом решаем, пора ли пробовать снова —
    # иначе ожидание проходило бы с живым маршрутом в никуда. mode=off сюда не входит: там своя
    # терминальная ветка ниже (она несущую уже сняла и лестницу не крутит).
    if [ "$xcur" = FAILED ] && [ "$mode" != off ]; then
        ensure_direct_mode "$TRANSPORT"
        _ret=$(fo_retry); [ "$_ret" -gt "$TUNNEL_RETRY_MAX" ] && _ret=$TUNNEL_RETRY_MAX
        _left=$(( _ret - $(stamp_age "$FAILOVER_STAMP") ))
        if [ "$_left" -gt 0 ]; then
            log "$TRANSPORT мёртв, уже FAILOPEN — прямой режим (следующая попытка через $((_left / 60)) мин)"
            finish
        fi
        episode_reset   # свежая попытка ВСЕЙ лестницы: вдруг ожил другой транспорт
        log "$TRANSPORT всё ещё мёртв, FAILOPEN → повторная попытка восстановления"
    fi

    episode_add "$TRANSPORT"
    log "$TRANSPORT health: подтверждённый сбой (режим=$mode)"

    if [ "$mode" = "off" ]; then
        # Фолбэк — только на УСТАНОВЛЕННЫЙ AmneziaWG (`awg_fallback_ok`: конфиг И программа). Конфиг без программы — это «awg не
        # установлен»: ветка ниже уводит в прямой режим ОДИН раз, а не зовёт отказывающий `switch awg` с письмом на каждом тике.
        # …И ЗАСЧИТЫВАЕТСЯ ОН ПО ФАКТУ, как возврат домой (`_fb_ok`): установленный AmneziaWG может и не подняться (awg_setup без
        # конфига страны, демон унёс OOM), и тогда `switch` ОТКАТЫВАЕТ флаг на прежний туннель, поднимает его к мёртвому VPS и
        # отдаёт код 1. Без кода тик писал «вернулись на AmneziaWG» каждые две минуты с мёртвой несущей в table 1000 (ревью
        # dev233, круг 1). Неудача — тот же прямой режим, а повтор — по троттлу лестницы (`fo_retry`, кап TUNNEL_RETRY_MAX):
        # каждый `switch awg` — это down/up несущих и сброс соединений, а вердикт «вернёт сам» держится на этих повторах: каждый
        # поднимает и AmneziaWG, и (откатом) сам туннель — ожившего хватит любого.
        _fb_awg=0; _fb_why=absent
        if awg_fallback_ok; then
            _fb_why=failed
            _ret=$(fo_retry); [ "$_ret" -gt "$TUNNEL_RETRY_MAX" ] && _ret=$TUNNEL_RETRY_MAX
            if [ "$xcur" != FAILED ] || [ "$(stamp_age "$FAILOVER_STAMP")" -ge "$_ret" ]; then
                date +%s > "$FAILOVER_STAMP"
                log "$TRANSPORT режим=off → фолбэк на AmneziaWG"
                _fb_awg=1
                tsw awg || _fb_awg=0   # релинквиш tunnel + подъём awg-несущей + .transport=awg
                [ "$_fb_awg" = 1 ] && [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" = awg ] || _fb_awg=0
                if [ "$_fb_awg" = 0 ]; then
                    # ОТКАТ ВЕРНУЛ ТУННЕЛЬ — СПРОСИТЬ ЕГО, А НЕ СНИМАТЬ ВСЛЕПУЮ. Неудачный `switch` поднимает прежнюю несущую
                    # обратно, и её VPS за паузу мог ожить; в режиме «Выкл» туннель иначе не проверялся бы НИКОГДА (выход из
                    # прямого — только через AmneziaWG), а панель обещала бы «вернёт сам» (ревью dev233, круг 2). Проба — как у
                    # возврата домой. Везёт ⇒ несущую оставляем, а HEALTHY/NORMAL и починку правил запишет здоровая ветка
                    # следующего тика — у перехода ОДИН владелец (объявленное отставание вердикта — один тик).
                    if [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" = "$TRANSPORT" ] \
                       && HEV_CHECK=1 sh "$TRANSPORT_SH" health "$TRANSPORT" >>"$LOG" 2>&1; then
                        log "$TRANSPORT режим=off: AmneziaWG не поднялся, но сам $TRANSPORT снова везёт — остаёмся на нём"
                        revived_event "$(transport_label awg)"
                        finish
                    fi
                    # Не везёт ⇒ пауза растёт лестницей (10 → 20 → 30 мин, кап TUNNEL_RETRY_MAX): каждая попытка — это down/up
                    # несущих, сброс соединений и рестарты dnsmasq, а неудача бывает постоянной (ревью dev233, круг 2). Как у
                    # лестницы резервов: ПЕРВЫЙ отказ эпизода паузу не растит — первый повтор через базовые 10 мин (круг 3).
                    log "$TRANSPORT режим=off: AmneziaWG не поднялся → прямой режим"
                    if [ "$xcur" = FAILED ]; then fo_backoff_bump "$TUNNEL_RETRY_MAX"; fi
                fi
            fi
        fi
        if [ "$_fb_awg" = 1 ]; then
            echo FAILED > "$XSTATE"
            ip=$(ext_ip)
            if [ "$NF_LANG" = en ]; then
                notify_ev "cross-switch" 0 "BE7000: $TLABEL went down -> back to AmneziaWG" \
"$TLABEL failed the health check (daemon/tunnel/egress probe).
Auto-failover is off (mode off) — the router returned to AmneziaWG (awg0).
External IP now: ${ip:-unknown}.
To turn $TLABEL back on: panel :8088 -> the VPN card."
            else
            notify_ev "cross-switch" 0 "BE7000: $TLABEL упал -> вернулись на AmneziaWG" \
"$TLABEL не прошёл проверку здоровья (демон/туннель/проба egress).
Авто-failover выключен (режим off) — роутер вернулся на AmneziaWG (awg0).
Внешний IP сейчас: ${ip:-неизвестен}.
Снова включить $TLABEL: панель :8088 -> карточка VPN."
            fi
        else
            # Возвращаться на awg НЕКУДА (не установлен/не настроен) или он не поднялся → прямой режим. Уведомляем ОДИН
            # раз (на переходе xcur!=FAILED): .transport остаётся прежним, иначе ветка крутила бы down+письмо каждый тик.
            # down в tunnel-only сам уводит в прямой (set_direct_dns); после неудачного switch он же снимает несущую, которую
            # откат оркестратора поднял обратно (и проба выше сказала, что VPS мёртв). Письмо называет ИМЕННО ту причину, что была.
            if [ "$xcur" != FAILED ]; then
                if [ "$_fb_why" = failed ]; then
                    _fb_ru="AmneziaWG не поднялся"; _fb_en="AmneziaWG failed to come up"
                    _fb_tru="Сторож повторит переход сам (не чаще раза в 10–30 мин); вернуть $TLABEL сразу: панель :8088 -> карточка VPN."
                    _fb_ten="The watchdog retries by itself (every 10–30 min); to bring $TLABEL back now: panel :8088 -> the VPN card."
                else
                    _fb_ru="AmneziaWG не установлен или не настроен"; _fb_en="AmneziaWG is not installed or not set up"
                    _fb_tru="Снова поднять $TLABEL: панель :8088 -> карточка VPN."
                    _fb_ten="To bring $TLABEL back up: panel :8088 -> the VPN card."
                    log "$TRANSPORT режим=off, AmneziaWG не установлен (нет конфига или программы) → прямой режим (fail-open)"
                fi
                sh "$TRANSPORT_SH" down "$TRANSPORT" >>"$LOG" 2>&1
                echo FAILED > "$XSTATE"
                ip=$(ext_ip)
                if [ "$NF_LANG" = en ]; then
                    failopen_mail "BE7000: $TLABEL went down -> direct mode" \
"$TLABEL failed the health check (daemon/tunnel/egress probe).
Auto-failover is off (mode off) and $_fb_en — the router is in DIRECT
mode: traffic and DNS bypass the VPN (if the ISP link is up, the internet works),
listed sites are unavailable.
External IP now: ${ip:-unknown}.
$_fb_ten"
                else
                failopen_mail "BE7000: $TLABEL упал -> прямой режим" \
"$TLABEL не прошёл проверку здоровья (демон/туннель/проба egress).
Авто-failover выключен (режим off), $_fb_ru — роутер в ПРЯМОМ
режиме: трафик и DNS идут мимо VPN (если связь с провайдером есть, интернет
работает), сайты из списка недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.
$_fb_tru"
                fi
            else
                # Повторные тики: письмо и переход не дублируем, но следим, что прямой режим не
                # разъехался — несущую мог поднять heal/установщик/ручной up, а VPS всё ещё мёртв.
                # ВЕРДИКТ — СВОИМ ИМЕНЕМ, и при ПУСТОЙ table 1000 тоже: повтор фолбэка звал `switch`, чей `down` стирает xstate, а
                # откат мог и не поднять несущую (у Hysteria2 при мёртвом VPS — штатно), тогда `ensure_direct_mode` выходит молча.
                # Без FAILED следующий тик читал «здоров» → SUSPECT → повтор без паузы и второе письмо (ревью dev233, круг 3).
                ensure_direct_mode "$TRANSPORT"
                echo FAILED > "$XSTATE"
            fi
        fi
        finish
    fi

    # sticky/home → перебор резервов транспорта (внутри плагина: xray-configs/*.json и т.п.)
    log "→ перебор резервов $TRANSPORT"
    # Отметка ПОПЫТКИ (не результата) — от неё считает троттл повторов выше. Ставим до вызова:
    # свип может идти минуты, и «с момента прошлой попытки» честнее мерить от её начала.
    date +%s > "$FAILOVER_STAMP"
    if sh "$TRANSPORT_SH" failover "$TRANSPORT" >>"$LOG" 2>&1; then
        off_bail "перебора резервов $TRANSPORT"
        echo HEALTHY > "$XSTATE"
        log "$TRANSPORT-failover: встали на резервный сервер"
        finish
    fi
    off_bail "перебора резервов $TRANSPORT"
    # Аплинк пропал ПОСРЕДИ перебора (плагин его и оборвал) — эскалация ниже бессмысленна, а письмо «резервы недоступны»
    # обвинило бы VPN в аварии провайдера. Уходим, как гейт выше: состояние не трогаем, ждём аплинка.
    ladder_wan_gate "эскалацию после перебора $TRANSPORT"

    # Пул транспорта исчерпан → эскалация. cross → следующий готовый транспорт по реестру
    # (transport.sh next, обычно awg — он первый; в tunnel-only его нет → cross_target пуст
    # → прямой режим, без попыток поднять отсутствующий awg0).
    esc=$(fo_escalate)
    other=$(sh "$TRANSPORT_SH" next "$TRANSPORT")
    if [ "$esc" = "cross" ] && [ -n "$other" ] && ! episode_has "$other"; then
        episode_add "$other"
        log "$TRANSPORT-пул исчерпан → cross: переключаюсь на $other"
        # ПЕРЕХОД ЗАСЧИТЫВАЕТСЯ ПО ФАКТУ — код `switch` И флаг, как фолбэк «Выкл» и возврат домой. Неудачный подъём цели `switch`
        # ОТКАТЫВАЕТ: флаг — на прежний туннель, его несущая — обратно к мёртвому VPS, код 1. А `health <цель>` у НЕАКТИВНОГО
        # транспорта отвечает 0 у ЛЮБОГО плагина («судить не нам»): тик писал «$other жив — остаёмся» при флаге прежнего,
        # HEALTHY/NORMAL на мёртвом туннеле, и через пару тиков лестница заново — switch, у AmneziaWG ещё и awg_setup с firewall
        # reload, каждые ~4 мин и молча (27.09.2026, стенд watchdog-tick-test).
        _xsw=1; _xsvf=0
        tsw "$other" || _xsw=0   # релинквиш tunnel + подъём несущей $other (switch уже записал .transport)
        _xfl=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
        [ "$_xfl" = "$other" ] || _xsw=0
        if [ "$_xsw" = 0 ] && [ "$_xfl" = "$TRANSPORT" ] && HEV_CHECK=1 sh "$TRANSPORT_SH" health "$TRANSPORT" >>"$LOG" 2>&1; then
            # Откат вернул прежний туннель, и его VPS за это время ожил — остаёмся, как в «Выкл»: HEALTHY/NORMAL и починку правил
            # запишет здоровая ветка следующего тика (у перехода один владелец; отставание вердикта — один тик).
            log "cross: $other не поднялся, но сам $TRANSPORT снова везёт — остаёмся на нём"
            revived_event "$(transport_label "$other")"
        elif [ "$_xsw" = 1 ] && HEV_CHECK=1 sh "$TRANSPORT_SH" health "$other" >>"$LOG" 2>&1; then
            # Несущая $other поднята; здоровье — через контракт плагина. Жив → остаёмся.
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: $other жив — остаёмся на нём"
        elif [ "$_xsw" = 1 ] && [ "$other" = "awg" ] && [ -f "$SWITCH_VPN" ] && { _xsvf=1; sh "$SWITCH_VPN" failover >>"$LOG" 2>&1; }; then
            # awg: текущий default-конфиг мёртв → перебор awg-резервов (единый бэкенд switch-vpn;
            # do_failover здесь НЕзачем — он пропустил бы рабочий default по имени).
            off_bail "перебора серверов AmneziaWG"
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: текущий awg мёртв → встали на awg-резерв"
        elif [ "$_xsw" = 1 ] && [ "$other" != "awg" ] && sh "$TRANSPORT_SH" failover "$other" >>"$LOG" 2>&1; then
            # tunnel-цель (hy2/…): перебор её собственных резервов
            off_bail "перебора резервов $other"
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: перебор резервов $other — встали"
        else
            off_bail "перебора резервов $other"
            echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
            if [ "$_xsw" = 1 ]; then log "cross: $other тоже недоступен → прямой режим"
            else log "cross: $other не поднялся (флаг: ${_xfl:-—}) → прямой режим"; fi
            # …и прямой режим обязан быть НАСТОЯЩИМ: switch уже поднял несущую $other (или откат —
            # прежнюю), а health она не прошла — без снятия её default в table 1000 остался бы блэкхол.
            # Чью — говорит ФЛАГ, а не цель: после отката несёт прежний туннель.
            # awg — исключение: его владелец safety_off (снимает маршрут, но awg0 СОЗНАТЕЛЬНО
            # держит тёплым резервом ради детекта оживления по handshake), и .transport=awg ⇒
            # следующий тик идёт awg-веткой, а не сюда.
            # Бэкофф растим и ЗДЕСЬ. Ветка «пул исчерпан» ниже до нас не доходит (cross кончается
            # своим finish), поэтому без этой строки конфигурация «два tunnel-транспорта без awg»
            # (xray+hy2) крутила бы полный свип ОБОИХ пулов каждые FAILOVER_RETRY=10 мин всю
            # аварию — с двумя `switch`, conntrack -F и рестартом dnsmasq, видимыми клиентам.
            # Кап: флаг на awg (цель встала, но не везёт) ⇒ следующий тик пойдёт awg-веткой с её
            # собственным капом FAILOVER_MAX, поэтому сужать лестницу до TUNNEL_RETRY_MAX там
            # незачем (у awg несущая остаётся тёплой — см. коммент к константе).
            if [ "$_xfl" = awg ]; then
                [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
                fo_backoff_bump
            else
                ensure_direct_mode "$_xfl"
                fo_backoff_bump "$TUNNEL_RETRY_MAX"
            fi
            # ПИСЬМО — И ЗДЕСЬ. Прямой режим без cross (ветка ниже) шлёт его на первом отказе, а неудачный cross кончается своим
            # finish, и до ветки с письмом тик не доходил НИКОГДА: следующие тики видят FAILED и эпизод с целью — и молчат. Роутер
            # уходил в прямой режим без единого слова, ровно на самой тяжёлой аварии (хвост 12 ревью dev233). Ключ — тот же
            # `vpn-failopen`: для журнала и «О чём писать» это то же событие, причина — в тексте; окно 0, как у соседних переходов.
            # ТОЛЬКО НА ПЕРЕХОДЕ (`xcur != FAILED`), как у ветки ниже: повтор лестницы по троттлу сбрасывает эпизод, и cross к той
            # же цели идёт заново на КАЖДОМ повторе — без гарда письмо приходило бы каждые 10–30 мин всю аварию. И не вторым:
            # если прямой режим объявил перебор резервов AmneziaWG (`switch-vpn failover`), письмо о нём уже ушло оттуда.
            if [ "$xcur" != FAILED ] && [ "$_xsvf" = 0 ]; then
            _xol=$(transport_label "$other")
            ip=$(ext_ip)
            if [ "$NF_LANG" = en ]; then
                if [ "$_xsw" = 1 ]; then _xwhy="$_xol is unreachable as well"; else _xwhy="$_xol failed to come up"; fi
                failopen_mail "BE7000: $TLABEL and its backups are unreachable -> direct mode" \
"$TLABEL went down and none of its backups came up; switching over to $_xol failed too: $_xwhy.
The router is in DIRECT mode (safety_off): traffic and DNS bypass the VPN — if the ISP link is up,
the internet works; listed sites are unavailable.
External IP now: ${ip:-unknown}.
The watchdog keeps retrying by itself; to bring the VPN back now: panel :8088 -> the VPN card."
            else
                if [ "$_xsw" = 1 ]; then _xwhy="$_xol тоже недоступен"; else _xwhy="$_xol не поднялся"; fi
                failopen_mail "BE7000: $TLABEL и резервы недоступны -> прямой режим" \
"$TLABEL упал, и ни один его резерв не поднялся; переход на другой протокол тоже не удался: $_xwhy.
Роутер в ПРЯМОМ режиме (safety_off): трафик и DNS идут мимо VPN — если связь с провайдером есть,
интернет работает; сайты из списка недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.
Сторож повторит попытку сам; вернуть VPN сразу: панель :8088 -> карточка VPN."
            fi
            fi
        fi
        finish
    fi

    # direct, либо cross но цель уже пробована/отсутствует (анти-петля) → прямой режим.
    # Действуем и уведомляем ТОЛЬКО на переходе (xcur != FAILED): иначе при стойком сбое
    # (tunnel-only / исчерпанный cross) эта ветка крутилась бы каждый тик = спам.
    if [ "$xcur" != FAILED ]; then
        log "$TRANSPORT-пул исчерпан → прямой режим (escalate=$esc)"
        sh "$TRANSPORT_SH" down "$TRANSPORT" >>"$LOG" 2>&1
        [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
        echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
        ip=$(ext_ip)
        if [ "$NF_LANG" = en ]; then
            failopen_mail "BE7000: $TLABEL and its backups are unreachable -> direct mode" \
"$TLABEL went down and none of its backups came up. The router is in DIRECT mode
(safety_off): traffic and DNS bypass the VPN — if the ISP link is up, the internet
works; listed sites are unavailable.
External IP now: ${ip:-unknown}.
To bring the VPN back by hand: panel :8088 -> the VPN card."
        else
        failopen_mail "BE7000: $TLABEL и резервы недоступны -> прямой режим" \
"$TLABEL упал, и ни один его резерв не поднялся. Роутер в ПРЯМОМ режиме
(safety_off): трафик и DNS идут мимо VPN — если связь с провайдером есть,
интернет работает; сайты из списка недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.
Вернуть VPN вручную: панель :8088 -> карточка VPN."
        fi
        # Бэкофф тут НЕ растим: это ПЕРВЫЙ отказ эпизода, и первая повторная попытка должна
        # прийтись на базовые 10 мин (растим со второй — см. ветку ниже).
    else
        # Повторная попытка (по троттлу выше) провалилась. Растим паузу И ОБЯЗАТЕЛЬНО возвращаем
        # прямой режим: ФАЗА 0 плагина внутри failover могла поднять несущую под мёртвый VPS, а
        # письмо/переход здесь уже не повторяются — раньше на этом месте оставался блэкхол.
        fo_backoff_bump "$TUNNEL_RETRY_MAX"
        ensure_direct_mode "$TRANSPORT"
        log "$TRANSPORT-пул исчерпан, остаёмся в прямом режиме (escalate=$esc)"
    fi
    finish
fi

# awg0 ИСЧЕЗ при transport=awg (сюда доходим только с awg/пустым transport — tunnel-ветка
# отработала выше). Раньше тут был безусловный `ip link show awg0 || exit 0`: если демон
# amneziawg-go умер/убит OOM среди дня, TUN-интерфейс awg0 уходит вместе с процессом →
# сторож молча выходил, а heal.sh заперт boot-локом (1×/boot) и НЕ поднимет awg0 до ребута.
# При этом dnsmasq форвардит upstream в дохлый туннель → DNS-SPOF на всю сеть, safety_off
# никто не зовёт. Теперь: если awg установлен и WAN жив — уводим в fail-open (safety_off,
# DNS→публичный: снимаем SPOF немедленно) и СНИМАЕМ heal-лок, чтобы heal на следующем cron-тике
# (*/1) пересоздал awg0 (пересоздание несущей — его зона, не дублируем awg_setup тут). Когда
# handshake вернётся, следующий тик сторожа (ветка «VPS жив», cur=FAILOPEN) вернёт VPN-роутинг.
#
# ТЕКУЩИЙ РЕЖИМ читаем ЗДЕСЬ, а не после блока handshake ниже: ветка «awg0 исчез» сравнивает
# $cur с FAILOPEN, а переменная присваивалась ПОСЛЕ неё ⇒ была пуста ВСЕГДА, «переход» считался
# каждый тик и письмо «awg0 упал» уходило раз в 2 минуты, пока интерфейса нет (тот же класс
# шума, что и повод 03.08.2026; notify() тут прямой, без throttle и без журнала событий).
cur="NORMAL"
[ -f "$STATE" ] && cur=$(cat "$STATE")

if ip link show awg0 >/dev/null 2>&1; then
    # awg0 ЕСТЬ ⇒ будить heal больше не за чем, и счёт попыток обнуляем ЗДЕСЬ — там, где факт
    # наблюдается, а не в хвосте ветки: интерфейс мог вернуть и heal, и человек, и импорт бэкапа
    # (важен ФАКТ, а не автор), а хвост ветки пропускал случай «упал и поднялся между тиками» —
    # три таких флапа съедали бюджет молча (ревью 2, 06.09.2026).
    # `rm` это форк, а строка стоит на быстром пути ⇒ зовём его только когда есть что снимать.
    # МЕТКА В ЭТОМ ЖЕ ГАРДЕ: heal мог уйти по switching-локу и при живом awg0 (человек менял
    # сервер), а счётчика тогда нет вовсе — без второго условия «файл есть» значило бы уже не
    # «после последнего пробуждения», и dump.sh показывал бы её до ребута (ревью 1).
    { [ -e "$HEAL_KICK_CNT" ] || [ -e "$HEAL_SKIPPED" ]; } && heal_kick_reset
else
    if ! wan_up; then exit 0; fi    # WAN опущен: и чинить нечего, и свип выходов дал бы ложные отказы
    # КОМПОНЕНТА НЕТ ВООБЩЕ: `awg.conf` есть (намерение), а бинарей AmneziaWG на роутере не было
    # ни разу — типовой сценарий переезда «свежая установка + импорт бэкапа с другого роутера»
    # (замерено на AX3600 16.08.2026). Пересоздать awg0 нечем, и heal тут бессилен ПО ОПРЕДЕЛЕНИЮ,
    # а прежний код снимал ему лок КАЖДЫЕ две минуты — heal вечно гонял ПОЛНЫЙ бутовый сценарий
    # (cron/мин, до ребута), его вердикт слал письмо «после загрузки VPN НЕ поднялся», и человек
    # искал поломку там, где её нет: ставить надо компонент. Говорим ОДИН раз и называем лечение.
    # Ветку держим ВЫШЕ обычной: ниже awg.conf — единственный гард, и порядок тут и есть смысл.
    if [ -f "$ENODIA_STATE/awg.conf" ] && ! carrier_installed awg; then
        if [ "$cur" != "FAILOPEN" ]; then
            log "transport=awg, но компонент не установлен (бинарей нет) — heal-лок НЕ снимаю, пересоздавать awg0 нечем"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            transport_missing_event AmneziaWG
        fi
        finish
    fi
    if [ -f "$ENODIA_STATE/awg.conf" ]; then
        # HEAL УЖЕ ЗАНЯТ ЭТИМ — но гасим РОВНО ОДНО действие, снятие его лока. Все три ветки ниже
        # кончаются «снимаю heal-лок, heal пересоздаст awg0», и при БЕГУЩЕМ heal это значит «сними
        # лок у того, кто прямо сейчас поднимает интерфейс»: через минуту стартует ВТОРОЙ heal, и
        # его `ip link del awg0` снесёт то, что первый создал (плюс два `firewall reload`).
        # А ВОТ `safety-off` ЖДАТЬ НЕЛЬЗЯ (ревью 3, 06.09.2026): он снимает DNS-SPOF — указатель
        # dnsmasq в туннель, которого нет, — и с бегущим heal не конфликтует вовсе. Прежняя
        # редакция выходила из ветки целиком, оставляя дом без имён на всё время heal (штатно
        # 100–200 с, а у зависшего — до ребута: у heal нет потолка по возрасту лока).
        HEAL_BUSY=0; heal_running && HEAL_BUSY=1
        # «На ЭТОМ тике будить heal отказались» — по нему ниже решается, отдавать ли вопрос
        # лестнице. Судить по самому счётчику нельзя: третий kick делает его равным потолку ПРЯМО
        # СЕЙЧАС, и эскалация случилась бы в том же тике — то есть последнему разбуженному heal
        # не дали бы ни одной попытки (замер стенда, ревью 2, 06.09.2026).
        HEAL_KICK_CAPPED=0
        # $1 = причина для heal. Причину пишем ТОЛЬКО вместе со снятием лока: иначе в файле лежал
        # бы повод для прогона, которого не будет, и следующий — законный — heal взял бы чужой.
        heal_lock_release() {   # снять лок heal — ТОЛЬКО если он не бежит и попытки не исчерпаны
            [ "$HEAL_BUSY" = 1 ] && { log "heal сейчас работает — лок не трогаю, подъём awg0 за ним"; return 0; }
            if ! heal_kick_ok; then
                HEAL_KICK_CAPPED=1
                # В ЛОГ — ОДИН РАЗ (правило файла, см. ветку «пул исчерпан»): повод не
                # меняется часами, а лог живёт в ОЗУ и не ротируется. ПИСЬМО же уходит НИЖЕ, когда
                # станет известно, чем кончилась лестница: иначе человек получал в одном тике три
                # диагноза подряд — «сторож сдался» → «сервер не отвечает» → «перешли на Xray»
                # (ревью 4, 06.09.2026), причём первый протухал через секунды.
                [ -f "$HEAL_KICK_SAID" ] || { : > "$HEAL_KICK_SAID" 2>/dev/null
                    log "снятий heal-лока было $(heal_kick), awg0 так и не создан — дальше не чаще раза в $((HEAL_KICK_SLOW / 60)) мин; резервов $(count_backups), эскалация $(fo_escalate), режим $(fo_mode) — причина не в том, что heal не добежал (смотрите конфиг awg, ключи и бинари)"; }
                return 0
            fi
            heal_kick_add
            # Метку раннего выхода снимаем ТЕМ ЖЕ `rm`: «файл есть» обязано значить «heal ушёл по
            # switching-локу ПОСЛЕ этого пробуждения», а не «когда-то в эту загрузку».
            rm -f "$HEAL_LOCK" "$HEAL_SKIPPED" 2>/dev/null
            heal_reason "$1"
        }
        if [ "$cur" != "FAILOPEN" ]; then
            # ЧИНИМ ОДИНАКОВО, ГОВОРИМ РАЗНОЕ. Действие тут одно (снять DNS-SPOF + отдать heal'у
            # право пересоздать awg0), а вот повод — два: несущая УПАЛА или её ЕЩЁ НЕ ПОДНИМАЛИ
            # (компонент доехал после импорта бэкапа; `packages.sh` ставит, но не активирует).
            # Письмо «awg0 упал» во втором случае описывает падение того, чего не было, и человек
            # ищет аварию вместо того, чтобы просто дождаться heal (замерено на AX3600 17.08.2026:
            # письмо ушло через минуту после установки компонента, а ещё через минуту туннель
            # встал сам). Ответ даёт СВОЁ наблюдение — отметка $AWG0_SEEN, см. её у boot-grace.
            if [ ! -f "$AWG0_SEEN" ]; then
                log "transport=awg, но awg0 в эту загрузку ещё не поднимался (компонент/конфиг приехали позже) → safety_off + снимаю heal-лок; письма нет — это не падение"
                [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
                echo "FAILOPEN" > "$STATE"
                # ПОМЕТКА «ПРЯМОЙ РЕЖИМ ЗДЕСЬ — НАШ И ПЕРВИЧНЫЙ»: heal сейчас поднимет awg0 ВПЕРВЫЕ,
                # и следующий тик увидит свежий handshake при STATE=FAILOPEN — то есть ветку «VPS
                # ОЖИЛ → возврат VPN» с письмом «VPN восстановлен». Восстанавливать нечего: ничего
                # не падало, это штатный бут (в раскладке `bins` — КАЖДЫЙ). Отметка живёт в /tmp и
                # снимается тем же тиком, что её прочитал (ревью 06.09.2026).
                : > "$AWG0_FIRSTUP" 2>/dev/null || true
                heal_lock_release carrier-not-up   # причина СВОЯ: в логе heal видно, что несущую поднимают ВПЕРВЫЕ, а не чинят падение
                finish
            fi
            log "awg0 ИСЧЕЗ при transport=awg → safety_off (снимаю DNS-SPOF)"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            # …а про лок говорит САМ heal_lock_release: при исчерпанном потолке он его не трогает,
            # и обещание «heal пересоздаст awg0» в этой строке было бы ложью (ревью 4).
            heal_lock_release carrier-lost
            ip=$(ext_ip)
            # ЧЕРЕЗ обёртку событий, а не прямым notify: повод повторяемый (демон может падать по
            # OOM раз за разом), а прямое письмо не троттлится и не попадает в «центр уведомлений»
            # панели — человек видел письма, а в истории роутера пусто.
            if [ "$NF_LANG" = en ]; then
                notify_ev "awg0-down" 3600 "BE7000: awg0 went down — direct mode" \
"The awg0 interface is gone (the amneziawg-go daemon died or was killed). The router is
temporarily in DIRECT mode: traffic and DNS bypass the VPN (with a live ISP link the
internet works), listed sites are unavailable.
Auto-recovery of awg0 is running (heal.sh).
External IP now: ${ip:-unknown}."
            else
            notify_ev "awg0-down" 3600 "BE7000: awg0 упал — прямой режим" \
"Интерфейс awg0 исчез (демон amneziawg-go умер/убит). Роутер временно в ПРЯМОМ
режиме: трафик и DNS идут мимо VPN (при живой связи с провайдером интернет
работает), сайты из списка недоступны.
Идёт авто-восстановление awg0 (heal.sh).
Внешний IP сейчас: ${ip:-неизвестен}."
            fi
        else
            heal_lock_release carrier-lost   # уже FAILOPEN — просто дать heal попробовать поднять awg0
            [ "$HEAL_KICK_CAPPED" = 0 ] && log "awg0 всё ещё отсутствует, уже FAILOPEN — жду heal"
        fi
        # ПОТОЛОК ИСЧЕРПАН ⇒ ВОПРОС ОТДАЁМ ЛЕСТНИЦЕ. Зеркало carrier_tries («дальше обычная
        # лестница»): heal трижды прогонял ПОЛНЫЙ бутовый сценарий, а awg0 так и не создался —
        # значит дело не в heal, а в самом awg (конфиг, ключи, бинарь, ядро без модуля), и ждать
        # от него больше нечего. У tunnel-ветки на этом месте начинается перебор резервов и cross,
        # у awg-ветки его не было ВОВСЕ: роутер с исправным установленным xray сидел бы в прямом
        # режиме до ребута — то есть потолок один, без эскалации, менял «долбит вечно» на «молчит
        # вечно» (ревью 2, 06.09.2026). Троттл — ОБЩИЙ с остальной лестницей (fo_retry), эпизод
        # сбрасываем: вдруг за час что-то ожило.
        # `inet_reachable` ОБЯЗАТЕЛЕН перед КАЖДЫМ перебором (инвариант файла, см. шапку): авария у
        # ПРОВАЙДЕРА — типовая причина, по которой awg0 и не создаётся (endpoint не резолвится,
        # рукопожатию не с кем случиться), и без гейта эскалация гоняла бы `do_failover` с его
        # `firewall reload` на каждый резерв ВПУСТУЮ, а потом уводила бы на xray — то есть авария
        # провайдера МОЛЧА переписывала бы выбор транспорта, сделанный человеком (`.transport`
        # переживает ребут). Гейт ещё и шлёт письмо «нет связи с провайдером» вместо ложного
        # «AmneziaWG упал» (ревью 3, 06.09.2026). [[watchdog-wan-gate]]
        # …и «ЕСТЬ ЧТО ПРОБОВАТЬ» — тоже часть гейта: при нулевом пуле резервов и `escalate=direct`
        # ветка не делала НИЧЕГО, но писала в лог «лестница…», а `fo_backoff_bump` следом —
        # «перебор не помог». Два срока рядом (бэкофф и потолок) читались как противоречие, а
        # пробовать было нечего вовсе (ревью 5, 06.09.2026). У cross спрашиваем и ЦЕЛЬ (зеркало
        # ветки «пул исчерпан»): дефолт `escalate=cross` открывал гейт даже там, где переходить
        # НЕ НА ЧТО — свежая установка с одним awg (ревью 6).
        # СЧИТАЕМ ОДИН РАЗ И ТОЛЬКО ПРИ ИСЧЕРПАННОМ ПОТОЛКЕ: `count_backups` форкает `basename` на
        # каждый конфиг, а `cross_target_from_awg` — целый `sh transport.sh next awg`. Оба нужны
        # лишь двум блокам ниже, и оба начинаются с этой же проверки; на прочих тиках (первые три,
        # и всё время, пока heal работает) значения просто выбрасывались бы (ревью 7, 06.09.2026).
        _esc_bk=0; _esc_cr=0; _esc_tgt=
        if [ "$HEAL_KICK_CAPPED" = 1 ]; then
            _esc_bk=$(count_backups)
            [ "$(fo_escalate)" = cross ] && _esc_tgt=$(cross_target_from_awg)
            [ -n "$_esc_tgt" ] && _esc_cr=1
        fi
        if [ "$HEAL_KICK_CAPPED" = 1 ] && [ "$(fo_mode)" != off ] \
           && { [ "$_esc_bk" -ge 1 ] || [ "$_esc_cr" = 1 ]; } \
           && [ "$(stamp_age "$FAILOVER_STAMP")" -ge "$(fo_retry)" ] && inet_reachable; then
            date +%s > "$FAILOVER_STAMP"; episode_reset; episode_add awg
            # Говорим, ЧТО именно есть под рукой (ревью 3): иначе строка читалась в разборе как
            # «лестница отработала и не помогла».
            log "awg0 не создаётся, а heal исчерпан → лестница: резервов $_esc_bk, cross ${_esc_tgt:-нет}"
            if [ "$_esc_bk" -ge 1 ] && [ -f "$SWITCH_VPN" ]; then
                run_failover || cross_awg_to_other || fo_backoff_bump
            else
                cross_awg_to_other || fo_backoff_bump
            fi
            # Слепок ОБНОВЛЯЕМ: перебор переписал конфиги сам (install_config на каждого
            # кандидата), и без этой строки следующий тик принял бы свои же правки за людские.
            heal_cfg_save
            # Ушли на резерв/другой транспорт — бюджет пробуждений больше ни при чём: вернёмся на
            # awg (домашний транспорт, ручной выбор) уже с чистым счётом.
            [ "$(cat "$STATE" 2>/dev/null)" = NORMAL ] && heal_kick_reset
        fi
        # ПИСЬМО «СТОРОЖ ПЕРЕСТАЛ ПЕРЕСОЗДАВАТЬ awg0» — ЗДЕСЬ, В КОНЦЕ, И ТОЛЬКО ЕСЛИ ЛЕСТНИЦА НЕ
        # ПОМОГЛА. Ушли на резерв или другой протокол — человеку уходит своё письмо (failover/cross),
        # и второе, про «сдался», ему только мешает.
        # Говорим РОВНО то, что будет: перебор идёт лишь при включённом failover, cross — только при
        # escalate=cross, и правку конфига сторож заметит СРАЗУ, а бинари/место — на редкой попытке.
        # ОДИН РАЗ ЗА ЭПИЗОД — своим флагом, а не только троттлом notify-event: тик идёт раз в две
        # минуты, и без флага мы бы каждый раз форкали обёртку событий ради заведомого отказа. Флаг
        # снимает `heal_kick_reset`, то есть новый эпизод письмо получит; троттл (NORAISE_THROTTLE,
        # 6 ч) страхует от флапа, при котором эпизод повторяется каждые четверть часа.
        # ГЕЙТ НА ЧУЖУЮ АВАРИЮ: при мёртвом аплинке лестница не идёт (inet_reachable выше), а письмо
        # ушло бы и врало дважды — «проверь конфиг awg» (причина у ПРОВАЙДЕРА) и «интернет есть»
        # (его нет). Спрашиваем УЖЕ ОБЪЯВЛЕННЫЙ эпизод (файл, ноль цены), а не пробу: она платная
        # и сбивала бы гистерезис (ревью 5, 06.09.2026). ПО ВОЗРАСТУ, а не по факту (ревью 6):
        # закрывает эпизод `wan_out_clear` изнутри `inet_reachable`, а в этой ветке она стоит за
        # гейтом лестницы и при `fo_mode=off` не зовётся вовсе — «есть файл» заперло бы письмо до
        # ребута. Свежесть меряем age_since (скачок часов иначе состарил бы эпизод мгновенно).
        if [ "$HEAL_KICK_CAPPED" = 1 ] && [ ! -f "$HEAL_KICK_MAILED" ] \
           && [ "$(stamp_age "$WANOUT_EVENT")" -ge "$WANOUT_FRESH" ] \
           && [ "$(cat "$STATE" 2>/dev/null)" != NORMAL ]; then
            : > "$HEAL_KICK_MAILED" 2>/dev/null || true
            # ЧТО ИМЕННО БУДЕТ — по ФАКТУ, а не по одному тумблеру failover: резервов может не быть
            # вовсе, а cross бывает выключен (`escalate=direct`). Лог это уже говорит честно —
            # письмо обязано говорить то же самое (ревью 5, 06.09.2026).
            # «САМОВОССТАНОВЛЕНИЕ ОТРАБАТЫВАЛО» — ФАКТ, а не вежливая формула, и судим по ДВУМ
            # согласным признакам: лок heal мы сняли, и через две минуты его обязан вернуть сам
            # heal (ЛОК ЕСТЬ ⇒ стартовал), а причину прогона heal СЪЕДАЕТ, дойдя до работы
            # (ПРИЧИНЫ НЕТ ⇒ дошёл). Порознь каждый врёт: лок не появится, если heal вышел по
            # `enodia-switching.lock` (человек меняет сервер), а причину мог снять предыдущий
            # прогон. Оба сразу — это «heal НЕ бежал», типично при снесённой cron-строке
            # (`uninstall.sh deactivate`, потерянный /etc на AX3600). Ревью 5-6, 06.09.2026.
            _nr_heal="и самовосстановление каждый раз отрабатывало."
            _nr_heale="and self-healing did run each time."
            _nr_healok=1
            # …и ТРЕТИЙ признак — «сейчас не идёт переключение»: `heal.sh` смотрит switching-лок
            # РАНЬШЕ, чем берёт свой, и один такой ранний выход даёт оба наших признака разом —
            # совет «проверь cron» ушёл бы при исправном cron (ревью 7). ЧЕТВЁРТЫЙ закрывает ту же
            # дыру ЗАДНИМ ЧИСЛОМ: переключение могло УЖЕ кончиться, и тогда третий признак молчит,
            # а `heal.sh` про свой уход рассказать некому — он и оставляет метку HEAL_SKIPPED.
            if [ ! -e "$HEAL_LOCK" ] && [ -e "$HEAL_REASON" ] && [ ! -e "$SWITCH_LOCK" ] \
               && [ ! -e "$HEAL_SKIPPED" ]; then
                _nr_healok=0
                # ЯРЛЫК — КАК В ПАНЕЛИ. Раздела «Диагностика» в ней нет: cron видно в архиве,
                # который снимает пункт меню «⬇ Скачать диагностику» (ревью 1, 06.09.2026).
                _nr_heal="а самовосстановление после наших попыток так и не запускалось — проверьте строку heal.sh в cron (она есть в архиве «⬇ Скачать диагностику»)."
                _nr_heale="but self-healing never started after our attempts — check the heal.sh cron line (it is in the «Download diagnostics» archive)."
            fi
            # ЧТО СОВЕТОВАТЬ — зависит от того, ЧТО МЫ ВИДЕЛИ. Но ТОЛЬКО когда heal вправду бежал:
            # иначе два вывода подряд противоречат друг другу («до awg дело не дошло» + «значит
            # дело в самом awg»), и человек идёт проверять ключи вместо cron (ревью 6).
            if [ "$_nr_healok" = 0 ]; then
                _nr_why="Про сам AmneziaWG судить рано: до него дело не дошло."
                _nr_whye="It is too early to blame AmneziaWG itself — the recovery never got that far."
            elif [ -f "$AWG0_SEEN" ]; then
                _nr_why="awg0 в эту загрузку уже работал, а теперь не пересоздаётся — чаще всего это нехватка ОЗУ (демона унёс OOM) или занятый флеш; конфиг и ключи тут ни при чём."
                _nr_whye="awg0 was up earlier in this boot and now cannot be recreated — usually that means low RAM (the daemon was OOM-killed) or a full flash; the config and keys are not the cause."
            else
                _nr_why="Значит дело в самом AmneziaWG — проверьте конфиг сервера (ключи, Endpoint), бинари в «Компонентах» и место на флеше."
                _nr_whye="So the problem is AmneziaWG itself — check the server config (keys, Endpoint), the binaries in Components and free flash space."
            fi
            _nr_bk=0; [ "$(fo_mode)" != off ] && [ "$_esc_bk" -ge 1 ] && _nr_bk=1
            _nr_cr=0; [ "$(fo_mode)" != off ] && [ "$_esc_cr" = 1 ] && _nr_cr=1
            _nr_next="Дальше пробую редко — раз в $((HEAL_KICK_SLOW / 60)) мин."
            [ "$_nr_bk" = 1 ] && _nr_next="$_nr_next Параллельно перебираю резервные серверы."
            [ "$_nr_cr" = 1 ] && _nr_next="$_nr_next Если не поможет — перейду на другой протокол."
            _nr_nexte="From now on I retry rarely — once every $((HEAL_KICK_SLOW / 60)) min."
            [ "$_nr_bk" = 1 ] && _nr_nexte="$_nr_nexte Backup servers are tried in parallel."
            [ "$_nr_cr" = 1 ] && _nr_nexte="$_nr_nexte If that does not help, I switch to another protocol."
            if [ "$NF_LANG" = en ]; then
                notify_ev "awg-noraise" "$NORAISE_THROTTLE" "BE7000: AmneziaWG does not come up — the watchdog stopped recreating it" \
"awg0 is not being created (attempts in a row: $(heal_kick)), $_nr_heale
$_nr_whye
The router is in DIRECT mode right now: listed sites bypass the VPN, and with a live ISP link
the internet works.
$_nr_nexte A config change is noticed at once; new binaries or freed space — at the next retry.
Panel: :8088 -> the VPN card."
            else
                notify_ev "awg-noraise" "$NORAISE_THROTTLE" "BE7000: AmneziaWG не поднимается — сторож перестал пересоздавать" \
"Интерфейс awg0 не создаётся (попыток подряд: $(heal_kick)), $_nr_heal
$_nr_why
Роутер сейчас в ПРЯМОМ режиме: сайты из списка идут мимо VPN, и при живой связи с провайдером
интернет работает.
$_nr_next Правку конфига сторож заметит СРАЗУ, а новые бинари или освободившееся место — на
ближайшей редкой попытке. Панель: :8088 -> карточка VPN."
            fi
        fi
    fi
    finish            # доп-выходы несут СВОИ несущие — их здоровье от awg0 не зависит
fi
awg_watchable || finish  # без бинаря awg судить об основном туннеле нечем, а выходы сторожим; тот же гейт — у обещаний возврата вердикта

# Возраст последнего handshake. Считает age_since (clock-lib.sh), а НЕ «now - hs»: часы на роутере
# без RTC прыгают вперёд через ~13 мин после загрузки, и голая разность объявляла живой VPS мёртвым
# (замерено 10.08.2026: «77282с назад» при рукопожатии минуту назад ⇒ лестница failover на ровном
# месте). [[watchdog-clock-step-false-death]]
hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
age=$(age_since "$hs")

if [ "$age" -ge "$HS_DEAD" ]; then
    # ===== VPS не отвечает =====
    # Резолвер — из туннеля вон, по той же причине, что и у tunnel-транспортов: при DoH он заперт
    # маркой в awg0, и молчащий VPS означает дом без DNS. Ветку «интернета нет вообще» это не
    # портит: там DNS всё равно не работает, а правило снимется само на первом здоровом тике.
    doh_follow_carrier suspect
    # Интернета нет ВООБЩЕ → handshake устарел НЕ из-за VPS, а из-за отсутствия аплинка:
    # перебирать awg-резервы и cross-транспорты бессмысленно (все серверы недостижимы), да и
    # reup ниже рвал бы awg0 впустую. Просто ждём аплинк, состояние/маршруты не трогаем (трафика
    # всё равно нет; когда связь и VPS вернутся, handshake оживёт → ветка «VPS жив»).
    if ! inet_reachable; then
        log "VPS handshake устарел (${age}с), но интернета нет вообще — не перебираю, жду аплинка"
        exit 0
    fi
    # ДАЛЬШЕ — НАСТОЯЩАЯ АВАРИЯ (reup, перебор, cross, прямой режим), и её восстановление обязано
    # прийти письмом. Отметка «прямой режим — наше ожидание первого подъёма» с этой секунды лжёт:
    # awg0 подняли, а сервер молчит — это уже не бут, а отказ. Снимаем, иначе возврат из ЭТОГО
    # эпизода прошёл бы молча (ревью 06.09.2026).
    rm -f "$AWG0_FIRSTUP" 2>/dev/null
    # --- Reup: ОДИН переподъём ТЕКУЩЕЙ несущей ПЕРЕД перебором резервов ---
    # ГРАБЛЯ (железо 30.07.2026): «handshake устарел» ≠ «VPS умер». На буте heal поднимает awg0
    # на 39-й секунде аптайма — одновременно с fw3 reload и до того, как сеть устоялась; если
    # первый handshake не прошёл, несущая ЗАЛИПАЕТ (данных через туннель нет ⇒ инициировать
    # рукопожатие нечему), и живой сервер выглядит мёртвым. Сторож честно отрабатывал failover и
    # уводил на резерв, хотя исходный VPS отвечал за секунду — проверено тест-инстансом.
    # Симметрично byedpi (там смерть демона чинится НА МЕСТЕ через reup_carrier, а cross — только
    # если не вышло): сперва пересоздаём awg0 из ТЕКУЩЕГО конфига (конфиг НЕ меняем — это не
    # failover), и лишь если handshake так и не пришёл, идём по лестнице резервов.
    # Троттл обязателен: reup рвёт awg0 на несколько секунд, крутить его каждый тик нельзя.
    # Гейт [ -f awg.conf ]: без конфига пересоздавать нечего (hy2/xray-only установка).
    if [ "$cur" != "FAILOPEN" ] && [ -f "$ENODIA_STATE/awg.conf" ] && [ -f "$TRANSPORT_SH" ] \
       && [ "$(stamp_age "$REUP_STAMP")" -ge "$REUP_RETRY" ]; then
        wd_switch_take "переподъём awg0"   # ДО отметки: при ручной смене попытка не потрачена
        date +%s > "$REUP_STAMP"
        # Часы сверит сам плагин в `up` (transport-awg cmd_up → clock_boot_sync): с отставшими
        # часами сервер отбрасывает рукопожатие как повтор, и reup повторял бы тот же отказ (замер
        # 05.09.2026 — 42 с впустую, потом failover). Сдвиг переносит и REUP_STAMP (clock_rebase_stamps).
        log "handshake ${age}с → сперва ОДИН переподъём awg0 (резервы — только если не поможет)"
        ip link del awg0 2>/dev/null
        sh "$TRANSPORT_SH" up awg >>"$LOG" 2>&1
        wd_switch_drop
        off_bail "переподъёма awg0"
        i=0
        while [ "$i" -lt 25 ]; do
            sleep 1
            hs2=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$hs2" in
                ''|0) ;;
                *)  if [ "$(age_since "$hs2")" -lt "$HS_DEAD" ]; then
                        log "reup помог: handshake вернулся на текущем конфиге — резервы не трогаю"
                        finish
                    fi ;;
            esac
            i=$((i + 1))
        done
        log "reup не помог (handshake так и не пришёл) — иду по лестнице failover"
    fi
    mode=$(fo_mode)
    nbk=$(count_backups)
    if [ "$cur" != "FAILOPEN" ]; then
        # --- переход: VPS только что умер --- (новый эпизод аварии)
        episode_reset; episode_add awg; date +%s > "$FAILOVER_STAMP"
        if [ "$mode" != "off" ] && [ "$nbk" -ge 1 ] && [ -f "$SWITCH_VPN" ]; then
            # есть awg-резервы → перебор (письма шлёт switch-vpn); awg-пул исчерпан →
            # cross на другой транспорт (вариант A), иначе остаёмся в прямом режиме.
            log "VPS МЁРТВ (handshake ${age}с) → failover (режим=$mode, резервов=$nbk)"
            run_failover || cross_awg_to_other || fo_backoff_bump
        elif [ "$mode" != "off" ] && [ "$(fo_escalate)" = "cross" ] && [ -n "$(cross_target_from_awg)" ]; then
            # failover включён, awg-резервов нет → сразу cross на другой транспорт (A)
            log "VPS МЁРТВ (handshake ${age}с), awg-резервов нет → cross на другой транспорт"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            cross_awg_to_other || fo_backoff_bump
        else
            # режим off, либо нет ни awg-резервов, ни другого транспорта — классический fail-open
            log "VPS МЁРТВ (handshake ${age}с) → прямой режим (режим=$mode, резервов=$nbk)"
            [ -f "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            active=$(cat "$ACTIVE_NAME" 2>/dev/null)
            ip=$(ext_ip)
            # «vpn-toggle меню → 9» — пункт из времён, когда сервером управляли по SSH. Сейчас
            # сервер меняют в панели, и совет вёл в никуда именно тогда, когда он нужен.
            if [ "$NF_LANG" = en ]; then
                failopen_mail "BE7000: the VPN went down, direct mode" \
"The VPS does not answer (last handshake ${age} s ago).
Config: ${active:-?}.

The router switched to DIRECT mode: traffic and DNS bypass the VPN — if the ISP
link is up, the internet works; listed sites are temporarily unavailable.
External IP now: ${ip:-unknown}.

When the VPS comes back, the VPN returns automatically and a second email
arrives. If the VPS stays down for long — check it, or switch the server:
panel :8088 -> the VPN card."
            else
            failopen_mail "BE7000: VPN упал, прямой режим" \
"VPS не отвечает (последний handshake ${age} сек назад).
Конфиг: ${active:-?}.

Роутер перешёл в ПРЯМОЙ режим: трафик и DNS идут мимо VPN — если связь
с провайдером есть, интернет работает; сайты из списка временно недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.

Когда VPS снова заработает, VPN вернётся автоматически и придёт
второе письмо. Если VPS долго не оживает — проверьте его или смените
сервер: панель :8088 -> карточка VPN."
            fi
        fi
    else
        # --- уже FAILOPEN: периодически (троттл) пробуем восстановиться заново ---
        # Каждый ретрай = свежая попытка ВСЕЙ лестницы (awg-пул + cross на другой транспорт):
        # сбрасываем эпизод-гард, вдруг что-то ожило. Без флаппинга — раз в FAILOVER_RETRY.
        # Пауза между свипами РАСТЁТ (fo_retry: 10→20→40→80→120 мин), пока попытки безуспешны —
        # иначе исчерпанный пул перебирается всю ночь в одном ритме (повод 03.08.2026).
        if [ "$mode" != "off" ] && [ "$(stamp_age "$FAILOVER_STAMP")" -ge "$(fo_retry)" ]; then
            date +%s > "$FAILOVER_STAMP"; episode_reset; episode_add awg
            log "VPS всё ещё мёртв (${age}с), FAILOPEN → повторная попытка восстановления"
            if [ "$nbk" -ge 1 ] && [ -f "$SWITCH_VPN" ]; then
                run_failover || cross_awg_to_other || fo_backoff_bump
            else
                cross_awg_to_other || fo_backoff_bump
            fi
        else
            log "VPS всё ещё мёртв (${age}с), уже FAILOPEN — без изменений (следующая попытка через $(( ($(fo_retry) - $(stamp_age "$FAILOVER_STAMP")) / 60 )) мин)"
        fi
    fi
elif awg_hs_alive "$age"; then
    # ===== VPS жив =====
    # Туннель здоров ⇒ прошлый reup-троттл своё отработал: снимаем штамп, чтобы СЛЕДУЮЩАЯ авария
    # снова получила попытку «починить на месте», а не упёрлась в остаток получасового окна.
    rm -f "$REUP_STAMP" 2>/dev/null
    health_back   # бэкофф перебора, «интернета нет» и (продержавшись) «прямой режим» закрыты: handshake свежий ⇒ аплинк жив
    doh_follow_carrier ok       # awg0 везёт ⇒ резолвер можно вернуть в туннель
    if [ "$cur" = "FAILOPEN" ] && [ -f "$AWG0_FIRSTUP" ]; then
        # ПЕРВЫЙ ПОДЪЁМ, А НЕ ВОЗВРАТ. FAILOPEN сюда поставили МЫ же — веткой «awg0 в эту загрузку
        # не поднимался» (отметку кладёт она), а heal тем временем несущую поднял. Маршрут и DNS
        # поставил его `transport.sh up`, значит чинить нечего: снимаем отметку, пишем NORMAL и
        # молчим. Письмо «VPN восстановлен» тут описывало бы аварию, которой не было, — и приходило
        # бы на КАЖДОМ буте раскладки `bins` (ревью 06.09.2026).
        # НО «NORMAL» — ЭТО СОСТОЯНИЕ ЯДРА, А НЕ СТРОКА В ФАЙЛЕ (тот же инвариант, что у возврата из
        # fail-open). Отметку ставила ветка, которая перед этим позвала `safety-off` — а он снял И
        # маршрут, И `ip rule fwmark→1000`. Что heal их вернул, ничем не гарантировано: он не
        # проверяет код `transport.sh up`, а awg0 создаёт ОТДЕЛЬНОЙ секцией, которая живёт и без
        # 5.6. Напиши мы NORMAL вслепую — трафик идёт мимо туннеля, и это не починит НИКТО: все три
        # rule-heal'а ниже требуют либо маршрут, либо правило (ревью 3, 06.09.2026). Проверяем и
        # чиним идемпотентным restore_awg_carrier.
        if [ -z "$(carrier_route_dev)" ] || ! carrier_rule_present; then
            log "awg0 поднят ВПЕРВЫЕ, но ядро не восстановлено (маршрут/ip rule) — возвращаю несущую"
            restore_awg_carrier
        fi
        rm -f "$AWG0_FIRSTUP" 2>/dev/null
        echo "NORMAL" > "$STATE"; episode_reset
        log "awg0 поднят ВПЕРВЫЕ в эту загрузку (handshake ${age}с назад) — прямой режим был нашим ожиданием, а не аварией: NORMAL, письма нет"
    elif [ "$cur" = "FAILOPEN" ]; then
        log "VPS ОЖИЛ (handshake ${age}с назад) → возврат VPN"
        # 1) awg-несущая обратно: mark-core + transport-awg.sh up (default dev awg0 +
        #    FORWARD + MASQUERADE + туннельный DNS). Замена ретайрнутого split-route.sh.
        restore_awg_carrier
        # 2) DNS-upstream. ВЛАДЕЛЕЦ ОДИН — плагин: `restore_awg_carrier` выше уже позвал
        #    `transport-awg.sh up` → `restore_vpn_dns`, а тот ПЕРВОЙ строкой спрашивает
        #    `doh_apply_dns tunnel`. Здесь жил дубль мимо этого вопроса (ровно тот, что вырезали из
        #    switch-vpn.sh на ревью батча 4): он переписывал 00-upstream.conf туннельным адресом
        #    поверх 127.0.0.1#5053 и МОЛЧА выключал шифрованный DNS на каждом возврате из FAILOPEN.
        #    Починить это было некому — `doh_start` бежит, только когда демон УПАЛ, а он жив;
        #    панель при этом продолжала показывать «Шифрованный DNS: включён».
        #    Маршрут к резолверу и рестарт dnsmasq делает тот же `restore_vpn_dns` — второй раз не надо.
        if [ ! -f "$XT_AWG" ]; then
            # Старый layout без плагина: владельца DNS нет, пишем сами — как было.
            VPN_DNS=$(grep -E '^DNS\s*=' "$ENODIA_STATE/awg.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
            [ -z "$VPN_DNS" ] && VPN_DNS=172.29.172.254
            ip route replace "$VPN_DNS/32" dev awg0 2>/dev/null
            dns_upstream_put "$VPN_DNS"
        fi
        echo "NORMAL" > "$STATE"; episode_reset   # эпизод аварии закрыт
        ip=$(ext_ip)
        if [ "$NF_LANG" = en ]; then
            notify_ev "vpn-restored" 0 "BE7000: the VPN is back" \
"The VPS answers again (last handshake ${age} s ago).
VPN routing and DNS through the tunnel are restored.
External IP: ${ip:-unknown}."
        else
        notify_ev "vpn-restored" 0 "BE7000: VPN восстановлен" \
"VPS снова отвечает (последний handshake ${age} сек назад).
Вернул VPN-роутинг и DNS через туннель.
Внешний IP: ${ip:-неизвестен}."
        fi
        vpn_ok_mailed   # эпизод аварии закрыт письмом: следующее падение — снова письмо
    else
        # Rule-heal: awg жив (handshake свежий) + NORMAL, но fw3-reload мог снести FORWARD/сплит
        # (mipctld-guard вернул бы лишь маркировку, не FORWARD несущей) → переиграть правила.
        # [[boot-race-fw3-reload-wipes-rules]]
        split_rules_wiped awg && heal_split_rules awg
        # …и вторая половина того же вопроса: правила на месте, а САМ МАРШРУТ несущей пропал
        # (table 1000 пуста) ⇒ маркированный трафик молча идёт напрямую. См. carrier_route_lost.
        carrier_route_lost awg && heal_carrier_route awg
        # …и ТРЕТЬЯ половина того же вопроса: маршрут на месте, а `ip rule fwmark→1000` пропал ⇒
        # метка никуда не ведёт, трафик идёт мимо туннеля при зелёном статусе. См. carrier_rule_lost.
        carrier_rule_lost awg && heal_carrier_rule awg
        # ===== уже NORMAL: в режиме home пробуем вернуться на основной =====
        # После прошлого failover мы можем работать на РЕЗЕРВНОМ конфиге. Если
        # режим home и активный != основного — раз в FAILBACK_INTERVAL проверяем,
        # ожил ли основной: ping его Endpoint (НЕ срывая рабочий резерв), и при
        # успехе зовём switch-vpn <home> (он сам проверит handshake и при неудаче
        # откатится на текущий резерв). ICMP-проба — чтобы не дёргать рабочий
        # туннель впустую; если VPS блокирует ICMP, авто-возврат не сработает —
        # вернуться можно вручную (меню 9).
        home_t=$(transport_home)
        if fo_home_transport_back awg \
           && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
            # ===== home-транспорт = tunnel (xray/hy2), а мы на awg (после cross) → вернуться на него =====
            # Reality/маскирующиеся туннели НЕ отвечают на ICMP и неотличимы по TCP (под HTTPS)
            # → «ожил ли сервер» надёжно проверяется ТОЛЬКО подъёмом транспорта + egress-пробой.
            # Делаем редко (FAILBACK_INTERVAL) и откатываемся на awg, если не встал. Это
            # opt-in (mode=home): краткая просадка раз в интервал, пока домашний транспорт мёртв.
            home_lbl=$(transport_label "$home_t")
            date +%s > "$FAILBACK_STAMP"
            log "home-transport: проба возврата на домашний $home_lbl (подъём + egress-проба)"
            # ВЕРНУЛИСЬ ЛИ — ПО ФАКТУ, И В ТРИ ШАГА. `health` у альтов отвечает 0, когда транспорт НЕ АКТИВЕН (xray-
            # transport.sh: «здоров ИЛИ не xray»), а неудачный подъём оркестратор откатывает сам: флаг снова awg, код 1.
            # Судили бы одним health — не поднявшийся дом читался бы «вернулись»: HEALTHY, а с 16.09.2026 ещё и
            # письмо с событием о возврате раз в FAILBACK_INTERVAL, пока дом мёртв (ревью шага 3c-2, круг 1).
            _fb_ok=1
            tsw "$home_t" || _fb_ok=0   # оркестратор: релинквиш awg + mark-core + подъём $home_t
            [ "$_fb_ok" = 1 ] && [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" = "$home_t" ] || _fb_ok=0
            if [ "$_fb_ok" = 1 ] && HEV_CHECK=1 sh "$TRANSPORT_SH" health "$home_t" >>"$LOG" 2>&1; then
                echo HEALTHY > "$XSTATE"; log "home-transport: вернулись на $home_lbl"
                failback_event transport "$home_lbl"
            else
                # Назад на AmneziaWG — только если флаг не там: неудачный подъём оркестратор УЖЕ откатил сам, и второй
                # `switch awg` лишь переигрывал бы маркировку, рестарт dnsmasq и сброс соединений раз в FAILBACK_INTERVAL
                # (ревью шага 3c-2, круг 2). Подъём удался, а проверка — нет: флаг на доме, и возвращаем честно.
                [ "$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')" = awg ] || tsw awg
                log "home-transport: $home_lbl ещё мёртв — остаёмся на awg"
            fi
        elif [ "$(fo_mode)" = "home" ]; then
            home=$(failover_home_name)
            active=$(cat "$ACTIVE_NAME" 2>/dev/null)
            if fo_awg_server_away \
               && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
                date +%s > "$FAILBACK_STAMP"
                ep=$(grep -E '^Endpoint' "$CONFIGS_DIR/$home.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//' | tr -d ' ')
                if [ -n "$ep" ] && ping -c 1 -W 2 "$ep" >/dev/null 2>&1; then
                    log "home-failback: основной '$home' (endpoint $ep) ожил → возврат"
                    # Вернулись ли — по ФАКТУ `.active`, а не по попытке: пинг домашний принял, а рукопожатия
                    # не дал — switch-vpn откатывается на резерв сам (и пишет своё событие об откате).
                    if sh "$SWITCH_VPN" "$home" >>"$LOG" 2>&1 && [ "$(cat "$ACTIVE_NAME" 2>/dev/null)" = "$home" ]; then
                        failback_event server "$home"
                    fi
                else
                    log "home-failback: основной '$home' ещё недоступен — остаёмся на '$active'"
                fi
            fi
        fi
    fi
fi
# Зона ${HS_ALIVE}..${HS_DEAD} — гистерезис, режим не трогаем.

# --- ХВОСТ ТИКА: сюда доходят awg-ветки (NORMAL/FAILOPEN/гистерезис), которые НЕ вышли раньше ---
# Выход ТОЛЬКО через finish(), как и у всех прочих путей. ГРАБЛЯ (ревью 09.08.2026): раньше здесь
# стоял голый `slot_health_sweep; exit 0` — свипы перечислялись ВТОРОЙ копией, и всё, что дописали
# в finish() позже, на awg просто не бежало. Цена: на каноничном роутере (.transport=awg) тик
# живости авто-DoH не выполнялся НИ РАЗУ — в том числе в fail-open, где авто-DoH как раз и
# взводится (safety_off → doh_apply_dns direct), то есть ровно в сценарии, ради которого он
# написан; тем же путём терялся периодический прогрев доменных правил. Новый свип дописывают
# в finish() и НИКОГДА сюда.
finish
