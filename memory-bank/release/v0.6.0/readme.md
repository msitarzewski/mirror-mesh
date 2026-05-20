# Release v0.6.0 — "Identity"

**Goal**: Real face-reenactment on Apple Silicon. The operator drives, a consented source identity puppets. Same "catfishing-on-steroids" mechanic class shown in Arlo Gilbert's LinkedIn warning, but with MirrorMesh's trust layer intact — every loaded identity carries a signed `ConsentedIdentity` bundle, every output frame carries Ed25519 + visible badge, every session emits an audible chirp.

**Theme**: Cross from "synthetic mesh overlay" to "wear a different face." The architectural gate (ConsentedIdentity) is the difference between "research telepresence platform" and "catfishing kit."

---

## The driving inspiration

User pointed at a real-time face+voice swap demo (LinkedIn post by Arlo Gilbert, "Catfishing on steroids"). Cover frame shows:
- Hero view: synthetic blonde-woman puppet, influencer aesthetic
- PIP bottom-right: male operator in a head-mounted rig with mocap dots

The mocap dots are noise — Apple Vision's markerless landmarks do the same job. The real work is the face-reenactment model that takes (source frame + driving frames) → reenacted output.

## The license/constraint gate

`projectRules.md` R1 and R12 explicitly forbid impersonation-for-deception. v0.6.0 makes the *mechanics* possible while making the *deception* architecturally hard:

| Mechanic | Standard catfishing kit | MirrorMesh v0.6.0 |
|----------|-------------------------|-------------------|
| Load any face from a URL/file | ✅ | ❌ — requires signed `ConsentedIdentity` bundle |
| Watermark off in release | ✅ | ❌ — release-locked on, every frame |
| Manifest of session activity | none | Ed25519-signed JSON, records identity-bundle hash |
| Audible "I'm synthetic" signal | none | Periodic chirp, schedule in manifest |
| Driver / operator visible | hidden | Camera-as-PIP shows the operator |

Same impressive demo to an outsider. Architecturally distinct.

---

## Milestones

| # | Title | Status |
|---|-------|--------|
| **M43** | Camera-as-PIP in Mirror/Mask styles | ✅ |
| **M52** | App icon refresh — mesh motif | ✅ |
| **M53** | Mask polish — hide AvatarMask in non-Wireframe styles + better shading | ✅ |
| **M55** | `ConsentedIdentity` protocol + `.mmid` bundle format | ✅ |
| **M56** | Stylized 3D head reenactor (license-clean, ethics-aligned path) + FOMM photoreal scaffolding (manual weight-download step documented) | ✅ |
| **M57** | `mirrormesh-consent` CLI | ✅ |
| **M58** | Identity-load UX in app | ✅ |
| **M59** | Audible disclosure chirp | ✅ |

## Exit criteria

1. User can run `mirrormesh-consent sign --source me.png -o me.mmid` and produce a `.mmid` bundle
2. App's Settings panel has an "Identity" picker that lists loaded `.mmid` bundles; loading any bundle requires verifying the signature
3. With FOMM weights bundled + an identity loaded, Mask style replaces the user's face with the source identity's face in real time, latency < 100ms E2E
4. Recorded `.mov` shows the reenacted output; manifest carries `identity_sha256` for the loaded bundle
5. Audible chirp is present in voice-swap sessions (v0.7.0 inherits)
6. Loading an unsigned or tampered bundle is rejected with a clear UI error
7. The visible badge + Ed25519 frame signatures are unchanged from v0.5.0

## Notes

- **FOMM license**: Apache-2.0 (we're clear)
- **LivePortrait**: was research-only and incompatible with the v0.4.0 AGPL+Commercial dual. After ADR-0015 (AGPL-3.0-only research-project posture) it became the recommended photoreal backend; FOMM remains as a license-clean fallback.
- **Source frame quality**: FOMM's quality scales with source-frame resolution and lighting. Bundles produced by `mirrormesh-consent` should include a quality-check pass.
- **Latency budget**: FOMM published numbers ~25 ms on M-series. Our full pipeline must stay < 100 ms including capture, vision, FOMM, render, watermark.
