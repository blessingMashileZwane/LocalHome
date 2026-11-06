/// Local miIO/MIoT client for Xiaomi air purifiers.
///
/// Talks to the purifier on UDP 54321 with the token-derived AES-CBC framing.
/// Status reads and allowlisted controls stay on the private LAN; no Xiaomi
/// account, cloud endpoint, or relay is used. The token is never logged or
/// surfaced by the client.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'airpurifier_status.dart';
import 'local_net.dart';
import 'miio_packet.dart';

typedef MiioTransportFactory =
    Future<MiioTransport> Function(String address, int port);

abstract class MiioTransport {
  Future<Uint8List> exchange(Uint8List packet, {required Duration timeout});
  Future<void> close();
}

class UdpMiioTransport implements MiioTransport {
  UdpMiioTransport._(this._address, this._port);

  final String _address;
  final int _port;
  bool _closed = false;

  static Future<MiioTransport> connect(String address, int port) async {
    return UdpMiioTransport._(address, port);
  }

  @override
  Future<Uint8List> exchange(
    Uint8List packet, {
    required Duration timeout,
  }) async {
    if (_closed) {
      throw const MiioException('The purifier session is closed.');
    }
    late final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException {
      throw const MiioException('Could not open a local UDP socket.');
    }
    final completer = Completer<Uint8List>();
    late final StreamSubscription<RawSocketEvent> subscription;
    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      if (datagram.address.address != _address) return;
      if (!completer.isCompleted) {
        completer.complete(datagram.data);
      }
    });
    try {
      socket.send(packet, InternetAddress(_address), _port);
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw const MiioTimeoutException(
        'No response from the purifier on UDP 54321.',
      );
    } on SocketException {
      throw const MiioTimeoutException(
        'Could not reach the purifier on UDP 54321.',
      );
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

class MiioDeviceInfo {
  const MiioDeviceInfo({required this.model, this.firmware, this.hardware});

  final String model;
  final String? firmware;
  final String? hardware;
}

class MiioPurifierClient {
  MiioPurifierClient({
    required this.address,
    required Uint8List token,
    this.port = miioPort,
    this.timeout = const Duration(seconds: 4),
    this.readbackTimeout = const Duration(seconds: 3),
    MiioTransportFactory? transportFactory,
  }) : _token = token,
       _transportFactory = transportFactory ?? UdpMiioTransport.connect;

  final String address;
  final int port;
  final Duration timeout;
  final Duration readbackTimeout;
  final Uint8List _token;
  final MiioTransportFactory _transportFactory;

  MiioTransport? _transport;
  Uint8List? _deviceId;
  int _deviceStamp = 0;
  DateTime? _handshakeAt;
  int _requestId = 0;
  bool _closed = false;
  bool _knownModel = false;
  Map<String, PurifierProperty> _properties = propertiesForModel('');
  PurifierProperty? _favoriteAlternate;
  MiioDeviceInfo? _info;

  MiioDeviceInfo? get info => _info;

  Future<MiioDeviceInfo> connect() async {
    if (!isPrivateIpv4(address)) {
      throw const MiioException(
        'The purifier address must be a private IPv4 address.',
      );
    }
    await _ensureTransport();
    await _handshake();
    final info = await _request('miIO.info', const <Object>[]);
    if (info is! Map) {
      throw const MiioException(
        'The purifier did not return device information.',
      );
    }
    final model = info['model'];
    if (model is! String || model.isEmpty) {
      throw const MiioException('The purifier did not report its model.');
    }
    _knownModel = purifierModelAliases.containsKey(model);
    _properties = propertiesForModel(model);
    _favoriteAlternate = alternateFavoriteLevel(model);
    final firmware = info['fw_ver'];
    final hardware = info['hw_ver'];
    _info = MiioDeviceInfo(
      model: model,
      firmware: firmware is String ? firmware : null,
      hardware: hardware is String ? hardware : null,
    );
    // The raw info map may contain the token and MAC; do not retain it.
    return _info!;
  }

  Future<void> _ensureTransport() async {
    if (_closed) {
      throw const MiioException('The purifier session is closed.');
    }
    if (_transport != null) return;
    _transport = await _transportFactory(address, port);
  }

  Future<void> _handshake() async {
    final response = await _exchange(miioHelloPacket);
    if (response.deviceId.length != 4) {
      throw const MiioException('The purifier sent an invalid handshake.');
    }
    _deviceId = response.deviceId;
    _deviceStamp = response.stamp;
    _handshakeAt = DateTime.now();
  }

  Future<MiioResponse> _exchange(Uint8List packet) async {
    final transport = _transport;
    if (transport == null) {
      throw const MiioException('The purifier session is not connected.');
    }
    final data = await transport.exchange(packet, timeout: timeout);
    return MiioPacket.parseResponse(data, _token);
  }

  Future<Object?> _request(
    String method,
    Object params, {
    bool retry = true,
  }) async {
    if (_closed) {
      throw const MiioException('The purifier session is closed.');
    }
    final attempts = retry ? 2 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final handshakeAt = _handshakeAt;
      if (_deviceId == null ||
          handshakeAt == null ||
          DateTime.now().difference(handshakeAt) >
              const Duration(minutes: 5)) {
        await _handshake();
      }
      _requestId = _requestId % 9998 + 1;
      final payload = <String, Object?>{
        'id': _requestId,
        'method': method,
        'params': params,
      };
      final packet = MiioPacket.buildRequest(
        payload: payload,
        token: _token,
        deviceId: _deviceId!,
        stamp: _deviceStamp + 1,
      );
      MiioResponse response;
      try {
        response = await _exchange(packet);
      } on MiioTimeoutException {
        _handshakeAt = null;
        if (attempt + 1 < attempts) continue;
        rethrow;
      }
      _deviceStamp = response.stamp;
      final body = response.payload;
      if (body == null) {
        throw const MiioException('The purifier sent an incomplete response.');
      }
      final responseId = body['id'];
      if (responseId is int && responseId != _requestId) {
        throw const MiioException(
          'The purifier response did not match the request.',
        );
      }
      final error = body['error'];
      if (error is Map) {
        final code = error['code'];
        if ((code == -30001 || code == -9999) && attempt + 1 < attempts) {
          _handshakeAt = null;
          continue;
        }
        throw MiioException(_deviceErrorMessage(code));
      }
      return body['result'];
    }
    throw const MiioException('The purifier did not answer.');
  }

  Future<List<Map<String, dynamic>>> _readEntries(
    List<PurifierProperty> properties,
  ) async {
    final entries = <Map<String, dynamic>>[];
    for (
      var start = 0;
      start < properties.length;
      start += miioMaxPropertiesPerRequest
    ) {
      final end = min(
        start + miioMaxPropertiesPerRequest,
        properties.length,
      );
      final chunk = properties.sublist(start, end);
      final params = <Map<String, Object>>[
        for (final property in chunk)
          {
            'did': property.name,
            'siid': property.siid,
            'piid': property.piid,
          },
      ];
      final result = await _request('get_properties', params);
      if (result is! List) {
        throw const MiioException(
          'The purifier did not return property values.',
        );
      }
      for (final entry in result) {
        if (entry is Map) {
          entries.add(entry.cast<String, dynamic>());
        }
      }
    }
    return entries;
  }

  Future<AirPurifierStatus> readStatus() async {
    if (_info == null) {
      await connect();
    }
    final info = _info!;
    if (!_knownModel) {
      return AirPurifierStatus(
        model: info.model,
        firmware: info.firmware,
        hardware: info.hardware,
        values: const <String, Object?>{},
        unsupported: const <String>{},
        errors: const <String, int>{},
        receivedAt: DateTime.now(),
      );
    }
    final properties = _properties.values
        .where((property) => !property.hidden)
        .toList(growable: false);
    final entries = await _readEntries(properties);
    var status = parseStatus(
      model: info.model,
      firmware: info.firmware,
      hardware: info.hardware,
      entries: entries,
      properties: _properties,
      receivedAt: DateTime.now(),
    );

    final alternate = _favoriteAlternate;
    if (alternate != null &&
        _properties['favorite_level'] != alternate &&
        status.unsupported.contains('favorite_level')) {
      final alternateEntries = await _readEntries([alternate]);
      final merged = parseStatus(
        model: info.model,
        firmware: info.firmware,
        hardware: info.hardware,
        entries: [...entries, ...alternateEntries],
        properties: {..._properties, 'favorite_level': alternate},
        receivedAt: DateTime.now(),
      );
      if (!merged.unsupported.contains('favorite_level')) {
        _properties['favorite_level'] = alternate;
        status = merged;
      }
    }
    return status;
  }

  Future<AirPurifierStatus> _waitForValue(
    String name,
    Object? expected,
  ) async {
    final deadline = DateTime.now().add(readbackTimeout);
    var status = await readStatus();
    while (status.values[name] != expected) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < const Duration(milliseconds: 400)
            ? remaining
            : const Duration(milliseconds: 400),
      );
      status = await readStatus();
    }
    return status;
  }

  Future<ControlResult> setProperty(String name, Object? value) async {
    if (_info == null) {
      await connect();
    }
    if (!_knownModel) {
      throw const MiioException(
        'Writing to an unknown purifier model is not supported.',
      );
    }
    final property = _properties[name];
    if (property == null || !property.writable) {
      throw const MiioException('That purifier setting is not supported.');
    }
    final checked = validateControlValue(property, value);
    final params = <Map<String, Object>>[
      {
        'did': property.name,
        'siid': property.siid,
        'piid': property.piid,
        'value': checked,
      },
    ];
    final result = await _request('set_properties', params, retry: false);
    final resultEntries = result is List ? result : <Object?>[result];
    for (final entry in resultEntries) {
      if (entry is! Map) continue;
      final code = entry['code'];
      if (code is int && code != 0) {
        throw MiioException(_deviceErrorMessage(code));
      }
    }
    final status = await _waitForValue(property.name, checked);
    final applied = status.values[property.name] == checked;
    if (!applied) {
      return ControlResult(
        status: status,
        applied: false,
        error: 'The purifier did not apply that change.',
      );
    }
    return ControlResult(status: status, applied: true);
  }

  Future<ControlResult> resetFilter() async {
    if (_info == null) {
      await connect();
    }
    if (!_knownModel) {
      throw const MiioException(
        'Resetting the filter on an unknown model is not supported.',
      );
    }
    const params = <String, Object>{
      'did': 'call-4-1',
      'siid': 4,
      'aiid': 1,
      'in': [
        {'piid': 3, 'value': 0},
      ],
    };
    Object? result;
    try {
      result = await _request('action', params, retry: false);
    } on MiioTimeoutException {
      final status = await readStatus();
      return ControlResult(
        status: status,
        applied: false,
        error:
            'No response from the purifier; check the filter values before '
            'retrying.',
      );
    }
    int? code;
    if (result is Map) {
      final value = result['code'];
      if (value is int) code = value;
    } else if (result is List && result.isNotEmpty && result.first is Map) {
      final value = (result.first as Map)['code'];
      if (value is int) code = value;
    }
    if (code != null && code != 0) {
      throw MiioException(_deviceErrorMessage(code));
    }
    final status = await _waitForValue('filter_used_time', 0);
    if (status.values['filter_used_time'] != 0) {
      return ControlResult(
        status: status,
        applied: false,
        error: 'The purifier did not reset the filter counter.',
      );
    }
    return ControlResult(status: status, applied: true);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport?.close();
    _transport = null;
  }
}

String _deviceErrorMessage(Object? code) {
  if (code == -4001) return 'The device does not expose that property.';
  if (code == -30001 || code == -9999) return 'The device is busy.';
  if (code == -5001) return 'The device rejected that value.';
  if (code is int) return 'The device rejected the request (code $code).';
  return 'The device rejected the request.';
}
