#!/usr/bin/env python3
"""Tests for benchmarks/merge_bmf.py.

Covers the 8 cases from design doc section 4.3 plus minimal harness
plumbing. Run via: python3 benchmarks/tests/test_merge_bmf.py
or: python3 -m unittest discover -s benchmarks/tests
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "benchmarks" / "merge_bmf.py"


def run_merge(*args: str) -> subprocess.CompletedProcess[str]:
    """Invoke merge_bmf.py in a subprocess so exit code semantics
    (exit 0 / exit 1) are exercised the way CI invokes them."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def write_json(path: Path, payload: object) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


class MergeBmfTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.out = self.dir / "merged.json"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    # 1. Zero-input argv -> exit 1 with usage error.
    def test_zero_inputs_exits_1_with_usage(self) -> None:
        result = run_merge(str(self.out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage", result.stderr.lower())
        self.assertFalse(self.out.exists())

    # 2. Single empty {} input -> exit 0, output == {}.
    def test_single_empty_input_yields_empty_output(self) -> None:
        empty = self.dir / "empty.json"
        write_json(empty, {})
        result = run_merge(str(self.out), str(empty))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.out.read_text()), {})

    # 3. Single valid input -> identity copy after sort-key re-emission.
    def test_single_valid_input_round_trips(self) -> None:
        inp = self.dir / "throughput.json"
        payload = {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {
                    "value": 7411.0,
                    "lower_value": 7300.0,
                    "upper_value": 7522.0,
                },
            },
        }
        write_json(inp, payload)
        result = run_merge(str(self.out), str(inp))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.out.read_text()), payload)

    # 4. Two inputs with disjoint slugs -> output is union.
    def test_two_inputs_disjoint_slugs(self) -> None:
        a = self.dir / "a.json"
        b = self.dir / "b.json"
        write_json(a, {
            "loony/mpmc_unbounded/4p4c": {"throughput_ops_ms": {"value": 100.0}},
        })
        write_json(b, {
            "moodycamel/mpmc_unbounded/4p4c": {"throughput_ops_ms": {"value": 200.0}},
        })
        result = run_merge(str(self.out), str(a), str(b))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.out.read_text()),
            {
                "loony/mpmc_unbounded/4p4c": {
                    "throughput_ops_ms": {"value": 100.0},
                },
                "moodycamel/mpmc_unbounded/4p4c": {
                    "throughput_ops_ms": {"value": 200.0},
                },
            },
        )

    # 5. Two inputs share a slug, disjoint measures -> output combines them.
    def test_shared_slug_disjoint_measures(self) -> None:
        a = self.dir / "throughput.json"
        b = self.dir / "latency.json"
        write_json(a, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 7411.0},
            },
        })
        write_json(b, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "latency_p50_ns": {"value": 292.0},
                "latency_p99_ns": {"value": 480.0},
            },
        })
        result = run_merge(str(self.out), str(a), str(b))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.out.read_text()),
            {
                "lockfreequeues_sipsic/spsc/1p1c": {
                    "latency_p50_ns": {"value": 292.0},
                    "latency_p99_ns": {"value": 480.0},
                    "throughput_ops_ms": {"value": 7411.0},
                },
            },
        )

    # 6. Two inputs share slug + same measure -> exit 1, stderr names pair.
    def test_collision_exits_1(self) -> None:
        a = self.dir / "a.json"
        b = self.dir / "b.json"
        write_json(a, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 7411.0},
            },
        })
        write_json(b, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 9999.0},
            },
        })
        result = run_merge(str(self.out), str(a), str(b))
        self.assertEqual(result.returncode, 1)
        self.assertIn("collision", result.stderr.lower())
        self.assertIn("lockfreequeues_sipsic/spsc/1p1c", result.stderr)
        self.assertIn("throughput_ops_ms", result.stderr)

    # 7. Schema validation: NaN value -> exit 1.
    def test_nan_value_rejected(self) -> None:
        inp = self.dir / "nan.json"
        # JSON does not allow NaN; emit raw text and let merge_bmf parse
        # via json.loads with allow_nan default (True for parsing) but
        # subsequent isfinite check should reject it.
        inp.write_text(
            '{"foo/spsc/1p1c": {"throughput": {"value": NaN}}}',
            encoding="utf-8",
        )
        result = run_merge(str(self.out), str(inp))
        self.assertEqual(result.returncode, 1)
        # Stderr should mention NaN / non-finite.
        self.assertTrue(
            "nan" in result.stderr.lower() or "finite" in result.stderr.lower(),
            f"unexpected stderr: {result.stderr}",
        )

    # 8a. Schema validation: invalid measure key (uppercase).
    def test_invalid_measure_key_uppercase(self) -> None:
        inp = self.dir / "bad_measure.json"
        write_json(inp, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "Throughput": {"value": 7411.0},
            },
        })
        result = run_merge(str(self.out), str(inp))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Throughput", result.stderr)

    # 8b. Schema validation: invalid slug shape.
    def test_invalid_slug_shape(self) -> None:
        inp = self.dir / "bad_slug.json"
        write_json(inp, {
            "BadSlug": {"throughput": {"value": 100.0}},
        })
        result = run_merge(str(self.out), str(inp))
        self.assertEqual(result.returncode, 1)
        self.assertIn("BadSlug", result.stderr)

    # PR 2 Task 2.9: 5-input disjoint-slug union (one input per
    # topology-split binary). Validates that the upload-job pipeline
    # the topology split assumes — five sibling BMF fragments arriving
    # via `actions/download-artifact` and going through merge_bmf.py
    # before the single `bencher run` upload — produces a single merged
    # output whose slug set is the disjoint union of the five inputs.
    def test_five_input_union(self) -> None:
        """5-input disjoint-slug union (one slug per binary)."""
        spsc = self.dir / "bench_spsc.json"
        mpsc = self.dir / "bench_mpsc.json"
        mpmc = self.dir / "bench_mpmc.json"
        unbounded = self.dir / "bench_unbounded.json"
        latency = self.dir / "bench_latency.json"

        write_json(spsc, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 7000.0},
            },
        })
        write_json(mpsc, {
            "lockfreequeues_mupsic/mpsc/4p1c": {
                "throughput_ops_ms": {"value": 6000.0},
            },
        })
        write_json(mpmc, {
            "lockfreequeues_mupmuc/mpmc/4p4c": {
                "throughput_ops_ms": {"value": 5000.0},
            },
        })
        write_json(unbounded, {
            "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/4p4c": {
                "throughput_ops_ms": {"value": 4000.0},
            },
        })
        # bench_latency emits latency_p50_ns / latency_p95_ns /
        # latency_p99_ns per design 2.3; this test pins to a
        # representative sipsic 1p1c slug. Note the slug intentionally
        # collides with the bench_spsc slug above ON THE SLUG axis but
        # the *measure* keys are disjoint (latency_* vs throughput_*),
        # which is the same shape the production pipeline ships
        # (Track 1 Task 1.5).
        write_json(latency, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "latency_p50_ns": {"value": 250.0},
                "latency_p99_ns": {"value": 800.0},
            },
        })

        result = run_merge(
            str(self.out),
            str(spsc), str(mpsc), str(mpmc),
            str(unbounded), str(latency),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        merged = json.loads(self.out.read_text())
        # 4 distinct slugs (bench_latency shares the sipsic 1p1c slug
        # with bench_spsc) plus the 3 unique slugs from mpsc, mpmc,
        # and unbounded = 4 top-level keys.
        self.assertEqual(set(merged.keys()), {
            "lockfreequeues_sipsic/spsc/1p1c",
            "lockfreequeues_mupsic/mpsc/4p1c",
            "lockfreequeues_mupmuc/mpmc/4p4c",
            "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/4p4c",
        })
        # Shared sipsic slug carries BOTH throughput_ops_ms (from
        # bench_spsc) and latency_p50_ns / latency_p99_ns (from
        # bench_latency); the cross-binary merge must preserve every
        # measure on the shared slug.
        sipsic = merged["lockfreequeues_sipsic/spsc/1p1c"]
        self.assertEqual(sipsic["throughput_ops_ms"]["value"], 7000.0)
        self.assertEqual(sipsic["latency_p50_ns"]["value"], 250.0)
        self.assertEqual(sipsic["latency_p99_ns"]["value"], 800.0)
        # The other three slugs each carry only their own measure.
        self.assertEqual(
            merged["lockfreequeues_mupsic/mpsc/4p1c"]
                  ["throughput_ops_ms"]["value"], 6000.0)
        self.assertEqual(
            merged["lockfreequeues_mupmuc/mpmc/4p4c"]
                  ["throughput_ops_ms"]["value"], 5000.0)
        self.assertEqual(
            merged["lockfreequeues_unbounded_mupmuc/mpmc_unbounded/4p4c"]
                  ["throughput_ops_ms"]["value"], 4000.0)

    def test_output_is_alpha_sorted(self) -> None:
        """Slugs and measures both emerge alpha-sorted regardless of input order."""
        inp = self.dir / "shuffled.json"
        write_json(inp, {
            "zzz_lib/spsc/1p1c": {
                "throughput_ops_ms": {"value": 1.0},
                "latency_p50_ns": {"value": 5.0},
            },
            "aaa_lib/spsc/1p1c": {"throughput_ops_ms": {"value": 2.0}},
        })
        result = run_merge(str(self.out), str(inp))
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = self.out.read_text()
        # Top-level slug ordering: aaa_lib before zzz_lib in serialized text.
        self.assertLess(raw.find("aaa_lib"), raw.find("zzz_lib"))
        # Measure ordering within zzz_lib's block: scan from zzz_lib forward
        # and assert latency_p50_ns appears before throughput_ops_ms.
        zzz_start = raw.find("zzz_lib")
        zzz_section = raw[zzz_start:]
        self.assertGreaterEqual(zzz_section.find("latency_p50_ns"), 0)
        self.assertLess(
            zzz_section.find("latency_p50_ns"),
            zzz_section.find("throughput_ops_ms"),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
