import unittest
import lockfreequeues

suite "lockfreequeues":
  test "hello returns expected greeting":
    check hello() == "hello from lockfreequeues"

  test "version present":
    check projectVersion == "0.0.1"
