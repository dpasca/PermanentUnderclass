#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
signing_identity="${PUNDERCLASS_SIGNING_IDENTITY:-}"
architecture="${PUNDERCLASS_ARCH:-}"
bundle_version="${PUNDERCLASS_VERSION:-}"
build_number="${PUNDERCLASS_BUILD_NUMBER:-}"
require_developer_id="${PUNDERCLASS_REQUIRE_DEVELOPER_ID:-0}"

case "$configuration" in
    debug|release) ;;
    *)
        print -u2 "error: configuration must be 'debug' or 'release'"
        exit 1
        ;;
esac

build_arguments=(-c "$configuration")
if [[ -n "$architecture" ]]; then
    case "$architecture" in
        arm64|x86_64) ;;
        *)
            print -u2 "error: unsupported architecture: $architecture"
            exit 1
            ;;
    esac
    build_arguments+=(--arch "$architecture")
fi

if [[ -n "$bundle_version" && ! "$bundle_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print -u2 "error: PUNDERCLASS_VERSION must use X.Y.Z"
    exit 1
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[0-9]+$ ]]; then
    print -u2 "error: PUNDERCLASS_BUILD_NUMBER must be numeric"
    exit 1
fi
if [[ "$require_developer_id" != 0 && "$require_developer_id" != 1 ]]; then
    print -u2 "error: PUNDERCLASS_REQUIRE_DEVELOPER_ID must be 0 or 1"
    exit 1
fi

cd "$project_dir"
swift build "${build_arguments[@]}"

binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
app_dir="$project_dir/.build/PermanentUnderclass.app"
contents_dir="$app_dir/Contents"

if [[ "$app_dir" != "$project_dir/.build/PermanentUnderclass.app" ]]; then
    print -u2 "error: refusing to replace unexpected app bundle: $app_dir"
    exit 1
fi

/bin/rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/usr/bin/install -m 0755 \
    "$binary_dir/punderclass" "$contents_dir/MacOS/punderclass"
/usr/bin/install -m 0644 \
    "$project_dir/AppBundle/Info.plist" "$contents_dir/Info.plist"
if [[ -n "$bundle_version" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $bundle_version" \
        "$contents_dir/Info.plist"
fi
if [[ -n "$build_number" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleVersion $build_number" \
        "$contents_dir/Info.plist"
fi
/usr/bin/install -m 0644 \
    "$project_dir/AppBundle/THIRD_PARTY_NOTICES.md" \
    "$contents_dir/Resources/THIRD_PARTY_NOTICES.md"
/usr/bin/install -m 0644 \
    "$project_dir/LICENSE" "$contents_dir/Resources/LICENSE.txt"
/usr/bin/install -m 0644 \
    "$project_dir/AppBundle/Resources/AppIcon.icns" \
    "$contents_dir/Resources/AppIcon.icns"
/usr/bin/ditto \
    "$project_dir/AppBundle/ThirdPartyLicenses" \
    "$contents_dir/Resources/ThirdPartyLicenses"
/usr/bin/ditto \
    "$project_dir/Prototypes/LiveAssistant" \
    "$contents_dir/Resources/LiveAssistant"

if [[ -z "$signing_identity" ]]; then
    signing_identity="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
    )"
fi

if [[ "$require_developer_id" == 1 && -z "$signing_identity" ]]; then
    print -u2 "error: a Developer ID Application identity is required"
    exit 1
fi

if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
    print -u2 \
        "warning: no Developer ID Application certificate found; privacy permissions may be requested again after rebuilding"
fi

if [[ "$require_developer_id" == 1 && "$signing_identity" == "-" ]]; then
    print -u2 "error: ad hoc signing is forbidden for a distributable build"
    exit 1
fi

if [[ -n "$architecture" ]]; then
    actual_architecture="$(/usr/bin/lipo -archs "$contents_dir/MacOS/punderclass")"
    if [[ "$actual_architecture" != "$architecture" ]]; then
        print -u2 \
            "error: expected $architecture executable, found $actual_architecture"
        exit 1
    fi
fi

# Resource installs update Contents but leave the outer .app directory's
# timestamp unchanged. Mark the bundle itself as changed so Launch Services
# refreshes metadata such as the Dock icon for development builds.
touch "$app_dir"
codesign_arguments=(--force --sign "$signing_identity")
if [[ "$require_developer_id" == 1 ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi
codesign "${codesign_arguments[@]}" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
print -u2 "Signed PermanentUnderclass with: $signing_identity"

echo "$app_dir"
