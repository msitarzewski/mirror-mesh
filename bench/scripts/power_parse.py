#!/usr/bin/env python3
"""Parse `powermetrics --format plist` output into JSONL.

`powermetrics -f plist -i 100` writes a stream of *separate* XML plist
documents, one per sample, concatenated together (often with a NUL byte
between them, sometimes not). `plistlib.loads` only accepts one document at
a time, so we split the stream into per-document chunks before parsing.

Each sample emits one JSONL record:
    {"t":"power","ts_us":..., "cpu_mw":..., "gpu_mw":..., "ane_mw":...,
     "package_mw":..., "thermal":"nominal"}

Usage:  power_parse.py <in.plist> <out.jsonl>
"""
import json
import plistlib
import sys
from pathlib import Path


# WHY: closing </plist> tag is the only reliable per-document boundary marker.
_DOC_END = b"</plist>"


def split_plist_documents(blob: bytes):
    """Yield each XML plist document from a concatenated/NUL-separated stream."""
    # WHY: powermetrics sometimes wedges NUL bytes between docs; drop them.
    blob = blob.replace(b"\x00", b"")
    if not blob.strip():
        return
    # WHY: split *after* each </plist>; final fragment is the (often truncated) tail.
    start = 0
    while True:
        end = blob.find(_DOC_END, start)
        if end == -1:
            break
        end += len(_DOC_END)
        chunk = blob[start:end].strip()
        if chunk:
            yield chunk
        start = end


def _to_mw(value) -> int:
    """Convert a powermetrics power field (typically mW) to int mW."""
    # WHY: powermetrics already reports milliwatts; coerce to int defensively.
    try:
        return int(round(float(value)))
    except (TypeError, ValueError):
        return 0


def extract_sample(doc: dict) -> dict | None:
    """Extract one JSONL record from a parsed plist sample dict."""
    if not isinstance(doc, dict):
        return None

    # WHY: powermetrics uses both 'elapsed_ns' and 'timestamp' across versions.
    ts_us = 0
    if "elapsed_ns" in doc:
        try:
            ts_us = int(doc["elapsed_ns"]) // 1000
        except (TypeError, ValueError):
            ts_us = 0
    elif "timestamp" in doc:
        ts_us = 0  # WHY: timestamp is a date; we keep ts_us=0 for date-form samples.

    processor = doc.get("processor", {}) or {}
    cpu_mw = _to_mw(processor.get("cpu_power", 0))
    gpu_mw = _to_mw(processor.get("gpu_power", 0))
    ane_mw = _to_mw(processor.get("ane_power", 0))
    package_mw = _to_mw(processor.get("package_power", cpu_mw + gpu_mw + ane_mw))

    # WHY: thermal pressure surfaces under 'thermal_pressure' on Apple Silicon.
    thermal = doc.get("thermal_pressure", "nominal")
    if not isinstance(thermal, str):
        thermal = str(thermal)

    return {
        "t": "power",
        "ts_us": ts_us,
        "cpu_mw": cpu_mw,
        "gpu_mw": gpu_mw,
        "ane_mw": ane_mw,
        "package_mw": package_mw,
        "thermal": thermal,
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: power_parse.py <in.plist> <out.jsonl>", file=sys.stderr)
        return 2

    in_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    if not in_path.exists():
        print(f"error: {in_path} does not exist", file=sys.stderr)
        return 1

    blob = in_path.read_bytes()
    n_ok = 0
    n_bad = 0

    with out_path.open("w") as out:
        for doc_bytes in split_plist_documents(blob):
            try:
                doc = plistlib.loads(doc_bytes)
            except Exception:
                # WHY: the last sample is frequently truncated; skip silently.
                n_bad += 1
                continue
            rec = extract_sample(doc)
            if rec is None:
                n_bad += 1
                continue
            out.write(json.dumps(rec) + "\n")
            n_ok += 1

    print(f"power_parse: wrote {n_ok} samples to {out_path} ({n_bad} skipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
