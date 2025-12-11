## N+1-slot virtual values for SPSC queue.
##
## SPSC uses N+1 slots to distinguish full from empty without flags.
## Virtual space is 0..<2*(N+1). Uses `mod (N+1)` for slot calculation.

import typestates

type
  VirtualValueN1*[N: static int] = object
    v: int

  RawLoadedN1*[N: static int] = distinct VirtualValueN1[N]
  WrappedValueN1*[N: static int] = distinct VirtualValueN1[N]
  UnwrappedSumN1*[N: static int] = distinct VirtualValueN1[N]
  PhysicalSlotN1*[N: static int] = distinct VirtualValueN1[N]

typestate VirtualValueN1[N: static int]:
  consumeOnTransition = false
  states RawLoadedN1[N], WrappedValueN1[N], UnwrappedSumN1[N], PhysicalSlotN1[N]
  transitions:
    RawLoadedN1[N] -> WrappedValueN1[N]
    WrappedValueN1[N] -> UnwrappedSumN1[N]
    UnwrappedSumN1[N] -> WrappedValueN1[N]
    WrappedValueN1[N] -> PhysicalSlotN1[N]
    WrappedValueN1[N] -> WrappedValueN1[N]


# Accessors
proc rawValue*[N: static int](r: RawLoadedN1[N]): int {.inline.} =
  VirtualValueN1[N](r).v

proc value*[N: static int](w: WrappedValueN1[N]): int {.inline.} =
  VirtualValueN1[N](w).v

proc unwrappedValue*[N: static int](u: UnwrappedSumN1[N]): int {.inline.} =
  VirtualValueN1[N](u).v

proc slotValue*[N: static int](p: PhysicalSlotN1[N]): int {.inline.} =
  VirtualValueN1[N](p).v


# Constructor
proc initRawN1*[N: static int](val: int): RawLoadedN1[N] {.inline.} =
  RawLoadedN1[N](VirtualValueN1[N](v: val))


# Transitions - KEY DIFFERENCE: uses (N+1) not N
proc validate*[N: static int](r: RawLoadedN1[N]): WrappedValueN1[N] {.inline, transition.} =
  let val = r.rawValue
  assert val >= 0 and val < 2 * (N + 1), "Value " & $val & " out of range 0..<" & $(2*(N+1))
  WrappedValueN1[N](VirtualValueN1[N](v: val))

proc add*[N: static int](w: WrappedValueN1[N], amount: int): UnwrappedSumN1[N] {.inline, transition.} =
  assert amount >= 0 and amount <= N, "Amount " & $amount & " out of range 0.." & $N
  UnwrappedSumN1[N](VirtualValueN1[N](v: w.value + amount))

proc wrapIfNeeded*[N: static int](u: UnwrappedSumN1[N]): WrappedValueN1[N] {.inline, transition.} =
  var val = u.unwrappedValue
  if val >= 2 * (N + 1):
    val -= 2 * (N + 1)
  WrappedValueN1[N](VirtualValueN1[N](v: val))

proc index*[N: static int](w: WrappedValueN1[N]): PhysicalSlotN1[N] {.inline, transition.} =
  ## KEY: mod (N+1), not mod N!
  let slot = w.value mod (N + 1)
  PhysicalSlotN1[N](VirtualValueN1[N](v: slot))

proc incOrResetN1*[N: static int](w: WrappedValueN1[N], amount: int): WrappedValueN1[N] {.inline, transition.} =
  w.add(amount).wrapIfNeeded()
