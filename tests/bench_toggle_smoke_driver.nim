## Out-of-process driver for the `LFQ_BENCH_HARNESS_BACKOFF` toggle.
##
## `disableHarnessBackoff` is cached at module init via a top-level `let`
## binding, so in-process `putEnv` after import will not exercise the
## cache. The `benchToggleSmoke` nimble task runs this binary three times
## with different env values and asserts the printed boolean matches.
import ../benchmarks/nim/bench_common
echo disableHarnessBackoff
