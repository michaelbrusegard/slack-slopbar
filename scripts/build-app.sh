#!/bin/sh

set -eu

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-release}
app_directory="$project_directory/build/Slack Slopbar.app"
contents_directory="$app_directory/Contents"

case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "$project_directory"
if [ "$configuration" = "release" ]; then
    # Release one universal app that runs natively on Apple silicon and Intel.
    swift build \
        --configuration release \
        --product SlackSlopbar \
        --arch arm64 \
        --arch x86_64
    binary_directory=$(swift build \
        --configuration release \
        --arch arm64 \
        --arch x86_64 \
        --show-bin-path)
else
    swift build --configuration debug --product SlackSlopbar
    binary_directory=$(swift build --configuration debug --show-bin-path)
fi

rm -rf "$app_directory"
mkdir -p "$contents_directory/MacOS"
mkdir -p "$contents_directory/Resources"
cp "$binary_directory/SlackSlopbar" "$contents_directory/MacOS/SlackSlopbar"
cp "$project_directory/Packaging/Info.plist" "$contents_directory/Info.plist"

codesign_identity=${CODESIGN_IDENTITY:-}
if [ -z "$codesign_identity" ]; then
    codesign_identity=$(
        security find-identity -v -p codesigning |
            awk '/"Apple Development:/ { print $2; exit }'
    )
fi
codesign_identity=${codesign_identity:--}

codesign \
    --force \
    --sign "$codesign_identity" \
    --timestamp=none \
    "$app_directory"

if [ "$codesign_identity" = "-" ]; then
    echo "Signed ad hoc; Keychain access may reset after rebuilding." >&2
else
    echo "Signed with stable identity $codesign_identity"
fi
echo "$app_directory"
