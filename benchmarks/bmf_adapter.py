#!/usr/bin/env python3
"""Convert bench_throughput.nim stdout to Bencher Metric Format (BMF) JSON.

The Nim throughput bench prints variant blocks in this shape:

    Sipsic (bounded SPSC) 1P/1C:
      mean: 11232. ops/ms
      stddev: 3268.

    Mupmuc (bounded MPMC) 2P/2C:
      mean: 8000. ops/ms
      stddev: 2582.

    UnboundedMupsic (unbounded MPSC) 4P/1C:
      mean: 7500. ops/ms
      min: 5000.  max: 10000.
      stddev: 3536.

    Channels (MPMC) 4P/4C:
      mean: 645. ops/ms
      stddev: 327.

We map each block to a BMF entry keyed by `<variant>/<P>p<C>c`, exposing the
mean as the throughput `value`. When the bench emits min/max (currently only
the unbounded_mupsic group), they populate `lower_value` and `upper_value`.

Non-finite samples (`inf`, `nan`) are dropped — Bencher rejects non-finite
floats. If a block has only non-finite samples, the block is skipped with a
warning, so the rest of the run still reports.

Usage:
    python benchmarks/bmf_adapter.py <input.txt> <output.json>

If `<output.json>` is `-`, JSON is written to stdout.
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from typing import Any

# Maps the human variant prefix emitted by bench_throughput.nim to the slug
# we use as the BMF benchmark name root. Matching is exact on the leading
# token of the header line (the word before the first space or paren).
VARIANT_SLUGS: dict[str, str] = {
    "Sipsic": "sipsic",
    "Mupmuc": "mupmuc",
    "UnboundedMupsic": "unbounded_mupsic",
    "Channels": "channels",
}

# `<Variant> (...) <P>P/<C>C:`  e.g. "Mupmuc (bounded MPMC) 2P/2C:"
HEADER_RE = re.compile(
    r"^(?P<variant>[A-Za-z_]+)\s+\([^)]*\)\s+(?P<p>\d+)P/(?P<c>\d+)C:\s*$"
)
# `  mean: 11232. ops/ms`   (Nim's `:.0f` formatter emits trailing dots)
MEAN_RE = re.compile(r"^\s*mean:\s+(?P<v>[-\w.]+)\s+ops/ms\s*$")
# `  min: 5000.  max: 10000.`
MIN_MAX_RE = re.compile(r"^\s*min:\s+(?P<lo>[-\w.]+)\s+max:\s+(?P<hi>[-\w.]+)\s*$")


def _parse_number(token: str) -> float | None:
    """Parse a Nim-formatted ops/ms token. Returns None if non-finite."""
    # Nim's `fmt"{x:.0f}"` produces e.g. "11232.", "inf", "nan".
    try:
        value = float(token)
    except ValueError:
        return None
    if not math.isfinite(value):
        return None
    return value


def parse_bench_output(text: str) -> dict[str, dict[str, dict[str, float]]]:
    """Parse bench_throughput.nim stdout into a BMF-shaped dict.

    Returns a mapping `{benchmark_name: {"throughput": {"value": ..., ...}}}`
    suitable for `json.dumps`. Skips blocks whose `mean` is non-finite.
    """
    bmf: dict[str, dict[str, dict[str, float]]] = {}

    current_name: str | None = None
    current_metrics: dict[str, float] | None = None

    def _flush() -> None:
        nonlocal current_name, current_metrics
        if current_name is not None and current_metrics is not None:
            if "value" in current_metrics:
                bmf[current_name] = {"throughput": current_metrics}
            else:
                # Header matched but we never saw a finite mean — drop it.
                print(
                    f"bmf_adapter: dropping {current_name!r} (no finite mean)",
                    file=sys.stderr,
                )
        current_name = None
        current_metrics = None

    for line in text.splitlines():
        header = HEADER_RE.match(line)
        if header is not None:
            _flush()
            variant = header["variant"]
            slug = VARIANT_SLUGS.get(variant)
            if slug is None:
                # Unknown variant — keep parsing but record nothing for it.
                current_name = None
                current_metrics = None
                continue
            current_name = f"{slug}/{header['p']}p{header['c']}c"
            current_metrics = {}
            continue

        if current_metrics is None:
            continue

        mean_match = MEAN_RE.match(line)
        if mean_match is not None:
            mean = _parse_number(mean_match["v"])
            if mean is not None:
                current_metrics["value"] = mean
            continue

        min_max_match = MIN_MAX_RE.match(line)
        if min_max_match is not None:
            lo = _parse_number(min_max_match["lo"])
            hi = _parse_number(min_max_match["hi"])
            if lo is not None:
                current_metrics["lower_value"] = lo
            if hi is not None:
                current_metrics["upper_value"] = hi
            continue

    _flush()
    return bmf


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: bmf_adapter.py <bench_output.txt> <bench_results.json|->",
            file=sys.stderr,
        )
        return 2

    in_path = Path(argv[1])
    text = in_path.read_text(encoding="utf-8")
    bmf: dict[str, Any] = parse_bench_output(text)

    if not bmf:
        print("bmf_adapter: no benchmark blocks parsed", file=sys.stderr)
        return 1

    payload = json.dumps(bmf, indent=2, sort_keys=True) + "\n"
    if argv[2] == "-":
        sys.stdout.write(payload)
    else:
        Path(argv[2]).write_text(payload, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
