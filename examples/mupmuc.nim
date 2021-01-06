# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage of Mupmuc, a multi-producer, multi-consumer bounded queue.

import options
import random

import lockfreequeues

var
  # Queue that can hold 8 ints at a time,
  # with 32 producer & 32 consumer workers
  queue = initMupmuc[8, 32, 32, int]()


proc consumerFunc() {.thread.} =
  # Get a unique consumer for this thread
  var consumer = queue.getConsumer()

  # Try to pop a single item from the queue; pop() returns Option[int]
  let item = consumer.pop()

  echo "[consumer ", consumer.idx, "] popped item: ", item

  # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
  let items = consumer.pop(4)

  echo "[consumer ", consumer.idx, "] popped items: ", items


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


var threads: array[64, Thread[void]]

for p in 0..<32:
  threads[p].createThread(producerFunc)

for c in 32..<64:
  threads[c].createThread(consumerFunc)

joinThreads(threads)

