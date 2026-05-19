#!/usr/bin/env python3
"""Side-by-side latency comparison for two MirrorMesh JSONL traces.

Reads two JSONL telemetry files (one per landmark backend) and prints a table of
P50/P95/P99 + mean for every stage tracked in the trace, plus the end-to-end totals.
The vision stage is the one that swaps between backends, so the table makes the
backend trade-off immediately visible.

Usage:
    python3 bench/scripts/compare_landmarks.py <vision.jsonl> <mediapipe.jsonl>
    python3 bench/scripts/compare_landmarks.py <vision.jsonl> <mediapipe.jsonl> --json out.json

Either trace may include events the other doesn't; missing stages are reported as
"-". Exits non-zero on argument errors or unreadable files; missing trace data only
warns.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Dict, List, Tuple


# Stages we expect from MirrorMeshCore.StageID. Listed in pipeline order so the
# printed table reads top-to-bottom in the order frames flow through the system.
KNOWN_STAGES: Tuple[str, ...] = ("capture", "vision", "solver", "render", "watermark")


def percentile(values: List[float], pct: float) -> float:
    """Linear-interpolated percentile. Matches the behaviour of `LatencyHistogram`
    in MirrorMeshCore so the script's numbers line up with what Pipeline reports."""
    if not values:
        return float("nan")
    if len(values) == 1:
        return values[0]
    s = sorted(values)
    # Same formula numpy uses for the default method: rank = (N-1) * pct/100.
    rank = (len(s) - 1) * (pct / 100.0)
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return s[lo]
    return s[lo] + (s[hi] - s[lo]) * (rank - lo)


def load_trace(path: Path) -> Tuple[Dict[str, List[float]], List[float], str]:
    """Return (per-stage ms lists, end-to-end ms list, backend tag) from a JSONL file."""
    stages: Dict[str, List[float]] = {s: [] for s in KNOWN_STAGES}
    e2e: List[float] = []
    backend_tag = "unknown"

    with path.open("r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Pipeline emits `.frame` records with per-stage ms + end-to-end ms.
            if event.get("kind") == "frame":
                per = event.get("perStageMs") or {}
                for stage, value in per.items():
                    stages.setdefault(stage, []).append(float(value))
                if "endToEndMs" in event:
                    e2e.append(float(event["endToEndMs"]))
            # Annotation event carries the backend tag (best-effort).
            elif event.get("kind") == "annotation":
                if event.get("key") in ("landmark.backend", "solver.coreml.model"):
                    backend_tag = str(event.get("value", backend_tag))

    return stages, e2e, backend_tag


def fmt_ms(value: float) -> str:
    if math.isnan(value):
        return "    -    "
    return f"{value:8.2f}"


def print_table(
    label_a: str,
    stages_a: Dict[str, List[float]],
    e2e_a: List[float],
    label_b: str,
    stages_b: Dict[str, List[float]],
    e2e_b: List[float],
) -> None:
    # Union of all stages present in either trace, ordered with known stages first.
    all_stages: List[str] = list(KNOWN_STAGES)
    for s in list(stages_a.keys()) + list(stages_b.keys()):
        if s not in all_stages:
            all_stages.append(s)

    header = f"{'stage':<11} | {'metric':<7} | {label_a:>10} | {label_b:>10} | {'delta':>10}"
    sep = "-" * len(header)
    print(header)
    print(sep)

    for stage in all_stages:
        va = stages_a.get(stage, [])
        vb = stages_b.get(stage, [])
        if not va and not vb:
            continue
        for pct_label, pct in (("p50", 50), ("p95", 95), ("p99", 99), ("mean", -1)):
            if pct == -1:
                a = sum(va) / len(va) if va else float("nan")
                b = sum(vb) / len(vb) if vb else float("nan")
            else:
                a = percentile(va, pct)
                b = percentile(vb, pct)
            delta = b - a if not (math.isnan(a) or math.isnan(b)) else float("nan")
            print(
                f"{stage:<11} | {pct_label:<7} | {fmt_ms(a)} | {fmt_ms(b)} | {fmt_ms(delta)}"
            )
        print(sep)

    # end-to-end
    for pct_label, pct in (("p50", 50), ("p95", 95), ("p99", 99), ("mean", -1)):
        if pct == -1:
            a = sum(e2e_a) / len(e2e_a) if e2e_a else float("nan")
            b = sum(e2e_b) / len(e2e_b) if e2e_b else float("nan")
        else:
            a = percentile(e2e_a, pct)
            b = percentile(e2e_b, pct)
        delta = b - a if not (math.isnan(a) or math.isnan(b)) else float("nan")
        print(
            f"{'e2e':<11} | {pct_label:<7} | {fmt_ms(a)} | {fmt_ms(b)} | {fmt_ms(delta)}"
        )
    print(sep)
    print(f"frames     |        | {len(e2e_a):>10d} | {len(e2e_b):>10d} |")


def build_json_summary(
    label_a: str,
    stages_a: Dict[str, List[float]],
    e2e_a: List[float],
    label_b: str,
    stages_b: Dict[str, List[float]],
    e2e_b: List[float],
) -> dict:
    def summary(values: List[float]) -> dict:
        if not values:
            return {"count": 0}
        return {
            "count": len(values),
            "p50": percentile(values, 50),
            "p95": percentile(values, 95),
            "p99": percentile(values, 99),
            "mean": sum(values) / len(values),
        }

    out: dict = {
        label_a: {"e2e": summary(e2e_a), "stages": {}},
        label_b: {"e2e": summary(e2e_b), "stages": {}},
    }
    for stage in set(list(stages_a.keys()) + list(stages_b.keys())):
        out[label_a]["stages"][stage] = summary(stages_a.get(stage, []))
        out[label_b]["stages"][stage] = summary(stages_b.get(stage, []))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Side-by-side latency comparison for two MirrorMesh JSONL traces.")
    parser.add_argument("trace_a", help="JSONL trace path (e.g. Vision backend run)")
    parser.add_argument("trace_b", help="JSONL trace path (e.g. MediaPipe backend run)")
    parser.add_argument("--label-a", default="vision",
                        help="Column label for trace_a (default: vision)")
    parser.add_argument("--label-b", default="mediapipe",
                        help="Column label for trace_b (default: mediapipe)")
    parser.add_argument("--json", dest="json_out",
                        help="Optional path; if set, also writes the summary as JSON.")
    args = parser.parse_args()

    path_a = Path(args.trace_a)
    path_b = Path(args.trace_b)
    if not path_a.is_file():
        print(f"ERROR: trace not found: {path_a}", file=sys.stderr)
        return 2
    if not path_b.is_file():
        print(f"ERROR: trace not found: {path_b}", file=sys.stderr)
        return 2

    stages_a, e2e_a, tag_a = load_trace(path_a)
    stages_b, e2e_b, tag_b = load_trace(path_b)

    print(f"trace A: {path_a}  (backend tag: {tag_a})")
    print(f"trace B: {path_b}  (backend tag: {tag_b})")
    print()
    print_table(args.label_a, stages_a, e2e_a, args.label_b, stages_b, e2e_b)

    if args.json_out:
        summary = build_json_summary(args.label_a, stages_a, e2e_a,
                                     args.label_b, stages_b, e2e_b)
        Path(args.json_out).write_text(json.dumps(summary, indent=2))
        print(f"\nJSON summary: {args.json_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
