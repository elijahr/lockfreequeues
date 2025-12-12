#!/usr/bin/env python3
"""Benchmark runner for lockfreequeues.

Orchestrates benchmark execution across languages and collects results.
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


def build_nim():
    """Build Nim benchmarks."""
    print("Building Nim benchmarks...")
    subprocess.run([
        "nim", "c", "-d:release", "--threads:on",
        str(BENCHMARK_DIR / "nim" / "bench_main.nim")
    ], check=True)
    print("Nim benchmarks built.")


def run_nim(runs: int, output_file: Path):
    """Run Nim benchmarks."""
    print(f"Running Nim benchmarks ({runs} runs)...")
    subprocess.run([
        str(BENCHMARK_DIR / "nim" / "bench_main"),
        f"--runs={runs}",
        f"-o={output_file}"
    ], check=True)
    print(f"Results written to {output_file}")


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
            # Copy to specified output file
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
