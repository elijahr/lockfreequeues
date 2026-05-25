## MPMC Pop operation lifecycle typestate (Vyukov per-slot sequence protocol).
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
## Memory ordering follows Vyukov canonical: `moRelaxed` on the global `head`
## CAS (the per-slot `seq` does the data-ordering work), `moAcquire` on the
## `seq` load (pairs with producer's release at `pos + 1`), and `moRelease`
## on the `seq` store at `pos + N` (gates the next-generation producer).
##
## Backoff: this verb returns the `Start` arm to signal "retry". The facade
## holds `var spins = InitialSpin` and calls `backoffOnRetry(spins)` between
## iterations on the Start arm. See design doc §6.
##
## See design doc §2 (algorithm), §3 (bug walkthrough), §10.5 (recipe).

import ../atomic_dsl
import typestates

import ./virtual_values_n
import ./mpmc_cell

type
  MPMCPopStart*[N: static int] = object ## Entry point. No data yet.

  MPMCPopSlotClaimed*[N: static int] = object
    ## CAS on `head` succeeded - we own the slot at `pos mod N`.
    ## MUST read data and publish the seq advance (re-arm for next gen).
    pos*: uint64
    slot*: PhysicalSlotN[N]

  MPMCPopEmpty*[N: static int] = object
    ## Terminal: queue was empty this generation (per-slot seq lags).

typestate MPMCPopOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states MPMCPopStart[N], MPMCPopSlotClaimed[N], MPMCPopEmpty[N]
  transitions:
    MPMCPopStart[N] ->
      MPMCPopSlotClaimed[N] | MPMCPopEmpty[N] | MPMCPopStart[N] as MPMCPopClaimResult[N]

# Forward declaration for Mupmuc (avoid circular import).
# Field order MUST stay in lockstep with MupmucPushBase in mpmc_push.nim
# - the facade uses a single Mupmuc object castable to either base via the
# offsetof asserts in design doc §10.10.
type MupmucBase*[N, P, C: static int, T] = object
  head* {.align: CacheLineBytes.}: Atomic[uint64]
  tail* {.align: CacheLineBytes.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, T]

proc start*[N: static int](): MPMCPopStart[N] {.inline.} =
  ## Begin a pop operation.
  MPMCPopStart[N]()

proc tryClaim*[N, P, C: static int, T](
    op: MPMCPopStart[N], queue: var MupmucBase[N, P, C, T]
): MPMCPopClaimResult[N] {.inline, transition.} =
  ## Vyukov consumer claim. Returns one of:
  ## - SlotClaimed: head CAS won; caller must call `complete`.
  ## - Empty: per-slot seq says producer hasn't written this generation
  ##          yet. Caller returns false to user.
  ## - Start: CAS race or consumer raced ahead; caller backs off and retries.
  let pos = queue.head.load(moRelaxed) # C1
  # PhysicalSlotN[N] via the validated index() path - see mpmc_push.nim
  # tryClaim for rationale on the double-mod.
  let slot = initRawN[N](int(pos mod uint64(N))).validate().index()
  let s = queue.cells.seqLoad(slot, moAcquire) # C2
  let diff = cast[int64](s) - cast[int64](pos + 1)
  if diff == 0:
    var expected = pos
    if queue.head.compareExchangeWeak(expected, pos + 1, moRelaxed, moRelaxed):
      # C3
      MPMCPopClaimResult[N] -> MPMCPopSlotClaimed[N](pos: pos, slot: slot)
    else:
      MPMCPopClaimResult[N] -> MPMCPopStart[N]() # CAS race: caller retries
  elif diff < 0:
    MPMCPopClaimResult[N] -> MPMCPopEmpty[N]() # generation empty
  else:
    MPMCPopClaimResult[N] -> MPMCPopStart[N]() # consumer raced ahead: retry

proc complete*[N, P, C: static int, T](
    op: MPMCPopSlotClaimed[N], queue: var MupmucBase[N, P, C, T]
): T {.inline, notATransition.} =
  ## Read value from the claimed slot, then re-arm the seq for the next
  ## generation. The `seq.store(pos+N, moRelease)` is the consumer->next-
  ## producer edge; the next producer at virtual position `pos + N` will
  ## see this seq value via its acquire load and proceed to claim.
  ##
  ## Note: the old protocol had a "fire-and-forget head advance" CAS here
  ## because head/reservedHead were separate. Vyukov has a single `head`
  ## cursor advanced by the claimant at C3, so no follow-up CAS is needed.
  let value = queue.cells.dataPtr(op.slot)[] # C4 plain load; ordered by C2
  queue.cells.seqStore(op.slot, op.pos + uint64(N), moRelease) # C5 re-arm
  value
