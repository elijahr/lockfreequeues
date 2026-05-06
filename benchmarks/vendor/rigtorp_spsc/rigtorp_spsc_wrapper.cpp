// extern "C" wrapper around `rigtorp::SPSCQueue<uint64_t>`.
//
// Why this exists. `SPSCQueue.h` is a single-header templated C++
// library. Importing it via `importcpp` would push the upstream
// template machinery into every `nim cpp` build; this thin shim
// reduces the API surface to four non-template, `uint64_t`-payload
// functions consumed by
// `benchmarks/nim/adapters/rigtorp_spsc_adapter.nim` via `importc`.
// Same pattern as `moodycamel_wrapper.cpp` and `atomic_queue_wrapper.cpp`.
//
// API surface:
//
//   rigtorp_spsc_init(capacity)       -> void*
//   rigtorp_spsc_push(q, item)        -> int  (1=ok, 0=full / null)
//   rigtorp_spsc_pop(q, *out)         -> int  (1=ok, 0=empty / null)
//   rigtorp_spsc_destroy(q)           -> void
//
// `SPSCQueue<T>` is single-producer / single-consumer bounded; the
// constructor takes a fixed capacity. `try_push(v)` returns false when
// full; `front()` returns a `T*` (or nullptr) and `pop()` retires the
// element.

#include "rigtorp/SPSCQueue.h"

#include <cstddef>
#include <cstdint>
#include <new>

namespace {
using BenchQueue = rigtorp::SPSCQueue<std::uint64_t>;
}  // namespace

extern "C" {

typedef void *rigtorp_spsc_queue_t;

// `SPSCQueue` constructor clamps capacity < 1 to 1 internally and adds
// one slack slot, so we don't repeat the clamp here. Returns nullptr on
// allocation failure (the constructor would otherwise throw bad_alloc;
// `nothrow` converts that to nullptr per the C-ABI contract).
rigtorp_spsc_queue_t rigtorp_spsc_init(unsigned long long capacity) {
  std::size_t cap = static_cast<std::size_t>(capacity);
  if (cap < 1) cap = 1;
  try {
    return new (std::nothrow) BenchQueue(cap);
  } catch (...) {
    return nullptr;
  }
}

int rigtorp_spsc_push(rigtorp_spsc_queue_t q, unsigned long long item) {
  if (q == nullptr) return 0;
  auto *queue = static_cast<BenchQueue *>(q);
  std::uint64_t v = static_cast<std::uint64_t>(item);
  return queue->try_push(v) ? 1 : 0;
}

int rigtorp_spsc_pop(rigtorp_spsc_queue_t q, unsigned long long *out) {
  if (q == nullptr || out == nullptr) return 0;
  auto *queue = static_cast<BenchQueue *>(q);
  std::uint64_t *p = queue->front();
  if (p == nullptr) return 0;
  *out = static_cast<unsigned long long>(*p);
  queue->pop();
  return 1;
}

void rigtorp_spsc_destroy(rigtorp_spsc_queue_t q) {
  if (q == nullptr) return;
  auto *queue = static_cast<BenchQueue *>(q);
  delete queue;
}

}  // extern "C"
