# Newtpad installer. Builds release, copies the exe to a stable location, and
# registers it with Explorer's "Open with" menu.
#
# Everything it writes lives under HKCU (per-user, no admin) and is removed by
# `install.ps1 -Uninstall`. It deliberately does NOT try to seize the default
# .txt handler: Windows 10/11 protect that with a tamper-checked UserChoice hash,
# so the honest path is to appear in "Open with" and let you pick "Always use
# this app" once. See the note printed at the end.
#
#   .\install.ps1              build release, install, register
#   .\install.ps1 -SkipBuild   install whatever is already in build\
#   .\install.ps1 -Uninstall   remove the registration, the exe, and the PATH entry
#   .\install.ps1 -Force       stop a running Newtpad instead of bailing out

param(
    [switch]$Uninstall,
    [switch]$SkipBuild,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'Newtpad'
$ExePath    = Join-Path $InstallDir 'newtpad.exe'
$AppKey     = 'HKCU:\Software\Classes\Applications\newtpad.exe'

# Text-ish types Newtpad opens natively, listed under SupportedTypes so Explorer
# offers Newtpad in "Open with" for them. Single source of truth: text_exts.txt at
# the repo root (also #load'ed by src/program/links.odin), so the "open in a tab"
# set and the registered set can never drift.
$Extensions = Get-Content (Join-Path $PSScriptRoot 'text_exts.txt') |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

function Stop-Newtpad {
    $running = Get-Process newtpad -ErrorAction SilentlyContinue
    if (-not $running) { return }
    if (-not $Force) {
        throw "Newtpad is running (PID $($running.Id -join ', ')). Close it first, or re-run with -Force."
    }
    Write-Host "Stopping running Newtpad (PID $($running.Id -join ', '))..."
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 400
}

function Remove-FromUserPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { return }
    $kept = $userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $InstallDir.TrimEnd('\') }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
}

# --- uninstall ---------------------------------------------------------------

if ($Uninstall) {
    Stop-Newtpad
    if (Test-Path $AppKey) { Remove-Item $AppKey -Recurse -Force }
    foreach ($ext in $Extensions) {
        $owl = "HKCU:\Software\Classes\$ext\OpenWithList\newtpad.exe"
        if (Test-Path $owl) { Remove-Item $owl -Recurse -Force }
    }
    Remove-FromUserPath
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    Write-Host ""
    Write-Host "Newtpad uninstalled." -ForegroundColor Green
    Write-Host "Session state in %APPDATA%\Newtpad was left alone - delete it by hand if you want it gone."
    return
}

# --- build -------------------------------------------------------------------

if (-not $SkipBuild) {
    Write-Host "Building release..."
    & (Join-Path $PSScriptRoot 'build.bat') release
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
}

$source = Join-Path $PSScriptRoot 'build\newtpad.exe'
if (-not (Test-Path $source)) { throw "no exe at $source - run without -SkipBuild" }

# --- install -----------------------------------------------------------------

Stop-Newtpad
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory $InstallDir | Out-Null }
Copy-Item $source $ExePath -Force

$size = [math]::Round((Get-Item $ExePath).Length / 1MB, 2)
Write-Host "Installed $ExePath ($size MB)"

# --- register with Explorer --------------------------------------------------

New-Item -Path "$AppKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$AppKey\shell\open\command" -Name '(default)' -Value "`"$ExePath`" `"%1`""
Set-ItemProperty -Path $AppKey -Name 'FriendlyAppName' -Value 'Newtpad'

New-Item -Path "$AppKey\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$AppKey\DefaultIcon" -Name '(default)' -Value "`"$ExePath`",0"

# SupportedTypes drives which files offer Newtpad in "Open with"; the per-
# extension OpenWithList keys make it show up without "Choose another app".
New-Item -Path "$AppKey\SupportedTypes" -Force | Out-Null
foreach ($ext in $Extensions) {
    Set-ItemProperty -Path "$AppKey\SupportedTypes" -Name $ext -Value ''
    New-Item -Path "HKCU:\Software\Classes\$ext\OpenWithList\newtpad.exe" -Force | Out-Null
}

# --- PATH --------------------------------------------------------------------

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $InstallDir) {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$InstallDir".Trim(';'), 'User')
    Write-Host "Added $InstallDir to your user PATH (new shells only)."
}

Write-Host ""
Write-Host "Newtpad installed." -ForegroundColor Green
Write-Host ""
Write-Host "To make it the default for a file type (one time, per extension):"
Write-Host "  right-click a .txt -> Open with -> Choose another app -> Newtpad -> Always"
Write-Host ""
Write-Host "Windows guards the default-handler setting with a tamper-checked hash,"
Write-Host "so no installer can set it for you - that click is unavoidable."
Write-Host ""
Write-Host "Uninstall with:  .\install.ps1 -Uninstall"
