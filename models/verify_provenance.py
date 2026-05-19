#!/usr/bin/env python3
"""Re-hash the shipped .mlpackage and assert it matches the provenance sidecar.

Used by CI per R5; runs without torch/coremltools. Exit 0 on match, 1 on mismatch.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


def sha256_of_path(path: Path) -> str:
    h = hashlib.sha256()
    if path.is_dir():
        for f in sorted(path.rglob("*")):
            if f.is_file():
                h.update(str(f.relative_to(path)).encode("utf-8"))
                h.update(b"\x00")
                with f.open("rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        h.update(chunk)
    else:
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def main(argv: list[str]) -> int:
    models_dir = Path(__file__).resolve().parent
    pkg = models_dir / "blendshape_solver_v1.mlpackage"
    sidecar = models_dir / "blendshape_solver_v1.provenance.json"
    if not sidecar.exists():
        print(f"FAIL: provenance sidecar missing: {sidecar}", file=sys.stderr)
        return 1
    meta = json.loads(sidecar.read_text())
    expected = meta.get("sha256", "")
    if not pkg.exists():
        # Sidecar present, package absent — acceptable: CoreMLSolver falls back to geometric.
        print(f"WARN: {pkg.name} absent; CoreMLSolver will fall back. Expected sha256={expected[:12]}...")
        return 0
    actual = sha256_of_path(pkg)
    if actual != expected:
        print(f"FAIL: sha256 mismatch.\n  expected: {expected}\n  actual:   {actual}", file=sys.stderr)
        return 1
    print(f"OK: {pkg.name} matches provenance ({actual[:12]}...)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
