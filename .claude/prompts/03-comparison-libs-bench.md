# Item 1 — Comparison-libraries bench matrix

**Tier:** LARGE / likely COMPLEX (FFI plumbing pushes the upper bound). Design doc REQUIRED before any adapter code.

**Source:** `~/lockfreequeues-bench-comparison-followups.md` Item 1 (lines 67-202).

**This is a multi-PR effort.** Suggested PR sequence: A (design doc) → B (refactor) → C (pure-Nim) → D (C++ FFI) → E (Rust FFI) → F (graphs, see Item 2).

## Goal

Extend `bench_throughput.nim` to benchmark lockfreequeues against several other queue/channel implementations across SPSC/MPSC/MPMC × bounded/unbounded topologies. Outcome is a defensible apples-to-apples performance comparison usable in the README and gated by Bencher.

## Libraries to compare (priority order)

| # | Library | Language | Topologies |
|---|---|---|---|
| 1 | stdlib `Channels` (`std/channels`) | Nim | MPMC bounded |
| 2 | `system/threading/Channel` | Nim | MPSC bounded |
| 3 | `Threading.Channels` (nimble) | Nim | MPMC bounded |
| 4 | Loony queue | Nim | MPMC unbounded |
| 5 | `boost::lockfree::queue` + `spsc_queue` | C++ FFI | MPMC bounded, SPSC bounded |
| 6 | `crossbeam-queue` (Rust) | Rust FFI | MPMC bounded, MPMC unbounded |
| 7 | `moodycamel::ConcurrentQueue` | C++ FFI | MPMC unbounded |

Existing adapter: `benchmarks/nim/adapters/channels_adapter.nim` (item 1 already wrapped).

## Topology / bench split decision

Today `bench_throughput.nim` mixes variants in one binary. With 7+ libraries × 3 topology classes × bounded/unbounded, that explodes. Two options:

a. **Multiple bench binaries** (`bench_spsc.nim`, `bench_mpsc.nim`, `bench_mpmc.nim`). Cleanest separation. CI invokes sequentially with separate Bencher uploads keyed by measure name.
b. **One binary, finer CLI filtering**. Faster to build, harder to time-budget per-topology.

Lean (a). Design doc must justify.

For each topology: SPSC 1P/1C; MPSC 1P/1C, 2P/1C, 4P/1C; MPMC 1P/1C, 2P/2C, 4P/4C.

## FFI plumbing (the hard part)

- **Rust (crossbeam):** tiny `bench-ffi-crossbeam` Cargo crate exposing `extern "C"` constructors / push / pop / drop. Build in CI via `dtolnay/rust-toolchain@stable` + `cargo build --release`, link statically. Do NOT vendor prebuilt binaries.
- **C++ (boost, moodycamel):** moodycamel is header-only; boost.lockfree is also header-only. Thin C wrapper exposing the same push/pop/drop ABI. Build via `nim cpp --passC:-Iboost/include`. Use `apt-get install libboost-dev` on the runner.
- **Adapter shape:** each library gets one file under `benchmarks/nim/adapters/` mirroring the existing pattern (`init`, `deinit`, producer/consumer thread procs, run proc).

Design doc must decide:
1. FFI builds in workflow (yes) vs vendored (no — supply chain).
2. Pinned versions of each external dep with cryptographic hashes where supported.
3. CI behavior on FFI build failure: soft-skip with annotation (lean) vs hard-fail.

## Methodology / fairness (the most important section of the design doc)

Defensible apples-to-apples means:
- Same message type and size across all variants. Default 8-byte payload (`int`); document choice.
- Same total message count; per-variant warmup; warmup-tainted runs excluded.
- Same producer/consumer thread placement (no pinning today; document).
- Same CI runner shape — `ubuntu-latest`, 4 vCPUs, x86_64. Note in README; results don't generalize to high-core or ARM.
- Unbounded variants: pre-allocate same expected total memory envelope.
- Bounded variants: same capacity (e.g., 1024); pin it.
- Channels (Nim stdlib) is bounded — only compare against unbounded queues on shapes where channels won't block. Note blocking-vs-non-blocking semantics in README.

Design doc should explicitly enumerate fairness assumptions and each one's caveat.

## Bencher integration

Each new measure (e.g., `throughput_spsc`, `throughput_mpsc`, `throughput_mpmc`) is a separate Bencher Measure so PR comparison comments don't conflate topology classes. Configure thresholds per measure once historical baselines accumulate. Don't gate on absolute numbers yet — only on % regression vs immediate ancestor.

## Out of scope for v1

- Latency benchmarks (parallel scope, see Item 4 / `.claude/prompts/02-latency-bench.md`).
- Multi-architecture matrix (just `ubuntu-latest` x86_64).
- Multiple Nim compiler versions (just `stable`).
- Hardware-perf-counter integration (`perf stat`).
- Stress-test integration in CI.

## Suggested PR structure (do NOT bundle B-F)

1. **PR A:** design doc only. Get sign-off on fairness methodology + FFI build approach before any adapter code.
2. **PR B:** topology-split refactor of `bench_throughput.nim` → multiple binaries (or finer CLI filtering, per design doc decision). All existing variants still benched. No new adapters.
3. **PR C:** pure-Nim adapters (Loony, Threading.Channels, system Channel).
4. **PR D:** C++ FFI adapters (boost.lockfree, moodycamel). Includes CI toolchain install steps.
5. **PR E:** Rust FFI adapter (crossbeam). Includes Cargo crate and CI Rust toolchain install.
6. **PR F:** README integration with interactive graphs (Item 2 / `.claude/prompts/04-interactive-graphs.md`).

## Critical pre-work flag

Item 2's "two-pipeline mess" decision affects this work — the Item 1 design doc must resolve which README-rendering pipeline is canonical (cloud vs local). See `.claude/prompts/04-interactive-graphs.md`.

## Kickoff prompt

```
/develop

Extend the bench harness with comparison libraries per
~/lockfreequeues-bench-comparison-followups.md Item 1. See
.claude/prompts/03-comparison-libs-bench.md for the full breakdown.

LARGE / COMPLEX tier. Design doc must cover:
(a) topology split strategy (multi-binary vs CLI filtering)
(b) FFI build approach for C++ and Rust (CI build, version pinning,
    failure handling)
(c) fairness methodology (enumerate every assumption with caveat)
(d) Bencher measure naming and threshold strategy
(e) resolution of Item 2's two-pipeline mess (cloud vs local README)

Do NOT implement adapters until the design doc is approved. Plan as a
6-PR sequence (A: design, B: refactor, C: pure-Nim, D: C++ FFI,
E: Rust FFI, F: README graphs). Do NOT bundle.
```
