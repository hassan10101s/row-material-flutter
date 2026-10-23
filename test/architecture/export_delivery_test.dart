import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the export-delivery invariant.
///
/// Every file the app produces for the user (inspection PDF, sample/equipment
/// label, batch labels, HTML tables, test history…) must reach the delivery
/// flow — `AppFeedbackExport.actions` — which opens the open/share sheet on a
/// phone and the open/reveal-or-share dialog on desktop. The mobile sandbox
/// (`.../files/MaterialLab/...`) is reachable by no file manager, so a
/// "Exported: path" feedback banner is a dead end: the user is told where the
/// file lives in a place they cannot open.
///
/// The pattern this test bans is exactly the shape the three surviving
/// banner-only call sites used before they were routed through
/// `AppFeedbackExport.actions` in 2026-10 (inspection detail export, equipment
/// sticker, equipment batch stickers):
///
///     AppFeedback.success(context, '${AppText.t('تم التصدير', 'Exported')}: path');
///
/// A new export added without the delivery sheet reintroduces that shape and
/// fails here, with no grandfathered list to negotiate with.
void main() {
  final lib = Directory('lib');
  late final List<File> dartFiles = lib.existsSync()
      ? lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
      : <File>[];

  String stripComments(String source) => source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  final deadEndBanner = RegExp(
    // `...'Exported')}: ${file.path}` / `...Exported')}: $path` — the banner
    // that points the user at an unreachable sandbox path instead of
    // opening the delivery sheet.
    r"Exported'\)\}\s*:\s*\$",
  );

  test('the library is present', () {
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run the tests from the project root',
    );
    expect(dartFiles.length, greaterThan(40));
  });

  test('every exported file goes through the delivery sheet — never a '
      'path-only banner', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      final code = stripComments(file.readAsStringSync());
      for (final match in deadEndBanner.allMatches(code)) {
        final line = code
            .substring(0, match.start)
            .split('\n')
            .length;
        offenders.add('$file:$line');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'An export finished with only an "Exported: <path>" banner. On '
          'mobile that path is inside the app sandbox, unreachable by any '
          'file manager — the file must be handed to AppFeedbackExport.actions '
          '(open/share sheet on phones, open/reveal-or-share dialog on '
          'desktop) like every other export.\n'
          '${offenders.join('\n')}',
    );
  });
}
