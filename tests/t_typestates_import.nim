import unittest2
import lockfreequeues/typestates

suite "Typestates module exports":
  test "all types accessible":
    # N-slot
    var rawN: RawLoadedN[8]
    var wrappedN: WrappedValueN[8]
    var slotN: PhysicalSlotN[8]
    var storageN: StorageN[8, int]
    var flagsN: CommittedFlagsN[8]

    # N+1-slot
    var rawN1: RawLoadedN1[8]
    var wrappedN1: WrappedValueN1[8]
    var slotN1: PhysicalSlotN1[8]
    var storageN1: StorageN1[8, int]

    # CAS
    var casPending: CASPending

    check(true) # Just verify it compiles
