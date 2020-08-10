# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage of Sipsic, a single-producer, single-consumer bounded queue.

import options
import random

import lockfreequeues

var
  # Queue that can hold 8 ints at a time
  queue = initSipsic[8, int]()


proc consumerFunc() {.thread.} =
  for i in 0..32:
    # Try to pop a single item from the queue; pop() returns Option[int]
    let item = queue.pop()

    echo "[consumer] popped item: ", item

    # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
    let items = queue.pop(4)

    echo "[consumer] popped items: ", items


proc producerFunc() {.thread.} =

  for i in 0..32:
    let item = rand(100)

    # Try to push a single item; push will return false when queue is full
    echo "[producer] pushed item: ", item, "? ", queue.push(item)

    let items = @[
      rand(100),
      rand(100),
      rand(100),
      rand(100),
    ]

    # Try to push the items. If not all items could be pushed,
    # the remainder is returned as an Option[HSlice[int, int]] suitable for
    # slicing the sequence.
    let remainder = queue.push(items)

    if remainder.isSome:
      echo "[producer] pushed items: ", items[0..<remainder.get.a], ", unpushed items: ", items[remainder.get]
    else:
      echo "[producer] pushed all items: ", items


var threads: array[2, Thread[void]]

threads[0].createThread(consumerFunc)
threads[1].createThread(producerFunc)

joinThreads(threads)
