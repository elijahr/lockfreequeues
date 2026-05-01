## lockfreequeues/backoff
##
## CAS-retry backoff policy for lockfreequeues' typestate retry loops.
## Built on debra's `cpuPause` and `schedYield` primitives. Two helpers:
##
##   * `backoffOnRetry`     - exponential backoff on CAS-failure retry.
##                            Doubles spin count each call up to MaxSpin;
##                            once spins reach YieldThreshold, also calls
##                            `schedYield` to release the CPU quantum.
##                            Use at every `continue` after a failed
##                            `tryClaim` / `compareExchange` in a
##                            retry-until-success loop.
##
##   * `backoffOnPeerWait`  - cpuPause-only stateless backoff for short
##                            peer-completion waits (e.g. spinning on a
##                            committed flag set by a peer thread). No
##                            syscall, no state: peer publication latency
##                            is typically shorter than `sched_yield`'s
##                            ~200ns-1us cost on Linux.
##
## State-passing pattern: `backoffOnRetry` callers declare
## `var spins = InitialSpin` BEFORE entering the retry loop and pass it
## by `var` reference; the helper mutates in place. `backoffOnPeerWait`
## takes no arguments (stateless). The caller's success path adds zero
## instructions (helpers are only called on the failure edge, not per
## loop iteration unconditionally).
##
## Constants are tunable via `-d:LockfreeQueuesInitialSpin=N` etc. if a
## downstream user needs to retune for a specific workload, but defaults
## are chosen from lock-free literature (Mellor-Crummey/Scott, Anderson)
## and validated by Bencher gates.
##
## NOTE: `cpuPause` is named so (not `cpuRelax`) in debra to avoid a
## collision with `system.cpuRelax` (re-exported from `std/sysatomics`).
## The stdlib version is a compiler-barrier-only fallback on non-x86;
## debra's `cpuPause` emits the real `pause`/`yield` instruction.

import debra/atomics/backoff

const
  InitialSpin* {.intdefine.} = 4
    ## Initial spin count for `backoffOnRetry`. Caller initializes
    ## `var spins = InitialSpin` before the retry loop. Doubles each
    ## failed iteration.

  MaxSpin* {.intdefine.} = 256
    ## Upper bound on `spins` after exponential growth. Prevents runaway
    ## spin counts on pathologically contended workloads. 256 is aligned
    ## with Anderson/MCS exponential-cap norms (typical range 64-256):
    ## permissive enough to absorb high contention bursts without
    ## unbounded spin time, low enough that a worst-case spin completes
    ## in single-digit microseconds on modern x86/aarch64.

  YieldThreshold* {.intdefine.} = 16
    ## When `spins >= YieldThreshold`, `backoffOnRetry` also calls
    ## `schedYield` after the cpuPause burst. Below this threshold,
    ## stays in cpuPause-only mode (no syscall cost).

proc backoffOnRetry*(spins: var int) {.inline.} =
  ## Called on the failure path of a CAS-retry loop. Burns `spins`
  ## cpuPause cycles, optionally yields the OS quantum if contention
  ## is escalating, then doubles `spins` (capped at `MaxSpin`).
  ##
  ## Caller pattern:
  ##   var spins = InitialSpin
  ##   while true:
  ##     ...
  ##     if not tryClaim(...):
  ##       backoffOnRetry(spins)
  ##       continue
  ##     ...
  for _ in 0 ..< spins:
    cpuPause()
  if spins >= YieldThreshold:
    schedYield()
  spins = min(spins * 2, MaxSpin)

proc backoffOnPeerWait*() {.inline.} =
  ## Called inside a tight `while peer-flag-not-set: ...` loop.
  ## Single cpuPause per call (no syscall, no state, no exponential
  ## growth). Stateless by design: peer publication latency is short
  ## enough that exponential growth and syscall escalation would
  ## overshoot.
  ##
  ## Caller pattern (e.g. unbounded segment-local committed flag):
  ##   while not seg.committed[i].load(moAcquire):
  ##     backoffOnPeerWait()
  cpuPause()
