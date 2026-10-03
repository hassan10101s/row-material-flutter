import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/domain/rules.dart' as rules;
import 'package:material_lab/core/services/aggregation.dart' as agg;

/// Decision-status labels have TWO independent sources of truth for the exact
/// same user-facing string:
///   lib/core/domain/rules.dart        → decisionLabels : {code: {ar, en, css}}
///   lib/core/services/aggregation.dart → decisionLabels : {code: arabic}
/// Both are consumed by different screens (the domain map by the inspection UI /
/// RTL + English rendering, the aggregation map by every report, PDF and
/// per-material summary), so any divergence is shown side by side to the same
/// user in the same session.
///
/// THE BUG CLASS IS THE DUPLICATION ITSELF: nothing links the two maps, so
/// nothing stops a wording change in one file from never reaching the other.
/// The two have ALREADY drifted on CONDITIONAL_APPROVAL.
void main() {
  group('decision label parity — the two maps must agree', () {
    // RULE: decisionCodes (rules.dart:27) is the canonical list of statuses, and
    // every code in it must be resolvable in BOTH maps.
    // SILENT-WRONG VALUE PREVENTED: a status that exists in one map only prints
    // as a raw code ("CONDITIONAL_APPROVAL") in the other surface — no label,
    // no translation, on a certificate of analysis.
    test('every decision code has a label in BOTH maps', () {
      expect(rules.decisionCodes, isNotEmpty);
      for (final code in rules.decisionCodes) {
        expect(rules.decisionLabels, contains(code),
            reason: 'rules.dart decisionLabels is missing $code');
        expect(rules.decisionLabels[code], contains('ar'),
            reason: 'rules.dart has no Arabic label for $code');
        expect(agg.decisionLabels, contains(code),
            reason: 'aggregation.dart decisionLabels is missing $code');
        expect(agg.decisionLabels[code], isNotEmpty,
            reason: 'aggregation.dart has an empty Arabic label for $code');
      }
    });

    // RULE: the Arabic text a user reads for a status must be BYTE-IDENTICAL in
    // both maps. These are the same string, shown in the same product.
    // SILENT-WRONG VALUE PREVENTED: the inspector reads
    // "قبول مبدئي مع المتابعة" on the inspection screen and
    // "قبول مع متابعة" on the exported PDF of that very inspection — two
    // different names for one decision, which is indefensible in a dispute.
    test('the Arabic label of every code is identical in both maps', () {
      final drifts = <String>[];
      for (final code in rules.decisionCodes) {
        final fromDomain = rules.decisionLabels[code]!['ar'];
        final fromAggregation = agg.decisionLabels[code];
        if (fromDomain != fromAggregation) {
          drifts.add('$code:\n'
              '        rules.dart      (core/domain/rules.dart:35)       -> "$fromDomain"\n'
              '        aggregation.dart (core/services/aggregation.dart:4) -> "$fromAggregation"');
        }
      }
      expect(
        drifts,
        isEmpty,
        reason: 'DUPLICATE SOURCES OF TRUTH — the Arabic decision label must be '
            'one string, but ${drifts.length} code(s) drifted:\n'
            '        ${drifts.join('\n        ')}',
      );
    });

    // RULE: neither map may invent a code outside decisionCodes — an extra key
    // is a status that validates nowhere but still prints a label, so a report
    // can display a decision that the form cannot produce.
    test('neither map carries a code outside decisionCodes', () {
      expect(rules.decisionLabels.keys.toSet().difference(rules.decisionCodes.toSet()),
          isEmpty,
          reason: 'rules.dart labels a status that is not a valid code');
      expect(
          agg.decisionLabels.keys.toSet().difference(rules.decisionCodes.toSet()),
          isEmpty,
          reason: 'aggregation.dart labels a status that is not a valid code');
    });

    // RULE: rules.dart is the bilingual source of truth, so every code must
    // carry ar + en + css; aggregation.dart is Arabic-only by design and needs
    // no translation keys. This test documents WHY the two maps may differ in
    // shape while agreeing on the Arabic string.
    test('rules.dart carries ar/en/css for every code, aggregation only ar', () {
      for (final code in rules.decisionCodes) {
        expect(rules.decisionLabels[code]!.keys.toSet(), {'ar', 'en', 'css'},
            reason: 'for $code');
        expect(rules.decisionLabels[code]!['en'], isNotEmpty, reason: code);
        expect(rules.decisionLabels[code]!['css'], isNotEmpty, reason: code);
      }
    });

    // RULE: the CSS bucket (the green/amber/red grouping in the UI) must exist
    // for every code, otherwise a status renders with no colour at all.
    test('the css bucket is one of the four known groups for every code', () {
      const known = {'Approved', 'Partial', 'Rejected'};
      for (final code in rules.decisionCodes) {
        expect(known, contains(rules.decisionLabels[code]!['css']),
            reason: 'for $code');
      }
    });
  });

  group('decisionLabel — fallback for an unknown or missing status', () {
    // RULE: an unknown code must resolve to something SAFE AND NON-EMPTY — an
    // empty cell reads as "no decision recorded" on a certificate, which is a
    // materially different claim from "unknown decision".
    // SILENT-WRONG VALUE PREVENTED: '' in the Decision column of a released
    // report.
    test('an unknown code resolves to a non-empty, visible placeholder', () {
      for (final unknown in ['UNKNOWN', 'DRAFT', 'approved', 'APPROVED ']) {
        final label = agg.decisionLabel(unknown);
        expect(label, isNotEmpty, reason: 'for <$unknown>');
        expect(label.trim(), isNotEmpty, reason: 'for <$unknown>');
        // PINNED: it is the RAW code — safe (never blank) but not Arabic, and
        // note the case/whitespace near-miss: 'APPROVED ' is NOT trimmed, so a
        // stray space prints an untranslated status code on the PDF.
        expect(label, unknown, reason: 'for <$unknown>');
      }
    });

    // RULE: a null status resolves to the "-" placeholder, never '' and never
    // the text "null".
    // SILENT-WRONG VALUE PREVENTED: a decision column that literally prints
    // "null" on a PDF.
    test('a null status resolves to "-"', () {
      expect(agg.decisionLabel(null), '-');
    });

    // RULE (defect): an EMPTY-STRING status must resolve to the same "-" as a
    // null status. `decisionLabel` (aggregation.dart:11-12) evaluates
    // `decisionLabels[status ?? ''] ?? status ?? '-'`; for '' the middle arm
    // wins, so the last arm is UNREACHABLE for any non-null status and the
    // label is the EMPTY STRING.
    // SILENT-WRONG VALUE PREVENTED: a blank Decision cell on a certificate —
    // indistinguishable from "no decision recorded", and it is what
    // detailRow prints for a row whose decision_status is empty.
    test('an empty status must not resolve to an empty label', () {
      expect(agg.decisionLabel(''), isNot(equals('')),
          reason: 'PINNED DEFECT: decisionLabel("") returns "" because the '
              '`?? status` arm shadows the `?? "-"` arm');
      expect(agg.decisionLabel(''), '-',
          reason: 'PINNED DEFECT: the placeholder "-" is unreachable for '
              'every non-null status');
    });

    // RULE: the four known codes resolve to their Arabic label through the
    // lookup — this is the path used by detailRow (aggregation.dart:109).
    test('every known code resolves through the lookup to a non-empty label', () {
      for (final code in rules.decisionCodes) {
        final label = agg.decisionLabel(code);
        expect(label, isNotEmpty, reason: code);
        expect(label, isNot(equals(code)), reason: '$code was NOT translated');
        expect(label, agg.decisionLabels[code], reason: code);
      }
    });
  });

  group('aggregateTotals — _safeQty coercion can UNDERSTATE a total', () {
    Map<String, dynamic> row(String status, Object? qty, [Object? rejQty]) => {
          'decision_status': status,
          'quantity': qty,
          'rejected_quantity': rejQty ?? 0,
          'supplier': 'S',
          'material_name': 'M',
        };

    // RULE: _safeQty (aggregation.dart:14) coerces an unparseable quantity to
    // the caller's fallback (0) — it is not an error, it just vanishes.
    // SILENT-WRONG VALUE PREVENTED: 'total_qty' of 0.0 for a real shipment,
    // so a QA manager reconciles the report against a total that is missing
    // the tonnage of the malformed rows — and approval_rate is unaffected,
    // which makes the wrong number look authoritative.
    test('an unparseable quantity is coerced to 0 and understates total_qty',
        () {
      final totals = agg.aggregateTotals([
        row('APPROVED', '1000'),
        row('APPROVED', 'N/A'),
        row('APPROVED', ''),
        row('APPROVED', null),
        row('APPROVED', 'abc'),
      ]);
      expect(totals['total_qty'], 1000.0,
          reason: 'PINNED: four rows of unknown quantity were dropped silently');
      expect(totals['approved'], 5,
          reason: 'the COUNT still includes them — quantity and count now '
              'disagree');
      expect(totals['approval_rate'], 100.0,
          reason: 'the rate is unaffected by the dropped quantities');
    });

    // RULE: a FULL_REJECTION contributes its whole quantity to the rejected
    // total. If the quantity is unparseable that rejected tonnage disappears,
    // so 'total_accepted_qty' looks clean.
    // SILENT-WRONG VALUE PREVENTED: a fully rejected batch reported as 0 kg
    // rejected and the full quantity counted as ACCEPTED.
    test('a full rejection with an unreadable quantity vanishes from the totals',
        () {
      final totals = agg.aggregateTotals([
        row('APPROVED', '500'),
        row('FULL_REJECTION', 'n/a'),
      ]);
      expect(totals['rejected'], 1);
      expect(totals['total_rejected_qty'], 0.0,
          reason: 'PINNED: the rejected tonnage is 0 even though a batch was '
              'rejected outright');
      expect(totals['total_accepted_qty'], 500.0,
          reason: 'PINNED: the rejected batch is counted as accepted tonnage');
    });

    // RULE: a PARTIAL_REJECTION adds only rejected_quantity. A blank or
    // unparseable rejected_quantity is coerced to 0, so the shipment is
    // counted 100% accepted.
    // SILENT-WRONG VALUE PREVENTED: a half-rejected batch reported as fully
    // accepted in both tonnage and label.
    test('a blank rejected_quantity on a partial rejection counts as fully accepted',
        () {
      final totals = agg.aggregateTotals([
        row('APPROVED', '500'),
        row('PARTIAL_REJECTION', '500', '   '),
      ]);
      expect(totals['partial'], 1);
      expect(totals['total_rejected_qty'], 0.0, reason: 'PINNED');
      expect(totals['total_accepted_qty'], 1000.0,
          reason: 'PINNED: 1000 kg accepted although 500 kg was rejected');
    });

    // RULE: a well-formed partial rejection subtracts only the rejected part.
    test('a well-formed partial rejection subtracts only the rejected part', () {
      final totals = agg.aggregateTotals([
        row('APPROVED', '500'),
        row('PARTIAL_REJECTION', '500', '250'),
      ]);
      expect(totals['total_qty'], 1000.0);
      expect(totals['total_rejected_qty'], 250.0);
      expect(totals['total_accepted_qty'], 750.0);
    });

    // RULE: the approval-rate DENOMINATOR is the row count, not the sum of the
    // known statuses. A row with an unrecognised (or null) status therefore
    // drags the rate down while appearing in no bucket at all.
    // SILENT-WRONG VALUE PREVENTED: buckets that sum to less than the row count
    // on a printed summary, and an approval rate that silently disagrees with
    // the counts printed beside it.
    test('an unknown status counts in the rate denominator but in no bucket', () {
      final totals = agg.aggregateTotals([
        row('APPROVED', '100'),
        row('APPROVED', '100'),
        row('APPROVED', '100'),
        row('APPROVED', '100'),
        row('DRAFT', '100'),
      ]);
      final bucketSum = (totals['approved'] as int) +
          (totals['conditional'] as int) +
          (totals['partial'] as int) +
          (totals['rejected'] as int);
      expect(bucketSum, 4, reason: 'the DRAFT row is in no bucket');
      expect(totals['approval_rate'], 80.0,
          reason: 'PINNED: a DRAFT row still divides the denominator, so the '
              'rate reads 80% while 4 of 5 rows are approved');
    });

    // RULE: conditional counts as accepted, and conditional_partial is the
    // follow-up workload.
    test('conditional counts as accepted and feeds conditional_partial', () {
      final totals = agg.aggregateTotals([
        row('APPROVED', '10'),
        row('CONDITIONAL_APPROVAL', '10'),
        row('PARTIAL_REJECTION', '10', '1'),
      ]);
      expect(totals['approved'], 1);
      expect(totals['conditional'], 1);
      expect(totals['accepted_total'], 2);
      expect(totals['conditional_partial'], 2);
      expect(totals['approval_rate'], 66.7);
    });

    // RULE: an empty list must not divide by zero — the rate is 0.0, not NaN.
    // SILENT-WRONG VALUE PREVENTED: "NaN%" printed on an empty report.
    test('an empty list yields 0.0% and zeroed quantities, never NaN', () {
      final totals = agg.aggregateTotals([]);
      expect(totals['approval_rate'], 0.0);
      expect(totals['total_qty'], 0.0);
      expect(totals['total_rejected_qty'], 0.0);
      expect(totals['total_accepted_qty'], 0.0);
      expect(totals['unique_suppliers'], 0);
      expect(totals['unique_materials'], 0);
    });
  });

  group('groupByMaterial / uniqueSuppliersCount — bucketing and counting', () {
    Map<String, dynamic> row(String? material, Object? supplier) =>
        {'material_name': material, 'supplier': supplier, 'quantity': '1'};

    // RULE: every row lands in exactly one bucket keyed by material_name; the
    // rows keep their input order inside the bucket.
    test('rows are bucketed by material_name in input order', () {
      final grouped = agg.groupByMaterial([
        row('Wheat', 'S1'),
        row('Rice', 'S2'),
        row('Wheat', 'S3'),
      ]);
      expect(grouped.keys.toSet(), {'Wheat', 'Rice'});
      expect(grouped['Wheat']!.length, 2);
      expect(grouped['Wheat']![0]['supplier'], 'S1');
      expect(grouped['Wheat']![1]['supplier'], 'S3');
    });

    // RULE (documented defect): a row with no material_name is bucketed under
    // the literal string "Unknown", and a row with a material name that is the
    // empty string is bucketed under "" — the two are NOT merged, so one report
    // section shows an "Unknown" bucket next to an invisible empty-titled one.
    // SILENT-WRONG VALUE PREVENTED: unique_materials over-counts by treating
    // missing and blank as two different materials.
    test('missing and blank material names become distinct buckets', () {
      final grouped = agg.groupByMaterial([
        row(null, 'S1'),
        row('', 'S2'),
        row('   ', 'S3'),
        row('Wheat', 'S4'),
      ]);
      expect(grouped.keys.toSet(), {'Unknown', '', '   ', 'Wheat'},
          reason: 'PINNED DEFECT: null -> "Unknown" but blank stays blank');
      expect(agg.groupByMaterial([row(null, 'S1')]).length, 1);
      final totals = agg.aggregateTotals([
        row(null, 'S1'),
        row('', 'S2'),
      ]);
      expect(totals['unique_materials'], 2,
          reason: 'PINNED DEFECT: 2 materials for 2 rows that name none');
    });

    // RULE: suppliers are counted as a SET of trimmed names; blank and
    // whitespace-only suppliers are excluded.
    // SILENT-WRONG VALUE PREVENTED (if blanks counted): the supplier KPI
    // printed on the report header — the number of vendors actually involved in
    // the batch — inflated by rows with no vendor.
    test('supplier names are de-duplicated and blanks are excluded', () {
      expect(agg.uniqueSuppliersCount([
        row('M', 'Alpha'),
        row('M', 'Beta'),
        row('M', 'Alpha'),
        row('M', '  Alpha  '),
      ]), 2, reason: 'the same supplier counted once, trimming included');
      expect(agg.uniqueSuppliersCount([
        row('M', 'Alpha'),
        row('M', null),
        row('M', ''),
        row('M', '   '),
      ]), 1, reason: 'blank / missing suppliers are not counted');
      expect(agg.uniqueSuppliersCount([]), 0);
    });

    // RULE (documented defect): uniqueSuppliersCount accepts
    // allowBlankSuppliers and aggregateTotals forwards it, but the parameter is
    // never read — blanks are dropped unconditionally. A caller that asks for
    // blank suppliers to count is silently ignored.
    // SILENT-WRONG VALUE PREVENTED: a report that means to show "3 suppliers
    // (including the unnamed one)" showing 2.
    test('allowBlankSuppliers is accepted but has no effect', () {
      final rows = [
        row('M', 'Alpha'),
        row('M', ''),
      ];
      expect(agg.uniqueSuppliersCount(rows, allowBlankSuppliers: true), 1,
          reason: 'PINNED DEFECT: the flag is ignored');
      expect(agg.aggregateTotals(rows, allowBlankSuppliers: true)['unique_suppliers'],
          1, reason: 'PINNED DEFECT: the flag is forwarded but never honoured');
    });
  });
}