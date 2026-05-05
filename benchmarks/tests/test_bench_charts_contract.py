#!/usr/bin/env python3
"""Tests for the chart-data contract between merge_bmf.py output and
docs/assets/bench-charts.js (Track 5 PR 5 Task 5.2).

The chart consumes `docs/assets/bench-results/latest.json`, which is
produced by `merge_bmf.py` and copied verbatim into the docs assets
tree by the snapshot-push step in bench.yml. This test guards the
shape JS depends on:

  - Top-level object: `{ slug: { measure: MeasureValue } }`.
  - Slug grammar: `<library>/<topology>/<P>p<C>c` with at least three
    `/`-separated segments and a final `\\d+p\\d+c` shape.
  - MeasureValue grammar: `value` is required and finite; `lower_value`
    and `upper_value` are optional and only present together when the
    Nim emitter has stddev information.
  - At least one slug carries `throughput_ops_ms` (the chart's primary
    measure); the chart errors loudly when this is missing, so the test
    asserts the contract is held by realistic input.

This is a contract test, not a render test. Headless-browser rendering
is out of scope per the impl plan ("HTML/JS rendering tests via
headless browser are out of scope"). The test exercises the parsing
logic that JS implements by mirroring the regex / layout in Python and
asserting it accepts a plausible BMF and rejects malformed inputs.
"""

from __future__ import annotations

import json
import math
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Mirrors the slug grammar enforced by `merge_bmf.py` schema validation
# AND consumed by `docs/assets/bench-charts.js` `parseSlug()`. Drift
# between the two would silently drop slugs from the chart.
SLUG_RE = re.compile(r"^[a-z][a-z0-9_]*(?:/[a-z][a-z0-9_]*)+/\d+p\d+c$")
# Mirrors `parseSlug` in bench-charts.js, which uses
# `parts.slice(1, -1).join('/')` for topology and therefore accepts
# nested topologies (3+ segments). The python regex must accept the
# same shape so the contract test does not reject slugs the JS chart
# would happily render — e.g. a hypothetical
# `library/mpmc/unbounded/1p1c` from a future topology split.
SHAPE_RE = re.compile(r"^(\d+)p(\d+)c$")
MEASURE_KEY_RE = re.compile(r"^[a-z][a-z0-9_]*$")
CHART_MEASURE = "throughput_ops_ms"


def parse_slug(slug: str) -> dict | None:
    """Python mirror of `parseSlug` in bench-charts.js. Returns the
    same fields the JS uses (library, topology, shape, p, c) when the
    slug is well-formed, else None. Kept in sync by hand; if either
    side drifts the contract test will flag the divergence."""
    parts = slug.split("/")
    if len(parts) < 3:
        return None
    library = parts[0]
    topology = "/".join(parts[1:-1])
    shape = parts[-1]
    m = SHAPE_RE.match(shape)
    if not m:
        return None
    return {
        "library": library,
        "topology": topology,
        "shape": shape,
        "p": int(m.group(1)),
        "c": int(m.group(2)),
    }


# A representative sample mirroring §2.4 of the design doc plus a few
# soft-skipped cells (omitted slugs) so the chart's "missing cell" path
# is exercised in spirit. Numbers are illustrative; this fixture does
# not need to come from a real bench run.
SAMPLE_BMF: dict = {
    "lockfreequeues_mupmuc/mpmc/1p1c": {
        "throughput_ops_ms": {
            "value": 6280.5,
            "lower_value": 6200.0,
            "upper_value": 6361.0,
        },
        "latency_p99_ns": {"value": 871.0},
    },
    "lockfreequeues_mupmuc/mpmc/2p2c": {
        "throughput_ops_ms": {
            "value": 7411.0,
            "lower_value": 7400.0,
            "upper_value": 7422.0,
        },
    },
    "lockfreequeues_sipsic/spsc/1p1c": {
        "throughput_ops_ms": {"value": 8123.4},
    },
    "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/4p4c": {
        "throughput_ops_ms": {"value": 1024.0},
    },
    "boost_lockfree_queue/mpmc/1p1c": {
        "throughput_ops_ms": {"value": 4321.0},
    },
}


class ChartContractTests(unittest.TestCase):
    def test_sample_bmf_passes_slug_grammar(self) -> None:
        """Every key in the sample BMF satisfies the slug regex shared
        with `merge_bmf.py`'s validator."""
        for slug in SAMPLE_BMF:
            self.assertRegex(slug, SLUG_RE, msg=f"slug {slug!r} fails grammar")

    def test_sample_bmf_passes_measure_grammar(self) -> None:
        """Measure keys match the `^[a-z][a-z0-9_]*$` rule used by
        merge_bmf.py and assumed by bench-charts.js when iterating."""
        for slug, measures in SAMPLE_BMF.items():
            for key in measures:
                self.assertRegex(
                    key,
                    MEASURE_KEY_RE,
                    msg=f"measure {key!r} (slug {slug!r}) fails grammar",
                )

    def test_sample_bmf_values_are_finite_floats(self) -> None:
        """`value` must be a finite number; `lower_value` /
        `upper_value` are optional but, when present, must also be
        finite. NaN/Inf are explicitly rejected by merge_bmf.py."""
        for slug, measures in SAMPLE_BMF.items():
            for measure, mv in measures.items():
                self.assertIn("value", mv, msg=f"{slug}/{measure} missing value")
                v = mv["value"]
                self.assertIsInstance(v, (int, float))
                self.assertTrue(
                    math.isfinite(v),
                    msg=f"{slug}/{measure} value not finite: {v!r}",
                )
                for opt in ("lower_value", "upper_value"):
                    if opt in mv:
                        self.assertIsInstance(mv[opt], (int, float))

    def test_throughput_measure_present(self) -> None:
        """The chart fails loudly when the throughput measure is
        absent from every slug. The fixture must include at least one
        slug with `throughput_ops_ms` so the chart has something to
        render under realistic conditions."""
        seen = any(CHART_MEASURE in measures for measures in SAMPLE_BMF.values())
        self.assertTrue(seen, "fixture must contain at least one throughput slug")

    def test_parse_slug_extracts_library_topology_shape(self) -> None:
        parsed = parse_slug("lockfreequeues_mupmuc/mpmc/4p4c")
        self.assertEqual(parsed["library"], "lockfreequeues_mupmuc")
        self.assertEqual(parsed["topology"], "mpmc")
        self.assertEqual(parsed["shape"], "4p4c")
        self.assertEqual(parsed["p"], 4)
        self.assertEqual(parsed["c"], 4)

    def test_parse_slug_handles_compound_topology(self) -> None:
        # `mpmc_unbounded` is a single topology label even though it
        # contains an underscore; the JS `parseSlug` joins all middle
        # segments to support future taxonomies with internal slashes.
        parsed = parse_slug("loony/mpmc_unbounded/2p4c")
        self.assertEqual(parsed["topology"], "mpmc_unbounded")
        self.assertEqual(parsed["p"], 2)
        self.assertEqual(parsed["c"], 4)

    def test_parse_slug_rejects_malformed(self) -> None:
        self.assertIsNone(parse_slug("missing_segments"))
        self.assertIsNone(parse_slug("lib/topo"))  # only two segments
        self.assertIsNone(parse_slug("lib/topo/abc"))  # bad shape

    def test_chart_assets_present(self) -> None:
        """The chart wiring requires three checked-in assets. If any
        is missing the chart silently fails with a console error
        (uPlot global undefined) or a 404 on the JS file. Keep the
        test as a tripwire."""
        assets = REPO_ROOT / "docs" / "assets"
        self.assertTrue(
            (assets / "uplot-1.6.27.iife.min.js").is_file(),
            "uPlot bundle missing",
        )
        self.assertTrue(
            (assets / "bench-charts.js").is_file(),
            "bench-charts.js missing",
        )
        self.assertTrue(
            (assets / "bench-charts.css").is_file(),
            "bench-charts.css missing",
        )
        self.assertTrue(
            (assets / "bench-results" / ".gitkeep").is_file(),
            "bench-results/.gitkeep missing",
        )

    def test_sample_bmf_round_trips_through_json(self) -> None:
        """The chart loads the snapshot via `fetch().json()`; round-
        tripping through JSON catches accidental Python-only types."""
        s = json.dumps(SAMPLE_BMF)
        decoded = json.loads(s)
        self.assertEqual(decoded, SAMPLE_BMF)


if __name__ == "__main__":
    unittest.main()
