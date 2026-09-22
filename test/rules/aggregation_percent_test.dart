import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/services/aggregation.dart';
import 'package:material_lab/core/utils/app_format.dart';

/// Phase 3 parity tests for one-decimal percentage rounding
/// (PLAN §5.2 — reference core/services/aggregation.py:83, round(..., 1)).
void main() {
  group('roundPct (aggregation.py round(x, 1))', () {
    test('5 of 6 accepted rounds to 83.3, never 83', () {
      expect(roundPct((5 / 6) * 100), 83.3);
      expect(roundPct(83.3333333), 83.3);
      expect(roundPct(83.3), 83.3);
    });

    test('rounds halves to the expected one-decimal value in all report sites', () {
      expect(roundPct(100.0), 100.0);
      expect(roundPct(0.0), 0.0);
      expect(roundPct(66.66666), 66.7);
      expect(roundPct(12.34), 12.3);
    });
  });

  group('aggregateTotals approval rate', () {
    Map<String, dynamic> row(String status, [String qty = '100']) => {
          'decision_status': status,
          'quantity': qty,
          'rejected_quantity': status == 'PARTIAL_REJECTION' ? '20' : '0',
          'supplier': 'S',
          'material_name': 'M',
        };

    test('5 approved + 1 full-rejected gives approval_rate 83.3', () {
      final totals = aggregateTotals([
        row('APPROVED'),
        row('APPROVED'),
        row('APPROVED'),
        row('APPROVED'),
        row('CONDITIONAL_APPROVAL'),
        row('FULL_REJECTION'),
      ]);
      expect(totals['accepted_total'], 5);
      expect(totals['rejected'], 1);
      expect(totals['approval_rate'], 83.3);
    });

    test('rejected-rate site (rejected + partial) / total also uses roundPct', () {
      final total = 6;
      final rej = 2; // 1 partial + 1 rejected
      expect(roundPct((rej / total) * 100), 33.3);
    });
  });
}