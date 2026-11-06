import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/miio_airpurifier.dart';
import 'package:localhome/miio_packet.dart';

const tokenHex = '00112233445566778899aabbccddeeff';

final token = parseMiioToken(tokenHex);
final deviceId = Uint8List.fromList([1, 2, 3, 4]);
const stamp = 0x11223344;

Uint8List helloResponse() {
  final bytes = Uint8List(32);
  final view = ByteData.sublistView(bytes);
  view.setUint16(0, 0x2131, Endian.big);
  view.setUint16(2, 32, Endian.big);
  bytes.setRange(8, 12, deviceId);
  view.setUint32(12, stamp, Endian.big);
  return bytes;
}

Uint8List encode(Map<String, Object?> payload) => MiioPacket.buildRequest(
  payload: payload,
  token: token,
  deviceId: deviceId,
  stamp: stamp,
);

class FakeTransport implements MiioTransport {
  FakeTransport(this.handler);

  final FutureOr<Uint8List> Function(Uint8List packet) handler;
  final List<Uint8List> packets = [];
  bool closed = false;

  @override
  Future<Uint8List> exchange(
    Uint8List packet, {
    required Duration timeout,
  }) async {
    packets.add(packet);
    return handler(packet);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakeDevice {
  FakeDevice({this.model = 'zhimi.airp.mb5a', Map<String, Object?>? values})
    : state = Map<String, Object?>.from(values ?? const <String, Object?>{});

  final String model;
  final Map<String, Object?> state;
  int getCalls = 0;
  int setCalls = 0;
  int actionCalls = 0;
  bool setEffect = true;
  bool actionEffect = true;
  bool actionTimeout = false;

  FutureOr<Uint8List> handle(Uint8List packet) {
    if (packet.length == 32) {
      return helloResponse();
    }
    final request = MiioPacket.parseResponse(packet, token).payload!;
    final method = request['method'];
    final id = request['id'];
    switch (method) {
      case 'miIO.info':
        return encode(<String, Object?>{
          'id': id,
          'result': <String, Object?>{
            'model': model,
            'fw_ver': '1.2.3',
            'hw_ver': '4.0',
            'mac': 'AA:BB:CC:DD:EE:FF',
            'token': tokenHex,
          },
        });
      case 'get_properties':
        getCalls++;
        final result = <Map<String, Object?>>[];
        for (final item in (request['params'] as List)) {
          final key = '${item['siid']}:${item['piid']}';
          final entry = <String, Object?>{
            'did': item['did'],
            'siid': item['siid'],
            'piid': item['piid'],
          };
          if (state.containsKey(key)) {
            entry['code'] = 0;
            entry['value'] = state[key];
          } else {
            entry['code'] = -4001;
          }
          result.add(entry);
        }
        return encode(<String, Object?>{'id': id, 'result': result});
      case 'set_properties':
        setCalls++;
        final result = <Map<String, Object?>>[];
        for (final item in (request['params'] as List)) {
          final key = '${item['siid']}:${item['piid']}';
          result.add(<String, Object?>{
            'did': item['did'],
            'siid': item['siid'],
            'piid': item['piid'],
            'code': 0,
          });
          if (setEffect) state[key] = item['value'];
        }
        return encode(<String, Object?>{'id': id, 'result': result});
      case 'action':
        actionCalls++;
        if (actionTimeout) {
          throw const MiioTimeoutException('simulated timeout');
        }
        if (actionEffect) state['4:3'] = 0;
        return encode(<String, Object?>{
          'id': id,
          'result': <String, Object?>{'did': 'call-4-1', 'code': 0},
        });
    }
    return encode(<String, Object?>{
      'id': id,
      'error': <String, Object?>{'code': -1},
    });
  }
}

(MiioPurifierClient, FakeDevice, FakeTransport) makeClient(
  FakeDevice device, {
  Duration readbackTimeout = const Duration(seconds: 3),
}) {
  final transport = FakeTransport(device.handle);
  final client = MiioPurifierClient(
    address: '192.168.1.50',
    token: token,
    readbackTimeout: readbackTimeout,
    transportFactory: (address, port) async => transport,
  );
  return (client, device, transport);
}

void main() {
  test('connect reads the model and does not expose the token', () async {
    final device = FakeDevice();
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);

    final info = await client.connect();
    expect(info.model, 'zhimi.airp.mb5a');
    expect(info.firmware, '1.2.3');
    expect(info.hardware, '4.0');
    expect(client.info!.model, info.model);
    expect(device.getCalls, 0);
  });

  test('readStatus chunks at 15 and parses values', () async {
    final device = FakeDevice(
      values: <String, Object?>{
        '2:1': true,
        '2:4': 2,
        '3:4': 18.0,
        '4:1': 80,
      },
    );
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final status = await client.readStatus();
    expect(status.values['power'], isTrue);
    expect(status.values['mode'], 2);
    expect(status.values['pm25'], 18.0);
    expect(status.values['filter_life'], 80);
    expect(status.unsupported, contains('anion'));
    expect(device.getCalls, 2);
  });

  test('vb4 reads PM10 and air quality', () async {
    final device = FakeDevice(
      model: 'zhimi.airp.vb4',
      values: <String, Object?>{'2:1': true, '3:8': 12.0, '3:9': 1},
    );
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final status = await client.readStatus();
    expect(status.values['pm10'], 12.0);
    expect(status.values['air_quality'], 1);
  });

  test('vb4 favorite level falls back to 15.1', () async {
    final device = FakeDevice(
      model: 'zhimi.airp.vb4',
      values: <String, Object?>{'2:1': true, '15:1': 7},
    );
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final first = await client.readStatus();
    expect(first.values['favorite_level'], 7);
    expect(first.unsupported, isNot(contains('favorite_level')));

    final second = await client.readStatus();
    expect(second.values['favorite_level'], 7);
  });

  test('setProperty reads the value back', () async {
    final device = FakeDevice(values: <String, Object?>{'2:1': false});
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final result = await client.setProperty('power', true);
    expect(result.applied, isTrue);
    expect(result.error, isNull);
    expect(result.status.values['power'], isTrue);
    expect(device.setCalls, 1);
  });

  test('setProperty reports a read-back mismatch', () async {
    final device = FakeDevice(values: <String, Object?>{'2:1': false})
      ..setEffect = false;
    final (client, _, _) = makeClient(
      device,
      readbackTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(client.close);
    await client.connect();

    final result = await client.setProperty('power', true);
    expect(result.applied, isFalse);
    expect(result.error, contains('did not apply'));
    expect(result.status.values['power'], isFalse);
  });

  test('invalid writes are rejected before sending', () async {
    final device = FakeDevice(values: <String, Object?>{'2:1': false});
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    await expectLater(
      client.setProperty('fan_level', 4),
      throwsFormatException,
    );
    await expectLater(
      client.setProperty('pm25', 1),
      throwsA(isA<MiioException>()),
    );
    await expectLater(
      client.setProperty('unknown', 1),
      throwsA(isA<MiioException>()),
    );
    expect(device.setCalls, 0);
  });

  test('unknown models are read-only', () async {
    final device = FakeDevice(
      model: 'zhimi.unknown.test',
      values: <String, Object?>{'2:1': true},
    );
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final status = await client.readStatus();
    expect(status.model, 'zhimi.unknown.test');
    expect(status.values, isEmpty);
    expect(device.getCalls, 0);
    await expectLater(
      client.setProperty('power', false),
      throwsA(isA<MiioException>()),
    );
  });

  test('cpa4 reads the Compact values', () async {
    final device = FakeDevice(
      model: 'xiaomi.airp.cpa4',
      values: <String, Object?>{
        '2:1': false,
        '2:4': 0,
        '3:4': 97,
        '4:1': 100,
        '4:3': 63,
        '4:4': 289,
        '6:1': true,
        '8:1': false,
        '9:1': 0,
        '9:11': 5,
        '13:2': 2,
      },
    );
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final status = await client.readStatus();
    expect(status.values['pm25'], 97);
    expect(status.values['favorite_level'], 5);
    expect(status.values.containsKey('fan_level'), isFalse);

    await expectLater(
      client.setProperty('mode', 3),
      throwsFormatException,
    );
    final result = await client.setProperty('favorite_level', 14);
    expect(result.applied, isTrue);
    expect(result.status.values['favorite_level'], 14);
  });

  test('resetFilter sends one action and reads back zero', () async {
    final device = FakeDevice(
      values: <String, Object?>{'4:1': 50, '4:3': 1234},
    );
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final result = await client.resetFilter();
    expect(result.applied, isTrue);
    expect(device.actionCalls, 1);
    expect(result.status.values['filter_used_time'], 0);
  });

  test('resetFilter does not retry a timed-out action', () async {
    final device = FakeDevice(
      values: <String, Object?>{'4:1': 50, '4:3': 1234},
    )..actionTimeout = true;
    final (client, _, _) = makeClient(device);
    addTearDown(client.close);
    await client.connect();

    final result = await client.resetFilter();
    expect(result.applied, isFalse);
    expect(device.actionCalls, 1);
    expect(result.error, contains('check the filter'));
  });

  test('close marks the session closed', () async {
    final device = FakeDevice();
    final (client, _, transport) = makeClient(device);
    await client.connect();
    await client.close();
    expect(transport.closed, isTrue);
    await expectLater(
      client.readStatus(),
      throwsA(isA<MiioException>()),
    );
  });
}
