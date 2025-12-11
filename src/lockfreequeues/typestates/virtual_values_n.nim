## N-slot virtual values for MPSC/SPMC/MPMC queues.
##
## These queues use N slots with committed flags. Virtual space is 0..<2*N.
## Key invariant: `mod N` is used for physical slot calculation.

import typestates

type
  VirtualValueN*[N: static int] = object
    ## Base type for N-slot virtual values.
    ## Value field is PRIVATE - only extractable via state-specific accessors.
    v: int

  RawLoadedN*[N: static int] = distinct VirtualValueN[N]
    ## Just loaded from atomic - not yet validated.

  WrappedValueN*[N: static int] = distinct VirtualValueN[N]
    ## Validated to be in range 0..<2*N.

  UnwrappedSumN*[N: static int] = distinct VirtualValueN[N]
    ## Result of addition - may be >= 2*N, must wrap before use.

  PhysicalSlotN*[N: static int] = distinct VirtualValueN[N]
    ## Storage index in range 0..<N. Only obtainable via index().

typestate VirtualValueN[N: static int]:
  consumeOnTransition = false
  states RawLoadedN[N], WrappedValueN[N], UnwrappedSumN[N], PhysicalSlotN[N]
  transitions:
    RawLoadedN[N] -> WrappedValueN[N]      # validate()
    WrappedValueN[N] -> UnwrappedSumN[N]   # add()
    UnwrappedSumN[N] -> WrappedValueN[N]   # wrapIfNeeded()
    WrappedValueN[N] -> PhysicalSlotN[N]   # index()
    WrappedValueN[N] -> WrappedValueN[N]   # incOrResetN() - convenience


# Accessors - only specific fields visible in each state
proc rawValue*[N: static int](r: RawLoadedN[N]): int {.inline.} =
  VirtualValueN[N](r).v

proc value*[N: static int](w: WrappedValueN[N]): int {.inline.} =
  VirtualValueN[N](w).v

proc unwrappedValue*[N: static int](u: UnwrappedSumN[N]): int {.inline.} =
  VirtualValueN[N](u).v

proc slotValue*[N: static int](p: PhysicalSlotN[N]): int {.inline.} =
  VirtualValueN[N](p).v


# Constructor
proc initRawN*[N: static int](val: int): RawLoadedN[N] {.inline.} =
  ## Create a raw loaded value (from atomic load).
  RawLoadedN[N](VirtualValueN[N](v: val))


# Transitions
proc validate*[N: static int](r: RawLoadedN[N]): WrappedValueN[N] {.inline, transition.} =
  ## Validate that raw value is in range 0..<2*N.
  let val = r.rawValue
  assert val >= 0 and val < 2 * N, "Value " & $val & " out of range 0..<" & $(2*N)
  WrappedValueN[N](VirtualValueN[N](v: val))

proc add*[N: static int](w: WrappedValueN[N], amount: int): UnwrappedSumN[N] {.inline, transition.} =
  ## Add to wrapped value. Result may need wrapping.
  assert amount >= 0 and amount <= N, "Amount " & $amount & " out of range 0.." & $N
  UnwrappedSumN[N](VirtualValueN[N](v: w.value + amount))

proc wrapIfNeeded*[N: static int](u: UnwrappedSumN[N]): WrappedValueN[N] {.inline, transition.} =
  ## Wrap value back into range 0..<2*N if needed.
  var val = u.unwrappedValue
  if val >= 2 * N:
    val -= 2 * N
  WrappedValueN[N](VirtualValueN[N](v: val))

proc index*[N: static int](w: WrappedValueN[N]): PhysicalSlotN[N] {.inline, transition.} =
  ## Convert to physical slot using mod N.
  let slot = w.value mod N
  PhysicalSlotN[N](VirtualValueN[N](v: slot))


# Convenience - combines add + wrapIfNeeded
proc incOrResetN*[N: static int](w: WrappedValueN[N], amount: int): WrappedValueN[N] {.inline, transition.} =
  ## Increment and wrap in one step.
  w.add(amount).wrapIfNeeded()
