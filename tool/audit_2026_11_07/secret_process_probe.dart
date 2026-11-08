// Runs only against a newly created temporary directory, never the user's key.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:material_lab/core/security/local_secret.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--worker') {
    final directory = args[1];
    await File(p.join(directory, 'ready-$pid')).writeAsString('ready');
    while (!await File(p.join(directory, 'start')).exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final key = await LocalSecret(directory).load();
    // Only a digest of this throwaway key crosses the process boundary.
    stdout.writeln(sha256.convert(key));
    return;
  }
  final directory = await Directory.systemTemp.createTemp(
    'materiallab_secret_processes_',
  );
  final processes = <Process>[];
  try {
    final completions = <Future<(int, String, String)>>[];
    for (var i = 0; i < 4; i++) {
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        Platform.script.toFilePath(),
        '--worker',
        directory.path,
      ]);
      processes.add(child);
      completions.add(() async {
        final out = child.stdout.transform(systemEncoding.decoder).join();
        final err = child.stderr.transform(systemEncoding.decoder).join();
        return (await child.exitCode, await out, await err);
      }());
    }
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while ((await directory
            .list()
            .where((entry) => p.basename(entry.path).startsWith('ready-'))
            .length) !=
        4) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Workers did not become ready.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await File(p.join(directory.path, 'start')).writeAsString('start');
    final results = await Future.wait(
      completions,
    ).timeout(const Duration(minutes: 1));
    if (results.any((result) => result.$1 != 0)) {
      throw StateError(
        'Secret worker failed: ${results.where((r) => r.$1 != 0).map((r) => r.$3).join('\n')}',
      );
    }
    final fingerprints = results.map((r) => r.$2.trim()).toSet();
    final persisted = sha256
        .convert(await LocalSecret(directory.path).load())
        .toString();
    if (fingerprints.length != 1 || fingerprints.single != persisted) {
      throw StateError('Concurrent process keys did not converge.');
    }
    stdout.writeln('processes=4 distinctKeys=1 mismatchesWithDisk=0');
  } finally {
    for (final process in processes) {
      process.kill();
    }
    // This exact Directory was returned by createTemp above.
    await directory.delete(recursive: true);
  }
}
