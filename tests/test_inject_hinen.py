from __future__ import annotations

import json
import unittest

import inject_hinen
from inject_lanpass import merge_string_preference


class ProfileMergeTests(unittest.TestCase):
    def test_appends_a_new_profile(self) -> None:
        profile = {
            "id": "hinen-1",
            "name": "PS300",
            "address": "192.168.1.50",
            "productKey": "YOURPRODUCTKEY00",
            "model": "PS300",
        }
        profiles = inject_hinen.update_profiles(None, profile)
        self.assertEqual(profiles, [profile])

    def test_merges_by_id_and_preserves_others(self) -> None:
        existing = [
            {"id": "other", "name": "Other", "address": "10.0.0.2"},
            {"id": "hinen-1", "name": "Old", "address": "192.168.1.50"},
        ]
        profile = {
            "id": "hinen-1",
            "name": "PS300",
            "address": "192.168.1.50",
            "productKey": "YOURPRODUCTKEY00",
            "model": "PS300",
        }
        profiles = inject_hinen.update_profiles(json.dumps(existing), profile)
        self.assertEqual(len(profiles), 2)
        self.assertEqual(profiles[0]["name"], "Other")
        self.assertEqual(profiles[1]["name"], "PS300")
        self.assertEqual(profiles[1]["productKey"], "YOURPRODUCTKEY00")

    def test_merges_by_address(self) -> None:
        existing = [
            {"id": "old-id", "name": "Station", "address": "192.168.1.50"}
        ]
        profile = {
            "id": "hinen-1",
            "name": "PS300",
            "address": "192.168.1.50",
            "productKey": "YOURPRODUCTKEY00",
            "model": "PS300",
        }
        profiles = inject_hinen.update_profiles(json.dumps(existing), profile)
        self.assertEqual(len(profiles), 1)
        self.assertEqual(profiles[0]["id"], "hinen-1")
        self.assertEqual(profiles[0]["name"], "PS300")

    def test_invalid_profile_data_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            inject_hinen.update_profiles('{"not": "a list"}', {})
        with self.assertRaises(json.JSONDecodeError):
            inject_hinen.update_profiles("not json", {})


class SharedPreferencesTests(unittest.TestCase):
    def test_profile_preference_round_trips(self) -> None:
        profile = {
            "id": "hinen-1",
            "name": "PS300",
            "address": "192.168.1.50",
            "productKey": "YOURPRODUCTKEY00",
            "model": "PS300",
        }
        first = merge_string_preference(
            None, inject_hinen.KEY, json.dumps([profile])
        )
        second = merge_string_preference(
            first, "flutter.camera_profiles", "[]"
        )
        raw = inject_hinen.existing_profiles(second)
        self.assertIsNotNone(raw)
        self.assertEqual(json.loads(raw or "[]"), [profile])
        self.assertIn(b"flutter.camera_profiles", second)
        self.assertNotIn(b"localKey", second)
        self.assertNotIn(b"HINEN_LOCAL_KEY", second)


if __name__ == "__main__":
    unittest.main()
