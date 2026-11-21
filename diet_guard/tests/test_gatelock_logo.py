"""The kuhy logo sits in the bottom-right corner of every gate surface."""

from __future__ import annotations

import os
import tkinter as tk
from typing import TYPE_CHECKING

from kuhy_credit.tk import KuhyCredit
import pytest

from diet_guard._gatelock_logo import place_logo

if TYPE_CHECKING:
    from pytest_xvfb import Xvfb


def test_place_logo_anchors_bottom_right(xvfb: Xvfb | None) -> None:
    # Real Tk, so only ever on pytest-xvfb's private display -- never the user's.
    if xvfb is None:
        pytest.skip("needs pytest-xvfb's private display")
    assert os.environ["DISPLAY"] == f":{xvfb.display}"
    root = tk.Tk()
    try:
        root.withdraw()
        frame = tk.Frame(root)
        credit = place_logo(frame)
        assert isinstance(credit, KuhyCredit)
        assert credit.master is frame
        info = credit.place_info()
        assert info["anchor"] == "se"
        assert (info["relx"], info["rely"]) == ("1", "1")
        assert (info["x"], info["y"]) == ("-16", "-16")
    finally:
        root.destroy()
