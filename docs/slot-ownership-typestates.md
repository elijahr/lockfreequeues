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
| No read uncommitted data | `SlotAvailable` only when committed flag set (MPSC) |

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
