# Builds installer\newtpad.iss into build\newtpad-<version>-setup.exe.
#
# Its own script rather than only a switch on release.ps1, because the setup.exe
# has to be buildable and testable without cutting a release: the only real test
# of an installer is running it, and tagging + publishing a GitHub Release to get
# one to try would be absurd. release.ps1 -Installer just calls this.
#
# Inno Setup is a build-time dependency and nothing more - it never ships inside
# the exe. It is also NOT required: if ISCC.exe is absent this script says how to
# get it, skips, and exits 0, so neither build.bat nor release.ps1 ever fails for
# want of it. build.bat is untouched and stays a single Odin invocation.
#
#   .\build-installer.ps1             build release, then the setup.exe
#   .\build-installer.ps1 -SkipBuild  use whatever exe is already in build\
#   .\build-installer.ps1 -DryRun     run the checks and the ISCC probe only
#
# ASCII only in every string literal. PowerShell 5.1 decodes a BOM-less .ps1 as
# ANSI, and an em dash in release.ps1 once shipped as mojibake into published
# release notes.

param(
    [switch]$SkipBuild,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$issPath  = Join-Path $PSScriptRoot 'installer\newtpad.iss'
$extsPath = Join-Path $PSScriptRoot 'text_exts.txt'
$licPath  = Join-Path $PSScriptRoot 'LICENSE.txt'
$buildDir = Join-Path $PSScriptRoot 'build'
$exePath  = Join-Path $buildDir 'newtpad.exe'

foreach ($required in @($issPath, $extsPath, $licPath)) {
    if (-not (Test-Path $required)) { Write-Error "Missing $required"; exit 1 }
}

# --- version (same single source of truth release.ps1 uses) ------------------
$verLine = Select-String -Path 'src\program\version.odin' -Pattern 'NEWTPAD_VERSION\s*::\s*"([^"]+)"'
if (-not $verLine) { Write-Error 'Could not find NEWTPAD_VERSION in src\program\version.odin'; exit 1 }
$version = $verLine.Matches[0].Groups[1].Value
$setupExe = Join-Path $buildDir "newtpad-$version-setup.exe"

# --- the .iss registration list must match text_exts.txt ---------------------
#
# The .iss spells the extensions out literally instead of reading text_exts.txt
# with an ISPP loop, because that idiom is syntax-fragile and cannot be compiled
# on a machine without Inno Setup. This check buys back what the duplication
# costs, and unlike the .iss it can actually be run here.
function Get-IssExtensions {
    param([string]$Path, [string]$Pattern)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in (Select-String -Path $Path -Pattern $Pattern)) {
        $out.Add($m.Matches[0].Groups[1].Value)
    }
    return , $out.ToArray()
}

function Compare-ExtensionLists {
    param([string[]]$Expected, [string[]]$Actual, [string]$What)
    $missing = @($Expected | Where-Object { $Actual -notcontains $_ })
    $extra   = @($Actual   | Where-Object { $Expected -notcontains $_ })
    $bad = $false
    if ($missing.Count -gt 0) {
        Write-Host "  $What is missing: $($missing -join ' ')" -ForegroundColor Red
        $bad = $true
    }
    if ($extra.Count -gt 0) {
        Write-Host "  $What has extras: $($extra -join ' ')" -ForegroundColor Red
        $bad = $true
    }
    if (-not $bad -and (($Expected -join ',') -ne ($Actual -join ','))) {
        Write-Host "  $What has the right extensions in a different order" -ForegroundColor Yellow
    }
    return (-not $bad)
}

$expected = @(Get-Content $extsPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

$supported = Get-IssExtensions $issPath 'SupportedTypes"; ValueType: string; ValueName: "([^"]+)"'
$openWith  = Get-IssExtensions $issPath 'Subkey: "Software\\Classes\\([^"\\]+)\\OpenWithList\\newtpad\.exe"'

$ok = $true
if (-not (Compare-ExtensionLists $expected $supported 'SupportedTypes')) { $ok = $false }
if (-not (Compare-ExtensionLists $expected $openWith  'OpenWithList'))   { $ok = $false }

# The three non-extension registrations install.ps1 writes. Spot-check that
# nobody deleted one while editing the long list above them.
$issText = Get-Content $issPath -Raw
foreach ($needle in @('FriendlyAppName', 'DefaultIcon', 'shell\open\command')) {
    if ($issText -notlike "*$needle*") {
        Write-Host "  newtpad.iss no longer registers $needle" -ForegroundColor Red
        $ok = $false
    }
}

if (-not $ok) {
    Write-Error 'installer\newtpad.iss does not match install.ps1 (via text_exts.txt). Fix the .iss.'
    exit 1
}
Write-Host "Registration list matches text_exts.txt ($($expected.Count) extensions)." -ForegroundColor Green

# --- find ISCC; absent is a skip, not a failure ------------------------------
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        # winget installs Inno Setup PER-USER by default, not into Program Files.
        # Checking only the two machine-wide paths meant the tool could be
        # installed and the script would still report it missing and skip -- a
        # silent skip that looks exactly like not having it at all.
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )) {
        if ((-not $iscc) -and $candidate -and (Test-Path $candidate)) { $iscc = $candidate }
    }
}
if (-not $iscc) {
    Write-Host ''
    Write-Host 'Inno Setup (ISCC.exe) was not found on PATH or at either default install path.' -ForegroundColor Yellow
    Write-Host 'No setup.exe was built. This is a skip, not a failure - the portable exe is' -ForegroundColor Yellow
    Write-Host 'the primary artifact and does not need an installer.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  winget install JRSoftware.InnoSetup'
    Write-Host ''
    exit 0
}
Write-Host "Found ISCC: $iscc" -ForegroundColor Green

if ($DryRun) {
    Write-Host "[dry run] would build $setupExe"
    exit 0
}

# --- the exe the installer wraps ---------------------------------------------
if (-not $SkipBuild) {
    Write-Host 'Building release...' -ForegroundColor Cyan
    $bat = Join-Path $PSScriptRoot 'build.bat' # absolute: cmd does not search the cwd
    cmd /c "`"$bat`" release"
    if ($LASTEXITCODE -ne 0) { Write-Error 'Release build failed.'; exit 1 }
}
if (-not (Test-Path $exePath)) { Write-Error "No exe at $exePath - run without -SkipBuild"; exit 1 }

# --- license page encoding ----------------------------------------------------
#
# Inno reads a plain-text LicenseFile as ANSI unless it carries a UTF-8 BOM.
# LICENSE.txt is BOM-less UTF-8 with LF endings and contains em dashes, so
# pointing Inno straight at it puts mojibake on the first page a stranger sees.
# Write a BOM'd CRLF copy into build\ and hand the .iss that instead.
$licStaged = Join-Path $buildDir 'LICENSE.txt'
$licText = [System.IO.File]::ReadAllText($licPath)
$licText = $licText -replace "`r`n", "`n"
$licText = $licText -replace "`n", "`r`n"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($licStaged, $licText, $utf8Bom)

# --- compile ------------------------------------------------------------------
if (Test-Path $setupExe) { Remove-Item $setupExe -Force }

Write-Host "Compiling $issPath ..." -ForegroundColor Cyan
& $iscc "/DMyAppVersion=$version" "/DLicenseFile=$licStaged" $issPath
if ($LASTEXITCODE -ne 0) { Write-Error 'ISCC failed.'; exit 1 }
if (-not (Test-Path $setupExe)) {
    Write-Error "ISCC reported success but $setupExe is missing (OutputBaseFilename changed?)."
    exit 1
}

$mb = [math]::Round((Get-Item $setupExe).Length / 1MB, 2)
Write-Host "Built $setupExe ($mb MB)" -ForegroundColor Green
