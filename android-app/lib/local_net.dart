/// Shared private-IPv4 validation for local-only modules.
///
/// Only the three RFC1918 ranges are accepted. Loopback, link-local, CGNAT,
/// multicast, IPv6, hostnames, and public addresses are rejected.
library;

bool isPrivateIpv4(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;

  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty ||
        part.length > 3 ||
        (part.length > 1 && part.startsWith('0')) ||
        !RegExp(r'^\d+$').hasMatch(part)) {
      return false;
    }
    final value = int.tryParse(part);
    if (value == null || value > 255) return false;
    octets.add(value);
  }

  return octets[0] == 10 ||
      (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] == 192 && octets[1] == 168);
}
