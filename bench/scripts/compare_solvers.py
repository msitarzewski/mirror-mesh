#!/usr/bin/env python3.11
"""Side-by-side comparison of two mirrormesh-bench JSONL runs.

Reads per-frame `{"t":"coefficients","frame":N,"values":{...}}` events from a
geometric run and a coreml run, joins them on frame ID, and reports:

* per-coefficient mean absolute disagreement
* overall mean / median / max absolute disagreement
* number of frames matched

Usage
-----
    compare_solvers.py <baseline.jsonl> <candidate.jsonl> [--json]

Globs are accepted because the spec script invokes it as
    compare_solvers.py bench/out/demo_*.jsonl bench/out/demo_coreml_*.jsonl
and the shell expands those into multiple paths. The script picks the **most
recent** file from each side (by mtime), which is the convention bench files
follow with their YYYYMMDD_HHMMSS suffix.

Output is human-readable by default; pass `--json` for a machine-readable
summary that's easy to embed in docs or CI logs.

No external deps — pure stdlib so it runs on any Python ≥ 3.9.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Tuple


def load_coefficients(path: Path) -> Dict[int, Dict[str, float]]:
    """Return {frame_id: {coef_key: value}} for every coefficients line in `path`."""
    out: Dict[int, Dict[str, float]] = {}
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("t") != "coefficients":
                continue
            fr = rec.get("frame")
            vals = rec.get("values")
            if fr is None or not isinstance(vals, dict):
                continue
            # values is {key: float}; coerce defensively in case ints sneak in.
            out[int(fr)] = {str(k): float(v) for k, v in vals.items()}
    return out


def pick_latest(paths: List[Path], hint: str) -> Path:
    """Of a list of paths, return the most recently modified one whose name contains hint
    (case-insensitive), falling back to the latest overall if no hint match."""
    if not paths:
        raise SystemExit(f"compare_solvers: no files supplied for '{hint}'")
    hint_lc = hint.lower()
    matched = [p for p in paths if hint_lc in p.name.lower()]
    pool = matched or paths
    return max(pool, key=lambda p: p.stat().st_mtime)


def compare(baseline: Dict[int, Dict[str, float]],
            candidate: Dict[int, Dict[str, float]]) -> Tuple[Dict, List[Tuple[str, float]]]:
    """Compute aggregate + per-coefficient mean absolute disagreement."""
    common_frames = sorted(set(baseline) & set(candidate))
    if not common_frames:
        raise SystemExit("compare_solvers: no overlapping frames between baseline and candidate")

    per_coef: Dict[str, List[float]] = {}
    all_diffs: List[float] = []
    for fr in common_frames:
        b = baseline[fr]
        c = candidate[fr]
        keys = set(b) | set(c)
        for k in keys:
            bv = b.get(k, 0.0)
            cv = c.get(k, 0.0)
            d = abs(bv - cv)
            per_coef.setdefault(k, []).append(d)
            all_diffs.append(d)

    per_coef_mean: List[Tuple[str, float]] = sorted(
        ((k, statistics.fmean(v)) for k, v in per_coef.items()),
        key=lambda kv: kv[1],
        reverse=True,
    )
    summary = {
        "matched_frames": len(common_frames),
        "baseline_frames": len(baseline),
        "candidate_frames": len(candidate),
        "mean_abs_diff": statistics.fmean(all_diffs) if all_diffs else 0.0,
        "median_abs_diff": statistics.median(all_diffs) if all_diffs else 0.0,
        "max_abs_diff": max(all_diffs) if all_diffs else 0.0,
        "coefficient_count": len(per_coef),
    }
    return summary, per_coef_mean


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Compare blendshape coefficients between two mirrormesh-bench JSONL runs.")
    parser.add_argument("paths", nargs="+", type=Path,
                        help="JSONL files. Pass at least one baseline-side and one candidate-side; "
                             "shell globs are fine — the latest per side is used.")
    parser.add_argument("--baseline-hint", default="demo_",
                        help="Substring matching baseline files (default: 'demo_').")
    parser.add_argument("--candidate-hint", default="coreml",
                        help="Substring matching candidate files (default: 'coreml').")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON summary.")
    parser.add_argument("--top", type=int, default=10, help="Show top-N noisiest coefficients.")
    args = parser.parse_args(argv)

    files = [p for p in args.paths if p.suffix == ".jsonl"]
    if not files:
        print("compare_solvers: no .jsonl files in arguments", file=sys.stderr)
        return 1

    # Partition: candidate = filename contains the candidate hint; baseline = the rest.
    cand_files = [p for p in files if args.candidate_hint.lower() in p.name.lower()]
    base_files = [p for p in files if p not in cand_files]
    if not base_files:
        # User passed only candidate-side; require explicit baseline.
        print(f"compare_solvers: no baseline files (none lacking '{args.candidate_hint}')",
              file=sys.stderr)
        return 1
    if not cand_files:
        print(f"compare_solvers: no candidate files (none containing '{args.candidate_hint}')",
              file=sys.stderr)
        return 1

    baseline_path = max(base_files, key=lambda p: p.stat().st_mtime)
    candidate_path = max(cand_files, key=lambda p: p.stat().st_mtime)

    baseline = load_coefficients(baseline_path)
    candidate = load_coefficients(candidate_path)
    if not baseline:
        print(f"compare_solvers: baseline {baseline_path} has no coefficient events. "
              "Did you set 'log_coefficients': true in the scenario?", file=sys.stderr)
        return 1
    if not candidate:
        print(f"compare_solvers: candidate {candidate_path} has no coefficient events. "
              "Did you set 'log_coefficients': true in the scenario?", file=sys.stderr)
        return 1

    summary, per_coef_mean = compare(baseline, candidate)
    summary["baseline_file"] = str(baseline_path)
    summary["candidate_file"] = str(candidate_path)

    if args.json:
        payload = {
            "summary": summary,
            "per_coefficient_mean_abs_diff": dict(per_coef_mean),
        }
        print(json.dumps(payload, indent=2))
        return 0

    # Human-readable
    print(f"baseline:  {baseline_path}  ({summary['baseline_frames']} frames)")
    print(f"candidate: {candidate_path}  ({summary['candidate_frames']} frames)")
    print(f"matched frames: {summary['matched_frames']}")
    print(f"coefficients tracked: {summary['coefficient_count']}")
    print()
    print(f"  mean   |coef_a - coef_b| = {summary['mean_abs_diff']:.6f}")
    print(f"  median |coef_a - coef_b| = {summary['median_abs_diff']:.6f}")
    print(f"  max    |coef_a - coef_b| = {summary['max_abs_diff']:.6f}")
    print()
    n = min(args.top, len(per_coef_mean))
    print(f"top {n} coefficients by mean absolute disagreement:")
    for k, v in per_coef_mean[:n]:
        print(f"  {k:<30s} {v:.6f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
