"""Tests for which backend a sync tick runs against.

Split out of ``test_sync.py`` to keep both files under the repo's 500-line
cap. Covers the Firebase/GitHub cutover seam (``_remote_client``) and which
credentials a run actually requires (``_client_for_run``).
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from crdt_sync import ConfigError
import pytest

from diet_guard import _sync, _sync_client


class TestRemoteClient:
    """Which backend a sync tick runs against during the cutover."""

    def test_stays_on_github_without_firebase_config(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """An unconfigured machine must not reach the network at all."""
        monkeypatch.setattr(
            _sync_client, "CONFIG_FILE", Path("/nonexistent/firebase.json")
        )
        github = object()

        assert _sync_client._remote_client(github) is github

    def test_mirrors_to_github_when_configured(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Configured: Firebase is primary, GitHub keeps receiving writes."""
        config = tmp_path / "firebase.json"
        config.write_text("{}", encoding="utf-8")
        monkeypatch.setattr(_sync_client, "CONFIG_FILE", config)
        monkeypatch.setattr(
            _sync_client, "mirror_client_for", lambda _app, client: ("mirror", client)
        )
        github = object()

        assert _sync_client._remote_client(github) == ("mirror", github)

    def test_falls_back_when_firebase_is_unusable(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A broken Firebase must degrade to GitHub, never fail the tick."""
        config = tmp_path / "firebase.json"
        config.write_text("{}", encoding="utf-8")
        monkeypatch.setattr(_sync_client, "CONFIG_FILE", config)

        def _boom(*_args: object, **_kwargs: object) -> None:
            message = "no password"
            raise ConfigError(message)

        monkeypatch.setattr(_sync_client, "mirror_client_for", _boom)
        github = object()

        assert _sync_client._remote_client(github) is github


class TestClientForRun:
    """Which credentials a run actually requires."""

    def test_syncs_without_a_pat_when_firebase_is_configured(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A Firebase-only machine must sync, not fail for a missing PAT.

        Requiring the token before ever constructing Firebase left the Python
        half unable to sync at all on a device that had moved to Firebase --
        the "Firebase-only device" fix had only ever touched the Dart side.
        """
        config = tmp_path / "firebase.json"
        config.write_text("{}", encoding="utf-8")
        monkeypatch.setattr(_sync_client, "CONFIG_FILE", config)
        monkeypatch.setattr(
            _sync_client, "SYNC_TOKEN_FILE", tmp_path / "absent_sync_token"
        )
        monkeypatch.setattr(
            _sync_client, "firebase_client_for", lambda app: ("firebase", app)
        )

        assert _sync_client._client_for_run() == ("firebase", "diet_guard")

    def test_unusable_firebase_config_becomes_a_sync_error(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """An unusable Firebase config must fail *closed*, not raise.

        ``ConfigError`` subclasses ``Exception`` directly, not
        ``RemoteSyncError``, so letting it out of here escapes every caller's
        catch tuple and raises a traceback out of the gate's fail-closed
        "Fetch from sync" button -- reintroducing, by a different exception,
        exactly the failure the ``RemoteSyncError`` swap was made to stop.
        This branch is reached precisely when the config file exists but is
        unusable and no PAT is present.
        """
        config = tmp_path / "firebase.json"
        config.write_text("{}", encoding="utf-8")
        monkeypatch.setattr(_sync_client, "CONFIG_FILE", config)
        monkeypatch.setattr(_sync_client, "SYNC_TOKEN_FILE", tmp_path / "absent_token")

        def _boom(*_args: object, **_kwargs: object) -> None:
            message = "no password"
            raise ConfigError(message)

        monkeypatch.setattr(_sync_client, "firebase_client_for", _boom)

        with pytest.raises(_sync.SyncError):
            _sync_client._client_for_run()

    def test_still_fails_when_neither_backend_is_configured(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """No PAT *and* no Firebase is the genuine "nothing is set up" case."""
        monkeypatch.setattr(
            _sync_client, "CONFIG_FILE", tmp_path / "absent_firebase.json"
        )
        monkeypatch.setattr(
            _sync_client, "SYNC_TOKEN_FILE", tmp_path / "absent_sync_token"
        )

        with pytest.raises(_sync.SyncError):
            _sync_client._client_for_run()


class TestInteractiveTimeout:
    """The short per-request budget for paths the user is waiting on."""

    def test_tightens_every_backend_half(self) -> None:
        """A mirrored client must bound both halves, not just the primary."""
        client = SimpleNamespace(
            primary=SimpleNamespace(_timeout_seconds=15.0),
            mirror=SimpleNamespace(_timeout_seconds=10.0),
        )

        _sync_client._apply_timeout(client, 2.0)

        assert client.primary._timeout_seconds == 2.0
        assert client.mirror._timeout_seconds == 2.0

    def test_a_client_without_the_attribute_is_left_alone(self) -> None:
        """Never invent a setting on a backend that does not read one."""
        client = SimpleNamespace()

        _sync_client._apply_timeout(client, 2.0)

        assert not hasattr(client, "_timeout_seconds")

    def test_a_bare_client_is_tightened_directly(self) -> None:
        """Not every backend is mirrored; the unwrapped case must work too."""
        client = SimpleNamespace(_timeout_seconds=15.0)

        _sync_client._apply_timeout(client, 2.0)

        assert client._timeout_seconds == 2.0
