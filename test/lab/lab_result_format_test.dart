import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/lab/core/lab_result_format.dart';

/// `labNumber` powers on-screen numeric previews (formula results, fixed
/// values): at most 3 decimals, trailing zeros trimmed, '' when not numeric.
void main() {
  group('labNumber', () {
    test('rounds to at most 3 decimals', () {
      expect(labNumber(1 / 3), '0.333');
      expect(labNumber(2.9999), '3');
      expect(labNumber(1.23456), '1.235');
    });

    test('trims trailing zeros', () {
      expect(labNumber(5.0), '5');
      expect(labNumber(12.50), '12.5');
      expect(labNumber(12.500), '12.5');
    });

    test('returns empty for missing or non-numeric values', () {
      expect(labNumber(null), '');
      expect(labNumber(''), '');
      expect(labNumber('abc'), '');
    });
  });
}
