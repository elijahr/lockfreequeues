# Item 2 — Interactive HTML+JS graphs in README

**Tier:** MEDIUM. Depends on Item 1 (`.claude/prompts/03-comparison-libs-bench.md`).

**Source:** `~/lockfreequeues-bench-comparison-followups.md` Item 2 (lines 206-315).

User picked Plotly/uPlot/Chart.js. Recommendation: **uPlot** for size/perf if data is purely line/bar; **Plotly** if you want richer interaction (hover-detail tables, zoom, range sliders) and don't mind the ~2MB bundle.

## CRITICAL pre-work — reconcile the two-pipeline mess

The repo has TWO completely disconnected bench pipelines. Item 1's design doc must pick a target end state; Item 2 implementation depends on it.

### Old pipeline (pre-PR-#14, still active)

1. `nimble benchmarks` runs the suite locally (manual).
2. Output → `benchmarks/results/latest.json`.
3. `nim r benchmarks/render_readme.nim` rewrites the table between `<!-- BENCHMARKS:start -->` / `<!-- BENCHMARKS:end -->` markers in `README.md`.
4. Maintainer commits both files by hand.
5. **Nothing in CI does any of this.** The README numbers in `devel` as of PR #14 merge are from `2025-12-03T22:24:55Z` on a maintainer's macOS arm64 laptop, lockfreequeues 3.1.0.

### New pipeline (PR #14)

1. `bench.yml` runs `bench_throughput` on `ubuntu-latest`.
2. `bmf_adapter.py` converts to BMF JSON.
3. `bencher run` uploads to Bencher.dev project `lockfreequeues`.
4. Bencher posts PR comparison comments and stores history.
5. **README is never touched.**

### Three options (Item 1 design doc must pick one)

a. **Cloud is canonical, kill local pipeline.** Delete `benchmarks/results/`, `benchmarks/render_readme.nim`, `benchmarks/runner.py`, the `nimble benchmarks` task. Replace README's `<!-- BENCHMARKS:start -->` block with a static table sourced from cloud + link to interactive graph + link to Bencher dashboard. Cleanest end state but loses local reproducibility.
b. **Keep both, wire CI to auto-update README from cloud.** On every `devel` push, after Bencher upload, regenerate `benchmarks/results/latest.json` from BMF JSON, run `render_readme.nim`, commit with `[skip ci]`. Local `nimble benchmarks` still works for ad-hoc runs but committed numbers always come from CI. Cost: self-pushing commit on merge.
c. **Keep both as separate stories.** README numbers stay maintainer-curated; Bencher dashboard is the authoritative cross-platform comparison, linked from README. Lowest change, highest confusion.

**Lean (a) or (b).** Don't ship comparison-library work without resolving this — otherwise comparison numbers exist in three places (Bencher, README table, methodology doc) with no clear source of truth.

## Goal (assumes (a) or (b) chosen)

Self-contained HTML page (committed to repo, served via GitHub Pages or referenced from README via raw GitHub link) showing:

- Throughput by topology (one chart per SPSC/MPSC/MPMC, x-axis = producer/consumer count, y-axis = ops/ms, one line per library).
- Bounded vs unbounded as separate charts (don't mix on one axis).
- Click-to-toggle libraries on/off.
- Hover for exact numbers + stddev.
- Footer noting CI runner specs, Nim version, message size, capacity, cross-platform applicability caveat.

## Data source

Two viable approaches:

- **Bencher API**: query `https://api.bencher.dev/v0/projects/lockfreequeues/...` in CI, render to JSON, commit alongside HTML. Authoritative and versioned upstream.
- **BMF JSON in repo**: bench workflow on `devel` writes BMF JSON to `docs/bench-results/<sha>.json` (and updates a `latest.json` symlink) on every merge. Static, easy to render, easy to diff.

**Lean second** — simpler, avoids tying README rendering to Bencher API availability.

## README integration

Replace the existing `<!-- BENCHMARKS:start --> ... <!-- BENCHMARKS:end -->` markers with: (1) a static summary table for at-a-glance, (2) a link to the interactive HTML page, (3) a link to the live Bencher dashboard.

## Out of scope

- A full benchmark dashboard that replicates Bencher's PR comparison UI. Bencher does that; don't reinvent.
- Real-time updates. Static commit-on-merge is fine.
- Mobile responsiveness beyond what the chart library gives for free.

## Kickoff prompt

```
/develop

Build interactive HTML+JS graphs in the README per
~/lockfreequeues-bench-comparison-followups.md Item 2. See
.claude/prompts/04-interactive-graphs.md for context.

DEPENDS ON Item 1 (.claude/prompts/03-comparison-libs-bench.md). The
Item 1 design doc must have already resolved the two-pipeline mess
(option a, b, or c). If not, do that first or stop and surface.

MEDIUM tier; design doc covers chart library choice (uPlot vs Plotly),
data source (Bencher API vs in-repo BMF JSON), and README integration
shape. Lean uPlot + in-repo BMF JSON.
```
