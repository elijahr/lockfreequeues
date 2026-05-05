import unittest2
import lockfreequeues/atomic_dsl
import lockfreequeues/typestates
import lockfreequeues/typestates/cas

suite "CAS Typestate":
  test "prepareCAS creates CASPending":
    var atom: Atomic[int]
    atom.store(5, moRelaxed)
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    check(pending.expectedVal == 5)
    check(pending.desiredVal == 10)

  test "executeCAS succeeds when expected matches":
    var atom: Atomic[int]
    atom.store(5, moRelaxed)
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    var res = pending.executeCAS()
    var sawSuccess = false
    match res:
      CASSucceeded(s):
        sawSuccess = true
        check(s.newVal == 10)
      CASFailed(_):
        fail()
    check(sawSuccess)
    check(atom.load(moRelaxed) == 10)

  test "executeCAS fails when expected doesn't match":
    var atom: Atomic[int]
    atom.store(7, moRelaxed) # Different from expected
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    var res = pending.executeCAS()
    var sawFailure = false
    match res:
      CASSucceeded(_):
        fail()
      CASFailed(f):
        sawFailure = true
        check(f.actualVal == 7)
    check(sawFailure)
    check(atom.load(moRelaxed) == 7) # Unchanged

  test "match selects success branch and exposes newVal":
    var atom: Atomic[int]
    atom.store(5, moRelaxed)
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    var res = pending.executeCAS()
    match res:
      CASSucceeded(s):
        check(s.newVal == 10)
      CASFailed(_):
        fail()

  test "match selects failure branch and exposes actualVal":
    var atom: Atomic[int]
    atom.store(7, moRelaxed)
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    var res = pending.executeCAS()
    match res:
      CASSucceeded(_):
        fail()
      CASFailed(f):
        check(f.actualVal == 7)
