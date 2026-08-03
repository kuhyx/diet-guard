"""The gate must be fully keyboard-reachable at every supported screen size.

This is the *gate*, not a report: it fails rather than printing numbers. It ran
red before the fix and green after, which is the only evidence that a check
tests anything at all.

What it caught, measured under a real 1366x768 X server: the Log Meal tab
required 866px inside a 739px content pane -- and 938px with a day of meals
logged -- while being ``place``-centered, so the overflow was sheared off the
top *and* the bottom simultaneously. That took the "Diet Gate" title and the
slot header (which meal you are being asked to log) off one edge and the calorie
headline plus the whole dashboard off the other, with no scrollbar and nothing
to indicate anything was missing. Inside a hard lock that cannot be left
without logging a meal.

Two independent causes, both needed fixing: every font size was passed to Tk as
*points* rather than pixels (~30% oversized), and there was no scroll container
anywhere in the package.
"""

from __future__ import annotations

import pytest

from diet_guard.tests._gate_layout_probe import measure

# The screen the gate must fit: the primary machine's 1366x768 panel. It is
# landscape and SHORT -- phone-portrait test sizes exercise neither
# constraint, which is why the overflow survived a test suite that already
# pinned surface sizes. Panels below 768px get gatelock's best-effort
# compaction (``gatelock._density``) but are not gated: no machine runs one,
# and the gate cannot be trimmed to 600px without dropping content.
_REQUIRED_SIZES = [(1366, 768)]


@pytest.mark.parametrize(("screen_w", "screen_h"), _REQUIRED_SIZES)
@pytest.mark.parametrize("populated", [False, True])
def test_all_gate_content_is_keyboard_reachable(
    screen_w: int, screen_h: int, *, populated: bool
) -> None:
    """No part of the gate is unreachable, empty or with a full day logged.

    ``populated`` matters: the dashboard grows one line per logged meal, so a
    layout that fits on a fresh boot can still overflow by dinner. The empty
    case is not the worst case.
    """
    result = measure(screen_w, screen_h, populated=populated)
    assert result.reachable, result.describe()


@pytest.mark.parametrize(("screen_w", "screen_h"), _REQUIRED_SIZES)
def test_overflow_is_always_scrollable(screen_w: int, screen_h: int) -> None:
    """Whenever content exceeds the viewport, the keyboard can scroll it.

    Guards the specific regression: content may legitimately overflow, but it
    may never overflow *without* a keyboard route to the rest of it.
    """
    result = measure(screen_w, screen_h, populated=True)
    if result.needs_scroll:
        assert result.scrolls_by_keyboard, result.describe()
        assert result.last_widget_visible_after_focus, result.describe()


@pytest.mark.parametrize("populated", [False, True])
def test_gate_fits_the_primary_screen(*, populated: bool) -> None:
    """The gate fits 1366x768 without scrolling, empty or with a day logged.

    Scrolling is a correctness backstop, not the intended experience -- and
    since 2026-08-03 it is also *only* reachable by the user's own keypress or
    click, because a viewport that followed the app's own ``focus_set()``
    scrolled the screen under a user who had touched nothing. A gate that
    needs scrolling therefore needs the user to discover that it does.

    ``populated`` is the worst case: the dashboard grows one line per logged
    meal, so a layout that fits on a fresh boot can still overflow by dinner.
    """
    result = measure(1366, 768, populated=populated)
    assert not result.needs_scroll, result.describe()
