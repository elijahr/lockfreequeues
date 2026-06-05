# lockfreequeues — agent notes

Onboarding notes for AI coding harnesses working in this repository. The README is the user-facing entry point; this file is the operational reference for harnesses that need to understand the algorithms, invariants, build/test surface, and the gotchas that are not obvious from reading the code in isolation.

If you are reading this for the first time, scan §1–§6 to orient, then jump to whatever section matches the task at hand.

---

## 1. What this library is

Lock-free queue implementations for Nim, covering all eight cells of the
(bounded vs unbounded) × (SPSC, SPMC, MPSC, MPMC) grid through two
generic types:

- `BQueue[T, ccProd, ccCons, N, P, C]` — bounded ring buffer, no
  reclamation needed (slots are reused in place under Vyukov per-slot
  sequence counters).
- `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` — unbounded linked
  segments, reclaimed via DEBRA epoch-based reclamation
  (`nim-debra >= 0.10.0`). The `(ccSingle, ccSingle)` arm is
  DEBRA-free.

`ccProd` / `ccCons` are `ccSingle` / `ccMulti`. Cardinality-illegal
direct-on-queue calls are blocked at compile time with `{.error.}`
overloads that point callers at the correct producer/consumer endpoint
API.

Family-named smart constructors (`newSpscQueue`, `newUnboundedMpmcQueue`,
etc.) wrap the two generics for ergonomic continuity.

---

## 2. Project structure

```
src/lockfreequeues.nim                  # umbrella import
src/lockfreequeues/
    queue.nim                           # Queue[T, ccProd, ccCons, ST, S, MaxThreads]
    bqueue.nim                          # BQueue[T, ccProd, ccCons, N, P, C]
    endpoint.nim, endpoint_types.nim    # Producer/Consumer endpoint types
    strategy.nim                        # stManual / stEager (deallocation)
    reclamation.nim                     # rkNone / rkEbr (kept for compat)
    role_tags.nim                       # ccSingle / ccMulti / phantom tags
    backoff.nim                         # backoffOnRetry / backoffOnPeerWait
    exceptions.nim                      # DebraRegistrationError, others
    spawn.nim                           # thread-spawn helpers (debug only)
    typestates.nim                      # local re-export of internal DSL
    typestates/                         # per-arm typestate verbs (push/pop)
        slot_seq_n.nim                  #   Vyukov sequence-counter ladder (BQueue)
        mpmc_cell.nim                   #   BQueue MPMC cell
        spsc_push.nim ... mpmc_pop.nim  #   verb files (eight)
        cas.nim                         #   CAS DSL
        atomic_loaders.nim              #   loader DSL
        fullness_checks.nim             #   shared full/empty predicates
        storage_n.nim, storage_n1.nim   #   slot storage prefixes
        virtual_values_n.nim, …n1.nim   #   index abstractions
    internal/
        aligned_alloc.nim               # cacheline-aligned heap helpers
        shared.nim                      # NoSlice, helpers used by both surfaces
        pinscope_stub.nim               # DEBRA-free PinScope no-op
        typestates_dsl.nim              # shim re-exporting upstream typestate DSL

tests/                                  # 88 .nim files, single-driver test.nim
    test.nim                            # umbrella importer (run via `nimble test`)
    should_fail/                        # compile-fail negative controls (runner.nim)
    fixtures/                           # shared test data
    t_lcrq_*.nim                        # Phase B / strict-LCRQ unit + race tests
    t_queue_bounded_*.nim               # BQueue per-arm tests + threaded variants
    t_unbounded_*.nim                   # Queue per-arm tests + threaded variants
    t_bench_*.nim                       # bench-harness self-tests (separate task)

benchmarks/                             # bench harness + per-binary drivers
    nim/bench_*.nim                     # one binary per topology family
    merge_bmf.py                        # unions per-binary BMF JSON into latest.json
    results/                            # tracked JSON outputs

examples/                               # runnable usage examples (also in CI)
docs/                                   # mkdocs site (guide/, design/, api/)
.github/workflows/build.yml             # CI matrix (lint + 6-cell test matrix)
nim.cfg                                 # platform-specific DWCAS flags
config.nims                             # nimble.paths include
lockfreequeues.nimble                   # tasks: test, examples, benchmarks, …
```

---

## 3. Build, test, and run

The package uses standard `nimble` tasks. Useful incantations:

| Task | Command | What it does |
|------|---------|--------------|
| Compile-fail controls | `nimble should_fail` | Runs `tests/should_fail/runner.nim` only |
| Full test suite | `nimble test` | should_fail + 5 MM lanes (C orc/arc/refc, C++ orc, atomicArc TSAN, ASAN) |
| Examples | `nimble examples` | Compiles + runs all `examples/*.nim` |
| Benchmarks | `nimble benchmarks` | Compiles + runs 9 bench binaries, merges BMF JSON |
| Bench-harness self-tests | `nimble benchtests` | `t_bench_*.nim` (excluded from `test.nim`) |
| Bench backoff toggle | `nimble benchToggleSmoke` | Smoke-test `LFQ_BENCH_HARNESS_BACKOFF` env toggle |

### 3.1 Run a single test file

`tests/test.nim` is an umbrella importer. To iterate on one file:

```sh
nim c --threads:on -r -f tests/t_lcrq_pop_race.nim
```

Add `--mm:arc` / `--mm:atomicArc` / `--cc:clang --passC:"-fsanitize=thread"`
etc. to match a CI lane.

### 3.2 Skip TSAN or ASAN in a local run

```sh
SANITIZE_THREADS=no SANITIZE_ADDRESS=no nimble test
```

Both default to "yes" in `nimble test`.

### 3.3 Output directory

`nim.cfg` sets `--outdir:".tmp"`. All compiled binaries land in `.tmp/`
(gitignored). Bench JSONs land in `benchmarks/results/`.

### 3.4 Pre-commit hooks

`.pre-commit-config.yaml` runs:

- standard hygiene (large-file, merge-conflict, YAML, EOF, trailing
  whitespace, mixed line endings, shebangs, case conflicts);
- `nph` — Nim formatter, **modifies files in place**;
- `nimble check` — package metadata validation.

**Operational consequence:** `nph` reformats your stage on commit. When
the hook reports `nph ... Failed` with `files were modified by this
hook`, **re-stage and retry**. Do not pass `--no-verify` to bypass — the
formatter changes are project-canonical. The retry-after-nph pattern
arises every few commits when you write code that doesn't already match
`nph` output; it is normal and not an error.

---

## 4. Architecture

### 4.1 Two generic surfaces

`BQueue[T, ccProd, ccCons, N, P, C]` — bounded ring buffer.

- `N` — capacity (slots).
- `P`, `C` — producer / consumer cardinality counts (typestate-tracked).
- Uses **Vyukov per-slot sequence counters** for cross-thread visibility
  of slot ownership (the v4.0.0 BREAKING change). Stale-generation
  claims are rejected by the sequence ladder, not detectable via a
  `committed: bool` flag.
- No reclamation, no DEBRA, no segments.
- Slot type: `MPMCCellPayload` (or analogue per arm) carrying a
  `SlotSeqN`. Field offsets are asserted via `static: offsetOf(…)` so
  the typestate Base types' unsafe casts stay sound across
  instantiations.

`Queue[T, ccProd, ccCons, ST, S, MaxThreads]` — unbounded linked
segments.

- `ST` — `stManual` / `stEager` deallocation strategy.
- `S` — segment size (cells per segment, power of two).
- `MaxThreads` — DEBRA participant ceiling (registers thread slots; the
  `(ccSingle, ccSingle)` arm still requires a positive value but does
  not consume slots).
- Segments form a linked list; head and tail advance through the chain.
- Reclamation: DEBRA epoch-based; consumers `pin` a scope while
  touching segment state, retire segments via `retireOnCAS` /
  `retireOnPublish` on advance.

### 4.2 Cardinality dispatch

Both surfaces use `when (ccProd, ccCons) is …` ladders inside their
push/pop bodies. The four arms are SPSC, MPSC, SPMC, MPMC. The
multi-side direct-on-queue overloads emit compile-time `{.error.}`
messages pointing the caller at the endpoint API
(`queue.getProducer().push(item)` /
`queue.getConsumer().pop()`).

### 4.3 Cross-import rule

`bqueue.nim` MUST NOT `import ./queue`, and vice versa. Shared helpers
route through `./internal/shared.nim`. Anything added to
`internal/shared` is available to both surfaces. Breaking this rule
defeats the surface split and reintroduces compile-time coupling that
the v5.0.0 reshape explicitly removed.

### 4.4 Endpoints

`QueueProducer` / `QueueConsumer` / `BQueueProducer` / `BQueueConsumer`
are typestate-tracked endpoint handles. Construction uses
`queue.getProducer()` / `.getConsumer()` (or the auto-registering
no-arg overloads under the `Auto`-* constructors). Endpoints own the
per-thread DEBRA registration on the unbounded family; destructors call
`unregisterThread` so the slot is reusable.

### 4.5 Auto-create vs explicit-manager constructors

Unbounded MP/SP variants expose two constructor styles:

- **Explicit-manager**: `newUnboundedMpmcQueue[...](addr manager)` —
  caller owns the `DebraManager` and may share it across queues.
- **Auto-create**: `newUnboundedMupmuc[S, T, MaxThreads](strategy)` —
  the queue heap-allocates a private manager, owned via
  `ownsManager: true`. `=destroy` tears down segments then the
  manager.

`DebraManager.clientCount` (a v4.1.0 addition) catches early-destruction
bugs: each queue constructor calls `bindClient` and `=destroy` calls
`unbindClient`. A shared manager destroyed before its queues asserts
out.

### 4.6 Strict-LCRQ (Phase B, v5.0.0)

Unbounded MPMC's `pop` / `push` uses **strict-LCRQ cells** with
double-word CAS (DWCAS) via `nim-debra >= 0.10.0`. The cell carries
`Pair[uint, T]` (seq, value) atomically. See §7.4 for the invariants
this introduced.

---

## 5. Algorithms and references

| Component | Algorithm | Source |
|-----------|-----------|--------|
| BQueue, all arms | Vyukov bounded MPMC (per-slot sequence counters) | Vyukov, 1024cores blog, 2010 |
| Queue SPSC arm | Michael & Scott baseline + linked-segment slab | MS 1996, plus committed-flag-free fast path |
| Queue MPSC arm | DEBRA-pinned MS-queue derivative | Brown 2015 (DEBRA) + MS 1996 |
| Queue SPMC arm | DEBRA-pinned MS-queue derivative | Brown 2015 + MS 1996 |
| Queue MPMC arm | **Strict-LCRQ** with DWCAS cell publish/claim | Morrison & Afek, *Fast Concurrent Queues for x86 Processors*, PPoPP 2013 (LCRQ §4 close-CAS-on-empty progress) |
| Memory reclamation | **DEBRA** (Distributed Epoch-Based Reclamation) | Brown, *Reclaiming Memory for Lock-Free Data Structures*, PODC 2015 |
| Cell DWCAS | `Atomic[Pair[A, B]]` with `validCasFailureOrder` | `nim-debra/atomics`, derived from C11 |

`docs/migration.md` and the `## References` section of `README.md` have
the long-form citations.

---

## 6. Concurrency model

### 6.1 Cardinalities and thread binding

`ccSingle` arms (producer or consumer) presume **at most one** thread
on that side. `ccMulti` arms presume any number. The typestate ladder
in `slot_seq_n.nim` enforces ownership transitions, not threading per
se — but the underlying algorithms rely on the cardinality being
honoured. Violating it (two threads producing on a `ccSingle` producer)
defeats the correctness argument; that case is what the endpoint
typestate forbids at compile time.

### 6.2 DEBRA thread registration

Unbounded MP/MP/SP variants require a `ThreadHandle[MaxThreads, CC]`
per participating thread. Acquired through:

- explicit: `manager.registerThread(...)` then
  `queue.getProducer(handle)` / `getConsumer(handle)`;
- auto-registering: `queue.getProducer()` / `getConsumer()` no-arg
  overloads call `registerThread` internally;
- auto-managing: the `Auto*` constructors that own the manager.

A handle consumes one of `MaxThreads` slots until the endpoint is
destroyed (`unregisterThread`). Threads using **multiple queues with a
shared manager** must prefer the explicit-handle overloads — using
auto-register on N queues consumes N slots per thread.

### 6.3 Bind-to-thread debug assertions

In `-d:debug` builds, `push` and `pop` assert
`self.attachedTid == getThreadId()` to catch the
"forgot which thread owns this endpoint" footgun. Release builds skip
the check.

---

## 7. Critical invariants and footgun callouts

Algorithmic invariants the type system cannot express. Read this
section before touching anything in `queue.nim`'s push or pop bodies.

### 7.1 Defense placement follows commit placement

When a typestate verb's correctness depends on snapshotted state, the
defense against TOCTOU drift between snapshot and commit goes
**immediately before the irreversible commit**, not at the snapshot
site and not after the commit. The commit is the moment the snapshot's
staleness becomes load-bearing. Defending earlier wastes work on
snapshots that were never used; defending after is too late — the
commit has already been observed by other actors and cannot be
unwound.

The two unbounded TOCTOU fixes in v4.3 illustrate this with mirrored
physical placement. In SPMC pop (`bb50bc9`), the irreversible commit is
the facade's CAS that advances `headSegment` past `oldSeg` (multi-
consumer coordination requires the CAS to live outside the verb to
keep the verb pipeline single-CAS-free). The defense — re-acquire-load
`consumerHead` and abort if items remain unclaimed — lives at the
facade, immediately before that CAS, in `unbounded_spmc.nim`'s
`USPMCPopReady` arm. In SPSC/MPSC pop (`7296240`), the irreversible
commit is the plain `headSegment.store` inside `advanceSegment`
(single-consumer; no coordination required, so the commit stays
verb-internal). The defense — F1' — re-loads `seg.tail` between
`next.load(moAcquire)` and the `headSegment.store`, and aborts the
advance if `freshTail > head`. Same principle, different physical
placement; both defenses sit at their respective commit points, not
before, not after.

For any future typestate work where commit-point defense is needed,
the heuristic is: locate the irreversible state transition (whether it
is a CAS, a plain release-store, or a multi-step facade-coordinated
advance), then place the defense immediately before that transition.
If you cannot articulate where the commit lives — in the verb, in the
facade, in a coordinated CAS — you do not yet understand the topology
well enough to add a defense; the placement question will surface bugs
before the defense is needed. Note that this means the defense can
widen the verb's return contract (e.g., F1' makes `Ready` either
"advance happened" or "retry on same segment"); when that happens,
callers need a disambiguator (e.g., facade comparing `headSegment`
before and after `advanceSegment`). Document the widened contract at
the call site so it does not decay (see `unbounded_spsc.nim` and
`unbounded_mpsc.nim` comparison-site comments per `12eb259`).

### 7.2 Typestate state-name U-prefix rule

State names in the eight `typestates/unbounded_*_{push,pop}.nim` files
use a `U`-prefix to avoid registry collisions with the bounded-graph
names, with one exception: SPSC PUSH (`unbounded_spsc_push.nim`)
leaves its states UN-prefixed because the SPSC push state graph has
no bounded counterpart to collide with. SPSC POP and the other six
files are U-prefixed. The rule is per state-graph, not per
concurrency variant — see commit body of `3d96020` for the
migration-time discovery.

### 7.3 BQueue: Vyukov sequence-counter discipline

`SlotSeqN` is the per-slot generation counter. Producers and consumers
each advance the counter by `2 * N` per round-trip; readers / writers
use the parity to detect "is this slot ready for me or for the other
side?" Direct `committed: bool` flags were removed in v4.0.0 because
they allowed a confirmed cross-generation duplicate-claim race
(TSAN-confirmed 100% repro, ~5% release-mode duplicate delivery under
contention). The new protocol is in `t_slot_seq_n.nim` /
`t_slot_seq_generation_rollover.nim`.

### 7.4 Strict-LCRQ MPMC: CR-1 and CR-2 (v5.0.0 cycle-4 fixes)

The unbounded MPMC pop fast-path has two non-obvious invariants from
the Phase B post-merge cycle:

- **CR-1 — `waitForPublish` is bounded.** The wait for a stalled
  producer is capped by
  `LockFreeQueuesMaxWaitForPublishSpins` (intdefine, default 1024).
  Budget exhaustion drives `tryCloseOnEmpty` on the consumer's reserved
  cell, surrendering the slot and falling through to the slow-path
  skip. Defends LCRQ §4 lock-free progress against producers that won
  the tail-CAS but never publish.

- **CR-2 — §5.3 CLOSED detection falls through to slow-path.** When
  fast-path `tryClaim` fails and the cell is observed CLOSED, the
  consumer does NOT retire the segment immediately. Instead it
  increments `closesSeenThisSegment` and continues, retiring only when
  the count reaches `S` (starvation threshold) or the scan walks off
  the end with no publishable cells. **Invariant change**:
  `prevConsumerIdx` now advances on **both successful claims AND
  skipped-closed cells** (previously claim-count-only). Reading code
  that assumes `prevConsumerIdx == claim_count` must read
  `prevConsumerIdx == claim_count + close_count` within the segment.

- **`closesSeenThisSegment` is fast-path-scoped.** The slow-path
  inline-skip scan uses a **local** counter (`localScanCloses`),
  because the slow path does not advance `prevConsumerIdx` between
  outer-loop iterations; re-entering the scan would re-observe the
  same CLOSED cells and double-count them, prematurely tripping the
  starvation threshold and orphaning publishable cells past `mySlot`.
  Fast-path closes feed the segment-wide counter; slow-path closes
  feed only the per-scan local counter.

- **Symmetric CLOSED escalation in `waitForPublish`.** After
  `tryCloseOnEmpty` succeeds on a stalled producer's cell, the
  consumer ALWAYS falls through to slow-path skip
  (`fellThroughOnClose = true`), regardless of `seg.next`. Earlier
  code split on `nextSeg == nil` and broke the outer loop in the nil
  case — that branch was a CR-2-shaped data-loss hazard (items
  published at indices > mySlot would be orphaned). Both successful-
  close paths in `waitForPublish` behave identically now.

### 7.5 Strict-LCRQ T-constraint

`Queue[T, ccMulti, ccMulti, ...]` requires
`supportsCopyMem(T) AND sizeof(T) <= sizeof(uint)` (8 bytes on 64-bit,
4 bytes on 32-bit). Wider T or non-trivially-copyable T is rejected at
compile time with a `{.error.}` overload that cites the migration
path (`BQueue[T]` for wider / move-only T). The check is in
`queue.nim` around the `tryPublish` static guard.

### 7.6 Nullable T in MPMC push

`tryPublish` `doAssert`s `not value.isNil` for any T where
`compiles(value.isNil)` — i.e., `ptr`, `ref`, `pointer`, `cstring`,
`proc`, closures. The check exists because `std/options.some(val)`
asserts `not val.isNil` at runtime for nullable types; forbidding nil
at the producer surfaces the contract violation there rather than as a
delayed `AssertionDefect` inside an unrelated consumer's `tryClaim`.
`doAssert` (not `assert`) so the guard survives `-d:danger`.

### 7.7 `ref T` rejected under arc / orc / atomicArc

Slots are shared across threads and stored in a plain `array[S, T]`,
so `=copy` / `=sink` hooks for `ref T` race on slot refcount mutation.
Compile-time `{.error.}` rejects `ref T` item types unless
`-d:allowNonLockFreeQueueItems` is passed. The standard mitigation is
to use a `ptr T` (caller owns lifetime) or a value type. Future
`ManagedRef[T]` work (v5.1.0 roadmap) will provide a managed-refcount
wrapper that integrates with EBR.

### 7.8 Atomics gate

All atomics route through `debra/atomics`, which statically rejects
`Atomic[T]` instantiations that would dispatch to libatomic spinlock
fallback (non-lock-free atomics). Opt out per call-site with
`-d:debraAllowNonLockFreeAtomics` (warning fires).

---

## 8. Memory ordering conventions

The codebase follows a few non-obvious patterns. When in doubt, read
the call site comment — every non-default ordering is annotated with
the synchronizes-with relationship it participates in.

- **`load(moAcquire)` pairs with `store(moRelease)`** on the same
  atomic location. Acquire-loads dominate the read side of
  publication; release-stores dominate the write side.
- **`moRelaxed` is used for counters and statistics** that are not
  load-bearing for synchronization (e.g., `itemCount.fetchSub`,
  `segments.fetchSub`). Never use relaxed for a load that the next
  control-flow decision depends on.
- **DWCAS in `tryPublish` / `tryClaim` / `tryCloseOnEmpty`** uses
  `dwcasOrderRelaxedCAS` from `debra/atomics`. The success order is
  `moRelease` (publisher) or `moAcquire` (consumer); failure order is
  always `moRelaxed`. The C11 `validCasFailureOrder` check enforces
  this at compile time via debra v0.10.0+.
- **The case-(b) inner spin** in `waitForPublish` re-loads the cell
  with `moAcquire` every iteration; this is the only place where we
  rely on a published cell becoming visible without an intervening
  release barrier on the same atomic, because the publishing
  `tryPublish` issues a release on the SAME cell.

---

## 9. Compile-time T constraints

| Surface | T constraint | Enforcement |
|---------|--------------|-------------|
| `BQueue[T, *, *, ...]` | `T` must not be `ref` (unless opted out) | `{.error.}` overload |
| `Queue[T, ccSingle, ccSingle, ...]` (SPSC) | `T` must not be `ref` | `{.error.}` overload |
| `Queue[T, ccMulti, *, ...]` and `Queue[T, *, ccMulti, ...]` non-MPMC | `T` must not be `ref` | `{.error.}` overload |
| `Queue[T, ccMulti, ccMulti, ...]` (MPMC) | `supportsCopyMem(T) AND sizeof(T) <= sizeof(uint)` | `static: when` guards in `push` |
| Opt-out | `-d:allowNonLockFreeQueueItems` | Disables ref-rejection (caller's risk) |

---

## 10. Compile-time tunables (intdefines)

| Name | Default | Affects | Notes |
|------|---------|---------|-------|
| `LockFreeQueuesAdvanceEvery` | 64 | DEBRA `advanceEvery` cadence in `rkEbr` Eager paths | Larger ⇒ fewer epoch advances ⇒ more retention |
| `LockFreeQueuesMaxWaitForPublishSpins` | 1024 | CR-1 bounded-spin budget for MPMC consumer waiting on stalled producer | Smaller ⇒ faster close-on-empty escalation ⇒ better tail latency under producer stalls; larger ⇒ better steady-state throughput |

Override at compile time with `-d:Name=Value`. Each has a `static:
assert Name > 0` guard.

---

## 11. Testing

### 11.1 Lanes

`nimble test` runs five MM lanes (plus `should_fail` as a preflight):

1. C, `--mm:orc` (default)
2. C++, `--mm:orc`
3. C, `--mm:arc`
4. C, `--mm:refc`
5. C, `--cc:clang --mm:atomicArc --passC:"-fsanitize=thread" --passL:"-fsanitize=thread"` (TSAN)
6. C, `--cc:clang --passC:"-fsanitize=address" --passL:"-fsanitize=address"` (ASAN)

Lanes 5 and 6 can be disabled with `SANITIZE_THREADS=no` /
`SANITIZE_ADDRESS=no`.

### 11.2 Compile-fail negative controls

`tests/should_fail/runner.nim` iterates a 5-case table and runs `nim c
--compileOnly` per case, asserting expected exit code + pinned
substring in stderr. New cases go under `tests/should_fail/` with
matching expected-error fixtures. The harness was ported from
nim-debra 0.8.0; the runner format is stable.

### 11.3 Targeted invocation

Match test scope to change scope. Running the full suite is slow
(several minutes for the matrix); for an iterating loop on one file:

```sh
nim c --threads:on -r -f tests/t_lcrq_pop_race.nim
nim c --cc:clang --mm:atomicArc --passC:"-fsanitize=thread" \
      --passL:"-fsanitize=thread" --threads:on -r -f tests/t_mpmc.nim
```

For repro tests on a known concurrency bug, prefer the
`t_*_critical_repros.nim` files — they are designed for deterministic
single-shot validation. The Phase B `t_lcrq_pop_critical_repros.nim`
is the model: each test sets up a precise cell state via direct
mutation, then runs a fixed sequence of `pop()` calls and asserts on
the resulting sequence.

### 11.4 Stress / race tests

`t_lcrq_pop_race.nim` and `t_lcrq_push_close_race.nim` push 100,000
items from 4 / 2 producers through the unbounded MPMC. Validation
checks the consumed count, the consumed sum (uses `Atomic[int64]` for
cross-platform safety), and rejects duplicates / drops. Consumer loops
break unconditionally when all producers report done; missing items
surface as clean assertion failures post-join rather than silent
hangs.

### 11.5 Bench-harness self-tests

`t_bench_*.nim` are NOT included in `tests/test.nim`. They live in
their own `nimble benchtests` task so the regular test matrix is free
of the bench harness's atomic dependencies. `nimble benchteststress`
opts into the gated 3.3M-sample p999 shape; slow (~10–15s release)
and not part of every CI run.

---

## 12. Benchmarks

`nimble benchmarks` compiles 9 release binaries (one per topology
family — `bench_spsc`, `bench_mpsc`, `bench_mpmc_bounded`,
`bench_spmc_bounded`, `bench_unbounded_{spsc,spmc,mpsc,mpmc}`,
`bench_latency`) and merges their per-binary Bencher Metric Format
JSON fragments into `benchmarks/results/latest.json` via
`merge_bmf.py`. Topology splits were introduced in v5.0.0 B3 to remove
cross-family iCache contention; merge collisions on `(slug, measure)`
keys exit non-zero.

`benchmarks/results/latest.json` is **tracked** because comparison
tooling (Bencher.dev) and reviewers may diff against it. Bench runs
locally produce noise from thermal throttling and runner state
(Apple Silicon throttles compile-time 4–5× under back-to-back runs);
trust **cold-state** measurements only (5-minute idle, thermal
pressure green) for meaningful wall-clock comparisons.

`LFQ_BENCH_HARNESS_BACKOFF=0` disables the backoff hint inside the
bench harness, useful for measuring no-backoff producer/consumer
behavior. `LFQ_STRESS_DURATION_SEC` raises the iteration budget on
threaded stress tests when run directly (not via `nimble test`).

---

## 13. Known issues

### 13.1 TSAN test-runner appears to hang after build succeeds

When invoking the TSAN-instrumented MM-MATRIX leg, e.g.

```
nim c --cc:clang --mm:atomicArc \
      --passC:"-fsanitize=thread" --passL:"-fsanitize=thread" \
      --threads:on -r tests/test.nim
```

the **build succeeds quickly** (the `Hint: ... [SuccessX]` line is
emitted and `.tmp/test` is produced), but the `-r`-driven exec phase
frequently appears to hang — the parent `nim` process sits in `S`
(sleep, 0% CPU) for many minutes without producing test output, then
never finishes. This has been observed repeatedly across sessions.

The hang is in the **runner**, not the test logic. The compiled binary
itself runs to completion (211 OK) in well under a second when invoked
directly.

#### Detection signal

You are in this state when:

- `Hint: ... .tmp/test [SuccessX]` has appeared in the output.
- `Hint: ... .tmp/test [Exec]` has *not* appeared (or appeared but no
  test output follows for >60 seconds).
- `ps -p <pid> -o stat,%cpu` shows the nim process in `S` (sleep)
  at 0% CPU.
- `.tmp/test` exists with a recent mtime.

#### Short-circuit

Treat the build as successful, kill the nim runner, and execute the
binary directly:

```
kill <nim-pid>
.tmp/test
```

Verify a clean `[Summary] 211 tests run (...): 211 OK, 0 FAILED, 0
SKIPPED` line appears. That output is the same data the `-r` runner
would have produced if it had not hung.

The same pattern (`build then exec the artifact directly`) also works
for focused TSAN×100 loops the v4.3 mitigation briefs prescribe —
build once with `-r` (or omit `-r`, equivalent), then loop the
produced `.tmp/<test>` binary in a shell `for` / `while` loop instead
of re-running `nim c -r` per iteration.

#### Why this matters operationally

Briefs that say "run the TSAN MM-MATRIX leg, expect 211 OK" can stall
an agent for 5+ minutes per attempt if the agent waits for `nim c -r`
to return. Detecting the hang early and pivoting to direct binary
invocation keeps the mitigation/verification loop tight without
losing TSAN coverage — the binary *is* TSAN-instrumented; only the
runner driver is misbehaving.

### 13.2 CI: nim-devel and macos-latest legs need 45-min timeout

The `build.yml` matrix runs nim-stable and nim-devel across
ubuntu-latest, ubuntu-24.04-arm, and macos-latest. The 25-minute
`timeout-minutes` budget was insufficient for the TSAN+ASAN passes on
macos-latest (both nim-stable and nim-devel) and on nim-devel x86_64
linux. The active config bumps those legs to 45 minutes. Adding new
matrix legs that exercise TSAN/ASAN should default to a 45-minute
budget; only `nim-stable / ubuntu-latest` consistently finishes
inside 25.

---

## 14. Platform requirements

### 14.1 ARM64 requires LSE atomics (ARMv8.1-A or newer)

`nim.cfg` passes `-march=armv8.1-a+lse` on gcc/clang for arm64 so
nim-debra's DWCAS is inlined rather than routed through libgcc
outline helpers. **Pre-ARMv8.1 hardware lacks LSE atomics** and will
fault with `SIGILL` at the first CAS. Affected hardware:

- Raspberry Pi 4 (Cortex-A72)
- Raspberry Pi 3 (Cortex-A53)
- Original Pixel C, Cortex-A57 boards
- Some older Snapdragon SoCs

Unaffected: Apple Silicon, AWS Graviton2/3/4, most ARM SoCs released
since 2019, ubuntu-24.04-arm runners. The CI matrix runs only on
supported hardware.

Users on older arm64 must either upgrade or pin to pre-v5.0.0
lockfreequeues + pre-0.10.0 nim-debra (no DWCAS requirement).

### 14.2 amd64 / x86_64 requires `-mcx16` for cmpxchg16b

Set in `nim.cfg` for gcc/clang on amd64. MSVC (`vcc`) is excluded
because it rejects `-mcx16` with D9002 and uses
`_InterlockedCompareExchange128` intrinsics directly.

### 14.3 macOS arm64 is unconditionally LSE-supported

The flag is harmless on Apple Silicon (always LSE-capable); the
nim.cfg conditional applies it anyway for consistency.

---

## 15. Repository hygiene

These rules govern what may and may not enter source-controlled
files — code comments, docstrings, prose docs, and commit messages.

### 15.1 No ephemeral process artifacts in tracked files

The following classes of content MUST NOT appear in tracked files
(source, docs, examples, tests, workflows):

- **Phase / Track / Bundle / Step markers.** Implementation-timeline
  identifiers like "Phase 3.3", "Track E", "Bundle F", "Step 3.3.9-D",
  "3.3.11-B", or any equivalent ad-hoc plan coordinate. These live in
  external plan documents and git history, not in shipped code.
- **Reviewer-feedback references.** Per-cycle flag identifiers
  (M-codes, F-codes, R-codes, "Gemini cycle N", "Momus r3 LOWs",
  "pepper flag-N", "lychee MED-N", "smart-ctor F-N", "BENCH-LOW-N",
  "CB-NNN", "arc-orc-NNN", "cascade-NNN"). The fix lives in the diff;
  the flag identifier dies with the review.
- **Temporary-state statements.** "Until X lands", "Once Y ships",
  "When Z completes", "(planned C1)". If a workaround is in place,
  describe the workaround in present tense without naming the future
  event that retires it. If the workaround DOES need retiring, file
  an issue or a TODO with no ephemeral coordinate.
- **Postmortem narration in code.** Reasoning about why an earlier
  attempt failed ("Wall 1 fix", "Wall 2 fix", "Wall 3 acceptance",
  "originally we tried X but it broke Y") belongs in the commit
  message or CHANGELOG, never in a checked-in comment.
- **AI attribution.** No `Co-Authored-By` trailers, no "Generated
  with Claude" footers, no bot signatures in commits, PR titles, PR
  descriptions, issue bodies, or comments.
- **GitHub issue numbers in commit messages, PR titles, or PR
  descriptions.** GitHub auto-links `#N` and notifies subscribers;
  reserve issue references for explicit human-curated cross-links.
- **Line-number / sha cross-references inside comments.** "Lifted
  from queue.nim L485-545 at HEAD 2ddca6a" is noise — line numbers
  shift, shas decay. If the lineage matters, the commit message has
  it. The reader looking at the code today gets nothing from a
  pointer to where it used to live.

### 15.2 What comments are FOR

Source comments and docstrings exist to explain code that is not
obvious from the code itself. Acceptable categories:

- FFI / ABI contracts (NIL sentinels, alignment requirements,
  memory-ownership protocols across language boundaries).
- Memory ordering / atomicity rationale (which load is acquire,
  which store is release, what synchronizes-with what).
- Algorithmic invariants the type system cannot express (Vyukov
  sequence-counter discipline, committed-flag publication, EBR
  epoch advancement rules, CR-1 / CR-2 / strict-LCRQ skip
  semantics).
- Footgun callouts at sites that LOOK safe but are not (use-after-
  destroy, ARC + `ref T` slot copy hazards, slow-path scope of
  `closesSeenThisSegment` vs `localScanCloses`).
- Non-obvious workarounds with the constraint that produces them
  ("must run before X because Y", stated in present tense without
  reference to when X will go away).

Comments that restate the code are noise. `# increment counter`
above `counter += 1` adds nothing; delete it.

### 15.3 Ephemeral docs do not get checked in

Implementation-phase audit trails — bench-delta postmortems, cascade
inventories, cross-doc re-gate reports, design rework deltas — do
not enter the tracked tree. The release-branch worktree is the right
home for them during development; the merge commit is where they
are dropped, not promoted to `docs/`.

The release-time documentation surface is:

- `README.md` — entry point.
- `docs/` (the mkdocs site, navigation defined in `mkdocs.yml`).
- `CHANGELOG.md` — versioned history.
- `AGENTS.md` — agent-facing operational notes (this file).
- `THIRD_PARTY_LICENSES.md`.

If a doc isn't reachable from one of those, it shouldn't be tracked.

---

## 16. Reviewer config

### PR Review Bot

- Bot username: `gemini-code-assist`
- Re-review comment: `/gemini review`
- Auto-reviews on PR creation: no — manual `/gemini review` comment
  required every cycle (including the first)
- Parallel bot: `axiomantic-momus` (fires automatically via
  `.github/workflows/momus.yml`)
- Gating priority: gemini gates the PR; momus is informational
  unless gemini is unavailable.

When the bot regurgitates findings already addressed in a previous
cycle's commit (verifiable via `git log` on the branch), do not
re-fix; the gemini bot has a tendency to re-issue stale advice. When
the bot raises a CRITICAL or HIGH severity on a known-fixed pattern,
verify against the actual source before re-doing work.

---

## 17. Phase B: strict-LCRQ migration on MPMC (v5.0.0)

Starting in v5.0.0, the unbounded `Queue[T, ccMulti, ccMulti, ...]`
uses strict-LCRQ cells via debra DWCAS. This narrows `T` to
`supportsCopyMem(T) AND sizeof(T) <= sizeof(uint)`. For wider T, use
`BQueue[T]` (bounded MPMC, Vyukov per-slot seq), which preserves
general T support including move-only types.

The migration was atomic across commits T0..T9 on
`feat/v5.0.0-strict-lcrq`. The T3..T7 range
(`77c7f20c..51f10b63`) contains partial-migration
`STRICT-LCRQ-PARTIAL` sentinels in source — use `git bisect skip` for
SHAs in that range. The green-gate commits are T8 (`33b8d49f`) and T9
(`cd8b27a1`); the `STRICT-LCRQ-PARTIAL` marker count is 0 at and
after T9. CHANGELOG.md v5.0.0 has the full migration notes (BREAKING
/ Added / Removed / Fixed / Dependencies / Platform requirements /
Bisect-notes) under the "Phase B: strict-LCRQ migration on unbounded
MPMC" subsection.

The cycle-4 through cycle-11 post-T16 gemini fixes landed several
correctness changes worth knowing when touching MPMC pop. See §7.4
for the consolidated invariant list. The cycle-by-cycle commit chain
is the canonical history; this file captures only the
forward-looking invariants.

---

## 18. Debugging tips

- **`-d:debug` enables bind-to-thread assertions** on push/pop. If a
  release binary works but a debug binary asserts on `attachedTid !=
  getThreadId()`, the calling thread is wrong, not the queue.
- **TSAN reports in `tryClaim` / `tryPublish`** are almost always
  false positives from the DWCAS used as a synchronizing operation;
  the underlying `debra/atomics` already validates the C11 ordering
  pair. If TSAN flags a NEW location after a code change, suspect
  the change first.
- **`STRICT-LCRQ-PARTIAL` markers in source** indicate intermediate
  Phase B commits (T3..T7) that do not pass the suite by design. If
  you see one in the current tree, you have an unreverted partial
  migration — git history should show the marker count is 0 at HEAD
  on `feat/v5.0.0-impl` and later.
- **Bisect across `feat/v5.0.0-strict-lcrq` T3..T7**: use
  `git bisect skip` for SHAs in that range (`77c7f20c..51f10b63`).
- **`closesSeenThisSegment` value during a hang** in unbounded MPMC
  pop suggests the slow-path inner scan is re-counting. Verify
  `localScanCloses` is the variable being incremented inside the
  inner scan loop and that the segment-wide counter is only touched
  in fast-path branches.
- **Producer reservation orphans** (consumer waiting forever on
  `case (b)` empty slot) are bounded by
  `LockFreeQueuesMaxWaitForPublishSpins`. If a test hangs past that
  budget × `backoffOnRetry` time, the close-on-empty escalation
  path is broken (suspect changes around `tryCloseOnEmpty` and the
  `fellThroughOnClose` arm).

---

## 19. Where to find more

- `README.md` — public surface, quick start, compatibility matrix,
  bibliography.
- `CHANGELOG.md` — versioned history including Phase B v5.0.0
  BREAKING / Added / Removed / Fixed / Dependencies / Platform
  requirements / Bisect notes.
- `docs/guide/core-concepts.md` — vocabulary, cardinality model,
  bounded vs unbounded.
- `docs/guide/safety-model.md` — what guarantees are provided and how
  they are enforced.
- `docs/guide/slot-ownership-typestates.md` — how the typestate
  ladder enforces single-writer / single-reader contracts on the
  bounded surface.
- `docs/guide/memory-management.md` — MM matrix, `ref T` rejection
  rationale, ptr-T and value-T patterns.
- `docs/guide/performance-tuning.md` — segment-size choice, backoff
  shape, intdefine knobs.
- `docs/migration.md` — v4.x → v5.0.0 migration table.
- `docs/design/v5-port-candidates-from-v4.3.md` — design notes for
  what made the v5.0.0 cut from the v4.3 backlog.
