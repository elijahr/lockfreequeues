[![Build Status](https://travis-ci.org/elijahr/lockfreequeues.svg?branch=master)](https://travis-ci.org/elijahr/lockfreequeues)

# lockfreequeues

Single-producer, single-consumer, lock-free queue (aka ring buffer) implementations for Nim.

Two implementations are provided: [`StaticQueue`](https://elijahr.github.io/lockfreequeues/lockfreequeues/spsc/staticqueue.html) and [`SharedQueue`](https://elijahr.github.io/lockfreequeues/lockfreequeues/spsc/sharedqueue.html).

`StaticQueue` should be used when your queue's capacity is known at compile-time.

`SharedQueue` should be used when your queue's capacity is only known at run-time or when the queue should reside in shared memory.

API documentation: https://elijahr.github.io/lockfreequeues/

## Examples

Examples are located in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory and can be compiled and run with:

```sh
nim c -r examples/spsc/staticqueue.nim
nim c -r examples/spsc/sharedqueue.nim
```

### Example usage for a statically allocated queue
```nim

import options
import os
import sequtils
import strformat

import lockfreequeues/spsc/staticqueue


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

import lockfreequeues/spsc/sharedqueue


proc consumerFunc(q: pointer) {.thread.} =
  var queuePtr = cast[ptr SharedQueue[int]](q)

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
  var queuePtr = cast[ptr SharedQueue[int]](q)

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

## Reference

* Juho Snellman's post ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/) ([alt](https://web.archive.org/web/20200530040210/https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/))
* Mamy Ratsimbazafy's [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature) for weave.
* Henrique F Bucher's post ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370) ([alt](https://web.archive.org/web/20191225164231/http://www.vitorian.com/x1/archives/370))

Many thanks to Mamy Ratsimbazafy for reviewing this code and offering suggestions.

## Contributing

* Pull requests and feature requests are quite welcome!
* Please file any issues you encounter.
* For pull requests, please see the [contribution guidelines](https://github.com/elijahr/lockfreequeues/tree/master/CONTRIBUTING.md).

## Release notes

## v1.0.0 - 2020-07-6

* Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
* `head` and `tail` are now in the range `0 ..<2*capacity`
* `capacity` doesn’t have to be a power of two
* Use `align` pragma instead of padding array

## v0.1.0 - 2020-07-02

Initial release, containing `SharedQueue` and `StaticQueue`.
