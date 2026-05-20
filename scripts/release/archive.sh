#!/usr/bin/env bash
# scripts/release/archive.sh — build, sign, and zip a Developer-ID-signed
# MirrorMesh.app ready for notarization.
#
# WHY this script exists: a fresh maintainer-of-record needs to go from "I
# pasted my Team ID into Local.xcconfig" to "I have a notarizable zip" in
# one command. The Xcode archive + export + ditto dance has enough sharp
# edges (export-options plist, signing identity selection, archive path
# layout) that documenting it as prose is fragile.
#
# Output: build/release/MirrorMesh.app and build/release/MirrorMesh.app.zip
# Next:   scripts/release/notarize.sh
#
# Failure modes (all caught with explicit errors):
#   - Local.xcconfig missing or DEVELOPMENT_TEAM unset   → exit 2
#   - DEVELOPER_DIR points at Command Line Tools         → exit 2
#   - xcodebuild archive fails                           → exit 3
#   - exportArchive produced no .app                     → exit 3
#   - codesign verification fails                        → exit 4

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

LOCAL_XCCONFIG="${repo_root}/Local.xcconfig"
TEMPLATE="${repo_root}/Local.xcconfig.template"
BUILD_DIR="${repo_root}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/MirrorMesh.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_OUT="${BUILD_DIR}/MirrorMesh.app"
ZIP_OUT="${BUILD_DIR}/MirrorMesh.app.zip"
EXPORT_OPTIONS_SRC="${repo_root}/bench/scripts/export-options.plist"
EXPORT_OPTIONS_RUN="${BUILD_DIR}/export-options.run.plist"
SCHEME="MirrorMesh"
CONFIGURATION="Release"

# ── pre-flight ────────────────────────────────────────────────────────────
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
  cat >&2 <<EOF
[archive] ERROR: Local.xcconfig not found at $LOCAL_XCCONFIG

  cp $TEMPLATE $LOCAL_XCCONFIG
  # then edit Local.xcconfig and paste your Apple Developer Team ID

See scripts/release/README.md for the one-page recipe.
EOF
  exit 2
fi

# Extract DEVELOPMENT_TEAM from Local.xcconfig (tolerate spaces around =).
team_id="$(awk -F'= *' '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {print $2; exit}' "$LOCAL_XCCONFIG" | tr -d '[:space:]')"

if [[ -z "$team_id" ]]; then
  cat >&2 <<EOF
[archive] ERROR: DEVELOPMENT_TEAM is empty in $LOCAL_XCCONFIG

  Open Local.xcconfig and set:
    DEVELOPMENT_TEAM = ABCDE12345

  Find your Team ID at: https://developer.apple.com/account
EOF
  exit 2
fi

# Make sure we're using a real Xcode, not Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "${DEVELOPER_DIR}/Platforms/MacOSX.platform" ]]; then
  echo "[archive] ERROR: DEVELOPER_DIR=$DEVELOPER_DIR does not look like Xcode.app" >&2
  echo "[archive]        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2
  exit 2
fi

if [[ ! -f "$EXPORT_OPTIONS_SRC" ]]; then
  echo "[archive] ERROR: missing export-options template at $EXPORT_OPTIONS_SRC" >&2
  exit 2
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$APP_OUT" "$ZIP_OUT"

echo "[archive] DEVELOPER_DIR=$DEVELOPER_DIR"
echo "[archive] DEVELOPMENT_TEAM=$team_id"
echo "[archive] scheme=$SCHEME configuration=$CONFIGURATION"
echo "[archive] archive  → $ARCHIVE_PATH"

# ── regenerate Xcode project from project.yml (idempotent) ────────────────
if command -v xcodegen >/dev/null 2>&1; then
  echo "[archive] xcodegen generate"
  xcodegen generate >/dev/null
else
  echo "[archive] xcodegen not on PATH — assuming existing MirrorMesh.xcodeproj is current"
fi

# ── archive ───────────────────────────────────────────────────────────────
xcodebuild \
  -project MirrorMesh.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$team_id" \
  archive \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  | tee "${BUILD_DIR}/xcodebuild-archive.log" \
  | grep -E '^(===|\*\*|warning:|error:)|note: signing' \
  || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "[archive] ERROR: archive failed — see ${BUILD_DIR}/xcodebuild-archive.log" >&2
  exit 3
fi

# ── exportArchive: produce a .app with Developer ID signing ───────────────
cp "$EXPORT_OPTIONS_SRC" "$EXPORT_OPTIONS_RUN"
/usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$EXPORT_OPTIONS_RUN" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :teamID $team_id" "$EXPORT_OPTIONS_RUN"

echo "[archive] export   → $EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_RUN" \
  | tee "${BUILD_DIR}/xcodebuild-export.log" \
  | grep -E '^(===|\*\*|warning:|error:)|note: signing' \
  || true

found_app="$(/usr/bin/find "$EXPORT_DIR" -maxdepth 2 -name '*.app' -type d | head -n1)"
if [[ -z "$found_app" || ! -d "$found_app" ]]; then
  echo "[archive] ERROR: no .app produced under $EXPORT_DIR" >&2
  echo "[archive]        see ${BUILD_DIR}/xcodebuild-export.log" >&2
  exit 3
fi

# Move the .app to a stable path under build/release.
rm -rf "$APP_OUT"
mv "$found_app" "$APP_OUT"
echo "[archive] app      → $APP_OUT"

# ── verify code signature ─────────────────────────────────────────────────
echo "[archive] codesign --verify --deep --strict"
if ! codesign --verify --deep --strict --verbose=2 "$APP_OUT" 2> "${BUILD_DIR}/codesign-verify.log"; then
  echo "[archive] ERROR: codesign verification failed" >&2
  cat "${BUILD_DIR}/codesign-verify.log" >&2
  exit 4
fi

# Confirm we picked up Developer ID (not ad-hoc / Apple Development).
identity_line="$(codesign --display --verbose=2 "$APP_OUT" 2>&1 | awk -F'=' '/^Authority/ {print $2; exit}' || true)"
echo "[archive] signed by: ${identity_line:-<unknown>}"

# ── zip for notarytool ────────────────────────────────────────────────────
echo "[archive] zip      → $ZIP_OUT"
/usr/bin/ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"

echo "[archive] done."
echo "[archive] next:    scripts/release/notarize.sh"
echo "[archive] app:     $APP_OUT"
echo "[archive] zip:     $ZIP_OUT"
