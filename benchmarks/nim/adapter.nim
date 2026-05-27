## Queue adapter interface for benchmarking.
## Each queue implementation must provide these operations.
##
## PR 1 Task 1.2 — `PushResult` / `PopResult` are now re-exported
## aliases of the canonical types defined in `bench_common`. PR 0 Task 0.1
## introduced parallel definitions in bench_common, leaving two nominally
## distinct enums. With both adapter packs (legacy spsc / mpmc /
## channels and the newer spmc / mpsc / unbounded_*) flowing through
## the same `bench_common.runLatencyHarness` / `runThroughputHarness`,
## the two-enum split forced cross-conversion at every call site. Aliasing
## here unifies the surface: `prSuccess` / `prFull` are now equal regardless
## of which module supplied them, and downstream code keeps working
## unchanged because the legacy import path still resolves both names.

import ./bench_common
# Re-export the canonical types/enum members from bench_common. Exporting
# the enum type re-exports its members; individual enum field exports are
# rejected by the Nim compiler.
export bench_common.PushResult, bench_common.PopResult

type
  ## Generic queue adapter trait
  QueueAdapter*[T] = concept q
    q.push(T) is PushResult
    q.pop() is PopResult[T]
    q.name is string

proc newPopResult*[T](value: T): PopResult[T] =
  PopResult[T](success: true, value: value)

proc emptyPopResult*[T](): PopResult[T] =
  PopResult[T](success: false)
