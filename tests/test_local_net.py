from __future__ import annotations

import unittest

from local_net import is_private_ipv4


class PrivateIpv4Tests(unittest.TestCase):
    def test_accepts_rfc1918_ranges(self) -> None:
        for value in (
            "10.0.0.1",
            "10.255.255.254",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.0.1",
            "192.168.1.100",
        ):
            with self.subTest(value=value):
                self.assertTrue(is_private_ipv4(value))

    def test_rejects_everything_else(self) -> None:
        for value in (
            "172.15.0.1",
            "172.32.0.1",
            "192.167.1.20",
            "8.8.8.8",
            "127.0.0.1",
            "169.254.1.1",
            "100.64.0.1",
            "0.0.0.0",
            "255.255.255.255",
            "224.0.0.1",
            "camera.local",
            "::1",
            "fd00::1",
            "192.168.001.20",
            "192.168.1.256",
            "",
        ):
            with self.subTest(value=value):
                self.assertFalse(is_private_ipv4(value))


if __name__ == "__main__":
    unittest.main()
