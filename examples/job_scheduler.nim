## Job Scheduler Example
##
## Demonstrates using an unbounded Mupmuc (MPMC) queue for a dynamic job
## scheduling system with multiple producers and consumers.
##
## Pattern: Multiple submitters → Job queue → Multiple workers
##
## Key properties:
## - Elastic capacity: queue grows with pending work
## - Lock-free operations: submitters and workers don't block each other
## - Dynamic scaling: workers can be added/removed at runtime
## - Fair scheduling: committed flag ensures FIFO within segments
##
## Use cases:
## - Web server request handling
## - Background job processing (like Sidekiq/Celery)
## - Build system task execution
## - Database query scheduling

import os
import options
import random
import std/monotimes
import strutils
import times

import lockfreequeues

import ./debra_cc_helpers

const
  SegmentSize = 32
  NumSubmitters = 3
  NumWorkers = 4
  JobsPerSubmitter = 50
  MaxThreads = NumSubmitters + NumWorkers + 4  # producers + consumers + main + slack

type
  Priority = enum
    pLow
    pNormal
    pHigh

  Job = object
    id: int
    submitterId: int
    priority: Priority
    workMs: int  # Simulated work duration

  JobQueue = Queue[Job, ccMulti, ccMulti, stEager, SegmentSize,
                   MaxThreads]

  SubmitterContext = object
    queue: ptr JobQueue
    submitterId: int

  WorkerContext = object
    queue: ptr JobQueue
    workerId: int


var
  # `initMultiConsumerManager` (from `./debra_cc_helpers`) walls off the
  # `debra` import so the `ccMulti` token here resolves unambiguously
  # to `lockfreequeues/internal/pinscope_stub.ccMulti` when the Queue
  # type is instantiated below.
  manager = initMultiConsumerManager[MaxThreads]()
  queue = newUnboundedMupmucQueue[Job, stEager, SegmentSize, MaxThreads](addr manager)
  running: Atomic[bool]
  jobsSubmitted: array[NumSubmitters, Atomic[int]]
  jobsCompleted: array[NumWorkers, Atomic[int]]
  nextJobId: Atomic[int]


proc submitterThread(ctx: ptr SubmitterContext) {.thread.} =
  ## Job submitter - creates and enqueues jobs.
  {.cast(gcsafe).}:
    var producer = ctx.queue[].getProducer()
    # Register THIS submitter thread with debra before any push.
    producer.attach()
    var submitted = 0

    for i in 0..<JobsPerSubmitter:
      let jobId = nextJobId.fetchAdd(1, moRelaxed)

      # Varied job characteristics
      let priority = case rand(10)
        of 0: pHigh
        of 1..3: pNormal
        else: pLow

      let workMs = case priority
        of pHigh: rand(1..5)
        of pNormal: rand(5..15)
        of pLow: rand(10..30)

      let job = Job(
        id: jobId,
        submitterId: ctx.submitterId,
        priority: priority,
        workMs: workMs
      )

      producer.push(job)
      inc submitted

      # Variable submission rate
      sleep(rand(1..10))

    jobsSubmitted[ctx.submitterId].store(submitted, moRelease)


proc workerThread(ctx: ptr WorkerContext) {.thread.} =
  ## Worker - fetches and executes jobs.
  {.cast(gcsafe).}:
    var consumer = ctx.queue[].getConsumer()
    # Register THIS worker thread with debra before any pop.
    consumer.attach()
    var completed = 0
    var workTime: int64 = 0

    while running.load(moAcquire) or ctx.queue[].len() > 0:
      let job = consumer.pop()

      if job.isSome:
        let j = job.get

        # Simulate work
        let start = getMonoTime()
        sleep(j.workMs)
        workTime += (getMonoTime() - start).inMilliseconds

        inc completed
      else:
        sleep(1)

    jobsCompleted[ctx.workerId].store(completed, moRelease)
    echo "Worker ", ctx.workerId, " completed ", completed, " jobs (", workTime, "ms work)"


when isMainModule:
  randomize()

  echo "Job Scheduler Example"
  echo "====================="
  echo "Segment size: ", SegmentSize
  echo "Submitters: ", NumSubmitters
  echo "Workers: ", NumWorkers
  echo "Jobs per submitter: ", JobsPerSubmitter
  echo "Total jobs: ", NumSubmitters * JobsPerSubmitter
  echo ""

  running.store(true, moRelease)
  nextJobId.store(0, moRelaxed)
  for i in 0..<NumSubmitters:
    jobsSubmitted[i].store(0, moRelaxed)
  for i in 0..<NumWorkers:
    jobsCompleted[i].store(0, moRelaxed)

  let startTime = getMonoTime()

  # Start workers
  var workerContexts: array[NumWorkers, WorkerContext]
  for i in 0..<NumWorkers:
    workerContexts[i] = WorkerContext(
      queue: addr queue,
      workerId: i,
    )

  var workers: array[NumWorkers, Thread[ptr WorkerContext]]
  for i in 0..<NumWorkers:
    createThread(workers[i], workerThread, addr workerContexts[i])

  # Start submitters
  var submitterContexts: array[NumSubmitters, SubmitterContext]
  for i in 0..<NumSubmitters:
    submitterContexts[i] = SubmitterContext(
      queue: addr queue,
      submitterId: i,
    )

  var submitters: array[NumSubmitters, Thread[ptr SubmitterContext]]
  for i in 0..<NumSubmitters:
    createThread(submitters[i], submitterThread, addr submitterContexts[i])

  # Wait for submitters to finish
  for i in 0..<NumSubmitters:
    joinThread(submitters[i])

  echo "All jobs submitted, waiting for workers..."
  echo ""

  # Signal shutdown and wait for workers
  sleep(100)  # Let workers drain
  running.store(false, moRelease)

  for i in 0..<NumWorkers:
    joinThread(workers[i])

  let totalTime = (getMonoTime() - startTime).inMilliseconds

  # Report results
  echo ""
  echo "Submission summary:"
  var totalSubmitted = 0
  for i in 0..<NumSubmitters:
    let submitted = jobsSubmitted[i].load(moAcquire)
    echo "  Submitter ", i, ": ", submitted, " jobs"
    totalSubmitted += submitted

  echo ""
  echo "Completion summary:"
  var totalCompleted = 0
  for i in 0..<NumWorkers:
    let completed = jobsCompleted[i].load(moAcquire)
    totalCompleted += completed

  echo ""
  echo "Total submitted: ", totalSubmitted
  echo "Total completed: ", totalCompleted
  echo "Queue remaining: ", queue.len()
  echo "Segments used: ", queue.segmentCount()
  echo "Total time: ", totalTime, "ms"

  if totalSubmitted == totalCompleted:
    echo ""
    echo "All jobs completed successfully!"
