import ../lockfreequeues
export lockfreequeues

type
  Producer*[N, P, C: static int; T] = MupmucProducer[N, P, C, T]
  Consumer*[N, P, C: static int; T] = MupmucConsumer[N, P, C, T]
