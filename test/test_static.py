"""Checks that need only the repository and the profile.

Run with:  pytest test/test_static.py
"""

from support import PROFILE, QML_DIR, require, run, shell_scripts


def qml_files():
    files = sorted(QML_DIR.glob("*.qml"))
    assert files, f"no .qml files under {QML_DIR}"
    return files


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
