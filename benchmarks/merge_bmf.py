#!/usr/bin/env python3
"""Merge multiple BMF JSON files into one before `bencher run` upload.

Bencher.dev creates a separate Report per `bencher run` invocation; multiple
uploads from sibling CI jobs (bench-throughput / bench-latency / topology
splits) would NOT co-locate measures on a single per-slug history. This
utility unions the per-slug measure dicts from N input BMF JSONs into one
output BMF JSON, validates the schema, and guards against collisions.

Contract (design doc section 4.3):
    merge_bmf.py <output_path> <input1> [input2 ...]

- N >= 1; zero inputs -> exit 1 with usage error.
- Inputs MUST parse as ``dict[str, dict[str, dict]]``. Slug keys match
  ``^[a-z][a-z0-9_]*/[a-z][a-z0-9_]*/\\d+p\\d+c$``. Measure keys match
  ``^[a-z][a-z0-9_]*$``. ``value`` fields MUST be finite, non-NaN floats.
  Bound fields ``lower_value`` / ``upper_value`` (when present) are
  validated the same way.
- Collision: same ``(slug, measure)`` pair across two inputs -> exit 1
  with ``error: collision on slug=<slug> measure=<measure> in files
  <pathA> and <pathB>`` to stderr.
- Output: single JSON file at ``<output_path>``, slugs alpha-sorted at
  the top level and measures alpha-sorted within each slug, indented 2
  spaces (human-readable diffs).

Schema-validation failures and collisions both exit 1; usage errors
exit 1 (NOT 2) to stay consistent with the design doc's exit-code
contract.
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from typing import Mapping, Tuple

SLUG_RE = re.compile(r"^[a-z][a-z0-9_]*/[a-z][a-z0-9_]*/\d+p\d+c$")
MEASURE_RE = re.compile(r"^[a-z][a-z0-9_]*$")
ALLOWED_FIELDS = frozenset({"value", "lower_value", "upper_value"})


def _die(msg: str) -> "int":
    """Print to stderr and return exit code 1."""
    print(msg, file=sys.stderr)
    return 1


def _validate_value_dict(
    slug: str, measure: str, mv: object, source: str
) -> str | None:
    """Return None on success, error string on failure."""
    if not isinstance(mv, dict):
        return (
            f"error: value for slug={slug} measure={measure} in {source} "
            f"must be an object; got {type(mv).__name__}"
        )
    if "value" not in mv:
        return (
            f"error: value for slug={slug} measure={measure} in {source} "
            f"missing required 'value' field"
        )
    for field, val in mv.items():
        if field not in ALLOWED_FIELDS:
            return (
                f"error: unexpected field '{field}' on slug={slug} "
                f"measure={measure} in {source}"
            )
        if not isinstance(val, (int, float)) or isinstance(val, bool):
            return (
                f"error: field '{field}' on slug={slug} measure={measure} "
                f"in {source} must be a number; got {type(val).__name__}"
            )
        if not math.isfinite(float(val)):
            return (
                f"error: non-finite (NaN or inf) value on slug={slug} "
                f"measure={measure} field={field} in {source}"
            )
    return None


def _validate_keys(
    obj: Mapping[str, object], source: str
) -> str | None:
    """Walk a parsed BMF JSON; return error string or None."""
    for slug, inner in obj.items():
        if not isinstance(slug, str) or not SLUG_RE.match(slug):
            return (
                f"error: invalid slug shape '{slug}' in {source} "
                f"(expected '<lib>/<topology>/<P>p<C>c')"
            )
        if not isinstance(inner, dict):
            return (
                f"error: slug={slug} in {source} must map to an object; "
                f"got {type(inner).__name__}"
            )
        for measure, mv in inner.items():
            if not isinstance(measure, str) or not MEASURE_RE.match(measure):
                return (
                    f"error: invalid measure key '{measure}' on slug={slug} "
                    f"in {source} (must match ^[a-z][a-z0-9_]*$)"
                )
            err = _validate_value_dict(slug, measure, mv, source)
            if err is not None:
                return err
    return None


def _read_bmf(path: Path) -> Tuple[dict[str, dict[str, dict[str, float]]], str | None]:
    """Read + parse a BMF JSON file. Returns (parsed_dict, error_string)."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return {}, f"error: cannot read {path}: {exc}"
    try:
        # allow_nan accepts NaN/Infinity tokens during parse so that the
        # downstream isfinite check (in _validate_value_dict) names the
        # failure mode precisely rather than failing at parse time with a
        # generic JSON error.
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        return {}, f"error: malformed JSON in {path}: {exc}"
    if not isinstance(parsed, dict):
        return {}, f"error: top-level value in {path} must be a JSON object"
    err = _validate_keys(parsed, str(path))
    if err is not None:
        return {}, err
    return parsed, None


def merge(
    inputs: list[Path],
) -> Tuple[dict[str, dict[str, dict[str, float]]], str | None]:
    """Stateless union of per-slug measure dicts. Returns
    (merged_dict, error_string). Error_string is non-None iff a
    collision was detected or any input failed validation."""
    merged: dict[str, dict[str, dict[str, float]]] = {}
    # Track which input file first introduced each (slug, measure) pair so
    # collision errors can name both files.
    origin: dict[Tuple[str, str], str] = {}
    for path in inputs:
        parsed, err = _read_bmf(path)
        if err is not None:
            return {}, err
        for slug, inner in parsed.items():
            slug_bucket = merged.setdefault(slug, {})
            for measure, mv in inner.items():
                key = (slug, measure)
                if key in origin:
                    return {}, (
                        f"error: collision on slug={slug} measure={measure} "
                        f"in files {origin[key]} and {path}"
                    )
                origin[key] = str(path)
                slug_bucket[measure] = mv
    return merged, None


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        return _die(
            "usage: merge_bmf.py <output_path> <input1> [input2 ...]"
        )
    output_path = Path(argv[1])
    input_paths = [Path(p) for p in argv[2:]]
    merged, err = merge(input_paths)
    if err is not None:
        return _die(err)
    # sort_keys=True orders both top-level slugs AND nested measure keys
    # alphabetically; nested value-dicts ('value', 'lower_value',
    # 'upper_value') also get alpha order, which puts 'lower_value' before
    # 'upper_value' before 'value' — acceptable since downstream tools
    # parse by name, not position.
    output_path.write_text(
        json.dumps(merged, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
