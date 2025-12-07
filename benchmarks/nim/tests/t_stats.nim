

import unittest2
import std/math
import ../stats

suite "Statistics":
  test "mean":
    check mean([1.0, 2.0, 3.0, 4.0, 5.0]) == 3.0
    check mean([10.0]) == 10.0
    check mean(newSeq[float]()) == 0.0

  test "stddev":
    let data = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
    let sd = stddev(data)
    check abs(sd - 2.138) < 0.01

  test "percentile":
    let data = @[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
    check percentile(data, 0.5) == 5.0
    check percentile(data, 0.9) == 9.0

  test "min max":
    let data = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0]
    check minVal(data) == 1.0
    check maxVal(data) == 9.0
