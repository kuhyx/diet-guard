"""CLI contract of ``scripts/check_patch_targets.py``: the package is an argument.

Other guard repos adopt the script by copying it into their own ``scripts/``,
so each case copies it into a scratch repo next to a scratch package and runs
it there as a subprocess -- the same shape an adopter gets. ``scripts/`` sits
outside coverage ``source``, so the subprocess run is the whole check.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_patch_targets.py"

GOOD = 'from unittest import mock\nmock.patch("pkg_a.mod.VALUE", 1)\n'
STALE = 'from unittest import mock\nmock.patch("pkg_a.mod.GONE", 1)\n'


def _run(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    """Run the script with ``args`` from ``cwd``, as the pre-commit hook does."""
    return subprocess.run(
        [sys.executable, str(cwd / "scripts" / SCRIPT.name), *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )


def _scratch_repo(tmp_path: Path, test_source: str, tests_dir: str) -> Path:
    """A repo with ``scripts/``, package ``pkg_a`` and one test file."""
    (tmp_path / "scripts").mkdir()
    shutil.copy(SCRIPT, tmp_path / "scripts" / SCRIPT.name)
    pkg = tmp_path / "pkg_a"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    (pkg / "mod.py").write_text("VALUE = 0\n")
    tests = tmp_path / tests_dir
    tests.mkdir(parents=True, exist_ok=True)
    (tests / "test_x.py").write_text(test_source)
    return tmp_path


def test_missing_package_argument_is_a_usage_error(tmp_path: Path) -> None:
    """No silent default: a bare run fails loudly instead of checking nothing."""
    repo = _scratch_repo(tmp_path, GOOD, "pkg_a/tests")
    result = _run(repo)
    assert result.returncode == 2
    assert "usage:" in result.stderr
    assert "package" in result.stderr


def test_good_target_in_named_package_passes(tmp_path: Path) -> None:
    """A resolvable target in ``<package>/tests`` exits 0 silently."""
    repo = _scratch_repo(tmp_path, GOOD, "pkg_a/tests")
    result = _run(repo, "pkg_a")
    assert (result.returncode, result.stderr) == (0, "")


def test_stale_target_in_named_package_fails(tmp_path: Path) -> None:
    """A target that no longer resolves names its file and line, and exits 1."""
    repo = _scratch_repo(tmp_path, STALE, "pkg_a/tests")
    result = _run(repo, "pkg_a")
    assert result.returncode == 1
    assert (
        "pkg_a/tests/test_x.py:2: patch target does not resolve: pkg_a.mod.GONE"
        in result.stderr
    )


def test_tests_root_override_is_the_directory_checked(tmp_path: Path) -> None:
    """``--tests-root`` replaces ``<package>/tests``, which may then not exist."""
    repo = _scratch_repo(tmp_path, STALE, "elsewhere")
    assert _run(repo, "pkg_a").returncode == 1  # default root is missing
    result = _run(repo, "pkg_a", "--tests-root", "elsewhere")
    assert result.returncode == 1
    assert "elsewhere/test_x.py:2:" in result.stderr


def test_real_tree_passes_with_diet_guard_argument() -> None:
    """The hook's own invocation is green on this repo."""
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "diet_guard"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert (result.returncode, result.stderr) == (0, "")


def test_sibling_prefix_package_is_not_checked(tmp_path: Path) -> None:
    """``pkg_a`` does not own ``pkg_ab``: a bare string prefix is not a package."""
    other = 'from unittest import mock\nmock.patch("pkg_ab.mod.GONE", 1)\n'
    repo = _scratch_repo(tmp_path, other, "pkg_a/tests")
    result = _run(repo, "pkg_a")
    assert (result.returncode, result.stderr) == (0, "")
