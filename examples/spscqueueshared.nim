# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage for a dynamically-allocated shared-memory queue.

import options
import os
import sequtils
import strformat

import lockfreequeues/spscqueueshared


proc consumerFunc(q: pointer) {.thread.} =
  var queuePtr = cast[ptr SPSCQueueShared[int]](q)

  # Pop 1..8 from the queue
  for expected in 1..8:
    while true:
      let popped = queuePtr[].pop()
      if popped.isSome:
        let item = popped.get()
        echo fmt"[consumer] popped {item}"
        assert item == expected
        break
      else:
        echo "[consumer] queue empty, waiting for producer..."
        sleep(1)

  # Wait for producer to complete
  sleep(10)

  # Pop 9..16 from the queue in a single call
  let expected = toSeq(9..16)
  let popped = queuePtr[].pop(8)
  let items = popped.get()
  echo fmt"[consumer] popped {items}"
  assert items == expected


proc producerFunc(q: pointer) {.thread.} =
  var queuePtr = cast[ptr SPSCQueueShared[int]](q)

  # Append 1..8 to the queue
  for item in 1..8:
    assert queuePtr[].push(item)
    echo fmt"[producer] pushed {item}"

  # Append 9..16 to the queue in a single call
  let items = toSeq(9..16)
  let unpushed = queuePtr[].push(items)
  echo fmt"[producer] pushed {items}"
  assert unpushed.isNone, fmt"[producer] could not push {unpushed.get()}"


proc main =
  var
    queue = newSPSCQueue[int](16) # A queue that can hold 16 ints.
    consumer: Thread[pointer]
    producer: Thread[pointer]
  consumer.createThread(consumerFunc, addr(queue))
  producer.createThread(producerFunc, addr(queue))
  joinThreads(consumer, producer)


if isMainModule:
  main()
