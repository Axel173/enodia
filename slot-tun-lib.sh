#!/bin/sh
# slot-tun-lib.sh — ОБЩИЙ per-slot слой tun2socks для доп-выходов (слотов мульти-транспорта).
#
# ЗАЧЕМ. Три транспорта несут слот ОДИНАКОВО: локальный socks-провайдер (ciadpi / xray /
# hysteria) + свой hev-socks5-tunnel → свой TUN → своя table 100N. Отличается ТОЛЬКО кто
# слушает socks. Первым это получил byedpi (Ф1c), и копировать те же 10 функций ещё в
# xray-transport.sh и transport-hy2.sh (Ф3) означало бы три расходящиеся копии — ровно та
# грабля, из-за которой resolve_ipv4 вынесли в dns-lib.sh, а probe_ext_ip — в ip-lib.sh.
# Здесь живёт ВСЁ, что не зависит от протокола: имена/порты/пути слота, per-slot hev.yaml,
# подъём и снятие hev, ожидание socks, карриер-маршрутизация.
#
# КОНТРАКТ ВЫЗЫВАЮЩЕГО (плагин транспорта определяет ДО `. slot-tun-lib.sh`):
#   ENODIA_DIR     — корень установки;
#   HEV         — путь к бинарю hev-socks5-tunnel;
#   SOCKS_ADDR  — адрес локального socks (127.0.0.1);
#   log()       — вывод в лог плагина;
#   proc_alive() — «жив ли pid из пидфайла» (пустой пидфайл = НЕ жив, см. грабли плагинов);
#   daemon_wait_port()/daemon_wait_dev() — ожидание старта демона (daemon-lib.sh или шим плагина):
#     срок старта зависит от НОСИТЕЛЯ бинаря, и держать вторую копию этого знания здесь нельзя.
# Библиотека НЕ имеет собственных дефолтов для них СОЗНАТЕЛЬНО: молчаливый дефолт замаскировал
# бы неполный source (плагин без ENODIA_DIR не должен «почти работать» на чужих путях).
#
# ЧЕГО ЗДЕСЬ НЕТ (и почему):
#   * DNS — один dnsmasq на роутер, upstream ведёт ОСНОВНОЙ транспорт (дизайн §DNS);
#   * MASQUERADE — tun2socks ТЕРМИНИРУЕТ соединение на роутере (наружу идёт от него же);
#   * ip rule (fwmark 0xN → table 100N) — владелец ОДИН: mark-core.sh (fallback-aware);
#     плагин после slot-up/slot-down лишь просит transport.sh переиграть маркировку;
#   * анти-петля — протокол-специфична (endpoint-bypass у awg/xray/hy2, owner-RETURN у byedpi).
#
# ПОРТЫ. socks слота = SLOT_SOCKS_BASE+id (10832..10834). Один id = РОВНО один транспорт
# (реестр slots.sh), поэтому общая база для всех плагинов не создаёт коллизий, а совпадение
# с чужим (осиротевшим после смены транспорта слота) демоном лечит slot_free_socks.
# Диапазон 10812..10819 намеренно НЕ трогаем — там throwaway-инстансы xray-test.sh.

# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w` (ENODIA_DIR даёт
# вызывающий — см. контракт выше). Плагины сорсят её и сами, повторный source безвреден; здесь он
# ради того, чтобы карриер-маршруты слота не зависели от полноты чужого пролога. Нет файла —
# прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# Нет ipt-lib.sh с `ipt_top` (частичное обновление) ⇒ прежнее «первым в цепочку», байт-в-байт.
command -v ipt_top >/dev/null 2>&1 || ipt_top() { _itc=$1; shift; iptables -C "$_itc" "$@" 2>/dev/null || iptables -I "$_itc" 1 "$@"; }

: "${ENODIA_STATE:=/data/usr/app/enodia-state}"

SLOT_SOCKS_BASE=10830

slot_socks_port() { echo $(( SLOT_SOCKS_BASE + $1 )); }   # id 2 -> 10832 ...
slot_tun()        { echo "xtun$1"; }
slot_table()      { echo "100$1"; }
slot_hev_pid()    { echo "/tmp/enodia-hev-s$1.pid"; }
slot_hev_log()    { echo "/tmp/enodia-hev-s$1.log"; }
slot_hev_yaml()   { echo "$ENODIA_STATE/hev-s$1.yaml"; }

# per-slot hev.yaml: свой tun/порт/ipv4. 198.18.<id>.1 — бенчмарк-диапазон (RFC 2544), не
# пересекается ни с LAN, ни с реальными сетями ⇒ адрес TUN слота ничего не затеняет.
slot_write_hev_yaml() {   # $1 = id
    _id="$1"
    cat > "$(slot_hev_yaml "$_id")" <<YAML
tunnel:
  name: xtun$_id
  mtu: 8500
  ipv4: 198.18.$_id.1
socks5:
  port: $(slot_socks_port "$_id")
  address: 127.0.0.1
  udp: 'udp'
misc:
  log-file: $(slot_hev_log "$_id")
  log-level: warn
YAML
}

# Дождаться, пока socks-порт слота начнёт слушать. Ждать «пока жив процесс, но не дольше
# потолка» умеет ОДИН владелец — daemon_wait_port (daemon-lib.sh): срок зависит от носителя
# бинаря, а слот и основная несущая отличаются здесь только пидфайлом.
# Пустой $2 = вызов из ПЛАГИНА ПРОШЛОЙ СБОРКИ (дрейф деплоя: библиотека новее плагина) — судить
# по процессу нечем, работаем прежним фиксированным сроком, а не отказываем на пустом пидфайле.
slot_wait_socks() {   # $1 = порт ; $2 = пидфайл демона слота ; $3 = имя бинаря ; $4 = срок на флеше (деф. 8)
    # СУДИМ ПО ФОРМЕ ВТОРОГО АРГУМЕНТА, а не по его пустоте. У ПРЕЖНЕЙ подписи там шло ЧИСЛО
    # попыток (`slot_wait_socks <порт> <попыток>`), и проверка «непусто ⇒ это пидфайл» увела бы
    # старый вызов в новый путь с пидфайлом «8»: `cat 8` пуст, и через три секунды мы объявили бы
    # «процесс НЕ ЗАПУСТИЛСЯ» про живой демон — то есть ветка совместимости не работала бы ровно
    # в том случае, ради которого написана. Пидфайл — всегда абсолютный путь, число — никогда.
    case "$2" in
        /*) daemon_wait_port "$2" "$3" "${4:-8}" "$SOCKS_ADDR" "$1"; return $? ;;
    esac
    _p="$1"; _t="${2:-8}"; _i=0
    # fixed-wait: пидфайла не дали — судить по процессу НЕЧЕМ. Сознательно ПРЕЖНИЙ путь для
    # плагина из старой сборки (см. шапку функции); новый код сюда не попадает никогда.
    while [ "$_i" -lt "$_t" ]; do
        netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$_p " && return 0
        sleep 1; _i=$((_i+1))
    done
    netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$_p "
}

# Освободить socks-порт слота, если его держит ЧУЖОЙ pid. Причина та же, что у основного
# free_foreign_socks: осиротевший демон (смена транспорта слота, оборванный рестарт) держит
# порт → наш socks-провайдер не забиндит и молча умрёт, а netstat увидит ЧУЖОГО слушателя →
# «поднялся» вернулось бы ЛОЖНО, и трафик выхода пошёл бы через чужой протокол/сервер.
slot_free_socks() {   # $1 = id ; $2 = пидфайл СВОЕГО socks-провайдера
    _port=$(slot_socks_port "$1"); _own=$(cat "$2" 2>/dev/null | tr -d ' \r\n')
    _holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$_port " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$_holder" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_holder" = "$_own" ] && return 0
    log "слот №$1: socks $_port держит чужой pid $_holder — освобождаю"
    kill "$_holder" 2>/dev/null
    _i=0; while [ $_i -lt 5 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$_port " || break; sleep 1; _i=$((_i+1)); done
}

# Держит ли socks-порт слота ИМЕННО наш демон? «Порт слушает» ≠ «слушает тот, кого мы запустили»:
# при перезапуске демона слота (смена стратегии/конфига) уходящий предшественник ещё держит бинд
# несколько секунд, новый в этот момент не стартует — и проверка по одному netstat отрапортовала бы
# успех, хотя через миг socks исчезнет вместе с ним. Нет netstat -p или держатель не определился →
# считаем «наш»: диагностики нет, ронять из-за этого рабочий путь нельзя.
slot_socks_is_ours() {   # $1 = port ; $2 = свой пидфайл
    _own=$(cat "$2" 2>/dev/null | tr -d ' \r\n')
    [ -n "$_own" ] || return 1
    _holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$1 " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$_holder" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_holder" = "$_own" ]
}

# Поднять hev слота (tun2socks → socks слота) и дождаться появления TUN. Идемпотентно
# (жив — не трогаем): watchdog зовёт slot-up повторно для reup. 0 = TUN есть.
slot_hev_up() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id")
    [ -x "$HEV" ] || { log "слот №$_id: НЕТ бинаря hev ($HEV)"; return 1; }
    slot_write_hev_yaml "$_id"
    if ! proc_alive "$(slot_hev_pid "$_id")"; then
        log "слот №$_id: запускаю hev (tun2socks -> $_tun)…"
        start-stop-daemon -S -b -m -p "$(slot_hev_pid "$_id")" -x "$HEV" -- "$(slot_hev_yaml "$_id")"
    fi
    daemon_wait_dev "$(slot_hev_pid "$_id")" hev 6 "$_tun" || {
        log "слот №$_id: tun $_tun не создан ($DAEMON_WAIT_WHY). Лог hev:"; tail -n 15 "$(slot_hev_log "$_id")" 2>/dev/null; return 1; }
    return 0
}

# Снять hev слота. hev держит xtunN как НЕ-persistent tun ⇒ устройство уходит вместе с ним,
# но -K НЕ блокирует, поэтому ждём исчезновения (и добиваем явным del, если tun пережил hev).
# Пидфайл убираем, чтобы не копить stale (риск попасть в переиспользованный pid).
slot_hev_down() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id")
    _hdp=$(cat "$(slot_hev_pid "$_id")" 2>/dev/null | tr -d ' \r\n')
    start-stop-daemon -K -p "$(slot_hev_pid "$_id")" 2>/dev/null
    # -K возвращается ДО смерти (daemon-lib.sh daemon_wait_gone): перезапуск на месте (slot_hev_path_check) стартовал бы новый hev
    # на то же имя xtunN, пока старый его ещё держит. Нет библиотеки — прежний путь.
    # …и TERM не услышан — KILL (новый hev на то же имя рядом с сиротой: ревью с.93, круг 3).
    if command -v daemon_wait_gone >/dev/null 2>&1 && [ -n "$_hdp" ] && ! daemon_wait_gone "$_hdp" 5; then
        { ! command -v pid_runs >/dev/null 2>&1 || pid_runs "$_hdp" hev; } && { kill -9 "$_hdp" 2>/dev/null; daemon_wait_gone "$_hdp" 3; }
    fi
    _i=0
    while ip link show "$_tun" >/dev/null 2>&1 && [ "$_i" -lt 6 ]; do
        ip link del "$_tun" 2>/dev/null
        ip link show "$_tun" >/dev/null 2>&1 || break
        sleep 1; _i=$((_i+1))
    done
    rm -f "$(slot_hev_pid "$_id")" 2>/dev/null
}

# Карриер-часть слота: default dev xtunN в table 100N + FORWARD ACCEPT (у fw3 policy FORWARD=DROP).
# БЕЗ MASQUERADE (см. шапку). ip rule ставит mark-core — тут только своя таблица и своё устройство.
slot_apply_routing() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id"); _tab=$(slot_table "$_id")
    ip link set "$_tun" up 2>/dev/null
    ipt_top FORWARD -o "$_tun" -j ACCEPT
    ipt_top FORWARD -i "$_tun" -j ACCEPT
    ip route replace default dev "$_tun" table "$_tab"
}
slot_remove_routing() {   # $1 = id
    _id="$1"; _tun=$(slot_tun "$_id"); _tab=$(slot_table "$_id")
    ip route flush table "$_tab" 2>/dev/null || true
    iptables -D FORWARD -o "$_tun" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$_tun" -j ACCEPT 2>/dev/null
}

# ===== ЗАЛИПШИЙ hev: путь клиентов TUN → hev → socks (общий слой: hev у трёх плагинов, и у основной несущей, и у выходов) =====
# ЗАЧЕМ. health плагинов меряет egress ЧЕРЕЗ SOCKS — прямо в демон протокола, МИМО hev. Залипший hev (процесс жив, TUN поднят,
# а в туннель он пишет с ошибками) так невидим: тестер 15.09.2026 — 9 дней `socks5 tunnel write` в логе hev, YouTube не выше 720p,
# и «здоров» на каждом тике; перезапуск hev вылечил. ПРИЗНАКОВ ДВА, и ловят они разное:
#   * путь МЁРТВ — проба `--interface <TUN>` идёт ровно путём клиента (пакет роутера, привязанный к TUN, читает hev и несёт в
#     socks; замер BE7000 02.10.2026: socks и xtun отдают один и тот же выход) и молчит. Промах ПОДТВЕРЖДАЕМ второй пробой.
#   * путь МЕДЛЕННЫЙ — случай тестера: маленький запрос проходит, а hev сыплет `socks5 tunnel write` (так он пишет НЕУДАВШУЮСЯ
#     запись в TUN). Проба такое не видит, видит лог (уровень warn — строка в нём есть). НОРМА ЗАМЕРЕНА (BE7000, hev 2.17.1,
#     02.10.2026): живой трафик дома и 1.7 ГБ закачек за 40 с с обрывами клиентом — НОЛЬ строк. Значит, поток строк — признак
#     беды, а не фон, и порог берём низким, но сам перезапуск не дёшев (ниже) ⇒ два окна подряд и не чаще раза в HEV_RESTART_GAP.
# Зовут ТОЛЬКО после прошедшей socks-пробы: сервер жив ⇒ виноват именно hev, и лечение — перезапуск hev на месте, а не перебор
# серверов. Каждый перезапуск — событие `hev-restart` в журнале: причина у тестера не изолирована, и совпадение срабатываний с
# жалобами — единственный дешёвый способ её доказать.
# ПЕРЕЗАПУСК НЕ ДЁШЕВ: TUN пересоздаётся, conntrack сбрасывается — установленные соединения дома рвутся. Поэтому (ревью с.93):
#   * ОСНОВНУЮ несущую судим только по просьбе ТИКА сторожа (`HEV_CHECK=1` у его главного health): тот же `cmd_health` проверяет
#     КАЖДОГО кандидата перебора резервов и прогрев, и каждый мёртвый путь там был бы перезапуском hev и сбросом соединений дома —
#     на 60–70 конфигах подписки (путь от сервера не зависит, сменой сервера его не вылечить). Дамп (`dump.sh`) тоже зовёт health —
#     без просьбы он улик не трогает. У выходов `slot-health` зовёт только свип сторожа;
#   * перезапуск — не чаще раза в HEV_RESTART_GAP при ЛЮБОМ признаке: путь мёртв и после перезапуска — health «нездоров», и дальше
#     лестница сторожа (cross, прямой режим), а не перезапуск каждые две минуты;
#   * перезапуск — под ЛОКОМ СМЕНЫ ТРАНСПОРТА со своим пидом (как подъём несущей сторожем, watchdog.sh::wd_switch_take): панель,
#     переключающая транспорт в ту же минуту, ждёт живого держателя (cgi `hold_switch`), а занятый чужой лок — повод hev не трогать:
#     иначе `start_daemons` поднял бы снятые демоны и вернул `default dev xtun` поверх новой несущей.
HEV_WERR_MIN=5          # строк `socks5 tunnel write` на 2 минуты (окно — от вызова до вызова, тик сторожа = 2 мин)
HEV_WERR_WINDOWS=2      # окон подряд: одиночная пачка (обрыв на сервере, пересоздание TUN) лечения не стоит
HEV_RESTART_GAP=1800    # с: перезапуск — не чаще; не помог — повтор каждые 4 минуты лишь рвал бы соединения дома
HEV_SWLOCK=${SWITCH_LOCK:-/tmp/enodia-switching.lock}
# Отметки hev живут ТОЛЬКО в /tmp ⇒ это АПТАЙМ, не эпоха (clock-lib.sh::up_age, ревью с.93, круг 3: перенос часов их не видит, и после
# скачка часов «перезапускали недавно» и «путь мёртв» держались бы часами). Нет библиотеки — «давно»: перезапуск будет.
command -v uptime_s >/dev/null 2>&1 || uptime_s() { _cl_u=$(awk '{print int($1)}' /proc/uptime 2>/dev/null); case "$_cl_u" in ''|*[!0-9]*) _cl_u=999999999 ;; esac; echo "$_cl_u"; }
command -v up_age >/dev/null 2>&1 || up_age() { echo 999999; }

# hev_tun_ok <TUN> — проходит ли запрос путём клиента (через TUN, то есть через hev). Критерий ОБЯЗАН совпадать с socks-пробой
# плагина: судим по разнице «socks — да, TUN — нет», и более строгая проба через TUN сама рождала бы залипание из ничего (ревью с.93:
# у ByeDPI socks-проба — любой код от 1.1.1.1 ИЛИ 8.8.8.8, и он переопределяет эту функцию своей). По умолчанию — проба выхода
# probe_ext_ip (её же берёт socks-проба xray/hy2).
hev_tun_ok() { [ -n "$(probe_ext_ip "--interface $1" 8)" ]; }

# hev_write_flood <лог hev> <метка: main | s<N>> — 0 и описание в stdout, если hev сыплет ошибками записи HEV_WERR_WINDOWS окон
# подряд; 1 — нет (или судить пока нечем). Состояние «<байт прочитано> <отметка аптайма> <окон подряд>» — в /tmp/enodia-hev-werr.<метка>:
# считаем только НОВЫЕ строки, а лог hev в ОЗУ и не ротируется (у тестера рос 9 дней). Окно короче минуты не судим (health сторож
# зовёт и повторно в том же тике), а копим до следующего вызова; длинное приводим к двум минутам.
hev_write_flood() {
    _hwl=$1; _hws="/tmp/enodia-hev-werr.$2"
    _hwz=$(wc -c < "$_hwl" 2>/dev/null | tr -d ' '); case "$_hwz" in ''|*[!0-9]*) _hwz=0 ;; esac
    _hwst=$(cat "$_hws" 2>/dev/null)
    _hwo=$(printf '%s' "$_hwst" | cut -d' ' -f1); _hwt=$(printf '%s' "$_hwst" | cut -d' ' -f2); _hwk=$(printf '%s' "$_hwst" | cut -d' ' -f3)
    case "$_hwo$_hwt$_hwk" in ''|*[!0-9]*) echo "$_hwz $(uptime_s) 0" > "$_hws"; return 1 ;; esac   # первый вызов или битая запись
    _hwa=$(up_age "$_hwt")
    [ "$_hwa" -lt 60 ] && return 1
    [ "$_hwz" -lt "$_hwo" ] && _hwo=0                                   # лог начат заново (перезапуск — hev_log_trim)
    _hwn=$(tail -c +$((_hwo + 1)) "$_hwl" 2>/dev/null | grep -c 'socks5 tunnel write' || true)
    case "$_hwn" in ''|*[!0-9]*) _hwn=0 ;; esac
    if [ $(( _hwn * 120 / _hwa )) -ge "$HEV_WERR_MIN" ]; then _hwk=$((_hwk + 1)); else _hwk=0; fi
    echo "$_hwz $(uptime_s) $_hwk" > "$_hws"
    [ "$_hwk" -ge "$HEV_WERR_WINDOWS" ] || return 1
    echo "$_hwn строк «socks5 tunnel write» за ${_hwa} с, $_hwk-е окно подряд"
}

# Перезапускали ли hev этой метки меньше HEV_RESTART_GAP назад.
hev_restart_recent() {
    _hrc=$(cat "/tmp/enodia-hev-restart.$1" 2>/dev/null | tr -d ' \r\n')
    [ -n "$_hrc" ] && [ "$(up_age "$_hrc")" -lt "$HEV_RESTART_GAP" ]
}
# ПУТЬ МЁРТВ, И ПЕРЕЗАПУСК hev НЕ ПОМОГ — отметка для ПЕРЕБОРА РЕЗЕРВОВ плагина (ревью с.93, круг 2). health в этом случае отвечает
# «нездоров», сторож зовёт failover, а тот первой строкой спрашивает тот же health БЕЗ проверки пути (HEV_CHECK — только у тика),
# socks-проба проходит, и перебор отвечал «уже здоров»: лестница крутилась HEALTHY↔SUSPECT, не доходя до cross и прямого режима,
# а трафик всё это время лил в залипший hev. Путь от сервера не зависит — сменой сервера его не вылечить, поэтому failover при
# отметке отказывает сразу. Живёт столько же, сколько пауза перезапуска; путь ожил — снимается.
hev_dead_mark()  { uptime_s > "/tmp/enodia-hev-dead.$1"; }
hev_dead_clear() { rm -f "/tmp/enodia-hev-dead.$1" 2>/dev/null; return 0; }
hev_path_dead()  {
    _hdd=$(cat "/tmp/enodia-hev-dead.$1" 2>/dev/null | tr -d ' \r\n')
    [ -n "$_hdd" ] && [ "$(up_age "$_hdd")" -lt "$HEV_RESTART_GAP" ]
}

# hev_stuck <TUN> <лог hev> <метка> — причина в stdout и код: 0 — залип, перезапускать; 1 — здоров (или лечить сейчас нечем);
# 2 — путь МЁРТВ, а перезапуск в паузе (не помог недавно): health обязан сказать «нездоров».
hev_stuck() {
    if ! hev_tun_ok "$1"; then
        sleep 2
        if ! hev_tun_ok "$1"; then
            echo "сервер отвечает через socks, а путь клиентов через $1 — нет (дважды)"
            hev_restart_recent "$3" && return 2
            return 0
        fi
    fi
    _hsf=$(hev_write_flood "$2" "$3") || return 1
    if hev_restart_recent "$3"; then
        log "health: hev ($1) сыплет ошибками записи в туннель ($_hsf), но его перезапускали меньше $((HEV_RESTART_GAP / 60)) мин назад — не трогаю" >&2
        return 1
    fi
    echo "путь клиентов через $1 жив, но hev сыплет ошибками записи в туннель ($_hsf)"
}

# Лок смены транспорта на время перезапуска: атомарно и со своим пидом. Не взяли — идёт чужая операция.
hev_lock_take() { ( set -C; echo $$ > "$HEV_SWLOCK" ) 2>/dev/null; }
hev_lock_drop() { rm -f "$HEV_SWLOCK" 2>/dev/null; return 0; }

# Лог hev перед новым стартом: хвост — свидетельство (его покажет дамп), остальное — ОЗУ, которую не вернёт никто.
hev_log_trim() { tail -n 20 "$1" > "$1.trim" 2>/dev/null && mv -f "$1.trim" "$1" 2>/dev/null; rm -f "$1.trim" 2>/dev/null; return 0; }

# Перезапуск состоялся: отметка для HEV_RESTART_GAP, счёт окон заново, событие в журнал. $1 метка · $2 причина · $3 ok|fail.
hev_restart_note() {
    uptime_s > "/tmp/enodia-hev-restart.$1"
    rm -f "/tmp/enodia-hev-werr.$1" 2>/dev/null
    _hrn=$ENODIA_DIR/notify-event.sh
    [ -f "$_hrn" ] || return 0
    # Язык письма — у nf-i18n.sh; не у каждого плагина он подключён (ByeDPI — нет, ревью с.93), поэтому берём сами.
    if ! command -v nf_lang >/dev/null 2>&1 && [ -f "$ENODIA_DIR/nf-i18n.sh" ]; then . "$ENODIA_DIR/nf-i18n.sh"; fi
    # Причина ($2) — строка лога сторожа, по-русски; английскому письму она идёт как есть, ради точных чисел.
    if command -v nf_lang >/dev/null 2>&1 && [ "$(nf_lang)" = en ]; then
        case "$1" in main) _hrw="the main carrier" ;; *) _hrw="extra exit #${1#s}" ;; esac
        case "$3" in ok) _hrr="After the restart the clients' path works." ;; *) _hrr="Even after the restart the clients' path does not work." ;; esac
        sh "$_hrn" "hev-restart-$1" 3600 "BE7000: hev of $_hrw restarted" \
"The hev layer (TUN -> protocol proxy) of $_hrw got stuck: $2. The server kept answering, so the router restarted only hev — established connections were cut at that moment.
$_hrr" >/dev/null 2>&1
        return 0
    fi
    case "$1" in main) _hrw="основной несущей" ;; *) _hrw="доп-выхода №${1#s}" ;; esac
    case "$3" in ok) _hrr="После перезапуска путь клиентов работает." ;; *) _hrr="И после перезапуска путь клиентов не работает." ;; esac
    sh "$_hrn" "hev-restart-$1" 3600 "BE7000: hev $_hrw перезапущен" \
"Прослойка hev (TUN → прокси протокола) $_hrw залипла: $2. Сервер при этом отвечал, поэтому роутер перезапустил только hev — установленные соединения в это время оборвались.
$_hrr" >/dev/null 2>&1
    return 0
}

# hev_path_check <функция маршрута плагина> — ОСНОВНАЯ несущая. 0 — путь клиентов жив (или ожил после перезапуска hev, или судить
# сейчас не нам), 1 — нет. КОНТРАКТ: HEV_PID, HEV_LOG, TUN, start_daemons (поднимает НЕДОСТАЮЩЕЕ — живой демон протокола не трогает),
# ct_flush, log, probe_ext_ip (ip-lib.sh); $1 — функция маршрута (default dev TUN в table 1000: TUN пересоздан, маршрут умер с ним).
# Перезапуск БЕРЁТ несущую ⇒ верб health у плагина — под carrier_run (следит C116).
hev_path_check() {   # $1 = функция маршрута плагина
    [ "${HEV_CHECK:-}" = 1 ] || return 0      # не тик сторожа (перебор, прогрев, дамп) — путь клиентов не судим
    _hpw=$(hev_stuck "$TUN" "$HEV_LOG" main); _hpr=$?
    case "$_hpr" in
        1) hev_dead_clear main; return 0 ;;
        2) log "health: $_hpw — hev перезапускали меньше $((HEV_RESTART_GAP / 60)) мин назад, а путь снова мёртв: не трогаю, решает лестница сторожа (перебор серверов не нужен)"
           hev_dead_mark main
           return 1 ;;
    esac
    hev_lock_take || { log "health: $_hpw — но идёт смена транспорта (лок): hev не трогаю"; return 0; }
    log "health: $_hpw — hev залип → перезапускаю hev на месте"
    _hpp=$(cat "$HEV_PID" 2>/dev/null | tr -d ' \r\n')
    start-stop-daemon -K -p "$HEV_PID" >/dev/null 2>&1      # -K пишет в stdout — health читают и CGI
    # TERM не услышан за 5 с — добиваем KILL: пидфайл ниже удаляется, и `start_daemons` поднял бы ВТОРОЙ hev рядом с сиротой (ревью с.93).
    if command -v daemon_wait_gone >/dev/null 2>&1 && [ -n "$_hpp" ] && ! daemon_wait_gone "$_hpp" 5; then
        # KILL — только СВОЕМУ hev: пидфайл мог протухнуть, и номер уже у чужого процесса (ревью с.96, круг 2).
        { ! command -v pid_runs >/dev/null 2>&1 || pid_runs "$_hpp" hev; } && { kill -9 "$_hpp" 2>/dev/null; daemon_wait_gone "$_hpp" 3; }
    fi
    hev_log_trim "$HEV_LOG"
    ip link del "$TUN" 2>/dev/null; rm -f "$HEV_PID" 2>/dev/null
    _hpo=fail
    if start_daemons && "$1"; then
        ct_flush
        hev_tun_ok "$TUN" && _hpo=ok
    fi
    hev_lock_drop
    hev_restart_note main "$_hpw" "$_hpo"
    if [ "$_hpo" = ok ]; then hev_dead_clear main; log "health: hev перезапущен — путь клиентов через $TUN ожил"; return 0; fi
    hev_dead_mark main
    log "health: и после перезапуска hev путь клиентов через $TUN мёртв — решает лестница сторожа (перебор серверов не нужен)"
    return 1
}

# slot_hev_path_check <id> — то же для ДОП-ВЫХОДА: его hev свой (xtunN, свой лог), а slot-health мерил socks выхода — мимо hev,
# с той же слепотой. Перезапуск — slot_hev_down/up + маршрут выхода (default dev xtunN в table 100N умер вместе с TUN) + ct_flush.
# Берёт несущую ⇒ верб slot-health у плагина — под carrier_run (C116). Зовут ТОЛЬКО после прошедшей socks-пробы выхода.
# Коды: 0 — путь жив (или ожил) · 5 — путь мёртв, а перезапуск hev не помог (сейчас или недавно): сервер ЖИВ, и это не «сервер не
# отвечает», а переподъём выхода каждые две минуты лишь рвал бы соединения дома ⇒ сторож снимает выход и ждёт с растущей паузой
# (ревью с.93, круг 2: прежний код 1 вёл к «не отвечает» и паре slot-up/slot-down на каждом тике) · 4 — путь мёртв, но лечить нельзя:
# идёт смена транспорта (лок) — «не судили», выход сторож не трогает.
slot_hev_path_check() {   # $1 = id
    _shid="$1"; _shtun=$(slot_tun "$_shid")
    _shw=$(hev_stuck "$_shtun" "$(slot_hev_log "$_shid")" "s$_shid"); _shr=$?
    case "$_shr" in
        1) return 0 ;;
        2) log "слот №$_shid health: $_shw — hev выхода перезапускали меньше $((HEV_RESTART_GAP / 60)) мин назад, а путь снова мёртв: не трогаю"
           return 5 ;;
    esac
    # Лок занят — путь МЁРТВ, но лечить сейчас нельзя: это не «жив» (код 0 сторож читал возвратом и слал «снова работает» при
    # мёртвом пути — ревью с.93, круг 3), а «не судили» — код 4: сторож выход не трогает и вердикта не пишет, следующий тик спросит снова.
    hev_lock_take || { log "слот №$_shid health: $_shw — но идёт смена транспорта (лок): hev выхода не трогаю, вердикт — следующим тиком"; return 4; }
    log "слот №$_shid health: $_shw — hev залип → перезапускаю hev выхода на месте"
    slot_hev_down "$_shid"
    hev_log_trim "$(slot_hev_log "$_shid")"
    _sho=fail
    if slot_hev_up "$_shid"; then
        slot_apply_routing "$_shid"
        ct_flush
        hev_tun_ok "$_shtun" && _sho=ok
    fi
    hev_lock_drop
    hev_restart_note "s$_shid" "$_shw" "$_sho"
    if [ "$_sho" = ok ]; then log "слот №$_shid health: hev перезапущен — путь клиентов через $_shtun ожил"; return 0; fi
    log "слот №$_shid health: и после перезапуска hev путь клиентов через $_shtun мёртв"
    return 5
}
