## Adapter for ``boost::lockfree::queue<uint64_t>`` (MPMC bounded).
##
## Boost.LockFree is a header-only C++ library (https://www.boost.org,
## Boost Software License 1.0). ``boost::lockfree::queue`` is a multi-producer
## multi-consumer lock-free FIFO over a fixed-size internal node pool;
## constructed with ``boost::lockfree::queue<T>(capacity)`` it never grows
## (we pin to ``fixed_sized<true>`` semantics by passing an explicit capacity
## at construction).
##
## Topology: ``mpmc`` bounded. ``topologiesSupported = {tMpmc}``.
##
## Build constraint: this adapter is C++ (template-heavy header-only library)
## and therefore requires ``nim cpp``. Compiling with ``nim c`` triggers an
## explicit ``{.error.}`` so we never silently fall back to a partial build.
##
## Compile-time gating: only included when
## ``-d:adapter_boost_lockfree_queue_available`` is passed.
##
## Header search path: we add ``-I`` for the conventional install locations
## so the adapter compiles out of the box on Ubuntu (``apt install
## libboost-dev`` -> ``/usr/include``) and macOS (``brew install boost`` ->
## ``/opt/homebrew/opt/boost/include`` on arm64, ``/usr/local/include`` on
## x86_64). On systems where Boost lives elsewhere, set
## ``-d:boostIncludeDir=<path>`` at compile time.

when defined(adapter_boost_lockfree_queue_available):
  when not defined(cpp):
    {.
      error: "boost_lockfree_queue_adapter requires `nim cpp` (Boost.LockFree is C++)."
    .}

  import ../bench_common
  import ../adapter
  import lockfreequeues/internal/aligned_alloc

  # Header search paths. Order: explicit override -> brew arm64 -> brew/macports
  # x86_64 / FreeBSD ports -> Linux apt default.
  when defined(boostIncludeDir):
    {.passC: "-I" & boostIncludeDir.}
  else:
    when defined(macosx) or defined(macos):
      {.passC: "-I/opt/homebrew/opt/boost/include".}
      {.passC: "-I/usr/local/include".}
    else:
      {.passC: "-I/usr/include".}
      {.passC: "-I/usr/local/include".}

  # ``boost::lockfree::queue<T>`` requires ``T`` to be trivially destructible
  # and trivially copy-assignable; ``uint64_t`` satisfies both. We always
  # store ``uint64`` regardless of the harness's ``T`` (the harness uses
  # ``uint64`` as its payload by convention; see ``bench_common.nim``).
  type BoostQueueRaw {.
    importcpp: "boost::lockfree::queue<unsigned long long>",
    header: "boost/lockfree/queue.hpp",
    byref
  .} = object

  proc constructBoostQueueRaw(
    capacity: csize_t
  ): BoostQueueRaw {.
    importcpp: "boost::lockfree::queue<unsigned long long>(@)",
    header: "boost/lockfree/queue.hpp",
    constructor
  .}

  proc bpush(
    q: var BoostQueueRaw, v: culonglong
  ): bool {.importcpp: "#.bounded_push(@)".}

  proc bpop(q: var BoostQueueRaw, v: var culonglong): bool {.importcpp: "#.pop(@)".}

  const topologiesSupported* = {tMpmc}

  type BoostLockfreeQueueAdapter*[T] = object
    queue*: ptr BoostQueueRaw
      ## Heap-allocated so the adapter can be moved/copied as a value type
      ## without invoking C++ move/copy semantics on the underlying queue
      ## (``boost::lockfree::queue`` is non-copyable and non-movable).
    capacity*: int

  proc makeBoostLockfreeQueueAdapter*[T](
      capacity: int = 1024
  ): BoostLockfreeQueueAdapter[T] =
    ## ``capacity`` is the fixed node-pool size; pushes that exceed it
    ## return ``prFull``. Default 1024 mirrors other bounded adapters.
    ## Backing storage uses ``allocAligned`` (cache-line aligned, zeroed)
    ## rather than ``alloc0`` so the placement-constructed Boost queue gets
    ## the alignment its internal padding pragmas expect — ``alloc0`` only
    ## guarantees ``alignof(max_align_t)`` (typically 16 bytes), which can
    ## leave Boost's per-cache-line atomics straddling line boundaries.
    result.capacity = capacity
    result.queue = allocAligned[BoostQueueRaw]()
    # Placement-construct the C++ object in the alloc'd storage. Going via
    # an importcpp constructor proc keeps Nim from emitting a Nim-level
    # constructor call.
    {.
      emit: [
        "new (",
        result.queue,
        ") boost::lockfree::queue<unsigned long long>(",
        csize_t(capacity),
        ");",
      ]
    .}

  proc cleanup*[T](a: var BoostLockfreeQueueAdapter[T]) =
    if a.queue != nil:
      {.emit: [a.queue, "->~queue();"].}
      freeAligned(a.queue)
      a.queue = nil

  proc push*[T](a: var BoostLockfreeQueueAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if bpush(a.queue[], culonglong(uint64(item))): prSuccess else: prFull

  proc pop*[T](a: var BoostLockfreeQueueAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    if bpop(a.queue[], raw):
      PopResult[T](success: true, value: T(uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: BoostLockfreeQueueAdapter[T]): string =
    "boost_lockfree_queue/queue[uint64]"
