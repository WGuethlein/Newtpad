# Is build\newtpad.res older than any of its sources?
#
# Prints "stale" or "ok". Exists as a file rather than inline in build.bat
# because expressing "is A newer than B" in cmd, through a for /f, through
# backticks, with escaped pipes, is a nest of escaping that silently evaluated
# to "ok" no matter what -- which is exactly the failure it was written to
# prevent. A .ps1 has no escaping layer at all.
#
# The cache used to be invalidated by absence only, so editing newtpad.rc, the
# manifest or the icon left a stale .res in place and the build shipped the old
# resource without a word.
param(
    [string]$Res = 'build\newtpad.res',
    [string[]]$Sources = @(
        'src\platform\newtpad.rc',
        'src\platform\newtpad.manifest',
        'src\platform\newtpad.ico',
        # The VERSIONINFO block's numbers come from here via build\version.rh, so
        # a version bump alone -- touching no .rc, no manifest, no icon -- must
        # still rebuild the resource. Without this line the shipped exe would
        # report the PREVIOUS version in its properties, which is worse than
        # reporting none: release.ps1 tags from this same file, so the tag and
        # the binary would disagree while looking like they agree.
        'src\program\version.odin'
    )
)

if (-not (Test-Path $Res)) { 'stale'; exit 0 }

$resTime = (Get-Item $Res).LastWriteTime
foreach ($s in $Sources) {
    if (-not (Test-Path $s)) { continue }
    if ((Get-Item $s).LastWriteTime -gt $resTime) { 'stale'; exit 0 }
}
'ok'
