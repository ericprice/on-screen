#!/usr/bin/env python3
"""Validate release metadata before creating or submitting an archive."""

from pathlib import Path
import plistlib
import sys


def validate(app, root):
    if app.name != "On Screen.app" or not app.is_dir():
        raise ValueError("The release bundle must be named On Screen.app.")
    actual = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = plistlib.loads((root / "App/Info.plist").read_bytes())
    if actual.get("CFBundleIdentifier") != "info.ericprice.on-screen":
        raise ValueError("Unexpected release bundle identifier.")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "SUPublicEDKey"):
        if actual.get(key) != expected[key]:
            raise ValueError(f"Release app {key} does not match App/Info.plist.")
    resources = app / "Contents/Resources"
    for name, source in (
        ("LICENSE", "LICENSE"),
        ("README.md", "README.md"),
        ("CC-BY-SA-4.0.txt", "Licenses/CC-BY-SA-4.0.txt"),
    ):
        if (resources / name).read_bytes() != (root / source).read_bytes():
            raise ValueError(f"Bundled {name} does not match the release source.")
    if "SPARKLE LICENSES AND NOTICES" not in (resources / "LICENSE").read_text():
        raise ValueError("Bundled LICENSE is missing Sparkle notices.")
    for name in ("Sparkle.txt", "THIRD-PARTY-NOTICES.md", "Licenses.txt"):
        if (resources / name).exists():
            raise ValueError(f"Unexpected obsolete license resource: {name}")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: validate_release_app.py APP")
        validate(Path(sys.argv[1]), Path(__file__).resolve().parent.parent)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print(f"error: Release validation: {error}", file=sys.stderr)
        sys.exit(1)
    print("Release app metadata and bundled licenses verified.")
