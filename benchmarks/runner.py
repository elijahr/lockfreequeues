#!/usr/bin/env python3
"""Benchmark runner for lockfreequeues.

Orchestrates benchmark execution across languages and collects results.
PR 2 (bench-rollup) replaced the single `bench_throughput` driver with
topology-split binaries; v5.0.0 B3 further split the MPMC slice into a
per-family pair (bench_mpmc_mupmuc + bench_mpmc_sipmuc); v5.0.0 3.3.9-D
applied the same mitigation to the unbounded slice, fanning the legacy
`bench_unbounded` binary out into four per-family binaries
(bench_unbounded_sipsic + bench_unbounded_sipmuc +
bench_unbounded_mupsic + bench_unbounded_mupmuc) so each unbounded
family no longer shares a release binary (cross-family iCache contention
reproduced -17% to -34% throughput regressions on unbounded_mupmuc/2p2c,
unbounded_mupsic/2p1c, and unbounded_mupsic/4p1c in 3.3.9 retry #4).
This runner builds + runs all nine binaries in sequence and merges the
BMF fragments via `merge_bmf.py` so callers keep getting one combined
JSON file.
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

BENCHMARK_DIR = Path(__file__).parent
PROJECT_ROOT = BENCHMARK_DIR.parent
RESULTS_DIR = BENCHMARK_DIR / "results"

# Track 2 PR 2 + v5.0.0 B3 split + v5.0.0 3.3.9-D split: topology-split
# binaries with the MPMC slice further split per family AND the
# unbounded slice fanned out into four per-family binaries. Each is
# built and run separately; merge_bmf.py unions the fragments before
# downstream consumers see a single JSON.
NIM_BINARIES = (
    "bench_spsc",
    "bench_mpsc",
    "bench_mpmc_mupmuc",
    "bench_mpmc_sipmuc",
    "bench_unbounded_sipsic",
    "bench_unbounded_sipmuc",
    "bench_unbounded_mupsic",
    "bench_unbounded_mupmuc",
    "bench_latency",
)


def build_nim():
    """Build all Nim topology-split benchmark binaries.

    Uses default {.intdefine.} run shapes (1M messages * 33 runs for
    bounded throughput, 500K * 3 for unbounded, 100K * 33 for latency).
    For tighter wall-clock budgets pass `-d:` overrides to nim
    directly; the runner does not surface those through its CLI.
    """
    print("Building Nim topology-split benchmarks...")
    for bin_name in NIM_BINARIES:
        src = BENCHMARK_DIR / "nim" / f"{bin_name}.nim"
        print(f"  -> {bin_name}")
        # Match the CI compile shape in `.github/workflows/bench.yml`
        # (`-d:release -d:danger`). `-d:danger` strips runtime checks
        # the queue hot path treats as cold-path overhead in production
        # benches; without it, locally produced numbers are not
        # comparable to the cloud baseline.
        subprocess.run(
            ["nim", "c", "-d:release", "-d:danger", "--threads:on", str(src)],
            check=True,
        )
    print("Nim benchmarks built.")


def run_nim(runs: int, output_file: Path):
    """Run every Nim topology-split binary and merge their BMF outputs.

    The `runs` argument is honored at compile time (via per-binary
    `-d:Bench<Topo>Runs=<n>` overrides) — kept as a no-op runtime arg
    for CLI back-compat. Use `python3 benchmarks/runner.py build` with
    explicit `nim c -d:` flags ahead of `run` to set the run count.
    """
    print(f"Running Nim topology-split benchmarks ({runs} runs)...")
    fragments: list[Path] = []
    try:
        for bin_name in NIM_BINARIES:
            bin_path = PROJECT_ROOT / ".tmp" / bin_name
            out = output_file.parent / f"{output_file.stem}-{bin_name}.json"
            print(f"  -> {bin_name} -> {out.name}")
            subprocess.run(
                [str(bin_path), f"--bmf-out={out}"],
                check=True,
            )
            fragments.append(out)
        # Merge the per-binary BMF fragments into the requested output
        # file via merge_bmf.py. Unions per-slug measure dicts and exits
        # 1 on (slug, measure) collisions.
        print(f"Merging {len(fragments)} fragments -> {output_file}")
        subprocess.run(
            [
                sys.executable,
                str(BENCHMARK_DIR / "merge_bmf.py"),
                str(output_file),
                *[str(p) for p in fragments],
            ],
            check=True,
        )
        print(f"Combined results written to {output_file}")
    finally:
        # The merged file at output_file is the canonical artifact; the
        # per-binary fragments are intermediate. Drop them so RESULTS_DIR
        # doesn't accumulate one set per invocation. `finally` so a
        # bench-binary failure or a merge collision still cleans up
        # whatever fragments were produced.
        for f in fragments:
            f.unlink(missing_ok=True)


def build(args):
    """Build benchmark binaries."""
    if args.language in ("nim", "all"):
        build_nim()


def run(args):
    """Run benchmarks."""
    RESULTS_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")

    if args.language in ("nim", "all"):
        output_file = RESULTS_DIR / f"nim-{timestamp}.json"
        run_nim(args.runs, output_file)

        if args.output:
            # Copy to specified output file.
            with open(output_file) as f:
                data = json.load(f)
            with open(args.output, "w") as f:
                json.dump(data, f, indent=2)
            print(f"Combined results written to {args.output}")


def main():
    parser = argparse.ArgumentParser(description="Benchmark runner for lockfreequeues")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Build command
    build_parser = subparsers.add_parser("build", help="Build benchmark binaries")
    build_parser.add_argument("--language", default="all", choices=["nim", "cpp", "rust", "java", "all"])

    # Run command
    run_parser = subparsers.add_parser("run", help="Run benchmarks")
    run_parser.add_argument("--language", default="all", choices=["nim", "cpp", "rust", "java", "all"])
    run_parser.add_argument("--runs", type=int, default=33, help="Number of benchmark runs")
    run_parser.add_argument("--output", "-o", help="Output file for combined results")

    args = parser.parse_args()

    if args.command == "build":
        build(args)
    elif args.command == "run":
        run(args)


if __name__ == "__main__":
    main()
