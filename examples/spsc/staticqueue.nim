# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage for a statically allocated queue.

import options
import os
import sequtils
import strformat

import lockfreequeues/sipsic/staticqueue


var
  queue = initSipsicQueue[16, int]() # A queue that can hold 16 ints.
  consumer: Thread[void]
  producer: Thread[void]


proc consumerFunc() {.thread.} =
  # Pop 1..8 from the queue
  for expected in 1..8:
    while true:
      let popped = queue.pop()
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
  let popped = queue.pop(8)
  let items = popped.get()
  echo fmt"[consumer] popped {items}"
  assert items == expected


proc producerFunc() {.thread.} =
  # Append 1..8 to the queue
  for item in 1..8:
    assert queue.push(item)
    echo fmt"[producer] pushed {item}"

  # Append 9..16 to the queue in a single call
  let items = toSeq(9..16)
  let unpushed = queue.push(items)
  echo fmt"[producer] pushed {items}"
  assert unpushed.isNone, fmt"[producer] could not push {unpushed.get()}"


consumer.createThread(consumerFunc)
producer.createThread(producerFunc)
joinThreads(consumer, producer)
