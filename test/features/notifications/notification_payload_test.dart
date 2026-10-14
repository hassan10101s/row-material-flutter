import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/notifications/data/notification_service.dart';
import 'package:material_lab/features/notifications/domain/notification_item.dart';

void main() {
  group('NotificationType', () {
    test('round-trips storage values', () {
      expect(
        NotificationType.fromStorage(NotificationType.inspection.storage),
        NotificationType.inspection,
      );
      expect(
        NotificationType.fromStorage(NotificationType.labResult.storage),
        NotificationType.labResult,
      );
      expect(NotificationType.fromStorage('unknown'), NotificationType.inspection);
    });

    test('payload encodes type and ref id', () {
      const item = NotificationItem(
        id: 1,
        type: NotificationType.inspection,
        refId: 42,
        entryCode: 'E-1',
        title: 't',
        subtitle: 's',
        createdAt: '',
        read: false,
      );
      expect(item.payload, 'inspection:42');
      const lab = NotificationItem(
        id: 2,
        type: NotificationType.labResult,
        refId: 7,
        entryCode: 'E-2',
        title: 't',
        subtitle: 's',
        createdAt: '',
        read: false,
      );
      expect(lab.payload, 'lab:7');
    });
  });

  group('routeForPayload', () {
    test('inspection payload routes to inspections with highlight', () {
      final r = NotificationService.routeForPayload('inspection:12');
      expect(r?.route, '/inspections');
      expect(r?.highlight, '12');
    });

    test('lab payload routes to lab tab 0 with highlight', () {
      final r = NotificationService.routeForPayload('lab:34');
      expect(r?.route, '/lab');
      expect(r?.highlight, '34');
      expect(r?.tab, 0);
    });

    test('malformed payloads return null', () {
      expect(NotificationService.routeForPayload(''), isNull);
      expect(NotificationService.routeForPayload('inspection'), isNull);
      expect(NotificationService.routeForPayload('other:1'), isNull);
    });
  });
}
