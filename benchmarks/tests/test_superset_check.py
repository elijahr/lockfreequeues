#!/usr/bin/env python3
"""Tests for benchmarks/scripts/superset_check.py.

Covers the deletion-safety contract from PR 2 Task 2.7:

  - exit 0 when post-split slug set is a superset of pre-split.
  - exit 1 when one or more pre-split slugs are missing from post; stderr
    names every missing slug.
  - exit 1 on usage or IO error; stderr names the failure mode.

Run via: python3 benchmarks/tests/test_superset_check.py
or:      python3 -m unittest discover -s benchmarks/tests
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "benchmarks" / "scripts" / "superset_check.py"


def run_check(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def write_json(path: Path, payload: object) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


class SupersetCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    # 1. Identical slug sets -> exit 0.
    def test_identical_slugs_exit_0(self) -> None:
        pre = self.dir / "pre.json"
        post = self.dir / "post.json"
        slugs = {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 1000.0},
            },
            "lockfreequeues_mupmuc/mpmc/4p4c": {
                "throughput_ops_ms": {"value": 800.0},
            },
        }
        write_json(pre, slugs)
        write_json(post, slugs)
        result = run_check(str(pre), str(post))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    # 2. Strict superset (post has extra slugs) -> exit 0.
    def test_post_strict_superset_exit_0(self) -> None:
        pre = self.dir / "pre.json"
        post = self.dir / "post.json"
        write_json(pre, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 1000.0},
            },
        })
        write_json(post, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 1100.0},
            },
            "lockfreequeues_mupmuc/mpmc/2p2c": {
                "throughput_ops_ms": {"value": 800.0},
            },
            "lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c": {
                "throughput_ops_ms": {"value": 600.0},
            },
        })
        result = run_check(str(pre), str(post))
        self.assertEqual(result.returncode, 0, result.stderr)

    # 3. Pre has slugs missing from post -> exit 1, stderr names them.
    def test_missing_slug_exit_1(self) -> None:
        pre = self.dir / "pre.json"
        post = self.dir / "post.json"
        write_json(pre, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 1000.0},
            },
            "lockfreequeues_mupmuc/mpmc/8p8c": {
                "throughput_ops_ms": {"value": 200.0},
            },
            "nim_channels/mpmc/4p4c": {
                "throughput_ops_ms": {"value": 100.0},
            },
        })
        # post is missing the 8p8c oversubscription slug AND the
        # nim_channels 4p4c slug — both should appear in stderr.
        write_json(post, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 1100.0},
            },
        })
        result = run_check(str(pre), str(post))
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing", result.stderr.lower())
        # Both missing slugs must surface so the failure is actionable.
        self.assertIn("lockfreequeues_mupmuc/mpmc/8p8c", result.stderr)
        self.assertIn("nim_channels/mpmc/4p4c", result.stderr)
        # Slugs should appear in alphabetical order.
        idx_mupmuc = result.stderr.find("lockfreequeues_mupmuc/mpmc/8p8c")
        idx_channels = result.stderr.find("nim_channels/mpmc/4p4c")
        self.assertGreaterEqual(idx_mupmuc, 0)
        self.assertGreaterEqual(idx_channels, 0)
        self.assertLess(idx_mupmuc, idx_channels)

    # 4. Empty pre is trivially a subset of anything -> exit 0.
    def test_empty_pre_exit_0(self) -> None:
        pre = self.dir / "pre.json"
        post = self.dir / "post.json"
        write_json(pre, {})
        write_json(post, {
            "lockfreequeues_sipsic/spsc/1p1c": {
                "throughput_ops_ms": {"value": 1000.0},
            },
        })
        result = run_check(str(pre), str(post))
        self.assertEqual(result.returncode, 0)

    # 5. Wrong arg count -> exit 1 with usage line.
    def test_no_args_exit_1(self) -> None:
        result = run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage", result.stderr.lower())

    def test_one_arg_exit_1(self) -> None:
        pre = self.dir / "pre.json"
        write_json(pre, {})
        result = run_check(str(pre))
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage", result.stderr.lower())

    # 6. Missing pre file -> exit 1 with file-name in stderr.
    def test_missing_pre_file_exit_1(self) -> None:
        post = self.dir / "post.json"
        write_json(post, {})
        result = run_check(str(self.dir / "does_not_exist.json"), str(post))
        self.assertEqual(result.returncode, 1)
        self.assertIn("does_not_exist.json", result.stderr)

    # 7. Malformed JSON -> exit 1 with file-name in stderr.
    def test_malformed_json_exit_1(self) -> None:
        pre = self.dir / "pre.json"
        post = self.dir / "post.json"
        pre.write_text("not json at all", encoding="utf-8")
        write_json(post, {})
        result = run_check(str(pre), str(post))
        self.assertEqual(result.returncode, 1)
        self.assertIn("malformed", result.stderr.lower())

    # 8. Top-level not an object -> exit 1.
    def test_top_level_array_exit_1(self) -> None:
        pre = self.dir / "pre.json"
        post = self.dir / "post.json"
        write_json(pre, ["a", "b"])
        write_json(post, {})
        result = run_check(str(pre), str(post))
        self.assertEqual(result.returncode, 1)
        self.assertIn("object", result.stderr.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
