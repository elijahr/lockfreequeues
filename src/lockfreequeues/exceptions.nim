# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Common exception types for lockfreequeues.

type InvalidCallDefect* = object of Defect
  ## Raised when a queue method is called incorrectly.
  ## For example, calling `queue.push()` directly on an MPSC queue instead of using `Producer.push()`.
