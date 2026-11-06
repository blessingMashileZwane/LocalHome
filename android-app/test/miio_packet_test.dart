import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/miio_packet.dart';

const tokenHex = '00112233445566778899aabbccddeeff';

final token = parseMiioToken(tokenHex);
final deviceId = Uint8List.fromList([1, 2, 3, 4]);

Map<String, Object?> requestPayload() => <String, Object?>{
  'id': 7,
  'method': 'get_properties',
  'params': [
    {'did': 'power', 'siid': 2, 'piid': 1},
  ],
};

void main() {
  group('parseMiioToken', () {
    test('accepts 32 hex characters', () {
      expect(token.length, 16);
      expect(token.first, 0x00);
      expect(token.last, 0xff);
    });

    test('rejects invalid tokens', () {
      for (final value in <String>['', '00' * 15, '00' * 17, 'zz' * 16, '0x11']) {
        expect(
          () => parseMiioToken(value),
          throwsA(isA<MiioException>()),
          reason: value,
        );
      }
    });
  });

  test('hello packet matches the documented bytes', () {
    expect(miioHelloPacket.length, 32);
    expect(miioHelloPacket.sublist(0, 4), <int>[0x21, 0x31, 0x00, 0x20]);
    expect(miioHelloPacket.sublist(4), List<int>.filled(28, 0xff));
  });

  test('request round-trips through parseResponse', () {
    final payload = requestPayload();
    final packet = MiioPacket.buildRequest(
      payload: payload,
      token: token,
      deviceId: deviceId,
      stamp: 1234,
    );
    final view = ByteData.sublistView(packet);
    expect(view.getUint16(0, Endian.big), 0x2131);
    expect(view.getUint16(2, Endian.big), packet.length);

    final response = MiioPacket.parseResponse(packet, token);
    expect(response.deviceId, deviceId);
    expect(response.stamp, 1234);
    expect(response.payload, payload);
  });

  test('corrupt checksum and wrong token are rejected', () {
    final packet = MiioPacket.buildRequest(
      payload: requestPayload(),
      token: token,
      deviceId: deviceId,
      stamp: 1234,
    );
    final corrupted = Uint8List.fromList(packet);
    corrupted[16] = corrupted[16] ^ 0xff;
    expect(
      () => MiioPacket.parseResponse(corrupted, token),
      throwsA(isA<MiioAuthException>()),
    );
    expect(
      () => MiioPacket.parseResponse(packet, parseMiioToken('ff' * 16)),
      throwsA(isA<MiioAuthException>()),
    );
  });

  test('invalid length is rejected', () {
    final packet = MiioPacket.buildRequest(
      payload: requestPayload(),
      token: token,
      deviceId: deviceId,
      stamp: 1234,
    );
    expect(
      () => MiioPacket.parseResponse(
        Uint8List.fromList(packet.sublist(0, packet.length - 1)),
        token,
      ),
      throwsA(isA<MiioException>()),
    );
  });
}
