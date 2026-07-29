#!/bin/sh

set -eu

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_app="$project_directory/build/Slack Menubar.app"
applications_directory="${HOME:?}/Applications"
installed_app="$applications_directory/Slack Menubar.app"

"$project_directory/scripts/build-app.sh" release
mkdir -p "$applications_directory"

# Quit any running instance so `open` launches the new binary instead of
# activating the old one, and remove the previous bundle so stale files can't
# invalidate the fresh code signature.
osascript -e 'tell application "Slack Menubar" to quit' >/dev/null 2>&1 || true
rm -rf "$installed_app"
ditto "$source_app" "$installed_app"
open "$installed_app"

echo "Installed and opened $installed_app"
