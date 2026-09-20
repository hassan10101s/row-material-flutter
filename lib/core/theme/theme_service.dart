import 'package:flutter/material.dart';

import '../../features/settings/data/settings_repo.dart';

/// Persisted light/dark theme mode stored in the settings table
/// (`theme_mode` = 'light' | 'dark').
class ThemeService extends ChangeNotifier {
  ThemeService({required this.settings});

  final SettingsRepo settings;

  static const _key = 'theme_mode';

  ThemeMode _mode = ThemeMode.light;
  ThemeMode get mode => _mode;

  Future<void> init() async {
    final value = await settings.getSettingValue(_key);
    if (value == 'dark') _mode = ThemeMode.dark;
    if (value == 'light') _mode = ThemeMode.light;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await settings
        .updateSettings({_key: mode == ThemeMode.dark ? 'dark' : 'light'});
  }

  Future<void> toggle() =>
      setMode(_mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
}