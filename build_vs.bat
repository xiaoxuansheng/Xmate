@echo off
call "D:\Visual Studio\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "%~dp0"
flutter build windows --debug 2>&1
