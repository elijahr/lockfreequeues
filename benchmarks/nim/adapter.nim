## Queue adapter interface for benchmarking.
## Each queue implementation must provide these operations.

type
  PushResult* = enum
    prSuccess,    ## Item was pushed
    prFull        ## Queue is full (bounded) or allocation failed

  PopResult*[T] = object
    case success*: bool
    of true:
      value*: T
    of false:
      discard

  ## Generic queue adapter trait
  QueueAdapter*[T] = concept q
    q.push(T) is PushResult
    q.pop() is PopResult[T]
    q.name is string

proc newPopResult*[T](value: T): PopResult[T] =
  PopResult[T](success: true, value: value)

proc emptyPopResult*[T](): PopResult[T] =
  PopResult[T](success: false)
