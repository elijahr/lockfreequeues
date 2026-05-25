// extern "C" wrapper around `atomic_queue::AtomicQueueB<uint64_t>`.
//
// Why this exists. `atomic_queue.h` is a heavily-templated C++ header
// (multiple CRTP base classes parameterised on cache-line size /
// throughput / total-order flags). Importing it directly via `importcpp`
// would push the upstream template machinery through every `nim cpp`
// build that touches the adapter, exactly the trade-off captured by
// Risk M5 in the bench-rollup understanding doc and resolved for
// MoodyCamel by the same shim pattern.
//
// API surface. Five non-template, `uint64_t`-payload functions consumed
// by `benchmarks/nim/adapters/atomic_queue_adapter.nim` via plain
// `importc`:
//
//   aq_init(capacity)           -> void*
//   aq_push(q, item)            -> int  (1=ok, 0=full / null)
//   aq_pop(q, *out)             -> int  (1=ok, 0=empty / null)
//   aq_destroy(q)               -> void
//
// `AtomicQueueB` is the dynamic-capacity variant (heap-allocated ring
// buffer; capacity fixed at construction). Bounded MPMC; `try_push`
// returns false when full.
//
// NIL sentinel. `AtomicQueueB<T>` reserves a sentinel value of `T` to
// indicate empty slots; the default sentinel for unsigned integers is
// 0. To preserve a 0-bearing benchmark payload we offset every push by
// +1 and undo it on pop, so the on-the-wire range is [1, UINT64_MAX]
// while the bench harness sees [0, UINT64_MAX-1]. The bench harness
// never pushes UINT64_MAX, so the offset is collision-free.
//
// Build. The Nim adapter compiles this file in via
// `{.compile: ".../atomic_queue_wrapper.cpp".}`. The header search
// path is supplied by `{.passC: "-I..." .}` in the adapter so no
// separate include flag is needed at the bench-binary `nim cpp`
// invocation.

#include "atomic_queue/atomic_queue.h"

#include <cstddef>
#include <cstdint>
#include <new>

namespace {
// Bounded MPMC, dynamic-capacity, MAXIMIZE_THROUGHPUT=true,
// TOTAL_ORDER=false, SPSC=false (general MPMC).
using BenchQueue = atomic_queue::AtomicQueueB<std::uint64_t>;
}  // namespace

extern "C" {

typedef void *aq_queue_t;

// Construct a queue of `capacity`. `AtomicQueueB` requires capacity >= 1
// at construction; we clamp 0 to 1. Returns nullptr on bad_alloc.
aq_queue_t aq_init(unsigned long long capacity) {
  std::size_t cap = static_cast<std::size_t>(capacity);
  if (cap < 1) cap = 1;
  try {
    return new (std::nothrow) BenchQueue(cap);
  } catch (...) {
    return nullptr;
  }
}

// Push. Bench harness payload is in [0, UINT64_MAX-1]; we add 1 so the
// on-the-wire value is never the NIL sentinel (0).
int aq_push(aq_queue_t q, unsigned long long item) {
  if (q == nullptr) return 0;
  auto *queue = static_cast<BenchQueue *>(q);
  std::uint64_t v = static_cast<std::uint64_t>(item) + 1;
  return queue->try_push(v) ? 1 : 0;
}

// Pop. Subtract the +1 offset before handing the value back.
int aq_pop(aq_queue_t q, unsigned long long *out) {
  if (q == nullptr || out == nullptr) return 0;
  auto *queue = static_cast<BenchQueue *>(q);
  std::uint64_t v;
  if (queue->try_pop(v)) {
    *out = static_cast<unsigned long long>(v - 1);
    return 1;
  }
  return 0;
}

void aq_destroy(aq_queue_t q) {
  if (q == nullptr) return;
  auto *queue = static_cast<BenchQueue *>(q);
  delete queue;
}

}  // extern "C"
