# Next Steps for lockfreequeues

Welcome to your newly scaffolded project! This repository was generated with **Polyform** configured with composable facets:
- Nim: `True`
- Python: `False`
- TypeScript: `False`
- C/C++: `False`

Follow this checklist to complete project onboarding and configure CI/CD.

---

## 1. Initial Local Setup & Verification

Run the canonical `just` recipes to verify your development environment:

```bash
# 1. Install toolchain dependencies
just setup

# 2. Run test suite
just test

# 3. Check formatting and linter
just lint

# 4. Check for committed secrets
just check-secrets
```

---

## 3. GitHub Secrets & CI Automation
### Momus AI PR Review (`.github/workflows/momus.yml`)
Momus provides automated, noise-filtered AI code reviews on pull requests using `~anthropic/claude-sonnet-latest` via `https://openrouter.ai/api/v1`.

- **Required Secret**:
  - `LLM_API_KEY`: Your OpenRouter (or provider-specific) API key.
  - You can configure this either as:
    - A **Repository secret**: Go to **Settings > Secrets and variables > Actions > New repository secret**, or
    - An **Environment secret**: Go to **Settings > Environments > New environment**, create an environment named `code-review`, and add `LLM_API_KEY` under Environment secrets. The workflow uses `environment: code-review` and `secrets: inherit` by default.
- **Optional GitHub App Integration**:
  - If you wish Momus to post formal `APPROVE` reviews rather than `COMMENT`, configure:
    - `MOMUS_APP_ID`: Your GitHub App ID.
    - `MOMUS_APP_PRIVATE_KEY`: Your GitHub App PEM private key.
- **Triggering Reviews & Security Gating**:
  - Reviews are securely gated to repository maintainers and collaborators (`OWNER`, `MEMBER`, `COLLABORATOR`).
  - PRs from maintainers are reviewed automatically when opened.
  - PRs from external forks are not reviewed automatically on open to protect secrets; maintainers trigger a review by commenting `/ai-review` on the PR.
  - Re-trigger reviews at any time by commenting `/ai-review` or `@axiomantic-momus[bot]`.

---

## 4. Architectural Toolchain Details
### Nim Core Library
- **Core Library Source**: `src/lockfreequeues.nim`
- **Nimble Package Definition**: `lockfreequeues.nimble`
- **Tests**: `tests/` (run via `just test` or `nimble test`)

---

## 5. Local Overrides (`justfile.local`)

To declare project-specific or developer-local `just` recipes without colliding with upstream template updates, create a `justfile.local` in the project root:

```just
# justfile.local
my-custom-task:
    @echo "Running custom local task..."
```

`justfile.local` is automatically ignored by `.gitignore` and imported by `justfile`.

---

## 6. Upstream Template Updates

Polyform supports continuous upstream template synchronization via Copier:

```bash
# Pull upstream template improvements and workflow updates
just update-template
```

Answers are tracked in `.copier-answers.yml`. Domain code is never overwritten.
