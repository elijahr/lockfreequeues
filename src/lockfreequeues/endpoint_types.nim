##
## Endpoint state types — leaf module shared by `endpoint.nim` (which
## owns the typestate FSM + transition procs + backend dispatch) and the
## per-flavour `bqueue.nim` / `queue.nim` (which carry the push/pop
## overloads on `Bound`).
##
## **Why split.** `endpoint.nim` imports `./bqueue` and `./queue` for the
## `BQueueType` / `QueueType` concept matching used by the
## concept-dispatched `onBind` / `onClose` helpers. `bqueue.nim` and
## `queue.nim` need to declare push/pop on `Bound[T, Tag, queueT]`
## receivers — declaring `Bound` here lets the per-flavour modules
## import it without a back-edge cycle.
##
## **Cost of split.** The `Endpoint` typestate in `endpoint.nim` runs
## with `consumeOnTransition = false` (mirroring `BQueueLifecycle` /
## `QueueLifecycle` in the same project). The static-affinity guarantee
## is upheld by lifecycle FSM strictness (`push`/`pop` exist only on
## `Bound`) + role discrimination via the `Tag` generic + effect-tag
## pragmas; the consume-on-transition flag would have added aliasing
## prevention on top, which is not load-bearing for the affinity
## guarantee and is incompatible with cross-module type+typestate split
## (typestates 0.12.0 codegen requires `=copy` hooks in the same module
## as the type).

type
  Unbound*[T; Tag; queueT] = object
    queue*: ptr queueT
    idx*: int

  Bound*[T; Tag; queueT] = object
    queue*: ptr queueT
    idx*: int
    when defined(debug):
      attachedTid*: int
    handleManager*: pointer
      ## Opaque storage for the debra `ThreadHandle.manager` pointer.
      ## Meaningful only for Queue endpoints; `nil` sentinel for BQueue
      ## endpoints. See `endpoint.nim` onBind/onClose for the cast-back
      ## round-trip.
    handleIdx*: int

  EndpointClosed*[T; Tag; queueT] = object
    queue*: ptr queueT
    handleManager*: pointer
    handleIdx*: int

  Closed*[T; Tag; queueT] = EndpointClosed[T, Tag, queueT]
    ## Public alias. `EndpointClosed` is the canonical name (renamed to
    ## avoid the unqualified-`Closed` collision with debra's
    ## `EpochGuardContext.Closed` typestate state visible through the
    ## import graph). User-facing API uses `Closed[T, Tag, queueT]`.
