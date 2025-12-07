import unittest2
import lockfreequeues/typestates/virtual_values_n

suite "VirtualValueN[N] - N-slot design":

  test "initRawN creates RawLoadedN":
    let raw = initRawN[8](5)
    check(RawLoadedN[8](raw).rawValue == 5)

  test "validate transitions RawLoadedN to WrappedValueN":
    let raw = initRawN[8](5)
    let wrapped = raw.validate()
    check(wrapped.value == 5)

  test "validate rejects values >= 2*N":
    let raw = initRawN[8](16)  # >= 2*8
    expect(AssertionDefect):
      discard raw.validate()

  test "add transitions WrappedValueN to UnwrappedSumN":
    let wrapped = initRawN[8](5).validate()
    let sum = wrapped.add(3)
    check(sum.unwrappedValue == 8)

  test "wrapIfNeeded transitions UnwrappedSumN to WrappedValueN":
    let wrapped = initRawN[8](14).validate()  # Near edge of 2*8=16
    let sum = wrapped.add(3)  # 14+3=17
    let rewrapped = sum.wrapIfNeeded()
    check(rewrapped.value == 1)  # 17 - 16 = 1

  test "wrapIfNeeded no-op when not needed":
    let wrapped = initRawN[8](5).validate()
    let sum = wrapped.add(2)  # 5+2=7 < 16
    let rewrapped = sum.wrapIfNeeded()
    check(rewrapped.value == 7)

  test "index transitions WrappedValueN to PhysicalSlotN":
    let wrapped = initRawN[8](10).validate()
    let slot = wrapped.index()
    check(slot.slotValue == 2)  # 10 mod 8 = 2

  test "incOrResetN combines add+wrapIfNeeded":
    let wrapped = initRawN[8](14).validate()
    let next = wrapped.incOrResetN(3)
    check(next.value == 1)  # (14+3) mod 16 with wrap

suite "PhysicalSlotN[N] type safety":

  test "PhysicalSlotN only from index()":
    # This tests that slot values are in range 0..<N
    let slot = initRawN[8](0).validate().index()
    check(slot.slotValue == 0)

    let slot2 = initRawN[8](15).validate().index()
    check(slot2.slotValue == 7)  # 15 mod 8 = 7
