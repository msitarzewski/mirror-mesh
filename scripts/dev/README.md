# scripts/dev/ — developer helpers

Quick-recovery helpers for day-to-day development. Nothing here is part of
the release path; see `scripts/release/` for production / notarization.

## refresh.sh

Clean rebuild + relaunch in one command.

```bash
./scripts/dev/refresh.sh
```

Does, in order:

1. `swift package clean` — wipes the SwiftPM build cache
2. `swift build -c release` — rebuilds (release config to match how the app
   is normally launched)
3. `pkill -f mirrormesh-app` — kills any prior instance still holding the
   camera (non-zero exit when nothing matches is expected and ignored)
4. `swift run -c release mirrormesh-app &` — launches a fresh instance,
   prints the PID

**Use when**: you changed source and the running app looks the same.
Symptoms include UI rows not appearing, log lines from old code still
firing, the camera being held by a process you can't see in the Dock, or
SwiftPM serving you a stale module.

**Don't use when**: you need a signed / notarized bundle for distribution
— that's `scripts/release/archive.sh` + `scripts/release/notarize.sh`.

**Doesn't do**: `rm -rf` of anything, including `~/Library/Application
Support/MirrorMesh/`. The script is deliberately non-destructive beyond
`swift package clean`. If you need to reset identities, manifests, or the
on-disk session log, do that by hand.

**Failure modes**:

| Exit | When | Fix |
|------|------|-----|
| `1` | Xcode.app not found at `/Applications/Xcode.app` | Install Xcode, or edit the script to point at your install |
| swift exit | `swift build` failed | Read the last 5 lines of `swift build` output the script prints, fix, re-run |

The script will not attempt to launch if the build failed (`set -euo
pipefail`), so you won't end up with a stale binary running while you
think you launched a fresh one.

## See also

- `scripts/release/` — the production / Developer-ID / notarization path.
  `archive.sh` produces `build/release/MirrorMesh.app`; `notarize.sh`
  staples Apple's verdict onto it. Use those when you're cutting a
  distributable .zip, not for day-to-day iteration.
- `bench/scripts/` — bench harness drivers (latency, power). Read
  `paper/draft_v1.md` Tables 1–4 for what these produce.
