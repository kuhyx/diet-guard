#!/usr/bin/env python3
"""Input cases for ``scripts/build_meal_schedule_fixture.py``.

Split out of the builder for the repo's 250-line cap.  Inputs only: every
expected value is computed by the builder from the Python implementation.
A script-style file like its siblings (hence the shebang); running it
directly does nothing -- run the builder.
"""

from __future__ import annotations

H = 60
Triple = tuple[int, int, int]


def window(first: int, last: int) -> list[Triple]:
    """Return ``(first, last, count)`` for counts 2..6 plus a clamp either side."""
    return [(first, last, count) for count in (0, 2, 3, 4, 5, 6, 7)]


#: Curated (first_minute, last_minute, count) inputs.  Both suites also sweep
#: the 15-minute grid in code; this table holds exact values a human can check.
SCHEDULES: list[Triple] = [
    *window(8 * H, 20 * H),  # the default window
    *window(7 * H + 15, 19 * H),  # the user's quarter-hour breakfast
    *window(7 * H + 23, 19 * H + 41),  # off-grid endpoints, never snapped
    *window(0, 1439),  # the whole day, last at 23:59
    (7 * H, 19 * H, 5),
    (7 * H, 21 * H, 4),  # uneven: the old hour formula said 12:00 here
    (7 * H, 21 * H, 5),
    (9 * H, 19 * H, 4),
    (0, 12 * H, 3),  # a midnight first slot is a real slot
    (0, H, 2),
    (0, H, 6),
    (22 * H, 1439, 3),
    (23 * H, 1439, 6),
    # Narrow windows: count is capped at window // 15 + 1.
    (8 * H, 8 * H + 15, 6),
    (8 * H, 8 * H + 30, 6),
    (8 * H, 8 * H + 45, 6),
    (8 * H, 9 * H, 6),
    (8 * H, 9 * H + 14, 6),
    (8 * H, 9 * H + 15, 6),
    (481, 496, 3),
    (8 * H + 7, 9 * H + 22, 6),
    # Every normalized() clamp.
    (-5, 20 * H, 4),
    (1430, 1439, 2),
    (1439, 1439, 2),
    (2000, -5, 999),
    (8 * H, 5000, 4),
    (12 * H, 12 * H, 4),
    (12 * H, 100, 4),
    (12 * H, 12 * H + 14, 2),
    (8 * H, 20 * H, -3),
    (8 * H, 20 * H, 99),
    (8, 20, 4),  # an hour-valued caller that missed the rename: 00:08-00:23
]

#: Schedules whose every slot +/- 1 minute and cutoff edge is pinned.
EDGE_SCHEDULES: list[Triple] = [
    (8 * H, 20 * H, 4),
    (8 * H, 20 * H, 5),
    (7 * H + 15, 19 * H, 5),
    (7 * H + 23, 19 * H + 41, 4),
    (0, 12 * H, 3),
    (0, 1439, 6),  # cutoff clamps to 1440: the window closes at midnight
    (22 * H, 1439, 3),
]

DEFAULT: Triple = (8 * H, 20 * H, 4)
SATISFIED: list[tuple[str, Triple, list[int]]] = [
    ("empty input satisfies nothing", DEFAULT, []),
    # Logged 07:00 and 10:00 under 07:00-19:00 x5, then the schedule moved.
    ("old 07:00/10:00 meals after moving to 07:15", (435, 1140, 5), [420, 600]),
    ("two meals snap onto one slot", DEFAULT, [480, 540]),
    ("legacy hour entries under five meals", (8 * H, 20 * H, 5), [480, 720]),
    ("exact halfway goes to the earlier slot", DEFAULT, [600, 840]),
    ("out-of-window minutes clamp to the ends", DEFAULT, [0, 1439]),
    ("every slot exactly", DEFAULT, [480, 720, 960, 1200]),
]

#: (schedule, minute, logged slot minutes) for missing_slots.
MISSING: list[tuple[Triple, int, list[int]]] = [
    (DEFAULT, 13 * H, [480, 720]),
    (DEFAULT, 17 * H, [480]),
    (DEFAULT, 23 * H, []),
    ((435, 1140, 5), 615, [435]),
    ((435, 1140, 5), 614, []),
]

LABELS = [0, 5, 59, 60, 435, 480, 615, 1200, 1439, 1440, -15]

WIRE_DECODE: list[object] = [
    {"f": 8, "l": 20, "n": 4},
    {"f": 7, "l": 19, "n": 5, "fm": 435},
    {"f": 7, "l": 19, "n": 5, "fm": 443, "lm": 1181},
    {"f": 7, "l": 19, "n": 5, "fm": 600},  # fm wins even if it disagrees with f
    {"f": 7, "l": 19, "n": 5, "fm": True},  # bool is not an int: f wins
    {"f": 7, "l": 19, "n": 5, "fm": 435.0},  # nor is a float
    {"f": 7, "l": 19, "n": 5, "lm": None},
    {"f": True, "l": 20, "n": 4},
    {"f": 8, "l": 20},
    {"f": "8", "l": 20, "n": 4},
    {"f": 99, "l": -5, "n": 999},  # garbage from a peer is normalised
    [8, 20, 4],
    None,
]

SLOT_FIELD_MINUTES = [0, 59, 60, 435, 480, 1200, 1439, -1, 1440]

ENTRIES: list[dict[str, object]] = [
    {"slot": 8},
    {"slot": 0},
    {"slot": 7, "slot_min": 435},
    {"slot_min": 435},
    {"slot": 5, "slot_min": 0},  # a zero slot_min still wins
    {"slot": 8, "slot_min": True},
    {"slot": 8, "slot_min": False},
    {"slot": True},
    {"slot": "8"},
    {"slot": 8.0},
    {"slot": None},
    {},
]
