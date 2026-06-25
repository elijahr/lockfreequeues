## A multi-producer, multi-consumer (MPMC) bounded queue.
##
## Both push and pop are lock-free, using the Vyukov per-slot sequence
## protocol (see `typestates/mpmc_cell` and the `mpmc_push` / `mpmc_pop`
## verb modules). Producers coordinate via CAS on `tail`; consumers
## coordinate via CAS on `head`; the per-slot `seq` counter on each cell
## carries the producer->consumer and consumer->next-producer happens-before
## edges, eliminating the separate `committed` flag array used by the old
## protocol.

when not compileOption("threads"):
  {.error: "lockfreequeues/mupmuc requires --threads:on option.".}

import ./atomic_dsl
import ./backoff
import options

import ./exceptions
import ./typestates
import ./typestates/mpmc_cell
import ./typestates/mpmc_push
import ./typestates/mpmc_pop

export exceptions

const NoSlice* = none(HSlice[int, int])

type
  Mupmuc*[N, P, C: static int, T] = object
    ## A multi-producer, multi-consumer bounded queue.
    ## Uses Vyukov per-slot sequence counters (see `MPMCCellArrayN`).
    ## Both push and pop are lock-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `C` is the number of consumer threads.
    ## * `T` is the type of data the queue will hold.
    ##
    ## Field order constraint: `head`, `tail`, `cells` MUST be the first
    ## three fields (in that order) so the unsafe casts in `push`/`pop`
    ## to `MupmucPushBase` / `MupmucBase` are sound. The `static` block
    ## below pins these offsets via `offsetof`.
    head* {.align: CacheLineBytes.}: Atomic[uint64]
    tail* {.align: CacheLineBytes.}: Atomic[uint64]
    cells*: MPMCCellArrayN[N, T]
    producerThreadIds*: array[P, Atomic[int]]
    consumerThreadIds*: array[C, Atomic[int]]

  MupmucProducer*[N, P, C: static int, T] = object
    ## A per-thread interface for pushing items to a Mupmuc queue.
    idx*: int
    queue*: ptr Mupmuc[N, P, C, T]

  Consumer*[N, P, C: static int, T] = object
    ## A per-thread interface for popping items from a Mupmuc queue.
    idx*: int
    queue*: ptr Mupmuc[N, P, C, T]

# I1 (design doc §10.10): the facade casts `ptr Mupmuc` to
# `ptr MupmucPushBase` / `ptr MupmucBase` in push/pop. That cast is sound
# only if the shared field PREFIX (head, tail, cells) has identical offsets.
# Sizeof equality would be wrong because Mupmuc carries the
# producerThreadIds/consumerThreadIds arrays not present in the bases.
# Picking [8, 4, 4, int] as the canonical generic instantiation is
# arbitrary but sufficient: object-field offsets are computed structurally,
# so a match for one instantiation implies a match for all.
static:
  doAssert offsetOf(Mupmuc[8, 4, 4, int], head) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], head)
  doAssert offsetOf(Mupmuc[8, 4, 4, int], tail) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], tail)
  doAssert offsetOf(Mupmuc[8, 4, 4, int], cells) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], cells)
  doAssert offsetOf(Mupmuc[8, 4, 4, int], head) ==
    offsetOf(MupmucBase[8, 4, 4, int], head)
  doAssert offsetOf(Mupmuc[8, 4, 4, int], tail) ==
    offsetOf(MupmucBase[8, 4, 4, int], tail)
  doAssert offsetOf(Mupmuc[8, 4, 4, int], cells) ==
    offsetOf(MupmucBase[8, 4, 4, int], cells)

proc clear[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]) =
  self.head.store(0'u64, moRelaxed)
  self.tail.store(0'u64, moRelaxed)
  self.cells.init()
  for p in 0 ..< P:
    self.producerThreadIds[p].store(0, moRelaxed)
  for c in 0 ..< C:
    self.consumerThreadIds[c].store(0, moRelaxed)

proc initMupmuc*[N, P, C: static int, T](): Mupmuc[N, P, C, T] =
  ## Initialize a new Mupmuc queue.
  result.clear()

proc getProducer*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T], idx: int = -1
): MupmucProducer[N, P, C, T] {.raises: [NoProducersAvailableError].} =
  ## Assigns and returns a `MupmucProducer` instance for the current thread.
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
      expected, threadId, moRelease, moRelaxed
    ):
      result.idx = i
      return

  # Producers are all spoken for by another thread
  raise newException(
    NoProducersAvailableError,
    "All producers have been assigned. " &
      "Increase your producer count (P) or setMaxPoolSize(P).",
  )

proc getConsumer*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T], idx: int = -1
): Consumer[N, P, C, T] {.raises: [NoConsumersAvailableError].} =
  ## Assigns and returns a `Consumer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  # getThreadId will be undeclared unless compiled with --threads:on
  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> consumerIdx
  for i in 0 ..< C:
    if self.consumerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  # Try to create new mapping of threadId -> consumerIdx
  for i in 0 ..< C:
    var expected = 0
    if self.consumerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moRelaxed
    ):
      result.idx = i
      return

  # Consumers are all spoken for by another thread
  raise newException(
    NoConsumersAvailableError,
    "All consumers have been assigned. " &
      "Increase your consumer count (C) or setMaxPoolSize(min(C, P)).",
  )

proc push*[N, P, C: static int, T](self: MupmucProducer[N, P, C, T], item: T): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is lock-free: producers never block on each other.
  ## Uses the Vyukov per-slot `seq` protocol via the `mpmc_push` typestate.

  # Cast queue to MupmucPushBase for typestate compatibility (sound per the
  # static offsetof asserts at the top of this module).
  var queueBase = cast[ptr MupmucPushBase[N, P, C, T]](self.queue)

  var op = mpmc_push.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPMCPushFull(full):
        return full.extractFalse()
      MPMCPushSlotClaimed(slotClaimed):
        return slotClaimed.complete(queueBase[], item)
      MPMCPushStart(restart):
        op = restart # CAS race or producer raced ahead: retry
        backoffOnRetry(spins)
        continue

proc push*[N, P, C: static int, T](
    self: MupmucProducer[N, P, C, T], items: openArray[T]
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

proc pop*[N, P, C: static int, T](self: Consumer[N, P, C, T]): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## Otherwise an item is popped and `some(T)` is returned.
  ##
  ## This operation is lock-free: consumers never block on each other.
  ## Uses the Vyukov per-slot `seq` protocol via the `mpmc_pop` typestate.

  # Cast queue to MupmucBase for typestate compatibility (sound per the
  # static offsetof asserts at the top of this module).
  var queueBase = cast[ptr MupmucBase[N, P, C, T]](self.queue)

  var op = mpmc_pop.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPMCPopEmpty(_):
        return none(T)
      MPMCPopSlotClaimed(slotClaimed):
        return some(slotClaimed.complete(queueBase[]))
      MPMCPopStart(restart):
        op = restart # CAS race or consumer raced ahead: retry
        backoffOnRetry(spins)
        continue

proc pop*[N, P, C: static int, T](
    self: Consumer[N, P, C, T], count: int
): Option[seq[T]] =
  ## Pop up to `count` items from the queue (best-effort drain).
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one and at
  ## most `count` items.
  ##
  ## SEMANTIC CHANGE FROM 3.x: The old API atomically reserved a contiguous
  ## block via `fetchAdd` on a `reservedHead` cursor; this API does not.
  ## Bulk pop is now a loop of single-item pops — the returned sequence may
  ## be shorter than `count` even when the queue still contains items
  ## visible to other consumers.
  ##
  ## This operation is lock-free: consumers never block on each other.
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

proc push*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T], item: T): bool =
  ## Raises `InvalidCallDefect`. Use `MupmucProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use MupmucProducer.push()")

proc push*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Raises `InvalidCallDefect`. Use `MupmucProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use MupmucProducer.push()")

proc pop*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]): Option[T] =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")

proc pop*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T], count: int
): Option[seq[T]] =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")

proc capacity*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N

proc producerCount*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T]
): int {.inline.} =
  ## Returns the queue's number of producers (`P`).
  result = P

proc consumerCount*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T]
): int {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  result = C

when defined(testing):
  from unittest import check

  proc reset*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]) =
    ## Resets the queue to its default state.
    ## For single-threaded unit tests only.
    self.clear()

  proc checkState*[N, P, C: static int, T](
      self: var Mupmuc[N, P, C, T], head: uint64, tail: uint64
  ) =
    ## Check internal queue state for testing (head + tail only).
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)

  proc checkState*[N, P, C: static int, T](
      self: var Mupmuc[N, P, C, T], head: uint64, tail: uint64, data: seq[T]
  ) =
    ## Check internal queue state for testing.
    ## Verifies head, tail, and each cell's payload data against `data`.
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0 ..< N:
      check(self.cells.cells[i].payload.data == data[i])
