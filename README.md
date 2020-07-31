[![Build Status](https://travis-ci.org/elijahr/lockfreequeues.svg?branch=master)](https://travis-ci.org/elijahr/lockfreequeues)

# lockfreequeues

Lock-free queue (aka ring buffer) implementations for Nim.

Four implementations are provided:

- [`SipsicStaticQueue`](https://elijahr.github.io/lockfreequeues/lockfreequeues/sipsic_static_queue.html) is a single-producer, single-consumer queue for when your queue's capacity is known at compile-time.
- [`SipsicSharedQueue`](https://elijahr.github.io/lockfreequeues/lockfreequeues/sipsic_shared_queue.html) is a single-producer, single-consumer queue for when your queue's capacity is only known at run-time, or when the queue should reside in shared memory.
- [`MupsicStaticQueue`](https://elijahr.github.io/lockfreequeues/lockfreequeues/mupsic_static_queue.html) is a multi-producer, single-consumer queue for when your queue's capacity and number of producers are known at compile-time.
- [`MupsicSharedQueue`](https://elijahr.github.io/lockfreequeues/lockfreequeues/mupsic_shared_queue.html) is a multi-producer, single-consumer queue for when your queue's capacity or number of producers are only known at run-time, or when the queue should reside in shared memory.

API documentation: https://elijahr.github.io/lockfreequeues/

## Examples

Examples are located in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory and can be compiled and run with:

```sh
nim c -r examples/sipsic_static_queue.nim
nim c -r examples/sipsic_shared_queue.nim
nim c -r examples/mupsic_static_queue.nim
nim c -r examples/mupsic_shared_queue.nim
```

### SipsicStaticQueue
```nim
TODO
```

### SipsicSharedQueue

```nim
TODO
```

### MupsicStaticQueue
```nim
TODO
```

### MupsicSharedQueue

```nim
TODO
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

## Release notes

## v2.0.0 - 2020-07-29

* Refactor, rename SPSC to Sipsic; it's much easier for my eyes and brain.
* Implement multi-producer, single-consumer (Mupsic) queues.

## v1.0.0 - 2020-07-6

* Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
* `head` and `tail` are now in the range `0 ..<2*capacity`
* `capacity` doesn’t have to be a power of two
* Use `align` pragma instead of padding array

## v0.1.0 - 2020-07-02

Initial release, containing `SipsicSharedQueue` and `SipsicStaticQueue`.
