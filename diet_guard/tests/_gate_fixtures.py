"""Fixtures that keep the gate's Tk widgets fake and its outputs hermetic.

Split out of ``conftest.py`` for file size, and imported back into it by name
-- pytest only discovers fixtures defined *or imported* in a conftest, and
``pytest_plugins`` is an error in a non-root conftest, so the import in
``conftest.py`` is what registers these. Do not "tidy" it away.

Every module that builds gate widgets is patched as one set: hand-picking a
subset is how a test ends up mixing a real ``tk.Frame`` into a fake notebook,
which fails far from the cause.
"""

from __future__ import annotations

from contextlib import ExitStack, contextmanager
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

from gatelock import Output, OutputRect
from gatelock import _scrollable as _gatelock_scrollable
from gatelock import widgets as _gatelock_widgets
import pytest

from diet_guard import (
    _gatelock,
    _gatelock_calendar,
    _gatelock_calendar_ui,
    _gatelock_core,
    _gatelock_mealflow,
    _gatelock_nutrition,
    _gatelock_ui,
)
from diet_guard._gatelock import MealGate
from diet_guard.tests._tk_fakes import (
    _FAKE_TK,
    _FAKE_TTK,
)

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path


@pytest.fixture(autouse=True)
def _block_real_tk() -> Iterator[None]:
    """Replace tk + the window class in _gatelock so no real window can open."""
    with (
        patch("diet_guard._gatelock.tk", MagicMock()),
        patch("diet_guard._gatelock.GateRoot", MagicMock()),
    ):
        yield


FAKE_OUTPUTS = (
    Output("DP-0", connected=True, rect=OutputRect(0, 0, 1920, 1080), primary=True),
)
"""One live output by default, so the Tk-screen fallback (which would call
int() on a MagicMock) is never reached."""

TWO_OUTPUTS = (
    Output("DP-0", connected=True, rect=OutputRect(0, 0, 3840, 2160), primary=True),
    Output("HDMI-0", connected=True, rect=OutputRect(3840, 0, 2560, 1440)),
)
"""The real desk. Opt in with ``dual_output`` for anything asserting that the
gate is really built on every monitor."""


def _make_toplevel(_parent: object = None, **_kwargs: object) -> MagicMock:
    """A Toplevel stand-in for gatelock's per-output surfaces."""
    window = MagicMock()
    window.winfo_children.return_value = []
    return window


@pytest.fixture(autouse=True)
def _hermetic_gatelock(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> Iterator[None]:
    """Keep gatelock v0.2.0's per-output machinery off the real machine.

    ``_block_real_tk`` patches ``tk`` inside *diet_guard*, which is no longer
    enough: ``LockWindow.setup()`` builds one real ``tk.Toplevel`` per live
    output through *gatelock's* own ``tk``. Over a MagicMock root that sends
    real tkinter into unbounded mock recursion, so the suite **hangs** rather
    than failing. The runtime dir is redirected too, so no test can stand a
    production locker down through the arbiter.
    """
    monkeypatch.setenv("GATELOCK_RUNTIME_DIR", str(tmp_path / "gatelock-runtime"))
    with (
        patch("gatelock._surfaces.tk.Toplevel", side_effect=_make_toplevel),
        patch("gatelock._outputs.RandrBackend.create", return_value=None),
        patch("gatelock._outputs.scan_xrandr", return_value=FAKE_OUTPUTS),
        patch("gatelock._detect._RandrEventSource.start", return_value=False),
    ):
        yield


@pytest.fixture
def dual_output(_hermetic_gatelock: None) -> Iterator[None]:
    """Re-scan as a two-monitor desk, layered over the single-output default."""
    with patch("gatelock._outputs.scan_xrandr", return_value=TWO_OUTPUTS):
        yield


@pytest.fixture(autouse=True)
def _block_real_vt() -> Iterator[None]:
    """Make gatelock's VT-switch disable a no-op for every test.

    Belt-and-suspenders alongside ``_block_real_tk``: VT-disable now lives in
    ``gatelock``, independent of the (mocked) root, so a test that builds a
    real prod-mode (``demo_mode=False``) gate would otherwise run a genuine
    ``setxkbmap`` against whatever X session the test happens to run under.
    """
    with patch("gatelock._vt.shutil.which", return_value=None):
        yield


@pytest.fixture(autouse=True)
def _hmac_key(tmp_path: Path) -> Iterator[None]:
    """Point the shared HMAC key at a deterministic temp file.

    Makes signing/verification work the same in any environment (including CI,
    which has no ``/etc/workout-locker/hmac.key``).  Tests that need the
    no-key path patch ``compute_entry_hmac`` to return None locally.
    """
    key = tmp_path / "hmac.key"
    key.write_bytes(b"diet-guard-test-key-0123456789ab")
    with patch("gatelock.log_integrity.DEFAULT_HMAC_KEY_FILE", key):
        yield


# --------------------------------------------------------------------------
# Gate fixture and its functional tk fakes
# --------------------------------------------------------------------------
#
# A functional fake ``tk`` (stateful Entry/Text/Listbox/StringVar widgets and a
# real, catchable ``TclError``) replaces the blanket MagicMock above for the
# duration of each gate test, so the window's *logic* runs for real against
# in-memory widgets without ever opening a window or grabbing the keyboard.


_GATE_TK_MODULES = (
    _gatelock,
    # The gate's buttons are built by gatelock now, so its widget module
    # needs the fake tk too -- otherwise the gate tests open real windows.
    _gatelock_widgets,
    _gatelock_calendar,
    _gatelock_calendar_ui,
    _gatelock_core,
    _gatelock_nutrition,
    _gatelock_mealflow,
    _gatelock_ui,
    # The gate's scroll viewport lives in gatelock, not here, and imports
    # tkinter independently -- so it needs the fake too, or a real tk.Frame
    # ends up parented to a FakeNotebook.
    _gatelock_scrollable,
)


@contextmanager
def fake_tk() -> Iterator[None]:
    """Patch every module that builds gate widgets to use the fakes.

    Exposed so tests that construct a gate outside the :func:`gate` fixture
    patch the *same* set. Hand-picking a subset is how a test ends up mixing a
    real ``tk.Label`` with a fake parent: the widget tree spans several modules
    plus ``gatelock``, and any module left real will try to talk to a fake
    master.
    """
    with ExitStack() as stack:
        for module in _GATE_TK_MODULES:
            stack.enter_context(patch.object(module, "tk", _FAKE_TK))
        stack.enter_context(patch.object(_gatelock_calendar, "ttk", _FAKE_TTK))
        stack.enter_context(patch.object(_gatelock_calendar_ui, "ttk", _FAKE_TTK))
        yield


@pytest.fixture
def gate() -> Iterator[MealGate]:
    """Build a demo gate whose widgets are functional fakes."""
    with fake_tk():
        yield MealGate(demo_mode=True)
