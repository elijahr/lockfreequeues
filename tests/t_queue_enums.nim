## Tests for the v5.0.0 shared enum modules.
##
## These modules consolidate the triplicated `DeallocationStrategy` enum
## (was identically defined at unbounded_mpsc.nim:52, unbounded_spmc.nim:54,
## unbounded_mpmc.nim:50) and introduce `ReclamationKind` for the unified
## `Queue` generic's `RK` phantom.
##
## (ReclamationKind), §3.1 (DeallocationStrategy), §5
## (verbatim source).
##
## 

import unittest2

import lockfreequeues/strategy
import lockfreequeues/reclamation

suite "v5.0.0 enum modules":

  test "DeallocationStrategy has stManual + stEager with documented ords":
    # Two members, distinct, in source order (stManual=0, stEager=1).
    check stManual.ord == 0
    check stEager.ord == 1
    check stManual != stEager

  test "DeallocationStrategy high/low pin the member set":
    # Guards against silent additional members. If a future commit appends
    # e.g. stBatch, this assertion fires.
    check ord(low(DeallocationStrategy)) == 0
    check ord(high(DeallocationStrategy)) == 1

  test "DeallocationStrategy string form matches member identifiers":
    check $stManual == "stManual"
    check $stEager == "stEager"

  test "Manual / Eager bare-symbol aliases preserved":
    # Backward-compatibility aliases from the v4.x triplicated enum form.
    check Manual == stManual
    check Eager == stEager

  test "DefaultDeallocationStrategy follows gcNone":
    when defined(gcNone):
      check DefaultDeallocationStrategy == stManual
    else:
      check DefaultDeallocationStrategy == stEager

  test "ReclamationKind has rkNone + rkEbr with documented ords":
    check rkNone.ord == 0
    check rkEbr.ord == 1
    check rkNone != rkEbr

  test "ReclamationKind high/low pin the member set":
    # Guards against silent additional members.
    check ord(low(ReclamationKind)) == 0
    check ord(high(ReclamationKind)) == 1

  test "ReclamationKind string form matches member identifiers":
    check $rkNone == "rkNone"
    check $rkEbr == "rkEbr"
