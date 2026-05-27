## Task Fan-Out Example
##
## Demonstrates using a bounded Spmc (SPMC) queue for distributing work
## from a single producer to multiple consumer workers.
##
## Pattern: Single dispatcher → Multiple workers
##
## Key properties:
## - Work-stealing: consumers compete for tasks via CAS
## - Load balancing: faster workers naturally get more tasks
## - Bounded memory: fixed queue size provides backpressure
## - Wait-free push: dispatcher never blocks
##
## Use cases:
## - HTTP request routing to worker pool
## - Image processing pipeline
## - Game engine job distribution

import debra/atomics
import debra/atomics/dsl
import os
import options
import std/monotimes
import times

import lockfreequeues

const
  QueueCapacity = 128
  NumWorkers = 4
  NumTasks = 1000

type
  TaskKind = enum
    tkCompute    # CPU-bound work
    tkIO         # Simulated I/O
    tkFast       # Quick task

  Task = object
    id: int
    kind: TaskKind
    payload: int

var
  q = newSpmcQueue[Task, QueueCapacity, NumWorkers]()
  done: Atomic[bool]
  tasksCompleted: array[NumWorkers, Atomic[int]]
  totalLatency: array[NumWorkers, Atomic[int64]]


proc simulateWork(task: Task) =
  ## Simulate different types of work
  case task.kind
  of tkCompute:
    # Simulate CPU work with busy loop
    var sum = 0
    for i in 0..<task.payload:
      sum += i
    discard sum
  of tkIO:
    # Simulate I/O wait
    sleep(task.payload)
  of tkFast:
    # Minimal work
    discard


proc workerThread(idx: int) {.thread.} =
  ## Worker consumes tasks from the queue until shutdown.
  let consumer = q.getConsumer(idx)
  var completed = 0
  var latencySum: int64 = 0

  while true:
    let task = consumer.pop()

    if task.isSome:
      let start = getMonoTime()
      simulateWork(task.get)
      let elapsed = (getMonoTime() - start).inMicroseconds
      latencySum += elapsed
      inc completed
    elif done.load(moAcquire):
      break
    else:
      # No work available, brief pause before retry
      sleep(0)

  tasksCompleted[idx].store(completed, moRelease)
  totalLatency[idx].store(latencySum, moRelease)


proc dispatcherThread() {.thread.} =
  ## Dispatcher generates and distributes tasks.
  var taskId = 0

  for i in 0..<NumTasks:
    # Create varied task mix
    let kind = case i mod 10
      of 0..2: tkFast
      of 3..6: tkCompute
      else: tkIO

    let payload = case kind
      of tkFast: 0
      of tkCompute: 1000 + (i mod 500)
      of tkIO: 1 + (i mod 3)

    let task = Task(id: taskId, kind: kind, payload: payload)
    inc taskId

    # Push with backpressure - wait if queue is full
    while not q.push(task):
      sleep(0)

  done.store(true, moRelease)


when isMainModule:
  echo "Task Fan-Out Example"
  echo "===================="
  echo "Queue capacity: ", QueueCapacity
  echo "Workers: ", NumWorkers
  echo "Tasks: ", NumTasks
  echo ""

  done.store(false, moRelaxed)
  for i in 0..<NumWorkers:
    tasksCompleted[i].store(0, moRelaxed)
    totalLatency[i].store(0, moRelaxed)

  let startTime = getMonoTime()

  # Start workers
  var workers: array[NumWorkers, Thread[int]]
  for i in 0..<NumWorkers:
    createThread(workers[i], workerThread, i)

  # Start dispatcher
  var dispatcher: Thread[void]
  createThread(dispatcher, dispatcherThread)

  # Wait for completion
  joinThread(dispatcher)
  sleep(50)  # Let workers drain queue
  for i in 0..<NumWorkers:
    joinThread(workers[i])

  let totalTime = (getMonoTime() - startTime).inMilliseconds

  # Report results
  echo "Results:"
  var totalCompleted = 0
  for i in 0..<NumWorkers:
    let completed = tasksCompleted[i].load(moAcquire)
    let latency = totalLatency[i].load(moAcquire)
    let avgLatency = if completed > 0: latency div completed else: 0
    echo "  Worker ", i, ": ", completed, " tasks, avg ", avgLatency, "us/task"
    totalCompleted += completed

  echo ""
  echo "Total completed: ", totalCompleted, "/", NumTasks
  echo "Total time: ", totalTime, "ms"
  echo "Throughput: ", (NumTasks * 1000) div max(1, totalTime.int), " tasks/sec"

  if totalCompleted == NumTasks:
    echo ""
    echo "All tasks processed successfully!"
