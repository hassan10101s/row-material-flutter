import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/sync/audit_trail.dart';
import 'package:material_lab/features/audit/presentation/audit_controller.dart';
import 'package:material_lab/features/audit/presentation/audit/audit_screen.dart';

/// Plan §14-P9.2: the audit screen renders the trail, filters it, pages it, and
/// refuses to show anything without `audit.read`.
///
/// The screen is driven through [AuditTrailReader], so the widget test needs no
/// database; the SQLite side of the trail is covered by
/// `test/sync/device_audit_test.dart`.
class _StubTrail implements AuditTrailReader {
  _StubTrail(this.rows, {this.allowed = true});

  final List<Map<String, Object?>> rows;
  final bool allowed;

  int calls = 0;

  @override
  bool get canRead => allowed;

  @override
  Future<AuditPage> page({
    String? entityType,
    String? action,
    DateTime? from,
    DateTime? to,
    int limit = 200,
    int offset = 0,
  }) async {
    calls++;
    final filtered = rows.where((row) {
      if (entityType != null && row['entity_type'] != entityType) return false;
      if (action != null && row['action'] != action) return false;
      if (from != null && '${row['occurred_at']}'.compareTo(from.toIso8601String()) < 0) {
        return false;
      }
      if (to != null && '${row['occurred_at']}'.compareTo(to.toIso8601String()) > 0) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => '${b['occurred_at']}'.compareTo('${a['occurred_at']}'));
    final page = filtered.skip(offset).take(limit).toList();
    return AuditPage(
      entries: page,
      total: filtered.length,
      offset: offset,
      hasMore: offset + page.length < filtered.length,
      entityTypes: rows.map((r) => '${r['entity_type']}').toSet().toList(),
      actions: rows.map((r) => '${r['action']}').toSet().toList(),
    );
  }
}

Map<String, Object?> _row(String action, String entityType, String occurredAt) => {
      'user_id': 'uid_admin',
      'user_name': 'Admin',
      'organization_id': 'org_test',
      'action': action,
      'entity_type': entityType,
      'entity_id': 'e_$action',
      'device_id': 'dev_1',
      'occurred_at': occurredAt,
      'details_json': '{"decision":"APPROVED"}',
    };

void main() {
  late AuditController controller_;

  Future<void> pumpScreen(
    WidgetTester tester,
    AuditTrailReader trail, {
    int pageSize = 50,
  }) async {
    // The app is Arabic by default; the assertions below read the English copy.
    AppText.useLanguage('en');
    addTearDown(() => AppText.useLanguage('ar'));
    final controller = AuditController(trail, pageSize: pageSize);
    controller_ = controller;
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1280, 800),
      builder: (context, child) => MaterialApp(home: AuditScreen(controller: controller)),
    ));
    // `pumpAndSettle` would never return: the loading spinner is an infinite
    // animation while the first page is read.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders the trail of the organization', (tester) async {
    final trail = _StubTrail([
      _row('QC_APPROVED', 'qualityCheck', '2026-03-01 10:00:00'),
      _row('SAMPLE_CREATED', 'sample', '2026-03-01 09:00:00'),
    ]);

    await pumpScreen(tester, trail);

    expect(find.text('QC_APPROVED'), findsOneWidget);
    expect(find.text('SAMPLE_CREATED'), findsOneWidget);
    expect(find.textContaining('qualityCheck'), findsOneWidget);
    expect(find.textContaining('Admin'), findsWidgets);
    expect(find.textContaining('dev_1'), findsWidgets);
  });

  testWidgets('an empty trail says so instead of showing a blank page',
      (tester) async {
    await pumpScreen(tester, _StubTrail(const []));

    expect(find.textContaining('No entries'), findsOneWidget);
  });

  testWidgets('a device without audit.read sees the refusal, not the data',
      (tester) async {
    final trail = _StubTrail([_row('QC_APPROVED', 'qualityCheck', '2026-03-01 10:00:00')],
        allowed: false);

    await pumpScreen(tester, trail);

    expect(find.textContaining('Not permitted'), findsOneWidget);
    expect(find.text('QC_APPROVED'), findsNothing);
  });

  testWidgets('filters, pages and keeps the reader honest', (tester) async {
    final rows = List.generate(
      5,
      (i) => _row('action_$i', i.isEven ? 'sample' : 'qualityCheck',
          '2026-03-0${i + 1} 10:00:00'),
    );
    final trail = _StubTrail(rows);

    await pumpScreen(tester, trail, pageSize: 2);

    expect(controller_.page.entries, hasLength(2));
    expect(controller_.pageNumber, 1);
    expect(controller_.pageCount, 3);
    expect(controller_.hasNext, isTrue);
    expect(controller_.hasPrevious, isFalse);
    expect(find.text('Page 1 / 3 · 5'), findsOneWidget);

    await controller_.nextPage();
    await tester.pump();
    expect(controller_.offset, 2);
    expect(controller_.hasPrevious, isTrue);
    // Newest first: page 2 of 5 rows with a page size of 2 is action_2, action_1.
    expect(find.text('action_2'), findsOneWidget);

    await controller_.previousPage();
    await tester.pump();
    expect(controller_.offset, 0);

    // A filter change always goes back to the first page.
    await controller_.nextPage();
    await tester.pump();
    await controller_.applyFilter(AuditFilter(entityType: 'sample'));
    await tester.pump();
    expect(controller_.offset, 0);
    expect(controller_.page.total, 3);
    expect(find.text('action_4'), findsOneWidget);
    expect(find.text('action_3'), findsNothing);

    await controller_.clearFilters();
    await tester.pump();
    expect(controller_.filter.isEmpty, isTrue);
    expect(controller_.page.total, 5);
  });

  testWidgets('the pager is disabled at both ends', (tester) async {
    final trail = _StubTrail([_row('SAMPLE_CREATED', 'sample', '2026-03-01 10:00:00')]);

    await pumpScreen(tester, trail, pageSize: 10);

    expect(controller_.hasNext, isFalse);
    expect(controller_.hasPrevious, isFalse);

    // Going past the end is a no-op, not a negative offset.
    await controller_.nextPage();
    await controller_.previousPage();
    expect(controller_.offset, 0);
  });
}
