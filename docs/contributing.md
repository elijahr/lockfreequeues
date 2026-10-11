# Contributing

!!! info "Compatibility Facade Notice"
    `lockfreequeues` is maintained strictly as a **zero-overhead backwards-compatibility facade** around canonical [**`lockfree`**](https://github.com/elijahr/lockfree).
    
    Active feature development, new concurrency primitives (such as CSP `Channel[T]`), cross-language C ABI bindings, and performance benchmarks are developed upstream in **[`lockfree`](https://github.com/elijahr/lockfree)**.
    
    - 📖 **Canonical Documentation**: [https://elijahr.github.io/lockfree/](https://elijahr.github.io/lockfree/)
    - 🔄 **Migration Guide**: [https://elijahr.github.io/lockfree/latest/migrations/from-lockfreequeues-v5/](https://elijahr.github.io/lockfree/latest/migrations/from-lockfreequeues-v5/)
    - 📦 **Canonical Repository**: [https://github.com/elijahr/lockfree](https://github.com/elijahr/lockfree)

How to set up a development environment for `lockfreequeues`, run the test
matrix, build the docs locally, and maintain the facade.

If you are filing a bug or feature request for modern concurrency features,
the [lockfree issue tracker](https://github.com/elijahr/lockfree/issues) is the
authoritative destination. Compatibility-specific issues may be filed on the
[lockfreequeues issue tracker](https://github.com/elijahr/lockfreequeues/issues).

## Repository orientation

### Top-level layout

```text
lockfreequeues/
├── src/lockfreequeues/      # public API + compatibility mappings
├── tests/                   # regression suites + test.nim aggregator
├── examples/                # runnable examples (driven by `nimble examples`)
├── docs/                    # mkdocs source (this site)
├── .github/workflows/       # CI: build, docs, release
├── lockfreequeues.nimble    # package manifest + tasks
├── nim.cfg                  # default compile flags
└── config.nims              # nimble script hooks
```

### `src/lockfreequeues/` — the compatibility API

The four bounded queue types (`Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`)
each live in a single module. Their unbounded counterparts are in
`unbounded_sipsic.nim` etc. Supporting modules:

- `atomic_dsl.nim` — re-exports atomic operations and the load / store
  acquire / release DSL from canonical `lockfree`.
- `backoff.nim` — exponential-backoff helper used by multi-producer
  CAS loops.
- `endpoint.nim` — endpoint handles for role separation.
- `role_tags.nim` — role tags for endpoint types.

All queue types forward operations directly to canonical `lockfree` engines.

### `tests/` — test runner + the `test.nim` aggregator

`tests/test.nim` imports the compatibility test modules and is the entry
point for `nimble test`. Tests use `unittest2`.

## Testing workflow

### `nimble test` — the 8-combo MM × sanitiser matrix

The `test` task in `lockfreequeues.nimble` runs the suite under every
relevant combination:

- C backend with default MM (`orc`) and explicit `arc`, `refc`.
- C++ backend with default MM.
- Two `-d:nimEnforceLockFreeAtomics` lanes (on `arc` and `orc`) that
  reject any spinlock fallback at compile time.
- ThreadSanitizer on `clang` + `atomicArc` (gated by
  `SANITIZE_THREADS=no` to skip on machines without a working clang
  TSAN).
- AddressSanitizer on `clang` (gated by `SANITIZE_ADDRESS=no`).

```sh
# Full matrix.
nimble test

# Skip the sanitiser lanes (faster local iteration).
SANITIZE_THREADS=no SANITIZE_ADDRESS=no nimble test
```

For the matrix CI exercises, see
[Safety Model → Test matrix](guide/safety-model.md#test-matrix).

### Running a single test

For tight iteration, point Nim straight at one file:

```sh
nim c --threads:on -r tests/t_sipsic.nim
```

Add flags as needed: `-d:release` for speed,
`--mm:arc -d:nimEnforceLockFreeAtomics` to reproduce a CI lane,
`--cc:clang --passC:"-fsanitize=thread" --passL:"-fsanitize=thread"` to
debug a TSAN report.

### Adding a new test

New behaviour goes in a focused `t_<feature>.nim` and gets imported
from `tests/test.nim`. Keep tests deterministic: the multi-threaded
suites use bounded loops with timeouts rather than "wait for it to
settle". Follow the pattern in `t_mupsic_threaded.nim` for the
producer / consumer thread plumbing.

## Documentation workflow

### `mkdocs serve` — local preview

Documentation uses MkDocs with the Material theme plus
`mkdocstrings-nim` for the API reference. Set up a virtualenv once:

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r docs-requirements.txt
```

Then serve locally with auto-reload:

```sh
mkdocs serve
# Open http://127.0.0.1:8000
```

The `watch:` block in `mkdocs.yml` includes `src/`, so editing a
docstring in a Nim source file rebuilds the API page that depends on it.

### Adding a new guide page

Create the markdown file under `docs/guide/`, then add an entry to the
`nav:` block in `mkdocs.yml`. Cross-link from existing pages where it
fits — the navigation list and the prose links are independent, and
both matter for discoverability.

Voice guidance for prose pages: prefer specifics (real numbers, real
scenarios) over generalities, keep sentence rhythm irregular (long
sentences next to short ones), and run `mkdocs build --strict` before
committing — `--strict` upgrades broken internal links from warnings
to errors.

### Editing API docs (Nim docstring → mkdocstrings-nim)

API pages under `docs/api/` use `mkdocstrings-nim` to render Nim
docstrings into HTML. To document a new proc, add a `##` doc-comment
on the proc itself (RST style — that is what `mkdocs.yml` configures
via `docstring_style: rst`). Build with `--strict` to catch missing
references.

The `source_url` and `source_ref` config in `mkdocs.yml` stamp a
clickable "source" link on every rendered symbol. Locally those links
point at the `devel` branch on GitHub; CI overrides `DOCS_SOURCE_REF`
per trigger so PR previews link back to the PR's head.

### Building locally

```sh
mkdocs build --strict
# Output lands in site/
```

`--strict` fails the build on any missing internal link or unrecognised
reference. CI runs `mkdocs build --strict` on every push, so a clean
local build is the prerequisite for a green PR.

## Code style

The repo's `.editorconfig` is the canonical formatter contract: 2-space
indent, LF line endings, UTF-8, trailing newline. Beyond that, the
conventions visible in `src/lockfreequeues/`:

- One queue type per file; the file name matches the type
  (`sipsic.nim` for `Sipsic`, etc.).
- Module-level docstring at the top using `##` for public headers and
  RST-style fields (`* parameter description`) for arguments.
- `{.align: CacheLineBytes.}` on every shared atomic that lives next to
  another shared atomic; do not skip the pragma "to save bytes".
- Generic parameters are `static int` for sizes (capacity, segment
  size, producer / consumer count) and bare for value types.
- Keep public proc signatures stable across patches; new procs are
  fine, signature changes ride a minor-version bump.

## PR process

The repo's default branch is `devel`. Branch from there, name the
branch descriptively (`feat/`, `fix/`, `docs/`, `chore/` prefixes), and
open the PR against `devel`. CI exercises the full
build × docs × bench × sanitiser matrix; expect 5-10 minutes of
runtime per PR.

Two repository-specific norms worth knowing before your first PR:

- **No AI attribution in commits or PR bodies.** Do not add
  `Co-Authored-By: Claude / GitHub Copilot / ...` trailers, "Generated
  with ..." footers, or bot signatures. The git history stays human.
- **No GitHub issue numbers in commit messages or PR titles.** GitHub
  auto-links and notifies on `#123` references; the project's
  convention is to keep that linkage in the PR body only, and only
  when explicitly requested.

Recent commit history is the right reference for the desired tone: short
imperative subjects ("typestates 0.7 uplift", "bench-rollup: shared
harness + comparison adapters"), a paragraph or two of body if the
change is non-trivial.

## Release process

### Branch / version bumps / CHANGELOG cuts

Releases are cut from `devel`. The flow:

1. On `devel`, bump `version` in `lockfreequeues.nimble` and add the
   release section to `CHANGELOG.md`.
2. Open a release-prep PR. CI must be green.
3. Merge to `devel`, tag the merge commit `vX.Y.Z`.

### Release-prep PR pattern (post-merge)

Some release work — re-pinning an upstream dependency, regenerating
benchmark snapshots, refreshing docs that reference the new version —
fits better in a follow-up PR after the version bump. Convention is
"release-prep: vX.Y.Z follow-ups" with a checklist body.

### Tagging

Tag the version-bump commit and push:

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

The tag triggers the release workflow in `.github/workflows/release.yml`,
which publishes to nimble and rebuilds the docs site.

### Mike alias materialization

The docs site uses [mike](https://github.com/jimporter/mike) to publish
versioned documentation. The `latest` alias points to the most recent
tagged release; per-version snapshots are kept indefinitely. The release
workflow handles alias updates automatically — manual intervention is
only needed when retiring an older series.

## License

`lockfreequeues` is released under the [MIT License](https://github.com/elijahr/lockfreequeues/blob/devel/LICENSE).
Add yourself to `AUTHORS` in your first PR if you would like attribution.
