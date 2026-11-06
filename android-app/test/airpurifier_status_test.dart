import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/airpurifier_status.dart';

void main() {
  test('mb5a map has no PM10 or air-quality', () {
    final properties = propertiesForModel('zhimi.airp.mb5a');
    expect(properties.containsKey('pm10'), isFalse);
    expect(properties.containsKey('air_quality'), isFalse);
    expect(properties['power']!.siid, 2);
    expect(properties['power']!.piid, 1);
  });

  test('vb4 map adds PM10 and air-quality', () {
    final properties = propertiesForModel('zhimi.airp.vb4');
    expect(properties['pm10']!.siid, 3);
    expect(properties['pm10']!.piid, 8);
    expect(properties['air_quality']!.piid, 9);
    expect(properties['favorite_level']!.siid, 9);
  });

  test('aliases resolve to the expected maps', () {
    expect(propertiesForModel('zhimi.airp.mb5').containsKey('pm10'), isFalse);
    expect(propertiesForModel('zhimi.airp.va2').containsKey('pm10'), isTrue);
  });

  test('cpa4 map is the 4 Compact tree', () {
    final properties = propertiesForModel('xiaomi.airp.cpa4');
    expect(properties.containsKey('fan_level'), isFalse);
    expect(properties.containsKey('humidity'), isFalse);
    expect(properties['mode']!.maximum, 2);
    expect(properties['favorite_level']!.siid, 9);
    expect(properties['favorite_level']!.piid, 11);
    expect(properties['favorite_level']!.maximum, 14);
    expect(properties['pm25']!.kind, 'int');
  });

  test('parseStatus reads values and marks unsupported properties', () {
    final properties = propertiesForModel('zhimi.airp.mb5a');
    final status = parseStatus(
      model: 'zhimi.airp.mb5a',
      firmware: '1.2.3',
      hardware: '4.0',
      properties: properties,
      receivedAt: DateTime(2026, 10, 31),
      entries: <Map<String, dynamic>>[
        {'did': 'power', 'siid': 2, 'piid': 1, 'code': 0, 'value': true},
        {'did': 'mode', 'siid': 2, 'piid': 4, 'code': 0, 'value': 2},
        {'did': 'pm25', 'siid': 3, 'piid': 4, 'code': 0, 'value': 18},
        {'did': 'temperature', 'siid': 3, 'piid': 7, 'code': 0, 'value': 22.3},
        {'did': 'anion', 'siid': 2, 'piid': 6, 'code': -4001},
        {'did': 'filter_life', 'siid': 4, 'piid': 1, 'code': -5001},
      ],
    );

    expect(status.values['power'], isTrue);
    expect(status.values['mode'], 2);
    expect(status.values['pm25'], 18.0);
    expect(status.values['temperature'], 22.3);
    expect(status.unsupported, contains('anion'));
    expect(status.errors['filter_life'], -5001);
    expect(status.model, 'zhimi.airp.mb5a');
    expect(status.firmware, '1.2.3');
  });

  test('duplicate entries let a supported alternate win', () {
    final properties = propertiesForModel('zhimi.airp.vb4');
    final alternate = alternateFavoriteLevel('zhimi.airp.vb4')!;
    final status = parseStatus(
      model: 'zhimi.airp.vb4',
      firmware: null,
      hardware: null,
      properties: {...properties, 'favorite_level': alternate},
      receivedAt: DateTime(2026, 10, 31),
      entries: <Map<String, dynamic>>[
        {'did': 'favorite_level', 'siid': 9, 'piid': 5, 'code': -4001},
        {'did': 'favorite_level', 'siid': 15, 'piid': 1, 'code': 0, 'value': 7},
      ],
    );

    expect(status.values['favorite_level'], 7);
    expect(status.unsupported, isNot(contains('favorite_level')));
  });

  test('validateControlValue enforces type and range', () {
    final properties = propertiesForModel('zhimi.airp.mb5a');
    expect(validateControlValue(properties['fan_level']!, 3), 3);
    expect(
      () => validateControlValue(properties['fan_level']!, 4),
      throwsFormatException,
    );
    expect(
      () => validateControlValue(properties['mode']!, 9),
      throwsFormatException,
    );
    expect(
      () => validateControlValue(properties['power']!, 1),
      throwsFormatException,
    );
    expect(validateControlValue(properties['power']!, true), isTrue);
  });

  test('alternateFavoriteLevel is only for vb4', () {
    expect(alternateFavoriteLevel('zhimi.airp.vb4')!.siid, 15);
    expect(alternateFavoriteLevel('zhimi.airp.mb5a'), isNull);
  });
}
