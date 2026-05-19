# Paper Figures

The figures the paper consumes are generated from real bench-run JSONL traces by `bench/scripts/figures.py`.

## Generate

```bash
pip3 install matplotlib                # one-time
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json
python3 bench/scripts/figures.py bench/out/fixture_*.jsonl
```

This writes:

- `docs/figures/latency_by_stage.pdf` — per-stage P50/P95/P99 bar chart
- `docs/figures/e2e_distribution.pdf` — end-to-end histogram, log-y
- `docs/figures/per_session.pdf` — frame-by-frame line plot

## Pooling multiple sessions

Pass multiple JSONL files to pool samples across runs:

```bash
python3 bench/scripts/figures.py bench/out/*.jsonl
```

## Reproducibility constraint

Every figure in the paper must be reproducible from a tagged commit + scenario file + this script. **Do not edit PDFs by hand.** If a figure needs a styling change, change the script and regenerate.
