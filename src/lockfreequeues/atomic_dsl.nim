# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics


# Load shortcuts

proc relaxed*[T](location: var Atomic[T]): T {.inline.} =
  result = location.load(moRelaxed)


proc consume*[T](location: var Atomic[T]): T {.inline.} =
  result = location.load(moConsume)


proc acquire*[T](location: var Atomic[T]): T {.inline.} =
  result = location.load(moAcquire)


proc release*[T](location: var Atomic[T]): T {.inline.} =
  result = location.load(moRelease)


proc acquireRelease*[T](location: var Atomic[T]): T {.inline.} =
  result = location.load(moAcquireRelease)


proc sequential*[T](location: var Atomic[T]): T {.inline.} =
  result = location.load(moSequentiallyConsistent)


# proc relaxed*[U, P](location: var PackedAtomic[U, P]): U {.inline.} =
#   result = location.load(moRelaxed)


# proc consume*[U, P](location: var PackedAtomic[U, P]): U {.inline.} =
#   result = location.load(moConsume)


# proc acquire*[U, P](location: var PackedAtomic[U, P]): U {.inline.} =
#   result = location.load(moAcquire)


# proc release*[U, P](location: var PackedAtomic[U, P]): U {.inline.} =
#   result = location.load(moRelease)


# proc acquireRelease*[U, P](location: var PackedAtomic[U, P]): U {.inline.} =
#   result = location.load(moAcquireRelease)


# proc sequential*[U, P](location: var PackedAtomic[U, P]): U {.inline.} =
#   result = location.load(moSequentiallyConsistent)


# Store shortcuts

proc relaxed*[T](location: var Atomic[T], value: T) {.inline.} =
  location.store(value, moRelaxed)


proc consume*[T](location: var Atomic[T], value: T) {.inline.} =
  location.store(value, moConsume)


proc acquire*[T](location: var Atomic[T], value: T) {.inline.} =
  location.store(value, moAcquire)


proc release*[T](location: var Atomic[T], value: T) {.inline.} =
  location.store(value, moRelease)


proc acquireRelease*[T](location: var Atomic[T], value: T) {.inline.} =
  location.store(value, moAcquireRelease)


proc sequential*[T](location: var Atomic[T], value: T) {.inline.} =
  location.store(value, moSequentiallyConsistent)


# proc relaxed*[U, P](location: var PackedAtomic[U, P], value: U) {.inline.} =
#   location.store(value, moRelaxed)


# proc consume*[U, P](location: var PackedAtomic[U, P], value: U) {.inline.} =
#   location.store(value, moConsume)


# proc acquire*[U, P](location: var PackedAtomic[U, P], value: U) {.inline.} =
#   location.store(value, moAcquire)


# proc release*[U, P](location: var PackedAtomic[U, P], value: U) {.inline.} =
#   location.store(value, moRelease)


# proc acquireRelease*[U, P](location: var PackedAtomic[U, P], value: U) {.inline.} =
#   location.store(value, moAcquireRelease)


# proc sequential*[U, P](location: var PackedAtomic[U, P], value: U) {.inline.} =
#   location.store(value, moSequentiallyConsistent)


# Extras

proc compareExchangeWeakReleaseRelaxed*[T](
  location: var Atomic[T],
  expected: var T,
  desired: T,
): bool
  {.inline.} =
  result = compareExchangeWeak(
    location,
    expected,
    desired,
    moRelease,
    moRelaxed,
  )


# proc compareExchangeWeakReleaseRelaxed*[U, P](
#   location: var PackedAtomic[U, P],
#   expected: var U,
#   desired: U,
# ): bool
#   {.inline.} =
#   var expectedPacked = cast[P](expected)
#   location.atom.compareExchangeWeakReleaseRelaxed(
#     expectedPacked,
#     cast[P](desired),
#   )
#   expected = cast[U](expectedPacked)
