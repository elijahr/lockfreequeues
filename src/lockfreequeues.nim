when compileOption("threads"):
  import
    ./lockfreequeues/[
      atomic_dsl, exceptions, mupmuc, mupsic, ops, sipmuc, sipsic,
      unbounded_mupmuc, unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic,
    ]

  export
    atomic_dsl, exceptions, mupmuc, mupsic, ops, sipmuc, sipsic,
    unbounded_mupmuc, unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic
else:
  # threading off, only provide sipsic
  import ./lockfreequeues/[atomic_dsl, ops, sipsic]

  export atomic_dsl, ops, sipsic
