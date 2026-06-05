## Adapter version capture for bench output `meta` block.
##
## Closes the benchmark-versioning gap (v5.0.0 wave, Item 1 + Item 4):
## each emitted BMF JSON gains a `meta` sibling key recording adapter ->
## version mapping captured at run time, so downstream consumers (charts,
## archived snapshots, cross-run comparisons) can disambiguate apparent
## regressions caused by upstream-library bumps from regressions in
## `lockfreequeues` itself.
##
## Schema (matches the v5.0.0-wave spec):
##
##   meta:
##     schema:                 1
##     generated_at:           ISO-8601 UTC
##     host:                   { os, arch }
##     lockfreequeues_version: <const from src/lockfreequeues.nim>
##     nim_version:            <NimVersion>
##     adapters:               <adapter slug -> { version, fingerprint, kind, ... }>
##     absent_adapters:        [<slug>, ...]
##
## Per-adapter schema:
##
##   adapters.<slug>: {
##     "version":     <string|null>,  # semver / release-tag if upstream exposes one
##     "fingerprint": <string|null>,  # "sha1:<hex>" content fingerprint, or null
##     "kind":        <string>,       # one of: in-tree, compiler-builtin,
##                                    #         vendored-version-macro,
##                                    #         vendored-content-hash,
##                                    #         cargo-locked, nimble-resolved,
##                                    #         system-package
##     "pinned_sha_per_readme": <string>,  # optional, vendored libs only:
##                                    #   documents the README's pinned SHA so
##                                    #   audits can compare against the
##                                    #   compile-time content fingerprint.
##     "status":      <string>,       # "absent" | "build-without-*" | "unknown"
##                                    #   (key OMITTED on the success path —
##                                    #   absence means "resolved cleanly")
##     ...
##   }
##
## Adapter-version sourcing (no more hand-typed mirrors of README files):
## - Vendored C/C++ headers WITHOUT a version macro
##   (`atomic_queue`, `concurrentqueue`/`moodycamel`, `rigtorp_mpmc`,
##    `rigtorp_spsc`): a SHA-1 fingerprint of the on-disk header bytes is
##   computed at compile time via `staticRead` + `std/sha1`. The
##   fingerprint IS the integrity primitive; any change to the vendored
##   sources changes the fingerprint deterministically. The README's
##   pinned SHA is carried alongside in `pinned_sha_per_readme` as
##   documentation only.
## - Vendored C/C++ libraries WITH a version macro (`liblfds`): the
##   macro is `importc`-ed via a tiny `{.emit.}` include, exactly the
##   pattern used for Boost. The macro is the canonical version string.
## - Rust adapters (`crossbeam_queue`, `flume`, `kanal`): captured at
##   build time inside the Rust cdylib (`benchmarks/rust/bench-ffi-crossbeam/`).
##   A `build.rs` reads the project's `Cargo.lock`, emits
##   `cargo:rustc-env=BENCH_DEP_*_VERSION=...` for each crate, and three
##   `#[no_mangle] pub extern "C"` functions return null-terminated C
##   strings via `env!()`. The Nim side `importc`-s those functions and
##   calls them at run time, so the captured version is exactly what is
##   linked in, not what `Cargo.toml` requests. Gated by the existing
##   `-d:adapter_{crossbeam_*,flume,kanal}_available` flags so absent
##   builds compile clean.
## - Loony / threading: nimble-resolved; `getNimbleResolvedVersion` shells
##   out to `nimble path <pkg>` at run time. Absent package -> "absent"
##   status, no version.
## - Boost.LockFree (system package): captured at compile time via
##   `boost/version.hpp` when one of the Boost adapter gates is set; see
##   Item 4 in the spec. Gated by `when defined(adapter_boost_lockfree_*)`
##   so absent-Boost builds compile clean.
## - Nim builtin: `NimVersion` from `system`.
## - In-tree `lockfreequeues`: the `LockfreequeuesVersion` constant from
##   `src/lockfreequeues.nim`.
##
## The output is best-effort: failures resolving any single adapter
## version are caught and recorded as `{"status": "unknown", ...}` rather
## than aborting the bench run. The bench data is the artifact that
## matters; missing meta is a documentation gap, not a measurement
## failure.

import std/[json, os, osproc, sha1, strutils, times]
import ../../src/lockfreequeues

# ---------- Compile-time content fingerprints ----------
#
# `staticRead` reads bytes at compile time. We concatenate every
# vendored header that ships with the adapter, separated by a recognizable
# marker line, then SHA-1 the result. The output is stable for identical
# inputs and changes deterministically when any byte of any vendored
# header changes. Filenames are listed in sorted order so the
# concatenation order is reproducible.
#
# Spec-required prefix: `"sha1:"` so downstream tools can disambiguate
# hash kinds if we later add SHA-256.

const FingerprintPrefix = "sha1:"

# Compile-time `staticRead` snapshots of every vendored header relevant
# to a content-hash adapter. The bytes are baked into the binary at
# compile time, so the runtime SHA-1 below hashes exactly what compiled
# in — the "build time" semantics the spec asks for. (We hash at run
# time instead of compile time because `std/sha1` uses `copyMem` /
# `c_memcpy`, which the Nim VM rejects with "VM not allowed to do FFI";
# the bytes themselves are still frozen at compile time, so the result
# is deterministic per build.)
const AtomicQueueHeaderBytes: array[5, (string, string)] = [
  (
    "atomic_queue.h",
    staticRead("../vendor/atomic_queue/include/atomic_queue/atomic_queue.h"),
  ),
  (
    "atomic_queue_mutex.h",
    staticRead("../vendor/atomic_queue/include/atomic_queue/atomic_queue_mutex.h"),
  ),
  ("barrier.h", staticRead("../vendor/atomic_queue/include/atomic_queue/barrier.h")),
  ("defs.h", staticRead("../vendor/atomic_queue/include/atomic_queue/defs.h")),
  ("spinlock.h", staticRead("../vendor/atomic_queue/include/atomic_queue/spinlock.h")),
]

const ConcurrentQueueHeaderBytes: array[1, (string, string)] =
  [("concurrentqueue.h", staticRead("../vendor/concurrentqueue/concurrentqueue.h"))]

const RigtorpMpmcHeaderBytes: array[1, (string, string)] =
  [("MPMCQueue.h", staticRead("../vendor/rigtorp_mpmc/include/rigtorp/MPMCQueue.h"))]

const RigtorpSpscHeaderBytes: array[1, (string, string)] =
  [("SPSCQueue.h", staticRead("../vendor/rigtorp_spsc/include/rigtorp/SPSCQueue.h"))]

proc concatWithSeparators(parts: openArray[(string, string)]): string =
  ## Concatenate `(filename, contents)` pairs into a single string with a
  ## `\n--- <filename> ---\n` separator before each part. The separator
  ## structure makes a divergence diagnosable from the raw concatenation
  ## even without the original files. `parts` MUST already be sorted by
  ## filename — the caller is responsible for sort order so the
  ## fingerprint is reproducible.
  result = ""
  for (name, body) in parts:
    result.add("\n--- ")
    result.add(name)
    result.add(" ---\n")
    result.add(body)

proc fingerprintOf(parts: openArray[(string, string)]): string =
  ## SHA-1 fingerprint of the concatenation of `parts` in their given
  ## order. Returns the spec-mandated `"sha1:<40-hex>"` string.
  FingerprintPrefix & toLowerAscii($secureHash(concatWithSeparators(parts)))

# ---------- README-pinned SHAs (documentation only) ----------
#
# These are NOT the source of truth for `version` anymore — the
# compile-time fingerprint above is. We keep the README-pinned SHAs in
# `pinned_sha_per_readme` so an audit can spot drift between the README's
# claim and the actual bytes that compiled in.

const
  AtomicQueueReadmeSha = "1a3774a89c86ecfdf08753dbd41018ace5a833a4"
    ## source: benchmarks/vendor/atomic_queue/README.md "Pinned commit"

  ConcurrentQueueReadmeSha = "d655418bb644b7f85159d94c591d7d983949fb81"
    ## source: benchmarks/vendor/concurrentqueue/README.md "Pinned commit"

  RigtorpMpmcReadmeSha = "b9808ede08f26fa9df4df4e081d19cace8f6c6ea"
    ## source: benchmarks/vendor/rigtorp_mpmc/README.md "Pinned commit"

  RigtorpSpscReadmeSha = "1053918dbd251fbff69b24ef27fa5d51c29ec2af"
    ## source: benchmarks/vendor/rigtorp_spsc/README.md "Pinned commit"

# ---------- liblfds: version macro from vendored header ----------
#
# `LFDS711_MISC_VERSION_STRING` is defined in
# `benchmarks/vendor/liblfds/liblfds711/inc/liblfds711/lfds711_misc.h`.
# We `importc` it the same way we do `BOOST_LIB_VERSION`, ensuring the
# version comes from the actual bytes that compile in.

# The `-I` flag for the liblfds vendor root is only on the compile line
# when the liblfds adapter is gated in (see `benchmarks/nim/adapters/
# liblfds_adapter.nim`, which emits `{.passC: "-I<vendor>/liblfds".}`).
# We therefore gate the `#include` + `importc` of
# `LFDS711_MISC_VERSION_STRING` on the same flag. From the
# `benchmarks/vendor/liblfds/` include root the misc header lives at
# `liblfds711/inc/liblfds711/lfds711_misc.h`.
when defined(adapter_liblfds_available):
  const LiblfdsAdapterPresent = true
  # We `#include` the umbrella header rather than `lfds711_misc.h`
  # directly: `lfds711_misc.h` depends on the porting-abstraction-layer
  # headers (compiler / OS / processor) being included first, and only
  # the umbrella header pulls them in in the right order. The macro
  # `LFDS711_MISC_VERSION_STRING` is defined transitively via this
  # include. Path is relative to the `-I<vendor>/liblfds` flag emitted
  # by `liblfds_adapter.nim`.
  {.
    emit: """/*INCLUDESECTION*/
#include "liblfds711/inc/liblfds711.h"
"""
  .}

  # Imported as a variable, not a proc: LFDS711_MISC_VERSION_STRING is a
  # C preprocessor macro that expands to a string literal, so calling it
  # with `()` would emit `"literal"()` and fail C compilation. A template
  # preserves the existing call-site form `getLiblfdsVersionMacro()`.
  let liblfdsVersionMacro {.
    importc: "LFDS711_MISC_VERSION_STRING",
    header: "liblfds711/inc/liblfds711.h",
    nodecl
  .}: cstring
  template getLiblfdsVersionMacro(): cstring =
    liblfdsVersionMacro

else:
  const LiblfdsAdapterPresent = false

# ---------- Boost.LockFree: version macro from system header ----------
#
# Compile-time include of <boost/version.hpp> when either Boost adapter
# gate is enabled; `BOOST_LIB_VERSION` expands to a literal string like
# "1_74".
when defined(adapter_boost_lockfree_queue_available) or
    defined(adapter_boost_lockfree_spsc_available):
  {.
    emit: """/*INCLUDESECTION*/
#include <boost/version.hpp>
"""
  .}
  # Imported as a variable, not a proc: BOOST_LIB_VERSION is a C
  # preprocessor macro that expands to a string literal (e.g. "1_74"),
  # so calling it with `()` would emit `"1_74"()` and fail C compilation.
  let boostLibVersionMacro {.
    importc: "BOOST_LIB_VERSION", header: "boost/version.hpp", nodecl
  .}: cstring
  template getBoostLibVersionMacro(): cstring =
    boostLibVersionMacro

  proc getBoostVersion(): string =
    ## Returns the Boost.LockFree version string captured at compile time
    ## (e.g. "1_74"). Header-include scope ensures we capture exactly the
    ## Boost the adapter was linked against — see spec Item 4(A).
    $getBoostLibVersionMacro()

# ---------- Rust cdylib: importc the version getters ----------
#
# The Rust cdylib at `benchmarks/rust/bench-ffi-crossbeam/` exports three
# `extern "C"` functions that return null-terminated C strings with the
# crate versions resolved at cargo-build time (read from `Cargo.lock` by
# a `build.rs`). We `importc` each function, gated by the matching Nim
# `-d:adapter_*_available` flag; the link flag emission lives in
# `benchmarks/nim/adapters/crossbeam_link.nim` (already imported by the
# adapter modules; a bench binary that includes any of the three Rust
# adapters will pull that in transitively, providing `-lbench_ffi_crossbeam`).

when defined(adapter_crossbeam_array_queue_available) or
    defined(adapter_crossbeam_seg_queue_available):
  # Defensive import: pulls in the shared `{.passL.}` link directives
  # for `-lbench_ffi_crossbeam` so the `importc` getter below resolves
  # even when this module is the ONLY consumer of the crossbeam gate
  # in a given binary (e.g. a script that captures versions without
  # importing any crossbeam adapter directly). Nim dedups module
  # imports, so binaries that already import a crossbeam adapter
  # (which transitively imports this link module) are unaffected.
  import ./adapters/crossbeam_link
  proc bench_ffi_crossbeam_queue_version(): cstring {.importc, cdecl.}
  const CrossbeamCdylibLinked = true
else:
  const CrossbeamCdylibLinked = false

when defined(adapter_flume_available):
  proc bench_ffi_flume_version(): cstring {.importc, cdecl.}
  const FlumeCdylibLinked = true
else:
  const FlumeCdylibLinked = false

when defined(adapter_kanal_available):
  proc bench_ffi_kanal_version(): cstring {.importc, cdecl.}
  const KanalCdylibLinked = true
else:
  const KanalCdylibLinked = false

# ---------- Nimble-resolved adapters ----------

proc getNimbleResolvedVersion(pkgName: string): string =
  ## Best-effort resolve of a nimble-managed package's version via
  ## `nimble path <pkg>`. The resolved path conventionally embeds the
  ## version (`.../pkgs2/<name>-<version>-<hash>` or `.../pkgs/<name>-<version>`);
  ## we parse the last hyphenated segment that looks like a version.
  ##
  ## Returns "" on any failure (binary not on PATH, package absent,
  ## exit code != 0, no parseable version segment). Callers map the
  ## empty string to `{"status": "absent"}` in the meta JSON.
  ##
  ## Defensive: `osproc.execCmdEx` may itself throw on platforms where
  ## the runtime cannot fork (rare; e.g. some heavily sandboxed CI).
  ## Wrap in try/except so a missing nimble never crashes the bench.
  try:
    # quoteShell escapes pkgName before concatenation. Today's call sites
    # pass safe literals ("loony", "threading"), but quoting future-proofs
    # the helper against any caller passing a dynamic or unusual package
    # name without re-validating this site.
    let (output, exitCode) = execCmdEx(
      "nimble path " & quoteShell(pkgName), options = {poUsePath, poStdErrToStdOut}
    )
    if exitCode != 0:
      return ""
    # `nimble path <pkg>` may print diagnostic `Info: ...` lines either
    # before OR after the actual path (the ordering has shifted across
    # nimble releases, and some `Info:` lines themselves contain
    # slashes, e.g. `Info: Using the environment variable:
    # NIMBLE_DIR=/home/.../.nimble`). The reliable signal is not the
    # line position but the shape: a real package path's basename
    # starts with `<pkgName>-`. Walk all slash-bearing lines and pick
    # the first whose trailing segment matches that prefix. Returns
    # "" if no line qualifies.
    let prefix = pkgName & "-"
    var path = ""
    for line in output.splitLines:
      # Whitespace strip first; then strip trailing path separators
      #: some nimble versions / platforms emit
      # a trailing `/` or `\` on the path line, which would otherwise
      # leave the basename empty and miss the `<pkg>-` prefix match.
      var stripped = line.strip()
      stripped = stripped.strip(chars = {'/', '\\'}, leading = false)
      if stripped.len == 0:
        continue
      if '/' notin stripped and '\\' notin stripped:
        continue
      let lastSlash = max(stripped.rfind('/'), stripped.rfind('\\'))
      let basename =
        if lastSlash >= 0:
          stripped[lastSlash + 1 .. ^1]
        else:
          stripped
      if basename.startsWith(prefix):
        path = stripped
        break
    if path.len == 0:
      return ""
    # Extract the trailing path segment, then strip a leading "<pkg>-".
    var segment = path
    let lastSlash2 = max(segment.rfind('/'), segment.rfind('\\'))
    if lastSlash2 >= 0:
      segment = segment[lastSlash2 + 1 .. ^1]
    if not segment.startsWith(prefix):
      return ""
    let afterPrefix = segment[prefix.len .. ^1]
    # `<version>-<hash>` (pkgs2) or `<version>` (pkgs). Split on the last
    # hyphen iff what follows looks like a hex hash (>= 8 hex chars).
    let lastDash = afterPrefix.rfind('-')
    if lastDash > 0:
      let tail = afterPrefix[lastDash + 1 .. ^1]
      var hexLike = tail.len >= 8
      if hexLike:
        for ch in tail:
          if ch notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
            hexLike = false
            break
      if hexLike:
        return afterPrefix[0 ..< lastDash]
    return afterPrefix
  except CatchableError:
    return ""

# ---------- meta builder ----------

proc fingerprintEntry(
    fingerprint: string, kind: string, pinnedSha: string = ""
): JsonNode =
  ## Build a `meta.adapters.<slug>` entry for a vendored-content-hash
  ## library: `version` is null (no upstream version exists), `fingerprint`
  ## is the compile-time SHA-1 of the vendored bytes, `kind` is
  ## `vendored-content-hash`, and `pinned_sha_per_readme` documents the
  ## README's pinned SHA for audit cross-checks.
  result = newJObject()
  result["version"] = newJNull()
  result["fingerprint"] = newJString(fingerprint)
  result["kind"] = newJString(kind)
  if pinnedSha.len > 0:
    result["pinned_sha_per_readme"] = newJString(pinnedSha)

proc adapterEntry(
    version: string, kind: string, extra: openArray[(string, JsonNode)] = []
): JsonNode =
  ## Build one `meta.adapters.<slug>` JsonNode. Empty `version` records
  ## `{"version": null, "fingerprint": null, "kind": kind, "status": "absent"}`
  ## so downstream consumers can distinguish "we couldn't resolve it"
  ## from "we resolved it to the empty string".
  result = newJObject()
  if version.len == 0:
    result["version"] = newJNull()
    result["fingerprint"] = newJNull()
    result["kind"] = newJString(kind)
    result["status"] = newJString("absent")
  else:
    result["version"] = newJString(version)
    result["fingerprint"] = newJNull()
    result["kind"] = newJString(kind)
  for (k, v) in extra:
    result[k] = v

proc rustCrateEntry(linked: bool, version: string, slug: string): JsonNode =
  ## Build the entry for a Rust crate captured via the cdylib FFI getter.
  ## When the cdylib is not linked into THIS bench binary (the gate flag
  ## is unset), records `{"status": "build-without-rust-cdylib"}` so
  ## absent-Rust builds are unambiguous. When linked but the getter
  ## returned an empty / whitespace-only string, records
  ## `{"status": "unknown"}` so a build.rs failure doesn't silently look
  ## like a successful capture.
  result = newJObject()
  result["kind"] = newJString("cargo-locked")
  if not linked:
    result["version"] = newJNull()
    result["fingerprint"] = newJNull()
    result["status"] = newJString("build-without-rust-cdylib")
  elif version.strip().len == 0:
    result["version"] = newJNull()
    result["fingerprint"] = newJNull()
    result["status"] = newJString("unknown")
    result["captured_from"] = newJString("bench_ffi_crossbeam_" & slug & "_version()")
  else:
    result["version"] = newJString(version)
    result["fingerprint"] = newJNull()
    result["captured_from"] = newJString("bench_ffi_crossbeam_" & slug & "_version()")

proc getAdapterVersions*(): JsonNode =
  ## Build the `meta` JsonNode injected at the top of every BMF JSON
  ## output. Schema mirrors the v5.0.0-wave spec exactly; field order is
  ## preserved by construction (`newJObject` is order-stable in the Nim
  ## std/json implementation).
  result = newJObject()
  result["schema"] = newJInt(1)
  # `getTime().utc` rather than `now().utc`:
  # `now()` is local-time and converting to UTC depends on the system
  # timezone configuration; `getTime()` returns a Time object directly
  # so the ISO-8601 output is timezone-independent.
  result["generated_at"] = newJString(getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"))

  let host = newJObject()
  host["os"] = newJString(hostOS)
  host["arch"] = newJString(hostCPU)
  result["host"] = host

  result["lockfreequeues_version"] = newJString(LockfreequeuesVersion)
  result["nim_version"] = newJString(NimVersion)

  let adapters = newJObject()
  var absent: seq[string] = @[]

  # ---- Vendored C/C++ adapters captured by content fingerprint ----
  # (header-only libs without an upstream version macro). Fingerprints
  # are computed at run-time over the compile-time-baked header bytes.
  let atomicQueueFingerprint = fingerprintOf(AtomicQueueHeaderBytes)
  let concurrentQueueFingerprint = fingerprintOf(ConcurrentQueueHeaderBytes)
  let rigtorpMpmcFingerprint = fingerprintOf(RigtorpMpmcHeaderBytes)
  let rigtorpSpscFingerprint = fingerprintOf(RigtorpSpscHeaderBytes)
  adapters["atomic_queue"] = fingerprintEntry(
    atomicQueueFingerprint, "vendored-content-hash", AtomicQueueReadmeSha
  )
  adapters["concurrentqueue"] = fingerprintEntry(
    concurrentQueueFingerprint, "vendored-content-hash", ConcurrentQueueReadmeSha
  )
  adapters["moodycamel"] = fingerprintEntry(
    concurrentQueueFingerprint, "vendored-content-hash", ConcurrentQueueReadmeSha
  )
  adapters["rigtorp_mpmc"] = fingerprintEntry(
    rigtorpMpmcFingerprint, "vendored-content-hash", RigtorpMpmcReadmeSha
  )
  adapters["rigtorp_spsc"] = fingerprintEntry(
    rigtorpSpscFingerprint, "vendored-content-hash", RigtorpSpscReadmeSha
  )

  # ---- liblfds: vendored-version-macro ----
  # The `LFDS711_MISC_VERSION_STRING` macro is only reachable if a
  # liblfds adapter was gated in (so `-I…/inc` is on the compile line).
  # Otherwise record null with the explicit "build-without-liblfds"
  # status so absent-liblfds builds are unambiguous.
  when LiblfdsAdapterPresent:
    let liblfdsVer = $getLiblfdsVersionMacro()
    let liblfdsEntry = newJObject()
    liblfdsEntry["version"] = newJString(liblfdsVer)
    liblfdsEntry["fingerprint"] = newJNull()
    liblfdsEntry["kind"] = newJString("vendored-version-macro")
    liblfdsEntry["captured_from"] =
      newJString("liblfds711/inc/liblfds711.h@LFDS711_MISC_VERSION_STRING")
    adapters["liblfds"] = liblfdsEntry
  else:
    let liblfdsEntry = newJObject()
    liblfdsEntry["version"] = newJNull()
    liblfdsEntry["fingerprint"] = newJNull()
    liblfdsEntry["kind"] = newJString("vendored-version-macro")
    liblfdsEntry["status"] = newJString("build-without-liblfds")
    adapters["liblfds"] = liblfdsEntry
    absent.add("liblfds")

  # ---- Rust crates: cargo-locked, captured via cdylib FFI getter ----
  block crossbeamCapture:
    var version = ""
    when CrossbeamCdylibLinked:
      try:
        version = $bench_ffi_crossbeam_queue_version()
      except CatchableError:
        version = ""
    adapters["crossbeam_queue"] =
      rustCrateEntry(CrossbeamCdylibLinked, version, "crossbeam_queue")
    if CrossbeamCdylibLinked and version.strip().len == 0:
      absent.add("crossbeam_queue")
    elif not CrossbeamCdylibLinked:
      absent.add("crossbeam_queue")

  block flumeCapture:
    var version = ""
    when FlumeCdylibLinked:
      try:
        version = $bench_ffi_flume_version()
      except CatchableError:
        version = ""
    adapters["flume"] = rustCrateEntry(FlumeCdylibLinked, version, "flume")
    if FlumeCdylibLinked and version.strip().len == 0:
      absent.add("flume")
    elif not FlumeCdylibLinked:
      absent.add("flume")

  block kanalCapture:
    var version = ""
    when KanalCdylibLinked:
      try:
        version = $bench_ffi_kanal_version()
      except CatchableError:
        version = ""
    adapters["kanal"] = rustCrateEntry(KanalCdylibLinked, version, "kanal")
    if KanalCdylibLinked and version.strip().len == 0:
      absent.add("kanal")
    elif not KanalCdylibLinked:
      absent.add("kanal")

  # ---- Nimble-resolved adapters (kind = nimble-resolved). Empty -> absent ----
  let loonyVer = getNimbleResolvedVersion("loony")
  adapters["loony"] = adapterEntry(loonyVer, "nimble-resolved")
  if loonyVer.len == 0:
    absent.add("loony")

  let threadingVer = getNimbleResolvedVersion("threading")
  adapters["threading"] = adapterEntry(threadingVer, "nimble-resolved")
  if threadingVer.len == 0:
    absent.add("threading")

  # ---- Boost.LockFree (kind = system-package) ----
  # Only captured when one of the Boost adapter gates is set; otherwise
  # recorded as absent with the explicit "build-without-boost" status so
  # consumers can distinguish "this run did not build Boost" from "this
  # run built Boost but failed to capture the version".
  when defined(adapter_boost_lockfree_queue_available) or
      defined(adapter_boost_lockfree_spsc_available):
    let boostVer = getBoostVersion()
    adapters["boost_lockfree"] = adapterEntry(
      boostVer,
      "system-package",
      [("captured_from", newJString("boost/version.hpp@BOOST_LIB_VERSION"))],
    )
    if boostVer.len == 0:
      absent.add("boost_lockfree")
  else:
    let boostObj = newJObject()
    boostObj["version"] = newJNull()
    boostObj["fingerprint"] = newJNull()
    boostObj["kind"] = newJString("system-package")
    boostObj["status"] = newJString("build-without-boost")
    adapters["boost_lockfree"] = boostObj
    absent.add("boost_lockfree")

  # ---- Nim `system.Channel` rides the compiler version ----
  adapters["nim_channel"] = adapterEntry(NimVersion, "compiler-builtin")

  # ---- In-tree ----
  adapters["lockfreequeues"] = adapterEntry(LockfreequeuesVersion, "in-tree")

  result["adapters"] = adapters
  let absentNode = newJArray()
  for slug in absent:
    absentNode.add(newJString(slug))
  result["absent_adapters"] = absentNode
