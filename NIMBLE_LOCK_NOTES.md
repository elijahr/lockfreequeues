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

## Lockfile scope during pre-release: typestates + debra are local-path

During the v5.0.0 integration wave, the `typestates` and `debra`
entries in `nimble.lock` carry **empty `url` and `vcsRevision`
fields**. This is intentional, not a corruption.

The reason is that v5.0.0 of `lockfreequeues` is co-developed against
the `main` branches of `nim-typestates` and `nim-debra` as sibling
checkouts via `config.nims`'s `--path:"../nim-typestates/src"` /
`--path:"../nim-debra/src"` overrides. The CI workflows
(`.github/workflows/{build,bench,bench-comparison}.yml`) `git clone`
those sibling repos at `main` and `nimble install` them locally so
nimble's resolver is satisfied; the compiler then resolves the actual
source via the sibling-path directives. The lockfile entries record
the resulting checksum but cannot meaningfully record an upstream
`url` / `vcsRevision` because the install came from a local path.

What `nimble.lock` actually guarantees today, therefore, is:

- **`unittest2`**: fully url+SHA pinned (Status nim-unittest2).
- **`typestates`**: SHA1 of the installed package contents; url and
  vcsRevision are empty because installs come from the local sibling
  checkout, not a git URL.
- **`debra`**: same as typestates.

This is acceptable for the v5.0.0 pre-release because the CI
workflows themselves pin to `main` HEAD of both repos and the
sibling-path override is what the compiler reads at build time
anyway. Once `typestates v0.10.0` and `debra v0.8.0` are published
to `nimble.directory`, the lockfile should be regenerated against
the registry (which will populate `url` and `vcsRevision` against
the public GitHub tags
`https://github.com/elijahr/nim-typestates@v0.10.0` ->
commit `f3955be472e8353f8736bb639c3133023889ddb8`, and
`https://github.com/elijahr/nim-debra@v0.8.0` ->
commit `123f29c9efbf9b646f80e385cdde95a690200a89`), and the CI's
sibling-clone step can be retired.

Until then, treat `nimble.lock` as binding only for `unittest2`;
typestates + debra are pinned by the CI sibling-clone step plus the
floor versions in `lockfreequeues.nimble` (`typestates >= 0.10.0`,
`debra >= 0.8.0`).
