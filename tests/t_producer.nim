

import unittest

import lockfreequeues/producer


suite "producer":

  test "sanity check":
    require(sizeof(Producer) <= sizeof(int64))

  # test "pack/unpack":
  #   for p in @[
  #     Producer(
  #       tail: 0u32,
  #       state: Synchronized,
  #       prevPid: 0u16,
  #     ),
  #     Producer(
  #       tail: 123456789u32,
  #       state: Reserved,
  #       prevPid: 12345u16,
  #     ),
  #     Producer(
  #       tail: high(uint32),
  #       state: Pending,
  #       prevPid: high(uint16),
  #     ),
  #   ]:
  #     check(p.pack.unpack == p)
