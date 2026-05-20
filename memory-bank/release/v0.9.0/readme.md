# Release v0.9.0 — "Paper"

**Goal**: Research paper draft v1 targeting ACM ASSETS (primary) or CHI (secondary). The narrative deliverable that makes the consent-first identity protocol citable.

**Theme**: The software exists; now we explain *why* in a form other researchers can build on. The paper is the lever for the trust layer's adoption beyond MirrorMesh.

## Milestones

| # | Title | Status |
|---|-------|--------|
| **M73** | `paper/draft_v1.md` — full draft, ASSETS-ready structure | 🟡 in flight |
| **M74** | `docs/CONSENT_PROTOCOL.md` — standalone spec extracted from paper | 🟡 in flight |
| **M75** | Bench measurements for paper (latency / power / accessibility-pilot dry-run) | ⚪ |
| **M76** | Figures (architecture diagram, identity bundle layout, latency CDFs) | ⚪ |
| **M77** | Reference bibliography | 🟡 in flight |
| **M78** | LaTeX conversion for camera-ready | ⚪ post-1.0 |

## Exit criteria

1. Draft is end-to-end readable; sections complete, references cited
2. Every implementation claim in the paper traces to `file.swift:line` in the actual codebase
3. Measurements pending camera-ready are explicitly marked; no invented numbers
4. Protocol spec stands alone — an implementer who reads only `CONSENT_PROTOCOL.md` could re-implement the verifier
