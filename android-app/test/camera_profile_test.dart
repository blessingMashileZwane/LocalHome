import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/camera_profile.dart';

void main() {
  test('camera profile round-trips its saved fields', () {
    const profile = CameraProfile(
      id: 'camera-42',
      name: 'Garage',
      address: '192.168.1.101',
      path: '/live/ch00_0',
    );

    final restored = CameraProfile.fromJson(profile.toJson());
    expect(restored.id, profile.id);
    expect(restored.name, profile.name);
    expect(restored.address, profile.address);
    expect(restored.path, profile.path);
  });

  test('invalid saved camera profile fields are rejected', () {
    expect(
      () => CameraProfile.fromJson({
        'id': 42,
        'name': 'Garage',
        'address': '192.168.1.101',
        'path': '/live/ch00_0',
      }),
      throwsFormatException,
    );
  });
}
