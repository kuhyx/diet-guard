"""The model call and its sandbox, against a fake ``claude_agent_sdk``."""

from __future__ import annotations

import asyncio
import json
import subprocess
from typing import TYPE_CHECKING, Any
from unittest.mock import AsyncMock, Mock, patch

import pytest

from diet_guard import _claude_sandbox as sandbox
from diet_guard import _claude_sdk as sdk
from diet_guard.tests._claude_fakes import (
    FakeResult,
    FakeSdk,
    fresh,
    write_host_login,
)

if TYPE_CHECKING:
    from pathlib import Path

FAR = 4_000_000_000_000  # an expiry far in the future, in ms


@pytest.fixture
def login() -> None:
    """A readable host login that is not about to expire."""
    write_host_login(sandbox.HOST_LOGIN_FILE, FAR)


def _ask(fake: FakeSdk, budget_s: float = 5) -> dict[str, Any]:
    content = [{"type": "text", "text": "banan"}]
    with patch("diet_guard._claude_sdk.import_module", return_value=fake):
        return asyncio.run(
            sdk.bounded_ask("PROMPT", content, {"s": 1}, budget_s=budget_s)
        )


@pytest.mark.usefixtures("login")
def test_answer_and_isolation_options() -> None:
    """The structured answer returns; the call is tool-less and sandboxed."""
    fake = FakeSdk([FakeResult({"kcal": 1})])
    assert _ask(fake) == {"kcal": 1}
    options = fake.calls[0]["options"]
    assert options.tools == []
    assert options.mcp_servers == {}
    assert options.setting_sources == []
    assert options.system_prompt == "PROMPT"
    assert options.output_format == {"type": "json_schema", "schema": {"s": 1}}
    assert options.env["CLAUDE_CONFIG_DIR"] == str(sandbox.SANDBOX_DIR)
    assert options.cwd == sandbox.SANDBOX_DIR / "work"
    message = fake.calls[0]["sent"][0]["message"]
    assert message["content"] == [{"type": "text", "text": "banan"}]


@pytest.mark.usefixtures("login")
def test_other_stream_messages_are_skipped() -> None:
    """Assistant/system chatter before the result does not matter."""
    fake = FakeSdk([object(), FakeResult({"kcal": 2}), object()])
    assert _ask(fake) == {"kcal": 2}


@pytest.mark.usefixtures("login")
@pytest.mark.parametrize(
    "messages",
    [
        [FakeResult(None, is_error=True)],
        [FakeResult(None)],
        [FakeResult(["not", "an", "object"])],
        [],
    ],
)
def test_no_usable_answer_is_a_model_error(messages: list[object]) -> None:
    """An API error or an answer that is not an object fails closed."""
    with pytest.raises(sdk.ModelError):
        _ask(FakeSdk(messages))


def test_missing_login_is_a_model_error() -> None:
    """No host login: nothing is sent to the model at all."""
    fake = FakeSdk([FakeResult({"kcal": 1})])
    with pytest.raises(sdk.ModelError, match="no Claude login"):
        _ask(fake)
    assert fake.calls == []


@pytest.mark.usefixtures("login")
def test_a_hung_model_times_out() -> None:
    """A call past its budget is a ModelTimeoutError."""
    with pytest.raises(sdk.ModelTimeoutError):
        _ask(FakeSdk([], hang=True), budget_s=0.05)


@pytest.mark.usefixtures("login")
def test_any_other_failure_is_wrapped() -> None:
    """A CLI/transport exception becomes a ModelError naming only its type."""
    fake = FakeSdk([])
    fake.query = Mock(side_effect=OSError("secret path"))
    with pytest.raises(sdk.ModelError, match="OSError") as caught:
        _ask(fake)
    assert "secret path" not in str(caught.value)


def test_run_model_delegates_to_bounded_ask() -> None:
    """The seam is a thin wrapper: same arguments, same result."""
    real = fresh(sdk)
    with patch.object(real, "bounded_ask", AsyncMock(return_value={"ok": 1})) as ask:
        out = asyncio.run(real.run_model("p", [], {}, budget_s=3))
    assert out == {"ok": 1}
    ask.assert_awaited_once_with("p", [], {}, budget_s=3)


# -- the sandbox ---------------------------------------------------------------
def test_login_copy_drops_the_refresh_token_and_mcp_tokens(login: None) -> None:
    """Only claudeAiOauth minus refreshToken reaches the sandbox, mode 0600."""
    assert sandbox.copy_login() == FAR
    target = sandbox.SANDBOX_DIR / ".credentials.json"
    text = target.read_text(encoding="utf-8")
    assert "SECRET" not in text
    assert json.loads(text) == {
        "claudeAiOauth": {"accessToken": "tok", "expiresAt": FAR}
    }
    assert target.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("raw", [None, "not json", "{}", '{"claudeAiOauth": 3}'])
def test_unreadable_host_login_copies_nothing(raw: str | None) -> None:
    """A missing, broken or empty login writes nothing and reports None."""
    if raw is not None:
        sandbox.HOST_LOGIN_FILE.write_text(raw, encoding="utf-8")
    assert sandbox.copy_login() is None
    assert not sandbox.SANDBOX_DIR.exists()


def test_expiry_missing_is_none_but_copied() -> None:
    """A login without expiresAt is copied; its expiry is unknown."""
    sandbox.HOST_LOGIN_FILE.write_text(
        json.dumps({"claudeAiOauth": {"accessToken": "t"}}), encoding="utf-8"
    )
    assert sandbox.copy_login() is None
    assert (sandbox.SANDBOX_DIR / ".credentials.json").is_file()


def test_prepare_installs_the_skill_and_work_dir(login: None) -> None:
    """A fresh login: no refresh, skill copied, work dir ready."""
    refresh = Mock()
    assert sandbox.prepare(refresh=refresh) == sandbox.SANDBOX_DIR
    refresh.assert_not_called()
    skill = sandbox.SANDBOX_DIR / "skills" / "diet-food" / "SKILL.md"
    assert skill.read_text(encoding="utf-8").startswith("---\nname: diet-food")
    assert (sandbox.SANDBOX_DIR / "work").is_dir()


def test_prepare_without_login_is_none() -> None:
    """No host login: no sandbox."""
    assert sandbox.prepare() is None


def test_prepare_refreshes_an_expiring_login_then_recopies() -> None:
    """Within the margin the host CLI refreshes first; the new token is copied."""
    write_host_login(sandbox.HOST_LOGIN_FILE, 1_000)
    refresh = Mock(side_effect=lambda: write_host_login(sandbox.HOST_LOGIN_FILE, FAR))
    assert sandbox.prepare(now=lambda: 1.0, refresh=refresh) == sandbox.SANDBOX_DIR
    refresh.assert_called_once_with()
    fresh_login = json.loads((sandbox.SANDBOX_DIR / ".credentials.json").read_text())
    assert fresh_login["claudeAiOauth"]["expiresAt"] == FAR


def test_failed_refresh_is_logged_and_the_old_copy_stays() -> None:
    """A refresh that fails does not raise; the call then fails in the CLI."""
    write_host_login(sandbox.HOST_LOGIN_FILE, 1_000)
    refresh = Mock(side_effect=subprocess.SubprocessError("nope"))
    assert sandbox.prepare(now=lambda: 1.0, refresh=refresh) == sandbox.SANDBOX_DIR


def test_refresh_host_login_runs_the_host_cli_with_nothing_loaded() -> None:
    """The refresh is one tiny, tool-less, settings-less CLI call."""
    with (
        patch(
            "diet_guard._claude_sandbox.host_cli",
            return_value=sandbox.Path("/x/claude"),
        ),
        patch("diet_guard._claude_sandbox.subprocess.run") as run,
    ):
        sandbox.refresh_host_login()
    cmd = run.call_args.args[0]
    assert cmd[0] == "/x/claude"
    assert "--setting-sources=" in cmd
    assert "--tools=" in cmd
    assert run.call_args.kwargs["cwd"] == sandbox.SANDBOX_DIR / "refresh"


def test_refresh_without_a_host_cli_is_a_noop() -> None:
    """No claude binary on PATH: nothing to refresh with, nothing raised."""
    with (
        patch("diet_guard._claude_sandbox.host_cli", return_value=None),
        patch("diet_guard._claude_sandbox.subprocess.run") as run,
    ):
        sandbox.refresh_host_login()
    run.assert_not_called()


def test_host_cli_follows_path() -> None:
    """host_cli is whatever ``claude`` resolves to, or None."""
    with patch("diet_guard._claude_sandbox.shutil.which", return_value="/bin/claude"):
        assert str(sandbox.host_cli()) == "/bin/claude"
    with patch("diet_guard._claude_sandbox.shutil.which", return_value=None):
        assert sandbox.host_cli() is None


def test_skill_text_without_front_matter(tmp_path: Path) -> None:
    """A skill file with no front matter is returned whole."""
    skill = tmp_path / "SKILL.md"
    skill.write_text("body only\n", encoding="utf-8")
    with patch("diet_guard._claude_sandbox.SKILL_DIR", tmp_path):
        assert sandbox.skill_text() == "body only"
