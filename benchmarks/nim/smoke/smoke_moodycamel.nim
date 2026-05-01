## Compile-and-run smoke for the MoodyCamel adapter.
##
## Used by ``bench.yml`` (Track 4 §4.7) as a sanity check that the
## vendored ``concurrentqueue.h`` is present and the
## ``moodycamel_wrapper.cpp`` shim builds cleanly with ``nim cpp``,
## before the full bench binaries run with the same define.
##
## Build:
##   nim cpp -d:adapter_moodycamel_available --threads:on \
##           benchmarks/nim/smoke/smoke_moodycamel.nim

import std/syncio

when defined(adapter_moodycamel_available):
  import ../adapters/moodycamel_adapter
  import ../adapter

when not defined(adapter_moodycamel_available):
  {.error: "smoke_moodycamel requires -d:adapter_moodycamel_available.".}

proc main() =
  setStdIoUnbuffered()
  echo "moodycamel smoke: starting"

  block:
    var a = makeMoodycamelAdapter[uint64](capacity = 64)
    defer: cleanup(a)
    for i in 0'u64 ..< 32'u64:
      let r = a.push(i)
      doAssert r == prSuccess, "moodycamel push failed at i=" & $i
    var seen = 0
    while true:
      let r = a.pop()
      if not r.success:
        break
      inc seen
    doAssert seen == 32, "moodycamel popped " & $seen & " (expected 32)"
    echo "moodycamel: 32 push/pop ok"

  echo "moodycamel smoke: ok"

when isMainModule:
  main()
