## Example helpers for v5.0.0 unbounded mupmuc job-scheduler example.
##
## See `tests/debra_cc_helpers.nim` for the canonical version. We
## duplicate the helper here so example sources can stay self-contained
## under `examples/nim.cfg` (which only adds `../src/` to the path, not
## `../tests/`).
##
## The 3.3.6 migration target imports `lockfreequeues/queue` + nim-debra,
## both of which export a `PinScopeCardinality` enum with `ccSingle` /
## `ccMulti` members. v5.0.0 keeps the lockfreequeues stub in place until
## Track E1 re-homes the canonical enum into nim-debra and deletes the
## stub. Until then, example files that need a ccMulti-typed
## `DebraManager` (mupmuc-equiv) cannot import both `debra` and
## `lockfreequeues/queue` unqualified without colliding on `ccMulti`.
##
## This helper module imports `debra` in isolation and exposes a single
## constructor that returns a ccMulti `DebraManager`. Callers can then
## `import lockfreequeues` + use `Queue[..., ccMulti, ...]` types
## referring to the pinscope_stub members without ambiguity.

import debra

proc initMultiConsumerManager*[MaxThreads: static int](): DebraManager[MaxThreads, ccMulti] =
  ## Returns a fresh `DebraManager[MaxThreads, ccMulti]` for examples of
  ## `ccCons == ccMulti` queues (mupmuc-equiv).
  initDebraManager[MaxThreads, ccMulti]()
