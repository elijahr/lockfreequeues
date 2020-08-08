# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage of Mupsic, a multi-producer, single-consumer bounded queue.

import options
import random
import threadpool

import lockfreequeues

var
  # Queue that can hold 8 ints, with MaxThreadPoolSize producer/consumer threads
  queue = initMupmuc[8, MaxThreadPoolSize, MaxThreadPoolSize, int]()


proc consumerFunc() {.gcsafe.} =
  # Get a unique consumer for this thread
  var consumer = queue.getConsumer()

  while true:
    # Pop a single item from the queue
    let item = consumer.pop()
    if item.isSome:
      echo "Popped item: ", item.get
      break
    cpuRelax()


proc producerFunc() {.gcsafe.} =
  # Get a unique producer for this thread
  var producer = queue.getProducer()

  let item = rand(100)
  while not producer.push(item):
    cpuRelax()

  echo "Pushed item: ", item

for i in 0..<MaxThreadPoolSize:
  spawn producerFunc()
  spawn consumerFunc()

sync()
