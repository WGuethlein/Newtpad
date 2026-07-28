# Newtpad release cutter. Derives the version from src/program/version.odin (the
# single source of truth), builds the release exe, tags v<version>, and pushes
# the current branch + the tag to origin. If GitHub CLI (gh) is installed it also
# creates a GitHub Release with the exe attached; otherwise it prints the manual
# upload step.
#
#   .\release.ps1              build, tag, push (and gh release if available)
#   .\release.ps1 -NoPush      build + tag locally only
#   .\release.ps1 -DryRun      print what it would do, change nothing
#   .\release.ps1 -Installer   also build and attach setup.exe (needs Inno Setup)
#
# -Installer is additive, never a substitute: the bare newtpad.exe is attached
# either way. Principle 5 is "no install required", so the portable exe stays the
# primary artifact and the setup.exe is an extra asset. If Inno Setup is absent
# the installer step says so and skips; the release still goes out.
param(
    [switch]$NoPush,
    [switch]$DryRun,
    [switch]$Installer
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# --- version (single source of truth) ---
$verLine = Select-String -Path 'src\program\version.odin' -Pattern 'NEWTPAD_VERSION\s*::\s*"([^"]+)"'
if (-not $verLine) { Write-Error 'Could not find NEWTPAD_VERSION in src\program\version.odin'; exit 1 }
$version = $verLine.Matches[0].Groups[1].Value
$tag = "v$version"
Write-Host "Releasing $tag" -ForegroundColor Cyan

# --- refuse to release a dirty or already-tagged tree ---
if ((git status --porcelain).Length -gt 0) { Write-Error 'Working tree is dirty. Commit the version bump and fixes first.'; exit 1 }
if (git tag --list $tag) { Write-Error "$tag already exists. Bump NEWTPAD_VERSION before cutting a new release."; exit 1 }

# --- build the shipped exe ---
Write-Host 'Building release...' -ForegroundColor Cyan
if (-not $DryRun) {
    $bat = Join-Path $PSScriptRoot 'build.bat' # absolute: cmd does not search the cwd
    cmd /c "`"$bat`" release"
    if ($LASTEXITCODE -ne 0) { Write-Error 'Release build failed.'; exit 1 }
}
$exe = 'build\newtpad.exe'
if (-not $DryRun -and -not (Test-Path $exe)) { Write-Error "Release exe missing: $exe"; exit 1 }
if (-not $DryRun) {
    $mb = [math]::Round((Get-Item $exe).Length / 1MB, 2)
    Write-Host "  built $exe ($mb MB)" -ForegroundColor Green
}

# --- installer (optional) ---
# build-installer.ps1 owns the ISCC hunt and exits 0 when Inno Setup is absent,
# so a missing toolchain never costs us a release. -SkipBuild because the exe it
# wraps was just built above.
$setupExe = "build\newtpad-$version-setup.exe"
if ($Installer) {
    & (Join-Path $PSScriptRoot 'build-installer.ps1') -SkipBuild -DryRun:$DryRun
    if ($LASTEXITCODE -ne 0) { Write-Error 'Installer build failed.'; exit 1 }
}

if ($DryRun) { Write-Host "[dry run] would tag $tag and push"; exit 0 }

# --- tag ---
git tag -a $tag -m "Newtpad $tag"
if ($NoPush) { Write-Host "Tagged $tag locally (-NoPush)."; exit 0 }

# --- push branch + tag ---
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
git push origin $branch
git push origin $tag

# --- GitHub Release (needs gh) ---
# A shell opened before gh was installed does not have it on PATH, so look in the
# default install location too. Getting this wrong once meant the tag was pushed
# and the Release silently skipped, with the manual-upload fallback printed as
# though gh were absent.
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) {
    $fallback = 'C:\Program Files\GitHub CLI\gh.exe'
    if (Test-Path $fallback) { $gh = $fallback }
}
if (-not $gh) {
    Write-Host "Pushed tag $tag, but 'gh' was not found on PATH or at the default install path." -ForegroundColor Yellow
    Write-Host "No GitHub Release was created. Install 'gh', or upload $exe manually at:" -ForegroundColor Yellow
    Write-Host "  https://github.com/WGuethlein/Newtpad/releases/new?tag=$tag"
    exit 1
}

# Prepended to the auto-generated notes. The repo is public and the exe is
# unsigned, so every download trips SmartScreen; say so rather than letting it
# look like a broken binary. Delete this once signing is in place.
#
# ASCII only, deliberately. PowerShell 5.1 decodes a BOM-less .ps1 as ANSI, so a
# non-ASCII character here is already mojibake by the time gh is invoked. An em
# dash in this string shipped as "a-EUR-quote" in the published v0.13.0 notes.
$notes = @"
**This build is unsigned.** Windows SmartScreen will warn when you download or first run it. Choose **More info**, then **Run anyway**. Code signing needs a purchased certificate and is tracked as ship-readiness work.
"@

# The exe first, always: it is the one that needs no install.
$assets = @($exe)
if ($Installer -and (Test-Path $setupExe)) {
    $assets += $setupExe
    $notes = $notes + "`n`nTwo downloads: ``newtpad.exe`` runs as-is from anywhere, and the setup.exe installs it per-user with an ""Open with"" registration and an uninstaller. Either is fine."
}
& $gh release create $tag @assets --title "Newtpad $tag" --notes $notes --generate-notes
if ($LASTEXITCODE -ne 0) { Write-Error "gh release create failed for $tag."; exit 1 }
Write-Host "GitHub Release $tag created with $($assets.Count) asset(s) attached." -ForegroundColor Green
