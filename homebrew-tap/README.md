# homebrew-tap

Homebrew formula and cask scaffolding for [MirrorMesh](https://github.com/msitarzewski/mirror-mesh).

> **STATUS: NOT YET PUBLISHED.** The instructions below describe the *planned*
> install flow for the day the tap goes live as `msitarzewski/homebrew-tap`.
> Right now there is no published Homebrew tap, no notarized `.app`, no
> GitHub release artifacts. None of the `brew tap` / `brew install` commands
> below will work yet. Build from source via `swift build` / `swift run`
> (see the top-level [README](../README.md)) until v1.0 actually ships.

This directory lives inside the main repo during early development. Once it
stabilizes it moves to a dedicated `homebrew-tap` GitHub repo so that
`brew tap` works without a path argument.

## Install — CLI bench

```bash
brew tap msitarzewski/homebrew-tap https://github.com/msitarzewski/homebrew-tap
brew install mirrormesh-bench

mirrormesh-bench --help
```

You'll get `mirrormesh-bench` on your `$PATH` (typically
`/opt/homebrew/bin/mirrormesh-bench`). The binary is a prebuilt
`macos-arm64` release artifact downloaded from the GitHub Releases page —
no local Swift build, no Xcode required.

## Install — `MirrorMesh.app`

```bash
brew tap msitarzewski/homebrew-tap https://github.com/msitarzewski/homebrew-tap
brew install --cask mirrormesh

open -a MirrorMesh
```

The cask installs the notarized, stapled `.app` bundle into `/Applications`.
On first launch macOS does the standard Gatekeeper check; because the app
is notarized, you get no "unidentified developer" warning.

## During local development

While the tap still lives inside the main repo, you can use it without
publishing:

```bash
# From inside this repo
brew tap mirrormesh/local ./homebrew-tap
brew install mirrormesh/local/mirrormesh-bench
brew install --cask mirrormesh/local/mirrormesh
```

`brew tap <name> <path>` creates a local tap that brew treats as if it were
remote. Useful for testing formula changes before cutting a release.

## How the formulas stay in sync with releases

`.github/workflows/release.yml` builds the `.app.zip` and
`mirrormesh-bench-macos-arm64.zip`, computes their sha256s, and writes them
into `release-artifacts/release.json` (also attached to the GitHub Release).

When updating the tap for a new version:

1. Bump `version` in both `Formula/mirrormesh-bench.rb` and
   `Casks/mirrormesh.rb` to match the tag (e.g. `0.3.1`).
2. Copy `bench_sha256` from `release.json` into the formula's `sha256` field.
3. Copy `app_sha256` from `release.json` into the cask's `sha256` field.
4. Commit and push the tap.

A future workflow can automate this with a `dispatch` step that opens a PR
against this directory whenever a release publishes — see `M30` notes.

## Verifying the install

```bash
which mirrormesh-bench                              # /opt/homebrew/bin/mirrormesh-bench
mirrormesh-bench --scenario /path/to/demo.json      # produces bench/out/*

ls /Applications/MirrorMesh.app                     # cask install
codesign --verify --deep --strict /Applications/MirrorMesh.app
spctl --assess --type execute --verbose /Applications/MirrorMesh.app
# Expected: "accepted ... source=Notarized Developer ID"
```

## Uninstall

```bash
brew uninstall mirrormesh-bench
brew uninstall --cask mirrormesh    # use --zap to also remove caches/prefs
brew untap msitarzewski/homebrew-tap
```
