#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_path="$project_root/.build/AppMan.app"
installed_bundle_path="/Applications/AppMan.app"

"$project_root/Scripts/build_app_bundle.sh" >/dev/null

pkill -x AppMan 2>/dev/null || true
rm -rf "$installed_bundle_path"
ditto "$bundle_path" "$installed_bundle_path"
open "$installed_bundle_path"
