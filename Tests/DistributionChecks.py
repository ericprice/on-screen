#!/usr/bin/env python3
"""Exercise release control flow with fake apps and no Apple/service requests."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent
MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, sys, zipfile
import xml.etree.ElementTree as ET
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CHECK_TOOL_LOG"], "a") as log:
    log.write(json.dumps([tool, *args]) + "\n")
failure = os.environ.get("CHECK_FAIL_AT", "")
if tool == "ditto":
    source, destination = map(pathlib.Path, args[-2:])
    if "-c" in args:
        if failure == "archive":
            destination.write_bytes(b"incomplete archive")
            sys.exit(1)
        with zipfile.ZipFile(destination, "w") as archive:
            for path in source.rglob("*"):
                if path.is_file():
                    archive.write(path, path.relative_to(source.parent))
    elif "-x" in args:
        with zipfile.ZipFile(source) as archive:
            archive.extractall(destination)
    else:
        shutil.copy2(source, destination)
elif tool == "lipo":
    print("arm64 x86_64")
elif tool == "codesign":
    sys.exit(1 if failure == "codesign" else 0)
elif tool == "spctl":
    sys.exit(1 if failure == "assessment" else 0)
elif tool == "mv":
    source, destination = map(pathlib.Path, args)
    if failure == "replace" and destination.parent.name == "dist":
        sys.exit(1)
    source.replace(destination)
elif tool == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        if failure == "submit":
            sys.exit(1)
        print(json.dumps({"status": "Accepted", "id": "mock-submission"}))
    elif args[:2] == ["stapler", "staple"]:
        (pathlib.Path(args[2]) / "Contents/stapled-ticket").write_text("mock")
    elif args[:2] == ["stapler", "validate"]:
        sys.exit(0 if (pathlib.Path(args[2]) / "Contents/stapled-ticket").exists() else 1)
    else:
        sys.exit("Unexpected xcrun command")
elif tool == "generate_keys":
    print("test-public-key")
elif tool == "generate_appcast":
    if failure == "appcast":
        sys.exit(1)
    staging = pathlib.Path(args[-1])
    archive = next(staging.glob("*.zip"))
    with zipfile.ZipFile(archive) as zip_file:
        info = plistlib.loads(zip_file.read("On Screen.app/Contents/Info.plist"))
    sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", sparkle)
    feed = ET.Element("rss")
    channel = ET.SubElement(feed, "channel")
    ET.SubElement(channel, "title").text = "On Screen"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, f"{{{sparkle}}}shortVersionString").text = info["CFBundleShortVersionString"]
    ET.SubElement(item, f"{{{sparkle}}}version").text = info["CFBundleVersion"]
    notes = archive.with_suffix(".html")
    if notes.exists():
        ET.SubElement(item, "description").text = notes.read_text()
    prefix = args[args.index("--download-url-prefix") + 1]
    ET.SubElement(item, "enclosure", {"url": prefix + archive.name,
        "length": str(archive.stat().st_size), f"{{{sparkle}}}edSignature": "mock-signature"})
    ET.ElementTree(feed).write(staging / "appcast.xml")
else:
    sys.exit("Unexpected mocked command")
'''


class DistributionChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="on-screen-distribution-checks-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("script", "App", "Licenses", "build", "dist", "bin"):
            (self.root / directory).mkdir()
        for name in (
            "package_zip.sh", "notarize_zip.sh", "verify_zip.sh", "generate_appcast.sh",
            "validate_release_app.py", "configure_posthog.py", "verify_package_pins.py",
        ):
            shutil.copy2(ROOT / "script" / name, self.root / "script" / name)
        self.info = {
            "CFBundleIdentifier": "info.ericprice.on-screen",
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "20",
            "SUPublicEDKey": "test-public-key",
        }
        self.write_plist(self.root / "App/Info.plist", self.info)
        for name, contents in (
            ("LICENSE", "SPARKLE LICENSES AND NOTICES\n"),
            ("README.md", "Test release documentation\n"),
            ("Licenses/CC-BY-SA-4.0.txt", "Test font license\n"),
        ):
            (self.root / name).write_text(contents)
        self.app = self.root / "external/On Screen.app"
        self.write_plist(self.app / "Contents/Info.plist", self.info)
        resources = self.app / "Contents/Resources"
        self.write_plist(resources / "PostHogConfiguration.plist", {
            "POSTHOG_PROJECT_TOKEN": "phc_FakePublicToken",
            "POSTHOG_HOST": "https://example.invalid",
            "ON_SCREEN_ANALYTICS_ENVIRONMENT": "production",
            "ON_SCREEN_ANALYTICS_INTERNAL": "false",
        })
        for name in ("LICENSE", "README.md", "Licenses/CC-BY-SA-4.0.txt"):
            shutil.copy2(self.root / name, resources / Path(name).name)
        (self.app / "Contents/MacOS").mkdir()
        (self.app / "Contents/MacOS/On Screen").write_text("fake executable")
        for name in ("ditto", "codesign", "lipo", "spctl", "mv", "xcrun", "generate_keys", "generate_appcast"):
            tool = self.root / "bin" / name
            tool.write_text(MOCK_TOOL)
            tool.chmod(0o755)
        self.log = self.root / "tool-calls.jsonl"
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.root / "bin") + os.pathsep + self.env["PATH"],
            "DISTRIBUTION_APP": str(self.app),
            "SIGNING_IDENTITY": "Developer ID Application: Test",
            "NOTARY_PROFILE": "mock-profile",
            "SPARKLE_BIN": str(self.root / "bin"),
            "SPARKLE_KEY_ACCOUNT": "mock-account",
            "CHECK_TOOL_LOG": str(self.log),
            "CHECK_FAIL_AT": "",
        })
        self.env.pop("UPDATE_ZIP", None)
        self.env.pop("RELEASE_NOTES_FILE", None)
        # Historical scratch and backups must never be removed by new runs.
        self.retained = self.root / "build/zip-check.existing"
        self.retained.mkdir()
        (self.retained / "keep").write_text("existing scratch")

    @staticmethod
    def write_plist(path, values):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(values))

    def run_script(self, name, *arguments, succeeds=True):
        result = subprocess.run(
            ["/bin/bash", str(self.root / "script" / name), *map(str, arguments)],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.assertEqual(result.returncode == 0, succeeds, result.stdout)
        self.assert_scratch_clean()
        return result

    def assert_scratch_clean(self):
        for pattern in ("package-zip.*", "zip-check.*", "notarized-zip.*", "appcast.*"):
            self.assertEqual([p for p in (self.root / "build").glob(pattern) if p != self.retained], [])
        self.assertEqual((self.retained / "keep").read_text(), "existing scratch")

    def calls(self, tool):
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [call for call in calls if call[0] == tool]

    def archive(self, path=None, stapled=False):
        path = path or self.root / "dist/On-Screen-2.0.zip"
        if stapled:
            (self.app / "Contents/stapled-ticket").write_text("mock")
        with zipfile.ZipFile(path, "w") as archive:
            for source in self.app.rglob("*"):
                if source.is_file():
                    archive.write(source, source.relative_to(self.app.parent))
        return path

    def test_package_rejects_mismatched_version_before_submission(self):
        self.write_plist(self.app / "Contents/Info.plist", {**self.info, "CFBundleShortVersionString": "1.9"})
        existing = self.root / "dist/On-Screen-2.0.zip"
        existing.write_bytes(b"previous release")
        self.run_script("package_zip.sh", succeeds=False)
        self.assertEqual(existing.read_bytes(), b"previous release")
        self.assertEqual(self.calls("xcrun"), [])
        self.assertFalse((self.root / "dist/On-Screen-1.9.zip").exists())

    def test_package_rejects_mismatched_build_before_submission(self):
        self.write_plist(self.app / "Contents/Info.plist", {**self.info, "CFBundleVersion": "19"})
        self.run_script("package_zip.sh", succeeds=False)
        self.assertEqual(self.calls("xcrun"), [])

    def test_package_preserves_previous_archive_on_creation_failure(self):
        existing = self.root / "dist/On-Screen-2.0.zip"
        existing.write_bytes(b"previous release")
        self.env["CHECK_FAIL_AT"] = "archive"
        self.run_script("package_zip.sh", succeeds=False)
        self.assertEqual(existing.read_bytes(), b"previous release")

    def test_package_preserves_previous_archive_on_submission_failure(self):
        existing = self.root / "dist/On-Screen-2.0.zip"
        existing.write_bytes(b"previous release")
        self.env["CHECK_FAIL_AT"] = "submit"
        self.run_script("package_zip.sh", succeeds=False)
        self.assertEqual(existing.read_bytes(), b"previous release")

    def test_package_preserves_previous_archive_on_replacement_failure(self):
        existing = self.root / "dist/On-Screen-2.0.zip"
        existing.write_bytes(b"previous release")
        self.env["CHECK_FAIL_AT"] = "replace"
        self.run_script("package_zip.sh", succeeds=False)
        self.assertEqual(existing.read_bytes(), b"previous release")
        backups = list((self.root / "build").glob("previous-zip.*/previous.zip"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), b"previous release")

    def test_package_submits_staged_archive_and_preserves_backup(self):
        existing = self.root / "dist/On-Screen-2.0.zip"
        existing.write_bytes(b"previous release")
        self.run_script("package_zip.sh")
        submissions = [call for call in self.calls("xcrun") if call[1:3] == ["notarytool", "submit"]]
        self.assertEqual(len(submissions), 1)
        self.assertEqual(Path(submissions[0][3]).name, existing.name)
        self.assertTrue(Path(submissions[0][3]).parent.name.startswith("package-zip."))
        with zipfile.ZipFile(existing) as archive:
            self.assertIn("On Screen.app/Contents/stapled-ticket", archive.namelist())
        backups = list((self.root / "build").glob("previous-zip.*/previous.zip"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), b"previous release")

    def test_package_can_explicitly_skip_notarization(self):
        self.env["NOTARY_PROFILE"] = ""
        self.run_script("package_zip.sh")
        self.assertTrue((self.root / "dist/On-Screen-2.0.zip").exists())
        self.assertEqual(self.calls("xcrun"), [])

    def test_notarization_uses_explicit_archive(self):
        archive = self.archive(self.root / "explicit-release.zip")
        self.run_script("notarize_zip.sh", archive)
        submissions = [call for call in self.calls("xcrun") if call[1:3] == ["notarytool", "submit"]]
        self.assertEqual(submissions[0][3], str(archive))

    def test_notarization_rejects_wrong_archive_before_submission(self):
        self.write_plist(self.app / "Contents/Info.plist", {**self.info, "CFBundleVersion": "19"})
        self.run_script("notarize_zip.sh", self.archive(), succeeds=False)
        self.assertEqual(self.calls("xcrun"), [])

    def test_verification_cleans_up_after_failed_assessment(self):
        self.env["CHECK_FAIL_AT"] = "assessment"
        self.run_script("verify_zip.sh", self.archive(stapled=True), succeeds=False)

    def test_verification_rejects_extra_archive_contents(self):
        archive = self.archive(stapled=True)
        with zipfile.ZipFile(archive, "a") as output:
            output.writestr("unexpected.txt", "extra")
        self.run_script("verify_zip.sh", archive, succeeds=False)

    def test_appcast_preserves_output_and_cleans_staging(self):
        self.archive(stapled=True)
        notes = self.root / "release-notes.html"
        notes.write_text("<p>Test release notes.</p>\n")
        self.env["RELEASE_NOTES_FILE"] = str(notes)
        self.run_script("generate_appcast.sh")
        self.assertIn("Test release notes", (self.root / "dist/appcast.xml").read_text())

    def test_appcast_failure_preserves_existing_feed(self):
        self.archive(stapled=True)
        existing = self.root / "dist/appcast.xml"
        existing.write_text("previous feed")
        self.env["CHECK_FAIL_AT"] = "appcast"
        self.run_script("generate_appcast.sh", succeeds=False)
        self.assertEqual(existing.read_text(), "previous feed")

    def test_pin_validation_rejects_stale_or_modified_checkout(self):
        packages = self.root / "packages"
        checkout = packages / "checkouts/test-sdk"
        checkout.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(checkout)], check=True)
        sdk_source = checkout / "SDK.swift"
        sdk_source.write_text("// Pinned SDK source\n")
        (checkout / ".gitignore").write_text(".build/\n")
        subprocess.run(["git", "-C", str(checkout), "add", "SDK.swift", ".gitignore"], check=True)
        subprocess.run([
            "git", "-C", str(checkout), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-qm", "Test SDK pin",
        ], check=True)
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        resolved = self.root / "Package.resolved"
        def check(expected, preflight=False):
            resolved.write_text(json.dumps({"pins": [{"identity": "test-sdk", "state": {"revision": expected}}]}))
            return subprocess.run([
                "python3", str(self.root / "script/verify_package_pins.py"),
                *(["--check-existing-cleanliness"] if preflight else []), str(resolved), str(packages),
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.assertEqual(check(revision).returncode, 0)
        self.assertNotEqual(check("0" * 40).returncode, 0)
        self.assertEqual(check("0" * 40, preflight=True).returncode, 0)
        sdk_source.write_text("// Modified SDK source at the same HEAD\n")
        self.assertNotEqual(check(revision).returncode, 0)
        self.assertNotEqual(check("0" * 40, preflight=True).returncode, 0)
        sdk_source.write_text("// Pinned SDK source\n")
        extra_source = checkout / "Extra.swift"
        extra_source.write_text("// Untracked code can also enter a path package\n")
        self.assertNotEqual(check(revision).returncode, 0)
        self.assertNotEqual(check(revision, preflight=True).returncode, 0)
        extra_source.unlink()
        (checkout / ".build").mkdir()
        (checkout / ".build/cache").touch()
        self.assertEqual(check(revision).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
