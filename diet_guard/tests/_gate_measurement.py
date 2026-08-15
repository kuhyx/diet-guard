"""The result type shared by the gate's layout and focus probes.

Split out of :mod:`._gate_layout_probe` so that module and
:mod:`._gate_focus_probe` can both import it without a cycle, and so each
file stays under the repo's 250-line limit.

Test support, not a test: it lives under ``tests/`` rather than in the
package, so its diagnostic-only branches are not held to the package's
100%-coverage bar.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Measurement:
    """One layout measurement against one screen size."""

    screen_w: int
    screen_h: int
    content_span: int
    viewport_h: int
    scrolls_by_keyboard: bool
    last_widget_visible_after_focus: bool
    has_scroll_viewport: bool = True

    @property
    def needs_scroll(self) -> bool:
        """Whether the content is taller than the viewport."""
        return self.content_span > self.viewport_h

    @property
    def reachable(self) -> bool:
        """Whether every part of the content can be reached by keyboard.

        Content that fits is trivially reachable. Content that overflows must
        scroll by keyboard *and* bring a focused below-the-fold widget into
        view.

        Deliberately not asserted: that focusing always *moves* the view. When
        the overflow is small the deepest widget is already visible, and then
        holding still is the correct behaviour -- the invariant is "the focused
        widget is visible", not "the viewport scrolled".
        """
        if not self.needs_scroll:
            return True
        return self.scrolls_by_keyboard and self.last_widget_visible_after_focus

    def describe(self) -> str:
        """Return a one-line human-readable summary."""
        fit = (
            f"needs scroll (+{self.content_span - self.viewport_h}px)"
            if self.needs_scroll
            else "fits"
        )
        verdict = "REACHABLE" if self.reachable else "UNREACHABLE CONTENT"
        viewport = (
            "scroll viewport present"
            if self.has_scroll_viewport
            else "NO SCROLL VIEWPORT -- overflow is clipped, not scrolled"
        )
        return (
            f"{self.screen_w}x{self.screen_h}: "
            f"content {self.content_span} in viewport {self.viewport_h} "
            f"-> {fit}; {viewport}; keys={self.scrolls_by_keyboard} "
            f"last_visible={self.last_widget_visible_after_focus} "
            f"-> {verdict}"
        )
