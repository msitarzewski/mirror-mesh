# Instruments Signpost Guide

MirrorMesh emits `os_signpost` intervals around every pipeline stage on the
`ai.mirrormesh` subsystem under the `pointsOfInterest` category. Open a captured
`.trace` file in Instruments and the **Points of Interest** instrument shows one
lane per stage; nothing else is needed.

## Capturing a trace

```bash
bench/scripts/trace.sh
# writes bench/out/mirrormesh_<timestamp>.trace
open bench/out/mirrormesh_*.trace
```

The script launches `mirrormesh-bench --scenario bench/scenarios/demo.json` under
`xctrace` with the **Time Profiler** template, which already includes a Points
of Interest track.

## Lanes that appear

One lane per `StageID` plus an end-to-end umbrella:

| Lane         | Source file                                            | Wraps                                  |
|--------------|--------------------------------------------------------|----------------------------------------|
| `pipeline`   | `Sources/MirrorMeshOutput/Pipeline.swift`              | one frame, capture → watermark         |
| `capture`    | `LiveCaptureSource.swift` / `SyntheticFrameSource.swift` | delegate body / synth render          |
| `vision`     | `Sources/MirrorMeshVision/LandmarkExtractor.swift`      | `VNSequenceRequestHandler.perform`     |
| `solver`     | `Sources/MirrorMeshSolver/GeometricSolver.swift`        | `solve(_:)`                            |
| `render`     | `Sources/MirrorMeshRender/Renderer.swift`               | `render(captured:landmarks:...)`       |
| `watermark`  | `Sources/MirrorMeshWatermark/Watermarker.swift`         | `watermark(_:)`                        |

Each interval carries a metadata field `frame=<id>` so you can correlate a slow
interval back to a specific frame ID across the JSONL telemetry log.

## Interpreting the signposts

- Each interval is `os_signpost(.begin)` → `os_signpost(.end)` with a unique
  `OSSignpostID`. Concurrent frames don't collide.
- The `pipeline` umbrella is the wall-clock budget for one frame. The five
  stage lanes nest inside it; their sum should be very close to the umbrella
  width (the slack is pure pipeline overhead — `await`, telemetry, manifest
  writes).
- When the trace isn't recording, signposts are probe-only no-ops, so they're
  safe to leave enabled in release builds.

## Finding per-frame outliers

1. In Instruments, select the **Points of Interest** track.
2. Right-click → **Group by** → **Signpost Name**. You now see one row per
   stage.
3. Sort by **Duration** descending in the detail table. The top entries are
   the slow frames. The `frame=` annotation tells you which frame ID — match
   it against `bench/out/<scenario>_<stamp>.jsonl` to see the captured
   per-stage timings.
4. To find spikes, switch the detail table to **Summary** → **Duration Max**.

## What "good" vs "bad" looks like

| Stage      | Good (median)   | Bad (p99)             |
|------------|-----------------|-----------------------|
| capture    | < 1 ms          | sustained > 5 ms      |
| vision     | 6–15 ms         | > 30 ms               |
| solver     | < 1 ms          | > 3 ms                |
| render     | 1–4 ms          | > 10 ms               |
| watermark  | < 1 ms          | > 4 ms                |
| pipeline   | 12–20 ms (@30fps) | > 33 ms (drops frames) |

Signs of trouble in a trace:

- **vision lane wider than the umbrella minus everything else** → Vision is
  the dominant cost (expected for live mode; investigate revision/region
  settings if profile shows it ballooning).
- **render lane has periodic stalls** → GPU contention or pixel-buffer pool
  exhaustion. Cross-check `.error(stage: .render, message: "pool exhausted")`
  events in the JSONL log.
- **pipeline lane > 33 ms for >1 % of frames** → frame drops; we miss the
  30 fps SLA.
- **watermark lane growing over time** → manifest accumulation; verify
  `ManifestWriter` is flushing.
