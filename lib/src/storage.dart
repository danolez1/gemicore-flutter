import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the SDK keeps the customer token and the cached customer info between launches.
abstract interface class GemicoreStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain on iOS, encrypted storage on Android, so the customer token never sits in plain prefs.
class SecureGemicoreStorage implements GemicoreStorage {
  SecureGemicoreStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryGemicoreStorage implements GemicoreStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

// The key is part of the storage name so a test key and a live key never share a customer.
String storageKey(String apiKey, String name) {
  final mode = apiKey.startsWith('pk_test_') || apiKey.startsWith('sk_test_') ? 'test' : 'live';
  final tail = apiKey.length > 8 ? apiKey.substring(apiKey.length - 8) : apiKey;
  return 'gemicore.$mode.$tail.$name';
}
