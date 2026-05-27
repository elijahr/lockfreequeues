# Benchmarks

Performance benchmarks comparing lockfreequeues against alternative implementations.

## How to read these numbers

The chart organises every measurement along three axes: the **library** (which
queue implementation), the **topology** (who's allowed to push and pop), and
the **shape** (how many of each are running concurrently). Each combination is
one bar.

Topology slugs name the producer/consumer cardinality: **SPSC** is single
producer single consumer, **SPMC** is single producer with many consumers,
**MPSC** is the inverse, and **MPMC** is many on both sides. Different
topologies admit different algorithms — SPSC can be wait-free with no atomic
RMW on the hot path, while MPMC needs a full Vyukov sequence-counter dance.
See [Core Concepts](guide/core-concepts.md) for the algorithmic background.

Shapes use the `NpMc` form: `4p4c` means four producer threads and four
consumer threads, all on one queue. Higher counts under the same topology
crank up contention — `4p4c` MPMC is harder than `1p1c` MPMC because every
slot is now contested by up to eight threads instead of two, and the
`ubuntu-latest` runner only has 4 vCPU so `8p8c` measures scheduler
oversubscription, not the queue itself.

Bounded variants are ring buffers with compile-time capacity; unbounded
variants are linked segments reclaimed via DEBRA. The bounded/unbounded
choice changes the cost model — bounded amortises everything in a fixed
allocation, unbounded pays a small reclamation overhead in exchange for never
returning a "queue full" error. The trade-off is laid out in
[Bounded vs Unbounded](guide/bounded-vs-unbounded.md).

In the legend, an asterisk (`*`) and the `(blocking)` badge mark libraries
whose adapter blocks on a full queue instead of returning a non-blocking
"full" signal — Nim's `system/Channel` and `Threading.Channels` work that way.
Their bars are also rendered with a dotted edge. The throughput numbers for
those libraries reflect blocking semantics, not the `try_push` path the
lockfreequeues bounded variants expose, so cross-comparisons need that
asterisk in mind.

## When to pick lockfreequeues

If your bottleneck is **single-producer single-consumer with a known capacity**
— an audio callback handing buffers to a render thread, a GPU command queue,
a network read loop feeding a worker — the bounded SPSC queue
(`newSpscQueue`) is wait-free on both sides and clears around 7,600 ops/ms
at `1p1c` on `ubuntu-latest`. There's no adapter for `system/Channel` at SPSC
so the fixture has no head-to-head number against it, but the wait-free
progress guarantee alone usually settles it.

If your bottleneck is **multi-producer multi-consumer at high contention** —
a job scheduler with dozens of producer threads, an event collector
funneling from many sources — the bounded MPMC queue (`newMpmcQueue`) is
the right call. At `4p4c` it sustains around 18,200 ops/ms in the fixture,
against 1,720 ops/ms for `system/Channel` at the same shape — roughly 10.6x
faster. The bounded MPSC queue (`newMpscQueue`) shows a similar gap (about
3.7x at `4p1c`) when only the producer side fans out.

When NOT to reach for lockfreequeues:

- **You actually want blocking semantics.** If "queue full" should park the
  producer until the consumer drains a slot, `system/Channel` and
  `Threading.Channels` give that for free. The lockfreequeues bounded
  variants return a non-blocking signal instead, and you'd need to layer a
  semaphore or condvar on top.
- **Your runtime forbids ARC/ORC.** The library rejects `ref T` items under
  ARC, ORC, or atomicArc by design — the slot copy semantics aren't safe
  with shared `ref` payloads. `refc` works, but defeats the purpose. Use
  value types or `ptr T`.
- **DEBRA reclamation overhead matters more than throughput.** The unbounded
  variants pay a small per-pop bookkeeping cost for epoch advancement; on
  workloads dominated by tiny payloads at very high pop rates the bounded
  variants will measure higher. The fixture shows the unbounded MPMC queue
  at about 9,860 ops/ms at `1p1c` versus the bounded MPMC queue at about
  24,070 ops/ms — a real gap, and the cost of "never blocks on full".

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

### lockfreequeues variants

The in-tree queues are driven directly from the unified `BQueue` (bounded)
and `Queue` (unbounded) generics. Each topology is benchmarked from the
matching family-named smart constructor.

| Slug family                       | Topology      | Constructor               | Kind      |
|-----------------------------------|---------------|---------------------------|-----------|
| `lockfreequeues_spsc`           | SPSC          | `newSpscQueue`          | bounded   |
| `lockfreequeues_spmc`           | SPMC (MPMC slug grid) | `newSpmcQueue`  | bounded   |
| `lockfreequeues_mpsc`           | MPSC          | `newMpscQueue`          | bounded   |
| `lockfreequeues_mpmc`           | MPMC          | `newMpmcQueue`          | bounded   |
| `lockfreequeues_unbounded_spsc` | SPSC          | `newUnboundedSpscQueue` | unbounded |
| `lockfreequeues_unbounded_spmc` | SPMC          | `newUnboundedSpmcQueue` | unbounded |
| `lockfreequeues_unbounded_mpsc` | MPSC          | `newUnboundedMpscQueue` | unbounded |
| `lockfreequeues_unbounded_mpmc` | MPMC          | `newUnboundedMpmcQueue` | unbounded |

A `lockfreequeues_queue_bounded_*` parity slug is emitted alongside each
bounded family — it drives the same `BQueue` generic and exists only to
guard the unification against per-shape throughput regressions.

### Cross-library comparison set

The comparison adapters (`benchmarks/nim/adapters/`) plot third-party
queues on the same Bencher dashboard. All adapters are gated behind
`-d:adapter_<library_slug>_available`; absent gates produce no symbol
references and the production builds are unchanged. The set below was
expanded for the v5.0.0 benchmark suite so every topology has multiple
distinct external libraries.

| Library                | Lang | Variant(s) benchmarked                                  | Topologies covered          |
|------------------------|------|--------------------------------------------------------|-----------------------------|
| MoodyCamel             | C++  | `ConcurrentQueue`                                       | unbounded MPMC              |
| Boost.LockFree         | C++  | `boost::lockfree::queue`, `boost::lockfree::spsc_queue` | bounded MPMC, bounded SPSC  |
| atomic_queue           | C++  | `AtomicQueueB`                                          | bounded SPSC + bounded MPMC |
| rigtorp SPSCQueue      | C++  | `rigtorp::SPSCQueue`                                    | bounded SPSC                |
| rigtorp MPMCQueue      | C++  | `rigtorp::mpmc::Queue`                                  | bounded MPMC                |
| crossbeam              | Rust | `crossbeam_queue::ArrayQueue`, `crossbeam_queue::SegQueue` | bounded MPMC, unbounded MPMC |
| flume                  | Rust | bounded + unbounded channel                            | bounded MPMC + unbounded MPMC |
| kanal                  | Rust | bounded + unbounded channel                            | bounded SPSC + bounded MPMC + unbounded MPMC |
| liblfds (soft-skip)    | C    | `lfds711_queue_bss_*` (SPSC), `lfds711_queue_bmm_*` (MPMC) | bounded SPSC + bounded MPMC |
| Nim `system.Channel`   | Nim  | `system/channels.Channel` (blocking-on-full\*)         | MPSC + MPMC                 |
| nimble `threading`     | Nim  | `threading.Chan` (non-blocking try)                    | bounded MPMC                |
| Loony                  | Nim  | `LoonyQueue`                                            | unbounded MPMC              |

\* The `system.Channel` adapter blocks the producer on a full channel
instead of returning back-pressure, so its slugs are only loosely
comparable to the non-blocking adapters; the chart marks them with a
dotted bar and a `(blocking)` badge.

**liblfds is a soft-skip adapter.** The vendored subset
(`benchmarks/vendor/liblfds/`) carries the upstream C source and a C
wrapper, but **not** the `gcc_gnumake` Makefile that builds
`liblfds711.a`. The `bench-comparison.yml` install step is guarded by
`test -f .../Makefile` with `continue-on-error: true`, so on a checkout
that lacks the Makefile the liblfds adapter is simply omitted (a
`::warning title=Adapter skipped::` annotation is emitted) rather than
failing the workflow. CI environments that DO carry the full upstream
tree build the archive and exercise the adapter. The same soft-skip
pattern applies to every external adapter: install/build → smoke →
set-define, each `continue-on-error`, so a missing toolchain or library
drops that adapter's slugs instead of breaking the run.

Library upstreams and licenses, the per-adapter compile gates, and the
local run recipes are documented in
[`benchmarks/README.md`](https://github.com/elijahr/lockfreequeues/blob/devel/benchmarks/README.md);
per-library obligations are tracked in
[`THIRD_PARTY_LICENSES.md`](https://github.com/elijahr/lockfreequeues/blob/devel/THIRD_PARTY_LICENSES.md).

## Results

Results are generated per-platform. See the `benchmarks/results/` directory for JSON output.

### Live charts

The charts below pull from a snapshot published by the `bench` CI workflow on
every push to `devel` (see `.github/workflows/bench.yml`). The hero panel
shows lockfreequeues vs alternatives at a single representative bounded
shape; the per-topology panels below trace each library across the
producer/consumer shape grid (and pair bounded with unbounded variants where
the topology supports both). Each panel's legend toggles libraries on and
off; the Y axis defaults to log scale and is per-panel switchable to linear.
Hovering a shape shows mean ± stddev when the underlying measure carries
one, plus the topology context. Dotted bars and a `(blocking)` badge in the
legend mark libraries with blocking-on-full semantics — see the methodology
section below.

#### Headline: lockfreequeues vs alternatives

<div markdown="0">
  <div id="bench-status" class="bench-status" hidden></div>

  <div id="bench-hero" class="bench-panel bench-panel-hero">
    <noscript>
      Charts require JavaScript. The raw data is published at
      <code>../assets/bench-results/latest.json</code>; download the JSON
      snapshot if you need to consume it programmatically.
    </noscript>
  </div>
</div>

#### Throughput by topology

<div markdown="0">
  <div id="bench-throughput-spsc"           class="bench-panel"></div>
  <div id="bench-throughput-mpsc"           class="bench-panel"></div>
  <div id="bench-throughput-mpmc-bounded"   class="bench-panel"></div>
  <div id="bench-throughput-mpmc-unbounded" class="bench-panel"></div>
</div>

#### Latency

<div markdown="0">
  <div id="bench-latency" class="bench-panel"></div>

  <script src="../assets/uplot-1.6.27.iife.min.js"></script>
  <script src="../assets/bench-charts.js"></script>
</div>

### Methodology and fairness caveats

All numbers below are produced on GitHub-hosted `ubuntu-latest` runners (4 vCPU
implicit, x86_64). Do not infer absolute latency or throughput suitability for
production hardware from these numbers — use them only for relative comparison
between queue implementations under identical conditions.

Specific caveats:

- **Cache-line padding asymmetry.** Some libraries (lockfreequeues, MoodyCamel,
  Boost.LockFree, atomic_queue, rigtorp) pad their head/tail/sequence fields to
  64 bytes; others may not. The lockfreequeues MPMC types were padding-audited
  during the queue unification.
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
  non-blocking `try_push` path that the lockfree queues use. These are
  rendered with a dotted bar/line and carry an asterisk on the throughput-
  panel legends and a `(blocking)` badge on the hero legend.
- **Producer/consumer thread placement.** No explicit pinning. The runner's
  scheduler is the ground truth for thread placement.
- **CPU oversubscription.** `ubuntu-latest` has 4 vCPU. MPMC variants beyond
  4P + 4C measure scheduler oversubscription, not lock-free contention.
