## Unit tests for the three strict-LCRQ cell primitives:
## `tryPublish`, `tryClaim`, `tryCloseOnEmpty`.
##
## Phase B Task T2 of the strict-LCRQ migration. Single-threaded
## isolation tests — concurrency proofs live in later tasks once the
## primitives are wired into the production MPMC arm.
##
## CRITICAL contract (design §2.3.1 / CRITICAL-1): `tryClaim` MUST
## NEVER inspect `observed.second`. The CAS on the seq encoding is
## the sole authority on cell state. A successfully published cell
## with `seq=1` may legitimately carry `default(T)` as its payload
## (e.g. `q.push(0)` for `T=int`, `q.push(nil)` for `T=ptr X`). Tests
## T2.C2 and T2.C3 are the regression guard for the Phase A.5 spike's
## `observed.second == default(T)` short-circuit.

import std/unittest
import std/options

import lockfreequeues/queue
import debra/atomics

# Convenience constructors — explicit Pair[uint, T] literals for the
# DWCAS-shape cell init. Mirrors design §2.3 / §2.5.1 state-machine
# entries (empty / filled / closed-empty).

proc storeCell[T](cell: var LCRQCell[T], seqVal: uint, payload: T) =
  ## Single-threaded direct store of (seq, payload). Used to install
  ## test pre-conditions; production code goes through the primitives.
  store(cell, Pair[uint, T](first: seqVal, second: payload), moRelaxed)

proc readCell[T](cell: var LCRQCell[T]): Pair[uint, T] =
  load(cell, moRelaxed)

suite "T2: tryPublish / tryClaim / tryCloseOnEmpty cell primitives":
  # ------------------------------------------------------------------
  # tryPublish
  # ------------------------------------------------------------------

  test "T2.P1: tryPublish on empty cell succeeds, advances seq to 1":
    var cell: LCRQCell[int]
    storeCell(cell, 0'u, 0)
    check tryPublish(cell, 0'u, 42) == true
    let after = readCell(cell)
    check after.first == 1'u
    check after.second == 42

  test "T2.P2: tryPublish on already-filled cell fails; cell unchanged":
    var cell: LCRQCell[int]
    storeCell(cell, 1'u, 17)
    check tryPublish(cell, 0'u, 99) == false
    let after = readCell(cell)
    check after.first == 1'u
    check after.second == 17

  test "T2.P3: tryPublish on closed cell fails; cell unchanged":
    var cell: LCRQCell[int]
    storeCell(cell, CLOSED_BIT, 0)
    check tryPublish(cell, 0'u, 7) == false
    let after = readCell(cell)
    check after.first == CLOSED_BIT
    check after.second == 0

  test "T2.P4: tryPublish with already-published expectedSeq=1 fails":
    # A racing producer that observed seq=1 (already filled) must not
    # be able to overwrite the cell by guessing expectedSeq=1.
    var cell: LCRQCell[int]
    storeCell(cell, 1'u, 17)
    check tryPublish(cell, 1'u, 99) == false
    let after = readCell(cell)
    check after.first == 1'u
    check after.second == 17

  test "T2.P5: tryPublish[ptr X] with nil value asserts (Option transport restriction)":
    # `std/options.some(val: ptr X)` asserts `not val.isNil` at runtime.
    # tryPublish surfaces the violation at the producer (design §2.5.2 / §11)
    # rather than letting it manifest as a delayed AssertionDefect inside
    # an unrelated consumer's `tryClaim` call. `doAssert` so the guard
    # survives `-d:danger`.
    var cell: LCRQCell[ptr int]
    storeCell(cell, 0'u, nil)
    expect AssertionDefect:
      discard tryPublish(cell, 0'u, nil)

  # ------------------------------------------------------------------
  # tryClaim — CRITICAL-1 contract: CAS is the sole authority on state.
  # NEVER inspect observed.second.
  # ------------------------------------------------------------------

  test "T2.C1: tryClaim on filled cell returns the payload; seq stays at 1, payload zeroed":
    var cell: LCRQCell[int]
    storeCell(cell, 1'u, 42)
    let claimed = tryClaim(cell, 0'u)
    check claimed == some(42)
    let after = readCell(cell)
    check after.first == 1'u
    check after.second == 0 # default(int) — CAS zeroed the payload slot

  test "T2.C2: tryClaim on filled cell with default(T) payload returns some(default(T)) — CRITICAL-1 regression":
    # The spike's `if observed.second == default(T): return none(T)`
    # short-circuit would silently drop this. The production primitive
    # MUST NOT have that short-circuit: CAS is sole authority.
    var cell: LCRQCell[int]
    storeCell(cell, 1'u, 0) # legitimately published default(int)
    let claimed = tryClaim(cell, 0'u)
    check claimed == some(0)
    check claimed.isSome
    let after = readCell(cell)
    check after.first == 1'u
    check after.second == 0

  test "T2.C3: tryClaim on filled cell with non-nil pointer payload round-trips through Option[ptr int]":
    # Cross-T sanity for the pointer instantiation. T2.C2 already
    # exercises the CRITICAL-1 regression class (payload bit-pattern
    # == 0); this test proves the primitive instantiates and CAS-ses
    # correctly for `T = ptr X` and the post-state zeroes the cell.
    #
    # Note: a true `T=ptr X, payload=nil` round-trip cannot be
    # asserted through `std/options.some(ptr X)` (the stdlib `some()`
    # asserts `not val.isNil`). The nil-ptr transport question is an
    # outer-API surface concern (design §2.5.2) handled by the queue's
    # push/pop overload set, not the cell primitive contract.
    var sentinelHolder: int = 0xDEAD
    let sentinel: ptr int = addr sentinelHolder
    var cell: LCRQCell[ptr int]
    storeCell(cell, 1'u, sentinel)
    let claimed = tryClaim(cell, 0'u)
    check claimed.isSome
    check claimed.get() == sentinel
    let after = readCell(cell)
    check after.first == 1'u
    check after.second == nil # CAS zeroed the payload slot

  test "T2.C4: tryClaim on empty cell returns none(T)":
    var cell: LCRQCell[int]
    storeCell(cell, 0'u, 0)
    let claimed = tryClaim(cell, 0'u)
    check claimed.isNone
    let after = readCell(cell)
    check after.first == 0'u
    check after.second == 0

  test "T2.C5: tryClaim on closed cell returns none(T)":
    var cell: LCRQCell[int]
    storeCell(cell, CLOSED_BIT, 0)
    let claimed = tryClaim(cell, 0'u)
    check claimed.isNone
    let after = readCell(cell)
    check after.first == CLOSED_BIT
    check after.second == 0

  # ------------------------------------------------------------------
  # tryCloseOnEmpty
  # ------------------------------------------------------------------

  test "T2.X1: tryCloseOnEmpty on empty cell succeeds, sets CLOSED_BIT":
    var cell: LCRQCell[int]
    storeCell(cell, 0'u, 0)
    check tryCloseOnEmpty(cell, 0'u) == true
    let after = readCell(cell)
    check after.first == CLOSED_BIT
    check after.second == 0

  test "T2.X2: tryCloseOnEmpty on filled cell fails; cell unchanged":
    var cell: LCRQCell[int]
    storeCell(cell, 1'u, 42)
    check tryCloseOnEmpty(cell, 0'u) == false
    let after = readCell(cell)
    check after.first == 1'u
    check after.second == 42

  test "T2.X3: tryCloseOnEmpty on already-closed cell fails; cell unchanged":
    var cell: LCRQCell[int]
    storeCell(cell, CLOSED_BIT, 0)
    check tryCloseOnEmpty(cell, 0'u) == false
    let after = readCell(cell)
    check after.first == CLOSED_BIT
    check after.second == 0
