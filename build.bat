@echo off
REM Newtpad build script. One script, no build-system sprawl.
REM Usage: build.bat [release] [run]
REM   (default = -debug with symbols; "release" = -o:speed; "run" launches after)

setlocal enabledelayedexpansion
if not exist build mkdir build

REM Two artifacts need MSVC tooling: the SEH shim (cl) and the manifest resource
REM (rc). Both are compiled once and cached, and both need the same vcvars
REM environment, so one check covers them. IF YOU EDIT guarded_copy.c OR
REM newtpad.manifest, delete the matching file in build\ to force a rebuild.
set "NEED_MSVC="
if not exist build\guarded.obj set "NEED_MSVC=1"
if not exist build\newtpad.res set "NEED_MSVC=1"
if defined NEED_MSVC call :msvc_artifacts || exit /b 1

REM Release is the shipped app: GUI subsystem, so launching it never flashes a
REM console window. Debug keeps the console subsystem because the headless test
REM modes (test_modes.odin) print their results to stdout.
set "OPT=-debug"
if "%1"=="release" set "OPT=-o:speed -subsystem:windows"

REM -resource embeds newtpad.res, which carries the application manifest
REM declaring per-monitor-v2 DPI awareness. Building without it (a bare
REM `odin build src\program`) yields a DPI-unaware exe that renders bitmap-
REM stretched on non-96-DPI displays -- fine for the headless test modes, wrong
REM for anything you look at.
odin build src\program -out:build\newtpad.exe %OPT% -collection:src=src -resource:build\newtpad.res
if errorlevel 1 exit /b 1

if "%1"=="run" build\newtpad.exe
if "%2"=="run" build\newtpad.exe
exit /b 0

REM --- cl/rc need their own env, so locate MSVC via vswhere and build both ---
:msvc_artifacts
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
	echo build: vswhere not found - install Visual Studio C++ tools
	exit /b 1
)
REM Note: this line prints a harmless "'vswhere.exe' is not recognized" to stderr
REM (the sub-shell re-parses the "(x86)" in the path) yet still resolves VSPATH,
REM so the build succeeds. Only exercised when build\ is empty. If VSPATH ever
REM comes back unset the check below catches it -- don't read that message as the
REM failure.
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -prerelease -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH (
	echo build: could not locate a Visual Studio install via vswhere
	exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
if not exist build\guarded.obj (
	cl /nologo /c /O2 /Fobuild\guarded.obj src\platform\guarded_copy.c
	if errorlevel 1 exit /b 1
)
if not exist build\newtpad.res (
	rc /nologo /I src\platform /fo build\newtpad.res src\platform\newtpad.rc
	if errorlevel 1 exit /b 1
)
exit /b 0
