from __future__ import annotations

import json
import unittest

import inject_purifier

PROFILE = {
    "id": "purifier-1",
    "name": "Air purifier",
    "address": "192.168.1.60",
    "modelId": "xiaomi.airp.cpa4",
}


class UpdateProfilesTests(unittest.TestCase):
    def test_adds_when_empty(self) -> None:
        self.assertEqual(
            inject_purifier.update_profiles(None, PROFILE), [PROFILE]
        )

    def test_updates_matching_address(self) -> None:
        raw = json.dumps(
            [
                {
                    "id": "old-id",
                    "name": "Old name",
                    "address": PROFILE["address"],
                    "modelId": "",
                }
            ]
        )
        profiles = inject_purifier.update_profiles(raw, PROFILE)
        self.assertEqual(len(profiles), 1)
        self.assertEqual(profiles[0]["id"], PROFILE["id"])
        self.assertEqual(profiles[0]["name"], PROFILE["name"])
        self.assertEqual(profiles[0]["modelId"], PROFILE["modelId"])

    def test_preserves_other_profiles(self) -> None:
        other = {
            "id": "other",
            "name": "Other",
            "address": "192.168.1.50",
            "modelId": "",
        }
        raw = json.dumps([other])
        profiles = inject_purifier.update_profiles(raw, PROFILE)
        self.assertEqual(len(profiles), 2)
        self.assertEqual(profiles[0], other)
        self.assertEqual(profiles[1], PROFILE)

    def test_rejects_non_list(self) -> None:
        with self.assertRaises(ValueError):
            inject_purifier.update_profiles(json.dumps({"id": "x"}), PROFILE)


if __name__ == "__main__":
    unittest.main()
