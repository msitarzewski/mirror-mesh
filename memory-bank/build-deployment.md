# MirrorMesh — Build & Deployment

**Status**: Placeholder — no source tree yet. Populate when M1 lands.

---

## Build Environment

- Xcode 16+ (or current at session date)
- Swift 5.10+ / Swift 6 (strict concurrency once stable)
- macOS 14+ host; macOS 15+ recommended for full `CMIOExtension` support
- Apple Silicon required (arm64)

## Expected Build Commands (proposed)

```
swift build
swift test
swift run mirrormesh-bench --scenario <name>

xcodebuild -scheme MirrorMesh -destination 'platform=macOS' build
xcodebuild -scheme MirrorMesh -destination 'platform=macOS' test
```

## Benchmark Harness (proposed)

```
swift run mirrormesh-bench --config bench/scenarios/capture_landmark.json --out bench/out/$(date +%Y%m%d_%H%M).jsonl
python3 bench/scripts/summarize.py bench/out/<file>.jsonl
```

Power measurement requires sudo (uses `powermetrics`):

```
sudo bench/scripts/with_power.sh <bench-command>
```

## Signing & Notarization (release builds)

- Developer ID Application certificate required
- Notarization via `xcrun notarytool submit`
- Hardened runtime enabled
- Required entitlements (anticipated):
  - `com.apple.security.device.camera`
  - `com.apple.security.device.audio-input`
  - `com.apple.security.app-sandbox` — under evaluation; virtual camera path may require non-sandboxed system extension
  - `com.apple.developer.system-extension.install` (for `CMIOExtension`)

## CI

GitHub Actions, macOS arm64 runners. Pipeline (proposed):

1. `swift-format --lint --recursive Sources Tests`
2. `swiftlint --strict`
3. `swift build`
4. `swift test`
5. Provenance check: every file under `models/` has a `.provenance.json` and hash matches
6. Watermark verifier round-trip test on a fixture output

Benchmark CI runs on a dedicated self-hosted M-series runner (proposed) — public hosted runners are too noisy for latency measurement.

## Distribution

- **Source**: GitHub, public
- **Binary**: Notarized signed `.app` for app shell; signed CLI for `mirrormesh-bench`
- **Homebrew tap** (proposed): `brew install mirrormesh/tap/mirrormesh-bench`
- **App Store**: deferred — virtual camera entitlements may complicate review

## Model Distribution

- Models published as separate signed archives, not in main repo
- Hash + provenance committed in repo; binaries fetched on first run with user consent
- Offline-install path supported

## Release Checklist (proposed)

- [ ] All tests green on M3 and M4 reference runners
- [ ] Benchmark suite produces a fresh published run for the release tag
- [ ] Notarization succeeded
- [ ] Watermark round-trip verifier passes against fresh build
- [ ] CHANGELOG updated
- [ ] Paper companion artifacts tagged (if release coincides with paper revision)
