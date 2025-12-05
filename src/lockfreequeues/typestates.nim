# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Re-exports all typestate types for convenient importing.

# N-slot types (MPSC/SPMC/MPMC)
import ./typestates/virtual_values_n
import ./typestates/storage_n
import ./typestates/committed_flags_n

# N+1-slot types (SPSC)
import ./typestates/virtual_values_n1
import ./typestates/storage_n1

# Shared
import ./typestates/cas
import ./typestates/atomic_loaders
import ./typestates/fullness_checks

# Operation lifecycle typestates
import ./typestates/spmc_pop

# Old types for backward compatibility (will be removed after full migration)
import ./typestates/fullness
import ./typestates/atomic_values
import ./typestates/index_types

export virtual_values_n
export storage_n
export committed_flags_n
export virtual_values_n1
export storage_n1
export cas
export atomic_loaders
export fullness_checks
export spmc_pop
export fullness  # Backward compatibility
export atomic_values  # Backward compatibility
export index_types  # Backward compatibility
