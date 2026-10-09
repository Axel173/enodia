[![Версия](https://img.shields.io/github/v/release/Axel173/enodia?include_prereleases&sort=semver&label=версия)](https://github.com/Axel173/enodia/releases)
[![Дата релиза](https://img.shields.io/github/release-date-pre/Axel173/enodia?label=релиз)](https://github.com/Axel173/enodia/releases)
[![Скачиваний всего](https://img.shields.io/github/downloads/Axel173/enodia/total?label=скачиваний)](https://github.com/Axel173/enodia/releases)
[![Скачиваний последнего релиза](https://img.shields.io/github/downloads-pre/Axel173/enodia/latest/total?label=последний%20релиз)](https://github.com/Axel173/enodia/releases)
[![Telegram](https://img.shields.io/badge/Telegram-новости-26A5E4?logo=telegram&logoColor=white)](https://t.me/+tfMLMVKG03FhMGYy)
[![Поддержать автора](https://img.shields.io/badge/поддержать_автора-ea4aaa?logo=githubsponsors&logoColor=white)](#donate)

<img src="assets/banner-enodia-no-vpn.png" alt="Enodia — VPN и раздельная маршрутизация для роутеров Xiaomi" width="100%">

### Русский | [English](README.en.md)

Enodia — открытый проект для роутеров Xiaomi на стоковой прошивке. Заблокированные сайты идут через
ваш VPN-сервер или открываются без сервера, остальной трафик — напрямую. Настраивается всё в
веб-панели на самом роутере.

<img src="assets/panel-overview.jpg" alt="Веб-панель Enodia на планшете и телефоне: состояние VPN, трафик и куда он идёт" width="100%">

### [Скачать](https://github.com/Axel173/enodia/releases) | [Telegram](https://t.me/+tfMLMVKG03FhMGYy) | [Поддержать автора](#donate)

## Возможности

- Установка с компьютера: мастер сам открывает SSH на роутере и ставит панель, дальше всё в браузере.
- Раздельная маршрутизация по доменам, подсетям, гео-категориям и группам правил, отдельно для
  устройств и Wi-Fi-сетей.
- Несколько VPN-протоколов и до шести дополнительных выходов через другие серверы.
- Обход блокировок без своего сервера: ByeDPI и Zapret.
- Доступ домой: роутер работает как сервер AmneziaWG, телефон подключается по QR-коду.
- Шифрованный DNS (DoH/DoT), блокировка рекламы, вход в панель с двухфакторной аутентификацией.
- Сторож: переподнимает туннель, переключает на запасной сервер, присылает письма о сбоях.
- Расписания доступа для детей и приставок: когда устройству можно в интернет, лимит минут в день и окна
  «ограничено» — закрыты выбранные категории (соцсети, мессенджеры, видео, игры, любой пул каталога гео, свои сайты и
  адреса), остальное работает; или наоборот — открыто только разрешённое; безопасный поиск Google, Яндекса, Bing,
  DuckDuckGo и YouTube.
- Свои задачи по расписанию: скрипт, файл или команда — по cron, при загрузке или кнопкой, с историей запусков
  и письмом при ошибке; весь crontab роутера виден и правится в панели.
- Трафик за сегодня, неделю, месяц и год: через туннель и напрямую, по выходам и по устройствам.
- Обновления из панели подписанным пакетом с GitHub.
- Протоколы или всю систему можно держать на USB-флешке.
- Панель на русском и английском, светлая и тёмная тема.

## Роутеры

Проект запускался и работал на роутерах Xiaomi BE3600, BE6500, BE7000, BE10000, BE10000 PRO и AX3600
со стоковой прошивкой. Root-доступ по SSH мастер установки открывает сам через встроенный
[xmir-patcher](https://github.com/Axel173/xmir-patcher).

## <a id="protocols"></a>Протоколы

[![AmneziaWG](https://img.shields.io/badge/AmneziaWG-2dd4bf)](https://github.com/amnezia-vpn/amneziawg-go)
[![Xray](https://img.shields.io/badge/Xray-a371f7)](https://github.com/XTLS/Xray-core)
[![Hysteria2](https://img.shields.io/badge/Hysteria2-3fb950)](https://github.com/apernet/hysteria)
[![ByeDPI](https://img.shields.io/badge/ByeDPI-d29922)](https://github.com/hufrea/byedpi)
[![Zapret](https://img.shields.io/badge/Zapret-db6d28)](https://github.com/bol-van/zapret)

## Установка

1. Скачайте `enodia-setup-<версия>.zip` со страницы
   [Releases](https://github.com/Axel173/enodia/releases) и распакуйте.
2. Запустите `enodia-setup.bat` (Windows), `enodia-setup.command` (macOS) или `./enodia-setup.sh` (Linux).
3. Пройдите мастер установки в браузере.
4. Откройте панель: `http://192.168.31.1:8088` (IP вашего роутера, порт 8088). Логин — `admin`, пароль — тот, что
   задали в мастере.

Python ставить не нужно: если его нет, лаунчер скачает сам. Подробная документация готовится, вопросы —
в [Telegram](https://t.me/+tfMLMVKG03FhMGYy).

## Используемые проекты

- [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go), [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)
- [Xray-core](https://github.com/XTLS/Xray-core)
- [Hysteria](https://github.com/apernet/hysteria)
- [ByeDPI](https://github.com/hufrea/byedpi)
- [zapret](https://github.com/bol-van/zapret)
- [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)
- [https_dns_proxy](https://github.com/aarond10/https_dns_proxy)
- [xmir-patcher](https://github.com/openwrt-xiaomi/xmir-patcher)
- [amneziawg-be7000](https://github.com/alexandershalin/amneziawg-be7000) — скрипт установки AmneziaWG (`awg_setup.sh`)
- списки: [opencck / iplist](https://iplist.opencck.org) (на базе [rekryt/iplist](https://github.com/rekryt/iplist)),
  [ITDog allow-domains](https://github.com/itdoginfo/allow-domains)

Спасибо сообществу [@xiaomi_be7000](https://t.me/xiaomi_be7000) за опыт по этим роутерам.

## Лицензия

Код проекта — [GPL-3.0](LICENSE). Программы протоколов в `bin/` собраны из исходников проектов выше и распространяются
под их собственными лицензиями.

## <a id="donate"></a>Поддержать автора

Проект **бесплатный и с открытым кодом**, и за ним стоит много ручной работы: отладка на живом
железе, поддержка списков и скриптов, документация.

Если он сэкономил вам **время и нервы** или просто оказался полезным — можно сказать спасибо:

**Разовый донат или периодичный через Telegram:**
- 💬 **Telegram (Tribute)** — [web.tribute.tg/d/LtA](https://web.tribute.tg/d/LtA) (картой)
- 💎 **Telegram (Tribute, крипта)** — [t.me/tribute](https://t.me/tribute/app?startapp=dLtA) (можно криптой, прямо в Telegram)

**Криптовалютой** (несколько сетей на выбор — донор берёт удобную):
<!-- Один адрес на сеть, токены сети делят его:
       ETH + USDT-ERC20      → один Ethereum-адрес (0x…)
       TRX + USDT-TRC20      → один TRON-адрес (T…)
       Toncoin + USDT-TON    → один TON-адрес (UQ…)
     Дёшево донору: TON и USDT-TON (~цент), SOL (доли цента), TRX. Дороже: BTC, ETH, USDT-ERC20. Адреса проверены по контрольным суммам. -->
- ₿ **Bitcoin (BTC)** — `bc1q5wdv30gdnsc95dkju6zkenjjcsnfs0z77wxhsh`
- Ξ **Ethereum (ETH)** — `0x6558410D16A2937c7B7eF7E447013ddEadf11e4e`
- ₮ **USDT** — сеть **TON** — `UQDkGR4JuzMN1cUg_5ehYf5RFRSbvs7ynjeOdPCyC72F8r3a`
- ₮ **USDT** — сеть **TRC-20** (TRON) — `TKPAFNRJUx6zcYTeCrAEBjFoWhuPUDyBG8`
- ₮ **USDT** — сеть **ERC-20** (Ethereum) — `0x6558410D16A2937c7B7eF7E447013ddEadf11e4e`
- 💎 **Toncoin (TON)** — `UQDkGR4JuzMN1cUg_5ehYf5RFRSbvs7ynjeOdPCyC72F8r3a`
- 🔺 **TRON (TRX)** — `TKPAFNRJUx6zcYTeCrAEBjFoWhuPUDyBG8`
- ◎ **Solana (SOL)** — `Eq48vnUcJn8yxmAtmyZJ4wmGW3TJaMhRdZkRJi1VULYx`

**Берёте VPS для проекта? Возьмите по реферальной ссылке:**
вам всё равно нужен сервер (см. [Протоколы](#protocols)) — если оформите по ссылке ниже,
автору начислится небольшой бонус, **а для вас цена та же** (а по VDSina — даже со скидкой).
- 🖥️ **[MegaHost](https://megahost.kz/?from=16375)** (реферальная ссылка) — VPS и хостинг в Казахстане (свои дата-центры, регистратор с 2009 г.)
- 🖥️ **[JustHost](https://justhost.asia/?ref=232764)** (реферальная ссылка) — VPS во множестве локаций по миру (можно выбрать страну сервера)
- 🖥️ **[VDSina](https://www.vdsina.com/?partner=x8rv7m67wj)** (реферальная ссылка) — недорогие VPS с почасовой оплатой; по этой ссылке **вам скидка 10%**. _(Без скидки, но с бо́льшим бонусом автору — [альтернативная ссылка](https://www.vdsina.com/?partner=7i8wuiy8x5).)_
- 🖥️ **[HostVDS](https://hostvds.com/?affiliate_uuid=f47d06d6-4bbf-420a-844b-4bee4e98886a)** (реферальная ссылка) — недорогие VPS на NVMe, локации по всему миру

Спасибо!
