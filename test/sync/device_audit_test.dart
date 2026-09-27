import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/audit_trail.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/device_registry.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_dates.dart';

import 'sync_test_fixture.dart';

/// Plan §14-P9: the device registry, "sign out of this device only", the audit
/// trail read path (filters + paging) and its retention.
/// What the Rules answer to a member without `audit.read`: the read of
/// `organizations/{orgId}/auditLogs` is refused, the rest of the cycle is fine.
class _DenyAuditLogs extends InMemoryDataSource {
  _DenyAuditLogs() : super(rolesByUid: const {'uid_admin': 'admin'});

  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) {
    if (collection == SyncCollection.auditLogs) {
      return Future<RemotePage>.error(
        StateError('PERMISSION_DENIED: missing permission audit.read on auditLogs'),
      );
    }
    return super.listSince(
      organizationId: organizationId,
      collection: collection,
      startAtTs: startAtTs,
      startAtId: startAtId,
      limit: limit,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fixture;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late AuditLogger audit;
  late InMemoryDataSource remote;
  late AppSession session;

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    queue = SyncQueue(fixture.helper);
    metadata = SyncMetadata(fixture.helper);
    remote = InMemoryDataSource(rolesByUid: const {'uid_admin': 'admin'});
    session = const AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_1',
      role: 'admin',
      status: 'active',
      deviceId: 'dev_1',
    );
    audit = AuditLogger(queue: queue, session: () => session);
  });

  tearDown(() async => fixture.dispose());

  SessionSource source() => SessionSource.empty(() => session);
  DeviceRegistry registry() => DeviceRegistry(
        remote: remote,
        metadata: metadata,
        audit: audit,
        source: source(),
      );
  AuditTrail trail() => AuditTrail(audit: audit, metadata: metadata, devices: registry());
  PullWorker auditPuller() => PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: queue, remote: remote),
        source: source(),
        entities: [auditLogEntity],
        quietPermissionErrors: true,
        marksPullTimestamp: false,
      );

  // ── device registry ──────────────────────────────────────────────────────

  group('device registry', () {
    test('registers this device with the identity of the live session', () async {
      final registered = await registry().ensureRegistered();

      expect(registered, isTrue);
      final doc = remote.registeredDevices.singleWhere((d) => d.id == 'dev_1');
      expect(doc.data['uid'], 'uid_admin');
      expect(doc.data['email'], 'admin@material-lab.test');
      expect(doc.data['role'], 'admin');
      expect(doc.data['readOnly'], isFalse);
      expect(doc.data['platform'], isNotEmpty);
      expect(doc.data['lastSeenAt'], isNotNull);
    });

    test('a viewer device is registered as read-only', () async {
      session = const AppSession(
        uid: 'uid_viewer',
        email: 'viewer@material-lab.test',
        organizationId: orgId,
        memberId: 'member_2',
        role: 'viewer',
        status: 'active',
        deviceId: 'dev_9',
        readOnlyDevice: true,
      );
      await registry().ensureRegistered();

      final doc = remote.registeredDevices.singleWhere((d) => d.id == 'dev_9');
      expect(doc.data['role'], 'viewer');
      expect(doc.data['readOnly'], isTrue,
          reason: 'plan §14-P8.3: device.readOnly = (role == viewer)');
    });

    test('registration is throttled and never duplicates the document', () async {
      final devices = registry();
      expect(await devices.ensureRegistered(), isTrue);
      expect(await devices.ensureRegistered(), isFalse,
          reason: 'inside the interval: nothing to do');
      expect(remote.registeredDevices.where((d) => d.id == 'dev_1'), hasLength(1));

      // `force` is what the organization binder uses after an org switch.
      expect(await devices.ensureRegistered(force: true), isTrue);
      expect(remote.registeredDevices.where((d) => d.id == 'dev_1'), hasLength(1));
    });

    test('the registration window is stored per organization', () async {
      await registry().ensureRegistered();
      expect(await metadata.get(DeviceRegistry.lastRegisteredAtKey), isNotEmpty);
      expect(await metadata.get('device_registered_org'), orgId);
    });

    test('a partial refresh keeps the other fields (set merge semantics)',
        () async {
      final devices = registry();
      await devices.ensureRegistered();
      await devices.touchLastSeen();

      final doc = remote.registeredDevices.singleWhere((d) => d.id == 'dev_1');
      expect(doc.data['uid'], 'uid_admin');
      expect(doc.data['role'], 'admin',
          reason: 'a heartbeat only carries uid + lastSeenAt');
      expect(doc.data['readOnly'], isFalse);
    });

    test('lists the organization devices, newest first', () async {
      await remote.registerDevice(
        organizationId: orgId,
        deviceId: 'dev_old',
        data: {
          'uid': 'uid_other',
          'platform': 'linux',
          'lastSeenAt': nowIsoAt(DateTime.now().subtract(const Duration(days: 3))),
        },
      );
      await registry().ensureRegistered();

      final entries = await registry().list();
      expect(entries.map((e) => e.id), ['dev_1', 'dev_old']);
      expect(entries.first.isCurrentDevice, isTrue);
      expect(entries.last.isCurrentDevice, isFalse);
    });

    test('a device without devices.read gets an empty list', () async {
      session = const AppSession(
        uid: 'uid_qc',
        email: 'qc@material-lab.test',
        organizationId: orgId,
        memberId: 'member_3',
        role: 'quality_manager',
        status: 'active',
        deviceId: 'dev_1',
      );
      expect(registry().canListDevices, isFalse);
      expect(await registry().list(), isEmpty);
    });

    test('signing out of this device revokes it and keeps the member active',
        () async {
      await registry().ensureRegistered();
      final devices = registry();
      await devices.signOutThisDevice();

      final doc = remote.registeredDevices.singleWhere((d) => d.id == 'dev_1');
      expect(doc.data['status'], 'revoked');
      expect(doc.data['revokedAt'], isNotNull);
      // The Rules forbid deleting a device document; it is part of the trail.
      expect(remote.removedDevices, isEmpty);
      // The member is untouched: no role change, no other device revoked.
      expect(doc.data['role'], 'admin');
      expect(remote.registeredDevices.where((d) => d.id != 'dev_1'), isEmpty);
      // The next session on this device must register itself again.
      expect(await metadata.get(DeviceRegistry.lastRegisteredAtKey), isEmpty);
    });

    test('revoking another device needs devices.read', () async {
      await remote.registerDevice(
        organizationId: orgId,
        deviceId: 'dev_2',
        data: {'uid': 'uid_other'},
      );
      session = const AppSession(
        uid: 'uid_qc',
        email: 'qc@material-lab.test',
        organizationId: orgId,
        memberId: 'member_3',
        role: 'quality_manager',
        status: 'active',
        deviceId: 'dev_1',
      );
      await registry().revoke('dev_2');

      final doc = remote.registeredDevices.singleWhere((d) => d.id == 'dev_2');
      expect(doc.data['status'], isNull,
          reason: 'a member without devices.read cannot revoke anyone');
    });

    test('an offline device does not register and does not throw', () async {
      remote.offline = true;
      expect(await registry().ensureRegistered(), isFalse);
      expect(remote.registeredDevices, isEmpty);
    });
  });

  // ── audit trail: read path, filters, paging ──────────────────────────────

  group('audit trail', () {
    /// A row with an explicit timestamp - `AuditLogger` always stamps "now",
    /// which cannot express the date-range filters.
    Future<int> insertAudit(String action, String entityType, DateTime occurredAt) =>
        fixture.db.insert('audit_logs', {
          'user_id': 'uid_admin',
          'user_name': 'Admin',
          'organization_id': orgId,
          'action': action,
          'entity_type': entityType,
          'entity_id': 'e_$action',
          'device_id': 'dev_1',
          'occurred_at': nowIsoAt(occurredAt),
          'version': 1,
          'sync_state': 'synced',
        });

    Future<void> log(String action, String entityType) async {
      await fixture.transaction((txn) => audit.log(
            txn,
            action: action,
            entityType: entityType,
            entityId: 'e_$action',
          ));
    }

    test('the page is empty until something is written', () async {
      final page = await trail().page();
      expect(page.entries, isEmpty);
      expect(page.total, 0);
      expect(page.hasMore, isFalse);
    });

    test('filters by entityType and action', () async {
      await log(AuditAction.sampleCreated, 'sample');
      await log(AuditAction.sampleCreated, 'sample');
      await log(AuditAction.qcApproved, 'qualityCheck');
      await log(AuditAction.settingsUpdated, 'settings');

      expect((await trail().page(entityType: 'sample')).total, 2);
      expect((await trail().page(action: AuditAction.qcApproved)).total, 1);
      expect(
        (await trail().page(entityType: 'sample', action: AuditAction.qcApproved)).total,
        0,
        reason: 'the filters combine with AND',
      );
    });

    test('filters by date range inclusively', () async {
      await insertAudit(AuditAction.sampleCreated, 'sample',
          DateTime.now().subtract(const Duration(days: 10)));
      await insertAudit(AuditAction.sampleCreated, 'sample', DateTime.now());
      final today = DateTime.now();

      final page = await trail().page(
        from: DateTime(today.year, today.month, today.day, 0, 0, 0),
        to: DateTime(today.year, today.month, today.day, 23, 59, 59),
      );
      expect(page.total, 1, reason: 'only the entry written today is inside the range');
      expect(page.entries.single['action'], AuditAction.sampleCreated);

      expect((await trail().page(from: DateTime(2000))).total, 2);
    });

    test('the date filter is not broken by the storage format', () async {
      // Regression: `occurred_at` is stored as `yyyy-MM-dd HH:mm:ss`; a filter
      // built with `toIso8601String()` compares a space with a `T` and silently
      // matches nothing.
      await insertAudit(AuditAction.sampleCreated, 'sample', DateTime.now());
      final now = DateTime.now();
      expect((await trail().page(from: now.subtract(const Duration(minutes: 5)))).total, 1);
      expect((await trail().page(to: now.add(const Duration(minutes: 5)))).total, 1);
    });

    test('pages with an offset and reports whether more exist', () async {
      final base = DateTime(2026, 3, 1);
      for (var i = 0; i < 5; i++) {
        await insertAudit('action_$i', 'sample', base.add(Duration(minutes: i)));
      }
      final t = trail();

      final first = await t.page(limit: 2);
      expect(first.entries, hasLength(2));
      expect(first.total, 5);
      expect(first.hasMore, isTrue);

      final last = await t.page(limit: 2, offset: 4);
      expect(last.entries, hasLength(1));
      expect(last.hasMore, isFalse);

      // Newest first.
      expect(first.entries.first['action'], 'action_4');
    });

    test('exposes the facets for the filter dropdowns', () async {
      await log(AuditAction.sampleCreated, 'sample');
      await log(AuditAction.qcApproved, 'qualityCheck');

      final page = await trail().page();
      expect(page.entityTypes, containsAll(['sample', 'qualityCheck']));
      expect(page.actions, containsAll([AuditAction.sampleCreated, AuditAction.qcApproved]));
    });

    test('a device without audit.read reads nothing at all', () async {
      await log(AuditAction.sampleCreated, 'sample');
      session = const AppSession(
        uid: 'uid_viewer',
        email: 'viewer@material-lab.test',
        organizationId: orgId,
        memberId: 'member_2',
        role: 'viewer',
        status: 'active',
        deviceId: 'dev_1',
        readOnlyDevice: true,
      );
      final t = trail();
      expect(t.canRead, isFalse);
      final page = await t.page();
      expect(page.entries, isEmpty);
      expect(page.total, 0);
    });
  });

  // ── retention ────────────────────────────────────────────────────────────

  group('retention', () {
    Future<void> row(String state, int daysAgo) => fixture.db.insert('audit_logs', {
          'user_id': 'uid_admin',
          'organization_id': orgId,
          'action': AuditAction.settingsUpdated,
          'entity_type': 'settings',
          'entity_id': 'org_test',
          'device_id': 'dev_1',
          'occurred_at': nowIsoAt(DateTime.now().subtract(Duration(days: daysAgo))),
          'version': 1,
          'sync_state': state,
        });

    test('runs once a day and can be forced', () async {
      await row('synced', 200);
      final t = trail();

      expect(await t.runRetention(force: true), isTrue);
      expect(await fixture.db.query('audit_logs'), isEmpty);
      expect(await metadata.get(AuditTrail.lastPrunedAtKey), isNotEmpty);

      // A second pass inside the interval does nothing (and does not throw).
      await row('synced', 200);
      expect(await t.runRetention(), isFalse);
      expect(await fixture.db.query('audit_logs'), hasLength(1));
    });

    test('never deletes what the server has not confirmed', () async {
      await row('queued', 200);
      await row('failed', 200);

      await trail().runRetention(force: true);
      expect(await fixture.db.query('audit_logs'), hasLength(2));
    });
  });

  // ── the audit trail of another device ────────────────────────────────────

  group('audit pull', () {
    test('a second device sees the trail of the first one', () async {
      // Device 1 writes and pushes.
      await fixture.transaction((txn) => audit.log(
            txn,
            action: AuditAction.qcApproved,
            entityType: 'qualityCheck',
            entityId: 'qc_1_1',
            details: <String, dynamic>{'decision': 'APPROVED'},
          ));
      await PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: source(),
      ).runOnce();

      // Device 2 has its own database and pulls it.
      final other = await openSyncFixture();
      addTearDown(other.dispose);
      final otherAudit = AuditLogger(
        queue: SyncQueue(other.helper),
        session: () => session,
      );
      final otherRegistry = DeviceRegistry(
        remote: remote,
        metadata: SyncMetadata(other.helper),
        audit: otherAudit,
        source: source(),
      );
      final report = await PullWorker(
        queue: SyncQueue(other.helper),
        metadata: SyncMetadata(other.helper),
        remote: remote,
        conflicts: ConflictResolver(queue: SyncQueue(other.helper), remote: remote),
        source: source(),
        entities: [auditLogEntity],
        quietPermissionErrors: true,
        marksPullTimestamp: false,
      ).runOnce();

      expect(report.applied, 1);
      final rows = await other.db.query('audit_logs');
      expect(rows, hasLength(1));
      expect(rows.single['action'], AuditAction.qcApproved);
      expect(rows.single['entity_type'], 'qualityCheck');
      expect(rows.single['entity_id'], 'qc_1_1');
      expect(rows.single['user_id'], 'uid_admin');
      expect(rows.single['device_id'], 'dev_1');
      expect(rows.single['organization_id'], orgId);
      expect(rows.single['sync_state'], 'synced');
      expect('${rows.single['details_json']}', contains('APPROVED'));

      // The reader shows it, filters included.
      final trailOnDevice2 = AuditTrail(
        audit: otherAudit,
        metadata: SyncMetadata(other.helper),
        devices: otherRegistry,
      );
      expect((await trailOnDevice2.page()).total, 1);
      expect((await trailOnDevice2.page(entityType: 'qualityCheck')).total, 1);
      expect((await trailOnDevice2.page(entityType: 'sample')).total, 0);
    });

    test('pulling the same document twice does not duplicate the row', () async {
      await fixture.transaction((txn) => audit.log(
            txn,
            action: AuditAction.sampleCreated,
            entityType: 'sample',
            entityId: 's_1',
          ));
      await PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: source(),
      ).runOnce();

      final other = await openSyncFixture();
      addTearDown(other.dispose);
      final otherQueue = SyncQueue(other.helper);
      final otherMetadata = SyncMetadata(other.helper);
      final otherAudit = AuditLogger(queue: otherQueue, session: () => session);

      PullWorker puller() => PullWorker(
            queue: otherQueue,
            metadata: otherMetadata,
            remote: remote,
            conflicts: ConflictResolver(queue: otherQueue, remote: remote),
            source: source(),
            entities: [auditLogEntity],
            quietPermissionErrors: true,
            marksPullTimestamp: false,
          );

      await puller().runOnce();
      // Rewind the cursor: the same document is offered again.
      await otherMetadata.setCursor('auditLog', PullCursor('', ''));
      final second = await puller().runOnce();

      expect(second.skipped, 1, reason: 'the natural key device_id + occurred_at matched');
      expect(await other.db.query('audit_logs'), hasLength(1));
      expect(otherAudit, isNotNull);
    });

    test('a permission-denied does not break the cycle', () async {
      // What the Rules answer to a member without `audit.read` on `auditLogs`.
      final denying = _DenyAuditLogs();
      final puller = PullWorker(
        queue: queue,
        metadata: metadata,
        remote: denying,
        conflicts: ConflictResolver(queue: queue, remote: denying),
        source: source(),
        entities: [auditLogEntity],
        quietPermissionErrors: true,
        marksPullTimestamp: false,
      );
      final report = await puller.runOnce();

      expect(report.applied, 0);
      expect(report.error, isNull, reason: 'a permission is not a sync failure');
      expect(await metadata.lastError(), isEmpty);
    });

    test('the audit pass does not move the "last synced" marker', () async {
      await metadata.markPull(DateTime(2026, 1, 1));
      await auditPuller().runOnce();
      expect((await metadata.lastPullAt())?.year, 2026);
    });
  });
}
