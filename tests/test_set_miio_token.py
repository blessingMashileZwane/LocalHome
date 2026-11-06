from __future__ import annotations

import unittest

import set_miio_token as importer

TOKEN = "00112233445566778899aabbccddeeff"


class ReadTokenTests(unittest.TestCase):
    def test_plain_token(self) -> None:
        self.assertEqual(importer.read_token(TOKEN), TOKEN)
        self.assertEqual(importer.read_token(f"  {TOKEN}\n"), TOKEN)

    def test_labelled_token(self) -> None:
        self.assertEqual(importer.read_token(f"MIIO_TOKEN={TOKEN}"), TOKEN)
        self.assertEqual(importer.read_token(f"TOKEN: {TOKEN}"), TOKEN)

    def test_rejects_missing_or_multiple_tokens(self) -> None:
        for text in ("not a token", "", "00" * 16 + "\n" + "11" * 16):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    importer.read_token(text)

    def test_uppercase_is_normalized(self) -> None:
        self.assertEqual(importer.read_token(TOKEN.upper()), TOKEN)


if __name__ == "__main__":
    unittest.main()
