#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: scripts/prepare-update.sh <version> </path/to/Burrito.app>"
    exit 64
fi

version="$1"
app_path="$2"
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
info_plist="$app_path/Contents/Info.plist"
release_dir="$project_dir/.updates/$version"
archive_name="Burrito-$version.zip"
archive_path="$release_dir/$archive_name"
sparkle_build_dir="$project_dir/.build/sparkle-release-tools"
sparkle_bin="$sparkle_build_dir/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [[ ! -f "$info_plist" ]]; then
    print -u2 "No Burrito app found at: $app_path"
    exit 66
fi

app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist")
if [[ "$app_version" != "$version" ]]; then
    print -u2 "Version mismatch: app is $app_version, requested release is $version"
    exit 65
fi

/usr/bin/codesign --verify --deep --strict "$app_path"

if [[ -e "$archive_path" ]]; then
    print -u2 "Archive already exists: $archive_path"
    exit 73
fi

/bin/mkdir -p "$release_dir"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

if [[ ! -x "$sparkle_bin/generate_appcast" ]]; then
    /usr/bin/xcodebuild \
        -resolvePackageDependencies \
        -project "$project_dir/Burrito.xcodeproj" \
        -scheme Burrito \
        -derivedDataPath "$sparkle_build_dir"
fi

"$sparkle_bin/generate_appcast" \
    --download-url-prefix "https://github.com/arj00n/burrito/releases/download/v$version/" \
    "$release_dir"

/bin/cp "$release_dir/appcast.xml" "$project_dir/appcast.xml"

print "Prepared signed update: $archive_path"
print "Next: gh release create v$version '$archive_path' --title 'Burrito $version' --generate-notes"
print "Then commit and push appcast.xml so installed copies can discover it."
