import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/features/notifications/data/notification_service.dart';
import 'package:material_lab/features/notifications/domain/notification_item.dart';
import 'package:material_lab/features/notifications/domain/push_event.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

Future<int> _insertInspection(
  DatabaseHelper helper, {
  required String entryCode,
  String material = 'Wheat',
}) async {
  final db = await helper.database;
  return db.insert('inspections', {
    'entry_code': entryCode,
    'material_id': 1,
    'material_name': material,
    'material_code': 'W1',
    'inspection_date': '2026-10-11',
    'specialist_name': 'tester',
    'physical_results_json': '{}',
    'chemical_results_json': '{}',
    'physical_reference_json': '{}',
    'chemical_reference_json': '{}',
    'decision_status': 'PENDING',
    'snapshot_json': '{}',
    'sample_names_json': '[]',
    'created_by': 0,
    'created_by_name': '',
    'created_at': DateTime.now().toIso8601String(),
    'updated_at': DateTime.now().toIso8601String(),
  });
}

Future<int> _insertLabResult(
  DatabaseHelper helper, {
  String? entryCode,
  String sample = 'Sample A',
}) async {
  final db = await helper.database;
  return db.insert('lab_sample_tests', {
    'analysis_id': 1,
    'source_type': 'raw_material',
    'source_name': 'src',
    'sample_name': sample,
    'entry_code': entryCode,
    'tested_at': DateTime.now().toIso8601String(),
    'created_at': DateTime.now().toIso8601String(),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late NotificationService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_notif');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    final db =
        await helper.database; // creates schema incl. notifications table
    // inspections.material_id is FK-enforced: seed one parent material.
    await db.insert('reference_materials', {
      'material_name': 'Wheat',
      'material_code': 'W1',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': DateTime.now().toIso8601String(),
      'active': 1,
    });
    service = NotificationService(
      dbHelper: helper,
      metadata: SyncMetadata(helper),
    );
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('inserted inspection is detected once, then quiet', () async {
    await _insertInspection(helper, entryCode: 'E-001');

    final first = await service.checkForNew(labEnabled: false);
    expect(first, hasLength(1));
    expect(first.single.type, NotificationType.inspection);
    expect(first.single.entryCode, 'E-001');
    expect(await service.unreadCount(), 1);

    // Second scan: nothing new.
    final second = await service.checkForNew(labEnabled: false);
    expect(second, isEmpty);
    expect(await service.unreadCount(), 1);
  });

  test('stored titles are bilingual (AR and EN)', () async {
    await _insertInspection(helper, entryCode: 'E-040');
    await _insertLabResult(helper, entryCode: 'L-040');

    final found = await service.checkForNew();
    expect(found, hasLength(2));
    for (final item in found) {
      // One stored row must read correctly whatever language is active.
      expect(item.title, contains('•'));
      expect(
        item.title,
        anyOf([
          contains('فحص جديد'),
          contains('فحص خامة جديد'),
          contains('نتيجة معمل'),
          contains('متابعة تحليل منتج'),
        ]),
      );
      expect(
        item.title,
        anyOf([
          contains('New inspection'),
          contains('New material inspection'),
          contains('Lab result'),
          contains('Product analysis follow-up'),
        ]),
      );
    }
  });

  test('inserted lab result is detected with entry code', () async {
    await _insertLabResult(helper, entryCode: 'L-001');

    final found = await service.checkForNew(inspectionEnabled: false);
    expect(found, hasLength(1));
    expect(found.single.type, NotificationType.labResult);
    expect(found.single.entryCode, 'L-001');
  });

  test('both types detected together, newest first', () async {
    await _insertInspection(helper, entryCode: 'E-010');
    await _insertLabResult(helper, entryCode: 'L-010');

    final found = await service.checkForNew();
    expect(found, hasLength(2));
    // Lab row has the higher local id (inserted second).
    expect(found.first.type, NotificationType.labResult);
  });

  test('markAllRead clears the bell count', () async {
    await _insertInspection(helper, entryCode: 'E-020');
    await service.checkForNew(labEnabled: false);
    expect(await service.unreadCount(), 1);

    await service.markAllRead();
    expect(await service.unreadCount(), 0);

    // Rows already seen are not re-reported after mark-all-read.
    expect(await service.checkForNew(labEnabled: false), isEmpty);
  });

  test('raw inspection subtitle carries the supplier handle', () async {
    final db = await helper.database;
    await _insertInspection(helper, entryCode: 'E-050');
    await db.update(
      'inspections',
      {'supplier': 'Supplier X'},
      where: 'entry_code = ?',
      whereArgs: ['E-050'],
    );

    final found = await service.checkForNew(labEnabled: false);
    expect(found, hasLength(1));
    expect(found.single.subtitle, contains('E-050'));
    expect(found.single.subtitle, contains('Supplier X'));
  });

  test(
    'product lab result uses follow-up title with type/by/decision',
    () async {
      final db = await helper.database;
      final now = DateTime.now().toIso8601String();
      final batchId = await _insertInspection(helper, entryCode: 'BATCH-50T');
      final sampleId = await db.insert('product_batch_samples', {
        'batch_id': batchId,
        'sample_no': 1,
        'sample_name': 'Sample 1',
        'tested_by': 0,
        'tested_at': now,
        'decision_status': 'APPROVED',
        'created_at': now,
      });
      await db.insert('lab_sample_tests', {
        'analysis_id': 1,
        'source_type': 'product',
        'source_ref_id': sampleId,
        'source_name': 'Flour 50T',
        'sample_name': 'Sample 1',
        'entry_code': 'BATCH-50T',
        'tested_at': now,
        'created_at': now,
      });

      final found = await service.checkForNew(inspectionEnabled: false);
      expect(found, hasLength(1));
      expect(found.single.title, contains('متابعة تحليل منتج'));
      expect(found.single.subtitle, contains('Flour 50T'));
      expect(found.single.subtitle, contains('مقبول'));
    },
  );

  test('duplicate scans never duplicate stored rows', () async {
    await _insertInspection(helper, entryCode: 'E-030');
    await service.checkForNew(labEnabled: false);
    await service.checkForNew(labEnabled: false);
    expect(await service.recent(), hasLength(1));
  });

  test('concurrent callbacks return one new item across all callers', () async {
    await _insertInspection(helper, entryCode: 'CONCURRENT');
    final results = await Future.wait(
      List.generate(5, (_) => service.checkForNew(labEnabled: false)),
    );
    expect(results.expand((items) => items), hasLength(1));
    expect(await service.recent(), hasLength(1));
  });

  test(
    'a burst larger than the scan limit is drained without skipping rows',
    () async {
      await _insertInspection(helper, entryCode: 'BASE');
      await service.checkForNew(labEnabled: false);
      for (var i = 0; i < 45; i++) {
        await _insertInspection(helper, entryCode: 'BURST-$i');
      }
      final results = <NotificationItem>[];
      for (var i = 0; i < 3; i++) {
        results.addAll(await service.checkForNew(labEnabled: false));
      }
      expect(results, hasLength(45));
      expect(results.map((item) => item.entryCode).toSet(), hasLength(45));
      expect(await service.checkForNew(labEnabled: false), isEmpty);
    },
  );

  test(
    'a remote notification resolves the receiving device local row only',
    () async {
      final id = await _insertInspection(helper, entryCode: 'REMOTE');
      await (await helper.database).update(
        'inspections',
        {'remote_id': 'remote-row-999'},
        where: 'id = ?',
        whereArgs: [id],
      );
      helper.paths.orgId = 'org';
      final event = PushEvent.forRecord(
        organizationId: 'org',
        kind: 'inspection',
        remoteId: 'remote-row-999',
      );
      expect(
        await service.resolvePayload(event.payload),
        '/inspections?highlight=$id',
      );
      expect(
        await service.resolvePayload(
          PushEvent.forRecord(
            organizationId: 'another-org',
            kind: 'inspection',
            remoteId: 'remote-row-999',
          ).payload,
        ),
        isNull,
      );
    },
  );

  test('soft-deleted rows do not become new notifications', () async {
    final id = await _insertInspection(helper, entryCode: 'DELETED');
    await (await helper.database).update(
      'inspections',
      {'deleted_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    expect(await service.checkForNew(labEnabled: false), isEmpty);
  });
}
