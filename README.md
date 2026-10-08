# lockfreequeues (Compatibility Facade)

> ⚠️ **Package Consolidated into [`lockfree`](https://github.com/elijahr/lockfree)**  
> As of version 0.1.0, `lockfreequeues` and `nim-debra` have been unified into a single high-performance library: **[`lockfree`](https://github.com/elijahr/lockfree)**.  
> This package is maintained as a **zero-overhead backwards-compatibility facade**. New projects should depend directly on `lockfree`.

[![Docs](https://img.shields.io/badge/docs-lockfree-blue.svg)](https://elijahr.github.io/lockfree)
[![Migration Guide](https://img.shields.io/badge/guide-migration-orange.svg)](https://elijahr.github.io/lockfree/migration/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## What is this package?

`lockfreequeues` continues to exist on Nimble so that existing projects do not break. Under the hood, version `5.1.0+` forwards all calls directly to the unified `lockfree` engine:

```nim
# Existing code continues to compile with zero changes:
import lockfreequeues

var q = newSipsicQueue[int, 16]()
discard q.push(42)
assert q.pop().get == 42
```

## Legacy API Mapping

All historical types, constructors, and endpoints are 100% supported:

| Legacy Type | Parameters | Modern `lockfree` Equivalent |
| :--- | :--- | :--- |
| `Sipsic[N, T]` | Capacity `N`, Type `T` | `BQueue[T, ccSingle, ccSingle, N, 0, 0]` (`newSpscQueue`) |
| `Mupsic[N, P, T]` | Capacity `N`, Producers `P`, Type `T` | `BQueue[T, ccMulti, ccSingle, N, P, 0]` (`newMpscQueue`) |
| `Sipmuc[N, C, T]` | Capacity `N`, Consumers `C`, Type `T` | `BQueue[T, ccSingle, ccMulti, N, 0, C]` (`newSpmcQueue`) |
| `Mupmuc[N, P, C, T]` | Capacity `N`, Producers `P`, Consumers `C`, Type `T` | `BQueue[T, ccMulti, ccMulti, N, P, C]` (`newMpmcQueue`) |
| `UnboundedSipsic[T, ST, S]` | Type `T`, Strategy `ST`, Segment `S` | `Queue[T, ccSingle, ccSingle, ST, S, 1]` |
| `UnboundedMupsic[T, ST, S, M]`| Type `T`, Strategy `ST`, Segment `S`, MaxThreads `M` | `Queue[T, ccMulti, ccSingle, ST, S, M]` |
| `UnboundedSipmuc[T, ST, S, M]`| Type `T`, Strategy `ST`, Segment `S`, MaxThreads `M` | `Queue[T, ccSingle, ccMulti, ST, S, M]` |
| `UnboundedMupmuc[T, ST, S, M]`| Type `T`, Strategy `ST`, Segment `S`, MaxThreads `M` | `Queue[T, ccMulti, ccMulti, ST, S, M]` |

## Upgrading to `lockfree`

To take advantage of modern features (CSP `Channel[T]` facade, cross-language C ABI, Apple Silicon cacheline tuning, and batch pop primitives), migrate your dependency in `.nimble`:

```nim
# In your .nimble file:
requires "lockfree >= 0.1.0"
```

```nim
# In your code:
import lockfree
import lockfree/channel

var chan = newBoundedChannel[int](64)
assert chan.send(42)
```

Read the full [Migration Guide](https://elijahr.github.io/lockfree/migration/) and [Documentation](https://elijahr.github.io/lockfree).
