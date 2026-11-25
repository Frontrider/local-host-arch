"""Checks that need the built ISO.

Run with:  pytest --iso path/to.iso test/test_iso.py
"""

import os
import shutil
from pathlib import Path

from support import PROFILE, TEST_DIR, require, run


def test_osinfo_detect(iso):
    require("osinfo-detect")

    run("osinfo-detect", iso)


def test_xmllint_branding(work):
    require("xmllint")

    files = [
        path
        for path in sorted(
            (work / "livefs/usr/share/calamares/branding").rglob("*")
        )
        if path.is_file() and path.suffix in (".ts", ".xml")
    ]
    assert files, "no .ts or .xml files in the live Calamares branding"

    for path in files:
        run("xmllint", "--nonet", "--noout", path)


def test_grub_script_check(work):
    require("grub-script-check")

    files = sorted((work / "boot").rglob("*.cfg"))
    assert files, f"no GRUB configuration under {work / 'boot'}"

    for path in files:
        run("grub-script-check", path)


def test_overlay_files(work):
    require("unsquashfs", "cmp")

    run(
        "bash",
        TEST_DIR / "check-overlay-files.sh",
        work / "manjaro/x86_64",
        PROFILE,
    )


def test_systemd_analyze_cat_config(work):
    require("systemd-analyze")

    livefs = work / "livefs"
    for conf in ("systemd/system.conf", "systemd/logind.conf"):
        run("systemd-analyze", f"--root={livefs}", "cat-config", conf)


def test_systemd_analyze_verify(work):
    require("systemd-analyze")

    livefs = work / "livefs"
    units = sorted(
        path
        for path in (livefs / "etc/systemd/system").rglob("*")
        if path.is_file() and path.suffix in (".service", ".timer")
    )
    assert units, "no systemd units in the live filesystem"

    for unit in units:
        relative = unit.relative_to(livefs)
        result = run(
            "systemd-analyze",
            "--man=no",
            f"--root={livefs}",
            "verify",
            "/" + str(relative),
            check=False,
        )
        output = (result.stdout + result.stderr).strip()
        # livefs.sfs is one layer of the live system: rootfs.sfs and desktopfs.sfs
        # provide most of /usr/bin and /usr/local/bin. A missing ExecStart
        # binary is therefore expected here and says nothing about the unit.
        problems = [
            line
            for line in output.splitlines()
            if line.strip()
            and "is not executable" not in line
            and not line.strip().startswith("'(man)' failed")
        ]
        assert not problems, f"{relative}\n" + "\n".join(problems)


def test_calamares_load(work):
    require("calamares", "xvfb-run", "timeout")

    livefs = work / "livefs"
    settings = livefs / "etc/xdg/calamares/settings.conf"
    assert settings.is_file(), f"missing static Calamares settings: {settings}"

    # Put the ISO's configuration, pages and branding on top of the container
    # package, exactly as the live system has them.
    for source, target in (
        (livefs / "etc/calamares/modules", Path("/etc/calamares/modules")),
        (livefs / "usr/local/share/local-host", Path("/usr/local/share/local-host")),
        (
            livefs / "usr/share/calamares/branding/manjaro",
            Path("/usr/share/calamares/branding/manjaro"),
        ),
    ):
        target.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, target, dirs_exist_ok=True)

    Path("/etc/xdg/calamares").mkdir(parents=True, exist_ok=True)
    shutil.copy2(settings, "/etc/xdg/calamares/settings.conf")

    # Remove the fallback copies so a failed XDG lookup cannot pass silently.
    for fallback in (
        "/usr/share/calamares/settings.conf",
        "/etc/calamares/settings.conf",
    ):
        Path(fallback).unlink(missing_ok=True)

    runtime = work / "runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    runtime.chmod(0o700)

    env = dict(
        os.environ,
        XDG_CONFIG_DIRS="/etc/xdg",
        QT_QPA_PLATFORM="xcb",
        XDG_RUNTIME_DIR=str(runtime),
    )
    # -d is the debug variant of the production -D6: verbose logging and no
    # single-instance check. -X is what calamares_polkit passes, and selects
    # /etc/xdg/calamares.
    result = run(
        "timeout", "-k", "5", "30",
        # xvfb-run defaults to 640x480, below Calamares' 800x520 minimum; the
        # Debug build aborts on the clamped window size instead of shrinking.
        "xvfb-run", "-a", "-s", "-screen 0 1280x800x24",
        "calamares", "-d", "-X",
        check=False,
        env=env,
    )
    log = result.stdout + result.stderr

    assert result.returncode in (0, 124), (
        f"calamares exited with status {result.returncode}\n{log}"
    )
    assert "/etc/xdg/calamares/settings.conf" in log, (
        f"Calamares did not load /etc/xdg/calamares/settings.conf\n{log}"
    )
    for marker in (
        "FATAL",
        "Cowardly refusing",
        "Invalid module instance",
        "is not listed in the *instances*",
        "Cannot load module",
        "Failed to load module",
    ):
        assert marker not in log, f"Calamares reported {marker!r}\n{log}"
