# MirrorMesh — Project Rules

**Updated**: 2026-05-19 (initial scaffold)

These rules are load-bearing. Violations require explicit ADR in `decisions.md`.

---

## R1 — No Identity Spoofing of Real Third Parties

Identity transforms target one of:
- Self (user's own face)
- Non-human stylized (cartoon, animal, abstract)
- Real person with signed consent manifest (curated, reviewed at intake)

No PR may add a code path that bypasses this constraint, and no model may be bundled that exists primarily to impersonate a specific real person.

## R2 — Watermarking and Disclosure Are Mandatory by Default

Default shipped builds carry visible badge + cryptographic frame signing + session manifest. A `--research-no-watermark` flag may exist for paper reproducibility experiments but must:

- Be unavailable in release `.app` bundles
- Print a clear stderr banner in CLI / dev builds
- Be excluded from any default-build CI artifact

## R3 — Local-Only on the Inference Hot Path

No code on the per-frame inference path may make a network call. Streaming output (WebRTC) is allowed; inference fallback to cloud is not.

## R4 — No Cloud LLM / ML APIs as Inference Backends

Anthropic, OpenAI, ElevenLabs, Google Cloud, etc. are not permitted as backends for face / voice / expression inference. Such APIs may be used during *paper authoring* or *dataset curation* but never invoked from the shipped binary.

## R5 — Model Provenance Required

Every model file under `models/` ships with a `.provenance.json` sidecar:
- `source` (URL or paper)
- `license`
- `training_data_summary` (one paragraph)
- `conversion_pipeline` (script reference)
- `sha256`

CI verifies presence and hash match. Missing provenance fails the build.

## R6 — Reuse Before Create

Per AGENTS.md §1. Specifically for this project:

- Stage interfaces live in one place — extend, don't fork
- Benchmark schema is shared — new metrics extend existing JSONL, no parallel formats
- Metal shaders live in `shaders/` with shared utility headers

## R7 — File Naming and Layout (proposed; adoption with first source PR)

```
mirrormesh/
  Package.swift
  Sources/
    MirrorMeshCore/       # pipeline orchestration
    MirrorMeshCapture/    # AVFoundation
    MirrorMeshVision/     # landmarks
    MirrorMeshSolver/     # expression / blendshape
    MirrorMeshRender/     # Metal
    MirrorMeshWatermark/  # signing, badging, manifest
    MirrorMeshOutput/     # CMIOExtension, WebRTC
  Tests/
  shaders/
  models/
  bench/
  docs/
  app/                    # SwiftUI app shell
```

## R8 — Style

- `swift-format` config in repo root; CI enforces
- `swiftlint` warnings allowed, errors blocking
- No `// TODO` without a tracking task reference in `tasks/`

## R9 — Tests

- Unit tests live next to the module they cover under `Tests/`
- Benchmarks live in `bench/` and produce JSONL + summary markdown
- Snapshot / fixture media is small (≤ 1 MB per file) and license-cleared
- No flaky tests merged — retry-to-pass is not a fix

## R10 — Approval Gates

Per AGENTS.md, no commits without explicit user approval. Memory Bank task docs (`tasks/*/`), `decisions.md` updates, and `projectRules.md` updates also require approval before write — except during framework scaffolding (this initial commit's authoring window).

## R11 — Comments

Default: no comments. Add comments only where the *why* is non-obvious — a hidden constraint, a workaround for a specific Apple API bug, a latency-driven choice that would otherwise look wrong. No "what" comments next to self-evident code.

## R13 — Executable Entry-Point Files

Executable `.executableTarget`s have **two halves of one rule**:

1. **No `main.swift` + `@main` in the same module.** A file literally named `main.swift` is the implicit entry point — Swift treats its top-level code as the program body. Adding `@main` anywhere in the same module conflicts. Use names like `BenchCLI.swift`, `VerifyCLI.swift`, `MirrorMeshAppMain.swift`.

2. **No top-level executable code outside `@main` in any non-`main.swift` file.** When the entry file is *not* named `main.swift`, the executable target's entry point MUST be a `@main` type with a `static func main()`. All executable statements (`let app = …`, `app.run()`, etc.) live inside that function. Top-level `let`/`var`/expressions in any other file produce "Expressions are not allowed at the top level" in Xcode (even when CLI `swift build` accepts them).

Together: every executable target picks the `@main` style and stays consistent. See ADR-0013.

**Why**: Xcode's parser is strict; CLI `swift build` is lenient. Relying on `swift build` alone means the package compiles from the terminal but Xcode shows red errors and the IDE workflow is broken. We've hit this twice now — once via `main.swift` colliding with `@main`, once via top-level code in a `@main`-less file. Both fail the same rule.

## R14 — `.copy` (not `.process`) for Runtime-Loaded Resources

When a SwiftPM resource is **read at runtime as raw bytes** (Metal shader source, ML model definitions, fixture media that must arrive unchanged), declare it in `Package.swift` with `.copy("Path")`, not `.process("Path")`.

**Why**: `.process` applies platform-specific compilation to recognized file types — `.metal` → `default.metallib`, `.storyboard` → `nib`, etc. The transformation only happens when the relevant compiler is available (Xcode's metal compiler is present; CommandLineTools' is not). Result: the same package "works" under CLI `swift build` and fails under Xcode `xcodebuild`, or vice versa, because the bundle ships different contents.

Specifically: the Metal shader pipeline in `MirrorMeshRender` compiles source at runtime via `device.makeLibrary(source:)`. The `.metal` files must arrive raw — see `Sources/MirrorMeshRender/MetalContext.swift:48-57`.

**Counter-rule (use `.process`)**: when you want SwiftPM's processing — Asset Catalogs, Localizable.strings, storyboards. Anything Xcode's content pipeline normally compiles.

## R12 — Refuse on Sight

The following requests will be refused or escalated, not implemented:

- "Add a celebrity preset"
- "Make watermark optional in release"
- "Add cloud fallback for quality"
- "Bypass consent for testing"
- "Disable disclosure chirp"
- "Add anti-detection / anti-forensics mode"

If a user request matches the spirit of these, ask for re-framing before refusing — but do not implement.
