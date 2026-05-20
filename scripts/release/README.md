# scripts/release/ — release-build recipe

End-to-end: notarize a signed `MirrorMesh.app` for distribution outside the
App Store. Takes about 3–8 minutes once credentials are in place (Apple's
notary service is the long pole).

## Prerequisites

- macOS 14+ with Xcode 15+ installed
- Paid Apple Developer Program membership (the 99 USD/yr one)
- A **Developer ID Application** certificate in your login keychain
  (Xcode → Settings → Accounts → highlight team → Manage Certificates →
  `+` → "Developer ID Application")

## One-time setup

### 1. Paste your Team ID into `Local.xcconfig`

```bash
cp Local.xcconfig.template Local.xcconfig
# open Local.xcconfig and fill in DEVELOPMENT_TEAM
```

Find your Team ID at <https://developer.apple.com/account> → Membership.
It's a 10-character alphanumeric string. Not a secret, but per-developer.

### 2. Generate an App Store Connect API key

1. Sign in to <https://appstoreconnect.apple.com/access/api>
2. **Keys** → **+** → name it `MirrorMesh CI`, role **Developer**
3. Download the `.p8` file. Save it somewhere persistent
   (e.g. `~/Secrets/AuthKey_XXXXXXXXXX.p8`) — **you cannot redownload it**
4. Note the **Key ID** (10-char string next to the key) and **Issuer ID**
   (UUID at the top of the Keys page)

### 3. Store the credentials in your login keychain

```bash
xcrun notarytool store-credentials \
    --key ~/Secrets/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer 00000000-0000-0000-0000-000000000000 \
    mirrormesh-notary
```

The trailing positional argument is the keychain profile name.
`notarize.sh` defaults to `mirrormesh-notary`; override with the
`NOTARYTOOL_KEYCHAIN_PROFILE` env var if you use a different one.

The `.p8` is never read again after this step.

## Per-release recipe

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

./scripts/release/archive.sh    # ~2 min: builds, signs, zips
./scripts/release/notarize.sh   # ~3 min: submits, waits, staples
```

After `notarize.sh` returns 0:

- `build/release/MirrorMesh.app` — stapled, Gatekeeper-accepted
- `build/release/MirrorMesh-stapled.app.zip` — distribute this
- `build/release/notarize-submit.log` — Apple's JSON verdict

Confirm:

```bash
spctl --assess --type execute --verbose build/release/MirrorMesh.app
# expected: "accepted ... source=Notarized Developer ID"

xcrun stapler validate build/release/MirrorMesh.app
# expected: "The validate action worked!"
```

## Failure modes (and what each means)

| Exit code | Where | Meaning | Fix |
|-----------|-------|---------|-----|
| `archive.sh` 2 | pre-flight | `Local.xcconfig` missing or `DEVELOPMENT_TEAM` empty | Run the One-time setup above |
| `archive.sh` 3 | `xcodebuild` | archive or export failed | Read `build/release/xcodebuild-archive.log` |
| `archive.sh` 4 | `codesign` | signed binary doesn't verify | Confirm Developer ID cert is in login keychain and not expired |
| `notarize.sh` 2 | pre-flight | zip missing, or keychain profile not stored | Run `archive.sh` first; redo `store-credentials` |
| `notarize.sh` 3 | submit | notarytool failed to upload (network / auth) | Inspect `notarize-submit.log`; verify API key is still valid |
| `notarize.sh` 4 | verdict | Apple returned `Invalid` | Read `notarize-issues.json` for per-file diagnosis (usually: a nested binary lacking hardened runtime) |
| `notarize.sh` 5 | staple/spctl | ticket stapled but Gatekeeper still rejects | Wait 60s and re-run `xcrun stapler staple` — propagation lag |

## Without credentials (forks / contributors)

You can still run `scripts/release/archive.sh` after pasting **any** Team ID
into `Local.xcconfig` — but Xcode will fail to find a Developer ID
certificate and `codesign --verify` will reject the result. The script
exits with a clear error rather than silently producing a broken `.app`;
you'll see something like:

```
[archive] ERROR: codesign verification failed
```

That's expected without a paid Apple Developer account. The build is still
useful for `swift run mirrormesh-app` development; only **distribution**
requires the signed/notarized track.

## CI

The GitHub release workflow (`.github/workflows/release.yml`, when present)
calls the same scripts when the right secrets are configured on the repo:

| Secret | What it is |
|--------|------------|
| `APPLE_DEVELOPMENT_TEAM` | Team ID (same value as `Local.xcconfig`'s `DEVELOPMENT_TEAM`) |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID |
| `APPLE_NOTARY_ISSUER` | App Store Connect Issuer UUID |
| `APPLE_NOTARY_KEY_B64` | The `.p8` file, base64-encoded |

When any of those is missing, the workflow attaches an **unsigned** zip
plus the bench artifacts so CI stays green for forks.

## See also

- `docs/notarization.md` — the long-form reference (this README is the
  one-page recipe; that doc is the encyclopedia)
- `bench/scripts/notarize.sh` — the historical / lower-level script these
  wrap; same notarytool flow but exposes more knobs
