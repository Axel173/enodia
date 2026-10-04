#!/bin/sh
# build-byedpi.sh — ВОСПРОИЗВОДИМАЯ сборка ciadpi (byedpi) под роутер: aarch64, статик, musl.
#
# ДЕВ-ТУЛЗА: запускать на Linux / WSL Ubuntu (НЕ на роутере; НЕ часть payload-установки).
# Кладёт готовый бинарь в bin/byedpi.user (его уже забирает установщик/gh-update, как остальные).
#
# ЗАЧЕМ свой билд: не зависеть от чужих prebuilt — собираем из ПИННОГО тега исходников ciadpi
# (hufrea/byedpi, чистый C99, dependency-free) компилятором zig как self-contained кросс-
# компилятором (musl-static, без apt/sudo). Решено 2026-06-17. ciadpi = DPI-десинк SOCKS-прокси
# для транспорта byedpi (transport-byedpi.sh) — обход блокировок напрямую, без VPS.
#
# Использование:   sh build-byedpi.sh
#   Переопределить версии:  TAG=v0.17.3 ZIGVER=0.16.0 WORK=$HOME/byedpi-build sh build-byedpi.sh
#
# ГРАБЛЯ: ziglang.org часто тормозит/душится (~100 КБ/с) — curl -C - докачивает по частям.
set -e
TAG="${TAG:-v0.17.3}"
ZIGVER="${ZIGVER:-0.16.0}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/bin/byedpi.user"
WORK="${WORK:-$HOME/byedpi-build}"
mkdir -p "$WORK"; cd "$WORK"

ZIGDIR="$WORK/zig-x86_64-linux-$ZIGVER"
if [ ! -x "$ZIGDIR/zig" ]; then
    echo "== скачиваю zig $ZIGVER (curl -C - докачивает при обрыве) =="
    curl -L -C - --retry 6 --retry-delay 3 -o zig.tar.xz \
        "https://ziglang.org/download/$ZIGVER/zig-x86_64-linux-$ZIGVER.tar.xz"
    tar -xf zig.tar.xz
fi
ZIG="$ZIGDIR/zig"
echo "== zig: $("$ZIG" version) =="

SRC="$WORK/byedpi-$TAG"
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$TAG" https://github.com/hufrea/byedpi "$SRC"
cd "$SRC"
echo "== byedpi: $(git describe --tags --always) ($(git rev-parse HEAD)) =="

make clean >/dev/null 2>&1 || true
make CC="$ZIG cc -target aarch64-linux-musl" LDFLAGS="-static -s"

mkdir -p "$HERE/bin"
cp ciadpi "$OUT"
chmod +x "$OUT"
echo "== готово =="
ls -la "$OUT"
file "$OUT"
sha256sum "$OUT"
# Санити: ровно то, что нужно musl-aarch64 роутеру.
file "$OUT" | grep -q "ARM aarch64"     || { echo "ОШИБКА: бинарь не aarch64"; exit 1; }
file "$OUT" | grep -q "statically linked" || { echo "ОШИБКА: бинарь не статический"; exit 1; }
echo "OK: bin/byedpi.user готов (aarch64, static)"
