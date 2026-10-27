import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where API keys live between launches.
abstract class KeyStore {
  Future<String?> read(String name);
  Future<void> write(String name, String? value);
}

/// Keys in the platform keychain / keystore (the default).
class SecureKeyStore implements KeyStore {
  SecureKeyStore({FlutterSecureStorage? storage, this.prefix = 'omni_ai.'}) : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  final String prefix;

  @override
  Future<String?> read(String name) async {
    try {
      return await _s.read(key: '$prefix$name');
    } catch (e) {
      debugPrint('[omni_ai] could not read $name: $e');
      return null;
    }
  }

  @override
  Future<void> write(String name, String? value) async {
    if (value == null || value.isEmpty) {
      await _s.delete(key: '$prefix$name');
    } else {
      await _s.write(key: '$prefix$name', value: value);
    }
  }
}

/// Keys only in memory (tests, or keys you fetch from your own server).
class MemoryKeyStore implements KeyStore {
  MemoryKeyStore([Map<String, String>? initial]) : _m = {...?initial};
  final Map<String, String> _m;
  @override
  Future<String?> read(String name) async => _m[name];
  @override
  Future<void> write(String name, String? value) async {
    if (value == null || value.isEmpty) {
      _m.remove(name);
    } else {
      _m[name] = value;
    }
  }
}
