## Informational smoke test for Nimony / arc baseline
import std/options
import lockfreequeues

when defined(nimony):
  echo "nimony build detected; actual nimony tests would run here"
else:
  var q = newUnboundedSipsic[16, int]()
  q.push(42)
  let item = q.pop()
  doAssert item.isSome and item.get == 42, "Item should be 42"
  echo "nimony smoke baseline OK"
