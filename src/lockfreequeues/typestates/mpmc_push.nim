## MPMC Push operation lifecycle typestate (Vyukov per-slot sequence protocol).
##
## State machine:
##   Start -> SlotClaimed | Full | Start  (3-arm: claim succeeded / generation
##                                         full / retry)
##   SlotClaimed -> bool                  (terminal: write data + publish seq)
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
## See design doc §2 (algorithm), §3 (bug walkthrough), §10.4 (recipe).

import ../atomic_dsl
import typestates

import ./virtual_values_n
import ./mpmc_cell

type
  MPMCPushStart*[N: static int] = object ## Entry point. No data yet.

  MPMCPushSlotClaimed*[N: static int] = object
    ## CAS on `tail` succeeded - we own the slot at `pos mod N`.
    ## MUST write data and publish the seq advance.
    pos*: uint64
    slot*: PhysicalSlotN[N]

  MPMCPushFull*[N: static int] = object ## Terminal: generation full.

typestate MPMCPushOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states MPMCPushStart[N], MPMCPushSlotClaimed[N], MPMCPushFull[N]
  transitions:
    MPMCPushStart[N] ->
      MPMCPushSlotClaimed[N] | MPMCPushFull[N] | MPMCPushStart[N] as
      MPMCPushClaimResult[N]

# Forward declaration for Mpmc (avoid circular import).
# Note: even though push only writes `tail`, the shared base type carries
# `head` too so the facade can cast a single Mpmc[N,P,C,T] to either
# MpmcPushBase or MpmcBase (pop-side). Field order MUST stay in lockstep
# with MpmcBase in mpmc_pop.nim — see design doc §10.10 for the offsetof
# asserts the facade emits.
type MpmcPushBase*[N, P, C: static int, T] = object
  head* {.align: CacheLineBytes.}: Atomic[uint64]
  tail* {.align: CacheLineBytes.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, T]

proc start*[N: static int](): MPMCPushStart[N] {.inline.} =
  ## Begin a push operation.
  MPMCPushStart[N]()

proc tryClaim*[N, P, C: static int, T](
    op: MPMCPushStart[N], queue: var MpmcPushBase[N, P, C, T]
): MPMCPushClaimResult[N] {.inline, transition.} =
  ## Vyukov producer claim. Returns one of:
  ## - SlotClaimed: tail CAS won; caller must call `complete`.
  ## - Full: per-slot seq says the previous-generation consumer hasn't
  ##         re-armed this slot yet. Caller returns false to user.
  ## - Start: CAS race or producer raced ahead; caller backs off and retries.
  let pos = queue.tail.load(moRelaxed) # P1
  # PhysicalSlotN[N] is constructed via the validated index() path. The
  # double-mod (here, then again inside index()) is intentional: validate()
  # checks val < 2*N and index() does the final mod. The cost is one extra
  # mod on the hot path - negligible vs the CAS that follows. See Phase A
  # open issue #1 in the impl plan.
  let slot = initRawN[N](int(pos mod uint64(N))).validate().index()
  let s = queue.cells.seqLoad(slot, moAcquire) # P2
  let diff = cast[int64](s) - cast[int64](pos)
  if diff == 0:
    var expected = pos
    if queue.tail.compareExchangeWeak(expected, pos + 1, moRelaxed, moRelaxed):
      # P3
      MPMCPushClaimResult[N] -> MPMCPushSlotClaimed[N](pos: pos, slot: slot)
    else:
      MPMCPushClaimResult[N] -> MPMCPushStart[N]() # CAS race: caller retries
  elif diff < 0:
    MPMCPushClaimResult[N] -> MPMCPushFull[N]() # generation full
  else:
    MPMCPushClaimResult[N] -> MPMCPushStart[N]() # producer raced ahead: retry

proc complete*[N, P, C: static int, T](
    op: MPMCPushSlotClaimed[N], queue: var MpmcPushBase[N, P, C, T], item: T
): bool {.inline, notATransition.} =
  ## Write item to the claimed slot, then publish the seq advance.
  ## The `seq.store(pos+1, moRelease)` is the producer->consumer edge.
  queue.cells.dataPtr(op.slot)[] = item # P4 plain store; ordered by P5
  queue.cells.seqStore(op.slot, op.pos + 1, moRelease) # P5 publish
  true

proc extractFalse*[N: static int](op: MPMCPushFull[N]): bool {.notATransition.} =
  ## Terminal: extract false result (queue was full this generation).
  false
