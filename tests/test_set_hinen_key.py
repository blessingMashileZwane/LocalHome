from __future__ import annotations

import os
import pathlib
import stat
import tempfile
import unittest

import set_hinen_key


class KeyImportTests(unittest.TestCase):
    def test_plain_key(self) -> None:
        self.assertEqual(
            set_hinen_key.read_key("0123456789abcdef\n"),
            "0123456789abcdef",
        )

    def test_labelled_key(self) -> None:
        self.assertEqual(
            set_hinen_key.read_key("HINEN_LOCAL_KEY=abcdef0123456789\n"),
            "abcdef0123456789",
        )

    def test_uppercase_is_preserved(self) -> None:
        self.assertEqual(
            set_hinen_key.read_key("ABCDEF0123456789\n"),
            "ABCDEF0123456789",
        )

    def test_multiple_keys_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            set_hinen_key.read_key(
                "0123456789abcdef\nfedcba9876543210\n"
            )

    def test_missing_key_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            set_hinen_key.read_key("no key here\n")

    def test_device_id_is_optional(self) -> None:
        text = "HINEN_LOCAL_KEY=0123456789abcdef\nHINEN_DEVICE_ID=00112233445566778899\n"
        self.assertEqual(
            set_hinen_key.read_device_id(text), "00112233445566778899"
        )
        self.assertIsNone(set_hinen_key.read_device_id(""))


class EnvironmentFileTests(unittest.TestCase):
    def test_merge_preserves_other_lines(self) -> None:
        merged = set_hinen_key.merge_env(
            "OTHER=value\nHINEN_LOCAL_KEY=old\n# keep\n",
            {"HINEN_LOCAL_KEY": "0123456789abcdef", "HINEN_DEVICE_ID": "device"},
        )
        self.assertIn("OTHER=value", merged)
        self.assertIn("# keep", merged)
        self.assertIn("HINEN_LOCAL_KEY=0123456789abcdef", merged)
        self.assertIn("HINEN_DEVICE_ID=device", merged)
        self.assertNotIn("HINEN_LOCAL_KEY=old", merged)

    def test_write_env_file_is_mode_600(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "hinen.env"
            path.write_text("OTHER=value\n", encoding="utf-8")
            os.chmod(path, 0o644)
            set_hinen_key.write_env_file(
                path, {"HINEN_LOCAL_KEY": "0123456789abcdef"}
            )
            mode = stat.S_IMODE(path.stat().st_mode)
            self.assertEqual(mode, 0o600)
            text = path.read_text(encoding="utf-8")
            self.assertIn("OTHER=value", text)
            self.assertIn("HINEN_LOCAL_KEY=0123456789abcdef", text)


if __name__ == "__main__":
    unittest.main()
