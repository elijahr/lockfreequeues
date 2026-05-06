/*
 * extern "C"-equivalent wrapper around the liblfds 7.1.1 bounded
 * single-producer / single-consumer (`bss`) and bounded
 * many-producer / many-consumer (`bmm`) queues.
 *
 * Why this exists. The upstream `lfds711_queue_bss_*` and
 * `lfds711_queue_bmm_*` APIs require the caller to:
 *   - allocate the queue state struct,
 *   - allocate the element_array,
 *   - call init with both pointers,
 *   - issue the `MAKE_VALID_ON_CURRENT_LOGICAL_CORE` barrier,
 *   - re-cast (key, value) void* pairs to / from the user's payload.
 *
 * Doing all that from Nim via `importc` would require a substantial
 * amount of FFI bookkeeping for what is, semantically, a uint64-payload
 * push / pop. This shim folds the bookkeeping into eight C entry
 * points (four BSS, four BMM) consumed by
 * `benchmarks/nim/adapters/liblfds_adapter.nim` via plain `importc`.
 * Same pattern as `moodycamel_wrapper.cpp` and friends, except the
 * upstream library is C, so this wrapper is C too.
 *
 * Capacity contract: liblfds's bounded queue requires
 * `number_elements` to be a power of 2. The wrapper rounds the caller's
 * capacity request up to the next power of 2 with a minimum of 2.
 * Returns NULL on bad_alloc; the Nim adapter raises OutOfMemDefect on
 * NULL.
 *
 * Payload encoding: the upstream API stores two void* fields per slot
 * (key + value). We stash the uint64 payload in `value` (cast through
 * uintptr_t) and leave `key` NULL. On 64-bit platforms uintptr_t is
 * 64 bits so the round-trip is bit-exact. The bench harness only
 * exercises 64-bit platforms (`sizeof(T) == 8` static assert in the
 * adapter), which is enforced upstream too.
 */

#include "liblfds711/inc/liblfds711.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ----- shared util ----- */

/* Round `n` up to the next power of two, with a minimum of 2 (the
 * upstream APIs assert `number_elements >= 2`). */
static size_t bench_next_pow2(size_t n) {
  if (n < 2) return 2;
  /* Already a power of two? */
  if ((n & (n - 1)) == 0) return n;
  size_t p = 2;
  while (p < n) p <<= 1;
  return p;
}

/* ----- BSS (single-producer / single-consumer) ----- */

typedef struct {
  struct lfds711_queue_bss_state state;
  struct lfds711_queue_bss_element *elements;
  size_t capacity;
} bench_liblfds_bss_t;

void *bench_liblfds_bss_init(unsigned long long capacity) {
  size_t cap = bench_next_pow2((size_t)capacity);
  bench_liblfds_bss_t *q = (bench_liblfds_bss_t *)malloc(sizeof(*q));
  if (q == NULL) return NULL;
  q->elements = (struct lfds711_queue_bss_element *)malloc(
      sizeof(struct lfds711_queue_bss_element) * cap);
  if (q->elements == NULL) {
    free(q);
    return NULL;
  }
  q->capacity = cap;
  lfds711_queue_bss_init_valid_on_current_logical_core(
      &q->state, q->elements, cap, NULL);
  /* Required full-barrier handshake per the upstream init contract. */
  LFDS711_MISC_MAKE_VALID_ON_CURRENT_LOGICAL_CORE_INITS_COMPLETED_BEFORE_NOW_ON_ANY_OTHER_LOGICAL_CORE;
  return q;
}

int bench_liblfds_bss_push(void *raw, unsigned long long item) {
  if (raw == NULL) return 0;
  bench_liblfds_bss_t *q = (bench_liblfds_bss_t *)raw;
  /* Stash the uint64 payload in the `value` slot via uintptr_t cast.
   * Returns 1 on success, 0 on full. */
  return lfds711_queue_bss_enqueue(
      &q->state, NULL, (void *)(uintptr_t)item) ? 1 : 0;
}

int bench_liblfds_bss_pop(void *raw, unsigned long long *out) {
  if (raw == NULL || out == NULL) return 0;
  bench_liblfds_bss_t *q = (bench_liblfds_bss_t *)raw;
  void *key = NULL;
  void *value = NULL;
  if (!lfds711_queue_bss_dequeue(&q->state, &key, &value)) return 0;
  *out = (unsigned long long)(uintptr_t)value;
  return 1;
}

void bench_liblfds_bss_destroy(void *raw) {
  if (raw == NULL) return;
  bench_liblfds_bss_t *q = (bench_liblfds_bss_t *)raw;
  /* Cleanup callback is NULL — caller is responsible for draining
   * residual payloads before destroy if that matters. The bench harness
   * always drains the queue between runs. */
  lfds711_queue_bss_cleanup(&q->state, NULL);
  free(q->elements);
  free(q);
}

/* ----- BMM (many-producer / many-consumer) ----- */

typedef struct {
  struct lfds711_queue_bmm_state state;
  struct lfds711_queue_bmm_element *elements;
  size_t capacity;
} bench_liblfds_bmm_t;

void *bench_liblfds_bmm_init(unsigned long long capacity) {
  size_t cap = bench_next_pow2((size_t)capacity);
  bench_liblfds_bmm_t *q = (bench_liblfds_bmm_t *)malloc(sizeof(*q));
  if (q == NULL) return NULL;
  q->elements = (struct lfds711_queue_bmm_element *)malloc(
      sizeof(struct lfds711_queue_bmm_element) * cap);
  if (q->elements == NULL) {
    free(q);
    return NULL;
  }
  q->capacity = cap;
  lfds711_queue_bmm_init_valid_on_current_logical_core(
      &q->state, q->elements, cap, NULL);
  LFDS711_MISC_MAKE_VALID_ON_CURRENT_LOGICAL_CORE_INITS_COMPLETED_BEFORE_NOW_ON_ANY_OTHER_LOGICAL_CORE;
  return q;
}

int bench_liblfds_bmm_push(void *raw, unsigned long long item) {
  if (raw == NULL) return 0;
  bench_liblfds_bmm_t *q = (bench_liblfds_bmm_t *)raw;
  return lfds711_queue_bmm_enqueue(
      &q->state, NULL, (void *)(uintptr_t)item) ? 1 : 0;
}

int bench_liblfds_bmm_pop(void *raw, unsigned long long *out) {
  if (raw == NULL || out == NULL) return 0;
  bench_liblfds_bmm_t *q = (bench_liblfds_bmm_t *)raw;
  void *key = NULL;
  void *value = NULL;
  if (!lfds711_queue_bmm_dequeue(&q->state, &key, &value)) return 0;
  *out = (unsigned long long)(uintptr_t)value;
  return 1;
}

void bench_liblfds_bmm_destroy(void *raw) {
  if (raw == NULL) return;
  bench_liblfds_bmm_t *q = (bench_liblfds_bmm_t *)raw;
  lfds711_queue_bmm_cleanup(&q->state, NULL);
  free(q->elements);
  free(q);
}
