# MirrorMesh — Notice

**Author**: Michael Sitarzewski
**License**: AGPL-3.0-only (full text in [`LICENSE`](LICENSE))
**Status**: Research project. No commercial use.

---

## Plain English

This is a research project. It exists to demonstrate that consent-first identity transformation can be built on commodity Apple Silicon, and to publish a paper grounded in that demonstration. It is not a product. It is not for sale. There is no commercial license available.

The author does not monetize this code. The license is chosen so nobody else can monetize derivatives either. AGPL-3.0 was written by the GNU project precisely for this case: strong copyleft that survives forking, and a network-use clause that closes the SaaS loophole in plain GPL.

If you found this code and you're thinking about using it, here's how to think about whether you can:

**You can:**
- Read it, study it, learn from it
- Cite it in academic work
- Fork it for your own research, as long as your fork is also AGPL-3.0
- Run it on your own machine for your own non-commercial use
- Contribute back via pull requests with DCO sign-off

**You cannot:**
- Sell this code or anything derived from it
- Host a fork as a paid service, even with modifications
- Build a commercial product on this codebase
- Re-license it under anything other than AGPL-3.0
- Use the work as a basis for a proprietary identity-transformation product

There is no "contact for commercial licensing" link because there is no commercial license. The author will not grant one. If your use case requires commercial licensing, this project is not for you.

## How to cite

The companion paper is a draft targeting ACM ASSETS or CHI. While the paper is in draft, cite as:

> Sitarzewski, M. (2026). MirrorMesh: A Consent-First Identity Protocol for Real-Time Telepresence on Apple Silicon. Research draft, version v1.0.0.

The repository URL goes here once the project has a public home. For now, this file lives in the source tree.

## Contributing

Pull requests welcome. By contributing, you certify the Developer Certificate of Origin (DCO) — every commit must include a `Signed-off-by:` line. This is a lighter alternative to a Contributor License Agreement; it suffices for AGPL because the license itself constrains downstream re-use. See `CONTRIBUTING.md` for the workflow.

## Ethical posture (unchanged)

The license change in [ADR-0015](memory-bank/decisions.md) is purely about commercial monetization. The project's architectural rules — mandatory watermarking, audible disclosure chirp, consent-bundle gating, no third-party impersonation without signed consent, refuse-on-sight features — remain in force. Those rules are enforced by the code itself, not by the license. The license stops anyone from selling the work; the code stops anyone from misusing the work.

If you came here looking for a deepfake toolkit, this isn't one. It's the opposite — the same mechanics, with the trust layer welded in by construction.
