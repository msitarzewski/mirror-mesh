# MirrorMesh ConsentedIdentity Protocol — v1.0

**Status**: Stable. v1.0 spec — backward-compatible additions allowed; format and signature semantics frozen.
**Reference implementation**: `Sources/MirrorMeshWatermark/ConsentedIdentity.swift`.
**Tooling**: `mirrormesh-consent` CLI (`Sources/mirrormesh-consent/ConsentCLI.swift`).

This document is the standalone protocol reference. It is extracted from the trust-layer section of [`paper/draft_v1.md`](../paper/draft_v1.md) (Section 4) for implementers who want the spec without the narrative.

---

## 1. Goal

A portable, cryptographically-verifiable bundle that authorizes loading a third-party identity (a "puppet") into a face-reenactment pipeline. The bundle binds:

- The source image (the puppet's neutral-pose photograph)
- A named subject (or a stylized non-human marker)
- A versioned disclosure text the subject has agreed to
- A scope declaring which runtime versions may use the bundle
- The issuer's Ed25519 public key
- An Ed25519 signature over the canonical form of all of the above

The verifier — `ConsentedIdentityVerifier` at `Sources/MirrorMeshWatermark/ConsentedIdentity.swift:148-210` — accepts a bundle if and only if every check below passes.

## 2. On-Disk Layout

A `.mmid` bundle is a directory containing two files:

```
your-name.mmid/
  identity.json     # the JSON header (this document's Section 3)
  source.png        # the source frame, PNG-encoded
```

A future version may roll the two into a single archive; v1.0 ships them as a directory for ease of inspection and human review.

## 3. JSON Header Schema

The header is a Codable struct in Swift (`ConsentedIdentity`, lines 22-87). The on-disk JSON is encoded with sorted keys and ISO-8601 dates.

```json
{
  "bundle_version": "1.0",
  "identity_id": "550e8400-e29b-41d4-a716-446655440000",
  "display_name": "Alex Doe",
  "scheme": "self-as-source",
  "disclosure_text_sha256": "8b1a9953c4611296a827abf8c47804d7e7c5d4a3a8d1e7f5d8c2b9e6d3c2a1f0",
  "source_png_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "scope": "v1.0+",
  "issuer_public_key_b64": "MCowBQYDK2VwAyEA...",
  "signature_b64": "RvqXKWQrTd1YnBbTpkjY...",
  "signed_at": "2026-05-19T18:42:00Z"
}
```

### 3.1 Field Reference

| Field | Type | Required | Semantics |
|-------|------|----------|-----------|
| `bundle_version` | string | yes | Schema version. v1.0 only accepts the literal string `"1.0"`. |
| `identity_id` | string | yes | Stable UUID. Distinct from the content hash so revocation lists can target an issuance even after source bytes change. |
| `display_name` | string | yes | Human-readable label for the operator's identity picker. **Not** a security claim. |
| `scheme` | enum | yes | One of `"self-as-source"`, `"stylized-non-human"`, `"consented-third-party"`. See Section 4. |
| `disclosure_text_sha256` | string (hex) | yes | SHA-256 of the canonical disclosure text the subject signed. Binds the agreement to the bundle. |
| `source_png_sha256` | string (hex) | yes | SHA-256 of the `source.png` payload bytes. Detects tampered payloads without re-decoding. |
| `scope` | string | yes | Runtime version compatibility token. Grammar in Section 5. |
| `issuer_public_key_b64` | string (base64) | yes | Raw 32-byte Ed25519 public key. The subject's key for `self-as-source` / `consented-third-party`; the project's key for `stylized-non-human`. |
| `signature_b64` | string (base64) | yes (for verification) | Ed25519 signature over `canonical_json(header with this field cleared) ‖ source_png_bytes`. Optional during construction (the field is cleared during canonical encoding); required at verification time. |
| `signed_at` | RFC 3339 timestamp | yes | When the subject signed. Informational; the verifier does not reject by age. |

## 4. Identity Schemes

The `scheme` field is a closed enum (`IdentityScheme` at `Sources/MirrorMeshWatermark/ConsentedIdentity.swift:89-93`). The three values map to three explicit use cases, each with a distinct failure mode that distinguishes it from the others.

### 4.1 `self-as-source`

The subject of the bundle is the operator. Use cases: self-puppeting for gaze correction, expression amplification, or live persona consistency.

- Issuer public key: the operator's key.
- Threat addressed: still requires a signature so downstream consumers can distinguish this from third-party identity transfer.

### 4.2 `stylized-non-human`

The bundle's source image depicts a stylized, non-human subject (cartoon, animal, abstract puppet). No real person is depicted.

- Issuer public key: the project's curated-asset signing key (in v1.0; future revisions may admit third-party-stylized issuers).
- Threat addressed: prevents a cartoon-named bundle from secretly carrying a real face. The verifier accepts only project-signed bundles for this scheme.

### 4.3 `consented-third-party`

The subject is a named real person, not the operator, who has signed the bundle.

- Issuer public key: the subject's key, distinct from the operator's.
- Threat addressed: non-consensual impersonation of a real person.
- Special CLI constraint: `mirrormesh-consent` refuses to issue a bundle of this scheme without the explicit literal phrase `--consent-confirm "I HAVE WRITTEN CONSENT FROM THE SUBJECT"` (see `Sources/mirrormesh-consent/ConsentCLI.swift:55-70`). This is a friction point by design.

The `PhotorealBackend` (the FOMM-class identity-transfer path) accepts only `self-as-source` and `consented-third-party` (`Sources/MirrorMeshReenact/PhotorealBackend.swift:118-120`); `stylized-non-human` bundles run on the procedural stylized head, not on FOMM.

## 5. Scope Grammar

The `scope` field declares runtime version compatibility. v1.0 grammar (BNF):

```
scope     ::= "v" major "." minor "+"
major     ::= digit+
minor     ::= digit+
digit     ::= "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
```

Examples: `"v1.0+"`, `"v0.6+"`, `"v2.3+"`.

**Semantics**: A bundle with `scope: "vMAJOR.MINOR+"` is valid on any runtime version whose `(major, minor)` components compare lexicographically ≥ `(MAJOR, MINOR)`. Comparison is component-wise integer (`Sources/MirrorMeshWatermark/ConsentedIdentity.swift:201-209`).

**Future-compatibility**: An unrecognized scope string causes the verifier to throw `ConsentedIdentityError.unsupportedScope(scope)`. This is the conservative behavior — runtimes refuse to load bundles whose scope semantics they do not understand.

**Future revision**: v2.0 will replace this with proper semver-range semantics (e.g. `"^1.0"`, `">=1.0, <2.0"`). The v1.0 grammar is intentionally simple to keep the reference implementation small.

## 6. Disclosure Text

The subject agrees to a versioned, hashed disclosure text. v1.0 text (`IdentityConsentText.v1` at `Sources/MirrorMeshWatermark/ConsentedIdentity.swift:100-117`):

```
By signing this MirrorMesh ConsentedIdentity bundle (v1.0), I consent to:

1. The included source image being used to drive realtime face-reenactment of
   my likeness through the MirrorMesh pipeline.
2. Every output frame produced from this identity carrying:
   - A visible "MIRRORMESH • SYNTHETIC" badge
   - An Ed25519 cryptographic frame signature
   - A reference (by hash) to this bundle in the session manifest
3. The bundle being loadable on any device that has access to it.
   (Distribution is the responsibility of the bundle holder. Revocation is
   best-effort via the issuer.)
4. The scope declared in the bundle. Use outside that scope is unauthorized.

I confirm that I am either:
(a) the subject of the source image, OR
(b) authorized by the subject to issue this bundle, OR
(c) issuing a stylized non-human source (no real person depicted).
```

The verifier checks `disclosure_text_sha256 == SHA-256(IdentityConsentText.v1.utf8)` at runtime. A bundle signed against a different disclosure text fails verification.

## 7. Signature Construction

The signature is Ed25519 (Curve25519, via Apple's CryptoKit).

**Signed bytes**:

```
canonical_json(header_with_signature_cleared) ‖ source_png_bytes
```

where:

- `header_with_signature_cleared` is the JSON header struct with `signature_b64` set to `null`
- `canonical_json` is JSON-encoded with sorted keys (`.sortedKeys`) and ISO-8601 date encoding (`.iso8601`)
- `‖` is byte concatenation

Reference: `ConsentedIdentityVerifier.verify` at `Sources/MirrorMeshWatermark/ConsentedIdentity.swift:178-191`.

**Signing**: build the canonical header, append the PNG bytes, sign the resulting buffer with the issuer's Ed25519 private key.

**Verifying**: reconstruct the canonical header from the on-disk JSON (clearing `signature_b64`), append the on-disk PNG bytes, verify the signature against `issuer_public_key_b64`.

## 8. Verification Algorithm

The verifier (`ConsentedIdentityVerifier.verify`) performs seven checks **in order** and throws on the first failure. The order matters: cheap checks first, signature verification last.

```
1. bundle_version == "1.0"                                       → unsupportedBundleVersion
2. signature_b64 is present and base64-decodes                   → malformedBundle("missing signature")
3. issuer_public_key_b64 is base64-decodable as a Curve25519 key → invalidPublicKey
4. SHA-256(pngBytes) == source_png_sha256                        → payloadHashMismatch
5. disclosure_text_sha256 == IdentityConsentText.sha256          → disclosureHashMismatch
6. scope satisfied by runtimeVersion                             → unsupportedScope(scope)
7. publicKey.isValidSignature(sig, for: canonical_json ‖ png)    → invalidSignature
```

Reference: lines 151-192 in `ConsentedIdentity.swift`. Each step is a separate guard clause; the typed errors are exhaustive (`ConsentedIdentityError` at lines 125-145).

## 9. Runtime Version Handshake

A runtime declares itself by passing its version string to `ConsentedIdentityVerifier.verify(..., runtimeVersion: "X.Y.Z")`. The reference reenactor passes `FaceReenactor.runtimeVersion` (currently `"0.6.0"`, will be `"1.0.0"` at v1.0 ship; see `Sources/MirrorMeshReenact/FaceReenactor.swift:36`). The verifier extracts the bundle's scope's minimum (major, minor) and compares against the first two components of the runtime version.

**Forward compatibility**: a bundle with `scope: "v1.0+"` loads on v1.x, v2.x, v3.x runtimes (assuming the runtime still understands v1.0 bundles, which is the bundle_version check at step 1).

**Backward compatibility**: a v0.6 runtime cannot load a `v1.0+`-scoped bundle. This is the intended behavior — the subject's agreement applies to runtime versions ≥ the declared minimum, not below.

## 10. Pipeline Integration

The verified bundle is consumed by two backends:

- **`FaceReenactor`** (`Sources/MirrorMeshReenact/FaceReenactor.swift`) — the stylized 3D head puppet. Accepts all three schemes. Initializer at line 56-72 verifies the bundle, then constructs a stateless solver and the procedural head model.
- **`PhotorealBackend`** (`Sources/MirrorMeshReenact/PhotorealBackend.swift`) — the FOMM photoreal path. Accepts `self-as-source` and `consented-third-party` only (lines 118-120). Initializer at line 98-159 performs three gates: consent verification, scheme check, models-present check.

In both cases the verifier runs **synchronously at load time**. The per-frame hot path does *not* re-verify; the gate is at construction. Identity rotation is performed by tearing down the actor and constructing a new one (`FaceReenactor.setIdentity` at line 77-88 supports in-place hot-swap with re-verification).

## 11. Session Manifest Integration

When a bundle is loaded, the runtime emits an annotation to the telemetry bus:

```swift
TelemetryBus.emit(.annotation(
    key: "reenact.photoreal.loaded",
    value: identity.identity_id
))
```

(see `PhotorealBackend.swift:155-158`). The annotation is recorded in the session manifest. As of v1.0, the manifest's `models` array also records the loaded bundle's content hash; the explicit top-level `identity_sha256` field is a v1.0.1 schema addition (additive, backward-compatible).

## 12. Error Codes

The verifier throws one of (`ConsentedIdentityError` at lines 125-145):

| Error | Meaning |
|-------|---------|
| `invalidPublicKey` | The `issuer_public_key_b64` is not a valid Curve25519 public key. |
| `invalidSignature` | Signature verification failed. The canonical signed bytes do not match the bundle contents. |
| `payloadHashMismatch` | The `source.png` file's SHA-256 does not match `source_png_sha256`. |
| `disclosureHashMismatch` | The bundle's `disclosure_text_sha256` does not match the runtime's expected disclosure text. |
| `unsupportedScope(string)` | The bundle's `scope` is not satisfied by the live runtime version, or is unparseable. |
| `unsupportedBundleVersion(string)` | The bundle's `bundle_version` is not `"1.0"`. |
| `malformedBundle(string)` | Generic structural failure (missing signature, encoding error, etc.). |

The `PhotorealBackend` additionally surfaces (lines 34-63):

| Error | Meaning |
|-------|---------|
| `LoadError.identityNotVerified` | The bundle verifier rejected the bundle, **or** the scheme is not photoreal-eligible. |
| `LoadError.modelsMissing(URL)` | One or more of `keypoint_v1.mlpackage`, `motion_v1.mlpackage`, `generator_v1.mlpackage` is not present under the supplied models directory. |

## 13. Creating a Bundle (CLI Reference)

```bash
swift run mirrormesh-consent --print-disclosure
# … review the disclosure text …

swift run mirrormesh-consent \
  --name "Your Name" \
  --scheme self-as-source \           # or stylized-non-human | consented-third-party
  --scope "v1.0+" \
  --png path/to/portrait.png \
  --out ~/Documents/yourname.mmid
```

For a `consented-third-party` bundle, add:

```bash
  --consent-confirm "I HAVE WRITTEN CONSENT FROM THE SUBJECT"
```

The CLI generates a fresh Ed25519 keypair for the issuer (in v1.0; future revisions will admit caller-supplied keys), computes all required hashes, signs the canonical buffer, and writes the `.mmid` directory.

## 14. Threat Model

The protocol assumes a downstream consumer who can:

- Read the `.mmid` bundle as a file
- Compute SHA-256 over the PNG payload
- Verify Ed25519 signatures
- Compare the bundle's disclosure hash to a published reference

The protocol does *not* address:

- Compromise of the issuer's private key (use revocation by `identity_id` at the project level; runtime check is best-effort)
- Bundles distributed alongside the runtime that strip the verifier (the runtime itself is open source — anyone can confirm verification is enforced)
- Pixel-domain re-recording of generated output (this is the visible-badge + manifest's job; the bundle is not the only line of defense)

## 15. Backward Compatibility

The schema is additive. Future v1.x revisions may add fields (e.g. `identity_sha256` in the session manifest, an explicit revocation URL on the bundle) without breaking v1.0 verifiers. Renaming or removing fields is a v2.x change and requires a new bundle_version.

## 16. References

- Source: `Sources/MirrorMeshWatermark/ConsentedIdentity.swift`
- CLI: `Sources/mirrormesh-consent/ConsentCLI.swift`
- Photoreal load gate: `Sources/MirrorMeshReenact/PhotorealBackend.swift:98-159`
- Stylized load gate: `Sources/MirrorMeshReenact/FaceReenactor.swift:56-72`
- Tests: `Tests/MirrorMeshWatermarkTests/`
- Paper context: [`paper/draft_v1.md`](../paper/draft_v1.md) Section 4

---

*Spec v1.0 — stable. Edits to this document accompany a minor-or-major version bump and a corresponding ADR in `memory-bank/decisions.md`.*
