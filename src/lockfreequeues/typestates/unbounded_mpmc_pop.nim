## Typestate for unbounded MPMC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop with CAS coordination
## and committed flag check, bridges back. Multiple consumers coordinate via
## CAS on `consumerHead`, and must check `committed` flag before reading.
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

  UMPMCPopSlotUncommitted*[T; S, MT: static int] = object
    ## Producer claimed slot but hasn't finished writing yet (committed
    ## flag still false). Pop returns `none(T)` per design §1.
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
    UMPMCPopSlotUncommitted[T, S, MT],
    UMPMCPopSegmentExhausted[T, S, MT],
    UMPMCPopEmpty[T, S, MT],
    UMPMCPopComplete[T, S, MT]
  transitions:
    UMPMCPopReady[T, S, MT] -> UMPMCPopSegmentLoaded[T, S, MT]
    UMPMCPopSegmentLoaded[T, S, MT] ->
      (
        UMPMCPopSlotClaimed[T, S, MT] | UMPMCPopSegmentExhausted[T, S, MT] |
        UMPMCPopSlotUncommitted[T, S, MT] | UMPMCPopReady[T, S, MT]
      ) as UMPMCPopSlotClaimResult[T, S, MT]
    UMPMCPopSlotClaimed[T, S, MT] ->
      (UMPMCPopComplete[T, S, MT] | UMPMCPopSlotUncommitted[T, S, MT]) as
      UMPMCPopCommitCheck[T, S, MT]
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
    uncommitted: sink UMPMCPopSlotUncommitted[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](
      handle: uncommitted.pinnedHandle, epoch: uncommitted.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink UMPMCPopReady[T, S, MT]
): UMPMCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  ## Mirrors production memory ordering at `unbounded_mupmuc.nim:355-359`:
  ## acquire-load the headSegment (so a peer consumer's release-store on
  ## `headSegment.compareExchange` happens-before this load), then
  ## acquire-load `tail` and `consumerHead`. The `tail` load pairs with
  ## producers' `committed[slot].store(moRelease)` via the `seg.tail`
  ## release-edges; the `consumerHead` load pairs with peer consumers'
  ## successful CAS releases.
  let ctx = UMPMCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.consumerHead.load(moAcquire)

  UMPMCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    consumerHead: prevIdx,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink UMPMCPopSegmentLoaded[T, S, MT]
): UMPMCPopSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot with CAS coordination on `consumerHead`.
  ## Returns SlotClaimed, SegmentExhausted, SlotUncommitted, or Ready.
  ##
  ## Item-loss livelock fix (preempted from sipmuc bb50bc9): MPMC pop has
  ## the same SHAPE as sipmuc pop (snapshot tail in `loadSegment` +
  ## advance segment + CAS-advance head). When the snapshotted
  ## `loaded.tail` says we are exhausted, we MUST re-read `seg.tail` with
  ## acquire ordering before committing to that conclusion. Producers'
  ## CAS on `seg.tail` (the success edge of `tryClaimSlot` in the push
  ## verb) may have advanced past the snapshot taken in `loadSegment`,
  ## reserving slots that producers will then publish via
  ## `committed[slot].store(moRelease)`. If we trust the stale snapshot
  ## and propagate to `advanceSegment`, the facade will CAS-advance
  ## `headSegment` past a segment that still has unclaimed (or
  ## about-to-be-claimable) items — those items become unreachable when
  ## the segment is retired. The fresh acquire-load synchronises with the
  ## producers' release-edges, so newly reserved slots in this segment
  ## are observed before we decide to advance.
  ##
  ## In MPMC the bug is somewhat narrower than in SPMC because the
  ## consumer also gates on the per-slot `committed` flag (which the
  ## producer release-stores AFTER reserving the slot). However the same
  ## shape applies on the segment-advance path: the facade's Ready arm
  ## CAS-advances `headSegment` based on the consumer's exhausted
  ## conclusion; if that conclusion was made on stale `tail`, we can
  ## still skip past slots whose committed flag has not yet been
  ## observed, stranding items in the retired segment. The combined
  ## (typestate-side tail re-load) + (facade-side consumerHead
  ## re-check) defense matches the SPMC fix.
  let seg = loaded.segment
  # Note: loaded.consumerHead is a snapshot. A consumer that races
  # with another consumer's CAS will see a stale value here, but the
  # resulting CAS attempt simply fails (expected != actual) and the loop
  # re-iterates via the Ready arm. Benign; not a livelock.
  let mySlot = loaded.consumerHead + 1

  if mySlot >= loaded.tail:
    # Re-load tail with acquire to pair with the producers' release-store
    # on `seg.tail` (CAS success edge). If a producer reserved more slots
    # since `loadSegment`, fall through to the committed-check + CAS path.
    # If the segment really is exhausted, the fresh load returns the same
    # value and we transition to Exhausted as before.
    let freshTail = seg.tail.load(moAcquire)
    if mySlot >= freshTail:
      return
        UMPMCPopSlotClaimResult[T, S, MT] ->
        UMPMCPopSegmentExhausted[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
          segment: loaded.segment,
        )

  # Check if slot is committed before trying to claim. If a producer has
  # reserved the slot (advancing `seg.tail` past `mySlot`) but has not
  # yet release-stored `committed[mySlot]`, we report Uncommitted and
  # the facade returns `none(T)` per design §1 — non-blocking pop
  # contract.
  if not seg.committed[mySlot].load(moAcquire):
    return
      UMPMCPopSlotClaimResult[T, S, MT] ->
      UMPMCPopSlotUncommitted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
      )

  # CAS to claim slot via consumerHead. Free-running counter-CAS, NOT a
  # wait-chain (per design §1 / production line :409).
  var expected = loaded.consumerHead
  if seg.consumerHead.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    return
      UMPMCPopSlotClaimResult[T, S, MT] ->
      UMPMCPopSlotClaimed[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: mySlot,
      )
  else:
    # CAS failed - peer consumer already finished this iteration. Loop
    # back to retry from Ready. The facade's Ready arm uses
    # `backoffOnCASLossRetry()` here (production line :371 classification
    # per Decision §2.1).
    return
      UMPMCPopSlotClaimResult[T, S, MT] ->
      UMPMCPopReady[T, S, MT](
        UMPMCPopContext[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Read item from claimed slot
proc readItem*[T; S, MT: static int](
    claimed: sink UMPMCPopSlotClaimed[T, S, MT]
): UMPMCPopCommitCheck[T, S, MT] {.transition.} =
  ## Double-check committed flag and read item if ready. The slot
  ## was committed at `tryClaimSlot` time, but a paranoid re-check here
  ## means a consumer that lost a CAS race and re-entered cannot read
  ## from a slot whose committed flag was somehow rolled back. (Producers
  ## never roll back committed[]; this branch is structurally
  ## unreachable, but the typestate transition table includes it as a
  ## defensive arm — design §1 not-committed semantics.)
  let queue = claimed.queue
  let seg = claimed.segment

  if not seg.committed[claimed.slot].load(moAcquire):
    return
      UMPMCPopCommitCheck[T, S, MT] ->
      UMPMCPopSlotUncommitted[T, S, MT](
        pinnedHandle: claimed.pinnedHandle,
        pinnedEpoch: claimed.pinnedEpoch,
        queue: claimed.queue,
      )

  let value = seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  UMPMCPopCommitCheck[T, S, MT] ->
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
