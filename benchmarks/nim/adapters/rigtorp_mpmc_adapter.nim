## Adapter for `rigtorp::mpmc::Queue<uint64_t>` (bounded MPMC).
##
## Erik Rigtorp's `MPMCQueue` is a single-header Vyukov-style bounded
## MPMC ring buffer (MIT). Vendored at
## `benchmarks/vendor/rigtorp_mpmc/`.
##
## We go through a thin `extern "C"` wrapper at
## `benchmarks/vendor/rigtorp_mpmc/rigtorp_mpmc_wrapper.cpp` exposing
## four `uint64_t`-payload entry points: `rigtorp_mpmc_init` /
## `rigtorp_mpmc_push` / `rigtorp_mpmc_pop` / `rigtorp_mpmc_destroy`.
## Same rationale as the moodycamel / atomic_queue / rigtorp_spsc shims.
##
## Topology: bounded MPMC. Registered in `bench_mpmc`.
##
## Build constraint: requires `nim cpp` (the wrapper is C++ and
## `MPMCQueue.h` is C++-only).
##
## Compile-time gating: only included when
## `-d:adapter_rigtorp_mpmc_available` is passed.

when defined(adapter_rigtorp_mpmc_available):
  when not defined(cpp):
    {.error: "rigtorp_mpmc_adapter requires `nim cpp` (MPMCQueue.h is C++).".}

  import std/os
  import ../bench_common
  import ../adapter

  const VendorDir = currentSourcePath().parentDir.parentDir.parentDir &
    "/vendor/rigtorp_mpmc"

  {.passC: "-I" & VendorDir & "/include".}
  {.compile: VendorDir & "/rigtorp_mpmc_wrapper.cpp".}

  proc rigtorp_mpmc_init(capacity: culonglong): pointer {.importc, cdecl.}
  proc rigtorp_mpmc_push(q: pointer; item: culonglong): cint {.importc, cdecl.}
  proc rigtorp_mpmc_pop(q: pointer; outVal: ptr culonglong): cint
    {.importc, cdecl.}
  proc rigtorp_mpmc_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmc}

  type RigtorpMpmcAdapter*[T] = object
    queue*: pointer
    capacity*: int

  proc makeRigtorpMpmcAdapter*[T](capacity: int = 1024): RigtorpMpmcAdapter[T] =
    static:
      assert sizeof(T) == 8,
        "RigtorpMpmcAdapter requires sizeof(T) == 8 (the wrapper " &
        "stores `uint64_t`); got sizeof(" & $T & ") = " & $sizeof(T)
      assert not (T is ref),
        "RigtorpMpmcAdapter cannot transport ref types: the C++ queue " &
        "bypasses Nim's GC. Use a non-ref 64-bit payload."
    doAssert capacity > 0, "rigtorp::mpmc::Queue requires capacity > 0"
    result.capacity = capacity
    result.queue = rigtorp_mpmc_init(culonglong(capacity))
    if result.queue == nil:
      raise newException(
        OutOfMemDefect,
        "rigtorp_mpmc_init returned nullptr (rigtorp::mpmc::Queue " &
        "construction failed; capacity = " & $capacity & ")"
      )

  proc cleanup*[T](a: var RigtorpMpmcAdapter[T]) =
    if a.queue != nil:
      rigtorp_mpmc_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var RigtorpMpmcAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if rigtorp_mpmc_push(a.queue, culonglong(cast[uint64](item))) != cint(0):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var RigtorpMpmcAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    if rigtorp_mpmc_pop(a.queue, addr raw) != cint(0):
      PopResult[T](success: true, value: cast[T](uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: RigtorpMpmcAdapter[T]): string =
    "rigtorp/MPMCQueue[" & $T & "]"
