"""Wall-clock helpers shared by every adapter in this package.

All three adapter modules derive an ``Hlc`` from some ISO timestamp -- an
entry's birth ``time``, a budget's ``t`` edit stamp, a curated food's
``editedAt``. They therefore share one parsing rule, and it lives here rather
than in whichever module happened to be written first: a second copy is how
two adapters start disagreeing about what an unparsable stamp means, which
would silently change merge outcomes rather than raising.
"""

from __future__ import annotations

from datetime import datetime, timezone

_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def _wall_time_ms(stamp: str) -> int:
    """Return ``stamp``'s epoch milliseconds, or the epoch when unparsable.

    Falling back to the epoch rather than raising keeps a malformed stamp from
    dropping the record entirely: it sorts early in a last-writer-wins merge,
    so a well-formed copy from any other device wins, which is the outcome the
    user wants.
    """
    try:
        moment = datetime.fromisoformat(stamp)
    except ValueError:
        moment = _EPOCH
    return int(moment.timestamp() * 1000)
