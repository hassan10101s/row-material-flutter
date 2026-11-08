import 'package:sqflite/sqflite.dart';
import '../../../core/utils/app_dates.dart';
import '../core/formula_engine.dart' show inventoryUnits;

/// Unit catalogue SQL stays separate from test execution and stock accounting.
/// The caller supplies the active capture executor for every candidate write.
abstract final class LabUnitRegistry {
  /// Units registry: every unit string written anywhere is registered into
  /// `lab_units` (INSERT OR IGNORE) so the Units table holds all program
  /// units and every picker inherits from it. Never throws: a missing table
  /// on a hand-built test database simply skips.
  static Future<void> registerUnit(
    DatabaseExecutor exec,
    String? symbol,
  ) async {
    final s = (symbol ?? '').trim();
    if (s.isEmpty) return;
    try {
      await exec.rawInsert(
        'INSERT OR IGNORE INTO lab_units (symbol, is_active, created_at) '
        'VALUES (?, 1, ?)',
        [s, nowIso()],
      );
    } catch (_) {}
  }

  /// A unit is acceptable when the `lab_units` registry holds it. On a
  /// database whose registry is still empty (or a hand-built test database
  /// without the table) the legacy hardcoded list applies as fallback, so
  /// fresh installs and old tests keep working.
  static Future<bool> unitAllowed(DatabaseExecutor exec, String unit) async {
    final clean = unit.trim();
    if (clean.isEmpty) return false;
    try {
      final rows = await exec.rawQuery(
        'SELECT symbol FROM lab_units WHERE is_active = 1',
      );
      if (rows.isEmpty) return inventoryUnits.contains(clean);
      return rows.any((r) => '${r['symbol']}' == clean);
    } catch (_) {
      return inventoryUnits.contains(clean);
    }
  }

  /// Registry symbols for every unit picker in the lab surfaces. Falls back
  /// to the legacy hardcoded list when the registry is empty/missing.
  static Future<List<String>> listSymbols(DatabaseExecutor executor) async {
    try {
      final rows = await executor.rawQuery(
        'SELECT symbol FROM lab_units WHERE is_active = 1 '
        'ORDER BY symbol COLLATE NOCASE ASC',
      );
      final out = [
        for (final r in rows)
          if ('${r['symbol'] ?? ''}'.trim().isNotEmpty) '${r['symbol']}'.trim(),
      ];
      return out.isEmpty ? List<String>.from(inventoryUnits) : out;
    } catch (_) {
      return List<String>.from(inventoryUnits);
    }
  }
}
