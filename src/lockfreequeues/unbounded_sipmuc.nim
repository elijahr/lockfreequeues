import ../lockfreequeues
export lockfreequeues

type
  Producer*[S: static int, T; MaxThreads: static int = 64] = UnboundedSipmucProducer[S, T, MaxThreads]
  Consumer*[S: static int, T; MaxThreads: static int = 64] = UnboundedSipmucConsumer[S, T, MaxThreads]
