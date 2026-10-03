import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/core/utils/app_format.dart';

/// core/utils/app_format.dart — the silent-fallback layer of the app.
///
/// Almost everything here swallows its failure: a parse error, a wrong JSON
/// shape, a blank field, an unparseable number all produce a *plausible* value
/// (`{}`, `[]`, `0`, `'-'`, the original text) instead of an error. That is
/// what makes the app robust against half-filled forms, but it also means a
/// corrupt record is indistinguishable from an empty one.
///
/// Each test below names the person hurt by the silently-wrong value.
void main() {
  group('jsonLoads / jsonLoadsList — corrupt JSON is indistinguishable from empty',
      () {
    // RULE: a parse error is CAUGHT and the fallback (`{}` / `[]`) is returned.
    // NO exception, NO log — corrupt is bit-for-bit identical to empty.
    // HURT: a QA manager auditing a reference-materials row whose JSON was
    // truncated by a bad sync sees "{}" and concludes "no extra data stored",
    // instead of "this record is damaged". The lost field is unrecoverable.
    test('malformed JSON silently yields the empty fallback', () {
      for (final bad in ['{bad json', '{"a":1', 'not json at all', '{"a":,}']) {
        expect(jsonLoads(bad), isEmpty, reason: 'for <$bad>');
        expect(jsonLoadsList(bad), isEmpty, reason: 'for <$bad>');
      }
    });

    // RULE: valid JSON of the WRONG shape also falls back silently — a list
    // read with jsonLoads (or a map read with jsonLoadsList) is not an error,
    // it is an empty result.
    // HURT: a developer who swapped the two helpers loses a whole payload and
    // sees an empty map with no clue why.
    test('valid JSON of the wrong shape also falls back silently', () {
      expect(jsonLoads('[1,2]'), isEmpty);
      expect(jsonLoadsList('{"a":1}'), isEmpty);
      expect(jsonLoads('123'), isEmpty);
      expect(jsonLoads('null'), isEmpty);
      expect(jsonLoads('"text"'), isEmpty);
      expect(jsonLoadsList('{"a":1}'), isEmpty);
    });

    // RULE: null/blank input short-circuits to the fallback without parsing.
    // HURT: a brand-new form field (never touched) and a field whose text was
    // wiped look identical to a field that failed to load.
    test('null and blank input return the fallback without parsing', () {
      for (final empty in <String?>[null, '', '   ']) {
        expect(jsonLoads(empty), isEmpty, reason: 'for <$empty>');
        expect(jsonLoadsList(empty), isEmpty, reason: 'for <$empty>');
      }
    });

    // RULE: the caller may supply its own fallback; it is returned on failure
    // AND on a shape mismatch — so a caller cannot use a non-empty fallback to
    // detect corruption (the one would-be escape hatch is closed).
    // HURT: a caller who wanted to distinguish "missing" from "corrupt" cannot.
    test('a caller-supplied fallback is returned on parse failure', () {
      expect(jsonLoads('{bad', {'sentinel': 1}), {'sentinel': 1});
      expect(jsonLoads('[1]', {'sentinel': 1}), {'sentinel': 1},
          reason: 'a shape mismatch also returns the fallback');
      expect(jsonLoadsList('{bad', ['sentinel']), ['sentinel']);
      expect(jsonLoadsList('{"a":1}', ['sentinel']), ['sentinel']);
    });

    // RULE: a well-formed payload of the right shape is decoded, and surrounding
    // whitespace is tolerated.
    // HURT (if broken): every enriched reference value would silently vanish
    // from the report, leaving blank spec columns.
    test('a well-formed payload decodes with the matching helper', () {
      expect(jsonLoads('{"a":1}'), {'a': 1});
      expect(jsonLoads('  {"a":{"b":2}}  '), {
        'a': {'b': 2}
      });
      expect(jsonLoadsList('[1,2]'), [1, 2]);
      expect(jsonLoadsList(' [ {"x":1} ] '), [
        {'x': 1}
      ]);
    });
  });

  group('safeFloat — never throws, returns null instead', () {
    // RULE: commas are thousand separators and are stripped before parsing, so
    // "1,234.5" is 1234.5.
    // HURT (if broken): a quantity pasted from an Arabic-locale spreadsheet
    // ("1,234.5") becomes null and is silently coerced to 0 downstream.
    test('commas are stripped as thousand separators', () {
      expect(safeFloat('1,234.5'), 1234.5);
      expect(safeFloat('1,000'), 1000.0);
      expect(safeFloat(' 1,234 '), 1234.0);
      expect(safeFloat(42), 42.0);
      expect(safeFloat(4.5), 4.5);
    });

    // RULE (documented defect): commas are stripped wherever they appear, so a
    // European decimal comma is read as a thousands separator — "1,5" (which
    // means 1.5 in an Arabic/European locale) becomes 15.
    // HURT: a quantity typed or pasted in the operator's own locale is inflated
    // 10x on the report and in every total, and nothing warns about it.
    test('a decimal comma is stripped, inflating the value 10x', () {
      expect(safeFloat('1,5'), 15.0,
          reason: 'PINNED DEFECT: European 1.5 read as 15');
      expect(safeFloat('1.234,5'), 1.2345,
          reason: 'the fraction survives only because the comma is deleted');
    });

    // RULE: null and blank/whitespace-only input return null (never 0.0, which
    // would look like a real measurement).
    // HURT (if broken): an empty field prints "0.000" and is counted as a
    // genuine zero in every total.
    test('null and blank input return null', () {
      for (final v in <Object?>[null, '', '   ', '\t']) {
        expect(safeFloat(v), isNull, reason: 'for <$v>');
      }
    });

    // RULE: malformed text returns null rather than throwing — a whole report
    // must not fail because one cell holds "N/A".
    // HURT: every downstream caller must therefore handle null itself; the ones
    // that substitute 0 are pinned in aggregation's _safeQty tests.
    test('malformed text returns null instead of throwing', () {
      for (final v in ['abc', 'N/A', '-', '1.2.3', '12,34,567x', '١٢']) {
        expect(safeFloat(v), isNull, reason: 'for <$v>');
      }
    });

    // RULE: leading/trailing dots are tolerated the way Python's float() and
    // double.tryParse both accept them.
    test('leading and trailing dots are accepted', () {
      expect(safeFloat('.5'), 0.5);
      expect(safeFloat('12.'), 12.0);
      expect(safeFloat('-3.25'), -3.25);
    });
  });

  group('validateNonNegativeNumericText — the one loud validator in this file', () {
    // RULE: digits with an OPTIONAL single fraction, optionally signed off by
    // trimming; the trimmed text is returned.
    // HURT (if broken): a valid entry is rejected with "أرقام فقط" and the
    // inspector cannot save the inspection at all.
    test('accepts digits with an optional fraction and trims', () {
      expect(validateNonNegativeNumericText(' 500 ', 'الكمية'), '500');
      expect(validateNonNegativeNumericText('0', 'الكمية'), '0');
      expect(validateNonNegativeNumericText('12.345', 'الكمية'), '12.345');
      // PINNED: the grammar is `\d+(\.\d+)?`, so a leading dot is NOT a valid
      // fraction and is rejected instead of being read as 0.5.
      expect(() => validateNonNegativeNumericText('.5', 'الكمية'),
          throwsA(isA<ValidationError>()),
          reason: r'PINNED: ".5" is not \d+(\.\d+)?');
    });

    // RULE: a sign, a thousands separator, a unit suffix or any word is
    // rejected with ValidationError("… أرقام فقط …") — nothing is coerced.
    // HURT (if broken): "-5" silently stored as 5 inverts the meaning of a
    // signed delta; "1,200" silently stored as 1 loses 1,199 units.
    test('rejects signs, separators, units and words', () {
      for (final bad in ['-5', '+5', '1,200', '12.5 ppm', 'abc', '1 200', '']) {
        if (bad.isEmpty) continue;
        expect(() => validateNonNegativeNumericText(bad, 'الكمية'),
            throwsA(isA<ValidationError>()),
            reason: 'accepted <$bad>');
      }
    });

    // RULE: maxLength is enforced AFTER trimming and before the numeric check.
    // HURT (if broken): a 5000-character paste reaches the DB/report and
    // truncates the value, turning 500000 into 500000... truncated digits.
    test('maxLength is enforced after trimming', () {
      expect(
        () => validateNonNegativeNumericText('12345678', 'الكمية',
            maxLength: 5),
        throwsA(isA<ValidationError>()),
      );
      expect(validateNonNegativeNumericText(' 1234 ', 'الكمية', maxLength: 5),
          '1234');
    });

    // RULE: empty is allowed by default (optional field) and returns ''; with
    // allowEmpty:false it throws fieldRequired.
    // HURT (if broken): a required quantity stays blank and every total in the
    // report is computed as if the shipment had zero quantity.
    test('emptiness follows allowEmpty', () {
      expect(validateNonNegativeNumericText('   ', 'الكمية'), '');
      expect(
        () => validateNonNegativeNumericText('   ', 'الكمية',
            allowEmpty: false),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('formatQuantity / formatLabelQuantity — what a QA reader sees', () {
    // RULE: quantities print with thousands grouping and EXACTLY three decimals
    // (`#,##0.000`), so a tonnage column is aligned.
    // HURT (if broken): mixed decimals make two rows of the same quantity look
    // different and get double-counted during reconciliation.
    test('quantities print grouped with exactly three decimals', () {
      expect(formatQuantity(5), '5.000');
      expect(formatQuantity('5.5'), '5.500');
      expect(formatQuantity(1234.5678), '1,234.568');
      expect(formatQuantity('1,234.5'), '1,234.500');
      expect(formatQuantity(1000000), '1,000,000.000');
    });

    // RULE: null / blank print the placeholder "-", but a NON-numeric string is
    // printed VERBATIM (it is not blanked, and no digits are invented).
    // HURT: "N/A" or "to be re-tested" is printed in the quantity column and
    // later parsed by downstream tooling that expects a number.
    test('null/blank print "-" while non-numeric text passes through verbatim', () {
      for (final blank in <Object?>[null, '', '   ']) {
        expect(formatQuantity(blank), '-', reason: 'for <$blank>');
      }
      expect(formatQuantity('abc'), 'abc');
      expect(formatQuantity('N/A'), 'N/A');
      expect(formatQuantity('-'), '-');
    });

    // RULE (documented inconsistency): zero is a REAL quantity for
    // formatQuantity ("0.000") but a BLANK for formatLabelQuantity ("-").
    // HURT: the same 0 kg shipment shows as a measured zero in the report
    // table and disappears in the label — the two artefacts disagree.
    test('zero is printed by formatQuantity but hidden by formatLabelQuantity', () {
      expect(formatQuantity('0'), '0.000');
      expect(formatQuantity(0), '0.000');
      expect(formatLabelQuantity('0'), '-');
      expect(formatLabelQuantity(0), '-');
      expect(formatLabelQuantity(0.0), '-');
    });

    // RULE: formatLabelQuantity blanks anything that is not a non-zero number,
    // so free text can never reach the label.
    test('formatLabelQuantity blanks every zero/unparseable value', () {
      for (final blankish in <Object?>[null, '', '   ', 'abc', 'N/A', '-', 0]) {
        expect(formatLabelQuantity(blankish), '-', reason: 'for <$blankish>');
      }
    });

    // RULE (documented defect inherited from safeFloat): "1,5" is read as 15 and
    // printed "15.000" — a correct-looking number, ten times too large.
    // HURT: a European-formatted entry is inflated 10x on the certificate, and
    // the report total silently agrees with itself.
    test('a decimal comma is inflated 10x and looks perfectly normal', () {
      expect(formatQuantity('1,5'), '15.000',
          reason: 'PINNED DEFECT: 1.5 rendered as 15.000');
      expect(formatLabelQuantity('1,5'), '15.000',
          reason: 'PINNED DEFECT');
      // A fraction-only comma is merely truncated to 3 decimals.
      expect(formatQuantity('1.234,5'), '1.234', reason: '1.2345 rounded');
    });

    // RULE: both formatters share one NumberFormat, so a label and a report row
    // for the same value are byte-identical.
    test('both formatters agree on the same value', () {
      for (final v in <Object?>[5, '5.5', 1234.5678, '1,234.5', '12']) {
        expect(formatQuantity(v), formatLabelQuantity(v), reason: 'for <$v>');
      }
    });
  });

  group('sanitizeFilename — the exported PDF/certificate filename', () {
    // RULE: every path separator and every illegal filename character
    // (\ / : * ? " < > |) is replaced with '_', so a material name typed by a
    // user can never escape the export directory.
    // HURT (if broken): "../../etc/passwd" or "..\\..\\startup" writes the
    // certificate OUTSIDE the app's export folder, and on the source of a
    // name such as 'C:\' the export silently lands somewhere else.
    test('path separators and traversal segments cannot escape', () {
      expect(sanitizeFilename('../../etc/passwd'), '.._.._etc_passwd');
      expect(sanitizeFilename(r'..\..\windows\system32\cmd.exe'),
          '.._.._windows_system32_cmd.exe');
      expect(sanitizeFilename('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(sanitizeFilename('/absolute/path.pdf'), '_absolute_path.pdf');
      expect(
        sanitizeFilename('../../etc/passwd'),
        isNot(contains('/')),
        reason: 'a separator surviving would be a traversal primitive',
      );
      expect(sanitizeFilename('../../etc/passwd'), isNot(contains(r'\')));
    });

    // RULE: an empty or whitespace-only name falls back to the literal "file",
    // and runs of whitespace collapse to a single space.
    // HURT (if broken): the export produces "_" or "_.pdf" and the user cannot
    // tell which inspection a file belongs to in the downloads folder.
    test('an empty name falls back to "file" and whitespace is collapsed', () {
      expect(sanitizeFilename(''), 'file');
      expect(sanitizeFilename('   '), 'file');
      expect(sanitizeFilename('  spaced   out  '), 'spaced out');
      expect(sanitizeFilename('صنف   خام'), 'صنف خام');
    });

    // RULE (documented defects): the cleaner only handles separators, illegal
    // characters and whitespace. Leading dots, "." / ".." as a WHOLE name,
    // Windows reserved device names, non-whitespace control characters and
    // length are all left untouched, and the caller concatenates the result
    // into "${material}_${entry_code}.pdf" (report_service.dart:199).
    // HURT: '..' survives as a path segment, a name > 255 chars fails the
    // export on FAT/NTFS, and 'CON' is rejected by Windows Explorer.
    test('leading dots, device names and control chars are NOT neutralised', () {
      expect(sanitizeFilename('..'), '..', reason: 'PINNED DEFECT');
      expect(sanitizeFilename('...'), '...', reason: 'PINNED DEFECT');
      expect(sanitizeFilename('CON'), 'CON', reason: 'PINNED DEFECT: reserved '
          'device name kept');
      expect(sanitizeFilename('x' * 300).length, 300,
          reason: 'PINNED DEFECT: no length cap (FAT/NTFS limit is 255)');
      // Whitespace controls collapse to a plain space...
      expect(sanitizeFilename('a\tb'), 'a b');
      expect(sanitizeFilename('a\nb'), 'a b');
      // ...but every other control character survives verbatim.
      expect(sanitizeFilename('a\u0000b').codeUnits, [97, 0, 98],
          reason: 'PINNED DEFECT: NUL kept in the export filename');
      expect(sanitizeFilename('a\u001bb').codeUnits, [97, 27, 98],
          reason: 'PINNED DEFECT: ESC kept');
      expect(sanitizeFilename('a\u007fb').codeUnits, [97, 127, 98],
          reason: 'PINNED DEFECT: DEL kept');
      // The real export filename is material + "_" + code + ".pdf".
      final mat = sanitizeFilename('..');
      final code = sanitizeFilename('ENTRY-1');
      expect('${mat}_$code.pdf', '.._ENTRY-1.pdf',
          reason: 'PINNED DEFECT: a dot-only material name reaches the path');
    });
  });

  group('referenceValueText — the text a requirement column is rendered from', () {
    // RULE: {value: ...} envelopes are unwrapped (deeply) and the unit is
    // DROPPED — only the bare value text is returned, trimmed.
    // HURT (if broken): the column prints the raw JSON of the envelope, e.g.
    // '{"value":"5 - 10"}', on the certificate.
    test('nested value envelopes unwrap and the unit is dropped', () {
      expect(referenceValueText({'value': '5 - 10'}), '5 - 10');
      expect(referenceValueText({'value': 12.5, 'unit': 'ppm'}), '12.5');
      expect(referenceValueText({
        'value': {'value': {'value': '2 - 4'}}
      }), '2 - 4');
      expect(referenceValueText('  7  '), '7');
      expect(referenceValueText(12.5), '12.5');
    });

    // RULE: null renders as an EMPTY string (not "-", not "null").
    // HURT (if broken): a missing requirement prints the literal "null" and a
    // QA auditor records a limit that nobody ever set.
    test('null renders as an empty string, never the text "null"', () {
      expect(referenceValueText(null), '');
      expect(referenceValueText(''), '');
      expect(referenceValueText([]), '[]',
          reason: 'PINNED: a list is serialised, not blanked');
    });

    // RULE (documented defect): a map WITHOUT a 'value' key is serialised to
    // JSON and returned — and parseNumericRange then scans those JSON digits as
    // if they were limits.
    // HURT: '{"min":1}' becomes "minimum 1, no maximum" on the report, a limit
    // invented from a field name.
    test('a map without a value key is serialised to JSON and number-scanned', () {
      expect(referenceValueText({'min': 1}), '{"min":1}');
      expect(referenceValueText({'min': 1, 'max': 5}),
          '{"min":1,"max":5}',
          reason: 'PINNED DEFECT: the caller then reads 1 and 1 as bounds');
      expect(referenceValueText([1, 2]), '[1, 2]');
    });
  });
}