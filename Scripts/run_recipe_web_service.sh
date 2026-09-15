#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
exec /usr/bin/env python3 -m RecipeWebService.app "$@"
