## Thread-spawn helpers for the v5.0.0 endpoint API — 2-step API.
##
## ### Why 2-step instead of single-call macro
##
## Plan originally specified single-call macros `spawnBoundProducer(q): body`.
## Nim 2.2.10 codegen issue: `{.thread, nimcall, gcsafe.}` procs emitted by
## macros OR templates inside a block/proc context are silently downgraded to
## closures, then `createThread` calls into invalid memory at thread entry
## (no stack trace, body-independent segfault). Hand-rolled module-scope
## thread procs work correctly.
##
## The 2-step API makes the module-scope constraint EXPLICIT.
## `defineProducerWorker(WorkerName, queueType, body)` is a DECLARATION that
## MUST live at module scope (like `proc`/`type`). `spawnDefined(WorkerName,
## queue)` at the call site spawns the pre-defined worker.
##
## **MUST be invoked at module scope.** Inside a proc body, the emitted
## `{.thread, nimcall.}` worker is silently downgraded to a closure (Nim
## 2.2.10 codegen issue), causing runtime segfaults. There is no compile-
## time guard in v5.0.0; convention-enforced via doc-comments.
##
## ### Usage
##
## ```nim
## import std/atomics
## import lockfreequeues/[bqueue, endpoint, role_tags, spawn]
##
## # MUST be at module scope:
## defineProducerWorker(MyProducer, BQueue[int, ccMulti, ccMulti, 64, 4, 4]):
##   for i in 0 ..< 10:
##     discard producer.push(i)
##
## proc main() =
##   var q = initBQueue[int, ccMulti, ccMulti, 64, 4, 4]()
##   var thr = spawnDefined(MyProducer, q)
##   joinThread(thr)
##
## main()
## ```

{.experimental: "strictEffects".}

import std/macros
import std/typedthreads

import ./endpoint_types
import ./endpoint
import ./role_tags
import ./internal/typestates_dsl

export typedthreads

macro defineProducerWorker*(workerName, queueType, body: untyped): untyped =
  ## Declare a producer worker proc with the given name. `queueType` is the
  ## full queue type. `producer` is injected into `body`'s scope as
  ## `Bound[T, MpmcProducerTag, queueType]`.
  ## **MUST be invoked at module scope.**
  let workArgIdent = ident($workerName & "Arg")
  let producerSym = ident("producer")
  result = quote do:
    type `workArgIdent`* = Unbound[
      typeof(`queueType`).T, MpmcProducerTag, `queueType`
    ]
    proc `workerName`*(
        arg: `workArgIdent`
    ) {.thread, nimcall, tags: [MpmcProducerTag, TypestateOp, RootEffect], gcsafe.} =
      var u = arg
      var `producerSym` {.inject.} = u.bindToThread()
      `body`
    # Compile-time module-scope guard: `export` is rejected by Nim outside
    # top-level scope (`Error: 'export' is only allowed at top level`).
    # The emitted thread proc is silently downgraded to a closure in
    # nested scope (Nim 2.2.10 codegen issue) causing runtime segfault
    # at createThread; the export-as-scope-probe trips a clear compile-
    # time error before that misuse can ship.
    export `workerName`

macro defineConsumerWorker*(workerName, queueType, body: untyped): untyped =
  ## Symmetric: declare a consumer worker. `consumer` is injected as
  ## `Bound[T, MpmcConsumerTag, queueType]`. MUST be at module scope.
  let workArgIdent = ident($workerName & "Arg")
  let consumerSym = ident("consumer")
  result = quote do:
    type `workArgIdent`* = Unbound[
      typeof(`queueType`).T, MpmcConsumerTag, `queueType`
    ]
    proc `workerName`*(
        arg: `workArgIdent`
    ) {.thread, nimcall, tags: [MpmcConsumerTag, TypestateOp, RootEffect], gcsafe.} =
      var u = arg
      var `consumerSym` {.inject.} = u.bindToThread()
      `body`
    export `workerName`

proc spawnDefinedProducerImpl*[ArgT](
    workerProc: proc(arg: ArgT) {.thread, nimcall, gcsafe.}, tagged: ArgT
): Thread[ArgT] =
  ## Internal helper (proc, not template) — invokes createThread at
  ## proc-call scope. Avoiding template/block wrappers around
  ## createThread sidesteps Nim 2.2.10 codegen issue.
  createThread(result, workerProc, tagged)

template spawnDefinedProducer*(workerProc: untyped, q: untyped): untyped =
  ## Spawn a producer worker declared via `defineProducerWorker`. Returns
  ## the `Thread[…]` handle.
  let u_lfq_spawn = q.getProducer()
  type ArgT_lfq_spawn = `workerProc Arg`
  spawnDefinedProducerImpl[ArgT_lfq_spawn](
    workerProc,
    ArgT_lfq_spawn(queue: u_lfq_spawn.queue, idx: u_lfq_spawn.idx),
  )

proc spawnDefinedConsumerImpl*[ArgT](
    workerProc: proc(arg: ArgT) {.thread, nimcall, gcsafe.}, tagged: ArgT
): Thread[ArgT] =
  createThread(result, workerProc, tagged)

template spawnDefinedConsumer*(workerProc: untyped, q: untyped): untyped =
  ## Spawn a consumer worker declared via `defineConsumerWorker`. Returns
  ## the `Thread[…]` handle.
  let u_lfq_spawn = q.getConsumer()
  type ArgT_lfq_spawn = `workerProc Arg`
  spawnDefinedConsumerImpl[ArgT_lfq_spawn](
    workerProc,
    ArgT_lfq_spawn(queue: u_lfq_spawn.queue, idx: u_lfq_spawn.idx),
  )
