---
title: VPN и раздельная маршрутизация для роутеров Xiaomi на стоковой прошивке
description: >-
  AmneziaWG, Xray (VLESS), Hysteria2, WARP, ByeDPI и Zapret на Xiaomi BE3600, BE6500, BE7000, BE10000 и AX3600 без
  перепрошивки на OpenWrt. Заблокированное — через VPN, остальное напрямую; всё настраивается в веб-панели.
---

# VPN и раздельная маршрутизация для роутеров Xiaomi — без OpenWrt

**Enodia** — бесплатный проект с открытым кодом для роутеров Xiaomi **на стоковой прошивке**. Заблокированные сайты
идут через ваш VPN-сервер или открываются вовсе без сервера, остальной трафик — напрямую, на полной скорости
провайдера. Всё настраивается в веб-панели на самом роутере, перепрошивать роутер не нужно.

<video class="clip" autoplay loop muted playsinline preload="metadata" poster="media/overview.jpg"
       aria-label="Веб-панель Enodia: состояние VPN, трафик и куда он идёт">
  <source src="media/overview.webm" type="video/webm">
  <source src="media/overview.mp4" type="video/mp4">
</video>

[Скачать мастер установки](https://github.com/Axel173/enodia/releases){ .md-button .md-button--primary }
[Как установить](install.md){ .md-button }

## Роутеры

Проект запускался и работал на этих моделях со стоковой прошивкой:

<div class="models" markdown>
[**BE3600**<span>Xiaomi Router BE3600</span>](routers/be3600.md)
[**BE6500**<span>Xiaomi Router BE6500</span>](routers/be6500.md)
[**BE7000**<span>Xiaomi Router BE7000</span>](routers/be7000.md)
[**BE10000**<span>BE10000 и BE10000 PRO</span>](routers/be10000.md)
[**AX3600**<span>Xiaomi AIoT Router AX3600</span>](routers/ax3600.md)
</div>

## Что умеет

- **Раздельная маршрутизация (split tunneling).** В VPN идут только нужные сайты и сервисы — по доменам, подсетям,
  гео-категориям и группам правил, отдельно для устройств и Wi-Fi-сетей. Остальное — напрямую.
- **Несколько протоколов:** [AmneziaWG](protocols.md#amneziawg), [Xray (VLESS, Reality)](protocols.md#xray),
  [Hysteria2](protocols.md#hysteria2), [WARP](protocols.md#warp) — и обход блокировок без своего сервера:
  [ByeDPI](protocols.md#byedpi) и [Zapret](protocols.md#zapret).
- **До шести дополнительных выходов** через другие серверы: одно — через Нидерланды, другое — через Финляндию.
- **Подписки и Amnezia Premium:** серверы из одной ссылки, в том числе от 3x-ui, обновление по расписанию.
- **Сторож:** переподнимает туннель, переключает на запасной сервер, присылает письма о сбоях. Если VPS недоступен,
  дом не остаётся без интернета.
- **Доступ домой**, **шифрованный DNS**, **блокировка рекламы**, **расписания доступа для детей**, **трафик по
  устройствам** — [все возможности](features.md).

## Как это устроено

1. Вы скачиваете мастер установки и запускаете его на компьютере (Windows, macOS или Linux).
2. Мастер сам открывает SSH на роутере и ставит веб-панель. Отдельно ставить Python или PuTTY не нужно.
3. Дальше всё — в браузере: панель на `http://192.168.31.1:8088` (адрес вашего роутера, порт 8088). В ней вы
   добавляете сервер, выбираете, что пускать через VPN, и включаете нужные протоколы.

Подробно — в разделе [Установка](install.md). Вопросы — в [Telegram](https://t.me/+tfMLMVKG03FhMGYy).
