import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/hinen_profile.dart';

void main() {
  test('profile round-trips without a local key', () {
    const profile = HinenProfile(
      id: 'hinen-1',
      name: 'Backup station',
      address: '192.168.1.50',
      productKey: 'YOURPRODUCTKEY00',
      model: 'PS300',
      deviceId: '00112233445566778899',
      bridgeUrl: 'http://192.168.1.10:8092',
    );

    final restored = HinenProfile.fromJson(profile.toJson());
    expect(restored.id, profile.id);
    expect(restored.name, profile.name);
    expect(restored.address, profile.address);
    expect(restored.productKey, profile.productKey);
    expect(restored.model, profile.model);
    expect(restored.deviceId, profile.deviceId);
    expect(restored.bridgeUrl, profile.bridgeUrl);
    expect(profile.toJson().containsKey('localKey'), isFalse);
    expect(profile.toJson().containsKey('key'), isFalse);
  });

  test('optional product key, model, and device id default to empty', () {
    const profile = HinenProfile(
      id: 'hinen-2',
      name: 'Station',
      address: '10.0.0.20',
    );

    final restored = HinenProfile.fromJson(profile.toJson());
    expect(restored.productKey, '');
    expect(restored.model, '');
    expect(restored.deviceId, '');
    expect(restored.bridgeUrl, '');
  });

  test('invalid saved profile fields are rejected', () {
    expect(
      () => HinenProfile.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Station',
        'address': '192.168.1.50',
      }),
      throwsFormatException,
    );
  });
}
