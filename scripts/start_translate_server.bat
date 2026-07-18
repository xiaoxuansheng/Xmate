@echo off
REM XMate - LibreTranslate Server Launcher
REM Start with all installed models. Pass extra --load-only codes on command line.
cd /d "%~dp0"
echo Starting LibreTranslate Server on http://127.0.0.1:5000
echo Default: en,zh. Override with: start_translate_server.bat en,zh,ja,de,fr
echo.
set LOAD=en,zh
if not "%1"=="" set LOAD=%*
python -m libretranslate --host 127.0.0.1 --port 5000 --load-only %LOAD% --disable-web-ui
pause
