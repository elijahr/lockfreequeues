// extern "C" wrapper around moodycamel::ConcurrentQueue<uint64_t>.
//
// Why this exists. `concurrentqueue.h` is heavily templated; importing
// it directly into a Nim adapter via `importcpp` would push the
// upstream template machinery through every `nim cpp` build that
// touches the adapter. This shim reduces the API surface to four
// non-template, `uint64_t`-payload functions consumed by
// `benchmarks/nim/adapters/moodycamel_adapter.nim` via `importc`.
// Risk M5 in the bench-rollup understanding doc captures the
// rationale.
//
// Build. The Nim adapter compiles this file in via
// `{.compile: ".../moodycamel_wrapper.cpp".}`. The header search
// path is supplied by the adapter's `{.passC: "-I..." .}` pragma so
// no separate include flag is needed at the bench-binary `nim cpp`
// invocation.
//
// Lifetime. `mc_init` returns a pointer to a heap-allocated
// `moodycamel::ConcurrentQueue<uint64_t>`. The caller MUST balance
// every successful `mc_init` with a matching `mc_destroy` to avoid
// leaking the queue (its internal block pool is non-trivial — its
// destructor reclaims all blocks). The adapter does this in its
// `cleanup` proc.

#include "concurrentqueue.h"

#include <cstddef>  // SIZE_MAX
#include <cstdint>
#include <new>

extern "C" {

// Opaque handle returned to Nim. We round-trip a void* so the Nim
// importc signature can stay free of C++ types.
typedef void *mc_queue_t;

// Construct a queue. The optional `initial_capacity` hint maps to the
// upstream constructor's `size_t` argument; the queue grows beyond
// it on demand. We cap the hint at 1 to never request a zero-sized
// queue (upstream rejects 0). A zero argument from Nim is treated as
// "use the default capacity" by mapping to 32 (upstream's documented
// minimum block size).
//
// Returns nullptr on allocation failure. Critical: `extern "C"` forbids
// exceptions from escaping across the C ABI boundary, so we use
// `std::nothrow` (returns nullptr on bad_alloc) and a try/catch around
// any other constructor exception (e.g. from internal block-pool init)
// to map failure to nullptr. The caller MUST check the return value;
// see moodycamel_adapter.nim's `makeMoodycamelAdapter` for the Nim-side
// fail-fast on nullptr.
mc_queue_t mc_init(unsigned long long initial_capacity) {
  // The Nim adapter passes a uint64 capacity hint, but `std::size_t` is
  // 32 bits on ILP32 targets (32-bit Linux/Windows). Clamp to the host
  // size_t maximum before casting so a >4 GiB hint truncates to "as much
  // as the platform can address" rather than wrapping to a small value.
  // This matters only on 32-bit hosts; the bench harness in CI is x86_64
  // and will never exercise the clamp.
  unsigned long long clamped = initial_capacity;
  if (clamped > static_cast<unsigned long long>(SIZE_MAX)) {
    clamped = static_cast<unsigned long long>(SIZE_MAX);
  }
  std::size_t capacity = static_cast<std::size_t>(clamped);
  if (capacity == 0) {
    capacity = 32;
  }
  try {
    return new (std::nothrow)
        moodycamel::ConcurrentQueue<std::uint64_t>(capacity);
  } catch (...) {
    // bad_alloc is already turned into nullptr by `nothrow`; this
    // catch-all guards against any other ConcurrentQueue constructor
    // exception from leaking across the C ABI boundary.
    return nullptr;
  }
}

// Enqueue. `enqueue` returns false only on allocation failure; on
// success the queue may have grown internally, but that's fine for
// the bench adapter (capacity hint is advisory).
int mc_push(mc_queue_t q, unsigned long long item) {
  if (q == nullptr) return 0;
  auto *queue = static_cast<moodycamel::ConcurrentQueue<std::uint64_t> *>(q);
  std::uint64_t v = static_cast<std::uint64_t>(item);
  return queue->enqueue(v) ? 1 : 0;
}

// Try-dequeue. Returns 1 with the popped value through `*out` on
// success; 0 with `*out` unchanged when the queue is empty.
int mc_pop(mc_queue_t q, unsigned long long *out) {
  if (q == nullptr || out == nullptr) return 0;
  auto *queue = static_cast<moodycamel::ConcurrentQueue<std::uint64_t> *>(q);
  std::uint64_t v;
  if (queue->try_dequeue(v)) {
    *out = static_cast<unsigned long long>(v);
    return 1;
  }
  return 0;
}

void mc_destroy(mc_queue_t q) {
  if (q == nullptr) return;
  auto *queue = static_cast<moodycamel::ConcurrentQueue<std::uint64_t> *>(q);
  delete queue;
}

} // extern "C"
