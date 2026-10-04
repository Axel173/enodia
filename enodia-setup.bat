@echo off
setlocal
chcp 65001 > nul
title Enodia - установка
REM Лаунчер Enodia (ПК-сторона). Двойной клик открывает МАСТЕР УСТАНОВКИ в браузере
REM (enodia.py --wizard) — это основной и единственный путь для человека. Текстовое меню
REM (диагностика, служебные операции) — enodia-setup.bat cli. Перетащенные на .bat файлы
REM прокидываются дальше: drag-and-drop конфигов работает как раньше.
REM
REM ИМЯ ФАЙЛА — ASCII И БЕЗ ПРОБЕЛОВ НАМЕРЕННО. Кириллица в имени .bat ломается ровно там,
REM где её нельзя проверить (архиватор с чужой кодировкой, чужая локаль cmd), а пробелы
REM заставляют кавычить путь везде, где лаунчер упоминается в доках и в панели.
REM
REM ДВЕ ГРАБЛИ CMD, ИЗ-ЗА КОТОРЫХ ФАЙЛ ВЫГЛЯДИТ СТРАННО (обе замерены здесь же):
REM  1. БЕЗ BOM. cmd читает первую строку вместе с BOM и спотыкается: «"@echo" не является
REM     внутренней или внешней командой», echo остаётся ВКЛЮЧЁННЫМ, и человек видит простыню
REM     из этих самых комментариев. Правило «UTF-8 с BOM» в проекте — про *.ps1 (PS5 без него
REM     читает кириллицу как CP1251), к *.bat оно не относится.
REM  2. НИКАКИХ СКОБОЧНЫХ БЛОКОВ if ( … ) с кириллицей внутри. Блок cmd разбирает целиком и
REM     по БАЙТОВЫМ смещениям, а после chcp 65001 смещения многобайтового текста уезжают:
REM     строки рвутся посередине, и их обрывки исполняются как команды («'мигнувший' is not
REM     recognized»). Поэтому ветвление ниже — на goto, а не на скобках.
REM
REM ПОЧЕМУ ЗДЕСЬ НЕТ ОТКАТА НА be7000.ps1. Раньше без Python лаунчер молча запускал
REM ЗАМОРОЖЕННЫЙ монолит поколением старше. Человек получал свежую панель и старые скрипты
REM роутера, а сообщения об этом не было ВООБЩЕ. Монолит выведен из обращения.
REM
REM НЕТ PYTHON — СТАВИМ ЕГО САМИ ЧЕРЕЗ uv (решение пользователя 30.09.2026). uv — один
REM файл от Astral: он скачивает Python и зависимости (paramiko, keyring) в свой кэш и
REM запускает enodia.py, ничего не ставя в систему и не трогая PATH. Версия uv ПРИШПИЛЕНА,
REM архив сверяется по sha256 (суммы — из релиза uv на GitHub, поле digest); не сошлось —
REM не запускаем. Всё лежит в %LOCALAPPDATA%\enodia\uv (удалить папку = убрать след).
REM Вшить Python в архив проекта отвергнуто (+100 МБ, чужие уязвимости на нас), exe-сборку
REM тоже (антивирусы, платная подпись). Нет сети — прежняя ОСТАНОВКА с объяснением.
set "PYEXE="
where py >nul 2>nul && set "PYEXE=py -3"
if defined PYEXE goto haspy
REM `python` в PATH Windows 10/11 по умолчанию — ЗАГЛУШКА Microsoft Store: она ничего не
REM запускает, открывает магазин и выходит с кодом 49. Поэтому мало найти файл — надо
REM УБЕДИТЬСЯ, что он работает: настоящий интерпретатор ответит на -V нулём.
where python >nul 2>nul || goto uvsetup
python -V >nul 2>nul || goto uvsetup
set "PYEXE=python"

:haspy
REM Без аргументов — мастер в браузере. "cli" — текстовое меню. Прочее (--exec/--push) прокидываем.
if "%~1"=="" goto wizard
if /I "%~1"=="cli" goto cli
%PYEXE% "%~dp0enodia.py" %*
REM Упавший скрипт не должен уносить с собой сообщение об ошибке.
if errorlevel 1 pause
goto done

:wizard
%PYEXE% "%~dp0enodia.py" --wizard
if errorlevel 1 pause
goto done

:cli
%PYEXE% "%~dp0enodia.py" --cli
if errorlevel 1 pause
goto done

:uvsetup
REM Архитектура — по двум переменным: 32-битный cmd на 64-битной Windows видит x86 в
REM PROCESSOR_ARCHITECTURE, а настоящую — в PROCESSOR_ARCHITEW6432. x86 без второй — это
REM настоящая 32-битная Windows: у uv для неё своя сборка (i686).
set "UVVER=0.12.21"
set "UVARCH="
if /I "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "UVARCH=x86_64"
if /I "%PROCESSOR_ARCHITEW6432%"=="AMD64" set "UVARCH=x86_64"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "UVARCH=aarch64"
if /I "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "UVARCH=aarch64"
if not defined UVARCH if /I "%PROCESSOR_ARCHITECTURE%"=="x86" set "UVARCH=i686"
if not defined UVARCH goto nopython
if "%UVARCH%"=="x86_64" set "UVSHA=5d223efa0bf00208c3853246af09420419dfbd352536aa6bb8163d6170e23890"
if "%UVARCH%"=="aarch64" set "UVSHA=93ed53b94e9cec000cacdfd18ca67bc4cb2b6a5f5ec041edd7f2a3dae365ce79"
if "%UVARCH%"=="i686" set "UVSHA=66b7ffe136362b8522748c4d43b7e82b846e37e4e9272fcfadffaad8bf7b5a75"
set "UVURL=https://github.com/astral-sh/uv/releases/download/%UVVER%/uv-%UVARCH%-pc-windows-msvc.zip"
set "UVHOME=%LOCALAPPDATA%\enodia\uv"
set "UVDIR=%UVHOME%\%UVVER%-%UVARCH%"
set "UVEXE=%UVDIR%\uv.exe"
if exist "%UVEXE%" goto uvrun
echo.
echo   Python не найден — поставлю его сам через uv (около 18 МБ, один раз).
echo   Python was not found — setting it up via uv (about 18 MB, once).
echo.
REM Качает и сверяет PowerShell (есть в каждой Windows 10/11). Пути и сумма едут ему
REM ПЕРЕМЕННЫМИ ОКРУЖЕНИЯ, а не текстом команды: путь профиля с апострофом или кириллицей
REM в строке сломал бы кавычки. Скрипт — одной строкой только из ASCII (правило этого файла).
REM Распаковка — во временную папку и лишь потом на место: оборванная распаковка не должна
REM выглядеть «уже скачано».
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}; $z = Join-Path $env:TEMP ('enodia-uv-' + [guid]::NewGuid().ToString() + '.zip'); try { Invoke-WebRequest -UseBasicParsing -Uri $env:UVURL -OutFile $z } catch { Write-Host ('  [!] download failed: ' + $_.Exception.Message); exit 2 }; $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $z).Hash.ToLower(); if ($h -ne $env:UVSHA) { Remove-Item -LiteralPath $z -Force; Write-Host ('  [!] sha256 mismatch: ' + $h); exit 3 }; $t = $env:UVDIR + '.part'; if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }; Expand-Archive -LiteralPath $z -DestinationPath $t; Remove-Item -LiteralPath $z -Force; $u = Get-ChildItem -LiteralPath $t -Recurse -Filter uv.exe | Select-Object -First 1; if (-not $u) { Write-Host '  [!] uv.exe is not in the archive'; exit 4 }; if (Test-Path -LiteralPath $env:UVDIR) { Remove-Item -LiteralPath $env:UVDIR -Recurse -Force }; New-Item -ItemType Directory -Force -Path $env:UVDIR | Out-Null; Move-Item -LiteralPath $u.FullName -Destination $env:UVDIR; Remove-Item -LiteralPath $t -Recurse -Force"
if errorlevel 1 goto nopython
if not exist "%UVEXE%" goto nopython

:uvrun
REM Python и кэш uv — в НАШЕЙ папке, не в общем кэше uv человека: удалить её = убрать всё.
REM --managed-python: брать только Python, который поставил uv (в PATH может стоять
REM заглушка Microsoft Store); --no-project/--with-requirements: окружение по тому же
REM requirements.txt, что у pip-пути, без файлов в папке проекта (её распаковывают куда угодно).
set "UV_PYTHON_INSTALL_DIR=%UVHOME%\python"
set "UV_CACHE_DIR=%UVHOME%\cache"
REM БЕЗ СЕТИ ПОВТОРНЫЙ ЗАПУСК ОБЯЗАН ИДТИ (ПК в Wi-Fi роутера без интернета): uv пересверяет индекс PyPI
REM на каждом запуске (в requirements.txt диапазоны версий), и без сети падал ДО мастера (ревью с.88).
REM Окружение уже собрано — это скажет проба --offline (импорт зависимостей), тогда и запуск --offline.
set "UVOFF="
"%UVEXE%" run --offline --no-project --no-config --managed-python --python 3.12 --with-requirements "%~dp0requirements.txt" python -c "import paramiko, keyring" >nul 2>nul && set "UVOFF=--offline"
set PYEXE="%UVEXE%" run %UVOFF% --no-project --no-config --managed-python --python 3.12 --with-requirements "%~dp0requirements.txt"
goto haspy

:nopython
echo.
echo   [!] Python не найден — установить роутер нечем.
echo.
echo   Поставить его сам через uv не вышло (нет интернета или редкая архитектура).
echo   Нужен Python 3.8 или новее (он же нужен шагу открытия доступа).
echo   1. Скачайте с https://www.python.org/downloads/
echo   2. При установке ОБЯЗАТЕЛЬНО включите галочку "Add python.exe to PATH"
echo   3. Закройте это окно и запустите enodia-setup.bat заново
echo.
echo   Если Python установлен, но не виден: в PATH может стоять заглушка
echo   Microsoft Store. Выключите её в "Параметры - Приложения -
echo   Дополнительные параметры приложения - Псевдонимы выполнения приложения".
echo.
echo   --- EN ---------------------------------------------------------------
echo   Python was not found, and setting it up via uv failed (no internet or an
echo   unusual architecture), so there is nothing to install the router with.
echo   Install Python 3.8+ from https://www.python.org/downloads/ and tick
echo   "Add python.exe to PATH", then run enodia-setup.bat again. If Python is
echo   installed but invisible, disable the Microsoft Store alias in
echo   Settings - Apps - Advanced app settings - App execution aliases.
echo.
REM Окно НЕ закрываем: при запуске двойным кликом консоль исчезает вместе с текстом, и
REM человек видит только мигнувший чёрный прямоугольник — то есть ничего.
pause
exit /b 1

:done
