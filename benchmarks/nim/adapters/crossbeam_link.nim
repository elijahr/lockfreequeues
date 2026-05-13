## Shared link-flag emission for the consolidated Rust comparison cdylib.
##
## v4.2.0 Stage 5.2 consolidated the previous per-crate cdylibs (crossbeam
## only) into a single shared object `libbench_ffi_comparison` that
## also carries `flume_*` and `kanal_*` shims. All four Rust adapters
## (`crossbeam_array_queue_adapter`, `crossbeam_seg_queue_adapter`,
## `flume_adapter`, `kanal_adapter`) link against the same artifact via
## `-lbench_ffi_comparison`.
##
## Each adapter is enabled by its own `-d:adapter_<name>_available`
## gate. Putting `{.passL.}` in a shared module guarantees the flags
## are emitted exactly once per compilation unit that needs them,
## regardless of which gates are set. Nim module processing dedups:
## importing this module from any subset of the four adapters is fine —
## the pragmas execute once.
##
## A common CI configuration sets several adapter gates globally but
## only imports a subset into a given bench binary. The previous design
## (gating link emission on the OTHER adapter's gate) broke this case;
## owning emission here removes that coupling.
##
## Override the default search path with `-d:crossbeamLibDir=<path>`
## (the define name is preserved across the rename for backward
## compatibility with workflow snippets and downstream callers; the
## resolved directory points at the consolidated cdylib's `target/release`).

when defined(crossbeamLibDir):
  {.passL: "-L" & crossbeamLibDir.}
else:
  {.passL: "-Lbenchmarks/rust/comparison/target/release".}
{.passL: "-lbench_ffi_comparison".}
