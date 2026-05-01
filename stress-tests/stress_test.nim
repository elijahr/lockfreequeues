## Stress tests for lockfreequeues - multi-threaded concurrent tests.
## Run with `nimble stress-tests`

import ./t_mupmuc_threaded
import ./t_mupsic_threaded
import ./t_sipmuc_threaded
import ./t_sipsic_threaded
# DISABLED: unbounded_* stress tests use the pre-DEBRA EpochManager API
# (newEpochManager, 2-param UnboundedMupmuc[S, T], etc.) and need a
# rewrite for the post-3.2.0 DEBRA-based API (3-param
# UnboundedMupmuc[S, T, MaxThreads], DebraManager). Tracked separately
# from the mupmuc-livelock fix; bounded stress coverage is what this
# branch exercises.
# import ./t_unbounded_mupmuc_threaded
# import ./t_unbounded_mupsic_threaded
# import ./t_unbounded_sipmuc_threaded
# import ./t_unbounded_sipsic_threaded

export
  t_mupmuc_threaded,
  t_mupsic_threaded,
  t_sipmuc_threaded,
  t_sipsic_threaded
