import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/app_bootstrap.dart';
import 'package:material_lab/app/headless.dart';
import '../support/retired/core/sync/sync_engine.dart';
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
  test('headless startup never reactivates the legacy sync worker', () {
    isHeadlessBackground = true;
    startArchiveRefresh();
    verifyNever(engine.start);
  });
  test('foreground startup never reactivates the legacy sync worker', () {
    isHeadlessBackground = false;
    startArchiveRefresh();
    verifyNever(engine.start);
  });
}
