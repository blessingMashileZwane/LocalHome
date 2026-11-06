import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-profile storage for the purifier token.
///
/// The token never goes into [AirPurifierProfile] or shared preferences. The
/// interface is injectable so tests do not need the platform keystore.
abstract class TokenStore {
  Future<String?> read(String profileId);
  Future<void> write(String profileId, String token);
  Future<void> delete(String profileId);
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
          );

  final FlutterSecureStorage _storage;

  static String _key(String profileId) =>
      'localhome.purifier.token.$profileId';

  @override
  Future<String?> read(String profileId) =>
      _storage.read(key: _key(profileId));

  @override
  Future<void> write(String profileId, String token) =>
      _storage.write(key: _key(profileId), value: token);

  @override
  Future<void> delete(String profileId) =>
      _storage.delete(key: _key(profileId));
}
