## Adapter for lockfreequeues Mupmuc (bounded MPMC)
##
## Note: Mupmuc requires using Producer/Consumer objects for push/pop.
## This adapter manages those internally for single-threaded testing.
## For multi-threaded benchmarks, use getProducer/getConsumer directly.

import options
import lockfreequeues/mupmuc
import ../adapter

type
  MupmucAdapter*[N: static int, T] = object
    queue: ptr Mupmuc[N, 1, 1, T]
    producer: MupmucProducer[N, 1, 1, T]
    consumer: Consumer[N, 1, 1, T]

proc initMupmucAdapter*[N: static int, T](): MupmucAdapter[N, T] =
  result.queue = create(Mupmuc[N, 1, 1, T])
  result.queue[] = initMupmuc[N, 1, 1, T]()
  # Use idx parameter to manually assign producer/consumer for single-threaded use
  result.producer = result.queue[].getProducer(idx = 0)
  result.consumer = result.queue[].getConsumer(idx = 0)

proc deinitMupmucAdapter*[N: static int, T](a: var MupmucAdapter[N, T]) =
  if a.queue != nil:
    dealloc(a.queue)
    a.queue = nil

proc push*[N: static int, T](a: var MupmucAdapter[N, T], item: T): PushResult =
  if a.producer.push(item):
    prSuccess
  else:
    prFull

proc pop*[N: static int, T](a: var MupmucAdapter[N, T]): PopResult[T] =
  let item = a.consumer.pop()
  if item.isSome:
    newPopResult(item.get)
  else:
    emptyPopResult[T]()

proc name*[N: static int, T](a: MupmucAdapter[N, T]): string =
  "lockfreequeues/Mupmuc[" & $N & "]"
