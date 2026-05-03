# Item 4 — Latency benchmarks

**Tier:** STANDARD. Design doc required (histogram strategy, percentile reporting, Bencher measure shape).

**Source:** `~/lockfreequeues-bench-comparison-followups.md` Item 4 (lines 413-441).

**Parallel scope:** independent of Item 1 (comparison libs). Can land in either order.

## Goal

Per-message round-trip or push-to-pop latency, measured at multiple percentiles (p50, p95, p99, p999, max). Reported as a separate Bencher measure (e.g., `latency_spsc_p99`) so PR comparisons don't conflate latency with throughput.

## Starting point

`benchmarks/nim/bench_latency.nim` exists in the repo as a skeleton. It was not extended during PR #14 because throughput was the priority for gating Item 3b.

## Methodology constraints

- One producer pushes a timestamped message; one consumer pops and records `now - timestamp`.
- Pre-allocate the histogram (HdrHistogram-style log buckets) so the measurement itself doesn't allocate. Look for an existing Nim HdrHistogram impl or write a minimal one.
- Run for a **fixed message count**, not a fixed wall-clock — wall-clock budgets bias percentiles.
- Same fairness rules as the throughput harness: same message type, same capacity, same warmup.

## Out of scope (defer)

- Multi-producer latency. Define-only-after p50/p99 are stable for SPSC.
- Cross-NUMA latency. Same reason as Item 1's multi-arch matrix deferral.

## Bencher integration

- New measure name(s) per topology + percentile. Suggested: `latency_<topology>_<percentile>` (e.g., `latency_spsc_p99`).
- Don't gate PRs on absolute latency yet — only on % regression vs immediate ancestor commit. Same threshold strategy as throughput.

## Kickoff prompt

```
/develop

Build out the latency bench harness per ~/lockfreequeues-bench-comparison-followups.md
Item 4. See .claude/prompts/02-latency-bench.md for context.

The skeleton is at benchmarks/nim/bench_latency.nim. Mirror the throughput
harness pattern from PR #14. STANDARD tier; design doc must cover:
(a) histogram strategy (HdrHistogram-style log buckets, pre-allocated)
(b) percentile reporting (p50/p95/p99/p999/max)
(c) Bencher measure naming and threshold strategy
(d) fixed-message-count vs fixed-wall-clock decision
```
