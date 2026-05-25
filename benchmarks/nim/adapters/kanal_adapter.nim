## Adapter for the `kanal` Rust channel library
## (https://github.com/fereidani/kanal).
##
## kanal is a Rust MPMC channel crate (MIT). v4.2.0 Stage 5.2 wires it
## into the bench harness via the consolidated `libbench_ffi_crossbeam`
## cdylib alongside crossbeam and flume. The cdylib exports eight
## `extern "C"` fns under the `kanal_` prefix:
##
##   bounded   : kanal_init, kanal_push, kanal_pop, kanal_destroy
##   unbounded : kanal_unbounded_init, kanal_unbounded_push,
##               kanal_unbounded_pop, kanal_unbounded_destroy
##
## Topology routing:
##   bounded MPMC          (bench_mpmc)        -> {tMpmc}
##   bounded SPSC          (bench_spsc)        -> {tSpsc}  (1p1c slot)
##   unbounded MPMC        (bench_unbounded)   -> {tMpmcUnbounded}
##
## Compile-time gating: only included when
## `-d:adapter_kanal_available` is passed.

when defined(adapter_kanal_available):
  import ../bench_common
  import ../adapter
  # Owns `-L<dir> -lbench_ffi_crossbeam`. Idempotent across multiple
  # importing adapters; see crossbeam_link.nim header.
  import ./crossbeam_link

  # Bounded
  proc kanal_init(capacity: csize_t): pointer {.importc, cdecl.}
  proc kanal_push(q: pointer; item: uint64): bool {.importc, cdecl.}
  proc kanal_pop(q: pointer; outVal: ptr uint64): bool {.importc, cdecl.}
  proc kanal_destroy(q: pointer) {.importc, cdecl.}

  # Unbounded
  proc kanal_unbounded_init(): pointer {.importc, cdecl.}
  proc kanal_unbounded_push(q: pointer; item: uint64): bool
    {.importc, cdecl.}
  proc kanal_unbounded_pop(q: pointer; outVal: ptr uint64): bool
    {.importc, cdecl.}
  proc kanal_unbounded_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tSpsc, tMpmc, tMpmcUnbounded}

  type
    KanalAdapter*[T] = object
      ## Bounded kanal MPMC channel handle.
      queue*: pointer
      capacity*: int

    KanalUnboundedAdapter*[T] = object
      ## Unbounded kanal MPMC channel handle.
      queue*: pointer

  proc makeKanalAdapter*[T](capacity: int = 1024): KanalAdapter[T] =
    doAssert capacity > 0,
      "KanalAdapter (bounded) requires capacity > 0 " &
      "(zero would null-init at the FFI boundary)"
    result.capacity = capacity
    result.queue = kanal_init(csize_t(capacity))
    doAssert result.queue != nil, "kanal_init returned null"

  proc cleanup*[T](a: var KanalAdapter[T]) =
    if a.queue != nil:
      kanal_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var KanalAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if kanal_push(a.queue, cast[uint64](item)):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var KanalAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if kanal_pop(a.queue, addr raw):
      PopResult[T](success: true, value: cast[T](raw))
    else:
      PopResult[T](success: false)

  proc name*[T](a: KanalAdapter[T]): string =
    "kanal/bounded[u64]"

  proc makeKanalUnboundedAdapter*[T](
      capacity: int = 0): KanalUnboundedAdapter[T] =
    ## `capacity` is ignored — kanal's unbounded variant grows on demand.
    ## Default arg matches the other adapters' shape so wire-up sites
    ## can pass the same `capacity` uniformly without conditionals.
    discard capacity
    result.queue = kanal_unbounded_init()
    doAssert result.queue != nil, "kanal_unbounded_init returned null"

  proc cleanup*[T](a: var KanalUnboundedAdapter[T]) =
    if a.queue != nil:
      kanal_unbounded_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var KanalUnboundedAdapter[T], item: T): PushResult =
    ## Unbounded kanal push only fails on a disconnected channel; the
    ## Rust shim holds both halves alive in its Box.
    if a.queue == nil:
      return prFull
    discard kanal_unbounded_push(a.queue, cast[uint64](item))
    prSuccess

  proc pop*[T](a: var KanalUnboundedAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if kanal_unbounded_pop(a.queue, addr raw):
      PopResult[T](success: true, value: cast[T](raw))
    else:
      PopResult[T](success: false)

  proc name*[T](a: KanalUnboundedAdapter[T]): string =
    "kanal/unbounded[u64]"
