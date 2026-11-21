"""scripts/test_changed.sh runs flutter like a CI-mirror shard does.

A bare ``flutter test`` on the shared /tmp stalled a 3-file run to 67 s under
the build queue (2026-11-21, perf.heavybuild) while the same files take ~4 s
alone; the shards fixed that with a private TMPDIR and two isolates, and the
targeted runner must do the same.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[2]
GIT = shutil.which("git") or "git"
BASH = shutil.which("bash") or "bash"
FAKE_FLUTTER = """#!/bin/bash
printf 'TMPDIR=%s\\n' "${TMPDIR:-}" >> "$FLUTTER_LOG"
printf 'ARGS=%s\\n' "$*" >> "$FLUTTER_LOG"
"""


def _shared_tmp(tmp_path: Path) -> Path:
    """Stand-in for the machine-wide /tmp the caller would pass down."""
    shared = tmp_path / "shared-tmp"
    shared.mkdir(exist_ok=True)
    return shared


def _git(cwd: Path, *args: str) -> None:
    subprocess.run([GIT, *args], cwd=cwd, check=True, capture_output=True)


def _run_test_changed(tmp_path: Path) -> dict[str, str]:
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    (repo / "app" / "test").mkdir(parents=True)
    shutil.copy(REPO / "scripts" / "test_changed.sh", repo / "scripts")
    _git(repo, "init", "-q")
    _git(
        repo,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "init",
    )
    (repo / "app" / "test" / "a_test.dart").write_text("void main() {}\n")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "flutter"
    fake.write_text(FAKE_FLUTTER)
    fake.chmod(0o755)
    log = tmp_path / "flutter.log"
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "FLUTTER_LOG": str(log),
        "TMPDIR": str(_shared_tmp(tmp_path)),
    }
    subprocess.run(
        [BASH, "scripts/test_changed.sh"],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
    )
    return dict(line.split("=", 1) for line in log.read_text().splitlines())


def test_flutter_gets_a_private_tmpdir_that_is_removed(tmp_path: Path) -> None:
    seen = _run_test_changed(tmp_path)
    assert seen["TMPDIR"] not in {"", str(_shared_tmp(tmp_path))}
    assert not Path(seen["TMPDIR"]).exists()


def test_flutter_runs_two_isolates_on_the_changed_file(tmp_path: Path) -> None:
    seen = _run_test_changed(tmp_path)
    assert "--concurrency=2" in seen["ARGS"]
    assert "test/a_test.dart" in seen["ARGS"]
