[![Build Status](https://travis-ci.org/elijahr/lockfreequeues.svg?branch=master)](https://travis-ci.org/elijahr/lockfreequeues)

# lockfreequeues

Lock-free queues for Nim, implemented as ring buffers.

Four implementations are provided:

- [`Sipsic`](https://elijahr.github.io/lockfreequeues/lockfreequeues/sipsic.html) is a single-producer, single-consumer bounded queue. Pushing and popping are wait-free.
- [`Mupsic`](https://elijahr.github.io/lockfreequeues/lockfreequeues/mupsic.html) is a multi-producer, single-consumer bounded queue. Popping is wait-free. Compile with `--threads:on`.
- [`Mupmuc`](https://elijahr.github.io/lockfreequeues/lockfreequeues/mupmuc.html) is a multi-producer, multi-consumer bounded queue. Compile with `--threads:on`.

API documentation: https://elijahr.github.io/lockfreequeues/

## Examples

Examples are located in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory and can be compiled and run with:

```sh
nimble examples
```

### Single-producer, single-consumer

```nim
import atomics
import options
import random
import sequtils
import threadpool

import lockfreequeues

const
  itemCount = 30

var
  # Queue that can hold 8 ints
  queue = initSipsic[8, int]()


proc consumerFunc(): seq[int] {.gcsafe.} =
  result = @[]
  while result.len < itemCount:

    # Pop many items from the queue
    let items = queue.pop(itemCount)
    if items.isSome:
      result.insert(items.get, result.len)

    # Pop a single item from the queue
    let item = queue.pop()
    if item.isSome:
      result.add(item.get)
    cpuRelax()


proc producerFunc() {.gcsafe.} =
  for i in 0..<itemCount:
    let item = rand(100)

    if i mod 2 == 0:
      # Push a single item to the queue
      while not queue.push(item):
        cpuRelax()

    else:
      # Push a sequence to the queue
      while queue.push(@[item]).isSome:
        cpuRelax()

    echo "Pushed item: ", item


let consumedFlow = spawn consumerFunc()
spawn producerFunc()
sync()
echo "Popped items: ", ^consumedFlow
```

### Multi-producer, single-consumer

```nim
import atomics
import options
import random
import sequtils
import threadpool

import lockfreequeues

var
  # Queue that can hold 8 ints, with MaxThreadPoolSize maximum producer threads
  queue = initMupsic[8, MaxThreadPoolSize, int]()


proc consumerFunc(): seq[int] {.gcsafe.} =
  result = @[]
  while result.len < MaxThreadPoolSize:

    # Pop many items from the queue
    let items = queue.pop(queue.producerCount)
    if items.isSome:
      result.insert(items.get, result.len)

    # Pop a single item from the queue
    let item = queue.pop()
    if item.isSome:
      result.add(item.get)
    cpuRelax()


proc producerFunc() {.gcsafe.} =
  # Get a unique producer for this thread
  var producer = queue.getProducer()

  let item = rand(100)
  if producer.idx mod 2 == 0:
    # Half the time, push a single item to the queue
    while not producer.push(item):
      cpuRelax()
  else:
    # Half the time, push a sequence to the queue
    while producer.push(@[item]).isSome:
      cpuRelax()

  echo "Pushed item: ", item


let consumedFlow = spawn consumerFunc()

for producer in 0..<MaxThreadPoolSize:
  spawn producerFunc()

sync()

# ^ waits for consumer flow var to return
echo "Popped items: ", repr(^consumedFlow)
```

### Multi-producer, multi-consumer

```nim
import atomics
import options
import random
import sequtils
import threadpool

import lockfreequeues

var
  # Queue that can hold 8 ints, with MaxThreadPoolSize producer/consumer threads
  queue = initMupmuc[8, MaxThreadPoolSize, MaxThreadPoolSize, int]()


proc consumerFunc() {.gcsafe.} =
  # Get a unique consumer for this thread
  var consumer = queue.getConsumer()

  while true:
    # Pop a single item from the queue
    let item = consumer.pop()
    if item.isSome:
      echo "Popped item: ", item.get
      break
    echo "queue empty..."
    cpuRelax()


proc producerFunc() {.gcsafe.} =
  # Get a unique producer for this thread
  var producer = queue.getProducer()

  let item = rand(100)
  while not producer.push(item):
    echo "queue full..."
    cpuRelax()

  echo "Pushed item: ", item

for i in 0..<MaxThreadPoolSize:
  spawn producerFunc()
  spawn consumerFunc()

sync()
```

## Reference

* Juho Snellman's post ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/) ([alt](https://web.archive.org/web/20200530040210/https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/))
* Mamy Ratsimbazafy's [research on Sipsic channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_sipsic.md#litterature) for weave.
* Henrique F Bucher's post ["Yes, You Have Been Writing Sipsic Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370) ([alt](https://web.archive.org/web/20191225164231/http://www.vitorian.com/x1/archives/370))

Many thanks to Mamy Ratsimbazafy for reviewing the initial release and offering suggestions.

## Contributing

* Pull requests and feature requests are quite welcome!
* Please file any issues you encounter.
* For pull requests, please see the [contribution guidelines](https://github.com/elijahr/lockfreequeues/tree/master/CONTRIBUTING.md).

## Running tests

[Travis](https://travis-ci.org/elijahr/lockfreequeues) runs the test suite for both C and C++ targets on Linux and macOS. Tests can be run locally with `nimble test`.

## Changelog

## v2.0.0 - 2020-08-07

* Implement multi-producer, single-consumer queue (Mupsic).
* Implement multi-producer, multi-consumer queue (Mupmuc).
* Refactor, remove shared memory queues.

## v1.0.0 - 2020-07-6

* Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
* `head` and `tail` are now in the range `0 ..<2*capacity`
* `capacity` doesn’t have to be a power of two
* Use `align` pragma instead of padding array

## v0.1.0 - 2020-07-02

Initial release, containing `SipsicSharedQueue` and `SipsicStaticQueue`.
