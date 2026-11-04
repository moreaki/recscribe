#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
required_xcode_version="${1:-$(cat "$project_root/.xcode-version")}"
xcode_info="$(xcodebuild -version)"
selected_xcode_version="$(awk '$1 == "Xcode" { print $2 }' <<< "$xcode_info")"

printf '%s\n' "$xcode_info"
xcrun swift --version
printf 'macOS SDK: %s\n' "$(xcrun --sdk macosx --show-sdk-version)"
printf 'Host macOS: %s\n' "$(sw_vers -productVersion)"

if [[ "$selected_xcode_version" != "$required_xcode_version" ]]; then
    printf 'Expected Xcode %s, selected %s. Select the matching installation with DEVELOPER_DIR before claiming CI-equivalent validation.\n' \
        "$required_xcode_version" "$selected_xcode_version" >&2
    exit 1
fi
