import ../lockfreequeues
export lockfreequeues

type
  Producer*[S: static int, T; MaxThreads: static int = 64] = UnboundedMupmucProducer[S, T, MaxThreads]
  Consumer*[S: static int, T; MaxThreads: static int = 64] = UnboundedMupmucConsumer[S, T, MaxThreads]
