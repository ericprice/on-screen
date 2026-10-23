#!/usr/bin/env python3
"""Reject stale SDK checkouts before compiling the analytics harness."""

import json
from pathlib import Path
import subprocess
import sys


def verify(resolved, packages, existing_only=False):
    for pin in json.loads(resolved.read_text())["pins"]:
        checkout = packages / "checkouts" / pin["identity"]
        if existing_only and not checkout.exists():
            continue
        try:
            revision = subprocess.check_output(
                ["git", "-C", str(checkout), "rev-parse", "--verify", "HEAD"],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
            changes = subprocess.check_output(
                ["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=all"],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
        except subprocess.CalledProcessError:
            raise ValueError(
                f"Cannot inspect cached {pin['identity']}. Preserve any local changes, "
                "then resolve a fresh package cache."
            ) from None
        if changes:
            raise ValueError(
                f"Cached {pin['identity']} contains local changes. Preserve them, "
                "then resolve a clean cache before running checks."
            )
        if not existing_only and revision != pin["state"]["revision"]:
            raise ValueError(f"Cached {pin['identity']} does not match Package.resolved.")


if __name__ == "__main__":
    try:
        arguments = sys.argv[1:]
        existing_only = arguments[:1] == ["--check-existing-cleanliness"]
        if existing_only:
            arguments = arguments[1:]
        if len(arguments) != 2:
            raise ValueError("Usage: verify_package_pins.py [--check-existing-cleanliness] Package.resolved SourcePackages")
        verify(Path(arguments[0]), Path(arguments[1]), existing_only=existing_only)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"error: Package pin validation: {error}", file=sys.stderr)
        sys.exit(1)
    print("Existing SDK checkouts are clean." if existing_only else "Cached SDK revisions match Package.resolved and checkouts are clean.")
