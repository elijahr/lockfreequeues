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
//! Lockfile parsing uses the `toml` crate (build-dependency). The
//! previous implementation walked the file line by line and assumed
//! `name = ...` appeared before `version = ...` within each
//! `[[package]]` stanza; TOML keys are order-independent, so a future
//! Cargo release or a manual lockfile edit could silently break that
//! assumption. Parsing as TOML makes the lookup robust against any
//! key ordering.

use std::env;
use std::fs;
use std::path::PathBuf;

use toml::Value;

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

    let parsed: Value = contents.parse().unwrap_or_else(|e| {
        panic!(
            "failed to parse Cargo.lock as TOML at {}: {}",
            lockfile.display(),
            e,
        )
    });

    for (crate_name, env_suffix) in CRATES {
        let version = find_version_in_lockfile(&parsed, crate_name)
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

/// Find the `version` field of the `[[package]]` entry whose `name`
/// matches `crate_name`. Returns `None` if the crate is not present
/// in the lockfile.
///
/// Cargo.lock's top-level shape is:
///
/// ```text
/// [[package]]
/// name = "crossbeam-queue"
/// version = "0.3.12"
/// source = "registry+https://..."
/// dependencies = [...]
/// ```
///
/// TOML parses `[[package]]` as an array of tables under the
/// `package` key. We iterate and match on `name`, returning `version`
/// when found. Key order within each table is irrelevant.
fn find_version_in_lockfile(parsed: &Value, crate_name: &str) -> Option<String> {
    let packages = parsed.get("package")?.as_array()?;
    // Scan the full array so we can warn on duplicate `name` matches.
    // Multiple `[[package]]` entries with the same name in a single
    // `Cargo.lock` is legal (Cargo permits multiple major versions of
    // the same crate to coexist) but the bench harness records ONE
    // version per crate name into `meta.adapters.<slug>.version`, so a
    // duplicate is ambiguous: silently returning the first match would
    // hide which copy is actually linked. Warn via `cargo:warning=…`
    // so the operator sees the ambiguity in build output without
    // failing the build (the first match is still returned for
    // forward compatibility — duplicates were never expected here).
    let mut found: Option<String> = None;
    for pkg in packages {
        // A `[[package]]` entry without a `name` is malformed but should
        // not abort the search; skip it and continue scanning. Same for
        // a matching entry without a `version`.
        let name = match pkg.get("name").and_then(Value::as_str) {
            Some(n) => n,
            None => continue,
        };
        if name == crate_name {
            if let Some(version) = pkg.get("version").and_then(Value::as_str)
            {
                if let Some(prev) = &found {
                    println!(
                        "cargo:warning=bench-ffi-crossbeam build.rs: \
                         multiple Cargo.lock entries for crate {:?} \
                         ({:?} and {:?}); reporting the first match in \
                         BENCH_DEP_<crate>_VERSION. Disambiguate by \
                         removing the duplicate or splitting cdylib \
                         builds per crate version.",
                        crate_name, prev, version,
                    );
                } else {
                    found = Some(version.to_string());
                }
            }
        }
    }
    found
}
