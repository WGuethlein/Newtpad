@echo off
REM Newtpad build script. One script, no build-system sprawl.
REM Usage: build.bat [run]   (append "run" to launch after a successful build)

setlocal
if not exist build mkdir build

odin build src\program -out:build\newtpad.exe -debug -collection:src=src
if errorlevel 1 exit /b 1

if "%1"=="run" build\newtpad.exe
