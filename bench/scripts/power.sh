#!/usr/bin/env bash
# WHY: pair a mirrormesh-bench run with powermetrics sampling, then convert to JSONL.
# REQUIRES SUDO: powermetrics needs root to read SMC/SoC power counters.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <scenario-name> [--scenario <path>]" >&2
  echo "       e.g. $0 demo" >&2
  echo "       e.g. $0 demo --scenario bench/scenarios/demo.json" >&2
  exit 2
fi

name="$1"
shift
scenario_path="bench/scenarios/${name}.json"

# WHY: allow --scenario override so callers can point at non-default JSON.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      scenario_path="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$scenario_path" ]]; then
  echo "scenario not found: $scenario_path" >&2
  exit 2
fi

# WHY: powermetrics is sudo-only — make it explicit, never silent.
if ! sudo -n true 2>/dev/null; then
  echo "[power.sh] powermetrics requires sudo. You'll be prompted now." >&2
  echo "[power.sh] (cached creds will be reused for the rest of this run)" >&2
  sudo -v
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

stamp=$(date +%Y%m%d_%H%M%S)
out_dir="bench/out"
mkdir -p "$out_dir"

plist_path="${out_dir}/${name}_${stamp}_power.plist"
jsonl_path="${out_dir}/${name}_${stamp}_power.jsonl"
header_path="${out_dir}/${name}_${stamp}_power.header.json"

# WHY: snapshot environment that influences power numbers (thermal/AC/battery).
model=$(sysctl -n hw.model 2>/dev/null || echo "unknown")
os_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
os_build=$(sw_vers -buildVersion 2>/dev/null || echo "unknown")
power_source=$(pmset -g ps 2>/dev/null | head -n1 | sed -e 's/.*(//' -e 's/).*//' || echo "unknown")
thermal_state=$(pmset -g therm 2>/dev/null | awk -F': ' '/CPU_Scheduler_Limit/ {print $2}' | head -n1 || echo "unknown")

python3 - "$header_path" "$model" "$os_ver" "$os_build" "$power_source" "$thermal_state" "$stamp" "$name" "$scenario_path" <<'PY'
import json, sys
path, model, os_ver, os_build, power_source, thermal_state, stamp, name, scenario = sys.argv[1:10]
rec = {
    "t": "power_header",
    "stamp": stamp,
    "scenario": name,
    "scenario_path": scenario,
    "model": model,
    "os": f"{os_ver} ({os_build})",
    "power_source": power_source,
    "thermal_cpu_limit": thermal_state,
}
with open(path, "w") as f:
    f.write(json.dumps(rec) + "\n")
PY

echo "[power.sh] header: $header_path"
echo "[power.sh] starting powermetrics → $plist_path"

# WHY: -i 100ms matches the sampling cadence the parser/summarizer assume.
sudo powermetrics \
  --samplers cpu_power,gpu_power,ane_power,thermal \
  -i 100 \
  -f plist \
  -o "$plist_path" >/dev/null 2>&1 &
pm_pid=$!

# WHY: ensure powermetrics is reaped even on interrupt/error.
cleanup() {
  if kill -0 "$pm_pid" 2>/dev/null; then
    sudo kill -INT "$pm_pid" 2>/dev/null || true
    # WHY: powermetrics flushes its plist on SIGINT; give it a moment.
    wait "$pm_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "[power.sh] running: swift run mirrormesh-bench --scenario $scenario_path"
swift run mirrormesh-bench --scenario "$scenario_path"
bench_status=$?

cleanup
trap - EXIT INT TERM

if [[ ! -s "$plist_path" ]]; then
  echo "[power.sh] WARN: powermetrics produced no output (was sudo really granted?)" >&2
fi

echo "[power.sh] parsing plist → $jsonl_path"
python3 bench/scripts/power_parse.py "$plist_path" "$jsonl_path"

echo "[power.sh] done."
echo "[power.sh] plist:  $plist_path"
echo "[power.sh] jsonl:  $jsonl_path"
echo "[power.sh] header: $header_path"

exit "$bench_status"
