import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/app_bootstrap.dart';
import 'package:material_lab/app/headless.dart';
import 'package:material_lab/core/sync/sync_engine.dart';
import 'package:material_lab/di/service_locator.dart';

class _Engine extends Mock implements SyncEngine {}

void main() {
  late _Engine engine;
  setUp(() {
    engine = _Engine();
    getIt.registerSingleton<SyncEngine>(engine);
  });
  tearDown(() async {
    isHeadlessBackground = false;
    await getIt.unregister<SyncEngine>();
  });
  test(
    'headless startup leaves the dispatcher in control of its awaited cycle',
    () {
      isHeadlessBackground = true;
      startSyncEngine();
      verifyNever(engine.start);
    },
  );
  test('foreground startup still starts the automatic sync loop', () {
    isHeadlessBackground = false;
    startSyncEngine();
    verify(engine.start).called(1);
  });
}
