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

# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят чужим
# кроном ⇒ без ожидания правило МОЛЧА не встаёт, а ядро кладёт их десятками за один прогон. Путь
# ИЗ ПЕРЕМЕННОЙ (см. объявление выше): по литералу флеша в раскладке `full` файла нет, и
# ожидание лока пропадало молча — правило не встаёт, а stderr у половины вызовов заглушен.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi
# The packet mark saved into the ct mark (ct-lib.sh `ct_mark_save`, its own section says why): wired below with the marks it
# serves. No library (a partial update) — no rule, and every scoped flush falls back to the global one.
if [ -f "$ENODIA_DIR/ct-lib.sh" ]; then . "$ENODIA_DIR/ct-lib.sh"; fi
command -v slot_rules_show >/dev/null 2>&1 || slot_rules_show() { ip rule show 2>/dev/null; }
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi
if [ -f "$ENODIA_DIR/set-lib.sh" ]; then . "$ENODIA_DIR/set-lib.sh"; fi   # set_slot_needed: which exit sets the builders require
command -v set_slot_needed >/dev/null 2>&1 || set_slot_needed() { :; }   # no library = the 10b7e50 behaviour (nothing required)
command -v ipt_top >/dev/null 2>&1 || ipt_top() { _itc=$1; shift; iptables -C "$_itc" "$@" 2>/dev/null || iptables -I "$_itc" 1 "$@"; }
SLOTS_SH="$ENODIA_DIR/slots.sh"

# Watchdog tick -> settle -> rule/carrier owners. Off-settle waits for the tick before
# taking settle. A registry edit that already holds the slots lock must defer if busy.
case "${1:-}" in
    slot-repair|slot-replay)
        if command -v settle_lock_take >/dev/null 2>&1 &&
           { [ -z "$ENODIA_SETTLE_OWNER" ] || [ "$(cat "$SETTLE_LOCK" 2>/dev/null)" != "$ENODIA_SETTLE_OWNER" ]; }; then
            _settle_wait=60
            [ -z "$ENODIA_SLOTS_OWNER" ] || _settle_wait=0
            settle_lock_take "$_settle_wait" || exit 1
            trap 'settle_lock_drop' EXIT
            trap 'exit 1' HUP INT TERM PIPE
        fi ;;
esac
MAIN_ADMITTED=1
[ ! -f "$ENODIA_STATE/.vpn-off" ] || MAIN_ADMITTED=0
SLOT_RULE_LOCK=/tmp/enodia-slot-rules.lock

# One writer. The lookup list comes from intent, and the kernel skips a table without a route.
slot_routes() (
    command -v slot_rule_rows >/dev/null && command -v lbl_lock_take >/dev/null || exit 0
    _sr_before=$(slot_rules_show) || exit 1
    if [ ! -s "$ENODIA_STATE/.slots" ] && ! printf '%s\n' "$_sr_before" | grep -qE '^(9[2-7]|11[0-5]):'; then exit 0; fi
    lbl_lock_take "$SLOT_RULE_LOCK" 'mark-core\.sh' || exit 1
    trap 'lbl_lock_drop "$SLOT_RULE_LOCK"' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    _sr_before=$(slot_rules_show) || exit 1
    _sr_plan=''
    if [ -z "$1" ] && [ -s "$ENODIA_STATE/.slots" ]; then
        _sr_plan=$(sh "$SLOTS_SH" slot-plan "$2") || exit 1
    fi
    _sr_rc=0
    for _sr_id in ${1:-2 3 4 5 6 7}; do
        _sr_old=$(printf '%s\n' "$_sr_before" | slot_rule_rows "$_sr_id")
        _sr_new=$(printf '%s\n' "$_sr_plan" | awk -v id="$_sr_id" '$1==id {print $2,$3}')
        [ "$_sr_old" != "$_sr_new" ] || continue
        _sr_ok=1
        while read -r _sr_pref _sr_table; do
            [ -n "$_sr_table" ] || continue
            printf '%s\n' "$_sr_old" | grep -qxF "$_sr_pref $_sr_table" && continue
            ip rule add fwmark "0x$_sr_id" table "$_sr_table" pref "$_sr_pref" || _sr_ok=0
        done <<EOF
$_sr_new
EOF
        _sr_kept=''
        if [ "$_sr_ok" = 1 ]; then
            while read -r _sr_pref _sr_table; do
                [ -n "$_sr_table" ] || continue
                _sr_row="$_sr_pref $_sr_table"
                if printf '%s\n' "$_sr_new" | grep -qxF "$_sr_row" && ! printf '%s\n' "$_sr_kept" | grep -qxF "$_sr_row"; then
                    _sr_kept="$_sr_kept
$_sr_row"
                    continue
                fi
                ip rule del fwmark "0x$_sr_id" table "$_sr_table" pref "$_sr_pref" || _sr_ok=0
            done <<EOF
$_sr_old
EOF
        fi
        if [ "$_sr_ok" != 1 ]; then
            _sr_rc=1
            _sr_new=$(slot_rules_show | slot_rule_rows "$_sr_id")
        fi
        [ "$(printf '%s\n' "$_sr_old" | slot_rule_path)" = "$(printf '%s\n' "$_sr_new" | slot_rule_path)" ] ||
            ct_flush_slot "$_sr_id" origin
    done
    exit "$_sr_rc"
)

slot_firewall_repair() {
    sh "$SLOTS_SH" list-admitted | while IFS="$(printf '\t')" read -r _rp_id _rp_type _rp_cfg _rp_fb; do
        case "$_rp_type" in awg) _rp_if=awg$_rp_id ;; xray|hy2|byedpi) _rp_if=xtun$_rp_id ;; *) continue ;; esac
        slot_owned_default "$_rp_id" "$_rp_type" || continue
        if [ "$_rp_type" != awg ]; then
            ipt_top FORWARD -o "$_rp_if" -j ACCEPT
            ipt_top FORWARD -i "$_rp_if" -j ACCEPT
        fi
        case "$_rp_type" in awg|byedpi) sh "$ENODIA_DIR/transport.sh" slot-firewall "$_rp_id" ;; esac
    done
}

# A late writer must not leave a lookup forbidden by the current off plan.
slot_off_clean() {
    _oc_rules=$(slot_rules_show) || return 1
    _oc_plan=''
    if [ -s "$ENODIA_STATE/.slots" ]; then _oc_plan=$(sh "$SLOTS_SH" slot-plan) || return 1; fi
    ! printf '%s\n' "$_oc_rules" | grep -qE 'fwmark 0x1(/[^ ]+)? .*lookup 1000( |$)' || return 1
    for _oc_id in 2 3 4 5 6 7; do
        _oc_have=$(printf '%s\n' "$_oc_rules" | slot_rule_rows "$_oc_id")
        while read -r _oc_pref _oc_table; do
            [ -n "$_oc_pref" ] || continue
            printf '%s\n' "$_oc_plan" | grep -qxF "$_oc_id $_oc_pref $_oc_table" || return 1
        done <<EOF
$_oc_have
EOF
    done
}

SLOT_OUTPUT=ENODIA_SLOT_OUT
slot_output_unwire() {
    iptables -t mangle -S "$SLOT_OUTPUT" >/dev/null 2>&1
    case "$?" in 1) return 0 ;; 0) ;; *) return 1 ;; esac
    ipt_delete_all mangle OUTPUT -j "$SLOT_OUTPUT" &&
        iptables -t mangle -F "$SLOT_OUTPUT" && iptables -t mangle -X "$SLOT_OUTPUT"
}
# Keep resolver traffic on the path chosen by the DNS owner. RETURN skips only exit marking.
slot_output_guards() (
    _sog_op=$1
    for _sog_proto in udp tcp; do
        iptables -t mangle "$_sog_op" "$SLOT_OUTPUT" -p "$_sog_proto" --dport 53 -j RETURN || exit 1
    done
    [ -f "$ENODIA_DIR/doh-lib.sh" ] || exit 0
    . "$ENODIA_DIR/doh-lib.sh"
    _sog_proto=$(doh_wire_l4); _sog_port=$(doh_wire_port)
    for _sog_ip in $(dns_now anchors | tr ' ' '\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u); do
        iptables -t mangle "$_sog_op" "$SLOT_OUTPUT" -d "$_sog_ip" -p "$_sog_proto" --dport "$_sog_port" -j RETURN || exit 1
    done
)

slot_wiring() {
    [ -f "$SLOTS_SH" ] || return 0
    _sw_rows=$(sh "$SLOTS_SH" list-admitted 2>/dev/null | cut -f1 | tr '\n' ' ')
    case "$1:$UNWIRE" in
        check:0)
            iptables -t mangle -C OUTPUT -j "$SLOT_OUTPUT" 2>/dev/null &&
                slot_output_guards -C 2>/dev/null || return 1 ;;
        *)
            slot_output_unwire || return 1
            if [ "$UNWIRE" = 0 ] && [ -n "$_sw_rows" ]; then
                iptables -t mangle -N "$SLOT_OUTPUT" && slot_output_guards -A &&
                    iptables -t mangle -A OUTPUT -j "$SLOT_OUTPUT" || return 1
            fi ;;
    esac
    sh "$SLOTS_SH" list-enabled 2>/dev/null | while IFS="$(printf '\t')" read -r sid stransport _scfg _sfb; do
        case "$sid" in [2-7]) ;; *) continue ;; esac
        [ -z "$2" ] || [ "$sid" = "$2" ] || continue
        _sw_admitted=0
        case " $_sw_rows" in *" $sid "*) _sw_admitted=1 ;; esac
        for sset in "grp_vpn_s$sid" "geo_vpn_s$sid"; do
            ipset list -n 2>/dev/null | grep -qx "$sset" || continue
            if [ "$1" = check ]; then
                [ "$_sw_admitted" = 1 ] && [ "$stransport" != zapret ] || continue
                for chain in PREROUTING "$SLOT_OUTPUT"; do
                    iptables -t mangle -C "$chain" -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid" 2>/dev/null &&
                    iptables -t mangle -C "$chain" -m set --match-set "$sset" dst -j ACCEPT 2>/dev/null || exit 1
                done
                continue
            fi
            # чистка прежних копий (идемпотентность, зеркало базового цикла)
            for chain in PREROUTING OUTPUT; do
                while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j ACCEPT 2>/dev/null; do :; done
                while iptables -t mangle -D "$chain" -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid" 2>/dev/null; do :; done
            done
            [ "$UNWIRE:$_sw_admitted" = 0:1 ] || continue
            [ "$stransport" != zapret ] || continue
            mpos=$(iptables -t mangle -nL PREROUTING --line-numbers 2>/dev/null | awk '/miwifi|ipt_compiler|NFQUEUE/{print $1; exit}')
            if [ -n "$mpos" ]; then
                iptables -t mangle -I PREROUTING "$mpos" -m set --match-set "$sset" dst -j ACCEPT &&
                iptables -t mangle -I PREROUTING "$mpos" -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid" || exit 1
            else
                iptables -t mangle -A PREROUTING -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid" &&
                iptables -t mangle -A PREROUTING -m set --match-set "$sset" dst -j ACCEPT || exit 1
            fi
            iptables -t mangle -A "$SLOT_OUTPUT" -m set --match-set "$sset" dst -j MARK --set-mark "0x$sid" &&
            iptables -t mangle -A "$SLOT_OUTPUT" -m set --match-set "$sset" dst -j ACCEPT || exit 1
        done
    done
}

# Share the classifier verdict between status and the watchdog's fast path.
slot_classifiers_wired() {
    ipt_reply_guard check &&
        slot_wiring check "$1" &&
        sh "$ENODIA_DIR/apply-bypass.sh" slot-check "$1"
}

case "${1:-}" in
    slot-rules) slot_routes ''; exit $? ;;
    slot-off-clean) slot_off_clean; exit $? ;;
    slot-wired)
        case "$2" in [2-7]) ;; *) exit 1 ;; esac
        slot_admitted "$2" "$3" && slot_owned_default "$2" "$3" || exit 1
        # No required set = nothing to mark (an exit with no groups/geo: after a deactivation the replay recreates only the sets of exits
        # that have groups — AX3600 walk 23.11.2026); only its classifiers (device and port rules) are asked, else the status read
        # «правил нет» and sent people to a repair that cannot change it. The BUILDERS answer which sets are required (set-lib.sh
        # set_slot_needed), not «does a set exist»: a bound exit whose set is gone carries nothing and must read unwired (review 9/10).
        _swn=$(set_slot_needed "$2")
        [ -n "$_swn" ] || { slot_classifiers_wired "$2"; exit $?; }
        _swl=$(ipset list -n 2>/dev/null)
        for _sws in $_swn; do printf '%s\n' "$_swl" | grep -qx "$_sws" || exit 1; done
        iptables -t mangle -S 2>/dev/null | grep -qE -- "-j MARK --set-(x)?mark 0x$2(/[^ ]+)?( |$)" &&
            slot_classifiers_wired "$2"
        exit $? ;;
    slot-downgrade) slot_routes '' legacy; exit $? ;;
    slot-unrule) case "$2" in [2-7]) slot_routes "$2"; exit $? ;; *) exit 2 ;; esac ;;
    slot-unrules) slot_routes '2 3 4 5 6 7'; exit $? ;;
esac

if [ "$UNWIRE" = 0 ]; then
    [ ! -f "$ENODIA_STATE/.vpn-deactivated" ] || exit 0
    if { [ "$MAIN_ADMITTED" = 0 ] || [ "$1" = slot-repair ]; } &&
       [ -z "$(sh "$SLOTS_SH" list-admitted 2>/dev/null)" ]; then
        slot_routes '' && slot_output_unwire || exit 1
        [ "$1" != slot-replay ] || { sh "$ENODIA_DIR/apply-bypass.sh" apply; exit $?; }
        exit 0
    fi
    if [ "$1" = slot-repair ] &&
       iptables -t mangle -C OUTPUT -j VPN_EXCLUDE 2>/dev/null &&
       iptables -t mangle -C VPN_EXCLUDE -j VPN_ENDPOINT 2>/dev/null &&
       slot_classifiers_wired ''; then
        slot_routes '' && slot_firewall_repair && ct_mark_save on
        exit $?
    fi
fi

[ "$UNWIRE" = 1 ] || slot_routes '' || exit 1

# Protect reverse NAT replies before installing any destination marks.
if command -v ipt_reply_guard >/dev/null 2>&1; then
    ipt_reply_guard "$UNWIRE" || echo "[mark-core] ВНИМАНИЕ: reply-guard не поставлен"
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

# Exit set MARK+ACCEPT precedes main split routing and the stock NFQUEUE inspection.
slot_wiring full || exit 1

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
        [ "$UNWIRE:$MAIN_ADMITTED" = 0:1 ] || continue
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
# Save the original-direction mark for scoped connection retirement.
if command -v ct_mark_save >/dev/null 2>&1; then
    if [ "$UNWIRE" = 1 ]; then ct_mark_save off; else ct_mark_save on; fi
fi
if [ "$UNWIRE" = 1 ]; then slot_routes '2 3 4 5 6 7'; fi

# Slot replay keeps the main transport's current lookup, including during FAILOPEN.
case "$1" in slot-repair|slot-replay) ;; *) ip rule del fwmark $FWMARK table $TABLE 2>/dev/null ;; esac
if [ "$UNWIRE" = 1 ]; then
    # Саму table $TABLE не чистим: default в ней — собственность несущей, её снимает
    # transport.sh down (uninstall.sh зовёт его ПЕРЕД нами). Здесь только правила ядра.
    echo "[mark-core] маркировка СНЯТА (правила ядра и ip rule убраны; сеты и default в table $TABLE — не наша забота)"
    exit 0
fi
case "$1:$MAIN_ADMITTED" in slot-*:*) ;; *:1) ip rule add fwmark $FWMARK table $TABLE pref 99 || exit 1 ;; esac

# Plain main apply can race Off. Exit replay holds the settle lock throughout.
if [ "${1#slot-}" = "${1:-}" ] && [ "$MAIN_ADMITTED" = 1 ] && [ -f "$ENODIA_STATE/.vpn-off" ]; then
    ip rule del fwmark $FWMARK table $TABLE 2>/dev/null
    [ -z "$(sh "$SLOTS_SH" list-admitted 2>/dev/null)" ] || exec sh "$ENODIA_DIR/mark-core.sh" slot-replay
    exec sh "$ENODIA_DIR/mark-core.sh" unwire
fi
case "$1" in
    slot-repair|slot-replay)
        sh "$ENODIA_DIR/apply-bypass.sh" apply || exit 1
        [ ! -f "$ENODIA_DIR/road.sh" ] || sh "$ENODIA_DIR/road.sh" wire || exit 1
        [ "$1" != slot-repair ] || slot_firewall_repair || exit 1 ;;
esac

echo "[mark-core] маркировка применена (table $TABLE, fwmark $FWMARK; default ставит транспорт)"
