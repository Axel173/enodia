#!/bin/sh
# notify.sh — отправка уведомления на e-mail прямо с роутера BE7000.
#
# Зачем openssl, а не msmtp/curl:
#   - curl на стоке собран БЕЗ SMTP (`curl --version` → Protocols без smtp);
#   - msmtp/ssmtp/sendmail не установлены, а opkg-фиды (18.06-SNAPSHOT miwifi)
#     ненадёжны и тянутся из интернета;
#   - openssl-util + base64 уже есть в системе — поэтому SMTP-диалог ведём
#     руками через `openssl s_client`. Ничего ставить не нужно.
#
# Любой SMTP — и ВСЕГДА мимо туннеля:
#   notify.sh зовётся из watchdog.sh ИМЕННО когда VPN упал, поэтому письмо
#   ОБЯЗАНО уйти в обход туннеля. Раньше это держалось лишь на том, что дефолтный
#   Яндекс-SMTP — российский IP и не попадал в iplist_set. Теперь гарантия
#   СТРУКТУРНАЯ: mark-core.sh (notify-guard) выводит весь router-локальный SMTP-
#   submission (порты 465/587/25) из маркировки → он всегда идёт по main-таблице
#   напрямую через провайдера, МИМО awg0 — даже если хост Gmail/Google (их IP ЛЕЖАТ
#   в iplist_set). Значит можно указать ЛЮБОЙ SMTP-хост (SMTP_HOST в notify.conf).
#   Яндекс остаётся дефолтом просто как самый простой для РФ вариант.
#
# TLS: implicit (порт 465, сразу TLS) или STARTTLS (порт 587/25, апгрейд из plain).
#   Режим берётся из SMTP_TLS (implicit|starttls) в notify.conf, а если он не задан —
#   выводится из порта (465→implicit, 587/25→starttls). STARTTLS делает сам openssl
#   ключом `-starttls smtp` (шлёт EHLO+STARTTLS и апгрейдит канал), дальше наш
#   диалог EHLO/AUTH идёт уже по зашифрованному соединению — как и при implicit.
#
# Использование:
#   notify.sh "Тема письма" "Текст письма"
#
# Конфиг — notify.conf в КАТАЛОГЕ СОСТОЯНИЯ (chmod 600, НЕ в git): его пишет панель
# (cgi-bin/action write_notify_conf), и обновление, заменяющее каталог кода целиком, его не
# трогает. До 16.09.2026 конфиг искали «рядом со скриптом», то есть в каталоге КОДА: так было
# верно, пока состояние лежало рядом с кодом, а с переезда состояния 30.08.2026 письма не
# уходили ВООБЩЕ — замерено на BE7000: «нет …/enodia/notify.conf — пропуск» в каждом вызове при
# заполненном конфиге рядом. Форму «рядом со скриптом» для персиста сторожит C69.
#
# Нет конфига или он не заполнен (пустой SMTP_PASS) — выходим с кодом 3, а не 0. Ноль здесь был
# ложью, которая и спрятала поломку на две недели: notify-event.sh писал «отправлено» и ставил
# отметку throttle, а кнопка тест-письма в панели отвечала «250 queued». «Письмо не ушло, потому
# что почты нет» — отдельный ответ; ошибкой отправки (1) его тоже не считаем.

ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
CONF="$ENODIA_STATE/notify.conf"
LOG=/tmp/enodia-notify.log

SUBJECT="$1"
BODY="$2"

# Префикс темы = МОДЕЛЬ роутера. Callers исторически хардкодят «BE7000:» — на AX3600/
# BE3600 это врёт. Единый детект (router-lib.sh) переписывает лидирующий код модели на
# реальный. Шим-фолбэк: нет lib (старая установка) → тема остаётся как есть.
# Гард `if [ -f ]` обязателен: провалившийся `.` в busybox ash — фатальная ошибка спецбилтина,
# шелл выходит НА МЕСТЕ (проверено на BE7000: rc=2, `|| true` не спасает) ⇒ строка-шим ниже без
# гарда не выполнялась бы никогда, а письмо просто не ушло бы.
_rl="$(dirname "$0")/router-lib.sh"
if [ -f "$_rl" ]; then . "$_rl"; fi
command -v router_relabel >/dev/null 2>&1 && SUBJECT=$(router_relabel "$SUBJECT")

# БРЕНД В ТЕМЕ — здесь и ТОЛЬКО здесь. Письмо падает в общий ящик, где «AX3600: туннель упал»
# не говорит, ОТ КОГО оно: тему читают раньше отправителя. В ЖУРНАЛ панели бренд НЕ идёт (человек
# уже внутри Enodia — там это шум), поэтому владелец один и он в отправителе, а не в
# router_relabel, которым пользуются оба. Идемпотентно: notify.sh зовут и напрямую, и из
# notify-event.sh — второй подписи быть не должно. Ставим ДО base64 и до строки лога, иначе лог
# разойдётся с тем, что реально ушло (эта грабля уже уводила разбор, см. шапку notify-event.sh).
case "$SUBJECT" in
	"Enodia · "*) ;;
	*) SUBJECT="Enodia · $SUBJECT" ;;
esac

# Резолв SMTP-хоста — общий (dns-lib.sh), см. ниже «Резолвим SMTP-хост». Шим-фолбэк = системный
# резолвер: без библиотеки DoH-ступени нет, но письмо всё равно уходит (connect по имени).
_dl="$(dirname "$0")/dns-lib.sh"
if [ -f "$_dl" ]; then . "$_dl"; fi
command -v resolve_ipv4 >/dev/null 2>&1 || resolve_ipv4() { nslookup "$1" 2>/dev/null | awk '/^Name:/{f=1;next} f&&/Address/{x=$NF; if(x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print x; exit}}'; }

[ -f "$CONF" ] || { echo "$(date) notify: нет $CONF — почта не настроена, письмо не ушло" >>"$LOG"; exit 3; }
. "$CONF"

if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ] || [ -z "$MAIL_TO" ]; then
    echo "$(date) notify: notify.conf не заполнен (нет SMTP_PASS?) — письмо не ушло" >>"$LOG"
    exit 3
fi
SMTP_PORT="${SMTP_PORT:-465}"

# Режим TLS. Явный SMTP_TLS (implicit|starttls) имеет приоритет; иначе — по порту:
# 587/25 = STARTTLS (plain → апгрейд), всё прочее (в т.ч. 465) = implicit (сразу TLS).
STARTTLS_ARG=""
case "$(printf '%s' "${SMTP_TLS:-}" | tr 'A-Z' 'a-z')" in
    starttls) STARTTLS_ARG="-starttls smtp" ;;
    implicit) STARTTLS_ARG="" ;;
    *) case "$SMTP_PORT" in 587|25) STARTTLS_ARG="-starttls smtp" ;; *) STARTTLS_ARG="" ;; esac ;;
esac

# base64 для AUTH LOGIN (логин/пароль) и для MIME-кодирования темы (кириллица).
U_B64=$(printf '%s' "$SMTP_USER" | base64 | tr -d '\n')
P_B64=$(printf '%s' "$SMTP_PASS" | base64 | tr -d '\n')
SUBJ_B64=$(printf '%s' "$SUBJECT" | base64 | tr -d '\n')

DATE_HDR=$(date -R 2>/dev/null || date)

# timeout (если есть) — чтобы зависший SMTP не копил процессы в cron.
# busybox бывает с двумя синтаксисами: новый "timeout N CMD" и старый
# "timeout -t N CMD". Определяем рабочий, пробуя на безобидном `true`.
TMO=""
if command -v timeout >/dev/null 2>&1; then
    if timeout 2 true 2>/dev/null; then
        TMO="timeout 25"
    elif timeout -t 2 true 2>/dev/null; then
        TMO="timeout -t 25"
    fi
fi

# Резолвим SMTP-хост и подключаемся ПО IP (-servername ниже держит правильный SNI).
# Зачем: smtp.yandex.ru идёт МИМО туннеля по МАРШРУТУ, но его ИМЯ резолвится через dnsmasq →
# upstream ВНУТРИ туннеля. Письмо шлётся как раз когда VPN мёртв — обычный резолв тогда падает.
# ГРАБЛЯ (железо): busybox `nslookup HOST SERVER` ИГНОРИРУЕТ аргумент SERVER и всегда бьёт в
# системный resolver (=dnsmasq) → прежний цикл «nslookup @1.1.1.1/8.8.8.8» ДУМАЛ, что обходит
# dnsmasq, а шёл через него же. Рабочий обход — DoH ПО IP-ЛИТЕРАЛУ, и он же живёт в dns-lib.sh
# (resolve_ipv4: системный резолвер → DoH через WAN → DoH как есть). Не удалось — откат на имя.
# ЗАЧЕМ ОБЩАЯ ФУНКЦИЯ, а не свой цикл, как было до 04.08.2026: собственная копия не имела bind'а
# к WAN, и «узкий случай», честно описанный здесь прежним комментарием (VPN мёртв И mangle ещё
# включён ⇒ 1.1.1.1 само завёрнуто в туннель, резолв не пройдёт), был вовсе не узким — именно так
# выглядит КАЖДОЕ письмо о падении несущей до safety_off. Теперь его закрывает `--interface <wan>`
# внутри dns-lib (SO_BINDTODEVICE ходит мимо fwmark-роутинга), а не «письмо подстрахует watchdog».
SMTP_IP=""
case "$SMTP_HOST" in
    *[!0-9.]*)   # это имя, а не IPv4 — резолвим
        SMTP_IP=$(resolve_ipv4 "$SMTP_HOST")
        case "$SMTP_IP" in *.*.*.*) ;; *) SMTP_IP="" ;; esac
        ;;
    *) SMTP_IP="$SMTP_HOST" ;;   # SMTP_HOST уже IP
esac
if [ -n "$SMTP_IP" ]; then
    CONNECT="$SMTP_IP:$SMTP_PORT"
else
    CONNECT="$SMTP_HOST:$SMTP_PORT"   # fallback — как было
fi
echo "$(date) notify: connect=$CONNECT (host=$SMTP_HOST, tls=$([ -n "$STARTTLS_ARG" ] && echo starttls || echo implicit))" >>"$LOG"

# SMTP-диалог. sleep между шагами: AUTH LOGIN пошаговый (сервер ждёт логин,
# потом пароль), без пауз Яндекс иногда рвёт сессию. -crlf: openssl сам
# добавляет \r к каждой строке. -quiet: меньше служебного шума в выводе.
RESP=$(
{
    echo "EHLO router";            sleep 1
    echo "AUTH LOGIN";             sleep 1
    echo "$U_B64";                 sleep 1
    echo "$P_B64";                 sleep 1
    echo "MAIL FROM:<$SMTP_USER>"; sleep 1
    echo "RCPT TO:<$MAIL_TO>";     sleep 1
    echo "DATA";                   sleep 1
    echo "From: $SMTP_USER"
    echo "To: $MAIL_TO"
    echo "Subject: =?UTF-8?B?$SUBJ_B64?="
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo "Date: $DATE_HDR"
    echo ""
    printf '%s\n' "$BODY"
    echo ""
    echo "-- "
    echo "Поддержать: https://web.tribute.tg/d/LtA"
    echo "Другие способы: https://github.com/Axel173/enodia#donate"
    echo "."
    sleep 1
    echo "QUIT"
    sleep 1
} | $TMO openssl s_client -connect "$CONNECT" -servername "$SMTP_HOST" $STARTTLS_ARG -crlf -quiet 2>&1
)

echo "$(date) notify: subj='$SUBJECT'" >>"$LOG"
echo "$RESP" >>"$LOG"

# Успех = (а) аутентификация принята (код 235 в НАЧАЛЕ строки) И (б) сервер принял ПИСЬМО, то есть
# ответил 2xx ПОСЛЕ приглашения «354 Start mail input» — а не когда-либо вообще.
# ПОЧЕМУ не прежнее «есть где-то 250 2.0.0 / queued / 250 ok»: 250 сервер шлёт и на EHLO, и на
# MAIL FROM, и на RCPT TO, причём ТЕКСТЫ у каждого SMTP свои (Exim на MAIL FROM отвечает ровно
# «250 OK», Postfix — «250 2.0.0 Ok»). У Яндекса совпадения не случалось, а на «любом SMTP», который
# мы обещаем, отказ на ТЕЛЕ письма (квота, 552, спам-фильтр) читался как успех. Цена ошибки не
# «неверная строка в логе»: notify-event.sh ставит отметку throttle ТОЛЬКО при успехе — ложный успех
# ГЛУШИТ следующее письмо этого класса на всё окно (для падения VPN это час тишины).
# Ждём именно 250 после 354, а не «любой 2xx»: на QUIT сервер отвечает 221, и по «2xx после 354»
# отказ на теле (552 «mailbox full») снова читался бы как успех — поймано на синтетике при проверке
# этой же правки. `sub(/\r$/…)` — ответы приходят с CRLF (openssl -crlf), без среза хвоста форма
# «250» без текста не совпала бы.
if printf '%s\n' "$RESP" | grep -qE '^235' && \
   printf '%s\n' "$RESP" | awk '{sub(/\r$/,"")} /^354/{d=1; next} d && /^250([ -]|$)/{ok=1} END{if(ok) exit 0; exit 1}'; then
    exit 0
else
    echo "$(date) notify: ОТПРАВКА НЕ ПОДТВЕРЖДЕНА (детали выше)" >>"$LOG"
    exit 1
fi
