#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# Enodia — установка веб-панели (ПК-сторона проекта)
# ============================================================
# Python-версия ПК-стороны. Работает ОДИНАКОВО на Windows / macOS / Linux: новичок
# запускает, вводит пароль root, ставит панель. Зачем Python, а не PowerShell:
#   * Python 3 УЖЕ обязателен (утилита доступа xmir-patcher, которой мастер открывает root-SSH, — на Python) →
#     версия не добавляет установок, а УБИРАЕТ PuTTY (один рантайм вместо двух).
#   * in-process SSH (paramiko): пароль/байты/UTF-8 нативно → уходит ~⅓ костылей
#     оригинала (кавычки plink, CRLF, двойной base64 ради кириллицы, кодовая страница).
#
# ЧТО ЭТА ПРОГРАММА ДЕЛАЕТ — И ЧЕГО НЕ ДЕЛАЕТ. Она ставит РОВНО веб-панель со всей
# обвязкой (скрипты, cron, десинк-бутстрап ~0.4 МБ) и даёт к панели доступ: адрес, пароль
# панели, пароль root, диагностика, удаление. Транспорт она не выбирает и не активирует;
# протоколы (Xray, AmneziaWG, Hysteria2, DoH, HTTPS панели) роутер качает САМ из панели —
# «Компоненты», а серверы, сайты, Wi-Fi и режимы настраиваются там же, в браузере.
# Отсюда и четыре пункта меню вместо двадцати: два инструмента с одинаковой властью — это
# два набора граблей и вечный вопрос «где правда» (см. cli-installer-only-goal).
#
# Что НЕ трогаем: все роутерные *.sh/*.conf (busybox-сторона) — этот файл их только
# дёргает по SSH. Опасная hardware-логика остаётся в скриптах роутера.
#
# Зависимости: см. requirements.txt (paramiko + keyring). Запуск: python enodia.py
# Аргументы: --install / --manage форсируют ветку; неинтерактив (--push/--push-bin/--exec*)
# описан ниже у parse_args — это дев-инструмент, реформы меню он не касается.
# ============================================================

import sys
import os
import re
import socket
import base64
import hashlib
import io
import json
import subprocess
import tarfile
import getpass as _getpass
import threading
from collections import namedtuple

# Версия PC-стороны проекта. Держится В СИНХРОНЕ с `version` в pyproject.toml и requirements.txt
# (копии сознательные — uv-путь и pip-путь; разъезд ловит C35). См. CHANGELOG.md.
PROJECT_VERSION = "1.0.0"

# --- Зависимость paramiko (in-process SSH) — с авто-доустановкой ---
# paramiko ОБЯЗАТЕЛЕН (in-process SSH). Если его нет — НЕ падаем молча с кодом 1: на
# Windows .bat-лаунчер тогда мгновенно закрывает окно, и новичок не видит причину
# (отчёт тестера 25.06.2026 — «при первом запуске версии с портом, если не установлены
# зависимости, установка мигает и закрывается»). Поэтому: пробуем доустановить
# зависимости через pip автоматически, повторяем импорт; если и это не вышло —
# печатаем инструкцию и ЖДЁМ Enter, чтобы окно осталось открытым и ошибку было видно.
def _ensure_paramiko():
    import importlib
    try:
        import paramiko  # noqa: F401
        return
    except ImportError:
        pass
    sys.stderr.write("\n[i] Нет библиотеки paramiko (SSH). Пробую доустановить зависимости через pip...\n"
                     "[i] paramiko (SSH) is missing. Trying to install the dependencies with pip...\n")
    sys.stderr.flush()
    req = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements.txt")
    pkgs = (["-r", req] if os.path.isfile(req) else ["paramiko", "keyring"])
    base = [sys.executable, "-m", "pip", "install"]
    for extra in ([], ["--user"]):   # сначала в текущее окружение, потом в user-site
        try:
            rc = subprocess.call(base + extra + pkgs)
        except Exception:
            rc = 1
        if rc == 0:
            break
    importlib.invalidate_caches()
    try:
        import paramiko  # noqa: F401
        return
    except ImportError:
        pass
    # ОБА ЯЗЫКА РАЗОМ — и это не небрежность. Сюда мы попадаем ДО первой строки мастера, то
    # есть до того, как человек выбрал язык: спросить его негде, а угадывать по локали ОС
    # ради сообщения об ошибке значит рискнуть показать непонятное там, где нужно понятное.
    sys.stderr.write(
        "\n[!] paramiko не удалось установить автоматически.\n"
        "    Установите вручную и запустите снова:\n"
        "        pip install paramiko keyring\n"
        "    (или:  python -m pip install -r requirements.txt)\n"
        "    Linux/macOS с системным Python: сделайте venv — python3 -m venv .venv &&\n"
        "    .venv/bin/pip install -r requirements.txt\n"
        "\n[!] paramiko could not be installed automatically.\n"
        "    Install it by hand and start again:\n"
        "        pip install paramiko keyring\n"
        "    (or:  python -m pip install -r requirements.txt)\n"
        "    On a system-managed Python (Linux/macOS) use a venv — python3 -m venv .venv &&\n"
        "    .venv/bin/pip install -r requirements.txt\n\n")
    try:
        input("Нажмите Enter, чтобы закрыть окно / press Enter to close this window...")
    except (EOFError, KeyboardInterrupt):
        pass
    sys.exit(1)

_ensure_paramiko()
import paramiko


# --- Совместимость со старыми dropbear на стоке BE7000 ---
# Симптом (бета 03–04.07.2026): у одного тестера .py входит, у другого падает на РУКОПОЖАТИИ
# ещё ДО пароля. paramiko 5.x намеренно выпилил легаси RSA/SHA-1 в ТРЁХ местах, а старый dropbear
# (RFC 8332 rsa-sha2 не умеет) отдаёт ИМЕННО ssh-rsa/SHA-1 → по очереди ловим:
#   1) `_preferred_keys` без ssh-rsa → пересечение host key пустое → IncompatiblePeer «no acceptable host key»;
#   2) добавили в _preferred_keys, но `_key_info` без ssh-rsa → host key согласован, но не парсится → `KeyError: 'ssh-rsa'` (лог тестера);
#   3) распарсили, но `RSAKey.HASHES` без ssh-rsa → verify_ssh_sig отдаёт False на SHA-1-подпись → провал верификации.
# Лечим все три. Host key мы НЕ верифицируем против known_hosts (AutoAddPolicy — роутер в своей
# LAN, ключ меняется после перепрошивки), поэтому SHA-1 тут приемлем, а легаси-типы дописываем в
# КОНЕЦ списков — современные остаются в приоритете (даунгрейда для нормальных серверов нет).
# ВАЖНО: в _preferred_keys добавляем ТОЛЬКО то, что реально парсится (иначе negotiation выберет
# неразбираемый тип → снова KeyError). ssh-dss не поддерживаем на paramiko 5.x — DSSKey удалён.
# Один раз на классе Transport (единственный путь коннекта — Router._client). Идемпотентно.
def _enable_legacy_ssh_algos():
    T = getattr(paramiko, "Transport", None)
    if T is None:
        return
    # (2) вернуть ПАРСЕРЫ легаси host key в _key_info
    key_info = getattr(T, "_key_info", None)
    if isinstance(key_info, dict):
        rsak = getattr(paramiko, "RSAKey", None)
        if rsak is not None:
            key_info.setdefault("ssh-rsa", rsak)
        dssk = getattr(paramiko, "DSSKey", None)  # paramiko 5.x: DSA удалён совсем → обычно None
        if dssk is not None:
            key_info.setdefault("ssh-dss", dssk)
    # (3) вернуть SHA-1 в верификатор RSA-подписи (иначе ssh-rsa-подпись dropbear не пройдёт)
    try:
        from cryptography.hazmat.primitives import hashes as _hashes
        rsak = getattr(paramiko, "RSAKey", None)
        if rsak is not None and isinstance(getattr(rsak, "HASHES", None), dict):
            rsak.HASHES.setdefault("ssh-rsa", _hashes.SHA1)
    except Exception:
        pass
    # (1) разрешить легаси-алгоритмы в согласовании — но ТОЛЬКО те, что РЕАЛЬНО разрешимы на этой
    #     версии paramiko: имя обязано быть в соответствующем info-словаре. Иначе `_send_kex_init`
    #     валидирует список и кидает ValueError('unknown cipher') на КАЖДОМ коннекте — это сломало
    #     бы даже рабочие входы (поймано E2E-тестом). Потому KEX ...-sha1 на 5.x просто отсеется
    #     (в _kex_info их нет), а ssh-rsa пройдёт (мы добавили его в _key_info шагом (2) выше).
    def _append_known(list_attr, info_attr, wanted):
        info = getattr(T, info_attr, None)
        cur = getattr(T, list_attr, None)
        if not isinstance(info, dict) or not isinstance(cur, tuple):
            return
        add = tuple(a for a in wanted if a in info and a not in cur)
        if add:
            setattr(T, list_attr, cur + add)
    _append_known("_preferred_keys", "_key_info", ("ssh-rsa", "ssh-dss"))
    _append_known("_preferred_kex", "_kex_info",
                  ("diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1"))

_enable_legacy_ssh_algos()

# keyring — опционален: при отсутствии backend (headless Linux) падаем на файл chmod 600.
try:
    import keyring as _keyring
    _HAVE_KEYRING = True
except Exception:
    _keyring = None
    _HAVE_KEYRING = False


# ============================================================
# Константы (дефолты; реальный IP роутера — из settings.json, см. App)
# ============================================================
ROUTER_USER = "root"
ENODIA_DIR = "/data/usr/app/enodia"
# Каталогов на роутере ЧЕТЫРЕ, и путать их нельзя: код обновление заменяет целиком, а
# настройки и бинари протоколов его переживают. ПК-сторона читает и то, и другое —
# отсюда отдельные константы вместо одной. Литералов «/data/usr/app/...» в файле больше нет.
ENODIA_STATE = "/data/usr/app/enodia-state"
ENODIA_BIN = "/data/usr/app/enodia-bin"
# ЧЕТВЁРТЫЙ — резидентный бутстрап: на него ссылаются ВСЕ cron-строки (`boot.sh <цель>.sh`),
# потому что первые три могут целиком уехать на внешний накопитель. Собирает его install.sh
# (верб `boot.sh sync`), а ПК-сторона обязана проверить, что он там есть: без него после
# ребута не поднимется НИЧЕГО, а cron при этом выглядит заполненным.
ENODIA_BOOT = "/data/usr/app/enodia-boot"
# КАТАЛОГ ПРЕЖНЕЙ ВЕРСИИ (до ребрендинга). Историческая константа: меняться ей уже некуда, но
# копий у неё быть не должно — её спрашивают и мастер, и CLI, и она же названа человеку в тексте
# отказа. Критерий «стоит ли прежняя» ОДИН и совпадает с install.sh: файл снимальщика ЛИБО живая
# cron-строка. Второй признак важнее: вред создаёт не файл, а задача, которая каждую минуту
# поднимает вторую копию системы.
LEGACY_DIR = "/data/usr/app/awg"
LEGACY_PROBE = (f'if [ -f {LEGACY_DIR}/uninstall.sh ] || '
                f'grep -qF {LEGACY_DIR}/ /etc/crontabs/root 2>/dev/null; then echo LEGACY; fi')
# «НЕСУЩАЯ ДЕРЖИТ МАРШРУТ» — ОДНА СТРОКА НА ВСЮ ПК-СТОРОНУ. На роутере на этот вопрос отвечает
# ip-lib.sh::carrier_iface (следит C81), но ПК роутерных библиотек не сорсит — он посылает шелл
# строкой, и потому копия тут законна РОВНО ОДНА. Их было две, и они уже разошлись: шапка статуса
# спрашивала `grep -q "^default"`, а «жива ли панель» — `grep -q default` (то есть считала бы
# несущей и строку `default` в середине вывода). Смысл: `default` в БОЕВОЙ table 1000 ставит
# только плагин несущей, пусто = lookup проваливается в main = трафик идёт ПРЯМО (fail-open).
SH_CARRIER_ROUTE = "ip route show table 1000 2>/dev/null | grep -q '^default'"
# ЛОГИН ПАНЕЛИ. Учётных записей у панели нет — имя существует ради менеджеров паролей (запись
# они ключуют парой «имя + адрес») и потому одно на весь проект: роутерная сторона держит его в
# totp.sh (PANEL_USER, там же сверка), здесь — ПК-сторона, которая тем же именем и входит формой,
# и стучится Basic'ом в панель старее 03.09.2026. Разъедутся — вход с ПК начнёт получать «логин у
# панели один», а человек увидит «пароль не принят».
PANEL_USER = "admin"
DEFAULT_ROUTER_IP = "192.168.31.1"
DEFAULT_LAN_SUBNET = "192.168.31."

# Название категории меню — ОДНОЙ строкой на весь скрипт: на него ссылаются подсказки в шести
# местах («меню -> «…» -> пароль панели»), оба README и ответы тестерам, а номеров пунктов у нас
# нет принципиально (меню data-driven, список зависит от состояния роутера) — ссылаться можно
# только по имени. Разъехавшееся имя = совет, ведущий в несуществующий пункт.
# «и веб-панели» в имени НЕ украшение: пароль панели ищут именно здесь, а «Доступ к роутеру»
# читается как «про SSH» и человек проходит мимо (замечание пользователя 16.08.2026).
MENU_ACCESS = "Доступ к роутеру и веб-панели"

# Каталог под не-секреты (settings.json) и фолбэк-файл пароля. На Windows = %APPDATA%.
# ПЕРЕЕХАЛ при ребрендинге: `vpn-toggle` -> `enodia`. Совместимости с замороженным be7000.ps1
# по имени каталога больше нет и не надо — монолит выведен из обращения. Перенос старого
# содержимого делает _migrate_cred_dir ниже: без него человек молча терял бы IP роутера и
# сохранённый пароль, то есть ребрендинг выглядел бы как «утилита забыла мой роутер».
def _cred_dir():
    if os.name == "nt":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "enodia")

CRED_DIR = _cred_dir()

# РАЗОВЫЙ МОСТ РЕБРЕНДИНГА: %APPDATA%/vpn-toggle -> %APPDATA%/enodia. Переносим КАТАЛОГОМ, а не
# по файлу: там и settings.json (IP роутера), и фолбэк-хранилище пароля — по отдельности они
# бессмысленны. Условие «нового ещё нет» обязательно: иначе повторный запуск затёр бы свежие
# настройки старыми. Старый каталог НЕ удаляем — человек, откатившийся на прежнюю сборку, должен
# застать её рабочей. Молча: до определения warn()/ok() здесь ещё далеко, а падать из-за
# косметики нельзя. Блок умрёт вместе с установками, помнящими старое имя.
def _migrate_cred_dir():
    old = os.path.join(os.path.dirname(CRED_DIR), "vpn-toggle")
    if old == CRED_DIR or os.path.exists(CRED_DIR) or not os.path.isdir(old):
        return
    try:
        import shutil
        shutil.copytree(old, CRED_DIR)
    except Exception:
        pass

_migrate_cred_dir()
CRED_FILE = os.path.join(CRED_DIR, "cred.dat")          # фолбэк-хранилище пароля (без keyring)
SETTINGS_FILE = os.path.join(CRED_DIR, "settings.json")  # IP роутера и пр. не-секреты
LOG_FILE = os.path.join(CRED_DIR, "enodia.log")          # ПК-лог для отлова багов у тестеров

# Дебаг-режим: ENODIA_DEBUG=1 → в лог падают и ярлыки SSH-команд с кодами возврата (диагностика
# роутерных сбоев вроде «пустой ipset»). Ошибки/трейсы пишутся ВСЕГДА, независимо от флага.
DEBUG = os.environ.get("ENODIA_DEBUG", "").strip().lower() not in ("", "0", "false", "no")

_LOG_MAX = 512 * 1024  # ~0.5 МБ; при превышении оставляем «хвост» файла — ротации по файлам нет
def logdbg(msg):
    # ПК-сторонний лог для тестеров: пишем ТОЛЬКО метаданные/ошибки. НИКОГДА — пароль и НИКОГДА
    # stdin-payload (в нём приватные ключи awg.conf). Ярлык команды секрета не содержит: пароли
    # идут через stdin_data (см. action_set_panel_password), а не в argv. Best-effort — сам лог
    # не должен ронять приложение (любой сбой записи глушим).
    try:
        os.makedirs(CRED_DIR, exist_ok=True)
        try:
            if os.path.getsize(LOG_FILE) > _LOG_MAX:
                with open(LOG_FILE, "rb") as fh:
                    fh.seek(-_LOG_MAX // 2, os.SEEK_END)
                    tail = fh.read()
                with open(LOG_FILE, "wb") as fh:
                    fh.write("...(лог обрезан)...\n".encode("utf-8") + tail)
        except OSError:
            pass
        import datetime
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, "a", encoding="utf-8", errors="replace") as fh:
            fh.write("[" + ts + "] " + str(msg) + "\n")
    except Exception:
        pass

def _env_banner():
    # Строка окружения в лог: помогает вычислить проблемы конкретной ОС/версии paramiko.
    import platform
    pv = getattr(paramiko, "__version__", "?")
    return (f"enodia.py v{PROJECT_VERSION} | {platform.system()} {platform.release()} "
            f"| Python {platform.python_version()} | paramiko {pv}")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKUP_DIR = os.path.join(SCRIPT_DIR, "backups")

# КОД РОУТЕРА — ОДНИМ ПАКЕТОМ, ТЕМ ЖЕ, ЧТО И ОБНОВЛЕНИЕ ИЗ ПАНЕЛИ (решение пользователя 30.09.2026).
# Прежде здесь жили два списка файлов (REQUIRED/OPTIONAL) — вторая копия update-manifest.txt, и она с ним
# расходилась: json-lib.sh и wifi-lib.sh были в манифесте, но на свежую установку не приезжали — фикс жил
# только у тех, кто обновился с GitHub. Теперь ПК везёт подписанный минифицированный пакет
# `enodia-<CODE>.tar.gz` и ставит его ТЕМ ЖЕ pkg-install.sh, которым роутер обновляется сам: состав, порядок
# замены, снятие выпавших файлов и самовозврат при сбое — одни на оба пути, а список файлов один — манифест.
# Откуда пакет:
#   * архив установщика с релиза (enodia-setup-<версия>.zip, см. SETUP_FILES) — пакет, его release.txt и бинари обеих
#     арок лежат рядом со скриптом; запасной путь — «Code → Download ZIP», туда пакет кладёт в дерево публикация релиза
#     (dev/build-release.py publish). Сеть ПК для установки не нужна ни там, ни там;
#   * рабочая копия (рядом есть dev/build-release.py И ключи подписи local/release-keys/): собираем сами из исходников, что
#     лежат рядом, — иначе поставили бы пакет, отставший от них. Пока исходники не менялись, сборщик не пересобирает. Признак —
#     ПАРА, а не один сборщик (ревью с.97): dev/ под git, и попади он в публичный снимок, «Download ZIP» полез бы собирать сам —
#     без ключей, то есть «Пакет кода не собрался» вместо установки из пакета рядом. Ключи вне git и только у того, кто выпускает.
# ПОДПИСЬ ЗДЕСЬ НЕ СВЕРЯЕМ, и это не упущение: корень доверия установки с ПК — сам архив, и подменивший в нём
# пакет подменил бы и этот файл. Размер и sha256 из release.txt ловят то, что бывает на деле, — недокачанный
# или недораспакованный архив. СЕКРЕТОВ в пакете нет по построению: их не пропустит pkg-install.sh (pi_safe).
PKG_RELEASE = "release.txt"
PKG_BUILDER = os.path.join(SCRIPT_DIR, "dev", "build-release.py")
PKG_KEYS = os.path.join(SCRIPT_DIR, "local", "release-keys")
# АРХИВ УСТАНОВЩИКА (второй ассет релиза, enodia-setup-<версия>.zip; решение пользователя 30.09.2026) — ЧТО ЛЕЖИТ РЯДОМ
# СО СКРИПТОМ, кроме пакета кода с его release.txt и бинарей bin/<арка>/ (их сборщик берёт из манифеста пакета). Список
# ЗДЕСЬ, у читателя: dev/build-release.py берёт его отсюда (литерал — сборщик читает, не исполняя), а в распакованном
# архиве сверяет `--check-archive` (run_check_archive). Прочее роутерное, что ПК читает сам, — из пакета (payload_file).
SETUP_FILES = ("enodia.py", "VERSION", "requirements.txt", "pyproject.toml",
               "enodia-setup.bat", "enodia-setup.sh", "enodia-setup.command",
               "wizard/index.html",
               "web/assets/panel.css", "web/assets/inter-latin.woff2", "web/assets/inter-cyrillic.woff2",
               "README.md", "README.en.md")
# Путь внутри пакета — тот же белый список символов, что у gh-update.sh: распаковывает его root.
PKG_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
# Где пакет лежит на роутере до установки — ОЗУ (флеш 20 МБ, важен ПИК); префикс enodia- обязателен:
# namespace /tmp общий со стоком.
PKG_TMP = "/tmp/enodia-pkg-pc"
# Потолок ОЖИДАНИЯ установщика с ПК (не срок его жизни: он отцеплен и доработает сам). Замер BE7000 30.09.2026 — ~40–90 с вместе
# с install.sh; накопитель вдесятеро медленнее флеша — отсюда запас. Вышел потолок — ПК говорит «ещё идёт» и ничего не трогает.
PKG_INSTALL_WAIT = 900
BIN_NAMES = (
    "amneziawg-go.user",
    "awg.user",
    "xray.user",
    "hev.user",
    "hysteria.user",
    "byedpi.user",
    "nfqws.user",
    # https-dns-proxy — локальный DoH-прокси (опция «Шифрованный DNS», off по умолчанию).
    # Есть под ОБЕ арки, но сборки РАЗНЫЕ: arm64 = динамика против стоковых libcurl/c-ares/libev
    # (20 КБ, оба ядра — 5.4 BE7000 и 4.4 AX3600, после отказа от curl_url*); armv7 = полный статик
    # с mbedTLS+nghttp2 внутри (563 КБ — железки в руках нет, версии стоковых .so неизвестны).
    # Ни один транспорт его НЕ требует (verify не фатальна при отсутствии) — чистая опция.
    "https-dns-proxy.user",
    # dot-proxy — DNS-over-TLS форвардер (RFC 7858), альтернативный ПРОТОКОЛ слоя «Шифрованный
    # DNS» (пикер DoH/DoT в панели). Наш код (dev/dot), статик mbedTLS под обе арки (~300 КБ),
    # ноль version-skew по построению. Тоже чистая опция.
    "dot-proxy.user",
    # panel-tls — HTTPS-терминатор перед uhttpd панели (наш код, dev/tls; статик mbedTLS,
    # обе арки, ~290 КБ). Стоковый uhttpd HTTPS не поднимет: его крипто-плагин libustream-ssl
    # в прошивке отсутствует, а собранный нами не заводится из-за вендорски патченого
    # struct ustream (разбор — dev/tls/NOTES.md). Тоже чистая опция, OFF по умолчанию.
    "panel-tls.user",
)
# Бинари собраны под ДВЕ арки и лежат в bin/<арка>/ (плоского bin/*.user больше нет).
# Значение = (e_machine, EI_CLASS) из ELF-заголовка — по ним же опознаём роутер.
#   arm64 — BE7000/BE10000 (aarch64);  armv7 — BE3600 (32-битный userspace).
# На роутер набор всегда льётся в ПЛОСКИЙ $ENODIA_DIR/bin/ ⇒ install.sh про арки
# не знает, его гард bin_arch_matches остаётся независимой страховкой.
BIN_ARCHES = {
    "arm64": (0xB7, 2),   # EM_AARCH64, ELFCLASS64
    "armv7": (0x28, 1),   # EM_ARM,     ELFCLASS32
}
DEFAULT_ARCH = "arm64"

# БУТСТРАП-НАБОР: единственные бинари, которые ПК везёт с собой. Всё остальное (xray 8 МБ,
# hysteria 5 МБ, AmneziaWG, DoH/DoT, HTTPS панели) роутер качает сам из панели — «Компоненты».
# Почему эти трое и почему вообще хоть что-то, раз «ставим только панель»:
#   nfqws (0.12 МБ) + byedpi (0.13 МБ) — ДЕСИНК БЕЗ VPS. Роутер сразу после установки умеет
#     что-то полезное, даже если человек так и не завёл сервер: это не «предустановленный VPN»,
#     а рабочий обход блокировок, который не требует ни подписки, ни чужой инфраструктуры.
#   byedpi + hev (0.15 МБ) — ещё и АВАРИЙНЫЙ КАНАЛ до GitHub (gh-update.sh: закачка через
#     локальный socks с десинком). Без него установка компонентов из панели упирается ровно в то,
#     ради чего роутер и настраивают: у части провайдеров raw.githubusercontent душат по SNI.
# Итого ~0.4 МБ против ~15 МБ прежнего набора — и дистрибутив, и пик занятого флеша.
BOOTSTRAP_BINS = ("byedpi.user", "nfqws.user", "hev.user")


def _shq(v):
    """Путь роутера — в одинарных кавычках для sh (пробел в пути к хранилищу законен). Кавычки внутри не бывает (имена наших
    каталогов даёт бутстрап), но если приедет — закрываем и открываем заново, а не ломаем команду."""
    return "'" + str(v).replace("'", "'\\''") + "'"


def data_reserve_kb():
    # Неснижаемый резерв /data. ЧИСЛО ЖИВЁТ В store-lib.sh (DATA_RESERVE_B) — читаем его из
    # payload, а не дублируем здесь: разъехавшись, две копии дали бы гард, который пропускает
    # ровно то, что роутер потом сам считает переполнением. Нет файла — резерв 0, гард
    # вырождается в «влезет ли payload», и это честный минимум.
    data = payload_file("store-lib.sh")
    for ln in (data or b"").decode("utf-8", "replace").splitlines():
        m = re.match(r"\s*DATA_RESERVE_B=(\d+)", ln)
        if m:
            return int(m.group(1)) // 1024
    return 0


def bin_files(arch=DEFAULT_ARCH):
    # {имя на роутере: путь в репо} для набора одной арки.
    return {n: f"bin/{arch}/{n}" for n in BIN_NAMES}


_PKG = {}


def local_package(refresh=False):
    """Пакет кода, который поедет на роутер (см. PKG_RELEASE): {'path', 'version', 'code', 'size', 'files',
    'raw_kb', 'big_kb', 'blob'} либо {'error': почему ставить нечем}. ЕДИНСТВЕННЫЙ ответ «что ставим» — его
    спрашивают проверка перед установкой, гард места, экран мастера и удаление. Кэш — на процесс; refresh=True
    спрашивает заново (в рабочей копии — пересобирает, если исходники менялись)."""
    global _PKG
    if not _PKG or refresh:
        _PKG = _package_probe()
    return _PKG


def package_member(name):
    """Байты файла из пакета (None — пакета нет или файла в нём нет)."""
    pk = local_package()
    if pk.get("error"):
        return None
    try:
        with tarfile.open(fileobj=io.BytesIO(pk["blob"]), mode="r:gz") as tf:
            fh = tf.extractfile(name)
            return fh.read() if fh else None
    except (KeyError, tarfile.TarError, OSError):
        return None


def bootstrap_files(arch):
    """(ready, skipped) бутстрап-трио арки рядом со скриптом: ready — {имя.user: путь} тех, что ТА ЖЕ сборка, что знает манифест
    ставящегося пакета (он под подписью и едет на роутер); skipped — {имя.user: "missing" | "other"}. Другую сборку НЕ везём (ревью
    ветки, круг 1): в архиве установщика они совпадают по построению (--check-archive), а в «Code → Download ZIP» пакет — от момента
    публикации, `bin/` — голова main, и роутер получил бы бинарь, которого его манифест не знает (вечное «устарел» и «обновление»
    на старую подписанную). В пакете нет манифеста (старый) — сверять не с чем, везём как было."""
    sums = {}
    for ln in (package_member("bin-manifest.txt") or b"").decode("utf-8", "replace").splitlines():
        c = ln.split("\t")
        if not ln.startswith("#") and len(c) >= 5 and c[1] == arch:
            sums[c[0] + ".user"] = (c[2], c[4])
    ready, skipped = {}, {}
    bmap = bin_files(arch)
    for k in BOOTSTRAP_BINS:
        fp = os.path.join(SCRIPT_DIR, bmap[k]) if k in bmap else ""
        if not fp or not os.path.isfile(fp):
            skipped[k] = "missing"
            continue
        if sums:
            with open(fp, "rb") as fh:
                data = fh.read()
            want = sums.get(k)
            if not want or str(len(data)) != want[0] or hashlib.sha256(data).hexdigest() != want[1]:
                skipped[k] = "other"
                continue
        ready[k] = fp
    return ready, skipped


def bootstrap_verdict(arch):
    """([(уровень, текст)], есть_битые) — что установка скажет про бутстрап-трио арки перед заливкой; уровень — warn|err|ok.
    Функцией, а не телом установки: порядок проверок держит стенд (dev/release-build-test.py, круг 3 ревью ветки релиза)."""
    want_machine, want_class = BIN_ARCHES[arch]
    label = "ARM64" if arch == "arm64" else "ARMv7"
    bmap = bin_files(arch)
    _ready, skip = bootstrap_files(arch)
    out, bad = [], False
    for k in BOOTSTRAP_BINS:
        rel = bmap.get(k)
        fp = os.path.join(SCRIPT_DIR, rel) if rel else None
        if not fp or not os.path.isfile(fp):
            # Не отказ: панель встанет и без них, но роутер лишится аварийного канала до
            # GitHub (десинк) — а именно он и нужен там, где raw.github душат по SNI.
            out.append(("warn", L(f"{k} нет в bin/{arch}/ — аварийный канал до GitHub через десинк будет недоступен",
                                  f"{k} missing from bin/{arch}/ — the emergency GitHub channel over desync will be unavailable")))
            continue
        # Сверка с манифестом — ДО разбора ELF (ревью ветки, круг 2): файл, который всё равно не поедет, не вправе запереть
        # установку отказом «битые». «Прежняя» есть не всегда — на свежем роутере её нет, и тогда нужную ставит панель.
        if skip.get(k) == "other":
            out.append(("warn", L(f"{k} — не та сборка, что знает пакет кода: не повезу (нужную роутер поставит сам — «Компоненты» в панели)",
                                  f"{k} — not the build the code package knows: not taking it (the router installs the right one itself — “Components” in the panel)")))
            continue
        with open(fp, "rb") as fh:
            head = fh.read(20)
        is_elf = head[:4] == b"\x7fELF"
        is_le = len(head) >= 6 and head[4] == want_class and head[5] == 1
        # e_machine на offset 18 (LE, 2 байта): 0xB7 = AArch64, 0x28 = ARM(32).
        is_want = len(head) >= 20 and (head[18] | (head[19] << 8)) == want_machine
        if not is_elf:
            out.append(("err", L(f"{k} -- не ELF-файл (не Linux-бинарник!)", f"{k} -- not an ELF file (not a Linux binary!)")))
            bad = True
            continue
        if not (is_le and is_want):
            out.append(("err", L(f"{k} -- не {label} ELF (роутеру нужен {label})", f"{k} -- not a {label} ELF (the router needs {label})")))
            bad = True
            continue
        out.append(("ok", f"{k} ({label} ELF, {round(os.path.getsize(fp) / 1024, 1)} KB)"))
    return out, bad


def payload_file(name):
    """Байты роутерного файла, который ПК читает сам (uninstall.sh, dump.sh, store-lib.sh): ИЗ ПАКЕТА — он и есть код,
    который стоит или встанет на роутер, и в архиве установщика исходников рядом нет (SETUP_FILES). Пакета нет (битый
    архив) — исходник рядом, если он есть (рабочая копия, «Code → Download ZIP»); иначе None."""
    data = package_member(name)
    if data is not None:
        return data
    try:
        with open(os.path.join(SCRIPT_DIR, name), "rb") as fh:
            return fh.read()
    except OSError:
        return None


def _package_probe():
    again = L(": скачайте архив заново", ": download the archive again")
    _ver, code = payload_version()
    if not code.isdigit():
        return {"error": L(f"В {SCRIPT_DIR} нет файла VERSION с кодом — архив распакован не целиком",
                           f"{SCRIPT_DIR} has no VERSION file with a code — the archive was not unpacked in full")}
    where = SCRIPT_DIR
    if os.path.isfile(PKG_BUILDER) and os.path.isdir(PKG_KEYS):
        # СВОЙ каталог (`<код>-pc`), а не релизный `<код>`: сборка без архива установщика туда затёрла бы архив релиза между
        # `build` и `publish` (ревью ветки, круг 1); publish берёт только чисто числовые каталоги.
        where = os.path.join(SCRIPT_DIR, "local", "release-out", code + "-pc")
        info(L("Рабочая копия: пакет кода — из исходников рядом (пересобираю, если они менялись)…",
               "Working copy: the code package comes from the sources here (rebuilt if they changed)…"))
        try:
            r = subprocess.run([sys.executable, PKG_BUILDER, "build", "--if-changed", "--no-setup", "--out", where],
                               capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        except Exception as e:
            return {"error": L(f"Сборщик пакета не запустился: {e}", f"The package builder did not start: {e}")}
        if r.returncode != 0:
            tail = " | ".join((r.stderr or r.stdout or "").strip().splitlines()[-3:])
            return {"error": L("Пакет кода не собрался: ", "The code package did not build: ") + tail}
    try:
        with open(os.path.join(where, PKG_RELEASE), "rb") as fh:
            kv = dict(ln.split("=", 1) for ln in fh.read().decode("ascii", "replace").split("\n")
                      if "=" in ln and not ln.startswith("SIG="))
    except OSError:
        return {"error": L(f"Рядом со скриптом нет {PKG_RELEASE} — архив неполный",
                           f"There is no {PKG_RELEASE} next to the script — the archive is incomplete") + again}
    rcode, pkg = kv.get("CODE", ""), kv.get("PKG", "")
    if (kv.get("FORMAT") != "1" or not rcode.isdigit() or pkg != f"enodia-{rcode}.tar.gz"
            or not kv.get("SIZE", "").isdigit() or not re.fullmatch(r"[0-9a-f]{64}", kv.get("SHA256", ""))):
        return {"error": L(f"{PKG_RELEASE} вне правил", f"{PKG_RELEASE} breaks the format rules") + again}
    if rcode != code:
        # Снимок исходников, а не архив установщика: пакет и release.txt публикация кладёт в дерево ПОСЛЕ тега и после
        # того, как код ушёл в main, — у «Source code (zip)» тега они прежние НАВСЕГДА, у «Code → Download ZIP» — пока
        # выпуск не дошёл до конца (ревью ветки, круг 2: прежнее «скачайте через пару минут» тегу не помогало никогда).
        # Ставить нельзя — версия на роутере разошлась бы с тем, что про неё думают панель и downgrade-guard.
        return {"error": L(f"Пакет кода — версии с кодом {rcode}, а файлы рядом — {code}: это снимок исходников "
                           f"(«Source code» или «Download ZIP»), а не архив установщика. Скачайте со страницы "
                           f"Releases архив enodia-setup-<версия>.zip",
                           f"The code package has code {rcode} and the files next to it have {code}: this is a source "
                           f"snapshot (“Source code” or “Download ZIP”), not the installer archive. Download "
                           f"enodia-setup-<version>.zip from the Releases page")}
    try:
        with open(os.path.join(where, pkg), "rb") as fh:
            blob = fh.read()
    except OSError:
        return {"error": L(f"Рядом со скриптом нет {pkg} — архив неполный",
                           f"There is no {pkg} next to the script — the archive is incomplete") + again}
    if str(len(blob)) != kv["SIZE"] or hashlib.sha256(blob).hexdigest() != kv["SHA256"]:
        return {"error": L(f"{pkg} не совпал с {PKG_RELEASE} (размер или sha256) — архив битый",
                           f"{pkg} does not match {PKG_RELEASE} (size or sha256) — the archive is damaged") + again}
    # Состав — теми же правилами, что у апдейтера на роутере (gh-update.sh::cmd_apply): распаковывает его root.
    try:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
            members = tf.getmembers()
            names = {m.name for m in members}
            vf = tf.extractfile("VERSION") if "VERSION" in names else None
            vtxt = vf.read().decode("utf-8", "replace") if vf else ""
    except (tarfile.TarError, OSError, EOFError):
        return {"error": L(f"{pkg} не читается как архив", f"{pkg} cannot be read as an archive") + again}
    bad = [m.name for m in members
           if not m.isreg() or m.name.startswith("/") or ".." in m.name or not PKG_PATH_RE.match(m.name)]
    if bad:
        return {"error": L(f"В {pkg} путь или тип вне правил: {bad[0]}", f"{pkg} holds a path or type outside the rules: {bad[0]}")}
    need = [n for n in ("VERSION", "update-manifest.txt", "pkg-install.sh", "install.sh") if n not in names]
    if need:
        return {"error": L(f"В {pkg} нет {', '.join(need)}", f"{pkg} lacks {', '.join(need)}") + again}
    m = re.search(r"^CODE=(\d+)", vtxt, re.M)
    if not m or m.group(1) != rcode:
        return {"error": L(f"Версия внутри {pkg} не та, что в {PKG_RELEASE}",
                           f"The version inside {pkg} is not the one in {PKG_RELEASE}") + again}
    sizes = [x.size for x in members]
    return {"path": os.path.join(where, pkg), "version": kv.get("VERSION", ""), "code": rcode, "size": len(blob),
            "files": len(members), "raw_kb": (sum(sizes) + 1023) // 1024, "big_kb": (max(sizes) + 1023) // 1024,
            "blob": blob}


def detect_router_arch(router):
    # Арка роутера = e_machine из ELF-заголовка /bin/busybox (заведомо рабочего бинаря).
    # НЕ `uname -m`: ядро бывает 64-битным при 32-битном userspace — тогда uname говорит
    # aarch64, а execve нашего arm64-бинаря всё равно даёт ENOEXEC. busybox не врёт.
    # Тот же критерий, что у гарда bin_arch_matches в install.sh (DRY по смыслу).
    # Не прочитали/не опознали → None: вызывающий берёт DEFAULT_ARCH (fail-open — не мешать
    # установке там, где просто не смогли проверить; гард на роутере всё равно поймает).
    try:
        b64 = router.get("dd if=/bin/busybox bs=1 count=20 2>/dev/null | base64 | tr -d '\\n'")
        raw = base64.b64decode(b64)
    except Exception:
        return None
    if len(raw) < 20 or raw[:4] != b"\x7fELF":
        return None
    machine = raw[18] | (raw[19] << 8)
    for slug, (want_machine, want_class) in BIN_ARCHES.items():
        if machine == want_machine and raw[4] == want_class:
            return slug
    return None

# keyring: один service/account на проект (на Windows = Credential Manager = DPAPI).
# Имена переехали вместе с CRED_DIR (см. _cred_dir): старую запись `vpn-toggle/root@be7000`
# не читаем и не удаляем — пароль просто спросят ещё раз.
KEYRING_SERVICE = "enodia"
# ОБЩАЯ (легаси) запись: до 02.09.2026 она была ЕДИНСТВЕННОЙ — один пароль на все роутеры.
# Теперь читается как ФОЛБЭК (см. get_stored_password), а пишем всегда по адресу.
KEYRING_ACCOUNT = "root@enodia"
# Тот же мост, что у CRED_DIR, но keyring каталогом не копируется — читаем прежнюю запись, если
# новой ещё нет (см. get_stored_password). Только ЧТЕНИЕ: перекладывать пароль в новое хранилище
# без ведома человека — не наше решение, а первое же сохранение и так ляжет по новым именам.
KEYRING_SERVICE_OLD = "vpn-toggle"
KEYRING_ACCOUNT_OLD = "root@be7000"


# ============================================================
# Цвета / VT-консоль (ANSI; на старой Win-консоли включаем VT через ctypes)
# ============================================================
class C:
    RESET = "\033[0m"
    CYAN = "\033[36m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    GRAY = "\033[90m"      # DarkGray
    MAGENTA = "\033[35m"
    DARKCYAN = "\033[36m"
    DARKYELLOW = "\033[33m"
    WHITE = "\033[97m"


def _enable_ansi():
    # Win10+ умеет ANSI, но в legacy-консоли VT по умолчанию выключен. Включаем
    # ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004). Best-effort — если не вышло,
    # цвета просто не покрасятся (текст читается). Заодно UTF-8 на stdout/stdin.
    try:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8")
        if hasattr(sys.stdin, "reconfigure"):
            sys.stdin.reconfigure(encoding="utf-8")
    except Exception:
        pass
    if os.name != "nt":
        return
    try:
        import ctypes
        k = ctypes.windll.kernel32
        for handle_id in (-11, -12):  # STDOUT, STDERR
            h = k.GetStdHandle(handle_id)
            mode = ctypes.c_uint32()
            if k.GetConsoleMode(h, ctypes.byref(mode)):
                k.SetConsoleMode(h, mode.value | 0x0004)
    except Exception:
        pass


def cprint(text, color=None):
    if color:
        print(f"{color}{text}{C.RESET}")
    else:
        print(text)


# Утилиты вывода — зеркало Write-Section/Ok/Warn/Err/Info из be7000.ps1.
def section(text):
    print()
    cprint(f"=== {text} ===", C.CYAN)

def ok(text):    cprint(f"[ OK ] {text}", C.GREEN)
def warn(text):  cprint(f"[WARN] {text}", C.YELLOW)
def err(text):   cprint(f"[FAIL] {text}", C.RED)
def info(text):  cprint(f"[INFO] {text}", C.GRAY)


def clear_screen():
    # subprocess, а не os.system: тот отдаёт строку ОБОЛОЧКЕ (cmd.exe/sh), то есть заводит целый
    # интерпретатор ради одной команды и делает строку синтаксисом. Аргумент здесь константный, и
    # дыры нет — но идиома, которую копируют, обязана быть безопасной сама по себе, а не «потому
    # что вот тут аргумент не из ввода». Ошибку глушим: нет `clear` (голый терминал, Git Bash без
    # ncurses) — экран просто не чистится, программа продолжает работать.
    try:
        subprocess.run(["cls" if os.name == "nt" else "clear"], shell=(os.name == "nt"), check=False)
    except OSError:
        pass


def _open_file(path):
    # Кроссплатформенно открыть файл (замена Start-Process notepad): Win/macOS/Linux.
    try:
        if os.name == "nt":
            os.startfile(path)  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.run(["open", path])
        else:
            subprocess.run(["xdg-open", path])
    except Exception as e:
        warn(L(f"Не открыть файл автоматически: {e}", f"Could not open the file automatically: {e}"))


# Мастер установки (--wizard) ведёт диалог В БРАУЗЕРЕ, а его задания крутятся в фоновом
# потоке БЕЗ терминала: любой консольный вопрос повис бы навсегда — окна с вопросом человек
# не видит, а поток ждёт stdin. Гасим вопросы в ЕДИНСТВЕННОМ месте — в самих примитивах ввода:
# тогда и чужой путь, про который мы забыли (ретрай пароля внутри Router.run, «Пересохранить?»
# у чужого кода возврата), получит честный отказ, а не зависание. Решения, которые мастер уже
# принял НА ЭКРАНЕ, приезжают в код ЯВНЫМ параметром (preflight(tight_ok=...)) — догадка
# «в мастере отвечаем да» на вопросе вида «Стереть ТАКЖЕ все файлы?» стоила бы роутера.
WIZARD_MODE = False

# ЯЗЫК МАСТЕРА. Страница присылает его заголовком `X-Wizard-Lang` на КАЖДОМ запросе, потому
# что весь вывод агента уезжает в тот же лог, который человек читает на экране: русские строки
# посреди английского мастера — это ровно то, ради чего двуязычность и делалась.
# В консольном режиме язык остаётся 'ru', то есть прежний вывод БАЙТ-В-БАЙТ, а английский —
# отдельная ветка. Тот же приём, что у панели и у nf-i18n.sh на роутере: «русский режим
# прежний, en — параллельный перевод, при сомнении ru».
WIZARD_LANG = "ru"


def L(ru, en):
    """Пара «русский, английский» ПРЯМО В МЕСТЕ ИСПОЛЬЗОВАНИЯ — как T() на странице мастера.

    Словарь с ключами на дальнем конце файла разъезжается молча: строку правят, ключ остаётся,
    и человек видит чужой язык там, где ждал перевода. Пару видно в ревью.
    """
    return en if WIZARD_LANG == "en" else ru


def _wizard_no_ask(prompt):
    # Строка живёт ТОЛЬКО в мастере (в консоли этой ветки нет вовсе) — тем страннее было
    # видеть её по-русски в английском мастере: это единственная функция файла, у которой
    # другого читателя не бывает.
    warn(L("Вопрос «%s» пропущен: в мастере на него отвечает экран, а не консоль." % prompt.strip(),
           "The question “%s” was skipped: in the wizard the screen answers it, not the console." % prompt.strip()))


def ask(prompt):
    # Read-Host-эквивалент: пустая строка на EOF/Ctrl+C (вместо краша).
    if WIZARD_MODE:
        _wizard_no_ask(prompt)
        return ""
    try:
        return input(prompt)
    except (EOFError, KeyboardInterrupt):
        print()
        return ""


def ask_secret(prompt):
    if WIZARD_MODE:
        _wizard_no_ask(prompt)
        return ""
    try:
        return _getpass.getpass(prompt)
    except (EOFError, KeyboardInterrupt):
        print()
        return ""


# Правило формы пароля панели — ОДНО на оба входа (консоль и мастер) и ДОСЛОВНО то же, что у
# панели (cgi-bin/action, ветка panel_pass): форма входа шлёт пароль base64 через btoa, а тот
# кириллицу не берёт, да и раскладка на телефоне подводит ⇒ можно задать пароль, которым потом
# не войти. Второй копии правила не заводить — разъехавшиеся правила на двух входах мы уже чинили.
PANEL_PW_RE = r"^[!-~]{8,64}$"
def panel_pw_hint(root=False):
    """Требование к паролю панели. ФУНКЦИЯ, а не константа: язык мастера выбирается в
    рантайме, а модульная строка вычислилась бы один раз при импорте — всегда по-русски.
    Правило то же и у пароля root (`root=True`), но хвост «его спросит форма входа» — про панель:
    у root формы входа нет, и отказ с этим хвостом обещал бы то, чего не будет (ревью шага 8b)."""
    if root:
        return L("Пароль: 8..64 символов, латиница/цифры/знаки, без пробелов и кириллицы",
                 "Password: 8..64 characters, Latin letters/digits/symbols, no spaces and no Cyrillic")
    return L("Пароль: 8..64 символов, латиница/цифры/знаки, без пробелов и кириллицы (его спросит форма входа)",
             "Password: 8..64 characters, Latin letters/digits/symbols, no spaces and no Cyrillic (the sign-in form will ask for it)")


def ask_new_panel_password(prompt="Новый пароль панели (ввод скрыт): "):
    # Пароль веб-панели — ЕДИНСТВЕННОЕ место, где ПК спрашивает секрет вслепую и НИКТО потом не
    # может его перепроверить: опечатка означает роутер, в панель которого не войти (лечится
    # только повторным setpass по SSH). Поймано на живом тесте
    # 16.08.2026: лишний символ в пароле прочитался как «фикс не работает». HTTP-проба такое не
    # ловит ПРИНЦИПИАЛЬНО — она сверяет панель с тем же, что человек набрал, то есть подтверждает
    # опечатку. Ловит только повтор ввода.
    # Правило формы — ДОСЛОВНО то же, что у панели (cgi-bin/action, ветка panel_pass), см.
    # PANEL_PW_RE. Разъехавшиеся правила на двух входах — ровно тот класс, что мы сегодня и чинили.
    while True:
        pw = ask_secret(prompt)
        if not pw:
            return ""
        if not re.match(PANEL_PW_RE, pw):
            warn(panel_pw_hint())
            continue
        if pw != ask_secret("Повторите пароль: "):
            warn("Пароли не совпадают — наберите заново (Enter — отмена)")
            continue
        return pw


def confirm(prompt):
    # ДА — только однозначное согласие; всё прочее — НЕТ. Раньше принимался РОВНО литерал «y»/«Y»,
    # и это была мина: «да», «yes», «д», «1» и Enter молча означали отказ. Тестер (чат 08.08.2026)
    # так и не смог удалить систему с ПК — первый же вопрос «Продолжить» он подтверждал словом,
    # получал «Отмена» и читал это как «удаление не работает».
    #
    # «н» НЕ считаем согласием НИКОГДА, хотя на ЙЦУКЕН это та же клавиша, что латинская «y»:
    # это ещё и первая буква «нет». Функция общая на 17 мест, включая «Стереть ТАКЖЕ все файлы» и
    # откат из бэкапа — угадав здесь неверно, мы превратим попытку отказаться в согласие на
    # безвозвратное стирание. Поэтому неоднозначный ответ = ПЕРЕСПРОС, а не догадка.
    # «н» намеренно НЕ входит НИ В ОДИН список — это и латинская «y» на ЙЦУКЕН, и первая буква
    # «нет». Единственный честный разбор такого ответа — переспросить. Пустая строка (Enter) =
    # отказ, как и обещает подсказка [y/N].
    yes = ("y", "yes", "да", "д", "1")
    no = ("n", "no", "нет", "0", "")
    if WIZARD_MODE:
        _wizard_no_ask(prompt)
        return False
    while True:
        ans = ask(f"{prompt} [y/N]: ").strip().lower()
        if ans in yes:
            return True
        if ans in no:
            return False
        warn(L("Ответьте «y» (да) или «n» (нет).", "Answer “y” (yes) or “n” (no)."))


def has(text, *needles):
    # Замена PS-идиомы `"$out" -match "OK|ВКЛЮЧ"`: True, если в тексте есть хоть
    # одна подстрока. Большинство проверок вывода роутера — литералы-маркеры
    # (OK/SAVED/FAILED/ENABLED…), поэтому substring достаточно и проще regex.
    return any(n in text for n in needles)


def flush_local_dns():
    # Кроссплатформенная замена `ipconfig /flushdns`. Это лишь УДОБСТВО на стороне
    # ПК (чтобы старый DNS-ответ не залип в кэше после смены маршрута) — реальная
    # маршрутизация/conntrack меняются на роутере. Best-effort: True, если сброс
    # реально отработал; иначе тихо False (НЕ врём «сброшено»).
    try:
        if os.name == "nt":
            subprocess.run(["ipconfig", "/flushdns"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        if sys.platform == "darwin":
            rc = subprocess.run(["dscacheutil", "-flushcache"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            # killall -HUP mDNSResponder требует root — пробуем без sudo, не настаиваем.
            subprocess.run(["killall", "-HUP", "mDNSResponder"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return rc == 0
        # Linux: известные резолверы (любой успех = ок). Нет ни одного — обычно
        # локального DNS-кэша и нет (glibc не кэширует), сбрасывать нечего.
        for cmd in (["resolvectl", "flush-caches"], ["systemd-resolve", "--flush-caches"]):
            try:
                if subprocess.run(cmd, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL).returncode == 0:
                    return True
            except FileNotFoundError:
                continue
        return False
    except Exception:
        return False


# ============================================================
# Пароль root (keyring + фолбэк chmod-600 файл)
# ============================================================
def _kr_account(host):
    """Имя записи в хранилище — ПО АДРЕСУ РОУТЕРА (`root@192.168.31.1`).

    ЗАЧЕМ. Запись была ОДНА на проект, и у кого роутеров два (а это и наш стенд, и половина
    тестеров — «основной» плюс «на попробовать»), вход на ВТОРОЙ молча затирал пароль ПЕРВОГО:
    следующий заход к нему отвечал `auth`, и понять причину было нельзя — хранилище показывает
    один пароль и не говорит, от кого он. Поймано на живом стенде 02.09.2026: вход мастером на
    AX3600 сделал недоступным BE7000. Пустой host (совсем ранний вызов) → прежнее общее имя.
    """
    h = (host or "").strip()
    return ("root@" + h) if h else KEYRING_ACCOUNT


def save_password(host=None):
    print()
    pw = ask_secret(L("Введите пароль root от роутера (символы не будут видны): ",
                      "Enter the router root password (input is hidden): "))
    if not pw:
        err(L("Пустой пароль — отмена", "Empty password — cancelled"))
        return False
    return store_password(pw, host)


def store_password(pw, host=None):
    """Положить пароль root в хранилище. СПРАШИВАЕТ его вызывающий (консоль — вслепую,
    мастер — формой в браузере), ХРАНИТ — эта функция: место хранения одно на оба входа."""
    # keyring: на Windows = Credential Manager (DPAPI), macOS = Keychain, Linux =
    # Secret Service. При отсутствии backend — файл chmod 600 (как обещает README про
    # «шифрование» — на основной платформе keyring всегда есть).
    if _HAVE_KEYRING:
        try:
            _keyring.set_password(KEYRING_SERVICE, _kr_account(host), pw)
            ok(L("Пароль сохранён (системное хранилище ключей)",
                 "Password saved (system credential store)"))
            return True
        except Exception as e:
            warn(L(f"Системное хранилище недоступно ({e}); сохраняю в файл chmod 600.",
                   f"The system store is unavailable ({e}); saving to a chmod 600 file instead."))
    _save_password_file(pw)
    return True


def _save_password_file(pw):
    if not os.path.isdir(CRED_DIR):
        os.makedirs(CRED_DIR, exist_ok=True)
    # base64 — не шифрование, а защита от случайного подглядывания; права 600 — основная мера.
    data = base64.b64encode(pw.encode("utf-8")).decode("ascii")
    with open(CRED_FILE, "w", encoding="ascii") as f:
        f.write(data)
    try:
        os.chmod(CRED_FILE, 0o600)
    except Exception:
        pass
    ok(L(f"Пароль сохранён (файл chmod 600, {CRED_FILE})",
         f"Password saved (chmod 600 file, {CRED_FILE})"))


def get_stored_password(host=None):
    """Пароль root ДЛЯ ЭТОГО РОУТЕРА. Порядок поиска — от частного к общему: запись по адресу
    (`root@<ip>`), затем ОБЩАЯ легаси-запись (так хранили до 02.09.2026 — у кого один роутер,
    она и продолжает работать), затем совсем старая (`vpn-toggle`), затем файл-фолбэк.
    Перекладывать найденное в новое имя здесь НЕЛЬЗЯ: пароль ещё не проверен, а хранилище
    правит только УДАЧНЫЙ вход (store_password у вызывающего)."""
    if _HAVE_KEYRING:
        try:
            acc = _kr_account(host)
            if acc != KEYRING_ACCOUNT:
                pw = _keyring.get_password(KEYRING_SERVICE, acc)
                if pw:
                    return pw
            pw = _keyring.get_password(KEYRING_SERVICE, KEYRING_ACCOUNT)
            if pw:
                return pw
            pw = _keyring.get_password(KEYRING_SERVICE_OLD, KEYRING_ACCOUNT_OLD)
            if pw:
                return pw
        except Exception:
            pass
    if os.path.isfile(CRED_FILE):
        try:
            with open(CRED_FILE, "r", encoding="ascii") as f:
                raw = f.read().strip()
            return base64.b64decode(raw).decode("utf-8")
        except Exception as e:
            warn(L(f"Не удалось прочитать сохранённый пароль: {e}",
                   f"Could not read the saved password: {e}"))
    return None


# ============================================================
# IP роутера (settings.json, ключ RouterIp)
# ============================================================
def test_ip_string(s):
    # Грубая, но достаточная валидация IPv4 (4 октета 0..255).
    parts = s.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p.isdigit():
            return False
        if int(p) > 255:
            return False
    return True


def get_lan_subnet(ip):
    # "192.168.31.100" -> "192.168.31." (префикс /24 для поиска IP этого ПК). Не IPv4 -> None.
    if not test_ip_string(ip):
        return None
    return ip.rsplit(".", 1)[0] + "."


def load_router_host():
    if not os.path.isfile(SETTINGS_FILE):
        return None
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            j = json.load(f)
        ip = j.get("RouterIp")
        if ip and test_ip_string(ip):
            return ip
    except Exception:
        pass
    return None


def save_router_host(ip):
    if not os.path.isdir(CRED_DIR):
        os.makedirs(CRED_DIR, exist_ok=True)
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump({"RouterIp": ip}, f)


def get_my_lan_ip(router_ip):
    # Трюк без зависимостей: UDP-«коннект» к роутеру (пакеты НЕ шлёт) и читаем
    # локальный адрес сокета — это IP ЭТОГО ПК в сети роутера. Заменяет
    # Get-NetIPAddress/Get-NetRoute (которых нет на Mac/Linux).
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect((router_ip, 9))
            return s.getsockname()[0]
        finally:
            s.close()
    except Exception:
        return None


# Результат SSH-команды: текст (stdout+stderr, как plink 2>&1) + код возврата.
Result = namedtuple("Result", "out code")


# ============================================================
# Router — in-process SSH (paramiko). Замена Invoke-Router / Upload-File / Download-File.
# Один persist-коннект на сессию (lazy). Host key через AutoAddPolicy: новый ключ после
# ребута/перепрошивки принимается автоматически — НЕ нужен реестр PuTTY / Clear-PuttyHostKey.
#
# ПОЧЕМУ НЕ TOFU/known_hosts (внешний аудит предлагал; отклонено ЗАМЕРОМ на BE7000 23.08.2026).
# Ключи dropbear лежат в /etc/dropbear, а `/etc` на этом роутере — **ramfs** (`none on /etc type
# ramfs`); персистентной копии нет НИГДЕ: поиск `dropbear*host_key*` по /data, /overlay, /etc_ro
# и /usr/share не нашёл ни одной, а mtime живых ключей совпадает со временем загрузки. То есть
# ключ хоста генерится ЗАНОВО на каждом ребуте. С known_hosts это значит «WARNING: REMOTE HOST
# IDENTIFICATION HAS CHANGED» после КАЖДОЙ перезагрузки роутера — предупреждение, которое всегда
# ложное и потому приучает жать «да». Такой рубеж хуже отсутствующего: он тратит внимание там,
# где сигнала нет, и молчит там, где он появится.
# ОСТАТОЧНЫЙ РИСК НАЗЫВАЕМ ЧЕСТНО: активный MITM внутри домашней LAN увидит пароль root. Против
# него здесь нет защиты, и получить её можно только вместе с персистентным ключом хоста —
# то есть не на стоке. Канал используется в домашней сети и для установки, а не постоянно.
# ============================================================
class Router:
    def __init__(self, host, user=ROUTER_USER, port=22, password_provider=None):
        self.host = host
        self.user = user
        self.port = port
        self.password_provider = password_provider  # callable -> пароль или None
        self.last_code = 0
        # Почему упал последний connect: ok|auth|negotiation|network|nopass. 'negotiation' =
        # несовместимый host key/KEX (старый dropbear) — НЕ путать с неверным паролем.
        self.last_error_kind = "ok"
        self._cli = None

    def set_host(self, host):
        # Сменился IP — старый коннект к другому хосту больше не годится.
        if host != self.host:
            self.close()
            self.host = host

    def is_connected(self):
        """Жив ли SSH-коннект ПРЯМО СЕЙЧАС (не «был когда-то»). Спрашивает страница мастера при
        загрузке: перезагрузка вкладки не рвёт сессию агента, и спрашивать пароль root заново
        незачем — до 02.09.2026 после F5 мастер спрашивал его снова."""
        if self._cli is None:
            return False
        tr = self._cli.get_transport()
        return bool(tr is not None and tr.is_active())

    def close(self):
        if self._cli is not None:
            try:
                self._cli.close()
            except Exception:
                pass
            self._cli = None

    def _client(self):
        # Живой коннект? Переиспользуем. Иначе — новый (с актуальным паролем).
        if self._cli is not None:
            tr = self._cli.get_transport()
            if tr is not None and tr.is_active():
                return self._cli
            self.close()
        pw = self.password_provider() if self.password_provider else get_stored_password(self.host)
        if not pw:
            raise RuntimeError(L("нет пароля", "no password"))
        cli = paramiko.SSHClient()
        # known_hosts НЕ грузим — AutoAddPolicy всегда принимает текущий ключ (решает
        # «ключ сменился после ребута» без реестра/known_hosts, как и было задумано планом).
        cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        cli.connect(
            self.host, port=self.port, username=self.user, password=pw,
            allow_agent=False, look_for_keys=False,
            timeout=10, banner_timeout=15, auth_timeout=15,
        )
        self.last_error_kind = "ok"
        self._cli = cli
        return cli

    def run(self, command, stdin_data=None, silent=False, timeout=None):
        # КРИТИЧНО: на роутер шлём ТОЛЬКО LF. CRLF прилипал бы '\r' к значениям на
        # busybox/ash (та же грабля, что у Invoke-Router). stdin_data (base64 и т.п.)
        # не трогаем — его готовит вызывающий.
        if command:
            command = command.replace("\r", "")
        # Подключение (с одним ретраем по паролю, если аутентификация не прошла).
        try:
            cli = self._client()
        except paramiko.AuthenticationException:
            self.last_error_kind = "auth"
            logdbg(f"SSH auth failed @ {self.host}")
            # `silent` ЗДЕСЬ ТОЖЕ ЗНАЧИМ, и это не косметика. Тихим вызовом ПРОБУЮТ пароль
            # («пустит ли root/root после утилиты?»), и заранее известный отказ печатал
            # «пароль root не подходит» плюс вопрос из консоли, на который в мастере отвечать
            # некому (`_wizard_no_ask`) — то есть две строки паники на штатной ветке.
            if silent:
                self.last_code = 255
                return Result("", 255)
            err(L("Аутентификация не удалась — пароль root не подходит.",
                  "Authentication failed — the root password does not fit."))
            if confirm("Пересохранить пароль?"):
                if save_password(self.host):
                    self.close()
                    try:
                        cli = self._client()
                    except Exception as e:
                        logdbg(f"SSH re-connect failed @ {self.host}: {e!r}")
                        if not silent:
                            err(L(f"Подключиться не удалось: {e}", f"Could not connect: {e}"))
                        self.last_code = 255
                        return Result("", 255)
                else:
                    self.last_code = 255
                    return Result("", 255)
            else:
                self.last_code = 255
                return Result("", 255)
        except RuntimeError:
            # Нет пароля — попросим сохранить и повторим один раз.
            self.last_error_kind = "nopass"
            warn(L("Пароль ещё не сохранён — сохраним его", "No password saved yet — let's save one"))
            if not save_password(self.host):
                self.last_code = 255
                return Result("", 255)
            try:
                cli = self._client()
            except Exception as e:
                logdbg(f"SSH connect failed @ {self.host}: {e!r}")
                if not silent:
                    err(L(f"Подключиться не удалось: {e}", f"Could not connect: {e}"))
                self.last_code = 255
                return Result("", 255)
        except (socket.error, OSError, paramiko.SSHException) as e:
            # SSHException (host key/KEX/шифр/баннер) — это НЕ пароль. Разделяем, чтобы UI не
            # слал тестера менять верный пароль (баг беты 04.07.2026: IncompatiblePeer выдавался
            # как «неверный пароль»). network — TCP/сокет умер посреди коннекта.
            self.last_error_kind = "negotiation" if isinstance(e, paramiko.SSHException) else "network"
            logdbg(f"SSH connect failed @ {self.host} [{self.last_error_kind}]: {e!r}")
            if not silent:
                err(L(f"Не удалось подключиться к роутеру {self.host}: {e}",
                      f"Could not connect to the router at {self.host}: {e}"))
                if self.last_error_kind == "negotiation":
                    info(L("SSH-сессия не согласована (host key / шифр / KEX — старый dropbear).",
                           "The SSH session could not be negotiated (host key / cipher / KEX — old dropbear)."))
                    info(L(f"Обновите enodia.py; не помогло — пришлите лог: {LOG_FILE}",
                           f"Update enodia.py; if that does not help, send the log: {LOG_FILE}"))
            self.last_code = 255
            return Result("", 255)

        # Выполнение.
        try:
            # timeout — ПОТОЛОК ОЖИДАНИЯ ОДНОЙ КОМАНДЫ (None = как было, без потолка). Нужен
            # там, где команда может не вернуться вовсе: у мастера нет человека с Ctrl+C, и
            # повисший поток задания не закрыть ничем, кроме убийства агента.
            stdin, stdout, stderr = cli.exec_command(command, timeout=timeout)
            if stdin_data is not None:
                data = stdin_data.encode("utf-8") if isinstance(stdin_data, str) else stdin_data
                try:
                    stdin.write(data)
                    stdin.flush()
                except Exception:
                    pass
            try:
                stdin.channel.shutdown_write()
            except Exception:
                pass
            out_b = stdout.read()
            err_b = stderr.read()
            code = stdout.channel.recv_exit_status()
        except (socket.error, OSError, paramiko.SSHException) as e:
            logdbg(f"SSH exec failed @ {self.host}: {e!r}")
            if not silent:
                err(L(f"Ошибка выполнения команды: {e}", f"Command execution failed: {e}"))
            self.last_code = 255
            return Result("", 255)

        if DEBUG:
            # Ярлык команды (первая строка, обрезана) + код возврата. Секрета не содержит:
            # пароли идут через stdin_data, который тут НЕ пишем. Полезно для роутерных багов.
            label = (command or "").strip().splitlines()
            logdbg(f"cmd rc={code}: {(label[0][:120] if label else '(пусто)')}")

        out = out_b.decode("utf-8", "replace")
        err_txt = err_b.decode("utf-8", "replace")
        # Как plink 2>&1: stdout + stderr вместе (парсящие вызовы используют токены/маркеры,
        # шум stderr им не мешает; см. get_router_summary / detect_awg_state).
        combined = out
        if err_txt:
            combined = (out + ("\n" if out and not out.endswith("\n") else "") + err_txt) if out else err_txt

        self.last_code = code
        if code != 0 and not silent:
            err(L(f"SSH вернул код {code}", f"SSH returned code {code}"))
            if combined.strip():
                cprint(combined.rstrip("\n"), C.GRAY)
            low = combined.lower()
            if any(w in low for w in ("password", "denied", "unable to authenticate", "wrong passphrase")):
                if confirm("Похоже, пароль не подходит. Пересохранить?"):
                    save_password(self.host)
                    self.close()
        return Result(combined.rstrip("\n"), code)

    # --- Передача файлов (БЕЗ SFTP — у роутера его нет, как и pscp -scp) ---
    def upload(self, local_path, remote_path):
        # upload = exec("cat > path") + запись байтов файла в stdin. Бинари ок.
        if not os.path.isfile(local_path):
            err(L(f"Локальный файл не найден: {local_path}", f"Local file not found: {local_path}"))
            return False
        try:
            with open(local_path, "rb") as f:
                data = f.read()
        except Exception as e:
            err(L(f"Не прочитать {local_path}: {e}", f"Cannot read {local_path}: {e}"))
            return False
        return self.upload_data(data, remote_path, local_path)

    def upload_data(self, data, remote_path, label=""):
        # Те же байты, что проверены на ПК (пакет, файл из него), — без второго чтения с диска.
        local_path = label or L("байты", "bytes")
        # Кавычки в пути экранируем для sh.
        rp = "'" + remote_path.replace("'", "'\\''") + "'"
        # АТОМАРНО: пишем во временный .up.tmp (в том же каталоге → mv атомарен), затем mv на финал.
        # Прямой `cat > финал` НЕатомарен: open усекает файл СРАЗУ, обрыв канала посреди записи оставил
        # бы обрезанный install.sh/transport.sh/бинарь (старая рабочая копия уже уничтожена), а cron
        # heal/watchdog дёргают битый скрипт. mv происходит ТОЛЬКО при code==0.
        rp_tmp = "'" + (remote_path + ".up.tmp").replace("'", "'\\''") + "'"
        r = self.run(f"cat > {rp_tmp}", stdin_data=data, silent=True)
        if r.code != 0:
            self.run(f"rm -f {rp_tmp}", silent=True)
            err(L(f"upload не удался ({local_path} -> {remote_path}, код {r.code})",
                  f"upload failed ({local_path} -> {remote_path}, code {r.code})"))
            if r.out.strip():
                cprint(r.out, C.GRAY)
            return False
        mv = self.run(f"mv {rp_tmp} {rp}", silent=True)
        if mv.code != 0:
            self.run(f"rm -f {rp_tmp}", silent=True)
            err(L(f"upload не удался (переименование {remote_path}, код {mv.code})",
                  f"upload failed (renaming {remote_path}, code {mv.code})"))
            return False
        return True

    def download(self, remote_path, local_path):
        # download = exec("cat path") + чтение stdout в файл. Возвращает БАЙТЫ через run —
        # но run декодирует в текст; для бинарей здесь нужен сырой режим, поэтому
        # читаем канал напрямую.
        try:
            cli = self._client()
        except Exception as e:
            err(L(f"Не удалось подключиться: {e}", f"Could not connect: {e}"))
            return False
        rp = "'" + remote_path.replace("'", "'\\''") + "'"
        try:
            stdin, stdout, stderr = cli.exec_command(f"cat {rp}")
            try:
                stdin.channel.shutdown_write()
            except Exception:
                pass
            data = stdout.read()
            code = stdout.channel.recv_exit_status()
        except (socket.error, OSError, paramiko.SSHException) as e:
            err(L(f"Ошибка скачивания: {e}", f"Download failed: {e}"))
            return False
        if code != 0:
            err(L(f"download не удался ({remote_path} -> {local_path}, код {code})",
                  f"download failed ({remote_path} -> {local_path}, code {code})"))
            return False
        try:
            with open(local_path, "wb") as f:
                f.write(data)
        except Exception as e:
            err(L(f"Не записать {local_path}: {e}", f"Cannot write {local_path}: {e}"))
            return False
        return True

    # --- Удобные обёртки (используются десятками действий) ---
    def get(self, command):
        # Тихо выполнить и вернуть СТРИПнутый текст. Замена PS-идиомы
        # ("" + (Invoke-Router -Command … -Silent)).Trim() — читаем одиночные
        # значения с роутера (флаги/имена конфигов/счётчики).
        return self.run(command, silent=True).out.strip()

    def run_script(self, script, silent=False):
        # Прогнать МНОГОСТРОЧНЫЙ sh-скрипт: base64 уезжает ЧЕРЕЗ STDIN, ложится во ВРЕМЕННЫЙ файл
        # на роутере и запускается ИЗ ФАЙЛА. base64 = чистый ASCII → ни awk-кавычки, ни кириллица,
        # ни переводы строк не искажаются (тот же приём, что put_text).
        #
        # ПОЧЕМУ НЕ ПРЕЖНЕЕ `echo <b64> | base64 -d | sh`: там весь скрипт ехал В КОМАНДНОЙ СТРОКЕ,
        # и на скрипте покрупнее сессия просто РВАЛАСЬ — paramiko падал EOFError, а человек видел
        # «Непредвиденная ошибка, пришли лог», хотя ни роутер, ни скрипт ни при чём. ЗАМЕРЕНО на
        # AX3600 31.08.2026: 6.2 КБ скрипта проходят, 7.3 КБ уже рвут канал (порог между ними).
        # Цена была не только в неудобстве: роутерный стенд `dev/backup-import-test.sh` (10 КБ)
        # НЕЛЬЗЯ было запустить тем способом, который написан в его же шапке, — то есть проверка,
        # стоившая работы, тихо не гонялась вовсе.
        #
        # СТДИН САМОГО СКРИПТА ОСТАЁТСЯ СВОБОДНЫМ, и это обязательное свойство: запускаем
        # `sh <файл>`, а НЕ `sh` из потока — иначе первая же команда внутри, читающая stdin,
        # съела бы остаток собственного текста. Имя временного файла несёт наш префикс: /tmp —
        # общий namespace, а `/tmp/.enodia-*` уже стоит в масках уборки uninstall.sh (C56).
        # `$$` разворачивает УДАЛЁННЫЙ шелл, поэтому два одновременных прогона не мешают друг другу.
        # Код возврата — скрипта, а не уборки: сохраняем его до `rm` и им же выходим.
        b64 = base64.b64encode(script.replace("\r\n", "\n").encode("utf-8")).decode("ascii")
        tmp = "/tmp/.enodia-exec.$$.sh"
        cmd = f"base64 -d > {tmp} || exit 90; sh {tmp}; _rc=$?; rm -f {tmp}; exit $_rc"
        return self.run(cmd, stdin_data=b64, silent=silent)

    def put_text(self, remote_path, content, mode=600):
        # Атомарно записать ТЕКСТ в файл на роутере (зеркало Send-RouterFileAtomic):
        # CRLF->LF, base64 -> stdin -> 'base64 -d' -> .new + mv + chmod. .new+mv:
        # прерванная заливка НЕ затрёт рабочий файл ('> файл' усёк бы его сразу).
        # У роутера нет SFTP — отсюда base64-через-stdin, как и у pscp-фолбэка PS.
        content = content.replace("\r\n", "\n").replace("\r", "\n")
        b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
        rp = "'" + remote_path.replace("'", "'\\''") + "'"
        cmd = (f"base64 -d > {rp}.new && mv {rp}.new {rp} && chmod {mode} {rp} && "
               f"echo SAVED $(wc -c < {rp}) || {{ rm -f {rp}.new; echo FAILED; }}")
        r = self.run(cmd, stdin_data=b64, silent=True)
        if "SAVED" not in r.out:
            if r.out.strip():
                cprint(r.out, C.GRAY)
            return False
        return True


def test_router_reachable(host):
    # Быстрая проба TCP-22 (2с) ДО SSH: не дёргаем пароль «в пустоту» и сразу говорим,
    # что чинить. ping не используем — на разных ОС он требует прав/raw-сокетов и шумит;
    # открытый порт 22 — то, что реально нужно для работы.
    try:
        s = socket.create_connection((host, 22), timeout=2)
        s.close()
        return True
    except Exception:
        warn(L(f"Роутер {host} не отвечает по SSH (порт 22).",
               f"The router at {host} does not answer over SSH (port 22)."))
        info(L("Проверьте: вы в сети роутера (LAN-кабель/его Wi-Fi)? Верный IP? SSH открыт (мастер установки открывает его сам — шаг доступа)?",
               "Check: are you on the router network (LAN cable / its Wi-Fi)? Right IP? Is SSH open (the setup wizard opens it itself — the access step)?"))
        return False


# ============================================================
# Приложение: состояние + действия + меню
# ============================================================
class App:
    def __init__(self, force_install=False, force_manage=False):
        self.router_ip = DEFAULT_ROUTER_IP
        self.lan_subnet = DEFAULT_LAN_SUBNET
        self.awg_state = "INSTALLED"   # INSTALLED | FRESH | UNKNOWN
        self.unknown_reason = ""       # 'offline' | 'auth'
        self.router_summary = None     # список строк для шапки
        self.last_verify_carrier_up = False  # итог _verify_install: несущая поднялась?
        self.force_install = force_install
        self.force_manage = force_manage
        self._bin_arch = None          # кэш арки роутера (см. bin_arch)
        self._paths = None             # кэш АКТИВНЫХ каталогов роутера (см. router_paths)
        self.router = Router(self.router_ip, password_provider=self.ensure_password)

    def router_paths(self):
        """АКТИВНЫЕ каталоги НА РОУТЕРЕ: код, настройки, бинари — и режим раскладки.
        Литералы ENODIA_DIR/STATE/BIN — это раскладка «всё на флеше», а все три каталога могут
        целиком жить на внешнем накопителе (режим `full`): тогда по литералам нет НИЧЕГО, и
        каждая проба отвечает «не установлено» на живой системе. Цена ошибки максимальна у
        панели: «не найдена» ⇒ ПК предложит поставить систему ПОВЕРХ работающей.
        Владелец ответа один — бутстрап (`boot.sh paths`), и спрашиваем его ОДИН раз за сеанс:
        каждый вызов это SSH-раунд. Нет бутстрапа (установка старее фичи) или ответ не разобрали
        — прежние литералы, то есть прежнее поведение.
        Ключ `mode`: `full`/`bins`/`data` — где сейчас код; `none` — код ДОЛЖЕН быть на
        накопителе, а накопителя нет (тогда путей бутстрап не называет вовсе)."""
        if self._paths is None:
            p = {"mode": "", "dir": ENODIA_DIR, "state": ENODIA_STATE, "bin": ENODIA_BIN}
            try:
                out = self.router.get(
                    f'[ -f {ENODIA_BOOT}/boot.sh ] && sh {ENODIA_BOOT}/boot.sh paths 2>/dev/null')
            except Exception:
                out = ""
            for line in (out or "").splitlines():
                key, _, val = line.partition("=")
                key = key.strip(); val = val.strip()
                if key == "mode" and val:
                    p["mode"] = val
                elif key in ("dir", "state", "bin") and val.startswith("/"):
                    p[key] = val
            self._paths = p
        return self._paths

    def code_dir(self):
        """Каталог кода — самый частый вопрос к router_paths(), поэтому у него своё имя."""
        return self.router_paths()["dir"]

    def paths_forget(self):
        """Сбросить кэш router_paths(). Зовут ровно там, где каталоги МОГЛИ переехать
        (смена раскладки): кэш живёт весь сеанс, и после переезда он показывал бы флеш
        там, где код уже на накопителе, — то есть renv() перестал бы экспортировать пути,
        а это ровно та беда, ради которой renv() и заведён."""
        self._paths = None

    def store_state(self):
        """Что роутер знает про внешний накопитель. ВЛАДЕЛЕЦ ОТВЕТА — движок на роутере
        (`usb-offload.sh json`): своей копии «какая флешка кандидат, сколько на ней места,
        какая раскладка» на ПК быть не должно — она разошлась бы с панелью на первой правке.

        Возвращает разобранный JSON движка либо `{}`: движка нет (панель ещё не стоит или
        сборка старее фичи), не ответил, отдал не-JSON. Пустой ответ читается вызывающим как
        «спрашивать не о чем» — это не отказ, а отсутствие темы."""
        cd = self.code_dir()
        out = self.router.get(
            self.renv() + f'[ -f {_shq(cd)}/usb-offload.sh ] && sh {_shq(cd)}/usb-offload.sh json 2>/dev/null')
        if not out.startswith("{"):
            return {}
        try:
            js = json.loads(out)
        except ValueError:
            return {}
        return js if isinstance(js, dict) else {}

    def renv(self):
        """Префикс `export …; ` для КАЖДОЙ команды, которая ЗАПУСКАЕТ скрипт роутера.

        Мало знать, ГДЕ лежит скрипт: он и сам спрашивает окружение (форма `${VAR:-литерал}` —
        инвариант проекта, следит C60). Если позвать `sh <накопитель>/uninstall.sh` без него,
        снятие возьмёт настройки с ФЛЕША: маркер накопителя не найдётся, хранилище с ключами
        переживёт «полное удаление», а `web-ui.sh start` не найдёт docroot и панель не поднимется.
        На роутере уже это делает бутстрап (он экспортирует три пути перед `exec`), но ПК ходит
        по SSH напрямую — значит, обязан повторить то же самое.
        ОБЫЧНАЯ РАСКЛАДКА — ПУСТАЯ СТРОКА: команда остаётся байт-в-байт прежней, и ни один старый
        роутер не увидит разницы. Кавычки одинарные (пробел в пути к хранилищу законен); путь с
        самой кавычкой не бывает, но если приедет — молча отдаём пустой префикс, а не ломаный."""
        p = self.router_paths()
        if (p["dir"] == ENODIA_DIR and p["state"] == ENODIA_STATE and p["bin"] == ENODIA_BIN):
            return ""
        vals = (p["dir"], p["state"], p["bin"], ENODIA_BOOT)
        if any("'" in v for v in vals):
            return ""
        return ("export ENODIA_DIR='{0}' ENODIA_STATE='{1}' ENODIA_BIN='{2}' ENODIA_BOOT='{3}'; "
                .format(*vals))

    def bin_arch(self):
        # Арка роутера для выбора набора bin/<арка>/ — спрашивается ОДИН раз за сеанс
        # (каждый вызов = SSH-раунд, а нужен он в preflight, в заливке и в сводке).
        if self._bin_arch is None:
            self._bin_arch = detect_router_arch(self.router) or DEFAULT_ARCH
        return self._bin_arch

    # Единственный ответ ПК-стороны на «какие бинари РЕАЛЬНО стоят». Судить по
    # `[ -x $ENODIA_DIR/<имя> ]` НЕЛЬЗЯ: при включённом внешнем накопителе тяжёлые бинари живут на
    # нём (`store-lib.sh`: `bin_path`), а в $ENODIA_DIR их нет ВООБЩЕ. Замер на боевом BE7000
    # 04.08.2026: xray/hysteria/byedpi/nfqws/hev = `bin_where store`, а прежний код давал
    # `INSTPROTO:1000` — ПК считал роутер awg-only. Цена: `_alts_to_keep` не защищал
    # установленный альт от `purge-alt`, а «обновить скрипты» слало awg.conf на xray-only-роутер.
    # Тот же класс, что находки про `-x "$ENODIA_DIR/byedpi"` в slots.sh и proto-install.sh.
    # Нет store-lib.sh (доисторическая установка) — шим падает на прежний путь, поведение прежнее.
    BIN_PROBE = ("amneziawg-go", "awg", "xray", "hysteria", "byedpi", "nfqws", "hev")

    def installed_bins(self, names=None):
        names = names or self.BIN_PROBE
        _rp = self.router_paths()
        script = (
            f'D={_rp["dir"]}\n'
            # Каталог бинарей и настроек — ТОЖЕ активные: store-lib.sh читает маркер
            # накопителя из $ENODIA_STATE, и с литералом флеша в режиме `full` он не нашёл
            # бы ни маркера, ни самих бинарей — весь список ответил бы «не установлено» на
            # живой системе.
            f'ENODIA_STATE={_rp["state"]}; export ENODIA_STATE\n'
            f'ENODIA_BIN={_rp["bin"]}; export ENODIA_BIN\n'
            f'BN={_rp["bin"]}\n'
            'if [ -f "$D/store-lib.sh" ]; then . "$D/store-lib.sh"; fi\n'
            'command -v bin_path >/dev/null 2>&1 || bin_path() { printf "%s" "$BN/$1"; }\n'
            f'for n in {" ".join(names)}; do\n'
            '  p=$(bin_path "$n" 2>/dev/null)\n'
            '  [ -n "$p" ] && [ -x "$p" ] && echo "HAVE $n"\n'
            'done\n'
        )
        out = self.router.run_script(script, silent=True).out
        return {ln.split()[1] for ln in out.splitlines() if ln.startswith("HAVE ") and len(ln.split()) > 1}

    # ---- пароль ----
    def ensure_password(self):
        pw = get_stored_password(self.router_ip)
        if pw:
            return pw
        warn("Пароль ещё не сохранён")
        if not save_password(self.router_ip):
            return None
        return get_stored_password(self.router_ip)

    # ---- IP роутера ----
    def set_router_host(self, ip):
        self.router_ip = ip
        sub = get_lan_subnet(ip)
        if sub:
            self.lan_subnet = sub
        # Другой адрес — другой роутер, а арка кэшируется НА СЕАНС. Без сброса «Изменить IP» →
        # «Установить» уносило на второй роутер набор бинарей ПЕРВОГО: между BE7000 и AX3600
        # это незаметно (обе arm64 — проверено 16.08.2026), а на BE3600 (armv7) даёт ENOEXEC,
        # и спасает только роутерный гард bin_arch_matches — то есть бутстрап-десинк не встаёт
        # вовсе. Сценарий не гипотетический: под мульти-роутерную работу заведён и флаг --host.
        self._bin_arch = None
        # …и РОВНО ПО ТОЙ ЖЕ ПРИЧИНЕ — активные каталоги. Кэш `_paths` завели позже арки, и урок
        # выше на него не распространили: ЗАМЕР 02.09.2026, мастер в браузере, BE7000 → AX3600 в
        # одном сеансе. Проверка перед установкой на AX3600 (накопителя там нет вовсе, панель
        # стоит) сообщила «Панели ещё нет» и «Система живёт на накопителе: код сейчас в
        # /mnt/enodia-usb/enodia-store/enodia — ставить с компьютера нельзя», то есть ЗАПРЕТИЛА
        # установку на исправном роутере по раскладке ЧУЖОГО. Обратное направление хуже: приняв
        # роутер с накопителем за флешевый, ПК вырастил бы ВТОРУЮ установку рядом с рабочей —
        # ровно то, ради чего store_install_blocks и написан.
        # Сбрасываем поле `_paths` через владельца (paths_forget), а не присваиванием: у поля
        # один хозяин. Имя названо здесь намеренно — по нему сверяет C66.
        self.paths_forget()
        self.router.set_host(ip)

    def initialize_router_host(self):
        # Первый запуск: спросить IP роутера (Enter = дефолт) и запомнить. Зачем: роутер
        # не всегда на .1 (бывает .100) — без этого скрипт стучался не туда.
        saved = load_router_host()
        if saved:
            self.set_router_host(saved)
            return
        section("Первый запуск — адрес роутера")
        print(f"Укажите IP-адрес роутера в локальной сети. Обычно {self.router_ip}, но у вас может быть другой")
        cprint("(посмотрите в админке роутера или на наклейке; например 192.168.31.100).", C.GRAY)
        cprint(f"Поменять потом можно в меню: «{MENU_ACCESS}» -> «Изменить IP-адрес роутера».", C.GRAY)
        while True:
            ans = ask(f"IP роутера [{self.router_ip}]: ").strip()
            if not ans:
                ans = self.router_ip
            if test_ip_string(ans):
                self.set_router_host(ans)
                save_router_host(ans)
                break
            warn("Это не похоже на IPv4-адрес (пример: 192.168.31.1). Повторите.")
        ok(f"Адрес роутера сохранён: {self.router_ip}")

    # ---- детект состояния роутера ----
    def detect_awg_state(self):
        # INSTALLED = на роутере есть НАША ПАНЕЛЬ (web-ui.sh + дерево web/). Прежде признаком был
        # «switch-vpn.sh + конфиг/бинарь ЛЮБОГО транспорта», и после реформы это стало неверным
        # ровно для типовой установки: панель стоит, транспорта нет ВООБЩЕ — а скрипт объявлял бы
        # роутер свежим и предлагал ставить заново поверх рабочей системы. Судим по тому, что мы
        # действительно ставим.
        # Гард `-f`, а не `-x`: панель поднимают через `sh $D/web-ui.sh start` (короткие команды
        # на роутере не работают — симлинков нет), значит бит исполнения ей не нужен ВООБЩЕ, и
        # спрашивать про него — спрашивать не о том. Слетает он буднично: 15.08.2026 на BE7000
        # так лежал clock-lib.sh — 644 после точечной заливки, единственный из 64. Цена
        # ошибки здесь максимальна из всех мест этого класса: «панель не найдена» ⇒ предложение
        # поставить систему ПОВЕРХ работающей. То же самое ниже, в TCFG сводки.
        probe = (
            f'D={_shq(self.code_dir())}\n'
            'if [ -f "$D/web-ui.sh" ] && [ -f "$D/web/index.html" ]; then\n'
            '  echo INSTALLED\n'
            'else\n'
            '  echo FRESH\n'
            'fi\n'
        )
        out = self.router.run_script(probe, silent=True).out
        if "INSTALLED" in out:
            return "INSTALLED"
        if "FRESH" in out:
            return "FRESH"
        return "UNKNOWN"

    def unknown_reason_from_router(self):
        # Почему детект вернул UNKNOWN — по классификации последнего SSH-коннекта. 'negotiation'
        # (несовместимый host key/KEX старого dropbear) НЕ равно неверному паролю: не гоняем
        # тестера менять верный пароль (баг беты 04.07.2026). Прочее упрощаем до 'auth'.
        return "negotiation" if getattr(self.router, "last_error_kind", "") == "negotiation" else "auth"

    # ---- сводка для шапки (прошивка/CPU/RAM/диск + транспорт + живость несущей) ----
    def get_router_summary(self):
        sh = (
            'F=/usr/share/xiaoqiang/xiaoqiang_version\n'
            'rom=$(grep -E "option ROM " $F 2>/dev/null | sed "s/.*\'\\(.*\\)\'.*/\\1/")\n'
            'ch=$(grep -E "option CHANNEL " $F 2>/dev/null | sed "s/.*\'\\(.*\\)\'.*/\\1/")\n'
            'echo "FW ${rom:-?} ${ch:-?}"\n'
            # Загрузка ЦП — ДЕЛЬТА занятых тиков /proc/stat за секунду (как top и как
            # router-lib.sh::cpu_busy_pct на роутере), а НЕ (load1/ядра)*100. Прежняя формула
            # печатала «ЦП ~25%» на роутере, занятом на 0-1%: loadavg здесь держится около 1.0
            # из-за фонового демона — замерено 16.08.2026 одновременно на BE7000 (реальный 1%)
            # и AX3600 (0%). Панель от этой формулы ушла ещё в июле, а установщик остался с ней
            # и печатал 25% там, где человек первый раз смотрит на свой роутер — и читает эту
            # строку как факт. Копия, а не вызов библиотеки: шапка обязана работать
            # и до установки, когда на роутере нет НИ ОДНОГО нашего файла. Секунда сна — вся
            # цена; сводку берём один раз за сеанс.
            'set -- $(awk \'/^cpu /{s=0;for(i=2;i<=NF;i++)s+=$i; print s, $5+$6; exit}\' /proc/stat 2>/dev/null); t0="$1"; i0="$2"\n'
            'sleep 1\n'
            'set -- $(awk \'/^cpu /{s=0;for(i=2;i<=NF;i++)s+=$i; print s, $5+$6; exit}\' /proc/stat 2>/dev/null); t1="$1"; i1="$2"\n'
            'echo "CPU $(awk -v t0="${t0:-0}" -v i0="${i0:-0}" -v t1="${t1:-0}" -v i1="${i1:-0}" \'BEGIN{\n'
            '  dt=t1-t0; di=i1-i0; if(dt<=0){exit}\n'
            '  v=(1-di/dt)*100; if(v<0)v=0; if(v>100)v=100; printf "%d", v+0.5 }\')"\n'
            "awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf \"RAM %d %d\\n\",(a==\"\"?f:a)/1024,t/1024}' /proc/meminfo 2>/dev/null\n"
            # «Занято %» считаем САМИ (total − available), а не берём колонку `Use%` у df: та без
            # неснижаемого резерва UBIFS и расходится с панелью на 3-4 пункта. Владелец формулы —
            # status.sh, см. разбор там же и в show_router_resources ниже.
            # Четвёртым полем — ТОЧКА МОНТИРОВАНИЯ (последняя колонка df). Без неё строка шапки
            # подписывалась литералом «/data», а на BE10000 это ЧУЖОЙ том: числа наши, подпись
            # чужая — ровно та ложь, ради которой df и перевели на путь каталога.
            # СПРАШИВАЕМ О ПУТИ, КОТОРЫЙ УЖЕ ЕСТЬ. До заливки payload $ENODIA_DIR на роутере ещё
            # НЕТ, а `df` по несуществующему пути печатает в stdout один ЗАГОЛОВОК — и `tail -1`
            # честно отдаёт его как строку данных ($NF="on", $(NF-4)="Used"). Поднимаемся к
            # ближайшему СУЩЕСТВУЮЩЕМУ предку: на свежем роутере это /data/usr, то есть НАШ том и
            # на BE10000 тоже (фолбэк на литерал /data вернул бы ровно ту граблю, от которой ушли).
            # `+0` в гарде обязателен: у awk сравнение нечислового поля с числом СТРОКОВОЕ, и
            # "Used" > "0" истинно — прежний `$(NF-4)>0` заголовок пропускал.
            '_fa=' + ENODIA_DIR + '; while [ -n "$_fa" ] && [ ! -e "$_fa" ]; do _fa="${_fa%/*}"; done\n'
            "df -k \"${_fa:-/}\" 2>/dev/null | tail -1 | awk 'NF>=5 && $(NF-4)+0>0{printf \"DISK %d %d %.0f%% %s\\n\",$(NF-2)/1024,$(NF-4)/1024,($(NF-4)-$(NF-2))*100/$(NF-4),$NF}'\n"
            # Путь берём из КОНСТАНТЫ, а не литералом: вторая копия «/data/usr/app/enodia» в одном
            # файле с ENODIA_DIR — ровно тот дрейф, который потом ищут глазами.
            f'D={_shq(self.router_paths()["dir"])}\n'
            f'ST={_shq(self.router_paths()["state"])}\n'
            f'BN={_shq(self.router_paths()["bin"])}\n'
            # ЭКСПОРТ, а не только присваивание: ниже мы ЗАПУСКАЕМ скрипты роутера, а они
            # спрашивают окружение сами (форма ${VAR:-литерал}). Без него transport.sh в
            # режиме «всё на накопителе» читал бы .transport с флеша — то есть отвечал бы
            # «транспорт не выбран» на роутере с поднятым туннелем.
            'export ENODIA_DIR="$D" ENODIA_STATE="$ST" ENODIA_BIN="$BN"\n'
            'echo "TPT $(cat $ST/.transport 2>/dev/null || echo awg)"\n'
            # «Транспорт не выбран» — штатное состояние установки «только панель», и спрашиваем о
            # нём ОРКЕСТРАТОР: сам по себе пустой флаг значит ещё и «роутер старше флага», где
            # несущая awg. Код 2 (старая копия скрипта) = считаем, что транспорт есть, как раньше.
            # `-f`, не `-x`: скрипт мы тут же и запускаем через `sh` (см. detect_awg_state).
            # Со снятым битом гард молчком оставлял tcfg=1, и шапка на роутере, где транспорт
            # не выбран вовсе, печатала «Протокол: AmneziaWG · Конфиг: ?» — то есть врала о
            # состоянии ровно в той строке, ради которой её и читают.
            # TCFG=2 — «наших файлов тут нет ВООБЩЕ» (стоковый роутер до установки). Без этой
            # ветки такой роутер получал tcfg=1 и шапку «[!] VPN НЕ АКТИВЕН — несущая AmneziaWG
            # НЕ поднята, трафик идёт НАПРЯМУЮ»: тревога о системе, которую никогда не ставили
            # (ЗАМЕРЕНО 16.08.2026 прогоном этого же скрипта по пустому каталогу). Признак
            # ДВОЙНОЙ: нет ни оркестратора, ни switch-vpn.sh — последний есть в КАЖДОМ поколении
            # установки, поэтому доисторический роутер (транспорта ещё нет, VPN уже есть) в эту
            # ветку не попадёт и по-прежнему опишется как awg.
            'tcfg=1\n'
            'if [ -f $D/transport.sh ]; then sh $D/transport.sh configured >/dev/null 2>&1; [ "$?" = 1 ] && tcfg=0\n'
            'elif [ ! -f $D/switch-vpn.sh ]; then tcfg=2; fi\n'
            'echo "TCFG $tcfg"\n'
            'echo "ACONF $(cat $ST/.active 2>/dev/null)"\n'
            'echo "XCONF $(cat $ST/.xray-active 2>/dev/null)"\n'
            'echo "HCONF $(cat $ST/.hy2-active 2>/dev/null)"\n'
            't=$(cat $ST/.transport 2>/dev/null || echo awg)\n'
            'live=0\n'
            # У zapret НЕТ несущей и НЕТ маркировки (десинк идёт по прямому пути) ⇒ гейт
            # «fwmark 0x1 + default в table 1000» для него ВСЕГДА ложен, и шапка честно рабочий
            # роутер объявляла бы мёртвым. Его живость — та же, по которой судит rule-heal
            # сторожа: демон nfqws ПЛЮС наш jump ENODIA_ZAPRET (без jump десинк молча мёртв).
            'case "$t" in\n'
            "  zapret) ps 2>/dev/null | grep -q '[n]fqws' && iptables -t mangle -S PREROUTING 2>/dev/null | grep -q 'ENODIA_ZAPRET' && live=1 ;;\n"
            '  *)\n'
            # Маркировка И маршрут: у tunnel-транспортов «живо» = обе половины (метка есть, и
            # вести ей есть куда). Ответ про маршрут — общий, из SH_CARRIER_ROUTE.
            f"    if ip rule show 2>/dev/null | grep -q 'fwmark 0x1' && {SH_CARRIER_ROUTE}; then\n"
            '      case "$t" in\n'
            "        awg) hs=$($BN/awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); case \"$hs\" in ''|*[!0-9]*) hs=0;; esac; [ \"$hs\" -gt 0 ] && [ $(( $(date +%s) - hs )) -lt 180 ] && live=1 ;;\n"
            "        *)   netstat -ltn 2>/dev/null | grep -q '127.0.0.1:10808' && live=1 ;;\n"
            '      esac\n'
            '    fi ;;\n'
            'esac\n'
            'echo "LIVE $live"\n'
        )
        b64 = base64.b64encode(sh.encode("ascii")).decode("ascii")
        out = self.router.run(f"echo {b64} | base64 -d | sh", silent=True).out
        if not out:
            return None
        fw = load = ram = disk = None
        tpt = "awg"; aconf = xconf = hconf = None
        tcfg = 1   # 0 = транспорт не выбран вовсе (установка «только панель»)
        live = -1  # -1 = неизвестно (старый роутер без токена LIVE)
        for ln in out.splitlines():
            p = ln.replace("\r", "").strip().split()
            if not p:
                continue
            tok = p[0]
            if tok == "FW":
                if len(p) >= 3:
                    fw = f"{p[1]} ({p[2]})"
                elif len(p) >= 2:
                    fw = p[1]
            elif tok == "TPT" and len(p) >= 2 and p[1]:
                tpt = p[1]
            elif tok == "ACONF" and len(p) >= 2 and p[1]:
                aconf = p[1]
            elif tok == "XCONF" and len(p) >= 2 and p[1]:
                xconf = p[1]
            elif tok == "HCONF" and len(p) >= 2 and p[1]:
                hconf = p[1]
            elif tok == "LIVE" and len(p) >= 2 and p[1] in ("0", "1"):
                live = int(p[1])
            elif tok == "TCFG" and len(p) >= 2 and p[1] in ("0", "1", "2"):
                tcfg = int(p[1])
            elif tok == "CPU" and len(p) >= 2:
                # Пусто/мусор = «не смогли измерить» ⇒ строки ЦП в шапке просто не будет.
                # Выдумывать число нельзя: показанный процент читают как факт.
                try:
                    c = int(p[1])
                    if 0 <= c <= 100:
                        load = f"ЦП ~{c}%"
                except ValueError:
                    pass
            elif tok == "RAM" and len(p) >= 3:
                ram = f"ОЗУ {p[1]} из {p[2]} МБ своб"
            elif tok == "DISK" and len(p) >= 4:
                # Пятое поле — точка монтирования НАШЕГО тома; её нет только у своего же вывода
                # до 31.08.2026, и тогда честнее подписать привычным /data, чем не подписать.
                disk = f"ПЗУ {p[4] if len(p) >= 5 else '/data'} {p[1]} из {p[2]} МБ своб ({p[3]})"

        # Вилка ЗНАЕТ все пять транспортов. Прежде их было два (xray/hy2), а `*)` = «AmneziaWG»:
        # на byedpi шапка врала И протоколом, И конфигом (печатала имя awg-конфига из .active,
        # которого byedpi в глаза не видел), на zapret — ещё и вердиктом «VPN НЕ АКТИВЕН».
        # Это ровно тот класс «код забывает альт», из-за которого врала шапка status.sh.
        if tcfg != 1:
            # Не «VPN НЕ АКТИВЕН» (это про сломанную несущую), а «его тут и не заводили».
            # Разница для человека принципиальная: первое — авария, второе — следующий шаг.
            # Два разных «не заводили»: 0 — система стоит, транспорт не выбран; 2 — на роутере
            # вообще ничего нашего нет. Тревожную строку не печатаем НИ В ОДНОМ из них.
            lines = ["Транспорт не выбран — роутер работает как сток; всё дальше в панели"
                     if tcfg == 0 else
                     "Наша система не установлена — роутер работает как сток"]
            l1 = []
            if fw:   l1.append(f"Прошивка {fw}")
            if load: l1.append(load)
            l2 = []
            if ram:  l2.append(ram)
            if disk: l2.append(disk)
            if l1: lines.append("  ·  ".join(l1))
            if l2: lines.append("  ·  ".join(l2))
            return lines
        if tpt == "xray":
            pname, cfg = "Xray", (xconf or "?")
        elif tpt == "hy2":
            pname, cfg = "Hysteria2", (hconf or "?")
        elif tpt == "byedpi":
            pname, cfg = "ByeDPI", "десинк без VPS"
        elif tpt == "zapret":
            pname, cfg = "Zapret", "десинк без VPS"
        else:
            pname, cfg = "AmneziaWG", (aconf or "?")
        no_vps = tpt in ("byedpi", "zapret")
        # Шапка отражает РЕАЛЬНОЕ состояние несущей (live), а не просто .transport.
        if live == 0:
            what = "десинк НЕ проводится" if tpt == "zapret" else f"несущая {pname} ({cfg}) НЕ поднята"
            proto = f"[!] {'ОБХОД' if no_vps else 'VPN'} НЕ АКТИВЕН — {what}, трафик идёт НАПРЯМУЮ"
        elif live == 1:
            proto = f"Протокол: {pname}  ·  Конфиг: {cfg}  ·  {'обход активен' if no_vps else 'VPN активен'}"
        else:
            proto = f"Протокол: {pname}  ·  Конфиг: {cfg}"
        l1 = []
        if fw:   l1.append(f"Прошивка {fw}")
        if load: l1.append(load)
        l2 = []
        if ram:  l2.append(ram)
        if disk: l2.append(disk)
        lines = [proto]
        if l1: lines.append("  ·  ".join(l1))
        if l2: lines.append("  ·  ".join(l2))
        return lines or None

    def refresh_summary(self):
        self.router_summary = self.get_router_summary()

    # ---- шапка ----
    def show_header(self):
        bar = "============================================================"
        cprint(bar, C.CYAN)
        cprint(f"  Enodia — установка веб-панели  v{PROJECT_VERSION}", C.CYAN)
        cprint(f"  Роутер: {self.router_ip}", C.CYAN)
        if self.router_summary:
            for l in self.router_summary:
                clr = C.YELLOW if str(l).startswith("[!]") else C.CYAN
                cprint(f"  {l}", clr)
        cprint(bar, C.CYAN)
        cprint(f"  Веб-панель:          http://{self.router_ip}:8088  (браузер, пароль панели)", C.DARKCYAN)
        cprint("  Новости (Telegram):  https://t.me/+tfMLMVKG03FhMGYy", C.DARKCYAN)
        cprint("  Поддержать проект:   https://web.tribute.tg/d/LtA", C.DARKYELLOW)
        cprint(bar, C.CYAN)

    # ========================================================
    # Действия (Phase A)
    # ========================================================
    def action_raw_ssh(self):
        section("Произвольная команда на роутере")
        # Короткие awg/vpn/domain в SSH НЕ работают (симлинков нет: / = squashfs ro) —
        # подсказываем рабочую форму: ЧЕРЕЗ ЗАПУСКАТЕЛЬ. Прямой `sh {ENODIA_DIR}/<скрипт>.sh`
        # верен, только пока код на флеше; в раскладке `full` он читает литералы флеша (чужое,
        # пустое состояние), а самого файла там может не быть вовсе. Пути экспортирует boot.sh.
        c = ask(f"Команда на роутере (напр. 'ip rule', 'sh {ENODIA_BOOT}/boot.sh status.sh', "
                f"'sh {ENODIA_BOOT}/boot.sh switch-vpn.sh status'): ")
        if not c:
            return
        out = self.router.run(c).out
        print(out)

    def action_set_router_host(self):
        section("IP-адрес роутера")
        print(f"Текущий IP роутера: {self.router_ip}")
        cprint("Введите новый адрес (Enter — оставить как есть).", C.GRAY)
        ans = ask(f"Новый IP роутера [{self.router_ip}]: ").strip()
        if not ans or ans == self.router_ip:
            info("Без изменений.")
            return
        if not test_ip_string(ans):
            warn("Не похоже на IPv4-адрес (пример: 192.168.31.1) — отмена.")
            return
        self.set_router_host(ans)
        save_router_host(ans)
        ok(f"IP роутера: {self.router_ip}")
        # Другой роутер -> прежний детект/сводка устарели. Пере-проверяем.
        if test_router_reachable(self.router_ip):
            self.awg_state = self.detect_awg_state()
            if self.awg_state == "UNKNOWN":
                self.unknown_reason = self.unknown_reason_from_router()
            else:
                self.refresh_summary()
        else:
            self.awg_state = "UNKNOWN"
            self.unknown_reason = "offline"

    def action_change_password(self):
        section("Смена сохранённого пароля")
        if save_password(self.router_ip):
            self.router.close()  # сбросить коннект, чтобы подхватился новый пароль
            ok("Готово")
        # После смены пароля на не-INSTALLED — пере-детект (как в be7000.ps1).
        if self.awg_state != "INSTALLED" and test_router_reachable(self.router_ip):
            self.awg_state = self.detect_awg_state()
            if self.awg_state == "UNKNOWN":
                self.unknown_reason = self.unknown_reason_from_router()
            else:
                self.refresh_summary()

    # ========================================================
    # Действия (Phase B) — управление VPN
    # ========================================================

    # ---- VPN глобально / починка ----
    # ========================================================
    # iplist.conf — источник CIDR-списка (read-modify-write + кастомный файл)
    # ДВЕ ОРТОГОНАЛЬНЫЕ оси: источник СКАЧИВАНИЯ (opencck/сайты/URL) и кастомный
    # ЛОКАЛЬНЫЙ файл (off/only/merge). Conf читаем→меняем ключ→пишем, чтобы смена
    # одной оси не сбрасывала другую.
    # ========================================================
    def show_router_resources(self, label=None):
        # Роутер отдаёт ASCII-токены (RAM/DISK/LOGS), по-русски форматируем здесь.
        # df по /data (ubifs persist) и /tmp (RAM); НЕ по / (ro-squashfs, всегда 100%).
        # «ЗАНЯТО» СЧИТАЕМ САМИ, колонку `Use%` у df не берём: она считает used/(used+avail), то
        # есть БЕЗ неснижаемого резерва UBIFS. Замер на AX3600 17.08.2026: `Use%` дал 31%, а панель
        # и status.sh («занято = total − available») — 35% про тот же `/data`. Тестер копирует
        # в отчёт ОБА, и получаются два числа про одно место — ровно то, что уже чинили внутри
        # панели (16.08) и в status.sh; здесь была ЧЕТВЁРТАЯ копия арифметики. Отсюда `df` в
        # КИЛОБАЙТАХ (не `-h`) и `%.1fM` руками: оба монтирования заведомо меньше гигабайта.
        # Гард `$(NF-4)>0` — от деления на ноль и от строки-переноса длинного имени устройства.
        # Размер логов В ОЗУ считаем ТОЛЬКО по своим: список спрашиваем у владельца
        # (`clean.sh ramlogs-list`), маску `/tmp/*.log` брать нельзя — рядом лежат СТОКОВЫЕ
        # логи Xiaomi (wifi_analysis, ssh_patch, *.bootcheck, stat_points_*), и они удваивали
        # цифру. Инвариант записан ниже, у ROUTER_LOGS, — и ровно здесь же был нарушен (замер на
        # свежем AX3600 17.08.2026: маска дала 10 файлов / 8 КБ вместо наших 2 / 3 КБ; тот же
        # дефект чинили в status.sh и dump.sh). Владельца ещё нет (замер ДО заливки
        # payload) ⇒ ноль, и это верный ответ: своих логов там пока и правда нет.
        # ТОЧКА МОНТИРОВАНИЯ НАКОПИТЕЛЯ МОЖЕТ НЕСТИ ПРОБЕЛ (mount-lib.sh: «/mnt/My Flash» законна) ⇒ путь кода — в кавычках, а
        # в строках ответа точка — ПОСЛЕДНИМ полем: разбор по пробелам иначе резал её, и место мерилось на корне (ревью ветки, круг 2).
        # Разбор строки df (`_dfl`) ищет колонку «%»: пробел в точке сдвигает поля с конца. Склейка — через if, не `m (…)`: у busybox-awk
        # это вызов функции m, программа падала, и строки «Диск» пропадали молча (замер BE7000 30.09.2026; следит C118).
        # flash-lit: якорь `df` обязан мерить ФЛЕШ РОУТЕРА, а не том, на который уехал код
        # ДВА РАЗНЫХ ПУТИ, и путать их нельзя. ENODIA_DIR — ЛИТЕРАЛ ФЛЕША, и здесь это ВЕРНО:
        # якорь `df` отвечает на вопрос «сколько осталось НА РОУТЕРЕ», а в режиме «всё на
        # накопителе» активный каталог лежит на флешке и показал бы её 29 ГБ. CODE_DIR — АКТИВНЫЙ
        # каталог: владелец списка логов в ОЗУ (clean.sh) живёт там, и по литералу его в этом
        # режиме нет вовсе — сводка молча печатала «0 КБ» вместо настоящего размера.
        res_script = "ENODIA_DIR=" + ENODIA_DIR + "\nCODE_DIR=" + _shq(self.code_dir()) + "\n" + r"""awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf "RAM %d %d %d\n",f/1024,t/1024,(a==""?-1:a/1024)}' /proc/meminfo 2>/dev/null
_dfl() { df -k "$1" 2>/dev/null | tail -1 | awk '{for(i=NF;i>1;i--) if($i ~ /%$/) break; if(i>=4 && $(i-3) ~ /^[0-9]+$/ && $(i-1) ~ /^[0-9]+$/ && $(i-3)+0>0){m=""; for(j=i+1;j<=NF;j++){ if(j>i+1) m=m " "; m=m $j }; print $(i-3), $(i-1), m}}'; }
_fa="$ENODIA_DIR"; while [ -n "$_fa" ] && [ ! -e "$_fa" ]; do _fa="${_fa%/*}"; done
_ourmp=$(_dfl "${_fa:-/}" | { read -r _t _a _m; printf '%s' "$_m"; })
printf 'OURMP %s\n' "${_ourmp:-/data}"
_fd="$CODE_DIR"; while [ -n "$_fd" ] && [ ! -e "$_fd" ]; do _fd="${_fd%/*}"; done
_destmp=$(_dfl "${_fd:-/}" | { read -r _t _a _m; printf '%s' "$_m"; })
printf 'DESTMP %s\n' "${_destmp:-${_ourmp:-/data}}"
[ "$_destmp" = "${_ourmp:-/data}" ] && _destmp=""
for m in "${_ourmp:-/data}" ${_destmp:+"$_destmp"} /tmp; do _dfl "$m" | awk '{t=$1; a=$2; sub(/^[0-9]+ [0-9]+ /, ""); printf "DISK %.1fM %.1fM %.0f%% %.0f %s\n",a/1024,t/1024,(t-a)*100/t,a,$0}'; done
{ [ -f "$CODE_DIR/clean.sh" ] && sh "$CODE_DIR/clean.sh" ramlogs-list 2>/dev/null; } | while read -r p; do ls -l "$p" 2>/dev/null; done | awk '{s+=$5}END{printf "LOGS %d %d\n",(s+1023)/1024,NR}'
"""
        r = self.router.run_script(res_script, silent=True).out
        self.disk_free_kb = {}
        # ИМЯ НАШЕГО ТОМА — ОТ РОУТЕРА, не литералом. Ключи disk_free_kb — точки монтирования, и
        # гард места ищет в них СВОЮ: на BE10000 она зовётся /data/usr, и поиск по «/data» дал бы
        # промах, то есть «место узнать не удалось — ставлю без проверки» ровно там, где флеш
        # поделён на три тома и проверка нужнее всего.
        self.disk_our_mp = "/data"
        self.disk_dest_mp = None
        print()
        # Заголовок — аргумент по умолчанию, а язык выбирается В РАНТАЙМЕ: строка, стоящая в
        # сигнатуре, вычислилась бы один раз при импорте, то есть всегда по-русски.
        cprint("--- %s ---" % (label or L("Ресурсы роутера сейчас", "Router resources right now")), C.CYAN)
        if not r:
            info(L("(не удалось получить данные о памяти роутера)",
                   "(could not read the router memory figures)")); return
        for ln in r.splitlines():
            p = ln.replace("\r", "").strip().split()
            if not p:
                continue
            # Точка монтирования — ХВОСТОМ строки целиком (в ней законен пробел), числа — полями перед ней.
            if p[0] == "OURMP" and len(p) >= 2:
                self.disk_our_mp = ln.replace("\r", "").strip().split(None, 1)[1]
            elif p[0] == "DESTMP" and len(p) >= 2:
                self.disk_dest_mp = ln.replace("\r", "").strip().split(None, 1)[1]
            elif p[0] == "RAM" and len(p) >= 4:
                msg = L(f"RAM:       {p[1]} МБ свободно из {p[2]} МБ",
                        f"RAM:       {p[1]} MB free of {p[2]} MB")
                avail = int(p[1])
                if int(p[3]) >= 0:
                    msg += L(f" (доступно {p[3]} МБ)", f" ({p[3]} MB available)"); avail = int(p[3])
                clr = C.RED if avail < 30 else (C.YELLOW if avail < 60 else C.GREEN)
                cprint(msg, clr)
            elif p[0] == "DISK" and len(p) >= 6:
                _mp = ln.replace("\r", "").strip().split(None, 5)[5]
                cprint(L("Диск {:<8} {} своб из {} (занято {})",
                         "Disk {:<8} {} free of {} ({} used)").format(_mp, p[1], p[2], p[3]), C.GRAY)
                # Свободные КБ ТЕМ ЖЕ замером: гард места ниже обязан судить по числу, которое человек только что
                # увидел, иначе это пятая копия арифметики про /data.
                try:
                    self.disk_free_kb[_mp] = int(p[4])
                except ValueError:
                    pass
            elif p[0] == "LOGS" and len(p) >= 3:
                cprint(L(f"Логи /tmp (наши): {p[1]} КБ в {p[2]} файл(ах)",
                         f"Our logs in /tmp: {p[1]} KB in {p[2]} file(s)"), C.GRAY)

    def _preflight_remote(self):
        # Связь + рабочий SSH (paramiko). plink/pscp в Python НЕ нужны.
        if not test_router_reachable(self.router_ip):
            err(L("Нет связи с роутером (SSH порт 22 закрыт/недоступен).",
                  "No connection to the router (SSH port 22 closed or unreachable)."))
            return False
        if "SSH_OK" not in self.router.run("echo SSH_OK", silent=True).out:
            err(L("SSH не работает (пароль root неверен или вход закрыт).",
                  "SSH does not work (wrong root password, or login disabled)."))
            return False
        return True

    def legacy_install_blocks(self):
        """Стоит ли рядом установка ПРЕЖНЕЙ версии (до ребрендинга каталог звался иначе).

        ОТДЕЛЬНЫЙ метод, а НЕ строчка в _preflight_remote — и это главное про него. Тот помощник
        общий: его зовут и удаление, и перезапуск панели, и чтение логов, и снятие из мастера.
        Гард, положенный туда, запретил бы ровно те действия, которыми ситуацию и чинят, —
        человек получил бы «сперва снимите прежнюю» в ответ на попытку её снять. Поэтому
        спрашиваем ТОЛЬКО там, где мы собираемся ПИСАТЬ на роутер: в установке.
        Критерий общий с install.sh (LEGACY_PROBE), второй копии условия нет."""
        if "LEGACY" not in self.router.get(LEGACY_PROBE):
            return False
        err(L(f"На роутере стоит ПРЕЖНЯЯ версия — {LEGACY_DIR} (каталог переехал при ребрендинге).",
              f"An OLDER version is installed — {LEGACY_DIR} (the directory moved during the rebrand)."))
        err(L("Две копии разом дерутся за iptables и cron, поэтому ставить поверх нельзя.",
              "Two copies fight over the same iptables and cron, so installing on top is refused."))
        info(L("Снимите прежнюю: в её панели «Настройки» → «Удаление» → «Удалить всё»,",
               "Remove the old one from its own panel: Settings -> Uninstall -> Remove everything,"))
        info(L(f"либо по SSH:  sh {LEGACY_DIR}/uninstall.sh purge",
               f"or over SSH:  sh {LEGACY_DIR}/uninstall.sh purge"))
        return True

    def preflight(self, dry=False, tight_ok=None):
        # Pre-flight установки ПАНЕЛИ: пакет кода + бутстрап-бинари под арку роутера + связь +
        # записываемость $ENODIA_DIR. Конфигов транспорта тут больше нет ВООБЩЕ: серверы добавляются
        # в панели, а протоколы она качает сама — проверять на ПК нечего, кроме того, что мы реально везём.
        section(L("Pre-flight проверки", "Pre-flight checks"))
        info(L(f"Папка скрипта: {SCRIPT_DIR}", f"Script directory: {SCRIPT_DIR}"))
        # КУДА СТАВИТЬ — спрашиваем заново: кэш путей живёт весь сеанс (у мастера — с экрана проверки, у меню — со старта), а
        # раскладку могли сменить из панели в соседней вкладке. С кэшем свежая установка шла бы по литералам флеша рядом с
        # системой, уехавшей на накопитель, или пакет ложился бы туда, откуда система уже ушла (ревью ветки pkg-update, круг 2).
        self.paths_forget()
        # refresh: в рабочей копии исходники могли поменяться с прошлого вопроса — ставим то, что лежит СЕЙЧАС.
        pk = local_package(refresh=True)
        if pk.get("error"):
            err(pk["error"])
            return False
        ok(L(f"Пакет кода {pk['version']} (код {pk['code']}): {pk['files']} файлов, "
             f"{round(pk['size'] / 1024)} КБ (распакованным {pk['raw_kb']} КБ), размер и sha256 сошлись",
             f"Code package {pk['version']} (code {pk['code']}): {pk['files']} files, "
             f"{round(pk['size'] / 1024)} KB ({pk['raw_kb']} KB unpacked), size and sha256 match"))
        # Какой набор проверять — решает АРКА РОУТЕРА, а не наши догадки: на BE3600 нужен
        # bin/armv7/. Спрашиваем до проверки, иначе проверили бы не тот набор. Связи нет —
        # берём дефолт и молчим: честную ошибку про связь выдаст _preflight_remote ниже.
        arch = self.bin_arch()
        info(L(f"Архитектура роутера: {arch} -> набор bin/{arch}/",
               f"Router architecture: {arch} -> the bin/{arch}/ set"))
        _bv_lines, bin_bad = bootstrap_verdict(arch)
        for _bv_kind, _bv_text in _bv_lines:
            {"warn": warn, "err": err, "ok": ok}[_bv_kind](_bv_text)
        if bin_bad:
            err(L("Бинарник(и) битые -- исправьте и перезапустите",
                  "Some binaries are broken -- fix them and start again")); return False
        if not self._preflight_remote():
            return False
        # Прежняя установка рядом — отказ ДО заливки. install.sh это тоже ловит, но там уже лежит
        # привезённый payload: на 20-МБ флеше, где старая копия занимает свои мегабайты, заливка
        # ради последующего «нельзя» способна добить место. Мастер спрашивает то же в wizard_facts.
        if self.legacy_install_blocks():
            return False
        if self.store_install_blocks():
            return False
        _busy = self.router_busy()
        if _busy:
            self.busy_err(_busy)
            return False
        ok(L("SSH работает", "SSH works"))
        writable, r = self.dir_writable()
        D, S, B = self.install_dirs()
        if not writable:
            err(L(f"{D} / {S} / {B}: не записывается. Возможно SSH под не-root.",
                  f"{D} / {S} / {B}: not writable. The SSH session may not be root."))
            if r.strip():
                cprint(r, C.GRAY)
            return False
        ok(L(f"{D} (+ настройки, бинари) доступны для записи",
             f"{D} (+ settings, binaries) are writable"))
        self.show_router_resources(L("Ресурсы роутера (до установки)", "Router resources (before installing)"))
        if not self._check_data_space(dry, tight_ok):
            return False
        ok("Pre-flight OK")
        return True

    def store_install_blocks(self):
        """Система стоит НА НАКОПИТЕЛЕ (режим full) — ставить с ПК нельзя, и это не каприз.
        Заливка идёт по литеральным путям на флеше роутера: получилась бы ВТОРАЯ установка
        рядом с первой, бутстрап (он судит по факту) переключился бы на флеш, а копия на
        накопителе осталась бы сиротой — с ключами, подписками и паролем панели внутри.
        Выход простой и обратимый, поэтому просто называем его. Обновляться в режиме full
        надо ИЗ ПАНЕЛИ («Обновление») — там путь идёт в активный каталог, какой бы он ни был.
        ОТДЕЛЬНАЯ ВЕТКА — «код на накопителе, а накопителя НЕТ» (`mode=none`). Путей бутстрап
        в этом случае не называет вовсе, и молчаливый фолбэк на литерал означал бы ровно ту
        вторую установку: сирота с ключами осталась бы на полке, а человек и не узнал бы."""
        p = self.router_paths()
        if p["mode"] == "none":
            err(L("Система установлена на внешний накопитель, а накопителя на роутере НЕТ",
                  "The system is installed on an external drive, and the drive is NOT on the router"))
            info(L("Воткните накопитель и повторите: панель и настройки поднимутся сами.",
                   "Plug the drive in and retry: the panel and the settings come back on their own."))
            info(L("Ставить сейчас нельзя: на флеше выросла бы ВТОРАЯ установка, а прежняя — с ключами,",
                   "Installing now is not possible: a SECOND installation would grow on the flash, and the"))
            info(L("подписками и паролем панели — осталась бы на накопителе сиротой.",
                   "old one — with keys, subscriptions and the panel password — would be orphaned on the drive."))
            return True
        d = p["dir"]
        if d != ENODIA_DIR:
            # Режим «всё на накопителе» — НЕ запрет (с 30.09.2026): ставим туда же, где система живёт (install_dirs).
            info(L(f"Система живёт на внешнем накопителе — ставлю туда же: {d}",
                   f"The system lives on an external drive — installing into the same place: {d}"))
        return False

    def install_dirs(self):
        """КУДА СТАВИМ — ТЕКУЩИЕ каталоги (код, настройки, бинари), те же, что у обновления из панели (ревью ветки
        pkg-update, круг 1; решение пользователя 30.09.2026). Прежде установка с ПК писала по ЛИТЕРАЛАМ флеша и в режиме
        «всё на накопителе» была запрещена: рядом с рабочей системой выросла бы вторая. Теперь ПК ставит тем же пакетом
        и тем же pkg-install.sh, что и панель, — и туда же. Свежий роутер: бутстрапа нет ⇒ литералы (router_paths)."""
        p = self.router_paths()
        return p["dir"], p["state"], p["bin"]

    def space_mp(self):
        """Том, на котором считаем место под установку: тот, где живёт КОД (туда её и кладём). Не спросили — наш том флеша."""
        return getattr(self, "disk_dest_mp", None) or getattr(self, "disk_our_mp", "/data")

    def dir_writable(self):
        """Пишутся ли ВСЕ ТРИ наших каталога (мы там root или нет). Возвращает (bool, ответ).
        Проба одна на обе стороны: консольный preflight и экран проверки в мастере.

        Каталогов три, и проверять надо каждый: установка кладёт код в один, настройки во
        второй, бинари в третий. Проба ОДНОГО каталога отвечала бы «места хватит, права
        есть» — а спотыкалась установка уже на середине, когда откатывать нечего.
        ПРОБА НИЧЕГО НЕ СОЗДАЁТ (ревью ветки pkg-update, круг 2): прежний `mkdir -p` трёх каталогов стоял ДО снимка «что было»
        (_upload_all_files) — откат неудачной установки считал их прежними и не снимал никогда, а простой экран проверки при
        системе на пропавшем накопителе растил на флеше пустых двойников. Каталога ещё нет — пишем в ближайшего СУЩЕСТВУЮЩЕГО
        предка: права там и решают, создастся ли он. Проба живёт доли секунды, имя с префиксом enodia- (вне наших каталогов)."""
        dirs = " ".join(_shq(d) for d in self.install_dirs())
        r = self.router.run(
            f'for d in {dirs}; do a="$d"; while [ -n "$a" ] && [ ! -d "$a" ]; do a="${{a%/*}}"; done; '
            f't="${{a:-}}/.enodia-write-test.$$"; touch "$t" 2>/dev/null && rm -f "$t" || {{ echo "нет записи: ${{a:-/}}"; exit 1; }}; '
            f'done; echo ::WRITABLE::',
            silent=True).out
        # Метка, а не «OK» подстрокой: отказ печатает путь, а метка тома бывает BOOKS/TOKEN (ревью ветки, круг 3).
        return ("::WRITABLE::" in r.splitlines()), r

    def _payload_kb(self):
        # Сколько килобайт мы РЕАЛЬНО повезём на флеш: пакет кода РАСПАКОВАННЫМ (сам архив лежит в ОЗУ) плюс
        # бутстрап-бинари под арку роутера. Считаем по файлам, а не константой — константа протухла бы на первой
        # же новой подсистеме, причём в ту сторону, где гард бесполезен (пропустит установку, которой не хватит).
        # Отдаём ПАРУ: сумма (установка с нуля) и самый крупный файл (переустановка — см. _check_data_space:
        # pkg-install.sh кладёт <файл>.new рядом и лишь потом делает mv). Пакета нет — считаем без него: ставить
        # всё равно нечем, и это скажет preflight (мастеру — факт pkg_ok).
        pk = local_package()
        total = 0 if pk.get("error") else pk["raw_kb"] * 1024
        biggest = 0 if pk.get("error") else pk["big_kb"] * 1024
        for p in bootstrap_files(self.bin_arch())[0].values():
            sz = os.path.getsize(p)
            total += sz
            biggest = max(biggest, sz)
        return (total + 1023) // 1024, (biggest + 1023) // 1024

    def space_verdict(self):
        """ЕДИНСТВЕННЫЙ владелец ответа «влезет ли payload на НАШ том флеша».
        Возвращает (вердикт, free, total, biggest, reserve):
          none — не влезет даже крупнейший файл · tight — с нуля не хватает на весь payload ·
          near — влезет, но съест неснижаемый резерв · ok — влезет · unknown — не спросили df.
        ТРИ ПОРОГА, А НЕ ОДИН — потому что точного ответа «влезет ли» у нас НЕТ и быть не может:
        UBIFS СЖИМАЕТ, и наш payload (1.2 МБ одного panel.js текстом) ляжет заметно плотнее
        своего размера на ПК. Мерить сжатие с ПК нечем, вычитать du из df нельзя (см. карту проекта).
        Поэтому ОТКАЗЫВАЕМ только там, где безнадёжно арифметически, а «впритык» отдаём человеку
        решением: ложный отказ здесь хуже предупреждения — он останавливает установку, которая
        прошла бы. Переустановка считается по КРУПНЕЙШЕМУ файлу: upload пишет <файл>.up.tmp
        РЯДОМ и лишь потом mv, то есть лишним на флеше лежит ОДИН файл, а не вся пачка.
        Отдельным методом — потому что то же число показывает ЭКРАН мастера, а вторая копия
        этой арифметики дала бы два разных ответа про одно место (уже чинили в панели)."""
        # Ключ — точка монтирования, которую назвал РОУТЕР (OURMP), а не литерал «/data»:
        # на BE10000 наш том зовётся /data/usr, и по литералу гард получал бы промах ⇒ «место
        # узнать не удалось» ровно на той модели, где томов три и ошибиться легче всего.
        free = getattr(self, "disk_free_kb", {}).get(self.space_mp())
        total, biggest = self._payload_kb()
        reserve = data_reserve_kb()
        if free is None:
            return "unknown", None, total, biggest, reserve
        if free < biggest:
            return "none", free, total, biggest, reserve
        if self.awg_state != "INSTALLED" and free < total:
            return "tight", free, total, biggest, reserve
        if free < total + reserve:
            return "near", free, total, biggest, reserve
        return "ok", free, total, biggest, reserve

    def _check_data_space(self, dry=False, tight_ok=None):
        # ГАРД СВОБОДНОГО МЕСТА. Тестер 23.08.2026: на забитом под завязку /data установка
        # доходила до конца и рапортовала успех, а geo.sh и packages.sh на роутер не доезжали —
        # человек видел в панели «движок компонентов не установлен» и искал причину в панели.
        # Спросить df ДО заливки стоит один SSH-раунд, который мы всё равно уже сделали.
        verdict, free, total, biggest, reserve = self.space_verdict()
        # ИМЯ ТОМА — от роутера: те же числа под чужой подписью читаются как «он смотрит не туда».
        mp = self.space_mp()
        if verdict == "unknown":
            info(L(f"Свободное место на {mp} узнать не удалось — ставлю без проверки",
                   f"Could not read free space on {mp} — installing without that check"))
            return True
        if verdict == "none":
            err(L(f"На {mp} свободно {free} КБ, а самый крупный файл payload — {biggest} КБ.",
                  f"{mp} has {free} KB free, and the largest payload file is {biggest} KB."))
            info(L("  Не влезет даже он — пробовать бессмысленно.",
                   "  Not even that fits — there is no point in trying."))
            info(L("  Чем занят флеш и что можно снять (по SSH под root):",
                   "  What the flash is holding and what can go (over SSH as root):"))
            info(f"    du -xsk {mp}/* | sort -n | tail -15")
            info(L(f"    sh {ENODIA_BOOT}/boot.sh clean.sh dryrun   # если система уже стояла — покажет мусор",
                   f"    sh {ENODIA_BOOT}/boot.sh clean.sh dryrun   # if the system was installed before — lists the leftovers"))
            info(L("  Освободите место и повторите установку.", "  Free some space and run the installation again."))
            return False
        if verdict == "tight":
            warn(L(f"На {mp} свободно {free} КБ, а payload занимает {total} КБ (на ПК, без сжатия).",
                   f"{mp} has {free} KB free, and the payload takes {total} KB (on the computer, uncompressed)."))
            info(L("  UBIFS сжимает, так что шанс есть; не хватит — установка снимет положенное сама,",
                   "  UBIFS compresses, so it may still fit; if it does not, the installation removes what"))
            info(L("  и роутер останется таким, каким был.",
                   "  it placed on its own, and the router stays as it was."))
            info(L(f"  Надёжнее сперва освободить место: du -xsk {mp}/* | sort -n | tail -15",
                   f"  Freeing space first is safer: du -xsk {mp}/* | sort -n | tail -15"))
            # `dry` — это пункт меню «Pre-flight проверка (без изменений)»: там ПРОБОВАТЬ нечего,
            # и вопрос «всё равно пробовать?» был бы про действие, которого не будет. Проверке
            # принадлежит вердикт, вопрос — установке.
            if dry:
                return True
            # Мастер этот же вопрос задаёт ЭКРАНОМ и присылает ответ сюда готовым: у его
            # задания нет терминала, а спросить всё равно надо — решение тут не наше.
            if tight_ok is not None:
                info(L("  Решение принято в мастере: ", "  Decided in the wizard: ") +
                     (L("ставим", "installing") if tight_ok else L("не ставим", "not installing")))
                return bool(tight_ok)
            return confirm(L("Всё равно пробовать?", "Try anyway?"))
        if verdict == "near":
            warn(L(f"На {mp} свободно {free} КБ: payload {total} КБ + неснижаемый резерв {reserve} КБ — впритык",
                   f"{mp} has {free} KB free: payload {total} KB + a {reserve} KB reserve that cannot be used — only just"))
            info(L("  Поставится, но списки и обновление потом могут упереться в флеш.",
                   "  It will install, but the lists and later updates may hit the flash limit."))
            return True
        ok(L(f"Место на {mp}: {free} КБ свободно (payload {total} КБ + резерв {reserve} КБ)",
             f"Space on {mp}: {free} KB free (payload {total} KB + {reserve} KB reserve)"))
        return True

    def action_diagnose(self):
        section("Диагностика")
        section(f"Локально в {SCRIPT_DIR}")
        pk = local_package(refresh=True)
        if pk.get("error"):
            err(pk["error"])
        else:
            ok(f"Пакет кода {pk['version']} (код {pk['code']}): {pk['files']} файлов, {round(pk['size'] / 1024)} КБ — {pk['path']}")
        arch = self.bin_arch()
        info(f"Бутстрап-бинари: набор bin/{arch}/ (арка роутера); остальное качает панель")
        _bs_ready, _bs_skip = bootstrap_files(arch)
        for k in BOOTSTRAP_BINS:
            if k in _bs_ready:
                ok(f"{k} ({round(os.path.getsize(_bs_ready[k]) / 1024, 1)} KB)")
            elif _bs_skip.get(k) == "other":
                warn(f"{k} — не та сборка, что знает пакет кода (не повезу)")
            else:
                warn(f"{k} — нет (роутер останется без аварийного канала до GitHub)")
        print()
        if not self._preflight_remote():
            return
        # Каталоги спрашиваем У БУТСТРАПА: в режиме полной установки на накопитель ни кода, ни
        # настроек, ни бинарей на флеше НЕТ, и весь список ниже отвечал бы «не установлен» и
        # «каталог пуст» на живой системе.
        _rp = self.router_paths()
        D = _rp["dir"]; ST = _rp["state"]; BN = _rp["bin"]
        qD, qST, qBN = _shq(D), _shq(ST), _shq(BN)   # в команду роутера — в кавычках (пробел в точке монтирования законен)
        # Скрипты роутера спрашивают пути у окружения — без экспорта они ответили бы о
        # флеше, стоя на накопителе (см. renv).
        _re = self.renv()
        blocks = [
            # Диагностика идёт СВЕРХУ ВНИЗ по слоям: сперва то, что мы ставили (панель, файлы,
            # cron), и лишь потом сеть. Прежний список начинался с awg0 и handshake — на роутере,
            # где транспорт не выбран, это три экрана «(не поднят)» подряд, за которыми не видно
            # ЕДИНСТВЕННОГО, что здесь важно: жива ли панель.
            # Гард `-f`, а не `-x`: скрипт запускается через `sh`, биту исполнения тут веры нет —
            # снятый (после apply-scripts/копирования) он выдавал «не установлен» при живом файле,
            # то есть диагностика врала ФАКТОМ, а не отказом. Класс из батчей 5/10/13/15.
            ("Панель (uhttpd:8088)", _re + f"[ -f {qD}/web-ui.sh ] && sh {qD}/web-ui.sh status 2>&1 || echo '(web-ui.sh не установлен)'"),
            ("Версия на роутере", f"cat {qD}/VERSION 2>/dev/null || echo '(нет VERSION)'"),
            ("Транспорт", _re + f"if [ -f {qD}/transport.sh ]; then sh {qD}/transport.sh configured >/dev/null 2>&1; "
                          f"[ \"$?\" = 1 ] && echo 'не выбран (установка «только панель»)' || echo \"активен: $(cat {qST}/.transport 2>/dev/null)\"; "
                          f"echo \"готовы к включению: $(sh {qD}/transport.sh list 2>/dev/null | tr '\n' ' ')\"; else echo '(transport.sh не установлен)'; fi"),
            ("Статус подсистем", _re + f"[ -f {qD}/status.sh ] && sh {qD}/status.sh 2>&1 | head -40 || echo '(status.sh не установлен)'"),
            # Cron-строки и сниппеты dnsmasq — ТЕМИ ЖЕ ответами, какими их снимает удаление (`uninstall.sh ours`).
            # Свои регулярки здесь не знали строки подписок и сниппетов гео/групп (замер BE7000 30.09.2026: пять
            # строк cron из шести, два сниппета из шести, и один из них дважды — без имени каталога). Роутер старее
            # верба печатает usage с кодом 2 — тогда грубый срез по имени проекта, лишь бы не молчать.
            ("Cron и сниппеты dnsmasq (наши)", _re + f"_o=$(sh {qD}/uninstall.sh ours 2>/dev/null) && printf '%s\\n' \"$_o\" || "
                "{ echo 'cron:'; grep -F enodia /etc/crontabs/root 2>/dev/null; "
                "echo 'dnsmasq:'; ls -la /etc/dnsmasq.d/ /tmp/dnsmasq.d/ 2>/dev/null; }"),
            (f"Файлы в {D}", f"ls -la {qD}/ 2>/dev/null"),
            # Раскладка целиком: в каком режиме стоит система и где сейчас лежит код.
            ("Раскладка (режим накопителя)", f"[ -f {ENODIA_BOOT}/boot.sh ] && sh {ENODIA_BOOT}/boot.sh status 2>&1 || echo '(бутстрапа нет — установка старее фичи)'"),
            (f"Настройки в {ST}", f"ls -la {qST}/ 2>/dev/null"),
            (f"Бинари в {BN}", f"ls -la {qBN}/ 2>/dev/null"),
            ("Лог последнего heal.sh", "[ -f /tmp/enodia-startup.log ] && tail -15 /tmp/enodia-startup.log || echo '(enodia-startup.log нет)'"),
            # Том — по ПУТИ каталога: на BE10000 `/data` это ЧУЖОЙ стоковый том (4.7 МБ),
            # а наш код живёт на `/data/usr`. Подпись берём из самого df (последнее поле).
            ("Место на нашем томе", f"df -k {qD} 2>/dev/null | tail -1"),
        ]
        for title, cmd in blocks:
            section(title)
            print(self.router.run(cmd, silent=True).out)

    def action_diagdump(self):
        section("Выгрузка диагностики в файл (логи + состояние)")
        path, error = self.collect_diagdump()
        if error:
            err(error)
            return
        ok(f"Готово: {path}  ({round(os.path.getsize(path) / 1024, 1)} КБ)")
        info("Можно приложить к вопросу в чате сообщества — секреты уже замаскированы.")
        if confirm("Открыть файл сейчас?"):
            _open_file(path)

    def collect_diagdump(self):
        """Снять дамп с роутера в файл. Возвращает (путь, ошибка) — непустое ровно одно.
        ЕДИНСТВЕННАЯ реализация: её зовут и меню, и мастер; выбор «что секрет» — у роутера.
        """
        # Гоним ЛОКАЛЬНЫЙ dump.sh: stdin=base64(скрипта), команда='base64 -d | sh | base64'.
        # Двойной base64: вывод роутера UTF-8, а консольная кодировка могла бы его испортить;
        # base64 — чистый ASCII, декодируем БАЙТЫ на ПК. dump.sh маскирует секреты.
        dump = payload_file("dump.sh")
        if dump is None:
            return "", L(f"Ни в пакете кода, ни рядом со скриптом нет dump.sh ({SCRIPT_DIR}) — скачайте архив заново.",
                         f"There is no dump.sh in the code package or next to the script ({SCRIPT_DIR}) — download the archive again.")
        info(L("Снимаю состояние роутера (несколько секунд)...",
               "Capturing the router state (a few seconds)..."))
        raw = dump.decode("utf-8", "replace").replace("\r\n", "\n")
        b64in = base64.b64encode(raw.encode("utf-8")).decode("ascii")
        out = self.router.run(
            "printf '___AWGDUMP_BEGIN___\\n'; base64 -d | sh | base64; printf '___AWGDUMP_END___\\n'",
            stdin_data=b64in, silent=True).out
        if not out:
            return "", L("Пустой ответ от роутера (связь/SSH/пароль?).",
                         "Empty answer from the router (link / SSH / password?).")
        mm = re.search(r'(?s)___AWGDUMP_BEGIN___(.*?)___AWGDUMP_END___', out)
        b64out = re.sub(r'\s', '', mm.group(1)) if mm else re.sub(r'\s', '', out)
        try:
            data = base64.b64decode(b64out)
        except Exception:
            return "", L("Не удалось декодировать ответ роутера (ожидался base64). Связь оборвалась / старый busybox?",
                         "Could not decode the router answer (base64 expected). Link dropped, or an old busybox?")
        diag_dir = os.path.join(SCRIPT_DIR, "diag")
        os.makedirs(diag_dir, exist_ok=True)
        import datetime
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        out_file = os.path.join(diag_dir, f"enodia-diag-{ts}.txt")
        header = (
            "# Enodia — диагностический дамп\n"
            f"# собран: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  ПК -> {self.router.user}@{self.router_ip}\n"
            "# Ключи, endpoint и публичные IP замаскированы скриптом dump.sh.\n"
            "# ВСЁ РАВНО просмотрите файл перед публикацией — маскировка эвристическая.\n\n"
        )
        with open(out_file, "wb") as fh:
            fh.write(b"\xef\xbb\xbf")  # UTF-8 BOM, чтобы редакторы сразу увидели кодировку
            fh.write(header.encode("utf-8"))
            fh.write(data)
        return out_file, ""

    def _upload_all_files(self):
        D, S, B = self.install_dirs()
        section(L(f"Заливаю на роутер бутстрап и пакет кода ({D})",
                  f"Uploading the bootstrap and the code package to the router ({D})"))
        # ЧТО БЫЛО ДО НАС — чтобы неудача оставила роутер таким, каким он был (ревью ветки, круг 1): прежде на свежем роутере после
        # отказа установщика на флеше оставались созданные каталоги и стейдж-бинари, а экран «места впритык»
        # обещал, что роутер останется прежним. Снимаем ТОЛЬКО то, чего не было (_upload_undo).
        had = self.router.get("for d in " + " ".join(_shq(x) for x in (D, S, B)) + "; do [ -e \"$d\" ] && echo 1 || echo 0; done")
        self._had_dirs = [x.strip() == "1" for x in had.splitlines() if x.strip() in ("0", "1")][:3]
        if "OK" not in self.router.get(
                f"mkdir -p {_shq(D)} {_shq(D + '/bin')} {_shq(S + '/configs')} {_shq(B)} "
                f"&& chmod 700 {_shq(S)} && echo OK"):
            err(L(f"Не смог создать каталоги на роутере ({D} / {S} / {B})",
                  f"Could not create the directories on the router ({D} / {S} / {B})"))
            return False
        # Манифест бинарей (размеры, версии, суммы) отдельно больше НЕ возим: он едет В ПАКЕТЕ кода, под его подписью
        # (update-manifest.txt), и ложится в каталог кода вместе с ним — второй копии в настройках не бывает.
        # БУТСТРАП-БИНАРИ (byedpi/nfqws/hev, ~0.4 МБ). Прежде здесь жила арифметика «какой альт
        # везём, какой сносим ради места» — она ушла вместе с заливкой тяжёлых бинарей: их теперь
        # ставит панель («Компоненты»), она же и считает бюджет флеша (packages.sh plan). ПК
        # больше НИЧЕГО не сносит с роутера: снос — самое разрушительное, что делала установка,
        # и повод для него («не влезет») здесь больше не возникает.
        # Кладём в СТЕЙДЖ $ENODIA_DIR/bin/ ДО установщика: его забирает install.sh (он в пакете), а
        # pkg-install.sh файлов вне манифеста не касается.
        ready, skipped = bootstrap_files(self.bin_arch())
        for k, why in skipped.items():
            if why == "other":
                warn(L(f"  bin/{self.bin_arch()}/{k} — не та сборка, что знает пакет кода: не везу (останется прежняя копия, если была)",
                       f"  bin/{self.bin_arch()}/{k} is not the build the code package knows: not taking it (the previous copy stays, if any)"))
            else:
                warn(L(f"  локально НЕТ bin/{self.bin_arch()}/{k} — на роутере останется прежняя копия (если была)",
                       f"  bin/{self.bin_arch()}/{k} is MISSING locally — the router keeps the previous copy (if any)"))
        for k, local in ready.items():
            info(f"  -> bin/{k}")
            if not self.router.upload(local, f"{D}/bin/{k}"):
                err(L(f"Загрузка bin/{k} сорвалась", f"Uploading bin/{k} failed")); return False
        self.router.run(f"chmod +x {_shq(D)}/bin/*.user 2>/dev/null; true", silent=True)
        # configs/*.conf с ПК больше не возим: серверы (awg/vless/hy2) заводятся в панели, и это
        # единственное место, где они заводятся. Класть секреты рядом с установщиком незачем.
        # ПАКЕТ КОДА — в ОЗУ и распаковкой там же: на флеш ляжет только то, что поставит pkg-install.sh, и
        # оборванная заливка флеша не касается вовсе. Мерка места в ОЗУ — та же, что у апдейтера
        # (gh-update.sh::cmd_apply): текст жмётся примерно вчетверо, плюс запас.
        pk = local_package()
        if pk.get("error"):
            err(pk["error"]); return False
        need = pk["size"] * 6 // 1024 + 2048
        r = self.router.run(
            f"rm -rf {PKG_TMP}; mkdir -p {PKG_TMP}/root || exit 3; "
            f"f=$(df -k /tmp 2>/dev/null | awk 'NR==2{{print $4+0}}'); case \"$f\" in ''|*[!0-9]*) f=0 ;; esac; "
            f"[ \"$f\" -ge {need} ] && echo TMPOK || echo \"TMPLOW $f\"", silent=True)
        if "TMPOK" not in r.out:
            err(L(f"Под распаковку пакета в /tmp роутера нужно ≥ {need} КБ, а свободно меньше ({r.out.strip()})",
                  f"Unpacking the package in the router /tmp needs ≥ {need} KB, and less is free ({r.out.strip()})"))
            self.router.run(f"rm -rf {PKG_TMP}", silent=True)
            return False
        name = os.path.basename(pk["path"])
        info(f"  -> {name} ({round(pk['size'] / 1024)} KB) -> {PKG_TMP}")
        if not self.router.upload_data(pk["blob"], f"{PKG_TMP}/pkg.tar.gz", name):
            self.router.run(f"rm -rf {PKG_TMP}", silent=True)
            err(L(f"Загрузка {name} сорвалась", f"Uploading {name} failed")); return False
        r = self.router.run(f"tar -xzf {PKG_TMP}/pkg.tar.gz -C {PKG_TMP}/root && rm -f {PKG_TMP}/pkg.tar.gz && echo UNPACKED",
                            silent=True)
        if "UNPACKED" not in r.out:
            self.router.run(f"rm -rf {PKG_TMP}", silent=True)
            err(L(f"{name} не распаковался на роутере (мало памяти?)", f"{name} did not unpack on the router (low memory?)"))
            if r.out.strip():
                cprint(r.out, C.GRAY)
            return False
        ok(L("Бутстрап залит, пакет кода распакован в ОЗУ роутера", "Bootstrap uploaded, code package unpacked in the router RAM"))
        return True

    def run_followed(self, cmd, pidf, logf, wait, rcf=None, pre="", sync_note=""):
        """ДОЛГАЯ РАБОТА НА РОУТЕРЕ — ОТЦЕПЛЕННО, а ПК лишь СЛЕДИТ за ней. Возвращает
        {"started", "alive", "rc", "detached"}: `alive` — потолок `wait` вышел, а процесс жив (работа идёт, трогать её нельзя);
        `rc` — код из `rcf` (None — не записан или файла не просили).

        Почему не просто `run()`: обрыв Wi-Fi между ПК и роутером рвёт SSH-канал, а с ним — либо сам процесс (SIGHUP), либо только
        наше знание о нём. Установка кода глушит HUP и ДОРАБАТЫВАЕТ, а ПК получал код 255 и принимался «убирать за неудачей» — сносил
        источник пакета и стейдж-бинари из-под живого установщика (ревью ветки pkg-update, круг 2). Смена раскладки мастером
        жила тем же приёмом своей копией; теперь он один. Отцепляем тем же, что и CGI (`start-stop-daemon -S -b -m -p`: nohup/setsid
        в busybox нет, без пидфайла ждать было бы нечего). Инструмента нет — синхронно (страховка от обрыва, а не условие работы).
        СЛЕЖЕНИЕ ОТЛИЧАЕТ «кончился» от «роутер не ответил»: каждый опрос кончается меткой, и опрос без неё — обрыв связи, после
        которого ждём дальше (paramiko переподключается сам), а не объявляем работу законченной.
        `cmd` не содержит двойных кавычек: он уезжает внутрь `sh -c "…"`."""
        import time
        # `started`: True — запущен; False — роутер ответил, что НЕ запущен (убирать за собой можно); None — исход неизвестен
        # (роутер замолчал на старте): процесс мог уже работать, трогать нельзя ничего (ревью ветки, круг 3).
        res = {"started": None, "alive": False, "rc": None, "detached": False}
        # «Есть ли start-stop-daemon» — ответ yes|no. Молчание (обрыв) — не «нет»: синхронный запуск по рвущемуся каналу хуже всего.
        _sd = ""
        for _i in range(2):
            _sd = self.router.get("[ -x /sbin/start-stop-daemon ] && echo yes || echo no")
            if _sd in ("yes", "no"):
                break
        if _sd not in ("yes", "no"):
            return res
        detached = res["detached"] = _sd == "yes"
        if not detached and sync_note:
            warn(sync_note)
        inner = f"{cmd} > {logf} 2>&1" + (f"; echo \\$? > {rcf}" if rcf else "")
        start = self.router.run(
            pre + f"rm -f {pidf} {logf}" + (f" {rcf}" if rcf else "") + "; " +
            (f'start-stop-daemon -S -b -m -p {pidf} -x /bin/sh -- -c "{inner}"' if detached else f'sh -c "{inner}"'),
            silent=True, timeout=None if detached else wait)
        if detached and start.code != 0:
            # Отказ старта ≠ «не запустился»: канал мог оборваться ПОСЛЕ отцепления, и процесс уже работает. Один вопрос роутеру:
            # пидфайл или код есть — следим дальше; роутер молчит — исход неизвестен; ответил «ничего нет» — правда не запустился.
            _ev = self.router.get(f"[ -s {pidf} ] && echo ::P::; " + (f"[ -f {rcf} ] && echo ::P::; " if rcf else "") + "echo ::E::")
            if "::E::" not in _ev:
                return res
            if "::P::" not in _ev:
                res["started"] = False
                return res
        res["started"] = True
        seen = 0
        alive = True
        # Пидфайл `-b -m` пишет уже ОТЦЕПЛЕННЫЙ потомок, после возврата самой команды: «пидфайла нет» в первые мгновения —
        # «запускается», а не «кончился». С файлом кода это различимо до конца (кода нет — работа не кончилась); без него —
        # только паузой перед первым опросом, как было у смены раскладки.
        _nopid = f"[ -f {rcf} ] || echo '::ALIVE::'" if (rcf and detached) else ":"
        # ПОТОЛОК — ПО ЧАСАМ, а не по числу пауз: при обрыве связи каждый опрос сам стоит до 10–30 с (коннект, полуоткрытый TCP),
        # и счёт одних пауз растягивал 15 минут в полтора часа, всё это время мастер не закрыть (ревью ветки, круг 3).
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            time.sleep(2)
            # Хвост лога и жизнь процесса — ОДНИМ раундом, и порядок внутри важен: сперва «жив ли», потом хвост — иначе процесс
            # успел бы дописать строки между чтением и вопросом, а мы объявили бы прочитанное последним. Не get(): тот стрижёт
            # пробелы по краям, а установщик печатает строки с отступом.
            r = self.router.run(f'_rfp=$(cat {pidf} 2>/dev/null); if [ -z "$_rfp" ]; then {_nopid}; '
                                f'else kill -0 "$_rfp" 2>/dev/null && echo "::ALIVE::"; fi; '
                                f'sed -n "{seen + 1},\\$p" {logf} 2>/dev/null; echo "::POLL::"', silent=True, timeout=30).out
            if "::POLL::" not in r:
                continue            # роутер не ответил — это не «кончился»: ждём дальше
            alive = False
            for line in r.splitlines():
                if line == "::ALIVE::":
                    alive = True
                elif line != "::POLL::":
                    seen += 1
                    print(line)
            if not alive:
                break
        res["alive"] = alive
        if not alive and rcf:
            _rc = self.router.get(f"cat {rcf} 2>/dev/null")
            res["rc"] = int(_rc) if _rc.isdigit() else None
        return res

    def _run_installer(self):
        # INSTALL_PROTO=none — установка «только панель»: инсталлер разложит скрипты, cron и
        # панель, но НЕ активирует транспорт и не тронет маршрутизацию (см. PANEL_ONLY в
        # install.sh). Прочие режимы отсюда больше не запускаются: выбор протокола
        # переехал в браузер целиком, и второй способ его сделать означал бы второй набор граблей.
        # СТАВИТ ПАКЕТ ТОТ ЖЕ pkg-install.sh, что и обновление из панели (копия ИЗ пакета): он сверяет состав,
        # снимает снимок прежнего набора (на пустом роутере — «свежая установка», снимать нечего), заменяет по
        # файлу, снимает выпавшие и при сбое возвращает прежнее, а потом зовёт install.sh новой версии.
        section(L("Ставлю пакет на роутере (pkg-install.sh → install.sh, режим «только панель»)",
                  "Installing the package on the router (pkg-install.sh → install.sh, panel-only mode)"))
        # silent=True: вывод инсталлера печатаем МЫ, строкой ниже. Без него его печатает ещё и
        # Router.run на ненулевом коде — и в живом логе мастера весь прогон установщика двоился,
        # что читается ровно как «оно запустилось дважды». Замерено на AX3600 при отказе гарда
        # «прежняя версия рядом»: две одинаковые простыни подряд и никакого способа понять, один
        # это прогон или два. Код возврата ниже всё равно наш, а вопрос «пересохранить пароль?»
        # из Router.run здесь неуместен — до инсталлера мы уже авторизовались.
        # INSTALL_LANG — язык, который панель возьмёт ПО УМОЛЧАНИЮ (install.sh кладёт его в
        # .prefs и только если строки там ещё нет). Поставивший роутер английским мастером
        # ждёт английскую панель; в консольном режиме это ru, то есть прежнее поведение.
        # PKG_INSTALL_VERBOSE — вывод install.sh целиком в консоль человека, как было до пакета (в журнал
        # обновления панели он идёт одной строкой). Пути — явно: наследованию окружения SSH тут не верим.
        # ОТЦЕПЛЕННО (run_followed): обрыв связи с ПК установку не прерывает и не превращает в «неудачу», за которой ПК убирал бы
        # из-под живого установщика его источник. Лог, пидфайл и код — внутри PKG_TMP: снимаются вместе с ним, и ТОЛЬКО когда
        # установщик кончился. Код различает, что осталось на роутере (_upload_undo): 0 — готово; 3 — файлы новой версии уже на
        # месте, упал install.sh; прочее — ничего не заменено или прежний набор возвращён.
        # self._inst_rc: None — исход неизвестен (установщик жив после потолка или роутер не ответил): трогать нельзя ничего.
        D, S, B = self.install_dirs()
        res = self.run_followed(
            f"ENODIA_DIR={_shq(D)} ENODIA_STATE={_shq(S)} ENODIA_BIN={_shq(B)} ENODIA_BOOT={ENODIA_BOOT} "
            f"INSTALL_LANG={WIZARD_LANG} PKG_INSTALL_VERBOSE=1 sh {PKG_TMP}/root/pkg-install.sh install {PKG_TMP}/root",
            f"{PKG_TMP}/run.pid", f"{PKG_TMP}/run.log", PKG_INSTALL_WAIT, rcf=f"{PKG_TMP}/run.rc")
        self._inst_rc = res["rc"]
        if res["started"] is False:          # роутер ответил: не запущен (None — исход неизвестен, ниже: ничего не трогаем)
            err(L("Установщик на роутере не запустился", "The installer on the router did not start"))
            self.router.run(f"rm -rf {PKG_TMP}", silent=True)
            self._inst_rc = 1
            return False
        if res["alive"] or res["rc"] is None:
            # Не знаем, чем кончилось, — значит, ничего и не трогаем: ни источник пакета, ни стейдж, ни каталоги.
            warn(L("Установщик на роутере ещё работает (или роутер не ответил) — не прерываю и ничего не убираю",
                   "The installer on the router is still running (or the router did not answer) — not interrupting, not removing anything"))
            info(L("Проверьте снова через пару минут: повторная проверка скажет, закончилась ли установка.",
                   "Check again in a couple of minutes: the check will tell whether the installation has finished."))
            self._inst_rc = None
            return False
        self.router.run(f"rm -rf {PKG_TMP}", silent=True)
        if res["rc"] != 0:
            err(L(f"Установщик вернул код {res['rc']}", f"The installer returned code {res['rc']}"))
            return False
        return True

    def _upload_undo(self):
        """Неудача установки — снять то, что положил ПК, и ТОЛЬКО это: стейдж-бинари (их забирает install.sh, а до него дело не
        дошло) и каталоги, которых до нас не было (свежий роутер). Существовавшие каталоги не трогаем — там чужое и прежнее."""
        D, S, B = self.install_dirs()
        cmd = "rm -f " + " ".join(_shq(f"{D}/bin/{k}") for k in BOOTSTRAP_BINS) + "; "
        had = getattr(self, "_had_dirs", [True, True, True])
        for d, h in zip((D, S, B), had):
            if not h:
                cmd += f"rm -rf {_shq(d)}; "
        self.router.run(cmd + "true", silent=True)
        if not all(had):
            info(L("Роутер возвращён к виду до установки: созданные ею каталоги сняты.",
                   "The router is back to how it was: the directories the installation created are removed."))

    def router_busy(self):
        """Чем занят роутер из того, что запрещает ставить поверх: "upd" — обновление или откат из панели (ответ у апдейтера,
        `gh-update.sh upd-busy`); "pkg" — идёт установка кода (прежний запуск с ПК доработывает отцепленно, `pkg_install_alive`);
        "mode" — смена раскладки (`store_mode_alive`: переезд копирует и сносит те самые каталоги); "" — свободен.
        Установщик и сам откажет по своему локу, но ПОСЛЕ заливки: ПК к тому времени снёс бы источник пакета живого прогона
        (`rm -rf` PKG_TMP), подложил стейдж и каталоги в переезжающее дерево (ревью ветки pkg-update, круги 1–2). Причина нужна
        словами и ДО заливки. Ответы — у владельцев на роутере (daemon-lib.sh): библиотеку берём из установленного кода, а на
        свежем роутере — из пакета ещё идущего прогона; её нет или она старше вопросов — «свободен», как было."""
        D = self.install_dirs()[0]
        out = self.router.get(
            self.renv() +
            f'for _dl in {_shq(D + "/daemon-lib.sh")} {PKG_TMP}/root/daemon-lib.sh; do '
            f'if [ -f "$_dl" ]; then . "$_dl"; break; fi; done; '
            f'[ -f {_shq(D + "/gh-update.sh")} ] && sh {_shq(D + "/gh-update.sh")} upd-busy && echo UPD; '
            f'type pkg_install_alive >/dev/null 2>&1 && pkg_install_alive && echo PKG; '
            f'type store_mode_alive >/dev/null 2>&1 && store_mode_alive && echo MODE; '
            f'type uninstall_alive >/dev/null 2>&1 && uninstall_alive && echo UNINST; true')
        for word, why in (("UPD", "upd"), ("PKG", "pkg"), ("MODE", "mode"), ("UNINST", "uninst")):
            if word in out.split():
                return why
        return ""

    def busy_text(self, why):
        """«Роутер занят» словами — один текст на консоль, лог мастера и отказ снятия (экран проверки говорит своими строками)."""
        return {"upd": L("На роутере идёт обновление или откат из панели — дождитесь его конца и повторите",
                         "An update or a rollback from the panel is running on the router — wait for it to finish and retry"),
                "pkg": L("На роутере ещё идёт установка кода (прежний запуск) — дождитесь её конца и повторите",
                         "A code installation (an earlier run) is still going on the router — wait for it to finish and retry"),
                "mode": L("На роутере идёт смена раскладки (перенос на накопитель или обратно) — дождитесь её конца и повторите",
                          "A layout switch (moving to the drive or back) is running on the router — wait for it to finish and retry"),
                "code": L("На роутере идёт установка или обновление кода — снятие отменено, ничего не тронуто; дождитесь конца и повторите",
                          "A code installation or update is running on the router — the removal is cancelled, nothing was touched; wait for it to finish and retry"),
                "uninst": L("На роутере идёт снятие системы (отключение или полное удаление) — дождитесь его конца и повторите",
                            "The system is being removed on the router (turn-off or full removal) — wait for it to finish and retry"),
                }.get(why, why)

    def busy_err(self, why):
        err(self.busy_text(why))

    def _verify_install(self):
        # Проверяем ровно то, что установили: файлы на месте, cron заведён, панель поднимается.
        # Про несущую тут больше нет ни слова — её на этой установке нет по замыслу, и прежние
        # «handshake не пришёл»/«egress не прошёл» были бы не диагностикой, а пугалом.
        section(L("Проверка после установки", "Checks after installing"))
        miss = self.router.get(
            f"cd {_shq(self.install_dirs()[0])} 2>/dev/null && for f in web-ui.sh transport.sh heal.sh packages.sh "
            f"gh-update.sh uninstall.sh; do [ -f \"$f\" ] || echo \"$f\"; done; echo END")
        gone = [l for l in miss.splitlines() if l.strip() and l.strip() != "END"]
        if gone:
            err(L(f"На роутере НЕТ файлов: {', '.join(gone)} — payload доехал не целиком",
                  f"Files are MISSING on the router: {', '.join(gone)} — the payload did not arrive in full"))
        else:
            ok(L("Скрипты на месте (панель, оркестратор, heal, компоненты, апдейтер, удаление)",
                 "Scripts are in place (panel, orchestrator, heal, components, updater, uninstaller)"))
        # БУТСТРАП — цель каждой cron-строки. Проверяем ОТДЕЛЬНО от списка задач: строки в cron
        # могут стоять все до одной, но если файла, на который они смотрят, нет, после ребута не
        # поднимется ничего — и выглядеть это будет как «cron заведён, а система мертва».
        # ВЕРДИКТ — ПО ФАКТУ, А НЕ ПО НАЛИЧИЮ ФАЙЛА. Установка, обновлённая из панели до того,
        # как бутстрап появился в проекте, живёт с ПРЕЖНЕЙ формой строк (прямой путь в каталог
        # кода). Она рабочая, и кричать на неё «cron ссылается в пустоту» — врать тревожным
        # тоном о живой системе. Настоящая авария — строки ЗОВУТ бутстрап, а его нет.
        _bs = self.router.get(
            f"[ -f {ENODIA_BOOT}/boot.sh ] && echo HAVE || echo NONE; "
            f"grep -q {ENODIA_BOOT}/boot.sh /etc/crontabs/root 2>/dev/null && echo CRONBOOT || echo CRONOLD")
        if "HAVE" in _bs:
            ok(L("Бутстрап на месте (его зовёт cron, он же ищет накопитель)",
                 "The bootstrap is in place (cron calls it, and it finds the storage device)"))
        elif "CRONBOOT" in _bs:
            err(L(f"НЕТ {ENODIA_BOOT}/boot.sh — cron-строки ссылаются в пустоту, после ребута ничего не поднимется",
                  f"{ENODIA_BOOT}/boot.sh is MISSING — cron points nowhere, nothing will come up after a reboot"))
        else:
            warn(L("Бутстрапа нет: cron зовёт код напрямую (форма до сентября 2026). Работает, но раскладку",
                   "No bootstrap: cron calls the code directly (the pre-September-2026 form). It works, but the"))
            info(L("«всё на накопителе» так не включить — переустановите отсюда же или обновите из панели.",
                   "“everything on the drive” layout needs it — reinstall from here or update from the panel."))
        for job, label in (("heal.sh", L("восстановление после ребута", "recovery after a reboot")),
                           ("watchdog.sh", L("сторож", "the watchdog")),
                           ("web-ui.sh", L("подъём панели", "bringing the panel up"))):
            if "OK" in self.router.get(f"grep -qF {job} /etc/crontabs/root && echo OK || echo NONE"):
                ok(L(f"{job} в cron ({label})", f"{job} is in cron ({label})"))
            else:
                warn(L(f"{job} НЕ в cron ({label} не будет работать)",
                       f"{job} is NOT in cron ({label} will not work)"))
        # Транспорт спрашиваем у оркестратора, а не гадаем по файлам: «нет транспорта» — штатное
        # состояние этой установки, и увидеть его надо ровно так же, как его видят heal и сторож.
        if "NONE" in self.router.get(
                self.renv() + f"sh {_shq(self.code_dir())}/transport.sh configured >/dev/null 2>&1; "
                f"[ \"$?\" = 1 ] && echo NONE || echo SOME"):
            ok(L("Транспорт не активирован — роутер работает как сток (это и просили)",
                 "No transport is active — the router behaves as stock (which is what was asked)"))
        else:
            _st = self.router_paths()["state"]
            _tp = self.router.get(f"cat {_shq(_st)}/.transport 2>/dev/null") or "?"
            info(L(f"Активный транспорт: {_tp}", f"Active transport: {_tp}"))
        bins = self.installed_bins(("byedpi", "nfqws", "hev"))
        if bins:
            ok(L(f"Готово к работе без VPS: {', '.join(sorted(bins))} (десинк включается в панели)",
                 f"Ready to work without a VPS: {', '.join(sorted(bins))} (desync is switched on in the panel)"))
        else:
            warn(L("Бутстрап-бинарей нет — панель будет качать всё с GitHub напрямую",
                   "No bootstrap binaries — the panel will download everything from GitHub directly"))
        self.show_router_resources(L("Ресурсы роутера (после установки)", "Router resources (after installing)"))
    def panel_has_password(self):
        """Задан ли пароль панели — ответ роутера (`web-ui.sh haspass`, владелец пароля — totp.sh). Не ответил (или
        сборка старее верба) — False: тогда спрашиваем пароль, как на свежем роутере, — это безопасная сторона."""
        out = self.router.get(self.renv() + f"sh {_shq(self.code_dir())}/web-ui.sh haspass >/dev/null 2>&1 && echo HASPASS")
        return out.strip() == "HASPASS"

    def _finish_panel_setup(self):
        # ЕДИНСТВЕННЫЙ путь поднять панель после установки — и он ОБЯЗАТЕЛЬНЫЙ, а не «по желанию».
        # `web-ui.sh start` отказывается стартовать без файла пароля (`.panel-pass`), а его создаёт
        # только setpass: в payload его нет и быть не может (там пароль). Значит на свежем роутере
        # без этого шага панели не будет ВООБЩЕ — ни cron, ни heal.sh её не поднимут, им тоже
        # нечем. Раньше вопрос стоял за confirm с дефолтом «нет»: ответил не «y» — и получил
        # молчание вместо панели. Отсюда жалоба тестеров «поставил с ПК — панель не поставилась,
        # поставил её отдельным пунктом — встала сразу»: там пароль спрашивали безусловно.
        # …НО ПЕРЕУСТАНОВКА — не свежий роутер: пароль уже лежит в настройках и переживает её. Там Enter означает
        # «оставить прежний» (как кнопка мастера на обновлении), а прежнее «панель НЕ поднимется» было неправдой
        # на живой панели (замер меню cli на BE7000 30.09.2026). Судим ФАКТОМ роутера, а не памятью меню.
        if self.panel_has_password():
            pw = ask_new_panel_password(
                f"Новый пароль веб-панели (http://{self.router_ip}:8088; Enter — оставить прежний; ввод скрыт): ")
            if not pw:
                ok("Пароль панели прежний.")
                return True
        else:
            pw = ask_new_panel_password(
                f"Пароль веб-панели (http://{self.router_ip}:8088; ввод скрыт): ")
            if not pw:
                warn(f"Пароль не задан — панель НЕ поднимется. Задайте позже: меню -> «{MENU_ACCESS}» -> пароль панели.")
                return False
        # Проверяем ФАКТ, а не намерение. Вход по НОВОМУ паролю уже подтверждён внутри (HTTP-проба
        # ровно тем путём, которым пойдёт браузер) — второй раз то же самое не спрашиваем. TCP-проба
        # ниже осталась ради ДИАГНОСТИКИ отказа: все три причины «панели нет» (пароль не задан,
        # установщик оборвался выше секции панели, адрес br-lan не поднят) до неё выглядели одинаково.
        if self._apply_panel_password(pw):
            return True
        try:
            socket.create_connection((self.router_ip, 8088), timeout=5).close()
            info("Порт :8088 открыт — панель жива, но вход по НОВОМУ паролю она не подтвердила.")
        except Exception as e:
            warn(f"Пароль задан, но с ПК не достучаться до :8088 ({e}).")
            info("Проверьте: меню -> «Диагностика» -> Проверить, жива ли панель (там же перезапуск).")
        return False

    def action_install(self):
        # ЕДИНСТВЕННАЯ установка: веб-панель + вся обвязка + бутстрап-десинк. Транспорт НЕ
        # выбирается и НЕ активируется — протоколы, серверы, сайты, Wi-Fi и режимы человек
        # настраивает в браузере. Она же и «переустановить/починить»: идемпотентна, персист и
        # настройки не трогает (их владельцы — подсистемы на роутере, а не ПК).
        section("Установка веб-панели")
        cprint("  Поставлю: веб-панель :8088 + скрипты + cron (автозапуск, сторож, обновления).", C.GRAY)
        cprint("  Плюс десинк без VPS (ByeDPI/Zapret, ~0.4 МБ) — он же аварийный канал до GitHub.", C.GRAY)
        cprint("  ТРАНСПОРТ НЕ ВКЛЮЧАЕТСЯ: до вашего выбора роутер работает ровно как из коробки.", C.GRAY)
        cprint("  Всё остальное — протоколы, серверы, сайты, Wi-Fi — в браузере, в панели.", C.GRAY)
        if not confirm("Продолжить?"):
            warn("Отмена"); return
        done, stage = self.install_panel()
        if not done:
            err({"preflight": "Pre-flight не прошёл -- установка отменена",
                 "upload": "Загрузка файлов сорвалась — на роутере остались прежние версии",
                 "installer": "Инсталлер упал — смотрите вывод выше и меню «Диагностика»",
                 "running": "Установка на роутере ещё идёт — не прерываю; проверьте снова через пару минут"}[stage])
            return
        print()
        ok("Теперь пароль панели — без него она не отдаётся никому.")
        self._finish_panel_setup()
        print()
        ok("Готово. Дальше всё — в браузере.")
        info(f"Откройте панель: http://{self.router_ip}:8088 — панель спросит пароль формой.")
        info("Шаг 1 — карточка «Компоненты»: поставить нужные протоколы (качаются с GitHub).")
        info("Шаг 2 — карточка «Серверы»: перетащить vless://, hy2:// или awg-конфиг и включить.")
        info("Нет сервера и не нужен — включите десинк (ByeDPI/Zapret) там же, он работает без VPS.")

    def install_panel(self, tight_ok=None):
        """Установка панели БЕЗ единого вопроса: preflight → заливка → инсталлер → проверка.
        Возвращает (ok, стадия) — стадия и есть ответ «на чём споткнулись». Ядро общее для
        меню и мастера: порядок установки существует в одном экземпляре, спрашивают по-разному
        (консоль — confirm, мастер — экраном), а решение «место впритык» приезжает готовым."""
        if not self.preflight(tight_ok=tight_ok):
            return False, "preflight"
        if not self._upload_all_files():
            self._upload_undo()
            return False, "upload"
        if not self._run_installer():
            # Убираем за собой ТОЛЬКО когда установщик сказал, что роутер как был. Исход неизвестен (жив после потолка, роутер не
            # ответил) — не трогаем ничего: его источник и стейдж ещё нужны ему самому. Код 3 — файлы новой версии уже на месте и
            # install.sh мог завести cron: снести каталоги значило бы оставить cron-строки в пустоту; лечит повтор установки.
            if self._inst_rc is None:
                return False, "running"
            if self._inst_rc != 3:
                self._upload_undo()
            return False, "installer"
        self._verify_install()
        self.awg_state = "INSTALLED"
        self.refresh_summary()
        return True, "ok"

    def action_uninstall(self):
        """Удаление с роутера. СОБСТВЕННОЙ логики снятия здесь НЕТ — она живёт в
        uninstall.sh НА РОУТЕРЕ (единственная истина). Прежняя версия держала порядок
        снятия текстом прямо здесь и отстала от реальности на слоты, awgs0 «доступа
        домой», zapret/NFQUEUE, byedpi/xray/hev, второй uhttpd и цепочки PANEL_WAN —
        а заодно звала killall amneziawg-go (уносит VPN-сервер и слот-выходы разом) и
        флашила mangle PREROUTING вместе со СТОКОВЫМИ правилами Xiaomi."""
        section("Удаление с роутера")
        if not self._preflight_remote():
            err("Нет связи с роутером, удаление отменено"); return
        fresh, error = self.uninstall_refresh()
        if error:
            err(error); return
        if not fresh:
            warn("Удаление пойдёт ПРЕЖНЕЙ копией скрипта — она может не знать про часть подсистем")
            if not confirm("Продолжать с тем, что лежит на роутере?"):
                warn("Отмена"); return
        p = self.uninstall_plan()
        warn("Будет снято:")
        print("  - маркировка, ip rule/таблицы, цепочки вырезов и блокировок")
        print(f"  - несущая ({p.get('transport') or 'нет'}), доп-выходы: {p.get('slots', '?')}")
        if p.get("server"):
            print("  - «доступ домой» (VPN-сервер awgs0) — телефон в домашнюю сеть больше не зайдёт")
        if p.get("zapret"):
            print("  - Zapret (nfqws + NFQUEUE)")
        print(f"  - cron-строк: {p.get('cron', '?')}, ipset-сетов: {p.get('sets', '?')}")
        print("  - наши сниппеты dnsmasq (резолверы провайдера вернутся)")
        print()
        if not confirm("Продолжить"):
            warn("Отмена"); return
        # Бэкап настроек снимает САМА ПАНЕЛЬ (карточка «Резервная копия» — она же и умеет их
        # обратно ПРИМЕНИТЬ, чего файловая копия с ПК не умела никогда). Своей копии тут больше
        # нет: два бэкапа с разным охватом — это ровно тот случай, когда человек восстанавливает
        # не из того. Предупреждаем и даём выйти, пока панель ещё жива.
        info("Настройки сохраняются в самой панели: «Резервная копия» → скачать (там же и импорт).")
        if not confirm("Копия уже сделана (или не нужна)?"):
            warn("Отмена — сделайте копию в панели и вернитесь"); return
        print()
        info("Два варианта:")
        print("  1) Деактивация — снять VPN, файлы/настройки и панель ОСТАВИТЬ (можно вернуть)")
        print("  2) Полное удаление — то же + панель + стереть каталог (роутер станет стоковым)")
        full = confirm(f"Стереть ТАКЖЕ все файлы в {ENODIA_DIR} (вариант 2)?")
        if full and not confirm("Точно? Настройки, ключи и панель исчезнут безвозвратно"):
            warn("Отмена"); return
        self.uninstall_run(full)

    def uninstall_refresh(self):
        """Положить на роутер СВЕЖИЙ uninstall.sh и честно сказать, тот ли он там лежит.
        Возвращает (fresh, error); непустой error — снимать нечем, дальше идти нельзя.
        Ядро без единого вопроса: его зовут и меню, и мастер — спрашивают они по-своему,
        а «как снять систему» знает один uninstall.sh НА РОУТЕРЕ."""
        # Свежий uninstall.sh кладём ВСЕГДА: на роутере может лежать сборка, которая его
        # ещё не знает, а удалять надо тем, что знает про сегодняшний роутер.
        # РЕЗУЛЬТАТ ЗАЛИВКИ ПРОВЕРЯЕМ. Провал upload оставляет на роутере СТАРУЮ копию, а она
        # молча отстаёт ровно на то, чего в ней нет (слоты, awgs0, zapret, второй uhttpd) —
        # и снимет ПОЛОВИНУ системы, что хуже, чем не начать вовсе. Прежняя проба «в выводе
        # есть слово usage» такую копию пропускала: usage печатает и версия трёхмесячной
        # давности. Судим по ФАКТУ — сверяем md5 того, что ЛЕЖИТ на роутере, с локальным.
        # Байты — ИЗ ПАКЕТА: ровно их знают суммы установленного набора (.pkg-sums), и исходник поверх них
        # «Целостность» показала бы правкой на роутере. Пакета нет (архив неполный) — исходник рядом: снять
        # систему важнее, чем сверка сумм.
        # РОУТЕР ЗАНЯТ — ОТКАЗ ДО ЗАЛИВКИ (ревью ветки, круг 3). Через нас идут все три входа снятия (меню, план и снятие
        # мастера). Посреди установки или обновления кода uninstall.sh откажет и сам (un_gate), но мы бы уже переписали его
        # под идущим установщиком, а ответ «снялось не всё — перезагрузите роутер» звал бы ребут посреди установки.
        self.paths_forget()
        _busy = self.router_busy()
        if _busy:
            return False, self.busy_text(_busy)
        data = payload_file("uninstall.sh")
        fresh = False
        if data is not None:
            # Каталог — АКТИВНЫЙ: в режиме полной установки на накопитель код лежит не на
            # флеше, и свежая копия уехала бы мимо той, которую мы потом позовём.
            _cd = self.code_dir()
            if self.router.upload_data(data, f"{_cd}/uninstall.sh", "uninstall.sh"):
                self.router.run(f"chmod +x {_shq(_cd)}/uninstall.sh", silent=True)
                want = hashlib.md5(data).hexdigest()
                got = self.router.get(f"md5sum {_shq(_cd)}/uninstall.sh 2>/dev/null").split(" ")[0]
                fresh = bool(want) and got == want
                if not fresh:
                    warn(L("Залитый uninstall.sh на роутере не совпал с локальным (md5)",
                           "The uploaded uninstall.sh does not match the local one (md5)"))
            else:
                warn(L("Не удалось залить свежий uninstall.sh — на роутере осталась прежняя копия",
                       "Could not upload a fresh uninstall.sh — the router keeps the previous copy"))
        else:
            warn(L("Локального uninstall.sh нет — удалять буду тем, что уже лежит на роутере",
                   "No local uninstall.sh — removing with whatever already sits on the router"))
        # Вербы, которые мы реально позовём. Их отсутствие — отказ, а не предупреждение.
        _cd = self.code_dir()
        usage = self.router.get(self.renv() + f"sh {_shq(_cd)}/uninstall.sh 2>&1")
        if "deactivate" not in usage or "purge" not in usage:
            return False, L(f"На роутере нет рабочего {_cd}/uninstall.sh — обновите установку и повторите",
                            f"There is no working {_cd}/uninstall.sh on the router — update the installation and retry")
        return fresh, ""

    def uninstall_plan(self):
        """Что именно будет снято — спрашиваем У РОУТЕРА: там единственная истина, и она
        меняется вместе с подсистемами. Пустой словарь = ответ не разобрали."""
        plan = self.router.get(self.renv() + f"sh {_shq(self.code_dir())}/uninstall.sh plan")
        try:
            return json.loads(plan[plan.index("{"):plan.rindex("}") + 1])
        except Exception:
            return {}

    def uninstall_run(self, full):
        """Снять: purge (всё) или deactivate (VPN снят, панель и настройки остаются).
        Возвращает (ok, message) — вердикт ПО ФАКТУ, а не по намерению."""
        verb = "purge" if full else "deactivate"
        # Код возврата ЧЕСТНЫЙ (uninstall.sh проверяет результат по факту: что из цепочек, марок,
        # демонов, cron-строк и сниппетов dnsmasq пережило снятие). Раньше здесь печаталось
        # безусловное «VPN снят, интернет идёт напрямую» — и человек шёл искать причину куда
        # угодно, только не в отчёт.
        res = self.router.run(self.renv() + f"sh {_shq(self.code_dir())}/uninstall.sh {verb} 2>&1")
        if res.out:
            cprint(res.out, C.GRAY)
        if res.code == 4:
            # Отказ гарда снятия (un_gate): идёт установка или обновление кода, НИЧЕГО не тронуто. «Снялось не всё —
            # перезагрузите роутер» здесь звало бы ребут посреди живой установки (ревью ветки, круг 3).
            err(self.busy_text("code"))
            return False, self.busy_text("code")
        if full:
            left = self.router.get(f"[ -d {_shq(self.code_dir())} ] && echo LEFT || echo GONE")
            if "GONE" in left and res.code == 0:
                ok(L("Роутер вернулся к стоковому состоянию.", "The router is back to its stock state."))
                self.awg_state = "FRESH"
                self.router_summary = None
                return True, L("Роутер вернулся к стоковому состоянию.", "The router is back to its stock state.")
            if "GONE" in left:
                warn(L("Файлы стёрты, но часть обвязки пережила снятие — ПЕРЕЗАГРУЗИТЕ роутер",
                       "The files are gone, but part of the plumbing survived — REBOOT the router"))
                self.awg_state = "FRESH"
                self.router_summary = None
                return False, L("Файлы стёрты, но часть обвязки пережила снятие — перезагрузите роутер.",
                                "The files are gone, but part of the plumbing survived — reboot the router.")
            warn(L(f"{ENODIA_DIR} остался — проверьте вывод выше и отчёт /data/usr/enodia-uninstall.log",
                   f"{ENODIA_DIR} is still there — check the output above and /data/usr/enodia-uninstall.log"))
            return False, L(f"{ENODIA_DIR} остался — смотрите вывод и отчёт /data/usr/enodia-uninstall.log",
                            f"{ENODIA_DIR} is still there — see the output and /data/usr/enodia-uninstall.log")
        if res.code == 0:
            ok(L("VPN снят, интернет идёт напрямую. Файлы, настройки и панель на месте.",
                 "VPN is off, traffic goes directly. Files, settings and the panel are in place."))
            return True, L("VPN снят, интернет идёт напрямую. Панель и настройки на месте.",
                           "VPN is off, traffic goes directly. The panel and the settings are in place.")
        err(L("Снялось НЕ ВСЁ — что уцелело, сказано в строке «НЕ СНЯТО» выше",
              "NOT everything came off — what survived is listed in the line above"))
        warn(L("Повторите деактивацию; не помогло — перезагрузите роутер (правила живут в RAM)",
               "Run the deactivation again; if that does not help, reboot the router (the rules live in RAM)"))
        return False, L("Снялось не всё — что уцелело, сказано в строке «НЕ СНЯТО».",
                        "Not everything came off — what survived is listed in the output.")

    def _panel_accepts(self, pw, attempts=3):
        # Пустит ли панель по ЭТОМУ паролю — проба ровно тем путём, которым пойдёт браузер:
        # форма входа = POST в cgi-bin/login с CSRF-токеном (панель с 03.09.2026). Роутер старее —
        # нет cgi-bin/login (404) либо HTTP-Basic на всём (401 ещё на token) — прежняя Basic-проба.
        # True — пустила, False — пароль НЕ тот, None — вердикта нет (не достучались ИЛИ панель на
        # паузе после неудач — см. ветку `lock` ниже).
        # ПОБОЧНЫЙ ОТВЕТ — `self._panel_probe_legacy`: каким путём мы спрашивали. Он нужен
        # вызывающему, чтобы не перезапускать панель, которая читает пароль на КАЖДОМ входе:
        # для неё перезапуск ничего не меняет, зато вторая проба тратит ещё одну попытку в
        # пер-адресном счётчике неудач. Возвращать кортеж не стали: обоим вызывателям (оба — в
        # _apply_panel_password) нужен ровно вердикт, а путь спрашивает только один из них.
        self._panel_probe_legacy = False
        self._panel_probe_msg = ""
        # Пробная сессия тут же гасится (op=logout): иначе в «устройствах» панели повис бы Python.
        # Прокси гасим явно: с системным HTTP_PROXY urlopen ушёл бы наружу вместо LAN-роутера.
        import json as _json
        import time
        import urllib.parse
        import urllib.request
        import urllib.error
        base = f"http://{self.router_ip}:8088"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        form = {"Content-Type": "application/x-www-form-urlencoded"}
        legacy = False
        for i in range(attempts):
            try:
                with opener.open(base + "/cgi-bin/token", timeout=5) as resp:
                    tok = _json.loads(resp.read().decode("utf-8", "replace")).get("token", "")
                body = urllib.parse.urlencode({
                    # `remember: 0` — проверочной сессии длинный срок не нужен: её тут же гасят
                    # `op=logout`, но если тот не долетит (панель как раз перезапускается, обрыв),
                    # в списке устройств повиснет «Python-urllib» на ГОД. С нулём — на 12 часов.
                    "op": "login", "token": tok, "user": PANEL_USER, "remember": "0",
                    "pass": base64.b64encode(pw.encode("utf-8")).decode("ascii")}).encode("ascii")
                with opener.open(urllib.request.Request(base + "/cgi-bin/login", data=body, headers=form),
                                 timeout=8) as resp:
                    d = _json.loads(resp.read().decode("utf-8", "replace"))
                    cookie = (resp.headers.get("Set-Cookie") or "").split(";", 1)[0]
                if not d.get("ok"):
                    # Причину роутер называет словами («totp.sh старее формы входа», «логин у
                    # панели один», «неверный токен»), а наверх уезжал один голый False = «пароль
                    # не тот». Человек получал совет чинить не то. Текст запоминаем и печатаем.
                    self._panel_probe_msg = str(d.get("msg") or "")
                    # ПАУЗА ПОСЛЕ НЕУДАЧНЫХ ПОПЫТОК — ЭТО НЕ «ПАРОЛЬ НЕ ТОТ». Счётчик живёт на
                    # роутере (в /tmp) и перезапуск панели его не сбрасывает, а сменить пароль с ПК
                    # идут ровно после серии неудачных входов. Прежний код читал такой ответ как
                    # «не приняла»: перезапускал uhttpd и рапортовал провал ВЕРНОЙ смены пароля —
                    # человек шёл менять его снова. Признак машинный (`lock`), а не текст сообщения.
                    if d.get("lock"):
                        warn(L(f"Панель на паузе после неудачных попыток входа ({d.get('lock')} с) — "
                               "проверить новый пароль сейчас нельзя, он записан",
                               f"The panel is on hold after failed sign-ins ({d.get('lock')} s) — "
                               "the new password cannot be verified right now, but it is saved"))
                        return None
                    return False
                try:
                    out = urllib.parse.urlencode({"op": "logout", "token": tok}).encode("ascii")
                    opener.open(urllib.request.Request(base + "/cgi-bin/login", data=out,
                                                       headers=dict(form, Cookie=cookie)), timeout=5).close()
                except (OSError, ValueError):
                    pass
                return True
            except urllib.error.HTTPError as e:
                # 401 — ЕДИНСТВЕННЫЙ честный признак «панель старее формы входа»: Basic стоит на
                # всём, и до cgi-bin/token мы не доехали. А 404 на `login` бывает и у панели,
                # которую обновили НАПОЛОВИНУ (новый web-ui.sh поднял uhttpd без `-c`, старый web/
                # без CGI входа): Basic там уже снят, и прежняя проба «GET / вернул 200» отвечала
                # True НА ЛЮБОЙ пароль — «пароль ПРИНЯТ панелью» при том, что войти нельзя вовсе.
                # Поэтому 404 = «вердикта нет» (None), и человек читает про обновление панели.
                if e.code == 401:
                    legacy = True
                    self._panel_probe_legacy = True
                    break
                if e.code == 404:
                    self._panel_probe_msg = L("панель обновлена наполовину: cgi-bin/login не доехал",
                                              "the panel is half-updated: cgi-bin/login did not arrive")
                    return None
                if i + 1 < attempts:
                    time.sleep(1)
            except (OSError, ValueError):
                if i + 1 < attempts:
                    time.sleep(1)   # панель могла ещё не дослушать порт после рестарта
        if not legacy:
            return None
        # Панель старее формы входа: Basic сверяет сам uhttpd, спрашиваем его тем же заголовком.
        auth = base64.b64encode(f"{PANEL_USER}:{pw}".encode("utf-8")).decode("ascii")
        req = urllib.request.Request(base + "/", headers={"Authorization": "Basic " + auth})
        for i in range(attempts):
            try:
                with opener.open(req, timeout=5) as resp:
                    return 200 <= resp.status < 400
            except urllib.error.HTTPError as e:
                # 401 — единственный отказ ПО ПАРОЛЮ; 403/404/500 значат, что Basic уже пройден.
                return e.code != 401
            except OSError:
                if i + 1 < attempts:
                    time.sleep(1)
        return None

    def _apply_panel_password(self, pw):
        # Задать пароль веб-панели (форма входа) и поднять её. Пароль base64 на stdin (не в argv).
        # Общий код для интерактивной смены пароля и установки «только панель». Возврат True/False.
        b64 = base64.b64encode(pw.encode("utf-8")).decode("ascii")
        cmd = self.renv() + f'p=$(base64 -d); sh {_shq(self.code_dir())}/web-ui.sh setpass "$p" && sh {_shq(self.code_dir())}/web-ui.sh start'
        r = self.router.run(cmd, stdin_data=b64).out
        # МАССОВЫЙ ВЫХОД — ГРОМКО. `web-ui.sh setpass` вне панели гасит ВСЕ входы (пароль меняют
        # как раз тогда, когда боятся утечки), и роутер об этом говорит строкой. Она уезжала в
        # тишину: вывод роутера мы печатаем только при отказе — то есть более разрушительный из
        # двух вариантов человек не видел вовсе.
        if "разлогинен" in r:
            info(L("Все вошедшие устройства вышли из панели — на них она спросит новый пароль",
                   "Every signed-in device was signed out — the panel will ask them for the new password"))
        if not has(r, "поднят", "работает"):
            warn(L("Пароль задан, но панель не подтвердила старт. Вывод роутера:",
                   "The password was set, but the panel did not confirm it started. Router output:"))
            print(r)
            cprint(L(f"Проверить вручную по SSH: sh {_shq(self.code_dir())}/web-ui.sh status",
                     f"Check by hand over SSH: sh {_shq(self.code_dir())}/web-ui.sh status"), C.GRAY)
            return False
        # ВЕРДИКТ — ПО ФАКТУ ВХОДА, а не по выводу роутера. С формой входа файл пароля читается на
        # каждом входе и перезапуск не нужен; ветка «перезапускаю» ниже — для роутеров СТАРЕЕ
        # (Basic): там uhttpd читал хэш только при старте, и мы годами печатали «[ OK ] Пароль
        # задан» поверх старого пароля (поймано на железе 16.08.2026, AX3600).
        seen = self._panel_accepts(pw)
        # ПЕРЕЗАПУСК — ТОЛЬКО ДЛЯ ПАНЕЛИ С HTTP-Basic, и спрашиваем об этом пробу, а не гадаем.
        # У панели с формой входа хэш читается на КАЖДОМ входе: перезапуск исхода не меняет, зато
        # вторая проба тратит ещё одну попытку в пер-адресном счётчике неудач — и человек, пришедший
        # менять пароль ПОСЛЕ серии неудачных входов, получал паузу вместо ответа.
        restarted = False
        if seen is False and getattr(self, "_panel_probe_legacy", False):
            info(L("Панель ещё пускает по старому паролю (uhttpd читает его только при старте) — перезапускаю",
                   "The panel still accepts the old password (uhttpd reads it only at start) — restarting it"))
            self.router.run(self.renv() + f"sh {_shq(self.code_dir())}/web-ui.sh restart")
            restarted = True
            seen = self._panel_accepts(pw)
        if seen:
            ok(L(f"Пароль задан и ПРИНЯТ панелью: http://{self.router_ip}:8088",
                 f"Password set and ACCEPTED by the panel: http://{self.router_ip}:8088"))
            return True
        # ПРИЧИНУ, ЕСЛИ РОУТЕР ЕЁ НАЗВАЛ, печатаем в ОБЕИХ ветках: «панель обновлена наполовину»
        # приходит вместе с вердиктом None, и раньше терялась под общей фразой «не ответила либо
        # на паузе» — то есть единственный совет, который решал проблему, до человека не доезжал.
        _why = getattr(self, "_panel_probe_msg", "")
        if seen is None:
            # «Вердикта нет» — это ДВА разных случая, и про паузу после неудач `_panel_accepts` уже
            # сказал сам, отдельной строкой. Здесь поэтому не утверждаем «не ответила», а называем
            # оба: иначе после паузы человек читал бы про «проверь адрес и связь» при живой панели.
            warn(L(f"Пароль задан, но подтвердить вход не вышло: панель не ответила по "
                   f"http://{self.router_ip}:8088 либо на паузе после неудачных попыток",
                   f"The password was set, but the sign-in could not be confirmed: the panel did not "
                   f"answer at http://{self.router_ip}:8088, or it is on hold after failed attempts"))
            if _why:
                cprint(L(f"Ответ панели: {_why}", f"The panel answered: {_why}"), C.GRAY)
        else:
            # «Даже после перезапуска» говорим ТОЛЬКО когда перезапуск был, и судим по СВОЕМУ
            # флагу, а не по признаку пробы: тот сбрасывается на КАЖДОМ вызове, и после удачного
            # рестарта Basic-панели вторая проба уже идёт формой — факт рестарта терялся.
            if restarted:
                warn(L("Пароль записан, но панель по нему НЕ пускает даже после перезапуска — сообщите разработчику",
                       "The password was written, but the panel does NOT accept it even after a restart — please report this"))
            else:
                warn(L("Пароль записан, но панель по нему НЕ пускает — сообщите разработчику",
                       "The password was written, but the panel does NOT accept it — please report this"))
            if _why:
                cprint(L(f"Ответ панели: {_why}", f"The panel answered: {_why}"), C.GRAY)
        return False

    def action_set_panel_password(self):
        # Пароль веб-панели (форма входа) + поднять её. Пароль base64 на stdin (не в argv).
        section(f"Пароль веб-панели (http://{self.router_ip}:8088)")
        cprint(f"Панель управления VPN открывается в браузере: http://{self.router_ip}:8088.", C.GRAY)
        cprint("Пароль формы входа задаётся здесь. Забыли — просто задайте заново тут же.", C.GRAY)
        pw = ask_new_panel_password()
        if not pw:
            warn("Пустой пароль — отмена"); return
        self._apply_panel_password(pw)

    def action_open_panel(self):
        # Открыть веб-панель управления в браузере ПК. Печатаем адрес и проверяем, поднят ли uhttpd.
        url = f"http://{self.router_ip}:8088"
        section("Веб-панель управления")
        cprint(f"Адрес: {url}", C.CYAN)
        st = self.router.get(self.renv() + f"sh {_shq(self.code_dir())}/web-ui.sh status 2>/dev/null")
        if st:
            print(st)
        else:
            warn("Панель не подтвердила статус — возможно, не установлена/не запущена (см. «Перезапустить панель»).")
        try:
            import webbrowser
            if webbrowser.open(url):
                ok("Открываю в браузере...")
            else:
                info(f"Откройте вручную: {url}")
        except Exception as e:
            warn(f"Не удалось открыть браузер ({e}). Откройте вручную: {url}")

    def action_restart_panel(self):
        # Перезапуск uhttpd веб-панели (stop -> start). Rescue, когда панель зависла.
        section("Перезапуск веб-панели")
        if not self._preflight_remote():
            return
        out = self.router.run(self.renv() + f"sh {_shq(self.code_dir())}/web-ui.sh stop 2>/dev/null; sh {_shq(self.code_dir())}/web-ui.sh start").out
        if out:
            print(out)
        ok(f"Готово. Панель: http://{self.router_ip}:8088")

    def action_panel_alive(self):
        # Быстрая диагностика «жива ли панель»: роутер на связи -> uhttpd:8088 (на роутере + достучаться
        # с ПК) -> несущая VPN (есть ли default в table 1000). Замена полного статуса — панель :8088 живёт
        # отдельным uhttpd и от VPN-несущей НЕ зависит (потому «нет несущей» тут — не ошибка панели).
        section("Проверка: жива ли веб-панель")
        if not test_router_reachable(self.router_ip):
            err(f"Роутер {self.router_ip} недоступен по SSH (порт 22). Панель проверить нельзя.")
            return
        ok(f"Роутер {self.router_ip} на связи.")
        # Аптайм спрашиваем ТЕМ ЖЕ заходом. Зачем: сразу после перезагрузки панели закономерно ещё
        # нет — её поднимает heal.sh с cron'а (раз в минуту), и до этого «ЗАКРЫТ» означает «ещё не
        # успела», а не поломку. Без этой строки проверка выносила приговор и звала «Перезапустить
        # панель», то есть человек чинил то, что чинить не нужно (жалоба тестера 14.08.2026:
        # «после ребута панель отваливается, помогает перезапуск через батник»).
        st = self.router.get(
            self.renv() + f"sh {_shq(self.code_dir())}/web-ui.sh status 2>/dev/null; "
            "echo '---'; "
            "netstat -ln 2>/dev/null | grep -q ':8088 ' && echo 'PORT_8088: открыт' || echo 'PORT_8088: ЗАКРЫТ'; "
            "echo \"UPTIME: $(cut -d. -f1 /proc/uptime 2>/dev/null)\"")   # raw-uptime: спрашиваем РОУТЕР одной строкой (ПК роутерных библиотек не сорсит), и число идёт только в вердикт «панель ещё поднимается»
        up = -1
        if st:
            lines = []
            for ln in st.splitlines():
                if ln.startswith("UPTIME:"):
                    try:
                        up = int(ln.split(":", 1)[1].strip())
                    except ValueError:
                        up = -1
                    continue                       # служебная строка — на экран не выводим
                lines.append(ln)
            print("\n".join(lines))
        # Порог 180 с — не с потолка: панель поднимает первый же тик cron'а (до 60 с), а до неё heal
        # успевает пройти свои шаги. Замер на BE7000: uhttpd панели стартовал на 49-й секунде.
        boot_grace = (0 <= up < 180)
        # TCP-connect на :8088 прямо с ПК — то, что реально нужно браузеру.
        try:
            socket.create_connection((self.router_ip, 8088), timeout=4).close()
            ok(f"Порт 8088 доступен с ПК — панель: http://{self.router_ip}:8088")
        except Exception as e:
            if boot_grace:
                info(f"С ПК до :8088 пока не достучаться ({e}).")
                info(f"Роутер загрузился {up} с назад — панель поднимается автоматически в первую минуту после")
                info("загрузки. Подождите и повторите проверку; «Перезапустить панель» тут не нужно.")
            else:
                warn(f"С ПК не достучаться до :8088 ({e}). Панель не поднята? — «Перезапустить панель».")
        # Несущая VPN (одна строка): есть ли default-маршрут в table 1000.
        live = self.router.get(f"{SH_CARRIER_ROUTE} && echo LIVE || echo DOWN")
        if "LIVE" in live:
            ok("Несущая VPN: default в table 1000 есть — заблок-трафик идёт в туннель.")
        else:
            warn("Несущая VPN: default в table 1000 НЕ найден — сейчас прямой режим / fail-open (панели это не мешает).")

    # ФОЛБЭК-список логов наших скриптов в /tmp — только для роутера без clean.sh (совсем
    # старая установка). ЕДИНСТВЕННАЯ истина «какие логи мы пишем в ОЗУ» живёт на роутере:
    # `clean.sh ramlogs-list` (RAM_LOGS + пер-слотовые + тестерные). Свой перечень здесь
    # отставал от реальности на doh, subs-update, support, panel-tls, enodia-dnsq,
    # transport-awg-setup и на ВСЕ логи доп-выходов (замер 04.08.2026: девять живых логов
    # роутера просмотром с ПК не показывались вовсе). Маску /tmp/*.log брать по-прежнему нельзя:
    # рядом лежат стоковые логи Xiaomi (wifi_analysis, ssh_patch, *.bootcheck).
    # ИМЕНА — ОБЕИХ ЭПОХ, и это не перестраховка. Фолбэк работает ровно там, где владельца нет
    # (clean.sh не залит / старее верба `ramlogs-list`), то есть на роутере, который СТАРШЕ
    # префикса `enodia-` (02.09.2026): новые имена там ещё не пишутся, старые — уже. Спросить
    # роутер, какая у него эпоха, тут нечем — это и есть ветка «роутер не ответил».
    ROUTER_LOGS = ("enodia-startup", "enodia-watchdog", "enodia-switch-vpn-setup",
                   "enodia-iplist-update", "enodia-notify", "enodia-notify-event",
                   "enodia-byedpi", "enodia-hev", "enodia-hysteria", "enodia-zapret-nfqws",
                   "enodia-doh", "enodia-support", "enodia-subs-update", "enodia-panel-tls",
                   "xray", "xray-access",
                   "switch-vpn-setup", "iplist-update", "notify", "notify-event",
                   "byedpi", "hev", "hysteria", "zapret-nfqws", "doh", "support")

    def action_router_logs(self):
        # Тейл ключевых логов роутера (heal/watchdog/switch/iplist/notify + несущие + десинк, DoH,
        # подписки, доп-выходы). Нет файла — молча пропускаем. Полный /tmp — «Выгрузить диагностику».
        section("Логи роутера (/tmp/*.log — в RAM, обнуляются на перезагрузке)")
        if not self._preflight_remote():
            return
        n = ask("Сколько последних строк каждого лога [30]: ").strip() or "30"
        if not n.isdigit():
            n = "30"
        lst = self.router.get(self.renv() + f"[ -f {_shq(self.code_dir())}/clean.sh ] && sh {_shq(self.code_dir())}/clean.sh ramlogs-list")
        files = [ln.strip() for ln in lst.splitlines() if ln.strip().startswith("/tmp/")]
        if not files:
            info("clean.sh на роутере не ответил — беру встроенный список имён логов.")
            files = [f"/tmp/{b}.log" for b in self.ROUTER_LOGS]
        quoted = " ".join("'" + p.replace("'", "'\\''") + "'" for p in files)
        script = (
            f"N={n}\n"
            f"for f in {quoted}; do\n"
            "  [ -f \"$f\" ] || continue\n"
            "  echo \"===== $f (всего строк: $(wc -l < \"$f\" 2>/dev/null)) =====\"\n"
            "  tail -n \"$N\" \"$f\"\n"
            "  echo\n"
            "done\n"
        )
        print(self.router.run_script(script, silent=True).out)

    def action_pc_log(self):
        # Локальный лог программы на ПК (%APPDATA%\\enodia\\enodia.log). Ловит SSH/paramiko-сбои.
        section("Лог этой программы (на ПК)")
        if not os.path.isfile(LOG_FILE):
            info(f"Лог пока пуст / не создан: {LOG_FILE}")
            info("Трейсы пишутся всегда; для меток шагов запустите с ENODIA_DEBUG=1.")
            return
        cprint(f"Файл: {LOG_FILE}  ({os.path.getsize(LOG_FILE)} байт)", C.GRAY)
        n = ask("Сколько последних строк [40]: ").strip() or "40"
        if not n.isdigit():
            n = "40"
        try:
            with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
                tail = f.readlines()[-int(n):]
            print("".join(tail))
        except Exception as e:
            err(f"Не удалось прочитать лог: {e}")

    # ========================================================
    # Меню
    # ========================================================
    def submenu(self, title, items):
        # Подменю с локальной нумерацией (1..N + 0 назад). items: список (label, color, fn).
        while True:
            clear_screen()
            self.show_header()
            print()
            cprint(f"  {title}", C.WHITE)
            print()
            for i, (label, color, _fn) in enumerate(items, 1):
                cprint(f"  {i:>2}) {label}", color or C.GRAY)
            print()
            print("   0) Назад")
            print()
            sel = ask("Выбор: ").strip()
            if sel in ("0", ""):
                return
            if sel.isdigit() and 1 <= int(sel) <= len(items):
                items[int(sel) - 1][2]()
                print()
                ask("Enter — назад в подменю")
            else:
                warn("Нет такого пункта")

    def categories(self):
        # (title, mgmt, direct_fn_or_None, sub_fn_or_None). mgmt=True -> только при INSTALLED.
        # ПК-сторона ставит РОВНО панель и даёт к ней доступ. Всё остальное — протоколы, серверы,
        # сайты, Wi-Fi, режимы, обновления — живёт В ПАНЕЛИ, и второго способа это сделать нет
        # намеренно: два инструмента с одинаковой властью означают два набора граблей и вечный
        # вопрос «а где правда» (см. cli-installer-only-goal). Отсюда четыре пункта, а не двадцать.
        G, M, GR, CY = C.GREEN, C.MAGENTA, C.GRAY, C.CYAN   # мёртвые Y/R/DY убраны: цвет пункта меню задаётся только этими четырьмя
        return [
            ("Установить / переустановить веб-панель", False, self.action_install, None),
            ("Удалить с роутера", False, self.action_uninstall, None),
            (MENU_ACCESS, False, None, lambda: self.submenu(
                MENU_ACCESS, [
                    ("Открыть панель в браузере", G, self.action_open_panel),
                    ("Задать / сменить пароль панели", M, self.action_set_panel_password),
                    (f"Изменить IP-адрес роутера (сейчас: {self.router_ip})", M, self.action_set_router_host),
                    ("Изменить сохранённый пароль root (SSH)", None, self.action_change_password),
                    ("Произвольная команда на роутере (raw SSH)", GR, self.action_raw_ssh),
                ])),
            ("Диагностика", False, None, lambda: self.submenu(
                "Диагностика", [
                    ("Проверить, жива ли панель", CY, self.action_panel_alive),
                    ("Перезапустить панель", None, self.action_restart_panel),
                    ("Диагностика установки (файлы, cron, статус)", None, self.action_diagnose),
                    ("Показать логи роутера (heal/switch/watchdog/iplist/notify)", None, self.action_router_logs),
                    ("Выгрузить полную диагностику в файл", CY, self.action_diagdump),
                    ("Pre-flight проверка (без изменений)", GR, lambda: self.preflight(dry=True)),
                    ("Показать лог этой программы (на ПК)", GR, self.action_pc_log),
                ])),
        ]

    def startup(self):
        # Адрес роутера: при первом запуске спрашиваем, дальше применяем сохранённый.
        self.initialize_router_host()

        if not self.force_manage:
            if self.force_install:
                self.awg_state = "FRESH"
            else:
                section(f"Проверяю состояние роутера ({self.router_ip})")
                if not test_router_reachable(self.router_ip):
                    self.awg_state = "UNKNOWN"
                    self.unknown_reason = "offline"
                    info("Установка/управление невозможны, пока роутер не ответит — дождитесь загрузки или почините связь.")
                else:
                    self.awg_state = self.detect_awg_state()
                    if self.awg_state == "UNKNOWN":
                        self.unknown_reason = self.unknown_reason_from_router()
                        if self.unknown_reason == "negotiation":
                            warn("Роутер на связи, но SSH-сессия не согласована — несовместимый host key/шифр/KEX (старый dropbear).")
                            info(f"Обновите enodia.py до свежей версии; не помогло — пришлите лог: {LOG_FILE}")
                        else:
                            warn("Роутер на связи, но проверить установку не вышло — похоже, пароль не сохранён/неверен.")
                            info(f"В меню: «{MENU_ACCESS}» -> пароль root, затем «Диагностика».")
            if self.awg_state == "FRESH":
                warn("Панель на роутере не найдена (роутер свежий или систему сняли).")
                if confirm("Установить веб-панель сейчас?"):
                    self.action_install()
                else:
                    info("Ок — установка первым пунктом меню.")
            elif self.awg_state == "INSTALLED":
                ok("Панель установлена — открываю меню.")

        # Сводка в шапку (один раз за сессию) — пропускаем при UNKNOWN.
        self.router_summary = None
        if self.awg_state != "UNKNOWN":
            self.refresh_summary()
        return True

    def main_loop(self):
        while True:
            clear_screen()
            self.show_header()
            print()
            if self.awg_state != "INSTALLED":
                if self.awg_state == "UNKNOWN":
                    if self.unknown_reason == "negotiation":
                        warn("Роутер на связи, но SSH-сессия не согласована — несовместимый host key/шифр/KEX (старый dropbear).")
                        info("Обновите enodia.py до свежей версии; установка и управление заработают после входа.")
                        info(f"Если не помогло — пришлите лог: {LOG_FILE}")
                    elif self.unknown_reason == "auth":
                        warn("Роутер на связи, но войти по SSH не удалось — пароль не сохранён или неверен.")
                        info(f"Сначала «{MENU_ACCESS}» -> пароль root; установка заработает после входа.")
                    else:
                        warn("Роутер недоступен — нет сети, SSH закрыт или идёт перезагрузка.")
                        info("Установка и управление невозможны, пока роутер не ответит — дождитесь загрузки или почините связь.")
                        info("Сейчас осмысленны только: смена сохранённого пароля и локальная диагностика.")
                else:
                    warn("Веб-панель на роутере не установлена.")
                    info("Первый пункт меню поставит её; всё остальное настраивается уже в браузере.")
                print()
            visible = [c for c in self.categories() if (not c[1]) or (self.awg_state == "INSTALLED")]
            for i, c in enumerate(visible, 1):
                print(f"  {i:>2}) {c[0]}")
            print()
            print("   0) Выход")
            print()
            choice = ask("Выбор: ").strip()
            if choice == "0":
                return
            if choice.isdigit() and 1 <= int(choice) <= len(visible):
                cat = visible[int(choice) - 1]
                _title, _mgmt, direct, sub = cat
                if direct:
                    direct()
                    print()
                    ask("Enter — назад в меню")
                elif sub:
                    sub()
            else:
                warn("Нет такого пункта")

    def run(self):
        if not self.startup():
            return
        self.main_loop()


def parse_args(argv):
    # CLI-инсталлятор: только флаги режима. Управление конфигами (перетаскивание) переехало в
    # веб-панель — лишние аргументы просто игнорируем (не роняем запуск).
    force_install = force_manage = False
    for a in argv:
        if a in ("--install", "-Install", "/install"):
            force_install = True
        elif a in ("--manage", "-Manage", "/manage"):
            force_manage = True
        elif a in CLI_FLAGS:
            pass          # «текстовое меню»: мастер уже отсечён в wants_wizard, здесь флаг лишь известен
        elif a in ("-h", "--help"):
            print("Использование: python enodia.py [--cli|--install|--manage]")
            print("  без аргументов  — мастер установки в браузере (то же, что --wizard)")
            print("  --cli           — текстовое меню: диагностика и служебные операции")
            sys.exit(0)
    return force_install, force_manage


def _pop_host_override(argv):
    # Вынуть `--host <ip>` (алиас `--ip`) из argv — разовый оверрайд адреса роутера для --exec/--push
    # БЕЗ правки settings.json. Нужно для мульти-роутерной работы (BE7000 .1 + AX3600 .128 за ним):
    # settings.json держит ОДИН RouterIp, а флаг целит другой хост на ОДНУ команду. Флаг ищем в любой
    # позиции (можно до или после --push/--exec). Невалидный IP → ошибка (не молчим — иначе тихо
    # уедем на дефолтный хост и, например, зальём файл не на тот роутер). Возврат: (host|None, argv-без-флага).
    out = []; host = None; i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--host", "--ip"):
            if i + 1 >= len(argv):
                sys.stderr.write("[FAIL] --host требует IP-аргумент\n"); sys.exit(3)
            host = argv[i + 1]
            if not test_ip_string(host):
                sys.stderr.write(f"[FAIL] --host: неверный IP '{host}'\n"); sys.exit(3)
            i += 2; continue
        out.append(a); i += 1
    return host, out


def run_readonly_exec(argv):
    # НЕинтерактивный one-shot для скилла router-ssh / суб-агента диагностики: подключиться,
    # выполнить sh-скрипт на роутере, напечатать его вывод, выйти с кодом роутера. ЗАЧЕМ отдельно
    # от меню: старый рецепт (plink) на КАЖДОЕ чтение делал двухшаговый host-key (dropbear генерит
    # новый ключ на каждом ребуте → отпечаток не кэшируется), Start-Job с 35с-тайм-аутом и base64
    # через stdin от PS-кавычек — секунды и токены на простое `cat`. Здесь ОДИН paramiko-коннект
    # (AutoAddPolicy — host key не верифицируем, ключ после ребута принимается сам), скрипт через
    # run_script (base64 → без кавычек/CRLF/кириллицы). Возврат: НЕ вернёт при совпадении режима
    # (сам sys.exit с кодом роутера); False — режим не наш, main продолжает обычный запуск (меню).
    #
    #   py enodia.py --exec "sh /data/usr/app/enodia/status.sh"   # одна команда (argv)
    #   py enodia.py --exec-file diag.sh                            # многострочный скрипт из файла
    #   ... | py enodia.py --exec-stdin                             # скрипт из stdin
    #   py enodia.py --host 192.168.31.1 --exec-file diag.sh        # разовый оверрайд хоста (мимо settings.json)
    host_override, argv = _pop_host_override(argv)
    script = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--exec", "--ssh") and i + 1 < len(argv):
            script = argv[i + 1]; i += 2; continue
        if a in ("--exec-file", "--ssh-file") and i + 1 < len(argv):
            path = argv[i + 1]
            try:
                with open(path, "r", encoding="utf-8") as f:
                    script = f.read()
            except Exception as e:
                sys.stderr.write(f"[FAIL] не прочитать {path}: {e}\n"); sys.exit(3)
            i += 2; continue
        if a in ("--exec-stdin", "--ssh-stdin"):
            script = sys.stdin.read(); i += 1; continue
        i += 1
    if script is None:
        return False   # не наш режим — обычный запуск (меню/установка)
    host = host_override or load_router_host() or DEFAULT_ROUTER_IP
    pw = get_stored_password(host)
    if not pw:
        sys.stderr.write("[FAIL] пароль root не сохранён — запустите enodia.py и подключитесь один раз.\n")
        sys.exit(3)
    r = Router(host, password_provider=lambda: pw)
    try:
        res = r.run_script(script, silent=True)   # silent: без «SSH вернул код N» — печатаем чистый вывод скрипта
    finally:
        r.close()
    if res.code == 255 and not res.out.strip() and r.last_error_kind != "ok":
        sys.stderr.write(f"[FAIL] SSH ne podklyuchilsya k {host}: {r.last_error_kind}\n")
    # Вывод роутера — UTF-8. Пишем СЫРЫМИ байтами в stdout.buffer, минуя кодек консоли:
    # на ру-Windows консоль в cp1251, и sys.stdout.write падал бы UnicodeEncodeError на любом
    # не-cp1251 символе (напр. '→' из логов вотчдога). buffer гарантирует честный UTF-8 наружу.
    data = res.out
    if data and not data.endswith("\n"):
        data += "\n"
    buf = getattr(sys.stdout, "buffer", None)
    if buf is not None:
        buf.write(data.encode("utf-8", "replace")); buf.flush()
    else:
        sys.stdout.write(data)
    sys.exit(res.code if isinstance(res.code, int) else 0)


def run_check_archive(argv):
    # САМОПРОВЕРКА АРХИВА УСТАНОВЩИКА: `--check-archive` — полон ли этот каталог для установки БЕЗ СЕТИ. Её зовёт сборщик
    # релиза в распакованной копии архива (dev/build-release.py::check_setup), и спрашивает он ЭТОТ файл: что лежит рядом
    # и какие бинари нужны, знает читатель, а не сборщик. Сверяет: пакет кода (тот же разбор, что перед установкой), файлы
    # SETUP_FILES и бинари обеих арок — ровно те байты, суммы которых пакет везёт под подписью (bin-manifest.txt).
    # Код 0 — полон; 1 — нет, причины построчно. sys.exit при совпадении режима; False = не наш режим.
    if not argv or argv[0] != "--check-archive":
        return False
    bad = []
    pk = local_package()
    if pk.get("error"):
        bad.append(L("пакет кода: ", "code package: ") + pk["error"])
    # Не только «лежит ли», но и «запустится ли» (ревью ветки, круг 2: пустой файл, `.bat` с LF или BOM и `.sh` с CRLF
    # проходили): cmd на LF-батнике спотыкается о метки и `if`, BOM он читает командой, CR ломает shebang на mac/Linux.
    for rel in SETUP_FILES:
        try:
            with open(os.path.join(SCRIPT_DIR, rel), "rb") as fh:
                data = fh.read()
        except OSError:
            bad.append(L(f"нет {rel}", f"{rel} is missing")); continue
        if not data:
            bad.append(L(f"{rel} пуст", f"{rel} is empty"))
        elif rel.endswith(".bat") and (data.startswith(b"\xef\xbb\xbf") or data.count(b"\n") != data.count(b"\r\n")):
            bad.append(L(f"{rel}: нужен CRLF без BOM", f"{rel}: must be CRLF without a BOM"))
        elif rel.endswith((".sh", ".command", ".py")) and b"\r" in data:
            bad.append(L(f"{rel}: CR в файле — на mac/Linux не запустится", f"{rel}: has CR — will not run on mac/Linux"))
    # Материал мастера (WIZARD_ASSETS) отдаётся из web/assets — всё, что он отдаёт, обязано быть в архиве: иначе мастер
    # встаёт без стилей и шрифта, и заметит это только человек (связи списков больше нигде нет).
    for name in WIZARD_ASSETS:
        if f"web/assets/{name}" not in SETUP_FILES:
            bad.append(L(f"web/assets/{name} (WIZARD_ASSETS) не в SETUP_FILES", f"web/assets/{name} (WIZARD_ASSETS) is not in SETUP_FILES"))
    bm = package_member("bin-manifest.txt")
    if bm is None:
        bad.append(L("в пакете нет bin-manifest.txt — бинари сверить не с чем",
                     "the package has no bin-manifest.txt — nothing to check the binaries against"))
    nbin, known = 0, set()
    for ln in (bm or b"").decode("utf-8", "replace").splitlines():
        c = ln.split("\t")
        if ln.startswith("#") or len(c) < 5:
            continue
        rel = f"bin/{c[1]}/{c[0]}.user"
        known.add(rel)
        try:
            with open(os.path.join(SCRIPT_DIR, rel), "rb") as fh:
                data = fh.read()
        except OSError:
            bad.append(L(f"нет {rel}", f"{rel} is missing")); continue
        if str(len(data)) != c[2] or hashlib.sha256(data).hexdigest() != c[4]:
            bad.append(L(f"{rel} не совпал с манифестом пакета", f"{rel} does not match the package manifest")); continue
        nbin += 1
    # Лишнее в bin/ — не опасно (бутстрап сверяется с манифестом), но это признак сборки не по манифесту: сборщик кладёт
    # ровно его строки.
    for arch in BIN_ARCHES:
        try:
            extra = sorted(f"bin/{arch}/{n}" for n in os.listdir(os.path.join(SCRIPT_DIR, "bin", arch)))
        except OSError:
            extra = []
        for rel in extra:
            if rel not in known and bm is not None:
                bad.append(L(f"{rel} — нет в манифесте пакета", f"{rel} is not in the package manifest"))
    for arch in BIN_ARCHES:
        for rel in bin_files(arch).values():
            if rel.split("/")[-1] in BOOTSTRAP_BINS and not os.path.isfile(os.path.join(SCRIPT_DIR, rel)):
                bad.append(L(f"нет бутстрап-бинаря {rel}", f"bootstrap binary {rel} is missing"))
    if bad:
        for b in bad:
            print("[FAIL] " + b)
        sys.exit(1)
    print(f"[ OK ] {pk['version']} ({pk['code']}): {pk['files']} files, {len(SETUP_FILES)} setup files, {nbin} binaries")
    sys.exit(0)


def run_deploy(argv):
    # НЕинтерактивный деплой ТЕКСТОВОГО файла (sh/cgi/py/conf) на роутер: --push <local> <remote> [mode].
    # Тот же быстрый paramiko-путь, что и --exec (см. run_readonly_exec) — без pscp/host-key-танца.
    # Переиспользует Router.put_text: CRLF→LF (КРИТИЧНО для cgi/sh — иначе битый shebang на busybox),
    # атомарный .new+mv, chmod. MODE по умолчанию 755 (скрипты/CGI исполняемы; для секрет-конфига дай 600).
    # Только текст (бинари — через pscp/Router.upload). Несколько файлов — повтори --push. sys.exit при
    # совпадении режима; False = не наш режим (main идёт дальше в меню).
    host_override, argv = _pop_host_override(argv)
    if not argv or argv[0] not in ("--push", "--push-file", "--push-bin"):
        return False
    if len(argv) < 3:
        sys.stderr.write("[FAIL] использование: --push[-bin] <local> <remote> [mode]\n"); sys.exit(3)
    is_bin = (argv[0] == "--push-bin")   # бинарь (woff2/png/ELF): upload байт-в-байт, БЕЗ CRLF→LF
    local, remote = argv[1], argv[2]
    # Режим по умолчанию. У текста — 755 (скрипты и CGI исполняемы). А под `--push-bin` едут ДВА
    # разных груза: шрифты/картинки панели (им 644 верно) и ELF-бинари роутера, которым нужен +x —
    # иначе «залил, а оно не запускается», причём молча. Единого правильного дефолта тут нет, и
    # полагаться на память вызывающего («не забудь дописать 755») — ровно тот класс, что мы чиним.
    # Поэтому спрашиваем не расширение и не флаг, а САМ ФАЙЛ: сигнатуру ELF. Явный 4-й аргумент
    # по-прежнему главнее — им кладут секрет-конфиг под 600.
    mode = 755
    if is_bin:
        mode = 644
        try:
            with open(local, "rb") as fb:
                if fb.read(4) == b"\x7fELF":
                    mode = 755
        except Exception:
            pass
    if len(argv) >= 4 and argv[3].isdigit():
        mode = int(argv[3])
    content = None
    if not is_bin:
        try:
            with open(local, "r", encoding="utf-8") as f:
                content = f.read()
        except Exception as e:
            sys.stderr.write(f"[FAIL] не прочитать {local}: {e}\n"); sys.exit(3)
    elif not os.path.isfile(local):
        sys.stderr.write(f"[FAIL] не прочитать {local}: нет файла\n"); sys.exit(3)
    _host = host_override or load_router_host() or DEFAULT_ROUTER_IP
    pw = get_stored_password(_host)
    if not pw:
        sys.stderr.write("[FAIL] пароль root не сохранён — запустите enodia.py и подключитесь один раз.\n"); sys.exit(3)
    r = Router(_host, password_provider=lambda: pw)
    try:
        if is_bin:
            ok = r.upload(local, remote)
            if ok:
                r.run(f"chmod {mode} '" + remote.replace("'", "'\\''") + "'", silent=True)
        else:
            ok = r.put_text(remote, content, mode=mode)
            # ЗАЛИВКА КОДА — ЭТО СМЕНА ЭПОХИ ИМЁН. Штатно перенос имён в /tmp едет перед КАЖДЫМ
            # запуском цели (boot.sh::ram_mig), но точечный --push целей не запускает: до
            # ближайшего тика cron (<=1 мин) новый код соседствует с пидфайлами прошлой эпохи,
            # а демонов мы гасим СТРОГО по пидфайлу — промах означает неубиваемого сироту на
            # занятом порту. Зовём верб сами; best-effort, провал не должен ронять заливку.
            if ok:
                r.run(f"sh {ENODIA_BOOT}/boot.sh ram-migrate", silent=True)
    finally:
        r.close()
    msg = (f"OK {local} -> {remote} (mode {mode})\n" if ok else f"[FAIL] не залил {local} -> {remote}\n")
    (sys.stdout if ok else sys.stderr).buffer.write(msg.encode("utf-8"))
    sys.exit(0 if ok else 1)


# ============================================================
# МАСТЕР УСТАНОВКИ — локальный агент под браузер (--wizard)
# ============================================================
# ПОЧЕМУ АГЕНТ, А НЕ ПРОСТО СТРАНИЦА. Браузер сам по SSH не ходит и файлы на роутер не кладёт,
# поэтому UI живёт в браузере, а руки — здесь: тот же paramiko-слой, что у остального файла.
#
# ТРИ ГАРДА, без которых страницу выпускать нельзя (каждый закрывает свою дыру):
#  1. Слушаем ТОЛЬКО 127.0.0.1. На 0.0.0.0 мастер виден всей сети — а он ходит на роутер под root.
#  2. Токен. Localhost НЕ приватен: любая открытая вкладка может слать запросы на 127.0.0.1.
#  3. Гард Host. Защита от DNS-rebinding: чужой домен резолвится в 127.0.0.1, и браузер сам
#     отдаёт такому сайту наш ответ. Заголовок Host при этом остаётся ЧУЖИМ — на нём и ловим.
WIZARD_DIR = os.path.join(SCRIPT_DIR, "wizard")
WIZARD_TOKEN = ""       # заполняется на старте; пустой = сервер не поднимался
# Что из `web/assets` страница мастера берёт у панели (шаг 8b): стили и два шрифта, на которые они ссылаются. Список, а
# не каталог — разбор у do_GET; сверяет его с тем, что подключает страница, проверка C110.
WIZARD_ASSETS = {"panel.css": "text/css; charset=utf-8",
                 "inter-latin.woff2": "font/woff2",
                 "inter-cyrillic.woff2": "font/woff2"}


# Код железа → человеческое имя. Заводская морда китайской прошивки зовёт роутер
# «Xiaomi路由器BE7000» (замерено на живом BE7000), и показывать это человеку нельзя.
# АРКИ ЗДЕСЬ НЕТ СОЗНАТЕЛЬНО: её опознаёт роутер по e_machine своего busybox — второй
# источник правды об арке ровно тот случай, где ошибка кончается ENOEXEC и «[ OK ] установлен».
WIZARD_MODELS = {
    "RC06":  "Xiaomi BE7000",
    "RC01":  "Xiaomi BE10000",
    "RD15":  "Xiaomi BE3600 2.5G",
    "RN06":  "Xiaomi BE3600 2.5G",
    "RD16":  "Xiaomi BE3600 1G",
    "R3600": "Xiaomi AX3600",
}


def wizard_probe(ip, timeout=4):
    """Что видно о роутере ДО всякого доступа: отвечает ли, что за модель, открыт ли SSH.

    Спрашиваем заводскую морду БЕЗ пароля — эндпоинт init_info отдаёт hardware и romversion
    сам (замерено: RC06 / 1.1.38). Это и позволяет первому экрану показать ФАКТЫ, а не
    «нажмите далее». HTML-страница /cgi-bin/luci/web — фолбэк на случай прошивки, где JSON
    закрыт: там те же поля лежат в тексте (romVersion — camelCase, легко промахнуться).
    Зависимостей не добавляем: urllib из stdlib, а не requests — лишний пакет на ПК это
    лишний барьер ровно там, где мы его и убираем.
    """
    import re
    import urllib.request
    out = {"ip": ip, "web": False, "ssh": False, "alive": False, "model": "", "code": "",
           "firmware": "", "known": False, "error": ""}

    def _port(p, t=1.5):
        try:
            socket.create_connection((ip, p), timeout=t).close()
            return True
        except Exception:
            return False

    # ПОРТЫ СПРАШИВАЕМ ПЕРВЫМИ, и только потом HTTP. Замер 28.08.2026: на мёртвом адресе
    # (опечатка в последней цифре) четыре HTTP-попытки подряд висели ~20 секунд, и всё это
    # время человек смотрел на крутилку без единого слова. Три коротких TCP-пробы дают
    # ответ за 4-5 секунд И РАЗДЕЛЯЮТ два разных факта: «хост молчит» и «морда не ответила».
    out["ssh"] = _port(22)
    http_ok, https_ok = _port(80), _port(443)
    out["alive"] = out["ssh"] or http_ok or https_ok
    if not (http_ok or https_ok):
        return out
    # Прокси гасим явно: с системным HTTP_PROXY запрос ушёл бы наружу вместо LAN-роутера
    # (та же грабля, что у _panel_accepts).
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _get(url):
        return op.open(url, timeout=timeout).read().decode("utf-8", "replace")

    for scheme in (["http"] if http_ok else []) + (["https"] if https_ok else []):
        try:
            raw = _get(f"{scheme}://{ip}/cgi-bin/luci/api/xqsystem/init_info")
            info = json.loads(raw)
        except Exception as e:
            out["error"] = str(e)
            info = None
        if isinstance(info, dict) and info.get("hardware"):
            out["web"] = True
            out["error"] = ""
            out["code"] = str(info.get("hardware", "")).upper()
            out["firmware"] = str(info.get("romversion", "") or "")
            break
        try:
            page = _get(f"{scheme}://{ip}/cgi-bin/luci/web")
        except Exception as e:
            out["error"] = str(e)
            continue
        out["web"] = True
        out["error"] = ""
        m = re.search(r"hardware(?:Version)?\s*[:=]\s*'([^']+)'", page)
        if m:
            out["code"] = m.group(1).upper()
        m = re.search(r"romVersion\s*:\s*'([^']+)'", page)
        if m:
            out["firmware"] = m.group(1).strip()
        break
    if out["code"]:
        out["known"] = out["code"] in WIZARD_MODELS
        # Неизвестный код — НЕ отказ и не «не определилось»: показываем сам код. Модель, о
        # которой мы не знаем, всё равно может оказаться рабочей, а человеку есть что назвать
        # в чате. Врать «Xiaomi <код>» нельзя: под кодом бывает и Redmi.
        out["model"] = WIZARD_MODELS.get(out["code"], out["code"])
    return out


# ============================================================
# Мастер: ЗАДАНИЯ — одно за раз, вывод уезжает в браузер живьём
# ============================================================
# ПОЧЕМУ ЗАДАНИЕ, А НЕ ПРОСТО ОТВЕТ НА ЗАПРОС: всё, ради чего мастер и нужен, идёт десятками
# секунд (заливка 64 файлов, инсталлер, дамп), и человек обязан видеть ЖИВОЙ вывод, а не
# крутилку — ровно по той же причине, по которой вывод виден в консоли. Поэтому действие
# уходит в поток, его stdout ПЕРЕХВАТЫВАЕТСЯ, а страница забирает строки по мере появления.
#
# РЕАЛИЗАЦИИ ПРИ ЭТОМ ОБЩИЕ С МЕНЮ (install_panel, uninstall_run, collect_diagdump,
# _apply_panel_password): своей копии установки у мастера НЕТ. Две копии расходятся — это уже
# проверено на CLI-меню и панели, и второй раз мы за это платить не будем. Мастеру принадлежат
# только ДИАЛОГ (экраны) и РЕШЕНИЯ, которые он передаёт вниз явными параметрами.
WIZARD_JOB_LOCK = threading.Lock()
# `drop` — сколько строк уже ВЫБРОШЕНО из головы: страница нумерует строки СКВОЗНО, и без
# этого счётчика обрезка хвоста сбивала нумерацию. Замер: на выводе длиннее лимита лог в
# браузере ЗАМИРАЛ до конца задания (клиент просил строку 600, а список после обрезки всё
# время был длиной ровно 600 — «новых нет»), то есть человек терял вывод ровно на установке,
# где он единственный признак, что процесс жив.
WIZARD_JOB = {"name": "", "state": "idle", "lines": [], "result": {}, "drop": 0, "closing": False}
WIZARD_JOB_MAX = 600     # хвост лога в ОЗУ: он целиком уезжает в браузер на каждый опрос


class _WizardOut:
    """stdout задания. Строки уходят В БРАУЗЕР — и туда же, куда шли всегда: в enodia.log.
    ANSI-цвета режем: в консоли это цвет, в HTML — мусор вида «[32m»."""
    _ANSI = re.compile(r"\x1b\[[0-9;]*m")

    def __init__(self):
        self.buf = ""

    def write(self, s):
        self.buf += s
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            _wizard_line(self._ANSI.sub("", line).rstrip())
        return len(s)

    def flush(self):
        if self.buf:
            _wizard_line(self._ANSI.sub("", self.buf).rstrip())
            self.buf = ""

    def isatty(self):
        # Спрашивают перед тем, как что-то спросить у человека. У задания терминала НЕТ.
        return False


def _wizard_line(text):
    with WIZARD_JOB_LOCK:
        lines = WIZARD_JOB["lines"]
        lines.append(text)
        if len(lines) > WIZARD_JOB_MAX:
            cut = len(lines) - WIZARD_JOB_MAX
            del lines[:cut]
            WIZARD_JOB["drop"] += cut
    logdbg("wizard job: " + text)


def wizard_job_start(name, fn):
    """Запустить действие в фоне. ОДНО ЗА РАЗ: все задания ходят на ОДИН роутер по ОДНОМУ
    SSH-коннекту, и второе задание рвало бы первому канал посреди заливки. Возвращает
    (стартовали?, имя идущего). Мастер закрывается (/api/bye принят) — (False, ""): процесс вот-вот выйдет, и задание умерло
    бы посреди SSH; флаг ставится под этим же локом."""
    with WIZARD_JOB_LOCK:
        if WIZARD_JOB.get("closing"):
            return False, ""
        if WIZARD_JOB["state"] == "run":
            return False, WIZARD_JOB["name"]
        WIZARD_JOB.update({"name": name, "state": "run", "lines": [], "result": {}, "drop": 0})
    threading.Thread(target=_wizard_job_run, args=(name, fn), daemon=True).start()
    return True, name


def _wizard_job_run(name, fn):
    # ПОДМЕНА sys.stdout — ПРОЦЕССНАЯ, а не потоковая: пока задание идёт, В ЛОГ ЗАДАНИЯ уедет
    # всё, что напечатает ЛЮБОЙ поток. Для агента это безобидно (HTTP-потоки пишут в файл-лог,
    # а консоль в это время молчит) и ровно поэтому же задание может быть только одно.
    old = sys.stdout
    sys.stdout = _WizardOut()
    # ОДНА строка в НАСТОЯЩУЮ консоль на старте и на финише. Пока задание идёт, весь вывод
    # уезжает в браузер — и если браузер закрыли (а окно консоли осталось), человек видел бы
    # молчащее окно и решал, что мастер завис. Подробности всё равно в enodia.log.
    def _note(text):
        try:
            old.write(text + "\n")
            old.flush()
        except Exception:
            pass
    _note(L(f"[мастер] {name}: начал", f"[wizard] {name}: started"))
    try:
        res = fn() or {}
        state = "ok" if res.get("ok", True) else "fail"
    except Exception as e:
        # Трейс — В ЛОГ целиком, человеку — одна строка: разбирать чужой traceback на экране
        # мастера нечем, а в багрепорт приложат файл (та же логика, что у main()).
        import traceback
        logdbg(f"wizard job {name}:\n" + traceback.format_exc())
        msg = str(e) or e.__class__.__name__
        res, state = {"ok": False, "error": msg}, "fail"
        print(f"[FAIL] {msg}")
    finally:
        try:
            sys.stdout.flush()
        except Exception:
            pass
        sys.stdout = old
    with WIZARD_JOB_LOCK:
        WIZARD_JOB["result"] = res
        WIZARD_JOB["state"] = state
    # Отказ без `error` — ВЕРДИКТ экрана, а не сбой (проверка перед установкой: «ставить нельзя», причина — строками таблицы);
    # без этой отсылки консоль печатала «ОТКАЗ —» с пустотой (замер 30.09.2026).
    _why = str(res.get("error", "") or "") or L("причина — на экране мастера", "the reason is on the wizard screen")
    _note(L(f"[мастер] {name}: ", f"[wizard] {name}: ") +
          (L("готово", "done") if state == "ok"
           else L("ОТКАЗ — ", "FAILED — ") + _why))


def wizard_job_view(since=0):
    """Хвост лога, начиная со строки `since` в СКВОЗНОЙ нумерации (см. drop)."""
    with WIZARD_JOB_LOCK:
        lines, drop = WIZARD_JOB["lines"], WIZARD_JOB["drop"]
        start = since - drop
        # Клиент отстал сильнее, чем длина хвоста: часть строк он не увидит — и это честнее,
        # чем показать их повторно (в логе установки повтор читается как второй прогон).
        start = max(0, min(start, len(lines)))
        return {"name": WIZARD_JOB["name"], "state": WIZARD_JOB["state"],
                "lines": lines[start:], "next": drop + len(lines), "result": WIZARD_JOB["result"]}


# ============================================================
# Мастер: ДЕЙСТВИЯ. Каждое возвращает словарь с обязательным ok
# ============================================================
def wizard_app(state):
    """Один App на весь сеанс мастера: он держит SSH-коннект, кэш арки и состояние роутера.
    Пересоздавать его на каждый запрос — значит логиниться заново на каждый клик."""
    app = state.get("app")
    if app is None:
        app = App()
        state["app"] = app
    if state.get("host") and app.router_ip != state["host"]:
        app.set_router_host(state["host"])
    return app


def payload_version():
    """Версия СБОРКИ, которая лежит рядом со скриптом, — та самая, что поедет на роутер.

    ЭТО НЕ ВЕРСИЯ enodia.py. PROJECT_VERSION — номер ПК-утилиты, и сравнивать его с тем, что
    стоит на роутере, НЕЛЬЗЯ: там лежит номер из файла VERSION (payload). Замер 28.08.2026:
    экран «панель уже стоит» показал «на роутере 0.5.0-dev186, у меня 0.3.1» и звал обновиться
    — то есть предлагал откат туда, где номер просто про другое. Источник один: файл VERSION,
    тот же, что уезжает на роутер и по которому там работает downgrade-guard."""
    ver = code = ""
    fp = os.path.join(SCRIPT_DIR, "VERSION")
    try:
        with open(fp, "r", encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                ln = ln.strip()
                if ln.startswith("VERSION="):
                    ver = ln[8:].strip()
                elif ln.startswith("CODE="):
                    code = ln[5:].strip()
    except Exception:
        pass
    return ver, code


def wizard_router_state(app):
    """Что уже стоит на роутере: наша панель (владелец критерия — detect_awg_state), её
    версия и активный транспорт. Версию и транспорт берём ОДНИМ раундом."""
    app.awg_state = app.detect_awg_state()
    # PWRESET — «вернёт ли сток заводской пароль root на следующей загрузке». Спрашиваем РОУТЕР,
    # а не сверяемся с таблицей моделей: причина в прошивке, а не в имени, и второй список «где
    # так бывает» протух бы первым же новым роутером.
    #
    # СУДИМ ПО УСЛОВИЮ, А НЕ ПО НАЛИЧИЮ СТРОКИ. Первая версия считала вызовы `set_user` и на
    # BE7000 сказала «сбросится» — неправда: там тело функции закрыто гардом
    # `uci get xiaoqiang.common.INITTED != YES`, то есть пароль переустанавливается только на
    # заводски-чистом роутере, до первичной настройки. На AX3600 (замер 14.08.2026) того же
    # гарда НЕТ — set_user зовётся безусловно, и после ребута в /etc/shadow снова заводской хэш
    # (8 символов из серийника через `mkxqimage -I`). Разница решает: там смена пароля живёт до
    # первой перезагрузки, после которой сохранённый нами пароль не пускает ВООБЩЕ, а нового
    # человек не знает.
    #
    # Не смогли разобрать — отвечаем «сбросится». Ложное предупреждение стоит пропущенной смены
    # пароля (человек решает сам), ложное молчание — роутера, в который не войти.
    # ПУТИ — АКТИВНЫЕ, а не литералы флеша. Литералы врут ровно там, где система уехала на
    # накопитель: `installed` (его считает detect_awg_state по code_dir) сказал бы «панель есть»,
    # а версия и транспорт приехали бы пустыми — экран «панель уже стоит» показывал бы «?» и
    # предлагал обновиться на номер, которого не с чем сравнить. Тот же класс, что чинили
    # 01.09.2026 в router_paths(): у ПК есть ОДИН владелец ответа, и спрашивать надо его.
    probe = "D=" + _shq(app.code_dir()) + "\nST=" + _shq(app.router_paths()["state"]) + "\n" + r"""echo "VER $(sed -n 's/^VERSION=//p' "$D/VERSION" 2>/dev/null | head -1)"
echo "CODE $(sed -n 's/^CODE=//p' "$D/VERSION" 2>/dev/null | head -1)"
echo "TRANSPORT $(cat "$ST/.transport" 2>/dev/null)"
S=/etc/init.d/system
if [ ! -f "$S" ] || ! grep -qE '^[[:space:]]*set_user[[:space:]]*$' "$S"; then
  echo "PWRESET no"                       # некому переустанавливать пароль на буте
else
  body=$(sed -n '/^set_user()/,/^}/p' "$S")
  case "$body" in
    *INITTED*)
      if [ "$(uci -q get xiaoqiang.common.INITTED 2>/dev/null)" = "YES" ]; then
        echo "PWRESET no"                 # гард закрыт: роутер уже настроен, пароль переживёт ребут
      else
        echo "PWRESET yes"                # роутер ещё «заводской» — на буте пароль вернут
      fi ;;
    *) echo "PWRESET yes" ;;              # вызов без гарда (AX3600) — вернут ВСЕГДА
  esac
fi
"""
    out = app.router.run_script(probe, silent=True).out
    got = {}
    for ln in out.splitlines():
        p = ln.replace("\r", "").strip().split(None, 1)
        if p:
            got[p[0]] = p[1].strip() if len(p) > 1 else ""
    return {"installed": app.awg_state == "INSTALLED", "version": got.get("VER", ""),
            "code": got.get("CODE", ""), "transport": got.get("TRANSPORT", ""),
            "pw_resets": got.get("PWRESET", "") == "yes"}


def wizard_connect(app, state, ip, password):
    """Вход на роутер: адрес + пароль root. ТРИ ИСХОДА, и сливать их нельзя — «не отвечает»,
    «пароль не подошёл» и «зашли»: человек в первых двух видит одинаковый отказ, а лечатся
    они по-разному (адрес/доступ против пароля). Пароль кладём в то же хранилище, что и
    консоль (store_password) — второго места хранения у проекта нет."""
    if not test_ip_string(ip):
        return {"ok": False, "kind": "addr",
                "error": L("Адрес не похож на IPv4", "That does not look like an IPv4 address")}
    section(L(f"Вход на роутер {ip}", f"Signing in to the router at {ip}"))
    if ip != app.router_ip:
        app.set_router_host(ip)
    state["host"] = ip
    # ПАРОЛЬ СНАЧАЛА ПРОБУЕМ И ЛИШЬ ПОТОМ ХРАНИМ. Сохранить его до проверки значит затереть
    # РАБОЧИЙ пароль первой же опечаткой — и следующий запуск (хоть мастера, хоть меню) не
    # войдёт вообще, причём человек будет уверен, что пароль он ввёл правильный. Поэтому на
    # время пробы подменяем источник пароля, а хранилище трогаем только после успеха.
    if password:
        app.router.close()   # пароль подхватывается ТОЛЬКО новым коннектом
        app.router.password_provider = lambda: password
    try:
        if not (password or get_stored_password(ip)):
            return {"ok": False, "kind": "nopass",
                    "error": L("Пароль root не задан", "No root password has been set")}
        if not test_router_reachable(ip):
            err(L("SSH-порт 22 закрыт или роутер не отвечает",
                  "SSH port 22 is closed, or the router is not answering"))
            return {"ok": False, "kind": "net",
                    "error": L("Роутер не отвечает по SSH (порт 22). Доступ ещё не открыт либо адрес не тот.",
                               "The router does not answer over SSH (port 22). Access is not open yet, or the address is wrong.")}
        if "SSH_OK" not in app.router.run("echo SSH_OK", silent=True).out:
            kind = app.unknown_reason_from_router()
            err(L("Роутер во входе отказал", "The router refused the login"))
            return {"ok": False, "kind": kind,
                    "error": (L("Пароль root не подошёл", "The root password did not work") if kind == "auth" else
                              L("SSH-сессия не согласована (host key / шифр — старый dropbear). Пришлите лог.",
                                "The SSH session could not be negotiated (host key / cipher — old dropbear). Please send the log."))}
    finally:
        # Возвращаем штатный источник пароля в ЛЮБОМ исходе: лямбда переживала бы отказ и
        # держала бы неверный пароль до конца сеанса.
        if password:
            app.router.password_provider = app.ensure_password
    # Хранилище трогаем ТОЛЬКО после удачного входа — и пароль, и адрес: иначе опечатка
    # становится значением по умолчанию для следующего запуска.
    if password:
        store_password(password, ip)
    save_router_host(ip)
    ok(L("Вошли на роутер по SSH", "Signed in to the router over SSH"))
    st = wizard_router_state(app)
    pv, pc = payload_version()
    # Вошли ЗАВОДСКИМ паролем? Экран «Смените пароль root» говорит «сейчас у роутера пароль по умолчанию» — и после
    # доступа, открытого с новым паролем, звал сменить его второй раз (ревью шага 8b, круг 3). Страница его показывает
    # ТОЛЬКО при заводском.
    used = password or get_stored_password(ip) or ""
    st.update({"ok": True, "kind": "ok", "ip": ip, "payload_version": pv, "payload_code": pc,
               "pw_default": used == PATCHER_DEFAULT_PW})
    if st["installed"]:
        info(L(f"На роутере уже стоит панель (версия {st['version'] or '?'})",
               f"The panel is already installed on the router (version {st['version'] or '?'})"))
    else:
        info(L("Панели на роутере нет — это установка с нуля",
               "There is no panel on the router — this is a fresh install"))
    return st


# «Есть ли у роутера интернет» — вопрос ДВУХ фактов, и сливать их нельзя: панель потом сама
# качает протоколы с GitHub (нужен и маршрут, и резолв). ICMP до 1.1.1.1 отвечает на первый,
# nslookup — на второй; при мёртвом DNS роутер «в сети», но компоненты не поставятся.
WIZARD_NET_PROBE = r"""ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && echo "NET yes" || echo "NET no"
nslookup github.com >/dev/null 2>&1 && echo "DNS yes" || echo "DNS no"
"""


def wizard_facts(app, state):
    """Числа, по которым человек решает «ставить ли»: модель, арка, место, каталог, интернет.
    Тестер 23.08.2026 получил «успех» на забитом /data и пошёл искать причину в панели —
    потому что цифру места ему никто не показал. Своей арифметики здесь НЕТ: каждое число
    берём у владельца (bin_arch · show_router_resources · space_verdict · dir_writable ·
    detect_awg_state), иначе экран и консоль дадут два разных ответа про одно место."""
    section(L("Проверка перед установкой", "Checks before installing"))
    # «Проверить снова» обязана СПРОСИТЬ РОУТЕР ЗАНОВО, а не пересказать кэш сеанса. Раскладку
    # могли сменить ИЗ ПАНЕЛИ — ровно туда этот экран и отправляет («панель → «Накопитель» →
    # «Вернуть код и настройки на роутер»»), — и, вернувшись, человек получал ПРЕЖНИЙ отказ:
    # кэш `_paths` живёт весь сеанс и о чужой смене раскладки не знает. Замерено на живом BE7000
    # 02.09.2026: код уже переехал на флеш (режим bins), а экран проверки по-прежнему писал
    # «система живёт на накопителе» и держал кнопку выключенной — то есть совет мастера вёл в
    # тупик. Сбрасываем через владельца (paths_forget), как и в двух других местах; C66 сверяет,
    # что поле трогают только им.
    app.paths_forget()
    # Пакет кода — ДО чисел места: они считаются по нему. «Проверить снова» спрашивает заново: в рабочей копии
    # исходники могли поменяться, а человек мог докачать архив.
    pk = local_package(refresh=True)
    if pk.get("error"):
        err(pk["error"])
    st = wizard_router_state(app)
    arch = app.bin_arch()
    app.show_router_resources(L("Ресурсы роутера (до установки)", "Router resources (before installing)"))
    verdict, free, total, biggest, reserve = app.space_verdict()
    writable, raw = app.dir_writable()
    _dD, _dS, _dB = app.install_dirs()
    if not writable:
        err(L(f"{_dD} / {_dS} / {_dB}: не записывается — SSH под не-root?",
              f"{_dD} / {_dS} / {_dB}: not writable — is the SSH session root?"))
        if raw.strip():
            print(raw.strip())
    net = app.router.run_script(WIZARD_NET_PROBE, silent=True).out
    # ПРЕЖНЯЯ УСТАНОВКА РЯДОМ (до ребрендинга каталог звался /data/usr/app/awg). install.sh
    # откажется ставиться поверх неё — две копии дерутся за одни iptables и cron. Спросить об
    # этом НАДО ЗДЕСЬ, а не там: иначе мы сперва везём ~5 МБ на 20-МБ флеш, где уже лежит старая
    # копия, и только потом говорим «нельзя» — то есть тратим место ровно там, где его нет.
    # Замерено на AX3600: экран проверки при живом /data/usr/app/awg спокойно писал «Панели ещё
    # нет, установка с нуля». Критерий БЕРЁМ ТОТ ЖЕ, что у install.sh (файл ИЛИ живая cron-строка);
    # своей копии условия не заводим — разошлись бы на первой же правке.
    # Спрашиваем ТЕМ ЖЕ методом, что и меню: он и отвечает «блокирует ли», и печатает, чем это
    # снимается — печатает в лог мастера, то есть человек видит причину там же, где видит отказ.
    # Своего вопроса и своего текста здесь не заводим: разошлись бы на первой же правке.
    legacy = app.legacy_install_blocks()
    # СИСТЕМА НА НАКОПИТЕЛЕ — ТОЖЕ ОТКАЗ, и спросить о нём надо ЗДЕСЬ. Прежде экран проверки о
    # раскладке не знал: он зеленел, кнопка «Установить» включалась, и человек узнавал правду
    # только из лога установки — после клика по кнопке, которая делать этого была не должна.
    # Спрашиваем ТЕМ ЖЕ методом, что и preflight (store_install_blocks): он и отвечает
    # «блокирует ли», и печатает в лог, чем это снимается. Своего условия не заводим — оно
    # разошлось бы с настоящим гардом на первой же правке (тот же довод, что у legacy выше).
    store_blocked = app.store_install_blocks()
    _sp = app.router_paths()
    busy = app.router_busy()
    if busy:
        app.busy_err(busy)
    probe = state.get("probe") or {}
    facts = {
        "ip": app.router_ip,
        "model": probe.get("model", ""), "known": bool(probe.get("known")),
        "firmware": probe.get("firmware", ""),
        "arch": arch, "arch_label": "ARM64" if arch == "arm64" else "ARMv7",
        "space": verdict, "free_kb": free, "payload_kb": total, "peak_kb": biggest,
        "reserve_kb": reserve,
        # Имя тома — от роутера (OURMP, его же кладёт show_router_resources выше). Без него
        # экран подписывал числа литералом «/data», а на BE10000 наш том зовётся /data/usr:
        # числа верные, подпись чужая — и человек ищет место не там, где оно кончилось.
        "mount": app.space_mp(),
        "writable": writable, "dir": _dD,
        "net": "NET yes" in net, "dns": "DNS yes" in net,
        "installed": st["installed"], "version": st["version"], "transport": st["transport"],
        "legacy": legacy, "legacy_dir": LEGACY_DIR,
        # Раскладка: `store` = ставить нельзя, `store_mode` объясняет почему («full» — система
        # уехала на накопитель, «none» — уехала, а накопителя нет), `store_dir` — где она сейчас.
        "store": store_blocked, "store_mode": _sp.get("mode", ""), "store_dir": _sp.get("dir", ""),
        # Роутер занят тем, поверх чего ставить нельзя: "upd" | "pkg" | "mode" | "" (разбор у App.router_busy).
        "busy": busy,
        "payload_version": payload_version()[0],
        # Пакет кода рядом (см. local_package): нет или битый — ставить нечем, и экран называет причину.
        "pkg_ok": not pk.get("error"), "pkg_why": pk.get("error", ""),
    }
    ok(L("Проверка закончена", "Checks finished"))
    return {"ok": verdict != "none" and writable and not legacy and not store_blocked and not busy and not pk.get("error"),
            "facts": facts}


def wizard_install(app, tight_ok):
    """Установка панели. Ядро — общее с меню (install_panel); решение «место впритык»
    приезжает сюда ГОТОВЫМ с экрана: в консоль мастер вопросов не задаёт."""
    section(L("Установка веб-панели", "Installing the web panel"))
    done, stage = app.install_panel(tight_ok=tight_ok)
    if not done:
        return {"ok": False, "stage": stage, "error": {
            "preflight": L("Проверка перед установкой не прошла — установка не начиналась",
                           "The pre-install checks did not pass — the installation never started"),
            "upload": L("Заливка файлов сорвалась — на роутере остались прежние версии",
                        "The upload failed — the router keeps the previous versions"),
            "installer": L("Установщик на роутере вернул ошибку",
                           "The installer on the router returned an error"),
            "running": L("Установка на роутере ещё идёт — мастер её не прерывает; проверьте снова через пару минут",
                         "The installation on the router is still running — the wizard does not interrupt it; check again in a couple of minutes"),
        }.get(stage, L("Установка не прошла", "The installation did not go through"))}
    return {"ok": True, "stage": "ok", "url": f"http://{app.router_ip}:8088"}


def wizard_panel_password(app, pw):
    """Пароль веб-панели. Правило формы — ОДНО с консолью (PANEL_PW_RE, там же «почему»)."""
    section(L("Пароль веб-панели", "Web panel password"))
    if not re.match(PANEL_PW_RE, pw or ""):
        return {"ok": False, "error": panel_pw_hint()}
    if app._apply_panel_password(pw):
        # Заодно спрашиваем про накопитель: следующий экран (выбор раскладки) существует
        # ТОЛЬКО когда роутер видит флешку, а показывать его пустым и тут же уводить дальше
        # значит мигнуть человеку экраном, которого он не просил. Один SSH-раунд в задании,
        # где их и так несколько; движка нет — приедет пусто, и экран просто не появится.
        return {"ok": True, "url": f"http://{app.router_ip}:8088", "store": app.store_state()}
    return {"ok": False, "error": L("Пароль записан, но панель по нему не пустила — смотрите вывод",
                                    "The password was written, but the panel did not accept it — see the output")}


# СКОЛЬКО ЖДЁМ ПЕРЕЕЗДА РАСКЛАДКИ, прежде чем признать его повисшим. Число не с потолка:
# переезд — это копия дерева кода и настроек на накопитель ПЛЮС сверка md5, то есть чтение
# обратно; холодное чтение медленной флешки замерено на 448 КБ/с (`daemon-lib.sh` заведён
# ровно из-за этого). 3 МБ в обе стороны ≈ 15 с, потолок в 10 минут покрывает носитель
# вдесятеро медленнее — и всё равно кончается ОТВЕТОМ, а не вечным ожиданием: у мастера нет
# человека с Ctrl+C, повисшее задание не закрыть ничем, кроме убийства агента.
STORE_MODE_WAIT = 600
# Имена ПИД-файла и лога — ТЕ ЖЕ, что у кнопки панели (web/cgi-bin/action::store_mode).
# Это не совпадение: лог переезда лежит в `RAM_LOGS` (его собирает диаг-архив и чистит кнопка
# «очистить логи»), и второй путь означал бы, что «почему не переехало» после мастера искать
# негде. Заодно движок сам откажет второму заходу — оба конца видят один и тот же pid.
STORE_MODE_PID = "/tmp/enodia-store-mode.pid"
STORE_MODE_LOG = "/tmp/enodia-store-mode.log"


def wizard_store(app):
    """Что роутер знает про накопитель — для экрана выбора раскладки. Своих чисел не считаем:
    и режим, и кандидаты, и место приезжают от движка (`usb-offload.sh json`)."""
    section(L("Накопитель", "Storage drive"))
    st = app.store_state()
    if not st:
        info(L("Движок накопителя не ответил — раскладку менять нечем",
               "The storage engine did not answer — there is no layout to change"))
        return {"ok": True, "store": {}}
    cands = [c for c in (st.get("cands") or []) if isinstance(c, dict)]
    ok(L(f"Режим: {st.get('mode') or '?'}, накопителей видно: {len(cands)}",
         f"Mode: {st.get('mode') or '?'}, drives visible: {len(cands)}"))
    return {"ok": True, "store": st}


def wizard_store_mode(app, mode, dev):
    """Сменить раскладку (`usb-offload.sh mode data|bins|full`).

    ЗАПУСК ОТЦЕПЛЕННЫЙ, и это не перестраховка. Переезд кончается перезапуском панели с нового
    места, идёт десятки секунд и НЕ ИМЕЕТ ПРАВА умереть на середине: обрыв Wi-Fi между ПК и
    роутером убил бы SSH-сессию, а вместе с ней — процесс переезда (SIGHUP), оставив половину
    дерева на накопителе. Тот же довод, по которому кнопка панели тоже запускает движок
    отцепленным. Мы ЖДЁМ его снаружи и печатаем его лог по мере появления.

    ВЕРДИКТ — ПО ФАКТУ: у отцепленного процесса кода возврата нет вовсе, поэтому спрашиваем
    бутстрап, где сейчас лежит код (`boot.sh paths`), и сверяем с тем, что просили."""
    section(L("Раскладка", "Layout"))
    if mode not in ("data", "bins", "full"):
        return {"ok": False, "error": L("неизвестная раскладка", "unknown layout")}
    # Форму устройства проверяем ЗДЕСЬ, хотя её же проверяет CGI панели: значение приезжает из
    # браузера и уходит АРГУМЕНТОМ в шелл роутера. Гард на границе доверия обязан стоять у
    # каждой границы — это не дубль правила, а его применение (у CGI своя граница, у нас своя).
    if dev and not re.match(r"^/dev/sd[a-z][0-9]{0,2}$", dev):
        return {"ok": False, "error": L("неизвестное устройство", "unknown device")}
    cd = app.code_dir()
    # Путь уезжает в шелл роутера внутри одинарных кавычек — пробел в нём законен (точка
    # монтирования вида «/mnt/My Flash»), а вот сама кавычка сломала бы команду. Тот же гард и
    # по той же причине стоит в renv(): строку с кавычкой не «чиним», а отказываемся.
    if "'" in cd:
        return {"ok": False, "error": L("в пути к коду есть кавычка — так не пойдёт",
                                        "the code path contains a quote — cannot go on")}
    if app.router.get(f"[ -f '{cd}/usb-offload.sh' ] && echo yes") != "yes":
        return {"ok": False, "error": L("на роутере нет usb-offload.sh — обновите установку",
                                        "usb-offload.sh is missing on the router — update the installation")}
    # Уже идёт? Судим по ЖИВОМУ процессу, а не по файлу: pid-файл в /tmp переживает убитый
    # движок, и «уже идёт» осталось бы навсегда (та же причина, что у кнопки панели).
    busy = app.router.get(f'_smp=$(cat {STORE_MODE_PID} 2>/dev/null); '
                          f'[ -n "$_smp" ] && kill -0 "$_smp" 2>/dev/null && echo busy')
    if busy == "busy":
        return {"ok": False, "error": L("переключение раскладки уже идёт",
                                        "a layout switch is already running")}
    was = app.router_paths().get("mode") or ""
    if was == mode:
        ok(L(f"Раскладка уже {mode} — ничего не меняю", f"The layout is already {mode} — nothing to do"))
        return {"ok": True, "mode": mode, "same": True}
    info(L(f"Перевожу раскладку в {mode} — это займёт до минуты",
           f"Switching the layout to {mode} — this takes up to a minute"))
    # Отцепленно и со слежением — App.run_followed (тот же приём, что у CGI и у установки с ПК). Код возврата переезда нам не
    # нужен: вердикт выносит бутстрап, по факту.
    fr = app.run_followed(f"sh '{cd}/usb-offload.sh' mode {mode} {dev}", STORE_MODE_PID, STORE_MODE_LOG, STORE_MODE_WAIT,
                          pre=app.renv(), sync_note=L(
                              "start-stop-daemon не найден — веду переезд синхронно; не разрывайте связь с роутером",
                              "start-stop-daemon is missing — running the move synchronously; do not drop the link"))
    if fr["started"] is None:
        # Роутер замолчал на старте: переезд мог начаться — «не запустился» было бы неправдой, а «Повторить» поверх идущего вредно.
        return {"ok": False, "running": True, "error": L(
            "Роутер не ответил на старте переезда — он мог начаться; состояние — в панели («Роутер» → «Место и накопитель»)",
            "The router did not answer when the move was starting — it may have begun; the state is in the panel "
            "(“Router” → “Space and drive”)")}
    if not fr["started"]:
        return {"ok": False, "error": L("не удалось запустить переезд — смотрите вывод",
                                        "could not start the move — see the output")}
    if fr["alive"]:
        # Переезд ИДЁТ (движок жив) — это не отказ: `running` страница показывает иначе, чем «перенести не вышло»
        # (там она пишет «установка цела, не переехала только раскладка» — про незаконченный перенос неправда).
        # Раскладка в панели — «Роутер» → «Место и накопитель» (после редизайна «Компонентов» у неё нет).
        return {"ok": False, "running": True, "error": L(
            "Переезд идёт дольше 10 минут — роутер закончит его сам; состояние — в панели («Роутер» → «Место и накопитель»)",
            "The move is taking longer than 10 minutes — the router will finish it by itself; the state is in the panel "
            "(“Router” → “Space and drive”)")}
    # ВЕРДИКТ ПО ФАКТУ, а не по логу: спрашиваем бутстрап заново (кэш путей после переезда врёт).
    app.paths_forget()
    now = app.router_paths().get("mode") or ""
    if now == mode:
        ok(L(f"Раскладка: {mode}", f"Layout: {mode}"))
        return {"ok": True, "mode": mode}
    # Имени режима в тексте НЕТ: это слово движка, а строка уходит на экран человеку (сам режим
    # едет рядом полем `mode` — страница переводит его в человеческое слово сама).
    return {"ok": False, "mode": now, "error": L(
        "Раскладка не сменилась — причина в строках выше",
        "The layout did not change — the reason is in the lines above")}


def _passwd_root(router, pw):
    """Записать пароль root НА РОУТЕРЕ. ЕДИНСТВЕННАЯ копия этой команды на проект: зовут её
    двое (экран «смените пароль» и шаг открытия доступа), а команда набрана из четырёх
    замеров на живом железе — разъехавшись, вторая копия молча перестала бы менять пароль.
    Возвращает СЫРОЙ вывод роутера; судить по нему нельзя (см. ниже) — вердикт выносит вход.

    ЧТО ЗАМЕРЕНО на живом BE7000 28.08.2026 (и почему команда выглядит так):
      · `chpasswd` НЕТ ВООБЩЕ — остаётся только applet `passwd`;
      · у busybox `timeout` работает ТОЛЬКО форма `-t СЕК` (без -t: «not found», rc=127),
        а потолок здесь обязателен: passwd без tty может ждать ввода вечно;
      · хэш root сейчас `$1$` (MD5-crypt) ⇒ просим `-a md5`, чтобы формат не менялся;
      · `/etc/shadow` — симлинк на `/data/etc/shadow`, то есть смена ПЕРЕЖИВЁТ ребут
        (на AX3600 это не так — там пароль слетает на каждой загрузке)."""
    # В base64 уезжает пароль ОДИН раз: удваивает его шелл (passwd спрашивает дважды). Слать
    # две копии И удваивать — значит класть в passwd четыре строки; работает по случайности,
    # читается как ошибка. Поймано пробой 28.08.2026 (md5 потока не сошёлся с ожидаемым).
    b64 = base64.b64encode(pw.encode("utf-8")).decode("ascii")
    # Второй потолок — на нашей стороне (25 с > роутерных 20): если оборвётся не passwd, а сам
    # канал, задание всё равно вернётся, а не повиснет навсегда.
    # Сырая строка (r"") — чтобы `\n` уехал В ШЕЛЛ, а не превратился в перевод строки ещё в
    # Python. И только printf: `echo` в busybox трактует \-последовательности, а в пароле
    # обратный слэш разрешён — им бы и подменило символ, причём молча.
    #
    # ДВЕ ФОРМЫ КОМАНД СПРАШИВАЕМ У САМОГО РОУТЕРА, а не выбираем по модели: на BE7000 замерено,
    # что busybox знает ТОЛЬКО `timeout -t СЕК` (без -t: «1: not found», rc=127), но на другой
    # прошивке ровно наоборот, и жёсткая форма означала бы «смена молча не сработала». То же с
    # `-a md5` (нужен, чтобы формат хэша остался $1$, как сейчас): нет опции — идём без неё.
    return router.run(r"""p=$(base64 -d)
if timeout -t 1 true 2>/dev/null; then TO="timeout -t 20"; else TO="timeout 20"; fi
feed() { printf '%s\n' "$p"; printf '%s\n' "$p"; }
out=$(feed | $TO passwd -a md5 root 2>&1); rc=$?
case "$out" in
  *sage:*|*"nrecognized option"*|*"nvalid option"*|*"unknown option"*)
    out=$(feed | $TO passwd root 2>&1); rc=$? ;;
esac
printf '%s\n' "$out"
echo "RC=$rc"
""", stdin_data=b64, silent=True, timeout=25).out


def wizard_root_password(app, pw):
    """Смена пароля root НА РОУТЕРЕ. Зачем в мастере: сегодня README отсылает менять его
    чужой утилитой, человек уходит и не возвращается — роутер остаётся с паролем, который
    знает весь интернет.

    ВЕРДИКТ — ПО ФАКТУ ВХОДА, а не по коду возврата passwd: механика «пароль дважды со stdin»
    на этом железе НЕ ЗАМЕРЕНА, а поверить ей на слово значит оставить человека с роутером, в
    который он больше не войдёт. Поэтому пробуем ЗАЙТИ новым паролем и только после этого
    трогаем хранилище (та же болезнь, что и на входе: сохранить до проверки = затереть рабочий).

    Сама команда — в `_passwd_root()`: её же зовёт шаг открытия доступа, и двух копий у неё
    быть не должно."""
    section(L("Смена пароля root на роутере", "Changing the root password on the router"))
    # Правило формы то же, что у панели, и по той же причине: пароль уезжает и в SSH, и в
    # наше хранилище — не-ASCII здесь ломается тише всего (кодировку выбирает не мы).
    if not re.match(PANEL_PW_RE, pw or ""):
        return {"ok": False, "error": panel_pw_hint(root=True)}
    out = _passwd_root(app.router, pw)
    if out.strip():
        print(out.strip())
    # Пробуем ВОЙТИ новым паролем, не трогая хранилище: провал не должен стоить рабочего пароля.
    app.router.close()
    app.router.password_provider = lambda: pw
    try:
        entered = "SSH_OK" in app.router.run("echo SSH_OK", silent=True).out
    finally:
        app.router.password_provider = app.ensure_password
        app.router.close()   # дальше — снова тем паролем, что лежит в хранилище
    if entered:
        store_password(pw, app.router_ip)
        ok(L("Пароль root сменён — вход НОВЫМ паролем подтверждён",
             "The root password was changed — signing in with the NEW one is confirmed"))
        return {"ok": True}
    err(L("Роутер не пустил по новому паролю", "The router did not accept the new password"))
    return {"ok": False, "error": L(
        "Сменить пароль не вышло: роутер не пустил по новому. Прежний пароль в хранилище не "
        "тронут — мастер продолжит работать. Если роутер пароль всё же принял, введите новый "
        "на экране входа.",
        "Changing the password did not work: the router refused the new one. The stored password was "
        "left untouched, so the wizard keeps working. If the router did accept it after all, enter the "
        "new one on the sign-in screen.")}


def wizard_diag(app):
    """Диагностический отчёт. Собирает и МАСКИРУЕТ его сам роутер (dump.sh): решать,
    что считать секретом, на ПК нельзя — два места правды дадут два разных ответа."""
    section(L("Диагностика", "Diagnostics"))
    path, error = app.collect_diagdump()
    if error:
        err(error)
        return {"ok": False, "error": error}
    kb = round(os.path.getsize(path) / 1024, 1)
    ok(L(f"Готово: {path} ({kb} КБ)", f"Done: {path} ({kb} KB)"))
    return {"ok": True, "path": path, "kb": kb}


def wizard_remove_plan(app):
    """Что именно будет снято — спрашиваем у роутера ПЕРЕД показом экрана. Заодно кладём
    туда свежий uninstall.sh: снимать надо тем, что знает про сегодняшние подсистемы."""
    section(L("Что будет снято", "What will be removed"))
    fresh, error = app.uninstall_refresh()
    if error:
        err(error)
        return {"ok": False, "error": error}
    plan = app.uninstall_plan()
    return {"ok": True, "fresh": fresh, "plan": plan, "dir": app.code_dir()}


def wizard_remove(app, full):
    """Снятие. Свежесть скрипта проверяем ЗАНОВО (экран плана мог быть открыт давно, а
    uninstall_refresh идемпотентен), вердикт отдаёт uninstall_run — по факту."""
    section(L("Снятие с роутера", "Removing from the router"))
    # ОТКАЗ ДО НАЧАЛА — не «снялось не всё»: роутер не тронут, и экран обязан сказать это и ПРИЧИНУ (`started: false`).
    # Прежде отказ ехал полем `error`, а страница читала только `message` — «роутер занят установкой кода» превращалось
    # в «Снялось не всё — смотрите вывод ниже» (ревью ветки pkg-update, круг 3: снятие при занятом роутере).
    if not app._preflight_remote():
        return {"ok": False, "started": False, "message": L("Нет связи с роутером — снятие не начиналось",
                                                            "No connection to the router — the removal never started")}
    fresh, error = app.uninstall_refresh()
    if error:
        err(error)
        return {"ok": False, "started": False, "message": error}
    if not fresh:
        warn(L("Снимаю ПРЕЖНЕЙ копией скрипта — она может не знать про часть подсистем",
               "Removing with the OLD copy of the script — it may not know about some subsystems"))
    done, msg = app.uninstall_run(full)
    return {"ok": done, "full": full, "message": msg}


# Утилита открытия доступа (xmir-patcher). Для нас это ЧЁРНЫЙ ЯЩИК: зовём её готовые скрипты
# как есть, вывод отдаём в лог — внутрь не смотрим. PC-сторона, в payload роутера НЕ идёт.
#
# ПОЧЕМУ НЕ ВЕНДОРИМ. У апстрима (openwrt-xiaomi/xmir-patcher) ЛИЦЕНЗИИ НЕТ ВООБЩЕ — ни файла,
# ни строки в README (проверено 30.08.2026). Отсутствие лицензии значит не «бери кто хочет», а
# «все права у автора»: ToS GitHub даёт посторонним смотреть и ФОРКАТЬ в пределах GitHub, но не
# раздавать копию своим архивом. Поэтому байты человек получает С GITHUB, из нашего форка, а не
# из нашего ZIP — заодно проект худеет на 21 МБ, которые 9 из 10 не откроют ни разу.
#
# ПИН ПО КОММИТУ, А НЕ ПО ТЕГУ: тег можно передвинуть, коммит адресуется содержимым. Другого
# якоря целостности тут нет (`SHA256SUMS` — про роутерный payload), так что пин и ЕСТЬ проверка:
# GitHub отдаёт ровно это дерево либо не отдаёт ничего.
PATCHER_REPO = "Axel173/xmir-patcher"          # форк: апстрим + наши правки (ветка enodia)
PATCHER_TAG = "enodia-2026.08.30"              # человекочитаемая метка того же коммита
PATCHER_SHA = "6d406e81129ebd7b3b301d76101dc01d1fcd8ed3"
PATCHER_URL = f"https://codeload.github.com/{PATCHER_REPO}/zip/{PATCHER_SHA}"
PATCHER_SIZE_MB = 11                           # только для текста «скачаю ~11 МБ»
PATCHER_DL_DEADLINE_S = 600                    # потолок на ВСЮ закачку, см. _patcher_ensure
# КУДА кладём. НЕ в каталог проекта: его распаковывают куда угодно, вплоть до места без права
# записи, и повторная распаковка проекта затёрла бы кэш. `%APPDATA%\\enodia\\patcher\\<коммит>`
# переживает и то и другое, а имя ПО КОММИТУ делает смену пина новой папкой, а не перезаписью
# живой (иначе обновление пина посреди открытия доступа меняло бы файлы под работающей утилитой).
PATCHER_CACHE = os.path.join(CRED_DIR, "patcher", PATCHER_SHA[:12])
# Копия рядом с мастером. В репозитории её больше нет, но если она лежит (дерево разработчика,
# положили руками) — она ГЛАВНЕЕ кэша: правку хочется проверять сразу, а не после релиза форка.
PATCHER_VENDORED = os.path.join(WIZARD_DIR, "patcher")


def _patcher_python(base):
    """Чем запускать скрипты утилиты В КАТАЛОГЕ base. Windows: её ВСТРОЕННЫЙ python\\python.exe —
    в нём уже собраны зависимости, которых нет в окружении enodia.py. Иначе — run.sh поднимает
    venv сам, идём через него. Нет ни того, ни другого — каталога считай что нет."""
    win = os.path.join(base, "python", "python.exe")
    if os.path.isfile(win):
        return [win]
    sh = os.path.join(base, "run.sh")
    if os.path.isfile(sh):
        return ["bash", sh]
    return None


def _patcher_dir():
    """ГДЕ искать утилиту: локальная копия, если она рабочая, иначе кэш. Отвечает на «где», а не
    на «готово ли» — готовность обеспечивает `_patcher_ensure`."""
    return PATCHER_VENDORED if _patcher_python(PATCHER_VENDORED) else PATCHER_CACHE


class _PatcherWrongArchive(RuntimeError):
    """«Приехало не то» — в отличие от сетевого сбоя. Нужен отдельный тип, потому что обёртка
    ниже приписывает к сетевым отказам совет «проверьте интернет», а к ЭТОМУ он не подходит:
    связь-то была, ответ пришёл, он просто не тот. Совет, противоречащий диагнозу, хуже
    отсутствия совета — человек уходит чинить работающее."""


def _patcher_ensure():
    """Вернуть каталог ГОТОВОЙ к запуску утилиты, при нужде скачав её. Бросает с человеческим
    текстом, если не вышло.

    Зовётся ТОЛЬКО из открытия доступа — то есть когда SSH закрыт или человек ставит его заново.
    У кого доступ уже есть, эти 11 МБ не качаются никогда: качать «на всякий случай» значило бы
    брать плату за то, чем большинство не воспользуется.

    Распаковываем во ВРЕМЕННЫЙ каталог и лишь потом переименовываем: полураспакованное дерево
    выглядит «уже скачано» и падает потом — на середине открытия доступа, где цена ошибки выше."""
    base = _patcher_dir()
    if _patcher_python(base):
        return base
    import io
    import shutil
    import tempfile
    import time
    import urllib.request
    import zipfile
    info(L(f"Утилиты открытия доступа ещё нет — скачиваю из {PATCHER_REPO} ({PATCHER_TAG}, ~{PATCHER_SIZE_MB} МБ, один раз)",
           f"The access tool is not here yet — downloading from {PATCHER_REPO} ({PATCHER_TAG}, ~{PATCHER_SIZE_MB} MB, once)"))
    parent = os.path.dirname(PATCHER_CACHE)
    os.makedirs(parent, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".dl-", dir=parent)
    try:
        req = urllib.request.Request(PATCHER_URL, headers={"User-Agent": f"enodia/{PROJECT_VERSION}"})
        try:
            # Читаем КУСКАМИ, а не одним read(), по двум причинам, и обе уже стоили нам разбора
            # в этом же файле (см. _scan: «четыре HTTP-попытки висели ~20 с, и всё это время
            # человек смотрел на крутилку без единого слова»).
            #   1) ПРОГРЕСС. 11 МБ на медленном канале — это минута с лишним, и без строчек шаг
            #      выглядит зависшим ровно там, где человек и так нервничает.
            #   2) ОБЩИЙ ДЕДЛАЙН. `timeout=` у urlopen — это таймаут ОДНОЙ операции сокета, а не
            #      всей закачки: сервер, отдающий по байту раз в две минуты, не упрётся в него
            #      никогда и подвесит мастер навсегда. Считаем время сами.
            #   3) ПОТОЛОК РАЗМЕРА. Копим в памяти, а дедлайн ограничивает только ВРЕМЯ: на
            #      быстром канале за эти же 10 минут в ОЗУ прилетели бы гигабайты. Ждём ~11 МБ,
            #      режем на 64 — запас на рост утилиты и заведомо не «пока не кончится память».
            deadline = time.monotonic() + PATCHER_DL_DEADLINE_S
            hard_cap = 64 * 1024 * 1024
            chunks, got, said = [], 0, 0.0
            with urllib.request.urlopen(req, timeout=60) as resp:
                # Сколько всего обещали. Есть не всегда (chunked) — тогда показываем свою оценку.
                try:
                    total = int(resp.headers.get("Content-Length") or 0)
                except ValueError:
                    total = 0
                while True:
                    part = resp.read(256 * 1024)
                    if not part:
                        break
                    chunks.append(part)
                    got += len(part)
                    if got > hard_cap:
                        raise _PatcherWrongArchive(L(
                            f"по адресу утилиты отдают больше {hard_cap // 1024 // 1024} МБ — это не она",
                            f"the tool URL is serving more than {hard_cap // 1024 // 1024} MB — that is not it"))
                    now = time.monotonic()
                    if now > deadline:
                        raise TimeoutError(L(
                            f"качается дольше {PATCHER_DL_DEADLINE_S} с (взято {got // 1024} КБ)",
                            f"downloading for more than {PATCHER_DL_DEADLINE_S} s (got {got // 1024} KB)"))
                    # Не чаще раза в 3 с: строки уходят в браузер, и поток «10 обновлений в
                    # секунду» забил бы лог задания вместо того, чтобы что-то сообщать.
                    if now - said >= 3.0:
                        said = now
                        _pt = (total or PATCHER_SIZE_MB * 1024 * 1024) // 1024
                        _pa = '~' if not total else ''
                        info(L(f"  … {got // 1024} КБ из {_pa}{_pt}",
                               f"  … {got // 1024} KB of {_pa}{_pt}"))
            # Оборванная закачка отдаёт пустой read() — то есть ВЫГЛЯДИТ как штатный конец.
            # Без этой сверки её ловил бы уже zipfile, и человек читал бы «архив не
            # распаковался»: причина названа неверно, чинить он пошёл бы не то.
            if total and got != total:
                raise RuntimeError(L(f"закачка оборвалась: взято {got} байт из {total}",
                                     f"the download broke off: got {got} bytes of {total}"))
            blob = b"".join(chunks)
        except _PatcherWrongArchive:
            raise       # сеть тут ни при чём, совет про интернет был бы враньём
        except Exception as e:
            # Текст обязан говорить, ЧТО ДЕЛАТЬ. Раньше утилита лежала в архиве проекта и
            # работала без сети; теперь ей нужен интернет НА ЭТОМ КОМПЬЮТЕРЕ — и ровно в тот
            # момент, когда человек сидит в сети роутера, у которого интернета может ещё не
            # быть (новый роутер, WAN не настроен). Голое «не скачался» отправило бы его
            # чинить роутер, хотя качает ПК. Поэтому называем и причину, и обходной путь.
            # Про «СОДЕРЖИМОЕ архива» — не придирка к слову: внутри лежит каталог-обёртка
            # `xmir-patcher-<коммит>`, и распаковка «как есть» кладёт python на уровень глубже,
            # чем ищет `_patcher_python`. Совет, которому нельзя следовать буквально, хуже
            # отсутствия совета: человек его выполнит и получит ту же ошибку.
            raise RuntimeError(L(
                f"не скачался архив утилиты: {e}. Нужен интернет на этом компьютере (утилита "
                f"качается один раз, ~{PATCHER_SIZE_MB} МБ). Если его нет — скачайте на другой "
                f"машине {PATCHER_URL} и положите СОДЕРЖИМОЕ каталога из архива (сам файл "
                f"run.sh и папку python рядом с ним) в {PATCHER_VENDORED}",
                f"the tool archive did not download: {e}. This computer needs internet access (the tool "
                f"is fetched once, ~{PATCHER_SIZE_MB} MB). If there is none — download {PATCHER_URL} on "
                f"another machine and put the CONTENTS of the directory inside the archive (run.sh itself "
                f"and the python folder next to it) into {PATCHER_VENDORED}")) from e
        # ДВА РАЗНЫХ ОТКАЗА, и валить их в один текст нельзя. ОТКРЫТЬ архив не вышло — это про
        # то, что ПРИЕХАЛО (замерено 30.08.2026: codeload отдаёт без Content-Length, поэтому
        # сверка длины выше молчит и оборванная закачка доходит сюда — zip читает опись с КОНЦА
        # файла, а её нет). А вот РАСПАКОВАТЬ не вышло — это уже про диск: нет места, нет прав,
        # антивирус перехватил. Один общий текст «либо оборвалась закачка, либо файл повреждён»
        # на полном диске отправил бы человека перекачивать исправный архив.
        try:
            z = zipfile.ZipFile(io.BytesIO(blob))
        except Exception as e:
            raise RuntimeError(L(
                f"архив утилиты не открылся (взято {len(blob)} байт) — либо оборвалась "
                f"закачка, либо файл повреждён: {e}",
                f"the tool archive would not open (got {len(blob)} bytes) — either the download broke "
                f"off or the file is damaged: {e}")) from e
        try:
            with z:
                z.extractall(tmp)
        except Exception as e:
            raise RuntimeError(L(
                f"архив утилиты не распаковался в {tmp}: {e}. Проверьте место на диске и "
                f"права на запись в {parent}",
                f"the tool archive would not unpack into {tmp}: {e}. Check the free disk space and "
                f"write permissions for {parent}")) from e
        # У архива GitHub ровно один корневой каталог `<репо>-<коммит>`. Берём его ПО ФАКТУ, а не
        # собирая имя из констант: формат имени не наш и менялся бы молча.
        roots = [d for d in os.listdir(tmp) if os.path.isdir(os.path.join(tmp, d))]
        if len(roots) != 1:
            raise RuntimeError(L(f"в архиве утилиты ожидался один каталог, а их {len(roots)}",
                                 f"the tool archive was expected to hold one directory, it holds {len(roots)}"))
        src = os.path.join(tmp, roots[0])
        if not _patcher_python(src):
            raise RuntimeError(L("в скачанном архиве нет ни встроенного python, ни run.sh",
                                 "the downloaded archive has neither a bundled python nor run.sh"))
        # Битый остаток прошлой попытки сносим ЗДЕСЬ, а не раньше: пока новое дерево не собрано и
        # не проверено, старое — единственное, что вообще есть.
        if os.path.isdir(PATCHER_CACHE):
            shutil.rmtree(PATCHER_CACHE, ignore_errors=True)
        os.replace(src, PATCHER_CACHE)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # Кэш ключуется КОММИТОМ, значит смена пина не перезаписывает старый каталог, а заводит
    # соседний — и без уборки в профиле копится по 22 МБ на каждый прошлый пин. Чистильщика
    # ПК-стороны в проекте нет, сказать человеку «удали вон те папки» некому ⇒ убираем сами,
    # и ТОЛЬКО ПОСЛЕ того, как новое дерево уже на месте: до этого старое — единственное рабочее.
    # `.dl-*` НЕ ТРОГАЕМ: временные каталоги распаковки лежат в этом же родителе (иначе
    # `os.replace` уехал бы через границу ФС), и снести чужой `.dl-` значило бы убить закачку
    # ПАРАЛЛЕЛЬНОГО прогона прямо посреди распаковки — молча и с непонятной ошибкой у соседа.
    try:
        for name in os.listdir(parent):
            if name.startswith(".dl-"):
                continue
            old = os.path.join(parent, name)
            if old != PATCHER_CACHE and os.path.isdir(old):
                shutil.rmtree(old, ignore_errors=True)
    except OSError:
        pass    # уборка — не повод завалить открытие доступа
    info(L(f"Утилита открытия доступа готова: {PATCHER_CACHE}",
           f"The access tool is ready: {PATCHER_CACHE}"))
    return PATCHER_CACHE


def _run_patcher(script, args=None, stdin_text=None, base=None):
    """Запустить ОДИН готовый скрипт утилиты, транслируя его вывод построчно в лог задания
    (print → _WizardOut → браузер и enodia.log). Возвращает (код возврата, ХВОСТ вывода).

    Хвост нужен ровно для одного: у этой утилиты «уже сделано» и «сломалось» приходят
    ОДНИМ И ТЕМ ЖЕ ненулевым кодом, а разводит их только текст (см. wizard_open_access).
    Разбирать вывод дальше этого мы по-прежнему не пытаемся: она чёрный ящик.

    `base` ПРИНИМАЕМ от вызвавшего, а не вычисляем заново: каталог уже выбран и ПРОВЕРЕН в
    `_patcher_ensure()`, и в него же записан config.txt с адресом роутера. Второе вычисление
    ответило бы иначе, появись или исчезни `wizard/patcher` посреди прогона (человек распаковал
    архив проекта поверх, антивирус увёл файл в карантин) — и утилита пошла бы на СТОКОВЫЙ
    192.168.31.1 вместо указанного адреса, потому что рядом с её cwd конфига нет."""
    import subprocess
    if base is None:
        base = _patcher_dir()
    py = _patcher_python(base)
    if not py:
        raise RuntimeError(L(
            f"в каталоге утилиты ({base}) нет ни встроенного python, ни run.sh",
            f"the tool directory ({base}) has neither a bundled python nor run.sh"))
    env = dict(os.environ)
    # Заставляем вывод быть UTF-8 и небуферизованным: под пайпом Python 3.8 иначе пишет в
    # OEM-кодировке (chcp 866 из run.bat) — кириллица превратилась бы в мусор.
    env.update(PYTHONUTF8="1", PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
    # run.sh (macOS/Linux) берёт `python3` ИЗ PATH и строит на нём свой venv. Лаунчер без системного Python запускает
    # нас через uv (enodia-setup.sh), и `python3` в PATH тогда нет вовсе — шаг открытия доступа упал бы на «python3 binary
    # not found». Ставим впереди каталог интерпретатора, которым идём МЫ: у окружения uv и у venv там лежит `python3`; при
    # системном Python это его же каталог — ничего не меняется. Windows не касается: там встроенный python утилиты.
    if py[0] == "bash":
        env["PATH"] = os.path.dirname(sys.executable) + os.pathsep + env.get("PATH", "")
    proc = subprocess.Popen(
        py + [script] + (args or []), cwd=base, env=env,
        stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", bufsize=1)
    if stdin_text is not None:
        try:
            proc.stdin.write(stdin_text.rstrip("\n") + "\n")
            proc.stdin.flush()
        except Exception:
            pass
        finally:
            try:
                proc.stdin.close()
            except Exception:
                pass
    tail = []
    for line in proc.stdout:
        line = line.rstrip("\n")
        print(line)
        tail.append(line)
        if len(tail) > 40:          # потолок буфера, а не окно поиска: ищем в последних 5 строках
            tail.pop(0)
    proc.wait()
    return proc.returncode, "\n".join(tail)


def _access_steps(do_backup, do_lang):
    """План шагов открытия доступа: (id, скрипт, доп-арги, заголовок, текст-отказа, ОБЯЗАТЕЛЕН).
    `connect` ОБЯЗАН быть первым (ставит эксплойт и стабильный telnet); `backup` и `lang` — по
    флажкам экрана. id уходят в браузер маркерами ::STEP:: для полоски прогресса.

    ПОСЛЕДНЕЕ ПОЛЕ — «шаг обязателен для ИТОГА». Перевод интерфейса к доступу отношения не
    имеет: он косметика поверх заводской морды. Пока он был обязательным, его отказ выдавал
    «Доступ не открылся» при ЖИВОМ SSH — то есть мастер врал в вердикте и звал повторять то,
    что уже сделано (замер 30.08.2026 на AX3600). Резервная копия обязательна: без неё дальше
    идёт вмешательство в прошивку без права на откат."""
    steps = [("connect", "connect.py", None,
              L("Подключаюсь и ставлю эксплойт", "Connecting and installing the exploit"),
              L("подключиться и поставить эксплойт не вышло (см. вывод ниже)",
                "connecting and installing the exploit did not work (see the output below)"), True)]
    if do_backup:
        steps.append(("backup", "create_backup.py", None,
                      L("Резервная копия прошивки", "Firmware backup"),
                      L("резервная копия не снялась (см. вывод ниже)",
                        "the backup was not taken (see the output below)"), True))
    steps.append(("ssh", "install_ssh.py", None,
                  L("Открываю постоянный SSH", "Opening permanent SSH"),
                  L("открыть SSH не вышло (см. вывод ниже)",
                    "opening SSH did not work (see the output below)"), True))
    if do_lang:
        steps.append(("lang", "install_lang.py", ["full"],
                      L("Ставлю перевод интерфейса RU/EN", "Installing the RU/EN interface translation"),
                      L("перевод интерфейса не поставился — на доступ это не влияет",
                        "the interface translation did not install — this does not affect access"), False))
    return steps


# «Уже стоит» утилита сообщает ненулевым кодом и английской строкой — это НЕ отказ, а нужное
# нам конечное состояние. Список держим ЯВНЫМ: подстрока «already» сама по себе слишком широка.
_PATCHER_ALREADY = ("is already installed", "already installed")
# Ищем маркер ТОЛЬКО в последних строках вывода. Утилита печатает его ПОСЛЕДНИМ, как причину
# выхода; поиск по всему хвосту принял бы за «уже стоит» шаг, который сперва сообщил «патч на
# месте», а свалился дальше по другой причине — и мы бы покрасили настоящий отказ в успех.
_PATCHER_ALREADY_LINES = 5


def _patcher_says_already(out):
    """Вывод шага говорит «уже сделано»? Судим по последним непустым строкам."""
    last = [ln for ln in (out or "").splitlines() if ln.strip()][-_PATCHER_ALREADY_LINES:]
    low = "\n".join(last).lower()
    return any(m in low for m in _PATCHER_ALREADY)


def wizard_open_access(ip, do_backup=True, do_lang=False, root_pw=""):
    """Шаг «открыть доступ»: зовём утилиту как чёрный ящик и показываем её вывод. Её саму сюда
    достаёт `_patcher_ensure()` — в репозитории её НЕТ, качается из нашего форка по нужде.

    ПОРЯДОК как в её меню и КРИТИЧЕН (проверено на железе 29.08): СНАЧАЛА `connect.py` (пункт 2
    «Connect / install exploit») — он ставит эксплойт, поднимает СТАБИЛЬНЫЙ telnet и
    УСТАНАВЛИВАЕТ пароль root в введённый. Без него standalone-скрипты лезут в полуготовый
    telnet и намертво виснут на «Download file» (симптом «интермиттентного» зависания). Только
    ПОСЛЕ connect идут `create_backup.py` (опц.) и `install_ssh.py` — по уже открытому каналу.

    Пароль (станет паролем root) подаём connect'у на stdin — не в argv (там его видно в
    процессах). Вердикт — ПО ФАКТУ: в конце переспрашиваем порт 22."""
    import json
    if not test_ip_string(ip):
        return {"ok": False, "error": L("адрес роутера не похож на IPv4",
                                        "the router address does not look like an IPv4 address")}
    # ФОРМУ ПАРОЛЯ ПРОВЕРЯЕМ ДО ПЕРВОГО ШАГА, а не после. Правило одно с панелью (PANEL_PW_RE) —
    # второй копии, тем более в браузере, не заводим. Ниже начинается ВМЕШАТЕЛЬСТВО В ПРОШИВКУ,
    # и узнать «пароль не годится» после него человек должен был бы оговоркой в углу экрана —
    # то есть уже сделанного не вернуть, а пароль всё равно остался бы `root`.
    if root_pw and not re.match(PANEL_PW_RE, root_pw):
        return {"ok": False, "stage": "rootpw", "error": panel_pw_hint(root=True)}
    # Утилиту ДОСТАЁМ только здесь — на пути «SSH закрыт / ставлю заново». Скачивание, если оно
    # нужно, идёт ПЕРВЫМ шагом и до записи config.txt: писать настройки в каталог, которого ещё
    # может не оказаться, значило бы падать на ровном месте.
    try:
        pdir = _patcher_ensure()
    except Exception as e:
        return {"ok": False, "error": L(f"утилита открытия доступа недоступна: {e}",
                                        f"the access tool is unavailable: {e}")}
    # IP кладём в конфиг утилиты — оттуда его берут все её скрипты. МЕРДЖИМ, а не перезаписываем:
    # у config.txt могут быть и другие ключи (свои либо будущих версий) — терять их незачем.
    # Файл СОЗНАТЕЛЬНО вне git (.gitignore): это рантайм-состояние, а не исходник — пишем в него
    # и мы, и сама утилита (`img_write` через set_config_param). Пока он трекался, каждое
    # открытие доступа пачкало дерево и позволяло закоммитить АДРЕС СВОЕГО роутера. Отсутствие
    # файла безопасно с обеих сторон: у утилиты `load_config()` отдаёт {} и дефолт тот же
    # стоковый, а мы ниже ловим отсутствие/битый JSON и начинаем с пустого словаря.
    cfg_path = os.path.join(pdir, "config.txt")
    try:
        try:
            with open(cfg_path, encoding="utf-8") as fh:
                cfg = json.load(fh)
            if not isinstance(cfg, dict):
                cfg = {}
        except (OSError, ValueError):
            cfg = {}
        cfg["device_ip_addr"] = ip
        with open(cfg_path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=4)
    except OSError as e:
        return {"ok": False, "error": L(f"не смог записать config.txt утилиты: {e}",
                                        f"could not write the tool config.txt: {e}")}

    pw = root_pw or ""
    steps = _access_steps(do_backup, do_lang)
    print("::STEPS::" + ",".join(s[0] for s in steps))   # план шагов для полоски в браузере
    # НЕ `warn`: так зовётся функция вывода этого же модуля, и локальная переменная закрыла бы
    # её на всю функцию — первый же добавленный сюда warn(...) упал бы «str is not callable».
    warns = []
    for sid, script, args, title, failmsg, required in steps:
        print(f"::STEP::{sid}::run")
        section(title)
        try:
            rc, out = _run_patcher(script, args=args, stdin_text=pw, base=pdir)
        except Exception:
            # Метку fail шлём и на ИСКЛЮЧЕНИИ (не только на rc!=0) — иначе полоска шагов в
            # браузере остаётся крутиться на упавшем шаге. Дальше исключение ловит _wizard_job_run.
            print(f"::STEP::{sid}::fail")
            raise
        if rc != 0:
            if _patcher_says_already(out):
                # «Уже стоит» = ровно то состояние, которого мы добивались. Красить шаг в отказ
                # значило бы звать переделывать сделанное — а утилита за этим отсылает к
                # `install_lang.py uninstall` + ребуту, то есть к лишнему риску на ровном месте.
                info(L(f"{title}: уже стоит — оставляю как есть",
                       f"{title}: already in place — leaving it alone"))
                print(f"::STEP::{sid}::ok")
                continue
            print(f"::STEP::{sid}::fail")
            if required:
                return {"ok": False, "stage": sid, "error": failmsg}
            # Необязательный шаг: запоминаем и ИДЁМ ДАЛЬШЕ. Вердикт по-прежнему выносит факт
            # (порт 22 ниже), а не сумма кодов возврата. КОПИМ списком, а не одной строкой:
            # второй такой шаг иначе молча стёр бы отказ первого.
            warns.append(failmsg)
            continue
        # НОЛЬ ОТ УТИЛИТЫ — НЕ ВСЕГДА «всё снялось». Замерено на AX3600 31.08.2026: дамп одного
        # раздела упал (`ERROR: Remote file "/tmp/mtd_dump.bin" not found!`), а `create_backup.py`
        # напечатал «Completed!» и вернул 0 — шаг красился зелёным при НЕПОЛНОЙ копии. Для шага,
        # ради которого и заводят резервную копию перед вмешательством в прошивку, молчать об
        # этом нельзя. Шаг всё равно ok (копия есть, и она лучше, чем ничего), но оговорка едет.
        if sid == "backup":
            _bad = [l.strip() for l in out.splitlines() if l.strip().startswith("ERROR:")]
            if _bad:
                warns.append(L(f"резервная копия неполная — утилита сообщила: {_bad[0]}",
                               f"the backup is incomplete — the tool reported: {_bad[0]}"))
        print(f"::STEP::{sid}::ok")
    p = wizard_probe(ip)
    if not p.get("ssh"):
        return {"ok": False, "stage": "verify",
                "error": L("скрипты отработали, но порт 22 не отвечает — смотрите вывод",
                           "the scripts ran, but port 22 does not answer — see the output")}
    why = {}
    pw_set = _access_set_root_pw(ip, pw, warns, why)
    return {"ok": True, "ssh": True, "pw_set": pw_set, "pw_why": why.get("k", ""), "warn": "; ".join(warns)}


# Пароль root после открытия доступа задаём МЫ, а не утилита. Это не улучшение, а починка:
# утилита пароль со stdin НЕ ЧИТАЕТ ВООБЩЕ — в её `gateway.py` он прибит литералом
# (`echo -e "root\nroot" | passwd root`), проверено и в вендоренном дереве, и в пиннутом
# коммите форка (6d406e81, 31.08.2026). До этой функции набранный человеком пароль
# уезжал утилите в stdin и там пропадал, а экран входа сразу за «доступ открыт» советовал
# «тот, который вы задали на шаге „Доступ“» — то есть отправлял вводить пароль, которого на
# роутере нет. Замерено на живом AX3600: вход набранным паролем — отказ.
PATCHER_DEFAULT_PW = "root"      # что кладёт САМА утилита (gateway.py, литерал)


def _access_set_root_pw(ip, pw, warns, why=None):
    """True — пароль root теперь тот, что человек набрал (вход им ПОДТВЕРЖДЁН и он сохранён).

    `why["k"]` — почему НЕТ (ревью шага 8b, круг 3): «kept» — доступ открывали раньше, пароль прежний и нам неизвестен;
    «failed» — сменить не вышло, и сейчас он заводской. Страница говорит это РАЗНЫМИ словами: подсказка «введите тот,
    что у вас есть» во втором случае отправляла искать пароль, которого человек не задавал.

    Заходим паролем, который только что положила утилита, и меняем его на нужный. Если войти
    им не вышло — доступ на этом роутере был открыт РАНЬШЕ, и утилита пароль не трогала: тогда
    честнее сказать «оставили как есть», чем менять вслепую то, чего мы не знаем."""
    why = why if why is not None else {}
    if not pw:
        why["k"] = "nopw"
        return False
    if not re.match(PANEL_PW_RE, pw):
        why["k"] = "form"
        warns.append(L("пароль root не сменён: не подходит по форме — " + panel_pw_hint(root=True),
                       "the root password was not changed: bad form — " + panel_pw_hint(root=True)))
        return False
    r = Router(ip, password_provider=lambda: PATCHER_DEFAULT_PW)
    try:
        if "SSH_OK" not in r.run("echo SSH_OK", silent=True).out:
            # Не отказ шага: SSH-то открыт, а это и была цель. Но и молчать нельзя — иначе
            # человек пойдёт входить паролем, которого на роутере нет.
            why["k"] = "kept"
            warns.append(L("пароль root оставлен прежним: доступ был открыт раньше, и утилита "
                           "его не сбрасывала — входите тем, что у вас уже есть",
                           "the root password was left as it was: access had been opened earlier, so the "
                           "tool did not reset it — sign in with the one you already have"))
            return False
        out = _passwd_root(r, pw)
        if out.strip():
            print(out.strip())
    finally:
        r.close()
    # ВЕРДИКТ — ПО ФАКТУ ВХОДА, ровно как на экране смены пароля: код возврата passwd тут не
    # свидетель, а пообещать несуществующий пароль дороже, чем не менять его вовсе.
    chk = Router(ip, password_provider=lambda: pw)
    try:
        entered = "SSH_OK" in chk.run("echo SSH_OK", silent=True).out
    finally:
        chk.close()
    if not entered:
        why["k"] = "failed"
        warns.append(L("сменить пароль root не вышло: роутер не пустил по новому — сейчас он "
                       "«" + PATCHER_DEFAULT_PW + "», смените его на следующем экране",
                       "changing the root password failed: the router refused the new one — it is "
                       "“" + PATCHER_DEFAULT_PW + "” right now, change it on the next screen"))
        return False
    store_password(pw, ip)
    ok(L("Пароль root задан — вход им подтверждён", "The root password is set — signing in with it is confirmed"))
    return True


def _wizard_handler(app_state):
    # Импорты держим ЗДЕСЬ, а не в шапке файла: мастер — один режим из пяти, а стартовать
    # `--push`/`--exec` должны так же быстро, как раньше (их зовут из скриптов деплоя).
    # Методы класса видят эти имена замыканием.
    import hmac
    import platform
    import urllib.parse as urlparse
    from http.server import BaseHTTPRequestHandler

    class H(BaseHTTPRequestHandler):
        # Свой лог: BaseHTTPRequestHandler по умолчанию сыплет в stderr на каждый запрос,
        # а консоль мастера человек видит и пугается. Пишем в файл-лог, как всё остальное.
        # ТОКЕН ИЗ ЛОГА ВЫРЕЗАЕМ. Первая же проба показала его в enodia.log целиком: лог
        # прикладывают к багрепортам, а это ключ к агенту, который ходит на роутер под root.
        def log_message(self, fmt, *args):
            line = fmt % args
            logdbg("wizard: " + re.sub(r"([?&]t=)[^&\s\"]+", r"\1<токен>", line))

        def _host_ok(self):
            return self.headers.get("Host", "") == f"127.0.0.1:{app_state['port']}"

        def _token_ok(self):
            t = self.headers.get("X-Wizard-Token", "")
            if not t:
                q = urlparse.urlparse(self.path).query
                t = urlparse.parse_qs(q).get("t", [""])[0]
            # Сравнение постоянного времени: токен короткий, но привычка дешевле разбора.
            return hmac.compare_digest(t, WIZARD_TOKEN)

        def _send(self, code, body, ctype="application/json; charset=utf-8"):
            data = body if isinstance(body, bytes) else body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            # Страница мастера никуда не встраивается и ничего наружу не тянет.
            self.send_header("Content-Security-Policy", "default-src 'self' 'unsafe-inline'; img-src 'self' data:")
            self.send_header("X-Frame-Options", "DENY")
            # НИЧЕГО НЕ КЭШИРОВАТЬ. Страница опрашивает /api/job ОДНИМ И ТЕМ ЖЕ адресом, пока
            # новых строк нет (`since` не двигается) — а это ровно тот случай, где кэш браузера
            # означает «задание навсегда идёт»: состояние ok/fail до страницы уже не доедет.
            # Сегодня спасает лишь то, что мы не шлём ни Last-Modified, ни Expires, и браузер
            # эвристику не применяет; полагаться на это нельзя — заголовок стоит одну строку.
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _json(self, obj, code=200):
            self._send(code, json.dumps(obj, ensure_ascii=False))

        def _body(self):
            # Тело POST: только JSON и только небольшое. Потолок — не оптимизация, а гард:
            # читать в память столько, сколько скажет чужой Content-Length, нельзя.
            try:
                n = int(self.headers.get("Content-Length", "0") or 0)
            except ValueError:
                return {}
            if n <= 0 or n > 65536:
                return {}
            try:
                j = json.loads(self.rfile.read(n).decode("utf-8"))
            except Exception:
                return {}
            return j if isinstance(j, dict) else {}

        def _pick_lang(self):
            """Язык сеанса из заголовка страницы. Ставим на КАЖДОМ запросе и ДО разбора
            пути: отказы гарда — тоже текст, который человек прочитает на экране.
            Значение строго из белого списка: заголовок приходит снаружи процесса."""
            global WIZARD_LANG
            v = (self.headers.get("X-Wizard-Lang") or "").strip().lower()
            WIZARD_LANG = "en" if v == "en" else "ru"

        def _guard(self):
            """Общий вход для всех /api/*: Host (DNS-rebinding) + токен. Возвращает True,
            если запрос можно обслуживать; отказ уже отправлен."""
            self._pick_lang()
            if not self._host_ok():
                self._send(403, "forbidden", "text/plain; charset=utf-8")
                return False
            if not self._token_ok():
                self._json({"error": L("нет токена", "no token")}, 403)
                return False
            return True

        def do_GET(self):
            if not self._host_ok():
                self._send(403, "forbidden", "text/plain; charset=utf-8"); return
            path = urlparse.urlparse(self.path).path
            if path in ("/", "/index.html"):
                # Страницу отдаём и без токена — иначе человеку нечем его ввести. Токен
                # защищает ДЕЙСТВИЯ (/api/*), а сама разметка секретов не содержит.
                fp = os.path.join(WIZARD_DIR, "index.html")
                if not os.path.isfile(fp):
                    self._send(500, L("нет wizard/index.html", "wizard/index.html is missing"),
                               "text/plain; charset=utf-8"); return
                # Без стилей панели страница — голый текст без единой рамки, и кнопки не отличить от подписей.
                # Скажем причину словами, а не отдадим то, в чём человек не разберётся.
                if not os.path.isfile(os.path.join(SCRIPT_DIR, "web", "assets", "panel.css")):
                    self._send(500, L("нет web/assets/panel.css — распакуйте архив целиком",
                                      "web/assets/panel.css is missing — unpack the whole archive"),
                               "text/plain; charset=utf-8"); return
                with open(fp, "rb") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
                return
            # Своего значка вкладки у страницы нет (единственный <link> — panel.css, следит C110), и браузер
            # просит `/favicon.ico` сам. Отдавали 404 — и в консоли мастера ВСЕГДА
            # висели две ошибки. Дело не в красоте: консоль с постоянным шумом перестают читать,
            # и настоящая ошибка в ней теряется. 204 = «нечего отдавать», и это не ошибка.
            if path == "/favicon.ico":
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            # МАТЕРИАЛ ПАНЕЛИ (шаг 8b). Мастер — страница того же продукта, и собран он из ТЕХ ЖЕ стилей: карточка,
            # строки, плитки, двери, поля, кнопки, плашки, токены обеих тем и шрифт — `web/assets/panel.css`, а не
            # своя копия (копия палитры уже разъезжалась: мастер до 8b жил на палитре до редизайна). Отдаём СПИСКОМ, а не
            # каталогом: имя из адреса в путь не превращается вовсе, `..` и чужие файлы не достать. Без токена — как
            # саму страницу: секретов тут нет, а браузер шлёт за стилем и шрифтом свой запрос, без нашего заголовка.
            if path.startswith("/assets/"):
                name = path[len("/assets/"):]
                ctype = WIZARD_ASSETS.get(name)
                fp = os.path.join(SCRIPT_DIR, "web", "assets", name) if ctype else ""
                if not ctype or not os.path.isfile(fp):
                    self._send(404, "not found", "text/plain; charset=utf-8"); return
                with open(fp, "rb") as fh:
                    self._send(200, fh.read(), ctype)
                return
            if path.startswith("/api/"):
                if not self._guard():
                    return
                q = urlparse.parse_qs(urlparse.urlparse(self.path).query)
                if path == "/api/state":
                    _jv = wizard_job_view(10 ** 9)   # хвост не нужен — спрашиваем только состояние
                    self._json({
                        "version": PROJECT_VERSION,
                        "brand": "Enodia",
                        "platform": f"{platform.system()} {platform.release()}",
                        "python": platform.python_version(),
                        "host": app_state["host"],
                        "have_password": bool(get_stored_password(app_state["host"])),
                        # ЧТО АГЕНТ УЖЕ ЗНАЕТ О СЕБЕ — чтобы страница при загрузке не начинала
                        # с чистого листа там, где работа идёт. Перезагрузка вкладки (F5) — не
                        # отмена: задание крутится в агенте, а страница уходила на #welcome и
                        # человек терял и прогресс, и результат (замерено 02.09.2026). Плюс
                        # «уже подключён»: после F5 мастер снова спрашивал пароль root, хотя
                        # живой SSH-сессии он не терял.
                        "job": _jv["state"],
                        "job_name": _jv["name"],
                        "connected": bool(app_state.get("app") is not None
                                          and app_state["app"].router.is_connected()),
                    })
                    return
                if path == "/api/probe":
                    ip = (q.get("ip", [app_state["host"]])[0] or "").strip()
                    if not test_ip_string(ip):
                        self._json({"error": L("адрес не похож на IPv4",
                                               "that does not look like an IPv4 address")}, 400); return
                    # Ответ запоминаем: модель и прошивку спросили ДО всякого доступа, и
                    # переспрашивать их на экране проверки незачем (второй ответ мог бы и
                    # разойтись с первым — морда отвечает не всегда).
                    p = wizard_probe(ip)
                    app_state["probe"] = p
                    # Адрес сеанса — тот, что человек ПРОВЕРИЛ, а не прочитанный на старте: после F5 страница берёт
                    # адрес из /api/state, и вход после открытия доступа уходил бы на прежний (ревью шага 8b).
                    app_state["host"] = ip
                    # Сохранён ли пароль — для ПРОВЕРЕННОГО адреса: `have_password` в /api/state — про адрес со старта, и
                    # вход на другой роутер пробовал чужой пароль и писал «сохранённый не подошёл» (ревью шага 8b, круг 3).
                    self._json(dict(p, have_password=bool(get_stored_password(ip)))); return
                if path == "/api/job":
                    try:
                        since = int(q.get("since", ["0"])[0])
                    except ValueError:
                        since = 0
                    self._json(wizard_job_view(since)); return
                self._json({"error": L("неизвестный запрос", "unknown request")}, 404); return
            self._send(404, "not found", "text/plain; charset=utf-8")

        def do_POST(self):
            # Тело — ДО любого отказа. Отказ, отправленный при недочитанном теле, закрывает сокет с данными в приёмном буфере,
            # и Windows шлёт RST: браузер получает обрыв вместо 409 «мастер закрывается» и пишет «агент не отвечает»
            # (стенд pc-package-test под нагрузкой ловил WinError 10053, 30.09.2026). Прочесть ≤64 КБ до гарда безвредно.
            body = self._body()
            if not self._guard():
                return
            path = urlparse.urlparse(self.path).path
            # Закрытие принято — агент доживает полсекунды до остановки, и задание, начатое в это окно, умерло бы посреди SSH
            # (поток-демон гибнет вместе с процессом) — у установки это pkg-install.sh, брошенный посреди замены (ревью ветки,
            # круг 1). Отказ — до всего остального; окончательный — под локом, в wizard_job_start.
            if WIZARD_JOB.get("closing"):
                self._json({"error": L("мастер закрывается", "the wizard is closing")}, 409); return
            app = wizard_app(app_state)
            # Каждое действие — ЗАДАНИЕ: браузер получает имя и опрашивает /api/job.
            jobs = {
                "/api/connect": lambda: wizard_connect(app, app_state,
                                                       str(body.get("ip") or "").strip(),
                                                       str(body.get("password") or "")),
                "/api/facts": lambda: wizard_facts(app, app_state),
                "/api/install": lambda: wizard_install(app, body.get("tight_ok")),
                "/api/rootpw": lambda: wizard_root_password(app, str(body.get("password") or "")),
                "/api/panelpw": lambda: wizard_panel_password(app, str(body.get("password") or "")),
                "/api/store": lambda: wizard_store(app),
                "/api/storemode": lambda: wizard_store_mode(app, str(body.get("mode") or ""),
                                                            str(body.get("dev") or "")),
                "/api/diag": lambda: wizard_diag(app),
                "/api/removeplan": lambda: wizard_remove_plan(app),
                "/api/remove": lambda: wizard_remove(app, bool(body.get("full"))),
                "/api/access": lambda: wizard_open_access(
                    str(body.get("ip") or app_state["host"]).strip(),
                    bool(body.get("backup", True)),
                    bool(body.get("lang", False)),
                    str(body.get("rootpw") or "")),
            }
            if path in jobs:
                started, running = wizard_job_start(path.rsplit("/", 1)[1], jobs[path])
                if not started and not running:
                    self._json({"error": L("мастер закрывается", "the wizard is closing")}, 409); return
                if not started:
                    self._json({"error": L(f"уже идёт «{running}»", f"“{running}” is already running")}, 409); return
                self._json({"job": running}, 202); return
            if path == "/api/bye":
                # КОНЕЦ МАСТЕРА — КНОПКОЙ, А НЕ КОНСОЛЬЮ (30.09.2026). Установка у человека только в браузере, а окно, из
                # которого запущен агент, он не трогает: прежде «Мастер больше не нужен» вёл на приветствие, агент жил до
                # Ctrl+C, и закрывать окно велела сама страница. Ответ — ДО остановки (таймер), иначе браузер получил бы обрыв
                # вместо «закрыт»; после выхода Python с кодом 0 лаунчер окно не держит. Посреди задания — отказ: оборванная
                # заливка оставила бы роутер между двумя установками.
                # «Задания нет» и «закрываемся» — ОДНИМ шагом под локом заданий: флаг, поставленный после отпускания лока,
                # пропускал задание из второй вкладки, стартовавшее в этот зазор, — и оно умирало вместе с процессом посреди
                # SSH (ревью ветки, круг 2). Тот же лок проверяет флаг в wizard_job_start.
                with WIZARD_JOB_LOCK:
                    running = WIZARD_JOB["name"] if WIZARD_JOB["state"] == "run" else ""
                    if not running:
                        WIZARD_JOB["closing"] = True
                if running:
                    self._json({"error": L(f"идёт «{running}» — дождитесь конца", f"“{running}” is running — wait for it to finish")}, 409); return
                self._json({"ok": True})
                threading.Timer(0.5, app_state["srv"].shutdown).start()
                return
            if path == "/api/openpanel":
                import webbrowser
                url = f"http://{app.router_ip}:8088"
                try:
                    webbrowser.open(url)
                except Exception:
                    pass
                self._json({"ok": True, "url": url}); return
            if path == "/api/openfile":
                # Открыть собранный отчёт в проводнике/редакторе ПК. Путь принимаем ТОЛЬКО
                # свой — тот, что вернуло задание: открывать по чужой строке из браузера
                # значит дать странице запускать файлы на компьютере.
                want = str(body.get("path") or "")
                with WIZARD_JOB_LOCK:
                    mine = WIZARD_JOB.get("result", {}).get("path", "")
                if want and want == mine and os.path.isfile(want):
                    _open_file(want)
                    self._json({"ok": True}); return
                self._json({"ok": False, "error": L("путь не от последнего отчёта",
                                                    "that path is not the latest report")}, 400); return
            self._json({"error": L("неизвестный запрос", "unknown request")}, 404)

    return H


# Флаги «дай текстовое меню». Их несколько, потому что человек приходит из разных мест:
# лаунчер зовёт `--cli`, а из консоли пишут и `-cli`, и `/cli`, и по-английски `--menu`.
CLI_FLAGS = ("--cli", "-cli", "/cli", "--menu")


def wants_wizard(argv):
    """Мастер — путь ПО УМОЛЧАНИЮ, а не режим по флагу.

    Мы НАМЕРЕННО отменили второй способ установки: всё, кроме постановки панели, живёт в
    браузере. Значит и голый `python enodia.py` (ярлык, «Открыть с помощью», консоль — мимо
    лаунчера) обязан привести туда же, куда двойной клик, иначе человек попадает в текстовое
    меню и мастера, ради которого всё делалось, просто не находит.
    Текстовое меню осталось служебным входом и теперь просит СКАЗАТЬ ЭТО ЯВНО (`--cli`);
    `--install`/`--manage` — тоже явные CLI-режимы, они старше флага и работают как раньше.
    """
    # ПРАВИЛО ОДНО: меню — только когда его НАЗВАЛИ. Всё остальное (пусто, `--wizard` в любой
    # позиции, `--host 10.0.0.1`, случайный аргумент) ведёт в мастер.
    # ПОЧЕМУ НЕ «неизвестный аргумент → меню», как было сначала: `enodia.py --host 192.168.31.1`
    # молча открывал МЕНЮ — ровно тот же сюрприз, ради которого правилась позиция `--wizard`
    # (поймано в живом запуске 02.09.2026, когда обновляли второй роутер). Разбирать «похоже на
    # служебный вызов» тут нечем: перетащенные на лаунчер пути ФАЙЛОВ никто больше не читает —
    # управление конфигами переехало в панель (см. parse_args), а `--host` мастер уважает сам.
    if any(a in CLI_FLAGS for a in argv):
        return False
    if any(a in ("--install", "-Install", "/install",
                 "--manage", "-Manage", "/manage",
                 "-h", "--help") for a in argv):
        return False          # `--help` печатает справку меню, а не поднимает сервер
    return True


def run_wizard(argv):
    """`--wizard` — поднять мастер установки в браузере.

    ОДИН one-shot режим в ряду --exec/--push: разбираем сами, при совпадении не возвращаемся.
    Порт просим у ОС (0): фиксированный номер рано или поздно занят чужой программой, а
    закладка на мастер человеку не нужна — он приходит сюда один раз.
    """
    if not wants_wizard(argv):
        return
    # `--host` уважаем и здесь: флаг означает одно и то же во всех режимах, а «принял и молча
    # проигнорировал» — худший из вариантов. Адрес станет НАЧАЛЬНЫМ значением поля на первом
    # экране; человек всё равно видит его глазами и может поправить.
    host_override, argv = _pop_host_override(argv)
    global WIZARD_TOKEN, WIZARD_MODE
    import secrets
    import webbrowser
    from http.server import ThreadingHTTPServer
    WIZARD_TOKEN = secrets.token_urlsafe(24)
    # С этой секунды консольных вопросов не задаём НИГДЕ: у заданий нет терминала (см.
    # WIZARD_MODE). Диалог целиком ведёт страница.
    WIZARD_MODE = True
    state = {"host": host_override or load_router_host() or DEFAULT_ROUTER_IP,
             "port": 0, "app": None, "probe": {}}
    srv = ThreadingHTTPServer(("127.0.0.1", 0), _wizard_handler(state))
    state["port"] = srv.server_port
    state["srv"] = srv          # остановка кнопкой из браузера (/api/bye)
    # ВЫВОД — ПОСТРОЧНО. Перенаправленный в файл stdout Python буферизует блоком, а serve_forever не возвращается: адрес с
    # токеном («не открылось само — скопируйте») застревал в буфере и в журнал запуска не попадал вовсе (замер 30.09.2026).
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    url = f"http://127.0.0.1:{srv.server_port}/?t={WIZARD_TOKEN}"
    _enable_ansi()
    # Консольный баннер печатается ДО первого запроса страницы, то есть язык мастера ещё
    # неизвестен: пишем обе строки. Это единственное место, где двуязычие — не выбор, а
    # оба текста разом, и именно здесь оно и нужно: человек ещё ничего не выбирал.
    # ЗАГОЛОВОК — ПО ТОМУ ЖЕ ПРАВИЛУ. `L()` здесь всегда отдавал бы русский (язык приезжает
    # заголовком запроса, а запроса ещё не было), то есть блок, объявленный двуязычным,
    # открывался одноязычной строкой.
    section(f"Мастер установки / setup wizard {PROJECT_VERSION}")   # i18n-ok: обе строки разом
    ok("Открываю в браузере / opening in the browser:")             # i18n-ok
    cprint(f"  {url}", C.CYAN)
    info("Не открылось само — скопируйте адрес выше. Окно не закрывайте: пока оно живо, работает мастер.")  # i18n-ok
    info("Not opening by itself — copy the address above. Keep this window open: the wizard runs while it lives.")
    info("Остановить / stop — Ctrl+C.")                             # i18n-ok
    # Мастер теперь открывается и без флагов, поэтому «а где текстовое меню» — вопрос
    # ОТСЮДА: на headless-Linux браузера может не быть вовсе, и человеку нужен выход.
    info("Нужно текстовое меню (диагностика, служебные операции) — запустите с флагом --cli.")  # i18n-ok
    info("Need the text menu (diagnostics, service operations) — run it with --cli.")
    try:
        webbrowser.open(url)
    except Exception:
        pass
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    if WIZARD_JOB.get("closing"):
        ok("Мастер закрыт из браузера / the wizard was closed from the browser")   # i18n-ok: обе строки разом, как баннер
    sys.exit(0)


def main():
    run_readonly_exec(sys.argv[1:])   # one-shot read-only exec для скилла (при совпадении режима сам делает sys.exit)
    run_deploy(sys.argv[1:])          # one-shot deploy текстового файла (--push); тоже сам sys.exit при совпадении
    run_check_archive(sys.argv[1:])   # самопроверка архива установщика (--check-archive); sys.exit при совпадении
    run_wizard(sys.argv[1:])          # мастер установки в браузере (--wizard); serve_forever + sys.exit
    _enable_ansi()
    logdbg("=== старт: " + _env_banner() + " ===")
    force_install, force_manage = parse_args(sys.argv[1:])
    app = App(force_install=force_install, force_manage=force_manage)
    try:
        app.run()
    finally:
        app.router.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception:
        # Не дать окну .bat мгновенно закрыться на необработанной ошибке — пользователь
        # должен увидеть трейс (та же причина, что у _ensure_paramiko: «окно мигает»).
        # ПЛЮС пишем ПОЛНЫЙ трейс в лог: скриншот консоли часто обрезан (бета — фото 21
        # оборвано на середине), а файл целиком приложить к багрепорту.
        import traceback
        tb = traceback.format_exc()
        try:
            logdbg("НЕОБРАБОТАННАЯ ОШИБКА:\n" + tb)
        except Exception:
            pass
        traceback.print_exc()
        try:
            cprint(f"\n[i] Детали записаны в лог: {LOG_FILE}", C.GRAY)
            cprint("    Приложите этот файл к сообщению о баге — это ускорит разбор.", C.GRAY)
        except Exception:
            pass
        try:
            if sys.stdin and sys.stdin.isatty():
                input("\n[!] Непредвиденная ошибка. Нажмите Enter, чтобы закрыть окно...")
        except Exception:
            pass
        sys.exit(1)
