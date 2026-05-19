# M8 — Session Manifest & Consent Record

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M7
**Blocks**: M10

## Objective

A tamper-evident JSON document describing every session — what ran, on what hardware, with what models, under what consent, and signed.

## Deliverables

In `Sources/MirrorMeshWatermark/` (co-located with signer):

- `SessionManifest.swift`
- `ConsentRecord.swift`
- `DeviceInfo.swift`
- `PipelineConfig.swift`

## Schema (sketch)

```jsonc
{
  "manifest_version": "1.0",
  "session_id": "01H...",
  "started_at": "2026-05-19T18:30:00Z",
  "ended_at":   "2026-05-19T18:34:15Z",
  "device": {
    "model": "Mac15,3",
    "chip": "Apple M3 Pro",
    "memory_gb": 36,
    "os_version": "macOS 14.5"
  },
  "pipeline": {
    "capture":   { "format": "1280x720@60", "device_id": "FaceTime HD" },
    "landmarks": { "backend": "vision",     "smoothing": "one-euro" },
    "solver":    { "type": "geometric",     "calibration_frames": 30 },
    "render":    { "overlay": ["landmarks","avatar_mask"] },
    "watermark": { "visible": true, "signed": true, "audible_chirp": false }
  },
  "models": [],
  "consent": {
    "scheme": "self-as-source",
    "accepted_at": "2026-05-19T18:30:01Z",
    "user_disclosure_text_sha256": "..."
  },
  "frame_count": 7392,
  "public_key_b64": "...",
  "manifest_signature_b64": "..."
}
```

## Behavior

- Manifest written incrementally during session; finalized + signed on stop
- Consent text shown in UI is hashed and recorded — proves the user saw a specific disclosure version
- Model entries reference `models/*.provenance.json` files by hash
- Verifier CLI checks signatures and manifest schema

## Tests

- Schema validation via golden fixture
- Tamper test: mutate any field; verification fails
- Consent hash test: known text -> known hash
