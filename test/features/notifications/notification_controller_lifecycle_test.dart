import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/notifications/domain/notification_item.dart';
import 'package:material_lab/features/notifications/domain/notifications_port.dart';
import 'package:material_lab/features/notifications/presentation/notification_controller.dart';
import 'package:mocktail/mocktail.dart';

class _Notifications extends Mock implements NotificationsPort {}

void main() {
  const item = NotificationItem(
    id: 1,
    type: NotificationType.inspection,
    refId: 1,
    entryCode: 'SAMPLE',
    title: 'Inspection',
    subtitle: '',
    createdAt: '',
    read: false,
  );

  for (final markAll in [false, true]) {
    test(
      '${markAll ? 'mark all' : 'mark one'} skips reload after sign-out',
      () async {
        final service = _Notifications();
        final write = Completer<void>();
        when(() => service.markRead(item.id)).thenAnswer((_) => write.future);
        when(service.markAllRead).thenAnswer((_) => write.future);
        when(service.recent).thenAnswer((_) async => [item]);
        when(service.unreadCount).thenAnswer((_) async => 1);
        final controller = NotificationController(service);
        addTearDown(controller.dispose);

        final pending = markAll
            ? controller.markAllRead()
            : controller.markRead(item);
        controller.resetForSession();
        write.complete();
        await pending;

        expect(controller.items, isEmpty);
        expect(controller.unread, 0);
        verifyNever(service.recent);
        verifyNever(service.unreadCount);
      },
    );
  }
}
