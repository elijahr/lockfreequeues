//! Build script for the bench-ffi-crossbeam cdylib.
//!
//! Reads `Cargo.lock` at build time, resolves the exact versions of the
//! three crates the cdylib wraps (`crossbeam-queue`, `flume`, `kanal`),
//! and emits `cargo:rustc-env=BENCH_DEP_*_VERSION=<resolved-version>`
//! lines so `src/lib.rs` can bake the strings into the binary via
//! `env!()`. This closes the v5.0.0-wave version-capture gap: each Rust
//! adapter's `meta.adapters.<slug>.version` reflects what is actually
//! linked into the cdylib that compiled at THIS build, not what
//! `Cargo.toml` happens to request.
//!
//! Lockfile parsing is done by hand (no `toml` dependency) to avoid
//! pulling a build-script-only crate into the dep tree. The lockfile
//! grammar we need is trivial: stanzas separated by blank lines, each
//! with `name = "..."` and `version = "..."` keys we can grep for.

use std::env;
use std::fs;
use std::path::PathBuf;

// Crates we expose version getters for. Matches the
// `bench_ffi_crossbeam_<slug>_version()` exports in `src/lib.rs`.
const CRATES: &[(&str, &str)] = &[
    // (Cargo crate name, env var suffix)
    ("crossbeam-queue", "CROSSBEAM_QUEUE"),
    ("flume", "FLUME"),
    ("kanal", "KANAL"),
];

fn main() {
    // Cargo re-runs the build script automatically when build.rs itself
    // changes; we also need it to re-run when Cargo.lock changes (because
    // resolved versions can move without Cargo.toml moving).
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.lock");

    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR")
            .expect("CARGO_MANIFEST_DIR must be set by Cargo"),
    );
    let lockfile = manifest_dir.join("Cargo.lock");

    let contents = fs::read_to_string(&lockfile).unwrap_or_else(|e| {
        // Lockfile MUST exist at build time for a cdylib. A missing
        // lockfile means the cargo invocation skipped `cargo generate-lockfile`
        // somehow; failing the build is the right outcome — silently
        // shipping nulls in the bench JSON would lie about which versions
        // were linked in.
        panic!(
            "failed to read Cargo.lock at {}: {}. \
             The cdylib build requires a resolved lockfile so the bench \
             output `meta.adapters.<rust crate>.version` can be baked in.",
            lockfile.display(),
            e,
        )
    });

    for (crate_name, env_suffix) in CRATES {
        let version = find_version_in_lockfile(&contents, crate_name)
            .unwrap_or_else(|| {
                panic!(
                    "could not find resolved version for crate `{}` in Cargo.lock. \
                     This usually means the crate is no longer in the dep tree; \
                     either restore the dependency or remove the version getter \
                     for this crate from src/lib.rs and the BENCH_DEP_{} env \
                     emission below.",
                    crate_name, env_suffix,
                )
            });
        println!(
            "cargo:rustc-env=BENCH_DEP_{}_VERSION={}",
            env_suffix, version,
        );
    }
}

/// Find the `version = "..."` line belonging to the stanza whose
/// `name = "..."` matches `crate_name`. Returns `None` if the crate is
/// not in the lockfile.
///
/// Cargo.lock stanzas look like:
///
/// ```text
/// [[package]]
/// name = "crossbeam-queue"
/// version = "0.3.12"
/// source = "registry+https://..."
/// dependencies = [...]
/// ```
///
/// We walk the lockfile line by line, and when we see
/// `name = "<crate_name>"`, we keep walking until we hit either the next
/// `[[package]]` header (mismatched stanza, fall back through) or a
/// `version = "..."` line in the SAME stanza.
fn find_version_in_lockfile(contents: &str, crate_name: &str) -> Option<String> {
    let needle = format!("name = \"{}\"", crate_name);
    let mut lines = contents.lines();
    while let Some(line) = lines.next() {
        if line.trim() != needle {
            continue;
        }
        // Found the stanza. Walk forward until we either find a version
        // key or hit a new stanza boundary.
        for inner in lines.by_ref() {
            let trimmed = inner.trim();
            if trimmed.starts_with("[[package]]") || trimmed.starts_with("[") {
                // New stanza without a version key — malformed lockfile.
                break;
            }
            if let Some(rest) = trimmed.strip_prefix("version = \"") {
                if let Some(end) = rest.find('"') {
                    return Some(rest[..end].to_string());
                }
            }
        }
    }
    None
}
