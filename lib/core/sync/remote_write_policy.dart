import 'remote/remote_data_source.dart';
import 'sync_codec.dart';

/// One transport contract shared by Firestore and the offline test server.
/// The server owns original identity; a receiver's SQLite ids are not edits
/// to the record's creator or original local id.
class RemoteWritePlan {
  const RemoteWritePlan({
    required this.payload,
    required this.version,
    this.alreadyApplied = false,
    this.refusal,
  });
  final Map<String, dynamic> payload;
  final int version;
  final bool alreadyApplied;
  final PushResult? refusal;
}

abstract final class RemoteWritePolicy {
  static const immutableFields = {
    'organizationId',
    'localId',
    'createdBy',
    'createdAt',
  };
  static const _transportFields = {
    ...immutableFields,
    'version',
    'updatedAt',
    'updatedBy',
    'deviceId',
  };

  static RemoteWritePlan plan({
    required String organizationId,
    required Map<String, dynamic> data,
    required int baseVersion,
    Map<String, dynamic>? current,
  }) {
    RemoteWritePlan reject(String message) => RemoteWritePlan(
      payload: const {},
      version: 0,
      refusal: PushResult.rejected(message, remote: current),
    );
    if (data['organizationId'] != organizationId ||
        (current != null && current['organizationId'] != organizationId)) {
      return reject('Organization identity mismatch');
    }
    final payload = Map<String, dynamic>.from(data);
    if (current == null) {
      // A previously acknowledged row can be restored into an empty remote
      // database. A missing document always needs a complete v1 envelope.
      if (payload['localId'] == null) {
        return reject('Missing original local id');
      }
      final actor = payload['updatedBy'];
      if (actor is! String || actor.isEmpty) {
        return reject('Missing write actor');
      }
      final creator = payload['createdBy'];
      if (creator != null && creator is! String) {
        return reject('Invalid creator identity');
      }
      payload['createdBy'] = creator is String && creator.isNotEmpty
          ? creator
          : actor;
      payload['createdAt'] = SyncCodec.serverTimestampPlaceholder;
      payload['version'] = 1;
      return RemoteWritePlan(payload: payload, version: 1);
    }
    if (current['deletedAt'] != null && data['deletedAt'] == null) {
      return reject('Deleted records cannot be resurrected');
    }
    final version = (current['version'] as num?)?.toInt() ?? 0;
    if (version != baseVersion) {
      // A response may be lost after commit. A retry of identical business
      // content acknowledges the existing write instead of inventing a race.
      if (equivalent(data, current)) {
        return RemoteWritePlan(
          payload: current,
          version: version,
          alreadyApplied: true,
        );
      }
      return reject('Version conflict: remote=$version local=$baseVersion');
    }
    for (final field in immutableFields) {
      payload.remove(field);
    }
    // A cross-device UUID is also stable once one has been published.
    if ('${current['remoteId'] ?? ''}'.isNotEmpty) payload.remove('remoteId');
    payload['version'] = version + 1;
    return RemoteWritePlan(payload: payload, version: version + 1);
  }

  static bool equivalent(
    Map<String, dynamic> incoming,
    Map<String, dynamic> stored,
  ) => incoming.entries
      .where(
        (entry) =>
            !_transportFields.contains(entry.key) &&
            !(entry.key == 'remoteId' &&
                '${stored['remoteId'] ?? ''}'.isNotEmpty),
      )
      .every(
        (entry) =>
            (entry.key == 'deletedAt' &&
                entry.value == SyncCodec.serverTimestampPlaceholder &&
                stored[entry.key] != null) ||
            _same(entry.value, stored[entry.key]),
      );

  static bool _same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => i).every((i) => _same(a[i], b[i]));
    }
    return a == b;
  }
}
