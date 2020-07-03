# Package
version       = "0.1.0"
author        = "Elijah Shaw-Rutschman"
description   = "Single-producer, single-consumer, lock-free queue implementations for Nim."
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.2.0"

# Tasks
task make_docs, "Generate documentation":
  exec "sh bin/make_docs.sh"

task test, "Runs the test suite":
  exec "nim c -r tests/test"
