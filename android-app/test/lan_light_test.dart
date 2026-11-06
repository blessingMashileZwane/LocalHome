import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/lan_iot.dart';
import 'package:localhome/lan_light.dart';

class _FakeIot implements LanIotClient {
  _FakeIot(this.replies);

  final List<Map<String, dynamic>> replies;
  int _index = 0;
  List<(int, Object)>? lastSet;
  List<int>? lastGet;

  @override
  Future<void> connect() async {}

  @override
  Future<Map<String, dynamic>> getProperties(List<int> dpids) async {
    lastGet = dpids;
    return replies[_index++];
  }

  @override
  Future<Map<String, dynamic>> setProperties(
    List<(int dpid, Object value)> entries,
  ) async {
    lastSet = entries;
    return replies[_index++];
  }

  @override
  Future<void> close() async {}
}

Map<String, dynamic> _stateReply({required int sw, required int status}) => {
  'result': {'code': 1000},
  'data': {
    'dplist_result': [
      {'dpid': dpidLightFloodlightSw, 'value': sw, 'code': 1000},
      {'dpid': dpidLightFloodlightStatus, 'value': status, 'code': 1000},
    ],
  },
};

Map<String, dynamic> _setReply({int code = 1000}) => {
  'result': {'code': 1000},
  'data': {
    'dplist_result': [
      {'dpid': dpidLightFloodlightSw, 'code': code},
    ],
  },
};

void main() {
  group('LanLightClient', () {
    test('reads ON, OFF, and AUTO from the switch property', () async {
      final fake = _FakeIot([
        _stateReply(sw: 1, status: 1),
        _stateReply(sw: 2, status: 2),
        _stateReply(sw: 0, status: 2),
      ]);
      final client = LanLightClient(
        address: '192.168.1.20',
        password: 'secret',
        client: fake,
      );
      await client.connect();

      final on = await client.readState();
      final off = await client.readState();
      final auto = await client.readState();

      expect(on.mode, LightMode.on);
      expect(on.isOn, isTrue);
      expect(off.mode, LightMode.off);
      expect(off.isOn, isFalse);
      expect(auto.mode, LightMode.auto);
      expect(auto.isAuto, isTrue);
      expect(fake.lastGet, [dpidLightFloodlightSw, dpidLightFloodlightStatus]);
    });

    test('writes the confirmed switch values for ON, AUTO, and OFF', () async {
      final fake = _FakeIot([
        _setReply(),
        _stateReply(sw: 1, status: 1),
        _setReply(),
        _stateReply(sw: 0, status: 2),
        _setReply(),
        _stateReply(sw: 2, status: 2),
      ]);
      final client = LanLightClient(
        address: '192.168.1.20',
        password: 'secret',
        client: fake,
      );
      await client.connect();

      final on = await client.setMode(LightMode.on);
      expect(fake.lastSet, [(dpidLightFloodlightSw, 1)]);
      expect(on.mode, LightMode.on);

      final auto = await client.setMode(LightMode.auto);
      expect(fake.lastSet, [(dpidLightFloodlightSw, 0)]);
      expect(auto.mode, LightMode.auto);

      final off = await client.setMode(LightMode.off);
      expect(fake.lastSet, [(dpidLightFloodlightSw, 2)]);
      expect(off.mode, LightMode.off);
    });

    test('surfaces a rejected light property', () async {
      final fake = _FakeIot([_setReply(code: 1114)]);
      final client = LanLightClient(
        address: '192.168.1.20',
        password: 'secret',
        client: fake,
      );
      await client.connect();

      await expectLater(
        client.setMode(LightMode.on),
        throwsA(
          isA<LanLightException>().having(
            (error) => error.message,
            'message',
            contains('does not expose'),
          ),
        ),
      );
    });

    test('rejects a camera reply without the switch property', () async {
      final fake = _FakeIot([
        {
          'result': {'code': 1000},
          'data': {
            'dplist_result': [
              {'dpid': dpidLightFloodlightStatus, 'value': 2, 'code': 1000},
            ],
          },
        },
      ]);
      final client = LanLightClient(
        address: '192.168.1.20',
        password: 'secret',
        client: fake,
      );
      await client.connect();

      await expectLater(client.readState(), throwsA(isA<LanLightException>()));
    });
  });
}
