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
mode="${1:---signed}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

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

case "$mode" in
    --signed)
        xcodebuild "${common_arguments[@]}" -allowProvisioningUpdates clean build
        ;;
    --ad-hoc)
        xcodebuild "${common_arguments[@]}" CODE_SIGNING_ALLOWED=NO clean build
        codesign \
            --force \
            --deep \
            --sign - \
            --options runtime \
            --identifier "$bundle_identifier" \
            "$app_path"
        ;;
    *)
        fail "Usage: scripts/build-app.sh [--signed|--ad-hoc]"
        ;;
esac

[[ -x "$app_path/Contents/MacOS/RecScribe" ]] || fail "Built application is missing its executable."
[[ -s "$app_path/Contents/Info.plist" ]] || fail "Built application is missing Info.plist."
plutil -lint "$app_path/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$app_path"

echo "$app_path"
