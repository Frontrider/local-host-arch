"""Checks that need only the repository and the profile.

Run with:  pytest test/test_static.py
"""

import json
import re

from support import PROFILE, QML_DIR, TEST_DIR, require, run, shell_scripts


def qml_files():
    files = sorted(QML_DIR.glob("*.qml"))
    assert files, f"no .qml files under {QML_DIR}"
    return files


def test_openqa_needle_references():
    distri = TEST_DIR / "openqa-distri"
    tags = set()
    for path in sorted((distri / "needles").glob("*.json")):
        image = path.with_suffix(".png")
        assert image.is_file(), f"missing image for {path.name}: {image.name}"
        with image.open("rb") as png:
            assert png.read(8) == b"\x89PNG\r\n\x1a\n", f"invalid PNG: {image}"
        tags.update(json.loads(path.read_text(encoding="utf-8"))["tags"])
    assert tags, f"no openQA needles found in {distri}"

    # Check literal single tags and arrays, which openQA accepts as alternatives.
    calls = re.compile(
        r"""\b(?:assert_screen|check_screen|assert_and_click)\s*\(\s*"""
        r"""(\[[^\]\n]*\]|'[^'\n]+'|"[^"\n]+")"""
    )
    missing = []
    for path in sorted(distri.rglob("*.pm")):
        for arg in calls.findall(path.read_text(encoding="utf-8")):
            for tag in re.findall(r"""['"]([a-z0-9-]+)['"]""", arg):
                if tag not in tags:
                    missing.append(f"{path.relative_to(distri)}: {tag}")
    assert not missing, "missing openQA needles:\n" + "\n".join(missing)


def test_shellcheck():
    require("shellcheck")

    # Only the scripts the profile installs. The build and test tooling is not
    # part of the application and is not checked here.
    scripts = list(shell_scripts(PROFILE))
    assert scripts, f"no shell scripts under {PROFILE}"

    for path in scripts:
        result = run(
            "shellcheck",
            "--external-sources",
            "--exclude=SC1090,SC1091",
            "--severity=warning",
            path,
            check=False,
        )
        assert result.returncode == 0, f"{path}\n{result.stdout}{result.stderr}"


def test_xmllint():
    require("xmllint")

    files = sorted(list(PROFILE.rglob("*.ts")) + list(PROFILE.rglob("*.xml")))
    assert files, f"no .ts or .xml files under {PROFILE}"

    for path in files:
        run("xmllint", "--nonet", "--noout", path)


def test_desktop_file_validate():
    require("desktop-file-validate")

    files = sorted(PROFILE.rglob("*.desktop"))
    assert files, f"no .desktop files under {PROFILE}"

    for path in files:
        run("desktop-file-validate", path)


def test_qmlformat():
    require("qmlformat")

    for path in qml_files():
        run("qmlformat", path)


def test_qmllint():
    require("qmllint")

    for path in qml_files():
        result = run("qmllint", path, check=False)
        output = result.stdout + result.stderr
        # Calamares registers io.calamares.core from C++, so qmllint cannot
        # resolve that import and always warns. Only errors matter here.
        assert "Error:" not in output, f"{path}\n{output}"
        assert result.returncode == 0 or output, (
            f"qmllint failed on {path} without output"
        )
