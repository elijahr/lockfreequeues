import unittest2
import debra/atomics
import debra/atomics/dsl
import lockfreequeues/typestates/virtual_values_n
import lockfreequeues/typestates/mpmc_cell

proc slot[N: static int](i: int): PhysicalSlotN[N] {.inline.} =
  initRawN[N](i).validate().index()

suite "MPMCCell[T] layout":
  test "MPMCCell[int] size is a multiple of CacheLineBytes":
    check(sizeof(MPMCCell[int]) mod CacheLineBytes == 0)
    check(sizeof(MPMCCell[int]) >= CacheLineBytes)

  test "MPMCCell[ptr int] size is a multiple of CacheLineBytes":
    check(sizeof(MPMCCell[ptr int]) mod CacheLineBytes == 0)
    check(sizeof(MPMCCell[ptr int]) >= CacheLineBytes)

  test "MPMCCell[string] size is a multiple of CacheLineBytes":
    # `string` is a managed-memory T; its sizeof is implementation-defined
    # but must still produce a cell whose total size lands on a cache line.
    check(sizeof(MPMCCell[string]) mod CacheLineBytes == 0)

  test "adjacent cells in MPMCCellArrayN are cache-line separated":
    var a: MPMCCellArrayN[4, int]
    a.init()
    let stride =
      cast[int](addr a.cells[1]) - cast[int](addr a.cells[0])
    check(stride mod CacheLineBytes == 0)
    check(stride >= CacheLineBytes)
    # The first cell must itself be cache-line aligned.
    check(cast[int](addr a.cells[0]) mod CacheLineBytes == 0)

suite "MPMCCellArrayN[N, T]":
  test "init sets seq[i] = i for N=4, T=int":
    var a: MPMCCellArrayN[4, int]
    a.init()
    for i in 0 ..< 4:
      check(a.seqLoad(slot[4](i), moRelaxed) == uint64(i))

  test "seqStore + seqLoad round-trip":
    var a: MPMCCellArrayN[8, int]
    a.init()
    let idx = slot[8](5)
    a.seqStore(idx, 42'u64, moRelease)
    check(a.seqLoad(idx, moAcquire) == 42'u64)

  test "dataPtr write then read via plain assignment":
    var a: MPMCCellArrayN[4, int]
    a.init()
    let idx = slot[4](2)
    a.dataPtr(idx)[] = 12345
    check(a.dataPtr(idx)[] == 12345)

  test "seq and data are co-located but independently writable":
    var a: MPMCCellArrayN[4, int]
    a.init()
    let idx = slot[4](1)
    a.seqStore(idx, 7'u64, moRelease)
    a.dataPtr(idx)[] = 999
    check(a.seqLoad(idx, moAcquire) == 7'u64)
    check(a.dataPtr(idx)[] == 999)

  test "ptr T payload: pointer round-trip through dataPtr":
    var a: MPMCCellArrayN[4, ptr int]
    a.init()
    var live = 17
    let idx = slot[4](0)
    a.dataPtr(idx)[] = addr live
    check(a.dataPtr(idx)[] == addr live)
    check(a.dataPtr(idx)[][] == 17)

  test "string payload: managed-memory T survives init + store + load":
    var a: MPMCCellArrayN[4, string]
    a.init()
    let idx = slot[4](3)
    a.dataPtr(idx)[] = "hello"
    check(a.dataPtr(idx)[] == "hello")
    a.seqStore(idx, 99'u64, moRelease)
    check(a.seqLoad(idx, moAcquire) == 99'u64)
    check(a.dataPtr(idx)[] == "hello")

  test "MPMCCellArrayN size scales as N * sizeof(MPMCCell[T])":
    check(sizeof(MPMCCellArrayN[4, int]) == 4 * sizeof(MPMCCell[int]))
    check(sizeof(MPMCCellArrayN[16, int]) == 16 * sizeof(MPMCCell[int]))
    check(
      sizeof(MPMCCellArrayN[8, ptr int]) == 8 * sizeof(MPMCCell[ptr int])
    )
