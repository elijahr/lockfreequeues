## Compile-and-run smoke for the ``threading.Chan`` adapter.
##
## Used by ``bench.yml`` (Track 4 §4.7) as a sanity check that the
## ``nimble install threading`` step succeeded and that the package's
## channel module is resolvable + functional under ``--threads:on``.
##
## Build:
##   nim c -d:release --threads:on \
##     -d:adapter_threading_channels_available \
##     benchmarks/nim/smoke/smoke_threading_channels.nim

import std/syncio

when defined(adapter_threading_channels_available):
  import ../adapters/threading_channels_adapter
  import ../adapter

when not defined(adapter_threading_channels_available):
  {.error: "smoke_threading_channels requires -d:adapter_threading_channels_available.".}

proc main() =
  setStdIoUnbuffered()
  echo "threading_channels smoke: starting"

  block:
    var a = makeThreadingChannelsAdapter[uint64](capacity = 64)
    defer: cleanup(a)
    for i in 0'u64 ..< 32'u64:
      let r = a.push(i)
      doAssert r == prSuccess, "threading_channels push failed at i=" & $i
    var seen = 0
    while true:
      let r = a.pop()
      if not r.success:
        break
      inc seen
    doAssert seen == 32, "threading_channels popped " & $seen & " (expected 32)"
    echo "threading_channels: 32 push/pop ok"

  echo "threading_channels smoke: ok"

when isMainModule:
  main()
