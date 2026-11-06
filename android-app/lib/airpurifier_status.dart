/// Typed status, MIoT property maps, and write validation for the Xiaomi
/// air purifier (Smart Air Purifier 4 and 4 Pro).
library;

const String purifierModelMb5a = 'zhimi.airp.mb5a';
const String purifierModelVb4 = 'zhimi.airp.vb4';
const String purifierModelCpa4 = 'xiaomi.airp.cpa4';

const Map<String, String> purifierModelAliases = {
  'zhimi.airp.mb5': purifierModelMb5a,
  'zhimi.airp.mb5a': purifierModelMb5a,
  'zhimi.airp.va2': purifierModelVb4,
  'zhimi.airp.vb4': purifierModelVb4,
  'xiaomi.airp.cpa4': purifierModelCpa4,
};

class PurifierProperty {
  const PurifierProperty({
    required this.name,
    required this.siid,
    required this.piid,
    required this.kind,
    this.minimum,
    this.maximum,
    this.writable = false,
    this.label = '',
    this.unit,
    this.hidden = false,
  });

  final String name;
  final int siid;
  final int piid;
  final String kind;
  final num? minimum;
  final num? maximum;
  final bool writable;
  final String label;
  final String? unit;
  final bool hidden;

  String get displayLabel => label.isEmpty ? name : label;
}

PurifierProperty _p(
  String name,
  int siid,
  int piid,
  String kind, {
  num? minimum,
  num? maximum,
  bool writable = false,
  String label = '',
  String? unit,
  bool hidden = false,
}) => PurifierProperty(
  name: name,
  siid: siid,
  piid: piid,
  kind: kind,
  minimum: minimum,
  maximum: maximum,
  writable: writable,
  label: label.isEmpty ? name : label,
  unit: unit,
  hidden: hidden,
);

final Map<String, PurifierProperty> _commonProperties = {
  'power': _p('power', 2, 1, 'bool', writable: true, label: 'Power'),
  'fault': _p('fault', 2, 2, 'int', label: 'Fault'),
  'mode': _p(
    'mode',
    2,
    4,
    'int',
    minimum: 0,
    maximum: 3,
    writable: true,
    label: 'Mode',
  ),
  'fan_level': _p(
    'fan_level',
    2,
    5,
    'int',
    minimum: 1,
    maximum: 3,
    writable: true,
    label: 'Fan level',
  ),
  'anion': _p('anion', 2, 6, 'bool', writable: true, label: 'Anion'),
  'humidity': _p(
    'humidity',
    3,
    1,
    'int',
    minimum: 0,
    maximum: 100,
    label: 'Humidity',
    unit: '%',
  ),
  'pm25': _p(
    'pm25',
    3,
    4,
    'float',
    minimum: 0,
    maximum: 1000,
    label: 'PM2.5',
    unit: 'µg/m³',
  ),
  'temperature': _p(
    'temperature',
    3,
    7,
    'float',
    minimum: -30,
    maximum: 100,
    label: 'Temperature',
    unit: '°C',
  ),
  'filter_life': _p(
    'filter_life',
    4,
    1,
    'int',
    minimum: 0,
    maximum: 100,
    label: 'Filter life',
    unit: '%',
  ),
  'filter_used_time': _p(
    'filter_used_time',
    4,
    3,
    'int',
    minimum: 0,
    maximum: 65000,
    label: 'Filter used',
    unit: 'h',
  ),
  'filter_left_time': _p(
    'filter_left_time',
    4,
    4,
    'int',
    minimum: 0,
    maximum: 1000,
    label: 'Filter left',
    unit: 'days',
  ),
  'alarm': _p('alarm', 6, 1, 'bool', writable: true, label: 'Buzzer'),
  'child_lock': _p(
    'child_lock',
    8,
    1,
    'bool',
    writable: true,
    label: 'Child lock',
  ),
  'motor_rpm': _p(
    'motor_rpm',
    9,
    1,
    'int',
    label: 'Motor speed',
    unit: 'rpm',
  ),
  'favorite_speed': _p(
    'favorite_speed',
    9,
    2,
    'int',
    minimum: 200,
    maximum: 2300,
    writable: true,
    label: 'Favorite speed',
    unit: 'rpm',
    hidden: true,
  ),
  'favorite_level': _p(
    'favorite_level',
    9,
    5,
    'int',
    minimum: 0,
    maximum: 11,
    writable: true,
    label: 'Favorite level',
  ),
  'door': _p('door', 9, 6, 'bool', label: 'Filter door'),
  'manual_level': _p(
    'manual_level',
    9,
    9,
    'int',
    minimum: 1,
    maximum: 3,
    writable: true,
    label: 'Manual level',
    hidden: true,
  ),
  'purify_volume': _p(
    'purify_volume',
    11,
    1,
    'int',
    minimum: 0,
    maximum: 2147483600,
    label: 'Purified volume',
    unit: 'm³',
  ),
  'average_aqi': _p(
    'average_aqi',
    11,
    2,
    'int',
    minimum: 0,
    maximum: 600,
    label: 'Average AQI',
  ),
  'aqi_state': _p(
    'aqi_state',
    11,
    3,
    'int',
    minimum: 0,
    maximum: 5,
    label: 'Air quality',
  ),
  'filter_rfid_product': _p(
    'filter_rfid_product',
    12,
    3,
    'str',
    label: 'Filter type',
  ),
  'screen_brightness': _p(
    'screen_brightness',
    13,
    2,
    'int',
    minimum: 0,
    maximum: 2,
    writable: true,
    label: 'Screen brightness',
  ),
  'temperature_unit': _p(
    'temperature_unit',
    14,
    1,
    'int',
    minimum: 1,
    maximum: 2,
    writable: true,
    label: 'Temperature unit',
  ),
};

final Map<String, PurifierProperty> _mb5aProperties =
    Map<String, PurifierProperty>.unmodifiable(_commonProperties);

final Map<String, PurifierProperty> _vb4Properties =
    Map<String, PurifierProperty>.unmodifiable({
      ..._commonProperties,
      'pm10': _p(
        'pm10',
        3,
        8,
        'float',
        minimum: 1,
        maximum: 100,
        label: 'PM10',
        unit: 'µg/m³',
      ),
      'air_quality': _p(
        'air_quality',
        3,
        9,
        'int',
        minimum: 0,
        maximum: 5,
        label: 'Air quality',
      ),
      'favorite_square': _p(
        'favorite_square',
        9,
        12,
        'str',
        label: 'Favorite area',
        hidden: true,
      ),
    });

final Map<String, PurifierProperty> _cpa4Properties = {
  'power': _p('power', 2, 1, 'bool', writable: true, label: 'Power'),
  'fault': _p('fault', 2, 2, 'int', label: 'Fault'),
  'mode': _p(
    'mode',
    2,
    4,
    'int',
    minimum: 0,
    maximum: 2,
    writable: true,
    label: 'Mode',
  ),
  'pm25': _p(
    'pm25',
    3,
    4,
    'int',
    minimum: 0,
    maximum: 600,
    label: 'PM2.5',
    unit: 'µg/m³',
  ),
  'filter_life': _p(
    'filter_life',
    4,
    1,
    'int',
    minimum: 0,
    maximum: 100,
    label: 'Filter life',
    unit: '%',
  ),
  'filter_used_time': _p(
    'filter_used_time',
    4,
    3,
    'int',
    minimum: 0,
    maximum: 65535,
    label: 'Filter used',
    unit: 'h',
  ),
  'filter_left_time': _p(
    'filter_left_time',
    4,
    4,
    'int',
    minimum: 0,
    maximum: 1000,
    label: 'Filter left',
    unit: 'days',
  ),
  'alarm': _p('alarm', 6, 1, 'bool', writable: true, label: 'Buzzer'),
  'child_lock': _p(
    'child_lock',
    8,
    1,
    'bool',
    writable: true,
    label: 'Child lock',
  ),
  'motor_rpm': _p(
    'motor_rpm',
    9,
    1,
    'int',
    minimum: 0,
    maximum: 2500,
    label: 'Motor speed',
    unit: 'rpm',
  ),
  'favorite_level': _p(
    'favorite_level',
    9,
    11,
    'int',
    minimum: 0,
    maximum: 14,
    writable: true,
    label: 'Favorite level',
  ),
  'screen_brightness': _p(
    'screen_brightness',
    13,
    2,
    'int',
    minimum: 0,
    maximum: 2,
    writable: true,
    label: 'Screen brightness',
  ),
};

Map<String, PurifierProperty> propertiesForModel(String model) {
  final canonical = purifierModelAliases[model];
  final source = switch (canonical) {
    purifierModelVb4 => _vb4Properties,
    purifierModelMb5a => _mb5aProperties,
    purifierModelCpa4 => _cpa4Properties,
    _ => _commonProperties,
  };
  return {
    for (final entry in source.entries)
      if (!entry.value.hidden) entry.key: entry.value,
  };
}

PurifierProperty? alternateFavoriteLevel(String model) {
  if (purifierModelAliases[model] != purifierModelVb4) return null;
  return _p(
    'favorite_level',
    15,
    1,
    'int',
    minimum: 0,
    maximum: 11,
    writable: true,
    label: 'Favorite level',
  );
}

class AirPurifierStatus {
  const AirPurifierStatus({
    required this.model,
    required this.firmware,
    required this.hardware,
    required this.values,
    required this.unsupported,
    required this.errors,
    required this.receivedAt,
  });

  final String model;
  final String? firmware;
  final String? hardware;
  final Map<String, Object?> values;
  final Set<String> unsupported;
  final Map<String, int> errors;
  final DateTime receivedAt;

  Object? operator [](String name) => values[name];

  bool isUnsupported(String name) => unsupported.contains(name);
}

class ControlResult {
  const ControlResult({
    required this.status,
    required this.applied,
    this.error,
  });

  final AirPurifierStatus status;
  final bool applied;
  final String? error;
}

Object? coercePurifierValue(PurifierProperty property, Object? value) {
  if (value == null) return null;
  return switch (property.kind) {
    'bool' when value is bool => value,
    'bool' when value is num => value != 0,
    'int' when value is num && value is! bool => value.toInt(),
    'float' when value is num && value is! bool => value.toDouble(),
    'str' when value is String => value,
    _ => null,
  };
}

AirPurifierStatus parseStatus({
  required String model,
  required String? firmware,
  required String? hardware,
  required List<Map<String, dynamic>> entries,
  required Map<String, PurifierProperty> properties,
  required DateTime receivedAt,
}) {
  final byName = <String, PurifierProperty>{
    for (final property in properties.values) property.name: property,
  };
  final byPair = <String, String>{
    for (final property in properties.values)
      '${property.siid}:${property.piid}': property.name,
  };
  final values = <String, Object?>{};
  final unsupported = <String>{};
  final errors = <String, int>{};

  for (final entry in entries) {
    Object? name = entry['did'];
    if (name is! String || !byName.containsKey(name)) {
      name = byPair['${entry['siid']}:${entry['piid']}'];
    }
    if (name is! String) continue;
    final property = byName[name];
    if (property == null) continue;

    final code = entry['code'];
    if (code is int && code != 0) {
      if (code == -4001) {
        unsupported.add(name);
        errors.remove(name);
      } else {
        errors[name] = code;
      }
      continue;
    }
    unsupported.remove(name);
    errors.remove(name);
    values[name] = coercePurifierValue(property, entry['value']);
  }

  return AirPurifierStatus(
    model: model,
    firmware: firmware,
    hardware: hardware,
    values: values,
    unsupported: unsupported,
    errors: errors,
    receivedAt: receivedAt,
  );
}

Object validateControlValue(PurifierProperty property, Object? value) {
  switch (property.kind) {
    case 'bool':
      if (value is bool) return value;
      throw const FormatException('That value must be true or false.');
    case 'int':
      if (value is! num) {
        throw const FormatException('That value must be a number.');
      }
      final number = value.toInt();
      if (value != number) {
        throw const FormatException('That value must be a whole number.');
      }
      _checkRange(property, number);
      return number;
    case 'float':
      if (value is! num) {
        throw const FormatException('That value must be a number.');
      }
      final number = value.toDouble();
      _checkRange(property, number);
      return number;
    case 'str':
      if (value is String) return value;
      throw const FormatException('That value must be text.');
  }
  throw const FormatException('That purifier setting is not supported.');
}

void _checkRange(PurifierProperty property, num value) {
  final minimum = property.minimum;
  final maximum = property.maximum;
  if (minimum != null && value < minimum) {
    throw const FormatException('That value is out of range.');
  }
  if (maximum != null && value > maximum) {
    throw const FormatException('That value is out of range.');
  }
}
