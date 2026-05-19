# MirrorMesh — Active Context

**Updated**: 2026-05-19 (v0.4.0 in flight)
**Current state machine position**: `BUILD` (v0.4.0 — M31/M33/M36/M37 polish)
**Substate**: `CODING`

---

## Current Focus

**v0.3.0 "Ship It" — in progress 2026-05-19**

Theme: make MirrorMesh distributable and the demo defensible for a paper. Real `.xcodeproj` producing a notarizable `.app`, virtual camera output, WebRTC streaming, MediaPipe backend, real trained CoreML weights, Whisper transcription stub, Homebrew tap, paper draft v0.

Status board: `memory-bank/release/v0.3.0/readme.md`.

ADR-0013 logged: executable entry-point files renamed away from `main.swift` so Xcode's parser is happy.

**Awaiting from user** (to unblock signing/notarization milestones — non-blocking on everything else):
- Apple Developer **Team ID** (10-char like `ABCDE12345`)
- Bundle ID prefix (default `ai.mirrormesh.MirrorMesh` if not specified)
- Signing identity name (default `"Apple Development"` for dev builds; `"Developer ID Application: <Name> (<Team>)"` for distribution)

Paste any of those at any time and I'll wire them into `Local.xcconfig` (gitignored).

## Working Context

- No source tree exists yet
- No tasks under `tasks/2026-05/` yet (only the monthly README)
- Mission file is `mision.md` (misspelled; flagged for rename to `mission.md` pending user decision)

## Pending Decisions (to lift into `decisions.md` once made)

1. **License** — Apache 2.0 vs MIT
2. **Repo layout** — monorepo vs swift-package + xcode-app split
3. **First milestone** — pick one of:
   - Benchmark harness skeleton (measures nothing yet, defines schema)
   - Capture → Vision landmark → JSONL out (minimum end-to-end pipeline slice)
   - Watermarking design doc (no code, just the cryptographic spec)
4. **Mission file rename** — `mision.md` → `mission.md`?

## Recent Context Captured

- User invoked startup with directive: "use memory-bank/mision.md to create the rest of the framework"
- User has requested no clarifying questions during this turn — reasonable defaults applied
- Framework files created on 2026-05-19 based on AGENTS.md v2.2 conventions

## State Persistence Notes

This file is the canonical recovery point for compaction. On any state transition, append a dated line below.

### State Transition Log

- 2026-05-19 — Initial scaffold. Entered `PLAN`/`IDLE` after creating core Memory Bank files.
- 2026-05-19 — Release v0.1.0 created. Monorepo ADR-0011 approved.
- 2026-05-19 — M1–M4 built inline (scaffold, telemetry, capture, landmarks).
- 2026-05-19 — Dispatched 4 parallel agents for M5–M9.
- 2026-05-19 — M5–M9 integrated, one rename for namespace collision (`CaptureConfig` → `ManifestCaptureConfig`).
- 2026-05-19 — M10 built inline (Pipeline orchestrator, mirrormesh-bench, scenarios, summarizer). Demo green. Entered `DOCS`/`IDLE`.
- 2026-05-19 — Xcode installed. ADR-0012 approved. v0.2.0 "Living Window" planning entered. State: `PLAN`/`IDLE`.
- 2026-05-19 — M11 (Swift Testing) built inline. Round 1 of agents dispatched in parallel: M12 (Mobile App Builder), M14 (macOS Spatial/Metal), M16 (Performance Benchmarker), M18 (AI Engineer), M19 (DevOps Automator). All five returned clean.
- 2026-05-19 — Round 2 of agents: M13 (Mobile App Builder), M15 (macOS Spatial/Metal), M17 (Performance Benchmarker). All three returned clean.
- 2026-05-19 — M20 (demo polish, README rewrite, LICENSE Apache 2.0, figures) built inline. v0.2.0 closed. Entered `DOCS`/`IDLE`.
- 2026-05-19 — Xcode parser error: `@main` + `main.swift` collision in three executable targets. Renamed files (ADR-0013, R13). CLI + tests still green.
- 2026-05-19 — v0.3.0 "Ship It" planning entered. State: `PLAN`/`IDLE`.
