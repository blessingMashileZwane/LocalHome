from __future__ import annotations

import os
import pathlib
import tempfile
import unittest

import miio_token_from_cloud as bootstrap

TOKEN = "00112233445566778899aabbccddeeff"


class MergeTokenTests(unittest.TestCase):
    def test_replaces_existing_token_and_preserves_other_keys(self) -> None:
        existing = "V380_LANPASS_121=secret\nMIIO_TOKEN=old\nOTHER=value\n"
        merged = bootstrap.merge_token(existing, TOKEN)
        self.assertIn("V380_LANPASS_121=secret", merged)
        self.assertIn("OTHER=value", merged)
        self.assertEqual(merged.count("MIIO_TOKEN="), 1)
        self.assertIn(f"MIIO_TOKEN={TOKEN}", merged)

    def test_appends_when_no_token_exists(self) -> None:
        merged = bootstrap.merge_token("", TOKEN)
        self.assertEqual(merged, f"MIIO_TOKEN={TOKEN}\n")


class SelectTests(unittest.TestCase):
    devices = [
        {"name": "Living room purifier", "model": "zhimi.airp.mb5a"},
        {"name": "Bedroom", "model": "zhimi.airp.vb4"},
        {"name": "Desk lamp", "model": "yeelink.light.bslamp2"},
        {"name": "Compact", "model": "xiaomi.airp.cpa4"},
    ]

    def test_filters_purifiers(self) -> None:
        self.assertEqual(len(bootstrap.select_candidates(self.devices, None)), 3)

    def test_device_filter(self) -> None:
        selected = bootstrap.select_candidates(self.devices, "bedroom")
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]["model"], "zhimi.airp.vb4")

    def test_matches_cpa4(self) -> None:
        selected = bootstrap.select_candidates(self.devices, "compact")
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]["model"], "xiaomi.airp.cpa4")

    def test_rejects_non_purifier(self) -> None:
        self.assertFalse(
            bootstrap.is_purifier(
                {"name": "Desk lamp", "model": "yeelink.light.bslamp2"}
            )
        )


class WriteTokenFileTests(unittest.TestCase):
    def test_writes_mode_600_and_preserves_other_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sub" / "localhome-miio.env"
            path.parent.mkdir()
            path.write_text("OTHER=value\nMIIO_TOKEN=old\n", encoding="utf-8")

            bootstrap.write_token_file(path, TOKEN)

            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            text = path.read_text(encoding="utf-8")
            self.assertIn("OTHER=value", text)
            self.assertIn(f"MIIO_TOKEN={TOKEN}", text)


if __name__ == "__main__":
    unittest.main()
