# M16 — Instruments Signpost Coverage

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M20

## Objective

Every pipeline stage emits `os_signpost` intervals so an Instruments trace shows a clean, attributable per-stage timeline. A helper script captures a `.trace` file the user can open directly.

## Deliverables

- `MirrorMeshCore.Signpost` (already exists in skeleton form) — extended with explicit intervals for capture, vision, solver, render, watermark, recorder
- Each stage's existing `TelemetryBus.emit(.stageStart/.stageEnd)` is paired with a matching `os_signpost(.begin/.end)` call (don't duplicate work — wrap once)
- `bench/scripts/trace.sh` — wraps `xcrun xctrace record --template "Time Profiler" --launch swift run mirrormesh-app --smoke-test` and writes the `.trace` to `bench/out/`
- `docs/instruments.md` — how to interpret the trace, what each lane shows, screenshot of expected output

## Verification

```bash
bench/scripts/trace.sh
ls bench/out/*.trace
open bench/out/<latest>.trace    # Instruments opens; signposts visible
```

Automated: a unit test that flips a `Signpost.intervalsEnabled` flag and confirms the interval API doesn't throw.

## Notes

- `os_signpost` is zero-cost when the trace isn't recording (it's just a no-op syscall behind a probe)
- Use `OSLog(subsystem: "ai.mirrormesh", category: .pointsOfInterest)` — `pointsOfInterest` makes Instruments show the lane prominently
