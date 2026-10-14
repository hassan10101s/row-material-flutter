import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/utils/reference_range.dart';

/// The single range formatter every inspection surface uses: closed ranges,
/// one-sided bounds, exact values, free text and empty input.
void main() {
  test('closed JSON bound renders as a dash range with unit', () {
    final r = formatReferenceRange({
      'value': {'min': 0.5, 'max': 2, 'unit': '%'},
    });
    expect(r.display, '0.5 – 2');
    expect(r.unit, '%');
    expect(r.withUnit, '0.5 – 2 %');
    expect(r.isEmpty, isFalse);
  });

  test('equal bounds render as an exact target', () {
    final r = formatReferenceRange({'min': 7, 'max': 7});
    expect(r.display, '= 7');
  });

  test('upper-only bound renders with ≤', () {
    expect(formatReferenceRange({'max': 5, 'unit': 'ppm'}).display, '≤ 5');
    expect(
      formatReferenceRange('max 5').display,
      '≤ 5',
    );
    expect(formatReferenceRange('0.5-2').display, '0.5 – 2');
  });

  test('lower-only bound renders with ≥', () {
    expect(formatReferenceRange({'min': 0.5}).display, '≥ 0.5');
    expect(formatReferenceRange('>= 10').display, '≥ 10');
  });

  test('free text passes through cleaned, never as JSON', () {
    final r = formatReferenceRange('Ok|Good');
    expect(r.display, 'Ok|Good');
    expect(r.display.contains('{'), isFalse);
  });

  test('empty and null render as an em dash', () {
    expect(formatReferenceRange(null).display, '—');
    expect(formatReferenceRange('').display, '—');
    expect(formatReferenceRange(null).isEmpty, isTrue);
  });

  test('lone number is an exact target', () {
    expect(formatReferenceRange('7').display, '= 7');
  });
}
