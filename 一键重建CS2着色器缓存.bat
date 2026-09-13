@echo off
title CS2 Shader Cache Rebuild
rem Launcher: one-click rebuild CS2 shader cache (see README.md)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Rebuild-CS2ShaderCache.ps1" %*
pause
