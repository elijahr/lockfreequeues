# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Readable shortcuts to `atomics.load()` and `atomics.store()`.

import atomics


proc relaxed*[T](location: var Atomic[T]): T {.inline.} =
  ## Load the value from location using moRelaxed
  result = location.load(moRelaxed)


proc acquire*[T](location: var Atomic[T]): T {.inline.} =
  ## Load the value from location using moAcquire
  result = location.load(moAcquire)


proc sequential*[T](location: var Atomic[T]): T {.inline.} =
  ## Load the value from location using moSequentiallyConsistent
  result = location.load(moSequentiallyConsistent)


proc release*[T](location: var Atomic[T], value: T) {.inline.} =
  ## Store the value in location using moRelease
  location.store(value, moRelease)
