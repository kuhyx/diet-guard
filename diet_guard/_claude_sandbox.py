"""The isolated Claude config dir the meal estimator runs in.

kuhy's own ``~/.claude`` stays outside: its hooks and rules make the model
answer with a grilling round instead of JSON, and its credentials file also
holds a refresh token and every MCP server's OAuth tokens. The sandbox holds
exactly two things: a copy of the Claude access token (no refresh token, so
the CLI inside never refreshes and never rotates kuhy's own login out) and the
``diet-food`` skill. Same approach as ``~/src/tutor/tutor/model_login.py``.

``CLAUDE_CONFIG_DIR`` is set only in the model call's own ``env`` (see
:mod:`diet_guard._claude_sdk`), never in this process: ``HOST_LOGIN_FILE``
must keep naming kuhy's real login.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    from collections.abc import Callable

_logger = logging.getLogger(__name__)

#: Scratch config dir (``CLAUDE_CONFIG_DIR``); cache, not the synced data dir.
SANDBOX_DIR: Path = Path.home() / ".cache" / "diet_guard" / "claude-sandbox"
#: kuhy's own CLI login: read to copy the access token, never written.
HOST_LOGIN_FILE: Path = Path.home() / ".claude" / ".credentials.json"
#: The skill shipped in the repo (an editable install runs the working tree).
SKILL_DIR: Final = Path(__file__).resolve().parent.parent / "skills" / "diet-food"

#: The CLI refreshes its token within 5 minutes of expiry.
REFRESH_MARGIN_MS: Final = 300_000
_REFRESH_TIMEOUT_S: Final = 40
_LOGIN_NAME: Final = ".credentials.json"


def skill_text() -> str:
    """The ``SKILL.md`` body without its front matter (the system prompt)."""
    text = SKILL_DIR.joinpath("SKILL.md").read_text(encoding="utf-8")
    if text.startswith("---\n"):
        _, _, text = text[4:].partition("\n---\n")
    return text.strip()


def host_cli() -> Path | None:
    """The ``claude`` binary kuhy's login is refreshed with, if any."""
    found = shutil.which("claude")
    return Path(found) if found else None


def copy_login() -> int | None:
    """Copy the host's access token into the sandbox; its expiry in ms.

    Only ``claudeAiOauth`` minus ``refreshToken`` is written (0600, atomic).
    No readable host login writes nothing and returns None.
    """
    try:
        raw = json.loads(HOST_LOGIN_FILE.read_text(encoding="utf-8"))
        oauth = dict(raw["claudeAiOauth"])
    except (OSError, ValueError, KeyError, TypeError) as err:
        _logger.warning("no host Claude login to copy: %r", err)
        return None
    oauth.pop("refreshToken", None)
    SANDBOX_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=SANDBOX_DIR, prefix=".credentials.")
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump({"claudeAiOauth": oauth}, out)
    Path(tmp).replace(SANDBOX_DIR / _LOGIN_NAME)
    expires = oauth.get("expiresAt")
    return int(expires) if isinstance(expires, (int, float)) else None


def refresh_host_login() -> None:
    """Let kuhy's own CLI refresh his login: one tiny call, nothing loaded."""
    cli = host_cli()
    if cli is None:
        return
    cmd = [
        str(cli),
        "-p",
        "Reply with OK.",
        "--tools=",
        "--setting-sources=",
        "--strict-mcp-config",
        "--max-turns=1",
        "--no-session-persistence",
    ]
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    work = SANDBOX_DIR / "refresh"
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        cmd,
        cwd=work,
        env=env,
        check=True,
        capture_output=True,
        timeout=_REFRESH_TIMEOUT_S,
    )


def install_skill() -> None:
    """Copy the ``diet-food`` skill into the sandbox's ``skills/`` dir."""
    target = SANDBOX_DIR / "skills" / SKILL_DIR.name
    target.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SKILL_DIR / "SKILL.md", target / "SKILL.md")


def prepare(
    now: Callable[[], float] = time.time,
    refresh: Callable[[], None] = refresh_host_login,
) -> Path | None:
    """Make the sandbox ready; its path, or None when there is no login.

    A login about to expire is refreshed on the host first. Never raises on a
    refresh failure: the model call then reports the CLI's own error and the
    request fails closed as ``estimate_failed``.
    """
    expires = copy_login()
    if expires is None:
        return None
    if expires - now() * 1000 <= REFRESH_MARGIN_MS:
        try:
            refresh()
        except (OSError, subprocess.SubprocessError) as err:
            _logger.warning("could not refresh the Claude login: %r", err)
        else:
            copy_login()
    install_skill()
    (SANDBOX_DIR / "work").mkdir(exist_ok=True)
    return SANDBOX_DIR
