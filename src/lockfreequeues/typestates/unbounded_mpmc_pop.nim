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

# Try to claim slot wait-free via fetchAdd on consumerHead, then close-CAS
# the cell (Task 16, mirror of SPMC Task 10).
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink UMPMCPopSegmentLoaded[T, S, MT]
): UMPMCPopSlotClaimResult[T, S, MT] {.transition.} =
  ## Task 11 LCRQ (Task 16): fetchAdd consumerHead, then close-CAS the cell.
  ## Returns:
  ## - SlotClaimed: our fetchAdd returned an in-range slot AND the close-CAS
  ##   on `cellState[mySlot]` lost to the producer's publish-CAS — the cell
  ##   is `CellFilled` and `data[mySlot]` is published (HB via the failed
  ##   close-CAS pairing with the producer's publish-CAS, design §7.1 E1).
  ## - ClosedSlot: our close-CAS won — the cell was `CellEmpty`, we wrote
  ##   `CellClosed`. Terminal: facade returns `none(T)` without advancing
  ##   headSegment. The producer's later publish on this slot will fail
  ##   its CAS, recover its `pending` value, and retry on the next slot.
  ## - SegmentExhausted: segment is consumer-saturated. Pre-claim
  ##   short-circuits per design §3 D7 + D5 + C6 (§7.4):
  ##     1. `consumerHead >= S` (genuinely saturated; design §3 D7
  ##        load-bearing refinement).
  ##     2. `closed AND consumerHead >= tail` (early-close propagation;
  ##        BOTH loads `moAcquire` per design §3 D5 C6 + §7.4).
  ##   Also emitted when our fetchAdd returns `mySlot >= S`.
  ##
  ## Pre-Task-16, the over-claim race emitted SegmentExhausted as a
  ## placeholder via the `consumerHead >= freshTail` SC. Under LCRQ the
  ## producer's closure-skip retries advance `tail` past closed cells, so
  ## `tail` is no longer a reliable indicator of the number of filled
  ## cells; that SC is removed and replaced by the close-CAS-on-empty
  ## path that emits `UMPMCPopClosedSlot`.
  let seg = loaded.segment

  # Pre-claim short-circuit 1 (design §3 D7, load-bearing refinement):
  # only `consumerHead >= S` triggers the genuinely-saturated short-circuit.
  # The earlier fetchAdd-only `consumerHead >= freshTail` check was
  # **removed** under LCRQ — the producer's closure-skip retries advance
  # `tail` past closed cells, so `tail` is no longer a reliable indicator
  # of the number of filled cells. See design §3 D7.
  if loaded.consumerHead >= S:
    return
      UMPMCPopSlotClaimResult[T, S, MT] ->
      UMPMCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Pre-claim short-circuit 2 (D5 propagation; C6 paired moAcquire).
  # §7.4: BOTH `seg.closed.load(moAcquire)` AND `seg.tail.load(moAcquire)`
  # use acquire ordering for HB documentation clarity (a relaxed load on
  # `tail` is argumentatively sufficient via the prior closed-load HB
  # chain through E9, but is fragile under future maintenance). Cost:
  # one extra load-acquire barrier on a path that fires only when the
  # segment is producer-closed AND consumer-saturated (rare).
  if seg.closed.load(moAcquire) and
      loaded.consumerHead >= seg.tail.load(moAcquire):
    return
      UMPMCPopSlotClaimResult[T, S, MT] ->
      UMPMCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Wait-free claim primitive (D1 = fetchAdd). Acquire ordering on this
  # fetchAdd-RMW serializes claim ordering among consumers (slot
  # uniqueness). The HB chain for seg.data publication is independent —
  # it rides on the cellState CAS chain (E1, design §7.1), not on
  # consumerHead.
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

  # LCRQ close-on-empty CAS (design §7.1 E1; §7.4 ordering rationale).
  # `moAcquireRelease` on success: AcqRel pairs with the producer's
  # publish-CAS on the same `cellState[mySlot]` so that on the producer's
  # subsequent attempt the failed CAS observes our `CellClosed` write
  # (release side) and any HB chain established by us (acquire side).
  # `moAcquire` on failure: when our close-CAS loses, the cell must be
  # `CellFilled` (the producer's publish-CAS won — see doAssert below).
  # Acquire pairs with the producer's `moAcquireRelease` publish, which
  # carries the `data[mySlot] = move(item)` write (HB through E1) so the
  # subsequent `readItem` observes a fully-published value.
  var expected: uint8 = CellEmpty
  let closeWon = seg.cellState[mySlot].compareExchange(
      expected, CellClosed, moAcquireRelease, moAcquire)
  if closeWon:
    return
      UMPMCPopSlotClaimResult[T, S, MT] ->
      UMPMCPopClosedSlot[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
      )

  # CAS failure: cell must be CellFilled. CellClosed is impossible —
  # consumer's own fetchAdd returns a unique `mySlot`; no peer consumer
  # can have closed our slot, and the producer never writes CellClosed
  # (the producer's writeItem only writes CellFilled via publish-CAS;
  # CellClosed is consumer-only state under LCRQ).
  doAssert expected == CellFilled,
    "MPMC tryClaimSlot: cell observed unexpected state on close-CAS failure"
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
  ## CellFilled gate (Task 16, design §7.1 E1 + §7.4):
  ## `UMPMCPopSlotClaimed` is emitted by `tryClaimSlot` only after the
  ## failed close-CAS observed `CellFilled` (with `moAcquire` ordering),
  ## which pairs with the producer's `moAcquireRelease` publish-CAS on
  ## the same `cellState[slot]`. This carries the producer's
  ## `data[slot] = move(item)` write into the consumer's view (HB
  ## through E1), so the move below reads a fully-published value, NOT
  ## a moved-from cell from the producer's CAS-fail recovery path.
  ##
  ## We re-load `cellState[slot]` here as a debug-build defensive
  ## gate — the close-CAS HB chain already establishes correctness in
  ## release builds (no extra atomic load needed on the fast path),
  ## but the assertion documents the invariant in source.
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
