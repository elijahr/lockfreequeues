## Shared bounded-queue exerciser templates. All bodies operate on
## `untyped` arguments so symbol resolution happens at the caller's
## context — no per-family legacy imports are needed here.
##
## Step 3.3.7b dropped the vestigial `import lockfreequeues/spmc`;
## the legacy modules are deleted in this commit.

template testCapacity*(queue: untyped) =
  check(queue.capacity == 8)

template testHeadAndTailReset*(queue: untyped) =
  # SPSC: Virtual space is 2*(N+1) = 18 for N=8, so valid values are 0..17
  # MPSC/SPMC/MPMC: Virtual space is 2*N = 16 for N=8, so valid values are 0..15
  # This test uses 17 which is only valid for SPSC (N+1 slot design)
  when not compiles(queue.getProducer(0)) and not compiles(queue.getConsumer(0)):
    # Set head/tail to 17 to test wrap from 17 -> 0 (SPSC/SPMC only)
    queue.head.sequential(17)
    queue.tail.sequential(17)
    when (not compiles(queue.getProducer(0)) and compiles(queue.getConsumer(0))):
      queue.reservedHead.sequential(17)
    # N+1=9 slots
    queue.checkState(head = 17, tail = 17, storage = repeat(0, 9))

    check(queue.push(@[1]).isNone)

    # With mod (N+1) indexing: index(17, 8) = 17 mod 9 = 8 (slot 8)
    # After push, tail becomes 18 which wraps to 0
    queue.checkState(
      head = 17,
      tail = 0,
      # slot 8 has item 1
      storage = (@[0, 0, 0, 0, 0, 0, 0, 0, 1]),
    )

    let res =
      when (not compiles(queue.getProducer(0)) and compiles(queue.getConsumer(0))):
        queue.getConsumer(0).pop(1)
      else:
        queue.pop(1)

    check(res.isSome)
    check(res.get == @[1])
    # After pop, head becomes 18 which wraps to 0
    queue.checkState(
      head = 0, tail = 0, storage = (@[0, 0, 0, 0, 0, 0, 0, 0, 1]), # slot 8 still has old value
    )

template testWraps*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    check(queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  else:
    check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

  var popRes =
    when compiles(queue.getConsumer(0)):
      queue.getConsumer(0).pop(4)
    else:
      queue.pop(4)

  check(popRes.isSome)
  check(popRes.get == @[1, 2, 3, 4])

  let pushRes =
    when compiles(queue.getProducer(0)):
      queue.getProducer(0).push(@[9, 10, 11, 12])
    else:
      queue.push(@[9, 10, 11, 12])

  check(pushRes.isNone)

  # With mod (N+1) indexing: items 9,10,11,12 go to slots 8,0,1,2
  when compiles(queue.getProducer(0)):
    queue.checkState(head = 4'u64, tail = 12'u64)
  elif not compiles(queue.getProducer(0)) and compiles(queue.getConsumer(0)):
    queue.checkState(
      head = 4'u64,
      tail = 12'u64,
      # slot 0: 10 (index 9 mod 9), slot 1: 11, slot 2: 12, slot 8: 9
      data = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]),
    )
  else:
    queue.checkState(
      head = 4,
      tail = 12,
      # slot 0: 10 (index 9 mod 9), slot 1: 11, slot 2: 12, slot 8: 9
      storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]),
    )

  popRes =
    when compiles(queue.getConsumer(0)):
      queue.getConsumer(0).pop(4)
    else:
      queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[5, 6, 7, 8])

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 8'u64, tail = 12'u64)
  elif not compiles(queue.getProducer(0)) and compiles(queue.getConsumer(0)):
    queue.checkState(head = 8'u64, tail = 12'u64, data = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))
  else:
    queue.checkState(head = 8, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))

  popRes =
    when compiles(queue.getConsumer(0)):
      queue.getConsumer(1).pop(4)
    else:
      queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[9, 10, 11, 12])

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 12'u64, tail = 12'u64)
  elif not compiles(queue.getProducer(0)) and compiles(queue.getConsumer(0)):
    queue.checkState(head = 12'u64, tail = 12'u64, data = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))
  else:
    queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))
