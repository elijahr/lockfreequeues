## Shared link-flag emission for the Crossbeam cdylib.
##
## Both ``crossbeam_array_queue_adapter`` and ``crossbeam_seg_queue_adapter``
## link against the same Rust cdylib (``benchmarks/rust/bench-ffi-crossbeam``
## → ``libbench_ffi_crossbeam``). Each adapter is enabled by its own
## ``-d:adapter_crossbeam_{array_queue,seg_queue}_available`` gate.
##
## Putting ``{.passL.}`` in a shared module guarantees the flags are emitted
## exactly once per compilation unit that needs them, regardless of which
## gates are set. Nim module processing dedups: importing this module from
## both adapters is fine — the pragmas execute once.
##
## A common CI configuration sets BOTH adapter gates globally but only
## imports one adapter into a given bench binary (e.g. ``bench_mpmc_bounded``
## uses the array variant only; ``bench_unbounded_mpmc`` uses the seg
## variant only — v5.0.0 B3 split the original ``bench_mpmc`` into
## per-family binaries and v5.0.0 3.3.9-D split ``bench_unbounded`` the
## same way; the MVP comparison adapters live in the mpmc-shaped
## binary of each family).
## The previous design — gating link emission on the OTHER adapter's gate —
## broke this case: with both gates set, the array adapter would skip
## emission expecting the seg adapter to handle it, but if seg wasn't
## imported its emission block was never compiled, leading to undefined
## symbols at link time. Owning emission here removes that coupling.
##
## Override the default search path with ``-d:crossbeamLibDir=<path>``.

when defined(crossbeamLibDir):
  {.passL: "-L" & crossbeamLibDir.}
else:
  {.passL: "-Lbenchmarks/rust/bench-ffi-crossbeam/target/release".}
{.passL: "-lbench_ffi_crossbeam".}
