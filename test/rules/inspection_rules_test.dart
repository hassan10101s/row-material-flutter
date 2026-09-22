import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/inspections/domain/inspection_rules.dart';

/// Phase 3 parity tests for decision validation & normalization
/// (PLAN §5.2 — reference core/services/inspection.py:52-99).
void main() {
  Map<String, dynamic> valid({required String status}) => {
        'decision_status': status,
        'decision_reason': 'reason',
        'follow_up_note': 'note',
        'rejected_quantity': '0',
        'quantity': '500',
      };

  group('validateDecisionFields (inspection.py:52-93)', () {
    test('rejects an unsupported decision status', () {
      expect(
        () => validateDecisionFields({'decision_status': 'UNKNOWN'}),
        throwsA(isA<ValidationError>()),
      );
    });

    for (final status in [
      'CONDITIONAL_APPROVAL',
      'PARTIAL_REJECTION',
      'FULL_REJECTION',
    ]) {
      test('decision_reason is required for $status', () {
        final d = valid(status: status)
          ..['decision_reason'] = '   ';
        expect(
          () => validateDecisionFields(d),
          throwsA(isA<ValidationError>()),
        );
      });
    }

    test('APPROVED accepts an empty decision_reason', () {
      expect(
        () => validateDecisionFields(valid(status: 'APPROVED')
          ..['decision_reason'] = ''),
        returnsNormally,
      );
    });

    test('follow_up_note required for CONDITIONAL_APPROVAL', () {
      final d = valid(status: 'CONDITIONAL_APPROVAL')
        ..['follow_up_note'] = '';
      expect(
        () => validateDecisionFields(d),
        throwsA(predicate<ValidationError>(
            (e) => e.message.contains('ملاحظة المتابعة'))),
      );
    });

    test('follow_up_note not required for other non-approved statuses', () {
      for (final status in ['PARTIAL_REJECTION', 'FULL_REJECTION']) {
        expect(
          () => validateDecisionFields(valid(status: status)
            ..['follow_up_note'] = ''),
          returnsNormally,
        );
      }
    });

    test('PARTIAL_REJECTION requires a non-blank rejected_quantity', () {
      final d = valid(status: 'PARTIAL_REJECTION')
        ..['rejected_quantity'] = '  ';
      expect(
        () => validateDecisionFields(d),
        throwsA(predicate<ValidationError>(
            (e) => e.message.contains('الكمية المرفوضة'))),
      );
    });

    test('PARTIAL_REJECTION rejects rejected_quantity exceeding quantity', () {
      final d = valid(status: 'PARTIAL_REJECTION')
        ..['rejected_quantity'] = '600'
        ..['quantity'] = '500';
      expect(
        () => validateDecisionFields(d),
        throwsA(predicate<ValidationError>(
            (e) => e.message.contains('لا يمكن أن تتجاوز كمية الشحنة'))),
      );
    });

    test('PARTIAL_REJECTION accepts rejected_quantity <= quantity', () {
      final d = valid(status: 'PARTIAL_REJECTION')
        ..['rejected_quantity'] = '250'
        ..['quantity'] = '500';
      expect(() => validateDecisionFields(d), returnsNormally);
    });

    test('rejected_quantity must be numeric for every status when provided', () {
      for (final status in ['APPROVED', 'CONDITIONAL_APPROVAL', 'FULL_REJECTION']) {
        final d = valid(status: status)..['rejected_quantity'] = 'abc';
        expect(
          () => validateDecisionFields(d),
          throwsA(predicate<ValidationError>(
              (e) => e.message.contains('numbers only'))),
          reason: '$status accepted a non-numeric rejected_quantity',
        );
      }
    });
  });

  group('normalizeDecisionFields (inspection.py:94-99)', () {
    Map<String, dynamic> dirty({required String status}) => {
          'decision_status': status,
          'decision_reason': 'keep-me',
          'follow_up_note': 'note',
          'rejected_quantity': '5',
        };

    test('CONDITIONAL_APPROVAL keeps follow_up, clears rejected_quantity', () {
      final n = normalizeDecisionFields(dirty(status: 'CONDITIONAL_APPROVAL'));
      expect(n['follow_up_note'], 'note');
      expect(n['rejected_quantity'], '');
    });

    test('PARTIAL_REJECTION keeps rejected_quantity, clears follow_up', () {
      final n = normalizeDecisionFields(dirty(status: 'PARTIAL_REJECTION'));
      expect(n['rejected_quantity'], '5');
      expect(n['follow_up_note'], '');
    });

    test('FULL_REJECTION clears follow_up and rejected_quantity', () {
      final n = normalizeDecisionFields(dirty(status: 'FULL_REJECTION'));
      expect(n['follow_up_note'], '');
      expect(n['rejected_quantity'], '');
    });

    test('APPROVED clears follow_up and rejected_quantity but keeps reason', () {
      final n = normalizeDecisionFields(dirty(status: 'APPROVED'));
      expect(n['follow_up_note'], '');
      expect(n['rejected_quantity'], '');
      expect(n['decision_reason'], 'keep-me');
    });

    test('decision_reason is never cleared by normalization', () {
      final full = normalizeDecisionFields(dirty(status: 'FULL_REJECTION'));
      final approved = normalizeDecisionFields(dirty(status: 'APPROVED'));
      expect(full['decision_reason'], 'keep-me');
      expect(approved['decision_reason'], 'keep-me');
    });
  });
}