#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
prototype_dir="$project_dir/Prototypes/LiveAssistant"
port="${PUNDERCLASS_PROTOTYPE_PORT:-4173}"

cd "$prototype_dir"
print "PUnderclass Live Assistant prototype"
print "Open http://127.0.0.1:$port"
python3 -m http.server "$port" --bind 127.0.0.1
