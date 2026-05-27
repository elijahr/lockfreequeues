#!/usr/bin/env python3
"""Slug-set superset deletion-safety check (Track 2 PR 2 Task 2.7).

Verifies the post-split BMF (the union of `bench_spsc / bench_mpsc /
bench_mpmc_bounded / bench_spmc_bounded / bench_unbounded_spsc /
bench_unbounded_spmc / bench_unbounded_mpsc /
bench_unbounded_mpmc` outputs merged via `merge_bmf.py`) is a strict
superset of the pre-split BMF captured by Task 2.1 from the legacy
`bench_throughput` binary. v5.0.0 B3 split the `bench_mpmc` slot into
a per-family pair; v5.0.0 3.3.9-D fanned the `bench_unbounded` slot
into four per-family binaries. Each binary's slug subset is smaller;
the union is unchanged.

CONTRACT
    superset_check.py <pre.json> <post.json>

    Both arguments must be paths to JSON files emitted by the project's
    BMF emitter (`benchmarks/nim/bench_common.nim`). Top-level keys are
    slugs; values are dicts of measure names. Only the slug *keys* are
    compared by this check — measure values, bounds, and ordering are
    ignored. Slug-level deletion is what the topology split must avoid.

EXIT CODES
    0   set(pre) is a subset of set(post). Empty output on stdout.
    1   pre includes one or more slugs missing from post (deletion-
        safety failure). Stderr lists the missing slugs (one per line,
        alphabetically sorted) so CI log searches can grep them.
        Also returned for usage / IO errors (file missing, malformed
        JSON, top-level not an object) to match the exit-code contract
        used by `benchmarks/merge_bmf.py`. Stderr names the failure
        mode in either case.

DESIGN NOTE
    "Strict superset" in the impl plan means `set(pre) <= set(post)`
    AND no slug from pre is missing from post. This is identical to
    `set(pre) <= set(post)` for non-empty pre; we keep the
    `set.issubset` check explicit so the failure mode (which slugs
    are missing) can be enumerated for the operator.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def _die_usage(msg: str) -> int:
    print(f"error: {msg}", file=sys.stderr)
    print(
        "usage: superset_check.py <pre.json> <post.json>",
        file=sys.stderr,
    )
    return 1


def _load_slugs(path: Path) -> set[str]:
    """Return the set of top-level slug keys in `path`. Raises ValueError
    on malformed JSON or non-object top-level values."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"malformed JSON in {path}: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ValueError(
            f"top-level value in {path} must be a JSON object; "
            f"got {type(parsed).__name__}"
        )
    return set(parsed.keys())


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        return _die_usage(
            f"expected 2 arguments (pre.json, post.json); got {len(argv) - 1}"
        )
    pre_path = Path(argv[1])
    post_path = Path(argv[2])
    try:
        pre_slugs = _load_slugs(pre_path)
        post_slugs = _load_slugs(post_path)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    missing = pre_slugs - post_slugs
    if not missing:
        return 0

    # Failure mode: enumerate every missing slug so the operator can
    # see exactly which split-binary lost coverage. Sort for stable
    # diff output across runs.
    print(
        f"error: post-split BMF is missing {len(missing)} slug(s) "
        f"from pre-split fixture {pre_path}:",
        file=sys.stderr,
    )
    for slug in sorted(missing):
        print(f"  missing: {slug}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
