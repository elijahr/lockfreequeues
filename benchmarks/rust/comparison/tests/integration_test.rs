//! Integration test for the C-ABI surface. Calls the public extern "C"
//! functions directly through the rlib so the same code path the cdylib
//! exports is exercised end-to-end (init -> N pushes -> N pops -> destroy)
//! with count + set assertions matching the Nim adapter's smoke test.
//!
//! v4.2.0 Stage 5.2 renamed the symbols from `cb_*` to `crossbeam_*` as
//! part of the consolidation that pulls flume + kanal into the same
//! cdylib. The crossbeam round-trip / capacity / null-pointer checks
//! below carry over directly with the new names; flume + kanal are
//! exercised by the Nim-side smoke binaries (compiled via `nim c
//! --passL:-Wl,-rpath,...` against the consolidated cdylib).

use std::collections::HashSet;

use bench_ffi_comparison::{
    crossbeam_array_destroy, crossbeam_array_init, crossbeam_array_pop,
    crossbeam_array_push, crossbeam_seg_destroy, crossbeam_seg_init,
    crossbeam_seg_pop, crossbeam_seg_push,
};

const N: u64 = 1000;

#[test]
fn array_queue_round_trip_preserves_set() {
    unsafe {
        let q = crossbeam_array_init(N as usize);
        assert!(!q.is_null());

        let mut pushed: HashSet<u64> = HashSet::new();
        for i in 0..N {
            assert!(crossbeam_array_push(q, i), "array push failed at i={i}");
            pushed.insert(i);
        }

        let mut popped: HashSet<u64> = HashSet::new();
        let mut out: u64 = 0;
        while crossbeam_array_pop(q, &mut out) {
            popped.insert(out);
        }

        assert_eq!(popped.len() as u64, N);
        assert_eq!(pushed, popped);

        crossbeam_array_destroy(q);
    }
}

#[test]
fn array_queue_full_returns_false() {
    unsafe {
        let q = crossbeam_array_init(2);
        assert!(crossbeam_array_push(q, 10));
        assert!(crossbeam_array_push(q, 20));
        assert!(
            !crossbeam_array_push(q, 30),
            "expected push to fail at capacity"
        );
        crossbeam_array_destroy(q);
    }
}

#[test]
fn array_queue_zero_capacity_returns_null() {
    // `crossbeam_array_init` is not `unsafe` (no preconditions on the
    // 0-arg path), so the test body intentionally does not wrap it.
    // Guard against the upstream panic on ArrayQueue::new(0); we
    // return null instead so the FFI never unwinds.
    let q = crossbeam_array_init(0);
    assert!(q.is_null());
}

#[test]
fn seg_queue_round_trip_preserves_set() {
    unsafe {
        let q = crossbeam_seg_init();
        assert!(!q.is_null());

        let mut pushed: HashSet<u64> = HashSet::new();
        for i in 0..N {
            assert!(crossbeam_seg_push(q, i));
            pushed.insert(i);
        }

        let mut popped: HashSet<u64> = HashSet::new();
        let mut out: u64 = 0;
        while crossbeam_seg_pop(q, &mut out) {
            popped.insert(out);
        }

        assert_eq!(popped.len() as u64, N);
        assert_eq!(pushed, popped);

        crossbeam_seg_destroy(q);
    }
}

#[test]
fn pop_empty_returns_false() {
    unsafe {
        let q = crossbeam_array_init(4);
        let mut out: u64 = 999;
        assert!(!crossbeam_array_pop(q, &mut out));
        assert_eq!(out, 999, "out unchanged on empty pop");
        crossbeam_array_destroy(q);

        let q = crossbeam_seg_init();
        assert!(!crossbeam_seg_pop(q, &mut out));
        crossbeam_seg_destroy(q);
    }
}

#[test]
fn null_pointer_safe() {
    unsafe {
        let mut out: u64 = 0;
        assert!(!crossbeam_array_push(std::ptr::null_mut(), 1));
        assert!(!crossbeam_array_pop(std::ptr::null_mut(), &mut out));
        assert!(!crossbeam_seg_push(std::ptr::null_mut(), 1));
        assert!(!crossbeam_seg_pop(std::ptr::null_mut(), &mut out));
        crossbeam_array_destroy(std::ptr::null_mut());
        crossbeam_seg_destroy(std::ptr::null_mut());
    }
}
