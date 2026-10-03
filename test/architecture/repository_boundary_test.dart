import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the repository boundary of plan P5 (§3).
///
/// The rule is "presentation depends on domain contracts, never on `data/`".
///
/// **This rule used to be a ratchet and no longer is.** Plan V5 phase P1 closed
/// the last six exceptions by giving `auth`, `settings` and `backup` real
/// domain contracts, so the frozen list is gone and the rule is now a hard
/// failure: a presentation file that imports `data/` fails the build outright,
/// with no grandfathered set to negotiate with.
///
/// The rest of the rules were always hard failures:
///
///  * no presentation file may build a `DatabaseHelper`, import `sqflite` or
///    write raw SQL;
///  * a feature may only own `data/`, `domain/`, `core/` and `presentation/`;
///  * every declared domain contract must be registered in the DI.
const String sep = r'\';

void main() {
  final lib = Directory('lib');
  late final List<File> dartFiles = lib.existsSync()
      ? lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
      : <File>[];

  /// `import`/`export`/`part` directives only - a mention inside a comment or a
  /// doc string does not create a dependency.
  Iterable<String> importsOf(String source) => RegExp(
        r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
        multiLine: true,
      ).allMatches(source).map((m) => m.group(1)!);

  String relative(File file) => file.path
      .replaceAll('/', sep)
      .replaceAll(r'\', '/')
      .replaceFirst('./', '');

  Map<String, List<String>> currentPresentationDataImports() {
    final result = <String, List<String>>{};
    for (final file in dartFiles) {
      if (!file.path.contains('presentation')) continue;
      final targets = importsOf(file.readAsStringSync())
          .where((t) => t.contains('/data/'))
          .toList()
        ..sort();
      if (targets.isEmpty) continue;
      result[relative(file)] = targets;
    }
    return result;
  }

  test('the library is present', () {
    expect(lib.existsSync(), isTrue, reason: 'run the tests from the project root');
    expect(dartFiles.length, greaterThan(40));
  });

  test('presentation never imports data/', () {
    final offenders = <String>[];
    for (final entry in currentPresentationDataImports().entries) {
      for (final target in entry.value) {
        offenders.add('${entry.key} -> $target');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'presentation depends on the domain contract, never on the '
          'implementation. This list was a ratchet until plan V5 phase P1 '
          'closed the last six exceptions; there is no grandfathered set '
          'anymore.\n${offenders.join('\n')}',
    );
  });

  test('no presentation file builds a DatabaseHelper or raw SQL', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      if (!file.path.contains('presentation')) continue;
      final source = file.readAsStringSync();
      for (final needle in const [
        'DatabaseHelper',
        'package:sqflite',
        'SELECT ',
        'INSERT ',
      ]) {
        if (source.contains(needle)) {
          offenders.add('${relative(file)} contains "$needle"');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('a feature may only own data/, domain/, core/ and presentation/', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      final path = file.path.replaceAll('/', sep);
      if (!path.startsWith('lib${sep}features$sep')) continue;
      final parts = path.split(sep);
      if (parts.length <= 3) continue;
      final tail = parts.sublist(3);
      if (tail.length == 1) {
        offenders.add(relative(file));
        continue;
      }
      const allowed = {'data', 'domain', 'presentation', 'core'};
      if (!allowed.contains(tail.first)) offenders.add(relative(file));
    }
    expect(
      offenders,
      isEmpty,
      reason: 'unexpected folder layout\n${offenders.join('\n')}',
    );
  });

  test('every domain contract is registered in the DI', () {
    // A contract that was declared and never wired is dead weight: the facade
    // has to be reachable under its abstraction.
    const contracts = <String>[
      'AuthRepository',
      'BackupService',
      'DashboardRepository',
      'InspectionRepository',
      'SampleRepository',
      'QualityCheckRepository',
      'LabResultRepository',
      'LabConfigurationRepository',
      'LabLocalRepository',
      'MemberRepository',
      'OrganizationRepository',
      'ReferenceRepository',
      'ReportRepository',
      'SettingsRepository',
    ];
    final locator =
        File('lib${sep}di${sep}service_locator.dart').readAsStringSync();
    for (final contract in contracts) {
      expect(
        locator,
        contains('<$contract>'),
        reason: '$contract is declared but never registered',
      );
    }
  });
}
