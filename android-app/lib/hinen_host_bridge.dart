import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_net.dart' show isPrivateIpv4;

/// Reads the PS300 through the LocalHome host panel.
///
/// The host keeps the Tuya local key; the phone never sends it. This is the
/// fallback for the station's single LAN-session restriction, where the host's
/// verified Tuya client can read but a second direct phone session is closed.
class HinenHostBridge {
  HinenHostBridge({required this.baseUrl});

  final String baseUrl;

  static const writableDps = {6, 7, 25, 26, 105, 106, 108, 109, 110, 113};

  Future<Map<int, Object?>> readStatus({
    required String address,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!isPrivateIpv4(address)) {
      throw const HinenHostBridgeException('The station address is not private.');
    }
    final decoded = await _post(
      '/api/hinen/status',
      {'ip': address},
      timeout,
    );
    return _parseDps(decoded);
  }

  Future<Map<int, Object?>> setDp({
    required String address,
    required int dp,
    required Object value,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!isPrivateIpv4(address)) {
      throw const HinenHostBridgeException('The station address is not private.');
    }
    if (!writableDps.contains(dp)) {
      throw const HinenHostBridgeException('That DP is not writable from the app.');
    }
    if (value is! bool && value is! int) {
      throw const HinenHostBridgeException('The DP value type is invalid.');
    }
    final decoded = await _post(
      '/api/hinen/write',
      {'ip': address, 'dp': dp, 'value': value},
      timeout,
    );
    return _parseDps(decoded);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object> payload,
    Duration timeout,
  ) async {
    final base = _baseUri();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(
        base.replace(path: path),
      ).timeout(timeout);
      final body = utf8.encode(jsonEncode(payload));
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(timeout);
      final reply = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HinenHostBridgeException(
          'The host bridge returned ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(reply);
      if (decoded is! Map<String, dynamic>) {
        throw const HinenHostBridgeException('The host bridge reply is invalid.');
      }
      return decoded;
    } on HinenHostBridgeException {
      rethrow;
    } on Object catch (error) {
      throw HinenHostBridgeException(
        'Could not reach the host bridge: ${error.runtimeType}.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<int, Object?> _parseDps(Map<String, dynamic> decoded) {
    final rawDps = decoded['dps'];
    if (rawDps is! Map) {
      throw const HinenHostBridgeException('The host bridge returned no DPs.');
    }
    final dps = <int, Object?>{};
    for (final entry in rawDps.entries) {
      final id = int.tryParse(entry.key.toString());
      if (id != null) dps[id] = entry.value;
    }
    return dps;
  }

  Uri _baseUri() {
    final value = baseUrl.trim();
    if (value.isEmpty) {
      throw const HinenHostBridgeException('The host bridge URL is empty.');
    }
    final withScheme = value.contains('://') ? value : 'http://$value';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw const HinenHostBridgeException('The host bridge URL is invalid.');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const HinenHostBridgeException('The host bridge must use HTTP.');
    }
    if (!isPrivateIpv4(uri.host)) {
      throw const HinenHostBridgeException(
        'The host bridge must be on the private LAN.',
      );
    }
    return uri;
  }
}

class HinenHostBridgeException implements Exception {
  const HinenHostBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}
