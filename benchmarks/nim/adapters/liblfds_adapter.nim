## Adapter for liblfds 7.1.1 bounded queues (SPSC + MPMC).
##
## liblfds is a portable, license-free, lock-free C data structure
## library (public domain + permissive grant; see
## `THIRD_PARTY_LICENSES.md` and `benchmarks/vendor/liblfds/LICENSE`).
## Vendored at `benchmarks/vendor/liblfds/liblfds711/`.
##
## The adapter exposes both bounded SPSC and bounded MPMC under one
## type; the topology slot picks which underlying queue family runs:
##
##   - `tSpsc` -> `lfds711_queue_bss_*` (single-producer single-consumer
##     bounded ring with proper back-pressure: enqueue returns 0 on
##     full).
##   - `tMpmc` -> `lfds711_queue_bmm_*` (Vyukov-style bounded MPMC, also
##     with back-pressure on full).
##
## Note on the impl plan deviation: the v4.2.0 plan originally called
## for `lfds711_ringbuffer_*`. That API silently overwrites the oldest
## element on full, which violates the bench harness's
## "messages-produced equals messages-consumed" invariant — the
## harness's consumer would never see the full `messageCount` because
## some pushes were quietly clobbered. Using `bss` + `bmm` instead
## preserves the invariant and lets liblfds participate on the same
## back-pressure contract every other adapter uses.
##
## We go through a thin C shim
## (`benchmarks/vendor/liblfds/liblfds_wrapper.c`) that folds the
## upstream's verbose init / barrier / element_array bookkeeping into
## eight `uint64`-payload entry points consumed via plain `importc`.
## Same shim pattern as moodycamel / atomic_queue / rigtorp, except the
## upstream library is C, so the shim is C too — no `nim cpp` needed.
##
## Build constraint: plain `nim c` is sufficient (the wrapper is C and
## the upstream sources are C). The CI step builds `liblfds711.a` from
## the upstream Makefile and links the bench binary against it via
## `--passL:"-Lbenchmarks/vendor/liblfds/liblfds711/bin -llfds711"`.
##
## Compile-time gating: only included when
## `-d:adapter_liblfds_available` is passed.

when defined(adapter_liblfds_available):
  import std/os
  import ../bench_common
  import ../adapter

  const VendorDir = currentSourcePath().parentDir.parentDir.parentDir &
    "/vendor/liblfds"
    ## Resolved at compile time: `benchmarks/vendor/liblfds` under the
    ## repo root regardless of where the bench binary is invoked from.

  # `-I VendorDir` resolves the wrapper's
  # `#include "liblfds711/inc/liblfds711.h"` and `adapter_versions.nim`'s
  # identical-path include for `LFDS711_MISC_VERSION_STRING`. No deeper
  # `-I` is needed because both sites use the full `liblfds711/inc/...`
  # relative path rather than a bare `liblfds711.h`.
  {.passC: "-I" & VendorDir.}
  {.compile: VendorDir & "/liblfds_wrapper.c".}

  proc bench_liblfds_bss_init(capacity: culonglong): pointer
    {.importc, cdecl.}
  proc bench_liblfds_bss_push(q: pointer; item: culonglong): cint
    {.importc, cdecl.}
  proc bench_liblfds_bss_pop(q: pointer; outVal: ptr culonglong): cint
    {.importc, cdecl.}
  proc bench_liblfds_bss_destroy(q: pointer) {.importc, cdecl.}

  proc bench_liblfds_bmm_init(capacity: culonglong): pointer
    {.importc, cdecl.}
  proc bench_liblfds_bmm_push(q: pointer; item: culonglong): cint
    {.importc, cdecl.}
  proc bench_liblfds_bmm_pop(q: pointer; outVal: ptr culonglong): cint
    {.importc, cdecl.}
  proc bench_liblfds_bmm_destroy(q: pointer) {.importc, cdecl.}

  type LiblfdsKind* = enum
    lkBss, lkBmm

  const topologiesSupported* = {tSpsc, tMpmc}

  type LiblfdsAdapter*[T] = object
    queue*: pointer
    kind*: LiblfdsKind
    capacity*: int

  proc makeLiblfdsAdapter*[T](
      kind: LiblfdsKind = lkBss, capacity: int = 1024): LiblfdsAdapter[T] =
    ## `T` MUST be exactly 8 bytes — the wrapper packs the payload into
    ## a `uintptr_t` for liblfds's `void*` value slot. Same constraint
    ## as moodycamel / atomic_queue / rigtorp adapters.
    static:
      assert sizeof(T) == 8,
        "LiblfdsAdapter requires sizeof(T) == 8 (the wrapper packs the " &
        "payload into liblfds's void* slot via uintptr_t); got sizeof(" &
        $T & ") = " & $sizeof(T)
      assert not (T is ref),
        "LiblfdsAdapter cannot transport ref types: the C queue " &
        "bypasses Nim's GC. Use a non-ref 64-bit payload."
    doAssert capacity > 0, "liblfds bounded queues require capacity > 0"
    result.kind = kind
    result.capacity = capacity
    case kind
    of lkBss:
      result.queue = bench_liblfds_bss_init(culonglong(capacity))
    of lkBmm:
      result.queue = bench_liblfds_bmm_init(culonglong(capacity))
    if result.queue == nil:
      raise newException(
        OutOfMemDefect,
        "bench_liblfds_" & (if kind == lkBss: "bss" else: "bmm") &
        "_init returned nullptr (liblfds bounded queue construction " &
        "failed; capacity request = " & $capacity & ")"
      )

  proc cleanup*[T](a: var LiblfdsAdapter[T]) =
    if a.queue != nil:
      case a.kind
      of lkBss: bench_liblfds_bss_destroy(a.queue)
      of lkBmm: bench_liblfds_bmm_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var LiblfdsAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    let raw = culonglong(cast[uint64](item))
    let ok =
      case a.kind
      of lkBss: bench_liblfds_bss_push(a.queue, raw) != cint(0)
      of lkBmm: bench_liblfds_bmm_push(a.queue, raw) != cint(0)
    if ok: prSuccess else: prFull

  proc pop*[T](a: var LiblfdsAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    let ok =
      case a.kind
      of lkBss: bench_liblfds_bss_pop(a.queue, addr raw) != cint(0)
      of lkBmm: bench_liblfds_bmm_pop(a.queue, addr raw) != cint(0)
    if ok:
      PopResult[T](success: true, value: cast[T](uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: LiblfdsAdapter[T]): string =
    case a.kind
    of lkBss: "liblfds/queue_bss[" & $T & "]"
    of lkBmm: "liblfds/queue_bmm[" & $T & "]"
