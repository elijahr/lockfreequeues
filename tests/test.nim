import ./t_aligned_alloc
import ./t_atomic_dsl
import ./t_backoff
import ./t_slot_seq_generation_rollover
# v5.0.0 cascade (Track D3.2): legacy bounded test imports removed.
# Per-family Mupsic/Sipmuc/Mupmuc/Sipsic coverage now lives in the
# t_queue_bounded_* files below (Manager B / Task B2 verified pass-count
# parity: mupsic 28/28, sipmuc 27/27, mupmuc 28/28, sipsic 21/21,
# mupsic_threaded 2/2, sipsic_threaded 2/2). Files
# tests/t_{mupsic,sipmuc,mupmuc,sipsic}{,_threaded}.nim remain on disk
# until Track F5 deletes them with their src/ counterparts.
import ./t_queue_enums
import ./t_queue_type_shell
import ./t_queue_bounded_mupsic_smoke
import ./t_queue_bounded_mupsic
import ./t_queue_bounded_sipmuc
import ./t_queue_bounded_mupmuc
import ./t_queue_bounded_sipsic
import ./t_queue_bounded_mupsic_threaded
import ./t_queue_bounded_sipsic_threaded
# Re-enabled 2026-05-17 after v5.0.0 Phase 4.6.3 green-mirage audit
# surfaced that the prior disable comment ("pre-existing deadlock...")
# was verbatim-preserved from v3.x committed-flag era. Standalone
# re-run on feat/v5.0.0-impl @ adcc2f5 with --threads:on -r at 3-run
# cold-state per test PASSED for both variants. No deadlock observed
# in current code; the disable was stale documentation, not a live
# constraint. Audit artifact: docs/v5.0.0-migration/bench-report-b3-split.md
# references the Phase 4.6 audit context.
import ./t_queue_bounded_mupmuc_threaded
import ./t_queue_bounded_sipmuc_threaded
import ./t_unbounded_mupmuc
import ./t_unbounded_mupmuc_threaded
import ./t_unbounded_mupsic
import ./t_unbounded_mupsic_threaded
import ./t_unbounded_padding
import ./t_unbounded_sipmuc
import ./t_unbounded_sipmuc_threaded
import ./t_unbounded_sipsic
import ./t_unbounded_sipsic_threaded
import ./t_unbounded_auto_create

import ./t_wraparound

export
  t_aligned_alloc,
  t_atomic_dsl,
  t_backoff,
  t_slot_seq_generation_rollover,
  t_queue_enums,
  t_queue_type_shell,
  t_queue_bounded_mupsic_smoke,
  t_queue_bounded_mupsic,
  t_queue_bounded_sipmuc,
  t_queue_bounded_mupmuc,
  t_queue_bounded_sipsic,
  t_queue_bounded_mupsic_threaded,
  t_queue_bounded_sipsic_threaded,
  t_queue_bounded_mupmuc_threaded,
  t_queue_bounded_sipmuc_threaded,
  t_unbounded_mupmuc,
  t_unbounded_mupmuc_threaded,
  t_unbounded_mupsic,
  t_unbounded_mupsic_threaded,
  t_unbounded_padding,
  t_unbounded_sipmuc,
  t_unbounded_sipmuc_threaded,
  t_unbounded_sipsic,
  t_unbounded_sipsic_threaded,
  t_unbounded_auto_create,
  t_wraparound
