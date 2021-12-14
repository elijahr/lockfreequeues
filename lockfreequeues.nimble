import os

# Package
version       = "3.0.0"
author        = "Elijah Shaw-Rutschman"
description   = "Lock-free queue implementations for Nim."
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.2.0"

# Tasks
task test, "Runs the test suite":
  # C
  exec "nim c -r -f tests/test.nim"

  # C++
  exec "nim cpp -r -f tests/test.nim"

  if getEnv("SANITIZE_THREADS") != "no":
    # C (with thread sanitization)
    exec "nim c --cc:clang --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" -r -f tests/test.nim"


task examples, "Runs the examples":
  exec "nim c -r -f examples/mupmuc.nim"
  exec "nim c -r -f examples/mupsic.nim"
  exec "nim c -r -f examples/sipsic.nim"
