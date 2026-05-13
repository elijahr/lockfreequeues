# Third-Party Licenses

`lockfreequeues` itself is licensed under Apache-2.0 (see `LICENSE`).
The benchmark suite (under `benchmarks/`) compares `lockfreequeues`
against several upstream queue libraries; this file records the license
obligations for each one.

This file is the canonical home for vendored / linked third-party code
notices. Per [`benchmarks/README.md`](benchmarks/README.md), each entry
records source, version, license, vendored path (if any), and upgrade
procedure (if any).

Per-vendor block schema:

```markdown
### <Library Name>

- **Source:** https://github.com/<owner>/<repo>
- **Version:** commit `<sha>` (vendored sources) or `<x.y.z>` (tagged releases)
- **License:** <SPDX identifier>
- **Vendored at:** `<repo-relative path>` (omit if not vendored)
- **Upgrade procedure:** see `<repo-relative path>/README.md` (omit if not vendored)
```

## Comparison MVP libraries (PR 3)

The libraries below are linked at compile time by the bench suite when
the relevant `-d:adapter_*_available` gate is set; their source is NOT
vendored into this repository. The benchmark adapter code (under
`benchmarks/nim/adapters/<lib>_adapter.nim`) is original
`lockfreequeues` source and inherits the project's Apache-2.0 license.

### Loony

- **Source:** https://github.com/shayanhabibi/loony
- **Version:** `0.3.1` (resolved by `nimble install loony`; see
  `nimble.lock` if pinned by a downstream consumer)
- **License:** MIT
- **Vendored at:** _(not vendored — resolved at build time via Nimble)_
- **Upgrade procedure:** _(not applicable; nimble-managed)_

### Boost.LockFree

- **Source:** https://www.boost.org/libs/lockfree/
- **Version:** Whichever version is provided by the system package
  (`apt install libboost-dev` on Ubuntu CI; `brew install boost` on
  macOS dev). The bench adapter is API-compatible with all Boost
  versions that ship `boost/lockfree/queue.hpp` and
  `boost/lockfree/spsc_queue.hpp`.
- **License:** Boost Software License 1.0 (BSL-1.0)
- **Vendored at:** _(not vendored — system include path)_
- **Upgrade procedure:** _(not applicable; OS-package-managed)_

### Crossbeam

- **Source:** https://github.com/crossbeam-rs/crossbeam
- **Version:** `crossbeam-queue 0.3.x` (pinned by
  `benchmarks/rust/comparison/Cargo.toml`; recorded in the
  generated `Cargo.lock` at build time). The crate path was renamed
  from `bench-ffi-crossbeam` in v4.2.0 Stage 5.2 when flume + kanal
  were folded into the same consolidated cdylib.
- **License:** Apache-2.0 OR MIT (choose either)
- **Vendored at:** _(crate sources are downloaded by Cargo at build
  time; only our own thin C-ABI shim under
  `benchmarks/rust/comparison/` is committed)_
- **Upgrade procedure:** bump the `crossbeam-queue` version in
  `benchmarks/rust/comparison/Cargo.toml`, run `cargo build`
  to refresh `Cargo.lock`, run the integration tests
  (`cargo test --release --manifest-path benchmarks/rust/comparison/Cargo.toml`)
  and the Nim round-trip suite (`tests/t_bench_adapters.nim` with the
  crossbeam gates).

## Docs site charting (PR 5)

The docs site under `docs/` ships an interactive throughput chart
(`docs/benchmarks.md`) that renders via the vendored uPlot bundle
below. The chart wiring (`docs/assets/bench-charts.js` +
`docs/assets/bench-charts.css`) is original `lockfreequeues` source
and inherits the project's MIT license.

### uPlot

- **Source:** https://github.com/leeoniya/uPlot
- **Version:** `1.6.27`
- **License:** MIT
- **Vendored at:**
  - `docs/assets/uplot-1.6.27.iife.min.js` (chart runtime)
  - `docs/assets/uplot-1.6.27.min.css` (companion stylesheet for axes /
    grid lines / cursor; without it uPlot DOM elements stack incorrectly)
- **Upgrade procedure:** download both bundles from
  `https://cdn.jsdelivr.net/npm/uplot@<new-version>/dist/uPlot.iife.min.js`
  and `.../dist/uPlot.min.css`, rename each with the new version suffix,
  update the `<script src=...>` reference in `docs/benchmarks.md` (the
  CSS is loaded via `extra_css` in `mkdocs.yml`, not a `<link>` tag —
  bump both the `extra_css` entry and the bundle filename in lockstep),
  update the version-suffixed filenames in
  `benchmarks/tests/test_bench_charts_contract.py`
  (`test_chart_assets_present` checks the literal filename), update the
  `Version:` field above, and verify SHA-256 against jsdelivr's
  package metadata (`https://data.jsdelivr.com/v1/package/npm/uplot@<new-version>`).
  Delete the old version's files in the same commit.

## Comparison expansion libraries (PR 4)

PR 4 adds three more comparison adapters; one is vendored
(`concurrentqueue`), the other two are linked at compile time without
vendoring (Nim's stdlib `system.Channel` is built into the compiler;
the nimble `threading` package is resolved at build time).

### concurrentqueue (MoodyCamel)

- **Source:** https://github.com/cameron314/concurrentqueue
- **Version:** commit
  `d655418bb644b7f85159d94c591d7d983949fb81` (vendored at PR 4
  implementation time; see
  `benchmarks/vendor/concurrentqueue/README.md` for the upgrade
  procedure and rationale).
- **License:** BSD-2-Clause / Boost Software License 1.0 (dual)
- **Vendored at:** `benchmarks/vendor/concurrentqueue/`
- **Upgrade procedure:** see
  `benchmarks/vendor/concurrentqueue/README.md`

### threading (nimble package)

- **Source:** https://github.com/nim-lang/threading
- **Version:** `0.2.x` (resolved by `nimble install threading`; the
  bench CI step records the resolved SHA in the workflow log).
- **License:** MIT
- **Vendored at:** _(not vendored — resolved at build time via
  Nimble)_
- **Upgrade procedure:** _(not applicable; nimble-managed)_

### Nim system.Channel (stdlib)

- **Source:** https://nim-lang.org (built into the `system/channels`
  module of the Nim compiler distribution).
- **Version:** _(matches the Nim compiler version — currently the
  `jiro4989/setup-nim-action` `stable` channel)._
- **License:** MIT (Nim compiler license)
- **Vendored at:** _(not vendored — built into the Nim compiler)_
- **Upgrade procedure:** _(not applicable; tracks Nim compiler)_

## Tier 1 vendored comparison libraries (v4.2.0 Stage 5.1)

Three header-only C++ queue libraries vendored to broaden the bench
suite's coverage of bounded SPSC and bounded MPMC alternatives. Each is
consumed via a thin `extern "C"` wrapper that reduces the templated C++
surface to four `uint64_t`-payload functions — same shim pattern as
`concurrentqueue` (MoodyCamel) above.

### atomic_queue (max0x7ba)

- **Source:** https://github.com/max0x7ba/atomic_queue
- **Version:** commit
  `1a3774a89c86ecfdf08753dbd41018ace5a833a4` (vendored at v4.2.0
  Stage 5.1 implementation time; see
  `benchmarks/vendor/atomic_queue/README.md` for the upgrade
  procedure and rationale).
- **License:** MIT
- **Vendored at:** `benchmarks/vendor/atomic_queue/`
- **Upgrade procedure:** see
  `benchmarks/vendor/atomic_queue/README.md`

### rigtorp/SPSCQueue

- **Source:** https://github.com/rigtorp/SPSCQueue
- **Version:** commit
  `1053918dbd251fbff69b24ef27fa5d51c29ec2af` (vendored at v4.2.0
  Stage 5.1 implementation time).
- **License:** MIT
- **Vendored at:** `benchmarks/vendor/rigtorp_spsc/`
- **Upgrade procedure:** see
  `benchmarks/vendor/rigtorp_spsc/README.md`

### rigtorp/MPMCQueue

- **Source:** https://github.com/rigtorp/MPMCQueue
- **Version:** commit
  `b9808ede08f26fa9df4df4e081d19cace8f6c6ea` (vendored at v4.2.0
  Stage 5.1 implementation time).
- **License:** MIT
- **Vendored at:** `benchmarks/vendor/rigtorp_mpmc/`
- **Upgrade procedure:** see
  `benchmarks/vendor/rigtorp_mpmc/README.md`

## Tier 2 Rust comparison libraries (v4.2.0 Stage 5.2)

Two additional Rust queue crates folded into the consolidated
`bench_ffi_comparison` cdylib alongside crossbeam (see the Crossbeam
block above for the renamed crate path and shared cdylib rationale).
Crate sources are not vendored — Cargo resolves them from crates.io at
build time and pins the resolved versions in `Cargo.lock`.

### flume

- **Source:** https://github.com/zesterer/flume
- **Version:** `flume 0.11.x` (pinned by
  `benchmarks/rust/comparison/Cargo.toml`; resolved version recorded
  in `Cargo.lock` at build time).
- **License:** Apache-2.0 OR MIT (choose either)
- **Vendored at:** _(crate sources downloaded by Cargo at build time;
  only our own thin C-ABI shim under
  `benchmarks/rust/comparison/src/lib.rs` is committed)_
- **Upgrade procedure:** bump the `flume` version in
  `benchmarks/rust/comparison/Cargo.toml`, run
  `cargo build --release --manifest-path benchmarks/rust/comparison/Cargo.toml`
  to refresh `Cargo.lock`, re-run `smoke_comparison.nim` with
  `-d:adapter_flume_available` to verify the four `flume_*` /
  `flume_unbounded_*` symbols still resolve.

### kanal

- **Source:** https://github.com/fereidani/kanal
- **Version:** `kanal 0.1.x` (pinned by
  `benchmarks/rust/comparison/Cargo.toml`; resolved version recorded
  in `Cargo.lock` at build time).
- **License:** MIT
- **Vendored at:** _(crate sources downloaded by Cargo at build time;
  only our own thin C-ABI shim under
  `benchmarks/rust/comparison/src/lib.rs` is committed)_
- **Upgrade procedure:** bump the `kanal` version in
  `benchmarks/rust/comparison/Cargo.toml`, run
  `cargo build --release --manifest-path benchmarks/rust/comparison/Cargo.toml`
  to refresh `Cargo.lock`, re-run `smoke_comparison.nim` with
  `-d:adapter_kanal_available` to verify the four `kanal_*` /
  `kanal_unbounded_*` symbols still resolve.

## Tier 3 vendored comparison library (v4.2.0 Stage 5.3)

A full C source tree (rather than a header-only library) vendored
under a license-verification gate. liblfds is widely used (per the
upstream homepage, "Current users include AT&T, Red Hat and Xen") and
covers a different design point — a pure-C ringbuffer / bounded queue
family — than every other Tier 1 / Tier 2 / Tier 4 comparison adapter
in the suite. The license declaration was cross-checked against three
independent sources before the source was vendored; see the block below
for the full audit trail.

### liblfds

- **Source (project home):** <https://liblfds.org/>
- **Source (mirror used for vendoring):**
  <https://github.com/darthcloud/liblfds7.1.1> (a content-identical
  Git mirror of the upstream `liblfds7.1.1` release; the canonical
  GitHub mirror at `https://github.com/liblfds/liblfds7.1.1` has been
  replaced by a one-line README pointing at `liblfds.org` after the
  project moved off GitHub. A second independent mirror —
  `https://github.com/topecongiro/liblfds7.1.1` — was diff-checked
  byte-for-byte at vendoring time and produced identical content.).
- **Version:** release `7.1.1` (the upstream's bug-fix release that
  supersedes 7.1.0).
- **License:** **public domain** + permissive grant (MIT/BSD/Apache/
  GPL/LGPL/Creative Commons), per the upstream homepage. The upstream
  source tree itself ships **no LICENSE file**; the canonical license
  declaration lives only on `liblfds.org`. The full declaration is
  quoted verbatim below from
  <https://www.liblfds.org/> (retrieved 2026-05-06):
- **Vendored at:** `benchmarks/vendor/liblfds/`
- **Upgrade procedure:** see
  `benchmarks/vendor/liblfds/README.md`
- **Cross-checks consulted at vendoring time:**
  - Upstream homepage <https://www.liblfds.org/> — canonical license
    declaration (quoted in full below).
  - Repology project page
    <https://repology.org/project/liblfds/information> — listed as
    `custom:none`, consistent with the upstream's "no SPDX-recognised
    license; everything is public domain" stance and not contradicting
    the homepage declaration.
  - GitHub mirror tree
    <https://github.com/darthcloud/liblfds7.1.1> — diff-checked
    against `https://github.com/topecongiro/liblfds7.1.1` for source
    integrity. Neither mirror's `liblfds7.1.1/` subtree contains a
    `LICENSE`, `COPYING`, or `UNLICENSE` file; this is consistent with
    the upstream homepage's stance ("license-free, ... placed in the
    public domain").
  - All three sources agree (the homepage is authoritative; the other
    two corroborate without contradiction). Public-domain dedication
    + the explicit Apache-2.0 grant from the homepage list satisfies
    `lockfreequeues`'s own Apache-2.0-licensed re-distribution path.

#### Full upstream license declaration (verbatim)

Quoted verbatim from <https://www.liblfds.org/>, retrieved 2026-05-06:

> Welcome to liblfds, a portable, license-free, lock-free data
> structure library written in C.
>
> license
>
> You are free to use this library in any way. Go forth and create
> wealth!
>
> If for legal reasons a custom licence is required, the license of
> your choice will be granted, and license is hereby granted up front
> for a range of popular licenses : the MIT license, the BSD license,
> the Apache license, the GPL and LPGL (all versions thereof) and the
> Creative Commons licenses (all of them). Additionally, everything is
> also placed in the public domain.

The same text is preserved in `benchmarks/vendor/liblfds/LICENSE` so
the audit trail is recoverable from the vendored tree alone.
