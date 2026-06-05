## Compile-time-gated unit tests for the comparison-MVP bench adapters.
##
## Each adapter is wrapped in a ``when defined(adapter_<lib>_available):``
## block so the same test file:
## - vacuously passes when no FFI gates are set (CI default for the
##   in-tree-only test suite).
## - exercises each adapter's push/pop round-trip when its ``-d`` gate is set.
##
## Pattern: push 1000 sequential ``uint64`` values at the smallest topology
## the adapter supports; pop until the queue is empty; assert count + set
## equality.

import std/sets
import unittest2

const SampleCount = 1000

template runRoundTrip[A](makeAdapterExpr: untyped, cleanupExpr: untyped): untyped =
  ## Run a SampleCount-item ``uint64`` push-then-pop round-trip on ``adapter``.
  ## Asserts count match and set equality with the input range.
  block:
    var adapter {.inject.}: A = makeAdapterExpr
    defer:
      cleanupExpr
    var pushed: HashSet[uint64]
    var popped: HashSet[uint64]
    for i in 0'u64 ..< SampleCount.uint64:
      let r = adapter.push(i)
      check r == prSuccess
      pushed.incl(i)
    var got = 0
    while got < SampleCount:
      let r = adapter.pop()
      if not r.success:
        break
      popped.incl(r.value)
      inc got
    check got == SampleCount
    check pushed == popped

when defined(adapter_loony_available):
  import ../benchmarks/nim/adapters/loony_adapter
  import ../benchmarks/nim/adapter

  suite "loony_adapter":
    test "push/pop 1000 uint64 round-trip preserves set":
      runRoundTrip[LoonyAdapter[uint64]](makeLoonyAdapter[uint64](), cleanup(adapter))

when defined(adapter_boost_lockfree_queue_available):
  # Boost.LockFree is C++ -- only loadable under `nim cpp`. The adapter
  # raises a hard {.error.} under `nim c`, so pulling it in only when both
  # the gate AND the cpp build mode are set keeps `nim c -r` of this file
  # compilable.
  when defined(cpp):
    import ../benchmarks/nim/adapters/boost_lockfree_queue_adapter
    import ../benchmarks/nim/adapter

    suite "boost_lockfree_queue_adapter":
      test "push/pop 1000 uint64 round-trip preserves set":
        runRoundTrip[BoostLockfreeQueueAdapter[uint64]](
          makeBoostLockfreeQueueAdapter[uint64](capacity = 4096), cleanup(adapter)
        )

when defined(adapter_boost_lockfree_spsc_available):
  when defined(cpp):
    import ../benchmarks/nim/adapters/boost_lockfree_spsc_adapter
    import ../benchmarks/nim/adapter

    suite "boost_lockfree_spsc_adapter":
      test "push/pop 1000 uint64 round-trip preserves set":
        runRoundTrip[BoostLockfreeSpscAdapter[uint64]](
          makeBoostLockfreeSpscAdapter[uint64](capacity = 4096), cleanup(adapter)
        )

when defined(adapter_crossbeam_array_queue_available):
  import ../benchmarks/nim/adapters/crossbeam_array_queue_adapter
  import ../benchmarks/nim/adapter

  suite "crossbeam_array_queue_adapter":
    test "push/pop 1000 uint64 round-trip preserves set":
      runRoundTrip[CrossbeamArrayQueueAdapter[uint64]](
        makeCrossbeamArrayQueueAdapter[uint64](capacity = 4096), cleanup(adapter)
      )

when defined(adapter_crossbeam_seg_queue_available):
  import ../benchmarks/nim/adapters/crossbeam_seg_queue_adapter
  import ../benchmarks/nim/adapter

  suite "crossbeam_seg_queue_adapter":
    test "push/pop 1000 uint64 round-trip preserves set":
      runRoundTrip[CrossbeamSegQueueAdapter[uint64]](
        makeCrossbeamSegQueueAdapter[uint64](), cleanup(adapter)
      )

when defined(adapter_moodycamel_available):
  # MoodyCamel ``concurrentqueue`` is a C++ template + extern "C"
  # wrapper; load only when both the gate AND the cpp build mode are
  # set so ``nim c -r`` of this file stays compilable when the suite
  # runs under the default backend.
  when defined(cpp):
    import ../benchmarks/nim/adapters/moodycamel_adapter
    import ../benchmarks/nim/adapter

    suite "moodycamel_adapter":
      test "push/pop 1000 uint64 round-trip preserves set":
        runRoundTrip[MoodycamelAdapter[uint64]](
          makeMoodycamelAdapter[uint64](capacity = 4096), cleanup(adapter)
        )

when defined(adapter_threading_channels_available):
  import ../benchmarks/nim/adapters/threading_channels_adapter
  import ../benchmarks/nim/adapter

  suite "threading_channels_adapter":
    test "push/pop 1000 uint64 round-trip preserves set":
      runRoundTrip[ThreadingChannelsAdapter[uint64]](
        makeThreadingChannelsAdapter[uint64](capacity = 4096), cleanup(adapter)
      )

when defined(adapter_nim_channel_available):
  import ../benchmarks/nim/adapters/nim_channel_adapter
  import ../benchmarks/nim/adapter

  suite "nim_channel_adapter":
    test "push/pop 1000 uint64 round-trip preserves set":
      runRoundTrip[NimChannelAdapter[uint64]](
        makeNimChannelAdapter[uint64](capacity = 4096), cleanup(adapter)
      )
