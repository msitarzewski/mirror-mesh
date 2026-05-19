# CI — GitHub Actions

MirrorMesh runs continuous integration on GitHub Actions for every push and
pull request. The pipeline is defined in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Runner

- **Image**: `macos-14` (Apple Silicon arm64). `macos-latest` is intentionally
  avoided because that alias is occasionally pinned to Intel runners during
  GitHub Actions image rollouts. Bump to `macos-15` once both the image and the
  `latest-stable` Xcode are confirmed available on the project's runners.
- **Xcode**: pinned via [`maxim-lobanov/setup-xcode@v1`](https://github.com/maxim-lobanov/setup-xcode)
  with `xcode-version: latest-stable`. The first step logs `swift --version`
  and `xcodebuild -showsdks` so failures tied to a toolchain bump are easy to
  attribute.

## Stages (in order)

1. **Checkout** — `actions/checkout@v4`.
2. **Setup Xcode** — `maxim-lobanov/setup-xcode@v1`.
3. **Cache** — `actions/cache@v4` over `.build`,
   `~/Library/Caches/org.swift.swiftpm`, and `~/.swiftpm`. Key is derived from
   `Package.swift` + `Package.resolved`.
4. **Toolchain info** — logs Swift / Xcode versions; useful when debugging a
   green-locally / red-on-CI delta.
5. **`swift build`** — full library + executables.
6. **`swift test`** — full Swift Testing suite under the Xcode toolchain.
7. **`swift run mirrormesh-selftest`** — CLT-friendly smoke binary; see
   `memory-bank/decisions.md#ADR-0012`.
8. **`swift run mirrormesh-bench --scenario bench/scenarios/demo.json`** —
   writes `bench/out/demo_<timestamp>.jsonl` + `.manifest.json`.
9. **`swift run mirrormesh-verify --manifest …`** — verifies the newest
   manifest (the timestamped filename is resolved with
   `ls -1t bench/out/demo_*.manifest.json | head -1`, not shell glob, so the
   step is robust against zero-or-multiple matches).
10. **`python3 bench/scripts/summarize.py …`** — prints P50/P95/P99 per stage
    + end-to-end stats to the job log.
11. **Upload artifacts** — `bench/out/` archived as
    `bench-out-<run-id>` with a 14-day retention.

The job has a 15-minute timeout. With a warm cache, a clean run completes in
under 5 minutes.

## Reading failures

Every step is named, so the GitHub UI surfaces the failure at the failing
stage. Common patterns:

| Symptom                                           | Likely cause                                                            | Where to look |
| ------------------------------------------------- | ----------------------------------------------------------------------- | ------------- |
| `swift build` fails with "no such module"         | A new target or product not wired into `Package.swift`                  | Build log header line 1-3 |
| `swift test` fails with a single test name        | A regression in that test's module                                      | Click the failing test in the log; the file path is printed |
| `mirrormesh-selftest` exits non-zero              | Vision or synthetic-pipeline regression on the CLT path                 | The selftest prints which stage failed |
| `mirrormesh-bench` exits non-zero                 | Scenario regression or runner under load (rare for the demo scenario)   | Re-run; if persistent, file an issue with the JSONL artifact |
| `mirrormesh-verify` exits non-zero                | Manifest schema drift or watermark verification regression              | Download the `bench-out-*` artifact and inspect the manifest |
| `python3 bench/scripts/summarize.py` exits non-zero | Malformed JSONL (often a partial write from a crashed bench)         | Check the JSONL artifact for truncation |

If the workflow fails *before* `swift build`, suspect the runner image or the
Xcode pin. Open the **Toolchain info** step and compare `swift --version` and
`xcodebuild -version` with a last-known-good run.

## Caching

The cache key includes `Package.swift` and `Package.resolved`. Any change to
either invalidates the cache — expected, since SwiftPM dependency graph
changes invalidate built artifacts. If you find CI doing full rebuilds when
the manifests are untouched, check the **Cache** step for a `Cache not found`
message and verify the `restore-keys` fallback.

## Skipping CI locally

CI **does not** currently honor `[ci skip]` in commit messages — there is no
filter wired into `ci.yml`. This is documented as an aspirational convention:
when CI minutes become a real constraint we will add

```yaml
if: "!contains(github.event.head_commit.message, '[ci skip]')"
```

to the job's top-level. Until then:

- For pure documentation PRs, you can mark the PR as draft to delay reviewer
  attention, but CI still runs.
- For local experiments, push to a branch named `wip/*` and only open a PR
  when ready.

## Release workflow

Tagged pushes matching `v*` trigger
[`.github/workflows/release.yml`](../.github/workflows/release.yml). It runs
the same build + test + bench, packages `bench/out/` into a tarball, uploads
the tarball as a workflow artifact, and creates a GitHub Release (via
`softprops/action-gh-release@v2`) with the tarball attached and auto-generated
release notes.

## Dependabot

[`.github/dependabot.yml`](../.github/dependabot.yml) keeps third-party GitHub
Actions current. Weekly PRs land on Mondays at 06:00 UTC, labelled `ci` +
`dependencies`. Review and merge as you would any other PR; the CI workflow
itself acts as the validation.

## Action pinning policy

All third-party actions are pinned by **major version** (`@v4`, `@v1`,
`@v2`). Never pin to `@latest` — silent breakages from a transitive action
update are painful to debug. Dependabot will surface major-version bumps as
PRs.
