import ../lockfreequeues
export lockfreequeues

type
  Producer*[S: static int, T; MaxThreads: static int = 64] = UnboundedMupsicProducer[S, T, MaxThreads]
  Consumer*[S: static int, T; MaxThreads: static int = 64] = UnboundedMupsicConsumer[S, T, MaxThreads]
