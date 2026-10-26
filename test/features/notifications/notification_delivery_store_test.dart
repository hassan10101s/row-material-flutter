import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/features/notifications/data/notification_delivery_store.dart';
import 'package:material_lab/features/notifications/domain/push_event.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends AppPaths {
  _Paths(this.root);
  final Directory root;
  @override
  Future<Directory> appSupportRoot() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  late NotificationDeliveryStore store;
  final event = PushEvent.forRecord(
    organizationId: 'org',
    kind: 'inspection',
    remoteId: 'private-entry-code',
    sourceDeviceId: 'writer',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('notification_delivery_');
    store = NotificationDeliveryStore(
      paths: _Paths(root),
      factory: databaseFactoryFfi,
    );
    await store.bind(
      const PushBinding(
        organizationId: 'org',
        uid: 'viewer',
        deviceId: 'phone',
      ),
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test(
    'push and poll racing for the same record acquire one delivery',
    () async {
      final results = await Future.wait([
        store.claim(event),
        store.claim(event),
        store.claim(event),
      ]);
      expect(results.where((claimed) => claimed), hasLength(1));
      await store.complete(event);
      expect(await store.claim(event), isFalse);
    },
  );
  test('acknowledgements survive a terminated process', () async {
    expect(await store.claim(event), isTrue);
    await store.complete(event);
    await store.close();
    store = NotificationDeliveryStore(
      paths: _Paths(root),
      factory: databaseFactoryFfi,
    );
    expect(await store.claim(event), isFalse);
    expect((await store.binding())!.deviceId, 'phone');
  });
  test('failed rendering can retry without a permanently lost alert', () async {
    expect(await store.claim(event), isTrue);
    await store.release(event);
    expect(await store.claim(event), isTrue);
  });
  test(
    'old organizations, own saves and revoked local binding stay quiet',
    () async {
      expect(
        await store.claim(
          PushEvent.forRecord(
            organizationId: 'other',
            kind: 'inspection',
            remoteId: 'row',
          ),
        ),
        isFalse,
      );
      expect(
        await store.claim(
          PushEvent.forRecord(
            organizationId: 'org',
            kind: 'inspection',
            remoteId: 'row',
            sourceDeviceId: 'phone',
          ),
        ),
        isFalse,
      );
      await store.bind(null);
      expect(await store.claim(event), isFalse);
    },
  );
  test(
    'the background handler respects the bound reading permissions',
    () async {
      await store.bind(
        const PushBinding(
          organizationId: 'org',
          uid: 'viewer',
          deviceId: 'phone',
          samples: false,
        ),
      );
      expect(await store.claim(event), isFalse);
      expect(
        await store.claim(
          PushEvent.forRecord(
            organizationId: 'org',
            kind: 'lab',
            remoteId: 'row',
          ),
        ),
        isTrue,
      );
    },
  );
  test('transport uses opaque identities and stable Android IDs', () {
    final roundTrip = PushEvent.fromPayload(event.payload)!;
    expect(roundTrip.key, event.key);
    expect(event.toData().toString(), isNot(contains('private-entry-code')));
    expect(event.toData().containsKey('entryCode'), isFalse);
    expect(
      NotificationDeliveryStore.notificationId(event),
      NotificationDeliveryStore.notificationId(roundTrip),
    );
    expect(
      NotificationDeliveryStore.notificationId(event),
      inInclusiveRange(0, 0x7fffffff),
    );
    expect(PushEvent.fromPayload('mlpush:invalid'), isNull);
  });
}
