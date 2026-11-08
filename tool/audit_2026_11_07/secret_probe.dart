import 'dart:io';
import 'package:material_lab/core/security/local_secret.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp(
    'materiallab_secret_audit_',
  );
  try {
    final secret = LocalSecret(dir.path);
    final results = await Future.wait(List.generate(8, (_) => secret.load()));
    final disk = await LocalSecret(dir.path).load();
    final unique = results.map((k) => k.join(',')).toSet().length;
    final mismatches = results
        .where((k) => k.join(',') != disk.join(','))
        .length;
    // Never print the generated secret bytes.
    stdout.writeln(
      'parallelLoads=8 distinctKeys=$unique mismatchesWithDisk=$mismatches',
    );
    if (unique != 1 || mismatches != 0) {
      throw StateError('Concurrent secret creation did not converge.');
    }
  } finally {
    await dir.delete(recursive: true);
  }
}
