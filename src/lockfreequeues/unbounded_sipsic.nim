import ../lockfreequeues
export lockfreequeues

type
  Producer*[S: static int, T] = UnboundedSipsicProducer[S, T]
  Consumer*[S: static int, T] = UnboundedSipsicConsumer[S, T]
