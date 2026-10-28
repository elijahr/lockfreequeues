# lockfreequeues - High-performance lock-free queues in Nim

const projectVersion* = "0.0.1"

const greetingMsg* = "hello from lockfreequeues"

proc hello*(): string =
  ## Returns standard project greeting string.
  greetingMsg

proc add*(a, b: int): int =
  ## Adds two integers.
  a + b
