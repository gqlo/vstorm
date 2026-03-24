#!/usr/bin/env python3
"""YAML parse, ${threshold} substitution, list/lookup helpers for prom-query."""

from __future__ import annotations

import argparse
import re
import sys
from typing import Any, Dict, List, Tuple, Union

import yaml


class QueryNotFoundError(LookupError):
    def __init__(self, name: str, available: List[str]) -> None:
        self.name = name
        self.available = available


class MissingQueryFieldError(ValueError):
    def __init__(self, name: str) -> None:
        super().__init__(f'query "{name}" has no "query" field')
        self.name = name


class MissingThresholdError(ValueError):
    """Raised when ${threshold} appears but no defaults.threshold / per-query threshold."""


def format_threshold_for_subst(thr: Any) -> str:
    """Format threshold for ${threshold} replacement (PromQL rejects bare '.2' literals)."""
    if isinstance(thr, bool):
        return str(thr).lower()
    if isinstance(thr, str):
        s = thr.strip()
        if s.startswith("-."):
            body = s[2:]
            if body and body[0].isdigit():
                return "-0." + body
            return s
        if len(s) >= 2 and s[0] == "." and s[1].isdigit():
            return "0." + s[1:]
        return s
    if isinstance(thr, (int, float)) and not isinstance(thr, bool):
        return str(thr)
    return str(thr)


def load_queries_yaml(path: str) -> Dict[str, Any]:
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict) or not data:
        raise ValueError("no queries found in file")
    return data


def subst_threshold(
    text: str,
    entry: Union[dict, None],
    defaults: dict,
    *,
    is_query: bool = False,
) -> str:
    if "${threshold}" not in text:
        return text
    if isinstance(entry, dict):
        thr = entry.get("threshold", defaults.get("threshold"))
    else:
        thr = defaults.get("threshold")
    if thr is None:
        ctx = "query" if is_query else "description"
        raise MissingThresholdError(
            f"{ctx} contains ${{threshold}} but neither defaults.threshold nor "
            "per-query threshold is set"
        )
    return text.replace("${threshold}", format_threshold_for_subst(thr))


# PromQL rejects numeric literals that start with '.' (e.g. ">= .2"). Normalize to ">= 0.2".
_DOT_LITERAL_AFTER_CMP = re.compile(
    r"((?:>=|<=|==|!=|>|<))\s*\.(\d+)"
)


def normalize_promql_comparison_dot_literals(q: str) -> str:
    """Rewrite '>= .2' style comparisons to '>= 0.2' (Prometheus rejects bare '.2' literals)."""
    return _DOT_LITERAL_AFTER_CMP.sub(r"\1 0.\2", q)


def _validate_resolved_query(name: str, q: str) -> None:
    s = q.strip()
    if not s:
        raise ValueError(f'query "{name}" is empty after resolving YAML')
    # PromQL rejects a query that is only a leading-dot number (e.g. YAML typo query: ".2")
    if s[0] == ".":
        raise ValueError(
            f'query "{name}" starts with "." (invalid PromQL). '
            'Use a leading digit (e.g. 0.2) or fix the YAML "query" field.'
        )


def _finalize_query_string(q: str, entry: Union[dict, None], defaults: dict, name: str) -> str:
    q = q.replace("\r\n", "\n").replace("\r", "\n").strip()
    q = subst_threshold(q, entry, defaults, is_query=True)
    q = normalize_promql_comparison_dot_literals(q)
    _validate_resolved_query(name, q)
    return q


def query_names(data: Dict[str, Any]) -> List[str]:
    return [name for name in data if name != "defaults"]


def format_list_lines(data: Dict[str, Any]) -> List[str]:
    defaults = data.get("defaults", {}) if isinstance(data.get("defaults"), dict) else {}
    has_global_range = bool(defaults.get("start") or defaults.get("step"))
    lines: List[str] = []
    for name, entry in data.items():
        if name == "defaults":
            continue
        if not isinstance(entry, dict):
            lines.append(f"  {name}")
            continue
        desc = entry.get("description", "")
        desc = subst_threshold(desc, entry, defaults, is_query=False)
        is_range = bool(entry.get("start") or entry.get("step")) or has_global_range
        tag = " [range]" if is_range else ""
        if desc:
            lines.append(f"  {name:30s} {desc}{tag}")
        else:
            lines.append(f"  {name}{tag}")
    return lines


def lookup_query_lines(data: Dict[str, Any], name: str) -> Tuple[str, str, str, str]:
    defaults = data.get("defaults", {}) if isinstance(data.get("defaults"), dict) else {}
    entry = data.get(name)
    if entry is None:
        available = [k for k in data if k != "defaults"]
        raise QueryNotFoundError(name, available)
    if isinstance(entry, dict):
        q = entry.get("query")
        if not q:
            raise MissingQueryFieldError(name)
        if not isinstance(q, str):
            q = str(q)
        start = entry.get("start", defaults.get("start", ""))
        end = entry.get("end", defaults.get("end", ""))
        step = entry.get("step", defaults.get("step", ""))
        q = _finalize_query_string(q, entry, defaults, name)
        return (
            "" if start is None else str(start),
            "" if end is None else str(end),
            "" if step is None else str(step),
            q,
        )
    start = defaults.get("start", "")
    end = defaults.get("end", "")
    step = defaults.get("step", "")
    q = _finalize_query_string(str(entry), None, defaults, name)
    return (
        "" if start is None else str(start),
        "" if end is None else str(end),
        "" if step is None else str(step),
        q,
    )


def _die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(1)


def main(argv: List[str] | None = None) -> None:
    argv = argv if argv is not None else sys.argv[1:]
    p = argparse.ArgumentParser(prog="prom_query_yaml")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="format lines for prom-query -l")
    p_list.add_argument("file")

    p_names = sub.add_parser("names", help="print query names, one per line")
    p_names.add_argument("file")

    p_lookup = sub.add_parser("lookup", help="print start, end, step, query (4 lines)")
    p_lookup.add_argument("file")
    p_lookup.add_argument("name")

    args = p.parse_args(argv)

    try:
        data = load_queries_yaml(args.file)
    except ValueError:
        _die("(no queries found in file)")
    except OSError as e:
        _die(str(e))

    if args.cmd == "list":
        try:
            for line in format_list_lines(data):
                print(line)
        except MissingThresholdError as e:
            _die(f"Error: {e}")
        return

    if args.cmd == "names":
        for n in query_names(data):
            print(n)
        return

    if args.cmd == "lookup":
        try:
            start, end, step, q = lookup_query_lines(data, args.name)
        except QueryNotFoundError as e:
            _die(
                f'Error: query "{e.name}" not found in {args.file}\n'
                f'Available queries: {", ".join(e.available)}'
            )
        except MissingQueryFieldError as e:
            _die(f'Error: {e}')
        except MissingThresholdError as e:
            _die(f"Error: {e}")
        except ValueError as e:
            _die(f"Error: {e}")
        print(start)
        print(end)
        print(step)
        print(q)
        return


if __name__ == "__main__":
    main()
