##
## Endpoint types for static thread-affinity. See design §3.3.1.
##
## **Lifecycle vs role — orthogonal layers.** `Endpoint` is the typestate
## for endpoint LIFECYCLE only: `Unbound -> Bound -> Closed`. ROLE is
## carried via the `Tag` generic parameter — one of `SpscProducerTag`,
## `SpscConsumerTag`, `MpmcProducerTag`, `MpmcConsumerTag` (all in
## `role_tags.nim`), or `AnyThreadTag` for the same-thread shortcut path
## explicitly chosen by `getProducerHere` / `getConsumerHere` call sites.
## `Tag` distinctness is enforced at compile time via the
## `{.tags: [TagType, TypestateOp].}` effect pragma on `push`/`pop` procs
## (Task C9) plus `{.forbids: [...].}` regions; the typestate FSM here
## carries no role information.
##
## Per design §3.1 four-layer architecture (typestate=lifecycle,
## effect-tag=role). The plan template at §C4 sketched two parallel
## typestates `ProducerEndpoint` + `ConsumerEndpoint` with identical
## state sets; typestates 0.12.0 TA-004 forbids sharing state types
## across typestates (see `queue.nim:80-83` for the same constraint).
## Per pepper's MCLD call (2026-05-30): merge into a single `Endpoint`
## typestate — role lives in `Tag`, lifecycle in `Endpoint`.
##
## **Spike C2.5 result**: single-family import graph clean (outcome G).
##
## **Queue specialisation deferral**: the plan template originally
## sketched a `when queueT is Queue:` branch carrying a debra
## `ThreadHandle[queueT.MaxThreads]` field on `Bound`/`Closed`. Nim
## 2.2's eager generic resolution rejects `is Queue` on the
## 6-static-param generic without bound arguments. Per pepper's MCLD
## call: the Queue specialisation (`handle` field,
## `registerThread`/`unregisterThread`, `close` transition) moves
## wholesale to Task C6 — either a distinct `QueueBound` variant, a
## queueT-constrained re-introduction of the `when`-branch, or proc
## overloads, whichever reads cleanest at the implementation site.
##
## **R10 fallback** (per design §3.3.1): if the three-axis generic
## typestate trips a further nim-typestates corner case, drop `queueT`
## from the typestate axis and store it as a non-typestate field.

{.experimental: "strictEffects".}

import ./internal/typestates_dsl
import std/typedthreads

type
  Unbound*[T; Tag; queueT] = object
    queue*: ptr queueT
    idx*: int

  Bound*[T; Tag; queueT] = object
    queue*: ptr queueT
    idx*: int
    when defined(debug):
      attachedTid*: int

  Closed*[T; Tag; queueT] = object

typestate Endpoint[T, Tag, queueT]:
  consumeOnTransition = true
  strictTransitions = true
  states Unbound[T, Tag, queueT], Bound[T, Tag, queueT], Closed[T, Tag, queueT]
  transitions:
    Unbound[T, Tag, queueT] -> Bound[T, Tag, queueT]
    Bound[T, Tag, queueT] -> Closed[T, Tag, queueT]

proc bindToThread*[T; Tag; queueT](
    u: sink Unbound[T, Tag, queueT]
): Bound[T, Tag, queueT] {.transition, tags: [Tag, TypestateOp], gcsafe, raises: [].} =
  ## Bind the endpoint to the calling thread. See design §3.3.2.
  ##
  ## The sugar pragma `{.transition(tag: ...).}` was withdrawn 2026-05-28
  ## (Nim parser rejects `nkObjConstr` pragma form + semantic conflation of
  ## value-typestate with proc-effect). The explicit composed form above is
  ## the only available shape.
  ##
  ## Queue specialisation (debra `registerThread` call wired through
  ## `queueT.manager`) lands in Task C6 — either as a distinct overload, an
  ## overload set, or a `when queueT is …` branch evaluated in C6's
  ## queueT-constrained scope.
  let consumed = move(u)
  result = Bound[T, Tag, queueT](queue: consumed.queue, idx: consumed.idx)
  when defined(debug):
    result.attachedTid = getThreadId()

verifyTypestates()
