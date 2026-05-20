# MirrorMesh — Architectural Decisions Log

ADR format: short, dated, status-tracked. New entries appended.

---

## 2026-05-19 — ADR-0001: Apple Silicon-Only Target

**Status**: Approved (sourced from `mision.md`)
**Context**: Project thesis depends on unified memory, Neural Engine, and Metal/CoreML integration. Supporting Intel macOS or other platforms would dilute the core claim and multiply test surface.
**Decision**: Build targets arm64 macOS only. Minimum macOS version 14 (Sonoma); 15+ preferred.
**Alternatives considered**:
- Cross-platform (Linux + macOS): rejected — pipeline performance claims wouldn't generalize, and the paper's novelty is platform-specific.
- iOS / iPadOS: deferred — interesting future direction but not in scope for M0–M6.
**Consequences**: Smaller addressable user base, but sharper thesis and tractable engineering surface.

---

## 2026-05-19 — ADR-0002: Local-Only Inference, No Cloud Fallback

**Status**: Approved (sourced from `mision.md`)
**Context**: "Local" is a research claim and a privacy promise. A cloud fallback would undermine both.
**Decision**: Inference hot path makes no network calls. Network use restricted to: model downloads (opt-in updates), telemetry (opt-in), user-driven streaming (WebRTC output).
**Alternatives**: Hybrid local/cloud with quality fallback — rejected, see `projectRules.md` R3 and R4.
**Consequences**: We own the latency/quality tradeoffs entirely; no escape valve.

---

## 2026-05-19 — ADR-0003: Watermarking and Disclosure On By Default

**Status**: Approved (sourced from `mision.md`)
**Context**: Differentiates MirrorMesh from impersonation tooling; central to publishable framing.
**Decision**: Default builds carry visible badge + cryptographic frame signature + session manifest, and audio carries periodic disclosure marker. Bypass exists only for research reproducibility, gated as in `projectRules.md` R2.
**Alternatives**:
- Optional / off by default: rejected — defeats the trust-preserving framing.
- Visible-only: deferred — see ADR-0004.
**Consequences**: Some users will fork to remove. We accept that and rely on cryptographic signing being harder to strip than visible badges.

---

## 2026-05-19 — ADR-0004: Watermark Scheme — Layered (Visible + Cryptographic + Manifest)

**Status**: Proposed (pending design doc)
**Context**: Single-layer watermarks are trivially defeated; relying on metadata alone fails when codecs strip it; visible-only is removable.
**Decision (proposed)**: Ship all three layers from M3 onward — visible composite, cryptographic signature embedded in frame metadata where available, and an out-of-band signed session manifest file written alongside any recording.
**Alternatives**:
- Visible-only: cheap but trivially defeated.
- Crypto-only: invisible to humans; defeats the social signal.
- Steganographic frame embedding: research-grade, may regress under re-encoding — track as future work.
**Open**: spec details (which signature scheme, manifest format) deferred to M3 design doc.

---

## 2026-05-19 — ADR-0005: License — Apache 2.0 (SUPERSEDED by ADR-0014)

**Status**: Superseded by ADR-0014 on 2026-05-19. Original notes retained for history.
**Context**: Per mission, Apache 2.0 or MIT preferred. "Anti-open-source morality clauses" rejected. Selection needed before first public release.
**Decision**: **Apache 2.0**. Adopted because:
1. Explicit patent grant — meaningful for an Apple-platform research project where Apple may later add overlapping patents in Vision / CoreML / Metal. Apache's grant insulates downstream users.
2. Contributor clarity — Apache's Section 5 makes contribution licensing unambiguous, helpful as the project takes external PRs.
3. NOTICE-file mechanism gives us a clean place to keep attribution for any future vendored components (LivePortrait-class research code, etc.).
**Tradeoffs accepted**:
- Slightly heavier file headers vs MIT.
- Apache-2.0 is incompatible with GPLv2 (not v3). Acceptable — we don't intend to incorporate GPLv2-only code.
**Constraint adopted**: No restrictive use clauses. Mission constraints (watermark, no third-party impersonation, consent gating) are enforced by *defaults and architecture*, not license terms.
**Artifact**: `LICENSE` at repo root. Source headers added as `// Copyright 2026 The MirrorMesh Project Authors / SPDX-License-Identifier: Apache-2.0` over time (not blocking v0.2.0).

---

## 2026-05-19 — ADR-0011: Monorepo Layout

**Status**: Approved (user directive 2026-05-19)
**Context**: Project has ~8 modules plus a benchmark harness, shaders, models, docs, and an app shell. Coordination across modules is constant during research phase; cross-cutting refactors will be frequent.
**Decision**: Monorepo. Single git repository containing `Sources/`, `Tests/`, `app/`, `shaders/`, `models/`, `bench/`, `docs/`, `memory-bank/`, and release tooling. Swift Package Manager as the canonical build system; Xcode project layered on top for the app shell.
**Alternatives**:
- Multi-repo with submodules: rejected — overhead during pre-1.0 iteration outweighs encapsulation benefit.
- Single Xcode workspace without SPM: rejected — SPM is the modern path and gives us CI portability.
**Consequences**: All modules version together; clone-and-build is a single `swift build`. Repo grows over time — model binaries kept out of the main repo per `techContext.md`.

---

## 2026-05-19 — ADR-0012: Xcode Toolchain Available; CLT Fallback Removed in v0.2.0

**Status**: Approved (user has Xcode open in this directory 2026-05-19)
**Context**: v0.1.0 was built under Command Line Tools alone, which forced a workaround: a `mirrormesh-selftest` executable instead of `.testTarget` entries (XCTest / swift-testing both require Xcode's macro plugin). Xcode is now installed at `/Applications/Xcode.app` but `xcode-select` still points to `/Library/Developer/CommandLineTools`.
**Decision**: v0.2.0 forward, the canonical build path uses Xcode. Two acceptable invocations:
1. Persistent (preferred): `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. Per-invocation: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift ...`

Restore real test targets (`.testTarget` with `import Testing`) in `Package.swift`. Keep `mirrormesh-selftest` for now as a CI/CT-friendly smoke executable, but it is no longer the primary correctness gate — `swift test` is.

**Alternatives considered**:
- Continue with `mirrormesh-selftest` only: rejected — gives up the macro-based test ergonomics and Xcode test integration the user explicitly asked for.
- Vendor `swift-testing` as an SPM dep: rejected — duplicates what Xcode now provides; would add a network fetch step.

**Consequences**: CI builds must use the Xcode toolchain explicitly. The minimum environment for development is documented in `techContext.md` and `build-deployment.md`. CLT-only contributors can still run `mirrormesh-selftest` to validate basic correctness but cannot run the full test suite.

---

## 2026-05-20 — ADR-0015: License Simplification — AGPL-3.0-only, research-only posture

**Status**: Approved (2026-05-20). Supersedes the dual-license portion of ADR-0014.
**Context**: The maintainer clarified intent: this is a research project with no monetization plans, and the goal is to *prevent* anyone else from monetizing derivatives. The Commercial half of ADR-0014's dual license existed so the maintainer could grant per-deployment commercial exceptions to AGPL — but that affordance is unwanted. The Commercial half adds friction (LICENSE-COMMERCIAL.md, dual-license verbiage across README/paper/release notes, "contact for licensing" surface area) without serving any goal the maintainer actually has.
**Decision**:

1. **AGPL-3.0-only** as the single project license. Drop `LICENSE-COMMERCIAL.md`. The "A" already closes the SaaS loophole; AGPL alone serves the "I don't sell this AND nobody else can either" intent exactly. This is the original GNU design intent for AGPL.
2. **Top-level `NOTICE.md`** stating the research-only posture in plain English so a casual reader doesn't have to parse the AGPL text to understand the project's stance.
3. **Research-only model dependencies become accessible**. LivePortrait (blocked under ADR-0014 because InsightFace runtime weights are research-use-only) is now usable — the maintainer's research use satisfies that restriction. Swap LivePortrait in as the photoreal `.consentedThirdParty` backend; FOMM scaffolding is retained as a license-clean fallback.
4. **DCO sign-off remains** on every commit. AGPL doesn't need a CLA, and DCO is the lightest sufficient attestation that contributions are owned by the contributor.

Copyright holder remains **Michael Sitarzewski**. Project framing in README + paper + RELEASE_NOTES updates to "AGPL-3.0-only research project."

**Alternatives considered**:
- **Keep ADR-0014 dual license**: status quo. Carries Commercial offering signaling the maintainer never intends to honor. Confusing for anyone reading the project's intent.
- **GPL-3.0 (no A)**: blocks closed-source distribution but lets competitors host derivatives as SaaS without sharing back. AGPL closes that loophole; preferred.
- **Public domain / CC0**: gives away the right to prevent monetization. Opposite of the stated goal.

**Consequences**:
- LICENSE-COMMERCIAL.md deleted; LICENSE.md remains (AGPL-3.0 text).
- README, RELEASE_NOTES_v1.0.0.md, paper/draft_v1.md license sections updated to "AGPL-3.0-only research project; no commercial use of this code or derivatives."
- LivePortrait swap unblocked (separate ADR if it lands as the primary photoreal path; FOMM remains scaffolded as license-clean alternative).
- `models/external/` may carry research-only model definitions now — provenance + license sidecars must clearly flag the research-only nature of any weights the user is expected to download.
- Pre-existing commits in v0.4.0–v1.0.0 history that landed under "AGPL + Commercial" remain validly licensed under AGPL alone — dual-licensing is permissive at the maintainer's discretion, and unilateral simplification to one of the disjuncts is allowed.

---

## 2026-05-19 — ADR-0014: License Pivot — AGPL-3.0 + Commercial (dual)

**Status**: Superseded by ADR-0015 on 2026-05-20. Original notes retained for history.
**Context**: Apache-2.0 (chosen in v0.2.0) gave any third party the same commercial rights as the maintainer. With the project moving toward a distributable app and an eventual commercial offering, the maintainer needs to be the sole commercial-licensing party. Apache-2.0 cannot reach that outcome regardless of CLA — once shipped under Apache, the existing code is permanently free for commercial use.
**Decision**: Dual-license the project:

1. **AGPL-3.0** as the default open-source license. Real OSI-approved open source — researchers, academics, hobbyists, internal tools, and AGPL-derivative redistributors can use the project freely. The "A" closes the SaaS loophole that plain GPL has.
2. **Separate commercial license**, granted by the maintainer on a per-use-case basis, for parties who cannot satisfy AGPL-3.0's source-availability or network-deployment terms.
3. **DCO (Developer Certificate of Origin) sign-off** on every contributor commit. Lighter than a full CLA but sufficient to keep the commercial-license pipeline clean.

Copyright holder: **Michael Sitarzewski** for now; transferable to a future legal entity with a search-and-replace in source headers + a maintainer-of-record update.

**Alternatives considered**:
- **BSL (Business Source License)**: source-available with a time-bomb to Apache. Easier to read but not OSI-open-source — turns off academic venues; doesn't match the paper-publishing framing.
- **Apache + CLA**: keeps the OSI badge but allows competitors to ship closed-source forks; maintainer would compete with their own code.
- **GPL-3.0 (no A)**: blocks closed-source distribution but doesn't close the SaaS loophole — competitors can host MirrorMesh derivatives without sharing back.
- **SSPL**: rejected by OSI; too aggressive for academic audiences.

**Consequences**:
- Architectural constraints (watermarking on by default, no third-party impersonation, consent gating) survive the license switch — they were never license-enforced, always architecture-enforced.
- Apache-2.0 commits in v0.1.0–v0.3.0 history remain Apache; no retroactive change of license terms is possible. New commits land under AGPL + commercial.
- Source-header sweep (`SPDX-License-Identifier: AGPL-3.0-or-later` per file) is a v0.4.0 chore.
- `LICENSE`, `COMMERCIAL.md`, `CONTRIBUTING.md`, `README.md`, `CHANGELOG.md` updated.
- DCO check in CI added (v0.4.0).

---

## 2026-05-19 — ADR-0013: Executable Entry-Point Files Renamed Away From `main.swift`

**Status**: Approved (fixed during v0.3.0 kickoff after Xcode parser flagged the conflict)
**Context**: When a Swift file is literally named `main.swift`, the file's top-level statements are the implicit entry point. Adding `@main` to a struct in that same module conflicts ("'main' attribute cannot be used in a module that contains top-level code"). CLI `swiftc` was lenient and the package built fine via `swift build`; Xcode's parser was strict and surfaced the error in the Issue Navigator, blocking IDE use.
**Decision**: All executable targets that use `@main` use a non-`main.swift` filename. Renamed:
- `Sources/mirrormesh-bench/main.swift` → `BenchCLI.swift`
- `Sources/mirrormesh-verify/main.swift` → `VerifyCLI.swift`
- `Sources/mirrormesh-fixture-gen/main.swift` → `FixtureGen.swift`
**Already conformant**: `mirrormesh-selftest/SelfTest.swift`, `mirrormesh-app/MirrorMeshAppMain.swift`.
**Consequences**: Zero behavior change; `swift build`, `swift test`, `swift run` all still green. Xcode now opens the package cleanly.
**Rule going forward**: Executable targets MUST NOT name their entry file `main.swift`. Project lint will enforce in v0.3.0.

---

## Future ADRs (placeholders)

- ADR-0006: Landmark backend default (Apple Vision vs MediaPipe)
- ADR-0007: Virtual camera mechanism (`CMIOExtension`)
- ADR-0008: Streaming transport (libwebrtc bindings vs alternatives)
- ADR-0009: Voice transform inclusion and disclosure model
- ADR-0010: Distribution (Homebrew tap, signed DMG, source-only)
