import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production repositories use server-confirmed names and descriptions',
    () {
      final violations = <String>[];
      final retiredName = RegExp(
        r'offline.?first|offline.?local',
        caseSensitive: false,
      );
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        if (retiredName.hasMatch(file.path) ||
            retiredName.hasMatch(file.readAsStringSync())) {
          violations.add(file.path);
        }
      }
      expect(violations, isEmpty);
    },
  );
  test('production cannot import retired send engines or old sync screens', () {
    final retired = RegExp(
      r'''(?:import|export)\s+['"][^'"]*(?:command_worker|command_service|sync_engine|push_worker|pull_worker|backfill_service|conflict_resolver|features/sync/|test/support/retired)''',
    );
    final violations = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (retired.hasMatch(file.readAsStringSync())) violations.add(file.path);
    }
    expect(violations, isEmpty);
    expect(
      File('lib/features/sync/presentation/sync/sync_screen.dart').existsSync(),
      isFalse,
    );
  });
  test(
    'only the explicit direct-write service calls the business transport',
    () {
      final callers = <String>[];
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        if (RegExp(r'transport\.submit\(').hasMatch(file.readAsStringSync())) {
          callers.add(file.path.replaceAll('\\', '/'));
        }
      }
      expect(callers, ['lib/core/commands/direct_write_service.dart']);
    },
  );
}
