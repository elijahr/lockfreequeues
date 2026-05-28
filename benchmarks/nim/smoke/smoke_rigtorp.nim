## Compile-and-run smoke for the rigtorp/SPSCQueue and rigtorp/MPMCQueue
## adapters (a single smoke covers both, mirroring `smoke_crossbeam.nim`).
##
## Used by `bench.yml` as a sanity check that the
## vendored single-header sources are present and the wrapper shims
## build cleanly with `nim cpp`, before the full bench binaries run
## with the same defines.
##
## Build:
##   nim cpp -d:adapter_rigtorp_spsc_available \
##           -d:adapter_rigtorp_mpmc_available \
##           --threads:on \
##           benchmarks/nim/smoke/smoke_rigtorp.nim

import std/syncio

when defined(adapter_rigtorp_spsc_available):
  import ../adapters/rigtorp_spsc_adapter
  import ../adapter

when defined(adapter_rigtorp_mpmc_available):
  import ../adapters/rigtorp_mpmc_adapter
  import ../adapter

when not defined(adapter_rigtorp_spsc_available) and
     not defined(adapter_rigtorp_mpmc_available):
  {.error: "smoke_rigtorp requires at least one of " &
           "-d:adapter_rigtorp_spsc_available or " &
           "-d:adapter_rigtorp_mpmc_available.".}

proc main() =
  setStdIoUnbuffered()
  echo "rigtorp smoke: starting"

  when defined(adapter_rigtorp_spsc_available):
    block spsc:
      var a = makeRigtorpSpscAdapter[uint64](capacity = 64)
      defer: cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "rigtorp_spsc push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success: break
        inc seen
      doAssert seen == 32,
        "rigtorp_spsc popped " & $seen & " (expected 32)"
      echo "rigtorp/SPSCQueue: 32 push/pop ok"

  when defined(adapter_rigtorp_mpmc_available):
    block mpmc:
      var a = makeRigtorpMpmcAdapter[uint64](capacity = 64)
      defer: cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "rigtorp_mpmc push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success: break
        inc seen
      doAssert seen == 32,
        "rigtorp_mpmc popped " & $seen & " (expected 32)"
      echo "rigtorp/MPMCQueue: 32 push/pop ok"

  echo "rigtorp smoke: ok"

when isMainModule:
  main()
