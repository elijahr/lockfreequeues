when compileOption("threads"):
  import
    ./lockfreequeues/[
      atomic_dsl, constants, exceptions, mupmuc, mupsic, ops, sipmuc, sipsic,
      unbounded_mupmuc, unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic,
    ]

  export
    atomic_dsl, constants, exceptions, mupmuc, mupsic, ops, sipmuc, sipsic,
    unbounded_mupmuc, unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic
else:
  # threading off, only provide sipsic
  import ./lockfreequeues/[atomic_dsl, constants, ops, sipsic]

  export atomic_dsl, constants, ops, sipsic
