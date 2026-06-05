import std/[unittest, atomics, options, sysatomics]
import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import lockfreequeues/spawn

# Module-scope worker declarations (REQUIRED — see spawn.nim header):
defineProducerWorker(TenItemProducer, BQueue[int, ccMulti, ccMulti, 64, 4, 4]):
  for i in 0 ..< 10:
    discard producer.push(i)

defineConsumerWorker(FiveItemConsumer, BQueue[int, ccMulti, ccMulti, 64, 4, 4]):
  var got = 0
  while got < 5:
    let v = consumer.pop()
    if v.isSome:
      inc got
    else:
      cpuRelax()

suite "spawn 2-step API":
  test "producer worker pushes from spawned thread":
    var q = initBQueue[int, ccMulti, ccMulti, 64, 4, 4]()
    var thr = spawnDefinedProducer(TenItemProducer, q)
    joinThread(thr)
    var bc = q.getConsumerHere()
    var seen = 0
    for _ in 0 ..< 10:
      let v = bc.pop()
      if v.isSome:
        inc seen
    check seen == 10

  test "consumer worker pops from spawned thread":
    var q = initBQueue[int, ccMulti, ccMulti, 64, 4, 4]()
    var bp = q.getProducerHere()
    for i in 0 ..< 5:
      discard bp.push(i)
    var thr = spawnDefinedConsumer(FiveItemConsumer, q)
    joinThread(thr)
    var bc = q.getConsumerHere()
    check bc.pop().isNone
