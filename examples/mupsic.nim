# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage of Mupsic, a multi-producer, single-consumer bounded queue.

import atomics
import options
import random
import sequtils
import threadpool

import lockfreequeues

const
  producerCount = 30

var
  # Queue that can hold 8 ints, with 30 producerTails
  queue = initMupsic[8, producerCount, int]()


proc consumerFunc(): seq[int] {.gcsafe.} =
  result = @[]
  while result.len < producerCount:

    # Pop many items from the queue
    let items = queue.pop(producerCount)
    if items.isSome:
      result.insert(items.get, result.len)

    # Pop a single item from the queue
    let item = queue.pop()
    if item.isSome:
      result.add(item.get)
    cpuRelax()


proc producerFunc(producer: int) {.gcsafe.} =
  let item = rand(100)

  if producer mod 2 == 0:
    # Push a single item to the queue
    while not queue.push(producer, item):
      cpuRelax()

  else:
    # Push a sequence to the queue
    while queue.push(producer, @[item]).isSome:
      cpuRelax()

  echo "Pushed item: ", item


let consumedFlow = spawn consumerFunc()

for producer in 0..<producerCount:
  spawn producerFunc(producer)

sync()

echo "Popped items: ", ^consumedFlow
