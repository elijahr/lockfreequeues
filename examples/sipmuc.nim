## Example: Single-producer, multi-consumer (SPMC) queue
##
## This demonstrates a fan-out pattern where one producer
## distributes work to multiple consumers.

import lockfreequeues/atomic_dsl
import os
import options

import lockfreequeues


const
  NumItems = 100
  NumConsumers = 4


var
  queue = initSipmuc[64, NumConsumers, int]()
  done: Atomic[bool]
  processed: array[NumConsumers, Atomic[int]]


proc consumerThread(idx: int) {.thread.} =
  let consumer = queue.getConsumer(idx)
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
    while not queue.push(i):
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
