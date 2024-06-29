# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

when compileOption("threads") or defined(nimdoc):
  import ./lockfreequeues/[
    atomic_dsl,
    constants,
    exceptions,
    mupmuc,
    mupsic,
    ops,
    sipsic,
  ]

  export
    atomic_dsl,
    constants,
    exceptions,
    mupmuc,
    mupsic,
    ops,
    sipsic
else:
  # threading off, only provide sipsic
  import ./lockfreequeues/[
    atomic_dsl,
    constants,
    exceptions,
    ops,
    sipsic,
  ]

  export
    atomic_dsl,
    constants,
    exceptions,
    ops,
    sipsic
