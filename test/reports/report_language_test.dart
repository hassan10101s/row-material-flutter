import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/reports/data/report_builder.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';

void main() {
  test('report language controls dates and decisions independently of UI', () {
    final original = AppText.arabic;
    addTearDown(() => AppText.arabic = original);
    final row = <String, dynamic>{
      'id': 1,
      'entry_code': 'C-1',
      'material_name': 'Corn | ذرة',
      'decision_status': 'APPROVED',
      'quantity': 10,
    };
    AppText.useLanguage('ar');
    final english = buildDailyContext(
      [row],
      settings: {'report_language': 'en'},
      dateStr: '2026-10-28',
    );
    expect(english['is_en'], true);
    expect((english['material_sections'] as List).first['name'], 'Corn');
    expect(
      row['material_name'],
      'Corn | ذرة',
      reason: 'Report formatting must never mutate source data',
    );
    expect(english['formatted_date'], contains('October'));
    expect(
      (english['material_sections'] as List)
          .first['rows']
          .first['decision_status'],
      isNot(matches(RegExp(r'[؀-ۿ]'))),
    );
    AppText.useLanguage('en');
    final arabic = buildDailyContext(
      [row],
      settings: {'report_language': 'ar'},
      dateStr: '2026-10-28',
    );
    expect(arabic['is_en'], false);
    expect(arabic['formatted_date'], contains('أكتوبر'));
    expect(arabic['department_label'], 'قسم ضمان الجودة');
    expect(
      AppText.arabic,
      false,
      reason: 'Rendering must not mutate the UI language',
    );
  });

  test('English templates contain no fixed Arabic captions', () {
    for (final file in Directory(
      'assets/templates',
    ).listSync().whereType<File>()) {
      if (!file.path.endsWith('.html')) continue;
      final html = tinyJinjaRender(file.readAsStringSync(), {'is_en': true});
      final visible = html
          .replaceAll(RegExp(r'<style[\s\S]*?</style>'), '')
          .replaceAll(RegExp(r'<[^>]+>'), '');
      expect(visible, isNot(matches(RegExp(r'[؀-ۿ]'))), reason: file.path);
      expect(html, contains('dir="ltr"'), reason: file.path);
    }
  });
}
