# Install

Today there is exactly one way to install MirrorMesh: **build from source**.
Homebrew tap, GitHub Release artifacts, and a notarized `.app` cask are all
planned for a future release but are not yet published. Those install paths
are documented at the bottom of this file so contributors know what's coming;
none of them work as of v1.0.0-dev.

| Method | Status | Gets you |
|--------|--------|----------|
| [Build from source](#build-from-source) | ✅ works today | Everything, freshest commits |
| [Homebrew (CLI)](#planned-homebrew-cli-bench) | ⏳ planned (v1.1+) | `mirrormesh-bench` on `$PATH` |
| [Homebrew (Cask)](#planned-homebrew-cask-app) | ⏳ planned (v1.1+) | `MirrorMesh.app` in `/Applications` |
| [GitHub Release page](#planned-github-release-page) | ⏳ planned (v1.1+) | `.app.zip` + bench binary |

## Build from source

For paper reproducibility, contributions, or just to run the latest `main`:

```bash
git clone https://github.com/msitarzewski/mirror-mesh.git
cd mirror-mesh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

swift build
swift test --skip MirrorMeshStreamTests --skip MirrorMeshVirtualCameraTests --skip MirrorMeshMediaPipeTests
swift run mirrormesh-app
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
```

Requires macOS 14+, Apple Silicon, and a full Xcode install (Command Line
Tools alone is not sufficient — see [ADR-0012](../memory-bank/decisions.md)).

To produce a signed `.app` locally, see [`notarization.md`](./notarization.md).

---

## Planned: Homebrew (CLI bench)

> Not yet published. The commands below will not work until the
> `msitarzewski/homebrew-tap` repo exists and a release artifact is attached.

```bash
brew tap msitarzewski/homebrew-tap https://github.com/msitarzewski/homebrew-tap
brew install mirrormesh-bench

mirrormesh-bench --help
```

The formula will install a prebuilt `mirrormesh-bench` for `macos-arm64`. The
sha256 is pinned to the GitHub Release artifact; if the file changes, brew
refuses to install — that's intentional.

## Planned: Homebrew (Cask app)

> Not yet published. Requires notarization (blocked on user-supplied
> `DEVELOPMENT_TEAM`). See [`notarization.md`](./notarization.md).

```bash
brew tap msitarzewski/homebrew-tap https://github.com/msitarzewski/homebrew-tap
brew install --cask mirrormesh

open -a MirrorMesh
```

The cask will install the notarized, stapled `MirrorMesh.app` into
`/Applications`. Because it'll be notarized, Gatekeeper accepts it on first
launch without the "unidentified developer" prompt.

## Planned: GitHub Release page

> Not yet published — the GitHub Releases page at
> `https://github.com/msitarzewski/mirror-mesh/releases` is empty as of
> v1.0.0-dev. Once a tagged release lands, each release will publish:

1. `MirrorMesh-macos-arm64.zip` (the app)
2. `mirrormesh-bench-macos-arm64.zip` (the CLI)
3. `release.json` with the canonical sha256s

```bash
shasum -a 256 MirrorMesh-macos-arm64.zip
# Compare to "app_sha256" in release.json
```

---

## Verifying an install

```bash
# CLI (after Homebrew install)
which mirrormesh-bench
mirrormesh-bench --help

# App (after cask install)
ls /Applications/MirrorMesh.app
codesign --verify --deep --strict /Applications/MirrorMesh.app
spctl --assess --type execute --verbose /Applications/MirrorMesh.app
# Expected: "accepted ... source=Notarized Developer ID"
```

If `spctl` reports anything other than "Notarized Developer ID", you grabbed
an unsigned dev build — fine for local hacking, not for production use.

## Uninstall

```bash
# Built from source — just delete the clone:
rm -rf /path/to/mirror-mesh

# Once Homebrew install is published:
brew uninstall mirrormesh-bench
brew uninstall --cask --zap mirrormesh
brew untap msitarzewski/homebrew-tap
```

## Troubleshooting

- **"can't be opened because Apple cannot check it for malicious software"** —
  applies to the notarized cask only (once it exists). Until then, build from
  source via `swift build` / `swift run`.
- **`mirrormesh-bench --scenario` fails on permission** — bench writes to
  `bench/out/` relative to `$PWD`. Run it from a writable directory.
