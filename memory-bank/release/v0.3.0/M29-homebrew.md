# M29 — Homebrew Tap

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M23 (need a notarized artifact)
**Blocks**: M30

## Objective

`brew tap mirrormesh/tap && brew install mirrormesh-bench` works. The notarized `.app` is also installable as a Cask.

## Deliverables

- Separate `homebrew-tap` repo (or a directory inside this repo with formulas)
- `Formula/mirrormesh-bench.rb` — installs the `mirrormesh-bench` CLI binary
- `Casks/mirrormesh.rb` — installs the notarized `.app` into `/Applications`
- Both formulas reference a release artifact attached to the GitHub Releases page (release.yml from M19 already publishes there)
- `docs/install.md` — install methods (brew, source, release page)

## Verification

```bash
# From inside the project:
brew tap mirrormesh/tap ./homebrew-tap
brew install mirrormesh-bench
which mirrormesh-bench    # /opt/homebrew/bin/mirrormesh-bench
mirrormesh-bench --scenario bench/scenarios/demo.json

brew install --cask mirrormesh
ls /Applications/MirrorMesh.app
```

## Notes

- The formula computes the binary's sha256 at release time (release.yml automates this)
- Cask requires the binary to be notarized (else Gatekeeper blocks); hence the dependency on M23
- For initial development, the tap can live inside this repo; once mature it moves to its own GitHub repo
