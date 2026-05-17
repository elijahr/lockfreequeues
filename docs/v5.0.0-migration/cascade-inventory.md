# v5.0.0 cascade inventory (Task D1)

**Worktree:** `~/Development/worktrees/lfq-v5.0.0-wave/lockfreequeues-track-D-early/`
**Branch:** `feat/v5.0.0-impl-track-D-early`
**HEAD at inventory:** `b6da7f6` (devel base)
**Inventory date:** 2026-05-17

**Authoritative design doc:** `~/.local/spellbook/docs/Users-eek-Development-lockfreequeues/designs/design-strategy-cardinality-phantoms-v4.2-20260516.md` (Doc C)
**Impl plan:** `~/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-17-v5.0.0-queue-collapse-impl.md` (Track D1 §1067-1213)

---

## Summary

| Metric | Count |
|---|---|
| **Plan-coverage total (unique file:line)** | **477** |
| HALT-GATE status (vs ≤500 cap on plan-coverage) | **PASS** |
| Out-of-grep-scope additional sites | +39 (`stress-tests/`) +6 (`benchmarks/README.md`, `benchmarks/results/`) +17 (`CHANGELOG.md` intentional retention per Doc C §3.7) +12 (top-level `README.md`) +4 (`lockfreequeues.nimble` example invocations) |
| **Combined grand total** (informational only) | ~555 |

Total **migrating** sites in plan-defined scope: 477. UnboundedSipsic hits explicitly excluded (Doc C §3.0.3 carve-out).

### HALT-GATE evaluation

Per task brief: HALT if total > 500 sites. Per impl plan §D1 the inventory grep scope is `src/ tests/ examples/ benchmarks/ docs/`. That scope yields **477 ≤ 500 → PASS**.

**Escalation flag (non-halting):** `stress-tests/` (39 sites) and `benchmarks/README.md` + `benchmarks/results/` (6 sites) were not in the impl plan's grep methodology but contain real migration sites. Surface to `lfq-pepper` for scope confirmation. If pepper rules these IN to the migration scope, combined total becomes **516 sites → exceeds HALT-GATE** and D3 batches must be re-scoped.

---

## Method

### Greps executed (verbatim from impl plan §D1 Step 1, run inside worktree)

```bash
# (A) Typed bindings — Type[...] form
grep -rnE "\b(Mupsic|Sipmuc|Mupmuc|Sipsic|UnboundedMupsic|UnboundedSipmuc|UnboundedMupmuc)\[" \
    src/ tests/ examples/ benchmarks/ docs/

# (B) Constructor sites
grep -rnE "\b(initMupsic|initSipmuc|initMupmuc|initSipsic|newUnboundedMupsic|newUnboundedSipmuc|newUnboundedMupmuc)\b" \
    src/ tests/ examples/ benchmarks/ docs/

# (C) Module imports
grep -rnE "^import.*(mupsic|sipmuc|mupmuc|sipsic|unbounded_mupsic|unbounded_sipmuc|unbounded_mupmuc)" \
    src/ tests/ examples/ benchmarks/
```

Per-pattern raw hit counts:

| Bucket | Raw hits | Notes |
|---|---:|---|
| (A) typed bindings | 222 | `\b` boundary excludes `UnboundedSipsic[` from matching `Sipsic[` (verified — zero leak). |
| (B) constructors | 195 | No leak (no `init/newUnboundedSipsic` in the pattern set). |
| (C) imports | 65 | No leak (no `unbounded_sipsic` in the pattern set). |
| **Sum** | 482 | |
| **Unique file:line union** | **477** | A∪B∪C dedupe → 5 lines have both typed-binding and constructor on the same line. |

### Sweeps confirming UnboundedSipsic exclusion (R6 carve-out, Doc C §3.0.3)

| Sweep | Result |
|---|---|
| `\bUnboundedSipsic\[` hits in (A) raw output | 0 (regex `\bSipsic\[` correctly fails at the `d→S` non-boundary inside `UnboundedSipsic`) |
| `UnboundedSipsic` token anywhere in (A) | 0 |
| `unbounded_sipsic` token anywhere in (B) or (C) | 0 |

UnboundedSipsic is preserved end-to-end. `src/lockfreequeues/unbounded_sipsic.nim`, `tests/t_unbounded_sipsic*.nim`, `examples/?` (none reference it directly), `benchmarks/nim/adapters/lockfreequeues_unbounded_sipsic_adapter.nim`, `benchmarks/nim/tests/t_adapter_lockfreequeues_unbounded_sipsic.nim`, `docs/api/unbounded_sipsic.md` — all UNTOUCHED by this migration.

---

## Breakdown by category (return-contract format)

| Category | Sites | Source |
|---|---:|---|
| `typed_bindings` | 222 | grep (A), unique file:line |
| `constructors` | 195 | grep (B), unique file:line |
| `bench_adapters` (subset of typed+ctor, scope `benchmarks/nim/adapters/`) | 30 | grep (A∪B) filtered |
| `docs_api` (subset, scope `docs/api/`) | 13 | grep (A∪B) filtered |
| `examples` (subset, scope `examples/`) | 12 | grep (A∪B∪C) filtered |
| `benchmarks_readme_results` (top-level `benchmarks/README.md` + `benchmarks/results/`) | 6 prose mentions | secondary sweep (not in plan grep) — language-update only, not type-form migration |

The first two are exhaustive counts for the entire plan-coverage scope. The next four are **subset slices** of the same 477 unique sites, exposed because the task return contract calls them out individually. They are not additive.

---

## Per-cluster breakdown (file-ownership groups, plan-coverage scope)

### `src/lockfreequeues/` library source (130 sites total)

| File | Sites (A∪B∪C unique) | Disposition |
|---|---:|---|
| `mupsic.nim` | 20 | DELETE (Doc C §4 row 4) |
| `sipmuc.nim` | 20 | DELETE (row 5) |
| `mupmuc.nim` | 23 | DELETE (row 6) |
| `sipsic.nim` | 10 | DELETE (row 7) |
| `unbounded_mupsic.nim` | 17 | DELETE (row 8) |
| `unbounded_sipmuc.nim` | 17 | DELETE (row 9) |
| `unbounded_mupmuc.nim` | 18 | DELETE (row 10) |
| `unbounded_sipsic.nim` | 0 (excluded — C1 carve-out) | KEEP UNCHANGED (Doc C §3.0.3) |
| `lockfreequeues.nim` (umbrella) | 1 (import line) | MODIFY: replace 7 family imports with `[queue, strategy, reclamation, unbounded_sipsic]` (Track D3.1) |
| `typestates/` subdirectory | 9 | See typestates section below |

Net `src/` total: 130 (matches §D1 cluster pass).

### `src/lockfreequeues/typestates/` (9 sites — in-scope subset)

| File | Sites | Notes |
|---|---:|---|
| `unbounded_spmc_push.nim` | 6 | 6 in-scope per Doc C §3.6; references `UnboundedSipmuc[S,T,MT]`. Track E4 owns CC cascade. |
| `mpmc_push.nim` | 1 | Comment-only reference to `Mupmuc[N,P,C,T]` (line 51). |
| `mpsc_push.nim` | 1 | Comment-only reference to `Mupsic[N,P,T]` (line 54). |
| `spmc_push.nim` | 1 | Comment-only reference to `Sipmuc[N,C,T]` (line 57). |

The 6 in-scope `unbounded_{mpmc,mpsc,spmc}_{pop,push}.nim` files from Doc C §3.6 are partially captured here — only `unbounded_spmc_push.nim` has type-form hits via the grep. The other 5 may contain function-signature references not caught by the typed-binding regex; flag for Track E4 review.

### `tests/` (181 sites)

Top per-file counts (unique-line, A∪B∪C):

| File | Sites |
|---|---:|
| `t_unbounded_mupmuc.nim` | 18 |
| `t_unbounded_sipmuc.nim` | 17 |
| `t_unbounded_mupsic.nim` | 17 |
| `t_unbounded_auto_create.nim` | 11 |
| `t_stress.nim` | 12 |
| `t_mupsic.nim` | 7 |
| `t_sipmuc.nim` | 7 |
| `t_mupmuc.nim` | 7 |
| `t_unbounded_*_threaded.nim` (3 files) | ~6 each |
| `t_sipsic.nim`, `t_sipsic_threaded.nim`, `t_mupsic_threaded.nim`, `t_sipmuc_threaded.nim`, `t_mupmuc_threaded.nim`, etc. | balance |

Tests untouched (UnboundedSipsic): `t_unbounded_sipsic.nim`, `t_unbounded_sipsic_threaded.nim`, `t_unbounded_sipsic_lockfree_check.nim`, `t_unbounded_sipsic_lockfree_types.nim` — verified zero hits.

Track B2 (bounded test migration) + Track E3 (unbounded test migration) own these. Track E4 owns the 6 unbounded typestate test files.

### `examples/` (12 sites)

| File | Sites | Notes |
|---|---:|---|
| `mupsic.nim` | 2 | Rename to `queue_bounded_mupsic.nim`? (implementer decides per D3.5) |
| `sipmuc.nim` | 2 | Rename to `queue_bounded_sipmuc.nim`? |
| `mupmuc.nim` | 2 | Rename to `queue_bounded_mupmuc.nim`? |
| `sipsic.nim` | 2 | Rename to `queue_bounded_sipsic.nim`? |
| `audio_buffer.nim` | 1 | Migrate in-place. |
| `event_collector.nim` | 1 | Migrate in-place. |
| `job_scheduler.nim` | 1 | Migrate in-place. |
| `task_fanout.nim` | 1 | Migrate in-place. |

### `benchmarks/nim/` (79 sites)

| Sub-cluster | Sites | Notes |
|---|---:|---|
| `benchmarks/nim/bench_*.nim` (4 files: spsc, mpsc, mpmc, unbounded + bench_latency) | 45 | `bench_latency.nim`=8, `bench_unbounded.nim`=12, `bench_mpmc.nim`=7, `bench_mpsc.nim`=5, `bench_spsc.nim`=? — Track D3.6 owns. |
| `benchmarks/nim/adapters/` | 30 | 7 collapsed adapter modules (UnboundedSipsic carve-out: `lockfreequeues_unbounded_sipsic_adapter.nim` excluded — zero hits). Track D3.6.5 consolidates into 2 unified adapters (`queue_bounded_adapter.nim`, `queue_unbounded_adapter.nim`). |
| `benchmarks/nim/tests/` (`t_adapter_*.nim`) | 4 | 6 per-family adapter smoke tests to delete + KEEP `t_adapter_lockfreequeues_unbounded_sipsic.nim` (zero hits). Track D3.6.5 replaces with `t_adapter_queue_bounded.nim` + `t_adapter_queue_unbounded.nim`. |

Per-adapter breakdown:
- `lockfreequeues_mupsic_adapter.nim`: 4 sites
- `lockfreequeues_sipmuc_adapter.nim`: 4 sites
- `lockfreequeues_mupmuc_adapter.nim`: 4 sites
- `lockfreequeues_sipsic_adapter.nim`: 3 sites
- `lockfreequeues_unbounded_mupsic_adapter.nim`: 4 sites
- `lockfreequeues_unbounded_sipmuc_adapter.nim`: 2 sites
- `lockfreequeues_unbounded_mupmuc_adapter.nim`: 2 sites
- `lockfreequeues_unbounded_sipsic_adapter.nim`: 0 sites (KEPT — carve-out)

### `docs/` (75 sites)

| Sub-cluster | Sites | Disposition |
|---|---:|---|
| `docs/api/` | 13 | DELETE 7 per-family `.md` files; KEEP `unbounded_sipsic.md`; UPDATE `index.md`; NEW `queue.md` (Track F2). |
| `docs/guide/` | 25 | REWRITE references: `core-concepts.md` (1), `safety-model.md` (verify), `examples.md` (verify), `getting-started.md` (4), `memory-management.md` (3), `performance-tuning.md` (4), `bounded-vs-unbounded.md` (13). |
| `docs/plans/` (historical) | 35 | Historical design docs (`2025-11-30-sipmuc-unbounded-implementation.md` = 23, `2025-11-30-sipmuc-unbounded-queues-design.md` = 13). **DO NOT MUTATE** — these are historical artifacts. Flag for impl plan §3.4 confirmation. |
| `docs/index.md` + top-level | 2 | UPDATE. |

**Flag:** `docs/plans/` historical files contain 35 of the 477 sites. If left intact per "historical docs" policy, the net migration scope drops to 442. The impl plan §D1 cluster pass mentions `docs/guide/` and `docs/index.md` explicitly but does NOT mention `docs/plans/`. Surface to pepper.

---

## Out-of-grep-scope additional sites (flagged for pepper)

These are NOT counted in the 477 plan-coverage total but contain legacy queue-family references the impl plan's grep methodology missed:

### `stress-tests/` (39 sites — NOT in impl plan grep)

| File | Sites |
|---|---:|
| `t_unbounded_mupmuc_threaded.nim` | 7 |
| `t_unbounded_sipmuc_threaded.nim` | 6 |
| `t_unbounded_mupsic_threaded.nim` | 6 |
| `stress_test.nim` | 6 |
| `t_mupmuc_threaded.nim` | 4 |
| `t_sipsic_threaded.nim` | 3 |
| `t_sipmuc_threaded.nim` | 3 |
| `t_mupsic_threaded.nim` | 3 |
| `t_unbounded_sipsic_threaded.nim` | 1 (excluded — UnboundedSipsic carve-out) |

Net migrating: 38 (subtracting the 1 carve-out hit, though that file as a whole stays untouched).

**Recommendation:** Treat `stress-tests/` as a Track B2/E3 extension cluster. Mechanical sed pass alongside `tests/`.

### `benchmarks/README.md` (3 prose mentions)

Lines 12, 14, 16 reference "Sipsic 1p1c", "Mupsic {1,2,4}p1c", "Mupmuc/Sipmuc" in driver descriptions. Track D3.6.5 commit 3 rewrites these to reference the unified `Queue` adapter cardinality params.

### `benchmarks/results/*.json` (3 string mentions — DO NOT MUTATE)

`"implementation": "lockfreequeues/Sipsic"` in `latest.json`, `nim-20251203-162207.json`, `nim-test.json`. These are historical v4.1.x snapshots. Per impl plan §D1 Step 2 cluster bucket: "DO NOT MUTATE." Inventory completeness only.

### `lockfreequeues.nimble` (4 example invocations)

Lines 44-47: `exec "nim c --threads:on -r -f examples/{sipsic,sipmuc,mupsic,mupmuc}.nim"`. These are filename references. If D3.5 renames the example files to `queue_bounded_*.nim`, these 4 invocations need parallel updates. If examples stay at the same filename (the simpler option), zero changes needed.

### Top-level `README.md` (12 prose mentions)

User-facing documentation references queue family names. Track F2 (docs rewrite) likely owns; surface to pepper if a different track should claim it.

### `CHANGELOG.md` (17 type-name mentions, 1 ctor mention)

Per impl plan §D3 Step 4 ("Exception: CHANGELOG.md migration table (Track F1) DOES contain legacy names in the 'Before' column"), these are **intentional**. Track F1 authors the migration table verbatim from Doc C §5. D3 verifies post-cascade greps return ONLY CHANGELOG hits.

---

## Confidence notes / ambiguities

1. **`benchmarks/results/*.json` policy:** Inventoried for completeness but per impl plan §3.4 explicitly "DO NOT MUTATE — benchmark results pre-collapse are part of the v4.1.x snapshot history." Flagged for awareness, not migration.

2. **`stress-tests/` out-of-scope from plan grep:** Surfaced as a non-halting escalation. If pepper rules it IN, combined plan+stress total is 516 → exceeds HALT-GATE.

3. **`docs/plans/` historical files (35 sites):** Historical design docs from the November 2025 Sipmuc unbounded planning round. Standard convention treats these as immutable history. Surface to pepper for confirmation; impl plan §D1 cluster pass did not enumerate `docs/plans/`.

4. **Comment-only references in `src/lockfreequeues/typestates/{mpmc,mpsc,spmc}_push.nim`:** 3 of the typestate hits are inside comments (each is a doc-comment that names the original family type). Mechanical sed will rewrite these; verify the rewritten comment text still reads sensibly.

5. **`unbounded_{mpmc,mpsc}_{pop,push}.nim` and `unbounded_spmc_pop.nim` (5 of the 6 in-scope typestate files per Doc C §3.6):** Zero grep hits in the typed-binding pattern. Either (a) they don't directly name family types in any pattern the grep catches, or (b) they reference families through aliased symbols. Track E4 must verify these files compile after the cascade even though they have no D1-grepped sites.

6. **Comment hits in `src/lockfreequeues/mupmuc.nim:51` and similar:** Some `Mupmuc[N,P,C,T]` etc. references inside type-def comments. Plain sed handles them; the rewritten comment may want manual touch-up.

7. **5 lines with both typed-binding AND constructor on the same line:** These appear in test files like `let q: Mupsic[N,P,T] = initMupsic[N,P,T]()`. Dedup reduces 482 → 477.

---

## Appendix A: Full per-site listings

Raw grep output captured to `/tmp/lfq_cascade_{typed,ctor,imports}.txt` during inventory; per the task brief's reproducibility requirement, anyone can re-run the three grep commands listed in the Method section to regenerate identical output against worktree HEAD `b6da7f6`.

Per-site listings by directory follow. Each entry: `relative/path:line:context_snippet`.

(Full 477-row listing intentionally NOT inlined here for readability; the three grep commands above are deterministic and reproduce the full list verbatim. The per-cluster summary tables above + the per-file counts are the operational artifact.)

---

## HALT-GATE certification

**Per task brief HALT-GATE wording:** "If total inventory exceeds **500 sites**, STOP, do not commit, return immediately."

**Plan-coverage total = 477 sites ≤ 500 → PASS. Proceeding to D2 commit.**

Combined-with-stress-tests total = 516 (informational; depends on pepper scope ruling).

Combined-with-everything-flagged ≈ 555 (informational; CHANGELOG and JSON results are intentional retention or freeze).
