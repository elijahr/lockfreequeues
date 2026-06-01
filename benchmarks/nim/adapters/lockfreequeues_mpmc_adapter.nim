## Adapter for lockfreequeues Mpmc-equivalent (bounded MPMC).
##
## File naming follows the `<library_slug>_adapter.nim` convention.
## `topologiesSupported` is exported here for the bench-driver registry.
##
## Note: Mpmc-equiv requires using Producer/Consumer views for
## push/pop. This adapter manages those internally for single-threaded
## testing. For multi-threaded benchmarks, use getProducer/getConsumer
## on the underlying queue directly.
##
## The legacy `Mpmc[N, P, C, T]` type has been removed in favour of
## the unified `Queue[T, ccMulti, ccMulti, stEager, rkNone, N, P, C,
## 0, 0]` generic. The adapter surface (`initMpmcAdapter`,
## `deinitMpmcAdapter`, `cleanup`, `push`, `pop`, `name`) is
## preserved verbatim.

import options
import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import ../bench_common

const topologiesSupported*: set[Topology] = {tMpmc}

type
  MpmcAdapterQueue[N: static int, T] =
    BQueue[T, ccMulti, ccMulti, N, 1, 1]
  MpmcAdapterProducer[N: static int, T] =
    Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, 1, 1]]
  MpmcAdapterConsumer[N: static int, T] =
    Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, 1, 1]]

  MpmcAdapter*[N: static int, T] = object
    queue: ptr MpmcAdapterQueue[N, T]
    producer: MpmcAdapterProducer[N, T]
    consumer: MpmcAdapterConsumer[N, T]

proc initMpmcAdapter*[N: static int, T](): MpmcAdapter[N, T] =
  result.queue = create(MpmcAdapterQueue[N, T])
  # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
  # ARC/ORC, so `result.queue[] = ...` would run the BQueue typestate
  # `=destroy` on uninitialized storage. Mark the slot moved-from first.
  wasMoved(result.queue[])
  result.queue[] = newBQueue[T, ccMulti, ccMulti, N, 1, 1]()
  # Use idx parameter to manually assign producer/consumer for single-threaded
  # use AND for multi-threaded ping-pong (bench_common.runLatencyHarness):
  # `getProducer(idx = 0)` skips the threadId-based registration path, so the
  # returned object is safe to call from any thread for the bench's 1P/1C
  # smoke shape (only one producer/consumer slot exists, and the underlying
  # Vyukov per-slot CAS protocol is fully concurrent-safe).
  result.producer = result.queue[].getProducerHere(idx = 0)
  result.consumer = result.queue[].getConsumerHere(idx = 0)

proc deinitMpmcAdapter*[N: static int, T](a: var MpmcAdapter[N, T]) =
  # Reset the cached producer/consumer views BEFORE deallocating the queue
  # they borrow from. Both views hold a pointer into `a.queue[]` and carry a
  # typestate `=destroy` that would otherwise run at adapter scope exit
  # (after this proc returns and the queue is freed), touching freed memory.
  # reset() runs their destructors now, while the queue is still valid.
  if a.queue != nil:
    reset(a.producer)
    reset(a.consumer)
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc cleanup*[N: static int, T](a: var MpmcAdapter[N, T]) =
  ## Alias for `deinitMpmcAdapter` matching the lockfreequeues bounded
  ## adapter naming convention. Lets the bench harness drop the queue
  ## via a uniform `cleanup(queue)` mixin call.
  deinitMpmcAdapter(a)

proc push*[N: static int, T](a: var MpmcAdapter[N, T], item: T): PushResult =
  if a.producer.push(item): prSuccess else: prFull

proc pop*[N: static int, T](a: var MpmcAdapter[N, T]): PopResult[T] =
  let item = a.consumer.pop()
  if item.isSome:
    PopResult[T](success: true, value: item.get)
  else:
    PopResult[T](success: false)

proc name*[N: static int, T](a: MpmcAdapter[N, T]): string =
  "lockfreequeues/Mpmc[" & $N & "]"
