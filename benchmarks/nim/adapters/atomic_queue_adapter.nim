## Adapter for `atomic_queue::AtomicQueueB<uint64_t>` (bounded MPMC).
##
## Maxim Egorushkin's `atomic_queue` is a high-performance header-only
## C++ ring-buffer family (MIT). `AtomicQueueB<T>` is the
## dynamic-capacity bounded MPMC variant; `try_push` returns false when
## full, mirroring the bench harness's `prFull` convention.
##
## We do not import the templated header directly into Nim (Risk M5
## from the bench-rollup understanding doc — heavy template machinery
## leaks through every `importcpp` build). Instead we go through a thin
## `extern "C"` wrapper at
## `benchmarks/vendor/atomic_queue/atomic_queue_wrapper.cpp` exposing
## four `uint64_t`-payload entry points: `aq_init` / `aq_push` /
## `aq_pop` / `aq_destroy`. The adapter consumes those via plain
## `importc`, mirroring the moodycamel / rigtorp pattern.
##
## Topology: bounded MPMC. Registered in `bench_spsc` (with
## `topologiesSupported = {tSpsc}`) AND `bench_mpmc` (with
## `topologiesSupported = {tMpmc}`); slug emission inside each bench
## binary hardcodes the right topology label.
##
## Build constraint: requires `nim cpp` (the wrapper is C++ and
## `atomic_queue.h` is C++-only). Compiling with `nim c` triggers an
## explicit `{.error.}` so we never silently build a partial bench
## binary.
##
## Compile-time gating: only included when
## `-d:adapter_atomic_queue_available` is passed.

when defined(adapter_atomic_queue_available):
  when not defined(cpp):
    {.error: "atomic_queue_adapter requires `nim cpp` (atomic_queue.h is C++).".}

  import std/os
  import std/typetraits
  import ../bench_common
  import ../adapter

  const VendorDir =
    currentSourcePath().parentDir.parentDir.parentDir & "/vendor/atomic_queue"
    ## Resolved at compile time: `benchmarks/vendor/atomic_queue` under
    ## the repo root regardless of where the bench binary is invoked
    ## from. `parentDir` walks `adapters/` -> `nim/` -> `benchmarks/`.

  {.passC: "-I" & VendorDir & "/include".}
  {.compile: VendorDir & "/atomic_queue_wrapper.cpp".}

  proc aq_init(capacity: culonglong): pointer {.importc, cdecl.}
  proc aq_push(q: pointer, item: culonglong): cint {.importc, cdecl.}
  proc aq_pop(q: pointer, outVal: ptr culonglong): cint {.importc, cdecl.}
  proc aq_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tSpsc, tMpmc}

  type AtomicQueueAdapter*[T] = object
    queue*: pointer
    capacity*: int

  proc makeAtomicQueueAdapter*[T](capacity: int = 1024): AtomicQueueAdapter[T] =
    ## The wrapper is hardcoded to `uint64_t` payload, so `T` MUST be
    ## exactly 8 bytes. Same constraints as `MoodycamelAdapter`: bit-
    ## pattern round-trip via `cast[uint64](item)` / `cast[T](uint64)`.
    static:
      assert sizeof(T) == 8,
        "AtomicQueueAdapter requires sizeof(T) == 8 (the wrapper " &
          "stores `uint64_t`); got sizeof(" & $T & ") = " & $sizeof(T)
      assert supportsCopyMem(T),
        "AtomicQueueAdapter requires a type that supports copyMem " &
          "(no managed heap resources like string, seq, ref, or types " &
          "with custom destructors): the C++ queue bypasses Nim's GC, " &
          "so any managed resources wouldn't be maintained across the " &
          "boundary. Use a non-ref 64-bit payload (uint64, ptr, etc)."
    doAssert capacity > 0, "AtomicQueue requires capacity > 0"
    result.capacity = capacity
    result.queue = aq_init(culonglong(capacity))
    if result.queue == nil:
      raise newException(
        OutOfMemDefect,
        "aq_init returned nullptr (atomic_queue::AtomicQueueB " &
          "construction failed; capacity = " & $capacity & ")",
      )

  proc cleanup*[T](a: var AtomicQueueAdapter[T]) =
    if a.queue != nil:
      aq_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var AtomicQueueAdapter[T], item: T): PushResult =
    # NIL-sentinel guard: the C++ wrapper at
    # `benchmarks/vendor/atomic_queue/atomic_queue_wrapper.cpp` offsets
    # every push by +1 to dodge the 0 NIL sentinel that
    # `AtomicQueueB<T>` reserves. `high(uint64) + 1` overflows to 0 →
    # collides with NIL → silent corruption. Reject this single value
    # explicitly; the wrapper assumes the collision-free range
    # `[1, UINT64_MAX-1]`.
    doAssert cast[uint64](item) != high(uint64),
      "AtomicQueueAdapter cannot transport high(uint64): the C++ wrapper " &
        "offsets every push by +1 to avoid the 0 NIL sentinel, and high(uint64)+1 " &
        "overflows to 0 (a collision-free range of [1, UINT64_MAX-1] is required)."
    if a.queue == nil:
      return prFull
    if aq_push(a.queue, culonglong(cast[uint64](item))) != cint(0):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var AtomicQueueAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    if aq_pop(a.queue, addr raw) != cint(0):
      PopResult[T](success: true, value: cast[T](uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: AtomicQueueAdapter[T]): string =
    "atomic_queue/AtomicQueueB[" & $T & "]"
