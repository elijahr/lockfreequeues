## Adapter for the `flume` Rust channel library
## (https://github.com/zesterer/flume).
##
## flume is a Rust MPMC channel crate (Apache-2.0 OR MIT). v4.2.0
## Stage 5.2 wires it into the bench harness via the consolidated
## `libbench_ffi_crossbeam` cdylib (flume + kanal are folded into the
## same shared object alongside crossbeam). The cdylib exports eight
## `extern "C"` fns under the `flume_` prefix:
##
##   bounded   : flume_init, flume_push, flume_pop, flume_destroy
##   unbounded : flume_unbounded_init, flume_unbounded_push,
##               flume_unbounded_pop, flume_unbounded_destroy
##
## Topology routing:
##   bounded MPMC          (bench_mpmc)       -> {tMpmc}
##   unbounded MPMC        (bench_unbounded)  -> {tMpmcUnbounded}
##
## Compile-time gating: only included when
## `-d:adapter_flume_available` is passed.
##
## Linking: callers must build the cdylib first
## (`cargo build --release --manifest-path
## benchmarks/rust/bench-ffi-crossbeam/Cargo.toml`) and then compile
## the bench binary with the link flags emitted by `crossbeam_link.nim`
## (which owns `{.passL.}` for the consolidated cdylib).

when defined(adapter_flume_available):
  import ../bench_common
  import ../adapter
  # Owns `-L<dir> -lbench_ffi_crossbeam`. Idempotent across multiple
  # importing adapters; see crossbeam_link.nim header.
  import ./crossbeam_link

  # Bounded
  proc flume_init(capacity: csize_t): pointer {.importc, cdecl.}
  proc flume_push(q: pointer; item: uint64): bool {.importc, cdecl.}
  proc flume_pop(q: pointer; outVal: ptr uint64): bool {.importc, cdecl.}
  proc flume_destroy(q: pointer) {.importc, cdecl.}

  # Unbounded
  proc flume_unbounded_init(): pointer {.importc, cdecl.}
  proc flume_unbounded_push(q: pointer; item: uint64): bool
    {.importc, cdecl.}
  proc flume_unbounded_pop(q: pointer; outVal: ptr uint64): bool
    {.importc, cdecl.}
  proc flume_unbounded_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmc, tMpmcUnbounded}

  type
    FlumeAdapter*[T] = object
      ## Bounded flume MPMC channel handle.
      queue*: pointer
      capacity*: int

    FlumeUnboundedAdapter*[T] = object
      ## Unbounded flume MPMC channel handle.
      queue*: pointer

  proc makeFlumeAdapter*[T](capacity: int = 1024): FlumeAdapter[T] =
    doAssert capacity > 0,
      "FlumeAdapter (bounded) requires capacity > 0 " &
      "(zero would null-init at the FFI boundary)"
    result.capacity = capacity
    result.queue = flume_init(csize_t(capacity))
    doAssert result.queue != nil, "flume_init returned null"

  proc cleanup*[T](a: var FlumeAdapter[T]) =
    if a.queue != nil:
      flume_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var FlumeAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if flume_push(a.queue, uint64(item)):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var FlumeAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if flume_pop(a.queue, addr raw):
      PopResult[T](success: true, value: T(raw))
    else:
      PopResult[T](success: false)

  proc name*[T](a: FlumeAdapter[T]): string =
    "flume/bounded[u64]"

  proc makeFlumeUnboundedAdapter*[T](
      capacity: int = 0): FlumeUnboundedAdapter[T] =
    ## `capacity` is ignored — flume's unbounded variant grows on demand.
    ## Default arg matches the other adapters' shape so the wire-up
    ## sites can pass the same `capacity` uniformly without conditionals.
    discard capacity
    result.queue = flume_unbounded_init()
    doAssert result.queue != nil, "flume_unbounded_init returned null"

  proc cleanup*[T](a: var FlumeUnboundedAdapter[T]) =
    if a.queue != nil:
      flume_unbounded_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var FlumeUnboundedAdapter[T], item: T): PushResult =
    ## Unbounded flume push only fails on a disconnected channel; the
    ## Rust shim keeps both halves alive in its Box, so disconnection
    ## cannot happen during a bench run. A null pointer therefore maps
    ## to prFull (matches the other adapters' handle-dead convention).
    if a.queue == nil:
      return prFull
    discard flume_unbounded_push(a.queue, uint64(item))
    prSuccess

  proc pop*[T](a: var FlumeUnboundedAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if flume_unbounded_pop(a.queue, addr raw):
      PopResult[T](success: true, value: T(raw))
    else:
      PopResult[T](success: false)

  proc name*[T](a: FlumeUnboundedAdapter[T]): string =
    "flume/unbounded[u64]"
