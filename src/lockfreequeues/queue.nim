import atomics

type
  Queue* = concept q
    q.head is Atomic[int]
    q.tail is Atomic[int]
    q.storage is array
    q.capacity is int
