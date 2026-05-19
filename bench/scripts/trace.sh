#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
stamp=$(date +%Y%m%d_%H%M%S)
out=bench/out/mirrormesh_${stamp}.trace
swift build
xcrun xctrace record \
    --template "Time Profiler" \
    --launch -- $(swift build --show-bin-path)/mirrormesh-bench \
        --scenario bench/scenarios/demo.json \
    --output "$out"
echo "Trace written to $out"
echo "Open with: open '$out'"
