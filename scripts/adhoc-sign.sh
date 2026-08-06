#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "Usage: scripts/adhoc-sign.sh </path/to/Burrito.app>"
    exit 64
fi

app_path="$1"
if [[ ! -d "$app_path/Contents" ]]; then
    print -u2 "No application bundle found at: $app_path"
    exit 66
fi

/usr/bin/codesign --force --deep --sign - --timestamp=none "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

print "Ad-hoc signature verified: $app_path"
print "Gatekeeper will still require explicit approval after a downloaded first install."
