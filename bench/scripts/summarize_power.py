#!/usr/bin/env python3.11
"""Summarize a power JSONL produced by power_parse.py.

Prints mean / P50 / P95 / max for each power rail (cpu, gpu, ane, package) in
milliwatts, plus sample count.

Usage:  summarize_power.py <power.jsonl>
"""
import json
import sys
from pathlib import Path


def _percentile(values, p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    k = int(round((len(values) - 1) * p))
    return float(values[k])


def _mean(values) -> float:
    return float(sum(values) / len(values)) if values else 0.0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: summarize_power.py <power.jsonl>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"error: {path} does not exist", file=sys.stderr)
        return 1

    rails = {"cpu": [], "gpu": [], "ane": [], "package": []}
    thermal_counts: dict[str, int] = {}

    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            if evt.get("t") != "power":
                continue
            rails["cpu"].append(evt.get("cpu_mw", 0))
            rails["gpu"].append(evt.get("gpu_mw", 0))
            rails["ane"].append(evt.get("ane_mw", 0))
            rails["package"].append(evt.get("package_mw", 0))
            th = evt.get("thermal", "nominal")
            thermal_counts[th] = thermal_counts.get(th, 0) + 1

    print(f"file:    {path}")
    print(f"samples: {len(rails['cpu'])}")
    if thermal_counts:
        breakdown = ", ".join(f"{k}={v}" for k, v in sorted(thermal_counts.items()))
        print(f"thermal: {breakdown}")
    print()

    header = f"{'rail':<10}{'mean_mw':>12}{'p50_mw':>10}{'p95_mw':>10}{'max_mw':>10}{'n':>8}"
    print(header)
    print("-" * len(header))
    for rail, values in rails.items():
        n = len(values)
        mean = _mean(values)
        p50 = _percentile(values, 0.50)
        p95 = _percentile(values, 0.95)
        mx = float(max(values)) if values else 0.0
        print(f"{rail:<10}{mean:>12.1f}{p50:>10.1f}{p95:>10.1f}{mx:>10.1f}{n:>8d}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
