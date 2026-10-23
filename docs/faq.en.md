---
title: FAQ — VPN on a Xiaomi router without OpenWrt
description: >-
  Is OpenWrt needed, do you need your own server, what happens after a Xiaomi firmware update, will the speed drop,
  how to remove it — answers about Enodia on Xiaomi BE3600, BE6500, BE7000, BE10000 and AX3600.
---

# FAQ

## Do I need to flash OpenWrt?

No. Enodia runs on Xiaomi **stock firmware**. The setup wizard only opens SSH access and installs the scripts and the
web panel next to the firmware.

## Do I need my own VPN server?

For AmneziaWG, Xray and Hysteria2 — yes: your own VPS, a subscription or an Amnezia Premium key. WARP, ByeDPI and
Zapret work without a server — they open part of what is blocked, not everything. More — [Protocols](protocols.md).

## Will my internet get slower?

Only the chosen sites, devices or networks go through the VPN. Everything else goes direct at your ISP's full speed.
The speed through the VPN depends on your server.

## What if the VPN server stops working?

The watchdog notices within a couple of minutes: it restarts the tunnel, switches to a backup server, and if there are
no backups, sends traffic direct. The home keeps its internet, and you get an email.

## What happens after a Xiaomi firmware update?

A firmware update may close SSH access. Then run the setup wizard again — it opens access anew. Enodia's settings are
kept apart from its code; before a firmware update, back them up in the panel just in case («Router» → «Settings
backup»).

## Does Mi Home and the smart home work?

Yes. Xiaomi's servers in China are best sent past the VPN — in the panel that is the geo category `cn` with the action
«bypass».

## Can different devices use different VPNs?

Yes: rules are set for devices and Wi-Fi networks, and you can raise up to six additional exits — each with its own
server.

## Why not a VPN app on every device?

A VPN on the router works for every device at once — a TV, a console, a smart speaker — where a VPN app cannot be
installed. And nobody has to switch it on by hand: blocked sites go through the VPN by themselves, the rest goes direct.

## Is it free?

Yes. Enodia is an open project under the GPL-3.0 license. The only thing you may pay for is your own VPN server.

## How do I remove it?

Run the setup wizard and choose «Remove from the router» — [details](install.md#removing).

## Where do I ask?

In [Telegram](https://t.me/+tfMLMVKG03FhMGYy) or in [Issues](https://github.com/Axel173/enodia/issues) on GitHub.
