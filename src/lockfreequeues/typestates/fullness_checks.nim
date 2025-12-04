# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Type-safe fullness checks.

import ./virtual_values_n
import ./virtual_values_n1


# N-slot checks (MPSC/SPMC/MPMC)
proc usedN*[N: static int](head, tail: WrappedValueN[N]): int {.inline.} =
  result = tail.value - head.value
  if result < 0:
    result += 2 * N

proc availableN*[N: static int](head, tail: WrappedValueN[N]): int {.inline.} =
  N - usedN(head, tail)

proc fullN*[N: static int](head, tail: WrappedValueN[N]): bool {.inline.} =
  usedN(head, tail) >= N

proc emptyN*[N: static int](head, tail: WrappedValueN[N]): bool {.inline.} =
  head.value == tail.value


# N+1-slot checks (SPSC)
proc usedN1*[N: static int](head, tail: WrappedValueN1[N]): int {.inline.} =
  result = tail.value - head.value
  if result < 0:
    result += 2 * (N + 1)

proc availableN1*[N: static int](head, tail: WrappedValueN1[N]): int {.inline.} =
  N - usedN1(head, tail)

proc fullN1*[N: static int](head, tail: WrappedValueN1[N]): bool {.inline.} =
  usedN1(head, tail) >= N

proc emptyN1*[N: static int](head, tail: WrappedValueN1[N]): bool {.inline.} =
  head.value == tail.value
