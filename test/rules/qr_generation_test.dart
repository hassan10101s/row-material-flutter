import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/reports/data/qr_render.dart';

/// Phase 3 parity tests for QR data-URI generation & truncation
/// (PLAN §5.2 — reference core/utils.py:548-597 generate_qr_data_uri).
void main() {
  group('generateQrDataUri (utils.py:548-597)', () {
    test('empty payload returns empty data URI + English message', () {
      final r = generateQrDataUri('');
      expect(r.dataUri, '');
      expect(r.warning, 'QR payload is empty.');
      expect(() => qrPngBytes(''), throwsA(isA<AppError>()));
    });

    test('ordinary Arabic payload produces a decodable PNG data URI', () {
      final r = generateQrDataUri('Quality Lab QC-2026-001 | مختبر المواد');
      expect(r.dataUri, startsWith('data:image/png;base64,'));
      expect(r.warning, isEmpty);
      final png = base64Decode(
          r.dataUri.replaceFirst('data:image/png;base64,', ''));
      expect(img.decodePng(png), isNotNull);
    });

    test('a large payload near capacity still generates', () {
      final big = List.filled(1500, 'A').join();
      final r = generateQrDataUri(big);
      expect(r.dataUri, startsWith('data:image/png;base64,'));
      expect(r.warning, isEmpty);
    });

    test('>2400-byte payload degrades like the reference (both attempts fail)', () {
      final tooBig = List.filled(3000, 'A').join();
      final r = generateQrDataUri(tooBig);
      // First attempt exceeds version 40; the truncation retry (utf-8[:2380] +
      // "[truncated]") also exceeds the 2331-byte version-40/M capacity, so the
      // reference's final outcome is "Data exceeds QR code capacity".
      expect(r.dataUri, '');
      expect(r.warning, contains('capacity'));
      expect(() => qrPngBytes(tooBig), throwsA(isA<AppError>()));
    });
  });
}