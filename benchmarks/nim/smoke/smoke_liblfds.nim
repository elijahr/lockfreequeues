## Compile-and-run smoke for the liblfds adapter (covers BSS + BMM).
##
## Used by `bench.yml` (v4.2.0 Stage 5.3) as a sanity check that the
## vendored C source tree builds cleanly into `liblfds711.a`, that the
## thin C shim links, and that the adapter's push/pop round-trip
## works under both the SPSC (`bss`) and MPMC (`bmm`) backends, before
## the full bench binaries link against the same archive.
##
## Build:
##   nim c -d:release --threads:on \
##     -d:adapter_liblfds_available \
##     --passL:"-Lbenchmarks/vendor/liblfds/liblfds711/bin -llfds711" \
##     benchmarks/nim/smoke/smoke_liblfds.nim

import std/syncio

when not defined(adapter_liblfds_available):
  {.error: "smoke_liblfds requires -d:adapter_liblfds_available.".}

import ../adapters/liblfds_adapter
import ../adapter

proc main() =
  setStdIoUnbuffered()
  echo "liblfds smoke: starting"

  block bss:
    var a = makeLiblfdsAdapter[uint64](kind = lkBss, capacity = 64)
    defer: cleanup(a)
    for i in 0'u64 ..< 32'u64:
      let r = a.push(i)
      doAssert r == prSuccess, "liblfds bss push failed at i=" & $i
    var seen = 0
    while true:
      let r = a.pop()
      if not r.success: break
      inc seen
    doAssert seen == 32,
      "liblfds bss popped " & $seen & " (expected 32)"
    echo "liblfds/queue_bss: 32 push/pop ok"

  block bmm:
    var a = makeLiblfdsAdapter[uint64](kind = lkBmm, capacity = 64)
    defer: cleanup(a)
    for i in 0'u64 ..< 32'u64:
      let r = a.push(i)
      doAssert r == prSuccess, "liblfds bmm push failed at i=" & $i
    var seen = 0
    while true:
      let r = a.pop()
      if not r.success: break
      inc seen
    doAssert seen == 32,
      "liblfds bmm popped " & $seen & " (expected 32)"
    echo "liblfds/queue_bmm: 32 push/pop ok"

  echo "liblfds smoke: ok"

when isMainModule:
  main()
