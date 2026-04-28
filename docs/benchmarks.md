# Benchmarks

Performance benchmarks comparing lockfreequeues against alternative implementations.

## Methodology

### Throughput Benchmark
- N producer threads and N consumer threads share one queue
- Each thread sends/receives 1,000,000 / N messages
- Measures end-to-end time, reports ops/ms
- 33 runs with warmup for stable statistics

### Latency Benchmark
- Ping-pong between 2 threads using 2 queues
- Measures round-trip time (RTT) in nanoseconds
- 100,000 iterations per run
- Reports percentiles: p50, p95, p99, p999

## Running Benchmarks

```bash
# Quick run (10 iterations)
nimble benchmarks

# Full benchmark suite
python benchmarks/runner.py run --runs=33
```

## Queue Types Compared

### Bounded Queues

| Queue | Type | Implementation |
|-------|------|----------------|
| Sipsic | SPSC | lockfreequeues |
| Sipmuc | SPMC | lockfreequeues |
| Mupsic | MPSC | lockfreequeues |
| Mupmuc | MPMC | lockfreequeues |
| channels | MPMC | Nim stdlib |

### Unbounded Queues

| Queue | Type | Implementation |
|-------|------|----------------|
| UnboundedSipsic | SPSC | lockfreequeues |
| UnboundedMupmuc | MPMC | lockfreequeues |
| LoonyQueue | MPMC | loony |

## Results

Results are generated per-platform. See the `benchmarks/results/` directory for JSON output.

Charts and visualizations coming in Phase 2.
