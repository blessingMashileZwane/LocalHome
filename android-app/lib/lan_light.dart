/// White floodlight control over the camera's local IOT session.
///
/// Confirmed against the target firmware (`Hw_EV2X_NA1_XHR_E_V1.0_WF_20250312`):
/// `DPID_LIGHT_FLOODLIGHT_SW` accepts 0 = AUTO, 1 = ON, 2 = OFF, while
/// `DPID_LIGHT_FLOODLIGHT_STATUS` is read-only (1 = on, 2 = off, 3 = auto).
library;

import 'lan_iot.dart';

const int dpidLightFloodlightSw = 0x00050100;
const int dpidLightFloodlightStatus = 0x00050101;
const int dpidLightFloodlightSensitivity = 0x00050103;

const int _statusOn = 1;
const int _statusAuto = 3;

enum LightMode {
  auto(0),
  on(1),
  off(2);

  const LightMode(this.value);

  final int value;
}

class LightState {
  const LightState({
    required this.mode,
    required this.isOn,
    required this.status,
  });

  final LightMode? mode;
  final bool? isOn;
  final int? status;

  String get label => switch (mode) {
    LightMode.on => 'ON',
    LightMode.off => 'OFF',
    LightMode.auto => 'AUTO',
    null => 'UNKNOWN',
  };

  bool get isAuto => mode == LightMode.auto || status == _statusAuto;
}

class LanLightException implements Exception {
  const LanLightException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LanLightClient {
  LanLightClient({
    required this.address,
    required this.password,
    LanIotTransportFactory? transportFactory,
    LanIotClient? client,
  }) : _transportFactory = transportFactory,
       _session = client;

  final String address;
  final String password;
  final LanIotTransportFactory? _transportFactory;

  LanIotClient? _session;

  Future<void> connect() async {
    final session =
        _session ??
        LanIotSession(
          address: address,
          password: password,
          transportFactory: _transportFactory,
        );
    try {
      await session.connect();
      _session = session;
    } on LanIotException catch (error) {
      await session.close();
      throw LanLightException(error.message);
    }
  }

  Future<LightState> readState() async {
    final session = _requireSession();
    try {
      final reply = await session.getProperties([
        dpidLightFloodlightSw,
        dpidLightFloodlightStatus,
      ]);
      final properties = _properties(reply);
      final sw = _intValue(properties, dpidLightFloodlightSw);
      final status = _intValue(properties, dpidLightFloodlightStatus);
      if (sw == null) {
        throw const LanLightException(
          'This camera does not expose white light control.',
        );
      }
      return LightState(
        mode: switch (sw) {
          0 => LightMode.auto,
          1 => LightMode.on,
          2 => LightMode.off,
          _ => null,
        },
        isOn: status == null ? null : status == _statusOn,
        status: status,
      );
    } on LanIotException catch (error) {
      throw LanLightException(_lightMessage(error));
    }
  }

  Future<LightState> setMode(LightMode mode) async {
    final session = _requireSession();
    try {
      final reply = await session.setProperties([
        (dpidLightFloodlightSw, mode.value),
      ]);
      final properties = _properties(reply);
      final code = properties[dpidLightFloodlightSw]?.code;
      if (code != null && code != 1000) {
        throw LanLightException(_propertyMessage(code));
      }
      return await readState();
    } on LanIotException catch (error) {
      throw LanLightException(_lightMessage(error));
    }
  }

  LanIotClient _requireSession() {
    final session = _session;
    if (session == null) {
      throw const LanLightException('The light session is not connected.');
    }
    return session;
  }

  Future<void> close() async {
    final session = _session;
    _session = null;
    await session?.close();
  }
}

class _Property {
  const _Property(this.value, this.code);

  final Object? value;
  final int? code;
}

Map<int, _Property> _properties(Map<String, dynamic> reply) {
  final data = (reply['data'] as Map?)?.cast<String, dynamic>();
  final entries = data?['dplist_result'];
  if (entries is! List) {
    throw const LanLightException('Camera reply is missing light properties.');
  }
  final result = <int, _Property>{};
  for (final entry in entries) {
    if (entry is! Map) continue;
    final map = entry.cast<String, dynamic>();
    final dpid = map['dpid'];
    final code = map['code'];
    if (dpid is int) {
      result[dpid] = _Property(map['value'], code is int ? code : null);
    }
  }
  return result;
}

int? _intValue(Map<int, _Property> properties, int dpid) {
  final property = properties[dpid];
  if (property == null || (property.code != null && property.code != 1000)) {
    return null;
  }
  final value = property.value;
  return value is int ? value : null;
}

String _propertyMessage(int code) {
  return switch (code) {
    1106 => 'The camera rejected that light setting.',
    1110 => 'The camera does not allow this operation over LAN.',
    1114 => 'This camera does not expose that light property.',
    1119 => 'The camera rejected the LAN session.',
    _ => 'The camera rejected the light setting ($code).',
  };
}

String _lightMessage(LanIotException error) {
  if (error.code != null) return _propertyMessage(error.code!);
  return error.message;
}
