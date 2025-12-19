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

## Thread Safety and Lock-Free Guarantees

### Item Type Requirements

By default, lockfreequeues requires that queue item types are lock-free:

```nim
import lockfreequeues

# These work - lock-free types
var queue1 = newUnboundedSipsic[64, int]()
var queue2 = newUnboundedSipsic[64, uint64]()
var queue3 = newUnboundedSipsic[64, pointer]()

type NodeObj = object
  value: int
var queue4 = newUnboundedSipsic[64, ptr NodeObj]()

# This fails on arc/orc - ref uses spinlocks for refcounting
type Node = ref object
  value: int
var queue5 = newUnboundedSipsic[64, Node]()  # Compile error!
```

### Why This Matters

On arc/orc memory managers, `ref` types use reference counting. While the queue's CAS operations correctly serialize slot access, reference counting operations on ref types may use spinlock-based atomics on some platforms, potentially introducing subtle issues.

### Allowing Non-Lock-Free Types

If you understand the trade-offs and need to use non-lock-free types:

```bash
nim c -d:allowNonLockFreeQueueItems your_program.nim
```

### Recommended Patterns

For maximum safety and portability:

- **Value types**: Use int, uint64, float, enums, simple objects
- **Pointers**: Use `ptr T` when you need indirection (you manage lifetime)
- **Avoid ref types**: On arc/orc, prefer `ptr T` with manual memory management
- **Test on target platform**: Always verify lock-free status on your deployment target

### Testing Lock-Free Behavior

Include tests with multiple memory managers:

```bash
nim c -r --mm:refc tests/mytest.nim
nim c -r --mm:arc tests/mytest.nim
nim c -r --mm:orc tests/mytest.nim
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
