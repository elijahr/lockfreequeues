## Re-export shim for the upstream `typestates` package's DSL macros.
##
## Bundle F (3.3.11-B.4.1.6) lifts this shim into existence because
## the local `lockfreequeues/typestates.nim` re-export module shadows
## the upstream package name (`typestates`) for files at the same
## directory level as itself (e.g., `bqueue.nim`, `queue.nim`). Nim's
## module resolution prefers a same-directory sibling over a
## `--path:`-resolved package, so `import typestates` from `bqueue.nim`
## binds to the local module — which does NOT re-export the upstream
## `typestate` / `destructorTransition` / `transitionError` /
## `notATransition` macros.
##
## This module lives one directory down (`./internal/`) so it does
## not share a directory with `bqueue.nim`. From its perspective,
## `import typestates` unambiguously resolves to the upstream package.
## It then `export`s the upstream surface so `bqueue.nim` and
## `queue.nim` can pull the DSL via
## `import ./internal/typestates_dsl`.

import typestates
export typestates
