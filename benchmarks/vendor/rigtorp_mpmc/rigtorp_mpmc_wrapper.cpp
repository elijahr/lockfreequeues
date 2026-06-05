// extern "C" wrapper around `rigtorp::mpmc::Queue<uint64_t>`.
//
// Why this exists. `MPMCQueue.h` is a single-header templated C++
// library (Vyukov-style bounded MPMC ring buffer). Importing it via
// `importcpp` would push the upstream template machinery into every
// `nim cpp` build; this thin shim reduces the API surface to four
// non-template, `uint64_t`-payload functions consumed by
// `benchmarks/nim/adapters/rigtorp_mpmc_adapter.nim` via `importc`.
// Same pattern as `moodycamel_wrapper.cpp`.
//
// API surface:
//
//   rigtorp_mpmc_init(capacity)       -> void*
//   rigtorp_mpmc_push(q, item)        -> int  (1=ok, 0=full / null)
//   rigtorp_mpmc_pop(q, *out)         -> int  (1=ok, 0=empty / null)
//   rigtorp_mpmc_destroy(q)           -> void
//
// `mpmc::Queue<T>` requires `capacity >= 1` at construction (it throws
// `std::invalid_argument` otherwise; we clamp before invoking the
// constructor to keep the C-ABI exception-free).

#include "rigtorp/MPMCQueue.h"

#include <cstddef>
#include <cstdint>
#include <new>

namespace {
using BenchQueue = rigtorp::mpmc::Queue<std::uint64_t>;
}  // namespace

extern "C" {

typedef void *rigtorp_mpmc_queue_t;

rigtorp_mpmc_queue_t rigtorp_mpmc_init(unsigned long long capacity) {
  // Defensive bound: on a hypothetical platform where `size_t` is narrower
  // than `unsigned long long` (e.g. 32-bit `size_t`), an out-of-range
  // capacity would silently truncate on the cast. No-op on LP64 / LLP64
  // targets where the types are the same width.
  if (capacity > static_cast<unsigned long long>(SIZE_MAX)) {
    return nullptr;
  }
  std::size_t cap = static_cast<std::size_t>(capacity);
  if (cap < 1) cap = 1;
  try {
    return new (std::nothrow) BenchQueue(cap);
  } catch (...) {
    // Catches `std::invalid_argument` (cap < 1, defended above) and
    // `std::bad_alloc` from the slot allocator. `nothrow` already maps
    // operator new failure to nullptr; the catch handles the queue's
    // own constructor exceptions.
    return nullptr;
  }
}

int rigtorp_mpmc_push(rigtorp_mpmc_queue_t q, unsigned long long item) {
  if (q == nullptr) return 0;
  auto *queue = static_cast<BenchQueue *>(q);
  std::uint64_t v = static_cast<std::uint64_t>(item);
  return queue->try_push(v) ? 1 : 0;
}

int rigtorp_mpmc_pop(rigtorp_mpmc_queue_t q, unsigned long long *out) {
  if (q == nullptr || out == nullptr) return 0;
  auto *queue = static_cast<BenchQueue *>(q);
  std::uint64_t v;
  if (queue->try_pop(v)) {
    *out = static_cast<unsigned long long>(v);
    return 1;
  }
  return 0;
}

void rigtorp_mpmc_destroy(rigtorp_mpmc_queue_t q) {
  if (q == nullptr) return;
  auto *queue = static_cast<BenchQueue *>(q);
  delete queue;
}

}  // extern "C"
