import debra/atomics
import debra/atomics/dsl
import options
import unittest2

import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "wraparound":
  test "basic":
    var q = newSpscQueue[string, 2]()
    check q.head.load == 0
    check q.tail.load == 0

    discard q.push "a"
    check q.head.load == 0
    check q.tail.load == 1

    discard q.push "b"
    check q.head.load == 0
    check q.tail.load == 2

    check q.pop.get == "a"
    check q.head.load == 1
    check q.tail.load == 2

    check q.pop.get == "b"
    check q.head.load == 2
    check q.tail.load == 2

    discard q.push "c"
    check q.head.load == 2
    check q.tail.load == 3

    discard q.push "d"
    check q.head.load == 2
    check q.tail.load == 4

    check q.pop.get == "c"
    check q.head.load == 3
    check q.tail.load == 4

    check q.pop.get == "d"
    check q.head.load == 4
    check q.tail.load == 4
