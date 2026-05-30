## Example: MPSC (multi-producer, single-consumer) `BQueue` with the
## v5.0.0 static-affinity endpoint API.
##
## Producers obtain a per-thread endpoint via `q.getProducerHere()`
## (sugar for `getProducer().bindToThread()`); the result is a
## `Bound[T, AnyThreadTag, BQueue[…]]` on which `push` is callable
## with role-tag-checked effects. The single consumer uses
## `q.bindConsumer()` for the symmetric one-shot wrapper (MPSC has
## ccCons=ccSingle, so there is exactly one consumer endpoint).
##
## See `docs/migrations/v5.0.0.md` for the full API guide.

import options
import random

import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags

var q = initBQueue[int, ccMulti, ccSingle, 8, 32, 0]()

proc consumerFunc() {.thread, gcsafe.} =
  for i in 0 .. 32:
    let item = q.pop() # bare-BQueue pop still exists for SC consumer.
    echo "[consumer] popped item: ", item
    let items = q.pop(4)
    echo "[consumer] popped items: ", items

proc producerFunc() {.thread, gcsafe.} =
  # Get a per-thread Bound producer endpoint.
  var producer = q.getProducerHere()
  let item = rand(100)
  echo "[producer ", producer.idx, "] pushed item: ", item, "? ",
    producer.push(item)
  let items = @[rand(100), rand(100), rand(100), rand(100)]
  let pushed = producer.push(items) # batch push returns count pushed
  echo "[producer ", producer.idx, "] pushed ", pushed, "/", items.len,
    " items: ", items[0 ..< pushed]

var threads: array[33, Thread[void]]
threads[0].createThread(consumerFunc)
for p in 1 .. 32:
  threads[p].createThread(producerFunc)
joinThreads(threads)
