#!/usr/bin/env python3
"""Bundle public PostHog client configuration without evaluating .env as code."""

import ipaddress
import os
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlsplit


KEYS = ("POSTHOG_PROJECT_TOKEN", "POSTHOG_HOST")
ENVIRONMENT_KEY = "ON_SCREEN_ANALYTICS_ENVIRONMENT"
INTERNAL_KEY = "ON_SCREEN_ANALYTICS_INTERNAL"
ASSIGNMENT = re.compile(r"^(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$")


class ConfigurationError(Exception):
    pass


def read_dotenv(path):
    """Read only relevant KEY=value entries; quotes are literal, never expanded."""
    if not path.is_file():
        return {}
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError):
        raise ConfigurationError("Cannot read the repository .env file.") from None

    values = {}
    for number, line in enumerate(lines, start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        assignment = ASSIGNMENT.fullmatch(line)
        if assignment is None or assignment[1] not in KEYS:
            continue
        key, value = assignment.groups()
        value = value.strip()
        if value.startswith(("'", '"')):
            end = value.find(value[0], 1)
            if end == -1 or (value[end + 1 :].strip() and not value[end + 1 :].strip().startswith("#")):
                raise ConfigurationError(f"Malformed quoted {key} on .env line {number}.")
            value = value[1:end]
        else:
            value = re.split(r"[ \t]+#", value, maxsplit=1)[0].rstrip()
        values[key] = value
    return values


def validate_configuration(values):
    for key in KEYS:
        if not isinstance(values.get(key), str) or not values[key]:
            raise ConfigurationError(
                f"{key} is required. Set it in the build environment or repository .env; "
                "see .env.example."
            )

    token = values["POSTHOG_PROJECT_TOKEN"]
    if re.fullmatch(r"phc_[A-Za-z0-9]+", token) is None:
        raise ConfigurationError(
            "POSTHOG_PROJECT_TOKEN must be a public phc_ project token. "
            "Personal or secret API keys must never be bundled."
        )

    host = values["POSTHOG_HOST"]
    try:
        parsed = urlsplit(host)
        hostname = parsed.hostname
        port = parsed.port
        valid = (
            parsed.scheme == "https"
            and hostname
            and not re.search(r"\s", host)
            and parsed.username is None
            and parsed.password is None
            and "?" not in host
            and "#" not in host
            and parsed.path in ("", "/")
            and (port is None or 1 <= port <= 65535)
        )
        if valid:
            try:
                ipaddress.ip_address(hostname)
            except ValueError:
                valid = len(hostname) <= 253 and all(
                    re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                    for label in hostname.rstrip(".").split(".")
                )
        if not valid:
            raise ValueError
    except ValueError:
        raise ConfigurationError(
            "POSTHOG_HOST must be an HTTPS origin without credentials, a path, query, or fragment."
        ) from None

    return {"POSTHOG_PROJECT_TOKEN": token, "POSTHOG_HOST": host.rstrip("/")}


def analytics_classification(build):
    """Only explicit, signed distribution archives can produce production traffic."""
    environment = build.get(ENVIRONMENT_KEY, "development").strip()
    internal = build.get(INTERNAL_KEY, "true").strip()
    if environment not in ("production", "development", "test"):
        raise ConfigurationError(f"{ENVIRONMENT_KEY} must be production, development, or test.")
    if internal not in ("true", "false"):
        raise ConfigurationError(f"{INTERNAL_KEY} must be true or false.")
    if environment != "production":
        if internal != "true":
            raise ConfigurationError("Development and test analytics must be marked internal.")
    else:
        if internal != "false":
            raise ConfigurationError("Production distribution builds must explicitly set internal=false.")
        expected = {
            "CONFIGURATION": "Release",
            "DEPLOYMENT_LOCATION": "YES",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "CODE_SIGNING_ALLOWED": "YES",
        }
        for key, value in expected.items():
            if build.get(key) != value:
                raise ConfigurationError(
                    f"Production analytics requires a signed Release distribution archive ({key}={value}). "
                    "Use script/package_zip.sh; ordinary builds must remain development or test."
                )
        # Xcode reports archive in build settings; script phases on some versions
        # receive install for the archive's installation build-products step.
        if build.get("ACTION") not in ("archive", "install"):
            raise ConfigurationError(
                "Production analytics requires an archive/install action. Use script/package_zip.sh."
            )
        identity = build.get("EXPANDED_CODE_SIGN_IDENTITY_NAME") or build.get("CODE_SIGN_IDENTITY", "")
        if not identity.startswith("Developer ID Application:"):
            raise ConfigurationError("Production analytics requires Developer ID Application signing.")
    return {ENVIRONMENT_KEY: environment, INTERNAL_KEY: internal}


def validate_distribution_app(app):
    configuration = app / "Contents/Resources/PostHogConfiguration.plist"
    try:
        values = plistlib.loads(configuration.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        raise ConfigurationError("Distribution app is missing a valid PostHog configuration plist.") from None
    if not isinstance(values, dict) or values.get(ENVIRONMENT_KEY) != "production" or values.get(INTERNAL_KEY) != "false":
        raise ConfigurationError("Distribution app must bundle production analytics with internal=false.")
    validate_configuration(values)
    print("Distribution analytics classification verified.")


def write_configuration(destination, values):
    data = plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and destination.read_bytes() == data:
        return
    # Write only the declared build output so Xcode's script sandbox stays enabled.
    # A write failure fails the build before code signing or packaging can proceed.
    destination.write_bytes(data)
    destination.chmod(0o644)


def main():
    required = ("SRCROOT", "TARGET_BUILD_DIR", "UNLOCALIZED_RESOURCES_FOLDER_PATH")
    if any(not os.environ.get(key) for key in required):
        raise ConfigurationError("Run this script from the app's Xcode build phase.")

    overrides = {key: os.environ[key].strip() for key in KEYS if key in os.environ}
    values = {} if len(overrides) == len(KEYS) else read_dotenv(Path(os.environ["SRCROOT"]) / ".env")
    values.update(overrides)
    values = validate_configuration(values)
    # Classification never comes from .env, including in local Release builds.
    values.update(analytics_classification(os.environ))
    destination = (
        Path(os.environ["TARGET_BUILD_DIR"])
        / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
        / "PostHogConfiguration.plist"
    )
    write_configuration(destination, values)
    print("PostHog public client configuration and analytics classification bundled.")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--validate-distribution-app":
            validate_distribution_app(Path(sys.argv[2]))
        elif len(sys.argv) == 1:
            main()
        else:
            raise ConfigurationError("Usage: configure_posthog.py [--validate-distribution-app APP]")
    except ConfigurationError as error:
        print(f"error: PostHog configuration: {error}", file=sys.stderr)
        sys.exit(1)
    except OSError:
        print("error: PostHog configuration: Cannot write the app bundle configuration.", file=sys.stderr)
        sys.exit(1)
