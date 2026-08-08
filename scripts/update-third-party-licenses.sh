#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
checkouts_dir="$project_dir/.build/checkouts"
licenses_dir="$project_dir/AppBundle/ThirdPartyLicenses"

if [[ ! -d "$checkouts_dir" ]]; then
    print -u2 "error: Swift package checkouts are missing; run 'swift package resolve' first"
    exit 1
fi

expected_licenses_dir="$project_dir/AppBundle/ThirdPartyLicenses"
if [[ "$licenses_dir" != "$expected_licenses_dir" ]]; then
    print -u2 "error: refusing to replace unexpected directory: $licenses_dir"
    exit 1
fi

/bin/mkdir -p "$licenses_dir"
/usr/bin/find "$licenses_dir" -mindepth 1 -delete

copied_count=0
for checkout_dir in "$checkouts_dir"/*(/N); do
    package_name="${checkout_dir:t}"
    while IFS= read -r source_file; do
        relative_path="${source_file#$checkout_dir/}"
        destination_file="$licenses_dir/$package_name/$relative_path"
        /bin/mkdir -p "${destination_file:h}"
        /usr/bin/install -m 0644 "$source_file" "$destination_file"
        (( copied_count += 1 ))
    done < <(
        /usr/bin/find "$checkout_dir" -type f \( \
            -iname 'LICENSE' -o -iname 'LICENSE.*' -o \
            -iname 'NOTICE' -o -iname 'NOTICE.*' -o \
            -iname 'NOTICES' -o -iname 'NOTICES.*' -o \
            -iname 'COPYING' -o -iname 'COPYING.*' -o \
            -iname '*THIRD*PARTY*' -o -iname '*ACKNOWLEDG*' \
        \) -print | /usr/bin/sort
    )
done

if (( copied_count == 0 )); then
    print -u2 "error: no third-party license or notice files were found"
    exit 1
fi

print "Updated $copied_count third-party license and notice files."
