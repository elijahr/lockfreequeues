//! Integration test for the C-ABI surface. Calls the public extern "C"
//! functions directly through the rlib so the same code path the cdylib
//! exports is exercised end-to-end (init -> N pushes -> N pops -> destroy)
//! with count + set assertions matching the Nim adapter's smoke test.

use std::collections::HashSet;
use std::os::raw::c_void;

use bench_ffi_crossbeam::{
    bench_ffi_crossbeam_queue_version, bench_ffi_flume_version,
    bench_ffi_kanal_version, cb_array_destroy, cb_array_init, cb_array_pop,
    cb_array_push, cb_seg_destroy, cb_seg_init, cb_seg_pop, cb_seg_push,
};

// Bind the local names the tests use so the rest of the file (which
// passes raw `*mut c_void`) reads identically to the cdylib consumer.
// Each call site below uses the imported function directly.
#[allow(dead_code)]
fn _shape_check() -> *mut c_void {
    std::ptr::null_mut()
}

const N: u64 = 1000;

#[test]
fn array_queue_round_trip_preserves_set() {
    unsafe {
        let q = cb_array_init(N as usize);
        assert!(!q.is_null());

        let mut pushed: HashSet<u64> = HashSet::new();
        for i in 0..N {
            assert!(cb_array_push(q, i), "array push failed at i={i}");
            pushed.insert(i);
        }

        let mut popped: HashSet<u64> = HashSet::new();
        let mut out: u64 = 0;
        while cb_array_pop(q, &mut out) {
            popped.insert(out);
        }

        assert_eq!(popped.len() as u64, N);
        assert_eq!(pushed, popped);

        cb_array_destroy(q);
    }
}

#[test]
fn array_queue_full_returns_false() {
    unsafe {
        let q = cb_array_init(2);
        assert!(cb_array_push(q, 10));
        assert!(cb_array_push(q, 20));
        assert!(!cb_array_push(q, 30), "expected push to fail at capacity");
        cb_array_destroy(q);
    }
}

#[test]
fn array_queue_zero_capacity_returns_null() {
    // `cb_array_init` is not `unsafe` (it has no preconditions on a
    // 0-arg path), so the test body intentionally does not wrap it.
    // Guard against the upstream panic on ArrayQueue::new(0); we
    // return null instead so the FFI never unwinds.
    let q = cb_array_init(0);
    assert!(q.is_null());
}

#[test]
fn seg_queue_round_trip_preserves_set() {
    unsafe {
        let q = cb_seg_init();
        assert!(!q.is_null());

        let mut pushed: HashSet<u64> = HashSet::new();
        for i in 0..N {
            assert!(cb_seg_push(q, i));
            pushed.insert(i);
        }

        let mut popped: HashSet<u64> = HashSet::new();
        let mut out: u64 = 0;
        while cb_seg_pop(q, &mut out) {
            popped.insert(out);
        }

        assert_eq!(popped.len() as u64, N);
        assert_eq!(pushed, popped);

        cb_seg_destroy(q);
    }
}

#[test]
fn pop_empty_returns_false() {
    unsafe {
        let q = cb_array_init(4);
        let mut out: u64 = 999;
        assert!(!cb_array_pop(q, &mut out));
        assert_eq!(out, 999, "out unchanged on empty pop");
        cb_array_destroy(q);

        let q = cb_seg_init();
        assert!(!cb_seg_pop(q, &mut out));
        cb_seg_destroy(q);
    }
}

#[test]
fn null_pointer_safe() {
    unsafe {
        let mut out: u64 = 0;
        assert!(!cb_array_push(std::ptr::null_mut(), 1));
        assert!(!cb_array_pop(std::ptr::null_mut(), &mut out));
        assert!(!cb_seg_push(std::ptr::null_mut(), 1));
        assert!(!cb_seg_pop(std::ptr::null_mut(), &mut out));
        cb_array_destroy(std::ptr::null_mut());
        cb_seg_destroy(std::ptr::null_mut());
    }
}

// ---------------- Version-getter tests (v5.0.0-wave Item 1) ----------------
//
// `build.rs` reads `Cargo.lock` and bakes the resolved versions of
// `crossbeam-queue`, `flume`, and `kanal` into env vars; the three
// exported version getters return those strings as C cstrings. These
// tests catch a "build.rs didn't fire" silent failure: an empty string
// or a non-semver-looking value means the version-capture chain is
// broken, and the bench JSON would silently lie about which versions
// were linked in.

/// Convert an FFI version-getter return value into a Rust `&str`,
/// asserting the pointer is non-null and the string has no embedded
/// NULs.
unsafe fn fetch_version(ptr: *const std::os::raw::c_char) -> &'static str {
    assert!(!ptr.is_null(), "version getter returned null pointer");
    std::ffi::CStr::from_ptr(ptr)
        .to_str()
        .expect("version string is not valid UTF-8")
}

/// Minimal semver-shape check: at least `MAJOR.MINOR.PATCH` with all
/// three parts numeric. We do not require strict semver (pre-release /
/// build metadata is rare here) — the goal is to catch "got an empty
/// string" or "got the env var literal" silent failures.
fn looks_semver_ish(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() < 3 {
        return false;
    }
    // First three components must parse as u32.
    parts[..3].iter().all(|p| {
        // Strip optional `-suffix` / `+build` from the patch component.
        let stem = p
            .split(|c: char| c == '-' || c == '+')
            .next()
            .unwrap_or("");
        !stem.is_empty() && stem.chars().all(|c| c.is_ascii_digit())
    })
}

#[test]
fn crossbeam_queue_version_baked_in() {
    let v = unsafe { fetch_version(bench_ffi_crossbeam_queue_version()) };
    assert!(!v.is_empty(), "crossbeam-queue version string is empty");
    assert!(
        looks_semver_ish(v),
        "crossbeam-queue version {:?} does not look like semver",
        v,
    );
}

#[test]
fn flume_version_baked_in() {
    let v = unsafe { fetch_version(bench_ffi_flume_version()) };
    assert!(!v.is_empty(), "flume version string is empty");
    assert!(
        looks_semver_ish(v),
        "flume version {:?} does not look like semver",
        v,
    );
}

#[test]
fn kanal_version_baked_in() {
    let v = unsafe { fetch_version(bench_ffi_kanal_version()) };
    assert!(!v.is_empty(), "kanal version string is empty");
    assert!(
        looks_semver_ish(v),
        "kanal version {:?} does not look like semver",
        v,
    );
}
