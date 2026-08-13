#!/bin/sh

set -eu

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_directory=${1:-"$project_directory/dist"}
app_directory="$project_directory/build/Slack Slopbar.app"
plist="$project_directory/Packaging/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
filename="Slack-Slopbar-$version.dmg"
dmg="$output_directory/$filename"
staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/slack-slopbar-dmg.XXXXXX")

cleanup() {
    rm -rf "$staging_directory"
}
trap cleanup EXIT HUP INT TERM

"$project_directory/scripts/build-app.sh" release
mkdir -p "$output_directory"
ditto "$app_directory" "$staging_directory/Slack Slopbar.app"
ln -s /Applications "$staging_directory/Applications"
rm -f "$dmg" "$dmg.sha256"

hdiutil create \
    -volname "Slack Slopbar" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -ov \
    "$dmg"

(
    cd "$output_directory"
    shasum -a 256 "$filename" > "$filename.sha256"
)

echo "$dmg"
