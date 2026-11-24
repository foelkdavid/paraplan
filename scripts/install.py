#!/usr/bin/env python3
"""Per-user installation of paraplan (binary, desktop launcher, license notices)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def desktop_string(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t").replace(" ", "\\s")


def exec_arg(value):
    # Exec has its own quoting layer in addition to desktop-string escaping.
    value = str(value).replace("%", "%%")
    for char in ('\\', '"', '`', '$'):
        value = value.replace(char, '\\' + char)
    return desktop_string('"' + value + '"')


def refresh_icons(data):
    # Refresh an existing GTK icon cache (a stale one hides the new icon); never create one. Tools are optional.
    cmds = [["update-desktop-database", str(data / "applications")]]
    if (data / "icons/hicolor/icon-theme.cache").exists():
        cmds.append(["gtk-update-icon-cache", "-q", "-t", str(data / "icons/hicolor")])
    for cmd in cmds:
        try:
            subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            pass


def main():
    if sys.argv[1:] not in (["install"], ["uninstall"]):
        raise SystemExit("usage: install.py install|uninstall")
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
    if not data.is_absolute():
        raise SystemExit("XDG_DATA_HOME must be absolute")
    binary = home / ".local/bin/paraplan"
    desktop = data / "applications/paraplan.desktop"
    icon = data / "icons/hicolor/scalable/apps/paraplan.svg"
    licenses = data / "paraplan/licenses"
    notices = ("FONT-OFL.txt", "RAYLIB-LICENSE.txt")
    if sys.argv[1] == "uninstall":
        for path in (binary, desktop, icon, *(licenses / name for name in notices)):
            path.unlink(missing_ok=True)
        for directory in (licenses, licenses.parent):
            try:
                directory.rmdir()
            except OSError:
                pass  # Preserve any unrelated files.
        refresh_icons(data)
        print("Uninstalled paraplan.")
        return
    binary.parent.mkdir(parents=True, exist_ok=True)
    desktop.parent.mkdir(parents=True, exist_ok=True)
    licenses.mkdir(parents=True, exist_ok=True)
    # Replace the inode so reinstalling also works while paraplan is running.
    with tempfile.NamedTemporaryFile(dir=binary.parent, prefix=".paraplan-", delete=False) as staged:
        temporary = Path(staged.name)
    try:
        shutil.copyfile(ROOT / "build/paraplan", temporary)
        temporary.chmod(0o755)
        temporary.replace(binary)
    finally:
        temporary.unlink(missing_ok=True)
    for name in notices:
        destination = licenses / name
        shutil.copyfile(ROOT / "licenses" / name, destination)
        destination.chmod(0o644)
    template = (ROOT / "paraplan.desktop").read_text()
    desktop.write_text(template.replace("@EXEC@", exec_arg(binary)))
    desktop.chmod(0o644)
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "assets/paraplan.svg", icon)
    icon.chmod(0o644)
    refresh_icons(data)
    print(f"Installed {binary}, {desktop} and {icon}")
    print("Ensure ~/.local/bin is on PATH to run paraplan from a terminal.")


if __name__ == "__main__":
    main()
