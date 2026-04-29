"""Tests for the BMF adapter.

Each test asserts the FULL expected dict against parser output. No partial
assertions, no substring checks. Fixtures are real captures of
`bench_throughput` output (with both finite and non-finite values) so the
adapter is verified against the actual Nim formatter.

Run with stdlib unittest (no pytest dependency):

    python3 -m unittest benchmarks.test_bmf_adapter -v

or directly:

    python3 benchmarks/test_bmf_adapter.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ADAPTER = Path(__file__).parent / "bmf_adapter.py"


def _import_adapter():
    import importlib.util

    spec = importlib.util.spec_from_file_location("bmf_adapter", ADAPTER)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bmf_adapter = _import_adapter()


class ParseBenchOutputTests(unittest.TestCase):
    def test_full_output_with_finite_and_nonfinite_blocks(self) -> None:
        """The 10k-message smoke run mixes finite blocks and inf/nan blocks.

        Finite blocks become BMF entries; non-finite blocks are dropped. For
        unbounded_mupsic 4P/1C both min and max are finite, so lower_value
        and upper_value are present.
        """
        fixture = textwrap.dedent(
            """\
            Throughput Benchmark
            ====================

            Sipsic (bounded SPSC) 1P/1C:
              mean: inf ops/ms
              stddev: nan

            Mupmuc (bounded MPMC) 1P/1C:
              mean: inf ops/ms
              stddev: nan

            Mupmuc (bounded MPMC) 2P/2C:
              mean: 8000. ops/ms
              stddev: 2582.

            Mupmuc (bounded MPMC) 4P/4C:
              mean: 3283. ops/ms
              stddev: 1347.

            ===================================================
            UnboundedMupsic (unbounded MPSC) - runs = 2
            ===================================================
            UnboundedMupsic (unbounded MPSC) 1P/1C:
              mean: inf ops/ms
              min: 10000.  max: inf
              stddev: nan

            UnboundedMupsic (unbounded MPSC) 2P/1C:
              mean: inf ops/ms
              min: 10000.  max: inf
              stddev: nan

            UnboundedMupsic (unbounded MPSC) 4P/1C:
              mean: 7500. ops/ms
              min: 5000.  max: 10000.
              stddev: 3536.

            ===================================================

            Channels (MPMC) 1P/1C:
              mean: inf ops/ms
              stddev: nan

            Channels (MPMC) 2P/2C:
              mean: 2676. ops/ms
              stddev: 1747.

            Channels (MPMC) 4P/4C:
              mean: 645. ops/ms
              stddev: 327.
            """
        )

        expected = {
            "mupmuc/2p2c": {"throughput": {"value": 8000.0}},
            "mupmuc/4p4c": {"throughput": {"value": 3283.0}},
            "unbounded_mupsic/4p1c": {
                "throughput": {
                    "value": 7500.0,
                    "lower_value": 5000.0,
                    "upper_value": 10000.0,
                }
            },
            "channels/2p2c": {"throughput": {"value": 2676.0}},
            "channels/4p4c": {"throughput": {"value": 645.0}},
        }

        actual = bmf_adapter.parse_bench_output(fixture)
        self.assertEqual(actual, expected)

    def test_all_finite_full_run(self) -> None:
        """A full run with all finite means produces every variant."""
        fixture = textwrap.dedent(
            """\
            Throughput Benchmark
            ====================

            Sipsic (bounded SPSC) 1P/1C:
              mean: 12345. ops/ms
              stddev: 100.

            Mupmuc (bounded MPMC) 1P/1C:
              mean: 9000. ops/ms
              stddev: 200.

            UnboundedMupsic (unbounded MPSC) 1P/1C:
              mean: 11000. ops/ms
              min: 10000.  max: 12000.
              stddev: 50.

            UnboundedMupsic (unbounded MPSC) 2P/1C:
              mean: 6000. ops/ms
              min: 5500.  max: 6500.
              stddev: 30.

            Channels (MPMC) 1P/1C:
              mean: 4321. ops/ms
              stddev: 12.
            """
        )

        expected = {
            "sipsic/1p1c": {"throughput": {"value": 12345.0}},
            "mupmuc/1p1c": {"throughput": {"value": 9000.0}},
            "unbounded_mupsic/1p1c": {
                "throughput": {
                    "value": 11000.0,
                    "lower_value": 10000.0,
                    "upper_value": 12000.0,
                }
            },
            "unbounded_mupsic/2p1c": {
                "throughput": {
                    "value": 6000.0,
                    "lower_value": 5500.0,
                    "upper_value": 6500.0,
                }
            },
            "channels/1p1c": {"throughput": {"value": 4321.0}},
        }

        actual = bmf_adapter.parse_bench_output(fixture)
        self.assertEqual(actual, expected)

    def test_unknown_variant_is_skipped(self) -> None:
        """An unrecognised variant is ignored without breaking neighbours."""
        fixture = textwrap.dedent(
            """\
            SomethingNew (foo) 1P/1C:
              mean: 999. ops/ms
              stddev: 0.

            Sipsic (bounded SPSC) 1P/1C:
              mean: 100. ops/ms
              stddev: 1.
            """
        )

        expected = {"sipsic/1p1c": {"throughput": {"value": 100.0}}}
        actual = bmf_adapter.parse_bench_output(fixture)
        self.assertEqual(actual, expected)

    def test_partial_min_max_finite(self) -> None:
        """If only min is finite (max is inf), only lower_value is recorded."""
        fixture = textwrap.dedent(
            """\
            UnboundedMupsic (unbounded MPSC) 4P/1C:
              mean: 8000. ops/ms
              min: 5000.  max: inf
              stddev: 100.
            """
        )

        expected = {
            "unbounded_mupsic/4p1c": {
                "throughput": {"value": 8000.0, "lower_value": 5000.0}
            }
        }
        actual = bmf_adapter.parse_bench_output(fixture)
        self.assertEqual(actual, expected)


class CliTests(unittest.TestCase):
    def test_cli_writes_json_file(self) -> None:
        """End-to-end: CLI reads a fixture file and writes the expected JSON."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            in_path = tmp / "bench.txt"
            out_path = tmp / "bench.json"
            in_path.write_text(
                textwrap.dedent(
                    """\
                    Sipsic (bounded SPSC) 1P/1C:
                      mean: 100. ops/ms
                      stddev: 1.
                    """
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(ADAPTER), str(in_path), str(out_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            expected = {"sipsic/1p1c": {"throughput": {"value": 100.0}}}
            actual = json.loads(out_path.read_text(encoding="utf-8"))
            self.assertEqual(actual, expected)

    def test_cli_exits_nonzero_on_empty_input(self) -> None:
        """An input that yields no benchmark blocks is a hard failure."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            in_path = tmp / "bench.txt"
            out_path = tmp / "bench.json"
            in_path.write_text(
                "Throughput Benchmark\n====================\n", encoding="utf-8"
            )

            result = subprocess.run(
                [sys.executable, str(ADAPTER), str(in_path), str(out_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertEqual(
                result.stderr, "bmf_adapter: no benchmark blocks parsed\n"
            )
            self.assertFalse(out_path.exists())


if __name__ == "__main__":
    unittest.main()
