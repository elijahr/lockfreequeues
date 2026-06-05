import ./t_aligned_alloc
import ./t_atomic_dsl
import ./t_backoff
import ./t_slot_seq_generation_rollover
# v5.0.0: legacy bounded test imports removed. Per-family
# Mpsc/Spmc/Mpmc/Spsc coverage now lives in the t_queue_bounded_*
# files below, with verified pass-count parity (mpsc 28/28, spmc 27/27,
# mpmc 28/28, spsc 21/21, mpsc_threaded 2/2, spsc_threaded 2/2). The
# legacy tests/t_{mpsc,spmc,mpmc,spsc}{,_threaded}.nim files remain on
# disk until they are deleted alongside their src/ counterparts.
import ./t_queue_enums
import ./t_queue_type_shell
import ./t_queue_bounded_mpsc_smoke
import ./t_queue_bounded_mpsc
import ./t_queue_bounded_spmc
import ./t_queue_bounded_mpmc
import ./t_queue_bounded_spsc
import ./t_queue_bounded_mpsc_threaded
import ./t_queue_bounded_spsc_threaded
import ./t_queue_bounded_mpmc_threaded
import ./t_queue_bounded_spmc_threaded
import ./t_unbounded_mpmc
import ./t_unbounded_mpmc_threaded
import ./t_unbounded_mpsc
import ./t_unbounded_mpsc_threaded
import ./t_unbounded_padding
import ./t_unbounded_spmc
import ./t_unbounded_spmc_threaded
import ./t_unbounded_spsc
import ./t_unbounded_spsc_threaded
import ./t_unbounded_auto_create
import ./t_queue_strategy_phantom

import ./t_wraparound

export
  t_aligned_alloc, t_atomic_dsl, t_backoff, t_slot_seq_generation_rollover,
  t_queue_enums, t_queue_type_shell, t_queue_bounded_mpsc_smoke, t_queue_bounded_mpsc,
  t_queue_bounded_spmc, t_queue_bounded_mpmc, t_queue_bounded_spsc,
  t_queue_bounded_mpsc_threaded, t_queue_bounded_spsc_threaded,
  t_queue_bounded_mpmc_threaded, t_queue_bounded_spmc_threaded, t_unbounded_mpmc,
  t_unbounded_mpmc_threaded, t_unbounded_mpsc, t_unbounded_mpsc_threaded,
  t_unbounded_padding, t_unbounded_spmc, t_unbounded_spmc_threaded, t_unbounded_spsc,
  t_unbounded_spsc_threaded, t_unbounded_auto_create, t_queue_strategy_phantom,
  t_wraparound
