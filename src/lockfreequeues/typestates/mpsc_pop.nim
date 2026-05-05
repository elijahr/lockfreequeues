## MPSC Pop operation lifecycle typestate (Vyukov per-slot sequence protocol).
##
## State machine:
##   Start -> SlotClaimed | Empty | Start  (3-arm: claim succeeded /
##                                          generation empty / retry)
##   SlotClaimed -> T                      (terminal: read data + re-arm seq)
##
## Key invariant: Once a slot is claimed via CAS on `head`, the data MUST be
## read and the per-slot `seq` MUST be advanced to `pos + N` (release). That
## release is the consumer->next-generation-producer happens-before edge.
##
## Single-consumer by *contract*, but Nim's `Mupsic` facade does NOT enforce
## single-thread access. Per the C4 design-review decision (design doc §10.9),
## we keep `compareExchangeWeak` on `head` even on the single-consumer side as
## defense in depth: an accidental two-thread mis-use surfaces as a benign
## retry rather than silent data corruption.
##
## Memory ordering follows Vyukov canonical: `moRelaxed` on the global `head`
## CAS (the per-slot `seq` does the data-ordering work), `moAcquire` on the
## `seq` load (pairs with producer's release at `pos + 1`), and `moRelease`
## on the `seq` store at `pos + N` (gates the next-generation producer).
##
## Backoff: this verb returns the `Start` arm to signal "retry". The facade
## holds `var spins = InitialSpin` and calls `backoffOnRetry(spins)` between
## iterations on the Start arm. See design doc §6.
##
## See design doc §2 (algorithm), §3 (bug walkthrough), §10.9 (recipe).

import ../atomic_dsl
import typestates

import ./virtual_values_n
import ./mpmc_cell

type
  MPSCPopStart*[N: static int] = object ## Entry point. No data yet.

  MPSCPopSlotClaimed*[N: static int] = object
    ## CAS on `head` succeeded - we own the slot at `pos mod N`.
    ## MUST read data and publish the seq advance (re-arm for next gen).
    pos*: uint64
    slot*: PhysicalSlotN[N]

  MPSCPopEmpty*[N: static int] = object
    ## Terminal: queue was empty this generation (per-slot seq lags).

typestate MPSCPopOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states MPSCPopStart[N], MPSCPopSlotClaimed[N], MPSCPopEmpty[N]
  transitions:
    MPSCPopStart[N] ->
      MPSCPopSlotClaimed[N] | MPSCPopEmpty[N] | MPSCPopStart[N] as MPSCPopClaimResult[N]

# Forward declaration for Mupsic (avoid circular import).
# Field order MUST stay in lockstep with MupsicPushBase in mpsc_push.nim
# - the facade uses a single Mupsic object castable to either base via the
# offsetof asserts in design doc §10.11.
type MupsicBase*[N, P: static int, T] = object
  head* {.align: CacheLineBytes.}: Atomic[uint64]
  tail* {.align: CacheLineBytes.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, T]

proc start*[N: static int](): MPSCPopStart[N] {.inline.} =
  ## Begin a pop operation.
  MPSCPopStart[N]()

proc tryClaim*[N, P: static int, T](
    op: MPSCPopStart[N], queue: var MupsicBase[N, P, T]
): MPSCPopClaimResult[N] {.inline, transition.} =
  ## Vyukov consumer claim. Returns one of:
  ## - SlotClaimed: head CAS won; caller must call `complete`.
  ## - Empty: per-slot seq says producer hasn't written this generation
  ##          yet. Caller returns false to user.
  ## - Start: CAS race or mis-use detected; caller backs off and retries.
  let pos = queue.head.load(moRelaxed) # C1
  # PhysicalSlotN[N] via the validated index() path - see mpsc_push.nim
  # tryClaim for rationale on the double-mod.
  let slot = initRawN[N](int(pos mod uint64(N))).validate().index()
  let s = queue.cells.seqLoad(slot, moAcquire) # C2
  let diff = cast[int64](s) - cast[int64](pos + 1)
  if diff == 0:
    # Defensive CAS: contract says sole consumer, but Nim doesn't enforce
    # it. CAS catches accidental two-thread mis-use as benign retry.
    var expected = pos
    if queue.head.compareExchangeWeak(expected, pos + 1, moRelaxed, moRelaxed):
      # C3
      MPSCPopClaimResult[N] -> MPSCPopSlotClaimed[N](pos: pos, slot: slot)
    else:
      # Contract violation (two consumers raced) OR weak-CAS spurious fail.
      # Either way, retry — backoff applied by caller.
      MPSCPopClaimResult[N] -> MPSCPopStart[N]()
  elif diff < 0:
    MPSCPopClaimResult[N] -> MPSCPopEmpty[N]() # generation empty
  else:
    # diff > 0: the producer's release at P5 stores `seq = pos + 1`, which
    # is exactly what we expect for the consumer at this slot. Equality
    # (diff == 0) is the steady-state outcome. `diff > 0` requires a
    # producer that wrote a future-generation seq (e.g. the next
    # generation's producer ran ahead of us by N), which is benign on
    # MPMC but on MPSC's sole-consumer-by-contract side indicates either
    # an out-of-sync producer or a contract violation. Treat as retry so
    # a genuine race recovers; the assert catches contract violations in
    # debug builds.
    when defined(debug):
      doAssert false, "MPSC invariant suspected: seq > head+1 — second consumer?"
    MPSCPopClaimResult[N] -> MPSCPopStart[N]()

proc complete*[N, P: static int, T](
    op: MPSCPopSlotClaimed[N], queue: var MupsicBase[N, P, T]
): T {.inline.} =
  ## Read value from the claimed slot, then re-arm the seq for the next
  ## generation. The `seq.store(pos+N, moRelease)` is the consumer->next-
  ## producer edge; the next producer at virtual position `pos + N` will
  ## see this seq value via its acquire load and proceed to claim.
  let value = queue.cells.dataPtr(op.slot)[] # C4 plain load; ordered by C2
  queue.cells.seqStore(op.slot, op.pos + uint64(N), moRelease) # C5 re-arm
  value
