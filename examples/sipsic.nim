## Example usage of the unified `Queue` generic in SPSC (single-producer,
## single-consumer) bounded cardinality.
##
## v5.0.0 cascade migration: the legacy `Sipsic[N, T]` family was
## collapsed into `Queue[T, ccSingle, ccSingle, stEager, rkNone, N, 0,
## 0, 0, 0]`. The constructor short form below uses `initQueue[T,
## ccProd, ccCons, ST, N, P, C]()` (7-param shorthand for the bounded
## case; the underlying type fills in `rkNone, S=0, MaxThreads=0`).

import options
import random

import lockfreequeues
import lockfreequeues/queue as q_mod

var
  # Queue that can hold 8 ints at a time
  q = q_mod.initQueue[int, ccSingle, ccSingle, stEager, 8, 0, 0]()


proc consumerFunc() {.thread.} =
  for i in 0..32:
    # Try to pop a single item from the queue; pop() returns Option[int]
    let item = q.pop()

    echo "[consumer] popped item: ", item

    # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
    let items = q.pop(4)

    echo "[consumer] popped items: ", items


proc producerFunc() {.thread.} =

  for i in 0..32:
    let item = rand(100)

    # Try to push a single item; push will return false when queue is full
    echo "[producer] pushed item: ", item, "? ", q.push(item)

    let items = @[
      rand(100),
      rand(100),
      rand(100),
      rand(100),
    ]

    # Try to push the items. If not all items could be pushed,
    # the remainder is returned as an Option[HSlice[int, int]] suitable for
    # slicing the sequence.
    let remainder = q.push(items)

    if remainder.isSome:
      echo "[producer] pushed items: ", items[0..<remainder.get.a],
          ", unpushed items: ", items[remainder.get]
    else:
      echo "[producer] pushed all items: ", items


var threads: array[2, Thread[void]]

threads[0].createThread(consumerFunc)
threads[1].createThread(producerFunc)

joinThreads(threads)
