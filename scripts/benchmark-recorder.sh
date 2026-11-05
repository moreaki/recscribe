#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
label="${1:-$(date +%Y%m%d-%H%M%S)}"
[[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Use a simple benchmark label" >&2; exit 2; }
if [[ -z "${RECSCRIBE_RUN_DIR:-}" ]]; then
    exec python3 "$PWD/scripts/work-artifacts.py" run --label "$label" benchmark -- "$PWD/scripts/benchmark-recorder.sh" "$label"
fi
output="$RECSCRIBE_RUN_DIR"
{
    git rev-parse HEAD
    git diff --stat
    sysctl -n machdep.cpu.brand_string hw.memsize
    sw_vers
    xcodebuild -version
} > "$output/environment.txt"
xcodebuild test -quiet \
    -project RecScribe/RecScribe.xcodeproj -scheme RecScribe \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    -derivedDataPath Build/DerivedData ENABLE_TESTABILITY=YES \
    -only-testing:RecScribeTests/RecorderBenchmarkTests \
    -resultBundlePath "$output/result.xcresult" 2>&1 | tee "$output/build.log"
xcrun xcresulttool export diagnostics --path "$output/result.xcresult" --output-path "$output/diagnostics"
rg --no-filename 'RECORDER_BENCH' "$output/diagnostics" -g StandardOutputAndStandardError.txt | tee "$output/samples.txt"
echo "Saved benchmark: $output"
