## Test-only synchronization channels for the awaitingTail-strand
## regression test (Task 1.7 / Task 11).
##
## DO NOT enable `-d:awaitingTailTestHook` in production builds. The hook
## blocks the producer's release-store on `tail` and the consumer's
## awaitingTail break path on stdlib `Channel[T]` recv, which would stall
## any normal workload indefinitely.
##
## Hook expansions in production source are PURE WAITS (Channel.send /
## Channel.recv only). NO algorithm-observable state mutation, NO early-
## exit, NO conditional branching beyond the `when defined(...)` gate.
## See `stress-tests/t_unbounded_spmc_awaiting_tail_strand.nim` for the
## test driver that orchestrates these channels.
##
## v2 (multi-consumer race): adds Hook C between the facade's
## `loadSegment` and `tryClaimSlot` calls so the driver can interpose
## C2's fetchAdd between C1's snapshot capture and C1's pre-claim check.
## To keep Hook C scoped to C1 only (so C2's pops do not wedge the
## driver), the hook block tests a thread-local flag
## `c1IsTheTargetThread`. C1's thread proc sets this flag before its
## single pop call; all other threads observe the default `false` and
## bypass the channel pair entirely. The flag is test-driver-owned state,
## never read or written outside hook-gated code, and the
## `when defined(awaitingTailTestHook)` gate elides its declaration in
## production builds — purity rule §7.0 is satisfied.

when defined(awaitingTailTestHook):
  var awaitingTailReachedChan*: Channel[int]
    ## Signalled by the consumer-side Hook A in `unbounded_sipmuc.nim`
    ## immediately upon entering the `awaitingTail=true` branch (before
    ## `extractPinned`). The test driver recv's this to learn that C1
    ## has reached the strand site with its pin still held.

  var awaitingTailGoChan*: Channel[int]
    ## Recv'd by the consumer-side Hook A AFTER its `send` on
    ## `awaitingTailReachedChan`. The test driver sends on this channel
    ## once the producer has published item 2 (slot 1), releasing C1 to
    ## finish its `extractPinned` and break path.

  var producerPublishGoChan*: Channel[int]
    ## Recv'd by the producer-side Hook B in
    ## `typestates/unbounded_spmc_push.nim` immediately before the
    ## release-store on `tail`. The test driver pre-loads one token for
    ## the initial prime publish (slot 0) and sends additional tokens
    ## after observing the consumer's awaitingTail marker, deterministically
    ## ordering each subsequent publish AFTER C1's strand re-check.

  var c1LoadedChan*: Channel[int]
    ## Signalled by Hook C in `unbounded_sipmuc.nim` immediately after C1's
    ## `loadSegment` snapshot is captured and before its `tryClaimSlot`
    ## call. The test driver recv's this to learn that C1's snapshot is
    ## taken; it then runs the C2-role drain to invalidate the snapshot
    ## before releasing C1 to proceed via `c1ProceedChan`.

  var c1ProceedChan*: Channel[int]
    ## Recv'd by Hook C AFTER its `send` on `c1LoadedChan`. The test
    ## driver sends on this channel after running the interposer drain,
    ## releasing C1 to enter `tryClaimSlot` with its now-stale snapshot.

  var c1IsTheTargetThread* {.threadvar.}: bool
    ## Per-thread flag (default false on every thread) gating Hook C.
    ## C1's thread proc sets this `true` before its single `pop()` call;
    ## all other threads (producer, C2, main-thread driver acting as a
    ## consumer) leave it `false` so Hook C is a no-op for them. The
    ## flag is test-driver-owned: never read or written by algorithm
    ## paths, declared inside the `when defined` gate, so production
    ## builds elide it entirely. Purity rule §7.0 explicitly permits
    ## this test-state read.

  proc initAwaitingTailTestHook*() =
    ## Open all five Channels. MUST be called once at the top of the
    ## test driver, before any thread that may touch a hook is spawned.
    awaitingTailReachedChan.open()
    awaitingTailGoChan.open()
    producerPublishGoChan.open()
    c1LoadedChan.open()
    c1ProceedChan.open()

  proc closeAwaitingTailTestHook*() =
    ## Close all five Channels. MUST be called once at the bottom of the
    ## test driver, AFTER all threads have been joined.
    awaitingTailReachedChan.close()
    awaitingTailGoChan.close()
    producerPublishGoChan.close()
    c1LoadedChan.close()
    c1ProceedChan.close()
