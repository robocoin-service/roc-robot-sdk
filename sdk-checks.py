"""Read-only diagnostics and validation for the ROC Robot SDK."""

import json
import re
import sys
import time
from pathlib import Path


def read(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return ""


def response(text):
    try:
        result = json.loads(text)
    except ValueError:
        return {}
    return result if isinstance(result, dict) else {}


def verified_data(text):
    result = response(text)
    data = result.get("data")
    if str(result.get("code")) == "200" and isinstance(data, dict) and data.get("signatureVerified") is True:
        return data
    return {}


def robot_id(value):
    value = str(value)
    return value if re.fullmatch(r"[1-9][0-9]*", value) else None


def bound_robot(text):
    data = verified_data(text)
    return robot_id(data.get("robotId")) if data.get("bindingStatus") in ("BOUND", "MATCHED") else None


def accepted_heartbeat(text, expected_id):
    return bool(expected_id and robot_id(verified_data(text).get("robotId")) == expected_id)


def local_status(home, version):
    saved_id = robot_id(read(home / "robot-id"))
    file = home / "output" / "heartbeat-server-response.json"
    beat = read(file)
    fresh = False
    try:
        fresh = 0 <= time.time() - file.stat().st_mtime <= 90
    except OSError:
        pass
    accepted = accepted_heartbeat(beat, saved_id)
    return {
        "sdkVersion": version,
        "binding": "bound" if saved_id else "not_bound",
        "heartbeat": (
            "verified_recently" if accepted and fresh else
            "stale" if beat and not fresh else
            "not_verified" if beat else "not_seen"
        ),
    }


def check_adapter(directory):
    manifest = response(read(directory / "adapter.json"))
    for key in ("id", "displayName", "version", "platform", "entrypoint"):
        if not isinstance(manifest.get(key), str) or not manifest[key].strip():
            raise ValueError(f"{key} must be a non-empty string")
    if not re.fullmatch(r"[a-z][a-z0-9-]*", manifest["id"]):
        raise ValueError("id must use lowercase letters, digits and hyphens")
    if manifest["platform"] != "linux":
        raise ValueError("platform must be linux")
    for key in ("capabilities", "requires"):
        values = manifest.get(key)
        if not isinstance(values, list) or any(not isinstance(v, str) or not v.strip() for v in values):
            raise ValueError(f"{key} must be a list of non-empty strings")
        if len({v.strip() for v in values}) != len(values):
            raise ValueError(f"{key} must not contain duplicates")
    if not manifest["capabilities"]:
        raise ValueError("declare at least one capability")
    entry = Path(manifest["entrypoint"])
    actual = (directory / entry).resolve()
    if entry.is_absolute() or ".." in entry.parts or directory.resolve() not in actual.parents or not actual.is_file():
        raise ValueError("entrypoint must be an existing file inside the adapter directory")
    return manifest["id"]


def main(argv):
    if argv == ["bind"]:
        found = bound_robot(sys.stdin.read())
        if found:
            print(found)
        return 0 if found else 1
    if len(argv) == 3 and argv[0] == "heartbeat":
        return 0 if accepted_heartbeat(read(Path(argv[1])), robot_id(argv[2])) else 1
    if len(argv) in (3, 4) and argv[0] == "status" and argv[3:] in ([], ["--json"]):
        status = local_status(Path(argv[1]), argv[2])
        if argv[3:]:
            print(json.dumps(status, sort_keys=True))
        else:
            for name, value in status.items():
                print(f"{name}: {value}")
        return 0
    if len(argv) == 2 and argv[0] == "check-adapter":
        try:
            print(f"Adapter manifest valid: {check_adapter(Path(argv[1]))}. Hardware was not tested.")
            return 0
        except (ValueError, OSError, RuntimeError) as error:
            print(f"Adapter validation failed: {error}", file=sys.stderr)
            return 1
    print("Usage: sdk-checks.py bind | heartbeat <file> <robotId> | status <sdkHome> <version> [--json] | check-adapter <directory>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
