# Contributing to MirrorMesh

Thanks for your interest. A few things to know before you open a PR.

## License

MirrorMesh is **[AGPL-3.0-only](./LICENSE)** — a research project. See [`NOTICE.md`](./NOTICE.md) for the plain-English statement of intent. The previous v0.4.0 "AGPL + Commercial" dual ([ADR-0014](./memory-bank/decisions.md)) is superseded by [ADR-0015](./memory-bank/decisions.md); the Commercial half is dropped because no commercial offering is intended.

When you contribute, your changes are licensed under AGPL-3.0 alongside the rest of the project. You retain copyright in your work.

## Developer Certificate of Origin (DCO)

We don't ask you to sign a Contributor License Agreement. We do ask you to sign every commit with the **Developer Certificate of Origin** (DCO) — the same lightweight mechanism the Linux kernel uses.

What signing means: you're certifying the four points in the DCO 1.1 text below. You retain copyright in your contribution; you grant a license consistent with AGPL-3.0.

### How to sign

Add `-s` (or `--signoff`) to every commit:

```bash
git commit -s -m "Add the thing"
```

That appends a `Signed-off-by:` trailer with your name and email. CI rejects any commit on a PR branch that doesn't have a valid DCO trailer.

### DCO 1.1 text

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

By signing off your commit you assert all four clauses for the change.

### Why DCO and not a CLA

DCO is auditable per-commit, doesn't require a one-time legal step before you can contribute, and doesn't ask you to transfer copyright. You keep your copyright; the project gets the licenses it needs. This is the same model the Linux kernel, Git itself, and many other large open-source projects use.

## Practical contribution flow

1. Open an issue describing what you want to do — useful when the change is non-trivial.
2. Fork, branch, code.
3. `swift build` and `swift test` must pass locally. (Tests use Swift Testing — see [`docs/testing.md`](./docs/testing.md) once it exists.)
4. Commit with `-s` so each commit carries the DCO sign-off.
5. Open a PR. The CI workflow (`.github/workflows/ci.yml`) runs build, test, selftest, and a bench smoke. A separate DCO check enforces sign-off on every commit in the PR.
6. A maintainer reviews. Iterate as needed.

## Style

- Default to no comments. Only add a comment where the *why* is non-obvious — see [`memory-bank/projectRules.md`](./memory-bank/projectRules.md) Rule R11.
- `swift-format` config is at repo root; CI enforces.
- No `// TODO` without a task reference (see project rules).
- All public types `Sendable` where the platform allows.
- One-line WHY comments are the limit.

## What gets accepted

We optimize for code that fits the architecture documented in [`memory-bank/systemPatterns.md`](./memory-bank/systemPatterns.md), the project rules in [`memory-bank/projectRules.md`](./memory-bank/projectRules.md), and the in-flight release roadmap under [`memory-bank/release/`](./memory-bank/release/).

The hard non-negotiables are listed in `projectRules.md` Rule R12 ("Refuse on Sight"). PRs that add any of those — celebrity presets, ID-bypass paths, optional-watermark-in-release, cloud-inference fallback — will be closed regardless of code quality.

## Reporting security issues

Don't open public issues for vulnerabilities. Email the maintainer (see [`COMMERCIAL.md`](./COMMERCIAL.md) Contact section) with details. We'll respond within 5 business days.

## Acknowledgement

Contributors are credited in the per-release notes (`CHANGELOG.md`) and, for substantial contributions, in the paper drafts under [`docs/paper/`](./docs/paper/).
