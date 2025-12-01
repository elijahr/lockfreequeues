[![build](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml/badge.svg)](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml)

# lockfreequeues

Lock-free queues for Nim, implemented as ring buffers (bounded) and linked segments (unbounded).

**Bounded queues** (fixed capacity):

- `Sipsic` - Single-producer, single-consumer (SPSC). Wait-free operations.
- `Sipmuc` - Single-producer, multi-consumer (SPMC). Wait-free push, lock-free pop.
- `Mupsic` - Multi-producer, single-consumer (MPSC). Lock-free push, wait-free pop.
- `Mupmuc` - Multi-producer, multi-consumer (MPMC). Lock-free operations.

**Unbounded queues** (dynamic capacity with epoch-based memory reclamation):

- `UnboundedSipsic` - Single-producer, single-consumer (SPSC). Wait-free operations.
- `UnboundedSipmuc` - Single-producer, multi-consumer (SPMC). Wait-free push, lock-free pop.
- `UnboundedMupsic` - Multi-producer, single-consumer (MPSC). Lock-free push, wait-free pop.
- `UnboundedMupmuc` - Multi-producer, multi-consumer (MPMC). Lock-free operations.

API documentation: https://elijahr.github.io/lockfreequeues

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

- Juho Snellman's post ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/) ([alt](https://web.archive.org/web/20200530040210/https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/))
- Mamy Ratsimbazafy's [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature) for weave.
- Henrique F Bucher's post ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370) ([alt](https://web.archive.org/web/20191225164231/http://www.vitorian.com/x1/archives/370))

Many thanks to Mamy Ratsimbazafy for reviewing the initial release and offering suggestions.

## Contributing

- Pull requests and feature requests are welcome!
- Please file any issues you encounter.
- For pull requests, please see the [contribution guidelines](https://github.com/elijahr/lockfreequeues/tree/master/CONTRIBUTING.md).

## Running tests

Tests can be run locally with `nimble test`.

CI runs the test suite for both C and C++ targets on:
- Linux `x86_64` and `aarch64`
- macOS `x86_64`

The test suite is also run with [LLVM thread sanitization](https://clang.llvm.org/docs/ThreadSanitizer.html) to check for data races.
