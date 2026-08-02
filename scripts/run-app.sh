#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_dir/.build/PUnderclass.app"
app_executable="$app_path/Contents/MacOS/punderclass"

# `open` reuses an existing GUI process even after its executable has been
# rebuilt on disk. Quit first so this command never leaves the developer
# testing an older, possibly windowless instance.
if pgrep -f "${app_executable}$" >/dev/null 2>&1; then
    osascript \
        -e 'tell application id "com.permanentunderclass.meetingcopilot" to quit' \
        >/dev/null 2>&1 || true
    for _ in {1..50}; do
        if ! pgrep -f "${app_executable}$" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -f "${app_executable}$" >/dev/null 2>&1; then
        print -u2 "error: the existing PUnderclass process did not quit"
        exit 1
    fi
fi

app_path="$("$project_dir/scripts/build-app.sh" debug | tail -n 1)"
if (( $# > 0 )); then
    open "$app_path" --args "$@"
else
    open "$app_path"
fi
