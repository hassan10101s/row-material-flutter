import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/security/qr_payload.dart';
import 'package:material_lab/core/security/seal_codec.dart';
import 'package:material_lab/features/reports/data/report_builder.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';

void main() {
  final product = <String, dynamic>{
    'id': 1,
    'entry_code': 'P-20261029-001',
    'inspection_kind': 'product',
    'material_name': 'Test product',
    'formula_number': 'PRIVATE-FORMULA-521',
    'batch_number': 'PRIVATE-BATCH-739',
    'quantity': 20,
    'decision_status': 'APPROVED',
    'inspection_date': '2026-10-29',
  };
  test(
    'single and batch product labels omit formula and batch in both languages',
    () {
      for (final language in ['ar', 'en']) {
        final settings = {'report_language': language};
        final single = buildLabelContext(product, settings: settings);
        final batch = buildBatchLabelsContext([product], settings: settings);
        expect(
          (single['inspection'] as Map).containsKey('formula_number'),
          false,
        );
        expect(
          (batch['labels'] as List).first.containsKey('batch_number'),
          false,
        );
        for (final entry in {
          'label_template.html': single,
          'batch_label_template.html': batch,
        }.entries) {
          final html = tinyJinjaRender(
            File('assets/templates/${entry.key}').readAsStringSync(),
            entry.value,
          );
          expect(html, contains('P-20261029-001'));
          expect(html, isNot(contains('PRIVATE-FORMULA-521')));
          expect(html, isNot(contains('PRIVATE-BATCH-739')));
          expect(html, isNot(contains('Formula Number')));
          expect(html, isNot(contains('Batch Number')));
        }
      }
      expect(product['formula_number'], 'PRIVATE-FORMULA-521');
      expect(product['batch_number'], 'PRIVATE-BATCH-739');
      final report = buildInspectionContext(product, settings: {});
      expect(report['formula_number'], product['formula_number']);
      expect(report['batch_number'], product['batch_number']);
    },
  );
  test('plain and sealed product QR carry only the inspection pointer', () {
    final key = List<int>.generate(32, (i) => i);
    for (final encryptionSecret in <List<int>?>[null, key]) {
      final ctx = buildLabelContext(
        product,
        settings: {},
        encryptionSecret: encryptionSecret,
      );
      final payload = tryParseAppQr(ctx['qr_payload_text'] as String)!;
      expect(payload.entryCode, product['entry_code']);
      final body = encryptionSecret == null
          ? payload.body
          : unsealText(payload.body, key).$1;
      expect(jsonDecode(body), {'ec': product['entry_code']});
    }
  });
}
