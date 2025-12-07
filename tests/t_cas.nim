import unittest2
import atomics
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
    let result = pending.executeCAS()
    check(result.succeeded)
    check(atom.load(moRelaxed) == 10)

  test "executeCAS fails when expected doesn't match":
    var atom: Atomic[int]
    atom.store(7, moRelaxed)  # Different from expected
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    let result = pending.executeCAS()
    check(not result.succeeded)
    check(result.actualVal == 7)
    check(atom.load(moRelaxed) == 7)  # Unchanged

  test "handleSuccess extracts from CASSucceeded":
    var atom: Atomic[int]
    atom.store(5, moRelaxed)
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    let result = pending.executeCAS()
    if result.succeeded:
      let success = result.assumeSuccess()
      check(success.newVal == 10)

  test "handleFailure extracts from CASFailed":
    var atom: Atomic[int]
    atom.store(7, moRelaxed)
    let pending = prepareCAS(addr atom, expected = 5, desired = 10)
    let result = pending.executeCAS()
    if not result.succeeded:
      let failure = result.assumeFailure()
      check(failure.actualVal == 7)
