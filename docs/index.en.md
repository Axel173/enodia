---
title: VPN and split tunneling for Xiaomi routers on stock firmware
description: >-
  AmneziaWG, Xray (VLESS), Hysteria2, WARP, ByeDPI and Zapret on Xiaomi BE3600, BE6500, BE7000, BE10000 and AX3600
  without flashing OpenWrt. Blocked sites go through the VPN, the rest goes direct; managed from a web panel.
---

# VPN and split tunneling for Xiaomi routers — without OpenWrt

**Enodia** is a free, open-source project for Xiaomi routers **on stock firmware**. Blocked sites go through your VPN
server or open without any server at all, all other traffic goes direct at your ISP's full speed. Everything is
configured in a web panel on the router itself; no reflashing needed.

<video class="clip" autoplay loop muted playsinline preload="metadata" poster="../media/overview-en.jpg"
       aria-label="The Enodia web panel: VPN status, traffic and where it goes">
  <source src="../media/overview-en.webm" type="video/webm">
  <source src="../media/overview-en.mp4" type="video/mp4">
</video>

[Download the setup wizard](https://github.com/Axel173/enodia/releases){ .md-button .md-button--primary }
[How to install](install.md){ .md-button }

## Routers

The project has been run and worked on these models with stock firmware:

<div class="models" markdown>
[**BE3600**<span>Xiaomi Router BE3600</span>](routers/be3600.md)
[**BE6500**<span>Xiaomi Router BE6500</span>](routers/be6500.md)
[**BE7000**<span>Xiaomi Router BE7000</span>](routers/be7000.md)
[**BE10000**<span>BE10000 and BE10000 PRO</span>](routers/be10000.md)
[**AX3600**<span>Xiaomi AIoT Router AX3600</span>](routers/ax3600.md)
</div>

## What it does

- **Split tunneling.** Only the sites and services you choose go through the VPN — by domains, subnets, geo
  categories and rule groups, separately for devices and Wi-Fi networks. The rest goes direct.
- **Several protocols:** [AmneziaWG](protocols.md#amneziawg), [Xray (VLESS, Reality)](protocols.md#xray),
  [Hysteria2](protocols.md#hysteria2), [WARP](protocols.md#warp) — and bypassing blocks without a server of your own:
  [ByeDPI](protocols.md#byedpi) and [Zapret](protocols.md#zapret).
- **Up to six additional exits** through other servers: one site through the Netherlands, another through Finland.
- **Subscriptions and Amnezia Premium:** servers from one link, 3x-ui included, updated on a schedule.
- **Watchdog:** restarts the tunnel, switches to a backup server, emails you about failures. If the VPS is down, the
  home does not lose the internet.
- **Home access**, **encrypted DNS**, **ad blocking**, **access schedules for children**, **traffic by device** —
  [all features](features.md).

## How it works

1. You download the setup wizard and run it on a computer (Windows, macOS or Linux).
2. The wizard opens SSH on the router by itself and installs the web panel. No need to install Python or PuTTY.
3. Everything else is in the browser: the panel at `http://192.168.31.1:8088` (your router's address, port 8088).
   There you add a server, choose what goes through the VPN and turn on the protocols you need.

Details — [Installation](install.md). Questions — [Telegram](https://t.me/+tfMLMVKG03FhMGYy).
