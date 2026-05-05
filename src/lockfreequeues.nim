when compileOption("threads"):
  import
    ./lockfreequeues/[
      atomic_dsl, exceptions, mupmuc, mupsic, sipmuc, sipsic, unbounded_mupmuc,
      unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic,
    ]

  export
    atomic_dsl, exceptions, mupmuc, mupsic, sipmuc, sipsic, unbounded_mupmuc,
    unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic
else:
  # threading off, only provide sipsic
  import ./lockfreequeues/[atomic_dsl, sipsic]

  export atomic_dsl, sipsic
