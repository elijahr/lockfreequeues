## Example usage of the unified `BQueue` generic in SPSC (single-producer,
## single-consumer) bounded cardinality.
##
## v5.0.0 cascade migration: the legacy `Spsc[N, T]` family was
## collapsed into `BQueue[T, ccSingle, ccSingle, N, 0, 0]` (the bounded
## 6-param shape — `ccProd = ccCons = ccSingle`, capacity `N`, producer
## and consumer view counts both zero for the SPSC arm). The
## constructor short form below uses the `newSpscQueue[T, N]()`
## smart-constructor.

import options
import random

import lockfreequeues

var
  # Queue that can hold 8 ints at a time
  q = newSpscQueue[int, 8]()

proc consumerFunc() {.thread.} =
  for i in 0 .. 32:
    # Try to pop a single item from the queue; pop() returns Option[int]
    let item = q.pop()

    echo "[consumer] popped item: ", item

    # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
    let items = q.pop(4)

    echo "[consumer] popped items: ", items

proc producerFunc() {.thread.} =
  for i in 0 .. 32:
    let item = rand(100)

    # Try to push a single item; push will return false when queue is full
    echo "[producer] pushed item: ", item, "? ", q.push(item)

    let items = @[rand(100), rand(100), rand(100), rand(100)]

    # Try to push the items. If not all items could be pushed,
    # the remainder is returned as an Option[HSlice[int, int]] suitable for
    # slicing the sequence.
    let remainder = q.push(items)

    if remainder.isSome:
      echo "[producer] pushed items: ",
        items[0 ..< remainder.get.a], ", unpushed items: ", items[remainder.get]
    else:
      echo "[producer] pushed all items: ", items

var threads: array[2, Thread[void]]

threads[0].createThread(consumerFunc)
threads[1].createThread(producerFunc)

joinThreads(threads)
