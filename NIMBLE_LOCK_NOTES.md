# nimble.lock notes

## Why `nim` is not in this lockfile

The `nim` Nimble package is the Nim compiler distribution itself.
It is **intentionally not pinned in `nimble.lock`**.

`nimble lock` originally wrote `nim` into the lockfile because each
of our direct dependencies (`unittest2`, `typestates`, `debra`)
declares `requires "nim >= ..."`, which makes `nim` a transitive
node in the dependency graph. The compiler binary, however, is
installed and managed by:

- the CI `jiro4989/setup-nim-action` (which pins a specific Nim
  release per workflow), and
- `mkdocstrings-nim`'s `nimble install nim` step in the docs job
  (which fetches the compiler source so `import compiler/<X>` can
  resolve for the docstring extractor).

Locking `nim` to a specific checksum in `nimble.lock` conflicts with
both of these: `nimble install nim` against a different upstream
revision than the lockfile's pinned SHA aborts with a checksum
mismatch, and `setup-nim-action`'s pinned compiler will not match
the lockfile entry either. The lockfile entry also does not reflect
what `nimble install nim` actually lays down on disk (the compiler
source tree under `~/.nimble/pkgs/nim-X.Y.Z/`), so even when the
install succeeds the lock entry is misleading.

For these reasons the `nim` top-level entry has been removed, and
the `dependencies: [...]` arrays of the other entries have been
stripped of the `"nim"` reference (Nimble's lock validator rejects
references to absent packages).

The other three packages (`unittest2`, `typestates`, `debra`) remain
pinned by SHA1 checksum and serve their normal lockfile role.
