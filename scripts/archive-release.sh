#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
app_dir="$project_dir/.build/PermanentUnderclass.app"
dist_dir="$project_dir/dist"
archive_name="PermanentUnderclass-macOS-arm64.zip"
archive_path="$dist_dir/$archive_name"
checksums_path="$dist_dir/checksums.txt"
require_notarization="${PUNDERCLASS_REQUIRE_NOTARIZATION:-0}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print -u2 "usage: $0 X.Y.Z"
    exit 1
fi
if [[ ! -d "$app_dir" ]]; then
    print -u2 "error: build $app_dir before creating the archive"
    exit 1
fi
if [[ "$dist_dir" != "$project_dir/dist" ]]; then
    print -u2 "error: refusing unexpected distribution directory: $dist_dir"
    exit 1
fi
if [[ "$require_notarization" != 0 && "$require_notarization" != 1 ]]; then
    print -u2 "error: PUNDERCLASS_REQUIRE_NOTARIZATION must be 0 or 1"
    exit 1
fi

executable="$app_dir/Contents/MacOS/punderclass"
actual_architecture="$(/usr/bin/lipo -archs "$executable")"
if [[ "$actual_architecture" != arm64 ]]; then
    print -u2 "error: release executable must be arm64, found $actual_architecture"
    exit 1
fi

actual_version="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "$app_dir/Contents/Info.plist"
)"
if [[ "$actual_version" != "$version" ]]; then
    print -u2 "error: expected app version $version, found $actual_version"
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"
if [[ "$require_notarization" == 1 ]]; then
    /usr/bin/xcrun stapler validate "$app_dir"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app_dir"
fi

/bin/mkdir -p "$dist_dir"
/bin/rm -f "$archive_path" "$checksums_path"
/usr/bin/ditto \
    -c -k --sequesterRsrc --keepParent \
    "$app_dir" "$archive_path"

(
    cd "$dist_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$checksums_path"
)

verification_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/punderclass-release.XXXXXX")"
trap '/bin/rm -rf "$verification_dir"' EXIT
/usr/bin/unzip -q "$archive_path" -d "$verification_dir"
archived_app="$verification_dir/PermanentUnderclass.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$archived_app"
archived_architecture="$(
    /usr/bin/lipo -archs "$archived_app/Contents/MacOS/punderclass"
)"
if [[ "$archived_architecture" != arm64 ]]; then
    print -u2 \
        "error: archived executable must be arm64, found $archived_architecture"
    exit 1
fi

print "$archive_path"
print "$checksums_path"
