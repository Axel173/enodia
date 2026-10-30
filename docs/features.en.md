---
title: Enodia features — split tunneling, exits, watchdog, DNS, schedules on a Xiaomi router
description: >-
  What Enodia does on a Xiaomi router: split tunneling by domains, subnets and geo categories, up to six exits,
  subscriptions and Amnezia Premium, a watchdog, home access, encrypted DNS, ad blocking, schedules and traffic.
---

# Features

## Split tunneling

Only what you choose goes through the VPN, the rest goes direct. Rules are set:

- **by domains** — one site or a list; subdomains fall under the rule by themselves;
- **by subnets** — ready-made lists of blocked addresses update every night;
- **by geo categories** — «YouTube», «Telegram», «China» and hundreds more: into the VPN, past the VPN, blocked or
  through Zapret;
- **by rule groups** — your own sets of sites and addresses, each group with its own direction and its own exit;
- **by devices and Wi-Fi networks** — for example, the TV entirely through the VPN and the guest network direct.

The «What the device requests» screen shows where the chosen device goes and which way each address will take — a
rule is created from there with one tap.

## Several exits

Besides the main VPN you can raise **up to six additional exits** through other servers and protocols and send your
own sites, groups or devices to each. An exit whose server your ISP blocked can go over a «road» — another exit, for
example your own WARP.

## Subscriptions and Amnezia Premium

Xray, Hysteria2 and AmneziaWG servers are added from one subscription link (3x-ui included) and updated on a
schedule. An **Amnezia Premium** key goes in the same place: the router takes the configs of the countries you pick by
itself. The panel hands any saved server back — as a link, a QR code or a file. If a provider gives the subscription
only to a particular app (Happ, for example) and counts devices, the router presents itself as that app and sends its
own device ID (HWID) — set per subscription.

## Watchdog

Every two minutes the watchdog checks that the VPN really carries traffic. If the server went silent, it restarts the
tunnel, switches to a backup server, and if there are no backups, sends traffic direct so the home does not lose the
internet. Failures and recoveries come by email (any SMTP).

## Home access

The router becomes an AmneziaWG server: a phone or a laptop connects to the home network with a QR code — while
travelling, over mobile internet.

## DNS and ad blocking

- **Encrypted DNS:** DoH, DoT, DoQ and DoH3 (over QUIC) and ODoH — through a relay, so the resolver never learns whose
  questions they are.
- **Ad and tracker blocking** — by lists, for the whole home network.
- **Your own DNS records** and addresses pinned to devices.

## Access schedules

For children and consoles: when a device may go online, a daily minute limit and «limited» windows — the chosen
categories (social networks, messengers, video, games) are closed, the rest works. Or the other way round — only the
allowed is open. Safe search for Google, Yandex, Bing, DuckDuckGo and YouTube.

## Traffic

For today, the week, the month and the year: through the tunnel and direct, by exit and by device.

## The panel

- Russian and English, light and dark themes, comfortable on a phone.
- Password login, optionally with a second factor (TOTP); from the internet the panel opens only over HTTPS and with
  the second factor.
- Your own scheduled tasks: a script, a file or a command — on a cron schedule, at boot or by a button.
- A backup of all settings and their restore.
- Updates from GitHub as a signed package.
- Protocols or the whole system on a USB stick or an SSD in an M.2 slot, if the router has one.
