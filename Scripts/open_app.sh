#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_path="$project_root/.build/AppMan.app"

if [ ! -d "$bundle_path" ]; then
    "$project_root/Scripts/build_app_bundle.sh" >/dev/null
fi

open "$bundle_path"
