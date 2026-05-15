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

## DEBRA Pin–Claim Ordering Invariant (Task 11 / LCRQ — SPMC scope):
##
## 1. Pin opens BEFORE headSegment.load (this `withPin:` scope).
## 2. Pin covers fetchAdd(consumerHead) → readItem(data[mySlot]) window.
## 3. Segment under pin == segment under claim (typestate linearity).
## 4. headSegment.compareExchange retires oldSeg via DEBRA; oldSeg is
##    not freed until all pins in its retire-epoch rotate.
## 5. Bulk variant (sipmuc bulk pop site) acquires per-iteration pin
##    satisfying (1)–(4).
## 6. Closure-CAS pin coverage (SPMC). The pin opens BEFORE the consumer's
##    `cellState.CAS(CellEmpty -> CellClosed)` in `tryClaimSlot`, and
##    remains open THROUGH the CAS completion AND the subsequent transition
##    to `USPMCPopClosedSlot`. Same `withPin:` scope as the `loadSegment`
##    that produced the segment pointer. (Design §9 lines 687–719 /
##    §7.1 E1.)
##
##    SPMC producer scope: writeItem's publish-CAS does NOT require
##    `withPin:` scope. Single-producer immunity — no peer producer can
##    retire the segment under us (we are the only producer). Design §9
##    line 719 notes that pin coverage is not required for retire-
##    correctness, though the design recommends keeping it for consistency
##    — a recommendation the shipped sipmuc.nim push proc actively rejects,
##    prioritizing single-producer immunity over design symmetry.
##    Implementation: unbounded_sipmuc.nim push proc explicitly opts out of
##    `withPin:` on the push path; the publish-CAS at unbounded_spmc_push.nim
##    runs unpinned. The producer's failed publish-CAS followed by Shape A
##    retry (fetchAdd tail, re-enter) stays in the same single-producer
##    execution context, where pin coverage adds no safety.
##
##    MPMC topology (forward reference): this 6-item form scopes to SPMC's
##    shipped LCRQ cellState protocol. MPMC currently uses the v4.0
##    committed[] flag protocol (mpmc_pop.nim acquire-loads `committed[
##    mySlot]`; mpmc_push.nim release-stores via `markCommitted`). Pin
##    coverage of `committed[].load` and `committed[].store` falls under
##    items 1-5 (segment-level pin invariants apply equally to either
##    publication protocol). MPMC LCRQ migration is tracked as Tasks 14-22
##    of this plan; Task 22.5 will re-extend this doc-comment + add the
##    MPMC equivalent in unbounded_mpmc_pop.nim post-MPMC-migration.
##
## DO NOT alter withPin scope without re-establishing this invariant. In
## particular, do NOT introduce a `withPin:` scope around the SPMC push
## path "for consistency with MPMC" — the SPMC producer's no-pin design is
## load-bearing per design §9 line 719 (the producer doesn't reclaim
## segments and isn't racing other producers, so pin coverage adds no
## safety on the push path).

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
  ## Task 11 LCRQ: fetchAdd consumerHead, then close-CAS the cell.
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
  ## Pre-Task-10a, the over-claim race (`mySlot >= freshTail`) emitted
  ## SegmentExhausted as a placeholder. The close-CAS-on-empty replaces
  ## that placeholder with the LCRQ-correct `ClosedSlot` path.
  let seg = loaded.segment

  # Pre-claim short-circuit 1 (design §3 D7, load-bearing refinement):
  # only `consumerHead >= S` triggers the genuinely-saturated short-circuit.
  # The earlier fetchAdd-only `consumerHead >= freshTail` check was
  # **removed** under LCRQ — the producer's closure-skip retries advance
  # `tail` past closed cells, so `tail` is no longer a reliable indicator
  # of the number of filled cells. See design §3 D7.
  if loaded.consumerHead >= S:
    return
      USPMCSlotClaimResult[T, S, MT] ->
      USPMCPopSegmentExhausted[T, S, MT](
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
      USPMCSlotClaimResult[T, S, MT] ->
      USPMCPopClosedSlot[T, S, MT](
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
    "SPMC tryClaimSlot: cell observed unexpected state on close-CAS failure"
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
  ##
  ## CellFilled gate (Task 10a, design §7.1 E1 + §7.4):
  ## `USPMCPopSlotClaimed` is emitted by `tryClaimSlot` only after the
  ## failed close-CAS observed `CellFilled` (with `moAcquire` ordering),
  ## which pairs with the producer's `moAcquireRelease` publish-CAS on
  ## the same `cellState[slot]`. This carries the producer's
  ## `data[slot] = move(item)` write into the consumer's view (HB
  ## through E1), so the move below reads a fully-published value, NOT
  ## a moved-from cell from the producer's CAS-fail recovery path
  ## (see `unbounded_spmc_push.nim:392-412`).
  ##
  ## We re-load `cellState[slot]` here as a debug-build defensive
  ## gate — the close-CAS HB chain already establishes correctness in
  ## release builds (no extra atomic load needed on the fast path),
  ## but the assertion documents the invariant in source.
  let queue = claimed.queue
  let seg = claimed.segment
  when not defined(release):
    doAssert seg.cellState[claimed.slot].load(moAcquire) == CellFilled,
      "SPMC readItem: cellState invariant violated — slot must be " &
      "CellFilled when USPMCPopSlotClaimed is emitted (see tryClaimSlot " &
      "close-CAS HB chain, design §7.1 E1)"
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
