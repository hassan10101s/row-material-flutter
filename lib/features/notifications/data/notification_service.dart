import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/sync/sync_metadata.dart';
import '../../../core/utils/app_dates.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../lab/core/lab_result_format.dart';
import '../domain/notification_item.dart';
import '../domain/notifications_port.dart';

/// Detects new inspections + lab test results and fans out to the bell list
/// and (Android only) OS notifications.
///
/// Watermarks are `MAX(id)` per table stored in `sync_metadata`, so a pull
/// that inserts rows with fresh local ids and a local save are both caught.
/// Dedupe inside `notifications` is `(type, entry_code, ref_id)`.
class NotificationService implements NotificationsPort {
  NotificationService({required this.dbHelper, required this.metadata});

  final DatabaseHelper dbHelper;
  final SyncMetadata metadata;

  // v3 channel: Android keeps the importance of the channel created on
  // first install, so a new id is the only way to upgrade existing installs
  // from default to high importance (heads-up + sound). v3 also carries the
  // FCM default-channel id declared in AndroidManifest
  // (`com.google.firebase.messaging.default_notification_channel_id`) so
  // killed-app pushes render heads-up with sound too.
  static const String channelId = 'material_lab_new_items_v3';
  static const String channelName = 'New items';
  static const String channelDescription =
      'New inspections and lab results — فحص جديد ونتائج المعمل';
  static const int maxStored = 100;
  static const int scanLimit = 20;

  final FlutterLocalNotificationsPlugin _os = FlutterLocalNotificationsPlugin();
  bool _osReady = false;

  /// Pending deep-link payload from an OS tap when the app was killed.
  /// Consumed once by the router after `AuthState.ready`.
  @override
  String? pendingPayload;

  /// Listeners notified on every push / local-notification tap. The shell
  /// registers one and routes the payload; unlike the one-shot
  /// [pendingPayload] read this keeps working for taps made later in the
  /// session, not only the very first one after a cold start.
  final List<void Function(String payload)> _payloadListeners = [];

  @override
  void addPayloadListener(void Function(String payload) callback) {
    _payloadListeners.add(callback);
  }

  @override
  void removePayloadListener(void Function(String payload) callback) {
    _payloadListeners.remove(callback);
  }

  /// Stashes and broadcasts a tap payload. Safe to call from any platform
  /// (listener failing is swallowed — routing must never crash a tap).
  void deliverPayload(String payload) {
    pendingPayload = payload;
    for (final callback in List.of(_payloadListeners)) {
      try {
        callback(payload);
      } on Object catch (e) {
        debugPrint('[notif] payload listener skipped: $e');
      }
    }
  }

  Future<void> initOs({bool requestPermission = true}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _os.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null && r.payload!.isNotEmpty) {
          deliverPayload(r.payload!);
        }
      },
    );
    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.high,
      );
      await _os
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(channel);
      if (requestPermission) {
        await _os
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
    }
    final launch = await _os.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse?.payload?.isNotEmpty == true) {
      deliverPayload(launch!.notificationResponse!.payload!);
    }
    _osReady = true;
  }

  /// Scan both tables for rows newer than the watermarks, store them, advance
  /// watermarks. Returns the newly found items (newest first).
  /// Never throws: notification detection must not break sync or saves.
  @override
  Future<List<NotificationItem>> checkForNew({
    bool inspectionEnabled = true,
    bool labEnabled = true,
    bool showOs = false,
  }) async {
    try {
      // One shared first-run decision: on a fresh database both watermarks
      // are unseen and the table is empty, and each scan's first-run path
      // seeds its own watermark. Decided once here so the two parallel scans
      // below cannot disagree mid-flight (both re-checking would each take
      // the seeding path and report the same rows twice).
      // The watermarks are read once up front and handed to the scans, so the
      // steady path pays the same two metadata reads as before (not four),
      // and the fresh-database decision is shared instead of raced.
      int? seenInsp;
      int? seenLab;
      bool? sharedFirst;
      if (inspectionEnabled && labEnabled) {
        seenInsp =
            int.tryParse(
              await metadata.get(SyncMetadata.notifSeenInspectionIdKey),
            ) ??
            0;
        seenLab =
            int.tryParse(await metadata.get(SyncMetadata.notifSeenLabIdKey)) ??
            0;
        if (seenInsp == 0 && seenLab == 0) {
          sharedFirst = await _notifCount() == 0;
        }
      }
      // The two scans touch independent tables and watermark keys: run them
      // together instead of paying two sequential round-trip chains on the
      // single FFI isolate (startup + every 30 s tick + every pull).
      final scans = <Future<List<NotificationItem>>>[];
      if (inspectionEnabled) {
        scans.add(
          _scanInspections(firstOverride: sharedFirst, seenOverride: seenInsp),
        );
      }
      if (labEnabled) {
        scans.add(
          _scanLabResults(firstOverride: sharedFirst, seenOverride: seenLab),
        );
      }
      if (scans.isEmpty) return const [];
      final groups = await Future.wait(scans);
      final found = [for (final group in groups) ...group];
      if (found.isEmpty) return const [];
      found.sort((a, b) => b.id.compareTo(a.id));
      if (showOs) await showOsNotifications(found);
      return found;
    } on Object catch (e) {
      debugPrint('[notif] checkForNew skipped: $e');
      return const [];
    }
  }

  Future<List<NotificationItem>> _scanInspections({
    bool? firstOverride,
    int? seenOverride,
  }) async {
    final db = await dbHelper.database;
    final seen =
        seenOverride ??
        (int.tryParse(
              await metadata.get(SyncMetadata.notifSeenInspectionIdKey),
            ) ??
            0);
    // Baseline on first run: don't flood with the whole history.
    final isFirst = firstOverride ?? (seen == 0 && await _notifCount() == 0);
    // Rich body needs verdict + quantities: decision_status / decision_reason /
    // rejected_quantity / quantity / formula_number, plus the product name for
    // product-kind rows (inspections.product_id -> lab_products.name).
    final rows = await db.rawQuery(
      'SELECT i.id, i.entry_code, i.material_name, i.material_code, '
      'i.batch_number, i.supplier, i.inspection_kind, i.created_at, '
      'i.quantity, i.decision_status, i.decision_reason, i.rejected_quantity, '
      'i.formula_number, COALESCE(p.name, \'\') AS product_name '
      'FROM inspections i '
      'LEFT JOIN lab_products p ON p.id = i.product_id '
      '${isFirst ? '' : 'WHERE i.id > ? '} '
      'ORDER BY i.id DESC LIMIT ?',
      isFirst ? [scanLimit] : [seen, scanLimit],
    );
    if (rows.isEmpty) {
      if (isFirst)
        await _setMaxSeen(
          SyncMetadata.notifSeenInspectionIdKey,
          db,
          'inspections',
        );
      return const [];
    }
    if (isFirst) {
      // First ever scan: seed watermark, notify only the single newest row.
      // Returns what was just stored, not a re-read of the shared table: a
      // parallel sibling scan stores into the same table, and re-reading
      // here would report its rows a second time.
      final inserted = await _storeAndAdvance(
        type: NotificationType.inspection,
        rows: rows.take(1).toList(),
        seenKey: SyncMetadata.notifSeenInspectionIdKey,
        maxId: (rows.first['id'] as num).toInt(),
        titleOf: _inspectionTitle,
        subtitleOf: _inspectionSubtitle,
        createdOf: (r) => '${r['created_at'] ?? ''}',
      );
      return inserted;
    }
    return _storeAndAdvance(
      type: NotificationType.inspection,
      rows: rows,
      seenKey: SyncMetadata.notifSeenInspectionIdKey,
      maxId: (rows
          .map((r) => (r['id'] as num).toInt())
          .reduce((a, b) => a > b ? a : b)),
      titleOf: _inspectionTitle,
      subtitleOf: _inspectionSubtitle,
      createdOf: (r) => '${r['created_at'] ?? ''}',
    );
  }

  Future<List<NotificationItem>> _scanLabResults({
    bool? firstOverride,
    int? seenOverride,
  }) async {
    final db = await dbHelper.database;
    final seen =
        seenOverride ??
        (int.tryParse(await metadata.get(SyncMetadata.notifSeenLabIdKey)) ?? 0);
    final isFirst = firstOverride ?? (seen == 0 && await _notifCount() == 0);
    // `created_at` was added late; fall back to `tested_at` for old rows.
    // JOINs resolve who filed the test + the parent batch-sample decision so
    // product follow-ups can carry type / added-by / accepted-or-not, plus the
    // analysis name and the measured result (result_text) so the body is
    // useful without opening the app.
    final rows = await db.rawQuery(
      'SELECT t.id, t.entry_code, t.sample_name, t.source_name, t.source_type, '
      't.source_ref_id, t.tested_by, t.tested_at, t.analysis_id, '
      't.result_text, COALESCE(a.name, \'\') AS analysis_name, '
      'COALESCE(t.created_at, t.tested_at, \'\') AS created_at, '
      'COALESCE(NULLIF(ut.full_name, \'\'), NULLIF(ut.display_name, \'\'), '
      'ut.email, NULLIF(uc.full_name, \'\'), NULLIF(uc.display_name, \'\'), '
      'uc.email, \'\') AS tester_name, '
      's.decision_status AS sample_decision '
      'FROM lab_sample_tests t '
      'LEFT JOIN users ut ON ut.id = t.tested_by OR ut.uid = t.tested_by '
      'LEFT JOIN users uc ON uc.id = t.created_by OR uc.uid = t.created_by '
      'LEFT JOIN lab_analyses a ON a.id = t.analysis_id '
      'LEFT JOIN product_batch_samples s ON s.id = t.source_ref_id '
      'AND t.source_type = \'product\' '
      '${isFirst ? '' : 'WHERE t.id > ?'} '
      'ORDER BY t.id DESC LIMIT ?',
      isFirst ? [scanLimit] : [seen, scanLimit],
    );
    if (rows.isEmpty) {
      if (isFirst)
        await _setMaxSeen(
          SyncMetadata.notifSeenLabIdKey,
          db,
          'lab_sample_tests',
        );
      return const [];
    }
    if (isFirst) {
      // Same as inspections above: return what was stored, never a re-read
      // of the table the sibling scan writes to.
      final inserted = await _storeAndAdvance(
        type: NotificationType.labResult,
        rows: rows.take(1).toList(),
        seenKey: SyncMetadata.notifSeenLabIdKey,
        maxId: (rows.first['id'] as num).toInt(),
        titleOf: _labResultTitle,
        subtitleOf: _labSubtitle,
        createdOf: (r) => '${r['created_at'] ?? r['tested_at'] ?? ''}',
      );
      return inserted;
    }
    return _storeAndAdvance(
      type: NotificationType.labResult,
      rows: rows,
      seenKey: SyncMetadata.notifSeenLabIdKey,
      maxId: (rows
          .map((r) => (r['id'] as num).toInt())
          .reduce((a, b) => a > b ? a : b)),
      titleOf: _labResultTitle,
      subtitleOf: _labSubtitle,
      createdOf: (r) => '${r['created_at'] ?? r['tested_at'] ?? ''}',
    );
  }

  /// Bilingual stored titles (AR • EN): the row is written once but must read
  /// correctly even if the user switches language afterwards, and the same
  /// text is reused for the OS notification body.
  ///
  /// Raw material: `فحص خامة جديد: <material>`.
  /// Product: `تحليل منتج جديد: <product> (<batch>)` so a product batch reads
  /// as product follow-up instead of a generic inspection.
  static String _inspectionTitle(Map<String, Object?> r) {
    final kind = '${r['inspection_kind'] ?? ''}';
    if (kind == 'product') {
      final product = '${r['product_name'] ?? r['material_name'] ?? ''}'.trim();
      final batch = '${r['batch_number'] ?? ''}'.trim();
      final who = batch.isEmpty ? product : '$product ($batch)';
      return 'تحليل منتج جديد • New product analysis: $who';
    }
    return 'فحص خامة جديد • New material inspection: ${r['material_name'] ?? ''}';
  }

  /// Useful one-glance body, bilingual and compact:
  /// raw: `المورد: X • الكمية: Y • <مطابق/مرفوض> [• مرفوض منها: Z]`
  /// product: `<code> • التشغيلة: B • التركيبة: F • <verdict>`
  /// The verdict word comes first in meaning: مطابق للمواصفات vs مرفوض.
  static String _inspectionSubtitle(Map<String, Object?> r) {
    final parts = <String>[];
    final code = '${r['entry_code'] ?? ''}'.trim();
    if (code.isNotEmpty) parts.add(code);
    final kind = '${r['inspection_kind'] ?? ''}';
    if (kind == 'product') {
      final batch = '${r['batch_number'] ?? ''}'.trim();
      if (batch.isNotEmpty) parts.add('التشغيلة: $batch');
      final formula = '${r['formula_number'] ?? ''}'.trim();
      if (formula.isNotEmpty) parts.add('التركيبة: $formula');
      final product = '${r['product_name'] ?? ''}'.trim();
      if (product.isNotEmpty) parts.add('المنتج: $product');
    } else {
      final supplier = '${r['supplier'] ?? ''}'.trim();
      if (supplier.isNotEmpty) parts.add('المورد: $supplier');
      final qty = '${r['quantity'] ?? ''}'.trim();
      if (qty.isNotEmpty) parts.add('الكمية: $qty');
    }
    final headerStatus = '${r['decision_status'] ?? ''}';
    // Products carry no header quality decision: an empty status must not
    // print "pending" — no verdict is coming. Raw rows keep the label.
    if (headerStatus.isNotEmpty || kind != 'product') {
      parts.add(_inspectionDecisionLabel(headerStatus));
    }
    final rejected = '${r['rejected_quantity'] ?? ''}'.trim();
    if (rejected.isNotEmpty && rejected != '0') {
      parts.add('مرفوض منها: $rejected');
    }
    final reason = '${r['decision_reason'] ?? ''}'.trim();
    // Keep the bell line scannable: reason only when it fits.
    if (reason.isNotEmpty && parts.join(' • ').length < 90) {
      parts.add(reason);
    }
    return parts.join(' • ');
  }

  static String _inspectionDecisionLabel(String status) {
    switch (status) {
      case 'APPROVED':
        return 'مطابق للمواصفات • Accepted';
      case 'CONDITIONAL_APPROVAL':
        return 'مقبول مشروط • Conditionally accepted';
      case 'PARTIAL_REJECTION':
        return 'مرفوض جزئياً • Partially rejected';
      case 'FULL_REJECTION':
        return 'مرفوض • Rejected';
      default:
        return status.isEmpty
            ? 'بانتظار القرار • Pending'
            : 'الحالة: $status • $status';
    }
  }

  /// Lab wording: `نتيجة معمل (كيمياء)` for chemistry results, and a
  /// dedicated `متابعة تحليل منتج` title for product analyses so the bell
  /// reads as product follow-up instead of a generic lab result.
  static String _labResultTitle(Map<String, Object?> r) {
    final sourceType = '${r['source_type'] ?? ''}';
    if (sourceType == 'product') {
      final product = '${r['source_name'] ?? ''}'.trim();
      final sample = '${r['sample_name'] ?? ''}'.trim();
      final who = '${product.isEmpty ? '' : '$product – '}$sample'.trim();
      return 'متابعة تحليل منتج • Product analysis follow-up: $who';
    }
    return 'نتيجة معمل (كيمياء) • Lab result (Chemistry): '
        '${r['sample_name'] ?? r['source_name'] ?? ''}';
  }

  /// Product data inside the notification: type, who ran it, the measured
  /// result and accepted-or-not. Raw chemistry: analysis + result + code.
  /// Examples:
  /// - raw: `كيمياء • pH = 7.2 • الخامة: سكر • CODE-12`
  /// - product: `CODE • النوع: عصير • التحليل: Brix = 12.5 • أضافها: أحمد • مقبول`
  static String _labSubtitle(Map<String, Object?> r) {
    final parts = <String>[];
    final code = '${r['entry_code'] ?? ''}'.trim();
    final analysis = '${r['analysis_name'] ?? ''}'.trim();
    // Empty results must stay empty (the format helper returns '-'), or the
    // isNotEmpty guards below would start printing '-' in the body.
    final rawResult = '${r['result_text'] ?? ''}'.trim();
    final result = rawResult.isEmpty ? '' : formatLabResult(rawResult);
    if ('${r['source_type'] ?? ''}' != 'product') {
      final sample = '${r['sample_name'] ?? r['source_name'] ?? ''}'.trim();
      if (sample.isNotEmpty) parts.add('الخامة: $sample');
      if (analysis.isNotEmpty && result.isNotEmpty) {
        parts.add('$analysis = $result');
      } else if (result.isNotEmpty) {
        parts.add('النتيجة: $result');
      } else if (analysis.isNotEmpty) {
        parts.add('التحليل: $analysis');
      }
      if (code.isNotEmpty) parts.add(code);
      return parts.join(' • ');
    }
    if (code.isNotEmpty) parts.add(code);
    final type = '${r['source_name'] ?? ''}'.trim();
    if (type.isNotEmpty) parts.add('النوع: $type');
    if (analysis.isNotEmpty && result.isNotEmpty) {
      parts.add('$analysis = $result');
    } else if (result.isNotEmpty) {
      parts.add('النتيجة: $result');
    }
    final by = '${r['tester_name'] ?? ''}'.trim();
    if (by.isNotEmpty) parts.add('أضافها: $by');
    parts.add(_labDecisionLabel('${r['sample_decision'] ?? ''}'));
    return parts.join(' • ');
  }

  static String _labDecisionLabel(String status) {
    switch (status) {
      case 'APPROVED':
      case 'CONDITIONAL_APPROVAL':
        return 'مقبول • Accepted';
      case 'PARTIAL_REJECTION':
      case 'FULL_REJECTION':
        return 'مرفوض • Rejected';
      default:
        return 'بانتظار القرار • Pending';
    }
  }

  Future<List<NotificationItem>> _storeAndAdvance({
    required NotificationType type,
    required List<Map<String, Object?>> rows,
    required String seenKey,
    required int maxId,
    required String Function(Map<String, Object?>) titleOf,
    required String Function(Map<String, Object?>) subtitleOf,
    required String Function(Map<String, Object?>) createdOf,
  }) async {
    final db = await dbHelper.database;
    final inserted = <NotificationItem>[];
    for (final r in rows) {
      final refId = (r['id'] as num).toInt();
      final entry = '${r['entry_code'] ?? 'row_$refId'}';
      final created = createdOf(r);
      try {
        final rowId = await db.insert('notifications', {
          'type': type.storage,
          'ref_id': refId,
          'entry_code': entry,
          'title': titleOf(r),
          'subtitle': subtitleOf(r),
          'created_at': created,
          'read': 0,
        });
        inserted.add(
          NotificationItem(
            id: rowId,
            type: type,
            refId: refId,
            entryCode: entry,
            title: titleOf(r),
            subtitle: subtitleOf(r),
            createdAt: created,
            read: false,
          ),
        );
      } on Object {
        // Duplicate (type,entry_code,ref_id): already notified.
      }
    }
    await metadata.set(seenKey, '$maxId');
    await _trim();
    return inserted;
  }

  Future<void> _setMaxSeen(String key, dynamic db, String table) async {
    try {
      final rows = await db.rawQuery('SELECT MAX(id) AS m FROM $table');
      final m = (rows.first['m'] as num?)?.toInt() ?? 0;
      await metadata.set(key, '$m');
    } on Object {
      // Table missing on a legacy file: leave watermark at 0.
    }
  }

  Future<int> _notifCount() async {
    try {
      final db = await dbHelper.database;
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM notifications');
      return (rows.first['c'] as num).toInt();
    } on Object {
      return 0;
    }
  }

  Future<void> _trim() async {
    try {
      final db = await dbHelper.database;
      // Count first: the unconditional DELETE scanned the table on every
      // refresh (every 30 s tick, every pull) even though over-limit is rare.
      final count = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM notifications',
      );
      if ((((count.first['c'] as num?)?.toInt() ?? 0)) <= maxStored) return;
      await db.execute(
        'DELETE FROM notifications WHERE id NOT IN '
        '(SELECT id FROM notifications ORDER BY id DESC LIMIT $maxStored)',
      );
    } on Object {
      // Best effort.
    }
  }

  Future<List<NotificationItem>> unread({int limit = 30}) async {
    try {
      final db = await dbHelper.database;
      final rows = await db.query(
        'notifications',
        where: 'read = 0',
        orderBy: 'id DESC',
        limit: limit,
      );
      return rows.map(_fromRow).toList();
    } on Object {
      return const [];
    }
  }

  @override
  Future<List<NotificationItem>> recent({int limit = 30}) async {
    try {
      final db = await dbHelper.database;
      final rows = await db.query(
        'notifications',
        orderBy: 'id DESC',
        limit: limit,
      );
      return rows.map(_fromRow).toList();
    } on Object {
      return const [];
    }
  }

  @override
  Future<int> unreadCount() async {
    try {
      final db = await dbHelper.database;
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM notifications WHERE read = 0',
      );
      return (rows.first['c'] as num).toInt();
    } on Object {
      return 0;
    }
  }

  @override
  Future<void> markRead(int id) async {
    try {
      final db = await dbHelper.database;
      await db.update(
        'notifications',
        {'read': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    } on Object {
      // Best effort.
    }
  }

  /// "Mark all read" clears the bell history entirely (product decision:
  /// once the user acknowledges everything there is nothing left to keep).
  /// Watermarks still advance to MAX(id) so the same rows are never
  /// re-notified on the next scan — the delete is permanent, not a resurface.
  @override
  Future<void> markAllRead() async {
    try {
      final db = await dbHelper.database;
      await db.delete('notifications');
      await _setMaxSeen(
        SyncMetadata.notifSeenInspectionIdKey,
        db,
        'inspections',
      );
      await _setMaxSeen(SyncMetadata.notifSeenLabIdKey, db, 'lab_sample_tests');
    } on Object {
      // Best effort.
    }
  }

  /// Explicit alias for the UI ("Clear all / مسح الكل").
  Future<void> clearAll() => markAllRead();

  /// Bell + OS row for two-way sync problems (conflicts / blocked / failed).
  /// Fired by the sync engine whenever the problem total CHANGES, so the
  /// user learns that records did not reach the other side even on a day
  /// with no new inspections (the pull-driven scans would stay silent).
  /// Dedupe: `entry_code` carries the total, so an unchanged count never
  /// re-inserts (UNIQUE type+entry_code+ref_id rejects it) and a change
  /// always lands a fresh row on top of the bell.
  Future<void> notifySyncProblems({
    required int conflicts,
    required int blocked,
    required int failed,
  }) async {
    final total = conflicts + blocked + failed;
    if (total <= 0) return;
    final title = 'مشاكل مزامنة تحتاج مراجعة • Sync problems';
    final subtitle =
        'تعارضات: $conflicts • محظورة: $blocked • فاشلة: $failed — '
        'Conflicts: $conflicts • Blocked: $blocked • Failed: $failed';
    try {
      final db = await dbHelper.database;
      final rowId = await db.insert('notifications', {
        'type': NotificationType.sync.storage,
        'ref_id': 0,
        'entry_code': 'sync-problems-$total',
        'title': title,
        'subtitle': subtitle,
        'created_at': nowIso(),
        'read': 0,
      });
      await _trim();
      final item = NotificationItem(
        id: rowId,
        type: NotificationType.sync,
        refId: 0,
        entryCode: 'sync-problems-$total',
        title: title,
        subtitle: subtitle,
        createdAt: nowIso(),
        read: false,
      );
      // Own OS slot: reuse the same channel, but the heading must not go
      // through [showOsNotifications]'s inspection/lab branch table.
      if (_osReady && (Platform.isAndroid || Platform.isIOS)) {
        await _os.show(
          item.id,
          'مشاكل مزامنة • Sync problems',
          '$title\n$subtitle',
          NotificationDetails(
            android: AndroidNotificationDetails(
              channelId,
              channelName,
              channelDescription: channelDescription,
              importance: Importance.high,
              priority: Priority.high,
              styleInformation: BigTextStyleInformation('$title\n$subtitle'),
            ),
          ),
          payload: item.payload,
        );
      }
    } on Object catch (e) {
      // Unchanged count (UNIQUE duplicate) or storage outage: not fatal.
      debugPrint('[notif] sync problem skipped: $e');
    }
  }

  NotificationItem _fromRow(Map<String, Object?> r) => NotificationItem(
    id: (r['id'] as num).toInt(),
    type: NotificationType.fromStorage('${r['type']}'),
    refId: (r['ref_id'] as num?)?.toInt() ?? 0,
    entryCode: '${r['entry_code'] ?? ''}',
    title: '${r['title'] ?? ''}',
    subtitle: '${r['subtitle'] ?? ''}',
    createdAt: '${r['created_at'] ?? ''}',
    read: (r['read'] as num?)?.toInt() == 1,
  );

  /// Show one OS notification per new item (Android only, capped at 5).
  /// The stored row id is the Android id, so a batch never overwrites itself
  /// and re-scans of the same item update the same slot. Bodies use
  /// BigText so the useful details (supplier • qty • verdict • result) are
  /// fully expandable in the shade, not truncated to one line.
  Future<void> showOsNotifications(List<NotificationItem> items) async {
    if (!_osReady) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    for (final item in items.take(5)) {
      try {
        final heading = item.type == NotificationType.inspection
            ? (item.title.startsWith('تحليل منتج جديد')
                  ? 'تحليل منتج جديد • New product analysis'
                  : 'فحص خامة جديد • New material inspection')
            : item.title.startsWith('متابعة تحليل منتج')
            ? 'متابعة تحليل منتج • Product follow-up'
            : 'نتيجة معمل (كيمياء) • Lab result (Chemistry)';
        final body = '${item.title}\n${item.subtitle}'.trim();
        // Tray accent matches the bell: danger red when rejected, info blue
        // when accepted, default (palette primary) otherwise. OS accents are
        // not theme-aware, but the brand hues must stay in one place.
        final accent = item.isRejected
            ? AppColors.danger
            : item.isAccepted
            ? AppColors.info
            : null;
        await _os.show(
          item.id,
          heading,
          body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              channelId,
              channelName,
              channelDescription: channelDescription,
              importance: Importance.high,
              priority: Priority.high,
              styleInformation: BigTextStyleInformation(body),
              color: accent,
            ),
          ),
          payload: item.payload,
        );
      } on Object catch (e) {
        debugPrint('[notif] os show skipped: $e');
      }
    }
  }

  /// Single-shot renderer for FCM pushes (foreground handler + any
  /// server-driven alert). Separated from [showOsNotifications] so the FCM
  /// path never depends on the bell scan having run.
  Future<void> showOsNotificationsFromPush({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_osReady) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final text = '$title $body';
      final accent = text.contains('مرفوض') || text.contains('Rejected')
          ? AppColors.danger
          : (text.contains('مطابق') ||
                text.contains('مقبول') ||
                text.contains('Accepted'))
          ? AppColors.info
          : null;
      await _os.show(
        DateTime.now().microsecondsSinceEpoch ~/ 1000,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: body.isEmpty
                ? null
                : BigTextStyleInformation(body),
            color: accent,
          ),
        ),
        payload: payload,
      );
    } on Object catch (e) {
      debugPrint('[notif] push show skipped: $e');
    }
  }

  /// Parse `inspection:12` / `lab:34` / `sync:*` payloads.
  static ({String route, String? highlight, int? tab})? routeForPayload(
    String payload,
  ) {
    final parts = payload.split(':');
    if (parts.length != 2) return null;
    final id = parts[1];
    if (parts[0] == 'inspection') {
      return (route: '/inspections', highlight: id, tab: null);
    }
    if (parts[0] == 'lab') {
      return (route: '/lab', highlight: id, tab: 0);
    }
    if (parts[0] == 'sync') {
      return (route: '/sync', highlight: null, tab: null);
    }
    return null;
  }
}
