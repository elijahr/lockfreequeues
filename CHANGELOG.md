# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [4.2.0] - 2026-05-06

### BREAKING

- `CASAttempt` typestate restructured into a proper typestate union. `CASPending` now transitions to `CASSucceeded | CASFailed` (aliased as `CASResult`) via `executeCAS`, replacing the previous single-state design with `assumeSuccess` / `assumeFailure` escape hatches. The `assumeSuccess` and `assumeFailure` procs have been removed. Callers that drove `CASAttempt` outside the bundled MPMC machinery must migrate to the union return form. These helpers were only consumed by `tests/t_cas.nim`; the bundled MPMC machinery calls `compareExchangeWeak` directly and was unaffected. No public lock-free queue API is affected.

### Added

- Multi-panel benchmark chart layout on `docs/benchmarks.md`: a hero
  panel highlighting lockfreequeues vs alternatives at the most-relevant
  shape, per-topology throughput panels, and a dedicated latency panel.
  Hero panel selects shape by preference order MPMC 4p4c → MPMC 2p2c →
  MPSC 4p1c → SPSC 1p1c, with a bounded-only fallback when no shape in
  the snapshot covers all comparison libraries.
- Latency panel rendering (`#bench-latency`) — log-y stepped ladder
  across the p50 / p95 / p99 / p999 / max percentiles emitted by
  `bench_latency.nim`.
- Library color discipline (`LIBRARY_COLORS` map in
  `docs/assets/bench-charts.js`): a single brand color shared across the
  full lockfreequeues family (sipsic / sipmuc / mupsic / mupmuc and
  their unbounded counterparts) and distinct stable colors for each
  comparison library, so toggling series in the legend never reassigns
  hues.
- Blocking-library visual differentiation: `threading_channels` and
  `nim_channel` / `nim_channels` are drawn with dotted lines plus a
  dedicated legend badge, marking them apart from the non-blocking
  comparison set.
- Five new guide pages under `docs/guide/`: Getting Started, Core
  Concepts, Bounded vs Unbounded, Memory Management, and Performance
  Tuning. Skeletons scaffolded against the typestates-pattern guide
  shape, then filled in via a dedicated prose pass.
- New top-level `docs/contributing.md` (substantially richer than the
  9-line root `CONTRIBUTING.md`), covering branch / version / CHANGELOG
  protocol and contributor workflow.
- "How to read these numbers" and "When to pick lockfreequeues"
  narrative sections in `docs/benchmarks.md`, surfacing methodology
  context above the chart so readers don't have to dig through the
  benchmarks README to interpret the numbers.
- Hybrid README BENCHMARKS block: headline number (10.6× faster than
  system Channel at MPMC 4p4c) plus the existing four-row variant table
  plus a link line to the live chart page. Replaces the prior
  table-only block.
- Representative `docs/assets/bench-results/example.json` BMF fixture
  used by the chart for fallback rendering when `latest.json` is
  unavailable (e.g. fresh PRs before the snapshot pipeline runs on
  devel).
- Four new contract tests pinning the chart's BMF surface area: DOM
  container IDs (`#bench-chart`, `#bench-latency`, …), `LIBRARY_COLORS`
  coverage of every library slug emitted by the bench binaries,
  `BLOCKING_LIBRARIES` membership for blocking-API libraries, and
  `example.json` schema validity.
- Defensive fallback step in `bench.yml` writing a
  `_status: "fallback"` marker into `latest.json` when `merge_bmf.py`
  fails or is cancelled, so the chart's silent-on-error behaviour
  cannot mask a broken upload pipeline.
- Latency p99 + throughput regression gating in Bencher (PR 6, Track 6).
  `bench.yml`'s base-branch tracking step now configures per-measure
  thresholds in a single `bencher run` invocation: `latency_p99_ns`
  with `--threshold-upper-boundary 0.99` (regression = latency
  increase) and `throughput_ops_ms` with `--threshold-lower-boundary
  0.99` (regression = throughput drop). Both use `--threshold-test
  t_test --threshold-max-sample-size 64`, terminated by
  `--thresholds-reset` so only the explicitly-listed thresholds
  remain active. Threshold activation requires ≥ 10 prior runs
  accumulated in Bencher to calibrate the t-test baseline (Task 6.4
  stability soak gate). Also corrects a prior measure-name mismatch:
  the earlier `--threshold-measure throughput` never matched any
  emitted measure (the actual key is `throughput_ops_ms`), so the
  previous throughput threshold was a no-op.
- `latency_p999_ns` and `latency_max_ns` measures emitted by
  `bench_latency.nim` (PR 6, Track 6). Each bounded variant slug
  (`lockfreequeues_{sipsic,sipmuc,mupsic,mupmuc}/<topology>/1p1c`)
  now carries the full p50 / p95 / p99 / p999 / max latency tuple in
  the merged BMF, available for the Bencher dashboard and downstream
  comparison charts. `t_bench_latency.nim` extended to assert all
  four extra measures appear on every bounded variant in the smoke
  shape.
- `HistogramTopK` raised from 1000 to 5000 (PR 6, Task 6.2).
  `runLatencyHarness` builds a fresh Histogram per run and averages
  per-run percentiles (design 2.5) — each histogram only sees
  `BenchLatencyMessageCount` samples, NOT `messageCount × runCount`.
  At the default 100K samples per run, K=1000 was already adequate
  (TopK + Reservoir already captured every sample exactly). The bump
  to K=5000 is anticipatory: an operator who overrides
  `BenchLatencyMessageCount` upward (e.g. ~5M for a tail-stress
  configuration) needs ~5000 in the exact top-K stratum to keep p999
  (tail rank = MessageCount × 0.001) outside the rescaled-reservoir
  stratum. Memory cost: 5000 × 8B = 40KB additional per histogram,
  negligible vs the 99K-sample reservoir. New `t_bench_common.nim`
  test stress-checks the design choice by asserting p999 within 5%
  of sort fallback on a single 3.3M log-normal stream.
- Interactive uPlot throughput chart on the docs site (PR 5, Track 5).
  `docs/benchmarks.md` embeds a `<div id="bench-chart">` container plus
  a vendored `uPlot 1.6.27` IIFE bundle and a vanilla-JS wiring module
  (`docs/assets/bench-charts.js` + `docs/assets/bench-charts.css`).
  The chart fetches the merged BMF snapshot from the relative URL
  `./assets/bench-results/latest.json` so the same page works under
  the `/dev/`, `/latest/`, and `/v*/` mike aliases without rewrite.
  Library-toggle legend hides/shows series; log-scale Y axis toggle
  switches between linear and log; hover tooltips show mean ± stddev
  when `lower_value` / `upper_value` are present in the underlying
  measure (throughput). Soft-skipped (library, shape) cells render as
  gaps, not zeros. Graceful fallbacks render an inline message on
  fetch errors, missing uPlot global, or empty BMF.
- BMF snapshot publishing pipeline (PR 5, Track 5). New step in
  `bench.yml`'s `bench-upload` job runs only on `push` to
  `refs/heads/devel`, copies `merged.json` to
  `docs/assets/bench-results/<sha>.json` AND
  `docs/assets/bench-results/latest.json`, and pushes the snapshot
  back to `devel` as `github-actions[bot]` with a `[skip ci]` commit
  message. Three-layer loop-prevention per design §5.X:
  (1) `[skip ci]` marker (primary), (2) `paths-ignore` extension to
  `docs/assets/bench-results/**` on both `pull_request` and `push`
  triggers (secondary), and (3) bot-actor guard on the `bench` and
  `bench-upload` jobs (tertiary).
- Devel-triggered docs deploy (PR 5, Track 5). `docs.yml` now triggers
  on push to `devel` in addition to `main` / `master`, and the
  "Deploy docs (dev)" step's `if:` clause includes `devel`. A new
  post-deploy "Verify mike asset path" step (design §5.Y) curls
  the published BMF snapshot URL, asserts HTTP 200, and asserts the
  body parses as JSON; the chart's silent-on-404 behaviour would
  otherwise hide a broken asset path.
- `THIRD_PARTY_LICENSES.md` records the uPlot vendoring (1.6.27, MIT,
  vendored at `docs/assets/uplot-1.6.27.iife.min.js`) with a precise
  upgrade procedure including the jsdelivr URL and SHA-256
  verification path. `.gitattributes` gains
  `docs/assets/uplot-*.js linguist-vendored=true linguist-generated=true`
  and `docs/assets/bench-results/*.json linguist-generated=true`.
- New `benchmarks/tests/test_bench_charts_contract.py` (9 tests)
  guards the BMF -> chart contract: slug grammar
  `<library>/<topology>/<P>p<C>c`, measure regex
  `^[a-z][a-z0-9_]*$`, finite numeric values, throughput-measure
  presence, and the existence of the three checked-in chart assets.
  Mirrors the JS `parseSlug` logic in Python so drift is caught at
  CI time rather than in production.
- `docs/benchmarks.md` registered in `mkdocs.yml`'s nav (previously
  unreachable from the docs landing page) and the four-row §4.1
  fairness caveats embedded verbatim immediately below the chart so
  readers see the methodology footnotes within one viewport
  regardless of which library combination they toggle.
- `benchmarks/README.md` "Updating the README summary" subsection
  codifies the new hand-curation procedure for the README BENCHMARKS
  markers (which shapes to read, where to read them, when to commit).
- Five additional comparison libraries reach the bench matrix:
  `atomic_queue` (Tier 1, header-only, MIT), `rigtorp/SPSCQueue`
  (Tier 1, header-only, MIT), `rigtorp/MPMCQueue` (Tier 1,
  header-only, MIT), `flume` (Rust crate, MPL-2.0, mpsc / mpmc
  unbounded), `kanal` (Rust crate, MPL-2.0, mpmc / mpmc_unbounded).
  C++ header-only libraries are vendored under `benchmarks/vendor/`
  with pinned upstream SHAs and project-authored READMEs documenting
  the upgrade procedure; Rust crates are consolidated into a single
  cdylib at `benchmarks/rust/comparison/` (`libbench_ffi_comparison`)
  alongside the existing Crossbeam adapters. Plus `liblfds` (a C
  ringbuffer library, public-domain) wired through a thin C wrapper
  for SPSC + MPMC bounded coverage.
- First-class SPMC topology axis. A fifth throughput panel
  `bench-throughput-spmc` lands in `docs/benchmarks.md` and the
  sipmuc-family adapters (bounded `lockfreequeues_sipmuc` and
  unbounded `lockfreequeues_unbounded_sipmuc`) are rerouted from
  the MPMC panel to the new SPMC panel, with `spmc` /
  `spmc_unbounded` slug roots replacing the prior `mpmc` /
  `mpmc_unbounded` roots for those adapters.
- Topology-based adapter dispatcher (Option C). Each bench binary
  (`bench_spsc`, `bench_mpsc`, `bench_mpmc`, `bench_spmc`,
  `bench_unbounded`) now owns a `seq[Adapter]` registry whose
  per-adapter `topologiesSupported: set[Topology]` field declares
  which topologies that adapter participates in. The harness
  iterates the registry and dispatches by topology rather than by
  the prior name-based `case variant of "X":` ladder. The bench
  binaries take `<topology>` as `argv[1]` (e.g.
  `./bench_mpmc spmc 1p2c`) instead of the legacy variant name.
- `HarnessBackoff` in `benchmarks/nim/bench_common.nim`: a
  schedYield-escalating consumer-wait backoff for unbounded
  shapes. Initial spins use `cpuPause`; once the spin budget
  exhausts, the backoff escalates to `schedYield` to release the
  scheduler and break consumer-livelock on oversubscribed runners.
  Tunable via `-d:HarnessSpinBudget=N` /
  `-d:HarnessYieldThreshold=N` (defaults 128 / 1024).
- uPlot bars for the per-topology throughput panels (categorical
  X axis instead of a pseudo-continuous numeric axis), and a
  canvas-rendered hero panel paired with an offscreen `<table>`
  ARIA companion so screen readers can read the same data the
  canvas renders visually.
- Dark-mode-aware uPlot canvases. New `themeStroke()` /
  `themeFont()` helpers in `docs/assets/bench-charts.js` resolve
  axis stroke and font color from the active mkdocs theme, and a
  `MutationObserver` on `<html data-md-color-scheme>` reflows
  every chart when the user toggles the theme switch.
- Inline `## Glossary` (32 entries) and
  `## Why MPMC is harder than SPSC` (cache-line contention; ABA
  and reclamation; ordering and asymmetry) sections in
  `docs/benchmarks.md`, surfacing the methodology vocabulary and
  the "why is this metric hard" intuition immediately above the
  chart panels.
- Per-library smoke-step `--path:` flag propagation in
  `bench.yml`. The smoke-compile step now captures
  `nimble path <pkg>` for any installed package adapter and
  threads the resulting `--path:` flag through to the bench
  compile step. Previously, libraries that passed install but
  required an installed-package path on the bench compile would
  fail silently and get omitted from the BMF as a soft-skipped
  slug accompanied only by a yellow PR warning. The new flag
  propagation closes that false-negative path.
- Guard test
  `benchmarks/tests/test_smoke_compiles.py`: a fixture-pinned
  floor of expected comparison-library slugs in
  `latest.json`. Gated on
  `LOCKFREEQUEUES_BENCH_STRICT_FLOOR=1` until the post-merge
  `bench.yml` run regenerates `latest.json` with the restored
  boost / loony / threading_channels / crossbeam slugs; the
  env-var gate retirement (make strict mode default) is a
  v4.3.0 follow-up.

### Changed

- The three pre-existing guide-shaped pages (`safety-model.md`,
  `slot-ownership-typestates.md`, `examples.md`) moved from
  `docs/` to `docs/guide/` so the entire guide track lives under one
  directory. Internal links updated; mkdocs nav follows the move.
- API reference pages for `sipsic`, `mupsic`, and `mupmuc` expanded to
  match the structural template established by `sipmuc.md` (consistent
  section ordering, signatures, examples, cross-links).
- mkdocs `nav:` restructured to a top-level `Guide` grouping (typestates
  pattern), with the API reference and benchmarks sitting alongside it
  rather than scattered through the tree.
- `mkdocs.yml` aligned with the typestates pattern: `include-markdown`
  plugin enabled, `theme.custom_dir: docs/overrides` wired in,
  `show_attribution: false` set on the `mkdocstrings-nim` handler,
  and `click<8.3.0` pinned via the docs requirements to dodge an
  upstream incompatibility.
- `docs.yml` workflow swapped its in-place `nim.cfg` patching for
  `nimble install nim -y` to expose the Nim compiler API to
  `mkdocstrings-nim` more cleanly. Nim pinned to 2.2.8 to match the
  build matrix, and a daily cron at 05:17 UTC was added so the live
  chart picks up new BMF snapshots even when no commit lands on devel.
- `bench.yml` snapshot-commit message now carries `[skip ci]` (third
  loop-prevention layer alongside the existing `paths-ignore` filter
  and the bot-actor guard on the bench / bench-upload jobs).
- `bench.yml` `Track base branch benchmarks with Bencher` step marked
  `continue-on-error: true` as a release-day band-aid for an upstream
  Bencher CLI threshold-model validation quirk; threshold gating remains
  dormant pending the Track 6 calibration soak.
- `README.md` BENCHMARKS markers now hold a hand-curated four-row
  summary table (Sipsic / Sipmuc / Mupsic / Mupmuc bounded at one
  representative shape each) plus a link line to the live chart page
  at `https://elijahr.github.io/lockfreequeues/latest/benchmarks/`,
  per design §4.4. Initial cells contain placeholders; the release PR
  fills them in. The chart page absorbs run-to-run noise; the README
  intentionally captures only the most recent release's headline
  numbers.
- Bumped minimum `debra` from `>= 0.7.0` to `>= 0.7.1` to pull in
  the upstream signal-handler stride fix in cross-slot reclamation.
- `bench-comparison.yml` retired. The Crossbeam (Rust) adapters
  now run inside `bench.yml`'s regular matrix, consolidated
  alongside flume + kanal in a single Rust cdylib at
  `benchmarks/rust/comparison/` (`libbench_ffi_comparison.{so,dylib}`).
  Strict prefix-per-crate symbol naming
  (`cb_*` / `flume_*` / `kanal_*`) prevents collision across the
  consolidated FFI surface.
- Log-scale axes (throughput + latency) now suppress null and
  minor-tick labels — only major (power-of-10) ticks render. Cleans
  up the prior axis clutter where uPlot's default minor-tick density
  produced overlapping labels at small chart heights.
- Bench harness binaries take `<topology>` as `argv[1]`
  (e.g. `./bench_mpmc spmc 1p2c`) instead of the legacy
  `<variant_name>`. The Matrix Run step in `bench.yml` was
  updated to pass topology arguments.

### Removed

- `benchmarks/render_readme.nim` and its test
  `tests/t_render_readme.nim`. The auto-rendered README path is
  replaced by hand curation (above). Pre-deletion release-tag check
  (per impl plan 5.8): `v3.2.0` and `v4.0.0` each ship the renderer
  in their tagged tree; deleting on devel does not mutate those
  tags. No CI workflow, nimble task, or test runner referenced the
  renderer.

- `.github/workflows/bench-comparison.yml`. The Crossbeam comparison
  job folded into `bench.yml`'s regular matrix as part of the Rust
  cdylib consolidation; a separate workflow is no longer needed.
- Name-based `case variant of "X":` dispatch in the bench binaries.
  Replaced by the topology-based `seq[Adapter]` registry described
  in `### Added` above.
- `-d:BenchSkipOversubscribed` removed from `bench.yml`'s
  compile-flag list. The Nim-side `when not defined(...):` guards
  remain in the source so the gate can be re-engaged by re-adding
  the YAML line if a future regression demands it.

- Legacy `nim doc`-generated HTML output (`json/` directory, 17
  files) and the `nimdoc.cfg` config that drove it. The mkdocs +
  mike pipeline introduced in v4.0.x is now the canonical docs
  build path; legacy artifacts were not regenerated by current CI.

- Comparison expansion (PR 4, Track 4): four new third-party adapters
  reach the comparison set. `moodycamel_adapter.nim` wraps
  `moodycamel::ConcurrentQueue` (BSD-2-Clause / Boost dual,
  `mpmc_unbounded`) via a thin `extern "C"` shim isolating Nim from
  upstream's template machinery. `threading_channels_adapter.nim`
  wraps the nimble `threading` package's `Chan[T]` (MIT, `mpmc`
  bounded) using non-blocking `trySend` / `tryRecv`.
  `nim_channel_adapter.nim` wraps Nim's stdlib `system.Channel[T]`
  (MIT, `mpsc` bounded) with blocking-on-full producer semantics
  (apples-to-oranges fairness caveat documented inline + asterisked
  in the bench README). All three are gated behind
  `-d:adapter_<library_slug>_available` defines; absent gates produce
  no symbol references and the production builds are unchanged.
- Vendored MoodyCamel `concurrentqueue` at upstream commit
  `d655418bb644b7f85159d94c591d7d983949fb81` under
  `benchmarks/vendor/concurrentqueue/`: `concurrentqueue.h` + upstream
  `LICENSE.md` + a project-authored `README.md` documenting the
  pinned SHA and upgrade procedure. The
  `moodycamel_wrapper.cpp` shim exposes `mc_init` / `mc_push` /
  `mc_pop` / `mc_destroy` for `uint64_t`. New
  `benchmarks/nim/smoke/smoke_moodycamel.nim` and
  `benchmarks/nim/smoke/smoke_threading_channels.nim` run a 32-item
  push/pop round-trip as fast pre-flight checks in CI.
- `bench.yml` gains the `force_skip_moodycamel` /
  `force_skip_threading_channels` / `force_skip_nim_channel`
  `workflow_dispatch` boolean inputs and per-library install → smoke →
  set-flag pipelines (design §2.6 soft-skip pattern). MoodyCamel's
  install step is a `test -f` against the vendored header so the
  bench is reproducible without network egress; threading uses
  `nimble install threading`; system.Channel needs no install.
  Failure at install or smoke flips the binary's compile flags so the
  slugs are omitted from the BMF instead of failing the workflow; the
  `Annotate skipped` step emits a `::warning title=Adapter
  skipped::...` annotation visible on the PR check summary. The
  `bench_mpsc` compile step now consumes `ADAPTER_FLAGS` so the new
  `nim_channel` adapter wires in; the `bench_unbounded` compile step
  honours `NIM_MODE=cpp` when MoodyCamel is enabled.
- `tests/t_bench_adapters.nim` extends with three new
  `when defined(adapter_<lib>_available):` blocks covering 1000-item
  push/pop round-trip set equality for the new adapters (gated under
  `nim cpp` for MoodyCamel).
- `THIRD_PARTY_LICENSES.md` lands its first vendored entry
  (`concurrentqueue (MoodyCamel)`, BSD-2-Clause / Boost dual, pinned
  to commit `d655418bb644b7f85159d94c591d7d983949fb81`) plus
  unvendored entries for the nimble `threading` package (MIT) and
  Nim `system.Channel` stdlib (MIT). Placeholder PR-4 reservation
  removed.
- New `.gitattributes` rule
  `benchmarks/vendor/** linguist-vendored=true linguist-generated=true`
  excludes the vendored MoodyCamel header from GitHub language stats
  and code-search noise.
- `benchmarks/README.md` comparison table extends to seven upstream
  libraries / nine adapter variants with install commands for each.
- Bench-binary slug coverage extends per design §2.4: `bench_mpmc`
  emits `threading_channels/mpmc/{1,2,4}p{1,2,4}c` (9 shapes);
  `bench_mpsc` emits `nim_channel/mpsc/{1,2,4}p1c` (3 shapes);
  `bench_unbounded` emits
  `moodycamel/ConcurrentQueue/mpmc_unbounded/{1,2,4}p{1,2,4}c` (9
  shapes). Each carries a `throughput_ops_ms` measure with
  `value=mean`, `lower_value=mean-stddev`, `upper_value=mean+stddev`.
- New `benchmarks/nim/bench_common.nim` shared harness module exporting:
  `Topology` enum, `BMFEmitter` (alpha-sorted Bencher Metric Format JSON
  emission), `Histogram` (min-heap top-K + Algorithm R reservoir for
  stratified-percentile estimation, p99 within 1% of sort fallback on
  100k log-normal samples), generic `runThroughputHarness` and
  `runLatencyHarness` (1P/1C ping-pong RTT with monotonic-ns timing and
  per-run percentile aggregation), and Stats helpers (mean / stddev /
  minVal / maxVal / linear-interpolation percentile).
- Five new lockfreequeues adapters in `benchmarks/nim/adapters/`:
  `lockfreequeues_sipmuc_adapter.nim`, `lockfreequeues_mupsic_adapter.nim`,
  `lockfreequeues_unbounded_sipsic_adapter.nim`,
  `lockfreequeues_unbounded_sipmuc_adapter.nim`,
  `lockfreequeues_unbounded_mupmuc_adapter.nim`. Each exposes
  `topologiesSupported: set[Topology]` and the standard `push`/`pop`
  shape consumed by the shared harness. The unbounded adapters store
  the queue inline (not via `ptr`) to dodge a Nim 2.2.6 codegen bug
  triggered by generic-pointer destructor calls when bench_common is
  imported.
- New `benchmarks/merge_bmf.py` CLI: stateless union of per-binary BMF
  JSON fragments into a single output file. Exits 1 on `(slug, measure)`
  collisions naming both colliding inputs in stderr. Output slugs and
  measures alpha-sorted. Pure-stdlib (no third-party deps); covered by
  `benchmarks/tests/test_merge_bmf.py` (10 tests).
- `bench_throughput` `--bmf-out=<path>` flag emits Bencher Metric Format
  JSON natively. The flag is purely additive: with the flag absent, the
  binary is bit-for-bit unchanged from the prior release (same stdout
  text, same positional CLI: `bench_throughput sipsic mupmuc
  unbounded_mupsic channels`). Emitted slugs:
  `lockfreequeues_sipsic/spsc/1p1c`,
  `lockfreequeues_mupmuc/mpmc/{1,2,4,8}p{1,2,4,8}c`,
  `lockfreequeues_unbounded_mupsic/mpsc_unbounded/{1,2,4}p1c`,
  `nim_channels/mpmc/{1,2,4}p{1,2,4}c`. Each carries a
  `throughput_ops_ms` measure with `value=mean`, `lower_value=mean-stddev`,
  `upper_value=mean+stddev`.
- Per-variant compile-time run-count overrides:
  `-d:BenchSipsicRuns=N`, `-d:BenchSipsicWarmup=N`,
  `-d:BenchMupmucRuns=N`, `-d:BenchMupmucWarmup=N`,
  `-d:BenchChannelsRuns=N`, `-d:BenchChannelsWarmup=N`. Defaults match
  the prior hard-coded `runs = 10`, so production runs are unchanged.
- `bench_latency` now emits Bencher Metric Format JSON natively via
  `--bmf-out=<path>`, mirroring `bench_throughput`'s CLI surface (PR 1).
  Positional args filter the variants run (`sipsic`, `mupmuc`, `sipmuc`,
  `mupsic`); without any positional arg, all four bounded lockfreequeues
  variants run at the 1p1c smoke shape. Emitted slugs:
  `lockfreequeues_sipsic/spsc/1p1c`,
  `lockfreequeues_sipmuc/mpmc/1p1c`,
  `lockfreequeues_mupsic/mpsc/1p1c`,
  `lockfreequeues_mupmuc/mpmc/1p1c`. Each carries
  `latency_p50_ns` / `latency_p95_ns` / `latency_p99_ns` measures
  (`latency_p999_ns` / `latency_max_ns` deferred to PR 6's threshold-
  gating work). The binary is built on top of
  `bench_common.runLatencyHarness` and uses per-binary intdefines:
  `-d:BenchLatencyRuns=N` (default 33), `-d:BenchLatencyMessageCount=N`
  (default 100_000), `-d:BenchLatencyWarmupRuns=N` (default 3).
- New `bench-latency` job in `.github/workflows/bench.yml` sibling to
  `bench-throughput`. Both jobs upload per-binary BMF artifacts
  (`bench-throughput-bmf` / `bench-latency-bmf`) consumed by a new
  `bench-upload` job that downloads via `actions/download-artifact@v4`
  pattern `bench-*-bmf`, runs `merge_bmf.py` to union the fragments,
  and performs the single `bencher run` upload that co-locates latency
  + throughput measures on shared per-slug histories. (Multiple
  `bencher run` invocations create separate Bencher Reports and would
  NOT co-locate measures — see merge rationale in design 1.)
- Four new topology-split throughput binaries replacing the legacy
  `bench_throughput.nim` (PR 2):
  `benchmarks/nim/bench_spsc.nim` (Sipsic 1p1c),
  `benchmarks/nim/bench_mpsc.nim` (Mupsic {1,2,4}p1c),
  `benchmarks/nim/bench_mpmc.nim` (Mupmuc {1,2,4}p{1,2,4}c plus 8p8c
    oversubscription, Sipmuc 1p{1,2,4}c, Nim channels {1,2,4}p{1,2,4}c),
  `benchmarks/nim/bench_unbounded.nim` (all four lockfreequeues
    unbounded variants at their natural shapes).
  Each emits BMF JSON via `--bmf-out=<path>` with the same per-slug
  `throughput_ops_ms` shape as the prior binary. Each owns its own
  per-binary intdefines (`-d:BenchSpscRuns/MessageCount/Warmup`,
  `-d:BenchMpscRuns/...`, `-d:BenchMpmcRuns/...`, plus four pairs of
  `-d:Unbounded<Variant>Runs/MessageCount` per design 2.5) so CI can
  budget each topology independently.
- New `benchmarks/scripts/superset_check.py`: slug-set deletion-safety
  guard that exits 0 when the post-split BMF covers every slug in the
  pre-split fixture (`tests/fixtures/pre-split-slugs.json`) and
  exits 1 with the missing slugs alpha-listed on stderr otherwise.
  Run by `bench-upload` immediately after `merge_bmf.py` so any
  silent slug regression introduced by future edits to the topology
  binaries fails the PR check. Covered by 9 unit tests in
  `benchmarks/tests/test_superset_check.py`.
- `benchmarks/tests/test_merge_bmf.py` gains `test_five_input_union`
  covering the upload-job pipeline shape: 5 sibling fragments (one per
  topology binary) merged via `merge_bmf.py` produce a single output
  whose slug set is the disjoint union, with shared slugs carrying
  measures from every input binary.
- Five third-party comparison adapters land in `benchmarks/nim/adapters/`
  for the comparison MVP (PR 3, Track 3): `loony_adapter.nim`
  (LoonyQueue, MIT, mpmc_unbounded), `boost_lockfree_queue_adapter.nim`
  (`boost::lockfree::queue`, BSL-1.0, mpmc bounded),
  `boost_lockfree_spsc_adapter.nim`
  (`boost::lockfree::spsc_queue`, BSL-1.0, spsc bounded),
  `crossbeam_array_queue_adapter.nim` (`crossbeam_queue::ArrayQueue`,
  Apache-2.0 OR MIT, mpmc bounded), `crossbeam_seg_queue_adapter.nim`
  (`crossbeam_queue::SegQueue`, Apache-2.0 OR MIT, mpmc_unbounded).
  Each is gated behind a `-d:adapter_<library_slug>_available` define;
  absent gates produce no symbol references and the production builds
  are unchanged. Tests in `tests/t_bench_adapters.nim` cover a
  1000-item push/pop round-trip per adapter.
- New Rust crate `benchmarks/rust/bench-ffi-crossbeam/`: a `cdylib`
  exposing 8 `extern "C"` fns (`cb_array_init/push/pop/destroy`,
  `cb_seg_init/push/pop/destroy`) consumed by the Crossbeam Nim
  adapters. Pinned via `rust-toolchain.toml` to `stable`. Six
  integration tests cover round-trip set equality for both queue
  types, capacity edges, empty-pop, and null-pointer tolerance.
- New `benchmarks/nim/smoke/` directory with `smoke_boost.nim` and
  `smoke_crossbeam.nim`: 32-item push/pop round-trip binaries used as
  fast pre-flight checks in CI before the full bench compile.
- New workflow `.github/workflows/bench-comparison.yml`: dedicated
  Crossbeam comparison job triggered by nightly cron (`0 4 * * *`),
  `workflow_dispatch`, and targeted path pushes to `devel` (anything
  under `benchmarks/rust/**` or `benchmarks/nim/adapters/crossbeam_*`).
  Builds the cdylib via `dtolnay/rust-toolchain@stable` +
  `Swatinem/rust-cache@v2`, runs the cdylib integration tests,
  compiles `bench_mpmc` + `bench_unbounded` with the crossbeam gates,
  merges via `merge_bmf.py`, and uploads to a separate Bencher Report.
  Crossbeam is intentionally NOT in `bench.yml` so PR critical-path
  time stays unchanged.
- `bench.yml` gains the `force_skip_boost` / `force_skip_loony`
  `workflow_dispatch` boolean inputs and a per-library install ->
  smoke -> set-flag pipeline (design §2.6 soft-skip). Failure at
  install or smoke flips the binary's compile flags so the slugs are
  omitted from the BMF instead of failing the workflow; the
  `Annotate skipped` step emits a `::warning title=Adapter
  skipped::...` annotation visible on the PR check summary.
- New `THIRD_PARTY_LICENSES.md` records license obligations for the
  comparison MVP libraries (Loony MIT, Boost BSL-1.0, Crossbeam
  Apache-2.0 OR MIT) and reserves placeholder entries for
  concurrentqueue (PR 4) and uPlot (PR 5).
- New `src/lockfreequeues/internal/aligned_alloc.nim` exporting
  `allocAligned[T]: ptr T` via a local `posix_memalign` shim. Used by
  the four unbounded queue variants to allocate cache-line-aligned
  segments (64-byte alignment instead of `c_calloc`'s 16-byte ABI
  guarantee), eliminating the false-sharing asymmetry vs other
  libraries flagged in design §4.2.

### Fixed

- Cache-line padding for unbounded queue segments. Each `Segment` field
  participating in producer/consumer coordination now carries
  `{.align: CacheLineBytes.}`, and the four unbounded variants
  (`unbounded_sipsic`, `unbounded_sipmuc`, `unbounded_mupsic`,
  `unbounded_mupmuc`) allocate via `allocAligned[Segment[S, T]]()`
  instead of `c_calloc`. Verified by `tests/t_unbounded_padding.nim`
  (8 assertions across 4 variants, green under c/cpp/arc/refc).
- Boost lockfree adapters (`boost_lockfree_queue_adapter`,
  `boost_lockfree_spsc_adapter`) compile under CI again. The smoke
  step's `nim cpp` invocation gained `--path:src` so the
  `--noNimblePath` setting in the project's `nim.cfg` no longer
  hides the project's own `srcDir` from the smoke compile. Without
  the flag, the smoke step compiled clean against an empty path
  list and the bench compile then failed with module-not-found,
  flipping the slugs into the soft-skipped omit set.
- loony / `threading.Chan` smoke compiles surface their
  installed-package paths via `nimble path <pkg>` capture and feed
  the resulting `--path:` flag into the bench compile step. Both
  libraries are now restored in `latest.json` instead of being
  silently omitted.
- Oversubscribed unbounded shapes (e.g. `mpmc_unbounded 4p4c` on a
  4-vCPU runner) no longer stall the bench. `HarnessBackoff`
  escalates from `cpuPause` to `schedYield` after the spin budget
  exhausts, breaking the consumer-livelock that the strict-FIFO
  consumer-claim path plus a spin-only backoff produced under
  scheduler pressure.

### Changed

- `bench_throughput.nim` now natively emits Bencher Metric Format JSON
  via `--bmf-out=<path>`. The CI workflow (`.github/workflows/bench.yml`)
  was rewired to consume the native output and feed it through
  `merge_bmf.py` before uploading to Bencher.dev — the previous Python
  regex parser (`bmf_adapter.py`) is gone.
- The four existing lockfreequeues adapter files renamed to the
  canonical `<library_slug>_adapter.nim` convention with `git mv`
  (history preserved): `lockfreequeues_sipsic.nim`,
  `lockfreequeues_mupmuc.nim`, `lockfreequeues_unbounded_mupsic.nim`.
  Each gained a `topologiesSupported: set[Topology]` constant for the
  upcoming PR 3 binary-split.
- `benchmarks/render_readme.nim` rewritten to consume the new BMF JSON
  shape directly (`{slug: {measure: MeasureValue}}`) instead of the
  legacy `bench_main` aggregator output. The slug walk decomposes
  `<lib>/<topology>/<P>p<C>c` back into the (impl, thread_config) pair
  the table renders.
- `benchmarks/runner.py` and `lockfreequeues.nimble` `task benchmarks`
  redirected from `bench_main` to `bench_throughput --bmf-out=<path>`.
- `benchmarks/README.md` rewritten to document the new flow
  (bench_common module, adapter convention, `--bmf-out` flag,
  merge_bmf.py, expected slug set).
- `benchmarks/nim/adapter.nim` now re-exports `PushResult` / `PopResult`
  from `bench_common` instead of defining its own copies, unifying the
  two parallel type definitions introduced by PR 0 Task 0.1. Both
  adapter packs (legacy `lockfreequeues_sipsic` / `lockfreequeues_mupmuc`
  / `channels` and the newer `lockfreequeues_sipmuc` / `mupsic` /
  `unbounded_*`) now flow through the same `runLatencyHarness` and
  `runThroughputHarness` without per-call-site type conversion. No
  external API change: legacy callers that imported `./adapter` for
  `PushResult` / `PopResult` continue to compile (PR 1).
- `.github/workflows/bench.yml` now runs the five topology-split
  binaries (`bench_spsc`, `bench_mpsc`, `bench_mpmc`, `bench_unbounded`,
  `bench_latency`) as a GitHub Actions matrix instead of the legacy
  pair of bench-throughput / bench-latency jobs. Each matrix entry
  has its own `timeout-minutes: 12` budget so a hang in one binary
  cannot burn the entire workflow's clock; the surviving binaries
  finish, the bench-upload job merges what arrived, and the operator
  gets partial Bencher coverage rather than no coverage. The
  bench-upload job now also runs the `superset_check.py` deletion-
  safety guard between `merge_bmf.py` and `bencher run` (PR 2).
- `benchmarks/runner.py` and `lockfreequeues.nimble` `task benchmarks`
  iterate the five topology-split binaries and merge their fragments
  via `merge_bmf.py` (PR 2).
- `benchmarks/README.md` rewritten to describe the 5-binary pipeline
  (matrix CI job, per-binary intdefines, deletion-safety guard, the
  merged BMF schema where one slug can carry both throughput and
  latency measures) (PR 2).

### Removed

- `benchmarks/bmf_adapter.py` — Python regex parser that converted
  `bench_throughput` stdout text into BMF JSON. Replaced by native BMF
  emission via `--bmf-out=`.
- `benchmarks/test_bmf_adapter.py` — unit tests for the parser.
  Replaced by `benchmarks/tests/test_merge_bmf.py`.
- `benchmarks/nim/bench_main.nim` — aggregator binary that wrapped
  bench_throughput + bench_latency and produced a custom JSON shape.
  `bench_throughput` is now the canonical entry point.
- `benchmarks/nim/bench_throughput.nim` — single multi-topology
  throughput driver, replaced by the four topology-split binaries
  `bench_spsc`, `bench_mpsc`, `bench_mpmc`, and `bench_unbounded`.
  The pre-split slug fixture committed at
  `tests/fixtures/pre-split-slugs.json` plus the `superset_check.py`
  guard wired into bench.yml enforces that no slug from the legacy
  binary silently disappears across the split (PR 2).
### Changed (typestates 0.7 uplift)

- Bump minimum `typestates` to 0.7.2. Pulls in the upstream `match` macro fixes for generic and cross-module contexts shipped in nim-typestates v0.7.1 / v0.7.2.
- `opaqueStates = true` and `initial:` / `terminal:` DSL blocks added to 5 SET typestates: `CASAttempt`, `SPSCPopOp`, `SPSCPushOp`, `VirtualValueN`, and `VirtualValueN1`.
- 8 hand-written `case .kind` dispatches across 4 facade modules (`sipsic.nim`, `mupmuc.nim`, `mupsic.nim`, `sipmuc.nim`) replaced with the generated `match` macro for compile-time exhaustiveness.

### Added (typestates 0.7 uplift)

- CI: `typestates verify -W --format=github src/` step in `build.yml` to gate the typestate model against drift.

### Fixed (typestates 0.7 uplift)

- 22 read-only typestate accessors across `src/lockfreequeues/typestates/` now carry `{.notATransition.}`. typestates' verifier flagged these once `typestates verify -W` was wired into CI; the procs are pure data extraction and were never transitions.

### Known Limitations

- Queue-side `backoffOnPeerWait` does not yet escalate to
  `schedYield` — only the harness-side `HarnessBackoff` wrapper
  does. The canonical fix (queue-side schedYield plus relaxation of
  the strict-FIFO consumer-claim path) is deferred to v4.3.0 to
  keep this release's blast radius bounded;
  `src/lockfreequeues/backoff.nim` is read-only this release
  (Constraint #7).
- **Strict-floor breach**: `folly_pcq` was DROPPED from the
  comparison-library set. The transitive-include closure (15 unique
  folly headers) exceeds the 6-header threshold, and folly main
  additionally requires C++20 vs the repo's C++17. Final floor is
  16/17. Revisit in v4.3.0+ once folly stabilizes a thinner-include
  header export OR the repo upgrades to C++20.
- The `LOCKFREEQUEUES_BENCH_STRICT_FLOOR=1` env-var gate on
  `benchmarks/tests/test_smoke_compiles.py` remains in place until
  the post-merge `bench.yml` run regenerates
  `docs/assets/bench-results/latest.json` with the restored
  boost / loony / threading_channels / crossbeam slugs. Retiring
  the gate (making strict-mode the default) is a v4.3.0
  follow-up.
- **Bencher.dev threshold reset for sipmuc slugs**:
  `lockfreequeues_*sipmuc/mpmc*` slug threshold history is
  intentionally reset starting v4.2.0 because the sipmuc family
  moved from MPMC to SPMC. The old slug history is retained on
  Bencher.dev as a record but is not carried forward into the new
  SPMC slug roots. The new slugs (`lockfreequeues_sipmuc/spmc/...`
  and `lockfreequeues_unbounded_sipmuc/spmc_unbounded/...`) start
  fresh.

## [4.1.0] - 2026-05-01

### Added

- **Auto-create constructors for unbounded MP/SP variants.** `newUnboundedMupmuc[S, T, MaxThreads](strategy)`, `newUnboundedSipmuc[S, T, MaxThreads](strategy)`, and `newUnboundedMupsic[S, T, MaxThreads](strategy)` (the last auto-registers the caller as the consumer). Each heap-allocates a private `DebraManager` owned by the queue; teardown happens inside the queue's `=destroy` after segment cleanup. The existing explicit-manager API (`addr manager`) is preserved for multi-queue setups that share a manager.
- **Auto-register `getProducer()` / `getConsumer()` overloads.** No-arg variants that call `registerThread` internally. Each call consumes one thread slot; threads using multiple queues with a shared manager should prefer the explicit-handle overloads.
- **Bidirectional client refcount on `DebraManager`** (via `nim-debra >= 0.5.0`). Queue constructors call `bindClient`; `=destroy` calls `unbindClient`. The manager's destructor asserts `clientCount == 0`, catching the case where a shared manager is destroyed before its queues.

### Changed

- Bump minimum `debra` to 0.5.0.
- Bump minimum `typestates` to 0.6.0.
- `src/lockfreequeues/atomic_dsl.nim` no longer defines a local `compareExchange` shim — it's now provided by `debra/atomics`.

### Documentation

- `README.md` "Thread safety" section rewritten with the correct explanation of why `ref` items are rejected (`=copy`/`=sink` hooks race on slot refcounts in the shared `array[S, T]`), replacing the prior incorrect spinlock claim.
- "Choosing a queue" table split into separate Bounded and Unbounded tables for better rendering.
- The same `{.error.}` strings inside `unbounded_*.nim` were updated to match.

### Fixed

- `docs/api/epoch.md` removed (referenced a module extracted into `nim-debra`); was breaking the `mkdocs build` step in the docs deploy workflow.
- `.github/workflows/docs.yml` triggers extended to include `devel` branch and `workflow_dispatch`.

## [4.0.0] - 2026-04-30

### BREAKING

- Bounded MPMC/SPMC/MPSC slot protocol switched to per-slot sequence counters (Vyukov bounded-MPMC). Fixes a confirmed race that allowed two consumers to claim the same physical slot across generations, producing silent duplicate-item delivery and producer-vs-producer storage races. The race was TSAN-confirmed at 100% reproduction and ran at roughly a 5% release-mode duplicate rate under contention.
- `Mupmuc`, `Mupsic`, `Sipmuc` types: the `committed*`, `reservedHead*`, `reservedTail*`, and `storage*` fields have been removed. They are replaced with `cells*: MPMCCellArrayN[N, T]`. Consumers introspecting these fields directly must migrate to the new accessors.
- `head` and `tail` cursors on the bounded queue types are now `Atomic[uint64]` instead of `Atomic[int]`. Code reading these via `.load(...)` will need an explicit cast or a local rename.
- Bulk `push(items)` / `pop(count)` semantics have changed. The previous implementation performed an atomic block-claim across the requested range; the new implementation performs a best-effort fill via a loop of singleton operations. Partial completion is reported through the existing `Option[Slice[int]]` / `Option[seq[T]]` return types, so the API surface is unchanged but the intra-call atomicity guarantee is gone.
- `CommittedFlagsN` type removed. Replaced with `SlotSeqN`, `MPMCCellPayload`, and `MPMCCellArrayN`. The `tests/t_committed_flags_n.nim` file has been deleted; equivalent and stronger coverage lives in `tests/t_slot_seq_n.nim`.

### Added

- New `lockfreequeues/backoff` module with `backoffOnRetry` (exponential) and `backoffOnPeerWait` (cpuPause-only) helpers. Used internally on CAS-retry paths to handle CPU oversubscription without burning unbounded CPU.
- Bench harness now supports the `Mupmuc` 8P/8C topology. The previous topology table was implicitly capped at 4P/4C.
- New `LFQ_STRESS_DURATION_SEC` environment variable on threaded stress tests, for sustained-load runs beyond the default iteration budget.
- New `tests/t_slot_seq_generation_rollover.nim`: a deterministic single-threaded reproduction of the original protocol-bug scenario, asserting that the new sequence-counter protocol rejects the stale second-consumer claim.
- Throughput bench harness for `UnboundedMupsic` (1P/1C, 2P/1C, 4P/1C) at `benchmarks/nim/bench_throughput.nim` plus a thin adapter at `benchmarks/nim/adapters/lockfreequeues_unbounded_mupsic.nim` that owns the queue and `DebraManager`. Producer threads register their own `ThreadHandle` in-thread (handles are per-thread by construction). The new variants run for 33 timed iterations + 3 warmup; existing Sipsic/Mupmuc/Channels run counts are unchanged.
- `bench_throughput` accepts variant-group args (`sipsic`, `mupmuc`, `unbounded_mupsic`, `channels`) to limit which benchmarks run. With no args, all variants run (backward compatible). Multiple args take the union of groups. Unknown args print the supported list and exit non-zero. Lets gate runs target a single queue family without paying for the slow bounded MPMC variants.
- Compile-time overrides for `bench_throughput` run shape via `{.intdefine.}` constants: `-d:MessageCount=N`, `-d:DefaultRuns=N`, `-d:WarmupRuns=N`, `-d:UnboundedMupsicRuns=N`, `-d:UnboundedMupsicSegmentSize=N`, `-d:UnboundedMupsicMaxThreads=N`. Defaults are unchanged (1M messages, 33 runs, 3 warmup). Lets gate runs trade statistical confidence for wall-clock budget without source edits. `bench_throughput` also unbuffers stdout in `isMainModule` so progress is visible under file redirect.

### Fixed

- Mupmuc 4P/4C livelock under CPU oversubscription. The combination of new backoff helpers and monotonic per-thread retry counters resolves the scheduler-pressure livelock; the bounded queue can now run 8 contending threads on 4 vCPUs without hangs.
- Bench harness `messageCount div P` truncation bug. Consumers waited forever for items the integer-division truncation had silently discarded. Spread-the-remainder fix applied in three places.
- Several pre-existing breakages in the unbounded threaded stress tests. The 3.2.0 DEBRA migration left them on a deleted `EpochManager` API; the tests have been updated to the current handle-based API. A small number remain disabled pending separate cleanup.

### Changed

- Bounded queue documentation updated to reflect the new sequence-counter publication protocol. Unbounded queue documentation now explicitly disambiguates the segment-local committed-flag protocol from the bounded sequence-counter protocol. See `docs/safety-model.md` and `docs/slot-ownership-typestates.md`.

## [3.2.0] - 2026-04-27

### Added

- New queue types:
  - `Sipmuc`: bounded single-producer, multi-consumer queue.
  - `UnboundedSipsic`: segmented unbounded single-producer, single-consumer queue (no reclamation needed).
  - `UnboundedSipmuc`: segmented unbounded single-producer, multi-consumer queue with DEBRA reclamation.
  - `UnboundedMupsic`: segmented unbounded multi-producer, single-consumer queue with DEBRA reclamation.
  - `UnboundedMupmuc`: segmented unbounded multi-producer, multi-consumer queue with DEBRA reclamation.
  - Segment storage uses libc `c_calloc` / `c_free` (via `system/ansi_c`); a nil return from `c_calloc` raises `OutOfMemDefect`. Avoids the cross-thread free hazard from Nim's `allocShared`, which routes through per-thread heap metadata.
  - The consumer-visible head pointer is `Atomic[ptr Segment]` and is CAS-advanced past exhausted segments; the CAS winner retires the old segment via DEBRA.
- Typestate-driven push and pop modules under `src/lockfreequeues/typestates/` for both bounded and unbounded queues. The high-level queue APIs now build on these typestate transitions.
- `DeallocationStrategy` (`Manual` / `Eager`) on the unbounded queues, configured at queue construction. `Eager` retires and immediately attempts reclamation per pop; `Manual` accumulates retired segments for an external `tryReclaim` call. Default is `Eager`, except `Manual` under `--gc:none`.
- Compile-time `-d:LockFreeQueuesAdvanceEvery=N` (default 64) to tune the per-pop epoch-advance cadence in the unbounded queue retirement paths.
- Compile-time lock-free check for queue item types: arc/orc compilation errors when a queue holds `ref` items (which fall back to spinlock refcounting on those memory managers). Opt out with `-d:allowNonLockFreeQueueItems`.
- Threaded reclamation tests for all four unbounded queue variants (`t_unbounded_*_threaded`), exercised under arc, orc, and refc, plus the TSAN and ASAN sanitizer matrix.
- Latency and throughput benchmark suite under `benchmarks/nim/` (`bench_latency.nim`, `bench_throughput.nim`, `bench_main.nim`) with adapters for each queue type.
- New examples: `audio_buffer.nim`, `event_collector.nim`, `job_scheduler.nim`, `task_fanout.nim`, and `sipmuc.nim`.
- Thread safety section and slot-ownership typestate documentation in README.
- CI matrix across arc, orc, and refc memory managers, including a `-d:nimEnforceLockFreeAtomics` lane.
- Dependency on `debra >= 0.3.0` for safe memory reclamation in the unbounded multi-consumer queues.
- Dependency on `typestates >= 0.3.1` (already used; bumped to pull in the latest API).

### Changed

- Eager-strategy unbounded queues now gate `reclaimNow` on `advanceEvery` returning `true`, eliminating per-pop epoch-safety atomic loads when the global epoch hasn't advanced. Reclamation latency is bounded by `LockFreeQueuesAdvanceEvery` (default 64), the same cadence the user already controls.
- Bounded queues (`Sipsic`, `Mupsic`, `Mupmuc`) reimplemented on the typestate layer. SPSC uses N+1 storage slots to distinguish empty from full; MPSC, SPMC, and MPMC use N storage slots paired with per-slot committed flags so producers can publish before consumers observe the slot. Surface API (push/pop, `head`/`tail`, capacity semantics) is unchanged for SPSC; the multi-producer / multi-consumer variants gain a published-before-visible ordering guarantee they did not previously provide.
- `atomic_dsl.nim` now re-exports `debra/atomics` instead of wrapping `std/atomics`. Call-site DSL (`relaxed`, `acquire`, `release`, `sequential`) is unchanged.
- Stress test runner exercises all three memory managers.

### Removed

- `std/atomics` dependency. `Atomic[T]` and the memory-order primitives are now sourced from `debra/atomics`.
- `src/lockfreequeues/constants.nim`. `CacheLineBytes` is now sourced from `debra/atomics`.
- Removed the internal `lockfreequeues/ops` submodule. It was documented as internal, had no callers inside the library, and its `index` helper had silently shifted from `value mod capacity` (3.1.0) to `value mod (capacity + 1)` during the queue refactor. External code that imported `lockfreequeues/ops` directly should migrate to the public typestate API or inline the small helpers it contained.

## [3.1.0] - 2024-09-28

### Changed

- Fixed wraparound issue in `full()`
- Drop support for Nim v1 due to compilation issue with atomics.

## [3.0.0] - 2021-12-14

### Added

- README link to Gitter chat room.

### Changed

- Regenerate documentation on PR merge.
- Test against Nim 1.6.0.
- Convert `NoConsumersAvailableDefect` and `NoProducersAvailableDefect` to `CatchableErrors`; there might be some value in catching them.

### Removed

## [2.1.0] - 2021-07-19

### Added

### Changed

- Use correct memory orderings, as reported in https://github.com/elijahr/lockfreequeues/issues/6
- Move changelog from README.md to CHANGELOG.md

### Removed

## [2.0.6] - 2021-01-25

### Added

### Changed

- Fix issue with htmldocs submodule during `nimble install lockfreequeues`.

### Removed

## [2.0.5] - 2021-01-06

### Added

### Changed

- Moved from Travis CI to GitHub Actions.

### Removed

## [2.0.4] - 2020-08-10

### Added

- Multi-producer, single-consumer queue (Mupsic)
- Multi-producer, multi-consumer queue (Mupmuc)
- Nicer examples

### Changed

- Refactor
- Fix wrap-around bug, improve test coverage

### Removed

- Shared memory queues

## [1.0.0] - 2020-07-06

### Added

### Changed

- Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
- `head` and `tail` are now in the range `0 ..<2*capacity`
- `capacity` doesn’t have to be a power of two
- Use `align` pragma instead of padding array

### Removed

## [0.1.0] - 2020-07-02

### Added

- Initial release, containing `SipsicSharedQueue` and `SipsicStaticQueue`

### Changed

### Removed
