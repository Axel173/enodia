#!/bin/sh
# stock-backup.sh — THE STOCK SETTINGS BACKUP («копия настроек прошивки»): see it, turn it off (freeing the flash), turn it back
# on. The ONLY owner of this stock feature in the project: the panel (cgi-bin/data `stockbak`, cgi-bin/action `stock_backup`),
# the install wizard (enodia.py runs THIS file from the package over SSH, before anything is installed — hence the shims below),
# heal.sh (boot) and uninstall.sh call it; nobody else reads or writes the flag.
#
# WHAT IT IS. Xiaomi keeps its settings (/etc/config, crontabs, passwd/shadow) in a LUKS+ext4 container /data/sec_cfg/data.vol.
# With `misc.features.sec_cfg_bak=1` the stock's /usr/sbin/sec_cfg_bak.sh (cron every 6 h; on BE6500 a boot hook too) keeps a
# full COPY of it in /data/usr/sec_cfg/ whenever `uci show` changed. On BE6500 (19.5-MB /data) the copy held 3.8 MB of real flash
# and Xray did not fit (measured 13.10.2026); BE7000 ships the same script with the flag unset.
# THE PRICE, said wherever the offer is made (/lib/preinit/89_mount_sec_cfg): at boot a container that fails luksOpen/e2fsck is
# restored FROM THE COPY; with no copy the stock makes an EMPTY container — every router setting reset (Wi-Fi, the root password,
# our cron lines: Enodia stops starting until the wizard attaches it again).
#
# THE FLAG AND THE REMOVAL GO TOGETHER: the copy removed alone comes back on the stock's next pass, the flag alone leaves the
# megabytes where they are. UNDER THE STOCK'S OWN LOCK: sec_cfg_bak.sh copies under flock(/var/run/sec_cfg_bak.lock) — holding it,
# we never remove a copy being written nor flip the flag mid-copy.
# THE MARKER `$ENODIA_STATE/.stock-backup-off` is the person's INTENT and what the flag was before us: heal turns the copy off again
# when a firmware update brings the flag back, uninstall puts back the value we changed (user's decisions 15.10.2026). No marker —
# we never touched it, and neither verb does anything.
# NO OWN «LIGHT» COPY of the settings: they carry Wi-Fi passwords and the root hash — out of the encrypted container they would lie
# on the flash in the clear (user's decision 15.10.2026).
# The offer is judged by FACT, not by model: the stock script and the live container exist, and the flag is 1 or a copy lies there.
#
#   stock-backup.sh status     — one JSON line: present flag copy copy_b est_b live busy mine at freed_b free_b need_b mp offer
#                                off_why off_mine can_on on_why. The ROUTER decides what a screen shows: `offer` (a copy to turn
#                                off) or, when not, `off_why`; `off_mine` («turned off by you» — and it IS off: flag not 1, no copy);
#                                `can_on` or, when not, `on_why`. `mp` — the copy's volume (a plan short of room elsewhere is not helped).
#   stock-backup.sh off        — flag 0 + the copy removed: {"ok":true,"freed_b":N,"had":…,"marked":…} or {"ok":false,"why":"<code>"}
#   stock-backup.sh on         — the flag back to 1 and a fresh copy made at once; refused without room for it
#   stock-backup.sh heal       — boot: the person chose «off» and the flag (or a copy) came back ⇒ off again (+ an event when the
#                                FIRMWARE brought the flag back)
#   stock-backup.sh uninstall  — the flag back as the person's last off found it (1 once the firmware set it); the marker removed. Prints
#                                what it did: restored | kept | kept-absent | fail <was> (see sb_uninstall)
# Refusal codes (`why`) — the panel and the wizard word them: absent · nolive · busy · nothing · space · uci · rm · notmine · nostate.
# Status reason codes: off_why — absent · nolive; on_why — absent · nolive · notmine · on · space.

ENODIA_DIR=${ENODIA_DIR:-/data/usr/app/enodia}
ENODIA_STATE=${ENODIA_STATE:-/data/usr/app/enodia-state}
SB_VOL=${ENODIA_SB_VOL:-/data/sec_cfg/data.vol}             # the live container
SB_DIR=${ENODIA_SB_DIR:-/data/usr/sec_cfg}                  # the stock's copy of it
SB_SCRIPT=${ENODIA_SB_SCRIPT:-/usr/sbin/sec_cfg_bak.sh}     # the stock's copier (CGI's PATH may lack /usr/sbin — by path)
SB_LOCK=${ENODIA_SB_LOCK:-/var/run/sec_cfg_bak.lock}        # the copier's own flock
SB_MOUNTS=${ENODIA_SB_MOUNTS:-/proc/mounts}
SB_FREE_WAIT=${ENODIA_SB_FREE_WAIT:-10}                     # seconds UBIFS may take to give freed blocks back
SB_MARK="$ENODIA_STATE/.stock-backup-off"
SB_EST=${ENODIA_SB_EST:-/tmp/enodia-stock-backup.est}      # RAM: the copy's estimated weight per (file, size, mtime)
SB_RESERVE_B=1048576                                        # free space left over after a fresh copy
# The state dir may be MADE only by the wizard (it turns the copy off before the install: no state dir yet). Anyone else finding
# no state dir is looking at the flash literal of a system that lives elsewhere (`full` layout, its drive missing): `mkdir -p` there
# grows an empty twin on flash, the marker lands in it, and heal/uninstall/the panel never see the person's choice (review s.139).
SB_MKSTATE=${ENODIA_SB_MKSTATE:-0}

if [ -f "$ENODIA_DIR/store-lib.sh" ]; then . "$ENODIA_DIR/store-lib.sh"; fi
if [ -f "$ENODIA_DIR/label-lib.sh" ]; then . "$ENODIA_DIR/label-lib.sh"; fi
if [ -f "$ENODIA_DIR/clock-lib.sh" ]; then . "$ENODIA_DIR/clock-lib.sh"; fi
# The wizard runs this file before the install: no libraries yet. The shims repeat the library forms one to one.
command -v fs_anchor >/dev/null 2>&1 || fs_anchor() { _fan="${1:-$ENODIA_DIR}"; while [ -n "$_fan" ] && [ ! -e "$_fan" ]; do _fan="${_fan%/*}"; done; printf '%s' "${_fan:-/}"; }
command -v fs_line   >/dev/null 2>&1 || fs_line()   { df -k "$(fs_anchor "$1")" 2>/dev/null | tail -1 | awk '{for(i=NF;i>1;i--) if($i ~ /%$/) break; if(i>=4 && $(i-3) ~ /^[0-9]+$/ && $(i-1) ~ /^[0-9]+$/ && $(i-3)+0>0){m=""; for(j=i+1;j<=NF;j++){ if(j>i+1) m=m " "; m=m $j }; print $(i-3), $(i-1), m}}'; }
command -v fs_mount  >/dev/null 2>&1 || fs_mount()  { _fsm=$(fs_line "$1"); printf '%s' "${_fsm#* * }"; }
command -v fs_free_b >/dev/null 2>&1 || fs_free_b() { _fsb=$(fs_line "$1" | awk '{printf "%.0f", $2*1024}'); case "$_fsb" in ''|*[!0-9]*) _fsb=0 ;; esac; printf '%s' "$_fsb"; }
command -v clock_sane >/dev/null 2>&1 || clock_sane() { _csn=${1:-$(date +%s 2>/dev/null)}; case "$_csn" in ''|*[!0-9]*) return 1 ;; esac; [ "$_csn" -gt 1700000000 ] 2>/dev/null && [ "$_csn" -lt 4102444800 ] 2>/dev/null; }
command -v lbl_commit >/dev/null 2>&1 || lbl_commit() { if [ -z "$2" ]; then rm -f "$1"; return $?; fi; _lblt="$1.$$"; if printf '%s\n' "$2" > "$_lblt" 2>/dev/null && [ "$(cat "$_lblt" 2>/dev/null)" = "$2" ]; then mv "$_lblt" "$1" && return 0; fi; rm -f "$_lblt"; return 1; }

num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
tf()  { if "$@"; then echo true; else echo false; fi; }
# A refusal: its code for the wizard (it words it in two languages) and the words for the panel (its dictionary translates).
no()  {
	case "$1" in
		absent)  _nom="у этой прошивки нет копии настроек" ;;
		nolive)  _nom="хранилище настроек роутера не открылось при загрузке — копию не трогаю: она может быть единственной целой" ;;
		busy)    _nom="прошивка как раз делает копию — повторите через минуту" ;;
		nothing) _nom="копия настроек прошивки уже выключена" ;;
		space)   _nom="на флеше не хватит места на новую копию — сперва освободите место" ;;
		uci)     _nom="прошивка не приняла смену настройки" ;;
		rm)      _nom="копию выключил, но удалить её не вышло — место не освободилось" ;;
		nostate) _nom="каталог настроек системы недоступен (накопитель с системой не найден?) — выключать не стану: выбор негде запомнить" ;;
		*)       _nom="копию выключали не через панель — включить её отсюда нельзя" ;;
	esac
	printf '{"ok":false,"why":"%s","msg":"%s"}\n' "$1" "$_nom"; return 1
}
hum() { awk -v b="${1:-0}" 'BEGIN { k = b / 1024; if (k < 1024) printf "%d КБ", k; else printf "%.1f МБ", k / 1024 }'; }

# The flag as uci holds it: 1 · 0 · empty (unset — BE7000's way of «off»); anything else reads as empty.
sb_flag() { _sbf=$(uci -q get misc.features.sec_cfg_bak 2>/dev/null); case "$_sbf" in 0|1) echo "$_sbf" ;; *) echo "" ;; esac; }
# A refused set or commit is REVERTED: uci keeps a staged change in its own RAM dir, `get` (ours and the copier's) reads it as real, and
# any later `uci commit misc` (the stock web UI) would commit it silently (review s.139 r3, F4).
sb_set()  {
	if uci set "misc.features.sec_cfg_bak=$1" 2>/dev/null && uci commit misc 2>/dev/null && [ "$(sb_flag)" = "$1" ]; then return 0; fi
	uci -q revert misc.features.sec_cfg_bak 2>/dev/null; return 1
}
sb_present() { [ -f "$SB_SCRIPT" ] && [ -f "$SB_VOL" ]; }
sb_copy()    { [ -e "$SB_DIR" ]; }
# The live container mounted where the settings are read from. Not mounted = it failed at boot, and the copy may be the ONLY
# good one left — never removed then.
sb_live() { awk '$1 == "/dev/mapper/sec_cfg" && $2 == "/etc/config" { f = 1 } END { exit !f }' "$SB_MOUNTS" 2>/dev/null; }
# The copier at work right now: its lock is held. Opening the lock file creates it — as the copier itself does.
sb_busy() { [ -d "${SB_LOCK%/*}" ] || return 1; ! sb_try 9<>"$SB_LOCK"; }
sb_try()  { flock -n 9; }
sb_mark() { sed -n "s/^$1=//p" "$SB_MARK" 2>/dev/null | head -n 1; }
sb_size_b() { _sbs=0; for _sbz in "$@"; do [ -f "$_sbz" ] && _sbs=$((_sbs + $(num "$(stat -c %s "$_sbz" 2>/dev/null)"))); done; echo "$_sbs"; }
# Room a fresh copy needs: the whole container + a reserve (a `cp` cut by a full flash still gets its md5 written). ONE formula for
# status's «back on» and for `on` itself.
sb_need_b() { echo $(( $(sb_size_b "$SB_VOL") + SB_RESERVE_B )); }

# The copy's weight ON THE FLASH, estimated: UBIFS compresses, and the container's never-written part is zeros, so the bytes say
# little (BE6500: an 8-MB container, 3.8 MB freed). gzip of each file is the honest guess; it costs a second per copy, so it is
# kept in RAM per (file, size, mtime) — the copier rewrites the file only when the settings changed.
sb_est_b() {
	_seT=0; _seC=""
	for _sef in "$SB_DIR"/*; do
		[ -f "$_sef" ] || continue
		_sek="$_sef $(stat -c '%s %Y' "$_sef" 2>/dev/null)"
		_sev=$(awk -v k="$_sek" '($1 " " $2 " " $3) == k { print $4; exit }' "$SB_EST" 2>/dev/null)
		[ -n "$_sev" ] || _sev=$(gzip -c "$_sef" 2>/dev/null | wc -c)
		_sev=$(num "$(echo $_sev)")
		_seT=$((_seT + _sev)); _seC="${_seC:+$_seC
}$_sek $_sev"
	done
	lbl_commit "$SB_EST" "$_seC" 2>/dev/null
	echo "$_seT"
}

sb_status() {
	_ssP=false; sb_present && _ssP=true
	_ssF=$(sb_flag)
	_ssC=false; _ssCb=0; _ssEb=0
	if sb_copy; then _ssC=true; _ssCb=$(sb_size_b "$SB_DIR"/*); _ssEb=$(sb_est_b); fi
	_ssL=$(tf sb_live)
	_ssB=false; [ "$_ssP" = true ] && sb_busy && _ssB=true
	_ssM=false; [ -f "$SB_MARK" ] && _ssM=true
	_ssFree=$(fs_free_b "$SB_DIR")
	_ssNeed=$(sb_need_b)
	_ssMp=$(fs_mount "$SB_DIR" | tr -d '"\\')
	# The router decides, the screens only show (review s.139: the panel's own guesses read «turned off by you» with the copy back,
	# and «free space» when the container had not opened): an offer while the copier works or a copy lies there, else why not;
	# «turned off by you» only while it IS off; «back on» only for one turned off through us, and only with room for a fresh copy
	# (a copy cut short by a full flash still gets its md5 written — the stock would then «restore» a stump at boot), else why not.
	_ssO=false; _ssOw=""
	if [ "$_ssF" = 1 ] || [ "$_ssC" = true ]; then
		if [ "$_ssP" != true ]; then _ssOw=absent; elif [ "$_ssL" != true ]; then _ssOw=nolive; else _ssO=true; fi
	fi
	_ssMo=false; [ "$_ssM" = true ] && [ "$_ssF" != 1 ] && [ "$_ssC" != true ] && _ssMo=true
	_ssOn=false; _ssOnw=""
	if [ "$_ssP" != true ]; then _ssOnw=absent; elif [ "$_ssL" != true ]; then _ssOnw=nolive; elif [ "$_ssM" != true ]; then _ssOnw=notmine
	elif [ "$_ssF" = 1 ]; then _ssOnw=on; elif [ "$_ssFree" -lt "$_ssNeed" ]; then _ssOnw=space; else _ssOn=true; fi
	printf '{"present":%s,"flag":"%s","copy":%s,"copy_b":%s,"est_b":%s,"live":%s,"busy":%s,"mine":%s,"at":%s,"freed_b":%s,"free_b":%s,"need_b":%s,"mp":"%s","offer":%s,"off_why":"%s","off_mine":%s,"can_on":%s,"on_why":"%s"}\n' \
		"$_ssP" "$_ssF" "$_ssC" "$_ssCb" "$_ssEb" "$_ssL" "$_ssB" "$_ssM" "$(num "$(sb_mark at)")" "$(num "$(sb_mark freed)")" \
		"$_ssFree" "$_ssNeed" "$_ssMp" "$_ssO" "$_ssOw" "$_ssMo" "$_ssOn" "$_ssOnw"
}

# Freed space by FACT: the df delta of the copy's volume. UBIFS hands blocks back lazily — asked again each second until something
# came back and then two asks in a row add nothing (≤ SB_FREE_WAIT s).
sb_freed() {
	_sfm=0; _sfi=0; _sfs=0
	while [ "$_sfi" -lt "$SB_FREE_WAIT" ]; do
		_sfd=$(( $(fs_free_b "$SB_DIR") - $1 ))
		if [ "$_sfd" -gt "$_sfm" ]; then _sfm=$_sfd; _sfs=0
		else _sfs=$((_sfs + 1)); [ "$_sfs" -ge 2 ] && [ "$_sfm" -gt 0 ] && break; fi
		_sfi=$((_sfi + 1)); sleep 1
	done
	echo "$_sfm"
}

sb_now() {   # the moment for the marker; 0 while the clock is not trusted (the panel then shows no date)
	if command -v clock_sane >/dev/null 2>&1 && ! clock_sane; then echo 0; else num "$(date +%s 2>/dev/null)"; fi
}

# off — run with the copier's lock on fd 9 (sb_off opens it). $1: user | heal.
sb_off_locked() {
	sb_try || { no busy; return 1; }
	_soW=$(sb_flag)
	_soHad=false; sb_copy && _soHad=true
	[ "$_soW" = 1 ] || [ "$_soHad" = true ] || { no nothing; return 1; }
	# What the flag was BEFORE us survives a second «off» (heal after a firmware update): the first marker keeps it — unless the
	# firmware has set it to 1 since. Uninstall returns the router to STOCK (user's decision 15.10.2026), and the stock now is 1:
	# a «was 0» kept from a leftover copy would leave the copy off for good after the firmware chose it on (review s.139, A8).
	_soNew=1; [ -f "$SB_MARK" ] && _soNew=0
	_soWas=$(sb_mark was); [ "$_soNew" = 1 ] && _soWas=$_soW
	[ "$_soW" = 1 ] && _soWas=1
	# …and WHEN the person chose it: the panel says «выключена вами <date>», and heal's re-off is not their choice (walk s.139)
	_soAt=$(sb_mark at); [ "$_soNew" = 1 ] && _soAt=$(sb_now)
	# `done=1` — the person's «off» went all the way (the marker's last write). A re-off keeps what the person's off freed (the panel's
	# «освобождено N» is theirs), and only a re-off of a DONE off with the flag back at 1 is news from the firmware (review s.139 r2:
	# a cut between the marker and `uci commit` read «прошивка снова включила»).
	_soDone=$(sb_mark done); [ "$_soNew" = 1 ] && _soDone=0
	# A marker of the first build (1.2.0-dev.24) has no `done=` line at all: it was written only by a finished off (review s.139 r3, F6).
	[ "$_soNew" = 0 ] && ! grep -q '^done=' "$SB_MARK" 2>/dev/null && _soDone=1
	_soFrP=$(num "$(sb_mark freed)"); [ "$_soNew" = 1 ] && _soFrP=0
	_soF0=$(fs_free_b "$SB_DIR")
	# THE INTENT FIRST: a pass cut halfway (power, a killed caller) leaves the marker, and heal finishes it at the next boot — the
	# other order could leave the flag at 0 with nothing saying it was 1, and uninstall would never put it back. On a flash full to
	# the last block the marker may not land: the removal goes on (it is what frees the room), and the marker is written after it.
	# A state dir that takes no writes for another reason than a full flash (a drive gone read-only) would keep no choice at all —
	# no row, no way back, no heal (review s.139 r2): refused BEFORE the flag. A FULL flash is the one case let through — the removal
	# is what frees the room, and the dir and the marker are made after it — also when the wizard's state dir cannot even be made yet
	# (a fresh router full to the last block: review s.139 r3). The probe is `touch`, not a shell redirection: a stand can make it say
	# ENOSPC (busybox ash and its touch applet print the same strerror: «No space left on device» · «Read-only file system»).
	_soFull=0
	if [ ! -d "$ENODIA_STATE" ]; then
		[ "$SB_MKSTATE" = 1 ] || { no nostate; return 1; }   # only the wizard (before the install) may make it
		_soPe=$(mkdir -p "$ENODIA_STATE" 2>&1) || case "$_soPe" in *'No space'*|*'space left'*) _soFull=1 ;; *) no nostate; return 1 ;; esac
	fi
	if [ "$_soFull" = 0 ]; then
		_soPr="$ENODIA_STATE/.stock-backup-probe.$$"
		if ! _soPe=$(touch "$_soPr" 2>&1); then
			case "$_soPe" in *'No space'*|*'space left'*) _soFull=1 ;; *) no nostate; return 1 ;; esac
		fi
		rm -f "$_soPr" 2>/dev/null
	fi
	lbl_commit "$SB_MARK" "$(printf 'was=%s\nat=%s\nfreed=%s\ndone=%s' "$_soWas" "$_soAt" "$_soFrP" "$_soDone")" 2>/dev/null
	if [ "$_soW" = 1 ] && ! sb_set 0; then
		[ "$_soNew" = 1 ] && lbl_commit "$SB_MARK" "" 2>/dev/null   # refused: no intent left behind
		no uci; return 1
	fi
	rm -rf "$SB_DIR" 2>/dev/null; sync
	# The flag is already 0: what stays will not grow, but the megabytes were not given back — said, not hidden.
	sb_copy && { no rm; return 1; }
	# No copy before us (the flag at 1, the stock's pass not come yet) — nothing was freed and nothing will be: no waiting for UBIFS.
	_soFr=0; [ "$_soHad" = true ] && _soFr=$(sb_freed "$_soF0")
	_soFrM=$_soFr; [ "$_soDone" = 1 ] && _soFrM=$_soFrP
	[ -d "$ENODIA_STATE" ] || mkdir -p "$ENODIA_STATE" 2>/dev/null   # a full flash that took no dir before the removal has room now
	lbl_commit "$SB_MARK" "$(printf 'was=%s\nat=%s\nfreed=%s\ndone=1' "$_soWas" "$_soAt" "$_soFrM")" 2>/dev/null
	# The event says «the firmware turned it back on» — only when it DID: the person's off had gone all the way and the flag is 1
	# again. A heal that finishes an «off» cut halfway, or retries a failed removal, is no news from the firmware (review s.139).
	if [ "$1" = heal ] && [ "$_soW" = 1 ] && [ "$_soDone" = 1 ] && [ -f "$ENODIA_DIR/events.sh" ]; then
		if [ "$_soHad" = true ]; then _soEv="Вы её выключали — выключил снова: освобождено $((_soFr / 1024)) КБ."
		else _soEv="Вы её выключали — выключил снова, пока она не успела сделать новую копию."; fi
		sh "$ENODIA_DIR/events.sh" add stockbak-reoff 0 "Прошивка снова включила копию своих настроек" \
			"$_soEv Обычно так бывает после обновления прошивки." >/dev/null 2>&1
	fi
	if [ "$_soHad" != true ]; then _som="копия настроек прошивки выключена: копии ещё не было — прошивка её не сделает"
	elif [ "$_soFr" -gt 0 ]; then _som="копия настроек прошивки выключена: освобождено $(hum "$_soFr") на флеше"
	else _som="копия настроек прошивки выключена; место флеш отдаст чуть позже"; fi
	# The choice not remembered (the marker did not land even after the removal freed room): said in the same answer, with the only
	# way back — the panel will not show a row for it, heal will not re-apply it, uninstall will not know what to put back.
	_soMk=$(tf test -f "$SB_MARK")
	[ "$_soMk" = true ] || _som="$_som; выбор не запомнился — после обновления прошивки копия может вернуться, а включить её обратно можно только вручную: uci set misc.features.sec_cfg_bak=1; uci commit misc"
	printf '{"ok":true,"freed_b":%s,"had":%s,"marked":%s,"msg":"%s"}\n' "$_soFr" "$_soHad" "$_soMk" "$_som"
}
sb_off() {
	sb_present || { no absent; return 1; }
	sb_live || { no nolive; return 1; }
	mkdir -p "${SB_LOCK%/*}" 2>/dev/null
	_sbo=$(sb_off_locked "$1" 9<>"$SB_LOCK" 2>/dev/null)
	[ -n "$_sbo" ] || _sbo=$(no busy)   # the lock's fd could not even be opened: the same words as a held lock
	printf '%s\n' "$_sbo"
	case "$_sbo" in *'"ok":true'*) return 0 ;; esac; return 1
}

# on — the flag and the marker under the copier's lock on fd 9 (sb_on opens it), as off does: an «on» landing while an off or heal
# is in flight (a second tab) answered «включена», then the off rewrote its marker, and the next boot undid the person's «on» with a
# false «прошивка снова включила» (review s.139 r2). Prints `already` | `set` or a refusal's JSON.
sb_on_locked() {
	sb_try || { no busy; return 1; }
	[ -f "$SB_MARK" ] || { no notmine; return 1; }
	# The marker must GO for «on» to stick: left behind (a state dir gone read-only), the next boot's heal would turn the copy off
	# again and blame the firmware (review s.139 r3, F3). Asked BEFORE the flag; a removal that still fails puts the flag back.
	[ -w "$ENODIA_STATE" ] || { no nostate; return 1; }
	# The flag at 1 already (a firmware update brought it back, heal not run yet): it IS on — the person's «back on» only drops the
	# marker. The copier is not run here: the room was never checked, and the stock's own pass does exactly that (review s.139, A6).
	if [ "$(sb_flag)" = 1 ]; then lbl_commit "$SB_MARK" "" 2>/dev/null || { no nostate; return 1; }; echo already; return 0; fi
	[ "$(fs_free_b "$SB_DIR")" -ge "$(sb_need_b)" ] || { no space; return 1; }
	sb_set 1 || { no uci; return 1; }
	lbl_commit "$SB_MARK" "" 2>/dev/null || { sb_set 0; no nostate; return 1; }
	echo set
}
sb_on() {
	sb_present || { no absent; return 1; }
	sb_live || { no nolive; return 1; }
	mkdir -p "${SB_LOCK%/*}" 2>/dev/null
	_sbn=$(sb_on_locked 9<>"$SB_LOCK" 2>/dev/null)
	case "$_sbn" in
		already) printf '{"ok":true,"copy":%s,"msg":"%s"}\n' "$(tf sb_copy)" "копия настроек прошивки уже включена прошивкой"; return 0 ;;
		set) ;;
		'') no busy; return 1 ;;
		*) printf '%s\n' "$_sbn"; return 1 ;;
	esac
	# The copy NOW (the lock let go — the copier takes it itself), under our eyes and with the room just checked: the stock's own pass
	# may come at any of the next six hours, when the flash may be fuller. Busy means it is copying already.
	sh "$SB_SCRIPT" >/dev/null 2>&1
	if sb_copy; then _som="копия настроек прошивки включена и сделана"
	else _som="копия настроек прошивки включена — прошивка сделает её при следующем проходе"; fi
	printf '{"ok":true,"copy":%s,"msg":"%s"}\n' "$(tf sb_copy)" "$_som"
}

sb_heal() {
	[ -f "$SB_MARK" ] || return 0
	sb_present || return 0
	[ "$(sb_flag)" = 1 ] || sb_copy || return 0
	# A boot hook may be copying right now (BE6500's inited hook, BE7000's /etc/luci_post_init.d/99-sec_cfg_bak.sh — the same copier
	# under the same lock): wait for it — up to a minute, never longer (a boot heal and the panel's replay wait on this).
	_shi=0
	while :; do
		_sho=$(sb_off heal)
		case "$_sho" in *'"why":"busy"'*) ;; *) break ;; esac
		_shi=$((_shi + 1)); [ "$_shi" -lt 30 ] || break
		sleep 2
	done
	printf '%s\n' "$_sho"
}

# uninstall — prints what it did, uninstall.sh logs by it: restored (the flag back at 1) · kept (it was off before us) · kept-absent
# (it was on, but this firmware has no such copy any more) · `fail-flag 1` (the flag could not be put back) · `fail-mark <done>`
# (the flag is as it should be, only the marker could not be removed; <done> — what was done before). Review s.139 r3, F5.
# What «before us» means: the flag as the person's LAST off found it, or 1 once the firmware set it — uninstall returns the router to
# stock (user's decision 15.10.2026: «the flag goes back to 1»). An off → on → off made through us on a router whose flag was unset
# also ends at 1: the second off found the person's own 1 (review s.139 r2, F6 — within the decision's own words).
sb_uninstall() {
	[ -f "$SB_MARK" ] || return 0
	_suW=$(sb_mark was)
	if [ "$_suW" = 1 ]; then
		if sb_present; then
			[ "$(sb_flag)" = 1 ] || sb_set 1 || { echo "fail-flag 1"; return 1; }
			_suR=restored
		else _suR=kept-absent; fi
	else _suR=kept; fi
	lbl_commit "$SB_MARK" "" || { echo "fail-mark $_suR"; return 1; }
	echo "$_suR"
}

case "${1:-}" in
	status)    sb_status ;;
	off)       sb_off user ;;
	on)        sb_on ;;
	heal)      sb_heal ;;
	uninstall) sb_uninstall ;;
	*)         echo "usage: stock-backup.sh status|off|on|heal|uninstall" >&2; exit 2 ;;
esac
