# M19 — GitHub Actions CI

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11, M15
**Blocks**: M20

## Objective

Every push and PR runs `swift build` + `swift test` + `mirrormesh-selftest` + the fixture-driven bench on a macOS arm64 GitHub-hosted runner.

## Deliverables

- `.github/workflows/ci.yml` — matrix: macOS arm64 (latest), Xcode (latest stable)
  - `swift build`
  - `swift test`
  - `swift run mirrormesh-selftest`
  - `swift run mirrormesh-bench --scenario bench/scenarios/fixture.json` (smoke; bounds for P95 generous to avoid noisy runners flagging)
- `.github/workflows/release.yml` (stub) — runs on tagged `v*` pushes; archives the JSONL+manifest from a bench run
- `docs/ci.md` — what CI runs, how to read failures, how to skip locally
- A status badge added to root `README.md`

## Behavior

- Green build on every push and PR
- Failure messages link directly to the failing test / scenario
- Cache `~/Library/Caches/org.swift.swiftpm` for faster runs

## Verification

- Push a branch, watch CI go green
- Force a failure (mutate a fixture assertion); watch CI flag it; revert

## Notes

- GitHub macOS runners may not have full Xcode at the version we need — use `xcodebuild -showsdks` first and document the actual Xcode that runs there
- Fixture clip is checked in (small, license-cleared per M15), so CI runs the real Vision path
