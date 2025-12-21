## A single-producer, multi-consumer (SPMC) bounded queue.
##
## Sipmuc provides wait-free push operations (single producer) and lock-free
## pop operations (multiple consumers coordinate via CAS).

when not compileOption("threads"):
  {.error: "lockfreequeues/sipmuc requires --threads:on option.".}

import atomics
import options

import ./constants
import ./exceptions
import ./typestates
import ./typestates/spmc_push
import ./typestates/spmc_pop

export exceptions

const NoSlice* = none(HSlice[int, int])

type
  Sipmuc*[N, C: static int, T] = object
    ## A single-producer, multi-consumer (SPMC) bounded queue.
    ## Uses N slots with committed flags.
    ##
    ## * `N` is the capacity (number of items that can be stored).
    ## * `C` is the number of consumer threads.
    ## * `T` is the type of data the queue will hold.
    head* {.align: CacheLineBytes.}: Atomic[int]
    reservedHead* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    storage*: StorageN[N, T]
    committed*: CommittedFlagsN[N]
    consumerThreadIds*: array[C, Atomic[int]]

  Consumer*[N, C: static int, T] = object
    idx*: int
    queue*: ptr Sipmuc[N, C, T]

proc clear[N, C: static int, T](self: var Sipmuc[N, C, T]) =
  self.head.store(0, moRelaxed)
  self.tail.store(0, moRelaxed)
  self.reservedHead.store(0, moRelaxed)
  self.storage.init()
  self.committed.init()
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
  ## This operation is wait-free for the single producer.
  ## Uses typestate to ensure correct operation sequencing.

  # Cast queue to SipmucBase for typestate compatibility
  var queueBase = cast[ptr SipmucBase[N, C, T]](addr self)

  let op = spmc_push.start[N]()
  let loaded = op.loadPointers(queueBase[])
  let fullCheck = loaded.checkFull()

  case fullCheck.kind
  of sSPMCPushFull:
    return fullCheck.spmcpushfull.extractFalse()
  of sSPMCPushNotFull:
    let notFull = fullCheck.spmcpushnotfull
    let written = notFull.writeData(queueBase[], item)
    return written.complete(queueBase[])

proc push*[N, C: static int, T](
    self: var Sipmuc[N, C, T], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  if unlikely(items.len == 0):
    return NoSlice

  let tail = loadAcquireN[N](self.tail).validate()
  let reservedHead = loadAcquireN[N](self.reservedHead).validate()

  if unlikely(fullN(reservedHead, tail)):
    return some(0 .. items.len - 1)

  let avail = availableN(reservedHead, tail)
  var count: int

  if likely(avail >= items.len):
    result = NoSlice
    count = items.len
  else:
    result = some(avail .. items.len - 1)
    count = min(avail, N)

  # Write each item
  for i in 0 ..< count:
    let currentTail = tail.incOrResetN(i)
    self.storage[currentTail.index()] = items[i]

  # Mark all committed
  for i in 0 ..< count:
    let slot = tail.incOrResetN(i).index()
    self.committed.store(slot, true)

  let newTail = tail.incOrResetN(count)
  self.tail.storeReleaseN(newTail)

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
  ##
  ## This operation is lock-free: consumers never block on each other.
  ## Uses typestate to ensure correct operation sequencing.

  # Cast queue to SipmucBase for typestate compatibility
  var queueBase = cast[ptr SipmucBase[N, C, T]](self.queue)

  var op = spmc_pop.start[N]()

  while true:
    let loaded = op.loadPointers(queueBase[])

    let emptyCheck = loaded.checkEmpty()
    case emptyCheck.kind
    of sSPMCPopEmpty:
      return none(T)
    of sSPMCPopNotEmpty:
      let notEmpty = emptyCheck.spmcpopnotempty
      let committedCheck = notEmpty.checkCommitted(queueBase[])
      case committedCheck.kind
      of sSPMCPopStart:
        op = committedCheck.spmcpopstart # Retry - producer still writing
        continue
      of sSPMCPopSlotReady:
        let ready = committedCheck.spmcpopslotready
        let claimResult = ready.tryClaim(queueBase[])
        case claimResult.kind
        of sSPMCPopStart:
          op = claimResult.spmcpopstart # Retry - CAS contention
          continue
        of sSPMCPopSlotClaimed:
          let claimed = claimResult.spmcpopslotclaimed
          return some(claimed.complete(queueBase[]))

proc pop*[N, C: static int, T](self: Consumer[N, C, T], count: int): Option[seq[T]] =
  ## Pop `count` items from the queue.
  if unlikely(count <= 0):
    return none(seq[T])

  var items = newSeq[T]()

  for _ in 0 ..< count:
    let item = self.pop()
    if item.isNone:
      break
    items.add(item.get())

  if items.len == 0:
    return none(seq[T])

  return some(items)

proc pop*[N, C: static int, T](self: var Sipmuc[N, C, T]): Option[T] =
  raise newException(InvalidCallDefect, "Use Consumer.pop()")

proc pop*[N, C: static int, T](self: var Sipmuc[N, C, T], count: int): Option[seq[T]] =
  raise newException(InvalidCallDefect, "Use Consumer.pop()")

when defined(testing):
  from unittest import check

  proc reset*[N, C: static int, T](self: var Sipmuc[N, C, T]) =
    self.clear()

  proc checkState*[N, C: static int, T](
      self: var Sipmuc[N, C, T], head: int, reservedHead: int, tail: int
  ) =
    check(self.head.load(moRelaxed) == head)
    check(self.reservedHead.load(moRelaxed) == reservedHead)
    check(self.tail.load(moRelaxed) == tail)

  proc checkState*[N, C: static int, T](
      self: var Sipmuc[N, C, T], head: int, tail: int, storage: seq[T]
  ) =
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0 ..< N:
      check(self.storage.data[i] == storage[i])
