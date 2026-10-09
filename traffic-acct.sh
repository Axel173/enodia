#!/bin/sh
# traffic-acct.sh — фоновый НАКОПИТЕЛЬ трафика для веб-панели (cron */5).
#
# Зачем: счётчики /proc/net/dev (awg0/xtun = VPN-несущая, eth0 = WAN) КУМУЛЯТИВНЫ и
# обнуляются при ребуте и смене транспорта (TUN-iface пересоздаётся). Чтобы панель
# показывала «за сегодня/неделю/месяц/год», копим ДЕЛЬТЫ в посуточный файл на /data
# (он переживает ребут, в отличие от RAM-счётчиков). Обнуление счётчика ТОГО ЖЕ iface
# (стал меньше прошлого) → дельта = текущее значение (отсчёт от 0); а вот СМЕНА iface
# = «истории под этим именем нет» → интервал пропускаем, см. разбор у dvrx ниже.
#
# Почему cron, а не CGI: учёт должен идти и когда панель закрыта. Почему счётчики
# /proc/net/dev, а не iptables/conntrack по IP: Qualcomm NSS/ECM-offload уводит потоки
# мимо netfilter → per-IP учёт недостоверен (см. карту проекта). awg0/xtun — userspace-TUN,
# их счётчики offload переживают. Флеш-износ: файл крошечный (≤~25 КБ), перезапись раз
# в 5 мин под UBIFS wear-leveling безопасна.
ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
LAST="$ENODIA_STATE/.traffic-last"      # сырой прошлый замер: "vif vrx vtx wrx wtx wif" (wif дописан
                                   # В КОНЕЦ — старый файл из пяти полей читается как прежде;
                                   # формат — КОНТРАКТ с web/cgi-bin/traffic, править ОБА)
                                   # ДОП-ВЫХОДЫ — ОТДЕЛЬНЫМИ СТРОКАМИ ниже первой: "s<id> <iface> <rx> <tx>".
                                   # Именно СТРОКАМИ, а не полями: оба читателя берут первую строку через
                                   # `read vif vrx vtx wrx wtx wif`, и седьмое ПОЛЕ уехало бы в `wif`
                                   # (последняя переменная `read` забирает весь остаток) — то есть имя
                                   # WAN-интерфейса стало бы мусором, и «незаписанной дельтой» объявился
                                   # бы весь кумулятивный счётчик eth0. Строки же читателя не касаются.
DAILY="$ENODIA_STATE/.traffic-daily"    # посуточно: "epoch YYYY-MM-DD vrx vtx wrx wtx" (+ доп-выходы:
                                   # "s2rx s2tx … s7rx s7tx" ДОПИСАНЫ В КОНЕЦ строки и только
                                   # когда выход с несущей есть — читатели берут поля по номерам $3..$6,
                                   # а на роутере без доп-выходов файл остаётся байт-в-байт прежним)
LOCK=/tmp/enodia-traffic-acct.lock
KEEP=400                           # сколько последних дней хранить (>1 года)

# Лок с ОТМЕТКОЙ ВРЕМЕНИ: убитый -9 (или зависший на awk по большому файлу) тик оставлял бы
# пустой файл навсегда, и учёт трафика молча умирал до ребута — панель показывала бы «за сегодня»
# на момент смерти. Протухший лок перехватываем (то же сделано в watchdog.sh).
LOCK_STALE=${LOCK_STALE:-3600}
# Возраст лока — через age_since (clock-lib.sh): лок в /tmp рождается после загрузки, а часы без RTC
# прыгают вперёд через ~13 мин ⇒ голая разность объявляет живой лок протухшим и пускает второй тик
# считать те же дельты. Шим = прежнее поведение. [[watchdog-clock-step-false-death]]
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
# Имя WAN-интерфейса — у владельца (ip-lib.sh::wan_iface, следит C81); шим = прежняя строка.
if [ -f "$ENODIA_DIR/ip-lib.sh" ]; then . "$ENODIA_DIR/ip-lib.sh"; fi
command -v wan_iface >/dev/null 2>&1 || wan_iface() { ip route show default 2>/dev/null | awk '/^default/{d=""; for(i=1;i<=NF;i++) if($i=="dev") d=$(i+1); if(d!="" && d !~ /^(awg|xtun)/){print d; exit}}'; }
command -v age_since >/dev/null 2>&1 || age_since() {
    case "$1" in ''|*[!0-9]*) echo 999999; return ;; esac
    [ "$1" -gt 0 ] && echo $(( $(date +%s) - $1 )) || echo 999999
}
if [ -e "$LOCK" ]; then
    _lt=$(cat "$LOCK" 2>/dev/null); case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
    [ "$(age_since "$_lt")" -lt "$LOCK_STALE" ] && exit 0
fi
date +%s > "$LOCK"; trap 'rm -f "$LOCK"' EXIT; trap 'exit 1' INT TERM HUP PIPE

# Часы ещё не выставлены? У BE7000 НЕТ RTC — после холодного ребута время неверно,
# пока не отработает ntpsetclock (cron */15). Пропускаем тик, иначе записали бы дельту
# с битой датой (напр. 1970-01-01) — осиротевшая строка в истории. Следующий тик после
# синхронизации часов учтёт накопленный трафик (дельта считается от .traffic-last).
# Порог — у владельца (clock-lib.sh::clock_sane, следит C82).
clock_sane || exit 0

# Traffic BY DEVICE rides this cron line and this lock (one schedule, no second writer of its files): its own step, its own
# state (traffic-dev.sh). Here, before the interface accounting's early exits — its first run must not wait for theirs.
# `</dev/null`: nothing below reads stdin, but the child must not either. The script gates on the synced clock itself.
if [ -f "$ENODIA_DIR/traffic-dev.sh" ]; then sh "$ENODIA_DIR/traffic-dev.sh" tick </dev/null >/dev/null 2>&1; fi

# trim + дефолт: `cat || echo awg` НЕ ловит пустой-но-существующий .transport (t="" → vif=xtun, и
# трафик awg0 молча считался бы нулём). Зеркало той же строки в cgi-bin/traffic — читатель эту
# граблю уже пережил, писатель отстал.
t=$(cat "$ENODIA_STATE/.transport" 2>/dev/null | tr -d ' \r\n')
# Пусто = ЛИБО роутер старше флага (несущая awg), ЛИБО установка «только панель», где транспорта
# нет вовсе; отличает их оркестратор (код 2 = старая копия ⇒ как раньше). Зеркало вилки в
# cgi-bin/traffic — читатель и писатель обязаны звать один и тот же интерфейс.
if [ -z "$t" ]; then
    t=awg
    if [ -f "$ENODIA_DIR/transport.sh" ]; then
        sh "$ENODIA_DIR/transport.sh" configured >/dev/null 2>&1
        [ "$?" = 1 ] && t=none
    fi
fi
# «-», а НЕ пустая строка: `.traffic-last` читается через `read vif vrx vtx wrx wtx wif`, и пустое
# первое поле сдвинуло бы ВСЕ остальные (та же грабля, из-за которой в файл добавляли шестое поле).
# zapret — В ОДНОЙ ВЕТКЕ С none: несущей у десинка нет ВООБЩЕ, весь трафик идёт напрямую, и
# `*)` записывал бы счётчики несуществующего xtun. Ту же вилку держит web/cgi-bin/traffic —
# правя одну, правь обе (у него ветка та же, но пишет он "" вместо "-": читателю пустое поле
# не мешает, а нам сдвинуло бы все остальные при `read`).
case "$t" in none|zapret) vif="-" ;; awg) vif=awg0 ;; *) vif=xtun ;; esac
wan_if=$(wan_iface)   # владелец имени — ip-lib.sh (та же строка у читателя cgi-bin/traffic)

# "rx tx" по имени iface; нет iface → "0 0". sed снимает двоеточие (счётчик может
# слипнуться с именем без пробела: "eth0:39189...").
devbytes() { sed 's/:/ /' /proc/net/dev 2>/dev/null | awk -v i="$1" '$1==i{print $2" "$10; f=1} END{if(!f)print "0 0"}'; }
set -- $(devbytes "$vif");          vrx=${1:-0}; vtx=${2:-0}
set -- $(devbytes "${wan_if:-_}");  wrx=${1:-0}; wtx=${2:-0}

# --- ДОП-ВЫХОДЫ: счётчики ИХ несущих -------------------------------------------------------
# ЗАЧЕМ. Вопрос человека — «куда идёт трафик», то есть ЧЕРЕЗ КАКОЙ ВЫХОД, а не «туннель против
# прямого». У каждого доп-выхода своя несущая (awgN у awg, xtunN у трёх альтов), и счётчики
# интерфейсов ядро ведёт САМО: это самый дешёвый и самый точный разрез из возможных — по адресам
# считать нельзя вообще, NSS/ECM уводит установленные потоки мимо netfilter (см. карту проекта).
#
# ИМЯ НЕСУЩЕЙ СПРАШИВАЕМ У ОРКЕСТРАТОРА (`transport.sh slot-iface`), а не выводим сами: формула
# «id -> имя» живёт у плагинов (slot_iface / slot_tun), и третья копия здесь разъехалась бы молча —
# счётчики читались бы у несуществующего имени, а карточка вечно показывала бы ноль.
# ПУСТОЕ ИМЯ — ШТАТНЫЙ ОТВЕТ, А НЕ ОШИБКА: у zapret-выхода несущей нет ВООБЩЕ (десинк идёт
# напрямую, только марки), у выключенного выхода правил нет, а старые скрипты верба не знают.
# Во всех трёх случаях выход НЕ СЧИТАЕТСЯ ВОВСЕ — и это принципиально: ноль сказал бы «через этот
# выход не прошло ничего», а правда — «этот выход считать нечем». Разводит их читатель (панель).
SLOTS_FILE="$ENODIA_STATE/.slots"
TAB=$(printf '\t')
# Exit ids = slots.sh MIN_ID..MAX_ID (C130 checks this list). Per-exit state lives in variables NAMED by the id
# (sif<k>, s<k>rx, ls<k>if …): `eval` only ever sees our own names and a digit from this list or a `[2-7]` case.
SLOT_IDS="2 3 4 5 6 7"
for _k in $SLOT_IDS; do eval "sif$_k=''; s${_k}rx=0; s${_k}tx=0; ls${_k}if=''; ls${_k}rx=0; ls${_k}tx=0"; _kmax=$_k; done
if [ -s "$SLOTS_FILE" ] && [ -f "$ENODIA_DIR/transport.sh" ]; then
    # Поля реестра: id⇥имя(b64)⇥транспорт⇥конфиг⇥fallback⇥on|off. Спрашиваем только ВКЛЮЧЁННЫЕ:
    # у выключенного несущей нет, а `slot-iface` на нём и так ответит отказом — экономим форк.
    while IFS="$TAB" read -r _sid _snb _stp _scfg _sfb _sen; do
        [ "$_sen" = on ] || continue
        # `</dev/null` ОБЯЗАТЕЛЕН: stdin этого цикла — САМ РЕЕСТР, и всё, что мы отсюда зовём,
        # его наследует. Прочитай оркестратор (или любой плагин по дороге) хоть строку со входа —
        # цикл молча потеряет выход, а понять это по результату будет нельзя: просто «выход №3
        # не считается». Гард стоит ноль, а закрывает целый класс.
        _sif=$(sh "$ENODIA_DIR/transport.sh" slot-iface "$_sid" </dev/null 2>/dev/null) || _sif=""
        [ -n "$_sif" ] || continue
        case "$_sid" in [2-7]) eval "sif$_sid=\$_sif" ;; esac
    done < "$SLOTS_FILE"
fi
for _k in $SLOT_IDS; do
    eval "_sif=\$sif$_k"; [ -n "$_sif" ] || continue
    set -- $(devbytes "$_sif"); eval "s${_k}rx=\${1:-0}; s${_k}tx=\${2:-0}"
done

# прошлый замер
lvif=""; lvrx=0; lvtx=0; lwrx=0; lwtx=0; lwif=""
[ -f "$LAST" ] && read lvif lvrx lvtx lwrx lwtx lwif < "$LAST"
for n in lvrx lvtx lwrx lwtx; do eval "x=\$$n"; case "$x" in ''|*[!0-9]*) eval "$n=0";; esac; done
# ...и прошлый замер доп-выходов — СТРОКАМИ "s<id> <iface> <rx> <tx>" ниже первой. Первую строку
# цикл видит тоже, но её первое поле — имя несущей (awg0/xtun), в `case` оно не попадает.
if [ -f "$LAST" ]; then
    while read -r _k _i _r _t; do
        case "$_k" in s[2-7]) _n=${_k#s}; eval "ls${_n}if=\$_i; ls${_n}rx=\$_r; ls${_n}tx=\$_t" ;; esac
    done < "$LAST"
fi
for _k in $SLOT_IDS; do
    for n in ls${_k}rx ls${_k}tx; do eval "x=\$$n"; case "$x" in ''|*[!0-9]*) eval "$n=0";; esac; done
done

# WAN-iface ПРОПАЛ (нет дефолт-маршрута: пере-дозвон PPPoE, флап порта, авария провайдера — то
# есть ровно те моменты, ради которых учёт и ведут). devbytes отдаёт "0 0", и прежний код писал
# эти НУЛИ в .traffic-last: на СЛЕДУЮЩЕМ тике wrx(реальный, кумулятивный с буста) >= lwrx(0) ⇒
# дельта = ВЕСЬ счётчик eth0 ⇒ в «сегодня» прилетали десятки гигабайт, которых не было.
# Правильно — не судить: переносим прошлый замер как есть (дельта 0), а когда iface вернётся,
# дельта честно посчитается за весь пропуск. Имя iface теперь тоже в файле: смена (eth0→pppoe-wan)
# = чужой счётчик, трактуем как обнуление — зеркало логики vif.
if [ -z "$wan_if" ]; then
    wan_if="$lwif"; wrx=$lwrx; wtx=$lwtx
fi

had_last=0; [ -f "$LAST" ] && had_last=1
{                                                          # для следующей дельты
    printf '%s %s %s %s %s %s\n' "$vif" "$vrx" "$vtx" "$wrx" "$wtx" "${wan_if:-?}"
    # Строку выхода пишем ТОЛЬКО когда несущая у него есть: её ОТСУТСТВИЕ и есть признак «считать
    # нечем» для читателя — web/cgi-bin/traffic берёт имя интерфейса ОТСЮДА, чтобы не форкать
    # transport.sh на каждый запрос (панель спрашивает трафик раз в пять секунд).
    for _k in $SLOT_IDS; do
        eval "_sif=\$sif$_k; _r=\$s${_k}rx; _t=\$s${_k}tx"
        [ -n "$_sif" ] && printf 's%s %s %s %s\n' "$_k" "$_sif" "$_r" "$_t"
    done
    :          # группа не кончается на `[ ] && …`: rc-страж, а не украшение (класс Б5-9)
} > "$LAST.tmp" && mv "$LAST.tmp" "$LAST"
# ЧЕРЕЗ ВРЕМЕННЫЙ ФАЙЛ, как и посуточный рядом. `> "$LAST"` СНАЧАЛА обрезает файл, и всё это время
# читатель (панель дёргает CGI раз в пять секунд) может застать его пустым или в половину строки:
# тогда шестое поле не разберётся, файл сойдёт за «старого формата», и «незаписанной дельтой»
# окажется весь кумулятивный счётчик WAN — на экране это скачок в десятки гигабайт. Раньше окно
# было в одну строку, со строками выходов стало шире; `mv` в пределах одной ФС атомарен.
# Первый запуск (нет прошлого замера) — НЕ вкидываем «всё с буста» в сегодня.
[ "$had_last" = 0 ] && exit 0

# Дельты через awk (double, точно до 2^53 ≈ 9 ПБ) — НЕ через $(()) (busybox-арифметика
# может быть 32-битной, а eth0-счётчик уже >2^31). Детект обнуления/смены несущей.
# lwif пустой = файл СТАРОГО формата (пять полей): судим как раньше, только по счётчику.
deltas=$(awk -v vif="$vif" -v lvif="$lvif" -v vrx="$vrx" -v vtx="$vtx" -v wrx="$wrx" -v wtx="$wtx" \
             -v lvrx="$lvrx" -v lvtx="$lvtx" -v lwrx="$lwrx" -v lwtx="$lwtx" \
             -v wif="$wan_if" -v lwif="$lwif" 'BEGIN{
    OFMT="%.0f"; CONVFMT="%.0f";
    wsame=(lwif=="" || wif==lwif);   # lwif пуст = файл СТАРОГО формата: судим только по счётчику
    wunk=(lwif=="?");                # в прошлый замер WAN-iface не существовало и истории нет:
                                     # сравнивать не с чем ⇒ ЧЕСТНЕЕ пропустить интервал (0), чем
                                     # засчитать «сегодня» весь кумулятивный счётчик с буста
    # СМЕНИЛСЯ IFACE ⇒ интервал ПРОПУСКАЕМ (0), а не заряжаем весь счётчик нового имени. Счётчик
    # интерфейса кумулятивен с его СОЗДАНИЯ, а старый iface при смене остаётся жив: awg0 при
    # активном xray — «тёплый резерв», eth0 — под pppoe-wan. Возврат на него (ручное переключение,
    # cross-failover, редозвон) заряжал в «сегодня» ВСЁ, что уже учли до отхода. Замерено на
    # импорте бэкапа BE7000 (AX3600, 17.08.2026): за 08-14 «через VPN» 64.5 ГБ против 31.6 ГБ
    # «через WAN» — физически невозможно, VPN всегда ПОДМНОЖЕСТВО WAN, и панель печатала
    # «через VPN 60.2 ГБ · напрямую 0 Б · всего 29.5 ГБ». Истории под новым именем у нас нет ⇒
    # честнее потерять один пятиминутный интервал (та же логика, что у wunk выше).
    # ЧИТАТЕЛЬ (web/cgi-bin/traffic, «незаписанная дельта») так считает С САМОГО НАЧАЛА — это
    # ВТОРОЙ случай, когда писатель отстал от читателя в ОДНОМ контракте (первый — вилка `none`
    # выше). Правя одну сторону, сверяй обе.
    dvrx=(vif==lvif && vrx>=lvrx)?vrx-lvrx:(vif==lvif?vrx:0);
    dvtx=(vif==lvif && vtx>=lvtx)?vtx-lvtx:(vif==lvif?vtx:0);
    dwrx=wunk?0:((wsame && wrx>=lwrx)?wrx-lwrx:(wsame?wrx:0));
    dwtx=wunk?0:((wsame && wtx>=lwtx)?wtx-lwtx:(wsame?wtx:0));
    printf "%.0f %.0f %.0f %.0f", dvrx,dvtx,dwrx,dwtx
}')
set -- $deltas; dvrx=${1:-0}; dvtx=${2:-0}; dwrx=${3:-0}; dwtx=${4:-0}

# Дельта ОДНОГО доп-выхода — ТА ЖЕ ЛЕСТНИЦА, что у несущей выше (`dvrx`), слово в слово: имя то же
# и счётчик вырос ⇒ разность · имя то же, счётчик УПАЛ ⇒ интерфейс пересоздали, отсчёт от нуля ⇒
# весь счётчик · имя ДРУГОЕ (сменили транспорт выхода) или истории нет ⇒ интервал ПРОПУСКАЕМ.
# Отдельной функцией, а не четвёртой парой в общем awk: у пары vif/wan есть свои ветки (`wsame`,
# `wunk`, файл старого формата), и вплетать в них ещё шесть переменных значило бы трогать код,
# который уже платил кровью (см. разбор выше). У busybox awk НЕТ пользовательских функций —
# поэтому лестница живёт в шелле, а awk считает арифметику (double: $(()) на этом busybox может
# быть 32-битным, а счётчики давно за 2^31).
slot_delta() {   # <iface> <rx> <tx> <прошлый iface> <прошлый rx> <прошлый tx> -> "drx dtx"
    [ -n "$1" ] || { echo "0 0"; return; }
    awk -v i="$1" -v r="$2" -v t="$3" -v li="$4" -v lr="$5" -v lt="$6" 'BEGIN{
        OFMT="%.0f"; CONVFMT="%.0f";
        printf "%.0f %.0f", (i==li&&r>=lr)?r-lr:(i==li?r:0), (i==li&&t>=lt)?t-lt:(i==li?t:0) }'
}
# The deltas reach awk through the ENVIRONMENT (TA_D<k>R / TA_D<k>T): busybox awk has no split(), and a `-v` per
# exit would be one more hand-kept list of ids. Exits without a carrier get a zero delta and no fork.
# Хвост дописываем в посуточный файл ТОЛЬКО когда считать есть что. На роутере без
# доп-выходов (это подавляющее большинство) файл обязан остаться БАЙТ-В-БАЙТ прежним: «выключено —
# прежний путь байт-в-байт» стоит в проекте дороже единообразия формата, а читатель нули и так
# видит (отсутствующее поле awk считает нулём).
nslot=0
for _k in $SLOT_IDS; do
    eval "_i=\$sif$_k; _r=\$s${_k}rx; _t=\$s${_k}tx; _li=\$ls${_k}if; _lr=\$ls${_k}rx; _lt=\$ls${_k}tx"
    _d="0 0"; [ -n "$_i" ] && { _d=$(slot_delta "$_i" "$_r" "$_t" "$_li" "$_lr" "$_lt"); nslot=1; }
    set -- $_d; export "TA_D${_k}R=${1:-0}" "TA_D${_k}T=${2:-0}"
done

now=$(date +%s); today=$(date +%F)
[ -f "$DAILY" ] || : > "$DAILY"
# Прибавить дельты к сегодняшней строке (или создать). CONVFMT=%.0f — иначе awk при
# пересборке $0 отформатировал бы большие числа как "1.23e+09" и побил бы значения.
# ХВОСТ ДОП-ВЫХОДОВ — ПОЗИЦИОННЫЙ, по НОМЕРУ выхода, а не
# по порядку в реестре: выход №3 обязан оставаться третьим и после удаления второго, иначе история
# молча переедет к соседу. Присваивание $7 при шести полях в строке РАСШИРЯЕТ её (awk пересобирает
# $0 через OFS/CONVFMT — оба заданы), поэтому день, начавшийся без выходов, дописывается сам.
# Exit k sits at $(2k+3)/$(2k+4): the first three exits keep $7..$12 as before 05.10.2026, exits 5..7 appended at $13..$18,
# so a 12-field day of the old format simply grows (the readers take a missing field as zero).
awk -v today="$today" -v now="$now" -v a="$dvrx" -v b="$dvtx" -v c="$dwrx" -v d="$dwtx" -v ns="$nslot" \
    -v km="$_kmax" 'BEGIN{OFMT="%.0f";CONVFMT="%.0f"}
  $2==today { $3+=a; $4+=b; $5+=c; $6+=d
              if(ns) for(k=2;k<=km;k++){ f=2*k+3; $f+=ENVIRON["TA_D" k "R"]; $(f+1)+=ENVIRON["TA_D" k "T"] }
              seen=1 }
  { print }
  END { if(!seen){ printf "%.0f %s %.0f %.0f %.0f %.0f", now, today, a, b, c, d
                   if(ns) for(k=2;k<=km;k++) printf " %.0f %.0f", ENVIRON["TA_D" k "R"]+0, ENVIRON["TA_D" k "T"]+0
                   printf "\n" } }
' "$DAILY" > "$DAILY.tmp" && mv "$DAILY.tmp" "$DAILY"

# подрезать историю до KEEP последних дней
lines=$(wc -l < "$DAILY" 2>/dev/null); case "$lines" in ''|*[!0-9]*) lines=0;; esac
[ "$lines" -gt "$KEEP" ] && { tail -n "$KEEP" "$DAILY" > "$DAILY.tmp" && mv "$DAILY.tmp" "$DAILY"; }
exit 0
