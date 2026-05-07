import unittest2
import lockfreequeues/backoff

suite "backoff":
  test "backoffOnRetry mutates spins exponentially and caps at MaxSpin":
    var spins = InitialSpin
    backoffOnRetry(spins)
    check spins == InitialSpin * 2

    # Drive enough iterations to exceed MaxSpin
    for _ in 0 ..< 32:
      backoffOnRetry(spins)
    check spins == MaxSpin

  test "backoffOnRetry preserves local state across iterations":
    var spins = InitialSpin
    var counter = 0
    for i in 0 ..< 100:
      backoffOnRetry(spins)
      inc counter
    check counter == 100

  test "backoffOnPeerWait is callable in a tight loop without state":
    var counter = 0
    for i in 0 ..< 1000:
      backoffOnPeerWait()
      inc counter
    check counter == 1000

  test "backoffOnCASLossRetry is callable in a tight loop without state":
    var counter = 0
    for i in 0 ..< 1000:
      backoffOnCASLossRetry()
      inc counter
    check counter == 1000

  test "InitialSpin, MaxSpin, YieldThreshold defaults match design doc":
    check InitialSpin == 4
    check MaxSpin == 256
    check YieldThreshold == 16
