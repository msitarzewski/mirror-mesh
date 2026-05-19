# MirrorMesh — Quick Start

For agents and contributors picking up a session.

---

## First 60 Seconds

1. Read `mision.md` — the canonical mission (filename misspelled, will be renamed pending decision).
2. Read `activeContext.md` — current state and pending decisions.
3. Read `progress.md` — what's done and what's blocked.
4. If unsure: read `projectbrief.md` and `projectRules.md`.

## Where Things Live

| Looking for... | Read this |
|---|---|
| Why this project exists | `projectbrief.md`, `productContext.md` |
| Architecture / patterns | `systemPatterns.md` |
| Tech stack / dependencies | `techContext.md` |
| Current sprint | `activeContext.md` |
| What's done | `progress.md` |
| Rules I must not violate | `projectRules.md` |
| Why we chose X over Y | `decisions.md` |
| Build / run / bench commands | `build-deployment.md` |
| How we test | `testing-patterns.md` |
| Monthly summaries | `tasks/YYYY-MM/README.md` |
| Specific task history | `tasks/YYYY-MM/YYMMDD_*.md` |

## Hard Rules (Memorize)

1. No identity spoofing of real third parties without consent
2. Watermark / disclosure on by default — do not disable in release paths
3. No cloud inference on the hot path
4. No new files without reuse analysis
5. No commits without user approval
6. No documentation writes (decisions, tasks) without approval — exception is initial framework scaffold

## Common Commands

(Placeholder — populated when first source tree lands.)

```
# Once Package.swift exists:
swift build
swift test
swift run mirrormesh-bench --scenario capture_landmark

# Once Xcode project exists:
xcodebuild -scheme MirrorMesh -destination 'platform=macOS' build
```

## On Session Start

Output the AGENTS.md §1 compliance block, then load Memory Bank per the mode that fits the task (Fast Track / Standard / Deep Dive).

## On Session End

If state has advanced, ensure `activeContext.md` reflects current state and substate. State persistence is continuous, not deferred.
