# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer bounded queue implemented as a ring
## buffer.


type
  State* = object
    ## An object which holds the head and tail indices for a queue.
    head*: int
    tail*: int
