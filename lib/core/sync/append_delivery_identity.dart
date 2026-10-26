import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'sync_codec.dart';

/// Private acknowledgement hashes: no laboratory results are copied here.
abstract final class AppendDeliveryIdentity {
  static const _metadata = {
    'organizationId',
    'localId',
    'createdBy',
    'createdAt',
    'updatedBy',
    'updatedAt',
    'deviceId',
    'version',
  };
  static String id(String collection, String documentId) =>
      sha256.convert(utf8.encode('$collection/$documentId')).toString();
  static String fingerprint(Map<String, dynamic> data) => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            _canonical({
              for (final entry in SyncCodec.sanitizeMap(data).entries)
                if (!_metadata.contains(entry.key)) entry.key: entry.value,
            }),
          ),
        ),
      )
      .toString();
  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
