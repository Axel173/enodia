---
title: Enodia protocols — AmneziaWG, Xray (VLESS), Hysteria2, WARP, ByeDPI, Zapret on a Xiaomi router
description: >-
  Which VPN and block-bypass protocols Enodia supports on Xiaomi routers, which need a server and what to choose:
  AmneziaWG, Xray (VLESS, Reality), Hysteria2, WARP, ByeDPI and Zapret.
---

# Protocols

Each protocol is a separate component: under «Components» in the panel you turn on only the ones you need, and the
router downloads them by itself. You can keep a main protocol and up to six additional exits at once — for example,
AmneziaWG for everything blocked and WARP for a few sites.

| Protocol | Needs your own server | What for |
|---|---|---|
| [AmneziaWG](#amneziawg) | yes (or Amnezia Premium) | The main VPN: fast, resistant to WireGuard blocking |
| [Xray](#xray) | yes | VLESS, Reality and others — when AmneziaWG gets cut |
| [Hysteria2](#hysteria2) | yes | A fast protocol over QUIC |
| [WARP](#warp) | no | Cloudflare's free exit, the router gets it by itself |
| [ByeDPI](#byedpi) | no | Bypassing blocks without a server |
| [Zapret](#zapret) | no | Bypassing blocks without a server, right in the router's kernel |

## AmneziaWG { #amneziawg }

[AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go) is WireGuard with obfuscation that blocking systems do not
recognise. It takes a config from AmneziaVPN (a `.conf` file or a `vpn://` link), a subscription, 3x-ui panels
included, or an **Amnezia Premium** key — the router takes the configs of the countries you pick from Amnezia by
itself.

## Xray (VLESS, Reality) { #xray }

[Xray-core](https://github.com/XTLS/Xray-core): VLESS (Reality included), VMess, Trojan, Shadowsocks. Servers are added
by a link, a subscription or a file; subscriptions update on a schedule. «Check servers» in the panel checks each one
with a real connection through it, not a ping.

## Hysteria2 { #hysteria2 }

[Hysteria2](https://github.com/apernet/hysteria) runs over QUIC (UDP) and gets the most out of a poor channel. A
server is added by a `hysteria2://` link or a subscription.

## WARP { #warp }

Cloudflare's free WARP. The router registers by itself — one button, the key is created on the router and never
leaves it. WARP serves as a separate exit or as a **«road» to your server**: if your ISP blocked the VPS address,
traffic to it goes through WARP. If the ISP starts cutting WARP's port, the watchdog picks another one by itself.

## ByeDPI { #byedpi }

[ByeDPI](https://github.com/hufrea/byedpi) bypasses blocks without a server: it changes how the router sends the
first packets of a connection, and the blocking system stops recognising the site. Handy for particular sites and
services.

## Zapret { #zapret }

[Zapret](https://github.com/bol-van/zapret) does what ByeDPI does, but in the router's kernel (NFQUEUE), with more
techniques. Validated on the [BE7000](routers/be7000.md) and on the [AX3600](routers/ax3600.md) with stock firmware
1.1.21 (there the component brings a kernel support package). Other models and firmware need separate validation.

!!! tip "What to choose"
    Have your own server — start with **AmneziaWG**. If it gets cut too, add **Xray (VLESS, Reality)** as a backup.
    No server — try **WARP** and **ByeDPI**/**Zapret**: some sites will open that way.
