import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-profile storage for the Tuya local key.
///
/// The key never goes into [HinenProfile] or shared preferences. The interface
/// is injectable so tests do not need the platform keystore.
abstract class HinenKeyStore {
  Future<String?> read(String profileId);
  Future<void> write(String profileId, String key);
  Future<void> delete(String profileId);
}

class SecureHinenKeyStore implements HinenKeyStore {
  SecureHinenKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(
        aOptions: AndroidOptions(),
      );

  final FlutterSecureStorage _storage;

  static String _key(String profileId) => 'localhome.hinen.key.$profileId';

  @override
  Future<String?> read(String profileId) =>
      _storage.read(key: _key(profileId));

  @override
  Future<void> write(String profileId, String key) =>
      _storage.write(key: _key(profileId), value: key);

  @override
  Future<void> delete(String profileId) =>
      _storage.delete(key: _key(profileId));
}
