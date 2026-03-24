#!/usr/bin/env python3
"""
Tests for prom-query YAML handling (monitoring/scripts/prom_query_yaml.py).
Run from repo root: python3 -m unittest discover -s monitoring/tests -v
"""

from __future__ import annotations

import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

_SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
_LIB = _SCRIPTS / "prom_query_yaml.py"
_PROM_QUERY = _SCRIPTS / "prom-query"
_DESCHED_COUNTS = (
    Path(__file__).resolve().parent / "fixtures" / "prom-queries-descheduler-counts.yaml"
)


def _load_prom_query_yaml():
    spec = importlib.util.spec_from_file_location("prom_query_yaml", _LIB)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load spec for {_LIB}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pqy = _load_prom_query_yaml()


def _defaults_threshold_str(path: Path) -> str:
    """String form of defaults.threshold after format_threshold_for_subst (matches prom-query output)."""
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    defaults = data.get("defaults") if isinstance(data.get("defaults"), dict) else {}
    if "threshold" not in defaults:
        raise AssertionError(f"{path}: missing defaults.threshold (needed for integration checks)")
    return pqy.format_threshold_for_subst(defaults["threshold"])


class TestSubstThreshold(unittest.TestCase):
    def test_no_placeholder_unchanged(self) -> None:
        self.assertEqual(
            pqy.subst_threshold("up", {}, {}, is_query=True),
            "up",
        )

    def test_replaces_from_defaults(self) -> None:
        self.assertEqual(
            pqy.subst_threshold(
                "m >= ${threshold}",
                {"query": "x"},
                {"threshold": 0.1},
                is_query=True,
            ),
            "m >= 0.1",
        )

    def test_per_query_overrides_default(self) -> None:
        self.assertEqual(
            pqy.subst_threshold(
                "m >= ${threshold}",
                {"threshold": 0.25},
                {"threshold": 0.1},
                is_query=True,
            ),
            "m >= 0.25",
        )

    def test_scalar_entry_uses_defaults_only(self) -> None:
        self.assertEqual(
            pqy.subst_threshold("x >= ${threshold}", None, {"threshold": 2}, is_query=True),
            "x >= 2",
        )

    def test_missing_threshold_raises(self) -> None:
        with self.assertRaises(pqy.MissingThresholdError) as ctx:
            pqy.subst_threshold("x >= ${threshold}", {}, {}, is_query=True)
        self.assertIn("query", str(ctx.exception).lower())

    def test_string_threshold_leading_dot_normalized(self) -> None:
        self.assertEqual(pqy.format_threshold_for_subst(".2"), "0.2")
        self.assertEqual(pqy.format_threshold_for_subst("-.25"), "-0.25")
        self.assertEqual(
            pqy.subst_threshold(
                "m >= ${threshold}",
                {"query": "x"},
                {"threshold": ".2"},
                is_query=True,
            ),
            "m >= 0.2",
        )

    def test_normalize_promql_comparison_dot_literals(self) -> None:
        self.assertEqual(
            pqy.normalize_promql_comparison_dot_literals(
                "count(descheduler:x >= .2)"
            ),
            "count(descheduler:x >= 0.2)",
        )
        self.assertEqual(
            pqy.normalize_promql_comparison_dot_literals("a <= .25 and b > .5"),
            "a <= 0.25 and b > 0.5",
        )


class TestLookupAndList(unittest.TestCase):
    def _write(self, doc: dict) -> str:
        f = tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".yaml",
            delete=False,
            encoding="utf-8",
        )
        try:
            yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
            f.flush()
            return f.name
        finally:
            f.close()

    def test_lookup_merges_defaults_and_substitutes(self) -> None:
        path = self._write(
            {
                "defaults": {"start": "a", "end": "b", "step": "c", "threshold": 0.1},
                "q1": {
                    "description": "d >= ${threshold}",
                    "query": "metric >= ${threshold}",
                },
            }
        )
        try:
            data = pqy.load_queries_yaml(path)
            start, end, step, q = pqy.lookup_query_lines(data, "q1")
            self.assertEqual((start, end, step), ("a", "b", "c"))
            self.assertEqual(q, "metric >= 0.1")
            lines = pqy.format_list_lines(data)
            self.assertTrue(any("d >= 0.1" in ln for ln in lines))
        finally:
            Path(path).unlink(missing_ok=True)

    def test_lookup_scalar_query(self) -> None:
        path = self._write(
            {
                "defaults": {
                    "start": "s",
                    "end": "e",
                    "step": "t",
                    "threshold": 0.2,
                },
                "raw": "count(series >= ${threshold})",
            }
        )
        try:
            data = pqy.load_queries_yaml(path)
            start, end, step, q = pqy.lookup_query_lines(data, "raw")
            self.assertEqual((start, end, step), ("s", "e", "t"))
            self.assertEqual(q, "count(series >= 0.2)")
        finally:
            Path(path).unlink(missing_ok=True)

    def test_query_not_found(self) -> None:
        path = self._write({"defaults": {}, "a": {"query": "up"}})
        try:
            data = pqy.load_queries_yaml(path)
            with self.assertRaises(pqy.QueryNotFoundError) as ctx:
                pqy.lookup_query_lines(data, "missing")
            self.assertEqual(ctx.exception.name, "missing")
            self.assertEqual(ctx.exception.available, ["a"])
        finally:
            Path(path).unlink(missing_ok=True)

    def test_missing_query_field(self) -> None:
        path = self._write({"defaults": {}, "bad": {"description": "x"}})
        try:
            data = pqy.load_queries_yaml(path)
            with self.assertRaises(pqy.MissingQueryFieldError):
                pqy.lookup_query_lines(data, "bad")
        finally:
            Path(path).unlink(missing_ok=True)

    def test_query_names_order(self) -> None:
        path = self._write(
            {
                "defaults": {},
                "first": {"query": "1"},
                "second": {"query": "2"},
            }
        )
        try:
            data = pqy.load_queries_yaml(path)
            self.assertEqual(pqy.query_names(data), ["first", "second"])
        finally:
            Path(path).unlink(missing_ok=True)

    def test_query_starting_with_dot_rejected(self) -> None:
        # Quoted ".2" so YAML keeps a string (unquoted .2 would load as float 0.2).
        f = tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".yaml",
            delete=False,
            encoding="utf-8",
        )
        path = f.name
        try:
            f.write(
                """defaults:
  threshold: 0.1
bad:
  query: ".2"
"""
            )
            f.close()
            data = pqy.load_queries_yaml(path)
            with self.assertRaises(ValueError) as ctx:
                pqy.lookup_query_lines(data, "bad")
            self.assertIn("starts with", str(ctx.exception).lower())
        finally:
            Path(path).unlink(missing_ok=True)


class TestPromQueryYamlCLI(unittest.TestCase):
    def _run_main(self, argv: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        old_out, old_err = sys.stdout, sys.stderr
        try:
            sys.stdout, sys.stderr = out, err
            try:
                pqy.main(argv)
                code = 0
            except SystemExit as e:
                code = int(e.code) if isinstance(e.code, int) else 1
        finally:
            sys.stdout, sys.stderr = old_out, old_err
        return code, out.getvalue(), err.getvalue()

    def test_cli_list_resolves_threshold(self) -> None:
        thr = _defaults_threshold_str(_DESCHED_COUNTS)
        code, out, err = self._run_main(["list", str(_DESCHED_COUNTS)])
        self.assertEqual(code, 0, msg=err)
        self.assertIn("count-cpu-util-pd", out)
        self.assertIn(f">= {thr}", out)
        self.assertEqual(err, "")

    def test_cli_lookup_resolves_query(self) -> None:
        thr = _defaults_threshold_str(_DESCHED_COUNTS)
        code, out, err = self._run_main(
            ["lookup", str(_DESCHED_COUNTS), "count-cpu-util-pd"]
        )
        self.assertEqual(code, 0, msg=err)
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 4)
        self.assertIn(thr, lines[3])
        self.assertIn(f"positivedeviation >= {thr}", lines[3])

    def test_cli_lookup_unknown_query_exits_nonzero(self) -> None:
        code, _out, err = self._run_main(
            ["lookup", str(_DESCHED_COUNTS), "nope-not-a-query"]
        )
        self.assertNotEqual(code, 0)
        self.assertIn("not found", err)
        self.assertIn("Available queries", err)


class TestPromQueryShellScript(unittest.TestCase):
    @unittest.skipUnless(_PROM_QUERY.is_file(), "prom-query not present")
    def test_list_matches_python_cli(self) -> None:
        thr = _defaults_threshold_str(_DESCHED_COUNTS)
        r = subprocess.run(
            [str(_PROM_QUERY), "-l", str(_DESCHED_COUNTS)],
            cwd=str(_SCRIPTS.parent),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)
        self.assertIn("count-cpu-util-pd", r.stdout)
        self.assertIn(f">= {thr}", r.stdout)


if __name__ == "__main__":
    unittest.main()
