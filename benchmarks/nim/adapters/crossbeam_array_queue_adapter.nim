## Adapter for ``crossbeam_queue::ArrayQueue<u64>`` (bounded MPMC).
##
## Crossbeam is a Rust lock-free ecosystem (https://github.com/crossbeam-rs,
## dual-licensed Apache-2.0 / MIT). ``ArrayQueue<T>`` is a fixed-capacity
## ring-buffer MPMC queue.
##
## We do not link directly against the Rust library; instead we go through
## a thin C-ABI cdylib at ``benchmarks/rust/bench-ffi-crossbeam/`` (see
## ``Track 3 Task 3.8``). The cdylib exports four ``extern "C"`` fns:
## ``cb_array_init``, ``cb_array_push``, ``cb_array_pop``, ``cb_array_destroy``.
##
## Topology: ``mpmc`` bounded. ``topologiesSupported = {tMpmc}``.
##
## Compile-time gating: only included when
## ``-d:adapter_crossbeam_array_queue_available`` is passed.
##
## Linking: callers must build the cdylib first
## (``cargo build --release --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml``)
## and then compile the bench binary with the link flags emitted below.
## Override the search path with ``-d:crossbeamLibDir=<path>`` if the crate
## was built somewhere other than the in-tree ``target/release``.

when defined(adapter_crossbeam_array_queue_available):
  import ../bench_common
  import ../adapter

  # Skip the link flags if the seg-queue adapter (the other consumer of
  # the same cdylib) is also enabled; we'd otherwise emit -L/-l twice and
  # the Apple linker prints a duplicate-library warning. The seg adapter
  # owns the link-flag emission when both gates are set, since it sorts
  # last alphabetically among the two crossbeam adapter compile units.
  when not defined(adapter_crossbeam_seg_queue_available):
    when defined(crossbeamLibDir):
      {.passL: "-L" & crossbeamLibDir.}
    else:
      {.passL: "-Lbenchmarks/rust/bench-ffi-crossbeam/target/release".}
    {.passL: "-lbench_ffi_crossbeam".}

  # The Rust cdylib exports `cb_array_*` with C linkage. We model the
  # opaque queue handle as `pointer` (Nim) <-> `*mut c_void` (Rust). All
  # multi-threaded access is the caller's responsibility; the queue
  # itself is MPMC-safe.

  proc cb_array_init(capacity: csize_t): pointer {.importc, cdecl.}
  proc cb_array_push(q: pointer; item: uint64): bool {.importc, cdecl.}
  proc cb_array_pop(q: pointer; outVal: ptr uint64): bool {.importc, cdecl.}
  proc cb_array_destroy(q: pointer) {.importc, cdecl.}

  const topologiesSupported* = {tMpmc}

  type CrossbeamArrayQueueAdapter*[T] = object
    queue*: pointer
    capacity*: int

  proc makeCrossbeamArrayQueueAdapter*[T](capacity: int = 1024): CrossbeamArrayQueueAdapter[T] =
    doAssert capacity > 0,
      "CrossbeamArrayQueue requires capacity > 0 (zero would null-init)"
    result.capacity = capacity
    result.queue = cb_array_init(csize_t(capacity))
    doAssert result.queue != nil, "cb_array_init returned null"

  proc cleanup*[T](a: var CrossbeamArrayQueueAdapter[T]) =
    if a.queue != nil:
      cb_array_destroy(a.queue)
      a.queue = nil

  proc push*[T](a: var CrossbeamArrayQueueAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if cb_array_push(a.queue, uint64(item)):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var CrossbeamArrayQueueAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: uint64
    if cb_array_pop(a.queue, addr raw):
      PopResult[T](success: true, value: T(raw))
    else:
      PopResult[T](success: false)

  proc name*[T](a: CrossbeamArrayQueueAdapter[T]): string =
    "crossbeam_queue/ArrayQueue[u64]"
