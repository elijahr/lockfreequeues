discard """
  errormsg: "undeclared field: 'push'"
"""
import lockfreequeues/endpoint
import lockfreequeues/role_tags

type DummyQueue = object

var u: Unbound[int, AnyThreadTag, DummyQueue]
discard u.push(1) # MUST fail: push lives on Bound, not Unbound (L1 lifecycle guard).
