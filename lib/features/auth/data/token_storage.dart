import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/settings/app_preferences.dart';

/// Secure + persisted preference storage.
class TokenStorage {
  static const String _kPrefsVersion = 'prefs_v1';
  static const String _kLocale = 'ml_locale';
  static const String _kTheme = 'ml_theme';
  static const String _kDbKey = 'ml_db_key';

  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<AppPreferences> getPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final locale = prefs.getString(_kLocale) ?? 'ar';
    final themeRaw = prefs.getString(_kTheme) ?? 'system';
    final theme = switch (themeRaw) {
      'light' => AppThemeMode.light,
      'dark' => AppThemeMode.dark,
      _ => AppThemeMode.system,
    };
    return AppPreferences(localeCode: locale, theme: theme);
  }

  Future<void> savePreferences(AppPreferences prefs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kLocale, prefs.localeCode);
    await sp.setString(_kTheme, prefs.theme.name);
    await sp.setString(_kPrefsVersion, '1');
  }

  Future<void> setTheme(AppThemeMode theme) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kTheme, theme.name);
  }

  Future<void> setLocale(String locale) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kLocale, locale);
  }

  Future<String?> getDbKey() => _secure.read(key: _kDbKey);

  Future<void> setDbKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _secure.delete(key: _kDbKey);
    } else {
      await _secure.write(key: _kDbKey, value: key);
    }
  }
}