import ../lockfreequeues
export lockfreequeues

type
  Producer*[N, P: static int; T] = MupsicProducer[N, P, T]
  Consumer*[N, P: static int; T] = MupsicConsumer[N, P, T]
