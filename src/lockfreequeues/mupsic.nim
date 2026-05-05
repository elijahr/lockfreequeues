## A multi-producer, single-consumer (MPSC) bounded queue.
##
## Both push and pop are lock-free, using the Vyukov per-slot sequence
## protocol (see `typestates/mpmc_cell` and the `mpsc_push` / `mpsc_pop`
## verb modules). Producers race on `tail` via CAS; the single consumer
## coordinates via CAS on `head` (defensive — see design doc §10.9); the
## per-slot `seq` counter on each cell carries the producer->consumer
## and consumer->next-producer happens-before edges, eliminating the
## separate `committed` flag array used by the old protocol.

when not compileOption("threads"):
  {.error: "lockfreequeues/mupsic requires --threads:on option.".}

import ./atomic_dsl
import ./backoff
import options

import ./exceptions
import ./typestates
import ./typestates/mpmc_cell
import ./typestates/mpsc_push
import ./typestates/mpsc_pop

export exceptions

const NoSlice* = none(HSlice[int, int])

type
  Mupsic*[N, P: static int, T] = object
    ## A multi-producer, single-consumer bounded queue.
    ## Uses Vyukov per-slot sequence counters (see `MPMCCellArrayN`).
    ## Both push and pop are lock-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `T` is the type of data the queue will hold.
    ##
    ## Field order constraint: `head`, `tail`, `cells` MUST be the first
    ## three fields (in that order) so the unsafe casts in `push`/`pop`
    ## to `MupsicPushBase` / `MupsicBase` are sound. The `static` block
    ## below pins these offsets via `offsetof`.
    head* {.align: CacheLineBytes.}: Atomic[uint64]
    tail* {.align: CacheLineBytes.}: Atomic[uint64]
    cells*: MPMCCellArrayN[N, T]
    producerThreadIds*: array[P, Atomic[int]]

  Producer*[N, P: static int, T] = object
    ## A per-thread interface for pushing items to a queue.
    ## Retrieved via a call to `Mupsic.getProducer()`
    idx*: int
    queue*: ptr Mupsic[N, P, T]

# I1 (design doc §10.11): the facade casts `ptr Mupsic` to
# `ptr MupsicPushBase` / `ptr MupsicBase` in push/pop. That cast is sound
# only if the shared field PREFIX (head, tail, cells) has identical offsets.
# Sizeof equality would be wrong because Mupsic carries the
# producerThreadIds array not present in the bases. Picking [8, 4, int]
# as the canonical generic instantiation is arbitrary but sufficient:
# object-field offsets are computed structurally, so a match for one
# instantiation implies a match for all.
static:
  doAssert offsetOf(Mupsic[8, 4, int], head) == offsetOf(
    MupsicPushBase[8, 4, int], head
  )
  doAssert offsetOf(Mupsic[8, 4, int], tail) == offsetOf(
    MupsicPushBase[8, 4, int], tail
  )
  doAssert offsetOf(Mupsic[8, 4, int], cells) ==
    offsetOf(MupsicPushBase[8, 4, int], cells)
  doAssert offsetOf(Mupsic[8, 4, int], head) == offsetOf(MupsicBase[8, 4, int], head)
  doAssert offsetOf(Mupsic[8, 4, int], tail) == offsetOf(MupsicBase[8, 4, int], tail)
  doAssert offsetOf(Mupsic[8, 4, int], cells) == offsetOf(MupsicBase[8, 4, int], cells)

proc clear[N, P: static int, T](self: var Mupsic[N, P, T]) =
  self.head.store(0'u64, moRelaxed)
  self.tail.store(0'u64, moRelaxed)
  self.cells.init()
  for p in 0 ..< P:
    self.producerThreadIds[p].store(0, moRelaxed)

proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] =
  ## Initialize a new Mupsic queue.
  result.clear()

proc getProducer*[N, P: static int, T](
    self: var Mupsic[N, P, T], idx: int = -1
): Producer[N, P, T] {.raises: [NoProducersAvailableError].} =
  ## Assigns and returns a `Producer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  # getThreadId will be undeclared unless compiled with --threads:on
  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> producerIdx
  for i in 0 ..< P:
    if self.producerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  # Try to create new mapping of threadId -> producerIdx
  for i in 0 ..< P:
    var expected = 0
    if self.producerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moAcquire
    ):
      result.idx = i
      return

  # Producers are all spoken for by another thread
  raise newException(
    NoProducersAvailableError,
    "All producers have been assigned. " &
      "Increase your producer count (P) or setMaxPoolSize(P).",
  )

proc push*[N, P: static int, T](self: Producer[N, P, T], item: T): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is lock-free: producers never block on each other.
  ## Uses the Vyukov per-slot `seq` protocol via the `mpsc_push` typestate.

  # Cast queue to MupsicPushBase for typestate compatibility (sound per the
  # static offsetof asserts at the top of this module).
  var queueBase = cast[ptr MupsicPushBase[N, P, T]](self.queue)

  var op = mpsc_push.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPSCPushFull(full):
        return full.extractFalse()
      MPSCPushSlotClaimed(slotClaimed):
        return slotClaimed.complete(queueBase[], item)
      MPSCPushStart(restart):
        op = restart # CAS race or producer raced ahead: retry
        backoffOnRetry(spins)
        continue

proc push*[N, P: static int, T](
    self: Producer[N, P, T], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue (best-effort).
  ## If the queue is already full or fills during this call, `some(unpushed)`
  ## is returned, where `unpushed` is an `HSlice` corresponding to the
  ## chunk of items which could not be pushed.
  ## If all items are appended, `NoSlice` is returned.
  ##
  ## SEMANTIC CHANGE FROM 3.x: The old API atomically reserved a contiguous
  ## block via `fetchAdd` on a `reservedTail` cursor; this API does not.
  ## Bulk push is now a loop of single-item pushes — concurrent producers
  ## may interleave items in the queue. Consumers still see each item
  ## exactly once, in the order it was individually committed.
  ##
  ## This operation is lock-free: producers never block on each other.
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

proc push*[N, P: static int, T](self: var Mupsic[N, P, T], item: T): bool =
  ## Raises `InvalidCallDefect`. Use `Producer.push()` instead.
  raise newException(InvalidCallDefect, "Use Producer.push()")

proc push*[N, P: static int, T](
    self: var Mupsic[N, P, T], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Raises `InvalidCallDefect`. Use `Producer.push()` instead.
  raise newException(InvalidCallDefect, "Use Producer.push()")

proc pop*[N, P: static int, T](self: var Mupsic[N, P, T]): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## Otherwise an item is popped and `some(T)` is returned.
  ##
  ## This operation is lock-free for the single consumer (defensive CAS
  ## per design doc §10.9).
  ## Uses the Vyukov per-slot `seq` protocol via the `mpsc_pop` typestate.

  # Cast queue to MupsicBase for typestate compatibility (sound per the
  # static offsetof asserts at the top of this module).
  var queueBase = cast[ptr MupsicBase[N, P, T]](addr self)

  var op = mpsc_pop.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPSCPopEmpty(_):
        return none(T)
      MPSCPopSlotClaimed(slotClaimed):
        return some(slotClaimed.complete(queueBase[]))
      MPSCPopStart(restart):
        op = restart # CAS race or consumer raced ahead: retry
        backoffOnRetry(spins)
        continue

proc pop*[N, P: static int, T](self: var Mupsic[N, P, T], count: int): Option[seq[T]] =
  ## Pop up to `count` items from the queue (best-effort drain).
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one and at
  ## most `count` items.
  ##
  ## SEMANTIC CHANGE FROM 3.x: The old API atomically reserved a contiguous
  ## block via stores on `head`; this API does not. Bulk pop is now a loop
  ## of single-item pops — the returned sequence may be shorter than
  ## `count` even when the queue still contains items.
  ##
  ## This operation is lock-free for the single consumer.
  if unlikely(count <= 0):
    return none(seq[T])
  var items = newSeqOfCap[T](count)
  for _ in 0 ..< count:
    let v = self.pop()
    if v.isNone:
      break
    items.add(v.get)
  if items.len == 0:
    none(seq[T])
  else:
    some(items)

proc capacity*[N, P: static int, T](self: var Mupsic[N, P, T]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N

proc producerCount*[N, P: static int, T](self: var Mupsic[N, P, T]): int {.inline.} =
  ## Returns the queue's number of producers (`P`).
  result = P

when defined(testing):
  from unittest import check

  proc reset*[N, P: static int, T](self: var Mupsic[N, P, T]) =
    ## Resets the queue to its default state.
    ## For single-threaded unit tests only.
    self.clear()

  proc checkState*[N, P: static int, T](
      self: var Mupsic[N, P, T], head: uint64, tail: uint64
  ) =
    ## Check internal queue state for testing (head + tail only).
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)

  proc checkState*[N, P: static int, T](
      self: var Mupsic[N, P, T], head: uint64, tail: uint64, data: seq[T]
  ) =
    ## Check internal queue state for testing.
    ## Verifies head, tail, and each cell's payload data against `data`.
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0 ..< N:
      check(self.cells.cells[i].payload.data == data[i])
