#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
project_path="$project_root/RecScribe/RecScribe.xcodeproj"
scheme_name="RecScribe"
configuration="${RECSCRIBE_BUILD_CONFIGURATION:-Release}"
build_root="${RECSCRIBE_BUILD_DIR:-$project_root/Build}"
products_dir="$build_root/Products/$configuration"
derived_data_dir="$build_root/DerivedData"
app_path="$products_dir/RecScribe.app"
bundle_identifier="com.moreaki.recscribe"
mode=""
build_actions=(build)
usage="Usage: scripts/build-app.sh [--signed|--ad-hoc] [--clean]"

fail() {
    echo "Error: $*" >&2
    exit 1
}

for argument in "$@"; do
    case "$argument" in
        --signed|--ad-hoc)
            [[ -z "$mode" ]] || fail "Choose one signing mode. $usage"
            mode="$argument"
            ;;
        --clean) build_actions=(clean build) ;;
        --help|-h) echo "$usage"; exit 0 ;;
        *) fail "Unknown option: $argument. $usage" ;;
    esac
done
mode="${mode:---signed}"

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is unavailable. Install Xcode and select it with xcode-select."
command -v codesign >/dev/null 2>&1 || fail "codesign is unavailable."
[[ -d "$project_path" ]] || fail "Xcode project not found: $project_path"

common_arguments=(
    -project "$project_path"
    -scheme "$scheme_name"
    -configuration "$configuration"
    -destination "platform=macOS"
    -derivedDataPath "$derived_data_dir"
    CONFIGURATION_BUILD_DIR="$products_dir"
    COMPILER_INDEX_STORE_ENABLE=NO
)
if [[ "$configuration" == Release ]]; then
    common_arguments+=(CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

cd "$project_root"

# Prune only explicitly disposable runs; current caches/products/backups are outside
# its managed root. Housekeeping failures must not block a local preview build.
prune_artifacts() {
    if command -v python3 >/dev/null 2>&1; then
        python3 "$script_dir/work-artifacts.py" prune --apply --quiet >&2 \
            || echo "Artifact housekeeping skipped; retained output is safe." >&2
    else
        echo "Artifact housekeeping unavailable: python3 is not installed." >&2
    fi
}
prune_artifacts
trap prune_artifacts EXIT

case "$mode" in
    --signed)
        xcodebuild "${common_arguments[@]}" -allowProvisioningUpdates "${build_actions[@]}"
        ;;
    --ad-hoc)
        xcodebuild "${common_arguments[@]}" CODE_SIGNING_ALLOWED=NO "${build_actions[@]}"
        codesign \
            --force \
            --deep \
            --sign - \
            --options runtime \
            --identifier "$bundle_identifier" \
            "$app_path"
        ;;
esac

[[ -x "$app_path/Contents/MacOS/RecScribe" ]] || fail "Built application is missing its executable."
[[ -s "$app_path/Contents/Info.plist" ]] || fail "Built application is missing Info.plist."
plutil -lint "$app_path/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$app_path"

echo "$app_path"
