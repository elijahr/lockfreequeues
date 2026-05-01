## Adapter for ``crossbeam_queue::SegQueue<u64>`` (unbounded MPMC).
##
## ``SegQueue<T>`` is Crossbeam's unbounded MPMC queue (a Michael-Scott
## variant); it allocates new segments on demand instead of returning
## "full". Pushes therefore never report ``prFull`` -- failure can only
## come from a null queue handle.
##
## Topology: ``mpmc_unbounded``. ``topologiesSupported = {tMpmcUnbounded}``.
##
## Compile-time gating: only included when
## ``-d:adapter_crossbeam_seg_queue_available`` is passed.
##
## Same cdylib as ``crossbeam_array_queue_adapter``; both adapters can
## be enabled simultaneously without duplicate symbols (each adapter
## ``importc`` s a disjoint set of fns: ``cb_array_*`` vs ``cb_seg_*``).

when defined(adapter_crossbeam_seg_queue_available):
  import ../bench_common
  import ../adapter

  when defined(crossbeamLibDir):
    {.passL: "-L" & crossbeamLibDir.}
  else:
    {.passL: "-Lbenchmarks/rust/bench-ffi-crossbeam/target/release".}

  {.passL: "-lbench_ffi_crossbeam".}

  proc cb_seg_init(): pointer {.importc, cdecl.}
  proc cb_seg_push(q: pointer; item: uint64): bool {.importc, cdecl.}
  proc cb_seg_pop(q: pointer; outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_seg_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmcUnbounded}

  type CrossbeamSegQueueAdapter*[T] = object
    queue*: pointer

  proc makeCrossbeamSegQueueAdapter*[T](capacity: int = 0): CrossbeamSegQueueAdapter[T] =
    ## ``capacity`` is ignored — SegQueue is unbounded. Default arg matches
    ## the other adapters' shape so the wire-up sites can pass the same
    ## ``capacity`` uniformly without conditionals.
    discard capacity
    result.queue = cb_seg_init()
    doAssert result.queue != nil, "cb_seg_init returned null"

  proc cleanup*[T](a: var CrossbeamSegQueueAdapter[T]) =
    if a.queue != nil:
      cb_seg_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var CrossbeamSegQueueAdapter[T], item: T): PushResult =
    ## Always succeeds when the queue is alive (SegQueue is unbounded;
    ## the underlying ``cb_seg_push`` only returns false on a null handle).
    if a.queue == nil:
      return prFull
    discard cb_seg_push(a.queue, uint64(item))
    prSuccess

  proc pop*[T](a: var CrossbeamSegQueueAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if cb_seg_pop(a.queue, addr raw):
      PopResult[T](success: true, value: T(raw))
    else:
      PopResult[T](success: false)

  proc name*[T](a: CrossbeamSegQueueAdapter[T]): string =
    "crossbeam_queue/SegQueue[u64]"
