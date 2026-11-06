import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/debug_hinen_import.dart';
import 'package:localhome/hinen_key_store.dart';

class _FakeStore implements HinenKeyStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String profileId) async => values[profileId];

  @override
  Future<void> write(String profileId, String key) async {
    values[profileId] = key;
  }

  @override
  Future<void> delete(String profileId) async {
    values.remove(profileId);
  }
}

void main() {
  test('imports a staged key and deletes the file', () async {
    final directory = await Directory.systemTemp.createTemp('hinen-import');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/localhome-hinen.env')
      ..writeAsStringSync(
        'HINEN_LOCAL_KEY=0123456789abcdef\n'
        'HINEN_PROFILE_ID=hinen-1\n',
      );
    final store = _FakeStore();

    expect(await importHinenKeyFile(file, store), isTrue);
    expect(store.values['hinen-1'], '0123456789abcdef');
    expect(await file.exists(), isFalse);
  });

  test('rejects an invalid key without writing', () async {
    final directory = await Directory.systemTemp.createTemp('hinen-import');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/localhome-hinen.env')
      ..writeAsStringSync(
        'HINEN_LOCAL_KEY=short\n'
        'HINEN_PROFILE_ID=hinen-1\n',
      );
    final store = _FakeStore();

    expect(await importHinenKeyFile(file, store), isFalse);
    expect(store.values, isEmpty);
  });
}
