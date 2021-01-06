# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage of Mupsic, a multi-producer, single-consumer bounded queue.

import options
import random

import lockfreequeues

var
  # Queue that can hold 8 ints at a time,
  # with 32 producer workers
  queue = initMupsic[8, 32, int]()


proc consumerFunc() {.thread.} =
  for i in 0..32:
    # Try to pop a single item from the queue; pop() returns Option[int]
    let item = queue.pop()

    echo "[consumer] popped item: ", item

    # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
    let items = queue.pop(4)

    echo "[consumer] popped items: ", items


proc producerFunc() {.thread.} =
  # Get a unique producer for this thread
  var producer = queue.getProducer()

  let item = rand(100)

  # Try to push a single item; push will return false when queue is full
  echo "[producer ", producer.idx, "] pushed item: ", item, "? ", producer.push(item)

  let items = @[
    rand(100),
    rand(100),
    rand(100),
    rand(100),
  ]

  # Try to push the items. If not all items could be pushed,
  # the remainder is returned as an Option[HSlice[int, int]] suitable for
  # slicing the sequence.
  let remainder = producer.push(items)

  if remainder.isSome:
    echo "[producer ", producer.idx, "] pushed items: ", items[
        0..<remainder.get.a], ", unpushed items: ", items[remainder.get]
  else:
    echo "[producer ", producer.idx, "] pushed all items: ", items


var threads: array[33, Thread[void]]

threads[0].createThread(consumerFunc)

for p in 1..32:
  threads[p].createThread(producerFunc)

joinThreads(threads)
