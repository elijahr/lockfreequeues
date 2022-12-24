# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Readable shortcuts to `atomics.load()` and `atomics.store()`.

import atomics


template relaxed*[T](location: var Atomic[T]): T =
  ## Load the value from location using moRelaxed
  location.load(moRelaxed)


template acquire*[T](location: var Atomic[T]): T =
  ## Load the value from location using moAcquire
  location.load(moAcquire)


template sequential*[T](location: var Atomic[T]): T =
  ## Load the value from location using moSequentiallyConsistent
  location.load(moSequentiallyConsistent)


template relaxed*[T](location: var Atomic[T], value: T) =
  ## Store the value in location using moRelaxed
  location.store(value, moRelaxed)


template release*[T](location: var Atomic[T], value: T) =
  ## Store the value in location using moRelease
  location.store(value, moRelease)


template sequential*[T](location: var Atomic[T], value: T) =
  ## Store the value in location using moSequentiallyConsistent
  location.store(value, moSequentiallyConsistent)
