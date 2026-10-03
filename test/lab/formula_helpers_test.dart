import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/lab/core/formula_engine.dart';

/// Helpers of the Lab formula engine that turn a stored *reference requirement*
/// into the numbers printed on a report/PDF.
///
/// The whole chain is
///   parseNumericRange(requirement)  ->  min_value / max_value
///   isOutOfRange(actual, min, max)  ->  the red "OUT" flag on a result cell
///   formatValueWithUnit(text, unit) ->  the string a QA inspector reads
///   inferChemicalUnit(data, name)   ->  the unit those strings carry
///
/// Every failure in this chain is SILENT: nothing throws, no error is logged,
/// the report just prints a wrong number next to a real lab result. The rules
/// pinned below are the ones where an off-by-one or a lost character would
/// admit an out-of-spec result, or flag a compliant one.
void main() {
  group('parseNumericRange — well-formed "min - max" requirement', () {
    // RULE: "5 - 10" is the canonical stored requirement form (with or without
    // spaces around the dash) and must yield min=5.0 / max=10.0.
    // SILENT-WRONG VALUE PREVENTED: a report column reading "0 - 0" because the
    // dash form failed to parse, which flags every result as OUT.
    test('"5 - 10" and "5-10" produce the same min/max', () {
      final spaced = parseNumericRange('5 - 10');
      final tight = parseNumericRange('5-10');
      for (final r in [spaced, tight]) {
        expect(r['min_text'], '5');
        expect(r['max_text'], '10');
        expect(r['min_value'], 5.0);
        expect(r['max_value'], 10.0);
      }
      expect(spaced['raw'], '5 - 10');
    });

    // RULE: decimal limits keep their fraction ("0.5 - 1.5"), because a limit of
    // 0.5 ppm is routinely truncated to 0 by an int-typed parse.
    // SILENT-WRONG VALUE PREVENTED: min 0 instead of 0.5 → a 0.4 result is
    // reported OUT when it is in spec.
    test('fractional limits keep their decimal part', () {
      final r = parseNumericRange('0.5 - 1.5');
      expect(r['min_value'], 0.5);
      expect(r['max_value'], 1.5);
      expect(r['min_text'], '0.5');
      expect(r['max_text'], '1.5');
    });

    // RULE: the reference payload is stored as a {value, unit} envelope; the
    // envelope is unwrapped BEFORE the numbers are read (references are also
    // enriched on save with withReferenceUnit).
    // SILENT-WRONG VALUE PREVENTED: min_value null for every enriched
    // reference, i.e. the OUT flag silently never fires on the whole table.
    test('a {value: ...} envelope is unwrapped before parsing', () {
      final r = parseNumericRange({'value': '5 - 10'});
      expect(r['min_value'], 5.0);
      expect(r['max_value'], 10.0);
      expect(r['raw'], '5 - 10', reason: 'raw must be the unwrapped text, '
          'not the JSON of the envelope');
    });

    // RULE: envelopes may be nested (repeated enrichment); the innermost value
    // is the payload.
    // SILENT-WRONG VALUE PREVENTED: a doubly-enriched reference losing its
    // bounds and printing "-" in the Min/Max columns.
    test('nested {value: {value: ...}} envelopes unwrap to the innermost text',
        () {
      final r = parseNumericRange({
        'value': {'value': '2 - 4'}
      });
      expect(r['min_value'], 2.0);
      expect(r['max_value'], 4.0);
    });

    // RULE: "5:10" (the colon form that isPhysicalOutOfRange normalises to a
    // dash) is still accepted by the digit-scan fallback.
    // SILENT-WRONG VALUE PREVENTED: a colon-separated requirement printing
    // "-" for both limits.
    test('a colon-separated range is accepted by the digit-scan fallback', () {
      final r = parseNumericRange('5:10');
      expect(r['min_value'], 5.0);
      expect(r['max_value'], 10.0);
    });
  });

  group('parseNumericRange — malformed / ambiguous requirement text', () {
    // RULE (documented defect): the "min - max" grammar has NO sign class, so
    // the leading "-" of a negative limit is consumed as the range separator
    // and DROPPED. "-5 - 10" therefore parses as 5.0 - 10.0.
    // SILENT-WRONG VALUE PREVENTED: a negative lower limit (e.g. pH 2.5-8, or
    // a signed delta) silently becoming +5, so every compliant reading below
    // the real limit is flagged OUT on the certificate.
    test('a negative lower bound loses its sign and becomes positive', () {
      final r = parseNumericRange('-5 - 10');
      expect(r['raw'], '-5 - 10');
      expect(r['min_text'], '5', reason: 'PINNED DEFECT: the minus sign is '
          'dropped; a signed limit is not representable');
      expect(r['min_value'], 5.0, reason: 'PINNED DEFECT — silently wrong');
      expect(r['max_value'], 10.0);
    });

    // RULE (documented defect): thousand separators are NOT understood. The
    // digit scan takes the FIRST two number-like tokens of "1,000 - 2,000",
    // i.e. "1" and "000" → min 1.0, max 0.0.
    // SILENT-WRONG VALUE PREVENTED: min=1 / max=0 makes
    // isOutOfRange true for EVERY row (anything > 0 or < 1), i.e. a 100%
    // rejection rate on a perfectly conforming batch.
    test('thousand separators yield min 1.0 / max 0.0 — every row reads OUT',
        () {
      final r = parseNumericRange('1,000 - 2,000');
      expect(r['min_text'], '1', reason: 'PINNED DEFECT');
      expect(r['max_text'], '000', reason: 'PINNED DEFECT');
      expect(r['min_value'], 1.0);
      expect(r['max_value'], 0.0);
      expect(isOutOfRange('1500', r['min_value'] as double?, r['max_value'] as double?),
          isTrue,
          reason: 'PINNED DEFECT: the inverted bounds reject the in-spec 1500');
      expect(isOutOfRange('0.5', r['min_value'] as double?, r['max_value'] as double?),
          isTrue,
          reason: 'PINNED DEFECT: nothing can satisfy min 1.0 / max 0.0');
    });

    // RULE (documented defect): an upper-only limit ("max 15") is read as a
    // MINIMUM of 15, because the single number found is always assigned to
    // min_value.
    // SILENT-WRONG VALUE PREVENTED: a 20 result that must be rejected is
    // accepted, and a compliant 5 result is flagged OUT — the flag is inverted.
    test('a "max 15" upper-only limit is inverted into a minimum of 15', () {
      final r = parseNumericRange('max 15');
      expect(r['min_value'], 15.0, reason: 'PINNED DEFECT: max-only limits '
          'become minimums');
      expect(r['max_value'], isNull);
      expect(r['max_text'], '-');
      expect(isOutOfRange('20', r['min_value'] as double?, r['max_value'] as double?),
          isFalse,
          reason: 'PINNED DEFECT: an over-limit 20 is admitted as compliant');
      expect(isOutOfRange('5', r['min_value'] as double?, r['max_value'] as double?),
          isTrue,
          reason: 'PINNED DEFECT: a compliant 5 is flagged OUT');
    });

    // RULE (documented defect): the Arabic requirement "أقل من 5" (LESS THAN 5)
    // contains one number and is therefore read as "minimum 5" — the exact
    // opposite of the specification the chemist typed.
    // SILENT-WRONG VALUE PREVENTED: an over-limit reading (e.g. 7) is silently
    // accepted on a released certificate.
    test('an Arabic "less than 5" requirement is inverted into a minimum', () {
      final r = parseNumericRange('أقل من 5');
      expect(r['min_value'], 5.0, reason: 'PINNED DEFECT: the direction word '
          'is discarded');
      expect(r['max_value'], isNull);
      expect(isOutOfRange('7', r['min_value'] as double?, r['max_value'] as double?),
          isFalse,
          reason: 'PINNED DEFECT: 7 > "less than 5" is admitted');
      expect(isOutOfRange('3', r['min_value'] as double?, r['max_value'] as double?),
          isTrue,
          reason: 'PINNED DEFECT: 3 satisfies "less than 5" yet is flagged OUT');
    });

    // RULE (documented defect): reversed bounds are preserved verbatim; no
    // swap/normalisation happens. min=10 with max=5 makes EVERY value out of
    // range (anything < 10 or > 5).
    // SILENT-WRONG VALUE PREVENTED: a typo'd requirement ("10 - 5") silently
    // rejects the entire batch instead of being rejected as invalid data.
    test('reversed bounds are kept as-is, which rejects everything', () {
      final r = parseNumericRange('10 - 5');
      expect(r['min_value'], 10.0);
      expect(r['max_value'], 5.0);
      for (final v in ['7', '5', '10', '0']) {
        expect(isOutOfRange(v, r['min_value'] as double?, r['max_value'] as double?),
            isTrue,
            reason: 'PINNED DEFECT: $v cannot satisfy min 10 / max 5');
      }
    });

    // RULE (documented defect): a doubled decimal ("1.4.5 - 2") is not matched
    // by the strict grammar, and the fallback scan pairs "1.4" with the "5".
    // SILENT-WRONG VALUE PREVENTED: a limit of 2 printed/enforced as 5, so a
    // 3.0 reading is waved through.
    test('a doubled decimal pairs the fraction with the stray digit', () {
      final r = parseNumericRange('1.4.5 - 2');
      expect(r['min_value'], 1.4, reason: 'PINNED DEFECT');
      expect(r['max_value'], 5.0, reason: 'PINNED DEFECT: 5 comes from the '
          '"1.4.5" typo, not from the stated limit 2');
    });

    // RULE: a requirement with no numbers at all (blank, null, or free text)
    // is represented by null bounds and the "-" placeholder text — never 0.
    // SILENT-WRONG VALUE PREVENTED: min 0 / max 0, which would reject every
    // positive result on a row that simply has no requirement stored.
    test('a digit-free requirement yields null bounds and "-" placeholders', () {
      for (final v in <Object?>[null, '', '   ', 'abc', 'لا يوجد']) {
        final r = parseNumericRange(v);
        expect(r['min_value'], isNull, reason: 'for <$v>');
        expect(r['max_value'], isNull, reason: 'for <$v>');
        expect(r['min_text'], '-', reason: 'for <$v>');
        expect(r['max_text'], '-', reason: 'for <$v>');
      }
    });

    // RULE: an upper-only requirement ("5", ">=5") is a minimum with no
    // maximum, and the absence of a maximum is signalled by max_text '-' plus
    // a null max_value (never 0, which would reject everything).
    test('a single number is a minimum with an absent maximum', () {
      for (final entry in {'5': 5.0, '>=5': 5.0, '10 ppm': 10.0}.entries) {
        final r = parseNumericRange(entry.key);
        expect(r['min_value'], entry.value, reason: 'for <${entry.key}>');
        expect(r['max_value'], isNull, reason: 'for <${entry.key}>');
        expect(r['max_text'], '-', reason: 'for <${entry.key}>');
      }
    });
  });

  group('isOutOfRange — limits are INCLUSIVE (consumes parseNumericRange)', () {
    // RULE: comparison is strictly `<` / `>`, so a result sitting EXACTLY on
    // the stored limit is compliant (inclusive bounds).
    // SILENT-WRONG VALUE PREVENTED: an off-by-one to `<=` would flag a
    // reading of exactly the legal maximum as OUT, failing a conforming batch
    // and (in a dispute) contradicting the certificate's own limits column.
    test('a result exactly on the minimum or maximum is compliant', () {
      expect(isOutOfRange('5', 5, 10), isFalse, reason: 'exactly at min');
      expect(isOutOfRange('10', 5, 10), isFalse, reason: 'exactly at max');
      expect(isOutOfRange('5.0', 5.0, 10.0), isFalse);
      expect(isOutOfRange('10.0', 5.0, 10.0), isFalse);
    });

    // RULE: one representable step outside a limit is OUT (the flag is not
    // fuzzy and does not carry a tolerance).
    // SILENT-WRONG VALUE PREVENTED: an over-limit reading being rounded into
    // compliance by a tolerance that was never specified.
    test('one step outside either limit is flagged out of range', () {
      expect(isOutOfRange('4.9999999', 5, 10), isTrue);
      expect(isOutOfRange('10.0000001', 5, 10), isTrue);
      expect(isOutOfRange('11', 5, 10), isTrue);
      expect(isOutOfRange('4.99', 5, 10), isTrue);
    });

    // RULE: a missing bound means "not checked" on that side only.
    // SILENT-WRONG VALUE PREVENTED: substituting 0 for the absent bound, which
    // would flag every positive result OUT on single-sided requirements.
    test('a null bound disables that side of the check', () {
      expect(isOutOfRange('5', 5, null), isFalse);
      expect(isOutOfRange('4', 5, null), isTrue);
      expect(isOutOfRange('20', null, 10), isTrue);
      expect(isOutOfRange('20', null, null), isFalse,
          reason: 'no stored requirement means no judgement is made');
    });

    // RULE (documented defect): an actual value that is blank or non-numeric
    // returns false, i.e. "NOT out of range" — it is never reported as an
    // error and never flagged.
    // SILENT-WRONG VALUE PREVENTED: a result cell that was never transcribed
    // (or was typed as "N/A", "trace", "<0.1") passing through the report with
    // no OUT flag, so an incomplete row reads as a conforming one.
    test('a blank or non-numeric actual value is never flagged', () {
      for (final actual in <String?>[null, '', '   ', 'abc', 'N/A', 'trace', '12 ppm']) {
        expect(isOutOfRange(actual, 5, 10), isFalse,
            reason: 'SILENT PASS for <$actual> — no OUT flag is produced');
      }
    });
  });

  group('formatValueWithUnit — a unit is appended at most once', () {
    // RULE: nothing to show renders as the single placeholder "-", never
    // "- mg/kg"; this is what keeps the Min/Max columns readable when
    // parseNumericRange found no numbers (min_text/max_text are literally '-').
    // SILENT-WRONG VALUE PREVENTED: a stray "- mg/kg" printed as a real limit.
    test('null, empty, blank and "-" all collapse to the "-" placeholder', () {
      for (final v in <String?>[null, '', '   ', '-']) {
        expect(formatValueWithUnit(v, 'mg/kg'), '-', reason: 'for <$v>');
      }
    });

    // RULE: a value that already states its unit is returned VERBATIM (case
    // insensitively) — no unit is appended. "5 PPM" keeps its capitalisation.
    // SILENT-WRONG VALUE PREVENTED: "5 ppm mg/kg" — a unit pair printed on the
    // certificate that the analyst never measured.
    test('a value carrying ppm/ppb/% is returned verbatim', () {
      expect(formatValueWithUnit('5 ppm', 'mg/kg'), '5 ppm');
      expect(formatValueWithUnit('5 PPM', 'mg/kg'), '5 PPM');
      expect(formatValueWithUnit('5 ppb', ''), '5 ppb');
      expect(formatValueWithUnit('5%', '%'), '5%');
      expect(formatValueWithUnit('5.25 %', '%'), '5.25 %');
      expect(formatValueWithUnit('5% ABV', '%'), '5% ABV');
    });

    // RULE: an empty unit leaves the value untouched (no trailing space).
    test('an empty unit leaves the value untouched', () {
      expect(formatValueWithUnit('5', ''), '5');
      // PINNED: the unit is only tested for emptiness, never trimmed, so a
      // whitespace-only unit emits a trailing space into the report cell.
      expect(formatValueWithUnit('5', ' '), '5  ',
          reason: 'PINNED DEFECT: unit is not trimmed');
    });

    // RULE (documented defect): the "already has a unit" check only recognises
    // ppm / ppb / %. Any other spelled-out unit is re-appended.
    // SILENT-WRONG VALUE PREVENTED: "5 mg/kg mg/kg" printed on the report for a
    // result the analyst typed as "5 mg/kg".
    test('a value that spells any other unit gets the unit appended twice', () {
      expect(formatValueWithUnit('5 mg/kg', 'mg/kg'), '5 mg/kg mg/kg',
          reason: 'PINNED DEFECT');
      expect(formatValueWithUnit('10 mg/kg', 'mg/kg'), '10 mg/kg mg/kg',
          reason: 'PINNED DEFECT');
      expect(formatValueWithUnit('1 g/L', 'g/L'), '1 g/L g/L',
          reason: 'PINNED DEFECT');
    });

    // RULE (documented defect): the value is never validated as numeric, so a
    // free-text result is decorated with the unit anyway.
    // SILENT-WRONG VALUE PREVENTED: "abc mg/kg" / "N/A mg/kg" — a placeholder
    // rendered on a certificate as if it were a measurement.
    test('a non-numeric result still has the unit appended', () {
      expect(formatValueWithUnit('abc', 'mg/kg'), 'abc mg/kg',
          reason: 'PINNED DEFECT');
      expect(formatValueWithUnit('N/A', 'mg/kg'), 'N/A mg/kg',
          reason: 'PINNED DEFECT');
      expect(formatValueWithUnit('trace', 'mg/kg'), 'trace mg/kg',
          reason: 'PINNED DEFECT');
    });

    // RULE: a plain numeric value gets exactly one space before the unit.
    test('a plain numeric value gets a single space before the unit', () {
      expect(formatValueWithUnit('5', 'mg/kg'), '5 mg/kg');
      expect(formatValueWithUnit('  12.5  ', 'mg/kg'), '12.5 mg/kg');
      expect(formatValueWithUnit('0', '%'), '0 %');
    });
  });

  group('inferChemicalUnit — explicit unit, then name token, then "%"', () {
    // RULE: a unit stored on the reference payload always wins over the
    // name-based guess — the chemist's declaration beats the heuristic.
    test('an explicit unit on the payload wins over the name heuristic', () {
      expect(inferChemicalUnit({'value': 1, 'unit': 'mg/kg'}, 'Moisture'), 'mg/kg');
      expect(inferChemicalUnit({'value': 1, 'unit': 'ppb'}, 'Aflatoxin'), 'ppb');
      // even when the name says ppm: the declared unit is not overridden.
      expect(inferChemicalUnit({'value': 1, 'unit': 'mg/kg'}, 'Aflatoxin B1'),
          'mg/kg');
    });

    // RULE (documented defect): the unit scan walks nested {value: ...}
    // envelopes and OVERWRITES on every level, so the INNERMOST unit wins.
    // The enrichment writer (withReferenceUnit, app_format.dart:144) lets the
    // OUTER/explicit unit win — the two disagree on the same payload.
    // SILENT-WRONG VALUE PREVENTED: a ppm reference relabelled % (or the
    // reverse), which is a 10^3 error in the number printed next to it.
    test('the innermost unit of a nested envelope beats the outer one', () {
      expect(inferChemicalUnit({
        'unit': 'ppm',
        'value': {'unit': '%', 'value': 1}
      }, 'Moisture'), '%', reason: 'PINNED DEFECT: innermost wins');
    });

    // RULE: a blank unit (missing key or whitespace) is treated as absent and
    // the name heuristic runs.
    test('a blank unit falls through to the name heuristic', () {
      expect(inferChemicalUnit({'value': 1, 'unit': '   '}, 'Aflatoxin'), 'ppm');
      expect(inferChemicalUnit({'value': 1}, 'Aflatoxin'), 'ppm');
    });

    // RULE: analyte names in the aflatoxin/ochratoxin family are measured in
    // ppm; matching is case-insensitive.
    test('aflatoxin / ochratoxin names are labelled ppm', () {
      for (final name in [
        'Aflatoxin B1',
        'TOTAL AFLATOXIN',
        'aflatoxin',
        'Ochratoxin A',
        'Afla',
        'افلا',
      ]) {
        expect(inferChemicalUnit({'value': 1}, name), 'ppm', reason: name);
      }
    });

    // RULE (documented defect): token matching is a raw substring test, not a
    // word match, so any parameter whose NAME merely mentions a token is
    // labelled ppm.
    // SILENT-WRONG VALUE PREVENTED: "Moisture (okra matrix)" printed as a ppm
    // limit when the analyst is measuring a percentage — the printed number is
    // then off by two orders of magnitude.
    test('token matching is substring-based and mislabels unrelated analytes',
        () {
      expect(inferChemicalUnit({'value': 1}, 'Moisture (okra matrix)'), 'ppm',
          reason: 'PINNED DEFECT: "okra" matched inside "Moisture (...)"');
      expect(inferChemicalUnit({'value': 1}, 'okra'), 'ppm');
      // "moisture" is a percentage parameter but must not match any token.
      expect(inferChemicalUnit({'value': 1}, 'Moisture'), '%');
    });

    // RULE (documented defect): with no declared unit and no recognisable token
    // the unit is assumed to be "%" — a guess with no evidence.
    // SILENT-WRONG VALUE PREVENTED: a heavy-metal result in mg/kg printed as a
    // percentage (or vice versa) with no warning, e.g. "0.5 %" for 0.5 mg/kg.
    test('an unrecognised analyte with no unit defaults to "%"', () {
      expect(inferChemicalUnit(null, 'Moisture'), '%');
      expect(inferChemicalUnit({'value': 1}, 'Protein'), '%');
      expect(inferChemicalUnit({}, 'Ash'), '%');
      expect(inferChemicalUnit(null, ''), '%');
      expect(inferChemicalUnit(null, '   '), '%');
    });

    // RULE: with neither a usable name nor a unit, the payload text itself is
    // searched — so a name stored only inside the value is still detected.
    test('the payload text is used as the name when no name is supplied', () {
      expect(inferChemicalUnit({'value': 'Aflatoxin B1'}), 'ppm');
      expect(inferChemicalUnit({'value': {'value': 'Ochratoxin A'}}), 'ppm');
    });
  });
}