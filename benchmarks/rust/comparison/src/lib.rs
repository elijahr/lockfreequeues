//! C-ABI consolidated shim around three Rust queue crates: `crossbeam-queue`
//! (`ArrayQueue` + `SegQueue`), `flume` (bounded + unbounded MPMC channels),
//! and `kanal` (bounded + unbounded MPMC channels). v4.2.0 Stage 5.2
//! consolidates all three into a single cdylib (`libbench_ffi_comparison`)
//! so the Nim bench harness only links one shared object regardless of how
//! many Rust comparison adapters are enabled.
//!
//! Naming convention (strict prefix-per-crate so a single cdylib never sees
//! symbol collisions across crates):
//!
//! | Function                  | Backing type                                |
//! |---------------------------|---------------------------------------------|
//! | crossbeam_array_init      | crossbeam_queue::ArrayQueue<u64>            |
//! | crossbeam_array_push      | "                                           |
//! | crossbeam_array_pop       | "                                           |
//! | crossbeam_array_destroy   | "                                           |
//! | crossbeam_seg_init        | crossbeam_queue::SegQueue<u64>              |
//! | crossbeam_seg_push        | "                                           |
//! | crossbeam_seg_pop         | "                                           |
//! | crossbeam_seg_destroy     | "                                           |
//! | flume_init                | flume::bounded::<u64> sender+receiver pair  |
//! | flume_push                | "                                           |
//! | flume_pop                 | "                                           |
//! | flume_destroy             | "                                           |
//! | flume_unbounded_init      | flume::unbounded::<u64> sender+receiver pair|
//! | flume_unbounded_push      | "                                           |
//! | flume_unbounded_pop       | "                                           |
//! | flume_unbounded_destroy   | "                                           |
//! | kanal_init                | kanal::bounded::<u64> sender+receiver pair  |
//! | kanal_push                | "                                           |
//! | kanal_pop                 | "                                           |
//! | kanal_destroy             | "                                           |
//! | kanal_unbounded_init      | kanal::unbounded::<u64> sender+receiver pair|
//! | kanal_unbounded_push      | "                                           |
//! | kanal_unbounded_pop       | "                                           |
//! | kanal_unbounded_destroy   | "                                           |
//!
//! All functions are panic-safe relative to the Rust side: they perform
//! their own null-pointer checks. They are NOT thread-safe with respect
//! to `*_destroy` (the queues themselves are MPMC-safe, but freeing the
//! queue while another thread is mid-push/mid-pop is a UAF). The Nim-side
//! adapters guarantee `cleanup` is called only after all producer /
//! consumer threads have joined.
//!
//! Object lifetime: each `*_init` allocates a Box on the Rust heap via
//! `Box::into_raw`. The returned `*mut c_void` must be passed back to the
//! matching `*_destroy` to reclaim it; intermediate `_push` / `_pop`
//! calls borrow it immutably (interior mutability handles writes for
//! crossbeam; flume + kanal sender/receiver pairs are themselves clonable
//! handles into the underlying channel state).

use crossbeam_queue::{ArrayQueue, SegQueue};
use std::os::raw::c_void;

// ============================================================
// crossbeam_queue::ArrayQueue (bounded MPMC)
// ============================================================

/// Allocate a bounded `ArrayQueue<u64>` of `capacity`. Returns the queue
/// pointer (opaque to the caller). Caller must pair with
/// `crossbeam_array_destroy`.
///
/// `capacity` must be > 0; passing 0 returns null (an `ArrayQueue::new(0)`
/// would panic inside crossbeam, which would unwind across the FFI boundary).
#[unsafe(no_mangle)]
pub extern "C" fn crossbeam_array_init(capacity: usize) -> *mut c_void {
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
/// `q` must be a pointer previously returned by `crossbeam_array_init`
/// and not yet passed to `crossbeam_array_destroy`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn crossbeam_array_push(q: *mut c_void, item: u64) -> bool {
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
/// `q` must be a live ArrayQueue pointer (see `crossbeam_array_push`); `out`
/// must point to writable storage of at least `sizeof(u64)`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn crossbeam_array_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const ArrayQueue<u64>) };
    match q.pop() {
        Some(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        None => false,
    }
}

/// Free the array queue. Tolerates a null pointer (no-op).
///
/// # Safety
/// `q` must be a pointer previously returned by `crossbeam_array_init`
/// and not yet destroyed. After the call, `q` is dangling.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn crossbeam_array_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut ArrayQueue<u64>) });
}

// ============================================================
// crossbeam_queue::SegQueue (unbounded MPMC)
// ============================================================

/// Allocate an unbounded `SegQueue<u64>`. Caller must pair with
/// `crossbeam_seg_destroy`.
#[unsafe(no_mangle)]
pub extern "C" fn crossbeam_seg_init() -> *mut c_void {
    let q = Box::new(SegQueue::<u64>::new());
    Box::into_raw(q) as *mut c_void
}

/// Push `item` onto the seg queue. SegQueue is unbounded, so this never
/// reports "full"; failure is only possible on a null pointer (returns
/// false). On success returns true.
///
/// # Safety
/// `q` must be a live SegQueue pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn crossbeam_seg_push(q: *mut c_void, item: u64) -> bool {
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
/// See `crossbeam_array_pop`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn crossbeam_seg_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const SegQueue<u64>) };
    match q.pop() {
        Some(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        None => false,
    }
}

/// Free the seg queue. Tolerates a null pointer (no-op).
///
/// # Safety
/// `q` must be a pointer previously returned by `crossbeam_seg_init`
/// and not yet destroyed. After the call, `q` is dangling.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn crossbeam_seg_destroy(q: *mut c_void) {
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

#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn flume_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    pair.tx.try_send(item).is_ok()
}

/// # Safety
/// `q` must be a live FlumePair pointer; `out` must be writable.
#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn flume_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut FlumePair) });
}

#[unsafe(no_mangle)]
pub extern "C" fn flume_unbounded_init() -> *mut c_void {
    let (tx, rx) = flume::unbounded::<u64>();
    let pair = Box::new(FlumePair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live FlumePair pointer (unbounded variant).
#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
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

#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kanal_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    pair.tx.try_send(item).unwrap_or(false)
}

/// # Safety
/// `q` must be a live KanalPair pointer; `out` must be writable.
#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kanal_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut KanalPair) });
}

#[unsafe(no_mangle)]
pub extern "C" fn kanal_unbounded_init() -> *mut c_void {
    let (tx, rx) = kanal::unbounded::<u64>();
    let pair = Box::new(KanalPair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live KanalPair pointer (unbounded variant).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kanal_unbounded_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    pair.tx.try_send(item).unwrap_or(false)
}

/// # Safety
/// See `kanal_pop`.
#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kanal_unbounded_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut KanalPair) });
}
