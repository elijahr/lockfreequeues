## Typestate for unbounded MPMC pop operations.
##
## Multiple consumers coordinate via wait-free `fetchAdd` on `consumerHead`
## (Task 11 framing-flip: counter is next-claimable, starts at 0) plus the
## LCRQ per-slot tri-state `cellState[]` (Task 14 migration; replaces the
## prior per-slot `committed[]` flag). The post-claim cellState check
## pairs with the producer's release publish-CAS on `cellState[slot]`
## (CellEmpty -> CellFilled) to establish the publication HB edge.
##
## Task 14 scope: type-only declaration of `UMPMCPopClosedSlot` (mirrors
## SPMC Task 9). The close-CAS that emits this state is introduced by
## Task 16 in `tryClaimSlot`. Until Task 16 lands, the close-CAS arm is
## unreachable from production code paths; the state is wired into the
## typestate macro graph and the facade match arm only.
##
## State names are U-prefixed (Unbounded) to avoid registry collision with
## the bounded MPMC* graph (typestates 0.8.0 keys by base state name).

import ../atomic_dsl
import typestates
import debra

import ./unbounded_mpmc_push # Reuse UMPMCSegment, UnboundedMupmucBase

type
  # Base context - carries pinned state and queue pointer
  UMPMCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  # States (U-prefix per overlay #5: typestates 0.8.0 registry collision
  # with bounded MPMC* graph).
  UMPMCPopReady*[T; S, MT: static int] = distinct UMPMCPopContext[T, S, MT]

  UMPMCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    tail*: int
    consumerHead*: int

  UMPMCPopSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    slot*: int

  UMPMCPopClosedSlot*[T; S, MT: static int] = object
    ## Task 11 LCRQ: consumer's close-CAS won on an empty cell. Terminal:
    ## facade extracts pin and returns `none(T)`. Carries no segment
    ## pointer (the close-CAS already resolved this slot's race;
    ## headSegment is NOT advanced — the next pop() call re-enters on
    ## the same headSegment).
    ##
    ## Status (Task 14, 2026-05-15): TYPE-ONLY. The state is declared and
    ## wired into the typestate macro / facade match arm but no
    ## production code path emits it yet. Task 16 introduces the
    ## close-CAS in `tryClaimSlot` that produces this state. Mirror of
    ## SPMC `unbounded_spmc_pop.nim:56-69` (pre-Task-10a TYPE-ONLY shape).
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  UMPMCPopSegmentExhausted*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]

  UMPMCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  UMPMCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    value*: T
    slot*: int
    isLastSlot*: bool

typestate UMPMCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states UMPMCPopReady[T, S, MT],
    UMPMCPopSegmentLoaded[T, S, MT],
    UMPMCPopSlotClaimed[T, S, MT],
    UMPMCPopClosedSlot[T, S, MT],
    UMPMCPopSegmentExhausted[T, S, MT],
    UMPMCPopEmpty[T, S, MT],
    UMPMCPopComplete[T, S, MT]
  transitions:
    UMPMCPopReady[T, S, MT] -> UMPMCPopSegmentLoaded[T, S, MT]
    UMPMCPopSegmentLoaded[T, S, MT] ->
      (
        UMPMCPopSlotClaimed[T, S, MT] | UMPMCPopSegmentExhausted[T, S, MT] |
        UMPMCPopClosedSlot[T, S, MT]
      ) as UMPMCPopSlotClaimResult[T, S, MT]
    UMPMCPopSlotClaimed[T, S, MT] -> UMPMCPopComplete[T, S, MT]
    UMPMCPopClosedSlot[T, S, MT] -> UMPMCPopEmpty[T, S, MT]
    UMPMCPopSegmentExhausted[T, S, MT] ->
      (UMPMCPopReady[T, S, MT] | UMPMCPopEmpty[T, S, MT]) as
      UMPMCPopAdvanceResult[T, S, MT]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupmucBase[S, T, MT]
): UMPMCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  UMPMCPopReady[T, S, MT](
    UMPMCPopContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int](
    complete: sink UMPMCPopComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    empty: sink UMPMCPopEmpty[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    closedSlot: sink UMPMCPopClosedSlot[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning when a consumer wins the
  ## close-CAS on an empty cell (Task 16, type-only at Task 14). Terminal:
  ## facade returns `none(T)` without advancing headSegment. Mirror of
  ## SPMC `unbounded_spmc_pop.nim:148-158`.
  Pinned[MT](
    EpochGuardContext[MT](
      handle: closedSlot.pinnedHandle, epoch: closedSlot.pinnedEpoch
    )
  )

## DEBRA Pin–Claim Ordering Invariant (Task 11):
## 1. Pin opens BEFORE headSegment.load (this `withPin:` scope).
## 2. Pin covers fetchAdd(consumerHead) → readItem(data[mySlot]) window.
## 3. Segment under pin == segment under claim (typestate linearity).
## 4. headSegment.compareExchange retires oldSeg via DEBRA; oldSeg is
##    not freed until all pins in its retire-epoch rotate.
## 5. Bulk variant (mupmuc:bulk pop site) acquires per-iteration pin
##    satisfying (1)-(4).
## DO NOT alter withPin scope without re-establishing this invariant.

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink UMPMCPopReady[T, S, MT]
): UMPMCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  ## Mirrors production memory ordering: acquire-load the headSegment (so
  ## a peer consumer's release-store on `headSegment.compareExchange`
  ## happens-before this load), then acquire-load `tail` and
  ## `consumerHead`. The `tail` load pairs with producers' release-stores
  ## from `seg.tail` reservation CAS edges; the `consumerHead` load pairs
  ## with peer consumers' successful fetchAdd releases. (consumerHead is
  ## next-claimable under the Task 11 framing-flip.)
  let ctx = UMPMCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)
  let head = seg.consumerHead.load(moAcquire)

  UMPMCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    consumerHead: head,
  )

# Try to claim slot wait-free via fetchAdd on consumerHead.
#
# Task 14 scope: pure fetchAdd-then-emit. The close-CAS that produces
# `UMPMCPopClosedSlot` is introduced by Task 16. Until then, the
# emission path is: in-range fetchAdd -> SlotClaimed; OOR slot or
# pre-claim short-circuit -> SegmentExhausted. The `UMPMCPopClosedSlot`
# arm is declared in the result union (typestate macro) for type-graph
# completeness but is unreachable from this proc body at Task 14.
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink UMPMCPopSegmentLoaded[T, S, MT]
): UMPMCPopSlotClaimResult[T, S, MT] {.transition.} =
  ## Claim a slot wait-free using `fetchAdd` on `consumerHead`. Returns:
  ## - SlotClaimed: our fetchAdd returned an in-range slot (mySlot < S).
  ## - SegmentExhausted: segment is consumer-saturated (mySlot >= S, or
  ##   pre-claim short-circuit fired).
  ## - ClosedSlot: TYPE-ONLY at Task 14. Task 16 will introduce the
  ##   close-CAS-on-empty branch that emits this state.
  ##
  ## The wait-free `fetchAdd` primitive replaces the prior CAS-loop (which
  ## under contention could observe a stale snapshot and lose the CAS);
  ## see design §3 / §7.2 / §8.N1 for the framing-flip rationale.
  let seg = loaded.segment

  # Optional advisory pre-claim short-circuit (reduces wasted fetchAdds).
  # Per design §3 MPMC pseudocode + §7.2 row L145: MPMC retains the advisory
  # short-circuit. F1 verb-side defense, retained shape; correctness owned by
  # the close-CAS HB chain in Task 16 (once landed); this is OPTIMIZATION,
  # not a TOCTOU defense.
  if loaded.consumerHead >= loaded.tail:
    let freshTail = seg.tail.load(moAcquire)
    if loaded.consumerHead >= freshTail:
      return
        UMPMCPopSlotClaimResult[T, S, MT] ->
        UMPMCPopSegmentExhausted[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
          segment: loaded.segment,
        )

  # Wait-free claim primitive (D1 = fetchAdd). Acquire ordering on the
  # fetchAdd RMW serializes claim attempts among consumers. The HB chain
  # that carries the producer's `seg.data[slot]` write into our subsequent
  # read goes through `cellState[slot]` publish-CAS (E1, design §7.1) —
  # established at the close-CAS / CellFilled gate in `readItem` /
  # `tryClaimSlot`, not at this fetchAdd.
  let mySlot = seg.consumerHead.fetchAdd(1, moAcquire)

  # Slot-index past segment end — segment is consumer-saturated. The facade
  # advances headSegment when it sees this.
  if mySlot >= S:
    return
      UMPMCPopSlotClaimResult[T, S, MT] ->
      UMPMCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Task 14: emit SlotClaimed directly. The close-CAS-on-empty branch that
  # would emit `UMPMCPopClosedSlot` is introduced by Task 16. The post-claim
  # cellState check that establishes the HB chain with the producer's
  # publish-CAS lives in `readItem` (defensive debug-mode gate, mirror of
  # SPMC `unbounded_spmc_pop.nim:371-375`).
  return
    UMPMCPopSlotClaimResult[T, S, MT] ->
    UMPMCPopSlotClaimed[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: mySlot,
    )

# Read item from claimed slot.
proc readItem*[T; S, MT: static int](
    claimed: sink UMPMCPopSlotClaimed[T, S, MT]
): UMPMCPopComplete[T, S, MT] {.transition.} =
  ## Read item from claimed slot.
  ##
  ## CellFilled gate (Task 14 / Task 16, design §7.1 E1 + §7.4): once
  ## Task 16 lands the close-CAS in `tryClaimSlot`, `UMPMCPopSlotClaimed`
  ## will be emitted only after the failed close-CAS observed
  ## `CellFilled` (with `moAcquire` ordering), establishing HB with the
  ## producer's `moAcquireRelease` publish-CAS on the same
  ## `cellState[slot]`. Until Task 16, this debug-mode gate asserts the
  ## eventual invariant but does not yet have the close-CAS HB edge —
  ## tryClaimSlot at Task 14 simply fetchAdds and emits SlotClaimed
  ## (relying on producer ordering and the existing seg.tail acquire
  ## load for visibility).
  let queue = claimed.queue
  let seg = claimed.segment
  when not defined(release):
    doAssert seg.cellState[claimed.slot].load(moAcquire) == CellFilled,
      "MPMC readItem: cellState invariant violated — slot must be " &
      "CellFilled when UMPMCPopSlotClaimed is emitted (see tryClaimSlot " &
      "close-CAS HB chain, design §7.1 E1)"
  let value = move(seg.data[claimed.slot])
  discard queue.itemCount.fetchSub(1, moRelaxed)

  UMPMCPopComplete[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    value: value,
    slot: claimed.slot,
    isLastSlot: claimed.slot == S - 1,
  )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
    exhausted: sink UMPMCPopSegmentExhausted[T, S, MT]
): UMPMCPopAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  ##
  ## Note: MPMC's headSegment advance is the facade's responsibility
  ## (consumer-vs-consumer CAS coordination on
  ## `headSegment.compareExchange` happens at the call site, not here).
  ## The facade also retires the old segment via DEBRA when it wins the
  ## headSegment CAS. The facade's Ready arm additionally re-checks
  ## `oldSeg.consumerHead` before advancing — see the bb50bc9
  ## livelock fix pattern applied to sipmuc and preempted here for MPMC.
  ## (consumerHead is next-claimable under the Task 11 framing-flip.)
  let seg = exhausted.segment
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return
      UMPMCPopAdvanceResult[T, S, MT] ->
      UMPMCPopEmpty[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  UMPMCPopAdvanceResult[T, S, MT] ->
    UMPMCPopReady[T, S, MT](
      UMPMCPopContext[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Note (A3): the popped value lives on `UMPMCPopComplete.value*` (declared
# above as a public field). Callers read `complete.value` directly; no
# `getValue` verb proc is needed. Avoiding the proc shaves one
# generic-instantiation pass per (T, S, MT, mm-mode) tuple from compile time
# and removes a trivial wrapper.
