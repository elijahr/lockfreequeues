## Compile-and-run smoke for the consolidated Rust comparison cdylib's
## flume and kanal adapters (v4.2.0 Stage 5.2). Crossbeam keeps its own
## smoke at `smoke_crossbeam.nim`; this smoke covers the new flume +
## kanal shims (bounded and unbounded variants for each).
##
## Used by `bench.yml` (v4.2.0 Stage 5.2) as a sanity check that the
## consolidated cdylib (`libbench_ffi_comparison`) is on the search
## path AND that the symbol prefixes (`flume_*`, `kanal_*`) actually
## resolve before the full bench binaries run with the same defines.
##
## Build (Linux):
##   cargo build --release --manifest-path \
##     benchmarks/rust/comparison/Cargo.toml
##   nim c -d:adapter_flume_available \
##         -d:adapter_kanal_available \
##         --passL:-Wl,-rpath,benchmarks/rust/comparison/target/release \
##         benchmarks/nim/smoke/smoke_comparison.nim
##
## (the `-rpath` is only needed for run-time dlopen on Linux; on macOS
## the dylib's install_name resolves via the `-L` path.)

import std/syncio

when defined(adapter_flume_available):
  import ../adapters/flume_adapter
  import ../adapter

when defined(adapter_kanal_available):
  import ../adapters/kanal_adapter
  import ../adapter

when not defined(adapter_flume_available) and
     not defined(adapter_kanal_available):
  {.error: "smoke_comparison requires at least one of " &
           "-d:adapter_flume_available or -d:adapter_kanal_available.".}

proc main() =
  setStdIoUnbuffered()
  echo "comparison smoke: starting"

  when defined(adapter_flume_available):
    block flumeBounded:
      var a = makeFlumeAdapter[uint64](capacity = 64)
      defer: cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "flume bounded push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success: break
        inc seen
      doAssert seen == 32, "flume bounded popped " & $seen
      echo "flume/bounded: 32 push/pop ok"

    block flumeUnbounded:
      var a = makeFlumeUnboundedAdapter[uint64]()
      defer: cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "flume unbounded push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success: break
        inc seen
      doAssert seen == 32, "flume unbounded popped " & $seen
      echo "flume/unbounded: 32 push/pop ok"

  when defined(adapter_kanal_available):
    block kanalBounded:
      var a = makeKanalAdapter[uint64](capacity = 64)
      defer: cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "kanal bounded push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success: break
        inc seen
      doAssert seen == 32, "kanal bounded popped " & $seen
      echo "kanal/bounded: 32 push/pop ok"

    block kanalUnbounded:
      var a = makeKanalUnboundedAdapter[uint64]()
      defer: cleanup(a)
      for i in 0'u64 ..< 32'u64:
        let r = a.push(i)
        doAssert r == prSuccess, "kanal unbounded push failed at i=" & $i
      var seen = 0
      while true:
        let r = a.pop()
        if not r.success: break
        inc seen
      doAssert seen == 32, "kanal unbounded popped " & $seen
      echo "kanal/unbounded: 32 push/pop ok"

  echo "comparison smoke: ok"

when isMainModule:
  main()
