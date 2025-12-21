import unittest2
import atomics
import lockfreequeues/typestates/virtual_values_n
import lockfreequeues/typestates/virtual_values_n1
import lockfreequeues/typestates/atomic_loaders

suite "Atomic loaders for N-slot":
  test "loadAcquireN returns RawLoadedN":
    var atom: Atomic[int]
    atom.store(5, moRelaxed)
    let raw = loadAcquireN[8](atom)
    check(raw.rawValue == 5)

  test "loadAcquireN can validate":
    var atom: Atomic[int]
    atom.store(10, moRelaxed)
    let wrapped = loadAcquireN[8](atom).validate()
    check(wrapped.value == 10)

suite "Atomic loaders for N+1-slot":
  test "loadAcquireN1 returns RawLoadedN1":
    var atom: Atomic[int]
    atom.store(5, moRelaxed)
    let raw = loadAcquireN1[8](atom)
    check(raw.rawValue == 5)

  test "loadAcquireN1 can validate":
    var atom: Atomic[int]
    atom.store(17, moRelaxed) # Valid for N=8: 0..<18
    let wrapped = loadAcquireN1[8](atom).validate()
    check(wrapped.value == 17)

suite "Store helpers":
  test "storeReleaseN stores WrappedValueN":
    var atom: Atomic[int]
    let wrapped = initRawN[8](10).validate()
    atom.storeReleaseN(wrapped)
    check(atom.load(moRelaxed) == 10)

  test "storeReleaseN1 stores WrappedValueN1":
    var atom: Atomic[int]
    let wrapped = initRawN1[8](10).validate()
    atom.storeReleaseN1(wrapped)
    check(atom.load(moRelaxed) == 10)
