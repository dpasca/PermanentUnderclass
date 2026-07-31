#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$("$project_dir/scripts/build-app.sh" debug | tail -n 1)"
open "$app_path"
