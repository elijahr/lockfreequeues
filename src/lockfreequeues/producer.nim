# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

# import atomics

import ./constants
# import ./atomic_dsl

type
  ProducerState* = enum
    Synchronized, ## The Producer's tail has been synchronized to the Queue
    Reserved,  ## The Producer is in the process of updating storage
    Pending, ## The Producer has updated storage and is waiting to synchronize

  Producer* = object
    ## A state machine for managing updates of Mupsic queue tails.

    tail* {.align: CacheLineBytes.}: int ## \
      ## The tail of the queue once this producer is synchronized.

    state*: ProducerState ## \
      ## The state of this producer. Defaults to `Synchronized`.

    prevPid*: int ## \
      ## The ID (index) of the Producer which has reserved the preceding storage
      ## block.w

  # PackedAtomicProducer* = PackedAtomic[Producer, int64]


proc `==`*(x, y: Producer): bool =
  result = (
    x.tail == y.tail and
    x.state == y.state and
    x.prevPid == y.prevPid
  )
