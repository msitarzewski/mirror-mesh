#!/usr/bin/env bash
# scripts/release/notarize.sh — submit build/release/MirrorMesh.app.zip to
# Apple's notary service, wait for the verdict, staple the ticket, and
# verify Gatekeeper acceptance.
#
# WHY this script exists: notarytool's CLI is fine but its output is JSON,
# its credential model is keychain-based, and its happy path requires three
# separate commands (submit → wait → staple → spctl). A maintainer wants
# one command. Credentials live in the login keychain via
# `xcrun notarytool store-credentials`; nothing secret crosses argv.
#
# Prereq: run scripts/release/archive.sh first to produce the zip.
# Output: build/release/MirrorMesh.app is stapled in place; the
#         build/release/MirrorMesh.app.zip is re-created post-stapling
#         (Gatekeeper checks the stapled bundle, not the original zip).
#
# Failure modes (all caught with explicit errors):
#   - zip not found (archive.sh wasn't run)                 → exit 2
#   - keychain profile not stored                           → exit 2
#   - notarytool submit fails                               → exit 3
#   - Apple verdict ≠ Accepted                              → exit 4
#   - stapler / spctl rejects                               → exit 5

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

BUILD_DIR="${repo_root}/build/release"
APP="${BUILD_DIR}/MirrorMesh.app"
ZIP="${BUILD_DIR}/MirrorMesh.app.zip"
STAPLED_ZIP="${BUILD_DIR}/MirrorMesh-stapled.app.zip"
SUBMIT_LOG="${BUILD_DIR}/notarize-submit.log"

PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-mirrormesh-notary}"

# ── pre-flight ────────────────────────────────────────────────────────────
if [[ ! -d "$APP" || ! -f "$ZIP" ]]; then
  cat >&2 <<EOF
[notarize] ERROR: $ZIP not found.

  Run scripts/release/archive.sh first.

  Expected layout after archive.sh:
    $APP
    $ZIP
EOF
  exit 2
fi

# Probe that the keychain profile exists. notarytool doesn't have a "test
# credentials" command, but `history` is cheap and surfaces a clear error
# if the profile is unset.
echo "[notarize] checking keychain profile: $PROFILE"
if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null 2>&1; then
  cat >&2 <<EOF
[notarize] ERROR: keychain profile '$PROFILE' not found (or invalid).

  One-time setup:
    xcrun notarytool store-credentials \\
        --key ~/Secrets/AuthKey_XXXXXXXXXX.p8 \\
        --key-id XXXXXXXXXX \\
        --issuer 00000000-0000-0000-0000-000000000000 \\
        $PROFILE

  See scripts/release/README.md for how to get the .p8, Key ID, and Issuer ID
  from App Store Connect.

  Override the profile name with:
    NOTARYTOOL_KEYCHAIN_PROFILE=mycustomprofile scripts/release/notarize.sh
EOF
  exit 2
fi

# ── submit + wait ─────────────────────────────────────────────────────────
echo "[notarize] submitting $ZIP to Apple (profile=$PROFILE)"
echo "[notarize] this typically takes 1–5 minutes; output is JSON, logged to:"
echo "[notarize]   $SUBMIT_LOG"

set +e
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$PROFILE" \
  --wait \
  --output-format json \
  | tee "$SUBMIT_LOG"
submit_status=$?
set -e

if [[ $submit_status -ne 0 ]]; then
  echo "[notarize] ERROR: notarytool submit exited $submit_status" >&2
  tail -n 200 "$SUBMIT_LOG" >&2 || true
  exit 3
fi

# Parse the verdict out of the JSON log. notarytool emits one or more JSON
# objects; the last one carries the final "status" field.
verdict="$(python3 - "$SUBMIT_LOG" <<'PY'
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
)"

echo "[notarize] verdict: $verdict"

if [[ "$verdict" != "Accepted" ]]; then
  echo "[notarize] ERROR: Apple did not accept the submission" >&2
  echo "[notarize]        full JSON response is in $SUBMIT_LOG" >&2
  # On rejection, fetch the per-issue log for diagnostics.
  sub_id="$(python3 -c "
import json,sys
with open('$SUBMIT_LOG') as f:
    last=None
    for ln in f:
        ln=ln.strip()
        if ln.startswith('{'):
            try: last=json.loads(ln)
            except: pass
print((last or {}).get('id',''))
")"
  if [[ -n "$sub_id" ]]; then
    echo "[notarize] fetching detailed Apple log for submission $sub_id …"
    xcrun notarytool log "$sub_id" --keychain-profile "$PROFILE" \
      "${BUILD_DIR}/notarize-issues.json" || true
    echo "[notarize] saved → ${BUILD_DIR}/notarize-issues.json"
  fi
  exit 4
fi

# ── staple + verify ───────────────────────────────────────────────────────
echo "[notarize] stapling ticket onto $APP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "[notarize] verifying Gatekeeper acceptance"
if ! spctl --assess --type execute --verbose=4 "$APP" 2> "${BUILD_DIR}/spctl.log"; then
  echo "[notarize] ERROR: spctl rejected the bundle" >&2
  cat "${BUILD_DIR}/spctl.log" >&2
  exit 5
fi
cat "${BUILD_DIR}/spctl.log"

# Re-zip the stapled bundle so the distributed artifact matches what
# Gatekeeper just blessed.
rm -f "$STAPLED_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$STAPLED_ZIP"

echo "[notarize] done."
echo "[notarize] app (stapled): $APP"
echo "[notarize] zip (stapled): $STAPLED_ZIP"
echo "[notarize] submit log:    $SUBMIT_LOG"
