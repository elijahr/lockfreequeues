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
##     adapters:               <adapter slug -> { version, kind, ... }>
##     absent_adapters:        [<slug>, ...]
##
## Adapter-version sourcing:
## - Vendored C/C++ adapters: hard-coded `const` strings here, extracted
##   from `benchmarks/vendor/<lib>/README.md` "Pinned commit" / "release
##   tag" lines. When the vendor SHA bumps, BOTH the README AND the
##   matching constant below MUST be updated in the same commit; the
##   bench output is the only place mismatches become visible after the
##   fact.
## - Rust adapters: hard-coded from
##   `benchmarks/rust/bench-ffi-crossbeam/Cargo.lock` resolved versions.
##   Bump in lockstep with `cargo build` regenerating the lockfile.
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

import std/[json, osproc, strutils, times]
import ../../src/lockfreequeues

# Boost.LockFree version capture (Item 4). Compile-time include of
# <boost/version.hpp> when either Boost adapter gate is enabled; the
# `BOOST_LIB_VERSION` macro expands to a literal string like "1_74" which
# we can import as a `cstring`. Wrapped in `when` so the include is only
# attempted when the operator already opted in to a Boost build; absent-
# Boost runs never reference the header.
when defined(adapter_boost_lockfree_queue_available) or
     defined(adapter_boost_lockfree_spsc_available):
  {.emit: """/*INCLUDESECTION*/
#include <boost/version.hpp>
""".}
  proc getBoostLibVersionMacro(): cstring {.
    importc: "BOOST_LIB_VERSION", header: "boost/version.hpp", nodecl.}

  proc getBoostVersion(): string =
    ## Returns the Boost.LockFree version string captured at compile time
    ## (e.g. "1_74"). Header-include scope ensures we capture exactly the
    ## Boost the adapter was linked against — see spec Item 4(A).
    $getBoostLibVersionMacro()

# ---------- Hard-coded vendored / cargo-locked versions ----------
#
# Each constant below pairs with a source-of-truth file. Bump both in the
# same commit when the upstream version moves. The `# source:` comment is
# load-bearing for grep-based audits.

const
  AtomicQueueSha = "1a3774a89c86ecfdf08753dbd41018ace5a833a4"
    ## source: benchmarks/vendor/atomic_queue/README.md "Pinned commit"

  ConcurrentQueueSha = "d655418bb644b7f85159d94c591d7d983949fb81"
    ## source: benchmarks/vendor/concurrentqueue/README.md "Pinned commit"
    ## (also covers the `moodycamel` slug, which is the same vendored tree)

  LiblfdsRelease = "7.1.1"
    ## source: benchmarks/vendor/liblfds/README.md "Upstream release tag"

  RigtorpMpmcSha = "b9808ede08f26fa9df4df4e081d19cace8f6c6ea"
    ## source: benchmarks/vendor/rigtorp_mpmc/README.md "Pinned commit"

  RigtorpSpscSha = "1053918dbd251fbff69b24ef27fa5d51c29ec2af"
    ## source: benchmarks/vendor/rigtorp_spsc/README.md "Pinned commit"

  CrossbeamQueueVersion = "0.3.12"
    ## source: benchmarks/rust/bench-ffi-crossbeam/Cargo.lock (crate
    ## name = "crossbeam-queue"). Resolved from the
    ## `crossbeam-queue = "0.3"` requirement in Cargo.toml at lock time.

  FlumeVersion = "0.11.1"
    ## source: benchmarks/rust/bench-ffi-crossbeam/Cargo.lock (crate
    ## name = "flume")

  KanalVersion = "0.1.1"
    ## source: benchmarks/rust/bench-ffi-crossbeam/Cargo.lock (crate
    ## name = "kanal")

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
    let (output, exitCode) = execCmdEx(
      "nimble path " & pkgName,
      options = {poUsePath, poStdErrToStdOut},
    )
    if exitCode != 0:
      return ""
    # Path is on the last non-empty line; nimble prints diagnostic lines
    # first (`Info: Using the environment variable: ...`). Walk from the
    # bottom to find the first line that looks like a filesystem path.
    var path = ""
    for line in output.splitLines:
      let stripped = line.strip()
      if stripped.len > 0 and ('/' in stripped or '\\' in stripped):
        path = stripped
    if path.len == 0:
      return ""
    # Extract the trailing path segment, then strip a leading "<pkg>-".
    var segment = path
    let lastSlash = max(segment.rfind('/'), segment.rfind('\\'))
    if lastSlash >= 0:
      segment = segment[lastSlash + 1 .. ^1]
    let prefix = pkgName & "-"
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
          if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            hexLike = false
            break
      if hexLike:
        return afterPrefix[0 ..< lastDash]
    return afterPrefix
  except CatchableError:
    return ""

# ---------- meta builder ----------

proc adapterEntry(version: string, kind: string,
                  extra: openArray[(string, JsonNode)] = []): JsonNode =
  ## Build one `meta.adapters.<slug>` JsonNode. Empty `version` records
  ## `{"version": null, "kind": kind, "status": "absent"}` so downstream
  ## consumers can distinguish "we couldn't resolve it" from "we resolved
  ## it to the empty string".
  result = newJObject()
  if version.len == 0:
    result["version"] = newJNull()
    result["kind"] = newJString(kind)
    result["status"] = newJString("absent")
  else:
    result["version"] = newJString(version)
    result["kind"] = newJString(kind)
  for (k, v) in extra:
    result[k] = v

proc getAdapterVersions*(): JsonNode =
  ## Build the `meta` JsonNode injected at the top of every BMF JSON
  ## output. Schema mirrors the v5.0.0-wave spec exactly; field order is
  ## preserved by construction (`newJObject` is order-stable in the Nim
  ## std/json implementation).
  result = newJObject()
  result["schema"] = newJInt(1)
  result["generated_at"] = newJString(
    now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"))

  let host = newJObject()
  host["os"] = newJString(hostOS)
  host["arch"] = newJString(hostCPU)
  result["host"] = host

  result["lockfreequeues_version"] = newJString(LockfreequeuesVersion)
  result["nim_version"] = newJString(NimVersion)

  let adapters = newJObject()
  var absent: seq[string] = @[]

  # Vendored C/C++ adapters (kind = vendored-sha / vendored-release).
  adapters["atomic_queue"] = adapterEntry(AtomicQueueSha, "vendored-sha")
  adapters["concurrentqueue"] = adapterEntry(
    ConcurrentQueueSha, "vendored-sha")
  adapters["moodycamel"] = adapterEntry(
    ConcurrentQueueSha, "vendored-sha")
  adapters["liblfds"] = adapterEntry(LiblfdsRelease, "vendored-release")
  adapters["rigtorp_mpmc"] = adapterEntry(RigtorpMpmcSha, "vendored-sha")
  adapters["rigtorp_spsc"] = adapterEntry(RigtorpSpscSha, "vendored-sha")

  # Cargo-locked Rust crates (kind = cargo-locked).
  adapters["crossbeam_queue"] = adapterEntry(
    CrossbeamQueueVersion, "cargo-locked")
  adapters["flume"] = adapterEntry(FlumeVersion, "cargo-locked")
  adapters["kanal"] = adapterEntry(KanalVersion, "cargo-locked")

  # Nimble-resolved (kind = nimble-resolved). Empty -> absent.
  let loonyVer = getNimbleResolvedVersion("loony")
  adapters["loony"] = adapterEntry(loonyVer, "nimble-resolved")
  if loonyVer.len == 0:
    absent.add("loony")

  let threadingVer = getNimbleResolvedVersion("threading")
  adapters["threading"] = adapterEntry(threadingVer, "nimble-resolved")
  if threadingVer.len == 0:
    absent.add("threading")

  # Boost.LockFree (kind = system-package). Only captured when one of the
  # Boost adapter gates is set; otherwise recorded as absent with the
  # explicit "build-without-boost" status so consumers can distinguish
  # "this run did not build Boost" from "this run built Boost but failed
  # to capture the version".
  when defined(adapter_boost_lockfree_queue_available) or
       defined(adapter_boost_lockfree_spsc_available):
    let boostVer = getBoostVersion()
    adapters["boost_lockfree"] = adapterEntry(
      boostVer, "system-package",
      [("captured_from", newJString("boost/version.hpp@BOOST_LIB_VERSION"))])
    if boostVer.len == 0:
      absent.add("boost_lockfree")
  else:
    let boostObj = newJObject()
    boostObj["version"] = newJNull()
    boostObj["kind"] = newJString("system-package")
    boostObj["status"] = newJString("build-without-boost")
    adapters["boost_lockfree"] = boostObj
    absent.add("boost_lockfree")

  # Nim `system.Channel` rides the compiler version.
  adapters["nim_channel"] = adapterEntry(NimVersion, "compiler-builtin")

  # In-tree.
  adapters["lockfreequeues"] = adapterEntry(
    LockfreequeuesVersion, "in-tree")

  result["adapters"] = adapters
  let absentNode = newJArray()
  for slug in absent:
    absentNode.add(newJString(slug))
  result["absent_adapters"] = absentNode
