#!/bin/sh
# Обёртка для macOS: Finder запускает двойным кликом ТОЛЬКО .command (у .sh нет такой
# привязки — он открывается в редакторе). Своей логики здесь нет и быть не должно: весь
# лаунчер живёт в enodia-setup.sh, а вторая копия разошлась бы с ним на первой же правке.
#
# СТРОГО LF (.gitattributes: `*.command text eol=lf`): CRLF ломает shebang.
#
# ПОСЛЕ РАСПАКОВКИ АРХИВА может понадобиться `chmod +x enodia-setup.command` — zip, собранный
# на Windows, не переносит бит запуска. Без него Finder откроет файл текстом, а не выполнит.
cd "$(dirname "$0")" || exit 1
exec /bin/sh ./enodia-setup.sh "$@"
