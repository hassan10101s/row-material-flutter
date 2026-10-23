import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/data/qc_repo.dart';
import 'package:material_lab/features/qc_manager/data/routine_lists_repository.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

class _TestGuard implements WriteGuard {
  @override
  bool get online => true;

  @override
  String get uid => 'u1';

  @override
  String get email => 'checker@example.test';

  @override
  String get organizationId => 'org-1';

  @override
  String get memberId => 'm-1';

  @override
  String get deviceId => 'dev-1';

  @override
  bool allows(String permissionId) => true;
}

/// Routine lists over a real database: period sheets, attributed checks,
/// same-period uncheck, past-sheet lock and history filters.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late RoutineListsRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_routine');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    await helper.database;
    repo = RoutineListsRepositoryImpl(
      dbHelper: helper,
      guard: _TestGuard(),
      audit: QcAuditRepo(
        dbHelper: helper,
        actorReader: () => const QcActor(uid: 'u1', name: 'Checker'),
      ),
      templates: QcTemplateRepo(helper),
      inspections: QcInspectionRepo(helper),
    );
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<int> dailyList() => repo.saveRoutineList(
    name: 'Shift cleanliness',
    dept: 'Production',
    recurrence: QcRecurrence.daily,
    items: const ['Floor swept', 'Bins emptied'],
  );

  test('save + open seeds blank rows; check stamps who/when', () async {
    final id = await dailyList();
    final lists = await repo.listRoutineLists();
    expect(lists, hasLength(1));
    expect(lists.first.totalItems, 2);
    expect(lists.first.doneCount, 0);

    final sheet = await repo.openPeriodSheet(id);
    expect(sheet.rows, hasLength(2));
    expect(sheet.current, isTrue);
    expect(sheet.doneCount, 0);

    final itemId = sheet.rows.first.item.itemId!;
    final checked = await repo.toggleCheck(
      inspectionId: sheet.inspection.inspectionId!,
      itemId: itemId,
      note: 'done early',
    );
    expect(checked.doneCount, 1);
    final row = checked.rows.firstWhere((r) => r.item.itemId == itemId);
    expect(row.recorded, isTrue);
    expect(row.response.answeredBy, 'u1');
    expect(row.response.answeredByName, 'Checker');
    expect(row.response.measuredAt, isNotEmpty);
    expect(row.response.notes, 'done early');
  });

  test('opening twice in one period reuses the sheet (no reset)', () async {
    final id = await dailyList();
    final first = await repo.openPeriodSheet(id);
    await repo.toggleCheck(
      inspectionId: first.inspection.inspectionId!,
      itemId: first.rows.first.item.itemId!,
    );
    final second = await repo.openPeriodSheet(id);
    expect(
      second.inspection.inspectionId,
      first.inspection.inspectionId,
    );
    expect(second.doneCount, 1);
  });

  test('uncheck in the current period blanks the row again', () async {
    final id = await dailyList();
    final sheet = await repo.openPeriodSheet(id);
    final inspectionId = sheet.inspection.inspectionId!;
    final itemId = sheet.rows.first.item.itemId!;
    await repo.toggleCheck(inspectionId: inspectionId, itemId: itemId);
    final unchecked = await repo.toggleCheck(
      inspectionId: inspectionId,
      itemId: itemId,
    );
    expect(unchecked.doneCount, 0);
    final row = unchecked.rows.firstWhere((r) => r.item.itemId == itemId);
    expect(row.recorded, isFalse);
    expect(row.response.answeredBy, '');
  });

  test('past sheets are immutable', () async {
    final id = await dailyList();
    final db = await helper.database;
    final stamp = '2020-01-01 08:00:00';
    final oldId = await QcInspectionRepo(helper).createInspection(
      QcInspection(
        templateId: id,
        inspectionDate: '2020-01-01',
        createdAt: stamp,
        updatedAt: stamp,
      ),
    );
    final rows = await db.query(
      'qc_responses',
      columns: ['item_id'],
      where: 'inspection_id = ?',
      whereArgs: [oldId],
      limit: 1,
    );
    expect(
      () => repo.toggleCheck(
        inspectionId: oldId,
        itemId: (rows.first['item_id'] as num).toInt(),
      ),
      throwsA(isA<Exception>()),
    );
    // ...but it shows up in history.
    final history = await repo.sheetHistory();
    expect(history.any((e) => e.inspection.inspectionId == oldId), isTrue);
  });

  test('monthly lists share one sheet per month', () async {
    final id = await repo.saveRoutineList(
      name: 'Monthly gauges',
      recurrence: QcRecurrence.monthly,
      items: const ['Calipers', 'Micrometer'],
    );
    final first = await repo.openPeriodSheet(id);
    final second = await repo.openPeriodSheet(id);
    expect(
      second.inspection.inspectionId,
      first.inspection.inspectionId,
    );
  });

  test('history filters: person, completion, item text', () async {
    final id = await dailyList();
    final sheet = await repo.openPeriodSheet(id);
    await repo.toggleCheck(
      inspectionId: sheet.inspection.inspectionId!,
      itemId: sheet.rows.first.item.itemId!,
    );

    final byPerson = await repo.sheetHistory(
      const RoutineHistoryFilters(person: 'Checker'),
    );
    expect(byPerson, isNotEmpty);

    final byNobody = await repo.sheetHistory(
      const RoutineHistoryFilters(person: 'Nobody Here'),
    );
    expect(byNobody, isEmpty);

    final incomplete = await repo.sheetHistory(
      const RoutineHistoryFilters(completion: 'incomplete'),
    );
    expect(incomplete, isNotEmpty);

    final complete = await repo.sheetHistory(
      const RoutineHistoryFilters(completion: 'complete'),
    );
    expect(complete, isEmpty);

    final byItem = await repo.sheetHistory(
      const RoutineHistoryFilters(itemQuery: 'Bins'),
    );
    expect(byItem, isNotEmpty);

    final byTemplate = await repo.sheetHistory(
      RoutineHistoryFilters(templateId: id + 999),
    );
    expect(byTemplate, isEmpty);
  });

  test('done button: two presses → two log entries + row marked done', () async {
    final id = await dailyList();
    final sheet = await repo.openPeriodSheet(id);
    final inspectionId = sheet.inspection.inspectionId!;
    final itemId = sheet.rows.first.item.itemId!;

    await repo.recordDone(inspectionId: inspectionId, itemId: itemId);
    final afterSecond = await repo.recordDone(
      inspectionId: inspectionId,
      itemId: itemId,
      note: 'second press',
    );

    // Scorecard stays consistent: the row reads as done once, despite two
    // presses (the response row is stamped, not duplicated).
    expect(afterSecond.doneCount, 1);
    final row = afterSecond.rows.firstWhere((r) => r.item.itemId == itemId);
    expect(row.recorded, isTrue);
    expect(row.response.answeredBy, 'u1');
    expect(row.response.answeredByName, 'Checker');
    expect(row.response.measuredAt, isNotEmpty);
    // But EVERY press is logged (time + user each).
    expect(row.taskLogCount, 2);
    expect(row.hasTaskLogs, isTrue);
    expect(row.lastTaskLogByName, 'Checker');
    // Other rows untouched so far.
    expect(
      afterSecond.rows
          .firstWhere((r) => r.item.itemId != itemId)
          .taskLogCount,
      0,
    );

    final logs = await repo.taskLogs(inspectionId, itemId: itemId);
    expect(logs, hasLength(2));
    expect(logs.first.loggedBy, 'u1');
    expect(logs.first.loggedByName, 'Checker');
    expect(logs.first.loggedAt, isNotEmpty);
    expect(logs.first.note, 'second press');
    expect(logs.first.logId, greaterThan(logs.last.logId));
    expect(row.lastTaskLogAt, logs.first.loggedAt);
    expect(await repo.taskLogs(inspectionId), hasLength(2));

    // Unchecking the box does not erase the completion history.
    final unchecked = await repo.toggleCheck(
      inspectionId: inspectionId,
      itemId: itemId,
    );
    final row2 = unchecked.rows.firstWhere((r) => r.item.itemId == itemId);
    expect(row2.recorded, isFalse);
    expect(row2.taskLogCount, 2);
  });

  test('done button on a past sheet throws (immutability)', () async {
    final id = await dailyList();
    final db = await helper.database;
    final stamp = '2020-01-01 08:00:00';
    final oldId = await QcInspectionRepo(helper).createInspection(
      QcInspection(
        templateId: id,
        inspectionDate: '2020-01-01',
        createdAt: stamp,
        updatedAt: stamp,
      ),
    );
    final rows = await db.query(
      'qc_responses',
      columns: ['item_id'],
      where: 'inspection_id = ?',
      whereArgs: [oldId],
      limit: 1,
    );
    expect(
      () => repo.recordDone(
        inspectionId: oldId,
        itemId: (rows.first['item_id'] as num).toInt(),
      ),
      throwsA(isA<Exception>()),
    );
    expect(await repo.taskLogs(oldId), isEmpty);
  });

  test('editing a list in place reconciles items', () async {
    final id = await dailyList();
    await repo.saveRoutineList(
      templateId: id,
      name: 'Shift cleanliness v2',
      dept: 'Production',
      recurrence: QcRecurrence.daily,
      items: const ['Floor swept', 'Windows'],
    );
    final labels = await repo.listItemLabels(id);
    expect(labels, ['Floor swept', 'Windows']);
    final lists = await repo.listRoutineLists();
    expect(lists.first.template.name, 'Shift cleanliness v2');
  });
}
