//! C-ABI shim around `crossbeam_queue::ArrayQueue` and `crossbeam_queue::SegQueue`.
//!
//! Exposes 8 `extern "C"` functions for the Nim bench adapters:
//!
//! | Function           | Backing type                      |
//! |--------------------|-----------------------------------|
//! | cb_array_init      | crossbeam_queue::ArrayQueue<u64>  |
//! | cb_array_push      | "                                 |
//! | cb_array_pop       | "                                 |
//! | cb_array_destroy   | "                                 |
//! | cb_seg_init        | crossbeam_queue::SegQueue<u64>    |
//! | cb_seg_push        | "                                 |
//! | cb_seg_pop         | "                                 |
//! | cb_seg_destroy     | "                                 |
//!
//! All eight functions are panic-safe relative to the Rust side: they
//! perform their own null-pointer checks. They are NOT thread-safe with
//! respect to `*_destroy` (the queues themselves are MPMC-safe, but
//! freeing the queue while another thread is mid-push/mid-pop is a UAF).
//! The Nim-side adapters guarantee `cleanup` is called only after all
//! producer / consumer threads have joined.
//!
//! Object lifetime: each `*_init` allocates the queue on the Rust heap
//! via `Box::into_raw`. The returned `*mut c_void` must be passed back
//! to the matching `*_destroy` to reclaim it; intermediate `_push` /
//! `_pop` calls borrow it immutably (the queue's interior mutability
//! handles the writes).

use crossbeam_queue::{ArrayQueue, SegQueue};
use std::os::raw::{c_char, c_void};

// ---------------- Version getters (v5.0.0-wave Item 1) ----------------
//
// The three functions below return null-terminated C strings containing
// the resolved versions of the crates this cdylib wraps. The strings are
// baked in at build time by `build.rs`, which reads `Cargo.lock` and
// emits `cargo:rustc-env=BENCH_DEP_*_VERSION=...`. The Nim bench
// harness (`benchmarks/nim/adapter_versions.nim`) `importc`-s these
// functions and records the returned strings in the bench JSON's
// `meta.adapters.<slug>.version` field, so each bench result documents
// exactly which crate versions were linked in.
//
// Trailing `\0` is appended via `concat!` so the literal is a valid C
// string with no allocation. The returned pointer points into the
// binary's read-only data segment; the caller MUST NOT free it.

/// Returns the resolved `crossbeam-queue` crate version as a
/// NUL-terminated C string (e.g. `"0.3.12\0"` ptr). Baked in at
/// cdylib build time by `build.rs` from `Cargo.lock`.
#[no_mangle]
pub extern "C" fn bench_ffi_crossbeam_queue_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_CROSSBEAM_QUEUE_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

/// Returns the resolved `flume` crate version as a NUL-terminated C
/// string. See `bench_ffi_crossbeam_queue_version`.
#[no_mangle]
pub extern "C" fn bench_ffi_flume_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_FLUME_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

/// Returns the resolved `kanal` crate version as a NUL-terminated C
/// string. See `bench_ffi_crossbeam_queue_version`.
#[no_mangle]
pub extern "C" fn bench_ffi_kanal_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_KANAL_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

// ---------------- ArrayQueue (bounded MPMC) ----------------

/// Allocate a bounded `ArrayQueue<u64>` of `capacity`. Returns the queue
/// pointer (opaque to the caller). Caller must pair with `cb_array_destroy`.
///
/// `capacity` must be > 0; passing 0 returns null (an `ArrayQueue::new(0)`
/// would panic inside crossbeam, which would unwind across the FFI boundary).
#[no_mangle]
pub extern "C" fn cb_array_init(capacity: usize) -> *mut c_void {
    if capacity == 0 {
        return std::ptr::null_mut();
    }
    let q = Box::new(ArrayQueue::<u64>::new(capacity));
    Box::into_raw(q) as *mut c_void
}

/// Push `item` onto the array queue. Returns true on success, false if
/// the queue is full or `q` is null.
///
/// # Safety
/// `q` must be a pointer previously returned by `cb_array_init` and not
/// yet passed to `cb_array_destroy`.
#[no_mangle]
pub unsafe extern "C" fn cb_array_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const ArrayQueue<u64>) };
    q.push(item).is_ok()
}

/// Pop one item; on success writes it to `*out` and returns true. Returns
/// false if the queue is empty, `q` is null, or `out` is null.
///
/// # Safety
/// `q` must be a live ArrayQueue pointer (see `cb_array_push`); `out`
/// must point to writable storage of at least `sizeof(u64)`.
#[no_mangle]
pub unsafe extern "C" fn cb_array_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const ArrayQueue<u64>) };
    match q.pop() {
        Some(v) => {
            unsafe { std::ptr::write(out, v); }
            true
        }
        None => false,
    }
}

/// Free the array queue. Tolerates a null pointer (no-op).
///
/// # Safety
/// `q` must be a pointer previously returned by `cb_array_init` and not
/// yet destroyed. After the call, `q` is dangling.
#[no_mangle]
pub unsafe extern "C" fn cb_array_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut ArrayQueue<u64>) });
}

// ---------------- SegQueue (unbounded MPMC) ----------------

/// Allocate an unbounded `SegQueue<u64>`. Caller must pair with
/// `cb_seg_destroy`.
#[no_mangle]
pub extern "C" fn cb_seg_init() -> *mut c_void {
    let q = Box::new(SegQueue::<u64>::new());
    Box::into_raw(q) as *mut c_void
}

/// Push `item` onto the seg queue. SegQueue is unbounded, so this never
/// reports "full"; failure is only possible on a null pointer (returns
/// false). On success returns true.
///
/// # Safety
/// `q` must be a live SegQueue pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_seg_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const SegQueue<u64>) };
    q.push(item);
    true
}

/// Pop one item; on success writes it to `*out` and returns true.
/// Returns false on empty / null pointers (same convention as the array
/// variant).
///
/// # Safety
/// See `cb_array_pop`.
#[no_mangle]
pub unsafe extern "C" fn cb_seg_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const SegQueue<u64>) };
    match q.pop() {
        Some(v) => {
            unsafe { std::ptr::write(out, v); }
            true
        }
        None => false,
    }
}

/// Free the seg queue. Tolerates a null pointer (no-op).
///
/// # Safety
/// `q` must be a pointer previously returned by `cb_seg_init` and not
/// yet destroyed. After the call, `q` is dangling.
#[no_mangle]
pub unsafe extern "C" fn cb_seg_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut SegQueue<u64>) });
}

// ============================================================
// flume bounded + unbounded
// ============================================================

/// Pair of (sender, receiver) for a single flume channel. Both halves
/// are kept live for the lifetime of the bench so we never close the
/// channel by dropping a side mid-run; that would force `try_send` to
/// fail with `Disconnected` (not `Full`) and the bench harness would
/// see false "full" returns. The Nim adapter calls `flume_destroy`
/// only after all producer / consumer threads have joined.
struct FlumePair {
    tx: flume::Sender<u64>,
    rx: flume::Receiver<u64>,
}

#[no_mangle]
pub extern "C" fn flume_init(capacity: usize) -> *mut c_void {
    if capacity == 0 {
        return std::ptr::null_mut();
    }
    let (tx, rx) = flume::bounded::<u64>(capacity);
    let pair = Box::new(FlumePair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live FlumePair pointer.
#[no_mangle]
pub unsafe extern "C" fn flume_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    pair.tx.try_send(item).is_ok()
}

/// # Safety
/// `q` must be a live FlumePair pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn flume_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    match pair.rx.try_recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `flume_init`.
#[no_mangle]
pub unsafe extern "C" fn flume_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut FlumePair) });
}

#[no_mangle]
pub extern "C" fn flume_unbounded_init() -> *mut c_void {
    let (tx, rx) = flume::unbounded::<u64>();
    let pair = Box::new(FlumePair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live FlumePair pointer (unbounded variant).
#[no_mangle]
pub unsafe extern "C" fn flume_unbounded_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    // Unbounded send only fails on Disconnected; we keep both halves
    // alive in the Box so disconnection is impossible during the run.
    pair.tx.send(item).is_ok()
}

/// # Safety
/// See `flume_pop`.
#[no_mangle]
pub unsafe extern "C" fn flume_unbounded_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    match pair.rx.try_recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `flume_unbounded_init`.
#[no_mangle]
pub unsafe extern "C" fn flume_unbounded_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut FlumePair) });
}

// ============================================================
// kanal bounded + unbounded
// ============================================================

/// Same lifetime invariants as `FlumePair`: keep both sender and
/// receiver alive in the Box so the channel never disconnects mid-run.
struct KanalPair {
    tx: kanal::Sender<u64>,
    rx: kanal::Receiver<u64>,
}

#[no_mangle]
pub extern "C" fn kanal_init(capacity: usize) -> *mut c_void {
    if capacity == 0 {
        return std::ptr::null_mut();
    }
    let (tx, rx) = kanal::bounded::<u64>(capacity);
    let pair = Box::new(KanalPair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live KanalPair pointer.
#[no_mangle]
pub unsafe extern "C" fn kanal_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    pair.tx.try_send(item).unwrap_or(false)
}

/// # Safety
/// `q` must be a live KanalPair pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn kanal_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    match pair.rx.try_recv() {
        Ok(Some(v)) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        // `Ok(None)` means the channel is currently empty;
        // `Err(_)` means the channel is closed (impossible during a
        // bench run, since we hold both halves alive in the Box).
        Ok(None) | Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `kanal_init`.
#[no_mangle]
pub unsafe extern "C" fn kanal_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut KanalPair) });
}

#[no_mangle]
pub extern "C" fn kanal_unbounded_init() -> *mut c_void {
    let (tx, rx) = kanal::unbounded::<u64>();
    let pair = Box::new(KanalPair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live KanalPair pointer (unbounded variant).
#[no_mangle]
pub unsafe extern "C" fn kanal_unbounded_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    pair.tx.try_send(item).unwrap_or(false)
}

/// # Safety
/// See `kanal_pop`.
#[no_mangle]
pub unsafe extern "C" fn kanal_unbounded_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    match pair.rx.try_recv() {
        Ok(Some(v)) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Ok(None) | Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `kanal_unbounded_init`.
#[no_mangle]
pub unsafe extern "C" fn kanal_unbounded_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut KanalPair) });
}
