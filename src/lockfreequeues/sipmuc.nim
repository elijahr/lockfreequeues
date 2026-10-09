import ../lockfreequeues
export lockfreequeues

type
  Producer*[N, C: static int; T] = SipmucProducer[N, C, T]
  Consumer*[N, C: static int; T] = SipmucConsumer[N, C, T]
