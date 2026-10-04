#!/bin/sh
# dns-split.sh — раздельный резолв рунета. Домены .ru/.рф/.su резолвим НАПРЯМУЮ через российский
# резолвер (Яндекс 77.88.8.8 / 77.88.8.1), а не через туннель. Зачем:
#   * geo-корректность — RF-CDN (VK/Mail/Госуслуги/банки) отдаёт БЛИЖНИЙ узел по IP резолвера;
#     через VPS они видят зарубежный резолвер → отдают дальний/кривой узел;
#   * скорость — минус хоп резолва до VPS и обратно.
# Забугор-домены идут ПРЕЖНИМ путём (dnsmasq → upstream в туннель) — не трогаем. Opt-in (деф. выкл).
#
# КАК «направляем»: dnsmasq `server=/<tld>/<ip>` = запросы этого TLD только на этот резолвер. Запрос
# роутера к 77.88.8.* :53 идёт НАПРЯМУЮ (RF-IP не в iplist_set и не форс-маркирован в туннель set_xray_dns
# → mangle его не метит → main-таблица → WAN). RF-IP из ответа тоже не в iplist_set → клиент к нему прямо.
#
# ГДЕ ЖИВЁТ (грабля adblock disable-leak): живой conf в /tmp/dnsmasq.d (НЕ /etc — стоковый init.d
# копирует /etc→/tmp аддитивно, teardown из /etc не убирал бы копию). Персист-флаг на /data переживает
# ребут; conf в ОЗУ пересобирает heal.sh. `server=` reload — полный рестарт dnsmasq (как address=).
#
# РИСК: 77.88.8.* недоступен → ломается резолв ТОЛЬКО .ru/.рф/.su (не весь DNS). Яндекс-DNS в РФ
# крайне надёжен + два адреса для резерва; opt-in. Забугор/рунет-через-туннель при этом целы.
#
# ВЗАИМОДЕЙСТВИЕ С «ШИФРОВАННЫМ DNS» (DoH/DoT) — НЕ баг, но знать обязательно. `server=/<tld>/<ip>`
# специфичнее общего апстрима, поэтому при ОБОИХ включённых тумблерах .ru/.рф/.su уходят на Яндекс
# ОТКРЫТЫМ 53-м портом мимо локального DoH-прокси: провайдер видит эти имена. Это осознанный размен
# (geo-корректность рунета против шифрования его же имён), и выбор за человеком — поэтому мы не
# «чиним» его молча, а честно сообщаем: верб `conflict` (машинный 0/1) + предупреждение при `on`.
#
#   dns-split.sh on|off|apply|build|status|conflict

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
FLAG="$ENODIA_STATE/.split-runet"
CONF=/tmp/dnsmasq.d/09-split-runet.conf
# .рф = punycode xn--p1ai (dnsmasq матчит по ASCII-форме домена). Два резолвера = резерв.
TLDS="ru xn--p1ai su"
R1=77.88.8.8
R2=77.88.8.1

reload() { /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null; }

build() {
	mkdir -p /tmp/dnsmasq.d
	if [ -f "$FLAG" ]; then
		{ for t in $TLDS; do echo "server=/$t/$R1"; echo "server=/$t/$R2"; done; } > "$CONF.new" 2>/dev/null
		mv "$CONF.new" "$CONF" 2>/dev/null
	else
		rm -f "$CONF" 2>/dev/null
	fi
}

# Оба тумблера включены? Машинный ответ (1/0) — его читает панель, чтобы сказать человеку, что
# имена рунета при таком сочетании идут открытым 53-м (см. шапку). Нет doh-lib — ответ 0 (прежнее
# поведение байт-в-байт: до появления «Шифрованного DNS» конфликта не существовало).
conflict() {
	[ -f "$FLAG" ] || { echo 0; return 0; }
	[ -f "$ENODIA_DIR/doh-lib.sh" ] || { echo 0; return 0; }
	( . "$ENODIA_DIR/doh-lib.sh"; doh_want >/dev/null 2>&1 ) && echo 1 || echo 0
}

case "$1" in
	on)     : > "$FLAG"; build; reload; echo ok
	        [ "$(conflict)" = 1 ] && echo "внимание: при включённом «Шифрованном DNS» имена .ru/.рф/.su всё равно резолвятся ОТКРЫТО (server=/tld/ специфичнее общего апстрима)" ;;
	off)    rm -f "$FLAG"; build; reload; echo ok ;;
	apply)  build; reload; echo ok ;;   # для heal.sh на буте
	build)  build; echo ok ;;
	status) [ -f "$FLAG" ] && echo on || echo off ;;
	conflict) conflict ;;               # 1 = сплит рунета и шифрованный DNS включены одновременно
	*)      echo "usage: dns-split.sh on|off|apply|build|status|conflict" ;;
esac
