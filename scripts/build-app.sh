#!/bin/sh

set -eu

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-release}
app_directory="$project_directory/build/Slack Menubar.app"
contents_directory="$app_directory/Contents"

case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "$project_directory"
swift build --configuration "$configuration" --product SlackMenubar
binary_directory=$(swift build --configuration "$configuration" --show-bin-path)

rm -rf "$app_directory"
mkdir -p "$contents_directory/MacOS"
cp "$binary_directory/SlackMenubar" "$contents_directory/MacOS/SlackMenubar"
cp "$project_directory/Packaging/Info.plist" "$contents_directory/Info.plist"

codesign --force --sign - "$app_directory"
echo "$app_directory"

