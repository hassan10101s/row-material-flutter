import 'dart:async';
import 'dart:io';

import 'package:sqflite_common/utils/utils.dart' as utils;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../app_paths.dart';
import 'db_trace.dart';

/// SQLite access layer (port of core/infrastructure/sqlite_db.py schema).
///
/// On desktop (Windows/macOS/Linux) the FFI factory is used; on mobile the
/// native sqflite factory works out of the box — the same code path applies.
class DatabaseHelper {
  DatabaseHelper(this.paths);

  final AppPaths paths;

  /// The one live connection. There is deliberately no second read-only
  /// handle: sqflite's single-instance cache is keyed by path only, so an extra
  /// `openDatabase(readOnly: true)` returns this same object and `close()` would
  /// shut it down twice. See [readDatabase].
  Database? _db;

  /// Initialize the FFI database factory for desktop platforms.
  ///
  /// Idempotent on purpose. `databaseFactory` is a **global** in the sqflite
  /// packages and reassigning it is not free: sqflite prints "You are changing
  /// sqflite default factory" and warns that the new value becomes the default
  /// *for all operations*, including ones already in flight on a handle opened
  /// through the previous factory. It must therefore happen exactly once, at DI
  /// time, before any database is opened.
  static void ensureDesktopFactory() {
    if (_desktopFactoryReady) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      _installLockDiagnostics();
    }
    _desktopFactoryReady = true;
  }

  static bool _desktopFactoryReady = false;
  static bool _lockDiagnosticsReady = false;

  static const Duration _lockWarningDurationDefault = Duration(seconds: 10);

  /// Make sqflite's anonymous lock warning actionable.
  ///
  /// `Warning database has been locked for 0:00:10.000000. Make sure you
  /// always use the transaction object...` is printed by
  /// `sqflite_common`'s `SqfliteDatabaseMixinBase.txnSynchronized` after
  /// `lockWarningDurationDefault` (10s) spent waiting for the connection's
  /// non-reentrant `_rawLock`. It is worth keeping, but it cannot be used to
  /// find the culprit: it fires from the `Timer` of
  /// `timeoutCompleter.future.timeout(...)`, so the frames it prints are always
  /// `Future.timeout -> Timer._runTimers` and never the call that was waiting.
  ///
  /// The reason a wait gets that long at all is worth spelling out, because it
  /// is what makes the warning misleading. With the FFI factory every statement
  /// of every database is funnelled through **one** shared background isolate
  /// (`database_factory_ffi_io.dart:43`), and a statement that is not part of
  /// the transaction currently open on the connection is not run at all - it is
  /// parked in `SqfliteFfiDatabase._noTransactionHandlerQueue` until that
  /// transaction ends (`sqflite_ffi_impl.dart:270`) - while already holding the
  /// `_rawLock` the ten seconds are measured against. So "held the connection
  /// for ten seconds" almost always means "there was a long call in flight, and
  /// something behind it needed the same connection".
  ///
  /// The holder is reported by [DbTrace], which times every call from the
  /// synchronous part of its caller - so the stack it prints does name the call
  /// site, and a stall report lists every call that was in flight at that
  /// moment. This callback only records that a wait happened and points there.
  static void _installLockDiagnostics() {
    if (_lockDiagnosticsReady) return;
    _lockDiagnosticsReady = true;
    // Only the callback is replaced: the duration is left at the package default
    // so the warning still fires on the same schedule as before.
    utils.setLockWarningInfo(
      callback: () {
        // ignore: avoid_print
        print(
          'Warning database has been locked for more than '
          '$_lockWarningDurationDefault. A database call waited for the '
          'connection lock - the holder is whichever call had it. See the '
          '[db] lines from DbTrace for the call sites: a stall report lists '
          'every call that was in flight, oldest first.',
        );
      },
    );
  }

  /// Test hook: allow [ensureDesktopFactory] to run again.
  static void resetDesktopFactoryForTesting() => _desktopFactoryReady = false;

  Future<String> get databasePath async => paths.databasePath();

  /// Bind the process to an organization: closes the current connection and
  /// re-opens `%APPDATA%\MaterialLab\orgs\<orgId>\material_lab.db` (plan §D3).
  ///
  /// Returns the resolved database path. Calling it twice with the same id is a
  /// no-op, so a router rebuild never re-creates the file.
  Future<String> bindOrg(String? orgId) async {
    final normalized = (orgId == null || orgId.isEmpty) ? null : orgId;
    if (paths.orgId == normalized && _db != null) return databasePath;
    await close();
    paths.orgId = normalized;
    await database;
    return databasePath;
  }

  /// The organization currently bound (null ⇒ not bound yet).
  String? get boundOrgId => paths.orgId;

  /// The live connection.
  ///
  /// [_ensureOpen] is a *synchronisation* point, not a guarantee: a close that
  /// lands between "the open finished" and "hand the handle over" can still
  /// empty `_db`, because `close()` nulls the field synchronously and only then
  /// awaits the handle's own shutdown. Returning `_db!` there produced
  /// `Null check operator used on a null value` deep inside whichever service
  /// lost its connection, naming neither the service nor the cause.
  ///
  /// Re-driving the open closes that window: the second pass sees `_closing`,
  /// waits for the close to settle, and opens against the new handle.
  Future<Database> get database async {
    while (true) {
      await _ensureOpen();
      final db = _db;
      if (db != null) return db;
      // A close overtook us; `_ensureOpen` now waits for it and re-opens.
    }
  }

  /// The per-organization database, for read-only callers (reports).
  ///
  /// This deliberately returns the **same** handle as [database]. A second
  /// `openDatabase(..., readOnly: true)` does *not* create a second connection:
  /// sqflite's single-instance cache is keyed by path only
  /// (`factory_mixin.dart` -> `databaseOpenHelpers[path]`), with `readOnly`
  /// ignored, so the extra open handed back the identical object.
  ///
  /// That made [close] close one connection twice, and the second close raced
  /// the first: every holder that had memoized the handle (the sync queue via
  /// `_resolved`, the sync engine) kept pointing at a closed database and threw
  /// `DatabaseException(error database_closed)`, while the writes queued behind
  /// `closeDatabase`'s per-path lock produced the
  /// `Warning database has been locked for 0:00:10` spam.
  Future<Database> get readDatabase async => database;

  /// In-flight open, used to make opening single-flight.
  Future<void>? _opening;

  /// In-flight close. A caller that resolves [database] while a close is in
  /// flight must wait for it: `close()` awaits `_db.close()`, and the field
  /// still points at that handle until the await returns, so without this a
  /// caller would receive an already-closed database.
  Future<void>? _closing;

  /// Open the connection exactly once, no matter how many callers race.
  ///
  /// [_closing] is awaited *first*: a close empties `_db` synchronously and only
  /// then awaits the handle's own shutdown, so a caller that skipped the close
  /// would be handed nothing (or a dying connection) for the whole duration of
  /// that await. Once the close settles, the open is re-driven from scratch.
  Future<void> _ensureOpen() {
    final closing = _closing;
    if (closing != null) {
      return closing.then((_) => _ensureOpen());
    }
    if (_db != null) return Future<void>.value();
    return _opening ??= _openLive().whenComplete(() => _opening = null);
  }

  Future<void> _openLive() async {
    final path = await paths.databasePath();
    _db = await _open(path);
  }

  Future<void> rebuild() async {
    await close();
    await database;
  }

  /// Close and drop both open connections (used before replacing the live file
  /// during restore).
  ///
  /// Every listener registered with [onDatabaseClosed] is notified: a class that
  /// memoized the connection (the sync queue, the sync metadata) would otherwise
  /// keep reading and writing the file that was just closed - which, after a
  /// restore or an organization switch, is not the file the app is bound to.
  Future<void> close() async {
    // Serialise closes: a second concurrent close would race the first on the
    // same handle. `_ensureOpen` waits on `_closing`, so nobody receives the
    // handle while it is being shut.
    final pending = _closing;
    if (pending != null) return pending;

    final completer = Completer<void>();
    _closing = completer.future;
    try {
      // An open may still be in flight (bindOrg -> close -> open). Wait for it,
      // or `_open` would assign a fresh handle after this method nulled it.
      final opening = _opening;
      if (opening != null) {
        try {
          await opening;
        } on Object {
          // A failed open has nothing to close.
        }
      }
      // One connection only: `readDatabase` is the same handle (see its docs).
      final db = _db;
      _db = null;
      _opening = null;
      if (db != null) {
        try {
          await db.close();
        } on Object {
          // Closing an already-closed database must not abort the close.
        }
      }
      for (final listener in List<void Function()>.from(_closeListeners)) {
        try {
          listener();
        } on Object {
          // A listener must never block the close itself.
        }
      }
      completer.complete();
    } on Object catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _closing = null;
    }
  }

  /// Notified after [close] - the cached connection is gone.
  void onDatabaseClosed(void Function() listener) => _closeListeners.add(listener);

  final List<void Function()> _closeListeners = [];

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
    final db = await databaseFactory.openDatabase(
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
    // Apply idempotent column/table guarantees on every open — returns on
    // existing databases (fixed version 1) otherwise never see new columns.
    await _runLegacyGuarantees(db);
    // Every call through the handle is timed and, if it overruns, reported with
    // its caller's stack. Wrapping the handle rather than individual call sites
    // is what makes the set of suspects complete: a stall report has to list
    // *every* call that was in flight, including the ones nobody thought to
    // label, or it names victims and stays silent about the holder.
    return TracedDatabase(db);
  }

  /// Create the full schema. Idempotent (IF NOT EXISTS) so it can also be
  /// used to fill any missing tables after a restore.
  Future<void> _createSchema(Database db) async {
    await db.execute(_usersTableV2);
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
        parameter_id INTEGER REFERENCES parameters(id),
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
        inventory_id INTEGER REFERENCES lab_inventory(id),
        unit TEXT NOT NULL DEFAULT 'mL',
        kind TEXT NOT NULL DEFAULT 'link',
        fixed_value REAL,
        list_values TEXT,
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
    // Reference-driven material specs (plan: every material inherits the
    // canonical parameter NAME from `parameters` but carries its own
    // acceptance/rejection limits here).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS material_parameter_bounds (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_id INTEGER NOT NULL REFERENCES reference_materials(id),
        parameter_id INTEGER NOT NULL REFERENCES parameters(id),
        parameter_type TEXT NOT NULL CHECK(parameter_type IN ('physical', 'chemical')),
        unit TEXT NOT NULL DEFAULT '',
        min_value REAL,
        max_value REAL,
        precision INTEGER,
        active INTEGER NOT NULL DEFAULT 1,
        UNIQUE(material_id, parameter_id)
      )
    ''');

    await _createIndexes(db);
    await _createSyncTables(db);
    await _runLegacyGuarantees(db);
  }

  /// V2 `users` = organization roster (identity lives in Firebase, never a
  /// local password). Mirrors `organizations/{o}/members/{m}` remotely.
  static const String _usersTableV2 = '''
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY,
      uid TEXT UNIQUE,
      member_id TEXT,
      email TEXT NOT NULL,
      full_name TEXT NOT NULL DEFAULT '',
      role TEXT NOT NULL DEFAULT 'viewer',
      status TEXT NOT NULL DEFAULT 'invited',
      permissions_json TEXT NOT NULL DEFAULT '[]',
      display_name TEXT,
      photo_url TEXT,
      version INTEGER NOT NULL DEFAULT 1,
      updated_at TEXT NOT NULL DEFAULT '',
      updated_by TEXT,
      remote_version INTEGER NOT NULL DEFAULT 0,
      remote_synced_at TEXT,
      sync_state TEXT NOT NULL DEFAULT 'local',
      deleted_at TEXT,
      created_at TEXT NOT NULL DEFAULT ''
    )
  ''';

  /// Sync bookkeeping tables (plan §6.4, DDL verbatim).
  Future<void> _createSyncTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        local_ref INTEGER,
        operation TEXT NOT NULL,
        payload TEXT NOT NULL,
        base_version INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        last_error TEXT
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_queue_entity
        ON sync_queue(entity_type, entity_id)
        WHERE status IN ('pending','in_flight','blocked')
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_queue_ready
        ON sync_queue(status, next_attempt_at, id)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_conflicts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        direction TEXT NOT NULL,
        local_payload TEXT,
        remote_payload TEXT,
        detected_at TEXT NOT NULL,
        resolution TEXT,
        resolved_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device_registry (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        platform TEXT NOT NULL,
        os_version TEXT,
        app_version TEXT,
        role TEXT NOT NULL,
        read_only INTEGER NOT NULL DEFAULT 0,
        registered_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL,
        last_write_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS audit_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT,
        user_name TEXT,
        organization_id TEXT NOT NULL,
        action TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        details_json TEXT,
        device_id TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_logs(entity_type, entity_id, id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_time ON audit_logs(occurred_at DESC, id DESC)');
  }

  /// Tables mirrored to Firestore and the columns that make that possible
  /// (plan §6.5). `organization_id` is deliberately absent: isolation is
  /// physical (one file per organization).
  static const List<String> syncedTables = [
    'inspections',
    'inspection_status_history',
    'lab_sample_tests',
    'users',
    'lab_analyses',
    'lab_analysis_items',
    'lab_field_chemical_links',
    'lab_constants',
    'lab_products',
    'lab_product_analyses',
    'lab_units',
    // The audit outbox is never pulled back, but its rows are pushed as
    // `organizations/{orgId}/auditLogs` documents, so `SyncQueue.markDone`
    // stamps the same per-row bookkeeping on them.
    'audit_logs',
  ];

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
    // lab_field_chemical_links gained kind/fixed_value/list_values and a
    // nullable inventory_id (value/list configs store inventory_id NULL).
    // Rebuild the legacy NOT NULL FK table once.
    final fclCols = await db.rawQuery('PRAGMA table_info(lab_field_chemical_links)');
    if (fclCols.isNotEmpty && !fclCols.any((c) => c['name'] == 'kind')) {
      await db.execute(
          'ALTER TABLE lab_field_chemical_links RENAME TO lab_field_chemical_links_old');
      await db.execute('''
        CREATE TABLE lab_field_chemical_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          analysis_id INTEGER NOT NULL REFERENCES lab_analyses(id) ON DELETE CASCADE,
          dynamic_field TEXT NOT NULL,
          inventory_id INTEGER REFERENCES lab_inventory(id),
          unit TEXT NOT NULL DEFAULT 'mL',
          kind TEXT NOT NULL DEFAULT 'link',
          fixed_value REAL,
          list_values TEXT,
          created_at TEXT NOT NULL,
          UNIQUE(analysis_id, dynamic_field)
        )
      ''');
      await db.execute('''
        INSERT INTO lab_field_chemical_links (id, analysis_id, dynamic_field, inventory_id, unit, created_at)
        SELECT id, analysis_id, dynamic_field, inventory_id, unit, created_at
        FROM lab_field_chemical_links_old
      ''');
      await db.execute('DROP TABLE lab_field_chemical_links_old');
    }
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
    await _ensureColumn(db, 'lab_analyses', 'parameter_id', 'parameter_id INTEGER REFERENCES parameters(id)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS material_parameter_bounds (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_id INTEGER NOT NULL REFERENCES reference_materials(id),
        parameter_id INTEGER NOT NULL REFERENCES parameters(id),
        parameter_type TEXT NOT NULL CHECK(parameter_type IN ('physical', 'chemical')),
        unit TEXT NOT NULL DEFAULT '',
        min_value REAL,
        max_value REAL,
        precision INTEGER,
        active INTEGER NOT NULL DEFAULT 1,
        UNIQUE(material_id, parameter_id)
      )
    ''');
    await _ensureColumn(db, 'lab_inventory', 'category', "category TEXT CHECK(category IN ('liquid', 'powder'))");
    await _ensureColumn(db, 'lab_field_chemical_links', 'kind', "kind TEXT NOT NULL DEFAULT 'link'");
    await _ensureColumn(db, 'lab_field_chemical_links', 'fixed_value', 'fixed_value REAL');
    await _ensureColumn(db, 'lab_field_chemical_links', 'list_values', 'list_values TEXT');

    // V2: identity + sync bookkeeping.
    await _migrateUsersTable(db);
    await _createSyncTables(db);
    for (final table in syncedTables) {
      // The per-row sync version mirrored from the Firestore envelope
      // (`remoteToLocalRow` writes it on every pull). `users` and
      // `inspection_status_history` already declared it; `decision_version`
      // on `inspections` is the *business* approval counter and stays
      // separate, so a normal edit does not look like a version bump.
      await _ensureColumn(db, table, 'version', 'version INTEGER NOT NULL DEFAULT 1');
      await _ensureColumn(db, table, 'remote_version', 'remote_version INTEGER NOT NULL DEFAULT 0');
      await _ensureColumn(db, table, 'remote_synced_at', 'remote_synced_at TEXT');
      await _ensureColumn(
          db, table, 'sync_state', "sync_state TEXT NOT NULL DEFAULT 'local'");
      await _ensureColumn(db, table, 'deleted_at', 'deleted_at TEXT');
    }
    await _ensureUnknownUserRow(db);
  }

  /// Reserved `users` row with `id = 0` (plan §6.6, D2).
  ///
  /// `inspections.created_by` and `inspection_status_history.changed_by` stay
  /// `INTEGER NOT NULL REFERENCES users(id)`, but a document pulled from
  /// another device carries the *Firebase uid* of the author, not a local id.
  /// When that member has not been mirrored on this device yet, the pull
  /// stores `0` - so the row has to exist, otherwise every pull of a sample
  /// written elsewhere dies on the foreign key.
  Future<void> _ensureUnknownUserRow(Database db) async {
    final existing = await db.query('users', where: 'id = 0', limit: 1);
    if (existing.isNotEmpty) return;
    await db.insert('users', {
      'id': 0,
      'uid': null,
      'email': 'unknown@local.invalid',
      'full_name': 'Unknown user',
      'role': 'viewer',
      'status': 'disabled',
      'permissions_json': '[]',
      'version': 1,
      'updated_at': '',
      'created_at': '',
    });
  }

  /// One-time rebuild of the pre-V2 `users` table (plan §6.6).
  ///
  /// Legacy rows kept their `username`/`password_hash`/`is_active` columns; the
  /// new table is email/UID based. `PRAGMA foreign_keys=OFF` + `integrity_check`
  /// guard the migration, all inside one transaction.
  Future<void> _migrateUsersTable(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(users)');
    if (cols.isEmpty) {
      await db.execute(_usersTableV2);
      return;
    }
    final names = cols.map((c) => '${c['name']}').toSet();
    if (!names.contains('password_hash') && !names.contains('username')) {
      // Already V2 (or freshly created): only make sure it exists.
      await db.execute(_usersTableV2);
      return;
    }

    await db.execute('PRAGMA foreign_keys=OFF');
    // Without legacy_alter_table, RENAME rewrites the REFERENCES clauses of
    // other tables (inspections.created_by → users_legacy_v1).
    await db.execute('PRAGMA legacy_alter_table=ON');
    try {
      await db.transaction((txn) async {
        await txn.execute('ALTER TABLE users RENAME TO users_legacy_v1');
        await txn.execute(_usersTableV2);
        final hasIsActive = names.contains('is_active');
        final rows = await txn.rawQuery('SELECT * FROM users_legacy_v1');
        var nextId = 1;
        for (final row in rows) {
          final email = '${row['username'] ?? ''}'.trim();
          final role = switch ('${row['role'] ?? ''}') {
            'Admin' || 'Developer' => 'admin',
            'Lab User' => 'lab',
            'Quality Manager' => 'quality_manager',
            _ => 'viewer',
          };
          final status = hasIsActive && (row['is_active'] as num?)?.toInt() == 0
              ? 'disabled'
              : 'active';
          await txn.insert('users', {
            'id': nextId,
            'uid': null,
            'member_id': null,
            'email': email.isEmpty ? 'legacy_$nextId@local.invalid' : email,
            'full_name': '${row['full_name'] ?? ''}',
            'role': role,
            'status': status,
            'permissions_json': '[]',
            'version': 1,
            'updated_at': '${row['created_at'] ?? ''}',
            'created_at': '${row['created_at'] ?? ''}',
            'sync_state': 'local',
          });
          nextId++;
        }
        await txn.execute('DROP TABLE users_legacy_v1');
      });
      final check = await db.rawQuery('PRAGMA integrity_check');
      final ok = check.isNotEmpty && '${check.first.values.first}'.trim() == 'ok';
      if (!ok) {
        throw StateError('integrity_check failed after users migration');
      }
    } finally {
      await db.execute('PRAGMA legacy_alter_table=OFF');
      await db.execute('PRAGMA foreign_keys=ON');
    }
  }

  Future<void> _ensureColumn(Database db, String table, String column, String spec) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final has = cols.any((c) => c['name'] == column);
    if (!has) {
      await db.execute('ALTER TABLE $table ADD COLUMN $spec');
    }
  }
}