## SPMC Push operation lifecycle typestate (Vyukov per-slot sequence protocol).
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
## Single-producer by *contract*, but Nim's `Sipmuc` facade does NOT enforce
## single-thread access. Per the C4 design-review decision (design doc §10.6),
## we keep `compareExchangeWeak` on `tail` even on the single-producer side as
## defense in depth: an accidental two-thread mis-use surfaces as a benign
## retry rather than silent data corruption.
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
## See design doc §2 (algorithm), §3 (bug walkthrough), §10.6 (recipe).

import ../atomic_dsl
import typestates

import ./virtual_values_n
import ./mpmc_cell

type
  SPMCPushStart*[N: static int] = object ## Entry point. No data yet.

  SPMCPushSlotClaimed*[N: static int] = object
    ## CAS on `tail` succeeded - we own the slot at `pos mod N`.
    ## MUST write data and publish the seq advance.
    pos*: uint64
    slot*: PhysicalSlotN[N]

  SPMCPushFull*[N: static int] = object ## Terminal: generation full.

typestate SPMCPushOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states SPMCPushStart[N], SPMCPushSlotClaimed[N], SPMCPushFull[N]
  transitions:
    SPMCPushStart[N] ->
      SPMCPushSlotClaimed[N] | SPMCPushFull[N] | SPMCPushStart[N] as
      SPMCPushClaimResult[N]

# Forward declaration for Sipmuc (avoid circular import).
# Note: even though push only writes `tail`, the shared base type carries
# `head` too so the facade can cast a single Sipmuc[N,C,T] to either
# SipmucPushBase or SipmucBase (pop-side). Field order MUST stay in lockstep
# with SipmucBase in spmc_pop.nim — see design doc §10.12 for the offsetof
# asserts the facade emits.
type SipmucPushBase*[N, C: static int, T] = object
  head* {.align: CacheLineBytes.}: Atomic[uint64]
  tail* {.align: CacheLineBytes.}: Atomic[uint64]
  cells*: MPMCCellArrayN[N, T]

proc start*[N: static int](): SPMCPushStart[N] {.inline.} =
  ## Begin a push operation.
  SPMCPushStart[N]()

proc tryClaim*[N, C: static int, T](
    op: SPMCPushStart[N], queue: var SipmucPushBase[N, C, T]
): SPMCPushClaimResult[N] {.inline, transition.} =
  ## Vyukov producer claim. Returns one of:
  ## - SlotClaimed: tail CAS won; caller must call `complete`.
  ## - Full: per-slot seq says the previous-generation consumer hasn't
  ##         re-armed this slot yet. Caller returns false to user.
  ## - Start: CAS race or mis-use detected; caller backs off and retries.
  let pos = queue.tail.load(moRelaxed) # P1
  # PhysicalSlotN[N] is constructed via the validated index() path. The
  # double-mod (here, then again inside index()) is intentional: validate()
  # checks val < 2*N and index() does the final mod. The cost is one extra
  # mod on the hot path - negligible vs the CAS that follows.
  let slot = initRawN[N](int(pos mod uint64(N))).validate().index()
  let s = queue.cells.seqLoad(slot, moAcquire) # P2
  let diff = cast[int64](s) - cast[int64](pos)
  if diff == 0:
    # Defensive CAS: contract says sole producer, but Nim doesn't enforce
    # it. CAS catches accidental two-thread mis-use as benign retry.
    var expected = pos
    if queue.tail.compareExchangeWeak(expected, pos + 1, moRelaxed, moRelaxed):
      # P3
      SPMCPushClaimResult[N] -> SPMCPushSlotClaimed[N](pos: pos, slot: slot)
    else:
      # Contract violation (two producers raced) OR weak-CAS spurious fail.
      # Either way, retry — backoff applied by caller.
      SPMCPushClaimResult[N] -> SPMCPushStart[N]()
  elif diff < 0:
    SPMCPushClaimResult[N] -> SPMCPushFull[N]() # generation full
  else:
    # diff > 0: the consumer's release at C5 stores `seq = old_pos + N`,
    # which is exactly the virtual position of the next producer-generation
    # for this slot — equality (diff == 0) is the steady-state outcome.
    # `diff > 0` requires an out-of-sync consumer that wrote a future-
    # generation seq, OR another producer raced ahead (SPMC contract
    # violation). We treat as retry rather than Full so a genuine race
    # recovers; the assert flags contract violations in debug builds for
    # diagnosis. We keep the assert defensively in case the SPMC contract
    # is violated.
    when defined(debug):
      doAssert false, "SPMC invariant suspected: seq > tail+0 — second producer?"
    SPMCPushClaimResult[N] -> SPMCPushStart[N]()

proc complete*[N, C: static int, T](
    op: SPMCPushSlotClaimed[N], queue: var SipmucPushBase[N, C, T], item: T
): bool {.inline, notATransition.} =
  ## Write item to the claimed slot, then publish the seq advance.
  ## The `seq.store(pos+1, moRelease)` is the producer->consumer edge.
  queue.cells.dataPtr(op.slot)[] = item # P4 plain store; ordered by P5
  queue.cells.seqStore(op.slot, op.pos + 1, moRelease) # P5 publish
  true

proc extractFalse*[N: static int](op: SPMCPushFull[N]): bool {.notATransition.} =
  ## Terminal: extract false result (queue was full this generation).
  false
