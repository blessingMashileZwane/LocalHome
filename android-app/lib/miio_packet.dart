/// Local miIO packet framing and token-derived AES-CBC encryption.
///
/// The packet layout follows the documented miIO framing: a 16-byte header, an
/// MD5 checksum over the header, token, and encrypted payload, then the
/// encrypted JSON body. No vendor cloud is involved.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/md5.dart';

const int miioPort = 54321;
const int miioMaxPropertiesPerRequest = 15;
const int miioMaxPacketBytes = 4096;

const int _miioMagic = 0x2131;
const int _miioHeaderBytes = 16;
const int _miioOverhead = 32;

final Uint8List miioHelloPacket = Uint8List.fromList(<int>[
  0x21,
  0x31,
  0x00,
  0x20,
  ...List<int>.filled(28, 0xff),
]);

class MiioException implements Exception {
  const MiioException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MiioAuthException extends MiioException {
  const MiioAuthException(super.message);
}

class MiioTimeoutException extends MiioException {
  const MiioTimeoutException(super.message);
}

Uint8List parseMiioToken(String value) {
  final text = value.trim();
  if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(text)) {
    throw const MiioException(
      'The token must be 32 hexadecimal characters.',
    );
  }
  final token = Uint8List(16);
  for (var index = 0; index < 16; index++) {
    token[index] = int.parse(text.substring(index * 2, index * 2 + 2), radix: 16);
  }
  return token;
}

class MiioResponse {
  const MiioResponse({
    required this.deviceId,
    required this.stamp,
    this.payload,
  });

  final Uint8List deviceId;
  final int stamp;
  final Map<String, dynamic>? payload;
}

class MiioPacket {
  const MiioPacket._();

  static Uint8List buildRequest({
    required Map<String, Object?> payload,
    required Uint8List token,
    required Uint8List deviceId,
    required int stamp,
  }) {
    if (deviceId.length != 4) {
      throw const MiioException('The device identifier is not valid.');
    }
    final plaintext = Uint8List.fromList(<int>[
      ...utf8.encode(jsonEncode(payload)),
      0,
    ]);
    final encrypted = _encrypt(plaintext, token);
    final header = _header(encrypted.length + _miioOverhead, deviceId, stamp);
    final checksum = _md5(<int>[...header, ...token, ...encrypted]);
    return Uint8List.fromList(<int>[...header, ...checksum, ...encrypted]);
  }

  static MiioResponse parseResponse(Uint8List packet, Uint8List token) {
    if (packet.length < _miioOverhead || packet.length > miioMaxPacketBytes) {
      throw const MiioException('The purifier sent an invalid packet.');
    }
    final view = ByteData.sublistView(packet);
    final magic = view.getUint16(0, Endian.big);
    final length = view.getUint16(2, Endian.big);
    if (magic != _miioMagic || length != packet.length) {
      throw const MiioException('The purifier sent an invalid packet.');
    }
    final deviceId = Uint8List.fromList(packet.sublist(8, 12));
    final stamp = view.getUint32(12, Endian.big);
    if (length == _miioOverhead) {
      return MiioResponse(deviceId: deviceId, stamp: stamp);
    }

    final checksum = packet.sublist(16, 32);
    final encrypted = Uint8List.fromList(packet.sublist(32));
    final expected = _md5(<int>[
      ...packet.sublist(0, _miioHeaderBytes),
      ...token,
      ...encrypted,
    ]);
    if (!_bytesEqual(checksum, expected)) {
      throw const MiioAuthException('The purifier rejected the token.');
    }

    final plaintext = _decrypt(encrypted, token);
    var end = plaintext.length;
    while (end > 0 && plaintext[end - 1] == 0) {
      end--;
    }
    try {
      final decoded = utf8.decode(plaintext.sublist(0, end));
      final parsed = jsonDecode(decoded);
      if (parsed is! Map) {
        throw const FormatException();
      }
      return MiioResponse(
        deviceId: deviceId,
        stamp: stamp,
        payload: parsed.cast<String, dynamic>(),
      );
    } on FormatException {
      throw const MiioException(
        'The purifier sent a response that could not be read.',
      );
    }
  }
}

Uint8List _header(int length, Uint8List deviceId, int stamp) {
  final header = Uint8List(_miioHeaderBytes);
  final view = ByteData.sublistView(header);
  view.setUint16(0, _miioMagic, Endian.big);
  view.setUint16(2, length, Endian.big);
  view.setUint32(4, 0, Endian.big);
  header.setRange(8, 12, deviceId);
  view.setUint32(12, stamp & 0xffffffff, Endian.big);
  return header;
}

Uint8List _keyIv(Uint8List token) {
  final key = _md5(token);
  final iv = _md5(<int>[...key, ...token]);
  return Uint8List.fromList(<int>[...key, ...iv]);
}

Uint8List _encrypt(List<int> plaintext, Uint8List token) {
  final material = _keyIv(token);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV(
        KeyParameter(Uint8List.sublistView(material, 0, 16)),
        Uint8List.sublistView(material, 16, 32),
      ),
    );
  final padded = _pkcs7Pad(plaintext);
  final output = Uint8List(padded.length);
  for (var offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, output, offset);
  }
  return output;
}

Uint8List _decrypt(Uint8List ciphertext, Uint8List token) {
  if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
    throw const MiioException('The purifier sent an invalid encrypted body.');
  }
  final material = _keyIv(token);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV(
        KeyParameter(Uint8List.sublistView(material, 0, 16)),
        Uint8List.sublistView(material, 16, 32),
      ),
    );
  final output = Uint8List(ciphertext.length);
  for (var offset = 0; offset < ciphertext.length; offset += 16) {
    cipher.processBlock(ciphertext, offset, output, offset);
  }
  return _pkcs7Unpad(output);
}

Uint8List _md5(List<int> data) =>
    Uint8List.fromList(MD5Digest().process(Uint8List.fromList(data)));

bool _bytesEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

Uint8List _pkcs7Pad(List<int> data) {
  final padLength = 16 - (data.length % 16);
  final output = Uint8List(data.length + padLength);
  output.setRange(0, data.length, data);
  output.fillRange(data.length, output.length, padLength);
  return output;
}

Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) return data;
  final padLength = data.last;
  if (padLength < 1 || padLength > 16 || padLength > data.length) {
    throw const MiioException('The purifier sent invalid padding.');
  }
  for (var index = data.length - padLength; index < data.length; index++) {
    if (data[index] != padLength) {
      throw const MiioException('The purifier sent invalid padding.');
    }
  }
  return Uint8List.sublistView(data, 0, data.length - padLength);
}
