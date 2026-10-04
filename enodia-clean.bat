@echo off
chcp 65001 > nul
title Enodia - /data cleanup
REM Double-click: STEP 1 shows what would be removed (dry-run, nothing deleted),
REM then waits; STEP 2 (after you press a key) actually frees /data.
REM Removes only backup/temp/archive junk of our tooling - never configs or binaries.
REM Put this .bat next to enodia-clean.py and enodia.py, then double-click.
set "PYEXE="
where py >nul 2>nul && set "PYEXE=py -3"
if not defined PYEXE (
  where python >nul 2>nul && set "PYEXE=python"
)
if not defined PYEXE (
  echo [!] Python 3 not found. Run enodia.py from a console instead.
  echo.
  pause
  goto :eof
)
echo === STEP 1/2: preview - nothing is deleted yet ===
%PYEXE% "%~dp0enodia-clean.py" --dry-run
echo.
echo === STEP 2/2: press any key to DELETE the junk listed above, or CLOSE the window to cancel ===
pause
%PYEXE% "%~dp0enodia-clean.py"
echo.
pause
