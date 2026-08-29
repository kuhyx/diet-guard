"""Make it impossible for a test to write to real user state.

``diet_guard/tests/conftest.py`` redirects every known state path into
``tmp_path``, but that only protects tests that *load that conftest*.  On
2026-07-26 a throwaway test written into a scratch directory ran outside it,
wrote to the real ``~/.config/diet_guard/sync_token``, and destroyed the
user's GitHub PAT; the same session also created stray files under
``~/.local/share/diet_guard/``.

A redirect is a convention -- something a new test can forget or sidestep.
This is a guard: while pytest is in the process, any ``pathlib.Path`` write
under the real diet_guard data or config directory raises immediately,
whatever conftest is or is not in play, and whatever module forgot to be
patched.  Reads are left alone, so a test may still assert that a real path
is absent.

Scope, honestly: it covers ``pathlib.Path`` -- which is what every diet_guard
writer uses -- not builtin ``open()``, ``os.replace`` or ``shutil``.  It is a
hardened barrier across the paths this codebase actually takes, not a
kernel-level sandbox.

Inert outside pytest: production never imports pytest, so the single
``sys.modules`` check below is the whole cost.
"""

from __future__ import annotations

import pathlib
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable


def _resolved(path: pathlib.Path) -> pathlib.Path:
    """Resolve ``path`` as far as the filesystem allows, never raising."""
    try:
        return path.expanduser().resolve()
    except OSError, RuntimeError, ValueError:
        return path


# Resolved once, from the real home -- deliberately NOT from _constants, whose
# values a test may legitimately have patched to a temp path.  Resolving here
# matters: the candidate paths are resolved too, so if $HOME (or .local, or
# .local/share) is a symlink an unresolved root would never match and the
# guard would silently fail *open* -- the worst possible failure for a safety
# net.
_PROTECTED = (
    _resolved(pathlib.Path.home() / ".local" / "share" / "diet_guard"),
    _resolved(pathlib.Path.home() / ".config" / "diet_guard"),
)


class RealUserStateWriteError(RuntimeError):
    """Raised when a test tries to write to the user's real diet_guard state."""

    def __init__(self, path: pathlib.Path) -> None:
        """Name the offending path and how to fix the test."""
        super().__init__(
            f"test tried to write real user state at {path}. Point the relevant "
            "path at tmp_path (see diet_guard/tests/conftest.py's "
            "_isolate_state) instead of writing the real file.",
        )


def _is_protected(path: pathlib.Path) -> bool:
    """Return True if ``path`` lies inside a real user-state directory."""
    resolved = _resolved(pathlib.Path(path))
    return any(resolved.is_relative_to(root) for root in _PROTECTED)


# Marks an already-wrapped method, so installing twice is a no-op without
# needing module-level mutable state.
_MARKER = "_diet_guard_write_guarded"


def _guard(name: str, is_write: Callable[..., bool]) -> None:
    """Wrap ``pathlib.Path.<name>`` so protected writes raise.

    Idempotent per method: a second call finds the marker and returns, so the
    wrapper can never be stacked on itself.
    """
    original = getattr(pathlib.Path, name)
    if getattr(original, _MARKER, False):
        return

    def wrapper(self: pathlib.Path, *args: object, **kwargs: object) -> object:
        if is_write(*args, **kwargs) and _is_protected(self):
            raise RealUserStateWriteError(self)
        return original(self, *args, **kwargs)

    wrapper.__name__ = name
    setattr(wrapper, _MARKER, True)
    setattr(pathlib.Path, name, wrapper)


def install() -> None:
    """Install the guard, but only when running under pytest.

    Safe to call repeatedly: each :func:`_guard` is individually idempotent.
    """
    if "pytest" not in sys.modules:
        return
    _guard("open", lambda mode="r", *_a, **_k: any(c in mode for c in "wxa+"))
    # ``mkdir`` is guarded too: creating the real state directory is half of
    # what the 2026-07-26 accident did, and every writer calls it first.
    for name in ("write_text", "write_bytes", "unlink", "rename", "replace", "mkdir"):
        _guard(name, lambda *_a, **_k: True)
