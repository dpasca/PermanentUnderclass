#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"

cd "$project_dir"
swift build -c "$configuration"

binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$project_dir/.build/MeetingCopilot.app"
contents_dir="$app_dir/Contents"

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/usr/bin/install -m 0755 \
    "$binary_dir/MeetingCopilot" "$contents_dir/MacOS/MeetingCopilot"
/usr/bin/install -m 0644 \
    "$project_dir/AppBundle/Info.plist" "$contents_dir/Info.plist"
/usr/bin/install -m 0644 \
    "$project_dir/AppBundle/THIRD_PARTY_NOTICES.md" \
    "$contents_dir/Resources/THIRD_PARTY_NOTICES.md"

fluid_audio_license="$project_dir/.build/checkouts/FluidAudio/LICENSE"
if [[ -f "$fluid_audio_license" ]]; then
    /usr/bin/install -m 0644 \
        "$fluid_audio_license" "$contents_dir/Resources/FluidAudio-LICENSE.txt"
fi

codesign --force --sign - "$app_dir"

echo "$app_dir"
