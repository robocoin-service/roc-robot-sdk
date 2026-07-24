import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {".cpp", ".hpp", ".json", ".md", ".py", ".sh", ".txt", ".yml"}
SKIP_PARTS = {".git", "__pycache__", "build"}


class SourceQualityTests(unittest.TestCase):
    def source_files(self):
        for path in sorted(REPO_ROOT.rglob("*")):
            if not path.is_file() or any(part in SKIP_PARTS for part in path.parts):
                continue
            if path.suffix in TEXT_SUFFIXES or path.name == "CMakeLists.txt":
                yield path

    def test_text_sources_are_clean_utf8(self):
        for path in self.source_files():
            relative = path.relative_to(REPO_ROOT)
            data = path.read_bytes()
            self.assertFalse(data.startswith(b"\xef\xbb\xbf"), f"UTF-8 BOM: {relative}")
            self.assertNotIn(b"\x00", data, f"NUL byte: {relative}")
            unexpected_controls = sorted(
                {byte for byte in data if byte < 32 and byte not in (9, 10)}
            )
            self.assertEqual(
                [], unexpected_controls, f"control bytes {unexpected_controls}: {relative}"
            )
            self.assertNotIn(bytes((127,)), data, f"DEL control byte: {relative}")
            self.assertNotIn(bytes((13, 10)), data, f"CRLF line ending: {relative}")
            text = data.decode("utf-8")
            self.assertNotIn("\ufffd", text, f"replacement character: {relative}")
            for line_number, line in enumerate(text.splitlines(), start=1):
                self.assertEqual(
                    line.rstrip(" \t"),
                    line,
                    f"trailing whitespace: {relative}:{line_number}",
                )

    def test_python_and_shell_lines_are_reviewable(self):
        for path in self.source_files():
            if path.suffix not in {".py", ".sh"}:
                continue
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                self.assertLessEqual(
                    len(line),
                    120,
                    f"line too long: {path.relative_to(REPO_ROOT)}:{line_number}",
                )

    def test_no_development_markers_or_private_defaults(self):
        forbidden = (
            "BEGIN OPENSSH " + "PRIVATE KEY",
            "BEGIN RSA " + "PRIVATE KEY",
            "172.16." + "18.187",
            "TO" + "DO",
            "FIX" + "ME",
            "HA" + "CK",
        )
        for path in self.source_files():
            text = path.read_text(encoding="utf-8")
            for marker in forbidden:
                self.assertNotIn(marker, text, f"{marker!r} found in {path}")

    def test_json_files_parse(self):
        for path in self.source_files():
            if path.suffix == ".json":
                with self.subTest(path=path.relative_to(REPO_ROOT)):
                    json.loads(path.read_text(encoding="utf-8"))

    def test_documented_release_files_exist(self):
        required = (
            ".github/workflows/ci.yml",
            "ADAPTER-CONTRACT.md",
            "README.md",
            "README-TPM-LINUX.md",
            "schemas/adapter-manifest.schema.json",
            "schemas/job.schema.json",
            "schemas/job-event.schema.json",
        )
        for relative in required:
            self.assertTrue((REPO_ROOT / relative).is_file(), relative)


if __name__ == "__main__":
    unittest.main()
