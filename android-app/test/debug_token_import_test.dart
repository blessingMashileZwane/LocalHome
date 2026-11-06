import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/debug_token_import.dart';
import 'package:localhome/miio_packet.dart';
import 'package:localhome/token_store.dart';

const tokenHex = '00112233445566778899aabbccddeeff';

class _FakeStore implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String profileId) async => values[profileId];

  @override
  Future<void> write(String profileId, String token) async {
    values[profileId] = token;
  }

  @override
  Future<void> delete(String profileId) async {
    values.remove(profileId);
  }
}

void main() {
  test('parseEnvLines trims and ignores comments', () {
    final values = parseEnvLines([
      '# comment',
      '',
      'MIIO_TOKEN=$tokenHex',
      'MIIO_PROFILE_ID = purifier-1 ',
    ]);
    expect(values['MIIO_TOKEN'], tokenHex);
    expect(values['MIIO_PROFILE_ID'], 'purifier-1');
  });

  test('importTokenFile writes the token and deletes the seed', () async {
    final directory = await Directory.systemTemp.createTemp('localhome-token');
    final file = File('${directory.path}/localhome-miio.env');
    await file.writeAsString(
      'MIIO_TOKEN=$tokenHex\nMIIO_PROFILE_ID=purifier-1\n',
    );
    final store = _FakeStore();

    expect(await importTokenFile(file, store), isTrue);
    expect(store.values['purifier-1'], tokenHex);
    expect(await file.exists(), isFalse);

    await directory.delete(recursive: true);
  });

  test('importTokenFile rejects a bad token without storing it', () async {
    final directory = await Directory.systemTemp.createTemp('localhome-token');
    final file = File('${directory.path}/localhome-miio.env');
    await file.writeAsString(
      'MIIO_TOKEN=not-a-token\nMIIO_PROFILE_ID=purifier-1\n',
    );
    final store = _FakeStore();

    await expectLater(
      importTokenFile(file, store),
      throwsA(isA<MiioException>()),
    );
    expect(store.values, isEmpty);

    await directory.delete(recursive: true);
  });
}
