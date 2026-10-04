@echo off
chcp 65001 > nul
title Enodia router diag
REM Double-click launcher for enodia-diag.py: connects to the router and
REM saves an extended diagnostic dump to diag\enodia-diag-<date>.txt.
REM Put this .bat next to enodia-diag.py and enodia.py, then double-click it.
REM Keeps the window open at the end so the result path stays visible.
set "PYEXE="
where py >nul 2>nul && set "PYEXE=py -3"
if not defined PYEXE (
  where python >nul 2>nul && set "PYEXE=python"
)
if not defined PYEXE (
  echo [!] Python 3 not found. It is installed during beta Step 1 / xmir-patcher.
  echo     Make sure that step finished, or run enodia.py from a console.
  echo.
  pause
  goto :eof
)
%PYEXE% "%~dp0enodia-diag.py"
echo.
pause
