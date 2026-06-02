## SPMC Pop operation lifecycle typestate (Vyukov per-slot sequence protocol).
##
## State machine:
##   Start -> SlotClaimed | Empty | Start  (3-arm: claim succeeded /
##                                          generation empty / retry)
##   SlotClaimed -> T                      (terminal: read data + re-arm seq)
##
## Multiple consumers race on `head` — identical in shape to `mpmc_pop`, only
## the facade name differs (SpmcBase vs MpmcBase).
##
## Key invariant: Once a slot is claimed via CAS on `head`, the data MUST be
## read and the per-slot `seq` MUST be advanced to `pos + N` (release). That
## release is the consumer->next-generation-producer happens-before edge.
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
## See design doc §2 (algorithm), §3 (bug walkthrough), §10.7 (recipe).

import debra/atomics
import typestates

import ./virtual_values_n
import ./mpmc_cell

type
  SPMCPopStart*[N: static int] = object ## Entry point. No data yet.

  SPMCPopSlotClaimed*[N: static int] = object
    ## CAS on `head` succeeded - we own the slot at `pos mod N`.
    ## MUST read data and publish the seq advance (re-arm for next gen).
    pos*: uint64
    slot*: PhysicalSlotN[N]

  SPMCPopEmpty*[N: static int] = object
    ## Terminal: queue was empty this generation (per-slot seq lags).

typestate SPMCPopOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states SPMCPopStart[N], SPMCPopSlotClaimed[N], SPMCPopEmpty[N]
  transitions:
    SPMCPopStart[N] ->
      SPMCPopSlotClaimed[N] | SPMCPopEmpty[N] | SPMCPopStart[N] as SPMCPopClaimResult[N]

# Forward declaration for Spmc (avoid circular import).
# Field order MUST stay in lockstep with SpmcPushBase in spmc_push.nim
# - the facade uses a single Spmc object castable to either base via the
# offsetof asserts in design doc §10.12.
type SpmcBase*[N, C: static int, T] = object
  head* {.align: CacheLineBytes.}: Atomic[uint64]
  tail* {.align: CacheLineBytes.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, T]

proc start*[N: static int](): SPMCPopStart[N] {.inline.} =
  ## Begin a pop operation.
  SPMCPopStart[N]()

proc tryClaim*[N, C: static int, T](
    op: SPMCPopStart[N], queue: var SpmcBase[N, C, T]
): SPMCPopClaimResult[N] {.inline, transition.} =
  ## Vyukov consumer claim. Returns one of:
  ## - SlotClaimed: head CAS won; caller must call `complete`.
  ## - Empty: per-slot seq says producer hasn't written this generation
  ##          yet. Caller returns false to user.
  ## - Start: CAS race or consumer raced ahead; caller backs off and retries.
  let pos = queue.head.load(moRelaxed) # C1
  # PhysicalSlotN[N] via the validated index() path - see spmc_push.nim
  # tryClaim for rationale on the double-mod.
  let slot = initRawN[N](int(pos mod uint64(N))).validate().index()
  let s = queue.cells.seqLoad(slot, moAcquire) # C2
  let diff = cast[int64](s) - cast[int64](pos + 1)
  if diff == 0:
    var expected = pos
    if queue.head.compareExchangeWeak(expected, pos + 1, moRelaxed, moRelaxed):
      # C3
      SPMCPopClaimResult[N] -> SPMCPopSlotClaimed[N](pos: pos, slot: slot)
    else:
      SPMCPopClaimResult[N] -> SPMCPopStart[N]() # CAS race: caller retries
  elif diff < 0:
    SPMCPopClaimResult[N] -> SPMCPopEmpty[N]() # generation empty
  else:
    SPMCPopClaimResult[N] -> SPMCPopStart[N]() # consumer raced ahead: retry

proc complete*[N, C: static int, T](
    op: SPMCPopSlotClaimed[N], queue: var SpmcBase[N, C, T]
): T {.inline, notATransition.} =
  ## Read value from the claimed slot, then re-arm the seq for the next
  ## generation. The `seq.store(pos+N, moRelease)` is the consumer->next-
  ## producer edge; the next producer at virtual position `pos + N` will
  ## see this seq value via its acquire load and proceed to claim.
  let value = move(queue.cells.dataPtr(op.slot)[]) # C4 plain load; ordered by C2
  queue.cells.seqStore(op.slot, op.pos + uint64(N), moRelease) # C5 re-arm
  value
