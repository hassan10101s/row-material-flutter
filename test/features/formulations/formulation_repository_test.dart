import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/core/domain/formulation_receipt_policy.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
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

  test(
    'only final and conditional approvals enter sources and linked ledger, including fallback',
    () async {
      final decisions = [
        'APPROVED',
        'CONDITIONAL_APPROVAL',
        'PARTIAL_REJECTION',
        'FULL_REJECTION',
        'PENDING',
        '',
      ];
      for (var i = 0; i < decisions.length; i++) {
        await fixture.db.insert('inspections', {
          ...sampleRow(entryCode: 'STATUS-$i', decisionStatus: decisions[i]),
          'chemical_results_json': '{"protein":[${10 + i * 20}]}',
          'inspection_date': '2026-01-01',
        });
      }
      final rows = await repo.receipts([1], DateTime(1900), DateTime(2026, 2));
      expect(rows.map((row) => row.code), ['STATUS-0', 'STATUS-1']);
      final value = FormulationCalculator.averages(
        materialIds: [1],
        receipts: rows,
        from: DateTime(2026, 2),
        to: DateTime(2026, 2, 28),
        aggregation: FormulationAggregation.maximum,
      )[1]!['protein']!;
      expect(value.value, 30);
      final ledger = InspectionRepo(
        dbHelper: fixture.helper,
        referenceRepo: ReferenceRepo(dbHelper: fixture.helper),
      );
      expect(
        await ledger.count(
          status: formulationAcceptedStatusFilter,
          materialId: 1,
        ),
        2,
      );
      expect(
        (await ledger.list(
          status: formulationAcceptedStatusFilter,
          materialId: 1,
        )).map((row) => row['entry_code']).toSet(),
        {'STATUS-0', 'STATUS-1'},
      );
      await fixture.db.update(
        'inspections',
        {'decision_status': 'PARTIAL_REJECTION'},
        where: 'entry_code = ?',
        whereArgs: ['STATUS-1'],
      );
      expect(
        (await repo.receipts(
          [1],
          DateTime(1900),
          DateTime(2026, 2),
        )).map((row) => row.code),
        ['STATUS-0'],
      );
    },
  );

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

  test(
    'picker ids use live accepted raw receipts without requiring numeric results',
    () async {
      for (final spec in [
        ('ACCEPTED', 'APPROVED', 'raw', null, '2026-01-01'),
        ('DELETED', 'APPROVED', 'raw', '2026-01-02', '2026-01-01'),
        ('REJECTED', 'FULL_REJECTION', 'raw', null, '2026-01-01'),
        ('PRODUCT', 'APPROVED', 'product', null, '2026-01-01'),
        ('FUTURE', 'APPROVED', 'raw', null, '2027-01-01'),
      ]) {
        await fixture.db.insert('inspections', {
          ...sampleRow(entryCode: spec.$1),
          'material_id': 1,
          'decision_status': spec.$2,
          'inspection_kind': spec.$3,
          'deleted_at': spec.$4,
          'inspection_date': spec.$5,
          'chemical_results_json': '{}',
          'physical_results_json': '{}',
        });
      }
      expect(await repo.materialIdsWithReceipts(DateTime(2026, 2)), {1});
      await fixture.db.update('inspections', {
        'deleted_at': '2026-02-01',
      }, where: "entry_code = 'ACCEPTED'");
      expect(await repo.materialIdsWithReceipts(DateTime(2026, 2)), isEmpty);
    },
  );

  test(
    'archived analysis preserves historical lab values and selectable parameter',
    () async {
      final parameter = await fixture.db.insert('parameters', {
        'parameter_name': 'Protein',
        'unit': '%',
        'imported_at': '2026-01-01',
      });
      final analysis = await fixture.db.insert('lab_analyses', {
        'name': 'Protein',
        'parameter_id': parameter,
        'unit': '%',
        'created_at': '2026-01-01',
      });
      await fixture.db.insert('inspections', {
        ...sampleRow(entryCode: 'HISTORY', decisionStatus: 'APPROVED'),
        'inspection_date': '2026-01-01',
      });
      await fixture.db.insert('lab_sample_tests', {
        'analysis_id': analysis,
        'source_type': 'raw_material',
        'source_ref_id': 1,
        'source_name': 'Cement',
        'sample_name': 'A',
        'result_text': '22.5',
        'entry_code': 'HISTORY',
        'tested_by': 1,
        'tested_at': '2026-01-02',
      });
      final before = await repo.receipts(
        [1],
        DateTime(2026),
        DateTime(2026, 2),
      );
      await fixture.db.update(
        'lab_analyses',
        {'active': 0},
        where: 'id = ?',
        whereArgs: [analysis],
      );
      final after = await repo.receipts([1], DateTime(2026), DateTime(2026, 2));
      expect(after.single.values, before.single.values);
      expect(after.single.values['protein'], 22.5);
      expect(
        (await repo.parameters()).map((row) => row['id']),
        contains(parameter),
      );
    },
  );

  test(
    'missing global material identity never falls back to a reused name or code',
    () async {
      await fixture.db.update('reference_materials', {
        'remote_id': 'OriginalCase',
      }, where: 'id = 1');
      final id = await repo.save(record());
      await fixture.db.update('reference_materials', {
        'remote_id': 'originalcase',
      }, where: 'id = 1');
      final listed = (await repo.list()).single;
      expect(listed['_missing_references'], isTrue);
      expect(
        (jsonDecode(listed['items_json'] as String) as List)
            .single['material_id'],
        -1,
      );
      // A caller also cannot bypass the list resolver with an old numeric id.
      final saved = (await fixture.db.query('nutrition_formulations')).single;
      await expectLater(
        repo.save({
          ...record(),
          'items': jsonDecode(saved['items_json'] as String),
        }, id: id),
        throwsA(isA<ValidationError>()),
      );
    },
  );

  test(
    'missing product global identity never falls back to a reused name',
    () async {
      final product = await fixture.db.insert('lab_products', {
        'name': 'Product A',
        'remote_id': 'original-product',
        'created_at': '2026-01-01',
      });
      final id = await repo.save({...record(), 'product_id': product});
      await fixture.db.update(
        'lab_products',
        {'remote_id': 'replacement-product'},
        where: 'id = ?',
        whereArgs: [product],
      );
      final listed = (await repo.list()).single;
      expect(listed['product_id'], isNull);
      expect(listed['_missing_references'], isTrue);
      await expectLater(
        repo.save(record(), id: id),
        throwsA(isA<ValidationError>()),
      );
      await repo.save({...record(), '_allow_product_unlink': true}, id: id);
      expect((await repo.list()).single['product_id'], isNull);
    },
  );

  test(
    'tombstoned material references stay missing and cannot be saved',
    () async {
      await repo.save(record());
      await fixture.db.update('reference_materials', {
        'deleted_at': '2026-01-01',
      }, where: 'id = 1');
      expect((await repo.list()).single['_missing_references'], isTrue);
      expect(await repo.materials(), isEmpty);
      await expectLater(repo.save(record()), throwsA(isA<ValidationError>()));
    },
  );
}
