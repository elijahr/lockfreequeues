# Slot Ownership Typestates

## Overview

Slot ownership typestates track slot ownership through the type system, so the most common slot-misuse footguns (use-after-commit, double-commit, commit without write) are caught by the compile-time CFG verifier. Some combinations (notably cardinality-axis cross-products) still rely on runtime invariants — see the source comments in `bqueue.nim` for the precise envelope.

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

### Bounded multi-cardinality shapes (SPMC, MPSC, MPMC)

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

### Unbounded multi-cardinality shapes (SPMC, MPSC, MPMC)

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

## Integration with DEBRA epoch states

The slot-ownership typestates are an internal implementation detail; they
are not part of the user-facing v5.0.0 surface. They live under
`src/lockfreequeues/typestates/` and are composed by the unified `Queue`
generic's `push` / `pop` implementations, not invoked directly by
application code.

For the multi-cardinality unbounded shapes, the push-side typestate
progression is woven together with DEBRA's pin / unpin epoch states: a
push context carries the pinned thread handle and epoch alongside the
slot-ownership token, so the type system enforces all of these at once:

- **Must be pinned to push** — the context only exists after the calling
  thread has registered (via `attach()` / `attachConsumer()`) and pinned
  an epoch.
- **Must claim a slot to write** — `writeItem` requires the
  slot-claimed token produced by a successful CAS.
- **Invariants are enforced together** — the epoch pin and the slot
  ownership are threaded through the same linear typestate chain, so
  neither can be dropped without the other.

## MPSC implementation progression

The unbounded MPSC push path moves through this typestate sequence
(defined in `src/lockfreequeues/typestates/unbounded_mpsc_push.nim`):

1. **MPSCPushReady**: initial state with pinned DEBRA context
2. **MPSCPushSegmentLoaded**: segment and tail position loaded
3. **MPSCPushSlotClaimed**: slot claimed via CAS (or SegmentFull/Retry)
4. **MPSCPushItemWritten**: data written to slot
5. **MPSCPushComplete**: committed flag set, data visible to consumers

Each transition consumes its predecessor (a `sink` parameter), so a stale
token cannot be reused — the compiler rejects any code path that skips a
state or double-uses a claim. Application code never touches these states
directly; they are the compile-time scaffolding behind a single
`producer.push(item)` call on a `Queue` built with `newUnboundedMupsicQueue`.

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
