#!/usr/bin/env bash
# Regenerate all paper figures from runnable bench scenarios.
# Required reading: docs/paper/mirrormesh-v0.md — Section 4 (Evaluation)
set -euo pipefail

cd "$(dirname "$0")/../.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo "==> swift build"
swift build

echo "==> running scenarios"
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json
swift run mirrormesh-bench --scenario bench/scenarios/fixture_coreml.json

echo "==> generating figures"
python3 bench/scripts/figures.py \
    bench/out/demo_*.jsonl \
    bench/out/fixture_*.jsonl \
    bench/out/fixture_coreml_*.jsonl

echo ""
echo "wrote:"
ls -la docs/figures/*.pdf
