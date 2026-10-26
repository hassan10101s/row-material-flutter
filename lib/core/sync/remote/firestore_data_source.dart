import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../entity_registry.dart';
import '../sync_codec.dart';
import '../sync_cursor_time.dart';
import '../remote_write_policy.dart';
import '../append_delivery_identity.dart';
import 'remote_data_source.dart';

/// Firestore implementation of the remote seam (plan §5/P6).
///
/// Everything Firestore-specific lives in this file — `push_worker` and
/// `pull_worker` only know [RemoteDataSource], so replacing this class with a
/// Django/PostgreSQL backend changes nothing else.
class FirestoreDataSource implements RemoteDataSource {
  FirestoreDataSource({this.firestore, this.auth});

  final FirebaseFirestore? firestore;
  final FirebaseAuth? auth;

  /// Firestore rejects documents above 1 MiB; the plan sets an earlier,
  /// actionable limit (900 kB) so the conflict is recorded as
  /// `payload_too_large` instead of failing as a hard error.
  static const int maxPayloadBytes = 900000;

  FirebaseFirestore get _db {
    final db = firestore;
    if (db == null) {
      throw const RemoteNotConfiguredException('Firestore is not initialized');
    }
    return db;
  }

  @override
  bool get isConfigured => firestore != null && auth != null;

  @override
  bool get isSignedIn => isConfigured && auth?.currentUser != null;

  @override
  Future<bool> isFresh() async {
    if (!isConfigured) return false;
    final user = auth?.currentUser;
    if (user == null) return false;
    final token = await user.getIdToken(true);
    return token != null && token.isNotEmpty;
  }

  CollectionReference<Map<String, dynamic>> _orgCollection(
    String organizationId,
    SyncCollection collection,
  ) => _db
      .collection('organizations')
      .doc(organizationId)
      .collection(collection.path);

  @override
  Future<PushResult> setDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
    required int baseVersion,
  }) async {
    // Sanitized first: a stray Timestamp/DateTime in the queued payload must
    // size-estimate instead of throwing `Instance of 'Timestamp'`.
    final safeData = SyncCodec.sanitizeMap(data);
    final bytes = SyncCodec.byteSize(safeData);
    if (bytes > maxPayloadBytes) {
      return PushResult.oversized(
        'Document exceeds $maxPayloadBytes bytes ($bytes)',
      );
    }
    final ref = _orgCollection(organizationId, collection).doc(documentId);
    Map<String, dynamic>? current;
    try {
      return await _db.runTransaction<PushResult>((transaction) async {
        final snapshot = await transaction.get(ref);
        current = snapshot.exists
            ? SyncCodec.sanitizeMap(
                Map<String, dynamic>.from(snapshot.data() ?? {}),
              )
            : null;
        final plan = RemoteWritePolicy.plan(
          organizationId: organizationId,
          data: safeData,
          baseVersion: baseVersion,
          current: current,
        );
        if (plan.refusal != null) return plan.refusal!;
        if (!plan.alreadyApplied) {
          final size = SyncCodec.byteSize(plan.payload);
          if (size > maxPayloadBytes) {
            return PushResult.oversized(
              'Document exceeds $maxPayloadBytes bytes ($size)',
            );
          }
          final payload = _materialize(plan.payload, version: plan.version);
          if (snapshot.exists) {
            transaction.update(ref, payload);
          } else {
            transaction.set(ref, payload);
          }
        }
        return PushResult.success(
          plan.version,
          payload: SyncCodec.encodeMap(plan.payload),
        );
      });
    } on FirebaseException catch (e) {
      return _classify(e, current);
    } on Object catch (e) {
      return PushResult.retryable('$e');
    }
  }

  @override
  Future<PushResult> appendDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
  }) async {
    final safeData = SyncCodec.sanitizeMap(data);
    final size = SyncCodec.byteSize(safeData);
    if (size > maxPayloadBytes) {
      return PushResult.oversized(
        'Document exceeds $maxPayloadBytes bytes ($size)',
      );
    }
    final uid = auth?.currentUser?.uid;
    if (uid == null) return PushResult.retryable('unauthenticated');
    final ref = _orgCollection(organizationId, collection).doc(documentId);
    final receipt = _orgCollection(organizationId, SyncCollection.syncReceipts)
        .doc(uid)
        .collection('entries')
        .doc(AppendDeliveryIdentity.id(collection.path, documentId));
    final fingerprint = AppendDeliveryIdentity.fingerprint(safeData);
    final receiptData = <String, dynamic>{
      'fingerprint': fingerprint,
      'deviceId': safeData['deviceId'],
      'collectionId': collection.path,
      'documentId': documentId,
      'version': 1,
      'createdAt': FieldValue.serverTimestamp(),
    };
    PushResult acknowledged() => PushResult.success(
      1,
      payload: SyncCodec.encodeMap({...safeData, 'version': 1}),
    );
    try {
      return await _db.runTransaction<PushResult>((transaction) async {
        final saved = await transaction.get(receipt);
        if (saved.exists) {
          return saved.data()?['fingerprint'] == fingerprint
              ? acknowledged()
              : PushResult.rejected('Append-only identity collision');
        }
        transaction.set(ref, _materialize(safeData, version: 1));
        transaction.set(receipt, receiptData);
        return acknowledged();
      });
    } on FirebaseException catch (error) {
      // Legacy writes predate receipts. A member who can read the existing
      // record can prove an identical retry without changing that record.
      if (error.code == 'permission-denied' || error.code == 'already-exists') {
        try {
          final saved = await ref.get();
          if (saved.exists &&
              AppendDeliveryIdentity.fingerprint(
                    SyncCodec.sanitizeMap(saved.data() ?? {}),
                  ) ==
                  fingerprint) {
            return await _db.runTransaction<PushResult>((transaction) async {
              final existing = await transaction.get(receipt);
              if (existing.exists &&
                  existing.data()?['fingerprint'] != fingerprint) {
                return PushResult.rejected('Append-only identity collision');
              }
              if (!existing.exists) transaction.set(receipt, receiptData);
              return acknowledged();
            });
          }
        } on Object {
          /* A real denial stays visible; never weaken access. */
        }
      }
      return _classify(error, null);
    } on Object catch (error) {
      return PushResult.retryable('$error');
    }
  }

  @override
  Future<RemoteDocument> getDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  }) async {
    try {
      final snapshot = await _orgCollection(
        organizationId,
        collection,
      ).doc(documentId).get(const GetOptions(source: Source.server));
      if (!snapshot.exists) return RemoteDocument.missing;
      return _toRemote(snapshot);
    } on Object {
      // Enrollment must distinguish a denied lookup (e.g. revoked ownership)
      // from a genuinely missing device. Other sync callers retain their
      // existing missing-document fallback.
      if (collection == SyncCollection.devices) rethrow;
      return RemoteDocument.missing;
    }
  }

  @override
  Future<RemoteDocument> findProductBatchHeader({
    required String organizationId,
    required String deviceId,
    required int localId,
  }) async {
    if (deviceId.isEmpty || localId <= 0) return RemoteDocument.missing;
    final matches = await _orgCollection(organizationId, SyncCollection.samples)
        .where('deviceId', isEqualTo: deviceId)
        .where('localId', isEqualTo: localId)
        .where('inspectionKind', isEqualTo: 'product')
        .limit(2)
        .get(const GetOptions(source: Source.server));
    if (matches.docs.length != 1) return RemoteDocument.missing;
    return _toRemote(matches.docs.single);
  }

  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) async {
    try {
      Query<Map<String, dynamic>> query =
          _orgCollection(organizationId, collection)
              .orderBy('updatedAt', descending: false)
              .orderBy(FieldPath.documentId, descending: false);
      if (startAtTs.isNotEmpty && startAtId.isNotEmpty) {
        final anchor = SyncCursorTime.parse(startAtTs);
        query = query.startAfter([
          Timestamp(anchor.seconds, anchor.nanoseconds),
          startAtId,
        ]);
      }
      final snapshot = await query
          .limit(limit + 1)
          .get(const GetOptions(source: Source.server));
      final docs = snapshot.docs.take(limit).toList();
      return RemotePage(
        docs.map(_toRemote).toList(),
        hasMore: snapshot.docs.length > limit,
      );
    } on FirebaseException {
      // Do NOT swallow auth failures as an empty page: that made the badge
      // report "Synced" while the device saw zero remote documents (wrong org,
      // inactive member, missing samples.read). PullWorker records the error
      // into last_error (audit worker opts out via quietPermissionErrors).
      rethrow;
    }
  }

  @override
  Future<void> deleteTombstone({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  }) async {
    final ref = _orgCollection(organizationId, collection).doc(documentId);
    await _db.runTransaction<void>((transaction) async {
      final current = await transaction.get(ref);
      if (!current.exists || current.data()?['deletedAt'] != null) return;
      transaction.update(ref, <String, dynamic>{
        'deletedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'version': ((current.data()?['version'] as num?)?.toInt() ?? 0) + 1,
        'deviceId': current.data()?['deviceId'],
        'updatedBy': auth?.currentUser?.uid,
      });
    });
  }

  @override
  Future<RemoteDocument> readHeartbeat(String organizationId) async {
    try {
      final snapshot = await _db
          .collection('organizations')
          .doc(organizationId)
          .collection('meta')
          .doc('state')
          .get(const GetOptions(source: Source.server));
      if (!snapshot.exists) return RemoteDocument.missing;
      return _toRemote(snapshot);
    } on Object {
      return RemoteDocument.missing;
    }
  }

  @override
  Future<void> writeHeartbeat({
    required String organizationId,
    required Map<String, dynamic> data,
  }) async {
    // Merge-set so concurrent bumps from two devices never clobber each
    // other into a missing document; the Rules only allow the four listed
    // keys plus `lastWriteBy == auth.uid`, which the push worker provides.
    final payload = <String, dynamic>{
      'lastWriteAt': FieldValue.serverTimestamp(),
      if (data['lastWriteBy'] != null) 'lastWriteBy': data['lastWriteBy'],
      if (data['lastEntity'] != null) 'lastEntity': data['lastEntity'],
      if (data['version'] != null) 'version': data['version'],
    };
    await _db
        .collection('organizations')
        .doc(organizationId)
        .collection('meta')
        .doc('state')
        .set(payload, SetOptions(merge: true));
  }

  @override
  Future<void> registerDevice({
    required String organizationId,
    required String deviceId,
    required Map<String, dynamic> data,
  }) async {
    await _orgCollection(organizationId, SyncCollection.devices)
        .doc(deviceId)
        .set(
          _materialize(SyncCodec.sanitizeMap(data), version: 1),
          SetOptions(merge: true),
        );
  }

  @override
  Future<void> unregisterDevice({
    required String organizationId,
    required String deviceId,
  }) async {
    try {
      await _orgCollection(
        organizationId,
        SyncCollection.devices,
      ).doc(deviceId).delete();
    } on FirebaseException catch (e) {
      if (!_isPermissionDenied(e)) rethrow;
    }
  }

  @override
  Future<List<RemoteDocument>> listDevices(String organizationId) async {
    try {
      final snapshot = await _orgCollection(
        organizationId,
        SyncCollection.devices,
      ).get();
      return snapshot.docs.map(_toRemote).toList();
    } on Object {
      return const [];
    }
  }

  /// `users/{uid}` is a top-level collection (see `firestore.rules`).
  DocumentReference<Map<String, dynamic>> userDoc(String uid) =>
      _db.collection('users').doc(uid);

  // ── References used by the auth/organization flows (plan §8.3, §8.5) ──────
  DocumentReference<Map<String, dynamic>> organizationRef(
    String organizationId,
  ) => _db.collection('organizations').doc(organizationId);

  DocumentReference<Map<String, dynamic>> organizationMetaRef(
    String organizationId,
  ) => _db
      .collection('organizations')
      .doc(organizationId)
      .collection('meta')
      .doc('state');

  DocumentReference<Map<String, dynamic>> memberRef(
    String organizationId,
    String memberId,
  ) => _orgCollection(organizationId, SyncCollection.members).doc(memberId);

  DocumentReference<Map<String, dynamic>> inviteRef(
    String organizationId,
    String inviteKey,
  ) => _orgCollection(organizationId, SyncCollection.invites).doc(inviteKey);

  /// Members are read straight (ordered by e-mail) by the members screen.
  CollectionReference<Map<String, dynamic>> membersCollection(
    String organizationId,
  ) => _orgCollection(organizationId, SyncCollection.members);

  DocumentReference<Map<String, dynamic>> auditLogRef(
    String organizationId,
    String logId,
  ) => _orgCollection(organizationId, SyncCollection.auditLogs).doc(logId);

  WriteBatch newBatch() => _db.batch();

  FieldValue serverTimestamp() => FieldValue.serverTimestamp();

  static RemoteDocument _toRemote(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data() ?? const <String, dynamic>{};
    final updatedAt = data['updatedAt'];
    return RemoteDocument(
      id: snapshot.id,
      // Deep-convert server `Timestamp` objects (deletedAt, activatedAt, ...)
      // to ISO strings: the sqflite layer only accepts num / String / Uint8List.
      data: _sqliteSafe(Map<String, dynamic>.from(data)),
      version: (data['version'] as num?)?.toInt() ?? 1,
      cursorTimestamp: updatedAt is Timestamp
          ? SyncCursorTime(updatedAt.seconds, updatedAt.nanoseconds).iso
          : null,
      updatedAt: updatedAt is Timestamp
          ? updatedAt.toDate().toIso8601String()
          : (updatedAt == null ? null : '$updatedAt'),
      exists: snapshot.exists,
    );
  }

  /// Recursively replace every value the local SQLite store cannot persist.
  static Map<String, dynamic> _sqliteSafe(Map<String, dynamic> data) => {
    for (final entry in data.entries) entry.key: _sqliteSafeValue(entry.value),
  };

  static Object? _sqliteSafeValue(Object? value) {
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is DateTime) return value.toIso8601String();
    if (value is List) return [for (final v in value) _sqliteSafeValue(v)];
    if (value is Map) {
      return {
        for (final e in value.entries) '${e.key}': _sqliteSafeValue(e.value),
      };
    }
    // Defensive: FieldValue / GeoPoint / Blob must never reach SQLite or JSON.
    // Delegate to the shared codec so pull and push agree on the string form.
    if (value != null && value is! num && value is! bool && value is! String) {
      return SyncCodec.sanitizeValue(value);
    }
    return value;
  }

  /// Replace the sentinel with real server timestamps.
  static Map<String, dynamic> _materialize(
    Map<String, dynamic> data, {
    required int version,
  }) {
    final out = Map<String, dynamic>.from(data);
    for (final entry in out.entries.toList()) {
      if (entry.value == FieldTimestampSentinel.value) {
        out[entry.key] = FieldValue.serverTimestamp();
      }
    }
    out['version'] = version;
    return out;
  }

  static PushResult _classify(
    FirebaseException e,
    Map<String, dynamic>? current,
  ) {
    // Belt-and-braces: callers already sanitize, but a raw snapshot must never
    // become JSON-encodable `remote` downstream in PushWorker.
    Map<String, dynamic>? safeRemote;
    if (current != null) {
      try {
        safeRemote = SyncCodec.sanitizeMap(current);
      } catch (_) {
        safeRemote = const <String, dynamic>{};
      }
    }
    switch (e.code) {
      case 'permission-denied':
      case 'unauthenticated':
      case 'failed-precondition':
      case 'invalid-argument':
        return PushResult.rejected(e.message ?? e.code, remote: safeRemote);
      case 'not-found':
        return PushResult.rejected(e.message ?? e.code, remote: null);
      case 'failed-precondition-quota':
      case 'resource-exhausted':
      case 'resource-exhausted-quota':
        return PushResult.rejected(e.message ?? e.code, remote: safeRemote);
      case 'unavailable':
      case 'deadline-exceeded':
      case 'internal':
      default:
        return PushResult.retryable(e.message ?? e.code);
    }
  }

  static bool _isPermissionDenied(FirebaseException e) =>
      e.code == 'permission-denied' || e.code == 'unauthenticated';
}

/// Thrown by the data sources when Firebase is unavailable — the app catches
/// it and switches to degraded/offline mode instead of crashing.
class RemoteNotConfiguredException implements Exception {
  const RemoteNotConfiguredException(this.message);
  final String message;

  @override
  String toString() => 'RemoteNotConfiguredException: $message';
}
