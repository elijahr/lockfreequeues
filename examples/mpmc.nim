## Example: Multi-producer, multi-consumer (MPMC) bounded queue using
## the unified `BQueue` generic.
##
## v5.0.0 cascade migration: the legacy `Mpmc[N, P, C, T]` family was
## collapsed into `BQueue[T, ccMulti, ccMulti, N, P, C]` (the bounded
## 6-param shape — capacity `N`, `P` producer views, `C` consumer
## views). Producers and consumers are obtained via `q.getProducer()`
## / `q.getConsumer()` (one per thread). This example uses the
## `getProducerHere()` / `getConsumerHere()` sugar — each worker
## thread is also the operating thread, so the view's `attach()`
## lands on the right thread automatically.

import options
import random

import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags

var
  # Queue that can hold 8 ints at a time,
  # with 32 producer & 32 consumer workers
  q = newMpmcQueue[int, 8, 32, 32]()


proc consumerFunc() {.thread.} =
  # Get a unique consumer for this thread
  var consumer = q.getConsumerHere()

  # Try to pop a single item from the queue; pop() returns Option[int]
  let item = consumer.pop()

  echo "[consumer ", consumer.idx, "] popped item: ", item

  # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
  let items = consumer.pop(4)

  echo "[consumer ", consumer.idx, "] popped items: ", items


proc producerFunc() {.thread.} =
  # Get a unique producer for this thread
  var producer = q.getProducerHere()

  let item = rand(100)

  # Try to push a single item; push will return false when queue is full
  echo "[producer ", producer.idx, "] pushed item: ", item, "? ", producer.push(item)

  let items = @[
    rand(100),
    rand(100),
    rand(100),
    rand(100),
  ]

  # v5.0.0: batch push returns Option[HSlice[int, int]] — none if all
  # items pushed, some(slice) for unpushed indices.
  let remainder = producer.push(items)
  if remainder.isSome:
    echo "[producer ", producer.idx, "] pushed items ",
      items[0 ..< remainder.get.a], "; unpushed: ", items[remainder.get]
  else:
    echo "[producer ", producer.idx, "] pushed all items: ", items


var threads: array[64, Thread[void]]

for p in 0..<32:
  threads[p].createThread(producerFunc)

for c in 32..<64:
  threads[c].createThread(consumerFunc)

joinThreads(threads)
