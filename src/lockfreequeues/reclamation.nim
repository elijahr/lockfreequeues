## Reclamation-kind phantom enum for the v5.0.0 unified `Queue` generic.
##
## `RK` selects between two field-layout branches inside the `Queue` type:
##
## - `rkNone` — bounded family. Vyukov-style seq counters; no debra, no
##   segments.
## - `rkEbr`  — unbounded family. LCRQ-style segmented body + nim-debra
##   epoch-based reclamation.
##
## No default is supplied (Doc C §3.0.5: "Phase 3 deliberately does not
## supply one because the choice is semantically important").
##
## Doc C §3.0.5, §5 (verbatim source).

type ReclamationKind* = enum
  rkNone   ## Bounded queues: no reclamation machinery (Vyukov seqlocks).
  rkEbr    ## Unbounded queues: EBR via nim-debra.
