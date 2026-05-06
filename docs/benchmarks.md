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

See the [Glossary](#glossary) below for definitions of P×C, BMF, SPMC, sipmuc,
oversubscription, and other shorthand used throughout this page.

## Glossary

The bench page uses a small vocabulary repeatedly. Definitions are inlined
here so readers don't have to hop between this page and the source tree to
decode an axis label or a slug.

### BMF

Bencher Metric Format. The JSON shape produced by harness runs and merged
by `merge_bmf.py` into `latest.json`. One slug per benchmark configuration.

### P×C

Producers × Consumers. Categorical configuration label, e.g. `4p4c`. The
number of producer threads × the number of consumer threads. P×C is
categorical, not continuous; charts must use bars, not lines, because there's
no meaningful interpolation between e.g. `2p2c` and `4p4c`.

### Sipsic

Single-In-Place (single producer, single consumer; the lockfreequeues SPSC
family). Bounded and unbounded variants both exist.

### Sipmuc

Single-In-Place Multi-Consumer (single producer, multiple consumers; the
lockfreequeues SPMC family). Promoted from the MPMC panel to its own SPMC
panel in v4.2.0.

### Mupsic

Multi-Producer Single-Consumer (multiple producers, single consumer; the
lockfreequeues MPSC family).

### Mupmuc

Multi-Producer Multi-Consumer (multiple producers, multiple consumers; the
lockfreequeues MPMC family).

### SPSC

Single Producer, Single Consumer. The simplest topology — one writer, one
reader. Admits wait-free algorithms with no atomic read-modify-write on the
hot path.

### MPSC

Multi Producer, Single Consumer. Many writers fan into one reader. Producers
contend on the enqueue index; the consumer side is uncontended.

### SPMC

Single Producer, Multi Consumer. One writer fans out to many readers.
Consumers contend on the dequeue index; the producer side is uncontended.

### MPMC

Multi Producer, Multi Consumer. The hardest topology: contention on both
ends, plus the need to coordinate a globally-consistent committed prefix
across asymmetric producer and consumer claim orders.

### Bounded

Fixed capacity ring buffer; pushes can fail when the queue is full. Returns a
non-blocking signal rather than parking the producer.

### Unbounded

Capacity grows on demand (typically segmented and reclaimed via DEBRA);
pushes do not fail for capacity reasons. Pays a small per-pop reclamation
overhead in exchange.

### Oversubscription

Running more producer + consumer threads than the runner has physical cores.
Stresses scheduler interaction with queue backoff. The `ubuntu-latest` runner
has 4 vCPU, so any P×C totalling more than 8 threads measures the scheduler
as much as the queue.

### Strict-FIFO claim

Consumer-side ordering invariant where each consumer must observe the next
sequence index `prevConsumerIdx + 1`. Cannot skip slots reserved by
descheduled producers, leading to head-of-line stalls under oversubscription.
This is the root cause of the unbounded mupmuc/sipmuc stalls v4.2.0's
harness backoff works around.

### Work-stealing

Algorithmic property where consumers can claim from any producer's
queue/slot, bypassing strict FIFO. Tolerates oversubscription gracefully.
moodycamel, loony, and crossbeam's segmented queues all use this property.

### SchedYield-escalating backoff

Adaptive backoff that starts with `cpuPause` spin, escalates to `Thread.yield()`
/ `sched_yield(2)` after a spin budget, then to longer sleeps. Lets the OS
reschedule the descheduled producer holding a reserved-but-uncommitted slot.
v4.2.0 introduces this in the harness; the canonical queue-side fix lives in
v4.3.

### DEBRA

Distributed Epoch-Based Reclamation Algorithm. Memory reclamation scheme used
by lockfreequeues for unbounded queues. v4.2.0 ships with `nim-debra` 0.7.1.

### Epoch-based reclamation

Memory reclamation strategy where freed memory is held until all threads have
advanced past a global epoch counter. Avoids ABA hazards without per-pointer
hazard tracking overhead. DEBRA is one such scheme.

### Bench harness

The Nim test programs in `benchmarks/nim/` that drive the queue under
controlled load and emit BMF JSON. Distinct from the queue itself; harness
changes can move chart numbers without any queue source change.

### Queue

The data structure being benchmarked, in `src/lockfreequeues/`. The queue
source is read-only for v4.2.0 — performance numbers move only via harness
or comparison-library changes.

### Smoke compile

Quick `nim c --compileOnly` step in CI used to verify a bench adapter builds
before its full bench run is scheduled. Fails fast on missing deps.

### Soft-skip matrix step

CI matrix step that exits 0 with a warning when a comparison library is
unavailable, rather than failing the whole bench job. Lets the chart show
degraded data without breaking master.

### `latest.json`

The merged, canonical BMF document consumed by `bench-charts.js` to render
the page. Single source of truth for what the chart shows.

### `--path:src`

Nim compiler flag adding a path to the import search list. Defensive addition
to all comparison-library smokes in v4.2.0 to keep package-relative imports
resolving regardless of nimble install state.

### Slug

BMF identifier of shape `<library>/<topology>/<P×C>`, e.g.
`lockfreequeues/spmc_unbounded/1p8c`. Validated by `SLUG_RE` in
`merge_bmf.py`.

### Project

Distinct top-level adapter target. One of the named entries (lockfreequeues,
moodycamel, atomic_queue, flume, etc.). Distinct from "slug prefix" (a
project may produce multiple slug prefixes via family fanout) and from
"library" (used loosely; prefer "project" when the count matters).

### Slug prefix

First segment of a slug, e.g. `lockfreequeues_sipmuc`. The `lockfreequeues`
project produces 8 slug prefixes (sipsic / sipmuc / mupsic / mupmuc ×
bounded / unbounded). External libraries typically produce 1 slug prefix
each but may produce more (e.g., flume bounded vs unbounded).

### Topology axis

The categorical axis splitting throughput panels by topology (SPSC, MPSC,
SPMC, MPMC, plus unbounded variants). v4.2.0 adds SPMC as a first-class
entry; sipmuc was previously rendered on MPMC panels.

### P×C shape

The set of (producers, consumers) pairs run for a given library × topology
combination. Determines bar count per panel.

### Hero panel

The top-of-page summary panel showing headline numbers across libraries at a
single representative bounded shape. Distinct from the per-topology
throughput grid below.

### Throughput panel

One panel per topology in the grid. Bars per library × P×C configuration.
v4.2.0 splits SPMC out of MPMC, taking the panel count from 4 to 5.

### Dark-mode reflow

Chart redraw triggered by Material theme toggle, picking up new
`--md-default-fg-color` value via `getComputedStyle` and re-applying to uPlot
axis stroke and font. Without reflow, axis labels render black against a
dark background.

## Why MPMC is harder than SPSC

The bench numbers diverge by orders of magnitude across topology axes — SPSC
reliably lands in the tens of millions of ops/sec on `ubuntu-latest` while
MPMC under contention sits one to two orders of magnitude lower. Three
distinct cost centers explain the gap.

### Cache-line contention

MPMC's multiple producers contend for the same enqueue index cache line, and
multiple consumers contend for the same dequeue index cache line. Every CAS
or fetch-add on those indices forces a coherence round trip across cores;
under heavy contention the bus traffic dominates the algorithm. False
sharing amplifies the cost when adjacent fields share a cache line.

SPSC has exactly one writer per index — the producer owns the head, the
consumer owns the tail — so the cache lines never bounce. The hot path
becomes a plain load/store with appropriate memory ordering, no atomic
read-modify-write needed.

### ABA and reclamation

Multi-consumer dequeue must defend against the ABA problem: a consumer reads
a node pointer, the value at that pointer is freed and reallocated, and the
consumer's CAS now succeeds against a stale identity. Lock-free MPMC designs
solve this with hazard pointers, epoch-based reclamation (lockfreequeues
uses DEBRA), or other safe-memory-reclamation (SMR) schemes. Each adds
per-operation bookkeeping the consumer pays on every pop.

SPSC needs neither. The single consumer can free or recycle slots without
coordinating with peers, and the single producer's writes are sequenced with
the consumer's reads via a simple acquire/release pair on the index.

### Ordering and asymmetry

MPMC's claim/publish protocol is intrinsically asymmetric. Producers reserve
an index (claim) and then publish their payload (commit) in arbitrary order
— producer A may claim slot 10 and stall before committing while producer B
claims slot 11 and commits immediately. Consumers must observe a
globally-consistent committed prefix, which means slot 11's payload is
unreadable until slot 10 commits even though slot 11's data is already in
memory. Vyukov's sequence-counter protocol encodes this prefix with
per-slot generation tags; other designs use linked segments with per-segment
commit fences.

SPSC has total ordering for free. The producer publishes in slot order,
the consumer reads in slot order, and an acquire/release pair on a single
index is sufficient. There is no claim/publish asymmetry to coordinate
because there's only one of each role.

## When to pick lockfreequeues

If your bottleneck is **single-producer single-consumer with a known capacity**
— an audio callback handing buffers to a render thread, a GPU command queue,
a network read loop feeding a worker — `Sipsic` is wait-free on both sides
and clears around 7,600 ops/ms at `1p1c` on `ubuntu-latest`. There's no
adapter for `system/Channel` at SPSC so the fixture has no head-to-head
number, but the wait-free progress guarantee alone usually settles it.

If your bottleneck is **multi-producer multi-consumer at high contention** —
a job scheduler with dozens of producer goroutines, an event collector
funneling from many sources — `Mupmuc` is the right call. At `4p4c` it
sustains around 18,200 ops/ms in the fixture, against 1,720 ops/ms for
`system/Channel` at the same shape — roughly 10.6x faster. The MPSC variant
`Mupsic` shows a similar gap (about 3.7x at `4p1c`) when only the producer
side fans out.

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
  variants will measure higher. The fixture shows unbounded `Mupmuc` at
  about 9,860 ops/ms at `1p1c` versus bounded `Mupmuc` at about 24,070
  ops/ms — a real gap, and the cost of "never blocks on full".

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
  <div id="bench-throughput-spmc"           class="bench-panel"></div>
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
  non-blocking `try_push` path that the lockfree queues use. These are
  rendered with a dotted bar/line and carry an asterisk on the throughput-
  panel legends and a `(blocking)` badge on the hero legend.
- **Producer/consumer thread placement.** No explicit pinning. The runner's
  scheduler is the ground truth for thread placement.
- **CPU oversubscription.** `ubuntu-latest` has 4 vCPU. MPMC variants beyond
  4P + 4C measure scheduler oversubscription, not lock-free contention.

### Threshold history

Bencher.dev threshold history for the `lockfreequeues_*sipmuc/mpmc*` slug
roots was intentionally reset starting v4.2.0, because sipmuc moved from the
MPMC topology axis to a first-class SPMC axis. The old slug history is
retained on Bencher.dev as a record of pre-v4.2.0 behaviour but is not
aliased forward into the new `lockfreequeues_*sipmuc/spmc*` slug roots —
threshold-based regression detection on the SPMC slugs starts fresh.
