# M17 — Power Benchmark via `powermetrics`

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M14
**Blocks**: M20

## Objective

Pair every bench run with a power JSONL captured via `powermetrics`. This is the data that backs the paper's "local-only and energy-efficient" claim — without it the claim is vibes-only.

## Deliverables

- `bench/scripts/power.sh` — wrapper that:
  1. Starts `powermetrics --samplers cpu_power,gpu_power,ane_power,thermal -i 100 -o bench/out/<name>_power.txt` in the background (requires `sudo`; the script `sudo -v` first and warns)
  2. Runs the bench scenario in the foreground
  3. Kills the powermetrics process when the bench finishes
  4. Parses the powermetrics text output into JSONL (one record per sample) at `bench/out/<name>_power.jsonl`
- `bench/scripts/power_parse.py` — parser that turns the `powermetrics` plist/text output into JSONL records `{"t":"power","ts":...,"cpu_mw":...,"gpu_mw":...,"ane_mw":...,"package_mw":...}`
- `bench/scripts/summarize_power.py` — prints mean / P50 / P95 / max for each rail
- `docs/power-methodology.md` — what we measured, on what hardware, with what build, plugged vs battery

## Behavior

```bash
sudo -v   # cache sudo timestamp
bench/scripts/power.sh demo
# produces bench/out/demo_<ts>.jsonl  AND  bench/out/demo_<ts>_power.jsonl
python3 bench/scripts/summarize_power.py bench/out/demo_<ts>_power.jsonl
```

## Verification

- Run on the reference hardware (Mac17,6 / M5 Max)
- Numbers go into `bench/baselines/power.jsonl`

## Notes

- `powermetrics` requires sudo; the script makes that explicit, never hides it
- Numbers vary by thermal state and battery; the script records `Date`, `thermal_state` (via `pmset -g therm`), and power source at start
