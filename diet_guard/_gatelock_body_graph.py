"""The Body tab's weight graph, drawn on a plain ``tk.Canvas``.

No plotting dependency: the gate runs on system ``/usr/bin/python`` and a
line, some dots, four gridlines and a shaded healthy band are all a weight
trend needs. The geometry (:func:`graph_points`, :func:`value_ticks`) is pure
so it is tested without Tk; :func:`draw_weight_graph` only issues canvas
calls.

.. note::
   Imports ``tkinter`` for types only; it never builds widgets, so it is not
   in ``_GATE_TK_MODULES``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from typing import TYPE_CHECKING

from diet_guard._gatelock_calendar_types import _ACCENT, _COLORS, _MUTED
from diet_guard._gatelock_typography import CAPTION
from diet_guard._gatelock_ui import BG, FG

if TYPE_CHECKING:
    import tkinter as tk

__all__ = [
    "GRAPH_RANGES",
    "GraphBox",
    "draw_weight_graph",
    "graph_points",
    "value_ticks",
]

# (label, days back; None = everything).
GRAPH_RANGES: tuple[tuple[str, int | None], ...] = (
    ("30 days", 30),
    ("90 days", 90),
    ("1 year", 365),
    ("All", None),
)
_HEALTHY_FILL = "#1f3a2a"
_GRID = "#33363d"
_DOT_R = 3
_TICKS = 4
# Keep a flat line off the frame: pad the value range by this much (kg).
_MIN_SPAN_KG = 2.0
# Include a healthy-band edge on the axis only when it is this close (kg).
_BAND_REACH_KG = 5.0
# Headroom above and below the data, as a fraction of its range.
_PAD_FRACTION = 0.1


@dataclass(frozen=True)
class GraphBox:
    """Canvas size and the inner plot margins (px)."""

    width: int
    height: int
    left: int = 56
    right: int = 16
    top: int = 16
    bottom: int = 28

    def x(self, frac: float) -> float:
        """Canvas x for a 0..1 position along the time axis."""
        return self.left + frac * (self.width - self.left - self.right)

    def y(self, frac: float) -> float:
        """Canvas y for a 0..1 position up the value axis."""
        return self.height - self.bottom - frac * (self.height - self.top - self.bottom)


def in_range(
    weights: dict[str, float], today: date, days: int | None
) -> dict[str, float]:
    """The weigh-ins within the last ``days`` days (all when None)."""
    if days is None:
        return dict(weights)
    first = (today - timedelta(days=days)).isoformat()
    return {day: kg for day, kg in weights.items() if day >= first}


def value_span(
    values: list[float], band: tuple[float, float] | None
) -> tuple[float, float]:
    """Low/high of the value axis: the data, padded, plus a *nearby* band edge.

    A band edge more than :data:`_BAND_REACH_KG` from the data is left off the
    axis: pulling a 60 kg floor under an 84-to-82 kg trend flattens the trend
    into one line, and the trend is what the graph is for.
    """
    low, high = min(values), max(values)
    if band is not None:
        for edge in band:
            if low - _BAND_REACH_KG <= edge <= high + _BAND_REACH_KG:
                low, high = min(low, edge), max(high, edge)
    pad = max((high - low) * _PAD_FRACTION, _MIN_SPAN_KG / 2)
    return low - pad, high + pad


def graph_points(
    weights: dict[str, float], box: GraphBox, span: tuple[float, float]
) -> list[tuple[float, float]]:
    """Canvas points for each weigh-in, time on x (by date), kg on y."""
    days = sorted(weights)
    first = date.fromisoformat(days[0])
    total = max((date.fromisoformat(days[-1]) - first).days, 1)
    low, high = span
    return [
        (
            box.x(
                (date.fromisoformat(day) - first).days / total if len(days) > 1 else 0.5
            ),
            box.y((weights[day] - low) / (high - low)),
        )
        for day in days
    ]


def value_ticks(span: tuple[float, float]) -> list[float]:
    """Evenly spaced gridline values across the axis, ends included."""
    low, high = span
    return [low + (high - low) * i / _TICKS for i in range(_TICKS + 1)]


def _draw_band(
    canvas: tk.Canvas,
    box: GraphBox,
    span: tuple[float, float],
    healthy: tuple[float, float],
) -> None:
    """Shade the healthy-BMI weights, clipped to the axis (skipped if off it)."""
    low, high = span
    if healthy[0] >= high or healthy[1] <= low:
        return
    top = box.y((min(healthy[1], high) - low) / (high - low))
    bottom = box.y((max(healthy[0], low) - low) / (high - low))
    canvas.create_rectangle(
        box.x(0), top, box.x(1), bottom, fill=_HEALTHY_FILL, outline=""
    )
    font = (_COLORS.typography.font_family, CAPTION)
    canvas.create_text(
        box.x(1) - 4, top + 2, text="healthy BMI", anchor="ne", fill=_MUTED, font=font
    )


def draw_weight_graph(
    canvas: tk.Canvas,
    weights: dict[str, float],
    box: GraphBox,
    healthy: tuple[float, float] | None,
) -> None:
    """Redraw the whole graph; an empty log shows a hint instead."""
    canvas.delete("all")
    font = (_COLORS.typography.font_family, CAPTION)
    if not weights:
        canvas.create_text(
            box.width / 2,
            box.height / 2,
            text="Nothing logged in this range yet.",
            fill=_MUTED,
            font=font,
        )
        return
    span = value_span(list(weights.values()), healthy)
    low, high = span
    if healthy is not None:
        _draw_band(canvas, box, span, healthy)
    for value in value_ticks(span):
        y = box.y((value - low) / (high - low))
        canvas.create_line(box.x(0), y, box.x(1), y, fill=_GRID)
        canvas.create_text(
            box.left - 6, y, text=f"{value:.1f}", anchor="e", fill=_MUTED, font=font
        )
    points = graph_points(weights, box, span)
    if len(points) > 1:
        canvas.create_line(*[c for p in points for c in p], fill=_ACCENT, width=2)
    for x, y in points:
        canvas.create_oval(
            x - _DOT_R, y - _DOT_R, x + _DOT_R, y + _DOT_R, fill=_ACCENT, outline=BG
        )
    days = sorted(weights)
    base = box.height - box.bottom + 14
    canvas.create_text(box.x(0), base, text=days[0], anchor="w", fill=FG, font=font)
    canvas.create_text(box.x(1), base, text=days[-1], anchor="e", fill=FG, font=font)
