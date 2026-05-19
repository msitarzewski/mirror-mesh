# Notarization

MirrorMesh ships a notarized, stapled `MirrorMesh.app` so Gatekeeper accepts
it on a fresh Mac without right-click-open gymnastics. This page documents the
one-time setup (per maintainer) and the per-release recipe.

The automation lives in [`bench/scripts/notarize.sh`](../bench/scripts/notarize.sh)
and [`bench/scripts/export-options.plist`](../bench/scripts/export-options.plist).
The release workflow ([`.github/workflows/release.yml`](../.github/workflows/release.yml))
calls the same script when the right secrets are configured on the repo.

## Prerequisites

- Paid Apple Developer Program membership (Team ID set in `Local.xcconfig`)
- A `Developer ID Application` certificate in the login keychain (Xcode →
  Settings → Accounts → Manage Certificates → `+` → Developer ID Application)
- Xcode 15+ (`xcrun notarytool` ships with it)

## One-time setup

### 1. Generate an App Store Connect API key

1. Sign in to <https://appstoreconnect.apple.com/access/api>.
2. Select **Keys** → **+** to create a new key. Name it something like
   `MirrorMesh CI`. Give it the **Developer** access role — that's the
   minimum role notarytool requires.
3. Download the `.p8` file. **You cannot redownload it** — save it somewhere
   safe (e.g. `~/Secrets/AuthKey_XXXXXXXXXX.p8`). Treat it as a credential.
4. Note the **Key ID** (10-char string shown next to the key) and the
   **Issuer ID** (UUID shown at the top of the Keys page).

### 2. Store the credentials in your keychain

This caches the API key under a keychain profile name so you (and the
notarize script) never have to type it again.

```bash
xcrun notarytool store-credentials \
    --key ~/Secrets/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer 00000000-0000-0000-0000-000000000000 \
    mirrormesh-notary
```

The final positional argument (`mirrormesh-notary`) is the profile name the
script defaults to. Use a different name and pass `--keychain-profile <name>`
to the script if you prefer.

The `.p8` file is **never** read again after this step; the credential lives
in your login keychain.

### 3. Confirm the Team ID

Make sure `Local.xcconfig` has your `DEVELOPMENT_TEAM`. The notarize script
reads `$DEVELOPMENT_TEAM` from the environment (or `--team-id`) when writing
the export-options plist:

```bash
grep DEVELOPMENT_TEAM Local.xcconfig
```

## Per-release recipe

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPMENT_TEAM=$(awk -F'= *' '/^DEVELOPMENT_TEAM/ {print $2}' Local.xcconfig)

# Regenerate the project (in case project.yml changed)
xcodegen generate

# Archive a Release build (signed automatically via Local.xcconfig)
xcodebuild -project MirrorMesh.xcodeproj \
           -scheme MirrorMesh \
           -configuration Release \
           archive -archivePath build/MirrorMesh.xcarchive

# Export the .app, zip it, submit to Apple, wait, staple, validate.
bench/scripts/notarize.sh --archive build/MirrorMesh.xcarchive

# Confirm Gatekeeper acceptance
spctl --assess --type execute --verbose build/export/MirrorMesh.app
# Expected: "accepted ... source=Notarized Developer ID"
```

The notarize step typically completes in 1–5 minutes; `notarytool submit --wait`
blocks until Apple returns a verdict and prints structured JSON to stderr on
failure.

## CI / release.yml

`release.yml` automatically signs, notarizes, and attaches the `.app.zip` to
the GitHub Release **only when** all four secrets are set on the repository:

| Secret | What it is |
|--------|------------|
| `APPLE_DEVELOPMENT_TEAM` | 10-char Team ID (the same value as `Local.xcconfig`'s `DEVELOPMENT_TEAM`) |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID |
| `APPLE_NOTARY_ISSUER` | App Store Connect Issuer UUID |
| `APPLE_NOTARY_KEY_B64` | The `.p8` file, base64-encoded (`base64 -i AuthKey_XXX.p8 \| pbcopy`) |

When any of those is missing (forks, contributors without Apple accounts),
the workflow gracefully skips the sign + notarize steps and attaches an
**unsigned** `.app.zip` plus the bench artifacts — CI stays green for
everyone.

## Troubleshooting

- **`notarytool submit` says "Invalid"**: check `submit_log` written next to
  the archive — Apple's JSON response names the offending file (most common
  issue: a nested binary lacking the hardened runtime).
- **`stapler staple` says `Could not find the ticket`**: the verdict
  succeeded but the ticket hasn't propagated yet. Wait 60s and re-run
  `xcrun stapler staple build/export/MirrorMesh.app`.
- **`spctl` rejects with `source=no usable signature`**: the archive was
  built with ad-hoc signing. Set `DEVELOPMENT_TEAM` in `Local.xcconfig`,
  regenerate the project, re-archive.

## Security posture

- The `.p8` key is stored only in your login keychain (via `store-credentials`)
  and as the `APPLE_NOTARY_KEY_B64` repo secret. It's never committed,
  never logged, and never passed on argv.
- `.gitignore` already excludes `build/`, `*.app/`, and the `.xcarchive`
  artifacts created by this flow.
