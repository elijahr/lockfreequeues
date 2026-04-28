# Sipmuc & Unbounded Queues Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Sipmuc (SPMC) bounded queue and create unbounded segment-based versions of all four queue types with epoch-based memory reclamation.

**Architecture:** Sipmuc inherits from Sipsic (simple push) and adds Mupmuc-style consumer coordination. Unbounded queues use linked segments with an EpochManager for safe deallocation. Dynamic thread registration for unbounded queues.

**Tech Stack:** Nim 2.0+, atomics, unittest2

---

## Phase 1: Bounded Sipmuc

### Task 1.1: Create Sipmuc Test File Structure

**Files:**
- Create: `tests/t_suc.nim` (shared SPMC consumer test templates)
- Create: `tests/t_sipmuc.nim` (main test file)

**Step 1: Create shared consumer test templates**

Create `tests/t_suc.nim`:

```nim
# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Shared test templates for single-producer, multi-consumer queues (Sipmuc).


template testSucPopOne*(queue: untyped) =
  ## Test popping one item via Consumer.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let res = queue.getConsumer(0).pop()
  check(res.isSome)
  check(res.get == 1)

  queue.checkState(
    head = 1,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[1, 0, 0, 0]),
  )


template testSucPopAll*(queue: untyped) =
  ## Test popping all items via Consumer.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var items = newSeq[int]()
  for i in 1..8:
    let res = queue.getConsumer(0).pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testSucPopEmpty*(queue: untyped) =
  ## Test popping from empty queue.
  check(queue.getConsumer(0).pop().isNone)

  queue.checkState(
    head = 0,
    tail = 0,
    storage = repeat(0, 8),
  )
  queue.checkState(
    prevConsumerIdx = NoConsumerIdx,
    consumerHeads = repeat(0, 4),
  )


template testSucPopTooMany*(queue: untyped) =
  ## Test popping more items than available.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1..8:
    discard queue.getConsumer(0).pop()

  check(queue.getConsumer(0).pop().isNone)

  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testSucPopWrap*(queue: untyped) =
  ## Test popping with wraparound.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1..4:
    discard queue.getConsumer(0).pop()

  discard queue.push(@[9, 10, 11, 12])

  var items = newSeq[int]()
  for i in 1..8:
    let res = queue.getConsumer(0).pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(
    head = 12,
    tail = 12,
    storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[12, 0, 0, 0]),
  )


template testSucPopCountOne*(queue: untyped) =
  ## Test batch pop of one item at a time.
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  for i in 1..8:
    let popped = queue.getConsumer(0).pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testSucPopCountAll*(queue: untyped) =
  ## Test batch pop of all items.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.getConsumer(0).pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testSucPopCountEmpty*(queue: untyped) =
  ## Test batch pop from empty queue.
  let popped = queue.getConsumer(0).pop(1)
  check(popped.isNone)
  queue.checkState(
    head = 0,
    tail = 0,
    storage = repeat(0, 8),
  )
  queue.checkState(
    prevConsumerIdx = NoConsumerIdx,
    consumerHeads = repeat(0, 4),
  )


template testSucPopCountTooMany*(queue: untyped) =
  ## Test batch pop requesting more than available.
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

  queue.checkState(
    head = 0,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )

  let popped = queue.getConsumer(0).pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testSucPopCountWrap*(queue: untyped) =
  ## Test batch pop with wraparound.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  discard queue.getConsumer(0).pop(4)

  discard queue.push(@[9, 10, 11, 12])

  let popped = queue.getConsumer(1).pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(
    head = 12,
    tail = 12,
    storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevConsumerIdx = 1,
    consumerHeads = (@[4, 12, 0, 0]),
  )


template testSucGetConsumerAssigns*(queue: untyped) =
  ## Test that getConsumer assigns by thread ID.
  let consumer = queue.getConsumer()
  check(consumer.idx >= 0)
  check(consumer.idx < 4)


template testSucGetConsumerReusesAssigned*(queue: untyped) =
  ## Test that getConsumer reuses previously assigned index.
  let consumer1 = queue.getConsumer()
  let consumer2 = queue.getConsumer()
  check(consumer1.idx == consumer2.idx)


template testSucGetConsumerExplicitIndex*(queue: untyped) =
  ## Test explicit consumer index assignment.
  let consumer = queue.getConsumer(2)
  check(consumer.idx == 2)
```

**Step 2: Run test to verify it compiles**

Run: `nim c tests/t_suc.nim`
Expected: Compiles successfully (it's just templates)

**Step 3: Commit**

```bash
git add tests/t_suc.nim
git commit -m "feat(sipmuc): add shared SPMC consumer test templates"
```

---

### Task 1.2: Create Sipmuc Type and Init

**Files:**
- Create: `src/lockfreequeues/sipmuc.nim`

**Step 1: Write failing test**

Create `tests/t_sipmuc.nim`:

```nim
# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import sequtils
import unittest2

import lockfreequeues
import ./t_integration
import ./t_suc


var queue = initSipmuc[8, 4, int]()


suite "Sipmuc[N, C, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "consumerCount":
    check(queue.consumerCount == 4)

  test "initial state":
    queue.checkState(
      head = 0,
      tail = 0,
      storage = repeat(0, 8),
    )
    queue.checkState(
      prevConsumerIdx = NoConsumerIdx,
      consumerHeads = repeat(0, 4),
    )
```

**Step 2: Run test to verify it fails**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: FAIL - `initSipmuc` not defined

**Step 3: Write minimal implementation**

Create `src/lockfreequeues/sipmuc.nim`:

```nim
# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, multi-consumer bounded queue implemented as a ring buffer.

when not compileOption("threads"):
  {.error: "lockfreequeues/sipmuc requires --threads:on option.".}

import atomics
import options

import ./constants
import ./ops
import ./sipsic


const NoConsumerIdx* = -1 ## The initial value of `Sipmuc.prevConsumerIdx`.


type NoConsumersAvailableError* = object of CatchableError ## \
  ## Raised by `getConsumer()` if all consumers have been assigned to other
  ## threads.


type
  Sipmuc*[N, C: static int, T] = object of Sipsic[N, T]
    ## A single-producer, multi-consumer bounded queue implemented as a ring
    ## buffer. Pushing is wait-free. Popping is lock-free.
    ##
    ## :param N: The capacity of the queue.
    ## :param C: The number of consumer threads.
    ## :param T: The type of data the queue will hold.

    prevConsumerIdx*: Atomic[int] ## The ID (index) of the most recent consumer
    consumerHeads*: array[C, Atomic[int]] ## Array of consumer heads
    consumerThreadIds*: array[C, Atomic[int]] ## \
      ## Array of consumer thread IDs by index

  Consumer*[N, C: static int, T] = object
    ## A per-thread interface for popping items from a queue.
    ## Retrieved via a call to `Sipmuc.getConsumer()`
    ##
    ## :param N: The capacity of the queue.
    ## :param C: The number of consumer threads.
    ## :param T: The type of data the queue will hold.
    idx*: int ## The consumer's unique identifier.
    queue*: ptr Sipmuc[N, C, T] ## A reference to the consumer's queue.


proc clear[N, C: static int, T](
  self: var Sipmuc[N, C, T]
) =
  self.head.store(0, moSequentiallyConsistent)
  self.tail.store(0, moSequentiallyConsistent)

  for n in 0..<N:
    self.storage[n].reset()

  self.prevConsumerIdx.store(NoConsumerIdx, moSequentiallyConsistent)
  for c in 0..<C:
    self.consumerHeads[c].store(0, moSequentiallyConsistent)
    self.consumerThreadIds[c].store(0, moSequentiallyConsistent)


proc initSipmuc*[N, C: static int, T](): Sipmuc[N, C, T] =
  ## Initialize a new Sipmuc queue.
  ##
  ## :returns: A new Sipmuc queue instance.
  ##
  ## .. code-block:: nim
  ##    var queue = initSipmuc[64, 4, int]()
  result.clear()


proc consumerCount*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
): int
  {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  ##
  ## :returns: The number of consumer slots.
  result = C


when defined(testing):
  import sugar
  from unittest import check

  proc reset*[N, C: static int, T](
    self: var Sipmuc[N, C, T]
  ) =
    ## Resets the queue to its default state.
    self.clear()

  proc checkState*[N, C: static int, T](
    self: var Sipmuc[N, C, T],
    prevConsumerIdx: int,
    consumerHeads: seq[int],
  ) =
    check(self.prevConsumerIdx.load(moSequentiallyConsistent) == prevConsumerIdx)
    let heads = collect(newSeq):
      for c in 0..<C:
        self.consumerHeads[c].load(moSequentiallyConsistent)
    check(heads == consumerHeads)
```

**Step 4: Update main exports**

Modify `src/lockfreequeues.nim` - add sipmuc to imports and exports:

```nim
when compileOption("threads"):
  import ./lockfreequeues/[
    atomic_dsl,
    constants,
    mupmuc,
    mupsic,
    ops,
    sipmuc,
    sipsic,
  ]

  export
    atomic_dsl,
    constants,
    mupmuc,
    mupsic,
    ops,
    sipmuc,
    sipsic
```

**Step 5: Run test to verify it passes**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: PASS

**Step 6: Commit**

```bash
git add src/lockfreequeues/sipmuc.nim src/lockfreequeues.nim tests/t_sipmuc.nim
git commit -m "feat(sipmuc): add Sipmuc type and initialization"
```

---

### Task 1.3: Implement getConsumer

**Files:**
- Modify: `src/lockfreequeues/sipmuc.nim`
- Modify: `tests/t_sipmuc.nim`

**Step 1: Write failing test**

Add to `tests/t_sipmuc.nim`:

```nim
suite "getConsumer(Sipmuc[N, C, T])":
  setup:
    queue.reset()

  test "assigns by thread id":
    testSucGetConsumerAssigns(queue)

  test "reuses assigned":
    testSucGetConsumerReusesAssigned(queue)

  test "explicit index":
    testSucGetConsumerExplicitIndex(queue)

  test "throws NoConsumersAvailableError":
    # Fill all consumer slots with fake thread IDs
    for c in 0..<4:
      queue.consumerThreadIds[c].store(c + 1000, moSequentiallyConsistent)

    expect NoConsumersAvailableError:
      discard queue.getConsumer()
```

**Step 2: Run test to verify it fails**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: FAIL - `getConsumer` not defined

**Step 3: Write implementation**

Add to `src/lockfreequeues/sipmuc.nim` after `consumerCount`:

```nim
proc getConsumer*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  idx: int = NoConsumerIdx,
): Consumer[N, C, T]
  {.raises: [NoConsumersAvailableError].} =
  ## Assigns and returns a `Consumer` instance for the current thread.
  ##
  ## :param idx: Optional explicit consumer index. If not provided,
  ##             assigns based on thread ID.
  ## :returns: A Consumer instance for popping items.
  ## :raises NoConsumersAvailableError: If all consumer slots are taken.
  ##
  ## .. code-block:: nim
  ##    var queue = initSipmuc[64, 4, int]()
  ##    let consumer = queue.getConsumer()
  ##    let item = consumer.pop()
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  # getThreadId will be undeclared unless compiled with --threads:on
  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> consumerIdx
  for idx in 0..<C:
    if self.consumerThreadIds[idx].load(moAcquire) == threadId:
      result.idx = idx
      return

  # Try to create new mapping of threadId -> consumerIdx
  for idx in 0..<C:
    var expected = 0
    if self.consumerThreadIds[idx].compareExchangeWeak(
      expected,
      threadId,
      moRelease,
      moAcquire,
    ):
      result.idx = idx
      return

  # Consumers are all spoken for by another thread
  raise newException(
    NoConsumersAvailableError,
    "All consumers have been assigned. " &
    "Increase your consumer count (C) or setMaxPoolSize(C).")
```

**Step 4: Run test to verify it passes**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: PASS

**Step 5: Commit**

```bash
git add src/lockfreequeues/sipmuc.nim tests/t_sipmuc.nim
git commit -m "feat(sipmuc): implement getConsumer with thread ID mapping"
```

---

### Task 1.4: Implement Consumer.pop (single item)

**Files:**
- Modify: `src/lockfreequeues/sipmuc.nim`
- Modify: `tests/t_sipmuc.nim`

**Step 1: Write failing test**

Add to `tests/t_sipmuc.nim`:

```nim
suite "pop(Consumer[N, C, T])":
  setup:
    queue.reset()

  test "one":
    testSucPopOne(queue)

  test "all":
    testSucPopAll(queue)

  test "empty":
    testSucPopEmpty(queue)

  test "too many":
    testSucPopTooMany(queue)

  test "wrap":
    testSucPopWrap(queue)
```

**Step 2: Run test to verify it fails**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: FAIL - `pop` for Consumer not defined

**Step 3: Write implementation**

Add to `src/lockfreequeues/sipmuc.nim`:

```nim
import ./atomic_dsl


proc pop*[N, C: static int, T](
  self: Consumer[N, C, T],
): Option[T] =
  ## Pop a single item from the queue.
  ##
  ## :returns: ``some(T)`` if an item was popped, ``none(T)`` if queue is empty.
  ##
  ## .. code-block:: nim
  ##    let consumer = queue.getConsumer()
  ##    let item = consumer.pop()
  ##    if item.isSome:
  ##      echo "Got: ", item.get

  var prevHead: int
  var newHead: int
  var prevConsumerIdx: int
  var isFirstConsumption: bool

  # spin until reservation is acquired
  while true:
    prevConsumerIdx = self.queue.prevConsumerIdx.acquire
    isFirstConsumption = prevConsumerIdx == NoConsumerIdx
    var tail = self.queue.tail.sequential
    prevHead =
      if isFirstConsumption:
        0
      else:
        self.queue.consumerHeads[prevConsumerIdx].acquire

    if unlikely(empty(prevHead, tail, N)):
      return none(T)

    newHead = incOrReset(prevHead, 1, N)
    self.queue.consumerHeads[self.idx].release(newHead)

    if self.queue.prevConsumerIdx.compareExchangeWeak(
      prevConsumerIdx,
      self.idx,
      moRelease,
      moAcquire,
    ):
      break

  result = some(self.queue.storage[index(prevHead, N)])

  # Wait for prev consumer to update head, then update head
  if not isFirstConsumption:
    while true:
      var expectedHead = prevHead
      if self.queue.head.compareExchangeWeak(
        expectedHead,
        newHead,
        moRelease,
        moAcquire,
      ):
        break
  else:
    self.queue.head.release(newHead)
```

**Step 4: Run test to verify it passes**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: PASS

**Step 5: Commit**

```bash
git add src/lockfreequeues/sipmuc.nim tests/t_sipmuc.nim
git commit -m "feat(sipmuc): implement Consumer.pop for single items"
```

---

### Task 1.5: Implement Consumer.pop (batch)

**Files:**
- Modify: `src/lockfreequeues/sipmuc.nim`
- Modify: `tests/t_sipmuc.nim`

**Step 1: Write failing test**

Add to `tests/t_sipmuc.nim`:

```nim
suite "pop(Consumer[N, C, T], int)":
  setup:
    queue.reset()

  test "one":
    testSucPopCountOne(queue)

  test "all":
    testSucPopCountAll(queue)

  test "empty":
    testSucPopCountEmpty(queue)

  test "too many":
    testSucPopCountTooMany(queue)

  test "wrap":
    testSucPopCountWrap(queue)
```

**Step 2: Run test to verify it fails**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: FAIL - batch `pop` for Consumer not defined

**Step 3: Write implementation**

Add to `src/lockfreequeues/sipmuc.nim`:

```nim
proc pop*[N, C: static int, T](
  self: Consumer[N, C, T],
  count: int,
): Option[seq[T]] =
  ## Pop `count` items from the queue.
  ##
  ## :param count: Maximum number of items to pop.
  ## :returns: ``some(seq[T])`` with at least one item, or ``none(seq[T])`` if empty.
  ##
  ## .. code-block:: nim
  ##    let consumer = queue.getConsumer()
  ##    let items = consumer.pop(10)
  ##    if items.isSome:
  ##      for item in items.get:
  ##        echo item

  if unlikely(count <= 0):
    return none(seq[T])

  var actualCount: int
  var used: int
  var prevHead: int
  var newHead: int
  var prevConsumerIdx: int
  var isFirstConsumption: bool
  var tail: int

  # spin until reservation is acquired
  while true:
    prevConsumerIdx = self.queue.prevConsumerIdx.acquire
    isFirstConsumption = prevConsumerIdx == NoConsumerIdx
    tail = self.queue.tail.sequential
    prevHead =
      if isFirstConsumption:
        0
      else:
        self.queue.consumerHeads[prevConsumerIdx].acquire

    used = used(prevHead, tail, N)
    if likely(used >= count):
      # Enough items to fulfill request
      actualCount = count
    elif used <= 0:
      # Queue is empty, return nothing
      return none(seq[T])
    else:
      # Not enough items to fulfill request
      actualCount = min(used, N)

    newHead = incOrReset(prevHead, actualCount, N)
    self.queue.consumerHeads[self.idx].release(newHead)

    if self.queue.prevConsumerIdx.compareExchangeWeak(
      prevConsumerIdx,
      self.idx,
      moRelease,
      moAcquire,
    ):
      break

  let start = index(prevHead, N)
  var stop = incOrReset(prevHead, actualCount - 1, N)
  stop = index(stop, N)

  var items = newSeq[T](actualCount)

  if start > stop:
    # data may wrap
    let pivot = (N-1) - start
    items[0..pivot] = self.queue.storage[start..start+pivot]
    if stop > 0:
      # data wraps
      items[pivot+1..pivot+1+stop] = self.queue.storage[0..stop]
  else:
    # data does not wrap
    items[0..stop-start] = self.queue.storage[start..stop]

  result = some(items)

  # Wait for prev consumer to update head, then update head
  if not isFirstConsumption:
    while true:
      var expectedHead = prevHead
      if self.queue.head.compareExchangeWeak(
        expectedHead,
        newHead,
        moRelease,
        moAcquire,
      ):
        break

  elif isFirstConsumption:
    self.queue.head.release(newHead)
```

**Step 4: Run test to verify it passes**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: PASS

**Step 5: Commit**

```bash
git add src/lockfreequeues/sipmuc.nim tests/t_sipmuc.nim
git commit -m "feat(sipmuc): implement Consumer.pop for batch items"
```

---

### Task 1.6: Add Sipmuc.pop override (raise error)

**Files:**
- Modify: `src/lockfreequeues/sipmuc.nim`
- Modify: `tests/t_sipmuc.nim`

**Step 1: Write failing test**

Add to `tests/t_sipmuc.nim`:

```nim
import lockfreequeues/mupsic  # For InvalidCallDefect

suite "pop(Sipmuc[N, C, T])":
  setup:
    queue.reset()

  test "single should fail":
    expect InvalidCallDefect:
      discard queue.pop()

  test "batch should fail":
    expect InvalidCallDefect:
      discard queue.pop(1)
```

**Step 2: Run test to verify it fails**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: FAIL - inherited Sipsic.pop runs instead of raising

**Step 3: Write implementation**

Add to `src/lockfreequeues/sipmuc.nim`:

```nim
import ./mupsic  # For InvalidCallDefect


proc pop*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
): Option[T] =
  ## Overload of `Sipsic.pop()` that raises `InvalidCallDefect`.
  ## Pops should happen via `Consumer.pop()`.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc pop*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  count: int,
): Option[seq[T]] =
  ## Overload of `Sipsic.pop()` that raises `InvalidCallDefect`.
  ## Pops should happen via `Consumer.pop()`.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")
```

**Step 4: Run test to verify it passes**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: PASS

**Step 5: Commit**

```bash
git add src/lockfreequeues/sipmuc.nim tests/t_sipmuc.nim
git commit -m "feat(sipmuc): add pop overrides that raise InvalidCallDefect"
```

---

### Task 1.7: Add Integration and Push Tests

**Files:**
- Modify: `tests/t_sipmuc.nim`

**Step 1: Add push and integration tests**

Add to `tests/t_sipmuc.nim`:

```nim
suite "push(Sipmuc[N, C, T], T)":
  setup:
    queue.reset()

  test "basic":
    # Sipmuc uses Sipsic's push directly (single producer)
    check(queue.push(1) == true)
    queue.checkState(
      head = 0,
      tail = 1,
      storage = (@[1, 0, 0, 0, 0, 0, 0, 0]),
    )

  test "overflow":
    for i in 1..8:
      check(queue.push(i) == true)
    check(queue.push(9) == false)

  test "wrap":
    for i in 1..8:
      discard queue.push(i)
    for i in 1..4:
      discard queue.getConsumer(0).pop()
    for i in 9..12:
      check(queue.push(i) == true)
    queue.checkState(
      head = 4,
      tail = 12,
      storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
    )


suite "push(Sipmuc[N, C, T], seq[T])":
  setup:
    queue.reset()

  test "basic":
    check(queue.push(@[1, 2, 3, 4]).isNone)
    queue.checkState(
      head = 0,
      tail = 4,
      storage = (@[1, 2, 3, 4, 0, 0, 0, 0]),
    )

  test "overflow":
    let unpushed = queue.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    check(unpushed.isSome)
    check(unpushed.get == 8..9)

  test "wrap":
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
    for i in 1..4:
      discard queue.getConsumer(0).pop()
    check(queue.push(@[9, 10, 11, 12]).isNone)
    queue.checkState(
      head = 4,
      tail = 12,
      storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
    )


suite "capacity(Sipmuc[N, C, T])":
  test "basic":
    testCapacity(queue)


suite "Sipmuc integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)
```

**Step 2: Run tests**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc.nim`
Expected: PASS

**Step 3: Commit**

```bash
git add tests/t_sipmuc.nim
git commit -m "test(sipmuc): add push and integration tests"
```

---

### Task 1.8: Add Threaded Tests

**Files:**
- Create: `tests/t_sipmuc_threaded.nim`

**Step 1: Create threaded test file**

Create `tests/t_sipmuc_threaded.nim`:

```nim
# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import os
import unittest2

import lockfreequeues


const
  NumItems = 100000
  NumConsumers = 4


var queue = initSipmuc[1024, NumConsumers, int]()
var consumed: array[NumConsumers, seq[int]]
var totalConsumed: Atomic[int]


proc consumerThread(idx: int) {.thread.} =
  consumed[idx] = newSeq[int]()
  let consumer = queue.getConsumer(idx)
  while true:
    let item = consumer.pop()
    if item.isSome:
      consumed[idx].add(item.get)
      discard totalConsumed.fetchAdd(1, moRelaxed)
    elif totalConsumed.load(moRelaxed) >= NumItems:
      break
    else:
      # Spin wait
      discard


suite "Sipmuc threaded":
  test "single producer, multiple consumers":
    totalConsumed.store(0, moRelaxed)

    var threads: array[NumConsumers, Thread[int]]

    # Start consumer threads
    for i in 0..<NumConsumers:
      createThread(threads[i], consumerThread, i)

    # Producer pushes items
    for i in 1..NumItems:
      while not queue.push(i):
        # Queue full, spin wait
        discard

    # Wait for consumers
    for i in 0..<NumConsumers:
      joinThread(threads[i])

    # Verify all items consumed
    var allConsumed = newSeq[int]()
    for i in 0..<NumConsumers:
      allConsumed.add(consumed[i])

    allConsumed.sort()
    var expected = newSeq[int]()
    for i in 1..NumItems:
      expected.add(i)

    check(allConsumed == expected)
    check(totalConsumed.load(moRelaxed) == NumItems)
```

**Step 2: Run threaded tests**

Run: `nim c -r -d:testing --threads:on tests/t_sipmuc_threaded.nim`
Expected: PASS

**Step 3: Commit**

```bash
git add tests/t_sipmuc_threaded.nim
git commit -m "test(sipmuc): add multi-threaded stress tests"
```

---

### Task 1.9: Add Sipmuc to Test Runner

**Files:**
- Modify: `tests/test.nim`

**Step 1: Check current test runner**

Read `tests/test.nim` to see current structure.

**Step 2: Add sipmuc imports**

Add to `tests/test.nim`:

```nim
import ./t_sipmuc
import ./t_sipmuc_threaded
```

**Step 3: Run full test suite**

Run: `nimble test`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add tests/test.nim
git commit -m "test: add sipmuc tests to main test runner"
```

---

### Task 1.10: Add Sipmuc Example

**Files:**
- Create: `examples/sipmuc.nim`
- Modify: `lockfreequeues.nimble`

**Step 1: Create example**

Create `examples/sipmuc.nim`:

```nim
## Example: Single-producer, multi-consumer queue
##
## This demonstrates a fan-out pattern where one producer
## distributes work to multiple consumers.

import lockfreequeues
import os

const
  NumItems = 100
  NumConsumers = 4


var queue = initSipmuc[64, NumConsumers, int]()


proc consumerThread(idx: int) {.thread.} =
  let consumer = queue.getConsumer(idx)
  var count = 0
  while true:
    let item = consumer.pop()
    if item.isSome:
      inc count
      # Process item...
    else:
      sleep(1)
      if count > 0 and item.isNone:
        # No more items and we've processed some
        break
  echo "Consumer ", idx, " processed ", count, " items"


when isMainModule:
  var threads: array[NumConsumers, Thread[int]]

  # Start consumers
  for i in 0..<NumConsumers:
    createThread(threads[i], consumerThread, i)

  # Producer
  for i in 1..NumItems:
    while not queue.push(i):
      sleep(1)

  sleep(100)  # Let consumers finish

  for i in 0..<NumConsumers:
    joinThread(threads[i])

  echo "Done!"
```

**Step 2: Update nimble examples task**

Add to examples task in `lockfreequeues.nimble`:

```nim
task examples, "Runs the examples":
  exec "nim c -r -f examples/mupmuc.nim"
  exec "nim c -r -f examples/mupsic.nim"
  exec "nim c -r -f examples/sipmuc.nim"
  exec "nim c -r -f examples/sipsic.nim"
```

**Step 3: Run examples**

Run: `nimble examples`
Expected: All examples run successfully

**Step 4: Commit**

```bash
git add examples/sipmuc.nim lockfreequeues.nimble
git commit -m "docs(sipmuc): add example demonstrating fan-out pattern"
```

---

## Phase 1 Complete Checkpoint

Run full test suite to verify Phase 1:

```bash
nimble test
```

Expected: All tests pass, including new Sipmuc tests.

**Phase 1 delivers:**
- Complete bounded Sipmuc (SPMC) implementation
- Full test coverage (single-threaded + threaded)
- Example code
- Integrated into test runner

---

## Phase 2: Epoch Manager

*(Tasks 2.1 - 2.6 to be added after Phase 1 approval)*

Key components:
- `src/lockfreequeues/epoch.nim` - EpochManager, EpochGuard types
- Pin/unpin/retire/reclaim operations
- Thread-safe registration
- Unit tests for reclamation correctness

---

## Phase 3: Unbounded Sipsic

*(Tasks 3.1 - 3.8 to be added after Phase 2 approval)*

Key components:
- `src/lockfreequeues/unbounded/sipsic.nim` - Segment-based SPSC
- Segment linking (wait-free for single producer)
- Integration with EpochManager
- DeallocationStrategy enum
- Tests for all strategies

---

## Phase 4: Remaining Unbounded Queues

*(Tasks 4.1 - 4.6 to be added after Phase 3 approval)*

- UnboundedSipmuc - dynamic consumer registration
- UnboundedMupsic - dynamic producer registration
- UnboundedMupmuc - both dynamic

---

## Phase 5: Documentation

*(Tasks 5.1 - 5.4 to be added after Phase 4 approval)*

- RST-style docstrings for all public APIs
- Mkdocs site structure
- Guides: choosing-a-queue, segment-size-guide, etc.
- Examples
