#!/bin/sh
# conf-lib.sh — the ONLY reader of our shell-style settings files: `KEY=value` lines (iplist.conf, notify.conf). Sourced; prints
# nothing and changes nothing but the caller's variables it is asked for.
#
# WHY NOT `. file`. Both files travel in the settings backup, and an archive is not always the person's own («a friend's backup»,
# review s.99): sourced, ANY line of it ran as root at the next 5:00 list update or the next mail — `IPLIST_URL=x; wget …|sh` is a
# well-formed shell file. Parsed, a line is only ever a value, and only of a key the caller names: an unknown key, a command, a
# `$(…)` stay text nobody runs.
#
# THE GRAMMAR — what the panel and the examples write, and what a hand edit plausibly adds: `KEY=value`, `KEY='value'`,
# `KEY="value"`; blanks before KEY; `export KEY=…`; a ` # comment` after the value; the CR of a Windows editor. The LAST assignment
# wins, as with `.`. A bare value ends at the first blank (as the shell reads it). NOT understood — a value that leaned on them
# changes: `$VAR`/`$(…)`/`~` expansion, backslash escapes inside double quotes, a quoted value spanning lines. A key the file does
# not assign keeps the caller's default.

_CL_BL=" $(printf '\t')"

# conf_load <file> <KEY>... — set each listed KEY the file assigns. rc 1 — no file (nothing set). A KEY that is not a shell name
# is skipped: it goes into a sed pattern and an assignment, and only names the caller wrote may.
conf_load() {
	[ -f "$1" ] || return 1
	_clf=$1; shift
	for _clk in "$@"; do
		case "$_clk" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
		# «=» marks a match, so an empty value («KEY=») is told from a key the file does not assign (no output at all).
		_clv=$(sed -n "s/^[$_CL_BL]*\(export[$_CL_BL][$_CL_BL]*\)\{0,1\}$_clk=/=/p" "$_clf" 2>/dev/null | tr -d '\r' | tail -n 1)
		[ -n "$_clv" ] || continue
		_clv=${_clv#=}
		case "$_clv" in
			\'*) _clv=${_clv#\'}; _clv=${_clv%%\'*} ;;
			\"*) _clv=${_clv#\"}; _clv=${_clv%%\"*} ;;
			*)   _clv=${_clv%%[$_CL_BL]*} ;;
		esac
		eval "$_clk=\$_clv"   # the name is checked above; the value goes by reference — eval never parses it
	done
	return 0
}
