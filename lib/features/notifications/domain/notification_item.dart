/// Mobile-only new-item notification (inspection or lab test result).
library;

/// Stable type stored in `notifications.type`.
enum NotificationType {
  inspection('inspection'),
  labResult('labResult');

  const NotificationType(this.storage);
  final String storage;

  static NotificationType fromStorage(String value) =>
      value == 'labResult' ? NotificationType.labResult : NotificationType.inspection;
}

/// One row shown in the bell list. `refId` is the local SQLite row id,
/// `entryCode` is the cross-device dedupe key.
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.type,
    required this.refId,
    required this.entryCode,
    required this.title,
    required this.subtitle,
    required this.createdAt,
    required this.read,
  });

  final int id;
  final NotificationType type;
  final int refId;
  final String entryCode;
  final String title;
  final String subtitle;
  final String createdAt;
  final bool read;

  /// Deep-link payload used by OS notifications and in-app taps.
  /// Format: `inspection:<refId>` or `lab:<refId>`.
  String get payload =>
      '${type == NotificationType.inspection ? 'inspection' : 'lab'}:$refId';

  /// Product batch analysis (vs raw-material inspection). Title prefix is
  /// written once by `NotificationService._inspectionTitle`, so it survives
  /// language switches.
  bool get isProductInspection =>
      type == NotificationType.inspection &&
      title.startsWith('تحليل منتج جديد');

  /// Verdict derived from the stored bilingual subtitle (single source of
  /// truth — no extra column needed). Rejected is checked first because
  /// "مرفوض" never coexists with "مقبول" in one body.
  bool get isRejected =>
      title.contains('مرفوض') ||
      subtitle.contains('مرفوض') ||
      title.contains('Rejected') ||
      subtitle.contains('Rejected');

  bool get isAccepted =>
      !isRejected &&
      (title.contains('مطابق') ||
          subtitle.contains('مطابق') ||
          title.contains('مقبول') ||
          subtitle.contains('مقبول') ||
          title.contains('Accepted') ||
          subtitle.contains('Accepted'));
}
