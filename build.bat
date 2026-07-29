@echo off
REM Newtpad build script. One script, no build-system sprawl.
REM Usage: build.bat [release] [run]
REM   (default = -debug with symbols; "release" = -o:speed; "run" launches after)

setlocal enabledelayedexpansion
if not exist build mkdir build

REM Two artifacts need MSVC tooling: the SEH shim (cl) and the manifest resource
REM (rc). Both are compiled once and cached, and both need the same vcvars
REM environment, so one check covers them.
REM
REM The cache is invalidated by TIMESTAMP, not just by absence. It used to be
REM absence only, which meant editing newtpad.rc, the manifest or the icon left
REM a stale build\newtpad.res in place and the build silently shipped the old
REM resource. That cost a wrong release-size measurement the day the icon
REM landed, and would have shipped a stale icon just as quietly.
REM IF YOU EDIT guarded_copy.c, delete build\guarded.obj to force a rebuild.
set "NEED_MSVC="
if not exist build\guarded.obj set "NEED_MSVC=1"
if not exist build\newtpad.res set "NEED_MSVC=1"
if exist build\newtpad.res (
	set "RES_STALE="
	for /f "usebackq delims=" %%T in (`powershell -NoProfile -ExecutionPolicy Bypass -File tools\res-stale.ps1`) do set "RES_STALE=%%T"
	if "!RES_STALE!"=="stale" (
		del /q build\newtpad.res
		set "NEED_MSVC=1"
	)
)
if defined NEED_MSVC call :msvc_artifacts || exit /b 1

REM Release is the shipped app: GUI subsystem, so launching it never flashes a
REM console window. Debug keeps the console subsystem because the headless test
REM modes (test_modes.odin) print their results to stdout.
REM
REM The harness is `package main`, so it ships inside whatever exe is built.
REM `release` gates it out via NEWTPAD_TESTS (see test_modes.odin). `release tests`
REM is the way back in: some measurements are only meaningful against an -o:speed
REM build (a held key over a 300-row column rectangle, HANDOFF 6y), and gating
REM without this row would make that class of measurement impossible. It keeps the
REM console subsystem, or the modes would have nowhere to print.
set "OPT=-debug"
if "%1"=="release" set "OPT=-o:speed -subsystem:windows -define:NEWTPAD_TESTS=false"
if "%1"=="release" if "%2"=="tests" set "OPT=-o:speed -define:NEWTPAD_TESTS=true"

REM -resource embeds newtpad.res, which carries the application manifest
REM declaring per-monitor-v2 DPI awareness. Building without it (a bare
REM `odin build src\program`) yields a DPI-unaware exe that renders bitmap-
REM stretched on non-96-DPI displays -- fine for the headless test modes, wrong
REM for anything you look at.
REM
REM -extra-linker-flags "/STACK:8388608" raises the thread stack from the
REM 1 MB default to 8 MB. test_modes.odin is one enormous procedure with many
REM nested test procs, each getting its own Odin stack frame on top of
REM test_mode_dispatch's already-large one; `blocktest` has hit a real
REM STATUS_STACK_OVERFLOW twice from this (see docs/development-loop.md).
REM This one flag (applies to both debug and release, since both go through
REM this same invocation via %OPT%) raises the ceiling so the next added test
REM case doesn't crash with a cause that's invisible from the error alone.
odin build src\program -out:build\newtpad.exe %OPT% -collection:src=src -resource:build\newtpad.res -extra-linker-flags:"/STACK:8388608"
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
