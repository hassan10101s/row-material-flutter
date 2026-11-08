import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/diagnostics/error_reporter.dart';

void main() {
  test(
    'diagnostics serialize concurrent writes, rotate and omit payloads',
    () async {
      final root = await Directory.systemTemp.createTemp('diagnostics_test');
      addTearDown(() => root.delete(recursive: true));
      final reporter = ErrorReporter(
        directory: () async => root,
        maxBytes: 400,
      );
      await Future.wait(
        List.generate(
          12,
          (_) => reporter.record(
            'zone',
            StateError('SECRET_MEASUREMENT=173 TOKEN=private'),
            StackTrace.current,
          ),
        ),
      );
      final files = root.listSync().whereType<File>().toList();
      expect(files.length, 2);
      for (final file in files) {
        final text = await file.readAsString();
        expect(text, isNot(contains('SECRET_MEASUREMENT')));
        expect(text, isNot(contains('TOKEN=private')));
        expect(text, contains('StateError'));
        expect(text, contains('error_reporter_test.dart'));
      }
    },
  );
  test('a diagnostic IO failure never hides the application error', () async {
    final reporter = ErrorReporter(
      directory: () async => throw StateError('disk'),
    );
    await reporter.record('zone', StateError('original'), StackTrace.current);
  });
}
