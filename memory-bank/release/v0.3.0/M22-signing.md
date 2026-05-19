# M22 — Code Signing + Entitlements

**Status**: ⚪ blocked on user-provided Team ID
**Owner**: TBD
**Blocked by**: M21, user-paste-of-Team-ID
**Blocks**: M23, M24

## Objective

Sign the `.app` with a Developer ID Application certificate (or Apple Development for dev builds). Wire entitlements so Camera + Microphone work and the system-extension install path is open (M24 fills the actual extension).

## Deliverables

- `MirrorMesh/MirrorMesh.entitlements`:
  - `com.apple.security.device.camera` → YES
  - `com.apple.security.device.audio-input` → YES
  - `com.apple.developer.system-extension.install` → YES (for M24)
  - `com.apple.security.app-sandbox` → NO (v0.3.0 distributes outside the App Store)
- `Local.xcconfig.example` (committed) — example values
- `Local.xcconfig` (gitignored) — user pastes their `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`, `PRODUCT_BUNDLE_IDENTIFIER`
- `MirrorMesh.xcconfig` (committed) — shared non-secret settings (`CODE_SIGN_STYLE = Automatic`, `ENABLE_HARDENED_RUNTIME = YES`, `OTHER_CODE_SIGN_FLAGS = --timestamp`)
- `bench/scripts/sign.sh` (optional helper) — runs `codesign --verify --deep --strict --verbose=2 build/<configuration>/MirrorMesh.app`

## Verification

```bash
echo 'DEVELOPMENT_TEAM = ABCDE12345' >> Local.xcconfig    # user's value
echo 'CODE_SIGN_IDENTITY = Apple Development' >> Local.xcconfig
xcodebuild -project MirrorMesh.xcodeproj -scheme MirrorMesh -configuration Debug build
codesign --verify --deep --strict --verbose=2 build/Debug/MirrorMesh.app
spctl --assess --type execute --verbose build/Debug/MirrorMesh.app
```

`spctl` should say "accepted" once notarization (M23) is in place; before that "rejected" is expected for a non-notarized Developer ID build.

## Notes

- App Sandbox is intentionally OFF for v0.3.0 because virtual-camera install via `CMIOExtension` requires non-sandboxed installer behavior. v0.4.0 may revisit.
- The hardened runtime is mandatory for notarization
