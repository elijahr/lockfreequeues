# Slot Ownership Typestates

## Overview

Slot ownership typestates make data races structurally impossible by tracking slot ownership through the type system. Each state transition enforces critical invariants at compile-time.

## Facade pattern

As of v4.3, all four bounded queues (`Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`)
and all four unbounded queues (`UnboundedSipsic`, `UnboundedSipmuc`,
`UnboundedMupsic`, `UnboundedMupmuc`) share the same external shape:
**facade-over-typestate-verbs**. The facade — `push` and `pop` on the
queue's producer / consumer types — is the user-visible API; underneath it
calls a small set of typestate verbs (`tryClaimSlot`, `writeItem`,
`commitSlot`, `tryClaimForRead`, `readItem`, `advanceSegment`, etc.) that
carry the slot-ownership types described below.

The unification matters in three places:

1. **`withPin:` opens once at the facade.** For the unbounded multi-thread
   variants (`UnboundedSipmuc`, `UnboundedMupsic`, `UnboundedMupmuc`), the
   facade is responsible for entering and exiting the DEBRA pin scope
   exactly once per `push` / `pop` call. The verbs underneath carry a
   `Pinned[MaxThreads]` payload through the typestate transitions; they do
   NOT re-pin or unpin internally. Single-call pin lifetime keeps the
   epoch advance window tight, which is what lets DEBRA reclamation make
   progress under sustained traffic.

2. **Verbs carry `Pinned[MaxThreads]` as part of the slot-ownership
   payload.** The producer-side typestates (e.g. `UMPSCPushReady`,
   `UMPSCPushSlotClaimed`, `UMPSCPushItemWritten`) embed the pinned handle
   alongside the slot index and segment pointer, so the type system
   enforces "must be pinned to push" structurally rather than at runtime.
   See `Integration with DEBRA Typestates` below.

3. **Bulk variants run OUTSIDE the pin.** `pushAll` / `popAll` (the bulk
   forms) are loops of single-item `push` / `pop` calls; each iteration
   acquires its own pin scope. A bulk loop NESTED inside `withPin:` would
   extend the pin epoch arbitrarily and block DEBRA reclamation. The
   `nimble checkBulkOutsidePin` invariant gate fails CI loudly if any
   `for item in ...` loop appears within five lines of a `withPin:` site
   in `src/lockfreequeues/unbounded_*.nim`.

`UnboundedSipsic` is the exception to two-of-three: it has no DEBRA
manager (single-producer, single-consumer; no concurrent claim
contention to coordinate), so its facade type is 2-parameter
`[S: static int, T]` rather than the 3-parameter
`[S, T, MaxThreads: static int]` the other three unbounded variants take.
The facade-over-typestate-verbs and bulk-outside-pin conventions still
apply; the pin-scope discipline is moot because there is no pin.

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

The unbounded MPSC queue uses the following typestate progression. Names
are `U`-prefixed to avoid registry collisions with the bounded-graph
state names — see `Bind-name convention` below for the rule.

### Push Operation States

1. **`UMPSCPushReady`**: Initial state with pinned DEBRA context
2. **`UMPSCPushSegmentLoaded`**: Segment and tail position loaded
3. **`UMPSCPushSlotClaimed`**: Slot claimed via CAS (or `UMPSCPushSegmentFull` / `UMPSCPushReady` retry)
4. **`UMPSCPushItemWritten`**: Data written to slot
5. **`UMPSCPushComplete`**: Committed flag set, data visible to consumers

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
let ready = startPush[int, 64, 4](pinned, addr queue)
let loaded = ready.loadSegment()

var claimResult = loaded.tryClaimSlot()
match claimResult:
  UMPSCPushSlotClaimed(c):
    discard c
      .writeItem(42)
      .markCommitted()
      .extractPinned()
      .unpin()
  UMPSCPushSegmentFull(f):
    # Allocate new segment and retry
    let newSeg = newSegment()
    discard f.allocateNewSegment(newSeg)
  UMPSCPushReady(_):
    # CAS failed, retry
    discard
```

The example uses the typestates 0.8.0 `match` macro with exhaustive arms
(every state in the result union must have an arm; the compiler enforces
exhaustiveness). The concrete API verbs for the publish step are
`writeItem` → `markCommitted`; the upper `Producer-Side Flow` section
uses the pedagogical name `commitSlot` for the same operation.

## Bind-name convention

When destructuring typestate unions in `match` arms, the bound variable
follows a single-letter convention so reader and writer share an
expectation about which state is in play. The convention extends design
§3.3 with three new entries (`f`, `u`, `e`) that surfaced during the
74-site test migration in commit `3d96020`:

| Bind | State suffix it captures                       |
|------|------------------------------------------------|
| `b`  | `*Bound` (bound-but-not-yet-active)            |
| `p`  | `*Pinned` (pinned DEBRA context)               |
| `r`  | `*Ready`                                       |
| `s`  | `*SlotAvailable`, `*SlotReady`                 |
| `c`  | `*SlotClaimed` (outer)                         |
| `cmp`| `*Complete` (inner, when `c` is taken)         |
| `l`  | `*SegmentLoaded`                               |
| `f`  | `*SegmentFull`, `*SegmentExhausted`            |
| `u`  | `*SlotUncommitted`                             |
| `e`  | `*Empty`                                       |
| `_`  | unused / terminal arms                         |

The convention is for readability, not for the typestates verifier — the
verifier accepts any bind name. Using these consistently across the test
suite and source means a reader can scan a `match` arm and infer which
state is captured without reading the union definition.

## Performance

Slot ownership typestates are **zero-cost abstractions**:

- All types are compile-time only
- No runtime overhead
- Same assembly as hand-written CAS code
- Just adds compile-time safety

## Limitations

### `neutralizeStalled` is not safe mid-call (R5)

The unbounded queues expose a `neutralizeStalled` operation for
recovering from a thread that has stalled mid-push or mid-pop and will
not return. The operation re-publishes the slot the stalled thread
claimed, so consumers can resume drainage. **It is NOT safe to call
`neutralizeStalled` concurrently with an active `push` or `pop` on the
same queue.** Callers must serialise neutralisation against active
push/pop flows — typically by quiescing all producer/consumer threads
before invoking it.

The unsafety is structural: the typestate verbs assume the slot they
inspect has not been observed by a different actor mid-transition.
`neutralizeStalled` violates that assumption by design. Future work
(tracked separately) may lift this limitation; until then, treat
neutralisation as a periodic scheduled operation, not a hot-path tool.
