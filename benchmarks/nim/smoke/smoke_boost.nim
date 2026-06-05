## Compile-and-run smoke for the Boost.LockFree adapters.
##
## Used by ``bench.yml`` as a sanity check that the apt-installed
## ``libboost-dev`` headers are present and resolvable, before the
## full bench binaries run with the same defines.
##
## Build:
##   nim cpp -d:adapter_boost_lockfree_queue_available \
##           -d:adapter_boost_lockfree_spsc_available \
##           benchmarks/nim/smoke/smoke_boost.nim
##
## Either define alone is sufficient; both are accepted so a single
## smoke binary covers both adapters.

import std/syncio

when defined(adapter_boost_lockfree_queue_available):
  import ../adapters/boost_lockfree_queue_adapter
  import ../adapter

when defined(adapter_boost_lockfree_spsc_available):
  import ../adapters/boost_lockfree_spsc_adapter
  import ../adapter

when not defined(adapter_boost_lockfree_queue_available) and
    not defined(adapter_boost_lockfree_spsc_available):
  {.
    error:
      "smoke_boost requires at least one of -d:adapter_boost_lockfree_queue_available or -d:adapter_boost_lockfree_spsc_available."
  .}

proc main() =
  setStdIoUnbuffered()
  echo "boost smoke: starting"

  when defined(adapter_boost_lockfree_queue_available):
    block boostQueue:
      var a = makeBoostLockfreeQueueAdapter[uint64](capacity = 64)
      defer:
        cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "boost queue push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success:
          break
        inc seen
      doAssert seen == 32, "boost queue popped " & $seen & " (expected 32)"
      echo "boost queue: 32 push/pop ok"

  when defined(adapter_boost_lockfree_spsc_available):
    block boostSpsc:
      var a = makeBoostLockfreeSpscAdapter[uint64](capacity = 64)
      defer:
        cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "boost spsc push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success:
          break
        inc seen
      doAssert seen == 32, "boost spsc popped " & $seen & " (expected 32)"
      echo "boost spsc: 32 push/pop ok"

  echo "boost smoke: ok"

when isMainModule:
  main()
