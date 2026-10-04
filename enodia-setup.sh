#!/bin/sh
# Лаунчер Enodia для macOS и Linux — ровно то же, что enodia-setup.bat делает на Windows:
# без аргументов открывает МАСТЕР УСТАНОВКИ в браузере (enodia.py --wizard), с аргументом
# `cli` — текстовое меню, всё прочее прокидывает в enodia.py как есть.
#
# ЭТОТ ФАЙЛ — НАСТОЯЩИЙ ЛАУНЧЕР, а enodia-setup.command рядом — трёхстрочная обёртка над ним
# (Finder на macOS запускает двойным кликом только .command). Логика живёт в одном месте:
# две копии разошлись бы на первой же правке, а проверить это некому — у нас нет ни mac, ни
# Linux-машины, всё держится на том, что кода мало и он один.
#
# СТРОГО LF (зафиксировано в .gitattributes: `*.sh text eol=lf`). CRLF здесь — не косметика:
# `#!/bin/sh\r` ядро ищет как интерпретатор с именем «sh\r» и не находит, а сообщение при
# этом получается про ненайденный файл — то есть про что угодно, только не про перевод строки.
#
# НА РОУТЕР ЭТОТ ФАЙЛ НЕ ЕДЕТ. Он рядом с роутерными *.sh только потому, что лежит в корне
# репозитория; в payload его нет (проверка C2 знает об этом исключении явным списком).
set -u

# Каталог скрипта. Двойным кликом рабочий каталог — домашний, а не наш: без cd мы бы искали
# enodia.py в $HOME и не нашли.
cd "$(dirname "$0")" || exit 1

# ЧЕМ ЗАПУСКАТЬ. Мало НАЙТИ имя — надо убедиться, что оно работает и что версия не древняя:
# на macOS `python` бывает заглушкой Command Line Tools, которая при вызове открывает диалог
# установки и возвращает ошибку. Поэтому каждый кандидат проверяется запуском.
PY=""
for cand in python3 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 || continue
    PY="$cand"
    break
done

# НЕТ PYTHON — СТАВИМ ЕГО САМИ ЧЕРЕЗ uv (решение пользователя 30.09.2026; «почему uv, а не Python в архиве» — в
# enodia-setup.bat). uv — один статический файл от Astral: скачивает Python и зависимости в свой кэш и запускает enodia.py,
# ничего не ставя в систему. Версия ПРИШПИЛЕНА, архив сверяется по sha256 (суммы — поле digest релиза uv на GitHub); не
# сошлось — не запускаем. Всё лежит в ~/.cache/enodia/uv (удалить папку = убрать след). Нет сети/инструментов — прежняя
# ОСТАНОВКА с объяснением ниже. Linux — musl-сборка uv (статическая: идёт на любом дистрибутиве, glibc не нужен).
UVVER=0.12.21
UVRUN=""
uv_setup() {
    case "$(uname -s 2>/dev/null)" in
        Linux)  _os=unknown-linux-musl ;;
        Darwin) _os=apple-darwin ;;
        *) return 1 ;;
    esac
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64)  _arch=x86_64 ;;
        aarch64|arm64) _arch=aarch64 ;;
        i686|i386)     _arch=i686 ;;
        armv7l|armv7)  _arch=armv7 ;;
        *) return 1 ;;
    esac
    # 32-битный ARM у uv — `musleabihf`, а не `musl`: имя сборки другое, и сумма своя.
    [ "$_arch-$_os" = armv7-unknown-linux-musl ] && _os=unknown-linux-musleabihf
    case "$_arch-$_os" in
        x86_64-unknown-linux-musl)  _sha=d69d543a55ec9cdf9d3d9f2648b0a161847e3dbddc477e3be6b5813a6d46f639 ;;
        aarch64-unknown-linux-musl) _sha=67389a674e62adffa5a395d9a3b80688731c4aa7b33a6def3e62d00f7fec821f ;;
        i686-unknown-linux-musl)    _sha=1492353034d106f2067eeec8f8b6aad1354e13fbb3f91c25a40eb5d44215fd6f ;;
        armv7-unknown-linux-musleabihf) _sha=eeb8edc4e5b74ec4521da4d3911153ba8ce24ed8557e2dbbe55d04a6d7a7f45e ;;
        x86_64-apple-darwin)        _sha=2b336763b396ec6afa20c5a8b083538ca7402445b868311979d740a4344c17d8 ;;
        aarch64-apple-darwin)       _sha=b88bda573e566ef9bced66b155fe0408626fbbc053aee1c30ba686f0728c9447 ;;
        *) return 1 ;;
    esac
    UVHOME="${XDG_CACHE_HOME:-$HOME/.cache}/enodia/uv"
    _dir="$UVHOME/$UVVER-$_arch"
    if [ ! -x "$_dir/uv" ]; then
        _url="https://github.com/astral-sh/uv/releases/download/$UVVER/uv-$_arch-$_os.tar.gz"
        mkdir -p "$UVHOME" || return 1
        _tmp=$(mktemp -d "$UVHOME/.dl.XXXXXX") || return 1
        echo
        if [ -n "$PY" ]; then
            echo "  У Python на этом компьютере нет библиотек paramiko/keyring — соберу своё окружение через uv (около 20 МБ, один раз)."
            echo "  Your Python has no paramiko/keyring — building a separate environment via uv (about 20 MB, once)."
        else
            echo "  Python не найден — поставлю его сам через uv (около 20 МБ, один раз)."
            echo "  Python was not found — setting it up via uv (about 20 MB, once)."
        fi
        echo
        if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$_tmp/uv.tgz" "$_url"
        elif command -v wget >/dev/null 2>&1; then wget -q -O "$_tmp/uv.tgz" "$_url"
        else false; fi || { echo "  [!] не скачать uv (нет curl/wget или сети) / could not download uv"; rm -rf "$_tmp"; return 1; }
        # Сумма — тем, что есть: sha256sum (Linux), shasum (macOS), openssl (запас). Нечем посчитать — НЕ запускаем.
        _got=""
        if command -v sha256sum >/dev/null 2>&1; then _got=$(sha256sum "$_tmp/uv.tgz" | cut -d' ' -f1)
        elif command -v shasum >/dev/null 2>&1; then _got=$(shasum -a 256 "$_tmp/uv.tgz" | cut -d' ' -f1)
        elif command -v openssl >/dev/null 2>&1; then _got=$(openssl dgst -sha256 "$_tmp/uv.tgz" | sed 's/.*= *//'); fi
        if [ "$_got" != "$_sha" ]; then
            echo "  [!] sha256 архива uv не сошёлся (${_got:-нечем посчитать}) — не запускаю / uv archive sha256 mismatch"
            rm -rf "$_tmp"; return 1
        fi
        tar -xzf "$_tmp/uv.tgz" -C "$_tmp" || { rm -rf "$_tmp"; return 1; }
        _bin=$(find "$_tmp" -type f -name uv | head -n 1)
        [ -n "$_bin" ] || { echo "  [!] в архиве нет uv / uv is not in the archive"; rm -rf "$_tmp"; return 1; }
        # На место — переименованием: оборванная распаковка не должна выглядеть «уже скачано».
        mkdir -p "$_tmp/ready" && mv "$_bin" "$_tmp/ready/uv" && chmod +x "$_tmp/ready/uv" || { rm -rf "$_tmp"; return 1; }
        rm -rf "$_dir"; mv "$_tmp/ready" "$_dir" || { rm -rf "$_tmp"; return 1; }
        rm -rf "$_tmp"
    fi
    # Python и кэш uv — в НАШЕЙ папке; --managed-python: только Python, поставленный uv; --no-project/--with-requirements:
    # окружение по тому же requirements.txt, что у pip-пути, без файлов в папке проекта.
    UV_PYTHON_INSTALL_DIR="$UVHOME/python"; UV_CACHE_DIR="$UVHOME/cache"
    export UV_PYTHON_INSTALL_DIR UV_CACHE_DIR
    UVRUN="$_dir/uv"
    return 0
}

# Python есть, а зависимостей нет — тоже через uv: на свежих Debian/Ubuntu и в Homebrew системный Python «externally managed» (PEP 668),
# и доустановка enodia.py через pip там отказывает (ревью с.88, круг 2). Не вышло с uv (нет сети) — прежний путь через этот Python.
PYDEPS=0
[ -n "$PY" ] && "$PY" -c 'import paramiko, keyring' >/dev/null 2>&1 && PYDEPS=1
if [ "$PYDEPS" = 0 ] && uv_setup; then
    # Без сети повторный запуск обязан идти (ПК в Wi-Fi роутера без интернета): uv пересверяет индекс PyPI на каждом запуске
    # (диапазоны версий), и без сети падал ДО мастера (ревью с.88). Окружение уже собрано — это скажет проба --offline.
    UVOFF=""
    "$UVRUN" run --offline --no-project --no-config --managed-python --python 3.12 --with-requirements ./requirements.txt \
        python -c 'import paramiko, keyring' >/dev/null 2>&1 && UVOFF=--offline
    case "${1:-}" in
        "")   exec "$UVRUN" run $UVOFF --no-project --no-config --managed-python --python 3.12 --with-requirements ./requirements.txt ./enodia.py --wizard ;;
        cli)  shift; exec "$UVRUN" run $UVOFF --no-project --no-config --managed-python --python 3.12 --with-requirements ./requirements.txt ./enodia.py --cli ${1+"$@"} ;;
        *)    exec "$UVRUN" run $UVOFF --no-project --no-config --managed-python --python 3.12 --with-requirements ./requirements.txt ./enodia.py "$@" ;;
    esac
fi

if [ -z "$PY" ]; then
    # Двуязычно и обоими языками разом: язык мастера человек ещё не выбирал (мастер и не
    # запустился), а угадывать по локали ради сообщения об ошибке — значит рискнуть показать
    # непонятное ровно там, где нужно понятное.
    cat <<'EOF'

  [!] Python не найден — установить роутер нечем.

  Поставить его сам через uv не вышло (нет интернета, curl/wget или редкая платформа).
  Нужен Python 3.8 или новее (он же нужен шагу открытия доступа).
    macOS:  brew install python   (или xcode-select --install)
    Debian/Ubuntu:  sudo apt install python3 python3-venv
    Fedora:  sudo dnf install python3
  Затем запустите этот файл снова.

  --- EN ---------------------------------------------------------------
  Python was not found, and setting it up via uv failed (no internet, no curl/wget,
  or an unusual platform), so there is nothing to install the router with.
  Python 3.8+ is required (the access step needs it too).
    macOS:  brew install python   (or xcode-select --install)
    Debian/Ubuntu:  sudo apt install python3 python3-venv
    Fedora:  sudo dnf install python3
  Then run this file again.

EOF
    exit 1
fi

# Без аргументов — мастер в браузере. `cli` — текстовое меню. Прочее (--exec/--push) уходит
# в enodia.py как есть: набор флагов знает он, а не лаунчер.
#
# `${1+"$@"}`, А НЕ `"$@"` — из-за macOS. Там /bin/sh это bash 3.2, а до bash 4.4 пустой
# `"$@"` под `set -u` считался НЕУСТАНОВЛЕННОЙ переменной: `enodia-setup.sh cli` после
# `shift` роняло лаунчер с «$@: unbound variable» ровно на том пути, который README и
# называет текстовым режимом. Форма `${1+…}` подставляет аргументы, только если первый
# существует, и одинаково понятна dash, ash и bash любой версии.
case "${1:-}" in
    "")   exec "$PY" ./enodia.py --wizard ;;
    cli)  shift; exec "$PY" ./enodia.py --cli ${1+"$@"} ;;
    *)    exec "$PY" ./enodia.py "$@" ;;
esac
