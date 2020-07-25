
type
  ProducerState* = enum
    Synchronized, ## The Producer's tail has been synchronized to the Queue
    Reserved,  ## The Producer is in the process of updating storage
    Pending, ## The Producer has updated storage and is waiting to synchronize

  Producer* = object
    ## A state machine for managing updates of Mupsic queue tails.

    tail*: uint32 ## \
      ## The tail of the queue once this producer is synchronized.

    state*: ProducerState ## \
      ## The state of this producer. Defaults to `Synchronized`.

    prevPid*: uint16 ## \
      ## The ID (index) of the Producer which has reserved the preceding storage
      ## block.w


proc `==`*(x, y: Producer): bool =
  result = (
    x.tail == y.tail and
    x.state == y.state and
    x.prevPid == y.prevPid
  )
