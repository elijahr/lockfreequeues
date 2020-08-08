# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Example usage of Sipsic, a single-producer, single-consumer bounded queue.

import atomics
import options
import random
import sequtils
import threadpool

import lockfreequeues

const
  itemCount = 30

var
  # Queue that can hold 8 ints
  queue = initSipsic[8, int]()


proc consumerFunc(): seq[int] {.gcsafe.} =
  result = @[]
  while result.len < itemCount:

    # Pop many items from the queue
    let items = queue.pop(itemCount)
    if items.isSome:
      result.insert(items.get, result.len)

    # Pop a single item from the queue
    let item = queue.pop()
    if item.isSome:
      result.add(item.get)
    cpuRelax()


proc producerFunc() {.gcsafe.} =
  for i in 0..<itemCount:
    let item = rand(100)

    if i mod 2 == 0:
      # Push a single item to the queue
      while not queue.push(item):
        cpuRelax()

    else:
      # Push a sequence to the queue
      while queue.push(@[item]).isSome:
        cpuRelax()

    echo "Pushed item: ", item


let consumedFlow = spawn consumerFunc()
spawn producerFunc()
sync()
echo "Popped items: ", ^consumedFlow
