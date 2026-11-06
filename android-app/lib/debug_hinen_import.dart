import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'debug_token_import.dart' show parseEnvLines;
import 'hinen_key_store.dart';

/// Import a staged Tuya local key into [store] and delete the staging file.
Future<bool> importHinenKeyFile(File file, HinenKeyStore store) async {
  if (!await file.exists()) return false;
  final values = parseEnvLines(await file.readAsLines());
  final key = values['HINEN_LOCAL_KEY'];
  final profileId = values['HINEN_PROFILE_ID'];
  if (key == null || key.length != 16 || profileId == null || profileId.isEmpty) {
    return false;
  }
  await store.write(profileId, key);
  await file.delete();
  return true;
}

/// Debug-only import used by scripts/inject_hinen.py.
///
/// The seed file lives in the app's private support directory, is written over
/// adb, and is deleted after the key is stored in the Android keystore.
/// Release builds never read this file.
Future<bool> importDebugHinenKeyIfPresent() async {
  if (!kDebugMode) return false;
  try {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/localhome-hinen.env');
    return await importHinenKeyFile(file, SecureHinenKeyStore());
  } on Object {
    return false;
  }
}
