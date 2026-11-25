"""Helpers shared by the verification tests."""

import shutil
import subprocess
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parent
PROFILE = REPO_ROOT / "iso-profiles" / "manjaro" / "local-host"
QML_DIR = PROFILE / "live-overlay" / "usr" / "local" / "share" / "local-host"


def run(*cmd, check=True, env=None, timeout=None):
    """Run a command and return the completed process.

    On failure, raise AssertionError with the command, exit code and output, so
    a failing check always names the tool and what it said.
    """
    argv = [str(part) for part in cmd]
    result = subprocess.run(
        argv, capture_output=True, text=True, env=env, timeout=timeout
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"command failed: {' '.join(argv)}\n"
            f"exit: {result.returncode}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result


def require(*names):
    """Skip the current test when one of the named tools is not installed."""
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        import pytest

        pytest.skip("not installed: " + ", ".join(missing))


def shell_scripts(root: Path):
    """Yield shell scripts below root, detected by their shebang."""
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        try:
            with path.open(encoding="utf-8", errors="replace") as handle:
                first = handle.readline()
        except OSError:
            continue
        if first.startswith("#!") and "sh" in first:
            yield path
