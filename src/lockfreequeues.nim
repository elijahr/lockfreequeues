# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

when compileOption("threads"):
  import ./lockfreequeues/[
    atomic_dsl,
    constants,
    epoch,
    mupmuc,
    mupsic,
    ops,
    sipmuc,
    sipsic,
    unbounded_mupmuc,
    unbounded_mupsic,
    unbounded_sipmuc,
    unbounded_sipsic,
  ]

  export
    atomic_dsl,
    constants,
    epoch,
    mupmuc,
    mupsic,
    ops,
    sipmuc,
    sipsic,
    unbounded_mupmuc,
    unbounded_mupsic,
    unbounded_sipmuc,
    unbounded_sipsic
else:
  # threading off, only provide sipsic
  import ./lockfreequeues/[
    atomic_dsl,
    constants,
    ops,
    sipsic,
  ]

  export
    atomic_dsl,
    constants,
    ops,
    sipsic
