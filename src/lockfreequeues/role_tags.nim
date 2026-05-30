##
## Role-discriminating effect tags shared across queue flavours.
##
## Per design §3.3.4, §3.3.5, §4.1.
##
## - `AnyThreadTag`: same-thread shortcut path
##   (`getProducerHere` / `getConsumerHere`). Bypasses per-spawn freshness;
##   runtime `getThreadId()` backstop catches misuse under `-d:debug`.
## - `SpscProducerTag` / `SpscConsumerTag`: SPSC has cardinality 1 per role,
##   so per-spawn freshness collapses; role discrimination still applies.
## - `MpmcProducerTag` / `MpmcConsumerTag`: Option A — MPMC gets role
##   discipline only (no per-spawn tag). Per-thread identity stays runtime-
##   checked (see migration guide).

type
  AnyThreadTag* = object of RootEffect

  SpscProducerTag* = object of RootEffect
  SpscConsumerTag* = object of RootEffect

  MpmcProducerTag* = object of RootEffect
  MpmcConsumerTag* = object of RootEffect
