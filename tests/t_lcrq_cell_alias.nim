## Smoke test: `LCRQCell[T]` type alias + `CLOSED_BIT` from
## `lockfreequeues/queue`.
##
## Phase B Task T1 of the strict-LCRQ migration. Pure type-level
## introduction — no primitives, no behavior. This file proves four
## properties of the new alias before the next task (T2) consumes it:
##
## 1. `LCRQCell[T]` is a *transparent* alias for
##    `Atomic[Pair[uint, T]]` (not a wrapper struct). A value of
##    type `LCRQCell[int]` must be directly assignable to / from
##    `Atomic[Pair[uint, int]]` without any conversion. The alias
##    uses platform-native `uint` (rather than hardcoded `uint64`)
##    so the cell stays at the platform's native DWCAS width on
##    every debra-supported target.
##
## 2. `Pair[A, B]` is spellable from a downstream module that imports
##    both `lockfreequeues/queue` (for the alias) and `debra/atomics`
##    (for `Atomic` / `Pair`). The public alias `LCRQCell[T]` is the
##    intended downstream entry point; spelling out the payload pair
##    is only used here to prove the alias is transparent.
##
## 3. `sizeof(LCRQCell[int]) == sizeof(uint) * 2` — the DWCAS-width
##    invariant that the entire strict-LCRQ progress argument
##    (design §2.1, §4) rests on. On 64-bit targets this is 16 bytes
##    (128-bit DWCAS); on 32-bit targets it is 8 bytes (64-bit DWCAS).
##    A pessimization that widened the cell (e.g. an extra flag field)
##    would break double-word atomicity and would silently degrade to
##    a non-lock-free path.
##
## 4. `CLOSED_BIT == 1'u shl (sizeof(uint)*8 - 1)` — the §4 close
##    sentinel must occupy the high bit so the empty/filled epoch
##    counter (low bits) cannot collide with it. Moving this bit
##    would invalidate every producer/consumer mask in T2's
##    primitives. On 64-bit (uint == uint64) this is identical to
##    `1'u64 shl 63`.
##
## Once T2 lands the three cell primitives (`tryPublish` / `tryClaim`
## / `tryCloseOnEmpty`) this smoke test stays in place as a guard:
## if the alias is ever changed to wrap the pair, the assignment in
## test 1 fails to compile; if the pair is ever changed to include
## a third field, the sizeof in test 3 fails.

import std/unittest

# The public alias `LCRQCell[T]` is the intended downstream entry
# point. `Atomic` and `Pair` are imported directly from `debra/atomics`
# here only so the test can spell out the alias's RHS and prove
# transparency in test 1. Downstream code that only uses `LCRQCell[T]`
# does not need this extra import.
import lockfreequeues/queue
import debra/atomics

suite "LCRQCell[T] alias + CLOSED_BIT + Pair re-export (T1 smoke)":
  test "1. LCRQCell[int] is a transparent alias for Atomic[Pair[uint, int]]":
    # Assignment between the alias and the spelled-out type proves
    # transparency. If `LCRQCell` were declared as a `distinct`
    # alias or a wrapper `object`, the line below would not compile.
    var asAlias: LCRQCell[int]
    var asSpelled: Atomic[Pair[uint, int]]
    asAlias = asSpelled
    asSpelled = asAlias
    # Reaching this point with no compile error is the assertion;
    # the runtime check below is a belt-and-suspenders trigger so
    # the test framework records a pass for this case.
    check sizeof(asAlias) == sizeof(asSpelled)

  test "2. Pair[uint, T] is constructible (payload-shape sanity)":
    # Sanity-check that the payload pair can be constructed and
    # observed. `Pair` is imported here directly from `debra/atomics`;
    # downstream callers that only use `LCRQCell[T]` do not need this
    # import.
    let p: Pair[uint, int] = Pair[uint, int](first: 7'u, second: 42)
    check p.first == 7'u
    check p.second == 42

  test "3. sizeof(LCRQCell[int]) == sizeof(uint) * 2 (DWCAS width invariant)":
    # The strict-LCRQ progress argument (design §2.1, §4) requires
    # that each cell fit in a single double-word CAS operand. On
    # 64-bit targets (sizeof(uint)==8) that is 16 bytes / 128-bit
    # DWCAS; on 32-bit targets (sizeof(uint)==4) that is 8 bytes /
    # 64-bit DWCAS. A widened cell would silently lose lock-freedom
    # by falling back to the libatomic path or by splitting the
    # operation. Pin the width relative to sizeof(uint).
    check sizeof(LCRQCell[int]) == sizeof(uint) * 2
    static:
      doAssert sizeof(LCRQCell[int]) == sizeof(uint) * 2,
        "LCRQCell[int] must be sizeof(uint)*2 bytes for DWCAS"
      doAssert sizeof(LCRQCell[uint]) == sizeof(uint) * 2,
        "LCRQCell[uint] must be sizeof(uint)*2 bytes for DWCAS"
      doAssert sizeof(LCRQCell[pointer]) == sizeof(uint) * 2,
        "LCRQCell[pointer] must be sizeof(uint)*2 bytes for DWCAS"

  test "4. CLOSED_BIT == 1'u shl (sizeof(uint)*8 - 1) (close sentinel bit position)":
    # The §4 close-on-empty progress argument requires the close
    # sentinel to live in a bit position that is otherwise unreachable
    # by the empty/filled epoch counter. The high bit of platform-native
    # `uint` is the design's reserved position; the remaining low bits
    # encode the epoch. If `CLOSED_BIT` ever moves (e.g. to a low bit),
    # every producer/consumer mask in `tryPublish` / `tryClaim` /
    # `tryCloseOnEmpty` has to be revisited. On 64-bit this is
    # equivalent to `1'u64 shl 63`.
    check CLOSED_BIT == 1'u shl (sizeof(uint) * 8 - 1)
    check CLOSED_BIT != 0'u
    static:
      doAssert CLOSED_BIT == 1'u shl (sizeof(uint) * 8 - 1),
        "CLOSED_BIT must occupy the high bit of platform-native uint"
