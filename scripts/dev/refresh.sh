#!/usr/bin/env bash
# scripts/dev/refresh.sh — clean rebuild + relaunch for dev.
#
# WHY this script exists: every developer hits a state where the UI doesn't
# reflect what their source says. Causes range from a stale SwiftPM build
# cache to a still-running prior instance holding onto the camera. This
# script does the canonical "blow away the cache, rebuild, kill the old
# instance, launch fresh" dance in one command so you don't have to remember
# the four-line sequence.
#
# Use when: "I edited Sources/... and the app looks the same."
# Don't use when: you need a Developer-ID-signed bundle — see scripts/release/.
#
# Output: a fresh `swift run -c release mirrormesh-app` running in the
# background. PID is printed so you can `kill $PID` if needed.
#
# Failure modes (all caught with explicit errors):
#   - Xcode.app not at /Applications/Xcode.app → exit 1 (env not set up)
#   - swift build fails → exit code propagated from swift (no launch attempt)
#   - pkill returns non-zero when no process matches → swallowed (expected)

set -euo pipefail

cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ ! -d "${DEVELOPER_DIR}/Platforms/MacOSX.platform" ]]; then
  echo "[refresh] ERROR: DEVELOPER_DIR=${DEVELOPER_DIR} does not look like Xcode.app" >&2
  echo "[refresh]        Install Xcode at /Applications/Xcode.app, or edit this script" >&2
  echo "[refresh]        to point at your install. Command Line Tools alone won't work." >&2
  exit 1
fi

echo "[refresh] swift package clean"
swift package clean

echo "[refresh] swift build (release config)"
swift build -c release 2>&1 | tail -5

echo "[refresh] killing any running mirrormesh-app"
pkill -f mirrormesh-app || true

echo "[refresh] launching fresh"
swift run -c release mirrormesh-app &
echo "[refresh] PID $!"
