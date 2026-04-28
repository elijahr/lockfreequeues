# Benchmark Suite

Comprehensive benchmark suite for lockfreequeues.

## Structure

- `nim/` - Nim benchmarks (lockfreequeues, Loony, Nim channels)
- `results/` - JSON output from benchmark runs
- `runner.py` - Orchestrates benchmark execution

## Quick Start

```bash
# Run all Nim benchmarks
python benchmarks/runner.py run --language nim

# Run specific benchmark
nim c -r -d:release --threads:on benchmarks/nim/bench_throughput.nim
```

## Metrics

- **Throughput**: ops/ms with N producer/consumer threads
- **Latency**: RTT nanoseconds with percentiles (p50, p95, p99, p999)
