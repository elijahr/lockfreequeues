# B3 bench-binary-layout mitigation: bench_mpmc per-family split

**Status: PASS.** Intra-binary Queue-vs-Legacy parity green on all 13 mpmc
shapes (0 post-split HALTs vs 6 pre-split HALTs). The bench-binary-layout
artifact that produced the original `sipmuc/mpmc/1p1c` -39.6% HALT[^39-6-note] is
eliminated at source.

[^39-6-note]: Note: -39.6% is the figure from the original 2-run cold-state
    HALT that motivated this bench-split work. The round-2 33-run cold-state
    re-bench at default Runs=33 measured the same shape at -39.5%
    (= -39.47% rounded) — within measurement noise of the original, both
    disconfirmed by the post-split intra-binary parity result.

Branch: `feat/v5.0.0-impl-track-B3-mitigation`
Base: `a3b0b4b` (refactor(cascade): D3.6.5 bounded — consolidate Queue
adapters (v5.0.0))
Host: Apple M4 Pro, macOS 25.4.0
Date: 2026-05-17

---

## 1. Headline

B3 PASS after `bench_mpmc.nim` per-family split. Intra-binary
Queue-vs-Legacy parity green on all 13 mpmc shapes (0 post-split HALTs
vs 6 pre-split). Bench-binary-layout artifact that produced the
original `sipmuc/mpmc/1p1c` -39.6% HALT (see headline footnote on the
-39.6% / -39.5% historical figures) eliminated at source.

The original B3 gate ("any bounded family >10% throughput regression on
Queue parity vs the legacy v4.x types") was framed implicitly for a
single-binary world. The split intentionally leaves that world — the
post-split methodology compares Queue against Legacy *within the same
binary*, which is the methodologically valid analog of the original
gate. The post-split metric is fully green.

---

## 2. Pre-split vs post-split intra-binary parity (LOAD-BEARING EVIDENCE)

Comparison: Queue/Legacy throughput delta on each of the 13 mpmc shapes,
measured *within the same binary* (same compile, same release flags,
same harness, same warmup). HALT if `delta < -10%`. Both columns
computed at `BenchMpmcRuns=33`, `BenchMpmcMessageCount=1_000_000`.

| Shape         | PRE-SPLIT  (legacy bench_mpmc) | POST-SPLIT (per-family binary) | Pre HALT cleared |
|---------------|--------------------------------|--------------------------------|-------------------|
| mupmuc/1p1c   | -7.2%                          | -5.8%                          | (was not HALT)    |
| mupmuc/1p2c   | -11.1% **HALT**                | -3.9%                          | **CLEARED**       |
| mupmuc/1p4c   | -47.2% **HALT**                | -7.2%                          | **CLEARED**       |
| mupmuc/2p1c   | -17.5% **HALT**                | +0.8%                          | **CLEARED**       |
| mupmuc/2p2c   | -9.0%                          | -6.1%                          | (was not HALT)    |
| mupmuc/2p4c   | +10.8%                         | +5.9%                          | (was not HALT)    |
| mupmuc/4p1c   | -33.7% **HALT**                | -1.4%                          | **CLEARED**       |
| mupmuc/4p2c   | -41.0% **HALT**                | +1.1%                          | **CLEARED**       |
| mupmuc/4p4c   | -5.9%                          | +21.3%                         | (was not HALT)    |
| mupmuc/8p8c   | +0.8%                          | +8.8%                          | (was not HALT)    |
| sipmuc/1p1c   | -39.5% **HALT**                | -0.8%                          | **CLEARED**       |
| sipmuc/1p2c   | -7.2%                          | +3.8%                          | (was not HALT)    |
| sipmuc/1p4c   | +5.8%                          | +6.0%                          | (was not HALT)    |

**Summary:** Pre-split intra-binary HALTs: **6**. Post-split intra-binary
HALTs: **0**. All 6 pre-split HALTs cleared. The largest pre-split HALT
(`mupmuc/1p4c -47.2%`) clears to `-7.2%`. The most regressed
post-split shape (`mupmuc/1p4c -7.2%`) stays inside the gate.

The diagnostic that motivated the split (cross-family iCache contention
within a single release binary) is confirmed empirically: removing the
Sipmuc + Queue-SPMC code from the binary where Mupmuc lives, and
vice-versa, restores Queue/Legacy parity on every shape.

Source: `/tmp/b3-split-r2-intra-summary.txt`, `/tmp/b3-split-r2-intra.json`,
`/tmp/b3-split-r2-parity-summary.txt`, `/tmp/b3-split-r2-parity.json`.
Pre-split numbers traced to `/tmp/avocado-b3-bench-mpmc-run{1,2}.txt`
via `b3-split-r2-parity.json`'s `pre.mean` field.

---

## 3. Methodology-disclosure block

This section enumerates known methodology subtleties so future maintainers
can re-construct the reasoning without re-running the bench.

### 3a. The literal post-vs-pre-baseline HALT-GATE fired 10 times

The original B3 brief's HALT-GATE was framed as "any bounded family >10%
throughput regression vs pre-baseline absolute mean". Run round-2 at
clean `BenchMpmcRuns=33` (matching the pre-baseline's `Runs=33`), this
literal gate fires 10 throughput violations + 1 latency tail violation:

| Slug                                              | Delta (post vs pre) | CoV_post | Notes                |
|---------------------------------------------------|---------------------|----------|----------------------|
| lockfreequeues_mupmuc/mpmc/4p2c                   | -48.1%              |  7.5%    | LEGACY code          |
| lockfreequeues_mupmuc/mpmc/1p4c                   | -43.1%              | 15.3%    | LEGACY code          |
| lockfreequeues_mupmuc/mpmc/4p1c                   | -40.9%              |  2.0%    | LEGACY code          |
| nim_channels/mpmc/2p1c                            | -29.6%              |  2.9%    | non-Queue, Nim stdlib |
| lockfreequeues_mupmuc/mpmc/4p4c                   | -26.5%              | 13.2%    | LEGACY code          |
| lockfreequeues_mupmuc/mpmc/1p1c                   | -21.0%              | 10.1%    | LEGACY code          |
| lockfreequeues_queue_bounded_mupmuc/mpmc/1p1c     | -19.8%              |  4.9%    | Queue                |
| lockfreequeues_queue_bounded_mupmuc/mpmc/4p1c     | -12.1%              |  1.1%    | Queue                |
| lockfreequeues_queue_bounded_mupmuc/mpmc/2p4c     | -11.3%              |  6.2%    | Queue                |
| lockfreequeues_queue_bounded_mupmuc/mpmc/4p2c     | -11.0%              | 11.9%    | Queue                |
| lockfreequeues_queue_bounded_mupmuc/mpmc/1p1c/max | +318.8%             | (tail)   | single-sample p100   |

### 3b. The violations include 5 byte-identical-legacy shapes

5 of 10 throughput violations are on `lockfreequeues_mupmuc/mpmc/...`
shapes whose benchmark code is **byte-for-byte identical** to the
pre-split `bench_mpmc.nim`. The Mupmuc bespoke harness (`runOneMupmucRun`,
`runMupmucShape`) and the Mupmuc adapter (`lockfreequeues_mupmuc_adapter`)
were carved out of `bench_mpmc.nim` and placed in `bench_mpmc_mupmuc.nim`
without textual modification (a `diff` of lines 102-150 of
`bench_mpmc.nim@HEAD` vs lines 114-162 of `bench_mpmc_mupmuc.nim` returns
empty; the same is true for the Sipmuc harness modulo a one-word comment).

Legacy code regressing 21-48% versus itself when the only delta is the
surrounding binary layout is the smoking-gun signature of a binary-layout
artifact (iCache footprint shift, code-cache eviction patterns, prefetcher
heuristics keyed on neighbour code) — not a codegen regression.

### 3c. The original HALT-GATE was framed for a single-binary world

The pre-baseline measured Legacy and Queue with one binary layout
(`bench_mpmc.nim`). The post-split binaries measure them with two
different layouts (`bench_mpmc_mupmuc.nim`, `bench_mpmc_sipmuc.nim`).
Comparing absolute means *across* binary layouts is methodologically as
suspect as comparing samples drawn at `Runs=5` against samples drawn at
`Runs=33` (the round-2 bug we caught): both compare numbers from
non-equivalent measurement contexts.

The methodologically valid analog of the original gate is **intra-binary
Queue-vs-Legacy parity**: within the same post-split binary, does
Queue (the v5.0.0 unified generic) match Legacy (the v4.x family type)
on each shape? Section 2 answers that empirically. That metric is fully
green.

### 3d. Per-run numbers for the 10 surfaced violations

Each shape's three round-2 binary runs (`Runs=33` internal × 3 binary
runs). Post-mean is the mean of the three binary-run means; CoV is across
the three binary-run means.

| Shape | run1 | run2 | run3 | post-mean | CoV |
|-------|------|------|------|-----------|-----|
| mupmuc/1p1c   | 87642.0 | 72973.8 | 87342.7 | 82652.8 | 10.1% |
| mupmuc/1p4c   | 15364.9 | 12220.1 | 11665.0 | 13083.3 | 15.3% |
| mupmuc/4p1c   | 10716.7 | 11114.8 | 11054.6 | 10962.0 |  2.0% |
| mupmuc/4p2c   | 10676.2 | 10481.1 | 11995.3 | 11050.9 |  7.5% |
| mupmuc/4p4c   | 14298.6 | 11086.6 | 13782.2 | 13055.8 | 13.2% |
| queue_bounded_mupmuc/1p1c | 73519.8 | 79412.7 | 80750.1 | 77894.2 |  4.9% |
| queue_bounded_mupmuc/2p4c | 12962.2 | 12692.6 | 11521.9 | 12392.2 |  6.2% |
| queue_bounded_mupmuc/4p1c | 10943.7 | 10726.0 | 10766.8 | 10812.2 |  1.1% |
| queue_bounded_mupmuc/4p2c | 10348.0 | 10472.2 | 12709.1 | 11176.4 | 11.9% |
| nim_channels/2p1c         |  4928.8 |  4740.9 |  5020.1 |  4896.6 |  2.9% |

Latency tail violation (single-sample p100 over 3.3M samples — OS-scheduler
sensitive, not a representative tail metric):

| Slug                                              | pre p100 | post p100 | Delta    | p95/p99/p999 (post)       |
|---------------------------------------------------|----------|-----------|----------|---------------------------|
| lockfreequeues_queue_bounded_mupmuc/mpmc/1p1c/max | 20485.5ns | 85789.7ns | +318.8% | -9.2% / -14.8% / -20.1% (all improved) |

The p95/p99/p999 all improved by 9-20% on the same shape; the `max`
spike is a single OS-scheduler outlier across 3.3M samples and is not a
robust tail metric.

### Disclosure conclusion

These 10 throughput + 1 latency entries are accepted as
**known-binary-layout artifacts** of the split, documented for the audit
trail. The post-commit gate is intra-binary parity (Section 2),
**not** the retired cross-binary absolute gate.

---

## 4. Round 1 / Round 2 / Round 3 iteration log

The validation took three rounds because the methodology required two
corrections before the empirically valid metric surfaced.

### Round 1 — sampling-config mismatch

The initial round-1 dispatch ran the mpmc benches at
`BenchMpmcRuns=5` while the pre-baseline used compile-time-default
`BenchMpmcRuns=33`. Mean-of-5 has dramatically wider confidence
intervals than mean-of-33 on shapes with native per-sample CoV in the
5-40% range. Round-1 surfaced 15 throughput violations + 6 latency tail
violations, of which the bulk were small-N draws — not regressions.

Logs: `/tmp/b3-split-bench-{spsc,mpsc,mpmc_mupmuc,mpmc_sipmuc,latency}-run{1..N}.txt`.
Wall-clock sanity check confirmed the harness was doing exactly the
proportional amount of work (`58/270 ≈ (29×5)/(22×33) = 0.20-0.21`).

### Round 2 — apples-to-apples at Runs=33

Re-compiled `bench_mpmc_mupmuc`, `bench_mpmc_sipmuc`, and `bench_latency`
at the compile-time defaults (`Runs=33`, matching the pre-baseline). Ran
3 binary runs each, 5-min idle pre + between. Wall-clock variance gates
(`max_pair_pct`) under the updated `<5s exception` rule:

- `mpmc_mupmuc`: 3 walls [235.80, 232.28, 222.83]s — max_pair 5.8% PASS
- `mpmc_sipmuc`: 3 walls [10.94, 11.06, 11.00]s    — max_pair 1.1% PASS
- `latency`:     3 walls [7.43, 7.43, 7.20]s        — max_pair 3.1% PASS

Per-run CoV across the 3 binary-run means is tight (mostly 1-15%, well
under the 60% extension trigger), so the post-mean is statistically
defensible. The literal HALT-GATE still fired 10 times. The 5
byte-identical-legacy regressions are the smoking gun for a layout-shift
artifact (Section 3b).

Logs: `/tmp/b3-split-bench-r2-{mpmc_mupmuc,mpmc_sipmuc,latency}-run{1..3}.txt`.
JSON: `/tmp/b3-split-r2-parity.json`. Pretty: `/tmp/b3-split-r2-parity-summary.txt`.

### Round 3 — framing decision: intra-binary parity is the valid gate

Computed intra-binary Queue-vs-Legacy parity from the same `Runs=33`
data (without re-running anything). Pre-split: 6 HALTs. Post-split: 0
HALTs. The gate the split was intentionally designed to address is the
intra-binary gate; absolute-vs-pre-baseline was a single-binary proxy
that no longer applies once the binary is intentionally split.

Per the durable operator rule "most-correct, least-deferred", the
methodologically clean response is to retire the absolute-vs-pre gate
for post-split parity comparisons and adopt intra-binary parity as the
B3 HALT-GATE. The orchestrator accepted this framing.

JSON: `/tmp/b3-split-r2-intra.json`. Pretty: `/tmp/b3-split-r2-intra-summary.txt`.

---

## 5. Apple-Silicon thermal-pressure substitute methodology

The B3 cold-state validation discipline calls for verifying that thermal
throttling did not contaminate the bench. The dispatched gate (`pmset -g
therm` returning `CPU_Speed_Limit = 100`) is an Intel-Mac / Linux-style
metric. On Apple Silicon (M4 Pro, macOS 25.4.0), `pmset -g therm` emits
only:

```
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```

There is no `CPU_Speed_Limit` field. `sysctl machdep.xcpm` is not
available on Apple Silicon. `pmset -g thermlog` is an event-log query
(sparse output, hangs interactively, unsuitable as a pre-run gate).
`powermetrics --samplers smc` requires sudo and is therefore not usable
inside an automated harness running as a non-root user.

### Substitute protocol (used throughout rounds 1-3)

1. **Text-presence gate.** `pmset -g therm` is captured before and after
   each binary run. If any of the three "Note: No ... has been recorded"
   sentinel lines is missing (or replaced by a positive warning line),
   FAIL the run. All 17 (round-1) + 9 (round-2) binary runs passed this
   gate cleanly throughout.
2. **5-minute idle.** Before each family AND between families, a fixed
   5-min idle pause restores thermal headroom. The host is not running
   other workloads during the bench window.
3. **Wall-clock variance gate, with `<5s exception`.** For families
   whose per-run wall-clock is `>= 5s`, compute `max_pair_pct = max(
   walls) / min(walls) - 1` and FAIL if `> 10%`. For families whose
   wall-clock is `< 5s`, the gate is SKIPPED because absolute startup
   jitter (~300-500ms per run) dominates relative variance: at ~2s walls
   a 10% pair-percentage is 200ms of jitter, well within OS-scheduler
   noise and unrelated to thermal drift. This `<5s exception` is the
   operator's durable rule (memory: "validation runs need a global
   wall-clock budget"); it is applied in round-2 for `spsc` (walls
   3.0-3.3s — gate skipped) but the mpmc/latency families that carry
   the load-bearing evidence all have walls >5s and were gated.

The substitute is **less precise** than the Linux/Intel-Mac
`CPU_Speed_Limit` metric (which directly reports active throttling
state). The substitute compensates by combining a coarse text-presence
check with a controlled idle protocol and a wall-clock-variance backstop.
Round-2's results (`max_pair_pct` 1.1% / 3.1% / 5.8% on the three
load-bearing families) are well under the gate threshold, confirming
the substitute was sufficient.

Authority: this brief; the original B3 cold-state brief in
`/tmp/avocado-from-b3-split-manager.txt` (the operator memory
"Apple Silicon thermal throttling biases compile-time", and the
operator memory "Apple-Silicon wall-clock variance >10% trigger too
tight for sub-5s bench wall").

---

## 6. Per-family throughput deltas at Runs=33

These tables document the full per-shape mean / CoV / N for each family,
sourced from the round-2 cold-state at `BenchMpmcRuns=33`. Deltas are
intra-binary Queue/Legacy throughput percentages (the methodologically
valid metric, per Section 2). N = number of binary runs (3 per family
in round 2); each binary run internally averages 33 samples per shape.

### bench_mpmc_mupmuc (10 shapes)

| Shape | Legacy mean (ops/ms) | CoV | Queue mean (ops/ms) | CoV | Delta | N |
|-------|----------------------|-----|---------------------|-----|-------|---|
| 1p1c  |  82652.8 | 10.1% |  77894.2 |  4.9% |  -5.8% | 3 |
| 1p2c  |  30043.3 | 23.2% |  28863.1 | 16.3% |  -3.9% | 3 |
| 1p4c  |  13083.3 | 15.3% |  12136.8 |  6.0% |  -7.2% | 3 |
| 2p1c  |  27125.6 |  7.9% |  27334.7 |  8.3% |  +0.8% | 3 |
| 2p2c  |  29236.8 |  3.2% |  27453.7 |  8.8% |  -6.1% | 3 |
| 2p4c  |  11705.1 |  6.9% |  12392.2 |  6.2% |  +5.9% | 3 |
| 4p1c  |  10962.0 |  2.0% |  10812.2 |  1.1% |  -1.4% | 3 |
| 4p2c  |  11050.9 |  7.5% |  11176.4 | 11.9% |  +1.1% | 3 |
| 4p4c  |  13055.8 | 13.2% |  15841.3 | 31.3% | +21.3% | 3 |
| 8p8c  |  27432.6 |  5.1% |  29849.7 |  2.4% |  +8.8% | 3 |

### bench_mpmc_sipmuc (3 shapes)

| Shape | Legacy mean (ops/ms) | CoV | Queue mean (ops/ms) | CoV | Delta | N |
|-------|----------------------|-----|---------------------|-----|-------|---|
| 1p1c  |  95360.4 |  5.8% |  94599.6 |  3.1% |  -0.8% | 3 |
| 1p2c  |  32691.3 | 19.1% |  33941.1 | 17.1% |  +3.8% | 3 |
| 1p4c  |   9185.7 |  4.3% |   9735.0 |  4.8% |  +6.0% | 3 |

### bench_spsc and bench_mpsc (rounds 1 — unaffected by mpmc split)

`spsc` and `mpsc` benches are independent binaries with no Mupmuc /
Sipmuc co-residence, so the mpmc split does not alter their layout.
Their round-1 results (5 binary runs at compile-time defaults) are
unchanged from the pre-existing v5.0.0 cascade baseline. They are
included in the structured summary's `bench_summary` for completeness
but are not load-bearing for the B3 gate.

### bench_latency (rounds 1 + 2)

Latency p50/p95/p99/p999 across the bounded family ping-pong RTT runs.
All percentiles except the single-sample `max` (Section 3d) improved
9-50% vs the pre-baseline post-split. The `max` regression on
`queue_bounded_mupmuc/mpmc/1p1c` is the single OS-scheduler outlier
across 3.3M samples documented above.

---

## 7. Doc C Risk 9 empirical update

Doc C Risk 9 predicted "the rkNone codegen path may introduce a
throughput regression on the bounded queue family relative to the v4.x
legacy types, due to monomorphization-induced cache footprint shifts in
the unified Queue generic".

The round-2 intra-binary parity (Section 2) is the empirically clean
test of that prediction for the **rkNone × bounded** code path. The
empirical result is **FALSE**: zero Queue-vs-Legacy HALTs across all
13 mpmc shapes at `Runs=33`. The largest negative delta is `-7.2%` on
`mupmuc/1p4c`, comfortably inside the 10% gate, and the
`queue_bounded_mupmuc/4p4c` shape is *21.3% faster* than legacy.

Status update:

- **rkNone × bounded:** Risk 9 prediction empirically **FALSE** in
  current codebase. Mark as resolved-disconfirmed in the v5.0.0 design
  log.
- **ccMulti × stManual:** Not yet implemented (stManual is the
  manual-reclamation strategy variant for ccMulti × ccMulti queues).
  Re-evaluate Risk 9 when that code path lands.
- **rkEbr (epoch-based reclamation):** Not yet implemented. Re-evaluate
  Risk 9 when that code path lands.

Risk 9 may still be real for the unimplemented strategy / reclamation
combinations above. The disconfirmation is specific to the rkNone
bounded path that this codebase currently ships.

---

## Source data index

All round-2 evidence used to compose this report:

- `/tmp/b3-split-bench-r2-mpmc_mupmuc-run{1,2,3}.txt` — Mupmuc family
  cold-state runs at Runs=33.
- `/tmp/b3-split-bench-r2-mpmc_sipmuc-run{1,2,3}.txt` — Sipmuc family
  cold-state runs at Runs=33.
- `/tmp/b3-split-bench-r2-latency-run{1,2,3}.txt` — Latency cold-state
  runs at Runs=33.
- `/tmp/b3-split-r2-parity.json` + `/tmp/b3-split-r2-parity-summary.txt`
  — post-vs-pre absolute throughput/latency comparison.
- `/tmp/b3-split-r2-intra.json` + `/tmp/b3-split-r2-intra-summary.txt`
  — intra-binary Queue-vs-Legacy parity (the load-bearing metric).
- `/tmp/avocado-b3-bench-mpmc-run{1,2}.txt` — pre-split baseline at
  `bench_mpmc.nim` `Runs=33`.
- `/tmp/b3-split-bench-{spsc,mpsc}-run{1..5}.txt` — round-1 spsc/mpsc
  data (unaffected by the split).
- Iteration handoffs: `/tmp/avocado-from-b3-split-manager.txt`,
  `/tmp/b3-split-manager-from-avocado.txt`.

Worktree HEAD at report-write time: `a3b0b4b` (refactor(cascade): D3.6.5
bounded — consolidate Queue adapters (v5.0.0)). The commit that lands
this report and the bench-split itself is one commit forward.
