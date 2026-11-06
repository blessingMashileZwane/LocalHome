import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/hinen_host_bridge.dart';

void main() {
  test('rejects a non-private host bridge before sending', () async {
    final bridge = HinenHostBridge(baseUrl: 'http://8.8.8.8:8092');
    await expectLater(
      bridge.readStatus(address: '192.168.1.50'),
      throwsA(isA<HinenHostBridgeException>()),
    );
  });

  test('rejects a non-private station address', () async {
    final bridge = HinenHostBridge(baseUrl: 'http://192.168.1.10:8092');
    await expectLater(
      bridge.readStatus(address: '8.8.8.8'),
      throwsA(isA<HinenHostBridgeException>()),
    );
  });
}
