"""Guard: ``textgate scan`` lists nothing that ``docs/DOCS-textgate-keep.md`` omits.

The per-surface guards (fake tk, widget tree, wrapper) catch what a scenario
drives; this one catches what the line-based scanner sees anywhere in the repo,
so the count cannot drift back. Every hit must be documented as a kept row in
the keep doc (proper nouns, Claude-facing MCP titles, doubts) or live under the
exempt ``docs/explanations/`` pages. The scanner is a per-machine tool, so the
test skips where it is absent (CI); the same rows are what kuhy reviews.
"""

from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
KEEP = ROOT / "docs" / "DOCS-textgate-keep.md"
EXEMPT_PREFIX = "docs/explanations/"
HIT = re.compile(r"^hardcoded\s+(\S+?):(\d+)\s+(.*)$")


def parse_hits(output: str) -> list[tuple[str, str]]:
    """``(path, quoted text)`` for each scan line."""
    hits = []
    for line in output.splitlines():
        match = HIT.match(line)
        if match:
            hits.append((match.group(1), match.group(3)))
    return hits


def undocumented(hits: list[tuple[str, str]], keep: str) -> list[str]:
    """Hits outside the exempt docs whose ``path`` and text the keep doc omits."""
    return [
        f"{path} {text}"
        for path, text in hits
        if not path.startswith(EXEMPT_PREFIX) and f"`{path}`" not in keep
    ]


def test_parse_and_filter_are_strict() -> None:
    """Canary: a new file's hit is reported, a documented or exempt one is not."""
    out = (
        'hardcoded   app/lib/new.dart:3  "Hello"\n'
        'hardcoded   docs/explanations/a.html:9  "Page"\n'
        'hardcoded   app/lib/main.dart:65  "Diet Guard"\n'
        "240 to rework\n"
    )
    hits = parse_hits(out)
    assert len(hits) == 3
    assert undocumented(hits, "`app/lib/main.dart`") == ['app/lib/new.dart "Hello"']


@pytest.mark.skipif(shutil.which("textgate") is None, reason="textgate not installed")
def test_scan_lists_only_documented_rows() -> None:
    result = subprocess.run(
        [shutil.which("textgate") or "textgate", "scan"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=50,
    )
    hits = parse_hits(result.stdout)
    assert hits, "the scan returned nothing: the parser or the scanner broke"
    assert not undocumented(hits, KEEP.read_text(encoding="utf-8"))
