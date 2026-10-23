import 'package:flutter_test/flutter_test.dart';

import '../sync/sync_test_fixture.dart';

/// `nir_validation_settings` must materialize on **existing** installs.
///
/// `_createSchema` runs on fresh databases only (the app version is fixed at
/// 1, so `onCreate` never fires again); later tables are created on every
/// open by `_runLegacyGuarantees`. This test drops the table (simulating a
/// database created before the NIR فلديشن feature) and proves a reopen
/// recreates it — otherwise `getSettings()` crashes with
/// `no such table: nir_validation_settings` (the regression seen at runtime).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a reopen after the table was dropped recreates it', () async {
    final fx = await openSyncFixture();
    try {
      await fx.db.execute('DROP TABLE IF EXISTS nir_validation_settings');
      // DatabaseHelper caches the open handle; force a fresh open so
      // `_runLegacyGuarantees` (the every-open path) runs again.
      await fx.helper.close();
      final db = await fx.helper.database;
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'nir_validation_settings'",
      );
      expect(rows, hasLength(1),
          reason: 'the guarantee must recreate the dropped table on reopen');
      // And the table accepts a reset row immediately.
      await db.insert('nir_validation_settings', {
        'start_date': '2026-01-01',
        'reset_note': '',
        'reset_by': 'uid',
        'reset_by_name': 'tester',
        'created_at': 'x',
        'updated_at': 'x',
      });
      final settings = await db.query('nir_validation_settings');
      expect(settings, hasLength(1));
    } finally {
      await fx.dispose();
    }
  });
}
