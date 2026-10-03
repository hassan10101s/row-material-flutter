import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the responsive contract of PLAN_V4 (PLAN_V3 phase 2).
///
/// Four rules, each of which exists because breaking it produces a bug that is
/// hard to see and hard to reproduce:
///
///  1. **The form factor is a platform decision, never a width decision.**
///     `ScreenUtilInit.designSize` is a process-wide singleton established in
///     `main()` before `runApp`. If anything re-derived the form factor from
///     the live window width, a snapped desktop window would be handed the
///     phone grid - the 280dp sidebar becomes 672dp - and the router's
///     `pageBuilder` dispatch would go stale on every resize.
///  2. **Every `presentation/desktop/x.dart` has a `presentation/mobile/x.dart`
///     sibling, and vice versa.** The split is the whole point of PLAN_V4;
///     a one-sided variant is a half-finished screen nobody notices until a
///     user is on that form factor.
///  3. **No variant imports `data/`.** Same boundary as
///     `repository_boundary_test`, restated per-variant so the failure names
///     the file that broke it.
///  4. **Shared design-system widgets contain no form-factor branch.** They
///     are inherited by both experiences, so a branch inside one would make a
///     widget that is correct on desktop wrong on mobile without any screen
///     opting in.
const String sep = r'\';

/// Files that legitimately decide the form factor, or that are the definition
/// of it. Everything else is held to rule 1.
const Set<String> _formFactorAuthorities = {
  r'lib\core\responsive\form_factor.dart',
  r'lib\core\responsive\layout_spec.dart',
  r'lib\core\responsive\responsive_scope.dart',
  r'lib\router\app_router.dart',
  r'lib\main.dart',
};

/// Widgets whose job *is* the branch. These are the adaptive primitives, and
/// they are the only place a form-factor `if` is allowed to live.
const Set<String> _adaptivePrimitivePaths = {
  r'lib\design_system\widgets\app_adaptive_list.dart',
  r'lib\design_system\widgets\app_adaptive.dart',
};

/// Reads the live window size.
final RegExp _widthDerived = RegExp(
  r'MediaQuery\.(sizeOf|of)\([^)]*\)\s*\.?\s*(width|size)|'
  r'constraints\.maxWidth|'
  r'LayoutBuilder',
);

/// Names a form factor - the thing that must never come from the width.
final RegExp _mentionsFormFactor = RegExp(
  r'AppFormFactor|FormFactor\.|\bisMobile\b|\bisDesktop\b|context\.layout|'
  r'ResponsiveScope',
);

void main() {
  final lib = Directory('lib');
  final dartFiles = lib.existsSync()
      ? lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
      : <File>[];

  String relative(File file) => file.path
      .replaceAll('/', sep)
      .replaceAll(r'\', '/')
      .replaceFirst('./', '');

  String windowsStyle(File file) =>
      file.path.replaceAll('/', sep).replaceAll(r'\', sep);

  /// `import`/`export`/`part` directives only - a mention in a doc comment does
  /// not create a dependency.
  Iterable<String> importsOf(String source) => RegExp(
        r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
        multiLine: true,
      ).allMatches(source).map((m) => m.group(1)!);

  /// Source with comments and doc comments removed, so the *documentation* of
  /// a rule can mention `MediaQuery` without failing the rule.
  String codeOnly(String source) {
    final stripped = source.replaceAll(
      RegExp(r'/\*[\s\S]*?\*/'),
      '',
    );
    return stripped
        .split('\n')
        .where((line) => !RegExp(r'^\s*//').hasMatch(line))
        .join('\n');
  }

  final presentationFiles = dartFiles
      .where((f) => f.path.contains('presentation'))
      .toList();
  final variantFiles = presentationFiles
      .where((f) => RegExp(r'presentation[\\/](desktop|mobile)[\\/]').hasMatch(f.path))
      .toList();

  test('the library is present', () {
    expect(lib.existsSync(), isTrue, reason: 'run the tests from the project root');
    expect(dartFiles.length, greaterThan(40));
  });

  test('the form factor is never derived from the window size', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      if (_formFactorAuthorities.contains(windowsStyle(file))) continue;
      if (_adaptivePrimitivePaths.contains(windowsStyle(file))) continue;
      final source = codeOnly(file.readAsStringSync());
      // Narrow on purpose. Laying one experience out across the widths it can
      // end up at - a `LayoutBuilder` putting cards 2-up on a wide window and
      // 1-up on a narrow one - is correct and stays. What is forbidden is a
      // file that names a form factor *and* reaches for the window width, i.e.
      // one that has started deciding which experience to build from how big
      // the window happens to be.
      if (!_mentionsFormFactor.hasMatch(source)) continue;
      if (!_widthDerived.hasMatch(source)) continue;
      offenders.add(relative(file));
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'these files name a form factor and also read the window width, so '
          'they have started deciding which experience to build from how big '
          'the window is. Use `FormFactor.current` (platform) and '
          '`context.layout` (resolved metrics) instead.\n'
          '${offenders.join('\n')}',
    );
  });

  test('every desktop variant has a mobile sibling', () {
    final offenders = <String>[];
    for (final file in variantFiles) {
      final match = RegExp(
        r'presentation[\\/](desktop|mobile)[\\/]',
      ).firstMatch(file.path);
      if (match == null) continue;
      final counterpartDir =
          match.group(1) == 'desktop' ? 'mobile' : 'desktop';
      final counterpart = file.path.replaceFirst(
        match.group(0)!,
        'presentation$sep$counterpartDir$sep',
      );
      if (!File(counterpart).existsSync()) {
        offenders.add('${relative(file)} has no ${match.group(1) == 'desktop' ? 'mobile' : 'desktop'} counterpart');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a one-sided variant is a half-finished screen. Add the missing '
          'sibling.\n${offenders.join('\n')}',
    );
  });

  test('no variant imports data/', () {
    final offenders = <String>[];
    for (final file in variantFiles) {
      final targets = importsOf(file.readAsStringSync())
          .where((t) => t.contains('/data/'))
          .toList()
        ..sort();
      for (final target in targets) {
        offenders.add('${relative(file)} -> $target');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a desktop/mobile variant must depend on the domain contract, not '
          'the implementation.\n${offenders.join('\n')}',
    );
  });

  test('shared design-system widgets do not branch on the form factor', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      final path = relative(file);
      if (!path.startsWith('lib/design_system/widgets/')) continue;
      if (_adaptivePrimitivePaths.contains(windowsStyle(file))) continue;
      final source = file.readAsStringSync();
      if (RegExp(r'\bisMobile\b|\bisDesktop\b|AppFormFactor|context\.layout').hasMatch(source)) {
        offenders.add(path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'these widgets are inherited by both experiences, so a branch inside '
          'one makes it wrong on a form factor no screen opted into. Read '
          'AppSpacing/AppTextTheme instead.\n${offenders.join('\n')}',
    );
  });

  test('designSize is chosen per platform, not per width', () {
    final main = File('lib${sep}main.dart').readAsStringSync();
    expect(
      main,
      contains('FormFactor.current.isMobile'),
      reason:
          'main.dart must pick designSize from the resolved form factor; a '
          'width-derived designSize hands a snapped desktop window the phone grid',
    );
    expect(
      main,
      isNot(contains('platformDispatcher')),
      reason:
          'reading the physical/logical window size in main() is the bug PLAN_V4 '
          'was written to remove - see FormFactor.resolve',
    );
  });
}
