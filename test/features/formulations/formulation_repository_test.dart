import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/formulations/data/sqlite_formulation_repository.dart';
import 'package:material_lab/features/formulations/domain/formulation_calculator.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import '../../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late SqliteFormulationRepository repo;
  const session = AppSession(
    uid: 'uid_admin',
    organizationId: 'org_test',
    memberId: 'member_admin',
    deviceId: 'writer',
    role: 'nutritionist',
    status: 'active',
  );
  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    final queue = SyncQueue(fixture.helper);
    repo = SqliteFormulationRepository(
      dbHelper: fixture.helper,
      guard: SessionWriteGuard(
        source: SessionSource(() => session),
        isOnline: () => true,
      ),
      queue: queue,
      audit: AuditLogger(queue: queue, session: () => session),
    );
  });
  tearDown(() => fixture.dispose());

  Map<String, dynamic> record() => {
    'name': 'Starter',
    'items': [
      {
        'material_id': 1,
        'material_name': 'Cement',
        'quantity_kg': 100,
        'price_per_kg': 2,
      },
    ],
  };
  test(
    'save and duplicate keep independent identities, quantities and sync rows',
    () async {
      final first = await repo.save(record());
      final second = await repo.save({
        ...record(),
        'name': 'Copy',
        'copied_from_id': first,
      });
      final rows = await repo.list();
      expect(rows, hasLength(2));
      expect(rows.map((e) => e['remote_id']).toSet(), hasLength(2));
      expect(first, isNot(second));
      await repo.archive(first);
      expect((await repo.list()).single['id'], second);
      expect((await repo.list(archived: true)).single['id'], first);
      expect(
        await fixture.db.query(
          'sync_queue',
          where: 'entity_type = ?',
          whereArgs: ['nutritionFormulation'],
        ),
        isNotEmpty,
      );
    },
  );
  test(
    'empty and invalid quantities are rejected without writing a partial formula',
    () async {
      for (final value in [
        <Object?>[],
        [null],
        [
          {'material_id': 1, 'quantity_kg': 0},
        ],
        [
          {'material_id': 1, 'quantity_kg': 10, 'price_per_kg': -1},
        ],
      ]) {
        await expectLater(
          repo.save({'name': 'Invalid', 'items': value}),
          throwsA(isA<ValidationError>()),
        );
      }
      expect(await repo.list(), isEmpty);
    },
  );
  test(
    'fallback searches past a newer receipt that lacks the required parameter',
    () async {
      await fixture.db.insert('inspections', {
        ...sampleRow(entryCode: 'OLD', decisionStatus: 'APPROVED'),
        'inspection_date': '2026-01-01',
        'chemical_results_json': '{"protein":[20]}',
      });
      await fixture.db.insert('inspections', {
        ...sampleRow(entryCode: 'NEW', decisionStatus: 'APPROVED'),
        'inspection_date': '2026-01-10',
        'chemical_results_json': '{"moisture":[8]}',
      });
      final receipts = await repo.receipts(
        [1],
        DateTime(2026, 2),
        DateTime(2026, 2, 28),
      );
      final averages = FormulationCalculator.averages(
        materialIds: [1],
        receipts: receipts,
        from: DateTime(2026, 2),
        to: DateTime(2026, 2, 28),
      );
      expect(averages[1]!['protein']!.value, 20);
      expect(averages[1]!['protein']!.receiptCode, 'OLD');
      expect(averages[1]!['moisture']!.value, 8);
    },
  );
}
