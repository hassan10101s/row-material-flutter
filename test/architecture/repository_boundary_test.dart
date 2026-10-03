import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the repository boundary of plan P5 (§3).
///
/// The rule is "presentation depends on domain contracts, never on `data/`".
/// Plan P5.4 also forbids touching the 30 V1 cubits and 8 widgets, and most of
/// them still import their repository implementation directly - so the rule is
/// enforced as a **ratchet**: the known legacy imports are frozen in
/// [_legacyPresentationDataImports] and the set may shrink (when a module gets a
/// domain contract) but must never grow. Everything else is a hard failure:
///
///  * no presentation file may build a `DatabaseHelper`, import `sqflite` or
///    write raw SQL;
///  * a feature may only own `data/`, `domain/`, `core/` and `presentation/`;
///  * every declared domain contract must be registered in the DI.
const String sep = r'\';

/// Frozen at P5. Time to delete entries, never to add one.
const Map<String, List<String>> _legacyPresentationDataImports = {
  'lib/features/auth/presentation/cubit/create_organization_cubit.dart': [
    '../../data/auth_repository.dart',
  ],
  'lib/features/auth/presentation/cubit/login_cubit.dart': [
    '../../data/auth_repository.dart',
  ],
  'lib/features/settings/presentation/migration_panel.dart': [
    '../../backup/data/backup_manager.dart',
  ],
  'lib/features/settings/presentation/settings_screen.dart': [
    '../../backup/data/backup_manager.dart',
    '../data/settings_repo.dart',
  ],
  'lib/features/settings/presentation/cubit/database_settings_cubit.dart': [
    '../../../backup/data/backup_manager.dart',
  ],
  'lib/features/settings/presentation/cubit/general_settings_cubit.dart': [
    '../../data/settings_repo.dart',
  ],
};

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

  test('presentation never gains a new data/ import (ratchet)', () {
    final current = currentPresentationDataImports();
    final added = <String>[];
    for (final entry in current.entries) {
      final known = _legacyPresentationDataImports[entry.key] ?? const <String>[];
      for (final target in entry.value) {
        if (!known.contains(target)) {
          added.add('${entry.key} -> $target');
        }
      }
    }
    expect(
      added,
      isEmpty,
      reason: 'new presentation -> data/ dependency; depend on the domain '
          'contract instead\n${added.join('\n')}',
    );
  });

  test('the legacy ratchet list is not stale', () {
    final current = currentPresentationDataImports();
    final stale = <String>[];
    for (final entry in _legacyPresentationDataImports.entries) {
      final live = current[entry.key];
      if (live == null) {
        stale.add('${entry.key} no longer imports data/ - delete the entry');
        continue;
      }
      for (final target in entry.value) {
        if (!live.contains(target)) {
          stale.add('${entry.key} -> $target was removed - delete the entry');
        }
      }
    }
    expect(
      stale,
      isEmpty,
      reason: 'the boundary improved: shrink the frozen list\n'
          '${stale.join('\n')}',
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
