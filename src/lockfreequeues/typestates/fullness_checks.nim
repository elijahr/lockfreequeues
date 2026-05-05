## Type-safe fullness checks.

import typestates
import ./virtual_values_n
import ./virtual_values_n1

# N-slot checks (MPSC/SPMC/MPMC)
proc usedN*[N: static int](head, tail: WrappedValueN[N]): int {.notATransition.} =
  result = tail.value - head.value
  if result < 0:
    result += 2 * N

proc availableN*[N: static int](head, tail: WrappedValueN[N]): int {.notATransition.} =
  N - usedN(head, tail)

proc fullN*[N: static int](head, tail: WrappedValueN[N]): bool {.notATransition.} =
  usedN(head, tail) >= N

proc emptyN*[N: static int](head, tail: WrappedValueN[N]): bool {.notATransition.} =
  head.value == tail.value

# N+1-slot checks (SPSC)
proc usedN1*[N: static int](head, tail: WrappedValueN1[N]): int {.notATransition.} =
  result = tail.value - head.value
  if result < 0:
    result += 2 * (N + 1)

proc availableN1*[N: static int](
    head, tail: WrappedValueN1[N]
): int {.notATransition.} =
  N - usedN1(head, tail)

proc fullN1*[N: static int](head, tail: WrappedValueN1[N]): bool {.notATransition.} =
  usedN1(head, tail) >= N

proc emptyN1*[N: static int](head, tail: WrappedValueN1[N]): bool {.notATransition.} =
  head.value == tail.value
