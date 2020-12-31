[![Build Status](https://travis-ci.org/elijahr/lockfreequeues.svg?branch=master)](https://travis-ci.org/elijahr/lockfreequeues)

# lockfreequeues

Lock-free queues for Nim, implemented as ring buffers.

Three implementations are provided:

- [`Sipsic`](https://elijahr.github.io/lockfreequeues/lockfreequeues/sipsic.html) is a single-producer, single-consumer bounded queue. Pushing and popping are wait-free.
- [`Mupsic`](https://elijahr.github.io/lockfreequeues/lockfreequeues/mupsic.html) is a multi-producer, single-consumer bounded queue. Popping is wait-free.
- [`Mupmuc`](https://elijahr.github.io/lockfreequeues/lockfreequeues/mupmuc.html) is a multi-producer, multi-consumer bounded queue.

API documentation: https://elijahr.github.io/lockfreequeues

Note: if your project is compiled with `--threads:off`, only `Sipsic` is available.

## Installation

```sh
nimble install lockfreequeues
```

## Examples

Examples are located in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory and can be compiled and run with:

```sh
nimble examples
```

## Reference

* Juho Snellman's post ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/) ([alt](https://web.archive.org/web/20200530040210/https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/))
* Mamy Ratsimbazafy's [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature) for weave.
* Henrique F Bucher's post ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370) ([alt](https://web.archive.org/web/20191225164231/http://www.vitorian.com/x1/archives/370))

Many thanks to Mamy Ratsimbazafy for reviewing the initial release and offering suggestions.

## Contributing

* Pull requests and feature requests are quite welcome!
* Please file any issues you encounter.
* For pull requests, please see the [contribution guidelines](https://github.com/elijahr/lockfreequeues/tree/master/CONTRIBUTING.md).

## Running tests

Tests can be run locally with `nimble test`.

CI runs the test suite for both C and C++ targets on Linux (`x86_64`, `armv7`, `aarch64`, `ppc64le`) and macOS (`x86_64`).

Nightly builds look for and test against the latest release of Nim.

## Changelog

### v2.0.5 - 2021-01-06

* Moved from Travis CI to GitHub Actions.

### v2.0.4 - 2020-08-10

* Implement multi-producer, single-consumer queue (Mupsic)
* Implement multi-producer, multi-consumer queue (Mupmuc)
* Refactor, remove shared memory queues
* Fix wrap-around bug, improve test coverage
* Nicer examples

### v1.0.0 - 2020-07-06

* Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
* `head` and `tail` are now in the range `0 ..<2*capacity`
* `capacity` doesn’t have to be a power of two
* Use `align` pragma instead of padding array

### v0.1.0 - 2020-07-02

Initial release, containing `SipsicSharedQueue` and `SipsicStaticQueue`
