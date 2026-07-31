# Generates build\version.rh from src\program\version.odin, so the exe's
# VERSIONINFO resource and NEWTPAD_VERSION cannot disagree.
#
# version.odin is already the single source of truth -- release.ps1 greps it to
# derive the git tag. The .rc needed the same number in rc's own syntax
# (FILEVERSION wants four comma-separated integers, the string block wants
# "0.33.0"), and typing it into the .rc by hand would have made a THIRD place to
# forget on a version bump. Generating it means a bump touches one file.
#
# A .ps1 rather than inline cmd, for the reason res-stale.ps1 gives at length:
# parsing a quoted string out of a file, through a for /f, through backticks, is
# a nest of escaping that fails silently.
#
# EVERYTHING THIS WRITES IS ASCII, deliberately. PowerShell 5.1 decodes a
# BOM-less .ps1 as ANSI, so a non-ASCII character in a script literal is already
# mojibake before rc sees it -- that shipped a mangled em dash into the v0.13.0
# release notes once (docs/development-loop.md, "Shell"). The copyright line
# lives in newtpad.rc as "(C)" for the same reason; it never passes through here.
param(
    [string]$Source = 'src\program\version.odin',
    [string]$Out    = 'build\version.rh'
)

$ErrorActionPreference = 'Stop'

$text = Get-Content $Source -Raw -Encoding UTF8
if ($text -notmatch 'NEWTPAD_VERSION\s*::\s*"([0-9]+)\.([0-9]+)\.([0-9]+)"') {
    Write-Error "could not parse NEWTPAD_VERSION out of $Source"
    exit 1
}
$maj, $min, $pat = $Matches[1], $Matches[2], $Matches[3]

# FILEVERSION/PRODUCTVERSION take four integers; we carry three, so the build
# field is 0. The string form stays exactly what version.odin says, because that
# is the string a user reads in the file's properties and quotes in a bug report.
$body = @"
#define NEWTPAD_VER_COMMA $maj,$min,$pat,0
#define NEWTPAD_VER_STR   "$maj.$min.$pat"
"@

# Only rewrite when the content actually changed: the .rc's staleness check is by
# timestamp, so touching this file on every build would rebuild the resource on
# every build.
if ((Test-Path $Out) -and ((Get-Content $Out -Raw -Encoding UTF8) -eq ($body + "`r`n"))) {
    exit 0
}
Set-Content -Path $Out -Value $body -Encoding ASCII
