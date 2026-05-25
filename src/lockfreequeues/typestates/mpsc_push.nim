## MPSC Push operation lifecycle typestate (Vyukov per-slot sequence protocol).
##
## State machine:
##   Start -> SlotClaimed | Full | Start  (3-arm: claim succeeded / generation
##                                         full / retry)
##   SlotClaimed -> bool                  (terminal: write data + publish seq)
##
## Multiple producers race on `tail` — identical in shape to `mpmc_push`, only
## the facade name differs (MupsicPushBase vs MupmucPushBase).
##
## Key invariant: Once a slot is claimed via CAS on `tail`, data MUST be
## written and the per-slot `seq` MUST be advanced to `pos + 1` (release).
## That release is the producer->consumer happens-before edge.
##
## Memory ordering follows Vyukov canonical: `moRelaxed` on the global `tail`
## CAS (the per-slot `seq` does the data-ordering work), `moAcquire` on the
## `seq` load (pairs with consumer's release at `pos + N`), and `moRelease`
## on the `seq` store at `pos + 1` (gates the matching consumer).
##
## Backoff: this verb returns the `Start` arm to signal "retry". The facade
## holds `var spins = InitialSpin` and calls `backoffOnRetry(spins)` between
## iterations on the Start arm. See design doc §6.
##
## See design doc §2 (algorithm), §3 (bug walkthrough), §10.8 (recipe).

import ../atomic_dsl
import typestates

import ./virtual_values_n
import ./mpmc_cell

type
  MPSCPushStart*[N: static int] = object ## Entry point. No data yet.

  MPSCPushSlotClaimed*[N: static int] = object
    ## CAS on `tail` succeeded - we own the slot at `pos mod N`.
    ## MUST write data and publish the seq advance.
    pos*: uint64
    slot*: PhysicalSlotN[N]

  MPSCPushFull*[N: static int] = object ## Terminal: generation full.

typestate MPSCPushOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states MPSCPushStart[N], MPSCPushSlotClaimed[N], MPSCPushFull[N]
  transitions:
    MPSCPushStart[N] ->
      MPSCPushSlotClaimed[N] | MPSCPushFull[N] | MPSCPushStart[N] as
      MPSCPushClaimResult[N]

# Forward declaration for Mupsic (avoid circular import).
# Note: even though push only writes `tail`, the shared base type carries
# `head` too so the facade can cast a single Mupsic[N,P,T] to either
# MupsicPushBase or MupsicBase (pop-side). Field order MUST stay in lockstep
# with MupsicBase in mpsc_pop.nim — see design doc §10.11 for the offsetof
# asserts the facade emits.
type MupsicPushBase*[N, P: static int, T] = object
  head* {.align: CacheLineBytes.}: Atomic[uint64]
  tail* {.align: CacheLineBytes.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, T]

proc start*[N: static int](): MPSCPushStart[N] {.inline.} =
  ## Begin a push operation.
  MPSCPushStart[N]()

proc tryClaim*[N, P: static int, T](
    op: MPSCPushStart[N], queue: var MupsicPushBase[N, P, T]
): MPSCPushClaimResult[N] {.inline, transition.} =
  ## Vyukov producer claim. Returns one of:
  ## - SlotClaimed: tail CAS won; caller must call `complete`.
  ## - Full: per-slot seq says the previous-generation consumer hasn't
  ##         re-armed this slot yet. Caller returns false to user.
  ## - Start: CAS race or producer raced ahead; caller backs off and retries.
  let pos = queue.tail.load(moRelaxed) # P1
  # PhysicalSlotN[N] is constructed via the validated index() path. The
  # double-mod (here, then again inside index()) is intentional: validate()
  # checks val < 2*N and index() does the final mod. The cost is one extra
  # mod on the hot path - negligible vs the CAS that follows.
  let slot = initRawN[N](int(pos mod uint64(N))).validate().index()
  let s = queue.cells.seqLoad(slot, moAcquire) # P2
  let diff = cast[int64](s) - cast[int64](pos)
  if diff == 0:
    var expected = pos
    if queue.tail.compareExchangeWeak(expected, pos + 1, moRelaxed, moRelaxed):
      # P3
      MPSCPushClaimResult[N] -> MPSCPushSlotClaimed[N](pos: pos, slot: slot)
    else:
      MPSCPushClaimResult[N] -> MPSCPushStart[N]() # CAS race: caller retries
  elif diff < 0:
    MPSCPushClaimResult[N] -> MPSCPushFull[N]() # generation full
  else:
    MPSCPushClaimResult[N] -> MPSCPushStart[N]() # producer raced ahead: retry

proc complete*[N, P: static int, T](
    op: MPSCPushSlotClaimed[N], queue: var MupsicPushBase[N, P, T], item: T
): bool {.inline, notATransition.} =
  ## Write item to the claimed slot, then publish the seq advance.
  ## The `seq.store(pos+1, moRelease)` is the producer->consumer edge.
  queue.cells.dataPtr(op.slot)[] = item # P4 plain store; ordered by P5
  queue.cells.seqStore(op.slot, op.pos + 1, moRelease) # P5 publish
  true

proc extractFalse*[N: static int](op: MPSCPushFull[N]): bool {.notATransition.} =
  ## Terminal: extract false result (queue was full this generation).
  false
