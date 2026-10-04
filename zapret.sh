#!/bin/sh
# zapret.sh — DPI-десинк НАПРЯМУЮ (nfqws/NFQUEUE). С июня 2026 — 5-й ТРАНСПОРТ (псевдо-несущая
# БЕЗ VPS), переключаемый в селекторе панели наравне с awg/xray/hy2/byedpi.
#
# ИДЕЯ. nfqws на форварде десинхронизирует первые сегменты TLS-ClientHello / QUIC-Initial так,
# что DPI провайдера не успевает заблокировать. Это НЕ socks (десинк прямо на форварде), поэтому
# zapret НЕ участвует в авто-cross/failover (его нет в REGISTRY transport.sh, только в SELECTABLE).
# Когда zapret выбран транспортом: туннеля НЕТ, ВЕСЬ трафик идёт напрямую (провайдер видит твой
# IP), а выбранные категории (ipset zapret_set) пробивает nfqws. mark-core при этом безвреден —
# несущей в table 1000 нет, маркированное падает в main = напрямую (fail-open).
#
# РОЛЬ. Бесплатный обход без VPS, но покрытие ЧАСТИЧНОЕ и ISP-зависимое (YouTube/Google/Meta-TCP
# обычно да; x.com-Cloudflare и QUIC-over-IPv6 нет). Это АЛЬТЕРНАТИВА туннелю для тех, кому хватает,
# не замена для всех сайтов. Раньше zapret работал ПАРАЛЛЕЛЬНО с туннелем (слой над mark-core) —
# по просьбе пользователя переведён в отдельный взаимоисключающий транспорт; параллельный режим
# может вернуться позже отдельной фичей. Транспорт-контракт (up|down|health|failover) — внизу файла.
#
# РОЛЬ. zapret здесь = ДОПОЛНЕНИЕ к VPS-туннелю, не замена. Железо-спайки (2026-06-18→19)
# показали: на форварде nfqws берёт YouTube (TLS+QUIC), Google, Meta/Facebook-TCP, РФ-сайты —
# быстро и без нагрузки на VPS; но x.com-Cloudflare и QUIC-over-IPv6 (Instagram) на форварде
# НЕ пробиваются (NAT-инъекция / каркас IPv4-only). Покрытие ЧАСТИЧНОЕ → туннель остаётся
# основным, zapret опционален (OFF по умолчанию) и включается на категорию.
#
# РАБОЧАЯ ЦЕПОЧКА (обобщена на весь дом из спайка local/zt-spike/zt-test2.sh):
#   1. mangle PREROUTING -j ENODIA_ZAPRET → -m set --match-set zapret_set dst -j ACCEPT
#        — сайты категории МИМО туннеля (ACCEPT обрывает mangle ДО MARK mark-core → direct).
#          Своя цепочка, а не голое правило: её ПОЗИЦИЮ (ниже правил устройства, выше маркировки)
#          назначает единственный владелец порядка — apply-bypass.sh (см. zt_chain_ensure).
#   2. mangle POSTROUTING -p tcp/udp --dport 443 -m set zapret_set dst <connbytes 1:8>
#        -m mark ! --mark 0x40000000 -j NFQUEUE --queue-num 212 --queue-bypass
#        — первые 8 пакетов рукопожатия (TLS + QUIC) в очередь nfqws. --queue-bypass = FAIL-OPEN
#          (нет nfqws → пакеты ПРОХОДЯТ, не обрыв). connbytes 1:8 ловит ХЭНДШЕЙК ДО акселерации
#          (offload глушить НЕ нужно — массовый трафик идёт ускоренно, дом не тормозит).
#   3. mangle OUTPUT -m mark --mark 0x40000000 -j RETURN
#        — АНТИ-ПЕТЛЯ: nfqws штампует свои реинъекты меткой 0x40000000; их dst ∈ iplist_set →
#          mark-core OUTPUT иначе пометил бы их В ТУННЕЛЬ → EPERM (rawsend) → десинк ломается.
#          RETURN выводит реинъекты nfqws мимо маркировки. ОБЯЗАТЕЛЬНО (грабля спайка).
#   4. nfqws-демон (start-stop-daemon -b: busybox без nohup/setsid) с TLS+QUIC-профилями.
#   5. conntrack -F (NSS/ECM-инвариант: для УЖЕ установленных соединений старый маршрут залипает).
#
# DNS. Менять НЕ нужно: dnsmasq и так форвардит upstream В ТУННЕЛЬ → отдаёт РЕАЛЬНЫЕ IP (не
# RU-заглушку). zapret_set наполняет dnsmasq по `ipset=/<домен>/zapret_set` (сниппет 04-zapret.conf,
# регенерится в apply — /etc=ramfs). Те же резолвленные IP покрывают и TCP, и QUIC (одинаковый dst).
#
# СОСТОЯНИЕ (dotfiles в $ENODIA_DIR, переживают ребут): .zapret-on (флаг ВКЛ), .zapret-args (стратегия
# nfqws; нет → DEFAULT_ARGS), .zapret-cats (выбранные категории, пробел/запятая). Переигрывается на
# boot (heal.sh) и в vpn-toggle.sh repair (fw3-reload сносит mangle).
#
# Использование:
#   zapret.sh up|down         — поднять/снять как ТРАНСПОРТ (зовёт ОРКЕСТРАТОР; .zapret-on ⇔ .transport)
#   zapret.sh install|remove  — фоновая до/переустановка nfqws с GitHub / удаление (панель, как byedpi)
#   zapret.sh apply           — переиграть из состояния (идемпотентно; зовут heal/repair)
#   zapret.sh rewire          — дособрать правила под пулы менеджера источников (zapret-cidr/-dom)
#   zapret.sh status          — показать состояние
#   zapret.sh reload          — перезапустить nfqws с текущими .zapret-args (без снятия правил)
#   zapret.sh presets         — библиотека готовых стратегий (label|args)
#   zapret.sh defaults        — дефолтная стратегия (для показа в панели)
#   zapret.sh categories      — что выбрано «в десинк» в гео (key|label|адресов); выбор — в карточке «Гео»
#   zapret.sh sweep-begin|sweep-apply <args>|sweep-end — браузер-свип стратегий (см. ниже)

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
if ! command -v ct_flush >/dev/null 2>&1; then
    ct_flush()      { conntrack -F >/dev/null 2>&1 || true; }
    ct_flush_src()  { [ -n "$1" ] && conntrack -D --src "$1" >/dev/null 2>&1; return 0; }
fi
# Где лежит бинарь (store-lib.sh): без накопителя — прежний путь байт-в-байт. Шим на случай
# установки без lib.
if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
if [ -f "$ENODIA_DIR/daemon-lib.sh" ]; then . "$ENODIA_DIR/daemon-lib.sh"; fi
# «VPN выключен вручную — несущую не берёт никто» (carrier_barred/carrier_run, разбор в daemon-lib.sh). Нет — прежний путь.
command -v carrier_barred >/dev/null 2>&1 || carrier_barred() { return 1; }
command -v carrier_run >/dev/null 2>&1 || carrier_run() { shift; "$@"; }
# Возраст lock'а свипа — через age_since (clock-lib.sh): lock в /tmp рождается после загрузки, а часы
# без RTC прыгают вперёд ⇒ голая разность делает идущий свип «протухшим», и apply затирает временную
# стратегию посреди замера. Шим = прежнее поведение. [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
# Шим отметки подъёма несущей: старая установка без свежей clock-lib не должна падать на
# неизвестной команде посреди cmd_t_up — просто останется без грейса, то есть с прежним поведением.
command -v carrier_up_mark >/dev/null 2>&1 || carrier_up_mark() { return 0; }
command -v bin_path >/dev/null 2>&1 || bin_path() { printf '%s' "$ENODIA_BIN/$1"; }
# bin_dest ≠ bin_path: первый отвечает «КУДА класть новый файл» (политика), второй — «откуда
# запускать» (факт). Для ОТСУТСТВУЮЩЕГО бинаря bin_path отдаёт резидентный путь, поэтому
# качать по нему значило класть nfqws на 20-МБ флеш ровно тогда, когда план в «Компонентах»
# уже пообещал накопитель. bin_prune добивает копию с другой стороны («копия РОВНО одна»).
command -v bin_dest  >/dev/null 2>&1 || bin_dest()  { printf '%s' "$ENODIA_BIN/$1"; }
command -v bin_prune >/dev/null 2>&1 || bin_prune() { return 0; }
# Без store-lib переменная пуста, а cmd_remove сравнивает её с $ENODIA_DIR и делала бы rm по «/nfqws»
# в корне. Дефолт закрывает весь класс разом (тот же приём, что в packages.sh).
: "${BIN_DIR:=$ENODIA_DIR}"
NFQWS=$(bin_path nfqws)                # бинарь nfqws (bin/nfqws.user) — UPX-static aarch64
TLS_BIN="$ENODIA_DIR/zapret-tls.bin"      # фейк TLS-ClientHello (встроен base64 ниже)
QUIC_BIN="$ENODIA_DIR/zapret-quic.bin"    # фейк QUIC-Initial (встроен base64 ниже)
SET=zapret_set                         # ipset сайтов «десинк-direct» ПО ДОМЕНАМ (наполняет dnsmasq)
# ВТОРОЙ пул того же десинка — ПО IP (CIDR). Наполняет менеджер источников (lists-update.sh,
# категория zapret-cidr), здесь он только «ещё одно слово» в ZAPRET_SETS. ЗАЧЕМ отдельный сет,
# а не один общий: доменный пул ведёт dnsmasq (add по ответу резолвера), CIDR-пул заливается
# атомарным swap'ом — swap затирал бы всё, что туда положил dnsmasq. Ровно то же разделение
# обязанностей, что у пары enodia_list (домены) / iplist_set (CIDR) в основном тракте.
# ПРИЧИНА существования (железо, 2026-07-25): доменный пул наполняется ТОЛЬКО для клиентов,
# спрашивающих наш dnsmasq. ТВ/приставка со своим DNS (кэш, DoH, зашитый резолвер) не попадает
# в zapret_set никогда — десинка для неё нет вообще, хотя на ПК и телефоне всё работало.
SET_CIDR=zapret_cidr
# ТРЕТИЙ пул — СВОИ ДОМЕНЫ пользователя (файл/URL/текст через менеджер источников, категория
# zapret-dom). Наполняет его тот же dnsmasq, но по СВОЕМУ сниппету (07-zapret-dom.conf) и в СВОЙ
# набор — чтобы «выключил свой пул» не задевало курированную четвёрку категорий выше (и наоборот:
# teardown транспорта флашит только $SET). Категорий в коде четыре и добавить пятую можно лишь
# правкой скрипта — этот пул закрывает ровно это (договорено с юзером 2026-07-25).
SET_DOM=zapret_dom
# Единый whitelist пулов десинка — «новый пул = ОДНО слово здесь» (зеркало BYPASS_SETS в
# apply-bypass.sh): по нему идут И постановка правил, И их снятие, поэтому забыть половину нельзя.
# Четвёртый пул — гео-категории с действием «в десинк» (geo.sh собирает и чистит его САМ; мы только
# вешаем правила). Так вшитая четвёрка youtube/google/discord/meta уступила место поиску по каталогу
# v2fly: «что десинкать» задаёт тот же реестр, что «в VPN / мимо / блок».
SET_GEO=geo_zapret
ZAPRET_SETS="$SET $SET_CIDR $SET_DOM $SET_GEO"
QNUM=212                                            # номер NFQUEUE
MARK=0x40000000                                     # метка nfqws на своих реинъектах (DESYNC_MARK)
MARKM="$MARK/$MARK"
NFQ_PID=/tmp/enodia-zapret-nfqws.pid
NFQ_LOG=/tmp/enodia-zapret-nfqws.log
ON_FLAG="$ENODIA_STATE/.zapret-on"
ARGS_FILE="$ENODIA_STATE/.zapret-args"
CATS_FILE="$ENODIA_STATE/.zapret-cats"
TRANSPORT_FLAG="$ENODIA_STATE/.transport"
DNS1=1.1.1.1                                        # прямой резолвер (туннеля нет → upstream dnsmasq мимо VPN)
DNS2=8.8.8.8
GH="$ENODIA_DIR/gh-update.sh"                       # апдейтер: gh-update.sh fetch-bin nfqws (панель-установка)
INSTALL_STATE="$ENODIA_STATE/.zapret-install.state" # прогресс фоновой install/remove (формат как proto-install)
INSTALL_LOG="$ENODIA_STATE/.zapret-install.log"     # лог фоновой install/remove (фронт поллит последнюю строку)
DNSMASQ_SNIPPET=/etc/dnsmasq.d/04-zapret.conf
DNSMASQ_LIVE=/tmp/dnsmasq.d/04-zapret.conf          # ЖИВАЯ копия того же сниппета (см. write_dnsmasq/del_dnsmasq)
SWEEP_LOCK=/tmp/enodia-zapret-sweep.lock            # браузер-свип идёт (timestamp)
SWEEP_BAK="$ENODIA_STATE/.zapret-args.sweepbak"     # бэкап исходной стратегии на время свипа
SWEEP_TTL=150                                       # свежесть lock (сек)
# connbytes: первые 8 пакетов соединения в оригинальном направлении (= рукопожатие). Ловит ДО
# offload-акселерации потока → десинк работает при ВКЛЮЧЁННОМ ускорителе (грабля/находка спайка).
CB="-m connbytes --connbytes-dir original --connbytes-mode packets --connbytes 1:8"

# ДЕФОЛТ-СТРАТЕГИЯ — самые НАДЁЖНЫЕ на этом ISP комбо из железо-спайков (БЕЗ опций, которых могло
# бы не быть в урезанном форке: только базовые fake/multidisorder/repeats/fooling/fake-tls/fake-quic):
#   TLS: fake,multidisorder split-pos=1,sniext repeats=3 fooling=badseq fake-tls — открыл ВСЕ 5 TCP
#        блок-сайтов вкл. Meta (репеаты = ключ). QUIC: fake repeats=11 fake-quic — пробил YouTube-QUIC.
# @tls/@quic — токены, resolve_args подставляет абсолютные пути фейков перед запуском nfqws.
DEFAULT_ARGS="--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,sniext --dpi-desync-repeats=3 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic"

# Фейки в base64 (tls_clienthello.bin 652Б / quic_initial.bin 1200Б из спайка). apply пишет их на
# /data, если нет → фича разносится ОДНИМ скриптом (gh-update apply-scripts = только текст; отдельную
# бинарную раздачу фейков не заводим).
TLS_B64='FgMBAocBAAKDAwNfFWPLBuoc3UB29YxEUG4B86ODrMLiM2mG7KlnITC9JyC5zjH8AuwI5SWbkBxgsB4fErU45KaIuySqlj+mx/e02wAiEwETAxMCwCvAL8ypzKjALMAwwArACcATwBQAnACdAC8ANQEAAhgAAAATABEAAA53d3cuZ29vZ2xlLmNvbQAXAAD/AQABAAAKAA4ADAAdABcAGAAZAQABAQALAAIBAAAQAA4ADAJoMghodHRwLzEuMQAFAAUBAAAAAAAiAAoACAQDBQMGAwIDADMAawBpAB0AIHrBRo14u1yZ5ePVgAgeBwzYiWvmOe07TqRdXjKDSYx+ABcAQQTwQ0GH5mw8JFjPlmBpB53EXp4bh/BxiUK9zAIGmqsQCQNrvJHFqI6+toGn6rSl7SbMtFQQh/hzoWKsij5sr52tACsABQQDBAMDAA0AGAAWBAMFAwYDCAQIBQgGBAEFAQYBAgMCAQAcAAJAAf4NARkAAAEAAX8AIIt3byfmna7qvEsPOHznFjexjTEIZ9ajYlrBxP1CGVpJAO8mMk/Vk5ryi7d6gSiaXTAImHavEWFj2lEo4eL6ThF+93BwsM/10cZakX3laocEZSKm0aSbcHkTjtcSHxuMYElbInJ3sBVsvGtPvZIkgKwy4gwy7gEHygmFuJvL3tDG6GnMnJR8vyWQYCvhogH42VSbkteuSVI2wfYKVVtIrFedseO3tZb6m7Q5wbaC4+SN1gP2BCd3uiQgZzU4decymc/8uM6tEtJhoX13khLgmEXG6ggaJv2Q7hvq/V68Uh5wXcpgRFLUww5/5xG05hDzn694K9nTSl2n8F9BJBxA8xqwAFlYG+N7zk1dnwa0oJ7NqA=='
QUIC_B64='wwAAAAEIeOeYRrvzeYQAAESesuIbTYvML8k+74FJlUpbpjZLkRkbfQ7pPzj/kZL9Fu+3ogPlQ8dyMeP89o8Auy/DSwZaokXfGeuOwoSnfRtQe3OzcZK8imo9mFgmDBxr+y10Kbw8odbQHHk3KTKRDD0/8g5SJAkQBIKWNLqrjZ3+1tCq9p6GcDAc3qo+UCwnJkD6S+3zJDKp/T605OBNXZ0CWT78aGf6p7S4qYfZIhlTwaLpC3DRfnoU6fjOealCm82TouI15OZz2SddeAM94DLpdzpR6RsiF50yvp6XhGGrtG4aqVV+SzXrwxUkgyMrL8hjMlEGvRjXS7KHVda1WHEENZabAalpnEbSY4+7q+Tr21kWGdnpaXbSUHc9b+m8+EjZ9uSeFiAaTZuqjCrg8Awq/bM9kmxDHbj0SrXxGSUovKcBmjQg7N8N641Stbd0FYC2MKELnYtR3ZaDLCwz0eZsJKze/qh+ta8RSm0E97GPcKXE17ZdbfVt/eF+77Aq+J85nWxlCheLfrBJqNN2DDbV56uKq/9VIWHR29TXY/vWQ0UHzPn5KpG9VO2M4wjMzZoNfgTY9YcA+ClVuFOM0BHuCg6x2LAtsR8+Ofr6F0hh/BJzTmL1+dWoznqhCeW+PC4x9NQde8tShTbnhFpwuCRL1S0c+Py2rvQJtGzbj9NQCz+jHaSTpZ35hbdQabjb6jWtKB2Ws/tc3WSZgzVVSXLD2dOgwXCwbhp7vbEsQzBPAG8zcg01mp3zV3bA9u0N66Ne0on5Y30UI79cXsBhwuqivmYW2xpHNT+o8LL7ZhmimySIExeyLDWSOSSfPu33tffnIl4Pjl48p0G3BRdr3SnqhmW1DQFKl1XODREQTAwL5dYu00NgZ9gE9NHj6UGv0Wim7q9FVzLTK3C0nUrs2EVPBZhOcKaOgOHz8L4T06vK02haE+J/n1NsKxQffG9eOsZvmY/G8iAPd4rnRQV8w1vEPgcwyIgpAfREMDEjDZo0RLpAdW4HQ0gBmuFjeKSQ3yRQhRawu4mkrZOf6vfZRS6Wt74wx0s4CUSUwVyyU+WgHMPnWTrljlkoz61LHXDtedEZbg/lD1vjA3pt2/rYmYxmz7+P8+0ozYu4WAlRxG+BwMWZP0qvnwNQNtYUEHb9i/ffKVcW/IHO7/nSSb4JII/z5+oH7otIVVHSEqhxdAWZsDzKjCFInpRjxGL3awJBHnq+ULxEB3+nQbL6sQCjexBGocISAJ9oSXItUcPc6tBxeA/L97oMOpOyFMjR/OTYNWRJjKcDEw7UugROORI+ODAsOpgLte4By2IsGyMp7Ehsi45ZNYgT+OleAgSdkK0EIbkWgQE30NAVIERobsj6FGuIKLzlpVEIb296FBO7PbnJX3wtMjn3zF1wTxlKWyJJc/QshKIFdu9iOKzmx09T+RJuNApwts1ITGtRDc/RiHX6Zuihxw2lZHiKUXKyuNz1EzOj8shdnD8CkEawlP+301xKA9Gha+qp7SeDdC+KqFHKDFxkknOqOB3ZDJUijL+9n7RbDu32TGnEaaJCkE+VQEr94woNA8SxigFvW7dKtpEGSqPticyVBQsiI0atDHBW'

# Слой шифрованного DNS (doh-lib.sh): при включённом DoH резолв идёт через локальный прокси
# (dnsmasq→127.0.0.1#5053), :443 резолвера держим МИМО маркировки (туннеля нет). ВЫКЛ (дефолт) →
# doh_apply_dns даёт 1, прежний прямой путь байт-в-байт. Шим на случай установки без lib.
[ -f "$ENODIA_DIR/doh-lib.sh" ] && . "$ENODIA_DIR/doh-lib.sh"
command -v doh_apply_dns >/dev/null 2>&1 || doh_apply_dns() { return 1; }
# Наш upstream dnsmasq пишет ОДИН владелец (doh-lib.sh, разбор там). Нет библиотеки — прежняя пара «записать + рестарт».
command -v dns_upstream_put >/dev/null 2>&1 || dns_upstream_put() { mkdir -p /etc/dnsmasq.d; { echo no-resolv; for _dus in "$@"; do echo "server=$_dus"; done; } > /etc/dnsmasq.d/00-upstream.conf; /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }

log() { echo "[zapret] $*"; }

# Пустой/0-байтовый пидфайл = НЕ жив (busybox kill -0 "" врёт «жив»).
proc_alive() { p=$(cat "$1" 2>/dev/null | tr -d ' \r\n'); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# nfqws-демон и анти-петля ОБЩИЕ для двух потребителей: zapret-ТРАНСПОРТ (весь дом) и
# zapret-СЛОТ(ы) (десинк рядом с VPN, Ф1). Гасить их можно, только когда НИ ОДИН не нужен.
SLOTS_SH="$ENODIA_DIR/slots.sh"
# ПОТРЕБИТЕЛИ ИЗ VPN (транспорт и выходы) при ВЫКЛЮЧЕННОМ вручную VPN nfqws НЕ держат: их сняло `off`, а в `.transport` и в реестре
# выходов осталось лишь НАМЕРЕНИЕ. Считай мы его — последний снимаемый потребитель видел бы «нужен ещё кому-то» и оставлял nfqws
# жить при выключенном VPN (zapret-транспорт вместе с zapret-выходом, два zapret-выхода), а reload и свип стратегии поднимали бы
# его обратно (ревью ветки, круг 2). Устройства «целиком в десинк» — не VPN: их считаем всегда (по ФАКТУ в mangle).
zt_transport_active() { ! carrier_barred && [ "$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')" = zapret ]; }
# Есть ли ВКЛЮЧЁННЫЙ zapret-слот (опц. исключая id $1). list-enabled: id⇥transport⇥cfg⇥fallback.
zt_any_slot_enabled() {
    carrier_barred && return 1
    [ -f "$SLOTS_SH" ] || return 1
    sh "$SLOTS_SH" list-enabled 2>/dev/null | while IFS="$(printf '\t')" read -r _sid _st _sc _sf; do
        [ "$_st" = zapret ] || continue
        [ "$_sid" = "$1" ] && continue
        echo x; break
    done | grep -q x
}
# ТРЕТИЙ потребитель nfqws — УСТРОЙСТВА «целиком в десинк» (правила по ИСТОЧНИКУ, см. блок
# «десинк по источнику» ниже). Судим по ФАКТУ в mangle, а не по чужому хранилищу: владелец списка
# устройств — apply-bypass.sh, и читать его файл отсюда значило бы завести второго владельца.
zt_any_src_wired() {
    iptables -t mangle -S POSTROUTING 2>/dev/null \
        | grep -e '-s [0-9]' | grep -q -e "--queue-num $QNUM"
}
# «Десинк РЕАЛЬНО несёт трафик» = zapret активен транспортом ИЛИ живёт хотя бы одним доп-выходом
# ИЛИ хотя бы одним устройством. Гейт свипа/reload раньше смотрел ТОЛЬКО $ON_FLAG (флаг
# ТРАНСПОРТА) — из-за чего на zapret-выходе рядом с VPN подбор стратегии из панели молча отказывал
# («десинк выключен»), хотя nfqws работал.
# up/off/apply гейтить этим НЕЛЬЗЯ: там ON_FLAG означает именно «zapret несёт весь дом».
zt_desync_live() { zt_transport_active || zt_any_slot_enabled || zt_any_src_wired; }
# ЕДИНСТВЕННЫЙ МАШИННЫЙ ОТВЕТ «есть ли на роутере ЖИВОЙ десинк» (0 — да, 1 — нет; неизвестный верб
# у старой копии = 2, и вызыватель обязан это различать). Спрашивает тот, кто ОТЧИТЫВАЕТСЯ ЧЕЛОВЕКУ
# перед снятием: экран удаления обещал «Zapret (nfqws + NFQUEUE)» по одному лишь факту БИНАРЯ на
# диске — а nfqws кладёт бутстрап ПК на КАЖДОЙ установке, в том числе на ядре 4.4 (AX3600), где
# NFQUEUE вырезан и zapret невозможен в принципе. Обещание снять то, чего никогда не было,
# читается как «система тут стояла — и её сносят».
# $ON_FLAG проверяем ОТДЕЛЬНО от zt_desync_live: флаг «zapret несёт весь дом» переживает упавший
# демон, и снимать его всё равно придётся.
cmd_wired() { zt_desync_live || [ -f "$ON_FLAG" ] || proc_alive "$NFQ_PID"; }
# ПРОВОДКА ГЛАВНОГО ТРАНСПОРТА НА МЕСТЕ (0 да · 1 нет) — это ДРУГОЙ вопрос, чем «жив ли десинк
# вообще» выше. nfqws и очередь ОБЩИЕ у трёх потребителей (транспорт · доп-выход · устройство
# целиком), поэтому «есть NFQUEUE где-то в POSTROUTING» доказывает лишь, что десинк идёт
# КОМУ-ТО: при .transport=zapret со снесёнными fw3 reload правилами живой zapret-ВЫХОД рисовал
# в шапке «Zapret активен» (тестер, 18.08.2026). Отличаем по СЕТУ — пулы транспорта перечислены
# в ZAPRET_SETS, у выхода наборы свои (grp_vpn_sN/geo_vpn_sN), у устройства правило по источнику.
zt_transport_wired() {
    _tw=$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -e "--queue-num $QNUM")
    for _tws in $ZAPRET_SETS; do
        case "$_tw" in *"--match-set $_tws dst"*) return 0 ;; esac
    done
    return 1
}

# ---- «что десинкать» — гео-реестр, вшитых категорий БОЛЬШЕ НЕТ ----------------
# Было: четыре прибитых пула (youtube/google/discord/meta) со списком доменов прямо здесь. Стало:
# любая из ~1381 категории каталога v2fly, выбранная действием «в десинк» в гео (SET_GEO). Список
# доменов, dnsmasq-сниппет и обновление ведёт geo.sh — второй копии каталога не заводим.
GEO_SH="$ENODIA_DIR/geo.sh"
CATS_MIG="$ENODIA_STATE/.zapret-cats.migrated"   # след разового переноса (файл-маркер, он же архив выбора)
# Первый ключ, который знает каталог гео, побеждает: имена категорий v2fly со временем менялись
# (facebook → meta), а «неизвестный ключ» geo.sh отдаёт кодом 1 — на нём и разводим.
geo_set_desync() {
    for _gk in "$@"; do
        sh "$GEO_SH" set "$_gk" desync >/dev/null 2>&1 && { echo "$_gk"; return 0; }
    done
    return 1
}
# РАЗОВЫЙ перенос старого выбора в гео-реестр. Без него апдейт молча стёр бы настройку человека
# («десинк включён, а не десинкает ничего»). Идемпотентен: файл уходит в .migrated и ветка мертва.
migrate_cats() {
    [ -f "$CATS_FILE" ] || return 0
    [ -f "$GEO_SH" ] || return 0
    _mv=""
    for _c in $(tr ',\r\n' '   ' < "$CATS_FILE"); do
        _k=""
        case "$_c" in
            youtube) _k=$(geo_set_desync v2fly-youtube) ;;
            google)  _k=$(geo_set_desync v2fly-google) ;;
            discord) _k=$(geo_set_desync v2fly-discord) ;;
            # «meta» у нас значила Instagram+Facebook разом — в каталоге это разные категории.
            meta)    _k=$(geo_set_desync v2fly-meta v2fly-facebook)
                     _i=$(geo_set_desync v2fly-instagram) && _mv="$_mv $_i" ;;
        esac
        [ -n "$_k" ] && _mv="$_mv $_k"
    done
    mv "$CATS_FILE" "$CATS_MIG" 2>/dev/null
    if [ -n "$_mv" ]; then
        log "категории перенесены в гео (действие «в десинк»):$_mv"
        # Сборку пула гоним ФОНОМ (может уйти в сеть за списками): десинк не должен ждать её,
        # правила на пустой сет уже стоят и подхватят адреса, как только гео их положит.
        start-stop-daemon -S -b -m -p /tmp/enodia-zapret-migrate.pid -x /bin/sh -- "$GEO_SH" apply >/dev/null 2>&1 || true
    else
        log "перенос категорий: совпадений в каталоге гео не нашлось (выбор сохранён в $CATS_MIG)"
    fi
}

# ---- стратегия (аргументы nfqws) --------------------------------------------
# Санитайз под charset аргументов nfqws (буквы/цифры/пробел/-+,.:/=_@). @ — для токенов фейков.
strip_sani() {
    printf '%s' "$1" | tr '\r\n' '  ' \
        | sed 's#[^A-Za-z0-9 +,.:/=_@-]##g; s#[[:space:]]\{1,\}# #g; s#^ ##; s# $##'
}
# Аргументы из .zapret-args (непустой, без #-комментов) либо DEFAULT_ARGS.
desync_args() {
    if [ -s "$ARGS_FILE" ]; then
        a=$(grep -vE '^[[:space:]]*#' "$ARGS_FILE" 2>/dev/null | tr '\n' ' ')
        a=$(strip_sani "$a")
        [ -n "$a" ] && { echo "$a"; return; }
    fi
    echo "$DEFAULT_ARGS"
}
# Подставить пути фейков вместо токенов @tls/@quic (перед запуском nfqws).
resolve_args() { printf '%s' "$1" | sed "s#@tls#$TLS_BIN#g; s#@quic#$QUIC_BIN#g"; }

# ---- ресурсы (фейки + ipset) -------------------------------------------------
ensure_fakes() {
    [ -s "$TLS_BIN" ]  || printf '%s' "$TLS_B64"  | base64 -d > "$TLS_BIN"  2>/dev/null
    [ -s "$QUIC_BIN" ] || printf '%s' "$QUIC_B64" | base64 -d > "$QUIC_BIN" 2>/dev/null
}
# Создаём ОБА пула всегда, даже когда CIDR-пул пуст/выключен: правило `-m set --match-set` не
# вставляется, если сета нет, а порядок «кто первый — zapret или менеджер источников» не задан.
# Пустой ipset ничего не стоит и ничего не матчит. Параметры CIDR-пула СОВПАДАЮТ с apply_ipset
# (hashsize 4096) — тот заливается через `ipset swap`, а swap требует одинакового типа набора.
ensure_set() {
    ipset list -n 2>/dev/null | grep -qx "$SET" || \
        ipset create "$SET" hash:net family inet hashsize 1024 maxelem 1000000
    ipset list -n 2>/dev/null | grep -qx "$SET_CIDR" || \
        ipset create "$SET_CIDR" hash:net family inet hashsize 4096 maxelem 1000000
    # Свой доменный пул: параметры СОВПАДАЮТ с ensure_dom_set в lists-update.sh (кто первый создал —
    # тот и создал; наборы наполняет dnsmasq, swap'а тут нет, но тип обязан быть один и тот же).
    ipset list -n 2>/dev/null | grep -qx "$SET_DOM" || \
        ipset create "$SET_DOM" hash:net family inet hashsize 1024 maxelem 1000000
    # Гео-пул: параметры СОВПАДАЮТ с ensure_set/fill_set в geo.sh (hashsize 4096) — тот заливает
    # набор через `ipset swap`, а swap требует одинакового типа. Создаём и мы: правило `-m set` не
    # вставится, если сета нет, а кто первым дойдёт (zapret или гео) — не задано.
    ipset list -n 2>/dev/null | grep -qx "$SET_GEO" || \
        ipset create "$SET_GEO" hash:net family inet hashsize 4096 maxelem 1000000
}

# Сводка «сколько адресов в каком пуле» — для лога и status. Печатать список категорий, как раньше,
# больше нечего: состав задают гео-реестр и менеджер источников, каждый со своим экраном.
pool_summary() {
    _ps=""
    for _zs in $ZAPRET_SETS; do
        _pn=$(ipset list "$_zs" 2>/dev/null | grep -c '^[0-9]'); case "$_pn" in ''|*[!0-9]*) _pn=0 ;; esac
        _ps="$_ps $_zs=$_pn"
    done
    printf '%s' "${_ps# }"
}

# ---- dnsmasq-сниппет (домены → zapret_set) ----------------------------------
# ГРАБЛЯ (поймана 2026-07-25 на железе): стоковый init.d dnsmasq копирует /etc/dnsmasq.d → /tmp/dnsmasq.d
# АДДИТИВНО, без чистки, а читает dnsmasq ЖИВОЙ /tmp. Значит запись в /etc доезжает (рестарт копирует),
# а вот УДАЛЕНИЕ только из /etc — нет: копия в /tmp переживает выключение, и домены продолжают литься в
# zapret_set (после `off` сет так и стоял на 358 адресах). Ровно та же грабля, что у adblock-конфа.
# Лечение: пишем и сносим ОБЕ копии — /etc (переживает рестарт init'а) и /tmp (та, что реально читается).
# Своего сниппета у zapret БОЛЬШЕ НЕТ (домены «в десинк» пишет geo.sh в свой 11-geo.conf). Удаление
# осталось и зовётся на КАЖДОМ apply: у обновлённых установок в /etc и /tmp лежит старый 04-zapret.conf
# со вшитой четвёркой — не снеся его, dnsmasq продолжал бы лить те домены в zapret_set вечно.
del_dnsmasq() {
    [ -f "$DNSMASQ_SNIPPET" ] || [ -f "$DNSMASQ_LIVE" ] || return 0
    rm -f "$DNSMASQ_SNIPPET" "$DNSMASQ_LIVE"
    # Через агрегатор: снятый файл мог участвовать в склейке — её надо пересобрать, иначе в
    # агрегате остались бы наборы уже несуществующего правила (протухшая склейка перебивает
    # источники, то есть хуже её отсутствия). Нет агрегатора → прежний путь.
    sh "$ENODIA_DIR/dns-merge.sh" reload 2>/dev/null \
        || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ---- DNS (прямой, без туннеля) — ТОЛЬКО когда zapret = активный транспорт -----------
# Зеркало set_direct_dns из transport-byedpi.sh. Туннеля нет → dnsmasq должен резолвить через
# ПУБЛИЧНЫЙ upstream, а не «server=VPN_DNS dev awg0» (это и есть DNS-SPOF: при мёртвом туннеле
# не резолвится НИЧЕГО). Плюс RETURN для самих резолверов в OUTPUT/PREROUTING: их IP часто ∈
# iplist_set → иначе апстрим dnsmasq метился бы в table 1000 (хоть она и пуста без несущей —
# держим симметрию с byedpi и страхуемся от залипшего маршрута).
dns_direct_rules() {   # $1 = add|del
    for d in "$DNS1" "$DNS2"; do
        for ch in OUTPUT PREROUTING; do
            if [ "$1" = del ]; then
                while iptables -t mangle -C "$ch" -d "$d" -j RETURN 2>/dev/null; do
                    iptables -t mangle -D "$ch" -d "$d" -j RETURN 2>/dev/null || break
                done
            else
                iptables -t mangle -C "$ch" -d "$d" -j RETURN 2>/dev/null || \
                    iptables -t mangle -I "$ch" 1 -d "$d" -j RETURN
            fi
        done
    done
}
set_dnsmasq_direct() {
    dns_upstream_put "$DNS1" "$DNS2"
}
set_direct_dns() {
    doh_apply_dns direct && return 0    # DoH ВКЛ/авто → резолв через локальный прокси (резолвер :443 мимо марки); иначе → ниже
    dns_direct_rules add
    set_dnsmasq_direct
}

# ---- iptables-правила (идемпотентно) ----------------------------------------
# АНТИ-ПЕТЛЯ (общая для транспорта и слотов): реинъекты nfqws штампуются меткой 0x40000000,
# их dst часто ∈ iplist_set → mark-core OUTPUT иначе увёл бы их в туннель → EPERM (rawsend).
# RETURN выводит реинъекты мимо маркировки. Нужна ВСЕГДА, пока жив nfqws (любой потребитель).
nfq_antiloop() {   # add|del
    if [ "$1" = del ]; then
        while iptables -t mangle -D OUTPUT -m mark --mark "$MARKM" -j RETURN 2>/dev/null; do :; done
    else
        iptables -t mangle -C OUTPUT -m mark --mark "$MARKM" -j RETURN 2>/dev/null || \
            iptables -t mangle -I OUTPUT 1 -m mark --mark "$MARKM" -j RETURN
    fi
}
# --- цепочка ПУЛОВ десинка (ENODIA_ZAPRET) --------------------------------------
# ЗАЧЕМ ОТДЕЛЬНАЯ ЦЕПОЧКА (ревью 04.08.2026). ACCEPT'ы пулов жили прямо в mangle PREROUTING на
# позиции 1 — мимо ensure_prerouting_order из apply-bypass.sh, объявленного ЕДИНСТВЕННЫМ владельцем
# порядка. Итог: приоритет «пул десинка против правил устройства» решал тот, кто отработал
# ПОСЛЕДНИМ (мы или переигрыш цепочек), то есть был лотереей. Теперь правила лежат в своей цепочке,
# а её место назначает владелец — в самом низу, ПОД правилами конкретного устройства (порты/адреса/
# keep/мимо VPN/целиком в VPN), но ВЫШЕ базовой маркировки mark-core, ради чего ACCEPT и нужен.
# Владельцы разные и каждый у себя: что десинкать — мы, где это стоит — apply-bypass.
ZCHAIN=ENODIA_ZAPRET
APPLY_SH="$ENODIA_DIR/apply-bypass.sh"
zt_chain_ensure() {
    iptables -t mangle -L "$ZCHAIN" -n >/dev/null 2>&1 || iptables -t mangle -N "$ZCHAIN"
    # Позиция 1 — лишь СТАРТОВАЯ (и точный фолбэк на прежнее поведение, если apply-bypass нет):
    # сразу следом порядок переигрывает владелец и опускает нас под свои цепочки. Зовём его ТОЛЬКО
    # когда jump реально появился: rules_add проходит по четырём пулам, и безусловный вызов давал бы
    # четыре форка тяжёлого apply-bypass на каждый apply/rewire вместо одного за цикл жизни цепочки.
    if ! iptables -t mangle -C PREROUTING -j "$ZCHAIN" 2>/dev/null; then
        iptables -t mangle -I PREROUTING 1 -j "$ZCHAIN"
        [ -f "$APPLY_SH" ] && sh "$APPLY_SH" order >/dev/null 2>&1
    fi
    return 0
}
# Пустая цепочка = снять jump и удалить: у того, кто десинком не пользуется, набор правил
# остаётся БАЙТ-В-БАЙТ прежним (тот же приём, что у rebuild_ports/rebuild_keep в apply-bypass).
zt_chain_gc() {
    iptables -t mangle -L "$ZCHAIN" -n >/dev/null 2>&1 || return 0
    _zc=$(iptables -t mangle -S "$ZCHAIN" 2>/dev/null | grep -c '^-A')
    case "$_zc" in ''|*[!0-9]*) _zc=0 ;; esac   # busybox: grep -c при нуле даёт код 1
    [ "$_zc" -gt 0 ] && return 0
    iptables -t mangle -D PREROUTING -j "$ZCHAIN" 2>/dev/null
    iptables -t mangle -X "$ZCHAIN" 2>/dev/null
    return 0
}
# УМЕЕТ ЛИ ЭТА СБОРКА iptables ВООБЩЕ NFQUEUE. Без ответа на этот вопрос zapret рапортует успех
# на роутере, где десинка физически быть не может: замерено на AX3600 (ядро 4.4.60, iptables
# 1.6.2) — `/usr/lib/iptables/` НЕ содержит `libxt_NFQUEUE.so`, каждая постановка правила даёт
# «unknown option "--queue-num"», а `transport.sh switch zapret` при этом снял AmneziaWG, написал
# «десинк ВКЛ», записал .transport=zapret и вернул rc=0. В панели — «Zapret активен», по факту:
# NFQUEUE-правил ноль, nfqws даже не запущен, VPN снят. Хуже мёртвого десинка только мёртвый
# десинк, который считает себя живым.
# Проба — В СВОЕЙ временной цепочке (не в боевых): так неудачная попытка ничего не задевает, а
# удачная не оставляет следа. Результат кэшируем на /tmp: за прогон нас зовут многократно, а
# ответ меняется только с прошивкой.
NFQ_CAP=/tmp/.enodia-zapret-nfq-cap
nfq_supported() {
    [ -f "$NFQ_CAP" ] && { [ "$(cat "$NFQ_CAP" 2>/dev/null)" = 1 ]; return $?; }
    # `-w` ОБЯЗАТЕЛЕН и на пробе: спрашивают нас из CGI панели и из тика сторожа, а в это же время
    # apply-bypass/geo/mark-core держат xtables-лок.
    iptables -t mangle -N ENODIA_NFQ_PROBE 2>/dev/null
    iptables -t mangle -A ENODIA_NFQ_PROBE -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null
    _nfqrc=$?
    iptables -t mangle -F ENODIA_NFQ_PROBE 2>/dev/null
    iptables -t mangle -X ENODIA_NFQ_PROBE 2>/dev/null
    # ЗАПОМИНАЕМ ТОЛЬКО ОДНОЗНАЧНЫЙ ОТВЕТ. Замерено 15.08.2026 на обоих роутерах (iptables 1.6.2):
    # 0 = правило встало (умеет), 2 = «unknown option "--queue-num"» (не умеет). ЛЮБОЙ другой код —
    # это не ответ про NFQUEUE, а сбой вызова: 4 = занят xtables-лок. Записав его, мы заперли бы
    # РАБОЧИЙ роутер в «десинк здесь невозможен» до ребута — транспорт исчезает из списка, кнопка
    # в панели гаснет, `up` отказывает, и всё это из-за секундной гонки за локом. Тот же принцип,
    # что у `ipt_check` в стороже: код ≠ 0/1 = «не смог проверить», а не «нельзя».
    case "$_nfqrc" in
        0) echo 1 > "$NFQ_CAP" 2>/dev/null; return 0 ;;
        2) echo 0 > "$NFQ_CAP" 2>/dev/null; return 1 ;;
        *) log "nfq-проба: iptables дал код $_nfqrc (лок занят/сбой вызова) — НЕ сужу, ответ не кэширую"
           return 0 ;;
    esac
}
# ACCEPT (мимо туннеля) + scoped NFQUEUE (десинк хэндшейка) для ОДНОГО сета. Общий кирпич:
# зовёт транспорт (SET=zapret_set) и zapret-СЛОТ (grp_vpn_sN/geo_vpn_sN — десинк рядом с VPN).
# ACCEPT в ENODIA_ZAPRET (выше базовой маркировки mark-core) → сайты сета идут ПРЯМО, даже
# если их IP ∈ iplist_set (иначе ушли бы в туннель, а не в десинк). Идемпотентно.
nfq_set_rules() {   # <set> <add|del>
    _ns="$1"
    # ЛЕГАСИ-ФОРМА: до 08.2026 тот же ACCEPT лежал прямо в PREROUTING. Снимаем её ВСЕГДА — и на
    # add тоже: правила живут в RAM до ребута, и после обновления скриптов старая копия осталась
    # бы ВЫШЕ всех цепочек, продолжая перебивать правила устройства (то самое, что мы чиним).
    while iptables -t mangle -D PREROUTING -m set --match-set "$_ns" dst -j ACCEPT 2>/dev/null; do :; done
    if [ "$2" = del ]; then
        while iptables -t mangle -D "$ZCHAIN" -m set --match-set "$_ns" dst -j ACCEPT 2>/dev/null; do :; done
        for proto in tcp udp; do
            while iptables -t mangle -D POSTROUTING -p $proto --dport 443 -m set --match-set "$_ns" dst $CB -m mark ! --mark "$MARKM" -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null; do :; done
        done
        zt_chain_gc
    else
        zt_chain_ensure
        iptables -t mangle -C "$ZCHAIN" -m set --match-set "$_ns" dst -j ACCEPT 2>/dev/null || \
            iptables -t mangle -A "$ZCHAIN" -m set --match-set "$_ns" dst -j ACCEPT
        for proto in tcp udp; do
            iptables -t mangle -C POSTROUTING -p $proto --dport 443 -m set --match-set "$_ns" dst $CB -m mark ! --mark "$MARKM" -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || \
                iptables -t mangle -I POSTROUTING 1 -p $proto --dport 443 -m set --match-set "$_ns" dst $CB -m mark ! --mark "$MARKM" -j NFQUEUE --queue-num "$QNUM" --queue-bypass
        done
    fi
}
# ---- ДЕСИНК ПО ИСТОЧНИКУ («устройство целиком в десинк») ----------------------
# ЗАЧЕМ ОТДЕЛЬНЫЙ КИРПИЧ. Всё выше матчит по адресу НАЗНАЧЕНИЯ (ipset), а значит работает только
# для клиентов НАШЕГО dnsmasq: доменные пулы наполняются по ответам резолвера, и приставка/ТВ со
# своим DoH в них не попадает НИКОГДА (грабля «правило по доменам = правило для ЧАСТИ устройств»).
# Правило по ИСТОЧНИКУ от DNS не зависит вовсе — это единственный способ дать десинк такому
# устройству. Оно же закрывает «направить устройство целиком в zapret-выход»: марки у zapret нет,
# и до 08.2026 движок такое назначение честно отклонял (правило было бы вечно мёртвым).
#
# ЧТО СТАВИМ. Только POSTROUTING-NFQUEUE: «идти напрямую» устройству обеспечивает ACCEPT в
# VPN_EXCLUDE, который ставит apply-bypass (владелец порядка цепочек — он, своих `-I PREROUTING`
# мы не заводим). Без прямого пути десинк был бы вреден: nfqws резал бы пакеты УЖЕ ВНУТРИ
# туннеля (та же грабля, из-за которой пробу десинка меряют клиентским путём, а не с роутера).
#
# ГРАНИЦА ЧЕСТНО. Десинкуется рукопожатие 443 (TCP+QUIC), как и у всех прочих потребителей: connbytes
# 1:8 ловит ClientHello до offload-акселерации. «Целиком» здесь = «весь трафик устройства идёт
# напрямую, а его TLS/QUIC-рукопожатия проходят через nfqws», а не «каждый его пакет через nfqws».
nfq_src_rules() {   # <ip> <add|del>
    _si="$1"
    if [ "$2" = del ]; then
        for proto in tcp udp; do
            while iptables -t mangle -D POSTROUTING -s "$_si" -p $proto --dport 443 $CB -m mark ! --mark "$MARKM" -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null; do :; done
        done
    else
        for proto in tcp udp; do
            iptables -t mangle -C POSTROUTING -s "$_si" -p $proto --dport 443 $CB -m mark ! --mark "$MARKM" -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || \
                iptables -t mangle -I POSTROUTING 1 -s "$_si" -p $proto --dport 443 $CB -m mark ! --mark "$MARKM" -j NFQUEUE --queue-num "$QNUM" --queue-bypass
        done
    fi
}
# Правила ТРАНСПОРТА (весь дом через десинк) — на ВСЕ пулы сразу (категории + CIDR + свои домены,
# см. ZAPRET_SETS).
# Анти-петлю снимает НЕ здесь, а teardown под гардом (её может держать активный zapret-СЛОТ рядом
# с VPN — тогда nfqws/анти-петля живут).
rules_add() { for _zs in $ZAPRET_SETS; do nfq_set_rules "$_zs" add; done; nfq_antiloop add; }
rules_del() { for _zs in $ZAPRET_SETS; do nfq_set_rules "$_zs" del; done; }

# ---- демон nfqws ------------------------------------------------------------
# ЗАПУСК ЧЕРЕЗ `sh -c exec`, а не напрямую бинарём. Причина: `start-stop-daemon -b` заворачивает
# stdio демона в /dev/null, поэтому $NFQ_LOG был пуст ВСЕГДА — и ветка «не перезапустился, вот лог»
# показывала пустоту ровно тогда, когда причина (отвергнутый флаг стратегии) уходила в stderr.
# `exec` заменяет sh самим nfqws, так что пид в пидфайле остаётся пидом демона, а `ps | grep nfqws`
# по-прежнему его видит. Аргументы уже прошли strip_sani (ни кавычек, ни $) ⇒ подстановка безопасна.
spawn_nfqws() {
    : > "$NFQ_LOG" 2>/dev/null || true
    args=$(resolve_args "$(desync_args)")
    start-stop-daemon -S -b -m -p "$NFQ_PID" -x /bin/sh -- -c "exec '$NFQWS' --qnum=$QNUM $args >>'$NFQ_LOG' 2>&1"
}
stop_nfqws() {
    start-stop-daemon -K -p "$NFQ_PID" 2>/dev/null
    kill "$(cat "$NFQ_PID" 2>/dev/null)" 2>/dev/null
    rm -f "$NFQ_PID" 2>/dev/null
}
# Код возврата ЧЕСТНЫЙ: `start-stop-daemon -S -b` отдаёт 0 за факт ФОРКА, а не за живой демон, и
# отвергнутая nfqws стратегия давала «nfqws перезапущен» при фактически ВЫКЛЮЧЕННОМ десинке. Судим
# по ФАКТУ после короткой паузы — тем же приёмом, что уже применён в cmd_t_failover.
restart_nfqws() {
    stop_nfqws
    i=0; while [ $i -lt 3 ]; do ps w 2>/dev/null | grep -q 'nfqw[s]' || break; sleep 1; i=$((i+1)); done
    spawn_nfqws
    sleep 1
    proc_alive "$NFQ_PID" && return 0
    # Демон не встал (битая стратегия/нет прав) — в пидфайле остался ПОКОЙНИК от `sh -c exec`.
    # proc_alive его отбивает верно, но пиды в ядре переиспользуются: дождавшись совпадения,
    # stop_nfqws убил бы ЧУЖОЙ процесс, а slot_state показал бы «up». Чистим за собой.
    rm -f "$NFQ_PID" 2>/dev/null
    return 1
}

# ============================================================
# СНЯТЬ ВСЁ (off / apply при выключенном — идемпотентно для repair/boot). ГАРД: nfqws и
# анти-петлю оставляем жить, если их держит активный zapret-СЛОТ рядом с VPN (Ф1) — иначе
# выключение zapret-транспорта при живом слоте убило бы десинк слота.
teardown() {
    rules_del
    del_dnsmasq
    # Флашим ТОЛЬКО пул КАТЕГОРИЙ — он наш (его наполнял снятый выше сниппет dnsmasq). Пулы
    # менеджера источников (zapret_cidr по IP и zapret_dom со своими доменами) — чужие: у них свой
    # мастер-тумблер и свой снимок, и обнулять их на каждом выключении десинка значило бы терять
    # скачанное и качать заново при включении.
    ipset flush "$SET" 2>/dev/null || true
    # Демон и анти-петля ОБЩИЕ на трёх потребителей (транспорт · доп-выходы · устройства «в
    # десинк»): гасим, только когда не нужны НИКОМУ. Забыть здесь про устройства значило бы
    # «выключил zapret-транспорт — и у ТВ тихо пропал десинк», причём правила остались бы на месте.
    if zt_any_slot_enabled || zt_any_src_wired; then
        ct_flush
        return 0
    fi
    nfq_antiloop del
    stop_nfqws
    ct_flush
}

cmd_apply() {
    if [ ! -f "$ON_FLAG" ]; then
        teardown
        return 0
    fi
    [ -x "$NFQWS" ] || { log "НЕТ бинаря $NFQWS — поставьте Zapret в «Роутер → Компоненты»"; return 1; }
    ensure_fakes
    ensure_set
    del_dnsmasq          # снять легаси-сниппет вшитых категорий (см. комментарий у функции)
    migrate_cats         # разовый перенос старого выбора в гео-реестр
    rules_add
    proc_alive "$NFQ_PID" || spawn_nfqws
    ct_flush
    log "десинк ВКЛ (пулы: $(pool_summary); стратегия: $(desync_args))"
}

# rewire — идемпотентная «досборка» правил под изменившийся пул менеджера источников. Зовёт
# lists-update.sh (zapret-cidr / zapret-dom) после каждой заливки: сет мог не существовать в момент
# cmd_apply (десинк включали раньше, чем пул), и тогда правила на него не встали. Ничего не
# запускает и не гасит: десинк выключен → выходим молча, чтобы наполнение пула не «включало» zapret.
cmd_rewire() {
    ensure_set
    [ -f "$ON_FLAG" ] || return 0
    rules_add
    ct_flush
}

# ВНУТРЕННЯЯ функция (НЕ CLI-verb): teardown + сброс ON_FLAG. Зовут cmd_t_down (релинквиш) и
# cmd_remove. Своего verb'а `off` нет умышленно: zapret теперь ТРАНСПОРТ — снимать его надо через
# оркестратор (`transport.sh down zapret` / switch на другой), иначе ON_FLAG и .transport разойдутся.
cmd_off() { rm -f "$ON_FLAG"; teardown; log "десинк ВЫКЛ (правила сняты, nfqws остановлен, набор сброшен)"; }

# ============================================================
# ТРАНСПОРТ-АДАПТЕР (zapret как 5-й транспорт; зовёт ОРКЕСТРАТОР transport.sh через plugin_for).
# Контракт up|down|health|failover — над cmd_on/cmd_off/cmd_apply + прямой DNS (туннеля нет).
# ON_FLAG здесь = «zapret несёт трафик» ⇔ .transport=zapret (их двигает switch/up/down вместе).
#
# up   — поднять несущую: ON_FLAG + apply (nfqws/правила/ipset/dnsmasq-сниппет) + ПРЯМОЙ DNS +
#        .transport=zapret. .transport дублируем (как byedpi cmd_up) — heal зовёт `up` без switch.
# down — ЧИСТЫЙ релинквиш: teardown (cmd_off) + снять DNS-RETURN + dnsmasq на прямой резолвер
#        (fail-open до подъёма следующего транспорта). НЕ решает, что поднять следом (забота switch).
# health   — жив ли nfqws (бинарь + демон). Для watchdog: 0 здоров / 1 нет.
# failover — резервов-серверов нет (десинк локальный) → САМО-ИЗЛЕЧЕНИЕ: переподнять nfqws на месте
#            (как byedpi reup), 0 при успехе → watchdog остаётся на zapret; 1 → эскалация (но
#            cmd_next zapret пуст → оркестратор уводит в прямой режим, НЕ на VPS).
cmd_t_up() {
    [ -x "$NFQWS" ] || { log "up: НЕТ бинаря $NFQWS — поставьте Zapret в «Роутер → Компоненты»"; return 1; }
    # ГАРД ДО ЛЮБОГО ДЕЙСТВИЯ: отказ обязан быть ПУСТЫМ — ни ON_FLAG, ни DNS, ни .transport, иначе
    # оркестратор уже снял прежнюю несущую, а взамен встало «активно, но не работает» (разбор в
    # шапке nfq_supported). Порядок именно такой: сначала спросить, потом ломать.
    nfq_supported || {
        log "up: сборка iptables на этом роутере не умеет NFQUEUE (нет libxt_NFQUEUE) — десинк здесь невозможен"
        log "up: остаюсь без изменений; используйте VPN-транспорт (AmneziaWG/Xray/Hysteria2) или ByeDPI"
        return 1
    }
    touch "$ON_FLAG"
    cmd_apply || return 1
    set_direct_dns
    echo zapret > "$TRANSPORT_FLAG"
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    carrier_up_mark         # грейс сторожу: демоны стартовали, но egress поднимается ещё секунды (clock-lib.sh)
    ct_flush
    log "транспорт = ZAPRET (десинк направо, БЕЗ VPS; весь трафик напрямую, категории через nfqws)"
}
cmd_t_down() {
    cmd_off                 # rm ON_FLAG + teardown (правила/nfqws/dnsmasq-сниппет/ipset)
    dns_direct_rules del    # снять наши DNS-RETURN (следующий транспорт поставит свой DNS)
    set_dnsmasq_direct      # dnsmasq на прямой резолвер — fail-open до подъёма следующего транспорта
    rm -f /tmp/enodia-watchdog.xstate /tmp/enodia-failover-episode 2>/dev/null
    log "Zapret-несущая снята (релинквиш) → прямой режим. Следующий транспорт ставит оркестратор."
}
cmd_t_health() { [ -x "$NFQWS" ] && proc_alive "$NFQ_PID"; }
cmd_t_failover() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')
    [ "$t" = zapret ] || { log "failover: zapret не активен → эскалация на оркестраторе"; return 1; }
    if sweep_fresh; then log "failover: идёт браузер-свип — не вмешиваюсь"; return 0; fi
    log "failover: переподнимаю nfqws на месте (резервов-серверов нет — десинк локальный)…"
    touch "$ON_FLAG"; cmd_apply >/dev/null 2>&1
    proc_alive "$NFQ_PID" && { log "failover: nfqws снова жив — остаёмся на zapret"; return 0; }
    log "failover: nfqws переподнять не удалось → эскалация на оркестраторе (прямой режим)"; return 1
}

# ============================================================
# ZAPRET-СЛОТ (десинк рядом с VPN, Ф1). В отличие от zapret-ТРАНСПОРТА (весь дом напрямую) слот
# НЕ несущая: активный транспорт остаётся VPN, а сеты слота (grp_vpn_sN/geo_vpn_sN, наполняют
# groups.sh/geo.sh) выводятся из туннеля (ACCEPT) и десинкаются nfqws. nfqws/анти-петля/фейки —
# ОБЩИЕ с транспортом (queue 212, одна стратегия .zapret-args на всех потребителей). Зовёт
# ОРКЕСТРАТОР (transport.sh slot-up/slot-down → _slot_dispatch). Контракт: 0 = сделано, 1 = сбой
# (нет бинаря/битый id). Марок/таблиц у zapret-слота НЕТ — mark-core его сеты пропускает.
zt_slot_sets() { echo "grp_vpn_s$1 geo_vpn_s$1"; }
# СЕТ СЛОТА СОЗДАЁМ САМИ, ЕСЛИ ЕГО ЕЩЁ НЕТ. У zapret-ТРАНСПОРТА эта развилка решена давно
# (`ensure_set` создаёт свои наборы пустыми — пустой ipset ничего не стоит, «кто первый создал»
# не задано), а у СЛОТА её не было, и цена оказалась высокой: `slots.sh::slot_activate` зовёт
# `slot-up` ДО `rebind_owners`, поэтому в момент включения выхода наборов ещё нет — их создают
# groups.sh и geo.sh позже, а гео вообще фоном. Пропуская несуществующий набор, мы не ставили
# правил вовсе, и переиграть было некому (сторож zapret-слоты пропускает НАМЕРЕННО: несущей у
# них нет; `slots-up` бежит только на буте и в `vpn-toggle repair`). Симптом с железа: «создал
# выход → привязал категорию → не работает до ребута» (разбор 07.09.2026).
# ПАРАМЕТРЫ ОБЯЗАНЫ СОВПАДАТЬ С ВЛАДЕЛЬЦАМИ набора: наполнение идёт через `ipset swap` с
# временным набором того же имени, а swap наборов разного типа ядро отвергает — и наполнение
# молча не доехало бы. groups.sh: hashsize 1024 maxelem 65536; geo.sh: 4096 / 1000000.
zt_ensure_slot_set() {
    ipset list -n 2>/dev/null | grep -qx "$1" && return 0
    case "$1" in
        geo_vpn_s*) ipset create "$1" hash:net hashsize 4096 maxelem 1000000 2>/dev/null ;;
        *)          ipset create "$1" hash:net hashsize 1024 maxelem 65536   2>/dev/null ;;
    esac
}
cmd_slot_up() {   # <id> <config-игнор> — поднять zapret-десинк для сетов слота
    _id="$1"
    case "$_id" in 2|3|4) ;; *) log "slot-up: битый id '$_id'"; return 1 ;; esac
    [ -x "$NFQWS" ] || { log "slot-up: НЕТ бинаря $NFQWS — установите (панель «Zapret»)"; return 1; }
    # …и БИНАРЯ МАЛО — второй признак обязателен здесь ровно так же, как в cmd_t_up: nfqws едет
    # бутстрапом, поэтому на ядре без NFQUEUE (AX3600, 4.4) файл на месте, а очереди нет. Замерено
    # на импорте бэкапа 17.08: слот «zapret» приехал включённым, гард пропустил по `-x`, демон
    # поднялся и тут же умер (`nfq_unbind_pf(): Invalid argument`). Отказ ДО любого действия.
    nfq_supported || {
        log "slot-up: сборка iptables на этом роутере не умеет NFQUEUE (нет libxt_NFQUEUE) — выход-десинк здесь невозможен"
        log "slot-up: ничего не меняю; обход без VPS на этом железе даёт ByeDPI"
        return 1
    }
    ensure_fakes
    # ПРАВИЛА СТАВИМ ВСЕГДА, а наборы при необходимости создаём пустыми (см. zt_ensure_slot_set).
    # Прежняя логика «есть набор — ставим, нет — пропускаем» выглядела бережной, а на деле давала
    # ЕДИНСТВЕННЫЙ исход «выход включён, правил нет»: в момент включения наборов ещё не бывает
    # никогда. Пустой набор ничего не заворачивает — правило на нём столь же безвредно, сколько
    # и бесполезно, ровно до первой привязки; зато привязка начинает работать САМА, без ребута.
    for _s in $(zt_slot_sets "$_id"); do
        zt_ensure_slot_set "$_s"
        # СУДИМ ПО ФАКТУ, а не по коду create: набор мог не создаться (нет прав, занято чужим
        # типом). Правило на несуществующий сет iptables отвергает — и молча, потому что stderr
        # тут глушится: получилось бы ровно то, что чиним, только без следов в логе.
        if ! ipset list -n 2>/dev/null | grep -qx "$_s"; then
            log "слот №$_id: набор $_s не создан — правило не ставлю (десинк этого набора не заработает)"
            continue
        fi
        nfq_set_rules "$_s" add
    done
    nfq_antiloop add
    proc_alive "$NFQ_PID" || spawn_nfqws
    ct_flush
    log "слот №$_id: zapret-десинк рядом с VPN (сеты grp_vpn_s$_id/geo_vpn_s$_id; стратегия: $(desync_args))"
    log "слот №$_id: правила стоят заранее — пока наборы пусты, десинк ничего не заворачивает и включится сам при первой привязке группы или гео-категории"
    return 0
}
cmd_slot_down() {   # <id> — снять zapret-десинк слота
    _id="$1"
    case "$_id" in 2|3|4) ;; *) return 1 ;; esac
    for _s in $(zt_slot_sets "$_id"); do nfq_set_rules "$_s" del; done
    # nfqws/анти-петля ОБЩИЕ: гасим, только если не нужны НИ транспорту, НИ ДРУГОМУ zapret-слоту,
    # НИ устройствам «целиком в десинк» (правила по источнику живут отдельно от слотов).
    if ! zt_transport_active && ! zt_any_slot_enabled "$_id" && ! zt_any_src_wired; then
        nfq_antiloop del
        stop_nfqws
    fi
    ct_flush
    log "слот №$_id: zapret-десинк снят"
    return 0
}

# ============================================================
# УСТРОЙСТВО ЦЕЛИКОМ В ДЕСИНК (правила по ИСТОЧНИКУ). ТРЕТИЙ потребитель общего nfqws — наравне
# с транспортом и доп-выходами. Список устройств ведёт apply-bypass.sh (режим устройства, файл
# .desync-ips, он же ставит ACCEPT «идти напрямую»); здесь — ТОЛЬКО проводка NFQUEUE и жизненный
# цикл демона. Два владельца, каждый у себя: ровно как VPN_DEV (реестр у groups.sh, цепочка у
# apply-bypass) — иначе один и тот же список парсили бы двое.
# Контракт: 0 = сделано, 1 = нельзя (нет бинаря / битый IP) — вызывающий обязан честно отказать
# человеку, а не молча записать режим, которого на роутере нет.
cmd_src_wire() {   # <ip>
    _sip=$(printf '%s' "$1" | tr -d ' \r\n')
    echo "$_sip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { log "src-wire: нужен IPv4"; return 1; }
    [ -x "$NFQWS" ] || { log "src-wire: НЕТ бинаря $NFQWS — поставьте Zapret в «Роутер → Компоненты»"; return 1; }
    # Третий потребитель того же nfqws (устройство «целиком в десинк») — и ему бинаря так же мало.
    nfq_supported || {
        log "src-wire: сборка iptables на этом роутере не умеет NFQUEUE (нет libxt_NFQUEUE) — десинк по источнику невозможен"
        log "src-wire: ничего не меняю; обход без VPS на этом железе даёт ByeDPI"
        return 1
    }
    ensure_fakes
    nfq_src_rules "$_sip" add
    nfq_antiloop add
    proc_alive "$NFQ_PID" || spawn_nfqws
    # Точечно по источнику: рвать сессии всей сети из-за одного устройства незачем (зеркало
    # ports_conntrack в apply-bypass). Без сброса NSS/ECM держал бы старый путь до таймаута.
    ct_flush_src "$_sip"
    log "устройство $_sip: десинк по источнику ВКЛ (стратегия: $(desync_args))"
    return 0
}
cmd_src_unwire() {   # <ip>
    _sip=$(printf '%s' "$1" | tr -d ' \r\n')
    echo "$_sip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    nfq_src_rules "$_sip" del
    if ! zt_transport_active && ! zt_any_slot_enabled && ! zt_any_src_wired; then
        nfq_antiloop del
        stop_nfqws
    fi
    ct_flush_src "$_sip"
    log "устройство $_sip: десинк по источнику снят"
    return 0
}
# Что РЕАЛЬНО проводнено в mangle (по строке на IP) — машинный ответ для владельца списка:
# apply-bypass сверяет им своё хранилище и снимает осиротевшее. Источник истины про ПРАВИЛА —
# сам mangle, а не файл: после fw3-reload/ребута правил нет, а файл на месте (и наоборот).
cmd_src_list() {
    iptables -t mangle -S POSTROUTING 2>/dev/null \
        | grep -e "--queue-num $QNUM" \
        | sed -n 's/^-A POSTROUTING -s \([0-9.]*\)\/32 .*/\1/p' | sort -u
}
# Снять ВСЕ правила по источнику разом — не зная списка (его владелец может быть уже удалён:
# зовут uninstall.sh и cmd_remove). Демон здесь НЕ гасим: у cmd_remove следом идёт cmd_off, а
# uninstall.sh снимает несущую своим порядком (правила → демоны).
cmd_src_clear() {
    for _sip in $(cmd_src_list); do nfq_src_rules "$_sip" del; done
    return 0
}

# ============================================================
# НЕЗАВИСИМАЯ установка/удаление nfqws (фоном из панели — mirror proto-install). zapret —
# ОРТОГОНАЛЬНЫЙ транспорт: в отличие от xray/hy2/byedpi он НЕ занимает единственную alt-ось, а
# ставится отдельным бинарём (~0.13 МБ) ПОВЕРХ любого набора протоколов или вовсе без VPS, поэтому
# доустанавливается независимо. Бинарь nfqws с ПК (be7000) кладётся всегда, НО панель умеет до/переустановить
# его сама: фоновая закачка через gh-update fetch-bin + прогресс в .zapret-install.{state,log}
# (RUNNING/OK/FAIL), фронт поллит. НЕ трогает активную несущую (awg/xray/hy2/byedpi).
# Файл ПРОГРЕССА, который опрашивает панель, пишем АТОМАРНО (рядом + `mv`): `>` сперва обрезает, и опрос в это окно читал пусто —
# «кончилось» до конца (разбор у packages.sh::set_state; следит C105).
iset_state() { echo "$1" > "$INSTALL_STATE.new" && mv -f "$INSTALL_STATE.new" "$INSTALL_STATE"; }
ilog() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$INSTALL_LOG"; }

cmd_install() {   # $1 = update — заменить стоящий nfqws свежей сборкой (решает движок компонентов по bin-status)
    : > "$INSTALL_LOG"; iset_state RUNNING
    _zwas=0; [ -x "$NFQWS" ] && _zwas=1
    if [ "$_zwas" = 1 ] && [ "$1" != update ]; then
        # Бинарь уже на месте — НЕ переигрываем правила (не дёргаем conntrack/dnsmasq зря); лишь
        # подстрахуем наличие фейков. Если десинк включён — он и так уже живёт.
        ensure_fakes
        iset_state OK; ilog "nfqws уже установлен — качать ничего не нужно"; return 0
    fi
    # `-f`: апдейтер зовут через `sh "$GH"`, бит ему не нужен, а сообщение говорит про НАЛИЧИЕ.
    # С `-x` снятый бит давал «нет gh-update.sh» при живом файле — и установка nfqws из панели
    # отказывалась с диагнозом, который уводит чинить не то.
    [ -f "$GH" ] || { iset_state FAIL; ilog "нет gh-update.sh — обновите скрипты"; echo "[zapret] FAIL: нет gh-update.sh — обновите скрипты"; return 1; }
    ilog "Скачиваю nfqws с GitHub (~0.13 МБ)…"
    # fetch-bin тянет bin/<арка>/nfqws.user из публичного repo (atomic .dl→mv + ELF-проверка).
    # Порог обрыва НЕ передаём: gh-update сверяет размер и sha256 с манифестом бинарей (он в пакете кода),
    # иначе после каждой перепаковки UPX это число тут врало.
    # КУДА качать решает bin_dest, а не $NFQWS: тот вычислен при старте скрипта и для
    # отсутствующего файла указывает на /data, то есть мимо накопителя (и мимо того, что
    # обещал план). После закачки ПЕРЕСЧИТЫВАЕМ $NFQWS — им же ниже запускается демон.
    _dst=$(bin_dest nfqws)
    mkdir -p "${_dst%/*}" 2>/dev/null
    if sh "$GH" fetch-bin nfqws "$_dst" >> "$INSTALL_LOG" 2>&1; then
        chmod +x "$_dst" 2>/dev/null
        bin_prune nfqws
        NFQWS=$(bin_path nfqws)
        ensure_fakes
        # ОБНОВЛЕНИЕ правил не переигрывает: живой nfqws продолжает исполнять прежнюю сборку (замена файла его не трогает), а
        # переигрыш дёрнул бы conntrack и dnsmasq ради того, что заработает только после перезапуска демона.
        if [ "$_zwas" = 1 ]; then iset_state OK; ilog "nfqws обновлён. Включённый десинк работает на прежней сборке до перезапуска (проще всего — перезагрузить роутер)"; return 0; fi
        [ -f "$ON_FLAG" ] && cmd_apply >> "$INSTALL_LOG" 2>&1
        iset_state OK; ilog "nfqws установлен. Десинк: $([ -f "$ON_FLAG" ] && echo ВКЛ || echo выключен)"
        return 0
    fi
    # ПРИЧИНА — словами закачки (последняя строка FAIL у fetch-bin: код GitHub, обрыв, целостность), а не догадкой «сеть / нет в
    # repo»; и в stdout строкой «[zapret] FAIL:» — её берёт движок компонентов в «Последнюю операцию» (ревью шага 6c, круг 2).
    # Прежний совет «поставь с ПК» устарел: ПК больше не возит бинари, ставит их только панель.
    _zw=$(grep '^\[fetch-bin\] FAIL: ' "$INSTALL_LOG" 2>/dev/null | tail -n 1 | sed 's/^\[fetch-bin\] FAIL: //')
    [ -n "$_zw" ] || _zw="не скачался nfqws — нет связи с GitHub (или кончилось место)"
    iset_state FAIL; ilog "$_zw"; echo "[zapret] FAIL: $_zw"
    return 1
}

cmd_remove() {
    : > "$INSTALL_LOG"; iset_state RUNNING
    ilog "Удаляю zapret: снимаю правила/nfqws/dnsmasq, выключаю десинк…"
    # Правила по ИСТОЧНИКУ снимаем ПЕРВЫМИ и сами: teardown их не знает (их владелец —
    # apply-bypass), а оставленные висеть они пережили бы удаление бинаря. Внешне это fail-open
    # (`--queue-bypass` пропускает пакеты), но в mangle остался бы мусор, ссылающийся на
    # несуществующую очередь, и ref-count навсегда считал бы демон нужным.
    cmd_src_clear >> "$INSTALL_LOG" 2>&1
    cmd_off >> "$INSTALL_LOG" 2>&1   # teardown + сброс .zapret-on (десинк больше не поднимется)
    # Сносим ОБЕ возможные копии — резидентную и на накопителе (зеркало do_remove в packages.sh).
    # Одного `rm "$NFQWS"` мало: bin_path предпочитает накопитель, поэтому забытый на /data файл
    # пережил бы удаление и на следующем старте выдал бы себя за установленный nfqws.
    rm -f "$ENODIA_BIN/nfqws" 2>/dev/null
    [ "$BIN_DIR" != "$ENODIA_BIN" ] && rm -f "$BIN_DIR/nfqws" 2>/dev/null
    iset_state OK; ilog "nfqws удалён, десинк выключен (интернет/туннель не затронуты)."
    return 0
}

# reload — перечитать .zapret-args и перезапустить ТОЛЬКО nfqws (правила/набор не трогаем) → без
# обрыва. Зовёт панель после смены стратегии. Выключено → no-op (применится при следующем on).
cmd_reload() {
    zt_desync_live || { log "reload: десинк выключен — стратегия применится при включении"; return 0; }
    if restart_nfqws; then
        ct_flush
        log "nfqws перезапущен (стратегия: $(desync_args))"
        return 0
    fi
    # Лог теперь РЕАЛЬНО пишется (см. spawn_nfqws): обычная причина — nfqws отверг флаг стратегии.
    log "reload: nfqws не перезапустился — десинк сейчас ВЫКЛЮЧЕН. Стратегия: $(desync_args)"
    log "reload: вывод nfqws:"; tail -n 15 "$NFQ_LOG" 2>/dev/null | grep . || log "  (пусто — бинарь не запустился вовсе?)"
    return 1
}

# categories — ЧТО СЕЙЧАС ДЕСИНКАЕТСЯ по гео (`key|label|адресов`). Панель показывает этим списком
# выбор человека и ведёт его в карточку «Гео» за поиском; своей таблицы категорий у неё больше нет.
cmd_categories() { [ -f "$GEO_SH" ] && sh "$GEO_SH" desync-list 2>/dev/null; return 0; }

cmd_status() {
    on=ВЫКЛ; [ -f "$ON_FLAG" ] && on=ВКЛ
    echo "=== zapret (десинк-direct): $on ==="
    echo "--- в десинк по гео ---"; cmd_categories | sed 's/^/  /' | grep . || echo "  (не выбрано)"
    echo "--- стратегия ---"; desync_args
    echo "--- бинарь ---"; [ -x "$NFQWS" ] && echo "$NFQWS есть" || echo "НЕТ $NFQWS"
    # ВТОРОЙ признак, без которого первого МАЛО: умеет ли ЯДРО перехват. На AX3600/BE3600 (4.4)
    # libxt_NFQUEUE вырезан — nfqws приезжает бутстрапом и лежит, а десинка здесь не будет НИКОГДА.
    # Срез уходит в дамп, то есть в разбор: без этой строки читатель видит «бинарь есть, демон не
    # запущен», ищет причину в стратегии и конфиге и не находит её там в принципе. Ответ у
    # nfq_supported (проба кэширована на /tmp) — своей копии признака не заводим.
    echo "--- NFQUEUE в ядре ---"
    if nfq_supported; then echo "умеет"
    else echo "НЕ умеет (iptables без libxt_NFQUEUE) — десинк на этом роутере невозможен, обход без VPS даёт ByeDPI"; fi
    echo "--- nfqws ---"; proc_alive "$NFQ_PID" && echo "pid $(cat $NFQ_PID) жив" || echo "не запущен"
    for _zs in $ZAPRET_SETS; do
        zn=$(ipset list "$_zs" 2>/dev/null | grep -c '^[0-9]'); echo "--- ipset $_zs (IP): ${zn:-0} ---"
    done
    echo "--- устройства целиком в десинк (по источнику) ---"
    iptables -t mangle -S POSTROUTING 2>/dev/null | sed -n 's/^-A POSTROUTING -s \([0-9.]*\)\/32 .*--queue-num '"$QNUM"'.*/  \1/p' | sort -u | grep . \
        || echo "  (нет)"
    echo "--- правила mangle ---"
    # Цепочка пулов + её место в PREROUTING (позицию держит apply-bypass; строка легаси-формы,
    # если она ещё осталась в RAM у обновлённой установки, тоже видна этим грепом).
    iptables -t mangle -S "$ZCHAIN" 2>/dev/null | grep '^-A' || echo "  $ZCHAIN: нет"
    iptables -t mangle -S PREROUTING 2>/dev/null | grep -e "$ZCHAIN" -e "zapret_" || echo "  PREROUTING: нет"
    iptables -t mangle -S POSTROUTING 2>/dev/null | grep NFQUEUE || echo "  POSTROUTING NFQUEUE: нет"
    iptables -t mangle -S OUTPUT 2>/dev/null | grep "$MARK" || echo "  OUTPUT RETURN (анти-петля): нет"
    echo "--- offload (info; глушить НЕ нужно) ---"
    echo "  ecm stop ipv4/ipv6 = $(cat /sys/kernel/debug/ecm/front_end_ipv4_stop 2>/dev/null)/$(cat /sys/kernel/debug/ecm/front_end_ipv6_stop 2>/dev/null)"
}

# presets — курированная библиотека стратегий nfqws (label|args). Портированы из
# zapret-discord-youtube 1.9.9c (winws-пресеты general / ALT…ALT12 / FAKE TLS AUTO / SIMPLE FAKE):
# из каждого взят основной TCP-десинк-рецепт (port 443) + QUIC-fake-профиль; winws-only (hostlist/
# ipset/filter-l7/wf/game/отдельные .bin-фейки) выкинуты, фейки → токены @tls/@quic. Все флаги
# СВЕРЕНЫ с бинарём на железе (форк = upstream zapret v72.12: multisplit/multidisorder/fakedsplit/
# hostfakesplit, split-seqovl[-pattern], fake-tls-mod=rnd,dupsid,sni=, fooling ts/badseq/md5sig,
# split-pos маркеры sniext/midsld — ВСЕ поддержаны). Один рецепт применяется ко всем выбранным
# категориям (наша ipset-модель). Питает выпадашку и браузер-свип.
cmd_presets() {
    cat <<'PRESETS'
Авто — multidisorder + QUIC (по умолчанию)|
Только QUIC fake (YouTube QUIC)|--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Multisplit seqovl=568 (general)|--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1 --dpi-desync-split-seqovl=568 --dpi-desync-split-seqovl-pattern=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Multisplit seqovl=652 pos=2 (ALT2)|--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=2 --dpi-desync-split-seqovl=652 --dpi-desync-split-seqovl-pattern=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Fake+fakedsplit fooling=ts (ALT)|--filter-tcp=443 --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Fake fooling=ts (SIMPLE FAKE, лёгкий)|--filter-tcp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Fake TLS AUTO — multidisorder+SNI (FAKE TLS AUTO)|--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Fake badseq-increment (ALT8)|--filter-tcp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=2 --dpi-desync-fake-tls=@tls --dpi-desync-fake-tls-mod=none --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Hostfakesplit (ALT9)|--filter-tcp=443 --dpi-desync=hostfakesplit --dpi-desync-repeats=4 --dpi-desync-fooling=ts,md5sig --dpi-desync-hostfakesplit-mod=host=ozon.ru --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Fake+hostfakesplit SNI (ALT3)|--filter-tcp=443 --dpi-desync=fake,hostfakesplit --dpi-desync-fake-tls=@tls --dpi-desync-fake-tls-mod=rnd,dupsid,sni=ya.ru --dpi-desync-hostfakesplit-mod=host=ya.ru,altorder=1 --dpi-desync-fooling=ts --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Multidisorder repeats=6 (Meta/Facebook)|--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,sniext --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Multidisorder repeats=11 (агрессивный)|--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,sniext --dpi-desync-repeats=11 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Fakedsplit (только TCP, лёгкий)|--filter-tcp=443 --dpi-desync=fakedsplit --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls
Fake repeats=2 (минимальный TCP)|--filter-tcp=443 --dpi-desync=fake --dpi-desync-repeats=2 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls
Multisplit seqovl=336 pos=1 (лёгкий seqovl)|--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1 --dpi-desync-split-seqovl=336 --dpi-desync-split-seqovl-pattern=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Multidisorder midsld repeats=8|--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=8 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Fake+fakedsplit fooling=badseq repeats=8|--filter-tcp=443 --dpi-desync=fake,fakedsplit --dpi-desync-split-pos=1 --dpi-desync-repeats=8 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Multisplit seqovl=652 pos=2,sniext|--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=2,sniext --dpi-desync-split-seqovl=652 --dpi-desync-split-seqovl-pattern=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Multidisorder sniext repeats=4 fooling=ts|--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,sniext --dpi-desync-repeats=4 --dpi-desync-fooling=ts --dpi-desync-fake-tls=@tls --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
Только QUIC fake repeats=6 (лёгкий)|--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-quic=@quic
PRESETS
}

# ============================================================
# БРАУЗЕР-СВИП (управляется панелью ИЗ БРАУЗЕРА — честный forward+QUIC-путь). Для zapret это
# ЕДИНСТВЕННЫЙ честный тест: curl С РОУТЕРА мерил бы путь OUTPUT (там десинк «проходит», а на
# форварде — нет). Панель применяет КАЖДУЮ стратегию к боевому nfqws, реальный браузер грузит
# favicon заблок-сайтов через настоящий форвард. Здесь — router-сторона: применить + восстановить.
# (Свип nfqws НЕ влияет на health транспорта → не нужен lock-vs-watchdog как у byedpi; lock держим
#  лишь чтобы apply при выключении/repair посреди свипа не затёр временную стратегию.)
sweep_fresh() {
    [ -f "$SWEEP_LOCK" ] || return 1
    ts=$(cat "$SWEEP_LOCK" 2>/dev/null | tr -d ' \r\n'); case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    [ "$(age_since "$ts")" -lt "$SWEEP_TTL" ]
}
sweep_touch() { date +%s > "$SWEEP_LOCK"; }
sweep_restore() {
    if [ -f "$SWEEP_BAK" ]; then
        if [ -s "$SWEEP_BAK" ]; then mv "$SWEEP_BAK" "$ARGS_FILE" 2>/dev/null
        else rm -f "$ARGS_FILE" 2>/dev/null; fi
    fi
    rm -f "$SWEEP_LOCK" "$SWEEP_BAK" 2>/dev/null
}
cmd_sweep_begin() {
    zt_desync_live || { log "sweep-begin: десинк выключен — свип возможен только при включённом zapret (транспорт или доп-выход)"; return 1; }
    if [ ! -f "$SWEEP_BAK" ]; then
        if [ -f "$ARGS_FILE" ]; then cp "$ARGS_FILE" "$SWEEP_BAK" 2>/dev/null; else : > "$SWEEP_BAK"; fi
    fi
    sweep_touch
    log "sweep-begin: браузер-свип начат (исходная стратегия сохранена)"
    return 0
}
# применить ОДНУ стратегию к боевому nfqws. $1 = args (санитизированы в CGI); пусто = дефолт.
cmd_sweep_apply() {
    zt_desync_live || { log "sweep-apply: десинк выключен"; return 1; }
    [ -f "$SWEEP_BAK" ] || { log "sweep-apply: свип не начат — отказ"; return 1; }
    sweep_touch
    a=$(strip_sani "$1")
    if [ -n "$a" ]; then printf '%s\n' "$a" > "$ARGS_FILE.new" && mv "$ARGS_FILE.new" "$ARGS_FILE"; else rm -f "$ARGS_FILE"; fi
    if restart_nfqws; then
        ct_flush
        sweep_touch
        log "sweep-apply: применена стратегия ($(desync_args))"
        return 0
    fi
    sweep_touch
    log "sweep-apply: nfqws не поднялся на этой стратегии"
    return 1
}
cmd_sweep_end() {
    sweep_restore
    zt_desync_live && { restart_nfqws >/dev/null 2>&1; ct_flush; }
    log "sweep-end: исходная стратегия восстановлена, свип завершён"
    return 0
}

# ============================================================
# ИМПОРТ ДЕСКТОПНОГО КОНФИГА (winws/Flowseal и подобные .bat/.cmd) → флаги nfqws.
# Читает текст со STDIN. В stdout — ОДНА строка готовых аргументов (её кладёт в поле панель),
# в stderr — отчёт человеку. Разделение потоков здесь принципиально: отчёт нужен глазам, а
# строка — валидатору и файлу, и склеить их значило бы разбирать текст обратно.
# ЧЕГО КОНВЕРТЕР НЕ ДЕЛАЕТ: он не «умный». Он снимает обёртку .bat, выкидывает то, чего у nfqws
# нет вовсе, и НЕ пытается угадать замену — вместо этого называет выброшенное поимённо.
cmd_import() {
    _raw=$(cat 2>/dev/null)
    [ -n "$_raw" ] || { echo "[import] пусто — вставьте текст конфига" >&2; return 1; }
    # .bat переносит строки каретом (^) и CRLF; кавычки снимаем целиком — у флагов nfqws пробелов
    # внутри значения не бывает, а наш валидатор кавычку не пропустит.
    _flat=$(printf '%s' "$_raw" | tr -d '\r"' | sed 's/\^$//' | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g')
    _out=""; _dropw=""; _dropl=""; _dropf=""; _dropb=""; _warn=""; _unk=""
    # ГЛОББИНГ ВЫКЛЮЧАЕМ НА ВРЕМЯ РАЗБОРА. `for _w in $_flat` — это не только разбиение по
    # пробелам, но и подстановка имён файлов: токен вроде `%BIN%*.bin` из чужого конфига
    # раскрылся бы по содержимому текущего каталога, и в стратегию уехали бы имена файлов.
    set -f
    for _w in $_flat; do
        case "$_w" in
            # 1. winws-only: nfqws отвергает ВЕСЬ запуск, увидев их, — это не «лишний флаг», это отказ старта
            --wf-tcp=*|--wf-udp=*|--wf-raw=*|--wf-l3=*|--ssid-filter=*|--nlm-filter=*) _dropw="$_dropw $_w"; continue ;;
            # 2. файловые списки: у нас список — ipset в ядре, файлов нет вовсе
            --hostlist=*|--hostlist-exclude=*|--hostlist-auto=*|--hostlist-auto-fail-threshold=*|--hostlist-auto-fail-time=*|--ipset=*|--ipset-exclude=*) _dropl="$_dropl $_w"; continue ;;
            # 3. фейки: у нас РОВНО ДВА вшитых, и адресуются они токенами @tls/@quic, а не путём
            --dpi-desync-fake-tls=*)  _out="$_out --dpi-desync-fake-tls=@tls";  continue ;;
            --dpi-desync-fake-quic=*) _out="$_out --dpi-desync-fake-quic=@quic"; continue ;;
            --dpi-desync-fake-*=*) _dropf="$_dropf $_w"; continue ;;
            # 4. обёртка запуска: имя бинаря, путь, демонизация и номер очереди — наши
            --daemon|--pidfile=*|--user=*|--uid=*|--qnum=*|--queue-num=*) continue ;;
            "") continue ;;
        esac
        # 4б. У nfqws ВСЕ аргументы — флаги вида `--что-то[=значение]`. Всё остальное в строке
        #     десктопного конфига — обёртка .bat: имя бинаря, путь, `start /min`, `@echo off` и
        #     ЗАГОЛОВОК ОКНА (`start "zapret: general"`). Пропустить их «на всякий случай» нельзя:
        #     nfqws отвергает запуск с посторонним словом, а поймано это было ЗАМЕРОМ — первый же
        #     прогон конвертера на настоящем конфиге Flowseal вынес в стратегию «zapret: general».
        case "$_w" in --*) ;; *) _dropb="$_dropb $_w"; continue ;; esac
        # 5. фильтры портов: флаг сохраняем, но если он НЕ про 443 — предупреждаем. Наш крючок
        #    NFQUEUE ловит только dport 443 (tcp+udp, connbytes 1:8), и секция на 80 или на
        #    UDP-диапазон Discord не заработает ни при какой стратегии. Молчать об этом нельзя:
        #    человек будет думать, что дело в стратегии, и перебирать её вечно.
        case "$_w" in
            # РОВНО 443, а не «упоминает 443»: у секции `--filter-tcp=80,443` половина здесь
            # мертва, и молчать про неё — то же самое, что молчать про секцию целиком.
            --filter-tcp=443|--filter-udp=443) ;;
            --filter-tcp=*|--filter-udp=*) _warn="$_warn $_w" ;;
        esac
        # 6. всё остальное пропускаем, но то, что не пройдёт наш валидатор, называем отдельно —
        #    иначе панель ответит «недопустимые символы» на строку, которую сама же и собрала.
        case "$_w" in
            *[!A-Za-z0-9+,.:/=_@-]*) _unk="$_unk $_w"; continue ;;
        esac
        _out="$_out $_w"
    done
    set +f
    _out=$(printf '%s' "$_out" | sed 's/^ //; s/ $//')
    # ОТЧЁТ — в stderr, по одной теме на строку.
    [ -n "$_dropw" ] && echo "[import] выброшено (только для winws, nfqws не примет):$_dropw" >&2
    [ -n "$_dropl" ] && echo "[import] выброшено (списки у нас в ядре, файловых нет):$_dropl" >&2
    [ -n "$_dropf" ] && echo "[import] выброшено (свой файл фейка; у нас только @tls и @quic):$_dropf" >&2
    [ -n "$_unk"  ] && echo "[import] выброшено (символы, которых не принимает поле стратегии):$_unk" >&2
    [ -n "$_dropb" ] && echo "[import] выброшена обёртка запуска (не флаги nfqws):$_dropb" >&2
    [ -n "$_warn" ] && echo "[import] ВНИМАНИЕ: эти секции здесь не заработают — перехват идёт только по порту 443:$_warn" >&2
    if [ -z "$_out" ]; then
        echo "[import] после чистки не осталось ни одного флага nfqws — похоже, это не конфиг zapret" >&2
        return 1
    fi
    echo "[import] готово. Проверьте строку и нажмите «Сохранить» — сама по себе она не применяется" >&2
    # РЕЗУЛЬТАТ ПОМЕЧЕН ТОКЕНОМ. `log()` в этом файле печатает в STDOUT (`echo "[zapret] …"`), и
    # любая строка, залогированная до нас, оказалась бы в том же потоке. Вызыватель берёт строку
    # по префиксу `ARGS:`, а не «первую непохожую на отчёт» — иначе он однажды сохранит в
    # стратегию чужой лог.
    printf 'ARGS:%s\n' "$_out"
    return 0
}

case "$1" in
    # транспорт-контракт (зовёт transport.sh: switch/up/down/health/failover) — zapret как 5-й транспорт.
    # Прежних on|off здесь НЕТ: вкл/выкл идёт через оркестратор (up/down), чтобы .zapret-on и
    # .transport не разъезжались (раньше панельный zapret_toggle on/off рассинхронизировал статус).
    # Тихий вопрос «возможен ли десинк на этом роутере» (0 = да). Зовёт transport.sh
    # transport_ready: незачем предлагать в панели транспорт, который здесь физически не встанет
    # (AX3600: iptables без libxt_NFQUEUE). Проба кэширована — вызовов много, ответ один.
    nfq-ok)    nfq_supported ;;
    # Вербы, которые БЕРУТ несущую (весь дом через десинк или выход), — через carrier_run (daemon-lib.sh): при выключенном вручную VPN
    # отказ, выключение по ходу отпускает поднятое. Десинк УСТРОЙСТВ (src-*) — не VPN и живёт при выключенном; reload и свип при нём
    # служат только устройствам (см. zt_transport_active).
    up)        carrier_run cmd_t_down cmd_t_up ;;
    down)      cmd_t_down ;;
    cold)      : ;;                       # тёплого резерва нет: несущей у десинка нет вовсе (nfqws правит пакеты на форварде)
    health)    cmd_t_health ;;
    failover)  carrier_run cmd_t_down cmd_t_failover ;;
    # zapret-СЛОТ (десинк рядом с VPN, Ф1) — зовёт оркестратор transport.sh slot-up/slot-down.
    slot-up)   carrier_run cmd_slot_down cmd_slot_up "$2" "$3" ;;
    slot-down) cmd_slot_down "$2" ;;
    # десинк по ИСТОЧНИКУ (устройство целиком в десинк) — зовёт apply-bypass.sh, владелец списка.
    src-wire)   cmd_src_wire "$2" ;;
    src-unwire) cmd_src_unwire "$2" ;;
    src-clear)  cmd_src_clear ;;
    src-list)   cmd_src_list ;;   # что РЕАЛЬНО проводнено в mangle (машинно, по строке на IP)
    dns)       set_direct_dns ;;   # переиграть DNS (DoH toggle/смена резолвера) — прямой режим через doh_apply_dns
    install)   cmd_install "$2" ;;
    remove)    cmd_remove ;;
    apply)     cmd_apply ;;
    rewire)    cmd_rewire ;;   # досборка правил под пулы источников (зовут lists-update.sh zapret-*)
    status)    cmd_status ;;
    wired)     cmd_wired ;;   # машинно: есть ли ЖИВОЙ десинк (0 да · 1 нет · 2 = старая копия не знает верба)
    t-wired)   zt_transport_wired ;;   # машинно: проводка ГЛАВНОГО транспорта (не выхода, не устройства)
    reload)    cmd_reload ;;
    import)    cmd_import ;;   # STDIN = десктопный конфиг → stdout: флаги nfqws, stderr: отчёт
    presets)   cmd_presets ;;
    defaults)  echo "$DEFAULT_ARGS" ;;
    categories) cmd_categories ;;
    sweep-begin) cmd_sweep_begin ;;
    sweep-apply) cmd_sweep_apply "$2" ;;
    sweep-end)   cmd_sweep_end ;;
    *) echo "usage: $0 up|down|cold|health|failover|nfq-ok|slot-up <id>|slot-down <id>|src-wire <ip>|src-unwire <ip>|src-clear|install [update]|remove|apply|rewire|status|wired|t-wired|reload|import|presets|defaults|categories|sweep-begin|sweep-apply <args>|sweep-end"; exit 2 ;;
esac
