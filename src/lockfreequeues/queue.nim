## Unified `Queue` generic — v5.0.0 type shell.
##
## This file declares the type shell only; method bodies follow in
## subsequent tracks:
##   - Track B (Manager B) fills the `when RK == rkNone:` push/pop ladder.
##   - Track E (Manager E) fills the `when RK == rkEbr:` push/pop ladder
##     and the γ retire wrappers (retireOnCAS / retireOnPublish).
##
## **Mode-(a) carve-out (this commit only):** the `when RK == rkEbr:`
## field declarations are wrapped in `when false:` so the type
## instantiates without taking a dependency on nim-debra 0.8.0 types
## (`DebraManager`, `ThreadHandle`, `Segment`, `CacheLineBytes`). Manager
## E rewrites those field decls with real debra types when guava's
## nim-debra worktree linkage lands. The 9 param-coherence guards from
## Doc C §3.0.2.4 remain ACTIVE and apply to BOTH branches; only the
## rkEbr field layout is stubbed.
##
## **Nim translation of Doc C §3.0.2.4 guards:** Doc C writes the 9
## param-coherence guards as `static: assert COND, MSG` statements at
## the top of each `when RK` branch of the object body. Nim does not
## accept `static:` blocks (nor `{.error.}` pragmas) directly inside
## an object type body, so the guards are lifted into a sibling
## generic template `assertQueueParams` invoked by the generic
## `validateQueueParams` proc that callers must use as the entry
## point for type validation. The condition expressions and error
## messages are byte-identical with Doc C §3.0.2.4; only the syntactic
## wrapper differs. Track A4 will harden this with a `nim check`
## expected-fail shell harness.
##
## Param order is LOAD-BEARING (Doc C §3.0.1, §5):
##   T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads
##
## Doc C §3.0 (target shape), §3.0.1 (uniform generic), §3.0.2.4 (9
## param-coherence guards), §5 (verbatim source).

import ./strategy
import ./reclamation
import ./internal/pinscope_stub
# NOTE: `import std/atomics` is intentionally NOT added in the A2 shell.
# Tracks B (rkNone bounded body) and E (rkEbr unbounded body) will add
# `import std/atomics` (and, for E, `import debra`) at the same time
# they introduce the field declarations that consume `Atomic[T]` etc.

# `stManual`, `stEager`, `rkNone`, `rkEbr`, `ccSingle`, `ccMulti` are
# enum members that travel with their enum type — they are visible to
# any module that imports `queue` (no individual re-export needed; Nim
# rejects per-member enum re-exports).
export DeallocationStrategy, ReclamationKind, PinScopeCardinality,
       Manual, Eager,
       DefaultDeallocationStrategy

const LockFreeQueuesAdvanceEvery* {.intdefine.}: int = 64
  ## Cadence for `advanceEvery` calls in the rkEbr Eager reclamation path.
  ## Override at compile time with `-d:LockFreeQueuesAdvanceEvery=N`.
  ##
  ## Lifted from `unbounded_mupmuc.nim` and `unbounded_mupsic.nim` per
  ## impl plan §A2 Step 3a-bis. Track F deletes the per-family copies
  ## once the unified body lands; lockfreequeues.nim re-exports this
  ## symbol as part of F5.
static:
  assert LockFreeQueuesAdvanceEvery > 0,
    "LockFreeQueuesAdvanceEvery must be a positive integer"

type
  Queue*[T;
         ccProd, ccCons: static PinScopeCardinality;
         ST: static DeallocationStrategy;
         RK: static ReclamationKind;
         N, P, C, S, MaxThreads: static int] = object
    when RK == rkNone:
      # Bounded body field decls are added by Manager B (Track B / Task
      # B1). For the A2 shell they are intentionally omitted; the smoke
      # test only takes `addr q` on an instantiated zero-method Queue.
      discard
    elif RK == rkEbr:
      # MODE-(a) STUB: real field decls (DebraManager, Segment,
      # ThreadHandle, CacheLineBytes-aligned atomics) are added by
      # Manager E once nim-debra 0.8.0 linkage lands. Wrapping in
      # `when false:` keeps the type parseable + instantiable without
      # depending on debra 0.8.0 type names.
      when false:
        # Placeholder for Doc C §3.0 / §5 rkEbr fields. Manager E
        # replaces this block with the real declarations.
        manager: pointer
        ownsManager: bool
      else:
        discard

## ----------------------------------------------------------------------
## Doc C §3.0.2.4 param-coherence guards.
##
## The condition expressions and error message strings are verbatim from
## Doc C §3.0.2.4. The Nim syntactic wrapper differs only because the
## design doc's `static: assert` notation is not legal inside an object
## type body in Nim; the assertions are lifted into a generic template
## and exercised via `validateQueueParams`.
## ----------------------------------------------------------------------

template assertQueueParams*[T;
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    RK: static ReclamationKind;
    N, P, C, S, MaxThreads: static int]() =
  when RK == rkNone:
    # 6 rkNone guards — Doc C §3.0.2.4.
    static: assert N > 0,
      "Queue[..., RK=rkNone] requires N > 0 (bounded slot count)"
    static: assert S == 0 and MaxThreads == 0,
      "Queue[..., RK=rkNone] must have S=0, MaxThreads=0 " &
      "(segment-size and thread-registry are rkEbr-only)"
    when ccProd == ccMulti:
      static: assert P > 0,
        "Queue[..., ccProd=ccMulti, RK=rkNone] requires P > 0 " &
        "(per-producer state count)"
    when ccProd == ccSingle:
      static: assert P == 0,
        "Queue[..., ccProd=ccSingle, RK=rkNone] must have P == 0"
    when ccCons == ccMulti:
      static: assert C > 0,
        "Queue[..., ccCons=ccMulti, RK=rkNone] requires C > 0 " &
        "(per-consumer state count)"
    when ccCons == ccSingle:
      static: assert C == 0,
        "Queue[..., ccCons=ccSingle, RK=rkNone] must have C == 0"
  elif RK == rkEbr:
    # 3 rkEbr guards — Doc C §3.0.2.4.
    static: assert S > 0,
      "Queue[..., RK=rkEbr] requires S > 0 (segment slot count)"
    static: assert MaxThreads > 0,
      "Queue[..., RK=rkEbr] requires MaxThreads > 0 " &
      "(debra thread-registry capacity)"
    static: assert N == 0 and P == 0 and C == 0,
      "Queue[..., RK=rkEbr] must have N=0, P=0, C=0 " &
      "(bounded slot/per-producer/per-consumer counts are rkNone-only)"

proc validateQueueParams*[T;
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    RK: static ReclamationKind;
    N, P, C, S, MaxThreads: static int](
    _: typedesc[Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]]
) =
  ## Compile-time entry point for Doc C §3.0.2.4 param-coherence guards.
  ##
  ## Call this once per `Queue[...]` instantiation (the future
  ## constructors and method bodies in Tracks B/E will invoke it
  ## implicitly). For the A2 type-shell, smoke tests call it explicitly
  ## to exercise the 9 guards. Has no runtime cost — the body collapses
  ## to a single `discard` after the template's `static: assert`s fire.
  assertQueueParams[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]()
  discard
