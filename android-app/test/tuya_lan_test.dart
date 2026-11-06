import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/tuya_lan.dart';

const _key = '0123456789abcdef';
const _deviceId = '00112233445566778899';

void main() {
  test('crc32 matches the standard vector', () {
    expect(
      HinenTuyaClient.crc32(utf8.encode('123456789')),
      0xcbf43926,
    );
  });

  test('status request is a 3.4 DP_QUERY frame', () {
    final packet = HinenTuyaClient.buildStatusPacket(
      deviceId: _deviceId,
      localKey: _key,
      sequence: 7,
    );
    final header = ByteData.sublistView(packet);
    expect(header.getUint32(0), 0x000055aa);
    expect(header.getUint32(4), 7);
    expect(header.getUint32(8), 16);
    expect(header.getUint32(packet.length - 4), 0x0000aa55);
    final encrypted = Uint8List.sublistView(packet, 16, packet.length - 36);
    final decrypted =
        utf8.decode(HinenTuyaClient.decryptPayload(encrypted, _key));
    expect(decrypted, '{}');
  });

  test('response parses mapped and raw data points', () {
    final body = jsonEncode(<String, Object>{
      'dps': <String, Object>{
        '1': 98,
        '6': false,
        '7': true,
        '25': false,
        '26': 7200,
        '105': 90,
      },
    });
    final plain = Uint8List.fromList(<int>[
      ...utf8.encode('3.4'),
      ...List<int>.filled(12, 0),
      ...utf8.encode(body),
    ]);
    final encrypted = HinenTuyaClient.encryptPayload(plain, _key);
    final frame = HinenTuyaClient.buildResponseFrame(encrypted, 8, 1, _key);
    final parsed = HinenTuyaClient.parseFrame(frame, _key);
    expect(parsed.ack, isFalse);
    expect(parsed.dps![1], 98);
    expect(parsed.dps![6], false);
    expect(parsed.dps![7], true);
    expect(parsed.dps![25], false);
    expect(parsed.dps![26], 7200);
    expect(parsed.dps![105], 90);
  });

  test('empty payload is an ack', () {
    final frame =
        HinenTuyaClient.buildResponseFrame(Uint8List(0), 8, 2, _key);
    final parsed = HinenTuyaClient.parseFrame(frame, _key);
    expect(parsed.ack, isTrue);
    expect(parsed.dps, isNull);
  });
}
