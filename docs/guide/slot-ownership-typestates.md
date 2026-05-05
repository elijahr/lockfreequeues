# Slot Ownership Typestates

## Overview

Slot ownership typestates make data races structurally impossible by tracking slot ownership through the type system. Each state transition enforces critical invariants at compile-time.

## Producer-Side Flow

```
tryClaimSlot()
    |
    v
SlotClaimed ----[writeItem]----> SlotWritten ----[commitSlot]----> SlotCommitted
    |                                |
    v                                v
 SegmentFull                      [data ready]
```

### States

- **SlotClaimed**: Exclusive write access after winning CAS
  - Guarantees: This thread owns the slot index
  - Linear type: Can only use once (via `sink` parameter)

- **SlotWritten**: Data written but not visible yet
  - Guarantees: Data in slot, but consumers blocked

- **SlotCommitted**: Data visible to consumers
  - Guarantees: Consumers can now read

### Transitions

```nim
# Try to claim a slot
let result = tryClaimSlot(segment)

case result.kind:
of ckClaimed:
  # Won CAS - have exclusive access
  let claimed = result.claimed

  # Write data (consumes claimed token)
  let written = writeItem(claimed, myData)

  # Commit (make visible to consumers)
  let committed = commitSlot(written)

of ckSegmentFull:
  # Allocate new segment and retry
  discard

of ckRetry:
  # Lost CAS race, try again
  discard
```

## Consumer-Side Flow

```
tryClaimForRead()
    |
    v
SlotAvailable ----[readItem]----> T (data)
    |
    v
SlotPending ----[waitForCommit]----> SlotAvailable
```

### States

- **SlotAvailable**: Slot ready to read
  - Guarantees: Producer has committed, data is valid

- **SlotPending**: Claimed but not committed (MPSC only)
  - Need to wait for producer to commit

### Transitions

```nim
# Try to claim a slot for reading
let result = tryClaimForRead(segment)

case result.kind:
of pkAvailable:
  # Data ready - can read immediately
  let data = readItem(result.available)

of pkPending:
  # Producer hasn't committed yet - wait
  let available = waitForCommit(result.pending)
  let data = readItem(available)

of pkExhausted:
  # Segment empty, advance to next
  discard

of pkEmpty:
  # Queue empty
  discard
```

## Safety Guarantees

| Guarantee | How Enforced |
|-----------|--------------|
| No write without CAS | `writeItem` requires `SlotClaimed`, only from successful CAS |
| No double write | `sink` parameter consumes `SlotClaimed` token |
| No commit without write | `commitSlot` requires `SlotWritten` |
| No read without CAS | `readItem` requires `SlotAvailable`, only from successful CAS |
| No read uncommitted data | `SlotAvailable` only when slot is published — sequence-counter match for bounded variants, committed-flag set for unbounded variants |

## Publication Protocol: Bounded vs Unbounded

The slot-ownership typestates above describe the *shape* of producer and
consumer ownership transitions; the underlying mechanism that decides when a
slot is "claimable" or "available" differs between bounded and unbounded
queues.

### Bounded variants (`Sipmuc`, `Mupsic`, `Mupmuc`)

Bounded queues use the **Vyukov per-slot sequence counter** protocol. Each
slot carries an `Atomic[uint64]` whose value encodes the slot's generation
and phase:

- For slot `i` with capacity `N`, the producer-ready value is
  `gen * N + i`; after a producer commits, the value advances to
  `gen * N + i + 1` (consumer-ready). After a consumer reads, it advances
  to `(gen + 1) * N + i` (producer-ready again, next generation).
- Producers CAS the tail cursor only when the target slot's sequence equals
  `tail` (this generation's producer-ready value); consumers CAS the head
  cursor only when the target slot's sequence equals `head + 1` (this
  generation's consumer-ready value).
- Generation rollover races are structurally impossible: a stale consumer
  from generation `g` that wakes up after the slot has been recycled into
  generation `g + 1` will see a sequence value from generation `g + 1` and
  refuse to claim. This eliminates the silent-duplicate-delivery race that
  the old single-bit committed-flag protocol suffered under wraparound.
- Implementation lives in `src/lockfreequeues/typestates/slot_seq_n.nim`
  and is paired with `MPMCCellArrayN` for slot storage.

### Unbounded variants (`UnboundedSipmuc`, `UnboundedMupsic`, `UnboundedMupmuc`)

Unbounded queues use a **per-slot single-bit committed flag** inside each
segment. The segment-local view is unchanged from the 3.x layout because
segments are single-use linked nodes — once a segment is exhausted it is
retired via DEBRA and never recycled, so there is no generation-rollover
hazard for the committed flag to defend against.

- A producer writes to slot `i`, then sets `committed[i] = true` with a
  release store.
- A consumer that observes the head/tail cursors pointing past slot `i`
  performs an acquire load on `committed[i]` and only reads the slot once
  the flag is set. If the flag is unset (the producer has claimed but not
  yet published), the consumer waits or retries.
- Cross-segment hazards (segment retirement, head pointer advance, etc.)
  are handled by DEBRA epoch reclamation, not by the committed flag.

## Type System Enforcement

The type system makes these errors impossible:

```nim
# ERROR: Cannot write without claiming
let written = writeItem(segment, data)  # No SlotClaimed token!

# ERROR: Cannot reuse claimed token
let claimed = tryClaimSlot(segment).claimed
let written1 = writeItem(claimed, data1)
let written2 = writeItem(claimed, data2)  # claimed already consumed!

# ERROR: Cannot commit without writing
let committed = commitSlot(claimed)  # Need SlotWritten, not SlotClaimed!

# ERROR: Cannot read without claiming
let data = readItem(segment, 0)  # No SlotAvailable token!
```

## Integration with DEBRA Typestates

Slot ownership states compose with DEBRA pin/unpin states:

```nim
type
  MPSCPushContext[T; S, MT: static int] = object
    pinnedHandle: ThreadHandle[MT]
    pinnedEpoch: uint64
    queue: ptr UnboundedMupsicBase[S, T, MT]
    slotOwnership: SlotClaimed[T, S]  # Embedded slot state
```

This ensures:
- Must be pinned to push
- Must claim slot to write
- All invariants enforced together

## MPSC Implementation Example

The unbounded MPSC queue uses the following typestate progression:

### Push Operation States

1. **MPSCPushReady**: Initial state with pinned DEBRA context
2. **MPSCPushSegmentLoaded**: Segment and tail position loaded
3. **MPSCPushSlotClaimed**: Slot claimed via CAS (or SegmentFull/Retry)
4. **MPSCPushItemWritten**: Data written to slot
5. **MPSCPushComplete**: Committed flag set, data visible to consumers

### Example Usage

```nim
import debra
import lockfreequeues/typestates/unbounded_mpsc_push

# Setup
var manager = initDebraManager[4]()
let handle = registerThread(manager)
var queue: UnboundedMupsicBase[64, int, 4]
# ... initialize queue ...

# Push operation
let pinned = unpinned(handle).pin()
let ready = startPush(pinned, addr queue)
let loaded = ready.loadSegment()

let claimResult = loaded.tryClaimSlot()
case claimResult.kind:
of mMPSCPushSlotClaimed:
  let claimed = claimResult.mpscpushslotclaimed
  let written = claimed.writeItem(42)
  let complete = written.markCommitted()
  discard complete.extractPinned().unpin()

of mMPSCPushSegmentFull:
  # Handle segment allocation
  let newSeg = newSegment()
  let ready = claimResult.mpscpushsegmentfull.allocateNewSegment(newSeg)
  # Retry...

of mMPSCPushReady:
  # CAS failed, retry
  discard
```

## Performance

Slot ownership typestates are **zero-cost abstractions**:

- All types are compile-time only
- No runtime overhead
- Same assembly as hand-written CAS code
- Just adds compile-time safety

## Future Extensions

Potential enhancements:

- Batch operations: Claim multiple slots at once
- Backpressure: SlotClaimFailed -> wait/retry logic
- Priority: Different claim strategies based on priority
- Monitoring: Track claim success rates
