import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// Minimal read-only Tuya LAN 3.4 client for the Hinen PS300.
///
/// The station speaks Tuya's 55AA framing on TCP 6668. The payload is
/// AES-128-ECB with the 16-character local key and a `3.4` protocol header.
/// Only a status query is implemented; there is no write/control method.
class TuyaException implements Exception {
  const TuyaException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TuyaFrame {
  const TuyaFrame({this.dps, this.ack = false});

  final Map<int, Object?>? dps;
  final bool ack;
}

class HinenTuyaClient {
  HinenTuyaClient({
    required this.address,
    required this.deviceId,
    required this.localKey,
    this.timeout = const Duration(seconds: 5),
  });

  final String address;
  final String deviceId;
  final String localKey;
  final Duration timeout;

  static const int port = 6668;
  static const int _prefix = 0x000055aa;
  static const int _suffix = 0x0000aa55;
  static const int _statusCommand = 16;
  static const int _maxFrameBytes = 8192;

  Future<Map<int, Object?>> readStatus() async {
    if (localKey.length != 16) {
      throw const TuyaException('The Tuya local key must be 16 characters.');
    }
    if (deviceId.isEmpty) {
      throw const TuyaException(
        'The device id is missing. Add the PS300 Virtual ID to the profile.',
      );
    }
    final socket = await Socket.connect(address, port, timeout: timeout);
    final reader = _SocketReader(socket, timeout);
    try {
      final sequence = DateTime.now().microsecondsSinceEpoch & 0x3fffffff;
      socket.add(buildStatusPacket(
        deviceId: deviceId,
        localKey: localKey,
        sequence: sequence,
      ));
      await socket.flush();
      for (var attempt = 0; attempt < 4; attempt++) {
        final frame = await reader.readFrame();
        final parsed = parseFrame(frame, localKey);
        if (parsed.dps != null) {
          return parsed.dps!;
        }
        if (!parsed.ack) {
          throw const TuyaException('The station returned an empty response.');
        }
      }
      throw const TuyaException('The station returned no status payload.');
    } on TuyaException {
      rethrow;
    } on Object catch (error) {
      throw TuyaException('Could not read the station: ${error.runtimeType}.');
    } finally {
      socket.destroy();
    }
  }

  /// Builds the read-only 3.4 DP_QUERY_NEW request.
  static Uint8List buildStatusPacket({
    required String deviceId,
    required String localKey,
    required int sequence,
  }) {
    // DP_QUERY_NEW (16) is in Tuya's no-protocol-header command list, so the
    // encrypted payload is only the empty JSON object.
    final encrypted = encryptPayload(
      Uint8List.fromList(utf8.encode('{}')),
      localKey,
    );
    return buildFrame(encrypted, _statusCommand, sequence, localKey);
  }

  static Uint8List buildFrame(
    Uint8List payload,
    int command,
    int sequence,
    String localKey,
  ) {
    final header = ByteData(16)
      ..setUint32(0, _prefix)
      ..setUint32(4, sequence)
      ..setUint32(8, command)
      ..setUint32(12, payload.length + 36);
    final body = BytesBuilder()
      ..add(header.buffer.asUint8List())
      ..add(payload);
    final data = body.toBytes();
    final tag = hmacSha256(utf8.encode(localKey), data);
    return (BytesBuilder()
          ..add(data)
          ..add(tag)
          ..add(uint32(_suffix)))
        .toBytes();
  }

  /// Builds a device-style response with a zero retcode; test-only helper.
  @visibleForTesting
  static Uint8List buildResponseFrame(
    Uint8List payload,
    int command,
    int sequence,
    String localKey,
  ) {
    final header = ByteData(16)
      ..setUint32(0, _prefix)
      ..setUint32(4, sequence)
      ..setUint32(8, command)
      ..setUint32(12, payload.length + 40);
    final body = BytesBuilder()
      ..add(header.buffer.asUint8List())
      ..add(uint32(0))
      ..add(payload);
    final data = body.toBytes();
    final tag = hmacSha256(utf8.encode(localKey), data);
    return (BytesBuilder()
          ..add(data)
          ..add(tag)
          ..add(uint32(_suffix)))
        .toBytes();
  }

  static TuyaFrame parseFrame(Uint8List frame, String localKey) {
    if (frame.length < 24) {
      throw const TuyaException('The response is too short.');
    }
    final header = ByteData.sublistView(frame);
    if (header.getUint32(0) != _prefix) {
      throw const TuyaException('The response has an unexpected prefix.');
    }
    final total = 16 + header.getUint32(12);
    if (total > _maxFrameBytes || frame.length < total) {
      throw const TuyaException('The response length is invalid.');
    }
    final suffix = header.getUint32(total - 4);
    if (suffix != _suffix) {
      throw const TuyaException('The response has an unexpected suffix.');
    }
    final tagStart = total - 36;
    if (tagStart < 20) {
      throw const TuyaException('The response is too short.');
    }
    final expectedTag = hmacSha256(
      utf8.encode(localKey),
      Uint8List.sublistView(frame, 0, tagStart),
    );
    final actualTag = Uint8List.sublistView(frame, tagStart, total - 4);
    if (!_equalBytes(expectedTag, actualTag)) {
      throw const TuyaException('The response signature is invalid.');
    }
    final retcode = header.getUint32(16);
    if (retcode != 0) {
      throw TuyaException('The station returned error $retcode.');
    }
    final encrypted = Uint8List.sublistView(frame, 20, tagStart);
    if (encrypted.isEmpty) {
      return const TuyaFrame(ack: true);
    }
    final decrypted = decryptPayload(encrypted, localKey);
    var text = utf8.decode(decrypted);
    final jsonStart = text.indexOf('{');
    if (jsonStart < 0) {
      throw const TuyaException('The station response has no JSON body.');
    }
    text = text.substring(jsonStart);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const TuyaException('The station response is not a JSON object.');
    }
    var dps = decoded['dps'];
    if (dps == null && decoded['data'] is Map) {
      dps = (decoded['data'] as Map)['dps'];
    }
    if (dps is! Map) {
      throw const TuyaException('The station returned no DP map.');
    }
    final result = <int, Object?>{};
    for (final entry in dps.entries) {
      final id = int.tryParse(entry.key.toString());
      if (id != null) {
        result[id] = entry.value;
      }
    }
    return TuyaFrame(dps: result);
  }

  static Uint8List encryptPayload(Uint8List plain, String localKey) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      ECBBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<CipherParameters?, CipherParameters?>(
          KeyParameter(utf8.encode(localKey)),
          null,
        ),
      );
    return cipher.process(plain);
  }

  static Uint8List decryptPayload(Uint8List encrypted, String localKey) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      ECBBlockCipher(AESEngine()),
    )..init(
        false,
        PaddedBlockCipherParameters<CipherParameters?, CipherParameters?>(
          KeyParameter(utf8.encode(localKey)),
          null,
        ),
      );
    return cipher.process(encrypted);
  }

  static Uint8List uint32(int value) {
    final data = ByteData(4)..setUint32(0, value & 0xffffffff);
    return data.buffer.asUint8List();
  }

  static Uint8List hmacSha256(List<int> key, List<int> data) {
    final hmac = HMac(SHA256Digest(), 64)
      ..init(KeyParameter(Uint8List.fromList(key)));
    return hmac.process(Uint8List.fromList(data));
  }

  /// Short non-secret check value for comparing the stored key with its source.
  static String keyCheck(String localKey) {
    final digest = SHA256Digest().process(utf8.encode(localKey));
    return digest
        .take(6)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static bool _equalBytes(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  static int crc32(List<int> data) {
    var crc = 0xffffffff;
    for (final byte in data) {
      crc ^= byte & 0xff;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}

class _SocketReader {
  _SocketReader(Socket socket, this.timeout)
    : _iterator = StreamIterator<Uint8List>(socket);

  final StreamIterator<Uint8List> _iterator;
  final Duration timeout;
  Uint8List _buffer = Uint8List(0);

  Future<Uint8List> _read(int count) async {
    while (_buffer.length < count) {
      final hasNext = await _iterator.moveNext().timeout(timeout);
      if (!hasNext) {
        throw const TuyaException('The station closed the connection.');
      }
      final chunk = _iterator.current;
      final merged = Uint8List(_buffer.length + chunk.length)
        ..setRange(0, _buffer.length, _buffer)
        ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
      _buffer = merged;
    }
    final value = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer = Uint8List.fromList(_buffer.sublist(count));
    return value;
  }

  Future<Uint8List> readFrame() async {
    final header = await _read(16);
    final length = ByteData.sublistView(header).getUint32(12);
    if (length > 8192) {
      throw const TuyaException('The station response is too large.');
    }
    final rest = await _read(length);
    return Uint8List.fromList(<int>[...header, ...rest]);
  }
}
