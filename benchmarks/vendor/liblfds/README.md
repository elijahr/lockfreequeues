# Vendored: `liblfds` 7.1.1

This directory vendors the C source tree of liblfds 7.1.1 — a portable,
license-free, lock-free data structure library — so the v4.2.0 bench
suite can compare `lockfreequeues` against a long-standing C-language
bounded-queue implementation without a system-package or build-time
network dependency.

## Pinned upstream

- **Upstream homepage:** <https://liblfds.org/>
- **Upstream release tag:** `7.1.1` (the `liblfds7.1.1` upstream repo).
- **Source mirror used for vendoring:**
  <https://github.com/darthcloud/liblfds7.1.1> (the canonical
  `https://github.com/liblfds/liblfds7.1.1` mirror has been replaced by
  a one-line README pointing at `liblfds.org` after the project moved
  off GitHub; `darthcloud/liblfds7.1.1` is a content-identical mirror
  of the 7.1.1 source. A second independent mirror —
  `https://github.com/topecongiro/liblfds7.1.1` — was diff-checked at
  vendoring time and produced byte-identical content.).
- **License:** public-domain + permissive grant (MIT/BSD/Apache/
  GPL/LGPL/Creative Commons), per the upstream homepage. See
  `LICENSE` in this directory for the full declaration quoted verbatim
  from <https://www.liblfds.org/>.

## What is vendored

The full `liblfds711/` source tree from upstream — `inc/`, `src/`,
`build/`, plus empty `bin/` and `obj/` placeholders so the upstream
Makefile's `mkdir -p` is unnecessary on first build. No upstream files
were modified.

| File / dir                              | Origin                                        |
| --------------------------------------- | --------------------------------------------- |
| `liblfds711/inc/`                       | upstream at the pinned release                |
| `liblfds711/src/`                       | upstream at the pinned release                |
| `liblfds711/build/`                     | upstream at the pinned release (Makefiles)    |
| `LICENSE`                               | original (synthesized; see note below)        |
| `README.md`                             | original `lockfreequeues` source (this file)  |

Note on `LICENSE`: the upstream tree ships **no** `LICENSE` file. The
canonical license declaration lives on the project homepage and is
quoted verbatim in our own `LICENSE` file in this directory so the
license trail is recoverable from the vendored tree alone.

## Adapter wiring

Unlike the other Tier 1 libraries (`atomic_queue`, `rigtorp_*`,
`concurrentqueue`), liblfds is plain C — there is no C++ wrapper file
in this directory. The Nim adapter
(`benchmarks/nim/adapters/liblfds_adapter.nim`) imports the upstream C
symbols directly via `{.importc.}` and links against the pre-built
`liblfds711.a` static archive that the bench CI step produces from
this tree's Makefile.

The adapter exposes both bounded SPSC and bounded MPMC slugs:

- `liblfds/spsc/1p1c` (using `lfds711_queue_bss_*` — single-producer
  single-consumer bounded queue with proper back-pressure semantics).
- `liblfds/mpmc/{1,2,4}p{1,2,4}c` (using `lfds711_queue_bmm_*` —
  Vyukov-style bounded MPMC).

Note: the impl plan originally proposed `lfds711_ringbuffer_*`. The
ringbuffer API is intentionally back-pressure-free: it overwrites the
oldest element on full rather than reporting failure. That semantic
breaks the bench harness's "messages produced equals messages
consumed" invariant, so the adapter uses the bounded queue APIs (`bss`
+ `bmm`), which return `0` on full and let the harness apply the same
backoff loop it uses for every other adapter.

## Build invocation

The upstream Makefile lives at
`liblfds711/build/gcc_gnumake/Makefile` and produces
`liblfds711/bin/liblfds711.a` and a matching `.so`. The CI step builds
the static archive only:

```bash
cd benchmarks/vendor/liblfds/liblfds711/build/gcc_gnumake
make ar_rel
```

On Linux the build is straightforward. On macOS the upstream porting
abstraction layer's OS detection only fires for `__linux__` or
`_WIN32` — no Darwin branch — so a local-development build needs
`CFLAGS='-D__linux__ -fPIC' DGFLAGS='-D__linux__'` overrides; see the
local-smoke recipe at the bottom of this README. CI runs on Ubuntu and
hits the native `__linux__` branch directly.

## Upgrade procedure

1. Pick the desired upstream release (e.g. 7.2.0 when published).
2. Clone a content-identical mirror of the new release. From a scratch
   directory:
   ```bash
   git clone --depth 1 https://github.com/<mirror>/liblfds7.x.y \
     liblfds-upstream
   cd liblfds-upstream
   git rev-parse HEAD
   ```
3. Diff-check at least one second independent mirror byte-for-byte so
   we don't pick up a tampered tree.
4. Re-fetch the upstream homepage and confirm the license declaration
   has not regressed (still public-domain + permissive grant). Quote
   the new declaration verbatim into `benchmarks/vendor/liblfds/LICENSE`.
5. Replace `benchmarks/vendor/liblfds/liblfds711/` with the new
   `liblfds7xy/` directory (rename to whatever upstream's directory is
   called; update the adapter `passC`/`passL` paths if the convention
   moves).
6. Update the **Pinned commit** + **License** lines above and the
   matching block in repo-root `THIRD_PARTY_LICENSES.md`.
7. Re-run the smoke binary:
   ```bash
   nim c -d:release --threads:on \
     -d:adapter_liblfds_available \
     --passL:"-Lbenchmarks/vendor/liblfds/liblfds711/bin -llfds711" \
     -o:.tmp/smoke_liblfds \
     benchmarks/nim/smoke/smoke_liblfds.nim
   .tmp/smoke_liblfds
   ```
8. If upstream changed `lfds711_queue_bss_*` / `lfds711_queue_bmm_*`
   signatures or the `MAKE_VALID_ON_CURRENT_LOGICAL_CORE` macro
   contract, update `liblfds_adapter.nim` to match before committing.

## Local development on macOS

```bash
cd benchmarks/vendor/liblfds/liblfds711/build/gcc_gnumake
CFLAGS='-D__linux__ -fPIC' DGFLAGS='-D__linux__' make ar_rel
```

Without the `-D__linux__` override the upstream porting abstraction
layer fails the OS-detect `#error`. CI runs on Ubuntu and does not
need this.
