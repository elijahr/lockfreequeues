# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Epoch-based memory reclamation for lock-free data structures.
##
## Threads announce when they're accessing shared memory by "pinning" an epoch.
## Memory can only be freed when no thread is pinned to the epoch when it was
## retired.
##
## Usage:
##
## ```nim
## let manager = newEpochManager()
##
## # Register thread (once per thread)
## let threadIdx = manager.registerThread()
##
## # Pin before accessing shared data
## let guard = manager.pin(threadIdx)
## # ... access shared memory ...
## # guard destroyed, unpins automatically
##
## # Retire memory for later reclamation
## manager.retire(segmentPtr)
##
## # Periodically reclaim safe memory
## discard manager.tryReclaim()
## ```

import atomics

# Use C stdlib for thread-safe cross-thread allocation
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

const
  MaxThreads* = 128  ## Maximum supported threads for epoch manager

type
  RetiredSegment = tuple[epoch: uint64, segment: pointer]

  EpochManager* = ref object
    ## Manages epoch-based memory reclamation.
    ##
    ## Thread-safe for concurrent registration and pinning.
    globalEpoch*: Atomic[uint64]
      ## Current global epoch, monotonically increasing.
    threadStates*: array[MaxThreads, Atomic[uint64]]
      ## Per-thread pinned epoch. 0 = unpinned. Fixed size to avoid reallocation races.
    threadCount*: Atomic[int]
      ## Number of registered threads.
    retireQueue: seq[RetiredSegment]
      ## Queue of segments awaiting reclamation.
    retireLock: Atomic[bool]
      ## Spinlock for retire queue access.

  EpochGuard* = object
    ## RAII guard that unpins thread on destruction.
    ##
    ## Created by `EpochManager.pin()`, automatically unpins when destroyed.
    manager: EpochManager
    threadIdx: int
    active: bool


proc newEpochManager*(): EpochManager =
  ## Create a new EpochManager.
  ##
  ## Returns a new EpochManager instance with epoch starting at 1.
  result = EpochManager()
  result.globalEpoch.store(1, moRelease)
  result.threadCount.store(0, moRelaxed)
  for i in 0..<MaxThreads:
    result.threadStates[i].store(0, moRelaxed)
  result.retireQueue = @[]
  result.retireLock.store(false, moRelease)


proc registerThread*(self: EpochManager): int =
  ## Register a new thread with the epoch manager.
  ##
  ## Returns the thread's unique index for use with `pin()`.
  ##
  ## Thread-safe. Each thread should register once and reuse its index.
  ## Raises assertion if MaxThreads exceeded.
  result = self.threadCount.fetchAdd(1, moAcquire)
  assert result < MaxThreads, "Too many threads registered with EpochManager (max " & $MaxThreads & ")"
  # Slot is already initialized to 0 (unpinned) from newEpochManager


proc pin*(self: EpochManager, threadIdx: int): EpochGuard =
  ## Pin the current thread to the current epoch.
  ##
  ## Thread index from `registerThread()` is required.
  ## Returns an EpochGuard that unpins on destruction.
  ##
  ## While pinned, memory retired at the current epoch cannot be reclaimed.
  let epoch = self.globalEpoch.load(moAcquire)
  self.threadStates[threadIdx].store(epoch, moRelease)

  result.manager = self
  result.threadIdx = threadIdx
  result.active = true


proc `=destroy`*(guard: EpochGuard) =
  ## Destructor - unpins the thread automatically.
  if guard.active and guard.manager != nil:
    guard.manager.threadStates[guard.threadIdx].store(0, moRelease)


proc `=copy`*(dest: var EpochGuard, src: EpochGuard) {.error: "EpochGuard cannot be copied".}
  ## EpochGuard is move-only to ensure proper RAII semantics.


proc `=dup`*(src: EpochGuard): EpochGuard {.error: "EpochGuard cannot be duplicated".}
  ## EpochGuard is move-only.


proc advance*(self: EpochManager) =
  ## Advance the global epoch.
  ##
  ## Should be called periodically to allow reclamation progress.
  discard self.globalEpoch.fetchAdd(1, moRelease)


proc retire*(self: EpochManager, segment: pointer) =
  ## Mark a segment for future reclamation.
  ##
  ## Pointer to memory to be freed when safe.
  ##
  ## The segment will be freed when `tryReclaim()` determines it's safe.
  let epoch = self.globalEpoch.load(moAcquire)

  # Spinlock for queue access
  while self.retireLock.exchange(true, moAcquire):
    discard

  self.retireQueue.add((epoch: epoch, segment: segment))

  self.retireLock.store(false, moRelease)


proc retireQueueLen*(self: EpochManager): int =
  ## Returns the number of segments awaiting reclamation.
  ##
  ## Useful for testing and monitoring.
  result = self.retireQueue.len


proc safeToReclaim*(self: EpochManager, epoch: uint64): bool =
  ## Check if segments retired at given epoch can be safely reclaimed.
  ##
  ## Returns true if no threads are pinned to epochs <= given epoch.
  let count = self.threadCount.load(moAcquire)
  for i in 0..<count:
    let threadEpoch = self.threadStates[i].load(moAcquire)
    if threadEpoch != 0 and threadEpoch <= epoch:
      return false
  return true


proc tryReclaim*(self: EpochManager): int =
  ## Attempt to reclaim retired segments that are safe to free.
  ##
  ## Returns the number of segments reclaimed.
  ##
  ## Call this periodically to free memory. Only segments where all threads
  ## have advanced past the retirement epoch will be freed.

  # Spinlock for queue access
  while self.retireLock.exchange(true, moAcquire):
    discard

  var remaining: seq[RetiredSegment] = @[]
  result = 0

  for item in self.retireQueue:
    if self.safeToReclaim(item.epoch):
      c_free(item.segment)
      inc result
    else:
      remaining.add(item)

  self.retireQueue = remaining

  self.retireLock.store(false, moRelease)
