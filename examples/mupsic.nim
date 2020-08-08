# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage of Mupsic, a multi-producer, single-consumer bounded queue.

import options
import random
import sequtils
import threadpool

import lockfreequeues

var
  # Queue that can hold 8 ints, with MaxThreadPoolSize maximum producer threads
  queue = initMupsic[8, MaxThreadPoolSize, int]()


proc consumerFunc(): seq[int] {.gcsafe.} =
  result = @[]
  while result.len < MaxThreadPoolSize:

    # Pop many items from the queue
    let items = queue.pop(queue.producerCount)
    if items.isSome:
      result.insert(items.get, result.len)

    # Pop a single item from the queue
    let item = queue.pop()
    if item.isSome:
      result.add(item.get)
    cpuRelax()


proc producerFunc() {.gcsafe.} =
  # Get a unique producer for this thread
  var producer = queue.getProducer()

  let item = rand(100)
  if producer.idx mod 2 == 0:
    # Half the time, push a single item to the queue
    while not producer.push(item):
      cpuRelax()
  else:
    # Half the time, push a sequence to the queue
    while producer.push(@[item]).isSome:
      cpuRelax()

  echo "Pushed item: ", item


let consumedFlow = spawn consumerFunc()

for producer in 0..<MaxThreadPoolSize:
  spawn producerFunc()

sync()

# ^ waits for consumer flow var to return
echo "Popped items: ", repr(^consumedFlow)
