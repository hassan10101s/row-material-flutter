import 'package:flutter/material.dart';

import '../../features/settings/data/settings_repo.dart';

/// Persisted theme mode stored in the settings table
/// (`theme_mode` = 'system' | 'light' | 'dark').
///
/// This used to map only 'light' and 'dark', so [ThemeMode.system] was
/// unreachable and the app always started in light regardless of the OS
/// setting. 'system' is now the default.
///
/// A second, unwired theme store also exists in
/// `features/auth/data/token_storage.dart` (`_kTheme`, default 'system'). It
/// writes to SharedPreferences and is never read back; nothing should write to
/// it.
class ThemeService extends ChangeNotifier {
  ThemeService({required this.settings});

  final SettingsRepo settings;

  static const _key = 'theme_mode';
  static const _system = 'system';
  static const _light = 'light';
  static const _dark = 'dark';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  Future<void> init() async {
    final value = await settings.getSettingValue(_key);
    _mode = switch (value) {
      _dark => ThemeMode.dark,
      _light => ThemeMode.light,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await settings.updateSettings({_key: _encode(mode)});
  }

  /// Cycles light -> dark -> system. Used by the compact top-bar toggle, which
  /// has room for two states but not three.
  Future<void> toggle() {
    final next = switch (_mode) {
      ThemeMode.dark => ThemeMode.system,
      ThemeMode.system => ThemeMode.dark,
      ThemeMode.light => ThemeMode.dark,
    };
    return setMode(next);
  }

  static String _encode(ThemeMode mode) => switch (mode) {
        ThemeMode.dark => _dark,
        ThemeMode.light => _light,
        ThemeMode.system => _system,
      };

  /// The three selectable values, in the order a settings control should show
  /// them.
  static const selectable = <ThemeMode>[
    ThemeMode.system,
    ThemeMode.light,
    ThemeMode.dark,
  ];
}
