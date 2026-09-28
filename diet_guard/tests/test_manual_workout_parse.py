"""Manual workouts: sport and distance from free text, and time windows."""

from __future__ import annotations

import pytest

from diet_guard._manual_workout_parse import logged_window, manual_session


class TestManualParse:
    @pytest.mark.parametrize(
        ("item", "kind", "km"),
        [
            ({"activity_type": "Running", "distance_km": "7.5"}, "run", 7.5),
            (
                {"sport": "other", "source": "evening run 5,2km by the river"},
                "run",
                5.2,
            ),
            ({"sport": "other", "source": "walked 3500 m"}, "walk", 3.5),
            ({"sport": "other", "source": "climbing a 5 m wall"}, "other", None),
            (
                {"sport": "other", "source": "long walk", "distance_km": "bad"},
                "walk",
                None,
            ),
            ({"activity_type": "Cycling", "source": "20 km"}, "cycle", None),
        ],
    )
    def test_kind_and_distance(
        self, item: dict[str, object], kind: str, km: float | None
    ) -> None:
        session = manual_session("2026-09-20", item, 45.0, "l")
        assert (session.kind, session.km) == (kind, km)

    def test_clock_window_including_past_midnight(self) -> None:
        night = manual_session(
            "2026-09-20", {"start_time": "23:30", "end_time": "00:30"}, 60, "l"
        )
        assert night.start is not None
        assert night.end is not None
        assert night.end > night.start
        assert manual_session("2026-09-20", {"start_time": "x"}, 60, "l").start is None

    def test_logged_window(self) -> None:
        start, end = logged_window("2026-09-27T15:15:00+00:00", 60)
        assert start is not None
        assert end is not None
        assert logged_window("never", 60) == (None, None)
