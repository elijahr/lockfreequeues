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

  const VendorDir = currentSourcePath().parentDir.parentDir.parentDir &
    "/vendor/concurrentqueue"
    ## Resolved at compile time: ``benchmarks/vendor/concurrentqueue``
    ## under the repo root regardless of where the bench binary is
    ## invoked from. ``parentDir`` walks
    ## ``adapters/`` -> ``nim/`` -> ``benchmarks/``.

  {.passC: "-I" & VendorDir.}
  {.compile: VendorDir & "/moodycamel_wrapper.cpp".}

  proc mc_init(initial_capacity: culonglong): pointer {.importc, cdecl.}
  proc mc_push(q: pointer; item: culonglong): cint {.importc, cdecl.}
  proc mc_pop(q: pointer; outVal: ptr culonglong): cint {.importc, cdecl.}
  proc mc_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmcUnbounded}

  type MoodycamelAdapter*[T] = object
    queue*: pointer
      ## Heap-owned by ``mc_init``; freed by ``cleanup`` via
      ## ``mc_destroy``. Always treated as a void* on the Nim side.

  proc makeMoodycamelAdapter*[T](capacity: int = 0): MoodycamelAdapter[T] =
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
    let cap = if capacity < 0: 0'u64 else: uint64(capacity)
    result.queue = mc_init(culonglong(cap))
    if result.queue == nil:
      raise newException(
        OutOfMemDefect,
        "mc_init returned nullptr (moodycamel ConcurrentQueue " &
        "construction failed; capacity hint = " & $cap & ")"
      )

  proc cleanup*[T](a: var MoodycamelAdapter[T]) =
    if a.queue != nil:
      mc_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var MoodycamelAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if mc_push(a.queue, culonglong(uint64(item))) != cint(0):
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
      PopResult[T](success: true, value: T(uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: MoodycamelAdapter[T]): string =
    "moodycamel/ConcurrentQueue[" & $T & "]"
