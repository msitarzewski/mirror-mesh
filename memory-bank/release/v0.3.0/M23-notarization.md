# M23 — Notarization + Stapling

**Status**: ⚪ blocked on M22
**Owner**: TBD
**Blocked by**: M22 (and an App Store Connect API key the user must provide separately)
**Blocks**: M29 (Homebrew distribution)

## Objective

Submit the signed `.app` to Apple's notary service via `xcrun notarytool`, wait for approval, staple the ticket. Produces a distributable `.dmg` / `.zip` that Gatekeeper accepts on a fresh Mac.

## Deliverables

- `bench/scripts/notarize.sh`:
  - Args: `<path-to-xcarchive>` (default `build/MirrorMesh.xcarchive`)
  - Steps: export `.app` from archive, zip, submit via `xcrun notarytool submit --keychain-profile mirrormesh-notary --wait`, staple
  - Requires: a keychain profile pre-stored via `xcrun notarytool store-credentials --key <AuthKey_*.p8> --key-id <ID> --issuer <UUID> mirrormesh-notary` (user does this one-time; we document it)
- `docs/notarization.md` — step-by-step recipe (one-time API key setup, per-release submission)
- `.gitignore` updated to exclude any local `*.p8` and `*.zip` artifacts in `build/`

## Verification

```bash
xcodebuild -project MirrorMesh.xcodeproj -scheme MirrorMesh archive -archivePath build/MirrorMesh.xcarchive
bench/scripts/notarize.sh build/MirrorMesh.xcarchive
xcrun stapler validate build/MirrorMesh.app
spctl --assess --type execute --verbose build/MirrorMesh.app    # → "accepted: source=Notarized Developer ID"
```

## Notes

- Notarization is async; `notarytool --wait` blocks until the response (typically <5 min)
- Failures surface as JSON; the script pretty-prints
- The user provides the `.p8` API key, key ID, and issuer UUID via `xcrun notarytool store-credentials` — the script never reads the `.p8` file directly
