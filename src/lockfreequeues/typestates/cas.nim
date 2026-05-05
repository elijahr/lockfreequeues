## Type-safe CAS operations.
##
## Forces explicit handling of success and failure paths via a typestate
## union: a `CASPending` is consumed by `executeCAS` and produces either a
## `CASSucceeded` (carrying the written value) or a `CASFailed` (carrying the
## value actually observed at the address). Callers `match` on the resulting
## `CASResult` union and cannot reach the payload without selecting a branch.

import ../atomic_dsl
import typestates

type
  CASAttempt* = object
    atom: ptr Atomic[int]
    expected: int
    desired: int

  CASPending* = distinct CASAttempt ## CAS prepared but not executed.

  CASSucceeded* = object ## Terminal: CAS succeeded; carries the written value.
    newVal*: int

  CASFailed* = object
    ## Terminal: CAS failed; carries the value actually observed at the address.
    actualVal*: int

typestate CASAttempt:
  opaqueStates = true
  states CASPending, CASSucceeded, CASFailed
  initial:
    CASPending
  terminal:
    CASSucceeded
    CASFailed
  transitions:
    CASPending -> CASSucceeded | CASFailed as CASResult

# Accessors
proc expectedVal*(p: CASPending): int {.notATransition.} =
  CASAttempt(p).expected

proc desiredVal*(p: CASPending): int {.notATransition.} =
  CASAttempt(p).desired

# Constructor
proc prepareCAS*(atom: ptr Atomic[int], expected, desired: int): CASPending {.inline.} =
  CASPending(CASAttempt(atom: atom, expected: expected, desired: desired))

# Execute CAS - returns the typestate union; caller MUST match on it.
proc executeCAS*(p: CASPending): CASResult {.transition.} =
  let attempt = CASAttempt(p)
  var expected = attempt.expected
  let success =
    attempt.atom[].compareExchangeWeak(expected, attempt.desired, moRelease, moAcquire)
  if success:
    CASResult -> CASSucceeded(newVal: attempt.desired)
  else:
    CASResult -> CASFailed(actualVal: expected)
