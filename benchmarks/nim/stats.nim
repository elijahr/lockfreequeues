## Statistical functions for benchmark analysis.

import std/[algorithm, math]

proc mean*(data: openArray[float]): float =
  if data.len == 0:
    return 0.0
  var sum = 0.0
  for x in data:
    sum += x
  sum / float(data.len)

proc stddev*(data: openArray[float]): float =
  if data.len < 2:
    return 0.0
  let m = mean(data)
  var sumSq = 0.0
  for x in data:
    sumSq += (x - m) * (x - m)
  sqrt(sumSq / float(data.len - 1))

proc percentile*(data: openArray[float], p: float): float =
  ## Calculate percentile (p in 0.0..1.0)
  if data.len == 0:
    return 0.0
  var sorted = @data
  sorted.sort()
  let idx = int(float(data.len - 1) * p)
  sorted[idx]

proc minVal*(data: openArray[float]): float =
  if data.len == 0:
    return 0.0
  result = data[0]
  for x in data:
    if x < result:
      result = x

proc maxVal*(data: openArray[float]): float =
  if data.len == 0:
    return 0.0
  result = data[0]
  for x in data:
    if x > result:
      result = x
