---
title: Xiaomi routers Enodia runs on — BE3600, BE6500, BE7000, BE10000, AX3600
description: >-
  The Xiaomi routers Enodia (VPN, AmneziaWG, Xray, Zapret) has been run and worked on with stock firmware, and how the
  models differ: architecture, flash, USB, bypassing blocks without a server.
---

# Routers

Enodia runs **on Xiaomi stock firmware** — no need to flash OpenWrt. The setup wizard opens SSH access by itself. The
project has been run and worked on these models:

| Model | Architecture | What to know |
|---|---|---|
| [Xiaomi BE3600](be3600.md) | ARMv7 | Modest memory — keep only the protocols you use. Zapret is not validated on this model yet. |
| [Xiaomi BE6500](be6500.md) | ARMv7 | About 20 MB of flash, and the firmware keeps a settings backup of almost 4 MB — the wizard offers to turn it off. No USB. |
| [Xiaomi BE7000](be7000.md) | ARM64 | The project's main model: every version is checked on it. A USB stick can hold the protocols or the whole system. |
| [Xiaomi BE10000 / BE10000 PRO](be10000.md) | ARM64 | The flash is split into several volumes — the panel counts space where Enodia's files actually live. |
| [Xiaomi AX3600](ax3600.md) | ARM64 | Old kernel 4.4. Zapret — on firmware 1.1.21 with a kernel support package. |

The wizard detects the architecture by itself and installs the protocol programs built for it.

## My model is not listed

If you have another Xiaomi router with stock OpenWrt-based firmware and SSH access opens on it, Enodia will most
likely install there too — but such a model has not been checked. Write to
[Telegram](https://t.me/+tfMLMVKG03FhMGYy): a «Diagnostics» snapshot from the wizard shows what is missing.
