## Adapter for ``boost::lockfree::spsc_queue<uint64_t>`` (SPSC bounded).
##
## ``boost::lockfree::spsc_queue`` is a single-producer single-consumer
## wait-free ring buffer. It provides stronger progress guarantees than
## ``boost::lockfree::queue`` (the MPMC version) at the cost of being
## restricted to one writer + one reader thread.
##
## Topology: ``spsc`` bounded. ``topologiesSupported = {tSpsc}``.
##
## Build constraint: requires ``nim cpp`` (Boost.LockFree is C++).
##
## Compile-time gating: only included when
## ``-d:adapter_boost_lockfree_spsc_available`` is passed.
##
## See ``boost_lockfree_queue_adapter.nim`` for the rationale on header
## search paths and the heap-allocated indirection (Boost queues are
## non-copyable, non-movable C++ types).

when defined(adapter_boost_lockfree_spsc_available):
  when not defined(cpp):
    {.error: "boost_lockfree_spsc_adapter requires `nim cpp` (Boost.LockFree is C++).".}

  import ../bench_common
  import ../adapter
  import lockfreequeues/internal/aligned_alloc

  when defined(boostIncludeDir):
    {.passC: "-I" & boostIncludeDir.}
  else:
    when defined(macosx) or defined(macos):
      {.passC: "-I/opt/homebrew/opt/boost/include".}
      {.passC: "-I/usr/local/include".}
    else:
      {.passC: "-I/usr/include".}
      {.passC: "-I/usr/local/include".}

  type
    BoostSpscRaw {.importcpp: "boost::lockfree::spsc_queue<unsigned long long>",
                   header: "boost/lockfree/spsc_queue.hpp", byref.} = object

  proc bsPush(q: var BoostSpscRaw; v: culonglong): bool
      {.importcpp: "#.push(@)".}

  proc bsPop(q: var BoostSpscRaw; v: var culonglong): csize_t
      {.importcpp: "#.pop(&#, 1ULL)".}

  const topologiesSupported* = {tSpsc}

  type BoostLockfreeSpscAdapter*[T] = object
    queue*: ptr BoostSpscRaw
    capacity*: int

  proc makeBoostLockfreeSpscAdapter*[T](capacity: int = 1024): BoostLockfreeSpscAdapter[T] =
    result.capacity = capacity
    # `allocAligned` (cache-line aligned, zeroed) instead of `alloc0` so the
    # placement-constructed Boost spsc_queue gets the alignment its internal
    # padding pragmas expect; matches the bounded `lockfree::queue` adapter.
    result.queue = allocAligned[BoostSpscRaw]()
    {.emit: ["new (", result.queue, ") boost::lockfree::spsc_queue<unsigned long long>(", csize_t(capacity), ");"].}

  proc cleanup*[T](a: var BoostLockfreeSpscAdapter[T]) =
    if a.queue != nil:
      {.emit: [a.queue, "->~spsc_queue();"].}
      freeAligned(a.queue)
      a.queue = nil

  proc push*[T](a: var BoostLockfreeSpscAdapter[T], item: T): PushResult =
    if a.queue == nil:
      return prFull
    if bsPush(a.queue[], culonglong(uint64(item))):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var BoostLockfreeSpscAdapter[T]): PopResult[T] =
    if a.queue == nil:
      return PopResult[T](success: false)
    var raw: culonglong
    let n = bsPop(a.queue[], raw)
    if n == csize_t(1):
      PopResult[T](success: true, value: T(uint64(raw)))
    else:
      PopResult[T](success: false)

  proc name*[T](a: BoostLockfreeSpscAdapter[T]): string =
    "boost_lockfree_queue/spsc_queue[uint64]"
