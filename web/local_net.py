"""Shared private-IPv4 validation for local-only modules.

Only the three RFC1918 ranges are accepted. Loopback, link-local, CGNAT,
multicast, all IPv6, hostnames, and public addresses are rejected so a module
cannot silently leave the private LAN.
"""

from __future__ import annotations

from ipaddress import IPv4Address


def is_private_ipv4(value: str) -> bool:
    try:
        address = IPv4Address(value)
    except ValueError:
        return False
    octets = address.packed
    return (
        octets[0] == 10
        or (octets[0] == 172 and 16 <= octets[1] <= 31)
        or (octets[0] == 192 and octets[1] == 168)
    )
