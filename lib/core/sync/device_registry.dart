import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/app_session.dart';
import '../auth/permissions.dart';
import '../auth/session_source.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'audit_logger.dart';
import 'remote/remote_data_source.dart';
import 'sync_metadata.dart';

/// One row of `organizations/{orgId}/devices`.
@immutable
class DeviceEntry {
  const DeviceEntry({
    required this.id,
    required this.uid,
    this.email = '',
    this.displayName = '',
    this.platform = '',
    this.role = '',
    this.readOnly = false,
    this.status = 'active',
    this.lastSeenAt,
    this.registeredAt,
    this.isCurrentDevice = false,
  });

  factory DeviceEntry.fromRemote(RemoteDocument document, {String? currentDeviceId}) {
    final d = document.data;
    return DeviceEntry(
      id: document.id,
      uid: '${d['uid'] ?? ''}',
      email: '${d['email'] ?? ''}',
      displayName: '${d['displayName'] ?? ''}',
      platform: '${d['platform'] ?? ''}',
      role: '${d['role'] ?? ''}',
      readOnly: d['readOnly'] == true,
      status: '${d['status'] ?? 'active'}',
      lastSeenAt: DateTime.tryParse('${d['lastSeenAt'] ?? ''}'),
      registeredAt: DateTime.tryParse('${d['registeredAt'] ?? ''}'),
      isCurrentDevice: document.id == currentDeviceId,
    );
  }

  final String id;
  final String uid;
  final String email;
  final String displayName;
  final String platform;
  final String role;

  /// `device.readOnly = (role == 'viewer')` (plan §14-P8.3): the device may not
  /// write anything, whatever the role of its owner changes to later.
  final bool readOnly;

  /// `active` | `revoked`. A revoked device is signed out; its document is
  /// never deleted because the audit trail points at it.
  final String status;

  final DateTime? lastSeenAt;
  final DateTime? registeredAt;
  final bool isCurrentDevice;

  bool get revoked => status == 'revoked';
}

/// The device inventory of the organization (plan §9.4 step 4 / §14-P9.1).
///
/// * registers this device once per organization and refreshes `lastSeenAt`,
/// * lists the other devices for an administrator,
/// * revokes a device (that is what "sign out of this device only" does on the
///   server side - the Rules refuse `delete`, so the entry is marked instead).
class DeviceRegistry {
  DeviceRegistry({
    required this.remote,
    required this.metadata,
    required this.audit,
    required this.source,
    this.registrationInterval = const Duration(hours: 12),
  });

  final RemoteDataSource remote;
  final SyncMetadata metadata;
  final AuditLogger audit;
  final SessionSource source;

  /// A device document is a `SetOptions(merge: true)` write, so refreshing it
  /// too often would be pure noise on the server.
  final Duration registrationInterval;

  static const String lastRegisteredAtKey = 'device_last_registered_at';

  AppSession get _session => source.session;

  bool get isSignedIn => _session.isSignedIn && _session.organizationId.isNotEmpty;

  bool get canListDevices => _session.can(Permission.devicesRead);

  /// Registers the current device if it was never registered for this
  /// organization, or if the last registration is older than
  /// [registrationInterval]. Never throws: a device that cannot register keeps
  /// working offline, it is simply not listed on the other devices.
  Future<bool> ensureRegistered({bool force = false}) async {
    if (!isSignedIn || !remote.isSignedIn) return false;
    final organizationId = _session.organizationId;
    final deviceId = _session.deviceId;
    if (deviceId.isEmpty) return false;

    if (!force) {
      final last = DateTime.tryParse(await metadata.get(lastRegisteredAtKey));
      if (last != null &&
          DateTime.now().difference(last) < registrationInterval &&
          await metadata.get('device_registered_org') == organizationId) {
        return false;
      }
    }

    final now = nowIso();
    await remote.registerDevice(
      organizationId: organizationId,
      deviceId: deviceId,
      data: {
        'uid': _session.uid,
        'email': _session.email,
        'displayName': _session.displayName.isNotEmpty ? _session.displayName : _session.email,
        'platform': Platform.operatingSystem,
        'role': _session.role,
        'readOnly': _session.readOnlyDevice || _session.role == AppRoles.viewer,
        'lastSeenAt': now,
      },
    );
    await metadata.set(lastRegisteredAtKey, now);
    await metadata.set('device_registered_org', organizationId);
    return true;
  }

  /// Heartbeat: cheap `lastSeenAt` refresh, no re-registration.
  Future<void> touchLastSeen() async {
    if (!isSignedIn || !remote.isSignedIn) return;
    if (_session.deviceId.isEmpty) return;
    try {
      await remote.registerDevice(
        organizationId: _session.organizationId,
        deviceId: _session.deviceId,
        data: {
          'uid': _session.uid,
          'lastSeenAt': nowIso(),
        },
      );
    } on Object catch (e) {
      debugPrint('[devices] lastSeenAt refresh skipped: $e');
    }
  }

  /// The organization device inventory, newest first. Empty when the session
  /// may not read it.
  Future<List<DeviceEntry>> list() async {
    if (!isSignedIn || !remote.isSignedIn || !canListDevices) return const [];
    final docs = await remote.listDevices(_session.organizationId);
    final entries = docs
        .map((d) => DeviceEntry.fromRemote(d, currentDeviceId: _session.deviceId))
        .toList()
      ..sort((a, b) {
        final at = a.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
    return entries;
  }

  /// Signs a device out. The local session of *this* device is the caller's
  /// business; this only records the decision on the server and in the audit
  /// trail, so the other sessions of the same member keep working.
  ///
  /// The Rules forbid deleting a device document (it is part of the audit
  /// trail), so a revoked device stays listed with `status = 'revoked'`.
  Future<void> revoke(String deviceId, {String? reason}) async {
    if (!isSignedIn || !remote.isSignedIn) return;
    final organizationId = _session.organizationId;
    final isSelf = deviceId == _session.deviceId;
    if (!isSelf && !canListDevices) return;
    await remote.registerDevice(
      organizationId: organizationId,
      deviceId: deviceId,
      data: {
        'uid': isSelf ? _session.uid : '',
        'status': 'revoked',
        'revokedAt': nowIso(),
        'revokedReason': reason ?? (isSelf ? 'signed_out_this_device' : 'revoked_by_admin'),
      },
    );
    if (isSelf) {
      await metadata.remove(lastRegisteredAtKey);
      await metadata.remove('device_registered_org');
    }
  }

  /// "Sign out of this device only" (plan §14-P9.1): revoke this device on the
  /// server, then let the caller clear the local session. The member stays
  /// active everywhere else - nothing about `users/{uid}` or the other devices
  /// is touched.
  Future<void> signOutThisDevice() async {
    final deviceId = _session.deviceId;
    if (deviceId.isEmpty || !isSignedIn) return;
    try {
      await revoke(deviceId);
    } on Object catch (e) {
      debugPrint('[devices] revoke before sign-out skipped: $e');
    }
    // The audit entry is a best effort too: it needs a local transaction and
    // the queue, and a failing write must not block the sign-out itself.
    try {
      final db = await audit.queue.dbHelper.database;
      await tracedTransaction(db, 'devices.signOutAudit', (txn) => audit.log(
            txn,
            action: AuditAction.deviceRegistered,
            entityType: 'device',
            entityId: deviceId,
            details: <String, dynamic>{'event': 'signed_out_this_device'},
          ));
    } on Object catch (e) {
      debugPrint('[devices] sign-out audit skipped: $e');
    }
  }
}
