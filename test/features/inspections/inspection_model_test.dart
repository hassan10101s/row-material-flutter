import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/core/utils/app_format.dart';
import 'package:material_lab/features/inspections/domain/inspection.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// The two domain records an inspection is made of. Nothing else in the app
/// deserialises them, so `fromMap`/`toMap` are the *only* place a column's
/// SQLite value becomes a Dart value — and every one of those conversions is a
/// place where a wrong value can be produced silently instead of loudly.
///
/// Rules pinned here:
///
///   * a value written and read back is byte-identical, both through
///     `toRowMap` and through a **real** `inspections` table (so the round trip
///     proves the column *types* survive, not just the Dart code);
///   * an absent or NULL optional column becomes `''` — never the four-character
///     string `"null"`, which is what a bare `'${m['x']}'` interpolation would
///     print into a PDF;
///   * a genuinely nullable field (`lastPdfPath`, `expiryDate`, `createdBy`)
///     stays `null`, because `''` would be a lie about "unknown";
///   * the numeric coercions are pinned on the *documented* defaults
///     (`decisionVersion` 1) and on the ones that hide data (`materialId` 0).
void main() {
  DatabaseHelper.ensureDesktopFactory();

  /// The minimum an `inspections` row can legally look like: only the columns
  /// the table declares NOT NULL, i.e. everything optional is absent.
  Map<String, dynamic> minimalRow() => <String, dynamic>{
        'entry_code': 'QC-MIG-001',
        'material_id': 1,
        'material_name': 'Sugar',
        'material_code': 'M-SUG-01',
        'inspection_date': '2026-09-01',
        'specialist_name': 'Ahmed Ali',
        'physical_results_json': '{}',
        'chemical_results_json': '{}',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'decision_status': 'APPROVED',
        'snapshot_json': '{}',
        'sample_names_json': '[]',
        'decision_version': 1,
        'created_by': 0,
        'created_by_name': 'Unknown user',
        'created_at': '2026-09-01T08:00:00.000',
        'updated_at': '2026-09-01T08:00:00.000',
      };

  /// [minimalRow] with `created_by` dropped, i.e. a row where all four of the
  /// columns `toRowMap` treats as nullable are genuinely absent.
  Map<String, dynamic> withoutNullableColumns() =>
      <String, dynamic>{...minimalRow()}..remove('created_by');

  /// Every optional column populated with something distinguishable, so a
  /// round trip cannot accidentally pass by writing the same wrong value twice.
  Map<String, dynamic> fullRow() => <String, dynamic>{
        'id': 42,
        ...minimalRow(),
        'expiry_date': '2027-01-31',
        'supplier': 'Al Dahra',
        'truck_number': 'TRK-9',
        'quantity': '1234.5',
        'sample_taken_by': 'Nour',
        'physical_results_json': '{"color":"Light gray","Moisture":"6.5"}',
        'chemical_results_json': '{"pH":"7.1"}',
        'physical_reference_json': '{"Moisture":"6-14.5"}',
        'chemical_reference_json': '{"pH":"5.5-8"}',
        'decision_reason': 'within specification',
        'follow_up_note': 're-check in 30 days',
        'rejected_quantity': '12.25',
        'report_html': '<html><body>ok</body></html>',
        'snapshot_json': '{"entry_code":"QC-MIG-001"}',
        'sample_names_json': '["Top","Mid","Base"]',
        'decision_version': 3,
        'created_by': 1,
        'last_pdf_path': 'C:/reports/QC-MIG-001.pdf',
      };

  group('Inspection.fromMap — absent and NULL optional columns', () {
    test('an absent optional text column becomes "" and never the string "null"',
        () {
      // `'${m['supplier'] ?? ''}'` is the guard. Without the `?? ''` the report
      // would print the literal word "null" where the supplier belongs.
      final i = Inspection.fromMap(minimalRow());

      expect(i.supplier, '');
      expect(i.truckNumber, '');
      expect(i.quantity, '');
      expect(i.sampleTakenBy, '');
      expect(i.decisionReason, '');
      expect(i.followUpNote, '');
      expect(i.rejectedQuantity, '');
      expect(i.reportHtml, '');
      for (final value in [
        i.supplier,
        i.truckNumber,
        i.quantity,
        i.sampleTakenBy,
        i.decisionReason,
        i.followUpNote,
        i.rejectedQuantity,
        i.reportHtml,
      ]) {
        expect(value, isNot('null'));
        expect(value, isNot('NULL'));
      }
    });

    test('an explicit NULL is treated exactly like an absent column', () {
      final i = Inspection.fromMap(<String, dynamic>{
        ...minimalRow(),
        'supplier': null,
        'truck_number': null,
        'quantity': null,
        'decision_reason': null,
        'follow_up_note': null,
        'rejected_quantity': null,
        'report_html': null,
        'sample_taken_by': null,
      });

      expect(i.supplier, '');
      expect(i.truckNumber, '');
      expect(i.quantity, '');
      expect(i.sampleTakenBy, '');
      expect(i.decisionReason, '');
      expect(i.followUpNote, '');
      expect(i.rejectedQuantity, '');
      expect(i.reportHtml, '');
    });

    test('a genuinely nullable field stays null instead of degrading to ""',
        () {
      // `''` here would be a lie: it would read as "there is no PDF" the same
      // way it reads for "the path is the empty string".
      final noOptionals = withoutNullableColumns();

      final i = Inspection.fromMap(noOptionals);
      expect(i.lastPdfPath, isNull);
      expect(i.expiryDate, isNull);
      expect(i.createdBy, isNull);
      expect(i.id, isNull);
      expect(Inspection.fromMap({...noOptionals, 'created_by': null}).createdBy,
          isNull);
      expect(Inspection.fromMap({...noOptionals, 'id': null}).id, isNull);
      expect(Inspection.fromMap(minimalRow()).createdBy, 0,
          reason: 'the reserved "Unknown user" row is a real author, not null');
    });

    test('a missing decision_version defaults to 1, the schema default', () {
      // The column is `NOT NULL DEFAULT 1`. Defaulting to 0 would make every
      // row look like the first version and defeat `maxDecisionVersions`.
      final i = Inspection.fromMap(<String, dynamic>{
        ...minimalRow(),
      }..remove('decision_version'));
      expect(i.decisionVersion, 1);
      expect(Inspection.fromMap({...minimalRow(), 'decision_version': null})
          .decisionVersion, 1);
    });

    test('a REAL decision_version is coerced to an int', () {
      // SQLite hands back a `double` for a column that once held `2.0`, and
      // `(m['decision_version'] as num?)?.toInt()` copes with that.
      final i = Inspection.fromMap(
          {...minimalRow(), 'decision_version': 3.0, 'material_id': 2.0});
      expect(i.decisionVersion, 3);
      expect(i.materialId, 2);
    });

    test('BUG PINNED: a missing material_id becomes 0, a material that does not exist',
        () {
      // `?? 0` is a silent wrong value: material 0 is not in
      // `reference_materials`, so the inspection is filed under an unnamed
      // material in the dashboard breakdown and in every per-material report —
      // and nothing raises, because nothing re-checks the id afterwards.
      final missing = <String, dynamic>{...minimalRow()}..remove('material_id');
      expect(Inspection.fromMap(missing).materialId, 0);

      expect(
          Inspection.fromMap({...minimalRow(), 'material_id': null}).materialId,
          0,
          reason: 'an explicit NULL is coerced the same silent way');
    });

    test('BUG PINNED: `id` uses a bare cast, so a REAL id crashes while material_id coerces',
        () {
      // `id: m['id'] as int?` vs `materialId: (m['material_id'] as num?)?.toInt()`
      // — two adjacent lines treating the same class of value differently, so a
      // REAL-typed `id` throws a `_TypeError` where `material_id` would not.
      expect(() => Inspection.fromMap({...minimalRow(), 'id': 42.0}),
          throwsA(isA<TypeError>()));
      expect(() => Inspection.fromMap({...minimalRow(), 'id': '42'}),
          throwsA(isA<TypeError>()));
    });
  });

  group('Inspection.fromMap — JSON columns', () {
    test('every JSON column decodes into a real map or list', () {
      final i = Inspection.fromMap(fullRow());

      expect(i.physicalResults, {'color': 'Light gray', 'Moisture': '6.5'});
      expect(i.chemicalResults, {'pH': '7.1'});
      expect(i.physicalReference, {'Moisture': '6-14.5'});
      expect(i.chemicalReference, {'pH': '5.5-8'});
      expect(i.snapshot, {'entry_code': 'QC-MIG-001'});
      expect(i.sampleNames, ['Top', 'Mid', 'Base']);
    });

    test('the already-decoded column wins over the JSON text column', () {
      // `m['physical_results'] ?? m['physical_results_json']` prefers the
      // decoded form, which is what the editor hands over.
      final i = Inspection.fromMap(<String, dynamic>{
        ...minimalRow(),
        'physical_results': <String, dynamic>{'from': 'decoded'},
        'physical_results_json': '{"from":"text"}',
      });
      expect(i.physicalResults, {'from': 'decoded'});
    });

    test('BUG PINNED: a corrupted results blob decodes to an empty map', () {
      // `jsonLoads` swallows the parse failure and returns `{}`. A saved
      // inspection whose results column got mangled therefore renders as an
      // inspection with NO results — the report shows an empty table and passes
      // the sample, and the corruption is invisible.
      final i = Inspection.fromMap(<String, dynamic>{
        ...minimalRow(),
        'physical_results_json': '{not json',
        'chemical_results_json': '',
        'snapshot_json': 'null',
      });

      expect(i.physicalResults, isEmpty);
      expect(i.chemicalResults, isEmpty);
      expect(i.snapshot, isEmpty);
    });

    test('a well-formed JSON array in a map column also becomes an empty map',
        () {
      // `jsonLoads` only accepts a `Map`, so a `[...]` payload silently empties
      // instead of being reported as the wrong shape.
      final i = Inspection.fromMap(
          {...minimalRow(), 'physical_results_json': '[1,2,3]'});
      expect(i.physicalResults, isEmpty);
    });

    test('a non-list sample_names blob becomes an empty list, not a crash', () {
      expect(
          Inspection.fromMap({...minimalRow(), 'sample_names_json': '{"a":1}'})
              .sampleNames,
          isEmpty);
      expect(
          Inspection.fromMap({...minimalRow(), 'sample_names_json': 'nope'})
              .sampleNames,
          isEmpty);
      expect(Inspection.fromMap(minimalRow()).sampleNames, isEmpty);
    });

    test('a decoded list is aliased, not copied', () {
      // `_jsonList` returns `value` itself when it is already a `List`. The
      // model therefore shares the caller's list: a mutation after
      // deserialisation writes straight through into the model's state.
      final names = <dynamic>['Top'];
      final i = Inspection.fromMap({...minimalRow(), 'sample_names': names});
      expect(identical(i.sampleNames, names), isTrue);

      names.add('Injected');
      expect(i.sampleNames, ['Top', 'Injected']);
    });
  });

  group('Inspection.toRowMap — serialisation', () {
    test('omits the four nullable keys when they are null', () {
      // `inspections.created_by` is NOT NULL with no default, so an omitted
      // key is not "safe to insert" — but writing `null` explicitly is what
      // used to produce `NOT NULL constraint failed: inspections.created_by`.
      final row = Inspection.fromMap(withoutNullableColumns()).toRowMap();

      expect(row.containsKey('id'), isFalse);
      expect(row.containsKey('created_by'), isFalse);
      expect(row.containsKey('last_pdf_path'), isFalse);
      expect(row.containsKey('expiry_date'), isFalse);
      expect(row.containsKey('supplier'), isTrue);
      expect(row['supplier'], '');
    });

    test('includes them as soon as they are set', () {
      final row = Inspection.fromMap(fullRow()).toRowMap();
      expect(row['id'], 42);
      expect(row['created_by'], 1);
      expect(row['last_pdf_path'], 'C:/reports/QC-MIG-001.pdf');
      expect(row['expiry_date'], '2027-01-31');
    });

    test('re-encodes the nested maps and lists as valid JSON text', () {
      final row = Inspection.fromMap(fullRow()).toRowMap();

      expect(jsonDecode('${row['physical_results_json']}'),
          {'color': 'Light gray', 'Moisture': '6.5'});
      expect(jsonDecode('${row['chemical_results_json']}'), {'pH': '7.1'});
      expect(jsonDecode('${row['sample_names_json']}'),
          ['Top', 'Mid', 'Base']);
      expect(jsonDecode('${row['snapshot_json']}'),
          {'entry_code': 'QC-MIG-001'});
    });

    test('an empty model serialises to the empty-JSON literals, not to "null"', () {
      final row = const Inspection(
        entryCode: 'E-1',
        materialId: 1,
        materialName: 'M',
        materialCode: 'C',
        inspectionDate: '2026-09-01',
        createdAt: '2026-09-01T00:00:00.000',
        updatedAt: '2026-09-01T00:00:00.000',
      ).toRowMap();

      expect(row['physical_results_json'], jsonDumps(const <String, dynamic>{}));
      expect(row['sample_names_json'], jsonDumps(const <dynamic>[]));
      expect('${row['physical_results_json']}', isNot(contains('null')));
    });
  });

  group('Inspection round trip', () {
    test('toRowMap -> fromMap -> toRowMap is byte-identical when nothing is null',
        () {
      final original = Inspection.fromMap(fullRow());
      final once = original.toRowMap();
      final twice = Inspection.fromMap(once).toRowMap();

      expect(twice, once,
          reason: 'a value written and read back must be IDENTICAL');
    });

    test('a null-valued model also survives a round trip unchanged', () {
      final once = Inspection.fromMap(withoutNullableColumns()).toRowMap();
      final twice = Inspection.fromMap(once).toRowMap();

      expect(twice, once);
      expect(Inspection.fromMap(twice).lastPdfPath, isNull);
      expect(Inspection.fromMap(twice).expiryDate, isNull);
      expect(Inspection.fromMap(twice).createdBy, isNull);
      expect(Inspection.fromMap(twice).id, isNull);
    });
  });

  group('Inspection round trip through the real inspections table', () {
    late Directory tmp;
    late DatabaseHelper helper;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('matlab_inspection_model');
      helper = DatabaseHelper(_FakeAppPaths(tmp.path));
      db = await helper.database;
      await db.insert('reference_materials', <String, dynamic>{
        'material_name': 'Sugar',
        'material_code': 'M-SUG-01',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'imported_at': nowIso(),
      });
      // `inspections.created_by` REFERENCES users(id); the schema only creates
      // the reserved id 0 row, so the author used by [fullRow] needs seeding.
      await db.insert('users', <String, dynamic>{
        'id': 1,
        'email': 'inspector@lab.test',
        'full_name': 'Ahmed Ali',
        'role': 'admin',
        'status': 'active',
        'created_at': nowIso(),
      });
    });

    tearDown(() async {
      await helper.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a fully populated row survives INSERT -> SELECT -> fromMap unchanged',
        () async {
      final expected = Inspection.fromMap(fullRow()).toRowMap();
      final id = await db.insert('inspections', expected);

      final stored = await db.query('inspections',
          where: 'entry_code = ?', whereArgs: ['QC-MIG-001']);
      expect(stored, hasLength(1));
      expect(Inspection.fromMap(stored.single).toRowMap(), expected,
          reason: 'the DB must not change a single column on the way through');
      expect(Inspection.fromMap(stored.single).id, id);
    });

    test('NULL columns come back as NULL, not as "" and not as "null"', () async {
      // Written straight into SQLite with the optional keys *absent*, so the
      // columns really hold NULL rather than an empty string. This is the shape
      // an importer or `pull_worker` leaves behind.
      await db.insert('inspections', <String, dynamic>{
        ...minimalRow(),
      }
        ..remove('supplier')
        ..remove('truck_number')
        ..remove('quantity')
        ..remove('sample_taken_by')
        ..remove('decision_reason')
        ..remove('follow_up_note')
        ..remove('rejected_quantity')
        ..remove('report_html'));

      final stored = await db.query('inspections',
          where: 'entry_code = ?', whereArgs: ['QC-MIG-001']);
      expect(stored.single['supplier'], isNull);
      expect(stored.single['last_pdf_path'], isNull);
      expect(stored.single['expiry_date'], isNull);

      final i = Inspection.fromMap(stored.single);
      // The text columns become '' ...
      expect(i.supplier, '');
      expect(i.truckNumber, '');
      expect(i.quantity, '');
      expect(i.decisionReason, '');
      expect(i.reportHtml, '');
      // ... and the genuinely nullable ones stay null.
      expect(i.lastPdfPath, isNull);
      expect(i.expiryDate, isNull);
      expect(i.createdBy, 0);
    });

    test('INTEGER columns come back as int, so the bare id cast always holds',
        () async {
      final expected = Inspection.fromMap(fullRow()).toRowMap();
      final id = await db.insert('inspections', expected);

      final stored = await db.query('inspections',
          where: 'entry_code = ?', whereArgs: ['QC-MIG-001']);
      expect(stored.single['id'], isA<int>());
      expect(stored.single['material_id'], isA<int>());
      expect(stored.single['decision_version'], isA<int>());
      expect(() => Inspection.fromMap(stored.single), returnsNormally);
      expect(Inspection.fromMap(stored.single).id, id);
    });

    test('a row whose inspection_date is empty still deserialises', () {
      // `inspection_date` is NOT NULL, and an empty string is a legal value.
      // Nothing here is a date parse, so no field may blow up on it.
      final i = Inspection.fromMap({...minimalRow(), 'inspection_date': ''});
      expect(i.inspectionDate, '');
      expect(i.toRowMap()['inspection_date'], '');
    });
  });

  group('qty3 / rejectedQty3 — the three-decimal report format', () {
    test('a numeric quantity is rendered with exactly three decimals', () {
      expect(const Inspection(entryCode: 'e', materialId: 1, materialName: 'm',
              materialCode: 'c', inspectionDate: '2026-09-01',
              createdAt: 'x', updatedAt: 'x', quantity: '12')
              .qty3,
          '12.000');
      expect(const Inspection(entryCode: 'e', materialId: 1, materialName: 'm',
              materialCode: 'c', inspectionDate: '2026-09-01',
              createdAt: 'x', updatedAt: 'x', quantity: '12.5')
              .qty3,
          '12.500');
      expect(const Inspection(entryCode: 'e', materialId: 1, materialName: 'm',
              materialCode: 'c', inspectionDate: '2026-09-01',
              createdAt: 'x', updatedAt: 'x', quantity: '  7  ')
              .qty3,
          '7.000',
          reason: 'the value is trimmed before parsing');
    });

    test('"" and "-" are passed through so the report can print its placeholder',
        () {
      expect(const Inspection(entryCode: 'e', materialId: 1, materialName: 'm',
              materialCode: 'c', inspectionDate: '2026-09-01',
              createdAt: 'x', updatedAt: 'x')
              .qty3,
          '');
      expect(
          const Inspection(
                  entryCode: 'e',
                  materialId: 1,
                  materialName: 'm',
                  materialCode: 'c',
                  inspectionDate: '2026-09-01',
                  createdAt: 'x',
                  updatedAt: 'x',
                  quantity: '-')
              .qty3,
          '-');
    });

    test('a non-numeric quantity is printed verbatim rather than as 0.000', () {
      expect(const Inspection(entryCode: 'e', materialId: 1, materialName: 'm',
              materialCode: 'c', inspectionDate: '2026-09-01',
              createdAt: 'x', updatedAt: 'x', quantity: 'N/A')
              .qty3,
          'N/A');
    });

    test('BUG PINNED: a comma-grouped quantity bypasses the three-decimal format',
        () {
      // `safeFloat` strips thousand separators, but `_to3` calls
      // `double.tryParse` directly, so `"1,234.5"` is not a number and the raw
      // text lands in the report — the very column the format exists to
      // normalise.
      expect(const Inspection(entryCode: 'e', materialId: 1, materialName: 'm',
              materialCode: 'c', inspectionDate: '2026-09-01',
              createdAt: 'x', updatedAt: 'x', quantity: '1,234.5')
              .qty3,
          '1,234.5');
      expect(const Inspection(entryCode: 'e', materialId: 1, materialName: 'm',
              materialCode: 'c', inspectionDate: '2026-09-01',
              createdAt: 'x', updatedAt: 'x', rejectedQuantity: '10,000')
              .rejectedQty3,
          '10,000');
    });
  });

  group('hasDecision', () {
    test('an empty decision status means "no decision yet"', () {
      expect(
          Inspection.fromMap({...minimalRow(), 'decision_status': ''})
              .hasDecision,
          isFalse);
      expect(
          Inspection.fromMap({...minimalRow(), 'decision_status': null})
              .hasDecision,
          isFalse);
    });

    test('BUG PINNED: the "PENDING" placeholder counts as a decision', () {
      // `pull_worker.dart:345` defaults a remote row with no decision to
      // `'PENDING'`, and `hasDecision` is `decisionStatus.isNotEmpty`. So a
      // freshly pulled, undecided inspection reports `hasDecision == true` and
      // the UI treats it as signed off.
      final pulled = Inspection.fromMap(
          {...minimalRow(), 'decision_status': 'PENDING'});
      expect(pulled.hasDecision, isTrue);
      expect(pulled.decisionStatus, isNotEmpty);
    });
  });

  group('StatusHistoryRow', () {
    Map<String, dynamic> historyRow({bool withId = false}) {
      final row = <String, dynamic>{
        'inspection_id': 42,
        'version': 2,
        'old_status': 'APPROVED',
        'new_status': 'FULL_REJECTION',
        'change_reason': 'retest failed',
        'follow_up_note': '',
        'rejected_quantity': '10',
        'changed_by': 1,
        'changed_by_name': 'Ahmed Ali',
        'changed_at': '2026-09-01T09:00:00.000',
      };
      if (withId) row['id'] = 7;
      return row;
    }

    test('fromMap normalises the nullable text columns but keeps old_status null',
        () {
      // The asymmetry is the point: `old_status` is the one column that survives
      // as null (so "there was no previous status" stays distinguishable from
      // "the previous status was empty"), while the three note columns collapse
      // to ''. `toMap` therefore writes null and '' interchangeably for the
      // same concept.
      final row = StatusHistoryRow.fromMap(<String, dynamic>{
        'inspection_id': 42,
        'version': 1,
        'old_status': null,
        'new_status': 'APPROVED',
        'changed_by': 1,
        'changed_at': '2026-09-01T09:00:00.000',
      });

      expect(row.oldStatus, isNull);
      expect(row.changeReason, '');
      expect(row.followUpNote, '');
      expect(row.rejectedQuantity, '');
      expect(row.changedByName, '');
      for (final value in [
        row.changeReason,
        row.followUpNote,
        row.rejectedQuantity,
        row.changedByName,
      ]) {
        expect(value, isNot('null'));
      }
    });

    test('toMap omits a null id so the insert works and keeps it once set', () {
      expect(StatusHistoryRow.fromMap(historyRow()).toMap().containsKey('id'),
          isFalse);
      expect(
          StatusHistoryRow.fromMap(historyRow(withId: true)).toMap()['id'], 7);
    });

    test('the NOT NULL id columns are read with a bare cast and throw on NULL',
        () {
      // Unlike `Inspection.fromMap`, which coerces with `?? 0` / `?? 1`, this
      // deserialiser crashes on a NULL `inspection_id`/`version`/`changed_by`.
      // The columns are NOT NULL in the schema, so the difference only shows up
      // on a corrupt or hand-edited row — but it shows up as a crash, not a
      // silent default.
      final base = <String, dynamic>{...historyRow()}..remove('inspection_id');
      expect(() => StatusHistoryRow.fromMap(base), throwsA(isA<TypeError>()));

      final noVersion = <String, dynamic>{...historyRow()}..remove('version');
      expect(
          () => StatusHistoryRow.fromMap(noVersion), throwsA(isA<TypeError>()));

      final noAuthor = <String, dynamic>{...historyRow()}..remove('changed_by');
      expect(
          () => StatusHistoryRow.fromMap(noAuthor), throwsA(isA<TypeError>()));
    });

    test('a REAL version is coerced, a REAL id is not', () {
      expect(
          StatusHistoryRow.fromMap({...historyRow(), 'version': 2.0}).version, 2);
      expect(() => StatusHistoryRow.fromMap({...historyRow(), 'id': 7.0}),
          throwsA(isA<TypeError>()));
    });

    test('fromMap -> toMap is byte-identical for a full row', () {
      final row = historyRow(withId: true);
      expect(StatusHistoryRow.fromMap(row).toMap(), row);
    });

    test('equatable: rows that differ only by id are not equal', () {
      expect(StatusHistoryRow.fromMap(historyRow(withId: true)),
          StatusHistoryRow.fromMap(historyRow(withId: true)));
      expect(StatusHistoryRow.fromMap(historyRow(withId: true)),
          isNot(StatusHistoryRow.fromMap(historyRow())));
      expect(
          StatusHistoryRow.fromMap(historyRow(withId: true)),
          isNot(StatusHistoryRow.fromMap({
            ...historyRow(withId: true),
            'new_status': 'APPROVED',
          })),
          reason: 'every field listed in props must affect equality');
    });
  });

  group('StatusHistoryRow round trip through the real history table', () {
    late Directory tmp;
    late DatabaseHelper helper;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('matlab_history_model');
      helper = DatabaseHelper(_FakeAppPaths(tmp.path));
      db = await helper.database;
      await db.insert('reference_materials', <String, dynamic>{
        'material_name': 'Sugar',
        'material_code': 'M-SUG-01',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'imported_at': nowIso(),
      });
      await db.insert('inspections', <String, dynamic>{
        ...minimalRow(),
        'material_id': 1,
      });
    });

    tearDown(() async {
      await helper.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('INSERT -> SELECT -> toMap preserves every column including NULL', () async {
      final expected = <String, dynamic>{
        'inspection_id': 1,
        'version': 1,
        'old_status': null,
        'new_status': 'APPROVED',
        'change_reason': '',
        'follow_up_note': '',
        'rejected_quantity': '',
        'changed_by': 0,
        'changed_by_name': 'Unknown user',
        'changed_at': '2026-09-01T09:00:00.000',
      };
      final id = await db.insert('inspection_status_history', expected);

      final stored = await db.query('inspection_status_history',
          where: 'inspection_id = ?', whereArgs: [1]);
      final round = StatusHistoryRow.fromMap(stored.single).toMap();

      expect(round['old_status'], isNull,
          reason: 'a NULL old_status must not come back as ""');
      expect(round['new_status'], 'APPROVED');
      expect(round['change_reason'], '');
      expect(round['id'], id);
      const identity = [
        'inspection_id',
        'version',
        'new_status',
        'changed_by',
        'changed_by_name',
        'changed_at',
      ];
      expect(
        {for (final k in identity) k: round[k]},
        {for (final k in identity) k: expected[k]},
      );
    });
  });
}