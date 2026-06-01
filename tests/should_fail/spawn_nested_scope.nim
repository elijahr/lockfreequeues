discard """
  errormsg: "'export' is only allowed at top level"
"""
## C14.5 module-scope guard for define*Worker macros.
##
## `defineProducerWorker` invoked inside a proc body must compile-fail.
## The emitted thread proc would be silently downgraded to a closure
## in nested scope (Nim 2.2.10 codegen issue) → runtime segfault at
## createThread. The macro's emitted `export <workerName>` trips the
## "'export' is only allowed at top level" error and fails cleanly.

import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import lockfreequeues/spawn

proc badNestedInvocation() =
  defineProducerWorker(BadWorker, BQueue[int, ccMulti, ccMulti, 64, 4, 4]):
    discard producer.push(1)

badNestedInvocation()
