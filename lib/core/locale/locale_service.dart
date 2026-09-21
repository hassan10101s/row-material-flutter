import 'package:flutter/material.dart';

import '../../features/settings/data/settings_repo.dart';

/// Persisted UI locale stored in the settings table (`locale` = 'ar'|'en').
/// The app supports separate Arabic and English UIs (no merged labels).
class LocaleService extends ChangeNotifier {
  LocaleService({required this.settings});

  final SettingsRepo settings;

  static const _key = 'locale';
  static const supportedLocales = <Locale>[Locale('ar'), Locale('en')];
  static const _defaultCode = 'ar';
  static const _enCode = 'en';

  Locale _locale = const Locale(_defaultCode);
  Locale get locale => _locale;

  bool get isArabic => _locale.languageCode != _enCode;

  Future<void> init() async {
    final value = await settings.getSettingValue(_key);
    _locale = value == _enCode ? const Locale(_enCode) : const Locale(_defaultCode);
    notifyListeners();
  }

  Future<void> setLocale(Locale locale) async {
    if (locale.languageCode == _locale.languageCode) return;
    _locale = locale;
    notifyListeners();
    await settings.updateSettings({_key: locale.languageCode});
  }

  Future<void> toggle() =>
      setLocale(isArabic ? const Locale(_enCode) : const Locale(_defaultCode));
}