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
- **Version:** `0.3.1` (resolved by `nimble install loony` in bench CI;
  the resolved version is also recorded at run time in the bench JSON
  `meta.adapters.loony.version` field — see Item 1).
- **License:** MIT
- **Vendored at:** _(not vendored — resolved at build time via Nimble)_
- **Upgrade procedure:** _(nimble-managed; Loony is not listed in the
  root `lockfreequeues.nimble` manifest because the package is a
  benchmark-only optional adapter, gated by
  `-d:adapter_loony_available`. The bench CI workflow runs
  `nimble install loony` immediately before the bench compile step.
  Production-dep pinning is via the committed `nimble.lock` at the
  root of this repository, which covers nim, unittest2, typestates,
  and debra. To pin Loony for a deterministic local bench, run
  `nimble install loony@<version>` before invoking `nimble benchmarks`.)_

### Boost.LockFree

- **Source:** https://www.boost.org/libs/lockfree/
- **Version:** Whichever version is provided by the system package
  (`apt install libboost-dev` on Ubuntu CI; `brew install boost` on
  macOS dev). The bench adapter is API-compatible with all Boost
  versions that ship `boost/lockfree/queue.hpp` and
  `boost/lockfree/spsc_queue.hpp`. The exact version is **captured at
  run time** into each bench JSON's
  `meta.adapters.boost_lockfree.version` field via the
  `BOOST_LIB_VERSION` macro from `boost/version.hpp` — see
  [`benchmarks/README.md`](benchmarks/README.md) "Version capture and
  pinning" for the cross-run comparison protocol.
- **License:** Boost Software License 1.0 (BSL-1.0)
- **Vendored at:** _(not vendored — system include path)_
- **Upgrade procedure:** _(not applicable; OS-package-managed. Mismatched
  `meta.adapters.boost_lockfree.version` between two bench JSONs
  indicates the OS image bumped Boost; throughput comparisons across
  that boundary are not apples-to-apples.)_

### Crossbeam

- **Source:** https://github.com/crossbeam-rs/crossbeam
- **Version:** `crossbeam-queue 0.3.x` (pinned by
  `benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`; recorded in the
  generated `Cargo.lock` at build time)
- **License:** Apache-2.0 OR MIT (choose either)
- **Vendored at:** _(crate sources are downloaded by Cargo at build
  time; only our own thin C-ABI shim under
  `benchmarks/rust/bench-ffi-crossbeam/` is committed)_
- **Upgrade procedure:** bump the `crossbeam-queue` version in
  `benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`, run `cargo build`
  to refresh `Cargo.lock`, run the integration tests
  (`cargo test --release --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`)
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
- **Version:** `0.2.x` (resolved by `nimble install threading` in bench
  CI; the resolved version is also recorded at run time in the bench
  JSON `meta.adapters.threading.version` field — see Item 1).
- **License:** MIT
- **Vendored at:** _(not vendored — resolved at build time via
  Nimble)_
- **Upgrade procedure:** _(nimble-managed; same rationale as Loony
  above — `threading` is a bench-only optional adapter gated by
  `-d:adapter_threading_channels_available`, so it is not listed in
  the root `lockfreequeues.nimble` manifest. Production deps are
  pinned via `nimble.lock`.)_

### Nim system.Channel (stdlib)

- **Source:** https://nim-lang.org (built into the `system/channels`
  module of the Nim compiler distribution).
- **Version:** _(matches the Nim compiler version — currently the
  `jiro4989/setup-nim-action` `stable` channel)._
- **License:** MIT (Nim compiler license)
- **Vendored at:** _(not vendored — built into the Nim compiler)_
- **Upgrade procedure:** _(not applicable; tracks Nim compiler)_

## Comparison expansion libraries (v5.0.0)

v5.0.0 adds four more vendored C/C++ comparison targets (`atomic_queue`,
`liblfds`, `rigtorp_mpmc`, `rigtorp_spsc`) and two additional Rust
crates that ride alongside `crossbeam-queue` in the existing
`bench-ffi-crossbeam` cdylib (`flume`, `kanal`). The benchmark adapter
code (`benchmarks/nim/adapters/<lib>_adapter.nim` and the C/C++
wrappers in each vendor directory) is original `lockfreequeues` source
under Apache-2.0.

### atomic_queue (max0x7ba)

- **Source:** https://github.com/max0x7ba/atomic_queue
- **Version:** commit `1a3774a89c86ecfdf08753dbd41018ace5a833a4`
  (head of upstream `master` on the v4.2.0 vendoring date).
- **License:** MIT
- **Vendored at:** `benchmarks/vendor/atomic_queue/`
- **Upgrade procedure:** see
  `benchmarks/vendor/atomic_queue/README.md`

### liblfds (7.1.1)

- **Source:** https://liblfds.org/ (mirrored at
  https://github.com/darthcloud/liblfds7.1.1)
- **Version:** `7.1.1` (upstream release tag; the canonical
  `liblfds/liblfds7.1.1` GitHub mirror was retired, so the vendoring
  uses two content-identical community mirrors cross-checked at
  vendoring time — see `benchmarks/vendor/liblfds/README.md`).
- **License:** public-domain dedication with an explicit multi-grant
  (MIT, BSD, Apache, GPL/LGPL, Creative Commons) per the upstream
  homepage. `lockfreequeues` consumes liblfds under the Apache-2.0
  grant from that list (matches the project's own Apache-2.0 license)
  and under the public-domain dedication. The verbatim grant text is
  preserved in `benchmarks/vendor/liblfds/LICENSE`.
- **Vendored at:** `benchmarks/vendor/liblfds/liblfds711/` (full
  upstream source tree, unmodified).
- **Upgrade procedure:** see
  `benchmarks/vendor/liblfds/README.md`

### rigtorp::mpmc::Queue

- **Source:** https://github.com/rigtorp/MPMCQueue
- **Version:** commit `b9808ede08f26fa9df4df4e081d19cace8f6c6ea`
  (head of upstream `master` on the v4.2.0 vendoring date).
- **License:** MIT
- **Vendored at:** `benchmarks/vendor/rigtorp_mpmc/`
- **Upgrade procedure:** see
  `benchmarks/vendor/rigtorp_mpmc/README.md`

### rigtorp::SPSCQueue

- **Source:** https://github.com/rigtorp/SPSCQueue
- **Version:** commit `1053918dbd251fbff69b24ef27fa5d51c29ec2af`
  (head of upstream `master` on the v4.2.0 vendoring date).
- **License:** MIT
- **Vendored at:** `benchmarks/vendor/rigtorp_spsc/`
- **Upgrade procedure:** see
  `benchmarks/vendor/rigtorp_spsc/README.md`

### flume (Rust crate)

- **Source:** https://github.com/zesterer/flume
- **Version:** `0.11.1` (resolved from the `flume = "0.11"` requirement
  in `benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`; the exact
  resolved version is recorded in
  `benchmarks/rust/bench-ffi-crossbeam/Cargo.lock`).
- **License:** Apache-2.0 OR MIT (choose either; `lockfreequeues`
  takes Apache-2.0 to match the project license).
- **Vendored at:** _(crate sources are downloaded by Cargo at build
  time; only our own thin C-ABI shim under
  `benchmarks/rust/bench-ffi-crossbeam/` is committed)_
- **Upgrade procedure:** bump the `flume` version in
  `benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`, run
  `cargo build --release` to refresh `Cargo.lock`, run the integration
  tests
  (`cargo test --release --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`)
  and the Nim round-trip suite with the `flume` adapter gate enabled.

### kanal (Rust crate)

- **Source:** https://github.com/fereidani/kanal
- **Version:** `0.1.1` (resolved from the `kanal = "0.1"` requirement
  in `benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`; the exact
  resolved version is recorded in
  `benchmarks/rust/bench-ffi-crossbeam/Cargo.lock`).
- **License:** MIT
- **Vendored at:** _(crate sources are downloaded by Cargo at build
  time; only our own thin C-ABI shim under
  `benchmarks/rust/bench-ffi-crossbeam/` is committed)_
- **Upgrade procedure:** bump the `kanal` version in
  `benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`, run
  `cargo build --release` to refresh `Cargo.lock`, run the integration
  tests
  (`cargo test --release --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`)
  and the Nim round-trip suite with the `kanal` adapter gate enabled.
