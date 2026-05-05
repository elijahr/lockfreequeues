## A single-producer, multi-consumer (SPMC) bounded queue.
##
## Both push and pop are lock-free, using the Vyukov per-slot sequence
## protocol (see `typestates/mpmc_cell` and the `spmc_push` / `spmc_pop`
## verb modules). The single producer coordinates via CAS on `tail`
## (defensive — see design doc §10.6); consumers race on `head` via CAS;
## the per-slot `seq` counter on each cell carries the producer->consumer
## and consumer->next-producer happens-before edges, eliminating the
## separate `committed` flag array used by the old protocol.

when not compileOption("threads"):
  {.error: "lockfreequeues/sipmuc requires --threads:on option.".}

import ./atomic_dsl
import ./backoff
import options

import ./exceptions
import ./typestates
import ./typestates/mpmc_cell
import ./typestates/spmc_push
import ./typestates/spmc_pop

export exceptions

const NoSlice* = none(HSlice[int, int])

type
  Sipmuc*[N, C: static int, T] = object
    ## A single-producer, multi-consumer bounded queue.
    ## Uses Vyukov per-slot sequence counters (see `MPMCCellArrayN`).
    ## Both push and pop are lock-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `C` is the number of consumer threads.
    ## * `T` is the type of data the queue will hold.
    ##
    ## Field order constraint: `head`, `tail`, `cells` MUST be the first
    ## three fields (in that order) so the unsafe casts in `push`/`pop`
    ## to `SipmucPushBase` / `SipmucBase` are sound. The `static` block
    ## below pins these offsets via `offsetof`.
    head* {.align: CacheLineBytes.}: Atomic[uint64]
    tail* {.align: CacheLineBytes.}: Atomic[uint64]
    cells*: MPMCCellArrayN[N, T]
    consumerThreadIds*: array[C, Atomic[int]]

  Consumer*[N, C: static int, T] = object
    ## A per-thread interface for popping items from a Sipmuc queue.
    idx*: int
    queue*: ptr Sipmuc[N, C, T]

# I1 (design doc §10.12): the facade casts `ptr Sipmuc` to
# `ptr SipmucPushBase` / `ptr SipmucBase` in push/pop. That cast is sound
# only if the shared field PREFIX (head, tail, cells) has identical offsets.
# Sizeof equality would be wrong because Sipmuc carries the
# consumerThreadIds array not present in the bases. Picking [8, 4, int]
# as the canonical generic instantiation is arbitrary but sufficient:
# object-field offsets are computed structurally, so a match for one
# instantiation implies a match for all.
static:
  doAssert offsetOf(Sipmuc[8, 4, int], head) == offsetOf(
    SipmucPushBase[8, 4, int], head
  )
  doAssert offsetOf(Sipmuc[8, 4, int], tail) == offsetOf(
    SipmucPushBase[8, 4, int], tail
  )
  doAssert offsetOf(Sipmuc[8, 4, int], cells) ==
    offsetOf(SipmucPushBase[8, 4, int], cells)
  doAssert offsetOf(Sipmuc[8, 4, int], head) == offsetOf(SipmucBase[8, 4, int], head)
  doAssert offsetOf(Sipmuc[8, 4, int], tail) == offsetOf(SipmucBase[8, 4, int], tail)
  doAssert offsetOf(Sipmuc[8, 4, int], cells) == offsetOf(SipmucBase[8, 4, int], cells)

proc clear[N, C: static int, T](self: var Sipmuc[N, C, T]) =
  self.head.store(0'u64, moRelaxed)
  self.tail.store(0'u64, moRelaxed)
  self.cells.init()
  for c in 0 ..< C:
    self.consumerThreadIds[c].store(0, moRelaxed)

proc initSipmuc*[N, C: static int, T](): Sipmuc[N, C, T] =
  ## Initialize a new Sipmuc queue.
  result.clear()

proc consumerCount*[N, C: static int, T](self: var Sipmuc[N, C, T]): int {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  result = C

proc capacity*[N, C: static int, T](self: var Sipmuc[N, C, T]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N

proc push*[N, C: static int, T](self: var Sipmuc[N, C, T], item: T): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is lock-free for the single producer (defensive CAS
  ## per design doc §10.6).
  ## Uses the Vyukov per-slot `seq` protocol via the `spmc_push` typestate.

  # Cast queue to SipmucPushBase for typestate compatibility (sound per the
  # static offsetof asserts at the top of this module).
  var queueBase = cast[ptr SipmucPushBase[N, C, T]](addr self)

  var op = spmc_push.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      SPMCPushFull(full):
        return full.extractFalse()
      SPMCPushSlotClaimed(slotClaimed):
        return slotClaimed.complete(queueBase[], item)
      SPMCPushStart(restart):
        op = restart # CAS race or producer raced ahead: retry
        backoffOnRetry(spins)
        continue

proc push*[N, C: static int, T](
    self: var Sipmuc[N, C, T], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue (best-effort).
  ## If the queue is already full or fills during this call, `some(unpushed)`
  ## is returned, where `unpushed` is an `HSlice` corresponding to the
  ## chunk of items which could not be pushed.
  ## If all items are appended, `NoSlice` is returned.
  ##
  ## SEMANTIC CHANGE FROM 3.x: The old API atomically reserved a contiguous
  ## block via stores on `tail` after writing all items; this API does not.
  ## Bulk push is now a loop of single-item pushes — each item is published
  ## individually via the per-slot `seq` advance. Consumers still see each
  ## item exactly once, in the order it was committed.
  ##
  ## This operation is lock-free for the single producer.
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

proc getConsumer*[N, C: static int, T](
    self: var Sipmuc[N, C, T], idx: int = -1
): Consumer[N, C, T] {.raises: [NoConsumersAvailableError].} =
  ## Assigns and returns a `Consumer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  let threadId = getThreadId()

  # Try to find existing mapping
  for i in 0 ..< C:
    if self.consumerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  # Try to create new mapping
  for i in 0 ..< C:
    var expected = 0
    if self.consumerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moAcquire
    ):
      result.idx = i
      return

  raise newException(NoConsumersAvailableError, "All consumers assigned")

proc pop*[N, C: static int, T](self: Consumer[N, C, T]): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## Otherwise an item is popped and `some(T)` is returned.
  ##
  ## This operation is lock-free: consumers never block on each other.
  ## Uses the Vyukov per-slot `seq` protocol via the `spmc_pop` typestate.

  # Cast queue to SipmucBase for typestate compatibility (sound per the
  # static offsetof asserts at the top of this module).
  var queueBase = cast[ptr SipmucBase[N, C, T]](self.queue)

  var op = spmc_pop.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      SPMCPopEmpty(_):
        return none(T)
      SPMCPopSlotClaimed(slotClaimed):
        return some(slotClaimed.complete(queueBase[]))
      SPMCPopStart(restart):
        op = restart # CAS race or consumer raced ahead: retry
        backoffOnRetry(spins)
        continue

proc pop*[N, C: static int, T](self: Consumer[N, C, T], count: int): Option[seq[T]] =
  ## Pop up to `count` items from the queue (best-effort drain).
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one and at
  ## most `count` items.
  ##
  ## SEMANTIC CHANGE FROM 3.x: The old API atomically reserved a contiguous
  ## block via stores on `head`; this API does not. Bulk pop is now a loop
  ## of single-item pops — the returned sequence may be shorter than
  ## `count` even when the queue still contains items visible to other
  ## consumers.
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

proc pop*[N, C: static int, T](self: var Sipmuc[N, C, T]): Option[T] =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")

proc pop*[N, C: static int, T](self: var Sipmuc[N, C, T], count: int): Option[seq[T]] =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")

when defined(testing):
  from unittest import check

  proc reset*[N, C: static int, T](self: var Sipmuc[N, C, T]) =
    ## Resets the queue to its default state.
    ## For single-threaded unit tests only.
    self.clear()

  proc checkState*[N, C: static int, T](
      self: var Sipmuc[N, C, T], head: uint64, tail: uint64
  ) =
    ## Check internal queue state for testing (head + tail only).
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)

  proc checkState*[N, C: static int, T](
      self: var Sipmuc[N, C, T], head: uint64, tail: uint64, data: seq[T]
  ) =
    ## Check internal queue state for testing.
    ## Verifies head, tail, and each cell's payload data against `data`.
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0 ..< N:
      check(self.cells.cells[i].payload.data == data[i])
