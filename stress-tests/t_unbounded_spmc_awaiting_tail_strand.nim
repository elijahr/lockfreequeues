## Deterministic regression test for the awaitingTail-strand item-loss
## bug at HEAD `bd0af1d` (feat/v4.2.0-bench-tightening), v2 mechanism.
##
## This test FAILS at HEAD with `STRAND_TEST_ITEM_LOSS:`-prefixed
## assertions (demonstrating the bug) and is expected to PASS after Task
## 11 (LCRQ cellState) lands.
##
## Mechanism (per design brief v2 §1.3 - §1.4):
##   1. Producer P publishes item 1 to slot 0 of seg1 (S=2). Hook B
##      gates each publish on producerPublishGoChan.
##   2. C1 (target thread) calls pop(); `loadSegment` captures
##      snapshot `tail=1, consumerHead=0`. Hook C signals
##      c1LoadedChan and blocks on c1ProceedChan.
##   3. C2 (interposer) pops slot 0 of seg1 via fetchAdd
##      (consumerHead -> 1) and drains item 1. C2 bypasses Hook C
##      because c1IsTheTargetThread is false on its thread.
##   4. Driver sends c1ProceedChan; C1 enters tryClaimSlot with its
##      stale snapshot. Pre-claim short-circuit (loaded.consumerHead=0
##      < loaded.tail=1) is bypassed. C1's fetchAdd returns mySlot=1;
##      close-CAS on cellState[1] (still CellEmpty because Hook B holds
##      the producer between data-write and publish-CAS) WINS -> emits
##      USPMCPopClosedSlot -> Hook A fires.
##   5. Driver releases producer's slot-1 publish (token 2). Under
##      post-Task-11 LCRQ cellState, C1's close-CAS already won -> the
##      producer's publish-CAS on seg1 slot 1 FAILS (cellState=CellClosed),
##      recovery restores pending=seq2, the facade escalates SegmentClosed
##      -> allocateNewSegment(seg2) -> writeItem RETRY on seg2 slot 0.
##      Token 3 releases that retry (pending=seq2 lands at seg2 slot 0).
##      Token 4 releases the producer's third push(seq3) on seg2 slot 1.
##      Then releases C1 via awaitingTailGoChan to break out.
##   6. Under post-Task-11 LCRQ cellState, C1's close-CAS wins -> ClosedSlot
##      -> seq 2 has NOT yet been published; producer's publish-CAS will
##      FAIL (cellState=CellClosed), recovery restores pending=seq2,
##      escalates SegmentClosed, allocates seg2, retries writeItem on
##      seg2 slot 0 -> pending=seq2 lands there. Producer's third
##      push(seq3) writes seg2 slot 1. C3 (main thread) drains seg2:
##      seq 2 from slot 0, seq 3 from slot 1. received[1]==true,
##      received[2]==true, totalConsumed==3.
##
## Determinism is established by stdlib `Channel[T]` send/recv across
## five channels (Hook A pair, Hook B, Hook C pair). The thread-local
## c1IsTheTargetThread gate scopes Hook C to C1 only.
##
## A watchdog thread provides the liveness guard. If the test wedges
## (Hook A, Hook B, or Hook C bypassed by some unintended algorithm
## path), the watchdog emits a `STRAND_TEST_HANG:` message and exits
## non-zero.
##
## CLI: `direnv exec . nimble strandRegression` (or `nimble stresstests`,
## which invokes it as part of the bundle).
##
## See:
##   - design brief: docs/Users-eek-Development-lockfreequeues/plans/
##     2026-05-13-v4.3-task-11-task17-design.md (v2)
##   - hooks: src/lockfreequeues/private/awaiting_tail_test_hook.nim

import options
import unittest2

import std/os

import debra
import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_sipmuc
import lockfreequeues/private/awaiting_tail_test_hook

const
  S = 2
  MaxThreads = 4

# Item encoding mirrors tests/t_unbounded_sipmuc_threaded_stress.nim:51-58.
# producerId in the high 32 bits, seq in the low 32 bits. seq is 1-indexed
# so 0 cannot alias an uninitialised slot.
proc encodeItem(producerId: int, seq: int): int =
  result = ((producerId.uint64 shl 32) or seq.uint64).int

proc decodeSeq(item: int): int =
  result = int(item.uint64 and 0xFFFFFFFF'u64)

type
  ProducerCtx = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]

  C1Ctx = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    totalConsumed: ptr Atomic[int]
    received: ptr array[3, Atomic[bool]]
    c1Done: ptr Atomic[bool]

  C2Ctx = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    totalConsumed: ptr Atomic[int]
    received: ptr array[3, Atomic[bool]]
    c2Done: ptr Atomic[bool]

  WatchdogCtx = object
    done: ptr Atomic[bool]

proc producerThreadProc(ctx: ptr ProducerCtx) {.thread.} =
  {.cast(gcsafe).}:
    # Three push() calls, FOUR writeItem invocations under LCRQ semantics.
    # Each writeItem call in unbounded_spmc_push.nim's Hook B blocks on
    # producerPublishGoChan.recv() between data-write and publish-CAS.
    #   - writeItem(seq1) on seg1 slot 0 — consumes token 1 (Phase 0 pre-load);
    #     publish-CAS WINS (cellState=CellEmpty -> CellFilled).
    #   - writeItem(seq2) on seg1 slot 1 — consumes token 2 (Phase 7); under
    #     post-Task-11 LCRQ, C1's close-CAS has already flipped cellState[1]
    #     to CellClosed, so this publish-CAS FAILS. The pop()-side recovery
    #     restores pending=seq2 and the facade escalates SegmentClosed ->
    #     allocateNewSegment(seg2) -> seg1.next.store(seg2, moRelease) ->
    #     writeItem RETRY.
    #   - writeItem(seq2) RETRY on seg2 slot 0 — consumes token 3 (Phase 8
    #     first send); publish-CAS WINS; pending=seq2 lands at seg2 slot 0.
    #   - writeItem(seq3) on seg2 slot 1 — consumes token 4 (Phase 8 second
    #     send); publish-CAS WINS.
    ctx.queue[].push(encodeItem(0, 1))
    ctx.queue[].push(encodeItem(0, 2))
    ctx.queue[].push(encodeItem(0, 3))

proc c1ThreadProc(ctx: ptr C1Ctx) {.thread.} =
  {.cast(gcsafe).}:
    # Mark this thread as Hook C's target. Hook C engages its
    # Channel.send/recv pair ONLY on threads where this flag is true.
    # Without this, every consumer's every pop call would wedge the
    # driver on c1LoadedChan. The threadvar lives only under
    # `-d:awaitingTailTestHook`; gate the write site to match so the
    # test driver still compiles cleanly under no-define builds (used
    # to verify the production library has no leaked hook code).
    when defined(awaitingTailTestHook):
      c1IsTheTargetThread = true
    let handle = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(handle)
    # One pop() call. Under HEAD bd0af1d this lands in awaitingTail=true
    # (Hook A fires) and returns none(T). Under post-Task-11 cellState it
    # may either close its claim and return none(T), OR observe a
    # CellFilled and drain — either is correct provided seq 2 is
    # eventually drained by SOME consumer.
    let item = c.pop()
    if item.isSome:
      let s = decodeSeq(item.get)
      if s >= 1 and s <= 3:
        if not ctx.received[s - 1].exchange(true, moRelaxed):
          discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
    ctx.c1Done[].store(true, moRelease)

proc c2ThreadProc(ctx: ptr C2Ctx) {.thread.} =
  {.cast(gcsafe).}:
    # C2 leaves c1IsTheTargetThread = false (default per threadvar
    # semantics), so Hook C is a no-op for this thread. C2 drains slot 0
    # of seg1 (seq 1) deterministically because the driver only spawns
    # this thread after C1 has parked in Hook C — C1's snapshot was
    # captured BEFORE C2's fetchAdd runs.
    let handle = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(handle)
    let item = c.pop()
    if item.isSome:
      let s = decodeSeq(item.get)
      if s >= 1 and s <= 3:
        if not ctx.received[s - 1].exchange(true, moRelaxed):
          discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
    ctx.c2Done[].store(true, moRelease)

proc watchdogThreadProc(ctx: ptr WatchdogCtx) {.thread.} =
  {.cast(gcsafe).}:
    # Liveness guard. 8s budget (80 × 100ms). If `done` is not set in
    # time, the strand pre-conditions weren't reached — emit a HANG
    # message with the grep-able prefix and exit non-zero. The
    # STRAND_TEST_HANG prefix is distinct from STRAND_TEST_ITEM_LOSS so
    # post-Task-11 audits can tell which failure mode fired.
    for _ in 0 ..< 80:
      sleep(100)
      if ctx.done[].load(moAcquire):
        return
    stderr.writeLine(
      "STRAND_TEST_HANG: timed out waiting for consumer/producer thread; " &
        "hook sites may not have been reached — strand not exercised"
    )
    stderr.flushFile()
    quit(QuitFailure)

suite "UnboundedSipmuc awaitingTail-strand regression":
  test "slot 1 must not be orphaned when C1 strands on awaitingTail":
    initAwaitingTailTestHook()

    var
      totalConsumed: Atomic[int]
      received: array[3, Atomic[bool]]
      c1Done: Atomic[bool]
      c2Done: Atomic[bool]
      watchdogDone: Atomic[bool]

    totalConsumed.store(0, moRelaxed)
    received[0].store(false, moRelaxed)
    received[1].store(false, moRelaxed)
    received[2].store(false, moRelaxed)
    c1Done.store(false, moRelaxed)
    c2Done.store(false, moRelaxed)
    watchdogDone.store(false, moRelaxed)

    # Watchdog FIRST so it covers all subsequent blocking operations.
    var watchdogCtx = WatchdogCtx(done: addr watchdogDone)
    var watchdogThread: Thread[ptr WatchdogCtx]
    createThread(watchdogThread, watchdogThreadProc, addr watchdogCtx)

    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedSipmuc[S, int, MaxThreads](addr manager)

    # Register main-thread (acts as driver + C3-role end-drain consumer)
    # BEFORE the producer publishes anything, so its consumer index is
    # stable.
    let mainHandle = registerThread(manager)
    var c3 = queue.getConsumer(mainHandle)

    # Phase 0 — pre-load producer token 1 for slot 0 of seg1.
    producerPublishGoChan.send(1)

    # Phase 1 — spawn producer. Producer's first writeItem consumes
    # token 1 and stores tail=1 (slot 0 published). Its second writeItem
    # writes data[1] and blocks on producerPublishGoChan.recv() (no
    # token 2 yet).
    var prodCtx = ProducerCtx(queue: addr queue)
    var prodThread: Thread[ptr ProducerCtx]
    createThread(prodThread, producerThreadProc, addr prodCtx)

    # Phase 2 — spawn C1 (target). C1 sets c1IsTheTargetThread=true,
    # calls pop(). loadSegment captures {tail=1, consumerHead=0}. Hook
    # C fires: c1LoadedChan.send(1); blocks on c1ProceedChan.recv().
    var c1Ctx = C1Ctx(
      queue: addr queue,
      manager: addr manager,
      totalConsumed: addr totalConsumed,
      received: addr received,
      c1Done: addr c1Done,
    )
    var c1Thread: Thread[ptr C1Ctx]
    createThread(c1Thread, c1ThreadProc, addr c1Ctx)

    # Phase 3 — wait for C1's Hook C signal. Blocking recv — watchdog
    # covers it.
    discard c1LoadedChan.recv()

    # Phase 4 — spawn C2 (interposer). C2 drains slot 0 of seg1: its
    # loadSegment captures {tail=1, consumerHead=0}, short-circuit
    # bypassed (0 < 1), fetchAdd returns mySlot=0 (consumerHead -> 1),
    # post-claim re-check passes (0 < 1), readItem returns seq 1.
    var c2Ctx = C2Ctx(
      queue: addr queue,
      manager: addr manager,
      totalConsumed: addr totalConsumed,
      received: addr received,
      c2Done: addr c2Done,
    )
    var c2Thread: Thread[ptr C2Ctx]
    createThread(c2Thread, c2ThreadProc, addr c2Ctx)

    # Wait for C2 to finish its single pop before releasing C1. Join
    # C2 here so the join's release/acquire pair guarantees C2's
    # consumerHead fetchAdd is globally visible before C1 resumes.
    joinThread(c2Thread)

    # Phase 5 — release C1 to enter tryClaimSlot with stale snapshot.
    # C1's snapshot still has {tail=1, consumerHead=0}. L187 pre-claim:
    # 0 < 1, skip. L203 fetchAdd -> mySlot=1 (consumerHead -> 2). L207:
    # 1 < 2 (S), skip. L223 post-claim: 1 >= seg.tail.load(=1) ->
    # awaitingTail=true. Hook A fires.
    c1ProceedChan.send(1)

    # Phase 6 — wait for C1's Hook A signal.
    discard awaitingTailReachedChan.recv()

    # Phase 7 — release producer's seg1 slot-1 publish attempt (token 2).
    # Under post-Task-11 LCRQ cellState, C1's close-CAS has already
    # flipped cellState[1] to CellClosed. Producer's publish-CAS therefore
    # FAILS: writeItem returns SegmentClosed, recovery restores
    # pending=seq2, the facade escalates -> allocateNewSegment(seg2) ->
    # seg1.next.store(seg2, moRelease) -> writeItem RETRY on seg2 slot 0.
    # The retry writes data[0]=seq2 and blocks on producerPublishGoChan.recv().
    producerPublishGoChan.send(1)

    # Phase 8 — release producer's seg2 slot-0 publish RETRY (token 3).
    # writeItem(seq2) on seg2 slot 0 succeeds (publish-CAS wins).
    # push(seq2) returns. Producer's next push(seq3) writes data[1]=seq3
    # on seg2 slot 1 and blocks on producerPublishGoChan.recv().
    producerPublishGoChan.send(1)

    # Phase 8b — release producer's seg2 slot-1 publish (token 4).
    # writeItem(seq3) on seg2 slot 1 succeeds, producer exits push loop,
    # returns. Join.
    producerPublishGoChan.send(1)
    joinThread(prodThread)

    # Phase 9 — release C1 to finish extractPinned + break path.
    awaitingTailGoChan.send(1)
    joinThread(c1Thread)

    # Phase 10 — main thread (C3-role) drains remaining items. Under
    # HEAD bd0af1d, c3.pop() returns seq 3 from seg2 slot 0 after the
    # CAS-advance retires seg1 (orphaning seg1 slot 1's seq 2). Under
    # post-Task-11, seq 2 surfaces somewhere (either C1, or via cellState
    # before retirement). Loop twice in case post-Task-11 surfaces seq 2
    # here too.
    for _ in 0 ..< 2:
      let item = c3.pop()
      if item.isSome:
        let s = decodeSeq(item.get)
        if s >= 1 and s <= 3:
          if not received[s - 1].exchange(true, moRelaxed):
            discard totalConsumed.fetchAdd(1, moRelaxed)

    # Signal the watchdog we're done BEFORE the assertion checks so a
    # delayed quit doesn't race with unittest2's normal failure path.
    watchdogDone.store(true, moRelease)
    joinThread(watchdogThread)

    # Assertions per design brief v2 §5.3.
    # ITEM-LOSS mode (must FAIL at HEAD bd0af1d, must PASS post-Task-11).
    # `unittest2.check` is a single-arg macro; failure diagnostics carry
    # `STRAND_TEST_ITEM_LOSS:`-prefixed strings via `checkpoint` calls
    # printed just before the failing `check`. The prefix is the
    # grep-able anchor required by design brief §5.3.
    check(received[0].load(moRelaxed))         # seq 1 — drained by C2 in phase 4
    if not received[1].load(moRelaxed):
      checkpoint(
        "STRAND_TEST_ITEM_LOSS: seq 2 (seg1 slot 1) was orphaned (awaitingTail strand)"
      )
    check(received[1].load(moRelaxed))
    check(received[2].load(moRelaxed))         # seq 3 — drained in phase 10
    if totalConsumed.load(moRelaxed) != 3:
      checkpoint(
        "STRAND_TEST_ITEM_LOSS: totalConsumed != 3 (expected 3, got " &
          $totalConsumed.load(moRelaxed) & ")"
      )
    check(totalConsumed.load(moRelaxed) == 3)

    closeAwaitingTailTestHook()
