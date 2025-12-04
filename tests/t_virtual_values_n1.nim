# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# tests/t_virtual_values_n1.nim
import unittest2
import lockfreequeues/typestates/virtual_values_n1

suite "VirtualValueN1[N] - N+1-slot design":

  test "initRawN1 creates RawLoadedN1":
    let raw = initRawN1[8](5)
    check(RawLoadedN1[8](raw).rawValue == 5)

  test "validate transitions RawLoadedN1 to WrappedValueN1":
    let raw = initRawN1[8](5)
    let wrapped = raw.validate()
    check(wrapped.value == 5)

  test "validate accepts values in range 0..<2*(N+1)":
    # For N=8, range is 0..<18
    let raw = initRawN1[8](17)
    let wrapped = raw.validate()
    check(wrapped.value == 17)

  test "validate rejects values >= 2*(N+1)":
    let raw = initRawN1[8](18)  # >= 2*(8+1) = 18
    expect(AssertionDefect):
      discard raw.validate()

  test "index uses mod (N+1)":
    # For N=8, physical slots are 0..8 (9 slots)
    let slot = initRawN1[8](10).validate().index()
    check(slot.slotValue == 1)  # 10 mod 9 = 1

  test "incOrResetN1 wraps at 2*(N+1)":
    let wrapped = initRawN1[8](16).validate()
    let next = wrapped.incOrResetN1(3)
    check(next.value == 1)  # (16+3) = 19, 19 - 18 = 1

suite "PhysicalSlotN1[N] type safety":

  test "PhysicalSlotN1 range is 0..N (N+1 slots)":
    let slot = initRawN1[8](8).validate().index()
    check(slot.slotValue == 8)  # 8 mod 9 = 8 (valid slot)
