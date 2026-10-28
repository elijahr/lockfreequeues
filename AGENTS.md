# lockfreequeues

## Project Philosophy

This project follows axiomantic standards: production-quality or nothing,
audit-driven tooling, no shortcuts. Read this file before making changes.

## Build & Test Commands

The justfile is the canonical command surface. Don't memorize `nimble` invocations.

| Task | Command | Notes |
|---|---|---|
| Setup | `just setup` | Installs project dependencies |
| Run tests | `just test` | Discovers and runs all test files via nimble test |
| Lint | `just lint` | nph --check + nimble check |
| Auto-format | `just fmt` | nph (in-place) |

| Build release | `just build` | nimble build -d:release |

## Architecture Overview

Single-package src layout. Public API is exposed via `src/lockfreequeues.nim`.
Tests live in `tests/` and are discovered by `just test` / `nimble test`.


## Key Modules

| Module | Purpose | Notes |
|---|---|---|
| `src/lockfreequeues.nim` | Module entry / public API | Single-file by default; promote to `src/lockfreequeues/` directory if it grows |

| (add per project) | | |

## Setup

1. Install Nim 2.2.6+ (use [mise](https://mise.jdx.dev/) or [choosenim](https://github.com/nim-lang/choosenim)).
2. `just setup`
3. `pip install pre-commit>=3.2.0`  # No native Nim equivalent; system Python or pipx is fine
4. `pre-commit install --install-hooks`

## Conventions

- **src layout:** importable code lives under `src/lockfreequeues.nim` (single-file) or `src/lockfreequeues/` (multi-file).
- **Testing:** stdlib `unittest` discovered via `just test`.
- **Doc comments:** standard Nim `## ` doc comments parsed automatically into API references.
- **Formatting authority:** `nph` is the only formatter (pinned to v0.7.0 in pre-commit, ci.yml, and Setup). Do not hand-format.
- **Pre-commit guard:** `pre-commit` in CI and on commit (`nph`, `nimble check`, YAML, file hygiene).
- **Dependencies:** Automated via Renovate (`.github/renovate.json`) and GitHub Dependabot (`.github/dependabot.yml`).
- **The justfile is the canonical command surface:** `nimble` is an implementation detail. Add new dev workflows as `just` recipes, not as ad-hoc shell commands in README.

## Forbidden Patterns

- No `untyped`/`varargs[untyped]` shortcuts in public APIs without justification.
- No empty `except` blocks. Catch specific exceptions or rethrow.
- No commented-out code. Delete or fix.
- No bypassing `nph` formatting via `# nimformat: off` without a one-line justification.

## Operational Notes


### Momus AI PR Review (`momus.yml`)
The `momus.yml` workflow calls `axiomantic/.github/.github/workflows/momus.yml@devel`.
It requires `secrets.LLM_API_KEY` (configured at the repo or org level).
Momus is securely gated to repository maintainers/collaborators. It runs automatically on internal PRs, and can be triggered on comments via `/ai-review` or `@axiomantic-momus[bot]`. External forks require an explicit maintainer `/ai-review` comment to run.


### `nph` version coupling
The pre-commit `nph` hook, the CI `nph --check` step, and the local `just lint`/`just fmt`
all assume the SAME nph version (currently 0.7.0). Bump in all three places together,
or skew will cause "format clean locally, fails in CI" footguns.



## Glossary

(populate per project)
