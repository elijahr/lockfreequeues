# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## SPMC Pop operation lifecycle typestate.
##
## Enforces correct sequencing for multi-consumer pop:
## Start -> LoadPointers -> CheckEmpty -> CheckCommitted -> TryClaim -> Complete
##
## Key invariant: Once a slot is claimed, it MUST be consumed. No abandonment.

import atomics
import options
import typestates

import ./virtual_values_n
import ./storage_n
import ./committed_flags_n
import ./atomic_loaders
import ./fullness_checks

type
  SPMCPopStart*[N: static int] = object
    ## Entry point. No data yet.

  SPMCPopPointersLoaded*[N: static int] = object
    ## Loaded reservedHead and tail.
    reservedHead*: WrappedValueN[N]
    tail*: WrappedValueN[N]

  SPMCPopNotEmpty*[N: static int] = object
    ## Confirmed queue has items.
    reservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPopSlotReady*[N: static int] = object
    ## Slot is committed - safe to claim.
    reservedHead*: WrappedValueN[N]
    newReservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPopSlotClaimed*[N: static int] = object
    ## CAS succeeded - we own this slot. MUST consume it.
    newReservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPopEmpty* = object
    ## Terminal: queue was empty.


typestate SPMCPopOp[N]:
  states SPMCPopStart[N], SPMCPopPointersLoaded[N], SPMCPopNotEmpty[N],
         SPMCPopSlotReady[N], SPMCPopSlotClaimed[N], SPMCPopEmpty
  transitions:
    SPMCPopStart[N] -> SPMCPopPointersLoaded[N]
    SPMCPopPointersLoaded[N] -> SPMCPopNotEmpty[N] | SPMCPopEmpty
    SPMCPopNotEmpty[N] -> SPMCPopSlotReady[N] | SPMCPopStart[N]
    SPMCPopSlotReady[N] -> SPMCPopSlotClaimed[N] | SPMCPopStart[N]
