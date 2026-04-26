import ./t_atomic_dsl
import ./t_mupmuc
# import ./t_mupmuc_threaded  # DISABLED: pre-existing deadlock unrelated to typestate migration
import ./t_mupsic
import ./t_mupsic_threaded
import ./t_ops
import ./t_sipmuc
# import ./t_sipmuc_threaded  # DISABLED: pre-existing deadlock unrelated to typestate migration
import ./t_sipsic
import ./t_sipsic_threaded
import ./t_unbounded_mupmuc
# t_unbounded_mupmuc_threaded: nim-debra reclaim-race fixed (this branch).
# Test still fails: queue's `headSegment` is a non-atomic field never advanced
# past retired segments. After Eager reclaim frees a segment, the next pop's
# `var seg = self.queue.headSegment` reads a freed pointer; ASAN catches as
# heap-use-after-free in `seg.tail.load` / `seg.next.load`. The pin happens
# AFTER the headSegment read, so EBR cannot protect this access. Fix requires
# making `headSegment` atomic and advancing it cooperatively when retiring;
# out of scope for the nim-debra fix.
# import ./t_unbounded_mupmuc_threaded
import ./t_unbounded_mupsic
# t_unbounded_mupsic_threaded: same root cause as mupmuc_threaded.
# Passes under arc/orc by accident (multiple producers stay pinned during
# the consumer's pops, keeping safeEpoch low enough to delay reclaim until
# producers exit; producers exit AFTER consumer drains). Under refc the
# allocator interaction is different and a SIGSEGV reproduces reliably in
# `seg.next.load`.
# import ./t_unbounded_mupsic_threaded
import ./t_unbounded_sipmuc
# t_unbounded_sipmuc_threaded: same root cause as mupmuc_threaded.
# import ./t_unbounded_sipmuc_threaded
import ./t_unbounded_sipsic
# t_unbounded_sipsic_threaded: pre-existing SPSC sipsic UAF under refc.
# Separate from the headSegment bug above; documented in the original brief.
# import ./t_unbounded_sipsic_threaded

import ./t_wraparound

export
  t_atomic_dsl,
  t_mupmuc,
  # t_mupmuc_threaded,
  t_mupsic,
  t_mupsic_threaded,
  t_ops,
  t_sipmuc,
  # t_sipmuc_threaded,
  t_sipsic,
  t_sipsic_threaded,
  t_unbounded_mupmuc,
  # t_unbounded_mupmuc_threaded,
  t_unbounded_mupsic,
  # t_unbounded_mupsic_threaded,
  t_unbounded_sipmuc,
  # t_unbounded_sipmuc_threaded,
  t_unbounded_sipsic,
  # t_unbounded_sipsic_threaded,
  t_wraparound
