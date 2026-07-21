// Layer: program — the single source of truth for the product version. The
// release script (release.ps1) greps this to derive the git tag, so the tag and
// the running binary can never disagree. Bump it in the same commit as the
// changes a release covers; SemVer-ish (0.x while pre-1.0).
package main

NEWTPAD_VERSION :: "0.9.0"
