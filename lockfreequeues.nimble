# Package
version       = "2.0.0"
author        = "Elijah Shaw-Rutschman"
description   = "Lock-free queue implementations for Nim."
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.2.4"

# Tasks
task make_docs, "Generate documentation":
  exec "sh bin/make_docs.sh"

task test, "Runs the test suite (C & C++)":
  exec "nim c -r -f tests/test.nim"
  exec "nim cpp -r -f tests/test.nim"

task examples, "Runs the examples":
  exec "nim c -r -f examples/mupmuc.nim"
  exec "nim c -r -f examples/mupsic.nim"
  exec "nim c -r -f examples/sipsic.nim"
