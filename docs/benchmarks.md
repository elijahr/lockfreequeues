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

### Live throughput chart

The chart below pulls from a snapshot published by the `bench` CI workflow on
every push to `devel` (see `.github/workflows/bench.yml`). Each line is one
library across the producer/consumer shape grid; the legend toggles individual
libraries on and off. The Y axis defaults to log scale; uncheck the box above
the chart to switch to linear. Hovering a shape shows mean ± stddev when the
underlying measure carries one.

<div markdown="0">
  <div id="bench-chart">
    <noscript>
      Charts require JavaScript. The raw data is published at
      <code>./assets/bench-results/latest.json</code>; download the JSON
      snapshot if you need to consume it programmatically.
    </noscript>
  </div>
  <script src="./assets/uplot-1.6.27.iife.min.js"></script>
  <script src="./assets/bench-charts.js"></script>
</div>

### Methodology and fairness caveats

All numbers below are produced on GitHub-hosted `ubuntu-latest` runners (4 vCPU
implicit, x86_64). Do not infer absolute latency or throughput suitability for
production hardware from these numbers — use them only for relative comparison
between queue implementations under identical conditions.

Specific caveats:

- **Cache-line padding asymmetry.** Some libraries (lockfreequeues, MoodyCamel,
  Boost.LockFree) pad their head/tail/sequence fields to 64 bytes; others may
  not. The lockfreequeues MPMC types were padding-audited as part of PR 3 (see
  audit checklist).
- **Memory ordering.** lockfreequeues uses `acquire`/`release` ordering on its
  hot paths; some external libraries default to `seq_cst`, which is stricter
  and may show as higher latency.
- **NUMA pinning.** None on `ubuntu-latest`. NUMA-aware comparison would
  require self-hosted high-core runners (radar item).
- **Message size and capacity.** All benchmarks transfer 8-byte `uint64_t`
  payloads. Bounded queues use a compile-time capacity matched across libraries.
- **Blocking vs non-blocking semantics.** Nim's `system/Channel` and
  `Threading.Channels` block on full instead of returning a "queue full"
  signal. Their throughput numbers reflect blocking semantics, not the
  non-blocking `try_push` path that the lockfree queues use. These are marked
  with an asterisk in the chart legend.
- **Producer/consumer thread placement.** No explicit pinning. The runner's
  scheduler is the ground truth for thread placement.
- **CPU oversubscription.** `ubuntu-latest` has 4 vCPU. MPMC variants beyond
  4P + 4C measure scheduler oversubscription, not lock-free contention.
