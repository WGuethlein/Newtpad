# Newtpad release cutter. Derives the version from src/program/version.odin (the
# single source of truth), builds the release exe, tags v<version>, and pushes
# the current branch + the tag to origin. If GitHub CLI (gh) is installed it also
# creates a GitHub Release with the exe attached; otherwise it prints the manual
# upload step.
#
#   .\release.ps1            build, tag, push (and gh release if available)
#   .\release.ps1 -NoPush    build + tag locally only
#   .\release.ps1 -DryRun    print what it would do, change nothing
param(
    [switch]$NoPush,
    [switch]$DryRun
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
    cmd /c "build.bat release"
    if ($LASTEXITCODE -ne 0) { Write-Error 'Release build failed.'; exit 1 }
}
$exe = 'build\newtpad.exe'
if (-not $DryRun -and -not (Test-Path $exe)) { Write-Error "Release exe missing: $exe"; exit 1 }
if (-not $DryRun) {
    $mb = [math]::Round((Get-Item $exe).Length / 1MB, 2)
    Write-Host "  built $exe ($mb MB)" -ForegroundColor Green
}

if ($DryRun) { Write-Host "[dry run] would tag $tag and push"; exit 0 }

# --- tag ---
git tag -a $tag -m "Newtpad $tag"
if ($NoPush) { Write-Host "Tagged $tag locally (-NoPush)."; exit 0 }

# --- push branch + tag ---
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
git push origin $branch
git push origin $tag

# --- GitHub Release (optional, needs gh) ---
if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh release create $tag $exe --title "Newtpad $tag" --generate-notes
    Write-Host "GitHub Release $tag created with the exe attached." -ForegroundColor Green
} else {
    Write-Host "Pushed tag $tag. Install 'gh' to auto-create a GitHub Release, or upload $exe manually at:" -ForegroundColor Yellow
    Write-Host "  https://github.com/WGuethlein/Newtpad/releases/new?tag=$tag"
}
