## Type-safe CAS operations.
##
## Forces explicit handling of success and failure paths.

import atomics
import typestates

type
  CASAttempt* = object
    atom: ptr Atomic[int]
    expected: int
    desired: int

  CASPending* = distinct CASAttempt ## CAS prepared but not executed.

  CASResult* = object ## Result of CAS - must check succeeded before extracting values.
    succeeded*: bool
    newVal*: int # Valid if succeeded
    actualVal*: int # Valid if not succeeded (what was actually there)

  CASSucceeded* = distinct CASResult
  CASFailed* = distinct CASResult

typestate CASAttempt:
  states CASPending, CASSucceeded, CASFailed
  transitions:
    CASPending -> CASSucceeded
    CASPending -> CASFailed

# Accessors
proc expectedVal*(p: CASPending): int {.inline.} =
  CASAttempt(p).expected

proc desiredVal*(p: CASPending): int {.inline.} =
  CASAttempt(p).desired

proc newVal*(s: CASSucceeded): int {.inline.} =
  CASResult(s).newVal

proc actualVal*(f: CASFailed): int {.inline.} =
  CASResult(f).actualVal

# Constructor
proc prepareCAS*(atom: ptr Atomic[int], expected, desired: int): CASPending {.inline.} =
  CASPending(CASAttempt(atom: atom, expected: expected, desired: desired))

# Execute CAS - returns result that must be checked
proc executeCAS*(p: CASPending): CASResult {.inline.} =
  let attempt = CASAttempt(p)
  var expected = attempt.expected
  let success =
    attempt.atom[].compareExchangeWeak(expected, attempt.desired, moRelease, moAcquire)
  if success:
    CASResult(succeeded: true, newVal: attempt.desired, actualVal: 0)
  else:
    CASResult(succeeded: false, newVal: 0, actualVal: expected)

# Safe extraction
proc assumeSuccess*(r: CASResult): CASSucceeded {.inline.} =
  assert r.succeeded, "CAS did not succeed"
  CASSucceeded(r)

proc assumeFailure*(r: CASResult): CASFailed {.inline.} =
  assert not r.succeeded, "CAS did not fail"
  CASFailed(r)
