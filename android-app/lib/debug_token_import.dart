import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'miio_packet.dart';
import 'token_store.dart';

/// Parse simple KEY=VALUE lines, ignoring comments and blank lines.
Map<String, String> parseEnvLines(Iterable<String> lines) {
  final values = <String, String>{};
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#') || !trimmed.contains('=')) {
      continue;
    }
    final index = trimmed.indexOf('=');
    final key = trimmed.substring(0, index).trim();
    final value = trimmed.substring(index + 1).trim();
    if (key.isNotEmpty) values[key] = value;
  }
  return values;
}

/// Import a staged token into [store] and delete the staging file.
Future<bool> importTokenFile(File file, TokenStore store) async {
  if (!await file.exists()) return false;
  final values = parseEnvLines(await file.readAsLines());
  final token = values['MIIO_TOKEN'];
  final profileId = values['MIIO_PROFILE_ID'];
  if (token == null || profileId == null || profileId.isEmpty) {
    return false;
  }
  parseMiioToken(token);
  await store.write(profileId, token);
  await file.delete();
  return true;
}

/// Debug-only import used by scripts/inject_purifier.py.
///
/// The seed file lives in the app's private support directory, is written over
/// adb, and is deleted after the token is stored in the Android keystore.
/// Release builds never read this file.
Future<bool> importDebugTokenIfPresent() async {
  if (!kDebugMode) return false;
  try {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/localhome-miio.env');
    return await importTokenFile(file, SecureTokenStore());
  } on Object {
    return false;
  }
}
