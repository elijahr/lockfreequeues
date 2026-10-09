import ../lockfreequeues
export lockfreequeues

type
  Producer*[N: static int; T] = SipsicProducer[N, T]
  Consumer*[N: static int; T] = SipsicConsumer[N, T]
