## Constants used by lockfreequeues

# The size of a cache line (128 bytes on PowerPC, 64 bytes elsewhere)
const CacheLineBytes* {.intdefine.} = when defined(powerpc): 128 else: 64
