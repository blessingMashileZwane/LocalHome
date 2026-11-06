from __future__ import annotations

import json
import unittest
import xml.etree.ElementTree as ET

import inject_lanpass


def _xml(children: str) -> bytes:
    return (
        "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n"
        f"<map>{children}</map>"
    ).encode()


class MergeCameraProfilesTests(unittest.TestCase):
    def test_preserves_other_preference_keys(self) -> None:
        purifier = [
            {"id": "p1", "name": "Living room", "address": "192.168.1.50"}
        ]
        camera = [
            {
                "id": "c1",
                "name": "Garage",
                "address": "192.168.1.60",
                "path": "/live/ch00_0",
                "lanPassword": "",
            }
        ]
        data = _xml(
            f'<string name="flutter.airpurifier_profiles">'
            f"{json.dumps(purifier)}</string>"
            f'<string name="flutter.camera_profiles">'
            f"{json.dumps(camera)}</string>"
            '<int name="flutter.some_counter" value="3" />'
        )
        updated = [dict(camera[0], lanPassword="secret")]

        merged = inject_lanpass.merge_camera_profiles(data, updated)

        root = ET.fromstring(merged)
        values = {
            node.get("name"): node.text for node in root.findall("string")
        }
        self.assertEqual(
            json.loads(values["flutter.airpurifier_profiles"]), purifier
        )
        self.assertEqual(
            json.loads(values["flutter.camera_profiles"]), updated
        )
        self.assertEqual(root.find("int").get("value"), "3")

    def test_creates_a_map_when_no_store_exists(self) -> None:
        profiles = [{"id": "c1"}]
        merged = inject_lanpass.merge_camera_profiles(None, profiles)
        root = ET.fromstring(merged)
        node = root.find("string")
        self.assertEqual(node.get("name"), inject_lanpass.KEY)
        self.assertEqual(json.loads(node.text), profiles)

    def test_updates_the_existing_camera_key(self) -> None:
        data = _xml('<string name="flutter.camera_profiles">[]</string>')
        merged = inject_lanpass.merge_camera_profiles(data, [{"id": "c2"}])
        root = ET.fromstring(merged)
        nodes = root.findall("string")
        self.assertEqual(len(nodes), 1)
        self.assertEqual(json.loads(nodes[0].text), [{"id": "c2"}])

    def test_malformed_xml_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            inject_lanpass.merge_camera_profiles(b"<map>", [])

    def test_profiles_from_xml(self) -> None:
        data = _xml(
            '<string name="flutter.camera_profiles">[{"id":"c1"}]</string>'
        )
        self.assertEqual(
            json.loads(inject_lanpass.profiles_from_xml(data)),
            [{"id": "c1"}],
        )
        self.assertIsNone(inject_lanpass.profiles_from_xml(None))

    def test_merge_string_preference_preserves_other_keys(self) -> None:
        data = _xml(
            '<string name="flutter.camera_profiles">[]</string>'
            '<int name="flutter.some_counter" value="3" />'
        )
        merged = inject_lanpass.merge_string_preference(
            data,
            "flutter.airpurifier_profiles",
            '[{"id":"p1"}]',
        )
        root = ET.fromstring(merged)
        values = {
            node.get("name"): node.text for node in root.findall("string")
        }
        self.assertEqual(values["flutter.camera_profiles"], "[]")
        self.assertEqual(
            json.loads(values["flutter.airpurifier_profiles"]),
            [{"id": "p1"}],
        )
        self.assertEqual(root.find("int").get("value"), "3")


if __name__ == "__main__":
    unittest.main()
