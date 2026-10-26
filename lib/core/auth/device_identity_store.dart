import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Installation identity is independent of the currently open org database.
/// Existing installations keep their id; only explicit fresh enrollment rotates
/// it. A hostname is not a unique Android installation identifier.
class DeviceIdentityStore {
  DeviceIdentityStore({
    FlutterSecureStorage? storage,
    String Function()? generate,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(resetOnError: true),
           ),
       _generate = generate ?? newId;

  static const key = 'ml_installation_identity_v1';
  final FlutterSecureStorage _storage;
  final String Function() _generate;
  String? _current;

  static String newId() =>
      'device_${Platform.operatingSystem}_${const Uuid().v4()}';

  Future<String> loadOrMigrate(String legacyId) async {
    if (_current != null) return _current!;
    final saved = await _storage.read(key: key);
    if (saved != null && saved.isNotEmpty) return _current = saved;
    final value = legacyId.isNotEmpty ? legacyId : _generate();
    await _storage.write(key: key, value: value);
    return _current = value;
  }

  Future<String> rotate() async {
    final value = _generate();
    await _storage.write(key: key, value: value);
    return _current = value;
  }
}
