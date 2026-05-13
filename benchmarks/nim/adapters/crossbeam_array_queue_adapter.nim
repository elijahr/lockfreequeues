## Adapter for ``crossbeam_queue::ArrayQueue<u64>`` (bounded MPMC).
##
## Crossbeam is a Rust lock-free ecosystem (https://github.com/crossbeam-rs,
## dual-licensed Apache-2.0 / MIT). ``ArrayQueue<T>`` is a fixed-capacity
## ring-buffer MPMC queue.
##
## We do not link directly against the Rust library; instead we go through
## a thin C-ABI cdylib at ``benchmarks/rust/comparison/`` (renamed from
## ``bench-ffi-crossbeam`` in v4.2.0 Stage 5.2 when flume + kanal were
## folded into the same shared object). The cdylib exports four
## ``extern "C"`` fns under the ``crossbeam_`` prefix:
## ``crossbeam_array_init``, ``crossbeam_array_push``,
## ``crossbeam_array_pop``, ``crossbeam_array_destroy``.
##
## Topology: ``mpmc`` bounded. ``topologiesSupported = {tMpmc}``.
##
## Compile-time gating: only included when
## ``-d:adapter_crossbeam_array_queue_available`` is passed.
##
## Linking: callers must build the cdylib first
## (``cargo build --release --manifest-path benchmarks/rust/comparison/Cargo.toml``)
## and then compile the bench binary with the link flags emitted below.
## Override the search path with ``-d:crossbeamLibDir=<path>`` if the crate
## was built somewhere other than the in-tree ``target/release``.

when defined(adapter_crossbeam_array_queue_available):
  import ../bench_common
  import ../adapter
  # Link-flag emission lives in a shared module so it fires exactly once
  # per bench binary that imports ANY crossbeam adapter, decoupled from
  # which gates happen to be globally set. See crossbeam_link.nim header
  # for the failure mode this avoids.
  import ./crossbeam_link

  # The Rust cdylib exports `crossbeam_array_*` with C linkage. We model the
  # opaque queue handle as `pointer` (Nim) <-> `*mut c_void` (Rust). All
  # multi-threaded access is the caller's responsibility; the queue
  # itself is MPMC-safe.

  proc crossbeam_array_init(capacity: csize_t): pointer {.importc, cdecl.}
  proc crossbeam_array_push(q: pointer; item: uint64): bool {.importc, cdecl.}
  proc crossbeam_array_pop(q: pointer; outVal: ptr uint64): bool {.importc, cdecl.}
  proc crossbeam_array_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmc}

  type CrossbeamArrayQueueAdapter*[T] = object
    queue*: pointer
    capacity*: int

  proc makeCrossbeamArrayQueueAdapter*[T](capacity: int = 1024): CrossbeamArrayQueueAdapter[T] =
    doAssert capacity > 0,
      "CrossbeamArrayQueue requires capacity > 0 (zero would null-init)"
    result.capacity = capacity
    result.queue = crossbeam_array_init(csize_t(capacity))
    doAssert result.queue != nil, "crossbeam_array_init returned null"

  proc cleanup*[T](a: var CrossbeamArrayQueueAdapter[T]) =
    if a.queue != nil:
      crossbeam_array_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var CrossbeamArrayQueueAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if crossbeam_array_push(a.queue, uint64(item)):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var CrossbeamArrayQueueAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if crossbeam_array_pop(a.queue, addr raw):
      PopResult[T](success: true, value: T(raw))
    else:
      PopResult[T](success: false)

  proc name*[T](a: CrossbeamArrayQueueAdapter[T]): string =
    "crossbeam_queue/ArrayQueue[u64]"
