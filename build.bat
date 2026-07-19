@echo off
REM Newtpad build script. One script, no build-system sprawl.
REM Usage: build.bat [release] [run]
REM   (default = -debug with symbols; "release" = -o:speed; "run" launches after)

setlocal enabledelayedexpansion
if not exist build mkdir build

REM SEH shim (guarded_copy.c) -> build\guarded.obj. Compiled once; it never
REM changes. If you edit the .c, delete build\guarded.obj to force a rebuild.
if not exist build\guarded.obj call :build_shim || exit /b 1

set "OPT=-debug"
if "%1"=="release" set "OPT=-o:speed"

odin build src\program -out:build\newtpad.exe %OPT% -collection:src=src
if errorlevel 1 exit /b 1

if "%1"=="run" build\newtpad.exe
if "%2"=="run" build\newtpad.exe
exit /b 0

REM --- compile the SEH shim; cl needs its own env, so locate MSVC via vswhere ---
:build_shim
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
	echo build: vswhere not found - install Visual Studio C++ tools
	exit /b 1
)
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -prerelease -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH (
	echo build: could not locate a Visual Studio install via vswhere
	exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /c /O2 /Fobuild\guarded.obj src\platform\guarded_copy.c
if errorlevel 1 exit /b 1
exit /b 0
