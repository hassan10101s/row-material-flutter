import 'dart:convert';
import 'dart:io';

import '../app_paths.dart';

/// Local bounded diagnostics. Never persists exception messages, user inputs,
/// tokens, measurement values or organization/account identifiers.
class ErrorReporter {
  ErrorReporter({required this.directory, this.maxBytes = 262144});
  static final instance = ErrorReporter(
    directory: () async {
      final root = await AppPaths().appSupportRoot();
      return Directory('${root.path}/diagnostics');
    },
  );
  final Future<Directory> Function() directory;
  final int maxBytes;
  Future<void> _tail = Future.value();

  Future<void> record(String source, Object error, StackTrace stack) {
    final safeSource = const {'flutter', 'platform', 'zone'}.contains(source)
        ? source
        : 'application';
    // Stack frame lines only; custom StackTrace text may contain user values.
    final frames = stack
        .toString()
        .split('\n')
        .where((line) => RegExp(r'^#\d+\s').hasMatch(line))
        .take(40)
        .map((line) => line.length > 512 ? line.substring(0, 512) : line)
        .toList();
    final row = jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      'source': safeSource,
      'type': error.runtimeType.toString(),
      'frames': frames,
    });
    return _tail = _tail.then((_) async {
      try {
        final root = await directory();
        await root.create(recursive: true);
        final file = File('${root.path}/errors.jsonl');
        if (await file.exists() &&
            await file.length() + utf8.encode(row).length > maxBytes) {
          final previous = File('${root.path}/errors.previous.jsonl');
          if (await previous.exists()) await previous.delete();
          await file.rename(previous.path);
        }
        await file.writeAsString('$row\n', mode: FileMode.append, flush: true);
      } on Object {
        // Diagnostic failure cannot replace the original application failure.
      }
    });
  }
}
