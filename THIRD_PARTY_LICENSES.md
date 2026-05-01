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
- **Vendored at:** `docs/assets/uplot-1.6.27.iife.min.js`
- **Upgrade procedure:** download the new IIFE bundle from
  `https://cdn.jsdelivr.net/npm/uplot@<new-version>/dist/uPlot.iife.min.js`,
  rename the file with the new version suffix, update the
  `<script src=...>` reference in `docs/benchmarks.md`, update the
  `Version:` field above, and verify SHA-256 against jsdelivr's
  package metadata (`https://data.jsdelivr.com/v1/package/npm/uplot@<new-version>`).
  Delete the old version's file in the same commit.

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
