## Compile-and-run smoke for the atomic_queue (max0x7ba) adapter.
##
## Used by `bench.yml` as a sanity check that the
## vendored `atomic_queue.h` family is present and the
## `atomic_queue_wrapper.cpp` shim builds cleanly with `nim cpp`,
## before the full bench binaries run with the same define.
##
## Build:
##   nim cpp -d:adapter_atomic_queue_available --threads:on \
##           benchmarks/nim/smoke/smoke_atomic_queue.nim

import std/syncio

when defined(adapter_atomic_queue_available):
  import ../adapters/atomic_queue_adapter
  import ../adapter

when not defined(adapter_atomic_queue_available):
  {.error: "smoke_atomic_queue requires -d:adapter_atomic_queue_available.".}

proc main() =
  setStdIoUnbuffered()
  echo "atomic_queue smoke: starting"

  block:
    var a = makeAtomicQueueAdapter[uint64](capacity = 64)
    defer: cleanup(a)
    for i in 0'u64 ..< 32'u64:
      let r = a.push(i)
      doAssert r == prSuccess, "atomic_queue push failed at i=" & $i
    var seen = 0
    while true:
      let r = a.pop()
      if not r.success:
        break
      inc seen
    doAssert seen == 32, "atomic_queue popped " & $seen & " (expected 32)"
    echo "atomic_queue: 32 push/pop ok"

  echo "atomic_queue smoke: ok"

when isMainModule:
  main()
