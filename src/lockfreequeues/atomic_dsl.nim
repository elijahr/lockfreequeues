# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Readable shortcuts to `atomics.load()` and `atomics.store()`.

import atomics


type
  Trivial* = SomeNumber | bool | enum | ptr | pointer
    # A type that is known to be atomic and whose size is known at
    # compile time to be 8 bytes or less


proc relaxed*[T: Trivial](location: var Atomic[T]): T {.inline.} =
  ## Load the value from location using moRelaxed
  result = location.load(moRelaxed)


proc acquire*[T: Trivial](location: var Atomic[T]): T {.inline.} =
  ## Load the value from location using moAcquire
  result = location.load(moAcquire)


proc sequential*[T: Trivial](location: var Atomic[T]): T {.inline.} =
  ## Load the value from location using moSequentiallyConsistent
  result = location.load(moSequentiallyConsistent)


proc relaxed*[T: Trivial](location: var Atomic[T], desired: T) {.inline.} =
  ## Store the value in location using moRelaxed
  location.store(desired, moRelaxed)


proc release*[T: Trivial](location: var Atomic[T], desired: T) {.inline.} =
  ## Store the value in location using moRelease
  location.store(desired, moRelease)


proc sequential*[T: Trivial](location: var Atomic[T], desired: T) {.inline.} =
  ## Store the value in location using moSequentiallyConsistent
  location.store(desired, moSequentiallyConsistent)

