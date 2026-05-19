# MirrorMesh — Product Context

**Last reviewed**: 2026-05-19

---

## Who This Is For

### Primary audiences

1. **Researchers** — realtime graphics, HCI, accessibility, ML systems on consumer hardware
2. **Accessibility practitioners** — clinicians, AAC specialists, ALS / facial paralysis support, deaf/HoH communication tools
3. **Open-source telepresence developers** — WebRTC stack contributors, OBS plugin authors, virtual camera ecosystem
4. **Apple platform engineers** — CoreML / Metal / AVFoundation practitioners interested in unified-memory ML pipelines

### Explicitly not the audience

- Pranksters, catfishers, scammers
- Operators seeking to defeat KYC / ID-verification
- Anyone seeking covert (undisclosed) synthetic media generation

The product is shaped to be uninteresting to those users by design: watermarking on by default, consent prompts mandatory, no identity-spoofing presets, transparent session manifests.

## Why This Project Exists Now

Three converging conditions in 2026:

1. **Hardware**: M3/M4/M5 unified memory + Neural Engine + Metal performance now sufficient for sub-100ms local inference at HD
2. **Capture quality**: Apple integrated webcams (post-Continuity Camera era) deliver stable landmarks without markers
3. **Trust crisis**: Synthetic media is ubiquitous; transparency infrastructure is underdeveloped — there is a research-shaped hole for "trust-preserving" synthetic presence

The combination means a **commodity, local, transparent** stack is now achievable — and someone publishing the benchmarks first defines the field.

## User Goals

| User | Goal | MirrorMesh Provides |
|------|------|---------------------|
| Researcher | Reproducible realtime ML benchmarks on Apple Silicon | Open benchmark suite, raw traces, methodology docs |
| Accessibility user | Compensate for facial paralysis on video calls | Expression amplification, gaze correction |
| Multilingual presenter | Visually-coherent lip-sync across translation | Realtime visual lip synchronization |
| Telepresence developer | Local-only avatar pipeline | Reference SwiftUI + Metal + CoreML stack |
| Policy / safety researcher | Study transparent synthetic media | Default-on watermarking, signed manifests |

## Market / Landscape (2026)

- **Cloud avatar services** (Synthesia, HeyGen, D-ID): high quality, cloud-only, opaque, expensive, latency-incompatible with realtime calls
- **Realtime open tools** (OBS plugins, OpenSeeFace, VTube Studio): hobbyist-focused, Windows-centric, no transparency layer, fragmented hardware support
- **Closed Apple-platform tools** (Memoji, Personas): proprietary, no research access, limited customization
- **LivePortrait / first-order motion academic releases**: research-grade, no productized realtime path, no Apple Silicon optimization

**MirrorMesh's niche**: the only stack that is simultaneously *local*, *realtime*, *Apple-optimized*, *open-source*, and *transparency-first*.

## Strategic Positioning

The narrative is **not** "another deepfake tool." It is:

> "Commodity Apple hardware is now sufficient for trust-preserving realtime telepresence. Here is the benchmark to prove it, and the reference implementation to build on."

This is publishable, defensible against criticism, and difficult to weaponize.

## Risks to Positioning

- **Mission drift**: feature requests for celebrity presets / spoofing should be refused at intake — see `projectRules.md`
- **Watermark removal forks**: license must permit forking; mitigation is technical (cryptographic frame signing is harder to remove than visible badges)
- **Apple platform changes**: AVFoundation / CoreML API shifts could break the stack — pin minimum macOS version, version-lock CoreML model formats
- **Cloud regression**: if vendors drop cloud pricing dramatically, local-only positioning weakens — counter by emphasizing privacy, latency, offline use
