import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../app_paths.dart';

/// SQLite access layer (port of core/infrastructure/sqlite_db.py schema).
///
/// On desktop (Windows/macOS/Linux) the FFI factory is used; on mobile the
/// native sqflite factory works out of the box — the same code path applies.
class DatabaseHelper {
  DatabaseHelper(this.paths);

  final AppPaths paths;
  Database? _db;
  Database? _readDb;

  /// Initialize the FFI database factory for desktop platforms.
  static void ensureDesktopFactory() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<String> get databasePath async => paths.databasePath();

  Future<Database> get database async {
    if (_db != null) return _db!;
    final path = await paths.databasePath();
    final created = await _open(path);
    _db = created;
    _readDb = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    return created;
  }

  Future<Database> get readDatabase async {
    if (_readDb != null) return _readDb!;
    await database;
    return _readDb!;
  }

  Future<void> rebuild() async {
    await close();
    await database;
  }

  /// Close and drop both open connections (used before replacing the live file
  /// during restore).
  Future<void> close() async {
    await _db?.close();
    await _readDb?.close();
    _db = null;
    _readDb = null;
  }

  /// Re-run the full idempotent schema on the live database: creates any
  /// missing tables, indexes and legacy columns (parity with Python
  /// `Database.ensure_schema` after a restore).
  Future<void> ensureSchema() async {
    final db = await database;
    await _createSchema(db);
  }

  /// Open an arbitrary SQLite file (read-write), apply the full current schema
  /// guarantees (create missing tables + add missing columns), then close.
  /// Used by restore's pre-flight migration on a temp copy.
  Future<void> applySchemaToArbitraryFile(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=NORMAL');
          await db.execute('PRAGMA busy_timeout=5000');
          await db.execute('PRAGMA temp_store=MEMORY');
          await db.execute('PRAGMA cache_size=-20000');
          await db.execute('PRAGMA mmap_size=268435456');
        },
      ),
    );
    try {
      await _createSchema(db);
    } finally {
      await db.close();
    }
  }

  Future<Database> _open(String path) async {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys=ON');
          await db.execute('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=NORMAL');
          await db.execute('PRAGMA busy_timeout=5000');
          await db.execute('PRAGMA temp_store=MEMORY');
          await db.execute('PRAGMA cache_size=-20000');
          await db.execute('PRAGMA mmap_size=268435456');
        },
        onCreate: (db, version) async {
          await _createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await _runLegacyGuarantees(db);
        },
      ),
    );
  }

  /// Create the full schema. Idempotent (IF NOT EXISTS) so it can also be
  /// used to fill any missing tables after a restore.
  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE,
        full_name TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS reference_materials (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_name TEXT NOT NULL UNIQUE,
        material_code TEXT NOT NULL,
        physical_reference_json TEXT NOT NULL,
        chemical_reference_json TEXT NOT NULL,
        source_row INTEGER,
        imported_at TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entry_code TEXT NOT NULL UNIQUE,
        material_id INTEGER NOT NULL,
        material_name TEXT NOT NULL,
        material_code TEXT NOT NULL,
        inspection_date TEXT NOT NULL,
        supplier TEXT,
        truck_number TEXT,
        quantity TEXT,
        sample_taken_by TEXT,
        specialist_name TEXT NOT NULL,
        physical_results_json TEXT NOT NULL,
        chemical_results_json TEXT NOT NULL,
        physical_reference_json TEXT NOT NULL,
        chemical_reference_json TEXT NOT NULL,
        decision_status TEXT NOT NULL,
        decision_reason TEXT,
        follow_up_note TEXT,
        rejected_quantity TEXT,
        report_html TEXT,
        snapshot_json TEXT NOT NULL,
        sample_names_json TEXT NOT NULL,
        decision_version INTEGER NOT NULL DEFAULT 1,
        created_by INTEGER NOT NULL,
        created_by_name TEXT NOT NULL,
        last_pdf_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        expiry_date TEXT,
        FOREIGN KEY(material_id) REFERENCES reference_materials(id),
        FOREIGN KEY(created_by) REFERENCES users(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspection_status_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        inspection_id INTEGER NOT NULL,
        version INTEGER NOT NULL,
        old_status TEXT,
        new_status TEXT NOT NULL,
        change_reason TEXT,
        follow_up_note TEXT,
        rejected_quantity TEXT,
        changed_by INTEGER NOT NULL,
        changed_by_name TEXT NOT NULL,
        changed_at TEXT NOT NULL,
        FOREIGN KEY(inspection_id) REFERENCES inspections(id) ON DELETE CASCADE,
        FOREIGN KEY(changed_by) REFERENCES users(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS parameters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parameter_name TEXT NOT NULL UNIQUE,
        unit TEXT,
        parameter_type TEXT DEFAULT 'physical',
        imported_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        category TEXT,
        description TEXT,
        created_by INTEGER,
        created_at TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_product_analyses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        analysis_id INTEGER NOT NULL,
        min_value REAL,
        max_value REAL,
        unit TEXT,
        UNIQUE(product_id, analysis_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_analyses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        unit TEXT NOT NULL DEFAULT '%',
        description TEXT,
        dynamic_fields_json TEXT NOT NULL DEFAULT '[]',
        formula_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_analysis_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        analysis_id INTEGER NOT NULL,
        inventory_id INTEGER NOT NULL,
        qty_per_sample REAL NOT NULL,
        unit TEXT NOT NULL,
        UNIQUE(analysis_id, inventory_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_inventory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        category TEXT CHECK(category IN ('liquid', 'powder')),
        unit TEXT,
        current_qty REAL NOT NULL DEFAULT 0,
        min_qty REAL NOT NULL DEFAULT 0,
        description TEXT,
        created_by INTEGER,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_constants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        symbol TEXT NOT NULL,
        value_text TEXT,
        unit TEXT,
        unit_dim TEXT,
        is_expression INTEGER NOT NULL DEFAULT 0,
        expression TEXT,
        min_value REAL,
        max_value REAL,
        precision INTEGER,
        description TEXT,
        is_global INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        symbol TEXT NOT NULL UNIQUE,
        name TEXT,
        dimension TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_sample_tests (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        analysis_id INTEGER NOT NULL,
        source_type TEXT NOT NULL,
        source_ref_id INTEGER,
        source_name TEXT NOT NULL,
        sample_name TEXT NOT NULL,
        result_text TEXT,
        dynamic_values_json TEXT NOT NULL DEFAULT '{}',
        entry_code TEXT,
        worksheet_row_id INTEGER,
        tested_by INTEGER,
        tested_at TEXT NOT NULL,
        created_by INTEGER,
        updated_by INTEGER,
        updated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_worksheet (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_type TEXT NOT NULL DEFAULT 'raw_material',
        source_ref_id INTEGER,
        source_name TEXT,
        sample_number TEXT,
        entry_code TEXT,
        created_by INTEGER,
        created_at TEXT NOT NULL,
        updated_by INTEGER,
        updated_at TEXT,
        status TEXT NOT NULL DEFAULT 'ACTIVE',
        void_reason TEXT,
        voided_by INTEGER,
        voided_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_consumption_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sample_test_id INTEGER NOT NULL,
        inventory_id INTEGER NOT NULL,
        qty_used REAL NOT NULL,
        requested_qty REAL,
        applied_qty REAL,
        shortfall_qty REAL NOT NULL DEFAULT 0,
        event_type TEXT NOT NULL DEFAULT 'CONSUMPTION',
        reversal_of_log_id INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_stock_adjustments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        inventory_id INTEGER NOT NULL,
        old_qty REAL NOT NULL,
        new_qty REAL NOT NULL,
        reason TEXT,
        adjusted_by INTEGER,
        adjusted_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_field_chemical_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        analysis_id INTEGER NOT NULL REFERENCES lab_analyses(id) ON DELETE CASCADE,
        dynamic_field TEXT NOT NULL,
        inventory_id INTEGER NOT NULL REFERENCES lab_inventory(id),
        unit TEXT NOT NULL DEFAULT 'mL',
        created_at TEXT NOT NULL,
        UNIQUE(analysis_id, dynamic_field)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_material_analyses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_id INTEGER NOT NULL,
        analysis_id INTEGER NOT NULL,
        min_value REAL,
        max_value REAL,
        unit TEXT,
        UNIQUE(material_id, analysis_id)
      )
    ''');

    await _createIndexes(db);
    await _runLegacyGuarantees(db);
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_consumption_log_sample_test ON lab_consumption_log(sample_test_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_created_at_desc ON inspections(created_at DESC, id DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_date_created_desc ON inspections(inspection_date, created_at DESC, id DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_inspection_date ON inspections(inspection_date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_material_code_date ON inspections(material_code, inspection_date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_material_id ON inspections(material_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_status ON inspections(decision_status)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_inspections_supplier ON inspections(supplier)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sample_tests_worksheet_analysis ON lab_sample_tests(worksheet_row_id, analysis_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sample_tests_worksheet_entry_code ON lab_sample_tests(entry_code)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sample_tests_worksheet_row ON lab_sample_tests(worksheet_row_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_status_history_inspection_version ON inspection_status_history(inspection_id, version DESC, id DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_adjustments_adj_at ON lab_stock_adjustments(adjusted_at DESC, id DESC)');
  }

  /// Idempotent legacy-guard migrations matching sqlite_db.py pragmas/rules.
  Future<void> _runLegacyGuarantees(Database db) async {
    await _ensureColumn(db, 'inspections', 'expiry_date', 'expiry_date TEXT');
    await _ensureColumn(db, 'inspections', 'specialist_name', "specialist_name TEXT NOT NULL DEFAULT ''");
    await _ensureColumn(db, 'inspections', 'decision_version', 'decision_version INTEGER NOT NULL DEFAULT 1');
    await _ensureColumn(db, 'lab_analyses', 'formula_json', "formula_json TEXT NOT NULL DEFAULT '{}'");
    await _ensureColumn(db, 'lab_constants', 'unit_dim', 'unit_dim TEXT');
    await _ensureColumn(db, 'lab_sample_tests', 'entry_code', 'entry_code TEXT');
    await _ensureColumn(db, 'lab_sample_tests', 'worksheet_row_id', 'worksheet_row_id INTEGER');
    await _ensureColumn(db, 'lab_worksheet', 'entry_code', 'entry_code TEXT');
    await _ensureColumn(db, 'lab_worksheet', 'status', "status TEXT NOT NULL DEFAULT 'ACTIVE'");
    await _ensureColumn(db, 'lab_consumption_log', 'requested_qty', 'requested_qty REAL');
    await _ensureColumn(db, 'lab_consumption_log', 'applied_qty', 'applied_qty REAL');
    await _ensureColumn(db, 'lab_consumption_log', 'shortfall_qty', 'shortfall_qty REAL NOT NULL DEFAULT 0');
    await _ensureColumn(db, 'lab_consumption_log', 'event_type', "event_type TEXT NOT NULL DEFAULT 'CONSUMPTION'");
    await _ensureColumn(db, 'lab_consumption_log', 'reversal_of_log_id', 'reversal_of_log_id INTEGER');
    await _ensureColumn(db, 'reference_materials', 'active', 'active INTEGER NOT NULL DEFAULT 1');
    await _ensureColumn(db, 'lab_products', 'active', 'active INTEGER NOT NULL DEFAULT 1');
    await _ensureColumn(db, 'lab_analyses', 'active', 'active INTEGER NOT NULL DEFAULT 1');
    await _ensureColumn(db, 'lab_inventory', 'category', "category TEXT CHECK(category IN ('liquid', 'powder'))");
  }

  Future<void> _ensureColumn(Database db, String table, String column, String spec) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final has = cols.any((c) => c['name'] == column);
    if (!has) {
      await db.execute('ALTER TABLE $table ADD COLUMN $spec');
    }
  }
}