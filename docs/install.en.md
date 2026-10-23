---
title: Installing Enodia on a Xiaomi router — the setup wizard
description: >-
  How to install Enodia on a Xiaomi router with stock firmware: the wizard opens SSH by itself (xmir-patcher) and
  installs the web panel, then the VPN is set up in the browser. Windows, macOS, Linux.
---

# Installation

## What you need

- **A Xiaomi router** with stock firmware — [list of models](routers/index.md).
- **A computer** with Windows, macOS or Linux on the same network as the router (cable or Wi-Fi).
- **A VPN server** — if you want blocked sites to go through a VPN: your own VPS with AmneziaWG, Xray or Hysteria2,
  a subscription or an Amnezia Premium key. Bypassing blocks without a server (ByeDPI, Zapret) and WARP need no
  server — see [Protocols](protocols.md).
- **The router's admin password** — the one you use for its stock web interface.

No need to install Python, PuTTY or anything else beforehand: the launcher downloads what the wizard needs by itself.

## Steps

1. Download `enodia-setup-<version>.zip` from the [Releases](https://github.com/Axel173/enodia/releases) page and
   unpack it.
2. Run the launcher:
    - Windows — `enodia-setup.bat` (double click);
    - macOS — `enodia-setup.command`;
    - Linux — `./enodia-setup.sh` in a terminal.
3. The **setup wizard** opens in the browser. It finds the router, opens SSH access on it by itself (with the built-in
   [xmir-patcher](https://github.com/Axel173/xmir-patcher)) and installs the web panel. On the way it asks for three
   different passwords: the Xiaomi stock interface one (to open access), a new root password (to log into the router
   itself) and the Enodia web panel password. Write them down — the wizard cannot recover a password.
4. Open the panel: `http://192.168.31.1:8088` — your router's address and port 8088. The login is `admin`, the
   password is the one you set in the wizard.

In the panel you add a VPN server (a config file, a link, a QR code or a subscription), choose which sites and devices
go through the VPN, and turn on the protocols you need under «Components» — the router downloads them by itself.

!!! note "If the flash is short of space"
    Some firmware keeps a backup copy of its own settings (on the BE6500 almost 4 MB of flash). The wizard and the
    panel offer to turn that copy off and name how much space it frees first. Protocols can also live on a USB stick —
    if the router has a USB port.

## Updating

Updates come to the panel: a new version is downloaded from GitHub as a **signed package** and installed with one
button. The router checks the signature itself — it will not install someone else's package.

## Removing

Run the setup wizard again and choose «Remove from the router». There are two options:

- **«Switch VPN off»** — removes the routing and the rules; the panel, settings and servers stay, and everything can be
  switched back on;
- **«Remove everything»** — the same plus the panel and every file: the router goes back to stock, the settings are
  gone.

Before removing everything, back up the settings in the panel itself («Router» → «Settings backup») — the backup can
be applied after a new installation.

## If something went wrong

- The wizard has **«Diagnostics»**: it collects a snapshot of the router's state you can attach to a question.
- Questions — [Telegram](https://t.me/+tfMLMVKG03FhMGYy), bugs — [Issues](https://github.com/Axel173/enodia/issues).
- If the VPN server stops answering, the Enodia watchdog switches the router to a backup server or sends traffic
  direct — the home does not lose the internet.
