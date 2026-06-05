## Adapter for MoodyCamel ``concurrentqueue`` (unbounded MPMC).
##
## ``moodycamel::ConcurrentQueue<T>`` is a heavily-templated C++
## single-header library. To keep the upstream template machinery out
## of the Nim build path we go through a thin ``extern "C"`` wrapper
## (``benchmarks/vendor/concurrentqueue/moodycamel_wrapper.cpp``) that
## exposes four non-template ``uint64_t``-payload entry points:
## ``mc_init`` / ``mc_push`` / ``mc_pop`` / ``mc_destroy``. This
## adapter consumes those via plain ``importc``. See Risk M5 in the
## bench-rollup understanding doc for the full rationale.
##
## Topology: ``mpmc_unbounded``. The queue grows beyond its initial
## capacity hint on demand, so ``capacity`` is advisory only and the
## bench harness's ``capacity = 0`` form is honoured by mapping to
## upstream's documented minimum block size (32).
##
## Build constraint: requires ``nim cpp`` (the wrapper is C++ and
## ``concurrentqueue.h`` is C++-only). Compiling with ``nim c``
## triggers an explicit ``{.error.}`` so we never silently build a
## partial bench binary.
##
## Compile-time gating: only included when
## ``-d:adapter_moodycamel_available`` is passed. The bench binary's
## ``when declared(makeMoodycamelAdapter):`` block enables the slug
## only when the gate is set.

when defined(adapter_moodycamel_available):
  when not defined(cpp):
    {.error: "moodycamel_adapter requires `nim cpp` (concurrentqueue.h is C++).".}

  import std/os
  import ../bench_common
  import ../adapter

  const VendorDir =
    currentSourcePath().parentDir.parentDir.parentDir & "/vendor/concurrentqueue"
    ## Resolved at compile time: ``benchmarks/vendor/concurrentqueue``
    ## under the repo root regardless of where the bench binary is
    ## invoked from. ``parentDir`` walks
    ## ``adapters/`` -> ``nim/`` -> ``benchmarks/``.

  {.passC: "-I" & VendorDir.}
  {.compile: VendorDir & "/moodycamel_wrapper.cpp".}

  proc mc_init(initial_capacity: culonglong): pointer {.importc, cdecl.}
  proc mc_push(q: pointer, item: culonglong): cint {.importc, cdecl.}
  proc mc_pop(q: pointer, outVal: ptr culonglong): cint {.importc, cdecl.}
  proc mc_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmcUnbounded}

  type MoodycamelAdapter*[T] = object
    queue*: pointer
      ## Heap-owned by ``mc_init``; freed by ``cleanup`` via
      ## ``mc_destroy``. Always treated as a void* on the Nim side.

  proc makeMoodycamelAdapter*[T](capacity: int = 0): MoodycamelAdapter[T] =
    ## The C++ wrapper is hardcoded to ``uint64_t`` payload, so ``T`` MUST
    ## be exactly 8 bytes. ``cast[uint64](item)`` / ``cast[T](uint64(raw))``
    ## (push/pop below) round-trip the bit pattern, but the cast is only
    ## sound when the source and destination width match.
    ##
    ## ``T`` must also be POD-shaped: a ``ref`` payload would be unsafe
    ## here because the C++ queue is opaque to Nim's GC, so a refcount
    ## bump on push would never happen and the underlying object could be
    ## collected before ``pop``. Restrict to integer / ptr-like payloads.
    static:
      assert sizeof(T) == 8,
        "MoodycamelAdapter requires sizeof(T) == 8 (the C++ wrapper " &
          "stores `uint64_t`); got sizeof(" & $T & ") = " & $sizeof(T)
      assert not (T is ref),
        "MoodycamelAdapter cannot transport ref types: the C++ queue " &
          "bypasses Nim's GC, so refcounts wouldn't be maintained across " &
          "the boundary. Use a non-ref 64-bit payload (uint64, ptr, etc)."
    ## ``capacity`` is an initial-block-size hint. ``0`` selects
    ## upstream's default minimum (32) — see
    ## ``moodycamel_wrapper.cpp``.
    ##
    ## Fails fast if the C++ wrapper returned ``nullptr`` (allocation
    ## failure or queue-construction exception swallowed by the
    ## ``extern "C"`` boundary). Without this check a failed init would
    ## propagate as a silent ``a.queue == nil`` and the producer thread
    ## would spin-retry ``push`` returning ``prFull`` forever, masking
    ## the failure as a benchmark hang.
    let cap =
      if capacity < 0:
        0'u64
      else:
        uint64(capacity)
    result.queue = mc_init(culonglong(cap))
    if result.queue == nil:
      raise newException(
        OutOfMemDefect,
        "mc_init returned nullptr (moodycamel ConcurrentQueue " &
          "construction failed; capacity hint = " & $cap & ")",
      )

  proc cleanup*[T](a: var MoodycamelAdapter[T]) =
    if a.queue != nil:
      mc_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var MoodycamelAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    # `cast[uint64](item)` (not `uint64(item)`) so non-numeric 64-bit
    # payloads — pointers, refs, or distinct-int aliases that the
    # bench harness might exercise in the future — round-trip through
    # the C++ uint64 wire format by their bit pattern. For T=uint64
    # this is equivalent to a value conversion.
    if mc_push(a.queue, culonglong(cast[uint64](item))) != cint(0):
      prSuccess
    else:
      # MoodyCamel only fails on allocation failure — treat as
      # back-pressure so the bench harness can retry.
      prFull

  proc pop*[T](a: var MoodycamelAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    if mc_pop(a.queue, addr raw) != cint(0):
      # `cast[T]` mirrors the push side so pointer/ref payloads recover
      # their original bit pattern; for T=uint64 this is again
      # equivalent to a value conversion.
      PopResult[T](success: true, value: cast[T](uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: MoodycamelAdapter[T]): string =
    "moodycamel/ConcurrentQueue[" & $T & "]"
