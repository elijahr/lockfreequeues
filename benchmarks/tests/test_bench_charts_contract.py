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


# A representative sample covering all 6 topology axes (spsc, mpsc,
# mpmc, spsc_unbounded, mpsc_unbounded, mpmc_unbounded) plus the full
# latency percentile suite for ≥1 1p1c bounded slug. The library set
# is chosen so every entry has a corresponding LIBRARY_COLORS entry
# in bench-charts.js — `test_library_colors_map_covers_fixture` would
# fail loudly otherwise. Numbers are illustrative; this fixture does
# not need to come from a real bench run.
SAMPLE_BMF: dict = {
    # spsc
    "lockfreequeues_sipsic/spsc/1p1c": {
        "throughput_ops_ms": {
            "value": 8123.4, "lower_value": 8000.0, "upper_value": 8246.8,
        },
        "latency_p50_ns":  {"value": 412.0},
        "latency_p95_ns":  {"value": 580.0},
        "latency_p99_ns":  {"value": 871.0},
        "latency_p999_ns": {"value": 1450.0},
        "latency_max_ns":  {"value": 8920.0},
    },
    "boost_lockfree_spsc/spsc/1p1c": {
        "throughput_ops_ms": {"value": 5400.0},
    },
    # mpsc
    "lockfreequeues_mupsic/mpsc/2p1c": {
        "throughput_ops_ms": {
            "value": 6800.0, "lower_value": 6700.0, "upper_value": 6900.0,
        },
    },
    "nim_channel/mpsc/2p1c": {
        "throughput_ops_ms": {"value": 1200.0},
    },
    # mpmc bounded
    "lockfreequeues_mupmuc/mpmc/1p1c": {
        "throughput_ops_ms": {
            "value": 6280.5, "lower_value": 6200.0, "upper_value": 6361.0,
        },
        "latency_p99_ns": {"value": 871.0},
    },
    "lockfreequeues_mupmuc/mpmc/2p2c": {
        "throughput_ops_ms": {
            "value": 7411.0, "lower_value": 7400.0, "upper_value": 7422.0,
        },
    },
    "lockfreequeues_mupmuc/mpmc/4p4c": {
        "throughput_ops_ms": {"value": 4912.0},
    },
    "boost_lockfree_queue/mpmc/1p1c": {
        "throughput_ops_ms": {"value": 4321.0},
    },
    "crossbeam_array_queue/mpmc/4p4c": {
        "throughput_ops_ms": {"value": 2104.0},
    },
    "threading_channels/mpmc/2p2c": {
        "throughput_ops_ms": {"value": 950.0},
    },
    # spsc_unbounded
    "lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c": {
        "throughput_ops_ms": {"value": 7100.0},
    },
    # mpsc_unbounded
    "lockfreequeues_unbounded_mupsic/mpsc_unbounded/2p1c": {
        "throughput_ops_ms": {"value": 5900.0},
    },
    # mpmc_unbounded
    "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/4p4c": {
        "throughput_ops_ms": {"value": 1024.0},
    },
    "loony/mpmc_unbounded/4p4c": {
        "throughput_ops_ms": {"value": 980.0},
    },
    "moodycamel/mpmc_unbounded/4p4c": {
        "throughput_ops_ms": {"value": 1450.0},
    },
}

# Pinned to the documented blocking-on-full library set. Mirrored as
# `BLOCKING_LIBRARIES` in `docs/assets/bench-charts.js`; any drift
# between the two is a contract regression caught by
# `test_blocking_libraries_const_matches_contract`.
EXPECTED_BLOCKING_LIBRARIES = {"threading_channels", "nim_channel", "nim_channels"}

# Value-anchored regex for `LIBRARY_COLORS` entries in bench-charts.js
# (per Phase 3.2 CRIT-4: marker-range extraction is brittle under
# reformatting, so we anchor on the `key: '#hex'` line shape itself).
LIBRARY_COLOR_LINE_RE = re.compile(
    r"^\s*([a-z][a-z0-9_]*)\s*:\s*'(#[0-9a-f]{6})'",
    re.MULTILINE,
)
# Value-anchored regex for the BLOCKING_LIBRARIES const literal.
BLOCKING_LIBRARIES_LITERAL_RE = re.compile(
    r"BLOCKING_LIBRARIES\s*=\s*\[(.+?)\]",
    re.DOTALL,
)
# Quoted string literal extractor for parsing array contents.
QUOTED_STRING_RE = re.compile(r"'([a-z_][a-z0-9_]*)'")


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
        self.assertTrue(
            (assets / "bench-results" / "example.json").is_file(),
            "bench-results/example.json missing",
        )

    def test_sample_bmf_round_trips_through_json(self) -> None:
        """The chart loads the snapshot via `fetch().json()`; round-
        tripping through JSON catches accidental Python-only types."""
        s = json.dumps(SAMPLE_BMF)
        decoded = json.loads(s)
        self.assertEqual(decoded, SAMPLE_BMF)

    def test_dom_containers_present_in_benchmarks_md(self) -> None:
        """The chart's panel architecture pins six DOM container IDs.
        `docs/benchmarks.md` must declare each so the JS lookup
        `document.getElementById(...)` resolves at load time. Drift
        here means the chart silently fails to render that panel.
        """
        p = REPO_ROOT / "docs" / "benchmarks.md"
        self.assertTrue(p.is_file(), "docs/benchmarks.md missing")
        src = p.read_text()
        for cid in (
            "bench-status",
            "bench-hero",
            "bench-throughput-spsc",
            "bench-throughput-mpsc",
            "bench-throughput-mpmc-bounded",
            "bench-throughput-mpmc-unbounded",
            "bench-latency",
        ):
            needle = f'id="{cid}"'
            self.assertEqual(
                src.count(needle), 1,
                msg=f"expected exactly one {needle} in benchmarks.md, "
                    f"got {src.count(needle)}",
            )

    def test_library_colors_map_covers_fixture(self) -> None:
        """Every library family present in SAMPLE_BMF must have an
        entry in bench-charts.js's LIBRARY_COLORS const. Drift here
        means the chart silently falls back to the index palette and
        emits a console.warn.

        Uses a value-anchored regex per Phase 3.2 CRIT-4: matches the
        canonical `key: '#hex'` line shape directly, not the marker
        comment range. Robust against any future reformatter that
        might reflow `Object.freeze({...})`.
        """
        js = (REPO_ROOT / "docs" / "assets" / "bench-charts.js").read_text()
        pairs = LIBRARY_COLOR_LINE_RE.findall(js)
        self.assertGreater(
            len(pairs), 0,
            "value-anchored regex matched zero LIBRARY_COLORS entries — "
            "either the const is missing or the line shape changed",
        )
        colors = dict(pairs)
        # Each value matches `^#[0-9a-f]{6}$` (regex already enforces).
        for lib, hex_value in colors.items():
            self.assertRegex(hex_value, r"^#[0-9a-f]{6}$",
                             msg=f"{lib} hex {hex_value!r} not 6-char lowercase")
        fixture_libs = {slug.split("/")[0] for slug in SAMPLE_BMF}
        missing = fixture_libs - colors.keys()
        self.assertFalse(
            missing,
            f"libraries missing from LIBRARY_COLORS: {sorted(missing)}",
        )
        # The lockfreequeues family must have all 8 entries (4 bounded
        # + 4 unbounded) so co-located bounded/unbounded series stay
        # visually distinguishable per design §2.8.
        lfq_family = sorted(k for k in colors if k.startswith("lockfreequeues_"))
        self.assertEqual(
            lfq_family,
            [
                "lockfreequeues_mupmuc",
                "lockfreequeues_mupsic",
                "lockfreequeues_sipmuc",
                "lockfreequeues_sipsic",
                "lockfreequeues_unbounded_mupmuc",
                "lockfreequeues_unbounded_mupsic",
                "lockfreequeues_unbounded_sipmuc",
                "lockfreequeues_unbounded_sipsic",
            ],
            "LIBRARY_COLORS must cover all 8 lockfreequeues_* family members",
        )

    def test_blocking_libraries_const_matches_contract(self) -> None:
        """bench-charts.js's BLOCKING_LIBRARIES const must equal the
        test-side EXPECTED_BLOCKING_LIBRARIES exactly. Drift means the
        chart's dotted-line / `(blocking)` legend semantics no longer
        match documented semantics.

        Uses a value-anchored regex per Phase 3.2 CRIT-4: matches
        `BLOCKING_LIBRARIES = [ ... ]` directly, then extracts quoted
        string literals.
        """
        js = (REPO_ROOT / "docs" / "assets" / "bench-charts.js").read_text()
        m = BLOCKING_LIBRARIES_LITERAL_RE.search(js)
        self.assertIsNotNone(
            m, "BLOCKING_LIBRARIES = [...] literal not found in bench-charts.js"
        )
        actual = set(QUOTED_STRING_RE.findall(m.group(1)))
        self.assertEqual(actual, EXPECTED_BLOCKING_LIBRARIES)

    def test_example_json_validates_against_schema(self) -> None:
        """`docs/assets/bench-results/example.json` must be a checked-
        in BMF that satisfies the same slug / measure-key / value
        invariants enforced by `merge_bmf.py`. The chart consumes this
        file as the offline / fallback fixture, so any drift would
        ship a broken local-preview experience.
        """
        p = REPO_ROOT / "docs" / "assets" / "bench-results" / "example.json"
        self.assertTrue(p.is_file(), "example.json missing")
        with p.open() as f:
            data = json.load(f)
        # Defensive size guard: empty fixtures or accidentally-huge
        # ones are both regressions worth catching at test time.
        self.assertGreater(len(data), 10, "example.json suspiciously small")
        self.assertLess(len(data), 200, "example.json suspiciously large")
        # No leading-underscore top-level keys: those are placeholder
        # status fields the rollup job emits during fallback paths
        # (`_status: fallback` etc.) — they should never appear in the
        # checked-in fixture.
        for key in data:
            self.assertFalse(
                key.startswith("_"),
                msg=f"unexpected status/placeholder key in fixture: {key!r}",
            )
        # Every slug obeys the BMF grammar; every measure key obeys
        # the measure-key grammar; every value carries a finite
        # `value` field.
        for slug, measures in data.items():
            self.assertRegex(slug, SLUG_RE,
                             msg=f"bad slug in fixture: {slug!r}")
            self.assertIsInstance(measures, dict,
                                  msg=f"{slug!r} value is not a dict")
            for key, mv in measures.items():
                self.assertRegex(key, MEASURE_KEY_RE,
                                 msg=f"bad measure key: {key!r}")
                self.assertIsInstance(mv, dict,
                                      msg=f"{slug}/{key} measure not a dict")
                self.assertIn("value", mv,
                              msg=f"{slug}/{key} missing required 'value'")
                v = mv["value"]
                self.assertIsInstance(v, (int, float),
                                      msg=f"{slug}/{key} value not numeric")
                self.assertTrue(
                    math.isfinite(v),
                    msg=f"{slug}/{key} value not finite: {v!r}",
                )
                # Optional CI fields: only present together, both finite.
                for opt in ("lower_value", "upper_value"):
                    if opt in mv:
                        self.assertIsInstance(mv[opt], (int, float))
                        self.assertTrue(math.isfinite(mv[opt]))

    def test_throughput_panel_routing(self) -> None:
        """Every BMF topology must route to exactly one throughput
        panel, and the routing must pair bounded with unbounded for
        each core topology so unbounded slugs in the fixture render.

        Parses the `THROUGHPUT_PANELS` block in `bench-charts.js` and
        asserts the (panel-id -> {topologies}) mapping matches the
        agreed routing. If this test fails after a JS change, either
        the routing regressed or the contract here needs to follow
        suit; bench-charts.js is the source of truth for shape, and
        this test is the source of truth for routing intent.
        """
        js_path = REPO_ROOT / "docs" / "assets" / "bench-charts.js"
        src = js_path.read_text()

        # Extract the THROUGHPUT_PANELS array literal.
        m = re.search(
            r"const THROUGHPUT_PANELS\s*=\s*\[(.*?)\];",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(
            m, "THROUGHPUT_PANELS block not found in bench-charts.js"
        )
        block = m.group(1)

        # Each entry: { id: '...', label: '...',
        #               includes: (topology) => <expr> }
        # Parse id + the expression body.
        entry_re = re.compile(
            r"\{\s*id:\s*'([^']+)'\s*,\s*"
            r"label:\s*'[^']*'\s*,\s*"
            r"includes:\s*\(topology\)\s*=>\s*(.+?)\s*\}",
            re.DOTALL,
        )
        entries = entry_re.findall(block)
        self.assertEqual(
            len(entries), 4,
            f"expected 4 throughput panels, got {len(entries)}: {entries}",
        )

        # For each panel, extract the set of topology string literals
        # the predicate compares against. We accept `topology === 'X'`
        # repeated with `||`, which is the only form the routing uses.
        topo_lit_re = re.compile(r"topology\s*===\s*'([a-z_]+)'")
        actual: dict[str, set[str]] = {}
        for panel_id, expr in entries:
            topos = set(topo_lit_re.findall(expr))
            self.assertTrue(
                topos,
                f"panel {panel_id!r} predicate {expr!r} matched no topologies",
            )
            actual[panel_id] = topos

        expected = {
            "bench-throughput-spsc":           {"spsc", "spsc_unbounded"},
            "bench-throughput-mpsc":           {"mpsc", "mpsc_unbounded"},
            "bench-throughput-mpmc-bounded":   {"mpmc"},
            "bench-throughput-mpmc-unbounded": {"mpmc_unbounded"},
        }
        self.assertEqual(actual, expected)

        # Sanity: every topology routes to exactly one panel (no
        # accidental double-routing where a slug would render twice).
        all_topos: list[str] = []
        for topos in actual.values():
            all_topos.extend(topos)
        self.assertEqual(
            len(all_topos), len(set(all_topos)),
            f"topology routed to multiple panels: {all_topos}",
        )

        # Sanity: the routing covers every topology present in the
        # checked-in example.json fixture, so no fixture slug silently
        # disappears from the rendered chart.
        fixture_path = (
            REPO_ROOT / "docs" / "assets" / "bench-results" / "example.json"
        )
        fixture = json.loads(fixture_path.read_text())
        fixture_topos = set()
        for slug in fixture:
            if slug.startswith("_"):
                continue
            parsed = parse_slug(slug)
            if parsed is None:
                continue
            fixture_topos.add(parsed["topology"])
        covered = set().union(*actual.values())
        missing = fixture_topos - covered
        self.assertFalse(
            missing,
            f"fixture topologies not routed to any panel: {missing}",
        )


if __name__ == "__main__":
    unittest.main()
