# EpochManager

Epoch-based memory reclamation for lock-free data structures.

## Overview

`EpochManager` provides safe memory deallocation for lock-free data structures. Threads announce when accessing shared memory by "pinning" an epoch. Memory can only be freed when no thread is pinned to the epoch when it was retired.

## Usage

```nim
import lockfreequeues

let manager = newEpochManager()

# Register thread (once per thread)
let threadIdx = manager.registerThread()

# Pin before accessing shared data
let guard = manager.pin(threadIdx)
# ... access shared memory ...
# guard destroyed, unpins automatically

# Retire memory for later reclamation
manager.retire(segmentPtr)

# Periodically reclaim safe memory
discard manager.tryReclaim()
```

## How It Works

1. **Global epoch** increments over time via `advance()`
2. **Threads pin** to current epoch before accessing shared data
3. **Memory retires** at the current epoch when no longer needed
4. **Reclamation** frees memory when all threads have advanced past the retirement epoch

## Thread Safety

- `registerThread()`: Lock-free, call once per thread
- `pin()`: Lock-free, creates RAII guard
- `retire()`: Spinlock-protected
- `tryReclaim()`: Spinlock-protected
- `advance()`: Lock-free

## Limits

- Maximum threads: 128 (configurable via `MaxThreads`)

## API

::: lockfreequeues/epoch
