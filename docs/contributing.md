# Contributing

How to set up a development environment for `lockfreequeues`, run the test
matrix, build the docs locally, and ship a release. This page supersedes
the short top-level `CONTRIBUTING.md` at the repo root; the root file
remains as a pointer for tooling that expects it (GitHub, OSS scanners).

If you are filing a bug or feature request, the project's
[issue tracker](https://github.com/elijahr/lockfreequeues/issues) is the
right starting point.

## Repository orientation

### Top-level layout

_(Coming in v4.2.0)_

### `src/lockfreequeues/` — the public API

_(Coming in v4.2.0)_

### `benchmarks/` — bench harness

See [Benchmarks](benchmarks.md) for the published numbers and the
methodology used to produce them.

### `tests/` — test runner + the `test.nim` aggregator

_(Coming in v4.2.0)_

## Testing workflow

### `nimble test` — the 8-combo MM × sanitiser matrix

_(Coming in v4.2.0)_

### `nimble benchtests` — bench harness unit tests

_(Coming in v4.2.0)_

### Running a single test

_(Coming in v4.2.0)_

```bash
# (example coming)
```

### Adding a new test

_(Coming in v4.2.0)_

For the full test matrix that CI exercises, see
[Safety Model → Test matrix](guide/safety-model.md#test-matrix).

## Documentation workflow

### `mkdocs serve` — local preview

_(Coming in v4.2.0)_

```bash
# (example coming)
```

### Adding a new guide page

_(Coming in v4.2.0)_

### Editing API docs (Nim docstring → mkdocstrings-nim)

_(Coming in v4.2.0)_

### Building locally

_(Coming in v4.2.0)_

```bash
# (example coming)
```

## Release process

### Branch / version bumps / CHANGELOG cuts

_(Coming in v4.2.0)_

### Release-prep PR pattern (post-merge)

_(Coming in v4.2.0)_

### Tagging

_(Coming in v4.2.0)_

### Mike alias materialization

_(Coming in v4.2.0)_
