#!/usr/bin/env python3.11
"""Generate paper-ready figures from mirrormesh-bench JSONL traces.

Outputs into `docs/figures/`:
- latency_by_stage.pdf  — per-stage P50/P95/P99 bar chart
- e2e_distribution.pdf  — end-to-end latency histogram (log-y)
- per_session.pdf       — line plot of e2e latency over frame index

Requires `matplotlib`. Install via `pip3 install matplotlib`.
"""
import json
import os
import sys
from pathlib import Path

try:
    import matplotlib

    matplotlib.use("Agg")  # headless backend; PDFs render without a display
    import matplotlib.pyplot as plt
except ImportError:
    print("ERROR: matplotlib not installed. Run: pip3 install matplotlib", file=sys.stderr)
    sys.exit(1)


def load_frames(path):
    per_stage = {}
    e2e = []
    meta = {}
    with open(path) as f:
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
    return meta, per_stage, e2e


def percentile(values, p):
    if not values:
        return 0.0
    values = sorted(values)
    k = int(round((len(values) - 1) * p))
    return values[k]


def figure_latency_by_stage(per_stage, out_path):
    stages = sorted(per_stage.keys())
    p50s = [percentile(per_stage[s], 0.50) for s in stages]
    p95s = [percentile(per_stage[s], 0.95) for s in stages]
    p99s = [percentile(per_stage[s], 0.99) for s in stages]
    width = 0.25
    x = list(range(len(stages)))
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.bar([i - width for i in x], p50s, width, label="P50")
    ax.bar(x, p95s, width, label="P95")
    ax.bar([i + width for i in x], p99s, width, label="P99")
    ax.set_xticks(x)
    ax.set_xticklabels(stages, rotation=20, ha="right")
    ax.set_ylabel("Latency (ms)")
    ax.set_title("Per-stage latency")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path)
    plt.close(fig)


def figure_e2e_distribution(e2e, out_path):
    if not e2e:
        return
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.hist(e2e, bins=40)
    ax.set_xlabel("End-to-end latency (ms)")
    ax.set_ylabel("Frames")
    ax.set_yscale("log")
    ax.set_title("End-to-end latency distribution")
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path)
    plt.close(fig)


def figure_per_session(e2e, out_path):
    if not e2e:
        return
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.plot(list(range(len(e2e))), e2e, linewidth=1)
    ax.set_xlabel("Frame index")
    ax.set_ylabel("End-to-end latency (ms)")
    ax.set_title("End-to-end latency over session")
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path)
    plt.close(fig)


def main():
    if len(sys.argv) < 2:
        print("usage: figures.py <jsonl-file> [<jsonl-file> ...]", file=sys.stderr)
        sys.exit(2)
    out_dir = Path(__file__).resolve().parent.parent.parent / "docs" / "figures"
    out_dir.mkdir(parents=True, exist_ok=True)

    all_per_stage = {}
    all_e2e = []
    for arg in sys.argv[1:]:
        _, per_stage, e2e = load_frames(arg)
        for k, v in per_stage.items():
            all_per_stage.setdefault(k, []).extend(v)
        all_e2e.extend(e2e)

    figure_latency_by_stage(all_per_stage, out_dir / "latency_by_stage.pdf")
    figure_e2e_distribution(all_e2e, out_dir / "e2e_distribution.pdf")
    figure_per_session(all_e2e, out_dir / "per_session.pdf")

    print(f"wrote {out_dir / 'latency_by_stage.pdf'}")
    print(f"wrote {out_dir / 'e2e_distribution.pdf'}")
    print(f"wrote {out_dir / 'per_session.pdf'}")


if __name__ == "__main__":
    main()
