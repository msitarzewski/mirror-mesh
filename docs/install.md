# Install

Three supported install paths for MirrorMesh. Pick whichever matches what you
need.

| Method | Gets you | Requires |
|--------|----------|----------|
| [Homebrew (CLI)](#homebrew-cli-bench) | `mirrormesh-bench` on `$PATH` | macOS 14+, Apple Silicon, Homebrew |
| [Homebrew (Cask)](#homebrew-cask-app) | `MirrorMesh.app` in `/Applications` | macOS 14+, Apple Silicon, Homebrew |
| [GitHub Release page](#github-release-page) | `.app.zip` + bench binary | macOS 14+, Apple Silicon |
| [Build from source](#build-from-source) | Everything, freshest commits | Xcode 15+, Apple Silicon |

> **Maintainer**: replace `<user>/<repo>` with the published GitHub owner/repo.

## Homebrew (CLI bench)

```bash
brew tap <user>/<repo> https://github.com/<user>/<repo>
brew install mirrormesh-bench

mirrormesh-bench --help
```

The formula installs a prebuilt `mirrormesh-bench` for `macos-arm64`. The
sha256 is pinned to the GitHub Release artifact; if the file changes, brew
refuses to install — that's intentional.

## Homebrew (Cask app)

```bash
brew tap <user>/<repo> https://github.com/<user>/<repo>
brew install --cask mirrormesh

open -a MirrorMesh
```

The cask installs the notarized, stapled `MirrorMesh.app` into
`/Applications`. Because it's notarized, Gatekeeper accepts it on first
launch without the "unidentified developer" prompt.

## GitHub Release page

Each tagged release publishes the same artifacts the Homebrew formulas
consume:

1. Visit `https://github.com/<user>/<repo>/releases`.
2. Pick a release.
3. Download `MirrorMesh-macos-arm64.zip` (the app) or
   `mirrormesh-bench-macos-arm64.zip` (the CLI).
4. Unzip. For the app, drag it to `/Applications`. For the CLI, move
   `mirrormesh-bench` somewhere on your `$PATH`.

The `release.json` attached to each release lists the canonical sha256s if
you want to verify the download:

```bash
shasum -a 256 MirrorMesh-macos-arm64.zip
# Compare to "app_sha256" in release.json
```

## Build from source

For paper reproducibility, contributions, or just to run the latest
`main`:

```bash
git clone https://github.com/<user>/<repo>.git mirror-mesh
cd mirror-mesh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

swift build
swift test
swift run mirrormesh-app
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
```

To produce a signed `.app` locally, see [`notarization.md`](./notarization.md).

## Verifying an install

```bash
# CLI
which mirrormesh-bench
mirrormesh-bench --help

# App
ls /Applications/MirrorMesh.app
codesign --verify --deep --strict /Applications/MirrorMesh.app
spctl --assess --type execute --verbose /Applications/MirrorMesh.app
# Expected: "accepted ... source=Notarized Developer ID"
```

If `spctl` reports anything other than "Notarized Developer ID", you grabbed
an unsigned dev build — fine for local hacking, not for production use.

## Uninstall

```bash
# Homebrew
brew uninstall mirrormesh-bench
brew uninstall --cask --zap mirrormesh
brew untap <user>/<repo>

# Manual
rm -rf /Applications/MirrorMesh.app
rm /usr/local/bin/mirrormesh-bench  # or wherever you put it
```

## Troubleshooting

- **"can't be opened because Apple cannot check it for malicious software"** —
  you grabbed the source-built / unsigned bundle. Use the brew cask or the
  release-page download instead, or right-click → Open once.
- **`brew install` fails on sha mismatch** — the release file changed
  between tap publish and download. Run `brew update && brew install` again,
  or grab the artifact directly from the release page and verify by hand.
- **`mirrormesh-bench --scenario` fails on permission** — bench writes to
  `bench/out/` relative to `$PWD`. Run it from a writable directory.
