import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/inspections/data/offline_first_inspection_repository.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/reports/data/report_html_builder.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';

import '../../sync/sync_test_fixture.dart';

/// Saving an inspection used to freeze for ten seconds and silently leave
/// `report_html` stale.
///
/// `OfflineFirstInspectionRepository` opens a write transaction and, inside it,
/// `InspectionRepo.create` called `_refreshReportHtml`. That reached
/// `ReportHtmlBuilder.buildContext`, whose first act is `SettingsRepo.getSettings()`
/// — a read on the **root** handle. `sqflite_common_ffi` does not run a
/// root-handle statement while a transaction is open: it parks it in
/// `SqfliteFfiDatabase._noTransactionHandlerQueue` until the transaction commits,
/// having already taken the connection's non-reentrant lock. The transaction body
/// was waiting on that read, so the transaction could not commit and the read
/// could not be released.
///
/// `sqflite` breaks the deadlock after 10s by failing the parked read with a
/// `DatabaseException`, which `_refreshReportHtml` caught and discarded. The save
/// therefore "succeeded" after a ten-second freeze with a stale report.
///
/// The test below does not wait out sqflite's ten-second lock timeout, because a
/// regression would then also deadlock `tearDown` and hang the suite instead of
/// failing. Instead the builder probes the invariant directly: it issues a
/// root-handle read and gives up quickly. The read can only fail to come back if
/// a transaction is open on the connection, which is exactly the defect.
class _RootHandleReadingBuilder extends ReportHtmlBuilder {
  _RootHandleReadingBuilder(this.helper)
      : super(
          settingsRepo: SettingsRepo(
            dbHelper: helper,
            secret: LocalSecret('unused'),
          ),
          labRepo: LabRepo(dbHelper: helper),
          secret: LocalSecret('unused'),
          templateLoader: () async => 'x',
        );

  final DatabaseHelper helper;

  /// True when [renderInspectionHtml] was called while a transaction was open.
  bool calledInsideTransaction = false;

  @override
  Future<String> renderInspectionHtml(
    Map<String, dynamic> inspection, {
    String? baseUrl,
  }) async {
    // Stands in for `getSettings()` + `injectLabTests()`: both reach for the
    // root handle, which is the whole defect.
    final db = await helper.database;
    try {
      final rows =
          await db.query('settings').timeout(const Duration(milliseconds: 400));
      return 'report:${rows.length}';
    } on TimeoutException {
      // Parked in `_noTransactionHandlerQueue`: nobody can run it until the
      // transaction commits, and the transaction is waiting on us.
      calledInsideTransaction = true;
      return 'report:parked';
    }
  }
}

class _AllowAllGuard implements WriteGuard {
  @override
  bool get online => true;
  @override
  String get uid => 'uid_admin';
  @override
  String get organizationId => 'org_test';
  @override
  String get memberId => 'admin@material-lab.test';
  @override
  String get deviceId => 'dev_1';
  @override
  String get email => memberId;

  @override
  bool allows(String permissionId) => Permission.byId(permissionId) != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late SyncFixture fx;
  late OfflineFirstInspectionRepository repo;
  late _RootHandleReadingBuilder builder;

  const user = UserContext(id: 1, fullName: 'Hassan el sayed', role: 'admin');

  Map<String, dynamic> payload(String entryCode) => <String, dynamic>{
        'entry_code': entryCode,
        'material_id': 1,
        'inspection_date': '2026-09-27',
        'supplier': 'xcfhd',
        'truck_number': 'gx',
        'quantity': '4444',
        'sample_taken_by': 'gsdfgfgcg',
        'decision_status': 'APPROVED',
        'physical_results': <String, dynamic>{'color': 'Light gray'},
        'chemical_results': <String, dynamic>{'Moisture': '6'},
      };

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    final queue = SyncQueue(fx.helper);
    final audit = AuditLogger(queue: queue);
    builder = _RootHandleReadingBuilder(fx.helper);
    repo = OfflineFirstInspectionRepository(
      dbHelper: fx.helper,
      referenceRepo: ReferenceRepo(dbHelper: fx.helper),
      htmlBuilder: builder,
      guard: _AllowAllGuard(),
      queue: queue,
      audit: audit,
    );
  });

  tearDown(() async => fx.dispose());

  test('create renders the report outside the write transaction', () async {
    final row = await repo.create(payload('BTM-20260927-101'), user);

    expect(
      builder.calledInsideTransaction,
      isFalse,
      reason: 'the report builder reads on the root handle, which cannot run '
          'while a transaction is open — that is the deadlock',
    );
    final id = (row['id'] as num).toInt();
    final stored =
        (await fx.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
    expect(
      stored['report_html'],
      startsWith('report:'),
      reason: 'the report must still be written, just after the commit',
    );
  });

  test('update renders the report outside the write transaction', () async {
    final created = await repo.create(payload('BTM-20260927-102'), user);
    final id = (created['id'] as num).toInt();

    builder.calledInsideTransaction = false;
    await repo.update(id, payload('BTM-20260927-102'), user);

    expect(builder.calledInsideTransaction, isFalse);
  });

  test('a QC decision renders the report outside the write transaction',
      () async {
    final created = await repo.create(payload('BTM-20260927-104'), user);
    final id = (created['id'] as num).toInt();

    builder.calledInsideTransaction = false;
    await repo.updateStatus(id, <String, dynamic>{
      'decision_status': 'FULL_REJECTION',
      'decision_reason': 'moisture out of specification',
    }, user);

    expect(builder.calledInsideTransaction, isFalse);
  });
}
