#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
signing_identity="${PUNDERCLASS_SIGNING_IDENTITY:-}"

cd "$project_dir"
swift build -c "$configuration"

binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$project_dir/.build/PUnderclass.app"
contents_dir="$app_dir/Contents"

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/usr/bin/install -m 0755 \
    "$binary_dir/punderclass" "$contents_dir/MacOS/punderclass"
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

if [[ -z "$signing_identity" ]]; then
    signing_identity="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
    )"
fi

if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
    print -u2 \
        "warning: no Developer ID Application certificate found; privacy permissions may be requested again after rebuilding"
fi

codesign --force --sign "$signing_identity" "$app_dir"
print -u2 "Signed PUnderclass with: $signing_identity"

echo "$app_dir"
