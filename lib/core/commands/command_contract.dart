/// Central command protocol (plan `SYNC_ARCHITECTURE_PLAN_2026-10-25` §6).
///
/// Every local users change travels to the server as a **command**: a request
/// with a fixed `operationId`, an expected version and a hashed payload. The
/// server decides, returns a **receipt**, and the same operationId can be
/// replayed any number of times without producing a second effect
/// («إرسال الطلب نفسه 100 مرة → أثر واحد»).
///
/// Static identity rule (§3): entities are identified by
/// `organizationId + entityId`, where `entityId` is a global id (the sync
/// `remote_id` / document key). SQLite row numbers are NEVER used as shared
/// identity here.
library;

import 'package:crypto/crypto.dart' as crypto;
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';

/// Bump when the wire contract changes; the server refuses anything else
/// (`SCHEMA_VERSION_MISMATCH`).
const int commandSchemaVersion = 2;

/// Command types shipped with [commandSchemaVersion]. The registry is the
/// server-side allow-list AND the client-side builder map — both must agree
/// (§6 step 2: "التحقق من نوع الأمر ونسخة العقد والحقول المسموحة").
///
/// The pilot scope is the inspection family (§14: الدخول عبر أول مسار حقيقي
/// موثق). New entities patch the registry with their own tests before touching
/// the transport.
class CommandTypes {
  static const String domainCommit = 'domain.commit';
  static const String sampleCreate = 'sample.create';
  static const String sampleUpdate = 'sample.update';
  static const String sampleDelete = 'sample.delete';

  static const Set<String> all = {
    sampleCreate,
    sampleUpdate,
    sampleDelete,
    domainCommit,
  };
}

/// Required permission per command type — mirrors
/// `lib/core/auth/permissions.dart` naming; the server re-derives it from the
/// real role, the client only uses it to fail fast locally.
const Map<String, String> commandPermissions = {
  // The server checks every member of the write set independently.
  CommandTypes.domainCommit: 'org.read',
  CommandTypes.sampleCreate: 'samples.create',
  CommandTypes.sampleUpdate: 'samples.update',
  CommandTypes.sampleDelete: 'samples.update',
};

/// Stable server error codes (§6: "توثيق أخطاء الأعمال برموز ثابتة"). English
/// + Arabic message pairs from the server; codes are the only thing the client
/// branches on.
class CommandErrorCodes {
  // Permanent — the worker parks the command, never blind-retries.
  static const String unauthenticated = 'UNAUTHENTICATED';
  static const String membershipPending = 'MEMBERSHIP_PENDING';
  static const String orgSuspended = 'ORG_SUSPENDED';
  static const String permissionDenied = 'PERMISSION_DENIED';
  static const String deviceUntrusted = 'DEVICE_UNTRUSTED';
  static const String readOnlyDevice = 'READ_ONLY_DEVICE';
  static const String wrongOrg = 'WRONG_ORG';
  static const String schemaVersionMismatch = 'SCHEMA_VERSION_MISMATCH';
  static const String badCommandType = 'BAD_COMMAND_TYPE';
  static const String badPayload = 'BAD_PAYLOAD';
  static const String duplicateOperationIdContent =
      'DUPLICATE_OPERATION_ID_CONTENT';
  static const String parentMissingOrDeleted = 'PARENT_MISSING_OR_DELETED';
  static const String parentDeletedCannotLink = 'PARENT_DELETED_CANNOT_LINK';
  static const String parentWrongType = 'PARENT_WRONG_TYPE';
  static const String versionConflict = 'VERSION_CONFLICT';
  static const String deletedCannotModify = 'DELETED_CANNOT_MODIFY';
  static const String notFound = 'NOT_FOUND';
  static const String valueOutOfRange = 'VALUE_OUT_OF_RANGE';
  static const String invalidField = 'INVALID_FIELD';
  static const String internal = 'INTERNAL';
  static const String protocolNotReady = 'PROTOCOL_NOT_READY';

  // Transient — worker retries with backoff.
  static const String unavailable = 'UNAVAILABLE';
  static const String offline = 'OFFLINE';
  static const String cancelled = 'CANCELLED';
}

/// Codes that can never succeed on their own: park, show reason, keep the
/// draft (§5 "حالات التوقف", §12 "رفض الصلاحيات أو تعارض البيانات لا يدخلان
/// إعادة محاولة عمياء بلا نهاية").
const Set<String> commandPermanentErrors = {
  CommandErrorCodes.unauthenticated,
  CommandErrorCodes.membershipPending,
  CommandErrorCodes.orgSuspended,
  CommandErrorCodes.permissionDenied,
  CommandErrorCodes.deviceUntrusted,
  CommandErrorCodes.readOnlyDevice,
  CommandErrorCodes.wrongOrg,
  CommandErrorCodes.schemaVersionMismatch,
  CommandErrorCodes.badCommandType,
  CommandErrorCodes.badPayload,
  CommandErrorCodes.duplicateOperationIdContent,
  CommandErrorCodes.parentMissingOrDeleted,
  CommandErrorCodes.parentDeletedCannotLink,
  CommandErrorCodes.parentWrongType,
  CommandErrorCodes.versionConflict,
  CommandErrorCodes.deletedCannotModify,
  CommandErrorCodes.notFound,
  CommandErrorCodes.valueOutOfRange,
  CommandErrorCodes.invalidField,
  CommandErrorCodes.protocolNotReady,
};

/// `true` for codes where retrying exactly the same request (same
/// `operationId`, same hash) is the correct behavior.
bool isRetryableCommandError(String code) =>
    !commandPermanentErrors.contains(code);

/// Failure translated for the draft list (§5: "مع سبب واضح وبيانات محفوظة").
class CommandFailure {
  const CommandFailure({required this.code, required this.messageAr});

  /// One of [CommandErrorCodes].
  final String code;

  /// Human explanation (already Arabic on the server side).
  final String messageAr;

  bool get isPermanent => commandPermanentErrors.contains(code);

  Map<String, dynamic> toJson() => {'code': code, 'messageAr': messageAr};

  static CommandFailure fromJson(Map<String, dynamic> json) => CommandFailure(
    code: '${json['code'] ?? CommandErrorCodes.internal}',
    messageAr: '${json['messageAr'] ?? ''}',
  );
}

/// The request body sent to the server (§6 contract). Immutable once built:
/// a re-run of the worker sends the SAME map, byte for byte.
class CommandEnvelope {
  const CommandEnvelope({
    required this.operationId,
    required this.organizationId,
    required this.commandType,
    required this.entityId,
    required this.expectedVersion,
    required this.payload,
    required this.payloadHash,
    required this.deviceId,
    this.dependencies = const <String, String>{},
    this.schemaVersion = commandSchemaVersion,
  });

  static const Uuid _uuid = Uuid();

  /// Globally unique per effect. Replayed verbatim by the worker; the server
  /// uses it + [payloadHash] as the idempotency receipt key.
  final String operationId;
  final String organizationId;

  final int schemaVersion;

  /// One of [CommandTypes].
  final String commandType;

  /// Global entity identity (`remote_id` style), never a SQLite row number.
  final String entityId;

  /// Optimistic concurrency against the server version of [entityId].
  final int expectedVersion;

  /// Business payload (camelCase, same field whitelists as the server).
  final Map<String, dynamic> payload;

  /// sha256 of the canonical JSON of [payload]. A replay with a different
  /// payload for the same [operationId] is rejected by the server.
  final String payloadHash;

  /// Registered writing device (`device_registry.dart`) — the server checks
  /// it against the registration it owns, never trusting the value alone.
  final String deviceId;

  /// Global ids needed for creation (e.g. parent inspection). The server
  /// re-validates each inside its transaction.
  final Map<String, String> dependencies;

  Map<String, dynamic> toWire() => {
    'operationId': operationId,
    'organizationId': organizationId,
    'schemaVersion': schemaVersion,
    'commandType': commandType,
    'entityId': entityId,
    'expectedVersion': expectedVersion,
    'payload': payload,
    'payloadHash': payloadHash,
    'deviceId': deviceId,
    'dependencies': dependencies,
  };

  static CommandEnvelope fromWire(Map<String, dynamic> json) => CommandEnvelope(
    operationId: '${json['operationId'] ?? ''}',
    organizationId: '${json['organizationId'] ?? ''}',
    schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
    commandType: '${json['commandType'] ?? ''}',
    entityId: '${json['entityId'] ?? ''}',
    expectedVersion: (json['expectedVersion'] as num?)?.toInt() ?? 0,
    payload:
        (json['payload'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{},
    payloadHash: '${json['payloadHash'] ?? ''}',
    deviceId: '${json['deviceId'] ?? ''}',
    dependencies:
        (json['dependencies'] as Map?)?.cast<String, String>() ??
        const <String, String>{},
  );

  /// A fresh envelope for [payload] with a new operationId and correct hash.
  factory CommandEnvelope.create({
    required String organizationId,
    required String commandType,
    required String entityId,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    required String deviceId,
    Map<String, String> dependencies = const {},
  }) => CommandEnvelope(
    operationId: _uuid.v4(),
    organizationId: organizationId,
    commandType: commandType,
    entityId: entityId,
    expectedVersion: expectedVersion,
    payload: payload,
    payloadHash: hashPayload(payload),
    deviceId: deviceId,
    dependencies: dependencies,
  );
}

/// Canonical JSON: keys sorted recursively so both sides hash the same bytes.
String hashPayload(Map<String, dynamic> payload) {
  final canonical = _canonicalize(payload);
  return crypto.sha256
      .convert(utf8.encode(_jsonEncodeCanonical(canonical)))
      .toString();
}

Object? _canonicalize(Object? value) {
  if (value == null) return ['null'];
  if (value is bool) return ['boolean', value];
  if (value is String) return ['string', value];
  if (value is num) {
    final number = value.toDouble();
    if (!number.isFinite ||
        (number == number.truncateToDouble() &&
            number.abs() > 9007199254740991)) {
      throw const FormatException('Unsupported JSON number');
    }
    final bytes = ByteData(8)
      ..setFloat64(0, number == 0 ? 0 : number, Endian.big);
    return [
      'number',
      bytes.buffer
          .asUint8List()
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join(),
    ];
  }
  if (value is List) return ['array', value.map(_canonicalize).toList()];
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return [
      'object',
      [
        for (final key in keys) [key, _canonicalize(value[key])],
      ],
    ];
  }
  throw const FormatException('Unsupported JSON value');
}

/// jsonEncode is already deterministic for the canonical map above (keys stay
/// in insertion order), so a plain encode of the canonical copy is stable.
String _jsonEncodeCanonical(Object? value) => jsonEncode(value);

/// The server's reply (§6 result contract):
/// `operationId, status, entityId, committedVersion, committedAt,
/// changeSequence`.
class CommandResult {
  const CommandResult({
    required this.operationId,
    required this.status,
    required this.entityId,
    this.committedVersion,
    this.committedAt,
    this.changeSequence,
    this.failure,
  });

  static const String statusApproved = 'approved';
  static const String statusRejected = 'rejected';

  final String operationId;
  final String status;

  /// Global identity of the created/updated entity — the server may revisit
  /// it (e.g. confirming the entity id a client proposed).
  final String entityId;

  /// Version the server committed; null only on failure.
  final int? committedVersion;

  /// Server clock ISO timestamp of the commit — the ONLY time the UI may use.
  final String? committedAt;

  /// Per-organization change-sequence of the event emitted with this commit.
  final int? changeSequence;

  final CommandFailure? failure;

  bool get isApproved =>
      status == statusApproved &&
      failure == null &&
      committedVersion != null &&
      committedVersion! > 0 &&
      operationId.isNotEmpty &&
      entityId.isNotEmpty &&
      changeSequence != null &&
      changeSequence! > 0 &&
      DateTime.tryParse(committedAt ?? '') != null;

  Map<String, dynamic> toJson() => {
    'operationId': operationId,
    'status': status,
    'entityId': entityId,
    'committedVersion': committedVersion,
    'committedAt': committedAt,
    'changeSequence': changeSequence,
    'error': failure?.toJson(),
  };

  static CommandResult fromJson(Map<String, dynamic> json) {
    final failureJson = json['error'] as Map?;
    final opId = '${json['operationId'] ?? ''}';
    return CommandResult(
      operationId: opId,
      status: '${json['status'] ?? statusRejected}',
      entityId: '${json['entityId'] ?? ''}',
      committedVersion: (json['committedVersion'] as num?)?.toInt(),
      committedAt: json['committedAt'] as String?,
      // Firestore stores numbers as int; REST roundtrips may produce double.
      changeSequence: _intOrNull(json['changeSequence']),
      failure: failureJson == null
          ? null
          : CommandFailure.fromJson(failureJson.cast<String, dynamic>()),
    );
  }

  /// A local representative of "transport never answered" — the outbox row
  /// stays pending/retrying; no receipt is fabricated (§12 no false approval).
  static CommandResult retryable(
    String operationId,
    String code,
    String message,
  ) => CommandResult(
    operationId: operationId,
    status: statusRejected,
    entityId: '',
    failure: CommandFailure(code: code, messageAr: message),
  );

  static int? _intOrNull(Object? value) => (value as num?)?.toInt();
}

/// A queue belongs to one live organization/account/device, never only to a DB file.
class CommandScope {
  const CommandScope(this.organizationId, this.uid, this.deviceId);
  final String organizationId;
  final String uid;
  final String deviceId;
  bool owns(String org, String user) => organizationId == org && uid == user;
}
