## Reclamation-kind phantom enum for the v5.0.0 unified `Queue` generic.
##
## `RK` selects between two field-layout branches inside the `Queue` type:
##
## - `rkNone` — bounded family. Vyukov-style seq counters; no debra, no
##   segments.
## - `rkEbr`  — unbounded family. LCRQ-style segmented body + nim-debra
##   epoch-based reclamation.
##
## No default is supplied: the choice of `rkNone` vs `rkEbr` is
## semantically load-bearing — bounded queues have no segments to retire,
## and the unbounded SPSC shape is committed-flag-free, so the right
## reclamation kind is part of the queue's identity, not a configuration
## dial.

type ReclamationKind* = enum
  rkNone ## Bounded queues: no reclamation machinery (Vyukov seqlocks).
  rkEbr ## Unbounded queues: EBR via nim-debra.
