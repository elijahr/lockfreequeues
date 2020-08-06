[![Build Status](https://travis-ci.org/elijahr/lockfreequeues.svg?branch=master)](https://travis-ci.org/elijahr/lockfreequeues)

# lockfreequeues

Lock-free queue (aka ring buffer) implementations for Nim.

Four implementations are provided:

- [`Sipsic`](https://elijahr.github.io/lockfreequeues/lockfreequeues/sipsic.html) is a single-producer, single-consumer bounded queue.
- [`Mupsic`](https://elijahr.github.io/lockfreequeues/lockfreequeues/mupsic.html) is a multi-producer, single-consumer bounded queue.

API documentation: https://elijahr.github.io/lockfreequeues/

## Examples

Examples are located in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory and can be compiled and run with:

```sh
nim c -r examples/sipsic.nim
nim c -r examples/mupsic.nim
```

### Sipsic
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

### Mupsic

```nim
import atomics
import options
import random
import sequtils
import threadpool

import lockfreequeues

const
  producerCount = 30

var
  # Queue that can hold 8 ints, with 30 producerTails
  queue = initMupsic[8, producerCount, int]()


proc consumerFunc(): seq[int] {.gcsafe.} =
  result = @[]
  while result.len < producerCount:

    # Pop many items from the queue
    let items = queue.pop(producerCount)
    if items.isSome:
      result.insert(items.get, result.len)

    # Pop a single item from the queue
    let item = queue.pop()
    if item.isSome:
      result.add(item.get)
    cpuRelax()


proc producerFunc(producer: int) {.gcsafe.} =
  let item = rand(100)

  if producer mod 2 == 0:
    # Push a single item to the queue
    while not queue.push(producer, item):
      cpuRelax()

  else:
    # Push a sequence to the queue
    while queue.push(producer, @[item]).isSome:
      cpuRelax()

  echo "Pushed item: ", item


let consumedFlow = spawn consumerFunc()

for producer in 0..<producerCount:
  spawn producerFunc(producer)

sync()

echo "Popped items: ", ^consumedFlow
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

## Changelog

## v2.0.0 - 2020-07-31

* Implement multi-producer, single-consumer queue.
* Refactor, remove shared memory queues.

## v1.0.0 - 2020-07-6

* Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
* `head` and `tail` are now in the range `0 ..<2*capacity`
* `capacity` doesn’t have to be a power of two
* Use `align` pragma instead of padding array

## v0.1.0 - 2020-07-02

Initial release, containing `SipsicSharedQueue` and `SipsicStaticQueue`.
