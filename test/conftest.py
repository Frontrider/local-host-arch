"""Fixtures for the verification tests."""

import os
from pathlib import Path

import pytest

from support import PROFILE, REPO_ROOT, require, run


def pytest_addoption(parser):
    parser.addoption(
        "--iso",
        action="store",
        default=os.environ.get("ISO"),
        help="ISO file to verify (default: newest under out/)",
    )


def newest_iso():
    isos = sorted(
        (REPO_ROOT / "out").glob("**/*.iso"), key=lambda path: path.stat().st_mtime
    )
    return isos[-1] if isos else None


@pytest.fixture(scope="session")
def iso(request):
    value = request.config.getoption("--iso")
    path = Path(value) if value else newest_iso()
    if path is None:
        pytest.fail(f"no ISO given and none found under {REPO_ROOT / 'out'}")
    if not path.is_file():
        pytest.fail(f"ISO not found: {path}")
    return path


@pytest.fixture(scope="session")
def work(iso, tmp_path_factory):
    """Unpack the parts of the ISO that the checks read."""
    require("bsdtar", "unsquashfs")

    work = tmp_path_factory.mktemp("iso")

    members = ["boot", "manjaro/x86_64/livefs.sfs"]
    if (PROFILE / "desktop-overlay").is_dir():
        members.append("manjaro/x86_64/desktopfs.sfs")
    if (PROFILE / "root-overlay").is_dir():
        members.append("manjaro/x86_64/rootfs.sfs")

    run("bsdtar", "-xf", iso, "-C", work, *members)
    # Docker denies trusted.* xattrs without CAP_SYS_ADMIN; the checks only
    # read text files, so skipping xattrs changes nothing.
    run(
        "unsquashfs",
        "-q",
        "-no-xattrs",
        "-d",
        work / "livefs",
        work / "manjaro/x86_64/livefs.sfs",
    )
    return work
