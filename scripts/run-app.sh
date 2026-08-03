#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle_identifier="com.permanentunderclass.meetingcopilot"

# `open` reuses an existing GUI process even after its executable has been
# rebuilt on disk. Quit every build with this bundle identifier, including one
# from another worktree, so this command cannot leave an older headless process
# running beside the build the developer intends to test.
existing_pids="$(
    /usr/bin/osascript -l JavaScript <<JXA
ObjC.import('AppKit')
const apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier(
    '$bundle_identifier'
)
const pids = []
for (let index = 0; index < apps.count; ++index) {
    const app = apps.objectAtIndex(index)
    pids.push(Number(app.processIdentifier))
    app.terminate
}
pids.join('\\n')
JXA
)"
if [[ -n "$existing_pids" ]]; then
    for _ in {1..50}; do
        has_running_process=false
        for pid in ${(f)existing_pids}; do
            if kill -0 "$pid" >/dev/null 2>&1; then
                has_running_process=true
                break
            fi
        done
        if [[ "$has_running_process" == false ]]; then
            break
        fi
        sleep 0.1
    done
    for pid in ${(f)existing_pids}; do
        if kill -0 "$pid" >/dev/null 2>&1; then
            print -u2 "error: PUnderclass process $pid did not quit"
            exit 1
        fi
    done
fi

app_path="$("$project_dir/scripts/build-app.sh" debug | tail -n 1)"
if (( $# > 0 )); then
    open "$app_path" --args "$@"
else
    open "$app_path"
fi
