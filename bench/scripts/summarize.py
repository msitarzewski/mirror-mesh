#!/usr/bin/env python3.11
"""Summarize a mirrormesh-bench JSONL trace.

Reads a JSONL file produced by `mirrormesh-bench` and prints per-stage P50/P95/P99
latencies plus end-to-end stats.
"""
import json
import sys
from pathlib import Path


def percentile(values, p):
    if not values:
        return 0.0
    values = sorted(values)
    k = int(round((len(values) - 1) * p))
    return values[k]


def main():
    if len(sys.argv) < 2:
        print("usage: summarize.py <jsonl-file>", file=sys.stderr)
        sys.exit(2)
    path = Path(sys.argv[1])
    per_stage = {}
    e2e = []
    meta = {}
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = evt.get("t")
            if t == "meta":
                meta = evt
            elif t == "frame":
                for stage, ms in evt.get("per_stage_ms", {}).items():
                    per_stage.setdefault(stage, []).append(ms)
                e2e.append(evt.get("e2e_ms", 0))

    print(f"file:    {path}")
    if meta:
        print(f"session: {meta.get('session', '?')}")
        print(f"device:  {meta.get('device', '?')}  ({meta.get('os', '?')})")
    print(f"frames:  {len(e2e)}")
    print()
    print(f"{'stage':<12} {'p50_ms':>10} {'p95_ms':>10} {'p99_ms':>10} {'n':>6}")
    for stage in sorted(per_stage.keys()):
        v = per_stage[stage]
        print(f"{stage:<12} {percentile(v, 0.5):>10.3f} {percentile(v, 0.95):>10.3f} {percentile(v, 0.99):>10.3f} {len(v):>6}")
    print(f"{'e2e':<12} {percentile(e2e, 0.5):>10.3f} {percentile(e2e, 0.95):>10.3f} {percentile(e2e, 0.99):>10.3f} {len(e2e):>6}")


if __name__ == "__main__":
    main()
