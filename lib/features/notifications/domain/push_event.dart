import 'dart:convert';
import 'package:crypto/crypto.dart';

/// A remote identity, never a SQLite id from another device.
///
/// `eventId` (optional) is the stable per-event delivery identity for the
/// central channel: the device display path dedupes against
/// `org/kind/remoteId/eventId` when present, so a quality decision on a
/// record is its own notification while a replayed event never shows twice.
/// Absent eventId keeps the legacy creation-only key.
class PushEvent {
  const PushEvent({
    required this.organizationId,
    required this.kind,
    required this.remoteId,
    this.entryCode = '',
    this.sourceDeviceId = '',
    this.eventId = '',
  });
  final String organizationId;
  final String kind;
  final String remoteId;
  final String entryCode;
  final String sourceDeviceId;
  final String eventId;

  /// Hash the remote key before transport; an entry code can itself be a key.
  factory PushEvent.forRecord({
    required String organizationId,
    required String kind,
    required String remoteId,
    String sourceDeviceId = '',
  }) => PushEvent(
    organizationId: organizationId,
    kind: kind,
    remoteId: identityHash(remoteId),
    sourceDeviceId: sourceDeviceId,
  );
  static String identityHash(String remoteId) =>
      sha256.convert(utf8.encode(remoteId)).toString();

  String get key =>
      '$organizationId/$kind/$remoteId${eventId.isEmpty ? '' : '/$eventId'}';
  String get payload =>
      'mlpush:${base64Url.encode(utf8.encode(jsonEncode(toData())))}';
  Map<String, String> toData() => {
    'organizationId': organizationId,
    'kind': kind,
    'remoteId': remoteId,
    'eventId': eventId,
    'sourceDeviceId': sourceDeviceId,
  };

  static PushEvent? fromData(Map<String, dynamic> data) {
    final org = '${data['organizationId'] ?? ''}';
    final kind = '${data['kind'] ?? ''}';
    final remote = '${data['remoteId'] ?? ''}';
    if (org.isEmpty ||
        remote.isEmpty ||
        !{'inspection', 'lab', 'productSample', 'decision'}.contains(kind)) {
      return null;
    }
    final eventId = '${data['eventId'] ?? ''}';
    if ([
      org,
      remote,
      eventId,
    ].any((value) => value.contains('/') || value.length > 512)) {
      return null;
    }
    return PushEvent(
      organizationId: org,
      kind: kind,
      remoteId: remote,
      entryCode: '${data['entryCode'] ?? ''}',
      sourceDeviceId: '${data['sourceDeviceId'] ?? ''}',
      eventId: eventId,
    );
  }

  static PushEvent? fromPayload(String payload) {
    if (!payload.startsWith('mlpush:') || payload.length > 8192) return null;
    try {
      final data = jsonDecode(
        utf8.decode(base64Url.decode(payload.substring(7))),
      );
      return data is Map<String, dynamic> ? fromData(data) : null;
    } on Object {
      return null;
    }
  }
}
