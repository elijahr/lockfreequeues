# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Constants used by lockfreequeues

# The size of a cache line (128 bytes on PowerPC, 64 bytes elsewhere)
const CacheLineBytes* {.intdefine.} = when defined(powerpc):
  128
else:
  64
