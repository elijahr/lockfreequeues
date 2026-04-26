## Event Collector Example
##
## Demonstrates using an unbounded Mupsic (MPSC) queue for collecting events
## from multiple sources into a single processing pipeline.
##
## Pattern: Multiple event sources → Single processor
##
## Key properties:
## - Handles bursts: queue grows during traffic spikes
## - Never drops: events are queued even during overload
## - Memory reclamation: epoch-based cleanup when safe
## - Lock-free producers: sources don't block each other
##
## Use cases:
## - Log aggregation from multiple services
## - Metrics collection from distributed sensors
## - Network packet capture from multiple interfaces
## - User activity tracking across browser tabs

import lockfreequeues/atomic_dsl
import os
import options
import random
import std/monotimes
import times

import debra
import lockfreequeues

const
  SegmentSize = 64
  NumSources = 4
  DurationMs = 200
  MaxThreads = NumSources + 4  # sources + main/consumer + slack

type
  EventKind = enum
    ekClick
    ekPageView
    ekError
    ekMetric

  Event = object
    sourceId: int
    kind: EventKind
    timestamp: int64
    value: int

  SourceContext = object
    queue: ptr UnboundedMupsic[SegmentSize, Event, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    sourceId: int
    startTime: MonoTime

  ProcessorContext = object
    queue: ptr UnboundedMupsic[SegmentSize, Event, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    consumerHandle: ThreadHandle[MaxThreads]

var
  manager = initDebraManager[MaxThreads]()
  consumerHandle = registerThread(manager)
  queue = newUnboundedMupsic[SegmentSize, Event, MaxThreads](addr manager, consumerHandle)
  running: Atomic[bool]
  eventsProduced: array[NumSources, Atomic[int]]
  eventsConsumed: Atomic[int]
  maxQueueDepth: Atomic[int]


proc eventSourceThread(ctx: ptr SourceContext) {.thread.} =
  ## Simulates an event source generating events at variable rates.
  ## Sources occasionally burst to simulate real traffic patterns.
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var producer = ctx.queue[].getProducer(handle)
    var produced = 0

    while running.load(moAcquire):
      # Simulate variable event rate with occasional bursts
      let burstMode = rand(100) < 10  # 10% chance of burst
      let eventCount = if burstMode: rand(10..20) else: rand(1..3)

      for _ in 0..<eventCount:
        let event = Event(
          sourceId: ctx.sourceId,
          kind: EventKind(rand(ord(EventKind.high))),
          timestamp: (getMonoTime() - ctx.startTime).inMicroseconds,
          value: rand(1000)
        )

        producer.push(event)
        inc produced

      # Variable delay between event batches
      let delayMs = if burstMode: 1 else: rand(5..15)
      sleep(delayMs)

    eventsProduced[ctx.sourceId].store(produced, moRelease)


proc processorThread(ctx: ptr ProcessorContext) {.thread.} =
  ## Single processor consumes and processes all events.
  ## Periodically triggers memory reclamation.
  {.cast(gcsafe).}:
    var consumed = 0
    var maxDepth = 0
    var lastReclaim = getMonoTime()
    var eventCounts: array[EventKind, int]

    while running.load(moAcquire) or ctx.queue[].len() > 0:
      let event = ctx.queue[].pop()

      if event.isSome:
        # Process the event
        inc eventCounts[event.get.kind]
        inc consumed

        # Track queue depth
        let depth = ctx.queue[].len()
        if depth > maxDepth:
          maxDepth = depth

        # Periodic memory reclamation (every 10ms)
        if (getMonoTime() - lastReclaim).inMilliseconds > 10:
          ctx.manager[].advance()
          discard reclaimNow(ctx.consumerHandle)
          lastReclaim = getMonoTime()
      else:
        # No events, brief pause
        sleep(1)

    eventsConsumed.store(consumed, moRelease)
    maxQueueDepth.store(maxDepth, moRelease)

    echo ""
    echo "Event breakdown:"
    for kind in EventKind:
      echo "  ", kind, ": ", eventCounts[kind]


when isMainModule:
  randomize()

  echo "Event Collector Example"
  echo "======================="
  echo "Segment size: ", SegmentSize
  echo "Event sources: ", NumSources
  echo "Duration: ", DurationMs, "ms"
  echo ""

  running.store(true, moRelease)
  eventsConsumed.store(0, moRelaxed)
  maxQueueDepth.store(0, moRelaxed)
  for i in 0..<NumSources:
    eventsProduced[i].store(0, moRelaxed)

  let startTime = getMonoTime()

  # Start processor
  var procCtx = ProcessorContext(
    queue: addr queue,
    manager: addr manager,
    consumerHandle: consumerHandle,
  )
  var processor: Thread[ptr ProcessorContext]
  createThread(processor, processorThread, addr procCtx)

  # Start event sources
  var sourceContexts: array[NumSources, SourceContext]
  for i in 0..<NumSources:
    sourceContexts[i] = SourceContext(
      queue: addr queue,
      manager: addr manager,
      sourceId: i,
      startTime: startTime,
    )

  var sources: array[NumSources, Thread[ptr SourceContext]]
  for i in 0..<NumSources:
    createThread(sources[i], eventSourceThread, addr sourceContexts[i])

  # Run for specified duration
  sleep(DurationMs)
  running.store(false, moRelease)

  # Wait for completion
  for i in 0..<NumSources:
    joinThread(sources[i])
  sleep(50)  # Let processor drain
  joinThread(processor)

  let totalTime = (getMonoTime() - startTime).inMilliseconds

  # Report results
  echo ""
  echo "Results:"
  var totalProduced = 0
  for i in 0..<NumSources:
    let produced = eventsProduced[i].load(moAcquire)
    echo "  Source ", i, ": ", produced, " events"
    totalProduced += produced

  let consumed = eventsConsumed.load(moAcquire)
  let maxDepth = maxQueueDepth.load(moAcquire)

  echo ""
  echo "Total produced: ", totalProduced
  echo "Total consumed: ", consumed
  echo "Max queue depth: ", maxDepth
  echo "Final segments: ", queue.segmentCount()
  echo "Total time: ", totalTime, "ms"
  echo "Throughput: ", (consumed * 1000) div max(1, totalTime.int), " events/sec"

  if totalProduced == consumed:
    echo ""
    echo "All events processed - no data loss!"
