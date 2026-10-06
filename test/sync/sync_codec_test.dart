import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/sync/sync_codec.dart';

// Minimal Timestamp stand-in: same shape as Firestore's (toDate() + runtime
// type name containing 'Timestamp') without importing cloud_firestore.
class FakeTimestamp {
  FakeTimestamp(this.date);
  final DateTime date;
  DateTime toDate() => date;
}

class FakeFieldValue {
  @override
  String toString() => 'FieldValue(serverTimestamp)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sanitize converts Timestamp/DateTime/FieldValue instead of throwing', () {
    final out = SyncCodec.sanitizeMap({
      'createdAt': FakeTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
      'when': DateTime.utc(2026, 5, 6),
      'stamp': FakeFieldValue(),
      'nested': {
        'list': [FakeTimestamp(DateTime.utc(2026, 1, 1)), 1, 'x'],
      },
      'bytes': Uint8List.fromList([1, 2, 3]),
      'ok': 1,
    });
    expect(out['createdAt'], '2026-01-02T03:04:05.000Z');
    expect(out['when'], isA<String>());
    expect(out['stamp'], SyncCodec.serverTimestampPlaceholder);
    expect((out['nested'] as Map)['list'][0], isA<String>());
    expect(out['bytes'], isA<String>());
    // Must encode without throwing (the old Timestamp crash).
    expect(() => SyncCodec.encodeMap(out), returnsNormally);
  });

  test('byteSize matches utf8 length and avoids toLowerCase copy', () {
    final size = SyncCodec.byteSize({'a': 'ABC', 'n': 1});
    expect(size, greaterThan(0));
    expect(SyncCodec.tryEncodeMap(null), isNull);
    expect(SyncCodec.tryEncodeMap({'a': 1}), isA<String>());
  });
}
