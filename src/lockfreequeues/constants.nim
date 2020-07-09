# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Constants used by lockfreequeues

const CACHELINE_BYTES* = when defined(powerpc):
  128 ## The size of a cache line (128 bytes on PowerPC)
else:
  64 ## The size of a cache line (64 bytes on x86).