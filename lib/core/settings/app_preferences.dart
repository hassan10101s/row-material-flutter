enum AppThemeMode { system, light, dark }

class AppPreferences {
  final String localeCode;
  final AppThemeMode theme;
  final String defaultExportDir;
  final String? reportLogoPath;

  const AppPreferences({
    this.localeCode = 'ar',
    this.theme = AppThemeMode.system,
    this.defaultExportDir = '',
    this.reportLogoPath,
  });

  AppPreferences copyWith({
    String? localeCode,
    AppThemeMode? theme,
    String? defaultExportDir,
    String? reportLogoPath,
  }) =>
      AppPreferences(
        localeCode: localeCode ?? this.localeCode,
        theme: theme ?? this.theme,
        defaultExportDir: defaultExportDir ?? this.defaultExportDir,
        reportLogoPath: reportLogoPath ?? this.reportLogoPath,
      );
}