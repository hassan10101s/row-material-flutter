import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/platform/file_delivery.dart';
import 'package:material_lab/design_system/feedback/app_feedback_export.dart';
import 'package:material_lab/di/service_locator.dart';

/// A [FileDelivery] that records what the UI asked for, so the test can assert
/// on the *contract* (which affordances are offered, and that the chosen one is
/// actually delivered) rather than on the platform channel behind it.
class _RecordingDelivery implements FileDelivery {
  _RecordingDelivery({required this.canReveal, required this.canShare});

  @override
  final bool canReveal;
  @override
  final bool canShare;

  final List<String> calls = <String>[];
  bool succeed = true;

  @override
  Future<bool> reveal(String filePath) async {
    calls.add('reveal:$filePath');
    return succeed;
  }

  @override
  Future<bool> share(String filePath, {String? subject}) async {
    calls.add('share:$filePath:$subject');
    return succeed;
  }
}

void main() {
  late _RecordingDelivery delivery;

  setUp(() {
    // The app defaults to Arabic; these assertions read the English strings.
    final wasArabic = AppText.arabic;
    addTearDown(() => AppText.arabic = wasArabic);
    AppText.arabic = false;

    delivery = _RecordingDelivery(canReveal: true, canShare: true);
    getIt.registerSingleton<FileDelivery>(delivery);
  });

  tearDown(() {
    getIt.unregister<FileDelivery>();
  });

  void useDelivery(FileDelivery value) {
    getIt.unregister<FileDelivery>();
    getIt.registerSingleton<FileDelivery>(value);
  }

  /// Pumps a button that triggers the export feedback, and returns the tapped
  /// element's context so the sheet and any banner land in a real overlay.
  Future<void> pumpTrigger(WidgetTester tester, String filePath) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  AppFeedbackExport.actions(context, filePath: filePath),
              child: const Text('export'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
  }

  group('capabilities', () {
    testWidgets('offers both actions when the platform supports both',
        (tester) async {
      await pumpTrigger(tester, '/tmp/report.pdf');

      expect(find.text('Open the file'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('hides reveal when the platform cannot reveal', (tester) async {
      useDelivery(_RecordingDelivery(canReveal: false, canShare: true));
      await pumpTrigger(tester, '/tmp/report.pdf');

      // A visible control that cannot work is worse than no control: it is the
      // exact dead end this replaced.
      expect(find.text('Open the file'), findsNothing);
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('says so plainly when nothing can be delivered',
        (tester) async {
      useDelivery(_RecordingDelivery(canReveal: false, canShare: false));
      await pumpTrigger(tester, '/tmp/report.pdf');

      expect(find.text('Share'), findsNothing);
      expect(find.textContaining('cannot be opened'), findsOneWidget);
    });
  });

  group('delivery', () {
    testWidgets('share passes the file and the document name', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => AppFeedbackExport.actions(
                  context,
                  filePath: '/tmp/report.pdf',
                  documentName: 'Inspection 12',
                ),
                child: const Text('export'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('export'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      expect(delivery.calls, ['share:/tmp/report.pdf:Inspection 12']);
      // The sheet is dismissed so the user is not left staring at a stale
      // action list for a file they already sent.
      expect(find.text('Share'), findsNothing);
    });

    testWidgets('keeps the sheet open and reports when delivery fails',
        (tester) async {
      delivery.succeed = false;
      await pumpTrigger(tester, '/tmp/report.pdf');

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      // With no explicit document name the filename is still a useful subject.
      expect(delivery.calls, ['share:/tmp/report.pdf:report.pdf']);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Could not share the file'), findsOneWidget);
    });
  });
}
