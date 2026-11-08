import 'dart:async';

/// Report language is a device preference, independent of the application UI.
/// A zone scopes synchronous builders and their helpers without global mutation.
abstract final class ReportText {
  static const _localeKey = #materialLabReportLanguage;
  static bool get active => Zone.current[_localeKey] != null;
  static bool get arabic => Zone.current[_localeKey] != 'en';
  static String t(String ar, String en) => arabic ? ar : en;
  static String department(Map<String, dynamic> settings) {
    final value = '${settings['department_label'] ?? ''}';
    if (value.isEmpty ||
        value == 'Quality Assurance Department' ||
        value == 'قسم ضمان الجودة') {
      return t('قسم ضمان الجودة', 'Quality Assurance Department');
    }
    return value;
  }

  static bool isEnglish(Map<String, dynamic> settings) =>
      settings['report_language'] == 'en';
  static T withSettings<T>(Map<String, dynamic> settings, T Function() build) =>
      runZoned(() {
        final result = build();
        if (result is Map<String, dynamic>) {
          final display = _copy(result) as Map<String, dynamic>;
          _localizeNames(display);
          return display as T;
        }
        return result;
      }, zoneValues: {_localeKey: isEnglish(settings) ? 'en' : 'ar'});

  static Object? _copy(Object? value) {
    if (value is Map<String, dynamic>) {
      return <String, dynamic>{
        for (final entry in value.entries) entry.key: _copy(entry.value),
      };
    }
    if (value is List<Map<String, dynamic>>) {
      return <Map<String, dynamic>>[
        for (final entry in value) _copy(entry) as Map<String, dynamic>,
      ];
    }
    if (value is List) return [for (final entry in value) _copy(entry)];
    return value;
  }

  static void _localizeNames(Object? node) {
    if (node is List) {
      for (final value in node) {
        _localizeNames(value);
      }
    } else if (node is Map<String, dynamic>) {
      for (final key in node.keys.toList()) {
        final value = node[key];
        if (const {
              'name',
              'material_name',
              'source_name',
              'analysis_name',
            }.contains(key) &&
            value is String) {
          final parts = value.split(RegExp(r'\s*[|/]\s*'));
          final hasArabic = parts.any((p) => RegExp(r'[؀-ۿ]').hasMatch(p));
          final hasEnglish = parts.any((p) => RegExp(r'[A-Za-z]').hasMatch(p));
          if (parts.length > 1 && hasArabic && hasEnglish) {
            final selected = parts.where(
              (p) => arabic
                  ? RegExp(r'[؀-ۿ]').hasMatch(p)
                  : !RegExp(r'[؀-ۿ]').hasMatch(p),
            );
            if (selected.isNotEmpty) node[key] = selected.join(' / ');
          }
        } else {
          _localizeNames(value);
        }
      }
    }
  }
}
