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
      expect(
        rows,
        hasLength(1),
        reason: 'the guarantee must recreate the dropped table on reopen',
      );
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

  test(
    'opening a legacy reset table adds typed references and snapshots without rewriting history',
    () async {
      final fx = await openSyncFixture();
      try {
        await fx.db.execute('DROP TABLE nir_validation_settings');
        await fx.db.execute(
          '''CREATE TABLE nir_validation_settings (
        id INTEGER PRIMARY KEY AUTOINCREMENT, start_date TEXT NOT NULL,
        reset_note TEXT, reset_by TEXT, reset_by_name TEXT,
        scope TEXT, entity_id INTEGER, entity_name TEXT NOT NULL DEFAULT '',
        parameter TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
        );
        await fx.db.insert('nir_validation_settings', {
          'id': 41,
          'start_date': '2026-01-01',
          'scope': 'raw_material',
          'entity_id': 7,
          'entity_name': 'Legacy material',
          'parameter': 'Protein',
          'reset_note': 'Original note',
          'created_at': '2026-01-01',
          'updated_at': '2026-01-01',
        });
        await fx.helper.close();
        final db = await fx.helper.database;
        final row = (await db.query('nir_validation_settings')).single;
        expect(row['id'], 41);
        expect(row['entity_id'], 7);
        expect(row['entity_name'], 'Legacy material');
        expect(row['reset_note'], 'Original note');
        for (final field in [
          'material_id',
          'product_id',
          'reference_version',
          'calibration_snapshot_json',
        ]) {
          expect(row.containsKey(field), isTrue);
          expect(
            row[field],
            isNull,
            reason: 'legacy identities and statistics must not be invented',
          );
        }
      } finally {
        await fx.helper.close();
        await fx.dispose();
      }
    },
  );
}
