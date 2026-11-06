import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/lan_iot.dart';

Uint8List _frame(
  int command, {
  int secure = 0,
  int sid = 0,
  required List<int> body,
}) {
  final header = ByteData(16)
    ..setUint32(0, command, Endian.little)
    ..setUint8(4, 1)
    ..setUint8(5, secure)
    ..setUint8(6, sid)
    ..setUint8(7, 0)
    ..setUint32(8, 0, Endian.little)
    ..setUint32(12, body.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...body]);
}

class _FakeTransport implements LanIotTransport {
  _FakeTransport(this.replyBytes);

  final List<int> replyBytes;
  final List<int> sent = [];
  int _offset = 0;

  @override
  Future<void> connect() async {}

  @override
  void add(List<int> bytes) => sent.addAll(bytes);

  @override
  Future<void> flush() async {}

  @override
  Future<Uint8List> readExact(int size) async {
    if (_offset + size > replyBytes.length) {
      throw const LanIotException('test transport exhausted');
    }
    final out = Uint8List.fromList(replyBytes.sublist(_offset, _offset + size));
    _offset += size;
    return out;
  }

  @override
  Future<void> close() async {}
}

Future<Uint8List> _lanpassReply({String? overrideDs}) async {
  final keyPair = await X25519().newKeyPair();
  final public = (await keyPair.extractPublicKey()).bytes;
  final digest = await Sha256().hash(public);
  final body = utf8.encode(
    jsonEncode({
      'result': {'code': 1000},
      'data': {
        'verify': {
          'dK': base64Encode(public),
          'dS': overrideDs ?? base64Encode(digest.bytes),
          'sid': 7,
        },
      },
    }),
  );
  return _frame(lanIotCommand, body: body);
}

Uint8List _propertyReply(List<Map<String, Object?>> entries) {
  final body = utf8.encode(
    jsonEncode({
      'result': {'code': 1000},
      'data': {'dplist_result': entries},
    }),
  );
  return _frame(lanIotCommand, body: body);
}

void main() {
  group('LanIotSession', () {
    test('rejects public addresses before connecting', () async {
      var factoryCalls = 0;
      final session = LanIotSession(
        address: '8.8.8.8',
        password: 'secret',
        transportFactory: (_, _) async {
          factoryCalls++;
          return _FakeTransport([]);
        },
      );

      await expectLater(session.connect(), throwsA(isA<LanIotException>()));
      expect(factoryCalls, 0);
    });

    test('rejects an empty LAN password before connecting', () async {
      var factoryCalls = 0;
      final session = LanIotSession(
        address: '192.168.1.20',
        password: '',
        transportFactory: (_, _) async {
          factoryCalls++;
          return _FakeTransport([]);
        },
      );

      await expectLater(session.connect(), throwsA(isA<LanIotException>()));
      expect(factoryCalls, 0);
    });

    test('performs LANPASS and reads a property reply', () async {
      final transport = _FakeTransport([
        ...await _lanpassReply(),
        ..._propertyReply([
          {'dpid': 327936, 'value': 1, 'code': 1000},
        ]),
      ]);
      final session = LanIotSession(
        address: '192.168.1.20',
        password: 'secret',
        transportFactory: (_, _) async => transport,
      );

      await session.connect();
      final reply = await session.getProperties([327936]);

      expect(transport.sent, isNotEmpty);
      final header = ByteData.sublistView(
        Uint8List.fromList(transport.sent.sublist(0, 16)),
      );
      expect(header.getUint32(0, Endian.little), lanIotCommand);
      expect(header.getUint8(5), 2);
      final entries = (reply['data'] as Map)['dplist_result'] as List;
      expect(entries.first['dpid'], 327936);
      expect(entries.first['value'], 1);
    });

    test('sends a SET_PROPERTIES frame and returns its reply', () async {
      final transport = _FakeTransport([
        ...await _lanpassReply(),
        ..._propertyReply([
          {'dpid': 327936, 'code': 1000},
        ]),
      ]);
      final session = LanIotSession(
        address: '192.168.1.20',
        password: 'secret',
        transportFactory: (_, _) async => transport,
      );

      await session.connect();
      final reply = await session.setProperties([(327936, 1)]);

      expect(transport.sent.length, greaterThan(16));
      final secondHeaderOffset = _frameLength(transport.sent, 0);
      final header = ByteData.sublistView(
        Uint8List.fromList(
          transport.sent.sublist(secondHeaderOffset, secondHeaderOffset + 16),
        ),
      );
      expect(header.getUint32(0, Endian.little), lanIotCommand);
      expect(header.getUint8(5), 2);
      expect(header.getUint8(6), 7);
      final entries = (reply['data'] as Map)['dplist_result'] as List;
      expect(entries.first['code'], 1000);
    });

    test('rejects a LANPASS reply with a bad dS', () async {
      final transport = _FakeTransport([
        ...await _lanpassReply(overrideDs: base64Encode(List.filled(32, 0))),
      ]);
      final session = LanIotSession(
        address: '192.168.1.20',
        password: 'secret',
        transportFactory: (_, _) async => transport,
      );

      await expectLater(
        session.connect(),
        throwsA(
          isA<LanIotException>().having(
            (error) => error.message,
            'message',
            contains('verification'),
          ),
        ),
      );
    });

    test('propagates a rejected method result code', () async {
      final rejection = utf8.encode(
        jsonEncode({
          'result': {'code': 1114},
        }),
      );
      final transport = _FakeTransport([
        ...await _lanpassReply(),
        ..._frame(lanIotCommand, body: rejection),
      ]);
      final session = LanIotSession(
        address: '192.168.1.20',
        password: 'secret',
        transportFactory: (_, _) async => transport,
      );

      await session.connect();
      await expectLater(
        session.getProperties([327936]),
        throwsA(
          isA<LanIotException>().having((error) => error.code, 'code', 1114),
        ),
      );
    });
  });
}

int _frameLength(List<int> bytes, int offset) {
  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  final bodyLength = view.getUint32(offset + 12, Endian.little);
  return offset + 16 + bodyLength;
}
