#!/bin/sh
# net-tune.sh — сетевые тумблеры «Настроек» (группа Сеть/MTU). Флаг-driven, переигрывается на буте
# (heal.sh) и по верб-кнопке (immediate). Оба opt-in, дефолт = поведение стока (ноль регрессий).
#
#   .tun-mtu   = число (1280..1500) → MTU туннеля AmneziaWG (awg0). Пусто/нет → не трогаем (деф.
#                awg_setup ставит сам). Полезно под CGNAT: понизить при «висящих» больших страницах.
#                ТОЛЬКО awg0: у xray/hy2/byedpi несущая = xtun (tun2socks, MTU 8500 — это его норма,
#                трогать НЕЛЬЗЯ). Применяем к awg0, даже если он сейчас не активная несущая (вступит
#                в силу, когда AmneziaWG станет несущей; awg0 существует всегда после установки).
#   .go-memlimit = потолок кучи Go (GOMEMLIMIT) для демонов AmneziaWG. auto|off|<МиБ 16..512>;
#                нет файла = auto. ЗАЧЕМ: amneziawg-go (форк wireguard-go) держит пул пакетных
#                буферов БЕЗ ПОТОЛКА — в апстриме `PreallocatedBuffersPerPool = 0` с авторским
#                «allow for infinite memory growth», буфер = MaxSegmentSize 64 КБ. Куча растёт по
#                объёму прошедшего трафика и ядру НЕ возвращается: замерено 80 МБ пика на 2.25 ГБ
#                при 200 Мбит/с и ровно столько же в покое (стенд local/awg-ram-lab/). На BE7000
#                это незаметно, а BE3600 со 176 МБ уходил в ребут КАЖДЫЙ ЧАС.
#                GOMEMLIMIT — мягкий потолок: агрессивный GC включается лишь на подходе к нему,
#                поэтому ДО потолка он не стоит НИЧЕГО (замер: 64 МиБ → пик 80→37 МБ при ×1.0 CPU).
#                Колено между 64 и 48 МиБ; ниже 48 — обрыв в ×6..8 CPU ради единиц мегабайт.
#                GOGC СОЗНАТЕЛЬНО не трогаем: он ужимает кучу ВСЕГДА и в одиночку даёт те самые
#                ×6..8. Патч самой константы проверен и отвергнут — рабочего окна нет (128 вешает
#                демона на `awg setconf` в WaitPool.Get, 1024 не срабатывает никогда; значение iOS
#                не переносится: там MaxSegmentSize 1700, у нас 65535).
#                Значение вступает в силу при СЛЕДУЮЩЕМ подъёме несущей (демону нельзя сменить
#                потолок на лету) — переигрывать нечего, поэтому в heal.sh replay нас нет.
#                КОНТРАКТ ЧИТАТЕЛЯ: наш вывод фильтруется ПО ФОРМЕ на стороне вызывателя
#                (`| grep -E '^GOMEMLIMIT=[0-9]+MiB$'` перед env, `grep '^key='` в CGI). Причина —
#                РАССИНХРОН ВЕРСИЙ: у старой копии этого файла верба нет, она проваливается в `*)`
#                и печатает `usage: …` в STDOUT. Без фильтра это слово встаёт ПЕРВЫМ АРГУМЕНТОМ
#                env — и демон не поднимается вовсе (класс «половинное обновление роняет несущую»).
#                Фильтр живёт РЯДОМ с env у каждого читателя, в библиотеку не выносится: вынесенный,
#                он сам оказался бы устаревшей копией ровно в том сценарии, от которого защищает.
#   .ipv6-block  присутствует = блокировать клиентам выход в ГЛОБАЛЬНЫЙ IPv6 (2000::/3) на форварде.
#                Зачем: сплит-туннель работает по IPv4-ipset; заблок-сайт по IPv6 идёт МИМО (утечка) →
#                ISP его режет. Блок IPv6-интернета клиентам → всё по IPv4 через сплит. LAN-локальный
#                IPv6 (ULA/link-local) НЕ трогаем (2000::/3 = только глобал-юникаст). На стоке без
#                IPv6-аплинка это no-op; у кого провайдер даёт IPv6 — перебивает стоковый lan→wan6 ACCEPT.
#
#   net-tune.sh apply|mtu|mtu-flag|ipv6|detect|memlimit-env|memlimit-info   (mtu-flag — READ-ONLY: ручной MTU или пусто)

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
# Ожидание xtables-лока: ipt-lib.sh подменяет команду `iptables` и добавляет `-w`. Лок занят
# чужим кроном ⇒ без ожидания правило МОЛЧА не встаёт. Нет файла — прежний путь байт-в-байт.
if [ -f "$ENODIA_DIR/ipt-lib.sh" ]; then . "$ENODIA_DIR/ipt-lib.sh"; fi

# memlimit_value — ЕДИНСТВЕННЫЙ владелец числа «сколько МиБ разрешить куче демона». Печатает
# число или НИЧЕГО (= не ставить потолок вовсе). Копий этого правила не заводить: читателей
# трое (awg_setup.sh awg0, transport-awg.sh слоты awgN, vpn-server.sh awgs0), и разъехавшиеся
# копии дали бы роутер, где одна несущая зажата, а вторая нет.
memlimit_value() {
	v=$(cat "$ENODIA_STATE/.go-memlimit" 2>/dev/null | tr -cd 'a-z0-9')
	case "$v" in
		off) return 0 ;;
		[0-9]*)
			# Ручное значение пользователя. Диапазон 16..512: ниже 16 демон не поднимется вовсе,
			# выше 512 потолок бессмысленен (столько ОЗУ нет ни у одной поддержанной модели).
			{ [ "$v" -ge 16 ] && [ "$v" -le 512 ]; } 2>/dev/null && echo "$v"
			return 0 ;;
	esac
	# auto (деф.) — по объёму ОЗУ. Порог 256 МБ отделяет тесные модели (BE3600 = 176 МБ) от
	# просторных (BE7000 — 800+). На просторных НЕ ставим ничего: правило проекта — тумблер
	# opt-in обязан оставлять прежнее поведение БАЙТ В БАЙТ там, где проблемы нет.
	# AX3600 в «тесные» НЕ входит, хотя раньше был записан сюда: замерено на железе 14.08.2026 —
	# `MemTotal` 402472 кБ (393 МБ), то есть ВЫШЕ порога, и лимит ему не назначается (`mode=auto`,
	# `memlimit-env` пуст). Модель — не признак; судим по /proc/meminfo, и здесь он это подтвердил.
	t=$(awk '/^MemTotal:/{print $2+0}' /proc/meminfo 2>/dev/null)
	case "$t" in ''|*[!0-9]*) return 0 ;; esac
	[ "$t" -lt 262144 ] 2>/dev/null && echo 64
	return 0
}

# Строка для `env` перед запуском демона: «GOMEMLIMIT=64MiB» либо ПУСТО.
memlimit_env() {
	m=$(memlimit_value)
	[ -n "$m" ] && echo "GOMEMLIMIT=${m}MiB"
	return 0
}

# Для панели: режим, действующее значение и объём ОЗУ роутера — чтобы экран мог объяснить,
# ПОЧЕМУ здесь стоит именно это (и почему на BE7000 честно «не ограничивать»).
memlimit_info() {
	v=$(cat "$ENODIA_STATE/.go-memlimit" 2>/dev/null | tr -cd 'a-z0-9')
	case "$v" in
		off)    mode=off ;;
		[0-9]*) mode=manual ;;
		*)      mode=auto ;;
	esac
	t=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
	echo "mode=$mode"
	echo "value=$(memlimit_value)"
	echo "total=${t:-0}"
}

# РУЧНОЙ MTU, КОТОРЫЙ ДЕЙСТВУЕТ: флаг есть и в допустимых 1280..1500 — печатаем, иначе ничего. Один ответ на подъём awg0 (apply_mtu)
# и на экран сервера в панели (cgi-bin/action::get_config_info — «какой MTU получит этот конфиг»): своей копии проверки там нет.
mtu_flag() {
	m=$(cat "$ENODIA_STATE/.tun-mtu" 2>/dev/null | tr -cd '0-9')
	[ -n "$m" ] || return 0
	[ "$m" -ge 1280 ] 2>/dev/null && [ "$m" -le 1500 ] 2>/dev/null || return 0
	printf '%s\n' "$m"
}
apply_mtu() {
	m=$(mtu_flag)
	[ -n "$m" ] || return 0
	ip link show awg0 >/dev/null 2>&1 && ip link set awg0 mtu "$m" 2>/dev/null
}

apply_ipv6() {
	# идемпотентно снимаем прежнее правило ОБЕИМИ формами: ранние сборки ставили REJECT, и
	# снятие одного лишь DROP оставляло бы старое правило жить — тумблер «выключил», а IPv6 режется.
	while ip6tables -t filter -D FORWARD -d 2000::/3 -j DROP 2>/dev/null; do :; done
	while ip6tables -t filter -D FORWARD -d 2000::/3 -j REJECT 2>/dev/null; do :; done
	if [ -f "$ENODIA_STATE/.ipv6-block" ]; then
		ip6tables -t filter -I FORWARD 1 -d 2000::/3 -j DROP 2>/dev/null \
			&& echo "[net-tune] IPv6-block: FORWARD → 2000::/3 DROP (вкл)"
	fi
}

# detect_v6uplink — есть ли у роутера РЕАЛЬНЫЙ провайдерский IPv6 (dual-stack), а не только стоковый
# ULA (fd00::/8) без выхода. Признак: дефолт-роут v6 (провайдер раздаёт через RA/DHCPv6-PD) ИЛИ
# глобал-юникаст-адрес 2000::/3 на интерфейсе (ULA fc/fd и link-local fe80 отсеяны префиксом 2/3).
# На стоке Xiaomi без v6-аплинка — пусто → uplink=0. Read-only (ip … show), безопасно звать из панели:
# по нему панель контекстно подсказывает, актуален ли тумблер .ipv6-block или это no-op.
detect_v6uplink() {
	up=0
	if ip -6 route show 2>/dev/null | grep -q '^default'; then   # not-wan: IPv6-аплинк, а не WAN-интерфейс/несущая — вопрос другой
		up=1
	elif ip addr show 2>/dev/null | grep -qE 'inet6 [23][0-9a-f]{3}:'; then
		up=1
	fi
	echo "uplink=$up"
}

case "$1" in
	apply)  apply_mtu; apply_ipv6 ;;
	mtu)    apply_mtu ;;
	mtu-flag) mtu_flag ;;
	ipv6)   apply_ipv6 ;;
	# Снесён ли запрет IPv6, который обязан стоять: 0 — стоит (или тумблер выключен), 3 — снесён, иное — не знаю («не смог проверить» ≠
	# «снесено»). Спрашивает сторож при выключенном VPN: чужой reload иначе заметить не по чему (хвост 10 ревью dev233).
	wired)
		[ -f "$ENODIA_STATE/.ipv6-block" ] || exit 0
		ip6tables -t filter -C FORWARD -d 2000::/3 -j DROP 2>/dev/null; _nwr=$?
		case "$_nwr" in 0) exit 0 ;; 1) exit 3 ;; *) exit 2 ;; esac ;;
	detect) detect_v6uplink ;;
	# Оба верба READ-ONLY: их зовут из горячего пути подъёма несущей и из CGI панели.
	memlimit-env)  memlimit_env ;;
	memlimit-info) memlimit_info ;;
	*)      echo "usage: net-tune.sh apply|mtu|mtu-flag|ipv6|detect|memlimit-env|memlimit-info" ;;
esac
