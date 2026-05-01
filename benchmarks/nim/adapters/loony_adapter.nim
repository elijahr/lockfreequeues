## Adapter for the Loony unbounded MPMC queue.
##
## Loony is a third-party Nim package (https://github.com/shayanhabibi/loony,
## MIT-licensed). It exposes ``LoonyQueue[T]`` (a ref) created via
## ``newLoonyQueue[T]()``, with ``push(q, item)`` and ``pop(q): T``.
##
## **Storage constraint.** Loony stores its items as ``uint`` and uses the
## low 3 bits as ``RESUME``/``WRITER``/``READER`` slot-state flags
## (``loony/spec.nim``: ``SLOTMASK = ~0x7``). Loony's empty-slot detection
## reads ``(prev and SLOTMASK) == 0`` — i.e. it treats a zero "pointer"
## payload as "this slot is empty". Loony was designed for ref/ptr types
## whose addresses are 8-byte-aligned and never zero. Pushing the literal
## value ``0`` (or any value whose low 3 bits are non-zero) breaks Loony.
##
## To keep the harness's ``push(uint64(i))`` payload semantics intact for
## ``i in 0 ..< N``, this adapter encodes ``v`` as ``(v + 1) shl 3`` on
## push and ``(raw shr 3) - 1`` on pop. The ``+1`` ensures the encoded
## value is never zero (so it can never be misread as an empty slot); the
## ``shl 3`` keeps the low flag bits clear. This is documentation-
## equivalent to the way Loony users push ``ref`` values with naturally-
## non-null, naturally-aligned addresses; it does NOT change the queue
## algorithm.
##
## ``pop`` returns the default-constructed value of ``T`` when the queue is
## empty, so this adapter consults ``isEmpty(q)`` before each pop.
##
## Topology: ``mpmc_unbounded``. Capacity argument is ignored.
##
## Compile-time gating: only included when
## ``-d:adapter_loony_available`` is passed. The bench binary's
## ``when declared(makeLoonyAdapter):`` block enables the slug only when
## the gate is set.

when defined(adapter_loony_available):
  import loony
  import ../bench_common
  import ../adapter

  const topologiesSupported* = {tMpmcUnbounded}
  const LoonyTagShift* = 3
    ## Number of low bits Loony reserves for slot-state flags. Items with
    ## non-zero bits in this region collide with RESUME/WRITER/READER.

  type LoonyAdapter*[T] = object
    queue*: LoonyQueue[uint64]
      # We always store ``uint64`` regardless of the harness's ``T`` because
      # we need to control the low-bit aliasing. ``T`` is constrained to
      # ``uint64`` by the harness today.

  proc makeLoonyAdapter*[T](capacity: int = 0): LoonyAdapter[T] =
    ## ``capacity`` is ignored — Loony is unbounded.
    discard capacity
    result.queue = newLoonyQueue[uint64]()

  proc cleanup*[T](a: var LoonyAdapter[T]) =
    ## ``LoonyQueue[uint64]`` is a ``ref``; let GC reclaim it when the
    ## adapter goes out of scope.
    discard a

  proc push*[T](a: var LoonyAdapter[T], item: T): PushResult =
    a.queue.push((uint64(item) + 1'u64) shl LoonyTagShift)
    prSuccess

  proc pop*[T](a: var LoonyAdapter[T]): PopResult[T] =
    if a.queue.isEmpty():
      PopResult[T](success: false)
    else:
      let raw = a.queue.pop()
      PopResult[T](success: true, value: T((raw shr LoonyTagShift) - 1'u64))

  proc name*[T](a: LoonyAdapter[T]): string =
    "loony/LoonyQueue[" & $T & "]"
