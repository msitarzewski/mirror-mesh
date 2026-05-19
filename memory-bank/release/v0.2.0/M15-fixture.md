# M15 — Real-Face Fixture + `FileFrameSource`

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M20

## Objective

A small (≤ 8 MB), license-cleared, real-face fixture clip checked into the repo, plus a `FileFrameSource` that plays it through the pipeline. This is the artifact that lets the **real Vision landmark path** run in headless CI — without it we can never exercise the live path automatically.

## Deliverables

- `Tests/Fixtures/face_neutral_3s.mp4` (or `.mov`) — ≤ 8 MB, ~3 seconds, ~30 FPS, 720p, public-domain / Creative-Commons / synthetic-generated source. **Document provenance** in `Tests/Fixtures/PROVENANCE.md` with license and source link.
- `Sources/MirrorMeshCapture/FileFrameSource.swift` — `public actor FileFrameSource: FrameSource` that reads frames from a file URL via `AVAssetReader`, paces them at the file's native FPS, and emits `CapturedFrame`s identical in shape to the live source
- `bench/scenarios/fixture.json` — runs the full Vision path against the fixture
- A new test target `MirrorMeshFixtureTests` that:
  - Constructs a `Pipeline` with `FileFrameSource`
  - Runs to completion
  - Asserts that `>50%` of frames produced non-nil landmarks (Vision found a face)
  - Asserts manifest verifies

## Behavior

- `swift run mirrormesh-bench --scenario bench/scenarios/fixture.json` runs the real Vision path against the fixture, prints P50/P95 numbers
- Numbers are recorded in `bench/baselines/fixture.jsonl` for diff-tracking

## Provenance constraints

Per `projectRules.md` R5 (model provenance) and `productContext.md` (no PII of real third parties):

- Acceptable sources: NIST face-recognition test sets that are public-domain, talking-head openly-licensed creator footage, **OR** a procedurally generated face from a separate open synthetic-data project (e.g. a release-licensed SyntheticHumanFace dataset)
- **Not** acceptable: scraped social-media footage, anything without an explicit license, anything depicting an identifiable third party who hasn't released image rights

## Verification

```bash
swift test --filter MirrorMeshFixtureTests
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json
```

## Notes

- The fixture is the first real test of `LandmarkExtractor` against actual Vision output — expect to surface bugs around bounding-box transforms, image orientation, or normalized-coordinate flipping
