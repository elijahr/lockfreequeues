## Typestate for unbounded SPMC pop operations.
##
## Multiple consumers coordinate via wait-free `fetchAdd` on `consumerHead`
## (Task 11 framing-flip: counter is next-claimable, starts at 0). SPMC has
## NO `committed` array — the producer's release store on `tail` is the
## publication signal that consumers acquire-load before reading. The
## post-claim tail re-check (acquire) pairs with that release-store.
##
## State names are U-prefixed (Unbounded) to avoid registry collision with
## the bounded SPMC* graph (typestates 0.8.0 keys by base state name).

import ../atomic_dsl
import typestates
import debra

import ./unbounded_spmc_push # Reuse Segment, UnboundedSipmucBase

type
  # Base context - carries pinned state and queue pointer
  USPMCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  # States (U-prefix per overlay #5)
  USPMCPopReady*[T; S, MT: static int] = distinct USPMCPopContext[T, S, MT]

  USPMCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    tail*: int
    consumerHead*: int

  USPMCPopSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    slot*: int

  USPMCPopSegmentExhausted*[T; S, MT: static int] = object
    ## Consumer-saturated segment: pre-claim short-circuit observed
    ## consumerHead >= freshTail OR fetchAdd returned a slot index >= S.
    ## Facade advances headSegment on this state. Task 9 removed the
    ## prior `awaitingTail: bool` discriminator; the over-claim race
    ## (formerly `awaitingTail=true`) is resolved at Task 10a via the
    ## `USPMCPopClosedSlot` arm produced by the close-CAS in
    ## `tryClaimSlot`.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]

  USPMCPopClosedSlot*[T; S, MT: static int] = object
    ## Task 11 LCRQ: consumer's close-CAS won on an empty cell. Terminal:
    ## facade extracts pin and returns `none(T)`. Carries no segment
    ## pointer (the close-CAS already resolved this slot's race;
    ## headSegment is NOT advanced — the next pop() call re-enters on
    ## the same headSegment).
    ##
    ## Status (Task 9, 2026-05-15): TYPE-ONLY. The state is declared and
    ## wired into the typestate macro / facade match arm but no
    ## production code path emits it yet. Task 10a introduces the
    ## close-CAS in `tryClaimSlot` that produces this state.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  USPMCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  USPMCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    value*: T
    slot*: int
    isLastSlot*: bool

typestate USPMCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states USPMCPopReady[T, S, MT],
    USPMCPopSegmentLoaded[T, S, MT],
    USPMCPopSlotClaimed[T, S, MT],
    USPMCPopClosedSlot[T, S, MT],
    USPMCPopSegmentExhausted[T, S, MT],
    USPMCPopComplete[T, S, MT],
    USPMCPopEmpty[T, S, MT]
  transitions:
    USPMCPopReady[T, S, MT] -> USPMCPopSegmentLoaded[T, S, MT]
    USPMCPopSegmentLoaded[T, S, MT] ->
      (
        USPMCPopSlotClaimed[T, S, MT] | USPMCPopClosedSlot[T, S, MT] |
          USPMCPopSegmentExhausted[T, S, MT]
      ) as USPMCSlotClaimResult[T, S, MT]
    USPMCPopSlotClaimed[T, S, MT] -> USPMCPopComplete[T, S, MT]
    USPMCPopClosedSlot[T, S, MT] -> USPMCPopEmpty[T, S, MT]
    USPMCPopSegmentExhausted[T, S, MT] ->
      (USPMCPopReady[T, S, MT] | USPMCPopEmpty[T, S, MT]) as
      USPMCAdvanceResult[T, S, MT]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedSipmucBase[S, T, MT]
): USPMCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  USPMCPopReady[T, S, MT](
    USPMCPopContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int](
    complete: sink USPMCPopComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    empty: sink USPMCPopEmpty[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    exhausted: sink USPMCPopSegmentExhausted[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning when the facade
  ## terminates without advancing the head segment (e.g., the bulk-pop
  ## path bails after observing the segment is consumer-saturated but
  ## elects not to retire).
  Pinned[MT](
    EpochGuardContext[MT](
      handle: exhausted.pinnedHandle, epoch: exhausted.pinnedEpoch
    )
  )

proc extractPinned*[T; S, MT: static int](
    closedSlot: sink USPMCPopClosedSlot[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning when a consumer wins
  ## the close-CAS on an empty cell (Task 10a). Terminal: facade
  ## returns `none(T)` without advancing headSegment.
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
## 5. Bulk variant (sipmuc:504-509) acquires per-iteration pin satisfying (1)-(4).
## DO NOT alter withPin scope without re-establishing this invariant.

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink USPMCPopReady[T, S, MT]
): USPMCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  ## Mirrors production memory ordering: acquire load on `headSegment`
  ## synchronises with the consumer-side release store performed when a
  ## prior consumer advanced the head, so we never observe a freed
  ## pointer. `tail` and `consumerHead` are acquire-loaded so the
  ## producer's `tail.store(moRelease)` and other consumers' fetchAdd
  ## successes happen-before this load. (consumerHead is next-claimable
  ## under the Task 11 framing-flip.)
  let ctx = USPMCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)
  let head = seg.consumerHead.load(moAcquire)

  USPMCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    consumerHead: head,
  )

# Try to claim slot wait-free via fetchAdd on consumerHead
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink USPMCPopSegmentLoaded[T, S, MT]
): USPMCSlotClaimResult[T, S, MT] {.transition.} =
  ## Claim a slot wait-free using `fetchAdd` on `consumerHead`. Returns:
  ## - SlotClaimed: our fetchAdd returned an in-range slot whose data is
  ##   already published (tail re-check passed).
  ## - SegmentExhausted: segment is consumer-saturated (mySlot >= S, or
  ##   pre-claim short-circuit fired). Facade advances headSegment.
  ## - ClosedSlot: (Task 10a, NOT YET EMITTED) — consumer's close-CAS
  ##   wins on an empty cell. Currently the over-claim race
  ##   (mySlot >= freshTail post-claim) still emits SegmentExhausted as a
  ##   placeholder; Task 10a replaces that emit with the close-CAS path
  ##   producing ClosedSlot.
  ##
  ## The wait-free `fetchAdd` primitive replaces the prior CAS-loop (which
  ## under contention could observe a stale snapshot and lose); see design
  ## §3 / §7.1 / §8.N1 for the framing-flip rationale.
  let seg = loaded.segment

  # Optional advisory pre-claim short-circuit (reduces wasted fetchAdds).
  # F1 verb-side defense, retained shape. Correctness is OWNED BY the
  # post-claim re-check below; this is OPTIMIZATION, NOT a TOCTOU defense.
  # The acquire-load on freshTail ensures we observe any producer release
  # that happened between loadSegment's snapshot and this check.
  if loaded.consumerHead >= loaded.tail:
    let freshTail = seg.tail.load(moAcquire)
    if loaded.consumerHead >= freshTail:
      return
        USPMCSlotClaimResult[T, S, MT] ->
        USPMCPopSegmentExhausted[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
          segment: loaded.segment,
        )

  # Wait-free claim primitive (D1 = fetchAdd). Acquire ordering pairs with
  # other consumers' release on consumerHead (RMW) so subsequent reads of
  # seg.data are ordered after any consumer's prior writes.
  let mySlot = seg.consumerHead.fetchAdd(1, moAcquire)

  # Slot-index past segment end — segment is consumer-saturated. The facade
  # advances headSegment when it sees this.
  if mySlot >= S:
    return
      USPMCSlotClaimResult[T, S, MT] ->
      USPMCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Post-claim tail re-check (REQUIRED — placement is load-bearing per
  # design §6 D3). The acquire here pairs with the producer's release-store
  # on seg.tail. If the producer has not yet published mySlot, the slot is
  # in the over-claim race window. Task 9 emits SegmentExhausted here as a
  # placeholder (preserving prior advance-headSegment behavior); Task 10a
  # replaces this branch with the close-CAS that produces USPMCPopClosedSlot
  # (no headSegment advance, single-pop returns none(T)).
  if mySlot >= seg.tail.load(moAcquire):
    return
      USPMCSlotClaimResult[T, S, MT] ->
      USPMCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  return
    USPMCSlotClaimResult[T, S, MT] ->
    USPMCPopSlotClaimed[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: mySlot,
    )

# Read item from claimed slot
proc readItem*[T; S, MT: static int](
    claimed: sink USPMCPopSlotClaimed[T, S, MT]
): USPMCPopComplete[T, S, MT] {.transition.} =
  ## Read item from claimed slot.
  let queue = claimed.queue
  let seg = claimed.segment
  let value = move(seg.data[claimed.slot])
  discard queue.itemCount.fetchSub(1, moRelaxed)

  USPMCPopComplete[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    value: value,
    slot: claimed.slot,
    isLastSlot: claimed.slot == S - 1,
  )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
    exhausted: sink USPMCPopSegmentExhausted[T, S, MT]
): USPMCAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  ## Note: SPMC's headSegment advance is the facade's responsibility
  ## (consumer-vs-consumer CAS coordination on `headSegment.compareExchange`
  ## happens at the call site, not here, so the typestate stays single-CAS-
  ## free for the verb pipeline). The facade also retires the old segment
  ## via DEBRA when it wins the headSegment CAS.
  let seg = exhausted.segment
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return
      USPMCAdvanceResult[T, S, MT] ->
      USPMCPopEmpty[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  USPMCAdvanceResult[T, S, MT] ->
    USPMCPopReady[T, S, MT](
      USPMCPopContext[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Note (A3): the popped value lives on `USPMCPopComplete.value*` (declared
# above as a public field). Callers read `complete.value` directly; no
# `getValue` verb proc is needed. Avoiding the proc shaves one
# generic-instantiation pass per (T, S, MT, mm-mode) tuple from compile time
# and removes a trivial wrapper.
