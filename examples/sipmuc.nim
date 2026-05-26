## Example: Single-producer, multi-consumer (SPMC) bounded queue using
## the unified `BQueue` generic.
##
## This demonstrates a fan-out pattern where one producer distributes
## work to multiple consumers.
##
## v5.0.0 cascade migration: the legacy `Sipmuc[N, C, T]` family was
## collapsed into `BQueue[T, ccSingle, ccMulti, N, 0, C]` (the bounded
## 6-param shape — capacity `N`, single producer arm, `C` consumer
## views). Consumers are obtained via `q.getConsumer(idx)` with an
## explicit consumer index per thread. See
## `docs/v5.0.0-migration/3.3.11-B-final-shape.md` for the canonical
## surface reference.

import lockfreequeues/atomic_dsl
import os
import options

import lockfreequeues


const
  NumItems = 100
  NumConsumers = 4


var
  q = newSipmucQueue[int, 64, NumConsumers]()
  done: Atomic[bool]
  processed: array[NumConsumers, Atomic[int]]


proc consumerThread(idx: int) {.thread.} =
  let consumer = q.getConsumer(idx)
  var count = 0

  while not done.load(moAcquire):
    let item = consumer.pop()
    if item.isSome:
      # Process item...
      inc count
    else:
      sleep(1)

  # Drain remaining items
  while true:
    let item = consumer.pop()
    if item.isSome:
      inc count
    else:
      break

  processed[idx].store(count, moRelease)
  echo "Consumer ", idx, " processed ", count, " items"


when isMainModule:
  var threads: array[NumConsumers, Thread[int]]
  done.store(false, moRelaxed)

  # Start consumers
  for i in 0..<NumConsumers:
    processed[i].store(0, moRelaxed)
    createThread(threads[i], consumerThread, i)

  # Producer pushes items
  for i in 1..NumItems:
    while not q.push(i):
      sleep(1)

  done.store(true, moRelease)
  sleep(100)  # Let consumers finish draining

  for i in 0..<NumConsumers:
    joinThread(threads[i])

  var total = 0
  for i in 0..<NumConsumers:
    total += processed[i].load(moAcquire)

  echo "Total processed: ", total, " (expected ", NumItems, ")"
  assert total == NumItems
  echo "Done!"
