# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.

type QueueError* = object of CatchableError
type QueueIndexError* = object of QueueError ## \
  ## Raised by various comparison ops to indicate an invalid head or tail value.
type NoProducersAvailableError* = object of QueueError ## \
  ## Raised by `getProducer()` if all producers have been assigned to othe
type NoConsumersAvailableError* = object of QueueError ## \
  ## Raised by `getConsumer()` if all producers have been assigned to other
  ## threads.
