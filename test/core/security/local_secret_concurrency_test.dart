import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/security/local_secret.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'materiallab_secret_race_',
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test('separate concurrent instances all use the persisted key', () async {
    final keys = await Future.wait(
      List.generate(24, (_) => LocalSecret(directory.path).load()),
    );
    final persisted = await LocalSecret(directory.path).load();
    for (final key in keys) {
      expect(key, persisted);
    }
    expect(
      directory.listSync().where((f) => f.path.contains('.tmp-')),
      isEmpty,
    );
  });

  test('simultaneous isolates cannot replace one another\'s key', () async {
    final ready = ReceivePort();
    final results = ReceivePort();
    final starters = <SendPort>[];
    final values = <List<int>>[];
    final errors = <Object?>[];
    final completed = results.take(4).toList();
    final readySubscription = ready.listen((message) {
      starters.add(message as SendPort);
      if (starters.length == 4) {
        for (final starter in starters) {
          starter.send(true);
        }
      }
    });
    final isolates = <Isolate>[];
    addTearDown(() async {
      await readySubscription.cancel();
      ready.close();
      results.close();
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    });
    for (var i = 0; i < 4; i++) {
      isolates.add(
        await Isolate.spawn(_loadInIsolate, (
          directory.path,
          ready.sendPort,
          results.sendPort,
        )),
      );
    }
    for (final result in await completed) {
      if (result is List<int>) {
        values.add(result);
      } else {
        errors.add(result);
      }
    }
    expect(errors, isEmpty);
    expect(values, hasLength(4));
    final persisted = await LocalSecret(directory.path).load();
    for (final value in values) {
      expect(value, persisted);
    }
  });

  test(
    'an abandoned empty reservation fails closed without re-keying',
    () async {
      final file = File('${directory.path}${Platform.pathSeparator}.secret');
      await file.create();
      await expectLater(
        LocalSecret(directory.path).load(),
        throwsA(isA<LocalSecretException>()),
      );
      expect(await file.length(), 0);
    },
  );

  test('a failed load can be retried after explicit file repair', () async {
    final file = File('${directory.path}${Platform.pathSeparator}.secret');
    await file.writeAsString('invalid');
    final secret = LocalSecret(directory.path);
    await expectLater(secret.load(), throwsA(isA<LocalSecretException>()));
    const repaired = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE';
    await file.writeAsString(repaired);
    expect(await secret.load(), List.filled(32, 1));
    expect(await secret.readSecretText(), repaired);
  });
}

Future<void> _loadInIsolate((String, SendPort, SendPort) input) async {
  final start = ReceivePort();
  input.$2.send(start.sendPort);
  await start.first;
  start.close();
  try {
    input.$3.send((await LocalSecret(input.$1).load()).toList());
  } catch (error) {
    input.$3.send('$error');
  }
}
