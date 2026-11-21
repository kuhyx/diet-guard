"""The rank this repo publishes matches its row in ``DOCS-lock-order.md``.

kuhy fixed the order of every lock on 2026-11-21 (workout, book, tutor, diet,
focus, LeetCode last). Each repo keeps the rank as its own literal, so this
test is what stops one repo drifting out of that order on its own.
"""

from __future__ import annotations

from pathlib import Path
import re

from diet_guard._constants import RANK_DIET_GUARD

_DOCS = Path(__file__).resolve().parents[2] / "DOCS-lock-order.md"
_ROW = re.compile(r"^\| (\d+) \| [^|]+ \| (\w+) \| (\d+) \| [^|]+ \|$")


def _documented_ranks() -> dict[str, int]:
    """Map each gatelock app in the DOCS table to its rank."""
    rows = (_ROW.match(line) for line in _DOCS.read_text().splitlines())
    return {m[2]: int(m[3]) for m in rows if m}


def test_the_rank_is_the_one_in_the_lock_order_table() -> None:
    """A rank changed here without the table (or back) fails."""
    assert _documented_ranks()["diet_guard"] == RANK_DIET_GUARD


def test_the_table_orders_the_locks_by_falling_rank() -> None:
    """Rows run strongest first, and no two locks share a rank."""
    ranks = list(_documented_ranks().values())
    assert ranks == sorted(ranks, reverse=True)
    assert len(set(ranks)) == len(ranks)
