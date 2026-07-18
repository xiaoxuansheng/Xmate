@echo off
call "D:\Visual Studio\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d e:\AI\XMate
D:\Tool\Flutter\flutter\bin\flutter build windows --debug 2>&1
