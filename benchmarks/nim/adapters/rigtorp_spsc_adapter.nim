## Adapter for `rigtorp::SPSCQueue<uint64_t>` (bounded SPSC).
##
## Erik Rigtorp's `SPSCQueue` is a single-header bounded SPSC ring
## buffer (MIT). Vendored at `benchmarks/vendor/rigtorp_spsc/`.
##
## We go through a thin `extern "C"` wrapper at
## `benchmarks/vendor/rigtorp_spsc/rigtorp_spsc_wrapper.cpp` exposing
## four `uint64_t`-payload entry points: `rigtorp_spsc_init` /
## `rigtorp_spsc_push` / `rigtorp_spsc_pop` / `rigtorp_spsc_destroy`.
## Same rationale as the moodycamel and atomic_queue shims: avoid
## leaking the templated header into every `nim cpp` build.
##
## Topology: SPSC bounded. Registered in `bench_spsc`.
##
## Build constraint: requires `nim cpp` (the wrapper is C++ and
## `SPSCQueue.h` is C++-only).
##
## Compile-time gating: only included when
## `-d:adapter_rigtorp_spsc_available` is passed.

when defined(adapter_rigtorp_spsc_available):
  when not defined(cpp):
    {.error: "rigtorp_spsc_adapter requires `nim cpp` (SPSCQueue.h is C++).".}

  import std/os
  import std/typetraits
  import ../bench_common
  import ../adapter

  const VendorDir = currentSourcePath().parentDir.parentDir.parentDir &
    "/vendor/rigtorp_spsc"

  {.passC: "-I" & VendorDir & "/include".}
  {.compile: VendorDir & "/rigtorp_spsc_wrapper.cpp".}

  proc rigtorp_spsc_init(capacity: culonglong): pointer {.importc, cdecl.}
  proc rigtorp_spsc_push(q: pointer; item: culonglong): cint {.importc, cdecl.}
  proc rigtorp_spsc_pop(q: pointer; outVal: ptr culonglong): cint
    {.importc, cdecl.}
  proc rigtorp_spsc_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tSpsc}

  type RigtorpSpscAdapter*[T] = object
    queue*: pointer
    capacity*: int

  proc makeRigtorpSpscAdapter*[T](capacity: int = 1024): RigtorpSpscAdapter[T] =
    static:
      assert sizeof(T) == 8,
        "RigtorpSpscAdapter requires sizeof(T) == 8 (the wrapper " &
        "stores `uint64_t`); got sizeof(" & $T & ") = " & $sizeof(T)
      assert supportsCopyMem(T),
        "RigtorpSpscAdapter requires a type that supports copyMem (no " &
        "managed heap resources like string, seq, ref, or types with " &
        "custom destructors): the C++ queue bypasses Nim's GC. Use a " &
        "non-ref 64-bit payload."
    doAssert capacity > 0,
      "rigtorp::SPSCQueue requires capacity > 0"
    # Bench-harness policy: require power-of-2 capacity. Upstream
    # rigtorp::SPSCQueue uses an equality compare against capacity_ and
    # accepts any positive capacity, but our bench shapes are all pow-2,
    # so this asserts the bench contract and clears the static
    # reviewer's finding.
    doAssert (capacity and (capacity - 1)) == 0,
      "rigtorp::SPSCQueue bench adapter requires capacity to be a power of 2"
    result.capacity = capacity
    result.queue = rigtorp_spsc_init(culonglong(capacity))
    if result.queue == nil:
      raise newException(
        OutOfMemDefect,
        "rigtorp_spsc_init returned nullptr (rigtorp::SPSCQueue " &
        "construction failed; capacity = " & $capacity & ")"
      )

  proc cleanup*[T](a: var RigtorpSpscAdapter[T]) =
    if a.queue != nil:
      rigtorp_spsc_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var RigtorpSpscAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if rigtorp_spsc_push(a.queue, culonglong(cast[uint64](item))) != cint(0):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var RigtorpSpscAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    if rigtorp_spsc_pop(a.queue, addr raw) != cint(0):
      PopResult[T](success: true, value: cast[T](uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: RigtorpSpscAdapter[T]): string =
    "rigtorp/SPSCQueue[" & $T & "]"
