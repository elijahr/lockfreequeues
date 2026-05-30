## Event Collector Example — v5.0.0 static-affinity endpoint API.
##
## Multi-producer event sources feed a single-consumer processor via an
## unbounded MPSC queue. Each producer thread calls `getProducerHere()`
## on its own thread (sugar for `getProducer().bindToThread()`,
## debra-registers per-thread). The single consumer uses
## `bindConsumer()` (the v5.0.0 replacement for `attachConsumer`).

import os
import options
import random
import std/monotimes
import debra/atomics
import times

import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags

from debra import DebraManager, initDebraManager

const
  SegmentSize = 64
  NumSources = 4
  DurationMs = 200
  MaxThreads = NumSources + 4

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

  QueueT =
    Queue[Event, ccMulti, ccSingle, stEager, SegmentSize, MaxThreads]

  SourceContext = object
    queue: ptr QueueT
    sourceId: int
    startTime: MonoTime

  ProcessorContext = object
    queue: ptr QueueT

var
  manager = initDebraManager[MaxThreads]()
  queue = newUnboundedMpscQueue[Event, stEager, SegmentSize, MaxThreads](
    addr manager
  )
  running: Atomic[bool]
  eventsProduced: array[NumSources, Atomic[int]]
  eventsConsumed: Atomic[int]
  maxQueueDepth: Atomic[int]

proc eventSourceThread(ctx: ptr SourceContext) {.thread.} =
  {.cast(gcsafe).}:
    # v5.0.0: getProducerHere binds this thread's debra handle on entry.
    var producer = ctx.queue[].getProducerHere()
    var produced = 0
    while running.load(moAcquire):
      let burstMode = rand(100) < 10
      let eventCount =
        if burstMode:
          rand(10 .. 20)
        else:
          rand(1 .. 3)
      for _ in 0 ..< eventCount:
        let event = Event(
          sourceId: ctx.sourceId,
          kind: EventKind(rand(ord(EventKind.high))),
          timestamp: (getMonoTime() - ctx.startTime).inMicroseconds,
          value: rand(1000),
        )
        producer.push(event)
        inc produced
      let delayMs =
        if burstMode:
          1
        else:
          rand(5 .. 15)
      sleep(delayMs)
    eventsProduced[ctx.sourceId].store(produced, moRelease)

proc processorThread(ctx: ptr ProcessorContext) {.thread.} =
  {.cast(gcsafe).}:
    # v5.0.0: bindConsumer is the one-shot wrapper that replaces v4.x
    # attachConsumer. Single-consumer cardinality registers exactly
    # one debra handle on the consuming thread.
    var consumer = ctx.queue[].bindConsumer()
    var consumed = 0
    var maxDepth = 0
    var eventCounts: array[EventKind, int]
    while running.load(moAcquire) or ctx.queue[].len() > 0:
      let event = consumer.pop()
      if event.isSome:
        inc eventCounts[event.get.kind]
        inc consumed
        let depth = ctx.queue[].len()
        if depth > maxDepth:
          maxDepth = depth
      else:
        sleep(1)
    eventsConsumed.store(consumed, moRelease)
    maxQueueDepth.store(maxDepth, moRelease)
    echo ""
    echo "Event breakdown:"
    for kind in EventKind:
      echo "  ", kind, ": ", eventCounts[kind]

when isMainModule:
  randomize()
  echo "Event Collector Example (v5.0.0 static-affinity API)"
  echo "===================================================="
  echo "Segment size: ", SegmentSize
  echo "Event sources: ", NumSources
  echo "Duration: ", DurationMs, "ms"
  echo ""
  running.store(true, moRelease)
  eventsConsumed.store(0, moRelaxed)
  maxQueueDepth.store(0, moRelaxed)
  for i in 0 ..< NumSources:
    eventsProduced[i].store(0, moRelaxed)
  let startTime = getMonoTime()
  var procCtx = ProcessorContext(queue: addr queue)
  var processor: Thread[ptr ProcessorContext]
  createThread(processor, processorThread, addr procCtx)
  var sourceContexts: array[NumSources, SourceContext]
  for i in 0 ..< NumSources:
    sourceContexts[i] =
      SourceContext(queue: addr queue, sourceId: i, startTime: startTime)
  var sources: array[NumSources, Thread[ptr SourceContext]]
  for i in 0 ..< NumSources:
    createThread(sources[i], eventSourceThread, addr sourceContexts[i])
  sleep(DurationMs)
  running.store(false, moRelease)
  for i in 0 ..< NumSources:
    joinThread(sources[i])
  sleep(50)
  joinThread(processor)
  let totalTime = (getMonoTime() - startTime).inMilliseconds
  echo ""
  echo "Results:"
  var totalProduced = 0
  for i in 0 ..< NumSources:
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
  echo "Throughput: ",
    (consumed * 1000) div max(1, totalTime.int), " events/sec"
  if totalProduced == consumed:
    echo ""
    echo "All events processed - no data loss!"
