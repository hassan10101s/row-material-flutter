import 'dart:convert';

import 'remote_data_source.dart';

/// In-memory [RemoteDataSource] used by the sync tests and by the offline
/// demo mode. It mirrors the Firestore semantics the engine relies on:
/// `version` monotonicity, permission checks by role and the 900 kB limit.
class InMemoryDataSource implements RemoteDataSource {
  InMemoryDataSource({this.rolesByUid = const {}, this.fresh = true});

  /// `organizations/{orgId}/{collection}/{docId}`.
  /// `organizations/{orgId}/{collection}/{docId}` → document fields.
  final Map<String, Map<String, dynamic>> documents = {};

  final Map<String, String> rolesByUid;

  bool fresh;

  bool configured = true;
  bool signedIn = true;
  bool offline = false;

  final List<RemoteDocument> registeredDevices = [];
  final List<String> removedDevices = [];

  static const int maxPayloadBytes = 900000;

  /// Server clock of the double.
  ///
  /// Firestore replaces [FieldTimestampSentinel] with a timestamp it owns and
  /// never lets a client write it, which is exactly what makes the pull cursor
  /// (`orderBy('updatedAt')`, `documentId`) monotonic (plan §9.3). The double
  /// has to do the same, otherwise two writes of the same document keep the
  /// sentinel and the second device never sees the update.
  DateTime _clock = DateTime.utc(2026, 1, 1);

  String _serverNow() =>
      (_clock = _clock.add(const Duration(milliseconds: 1))).toIso8601String();

  /// Substitutes the sentinels the way the server would.
  Map<String, dynamic> _withServerTimestamps(Map<String, dynamic> data) {
    final out = Map<String, dynamic>.from(data);
    for (final field in const ['updatedAt', 'createdAt']) {
      if (out[field] == '__SERVER_TIMESTAMP__') out[field] = _serverNow();
    }
    return out;
  }

  String _key(String orgId, SyncCollection collection, String docId) =>
      '$orgId/${collection.path}/$docId';

  @override
  bool get isConfigured => configured;

  @override
  bool get isSignedIn => signedIn && !offline;

  @override
  Future<bool> isFresh() async => fresh && isSignedIn;

  @override
  Future<PushResult> setDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
    required int baseVersion,
  }) async {
    if (offline) return PushResult.retryable('offline');
    if (!signedIn) return const PushResult.rejected('unauthenticated');
    final bytes = jsonEncode(data).toLowerCase().codeUnits.length;
    if (bytes > maxPayloadBytes) return PushResult.oversized('too large: $bytes');
    final key = _key(organizationId, collection, documentId);
    final existing = documents[key];
    if (existing != null) {
      final currentVersion = (existing['version'] as num?)?.toInt() ?? 0;
      if (currentVersion != baseVersion) {
        return PushResult.rejected(
          'Version conflict: remote=$currentVersion local=$baseVersion',
          remote: existing,
        );
      }
    }
    final payload = _withServerTimestamps(Map<String, dynamic>.from(data))
      ..['version'] = baseVersion + 1;
    documents[key] = payload;
    return PushResult.success(baseVersion + 1, payload: jsonEncode(payload));
  }

  @override
  Future<PushResult> appendDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
  }) async {
    if (offline) return PushResult.retryable('offline');
    if (!signedIn) return const PushResult.rejected('unauthenticated');
    final key = _key(organizationId, collection, documentId);
    if (documents.containsKey(key)) {
      return const PushResult.rejected('append-only document already exists');
    }
    final payload = _withServerTimestamps(Map<String, dynamic>.from(data))
      ..['version'] = 1;
    documents[key] = payload;
    return PushResult.success(1, payload: jsonEncode(payload));
  }

  @override
  Future<RemoteDocument> getDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  }) async {
    if (offline) return RemoteDocument.missing;
    final value = documents[_key(organizationId, collection, documentId)];
    if (value == null) return RemoteDocument.missing;
    return RemoteDocument(
      id: documentId,
      data: Map<String, dynamic>.from(value),
      version: (value['version'] as num?)?.toInt() ?? 1,
      updatedAt: '${value['updatedAt'] ?? ''}',
    );
  }

  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) async {
    if (offline) return const RemotePage([], hasMore: false);
    final prefix = '$organizationId/${collection.path}/';
    final docs = <RemoteDocument>[];
    documents.forEach((key, value) {
      if (!key.startsWith(prefix)) return;
      final id = key.substring(prefix.length);
      final ts = '${value['updatedAt'] ?? ''}';
      if (startAtTs.isNotEmpty && startAtId.isNotEmpty) {
        final cmp = ts.compareTo(startAtTs);
        if (cmp < 0 || (cmp == 0 && id.compareTo(startAtId) <= 0)) return;
      }
      docs.add(RemoteDocument(
        id: id,
        data: Map<String, dynamic>.from(value),
        version: (value['version'] as num?)?.toInt() ?? 1,
        updatedAt: ts,
      ));
    });
    docs.sort((a, b) {
      final cmp = (a.updatedAt ?? '').compareTo(b.updatedAt ?? '');
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    final hasMore = docs.length > limit;
    return RemotePage(docs.take(limit).toList(), hasMore: hasMore);
  }

  @override
  Future<void> deleteTombstone({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  }) async {
    final key = _key(organizationId, collection, documentId);
    final existing = documents[key];
    if (existing == null) return;
    existing['deletedAt'] = _serverNow();
    existing['updatedAt'] = _serverNow();
  }

  @override
  Future<RemoteDocument> readHeartbeat(String organizationId) async {
    if (offline) return RemoteDocument.missing;
    final value = documents[_key(organizationId, SyncCollection.meta, 'state')];
    if (value == null) return RemoteDocument.missing;
    return RemoteDocument(
      id: 'state',
      data: Map<String, dynamic>.from(value),
      version: (value['version'] as num?)?.toInt() ?? 1,
      updatedAt: '${value['lastWriteAt'] ?? ''}',
    );
  }

  @override
  Future<void> registerDevice({
    required String organizationId,
    required String deviceId,
    required Map<String, dynamic> data,
  }) async {
    if (offline) throw StateError('offline');
    if (!signedIn) throw StateError('unauthenticated');
    // `set(..., SetOptions(merge: true))` on the real backend: a partial write
    // only touches the fields it carries, it never drops the others.
    final index = registeredDevices.indexWhere((d) => d.id == deviceId);
    final existing = index == -1
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(registeredDevices[index].data);
    final merged = existing..addAll(data);
    final doc = RemoteDocument(
      id: deviceId,
      data: merged,
      version: ((existing['version'] as num?)?.toInt() ?? 0) + 1,
    );
    if (index == -1) {
      registeredDevices.add(doc);
    } else {
      registeredDevices[index] = doc;
    }
  }

  @override
  Future<void> unregisterDevice({
    required String organizationId,
    required String deviceId,
  }) async {
    removedDevices.add(deviceId);
    registeredDevices.removeWhere((d) => d.id == deviceId);
  }

  @override
  Future<List<RemoteDocument>> listDevices(String organizationId) async =>
      List<RemoteDocument>.from(registeredDevices);

  /// Test helper: simulate a remote write by another device.
  void seed(
    String organizationId,
    SyncCollection collection,
    String documentId,
    Map<String, dynamic> seedData, {
    int version = 1,
    String? updatedAt,
  }) {
    final payload = Map<String, dynamic>.from(seedData)
      ..['version'] = version
      ..['updatedAt'] = updatedAt ?? '2026-01-01T00:00:${(documentId.hashCode % 60).toString().padLeft(2, '0')}.000Z';
    documents[_key(organizationId, collection, documentId)] = payload;
  }
}
