import 'dart:convert' as convert;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/offline_first_qc_custom_tables.dart';
import 'package:material_lab/features/qc_manager/data/qc_custom_tables_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_custom_table.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class _TestAppPaths extends AppPaths {
  _TestAppPaths(this.root);

  final String root;

  @override
  Future<Directory> appSupportRoot() async => Directory('$root/MaterialLab');
}

class _Writer implements WriteGuard {
  const _Writer();

  @override
  String get uid => 'u1';
  @override
  String get email => 'u1@example.test';
  @override
  String get organizationId => 'org-1';
  @override
  String get memberId => 'm-1';
  @override
  String get deviceId => 'dev-a';
  @override
  bool get online => true;

  @override
  bool allows(String permissionId) =>
      permissionId == Permission.qcRead.id ||
      permissionId == Permission.qcWrite.id;
}

class _ReadOnly implements WriteGuard {
  const _ReadOnly();

  @override
  String get uid => 'u1';
  @override
  String get email => 'u1@example.test';
  @override
  String get organizationId => 'org-1';
  @override
  String get memberId => 'm-1';
  @override
  String get deviceId => 'dev-a';
  @override
  bool get online => true;

  @override
  bool allows(String permissionId) => permissionId == Permission.qcRead.id;
}

const timestamp = '2026-01-06T09:30:00Z';

QcCustomTable newTable(String title, {int sortOrder = 0}) => QcCustomTable(
  title: title,
  description: 'A register of my own',
  sortOrder: sortOrder,
  createdAt: timestamp,
  updatedAt: timestamp,
);

QcCustomTableField newField(
  String label,
  String colType, {
  bool isOptional = true,
  int sortOrder = 0,
}) => QcCustomTableField(
  label: label,
  colType: colType,
  required: !isOptional,
  sortOrder: sortOrder,
  createdAt: timestamp,
  updatedAt: timestamp,
);

QcCustomTableRow record(
  QcCustomTable tableDef,
  Map<String, dynamic> values, {
  String note = '',
}) => QcCustomTableRow(
  tableId: tableDef.tableId,
  tableRemoteId: tableDef.remoteId,
  valuesJson: convert.jsonEncode(values),
  note: note,
  recordedAt: timestamp,
  createdAt: timestamp,
  updatedAt: timestamp,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory temporaryDirectory;
  late DatabaseHelper helper;
  late Database database;
  late QcCustomTablesRepository repo;
  late SyncQueue queue;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qc_custom_tables',
    );
    helper = DatabaseHelper(_TestAppPaths(temporaryDirectory.path));
    database = await helper.database;
    queue = SyncQueue(helper);
    repo = OfflineFirstQcCustomTablesRepository(
      local: QcCustomTablesRepo(helper),
      guard: const _Writer(),
      dbHelper: helper,
      queue: queue,
    );
  });

  tearDown(() async {
    await database.close();
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test(
    'createTable persists the definition with real cross-device identities',
    () async {
      final tableId = await repo.createTable(newTable('Sample weights'), [
        newField('Weight', QcCustomColType.number, isOptional: false),
        newField('Note', QcCustomColType.text),
        newField('Recorded day', QcCustomColType.date),
      ]);

      final bundle = await repo.getTableBundle(tableId);
      expect(bundle, isNotNull);
      expect(bundle!.table.title, 'Sample weights');
      expect(
        bundle.table.remoteId,
        hasLength(36),
        reason: 'the sync identity must be a uuid write at creation',
      );
      expect(bundle.fields, hasLength(3));
      for (final f in bundle.fields) {
        expect(
          f.tableRemoteId,
          bundle.table.remoteId,
          reason: 'children must stamp their parent at write time',
        );
        expect(f.remoteId, hasLength(36));
      }
    },
  );

  test('a record writes values keyed by column remote ids', () async {
    final tableId = await repo.createTable(newTable('Weights'), [
      newField('Pieces', QcCustomColType.number),
      newField('Batch', QcCustomColType.text, isOptional: false),
    ]);
    final bundle = (await repo.getTableBundle(tableId))!;
    await repo.addRow(
      record(bundle.table, {
        bundle.fields[0].remoteId: 12.5,
        bundle.fields[1].remoteId: 'B-2026-0142',
      }),
    );

    final rows = await repo.listRows(tableId);
    expect(rows, hasLength(1));
    expect(rows.single.values[bundle.fields[0].remoteId], 12.5);
    expect(rows.single.values[bundle.fields[1].remoteId], 'B-2026-0142');
  });

  test('every write lands in the real sync queue', () async {
    final tableId = await repo.createTable(newTable('Synced'), [
      newField('X', QcCustomColType.number),
    ]);
    final bundle = (await repo.getTableBundle(tableId))!;
    await repo.addRow(record(bundle.table, {bundle.fields[0].remoteId: 1}));

    // One definition + one column + one record = three queued changes. The
    // queue is what carries them to Firestore, so a commit that skips the
    // enqueue would pass every read test and still fail its only job.
    final queued = await database.query('sync_queue');
    expect(queued, hasLength(3));
    final entityTypes = queued.map((r) => '${r['entity_type']}').toSet();
    expect(
      entityTypes,
      containsAll(['qcCustomTable', 'qcCustomTableField', 'qcCustomTableRow']),
    );
  });

  test('invalid definitions are rejected and write nothing', () async {
    // No columns.
    await expectLater(
      repo.createTable(newTable('Empty'), const []),
      throwsA(isA<ValidationError>()),
    );
    expect(await repo.listTables(), isEmpty);

    // A duplicate title among alive definitions.
    await repo.createTable(newTable('Register'), [
      newField('A', QcCustomColType.text),
    ]);
    await expectLater(
      repo.createTable(newTable('Register'), [
        newField('A', QcCustomColType.number),
      ]),
      throwsA(isA<ValidationError>()),
    );
    expect(
      (await repo.listTables()).map((t) => t.title),
      everyElement('Register'),
    );
  });

  test(
    'saveTable reconciles: edits in place, appends new, tombstones gone',
    () async {
      final tableId = await repo.createTable(newTable('Title'), [
        newField('A', QcCustomColType.text),
        newField('B', QcCustomColType.number, isOptional: false),
        newField('C', QcCustomColType.date),
      ]);
      final before = (await repo.getTableBundle(tableId))!;
      final keyA = before.fields[0].remoteId;

      // A2 replaces A in the list; C is dropped; D is brand new. The facade
      // must keep A's identity (for values) and issue a fresh uuid for D.
      await repo.saveTable(before.table, [
        before.fields[0].copyWith(label: 'A renamed'),
        before.fields[1],
        newField('D', QcCustomColType.text, sortOrder: 3),
      ]);

      final after = (await repo.getTableBundle(tableId))!;
      final labels = after.fields.map((f) => f.label).toList();
      expect(labels, containsAll(['A renamed', 'B', 'D']));
      expect(labels, isNot(contains('C')));
      final idA = after.fields
          .firstWhere((f) => f.label == 'A renamed')
          .remoteId;
      expect(
        idA,
        keyA,
        reason: 'renaming must keep the column identity across devices',
      );

      // Older values recorded under a tombstoned column keep their keys -
      // history survives the user's later rename. A later record cannot
      // smuggle a value under a bare string, though: it is foreign. The
      // required column is included so the record itself stands on its own.
      final keyB = after.fields.firstWhere((f) => f.label == 'B').remoteId;
      await repo.addRow(
        record(after.table, {idA: 'a value', keyB: 1}),
      );
      await expectLater(
        repo.addRow(
          record(after.table, {'x': 1, keyB: 2}),
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(await repo.listRows(tableId), hasLength(1));
    },
  );

  test('a re-type over live values is refused; over none is allowed', () async {
    final tableId = await repo.createTable(newTable('Typing'), [
      newField('Count', QcCustomColType.number),
      newField('Fresh', QcCustomColType.number),
    ]);
    final bundle = (await repo.getTableBundle(tableId))!;
    final count = bundle.fields[0];
    final fresh = bundle.fields[1];
    await repo.addRow(record(bundle.table, {count.remoteId: 3}));

    // The column holds values: changing its type would re-type 3 into
    // "3.0"-neither text nor a number the other columns understand.
    await expectLater(
      repo.saveTable(bundle.table, [
        count.copyWith(colType: QcCustomColType.text),
        fresh,
      ]),
      throwsA(isA<ValidationError>()),
    );

    // The same re-type on a column nobody recorded into is legitimate.
    await repo.saveTable(bundle.table, [
      count,
      fresh.copyWith(colType: QcCustomColType.text),
    ]);
    final after = (await repo.getTableBundle(tableId))!;
    expect(
      after.fields.firstWhere((f) => f.label == 'Fresh').colType,
      QcCustomColType.text,
    );
  });

  test('record validation is policy, not SQL', () async {
    final tableId = await repo.createTable(newTable('Validation'), [
      newField('Pieces', QcCustomColType.number),
      newField('Batch', QcCustomColType.text, isOptional: false),
    ]);
    final bundle = (await repo.getTableBundle(tableId))!;
    final numberKey = bundle.fields[0].remoteId;
    final textKey = bundle.fields[1].remoteId;

    // A value under a key no column has: rejected, never stored.
    await expectLater(
      repo.addRow(record(bundle.table, {'no-such-column': 1})),
      throwsA(isA<ValidationError>()),
    );

    // A required column must not be skipped.
    await expectLater(
      repo.addRow(record(bundle.table, {numberKey: 42})),
      throwsA(isA<ValidationError>()),
    );

    // A number must really be a number.
    await expectLater(
      repo.addRow(record(bundle.table, {numberKey: 'twelve', textKey: 'B-1'})),
      throwsA(isA<ValidationError>()),
    );

    // The tables are empty: none of the rejected records persisted.
    expect(await repo.listRows(tableId), isEmpty);

    // A valid record does persist, values typed per column.
    await repo.addRow(
      record(bundle.table, {numberKey: 42, textKey: 'B-1'}, note: 'ok'),
    );
    var rows = await repo.listRows(tableId);
    expect(rows.single.values[numberKey], 42);

    // A partial edit merges over what exists instead of blanking it.
    final saved = rows.single;
    await repo.saveRow(
      saved.copyWith(valuesJson: convert.jsonEncode({textKey: 'B-2'})),
    );
    rows = await repo.listRows(tableId);
    expect(rows.single.values[textKey], 'B-2');
    expect(
      rows.single.values[numberKey],
      42,
      reason: 'an update that omits a value must keep it, not erase it',
    );
    expect(rows.single.note, 'ok');
  });

  test('rows read newest first and page by keyset', () async {
    final tableId = await repo.createTable(newTable('Paged'), [
      newField('X', QcCustomColType.number),
    ]);
    final bundle = (await repo.getTableBundle(tableId))!;
    for (var i = 0; i < 5; i++) {
      await repo.addRow(
        QcCustomTableRow(
          tableId: tableId,
          tableRemoteId: bundle.table.remoteId,
          valuesJson: convert.jsonEncode({bundle.fields[0].remoteId: i}),
          recordedAt: '2026-01-0${i + 1}T09:00:00Z',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
    }
    final first = await repo.listRows(tableId, limit: 3);
    expect(first.map((r) => r.rowId).toList(), [5, 4, 3]);

    final second = await repo.listRows(tableId, limit: 3, afterRowId: 3);
    expect(second.map((r) => r.rowId).toList(), [2, 1]);
  });

  test('deleteTable tombstones the definition and its children', () async {
    final tableIdx = await repo.createTable(newTable('Doomed'), [
      newField('X', QcCustomColType.text),
    ]);
    final bundle = (await repo.getTableBundle(tableIdx))!;
    await repo.addRow(record(bundle.table, {bundle.fields[0].remoteId: 'x'}));

    await repo.deleteTable(tableIdx);

    // Reads treat the whole subtree as gone.
    expect(await repo.listTables(), isEmpty);
    expect(await repo.getTableBundle(tableIdx), isNull);
    expect(await repo.listRows(tableIdx), isEmpty);

    // But the rows are tombstones on disk, not erasures: the audit trail
    // survives them.
    expect(await database.query('qc_custom_table_rows'), hasLength(1));
    expect(
      (await database.query('qc_custom_tables')).single['deleted_at'],
      isNotNull,
    );
    final fields = await database.query('qc_custom_table_fields');
    expect(fields.single['deleted_at'], isNotNull);
  });

  test('a deleted register frees its title for a new one', () async {
    final first = await repo.createTable(newTable('Free title'), [
      newField('X', QcCustomColType.text),
    ]);
    await repo.deleteTable(first);
    final second = await repo.createTable(newTable('Free title'), [
      newField('Y', QcCustomColType.number),
    ]);
    expect(second, isNot(first));
    final tables = (await repo.listTables());
    expect(tables, hasLength(1));
    expect(tables.single.title, 'Free title');
  });

  test('a read-only guard must not write anything', () async {
    final readonly = OfflineFirstQcCustomTablesRepository(
      local: QcCustomTablesRepo(helper),
      guard: const _ReadOnly(),
      dbHelper: helper,
      queue: queue,
    );
    await expectLater(
      readonly.createTable(newTable('Nope'), [
        newField('A', QcCustomColType.text),
      ]),
      throwsA(isA<AuthorizationError>()),
    );
    expect(await repo.listTables(), isEmpty);
  });
}
