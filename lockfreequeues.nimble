import os

# Package
version = "5.1.4"
author = "Elijah Shaw-Rutschman"
description = "Compatibility facade for lockfree — lock-free queues for Nim."
license = "MIT"
srcDir = "src"
entryPoints = @["tests/test.nim"]

# Dependencies
requires "nim >= 2.2.10"
requires "unittest2"
requires "lockfree == 0.6.3"

# Tasks
task test, "Runs the test suite":
  let nimcacheBase = getHomeDir() / ".cache" / "nim"

  # C with default MM (orc) and lock-free atomic enforcement (ensures no spinlock fallback)
  exec "nim c --mm:orc -d:nimEnforceLockFreeAtomics --threads:on --nimcache:" &
    quoteShell(nimcacheBase / "lockfreequeues_orc") & " -r tests/test.nim"

  # C++
  exec "nim cpp --threads:on --nimcache:" &
    quoteShell(nimcacheBase / "lockfreequeues_cpp") & " -r tests/test.nim"

  # Test with different memory managers (arc with lock-free atomic enforcement, refc)
  exec "nim c --mm:arc -d:nimEnforceLockFreeAtomics --threads:on --nimcache:" &
    quoteShell(nimcacheBase / "lockfreequeues_arc") & " -r tests/test.nim"
  exec "nim c --mm:refc --threads:on --nimcache:" &
    quoteShell(nimcacheBase / "lockfreequeues_refc") & " -r tests/test.nim"

  if getEnv("SANITIZE_THREADS") != "no":
    # C (with thread sanitization, requires atomicArc for thread-safe refcounting)
    exec "nim c --cc:clang --mm:atomicArc --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on --nimcache:" &
      quoteShell(nimcacheBase / "lockfreequeues_tsan") & " -r tests/test.nim"

  if getEnv("SANITIZE_ADDRESS") != "no":
    # C (with address sanitization)
    exec "nim c --cc:clang --passC:\"-fsanitize=address\" --passL:\"-fsanitize=address\" --threads:on --nimcache:" &
      quoteShell(nimcacheBase / "lockfreequeues_asan") & " -r tests/test.nim"

task examples, "Runs the examples":
  # Bounded queue examples
  exec "nim c --threads:on -r -f examples/sipsic.nim"
  exec "nim c --threads:on -r -f examples/sipmuc.nim"
  exec "nim c --threads:on -r -f examples/mupsic.nim"
  exec "nim c --threads:on -r -f examples/mupmuc.nim"
  # Advanced examples
  exec "nim c --threads:on -r -f examples/audio_buffer.nim"
  exec "nim c --threads:on -r -f examples/task_fanout.nim"
  exec "nim c --threads:on -r -f examples/event_collector.nim"
  exec "nim c --threads:on -r -f examples/job_scheduler.nim"
