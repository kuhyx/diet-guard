"""The local Body document: profile, per-day weight log, published workouts.

Shape and merge rules are in ``docs/DOCS-body.md``; the sync adapters are
:mod:`diet_guard.sync_merge._body`. Every write stamps an edit time ``t`` so
the per-field last-writer-wins merge has something to compare, and every read
is tolerant: a malformed field reads as absent rather than raising, because a
peer on a future version must not be able to break this device's Body tab.

KEEP IN SYNC WITH ``app/lib/services/body_service.dart``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime
import json
import logging

from diet_guard._budget_biometrics import Biometrics
from diet_guard._constants import BODY_FILE

_logger = logging.getLogger(__name__)

_FILE_VERSION = 1
# Every top-level section of the document (``bodyfat`` is a dated log like
# ``weights``; see ``_body_fat_store``).
SECTIONS: tuple[str, ...] = ("profile", "weights", "bodyfat", "activity", "steps")
PROFILE_FIELDS: tuple[str, ...] = ("birth", "height_cm", "sex")
_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)
# A body weight outside this range is a typo or a unit mix-up, never real.
MIN_KG = 20.0
MAX_KG = 400.0


@dataclass(frozen=True)
class Profile:
    """The person's stored body profile; any field may still be unset."""

    birth: str | None
    height_cm: float | None
    sex: str | None

    @property
    def complete(self) -> bool:
        """Whether every field is set -- then the profile moves to the bottom."""
        return None not in (self.birth, self.height_cm, self.sex)

    def biometrics(self, weight_kg: float, today: date) -> Biometrics | None:
        """Biometrics for today, or None while the profile is incomplete."""
        if self.birth is None or self.height_cm is None or self.sex is None:
            return None
        return Biometrics(
            weight_kg=weight_kg,
            height_cm=self.height_cm,
            age_years=age_on(date.fromisoformat(self.birth), today),
            is_male=self.sex == "m",
        )


@dataclass(frozen=True)
class WeightCandidate:
    """A weigh-in offered for the log, applied only if it is newer."""

    day: str
    kg: float
    src: str
    t: str


def age_on(birth: date, today: date) -> int:
    """Completed years between ``birth`` and ``today``."""
    before_birthday = (today.month, today.day) < (birth.month, birth.day)
    return today.year - birth.year - int(before_birthday)


def now_stamp() -> str:
    """The current local time as the ISO edit stamp every write carries."""
    return datetime.now(tz=UTC).astimezone().isoformat(timespec="seconds")


def stamp_ms(stamp: object) -> int:
    """Epoch milliseconds of an edit stamp; unparsable -> 0 (the epoch)."""
    try:
        moment = datetime.fromisoformat(str(stamp))
    except ValueError:
        return 0
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    return int((moment - _EPOCH).total_seconds() * 1000)


def read_body() -> dict[str, dict[str, object]]:
    """The raw document, normalised to its three sections; never raises."""
    try:
        raw = json.loads(BODY_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raw = {}
    except (OSError, ValueError) as exc:
        _logger.warning(
            "Unreadable body file %s (%s); treating as empty", BODY_FILE, exc
        )
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    return {
        section: value if isinstance(value := raw.get(section), dict) else {}
        for section in SECTIONS
    }


def write_body(doc: dict[str, dict[str, object]]) -> None:
    """Persist ``doc`` atomically enough for a single-writer local file."""
    BODY_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload = {"v": _FILE_VERSION, **doc}
    tmp = BODY_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=1, sort_keys=True), encoding="utf-8")
    tmp.replace(BODY_FILE)


def _field(doc: dict[str, dict[str, object]], name: str) -> object:
    """A profile field's value, or None when missing/malformed."""
    cell = doc["profile"].get(name)
    return cell.get("v") if isinstance(cell, dict) else None


def as_number(value: object) -> float | None:
    """``value`` as a float when it is a real (non-bool) number, else None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def profile() -> Profile:
    """The stored profile, with malformed fields read as unset."""
    doc = read_body()
    birth, height, sex = (_field(doc, name) for name in PROFILE_FIELDS)
    try:
        date.fromisoformat(str(birth))
    except ValueError:
        birth = None
    height_cm = as_number(height)
    return Profile(
        birth=birth if isinstance(birth, str) else None,
        height_cm=height_cm if height_cm is not None and height_cm > 0 else None,
        sex=sex if sex in {"m", "f"} else None,
    )


def set_profile(**fields: object) -> None:
    """Set any of ``birth``/``height_cm``/``sex``, each stamped now."""
    doc = read_body()
    stamp = now_stamp()
    for name, value in fields.items():
        doc["profile"][name] = {"v": value, "t": stamp}
    write_body(doc)


def _kg(cell: object) -> float | None:
    """A weight cell's kg, or None for a tombstone/malformed cell."""
    return as_number(cell.get("kg")) if isinstance(cell, dict) else None


def is_day(key: str) -> bool:
    """Whether ``key`` is a ``YYYY-MM-DD`` date (a peer could send anything)."""
    try:
        date.fromisoformat(key)
    except ValueError:
        return False
    return True


def weights() -> dict[str, float]:
    """``YYYY-MM-DD`` -> kg for every live (non-deleted) day, oldest first."""
    live = {day: _kg(cell) for day, cell in read_body()["weights"].items()}
    return {
        day: kg for day, kg in sorted(live.items()) if kg is not None and is_day(day)
    }


def newest_weight() -> tuple[str, float] | None:
    """The latest-dated live weigh-in, or None when the log is empty."""
    live = weights()
    if not live:
        return None
    day = max(live)
    return day, live[day]


def set_weight(day: str, kg: float | None, src: str = "manual") -> None:
    """Record (or, with ``kg=None``, delete) ``day``'s weight, stamped now."""
    doc = read_body()
    value = None if kg is None else round(float(kg), 2)
    doc["weights"][day] = {"kg": value, "src": src, "t": now_stamp()}
    write_body(doc)


def apply_weight_candidates(candidates: list[WeightCandidate]) -> int:
    """Apply each candidate whose day is missing or older; return the count."""
    doc = read_body()
    applied = 0
    for cand in candidates:
        current = doc["weights"].get(cand.day)
        current_t = current.get("t") if isinstance(current, dict) else None
        if current is not None and stamp_ms(current_t) >= stamp_ms(cand.t):
            continue
        doc["weights"][cand.day] = {"kg": cand.kg, "src": cand.src, "t": cand.t}
        applied += 1
    if applied:
        write_body(doc)
    return applied
