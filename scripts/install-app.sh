#!/bin/sh

set -eu

project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_app="$project_directory/build/Slack Menubar.app"
applications_directory="${HOME:?}/Applications"
installed_app="$applications_directory/Slack Menubar.app"

"$project_directory/scripts/build-app.sh" release
mkdir -p "$applications_directory"
ditto "$source_app" "$installed_app"
open "$installed_app"

echo "Installed and opened $installed_app"
