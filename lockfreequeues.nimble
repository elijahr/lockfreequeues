# Package
version       = "2.0.0"
author        = "Elijah Shaw-Rutschman"
description   = "Lock-free queue implementations for Nim."
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.2.0"

# Tasks
task make_docs, "Generate documentation":
  exec "sh bin/make_docs.sh"

task test, "Runs the test suite (C & C++)":
  exec "nim c -r tests/test.nim"
  exec "nim cpp -r tests/test.nim"

task examples, "Runs the examples":
  exec "nim c -r examples/mupmuc.nim"
  exec "nim c -r examples/mupsic.nim"
  exec "nim c -r examples/sipsic.nim"
