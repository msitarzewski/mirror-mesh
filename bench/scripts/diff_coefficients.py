#!/usr/bin/env python3.11
"""Side-by-side P50/P95 diff of two mirrormesh-bench JSONL traces.

Usage:
    diff_coefficients.py geometric.jsonl coreml.jsonl

The script does **not** assume the bench currently logs blendshape coefficients per frame —
it falls back to per-stage latency P50/P95/P99 when coefficient samples are absent. Once a
future bench logs `coefficients: {...}` inside frame events, this script will display the
per-coefficient delta as well.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Iterable


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    k = int(round((len(values) - 1) * p))
    return values[k]


def load(path: Path) -> dict:
    """Return {per_stage: {stage: [ms]}, e2e: [ms], coef: {key: [v]}}."""
    per_stage: dict[str, list[float]] = {}
    e2e: list[float] = []
    coef: dict[str, list[float]] = {}
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            if evt.get("t") != "frame":
                continue
            for stage, ms in evt.get("per_stage_ms", {}).items():
                per_stage.setdefault(stage, []).append(float(ms))
            if "e2e_ms" in evt:
                e2e.append(float(evt["e2e_ms"]))
            for k, v in (evt.get("coefficients") or {}).items():
                coef.setdefault(k, []).append(float(v))
    return {"per_stage": per_stage, "e2e": e2e, "coef": coef}


def fmt(v: float) -> str:
    return f"{v:8.3f}"


def print_row(label: str, a_p50: float, a_p95: float, b_p50: float, b_p95: float):
    print(f"  {label:<22} {fmt(a_p50)} {fmt(a_p95)}   |  {fmt(b_p50)} {fmt(b_p95)}   "
          f"|  Δp50={fmt(b_p50 - a_p50)}  Δp95={fmt(b_p95 - a_p95)}")


def report(a_path: Path, b_path: Path):
    a = load(a_path)
    b = load(b_path)

    print(f"A: {a_path}")
    print(f"B: {b_path}")
    print()
    print(f"  {'metric':<22} {'A_p50':>8} {'A_p95':>8}   |  {'B_p50':>8} {'B_p95':>8}   |  delta")
    print(f"  {'-' * 22} {'-' * 8} {'-' * 8}      {'-' * 8} {'-' * 8}      ----------")

    # End-to-end + per-stage latency
    print_row("e2e_ms",
              percentile(a["e2e"], 0.5),  percentile(a["e2e"], 0.95),
              percentile(b["e2e"], 0.5),  percentile(b["e2e"], 0.95))
    for stage in sorted(set(list(a["per_stage"].keys()) + list(b["per_stage"].keys()))):
        av = a["per_stage"].get(stage, [])
        bv = b["per_stage"].get(stage, [])
        print_row(f"{stage}_ms",
                  percentile(av, 0.5), percentile(av, 0.95),
                  percentile(bv, 0.5), percentile(bv, 0.95))

    # Coefficient deltas (only when both files log them)
    common = sorted(set(a["coef"].keys()) & set(b["coef"].keys()))
    if common:
        print()
        print("coefficients (raw values, 0..1)")
        print(f"  {'key':<22} {'A_p50':>8} {'A_p95':>8}   |  {'B_p50':>8} {'B_p95':>8}   |  delta")
        for k in common:
            av = a["coef"][k]
            bv = b["coef"][k]
            print_row(k,
                      percentile(av, 0.5), percentile(av, 0.95),
                      percentile(bv, 0.5), percentile(bv, 0.95))
    else:
        print()
        print("(no per-frame coefficient logging in either trace — only latency reported)")


def main(argv: list[str]):
    if len(argv) < 3:
        print("usage: diff_coefficients.py <a.jsonl> <b.jsonl>", file=sys.stderr)
        sys.exit(2)
    report(Path(argv[1]), Path(argv[2]))


if __name__ == "__main__":
    main(sys.argv)
