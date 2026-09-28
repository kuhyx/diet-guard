"""Workouts from RunnerUp TCX files and screen-locker's log, deduplicated.

conftest points ``RUNNERUP_DIRS`` at an empty tmp dir and stubs
``screen_locker_log_file``; each test here supplies its own sources.
"""

from __future__ import annotations

from datetime import date
import json
from types import SimpleNamespace
from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _activity_sources

if TYPE_CHECKING:
    from pathlib import Path

# Captured at import, before conftest's autouse patch replaces the attribute.
_REAL_LOG_FILE = _activity_sources.screen_locker_log_file
# screen-locker is not installed on CI (nor in the dev venv): stand in for its
# ``_log_io`` with the one behaviour used -- read the day-keyed JSON.
_FAKE_LOG_IO = SimpleNamespace(
    load_workout_log=lambda path: json.loads(path.read_text(encoding="utf-8"))
)

_TCX = """<?xml version="1.0"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
 <Activities><Activity Sport="{sport}"><Id>{ident}</Id>
  <Lap><TotalTimeSeconds>1800</TotalTimeSeconds><DistanceMeters>{m}</DistanceMeters></Lap>
  <Lap><TotalTimeSeconds>600</TotalTimeSeconds><DistanceMeters>0</DistanceMeters></Lap>
 </Activity></Activities>
</TrainingCenterDatabase>"""


def _tcx(
    folder: Path, name: str, ident: str, sport: str = "Running", m: int = 5000
) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_text(
        _TCX.format(sport=sport, ident=ident, m=m), encoding="utf-8"
    )


def _entry(
    data: dict[str, object], stamp: str = "2026-09-20T17:00:00+00:00"
) -> dict[str, object]:
    return {"timestamp": stamp, "workout_data": data}


class TestRunnerUp:
    def test_parses_dedupes_and_windows(self, tmp_path: Path) -> None:
        inbox, done = tmp_path / "in", tmp_path / "in/processed"
        _tcx(inbox, "a.tcx", "2026-09-20T17:00:00Z")
        _tcx(done, "a.tcx", "2026-09-20T17:00:00Z")  # same activity, moved
        _tcx(done, "old.tcx", "2026-08-01T17:00:00Z")
        _tcx(done, "walk.tcx", "2026-09-21T08:00:00Z", sport="Walking", m=0)
        (done / "broken.tcx").write_text("<nope", encoding="utf-8")
        (done / "empty.tcx").write_text("<TrainingCenterDatabase/>", encoding="utf-8")
        with patch.object(
            _activity_sources, "RUNNERUP_DIRS", (inbox, done, tmp_path / "x")
        ):
            runs = _activity_sources.runnerup_sessions("2026-09-01")
        assert [(s.kind, s.minutes, s.km) for s in runs] == [
            ("run", 40.0, 5.0),
            ("walk", 40.0, None),
        ]
        assert runs[0].start is not None
        assert runs[0].end is not None


class TestScreenLockerLogFile:
    def test_absent_package(self) -> None:
        with patch.object(_activity_sources, "import_module", side_effect=ImportError):
            assert _REAL_LOG_FILE() is None

    def test_package_with_and_without_a_log(self, tmp_path: Path) -> None:
        pkg = SimpleNamespace(__file__=str(tmp_path / "__init__.py"))
        with patch.object(_activity_sources, "import_module", return_value=pkg):
            assert _REAL_LOG_FILE() is None
            (tmp_path / "log.json").write_text("{}", encoding="utf-8")
            assert _REAL_LOG_FILE() == tmp_path / "log.json"


class TestScreenLocker:
    def _run(
        self, tmp_path: Path, log: dict[str, object], tcx_days: set[str]
    ) -> list[object]:
        path = tmp_path / "log.json"
        path.write_text(json.dumps(log), encoding="utf-8")
        with (
            patch.object(
                _activity_sources, "screen_locker_log_file", return_value=path
            ),
            patch.object(_activity_sources, "import_module", return_value=_FAKE_LOG_IO),
        ):
            return _activity_sources.screen_locker_sessions("2026-09-01", tcx_days)

    def test_every_entry_type(self, tmp_path: Path) -> None:
        log = {
            "2026-08-01": [
                _entry({"type": "pc_workout_verified", "duration_minutes": "50"})
            ],
            "2026-09-20": [
                _entry(
                    {
                        "type": "pc_workout_verified",
                        "source": "SL B (86 min, partial)",
                        "duration_minutes": "86.2",
                    }
                ),
                _entry(
                    {"type": "phone_verified", "source": "Workout verified! (86 min)"}
                ),
                _entry({"type": "relaxed_day_skip"}),
                _entry(
                    {
                        "type": "manual_workout",
                        "activity_type": "Walking",
                        "duration_minutes": "60",
                        "start_time": "19:15",
                        "end_time": "20:15",
                    }
                ),
                {"workout_data": "junk"},
            ],
            "2026-09-21": [
                _entry(
                    {"type": "phone_verified", "source": "Workout verified! (70 min)"}
                )
            ],
            "2026-09-22": [
                _entry(
                    {
                        "type": "runnerup_verified",
                        "source": "Auto-scanned: Running: 5.6 km in 60 min",
                        "distance_km": 5.61,
                        "duration_minutes": 60.5,
                    }
                )
            ],
            "2026-09-23": [
                _entry(
                    {
                        "type": "runnerup_verified",
                        "source": "Auto-scanned",
                        "duration_minutes": "x",
                    }
                )
            ],
            "2026-09-24": [
                _entry(
                    {
                        "type": "runnerup_verified",
                        "source": "odd",
                        "duration_minutes": 30,
                        "distance_km": "far",
                    }
                )
            ],
            "2026-09-25": [
                _entry({"type": "runnerup_verified", "duration_minutes": 30})
            ],
        }
        sessions = self._run(tmp_path, log, {"2026-09-25"})
        summary = [(s.day, s.kind, s.minutes, s.km) for s in sessions]
        assert summary == [
            ("2026-09-20", "strength", 86.2, None),
            ("2026-09-20", "walk", 60.0, None),
            ("2026-09-21", "strength", 70.0, None),
            ("2026-09-22", "run", 60.5, 5.61),
            ("2026-09-24", "run", 30.0, None),
        ]

    def test_absent_or_unreadable_log(self, tmp_path: Path) -> None:
        assert _activity_sources.screen_locker_sessions("2026-09-01", set()) == []
        with (
            patch.object(
                _activity_sources, "screen_locker_log_file", return_value=tmp_path
            ),
            patch.object(_activity_sources, "import_module", side_effect=ImportError),
        ):
            assert _activity_sources.screen_locker_sessions("2026-09-01", set()) == []


class TestCollect:
    def test_tcx_day_suppresses_the_duplicate_scan(self, tmp_path: Path) -> None:
        _tcx(tmp_path / "r", "a.tcx", "2026-09-22T17:00:00Z")
        log = tmp_path / "log.json"
        log.write_text(
            json.dumps(
                {
                    "2026-09-22": [
                        _entry({"type": "runnerup_verified", "duration_minutes": 60})
                    ]
                }
            ),
            encoding="utf-8",
        )
        with (
            patch.object(_activity_sources, "RUNNERUP_DIRS", (tmp_path / "r",)),
            patch.object(_activity_sources, "screen_locker_log_file", return_value=log),
            patch.object(_activity_sources, "import_module", return_value=_FAKE_LOG_IO),
        ):
            sessions = _activity_sources.collect_sessions(date(2026, 9, 28))
            assert _activity_sources.sources_available()
        assert [s.source for s in sessions] == ["runnerup"]

    def test_no_sources(self) -> None:
        assert not _activity_sources.sources_available()
