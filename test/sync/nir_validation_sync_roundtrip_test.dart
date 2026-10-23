import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/lab/data/nir_validation_repo.dart';
import 'package:material_lab/features/lab/domain/nir_validation_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import 'sync_test_fixture.dart';

class _LiveGuard implements WriteGuard {
  const _LiveGuard(this.session);

  final AppSession session;

  @override
  bool get online => true;
  @override
  String get uid => session.uid;
  @override
  String get organizationId => session.organizationId;
  @override
  String get memberId => session.memberId;
  @override
  String get deviceId => session.deviceId;
  @override
  String get email => session.email;

  @override
  bool allows(String permissionId) => true;
}

/// Full push → pull round-trip for the NIR فلديشن horizon (تصفير):
/// device A records a reset and pushes it as
/// `organizations/{orgId}/labConfig/lc_nir_validation_settings_<id>`;
/// the local rows are then wiped (simulating device B) and the pull restores
/// the horizon — so `getSettings()` on the second device agrees with the
/// first, and the validation computations exclude the same date range.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fx;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late AuditLogger audit;
  late InMemoryDataSource remote;
  late AppSession session;
  late SessionSource source;
  late NirValidationRepo repo;

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();

    session = const AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_admin',
      role: 'admin',
      status: 'active',
      deviceId: 'dev_AAAAAA',
    );
    queue = SyncQueue(fx.helper);
    metadata = SyncMetadata(fx.helper);
    audit = AuditLogger(queue: queue, session: () => session);
    remote = InMemoryDataSource(rolesByUid: const {'uid_admin': 'admin'});
    source = SessionSource.empty(() => session);

    repo = NirValidationRepo(
      dbHelper: fx.helper,
      guard: _LiveGuard(session),
      queue: queue,
      audit: audit,
    );
  });

  tearDown(() async => fx.dispose());

  test('reset push → pull round-trip restores the horizon', () async {
    // ── Device A: record the reset ──
    final settings =
        await repo.resetValidation('2026-01-01', note: 'بعد التحسين');
    expect(settings.startDate, '2026-01-01');

    // The queued push payload is a proper labConfig document: its id names
    // the table and the nested payload carries the start date.
    final queued = await fx.db.query(
      'sync_queue',
      where: 'entity_type = ?',
      whereArgs: ['nirValidationSettings'],
    );
    expect(queued, hasLength(1));
    expect('${queued.single['entity_id']}',
        startsWith('lc_nir_validation_settings_'));

    // ── Push worker: the doc lands on the remote with the full envelope ──
    final push = await PushWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      audit: audit,
      source: source,
    ).runOnce();
    expect(push.failed, 0, reason: 'the reset push must not fail');
    final docId = '${queued.single['entity_id']}';
    final doc = await remote.getDocument(
      organizationId: orgId,
      collection: SyncCollection.labConfig,
      documentId: docId,
    );
    expect(doc.exists, isTrue);
    // The nested labConfig payload travels as a JSON string; decode it and
    // confirm it carries the business data.
    final nested = (jsonDecode(doc.data['payload'] as String) as Map);
    expect(nested['start_date'], '2026-01-01');
    expect(nested['reset_note'], 'بعد التحسين');
    expect(doc.data['configType'], 'nir_validation_settings');
    expect(doc.version, 1);

    // ── "Device B": wipe the local rows, then pull the horizon back ──
    await fx.db.delete('nir_validation_settings');
    expect(await repo.getSettings(), isNull);

    final pull = await PullWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      conflicts: ConflictResolver(queue: queue, remote: remote),
      source: source,
    ).runOnce();
    expect(pull.failed, 0, reason: 'the reset doc must pull cleanly');

    final restored = await repo.getSettings();
    expect(restored, isNotNull);
    expect(restored!.startDate, '2026-01-01');
    expect(restored.resetNote, 'بعد التحسين');
    // The labConfig doc id keeps the row↔doc mapping: the pulled row keeps
    // its origin id.
    expect(restored.id, settings.id);

    // A second pull stays a no-op (no phantom rows).
    await PullWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      conflicts: ConflictResolver(queue: queue, remote: remote),
      source: source,
    ).runOnce();
    final rows = await fx.db.query('nir_validation_settings');
    expect(rows, hasLength(1));
  });

  test('a per-item reset round-trips its scope', () async {
    await repo.resetValidation(
      '2026-02-01',
      scope: NirScope.rawMaterial,
      entityId: 7,
      entityName: 'Cement',
      parameter: 'Protein',
    );

    final queued = await fx.db.query(
      'sync_queue',
      where: 'entity_type = ?',
      whereArgs: ['nirValidationSettings'],
    );
    final docId = '${queued.single['entity_id']}';
    await PushWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      audit: audit,
      source: source,
    ).runOnce();
    final doc = await remote.getDocument(
      organizationId: orgId,
      collection: SyncCollection.labConfig,
      documentId: docId,
    );
    final nested = jsonDecode(doc.data['payload'] as String) as Map;
    expect(nested['scope'], 'raw_material');
    expect(nested['entity_id'], 7);
    expect(nested['entity_name'], 'Cement');
    expect(nested['parameter'], 'Protein');

    await fx.db.delete('nir_validation_settings');
    await PullWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      conflicts: ConflictResolver(queue: queue, remote: remote),
      source: source,
    ).runOnce();

    final restored = (await repo.listResetHistory()).single;
    expect(restored.startDate, '2026-02-01');
    expect(restored.scope, 'raw_material');
    expect(restored.entityId, 7);
    expect(restored.entityName, 'Cement');
    expect(restored.parameter, 'Protein');
    // A scoped horizon must never masquerade as the global zero point.
    expect(await repo.getSettings(), isNull);
  });
}
