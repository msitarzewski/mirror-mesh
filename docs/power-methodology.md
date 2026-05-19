# Power Benchmark Methodology

How MirrorMesh measures end-to-end energy use, and how to reproduce the numbers in the paper.

## What `powermetrics` measures

`powermetrics(1)` is a Darwin-bundled tool that samples the SoC power-management counters (SMC on Intel; on-die counters on Apple Silicon). With the samplers we use it reports:

- `cpu_power` — total CPU complex power (P-cores + E-cores)
- `gpu_power` — integrated GPU power
- `ane_power` — Apple Neural Engine power (the rail we care about for Core ML inference)
- `package_power` — full SoC package, usually ≥ cpu + gpu + ane (includes uncore, fabric, memory controllers)
- `thermal_pressure` — `Nominal` / `Fair` / `Serious` / `Critical` — what the OS thinks the thermal headroom is

All power values are in milliwatts. We sample at **100 ms** (`-i 100`), which is a good balance between resolving short bursts (e.g. a single Vision pass) and not drowning in noise.

## Why `sudo` is required

`powermetrics` reads privileged kernel counters. It will refuse to start without root. `bench/scripts/power.sh` makes that explicit:

1. `sudo -n true` — check whether sudo creds are already cached
2. If not, `sudo -v` — prompt interactively, then cache for the rest of the script
3. The `powermetrics` invocation itself uses `sudo`

We do **not** silently cache sudo timestamps for the user, and we do **not** install a SUID helper. You will see the prompt.

## Thermal state matters

The same workload on the same machine can draw very different power depending on thermal state:

| State | What it means | Effect on numbers |
|-------|---------------|-------------------|
| `Nominal` | Headroom, no throttling | Steady-state numbers — what you want for the paper |
| `Fair` | Mild thermal pressure | CPU may down-clock under sustained load |
| `Serious` | Heavy throttling | Numbers go **down** (less work per watt is happening) but latency goes **up** |
| `Critical` | Emergency throttle | Discard the run; not representative |

The wrapper records `pmset -g therm` at start, and the parser preserves `thermal_pressure` on every sample. When summarizing, eyeball the `thermal:` line — if it's anything but mostly `Nominal`, the run isn't representative.

## Plugged vs battery

Apple Silicon Macs aggressively manage power on battery. The same scenario on the same machine, run on battery vs. plugged in, can differ by:

- **CPU power**: up to ~20% lower on battery (down-clocked P-cores)
- **GPU power**: up to ~30% lower on battery
- **ANE power**: roughly equal; the ANE is already extremely efficient

**Paper numbers are always plugged in.** The wrapper records `pmset -g ps` (the "(AC Power)" / "(Battery Power)" tag) into the header file so you can audit a posted result.

## Reproducing the paper numbers

Reference run:

- **Hardware**: Mac17,6 (M5 Max, 14C/40C, 64 GB)
- **macOS**: 26.x release build
- **Power**: Plugged into 140W adapter, lid open
- **Thermal**: Allow 5 minutes idle after the previous run so thermal pressure returns to `Nominal`
- **Scenario**: `bench/scenarios/demo.json` (synthetic, 640×360, 30 fps, 120 frames)
- **Build**: `swift build -c release` (the wrapper currently uses default `swift run`; switch to `-c release` for paper-grade runs)

Recipe:

```bash
# 1. Warm up: let thermal pressure return to nominal
pmset -g therm

# 2. Cache sudo creds (so the bench start isn't blocked on a prompt)
sudo -v

# 3. Run the paired bench + power capture
bench/scripts/power.sh demo

# 4. Summarize
ls -t bench/out/demo_*_power.jsonl | head -n1 | xargs python3 bench/scripts/summarize_power.py
ls -t bench/out/demo_*.jsonl | grep -v power | head -n1 | xargs python3 bench/scripts/summarize.py
```

The two summaries together pair latency with energy — that's the paper claim.

## Interpreting samples

- **Sampling cadence**: 100 ms. A 120-frame, 30 fps scenario runs for ~4 seconds → ~40 power samples. Short runs are noisy; prefer scenarios ≥ 10 seconds for stable percentiles.
- **Tail samples**: the very last sample in the stream is sometimes truncated when `powermetrics` is `SIGINT`ed mid-write. `power_parse.py` silently skips malformed final records; the count it prints is the *good* count.
- **`package_mw` ≠ `cpu+gpu+ane`**: the package rail includes uncore, fabric, and memory controllers. Expect package to be 200–400 mW higher than the sum of the three named rails. Use `package_mw` as the "total system-on-chip" number for the paper.

## Outputs

A successful run produces three files in `bench/out/`:

| File | Contents |
|------|----------|
| `<name>_<stamp>_power.header.json` | One JSON line: model, OS, power source, thermal state, scenario |
| `<name>_<stamp>_power.plist` | Raw `powermetrics` output (concatenated plist documents) |
| `<name>_<stamp>_power.jsonl` | Parsed JSONL, one `{"t":"power",...}` record per sample |

Pair the JSONL with the corresponding `<name>_<stamp>.jsonl` perf trace (same stamp, no `_power` suffix) to align latency and energy on the same wall clock.
