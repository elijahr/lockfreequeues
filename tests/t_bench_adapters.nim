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

template runRoundTrip[A](
    makeAdapterExpr: untyped, cleanupExpr: untyped
): untyped =
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
      runRoundTrip[LoonyAdapter[uint64]](
        makeLoonyAdapter[uint64](), cleanup(adapter)
      )
