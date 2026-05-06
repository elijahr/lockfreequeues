# Getting Started

Your first five minutes with `lockfreequeues`: install the library, build a
single-producer / single-consumer queue, push and pop a value, and learn the
two or three pitfalls that catch most newcomers.

If you are evaluating whether to use this library at all, jump first to
[Core Concepts](core-concepts.md) and
[Bounded vs Unbounded](bounded-vs-unbounded.md).

## Install

### Via nimble

The library is on the Nimble registry. The package and the import name match.

```sh
nimble install lockfreequeues
```

This pulls `lockfreequeues` plus its two runtime dependencies, `typestates`
and `debra`, and resolves a Nim `>= 2.2.0` requirement against your active
toolchain. Older Nim versions miss the atomic builtins the queues rely on
and will be rejected at compile time.

### Pinning a version

Production code should pin. The `requires` line in your own `.nimble` file
is the right place:

```text
# In yourproject.nimble
requires "lockfreequeues == 4.2.0"
```

Use `>= 4.2.0` only if you are willing to ride minor-version changes; the
public API is stable across patches but new minor versions sometimes
extend the surface (new constructors, new typestate hooks).

### Verifying the install

A six-line file is enough to confirm the install compiles, links, and runs:

```nim
# verify.nim
import options
import lockfreequeues

var q = initSipsic[16, int]()
discard q.push(42)
echo q.pop()  # prints "Some(42)"
```

Compile and run with threads on (the queues require `--threads:on` even when
you only touch them from one thread, because they reference threading
intrinsics):

```sh
nim c --threads:on -r verify.nim
```

If you see `Some(42)`, you are done — the library is installed and working.

## Your first SPSC queue

The smallest useful program: one producer, one consumer, one bounded queue.

### A 10-line "push and pop" example

`Sipsic` is the single-producer / single-consumer bounded ring buffer. One
thread pushes; one other thread pops; capacity `N` is a compile-time integer.
Both `push` and `pop` are wait-free, so a slow consumer never stalls the
producer beyond what the buffer's fullness implies.

```nim
import options
import os

import lockfreequeues

# Capacity 16, item type int. The queue is a global `var` so both threads
# can reach it; in production code prefer `ptr` or a shared object that
# you pass into thread procs explicitly.
var queue = initSipsic[16, int]()

proc producerFunc() {.thread.} =
  for i in 1 .. 8:
    # push returns false when the queue is full; here we just retry.
    while not queue.push(i):
      sleep(0)

proc consumerFunc() {.thread.} =
  var seen = 0
  while seen < 8:
    let item = queue.pop()
    if item.isSome:
      echo "got ", item.get
      inc seen
    else:
      sleep(0)

var threads: array[2, Thread[void]]
createThread(threads[0], producerFunc)
createThread(threads[1], consumerFunc)
joinThreads(threads)
```

The producer sends the integers 1 through 8; the consumer prints them in
order. Because `Sipsic` is FIFO, output is deterministic: `got 1` ...
`got 8`. Run it twice and you'll see the same lines.

### Running with `--threads:on`

The queues use Nim's `Atomic[T]` and `Thread[T]`, both of which require
threading enabled at compile time. The flag is mandatory, not optional:

```sh
nim c --threads:on -r myprog.nim
```

For production, layer on `-d:release` (strips runtime checks, enables
optimisation) or `-d:danger` (drops bounds checks too — fastest, least
forgiving):

```sh
nim c --threads:on -d:release -r myprog.nim
```

See [Performance Tuning → Compile-time settings](performance-tuning.md#compile-time-settings)
for when each flag is appropriate.

### What to expect on success

A successful run of the example above prints eight lines, in order, then
exits with status 0. There is no shutdown handshake to write — once both
threads have looped through their work, `joinThreads` returns and the
process exits cleanly. The queue's storage lives on the global var; Nim's
ARC/ORC reclaims it when the var goes out of scope.

If you see fewer than eight lines, or a deadlock, jump to
[Common pitfalls](#common-pitfalls) below.

## Common pitfalls

The three errors that account for the majority of "it doesn't compile" or
"it deadlocks immediately" reports.

### "Item type is not lock-free safe"

If your item type is a `ref T` and you compile under `--mm:arc` or `--mm:orc`,
you will see a static error from the queue's item-type guard. Reference
counting on `ref` types can fall back to spinlocks on some platforms,
defeating the lock-free guarantee at the item level.

```text
type Node = ref object
  value: int

# Compile error under arc/orc with default settings.
var q = newUnboundedSipsic[64, Node]()
```

The fix in 95% of cases is to use `ptr T` and manage the lifetime yourself,
or to redesign the item to be a plain `object` (passed by value) or an
integer index into a side-table. If you genuinely need `ref` and accept the
trade-off, the `-d:allowNonLockFreeQueueItems` flag opts out of the guard.

See [Memory Management → Item types and ARC / ORC](memory-management.md#item-types-and-arc-orc)
for the full story on item type requirements.

### Power-of-2 capacity vs arbitrary N

You may have read that other lock-free ring buffers require `N` to be a
power of two so that the head/tail wrap reduces to a bitmask. `lockfreequeues`
does not require this: any positive `N` compiles, and the wrap arithmetic
is done with modulo against the (possibly non-power-of-two) capacity.

```nim
import lockfreequeues

# Both compile and work fine.
var qa = initSipsic[1024, int]()  # power of 2
var qb = initSipsic[1000, int]()  # arbitrary
```

There is still a slight performance preference for powers of two on hot
paths, because the compiler can sometimes lower the modulo to a mask. For
benchmark-sensitive code, prefer powers of two; for everyday use, pick the
capacity that matches your domain (e.g. `BufferSize = 64` for a 1.45 ms
audio frame at 44.1 kHz).

See [Bounded vs Unbounded → Capacity selection](bounded-vs-unbounded.md#capacity-selection-bounded)
for the full rationale.

### Forgetting `--threads:on`

The most common "it won't compile" report. The queues import
`std/atomics` and reference `Thread[T]`; without `--threads:on` Nim
emits messages like `'Atomic' is not declared` or `'Thread' undeclared`.

The fix is one flag:

```sh
nim c --threads:on -r myprog.nim
```

If you build via Nimble tasks, put `--threads:on` in your `config.nims`
or in the task definition itself so contributors do not have to remember:

```text
# config.nims
switch("threads", "on")
```

## Next steps

### Multi-producer / multi-consumer variants

See [Core Concepts](core-concepts.md) for the SPSC / SPMC / MPSC / MPMC
quadrant and which queue type fits which pattern.

### Bounded vs Unbounded

See [Bounded vs Unbounded](bounded-vs-unbounded.md) for the decision guide.

### Performance tuning

See [Performance Tuning](performance-tuning.md) for capacity sizing,
thread placement, and compile-time settings.
