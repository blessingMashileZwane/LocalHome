import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/airpurifier_profile.dart';

void main() {
  test('profile round-trips without a token', () {
    const profile = AirPurifierProfile(
      id: 'purifier-1',
      name: 'Living room',
      address: '192.168.1.50',
    );

    final restored = AirPurifierProfile.fromJson(profile.toJson());
    expect(restored.id, profile.id);
    expect(restored.name, profile.name);
    expect(restored.address, profile.address);
    expect(restored.modelId, '');
    expect(profile.toJson().containsKey('token'), isFalse);
  });

  test('invalid saved profile fields are rejected', () {
    expect(
      () => AirPurifierProfile.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Living room',
        'address': '192.168.1.50',
      }),
      throwsFormatException,
    );
  });
}
