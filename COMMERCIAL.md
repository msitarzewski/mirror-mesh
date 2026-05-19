# MirrorMesh — Commercial Licensing

## TL;DR

- The default license for MirrorMesh is **GNU Affero General Public License v3.0 (AGPL-3.0)** — see [`LICENSE`](./LICENSE).
- If AGPL-3.0's terms don't work for your use case, a **separate commercial license** is available.

## When you need a commercial license

You need a commercial license if **any** of the following apply:

1. You want to ship MirrorMesh (or a derivative) as part of a **closed-source product** — desktop, mobile, embedded — without releasing your modifications under AGPL.
2. You want to offer MirrorMesh (or a derivative) as a **network/SaaS service** without making your service's source code available under AGPL (AGPL-3.0 §13 closes the SaaS loophole).
3. You want to **integrate MirrorMesh into a proprietary platform** (camera hardware, video-conferencing product, content moderation pipeline) where forcing the rest of the platform under AGPL is unacceptable.
4. You want **indemnification, warranty terms, support SLAs, or priority bug-fix commitments** that AGPL-3.0 does not provide.
5. Your organization's legal policy prohibits AGPL-licensed code in production.

If none of those apply — you're a researcher, hobbyist, academic, or you're shipping your derivative under AGPL too — the AGPL-3.0 license is free and sufficient.

## What the commercial license covers

A commercial license grants:

- Permission to use, modify, and distribute MirrorMesh and derivatives **without** AGPL-3.0's source-availability or network-deployment requirements
- Permission to incorporate MirrorMesh into closed-source products
- The cryptographic-disclosure invariants documented in [`memory-bank/projectRules.md`](./memory-bank/projectRules.md) (watermarking on by default, no third-party impersonation, consent-gated identity transforms) remain contractual requirements of every commercial license — they are not removable
- A warranty disclaimer and limitation of liability appropriate to the licensee's deployment
- A perpetual, non-exclusive grant for the version licensed; updates and upgrades per the agreement's terms
- Optional: indemnification, priority support, custom feature work — negotiated per agreement

## What the commercial license does NOT cover

- It does **not** transfer copyright. MirrorMesh remains owned by the maintainer.
- It does **not** remove the project's architectural constraints. The watermarking/consent/no-impersonation invariants are load-bearing for the project's defensibility and stay in every commercial deployment.
- It does **not** grant exclusivity to any licensee. The maintainer reserves the right to license to anyone.

## Pricing

Pricing is per-product, per-seat, or per-deployment depending on use case. Reach out for a quote (see "Contact" below). Typical structure for early adopters:

- **Startup tier** (< $5M ARR): annual fee, no royalty
- **Enterprise tier**: annual fee + optional support tier
- **OEM tier** (integrate into shipped hardware/software product): one-time or per-unit fee
- **Academic / non-profit**: AGPL is usually sufficient; commercial license available at a reduced rate for research consortia that need it

## Contact

For commercial licensing inquiries, contact the maintainer. Update this section once a sales channel exists.

```
Maintainer:  Michael Sitarzewski
Contact:     msitarzewski@gmail.com   (update to a commercial address when set up)
```

## How this dual-license model works in practice

1. **You clone the repo.** Free under AGPL-3.0.
2. **You build a research prototype, an internal tool, or a project you're happy to open-source.** AGPL is sufficient; you owe nothing.
3. **You decide to ship a closed-source product based on MirrorMesh.** Email for a commercial license before shipping.
4. **You're unsure which applies.** Email and ask — preferring AGPL until the use case is concrete is the right default.

## Why dual-license?

We want MirrorMesh to be a useful piece of research infrastructure (which AGPL handles) **and** a sustainable project that can be funded by commercial users who derive direct value from it (which the commercial license handles). The model is the same one used by Sentry, Sidekiq, MongoDB (pre-SSPL), GitLab, and others.

## Related documents

- [`LICENSE`](./LICENSE) — full AGPL-3.0 text
- [`CONTRIBUTING.md`](./CONTRIBUTING.md) — how to contribute, including the DCO that's required for commercial relicensing
- [`memory-bank/decisions.md`](./memory-bank/decisions.md) — ADR-0005 (license decision) and ADR-0014 (dual-license model)
- [`memory-bank/projectRules.md`](./memory-bank/projectRules.md) — the architectural constraints that survive every license

---

*Copyright © 2026 Michael Sitarzewski. AGPL-3.0 + Commercial — see this document.*
