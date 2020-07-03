[![Build Status](https://travis-ci.org/elijahr/lockfreequeues.svg?branch=master)](https://travis-ci.org/elijahr/lockfreequeues)

# lockfreequeues

Single-producer, single-consumer, lock-free queue (aka ring buffer) implementations for Nim.

Two implementations are provided: [`SPSCQueueStatic`](https://elijahr.github.io/lockfreequeues/lockfreequeues/spscqueuestatic.html) and [`SPSCQueueShared`](https://elijahr.github.io/lockfreequeues/lockfreequeues/spscqueueshared.html).

`SPSCQueueStatic` should be used when your queue's maximum capacity is known at compile-time.

`SPSCQueueShared` should be used when your queue's maximum capacity is only known at run-time or when the queue should reside in shared memory.

API documentation: https://elijahr.github.io/lockfreequeues/

## Examples

Examples are located in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory and can be compiled and run with:

```sh
nim c examples/spscqueuestatic.nim; ./examples/spscqueuestatic
nim c examples/spscqueueshared.nim; ./examples/spscqueueshared
```

### Example usage for a statically allocated queue
```nim

import options
import os
import sequtils
import strformat

import lockfreequeues/spscqueuestatic

var
  queue = newSPSCQueue[16, int]() # A queue that can hold 16 ints.
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
```

### Example usage for a dynamically-allocated shared-memory queue

```nim

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

```
