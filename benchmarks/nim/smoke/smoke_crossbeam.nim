## Compile-and-run smoke for the Crossbeam adapters.
##
## Used by ``bench-comparison.yml`` as a sanity check that the cdylib
## is on the search path before the full bench binaries run.
##
## Build:
##   cargo build --release --manifest-path \
##     benchmarks/rust/bench-ffi-crossbeam/Cargo.toml
##   nim c -d:adapter_crossbeam_array_queue_available \
##         -d:adapter_crossbeam_seg_queue_available \
##         --passL:-Wl,-rpath,benchmarks/rust/bench-ffi-crossbeam/target/release \
##         benchmarks/nim/smoke/smoke_crossbeam.nim
##
## (the ``-rpath`` is only needed for run-time dlopen on Linux; on macOS
## the dylib's install_name resolves via the ``-L`` path.)

import std/syncio

when defined(adapter_crossbeam_array_queue_available):
  import ../adapters/crossbeam_array_queue_adapter
  import ../adapter

when defined(adapter_crossbeam_seg_queue_available):
  import ../adapters/crossbeam_seg_queue_adapter
  import ../adapter

when not defined(adapter_crossbeam_array_queue_available) and
    not defined(adapter_crossbeam_seg_queue_available):
  {.
    error:
      "smoke_crossbeam requires at least one of -d:adapter_crossbeam_array_queue_available or -d:adapter_crossbeam_seg_queue_available."
  .}

proc main() =
  setStdIoUnbuffered()
  echo "crossbeam smoke: starting"

  when defined(adapter_crossbeam_array_queue_available):
    block array:
      var a = makeCrossbeamArrayQueueAdapter[uint64](capacity = 64)
      defer:
        cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "crossbeam array push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success:
          break
        inc seen
      doAssert seen == 32, "crossbeam array popped " & $seen & " (expected 32)"
      echo "crossbeam ArrayQueue: 32 push/pop ok"

  when defined(adapter_crossbeam_seg_queue_available):
    block seg:
      var a = makeCrossbeamSegQueueAdapter[uint64]()
      defer:
        cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "crossbeam seg push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success:
          break
        inc seen
      doAssert seen == 32, "crossbeam seg popped " & $seen & " (expected 32)"
      echo "crossbeam SegQueue: 32 push/pop ok"

  echo "crossbeam smoke: ok"

when isMainModule:
  main()
