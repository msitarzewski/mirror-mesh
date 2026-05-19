#!/usr/bin/env bash
# WHY: submit a Developer-ID-signed .app to Apple's notary service, wait for
# the verdict, and staple the resulting ticket so the bundle works offline.
# Secrets live in a keychain profile (see docs/notarization.md) — never in
# this repo, never in argv.
set -euo pipefail

archive="build/MirrorMesh.xcarchive"
profile="mirrormesh-notary"
team_id="${DEVELOPMENT_TEAM:-}"

usage() {
  cat >&2 <<EOF
usage: $0 [--archive <path>] [--keychain-profile <name>] [--team-id <id>]

  --archive            Path to .xcarchive (default: build/MirrorMesh.xcarchive)
  --keychain-profile   notarytool profile name (default: mirrormesh-notary)
  --team-id            Developer Team ID (default: \$DEVELOPMENT_TEAM env)

One-time setup (creates the keychain profile):
  xcrun notarytool store-credentials \\
      --key /path/to/AuthKey_XXXXXXXXXX.p8 \\
      --key-id XXXXXXXXXX \\
      --issuer 00000000-0000-0000-0000-000000000000 \\
      mirrormesh-notary

See docs/notarization.md for the full recipe.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) archive="$2"; shift 2 ;;
    --keychain-profile) profile="$2"; shift 2 ;;
    --team-id) team_id="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -d "$archive" ]]; then
  echo "[notarize] archive not found: $archive" >&2
  echo "[notarize] build it first:" >&2
  echo "  xcodebuild -project MirrorMesh.xcodeproj -scheme MirrorMesh \\" >&2
  echo "             -configuration Release archive -archivePath \"$archive\"" >&2
  exit 2
fi

if [[ -z "$team_id" ]]; then
  # WHY: the export-options.plist needs a concrete teamID injected; xcodebuild
  # will not infer it from the archive when signingStyle=automatic.
  echo "[notarize] DEVELOPMENT_TEAM is unset and --team-id was not provided." >&2
  echo "[notarize] export it from Local.xcconfig or pass --team-id <id>." >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_plist="${script_dir}/export-options.plist"
if [[ ! -f "$base_plist" ]]; then
  echo "[notarize] missing base export-options.plist next to this script" >&2
  exit 2
fi

out_dir="$(dirname "$archive")"
mkdir -p "$out_dir"

# WHY: PlistBuddy-merge the team ID into a per-run copy so we never mutate
# the committed template.
run_plist="${out_dir}/export-options.run.plist"
cp "$base_plist" "$run_plist"
/usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$run_plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :teamID $team_id" "$run_plist"

export_dir="${out_dir}/export"
rm -rf "$export_dir"
mkdir -p "$export_dir"

echo "[notarize] exporting .app from archive → $export_dir"
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$run_plist"

# WHY: -exportArchive produces a single .app inside exportPath; locate it
# rather than hard-coding the name.
app_path="$(/usr/bin/find "$export_dir" -maxdepth 2 -name '*.app' -type d | head -n1)"
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  echo "[notarize] no .app produced under $export_dir" >&2
  exit 1
fi
echo "[notarize] app: $app_path"

# WHY: notarytool wants a zip or dmg; `ditto -c -k --keepParent` preserves
# the bundle structure + xattrs (xcrun stapler is finicky otherwise).
zip_path="${out_dir}/$(basename "$app_path" .app)-notarize.zip"
rm -f "$zip_path"
echo "[notarize] zipping → $zip_path"
/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"

echo "[notarize] submitting to Apple (profile=$profile, will wait for verdict)…"
submit_log="${out_dir}/notarize-submit.log"
set +e
xcrun notarytool submit "$zip_path" \
  --keychain-profile "$profile" \
  --wait \
  --output-format json \
  | tee "$submit_log"
submit_status=$?
set -e

if [[ $submit_status -ne 0 ]]; then
  echo "[notarize] notarytool submit failed (exit $submit_status)" >&2
  echo "[notarize] full response logged to $submit_log" >&2
  # WHY: surface Apple's structured error to stderr so CI logs are useful.
  tail -n 200 "$submit_log" >&2 || true
  exit "$submit_status"
fi

# WHY: notarytool emits one JSON object per stage; the last line is the
# final verdict. Parse with python (jq is not guaranteed on every runner).
verdict=$(python3 - "$submit_log" <<'PY'
import json, sys
last = None
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            last = json.loads(line)
        except json.JSONDecodeError:
            continue
print((last or {}).get("status", "Unknown"))
PY
)

echo "[notarize] verdict: $verdict"
if [[ "$verdict" != "Accepted" ]]; then
  echo "[notarize] notarization did not return Accepted" >&2
  exit 1
fi

echo "[notarize] stapling → $app_path"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

echo "[notarize] verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose "$app_path" || {
  echo "[notarize] WARN: spctl rejected the bundle (review output above)" >&2
}

echo "[notarize] done."
echo "[notarize] app:    $app_path"
echo "[notarize] zip:    $zip_path"
echo "[notarize] log:    $submit_log"
