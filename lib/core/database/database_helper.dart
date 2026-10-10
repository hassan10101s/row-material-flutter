import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
  void onDatabaseClosed(void Function() listener) =>
      _closeListeners.add(listener);

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
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.rawQuery('PRAGMA synchronous=NORMAL');
          await db.rawQuery('PRAGMA busy_timeout=5000');
          await db.rawQuery('PRAGMA temp_store=MEMORY');
          await db.rawQuery('PRAGMA cache_size=-20000');
          await db.rawQuery('PRAGMA mmap_size=268435456');
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
          await db.rawQuery('PRAGMA foreign_keys=ON');
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.rawQuery('PRAGMA synchronous=NORMAL');
          await db.rawQuery('PRAGMA busy_timeout=5000');
          await db.rawQuery('PRAGMA temp_store=MEMORY');
          await db.rawQuery('PRAGMA cache_size=-20000');
          await db.rawQuery('PRAGMA mmap_size=268435456');
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
        inspection_kind TEXT NOT NULL DEFAULT 'raw',
        product_id INTEGER REFERENCES lab_products(id),
        formula_number TEXT,
        batch_number TEXT,
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
        parameter_type TEXT DEFAULT 'chemical',
        imported_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        category TEXT,
        description TEXT,
        physical_reference_json TEXT NOT NULL DEFAULT '{}',
        chemical_reference_json TEXT NOT NULL DEFAULT '{}',
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
        is_required INTEGER NOT NULL DEFAULT 0,
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
        category TEXT CHECK(category IN ('liquid', 'powder', 'count')),
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
    await _createLabEquipmentTables(db);
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
        is_required INTEGER NOT NULL DEFAULT 0,
        UNIQUE(material_id, parameter_id)
      )
    ''');

    // QC Manager tables and their indexes are guaranteed by
    // `_runLegacyGuarantees`, which runs on every open - see the note there.
    // (Perf indexes too: they must run after the column guarantees, so they
    // live at the end of `_runLegacyGuarantees`, not here.)
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
    // Badge counters (`SyncQueue.countBadge`, `countBlocked`) filter on
    // `status` alone. The leftmost column of `idx_sync_queue_ready` covers
    // that, but an explicit narrow index guarantees an index-only COUNT
    // without depending on the composite's shape surviving future edits.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_queue_status
        ON sync_queue(status)
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
    // The conflicts COUNT (`resolution IS NULL OR resolution NOT IN (...)`)
    // had no index at all: every badge read full-scanned `sync_conflicts`,
    // including its up-to-900 kB `local_payload`/`remote_payload` TEXT pages.
    // That scan is what stalled bootstrap past the 2 s DbTrace budget while
    // the dashboard's own queries queued behind it on the single FFI isolate.
    // Declared after the table: `CREATE INDEX` on a missing table is a hard
    // error, and recovery/QC-schema tests open files without sync tables.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_conflicts_resolution
        ON sync_conflicts(resolution)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_conflicts_detected
        ON sync_conflicts(detected_at DESC, id DESC)
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
      'CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_logs(entity_type, entity_id, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_audit_time ON audit_logs(occurred_at DESC, id DESC)',
    );
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
    // A guarantee must never abort the open (see `_ensureColumn`): a legacy
    // or crash-damaged database may lack whole tables, and a missing table
    // must mean a skipped index, not an unopenable database. Columns are
    // deliberately NOT guarded: this runs at the end of
    // `_runLegacyGuarantees`, after every `_ensureColumn`, so a missing
    // column on an existing table is a real schema bug that must still throw.
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((r) => '${r['name']}').toSet();

    Future<void> index(String table, String sql) async {
      if (!tables.contains(table)) {
        debugPrint('[DatabaseHelper] skipping index on missing table "$table".');
        return;
      }
      try {
        await db.execute(sql);
      } on DatabaseException catch (e) {
        // A crash-damaged or hand-built legacy file can hold a stub table
        // that lacks even the indexed column (the migration-recovery tests
        // seed exactly such stubs). An index is pure performance: skip it
        // and let the query fall back to a scan rather than refusing to
        // open the user's data. Anything else is a real schema bug.
        final message = e.toString();
        if (message.contains('no such table') ||
            message.contains('no such column')) {
          debugPrint('[DatabaseHelper] skipping index: $e');
          return;
        }
        rethrow;
      }
    }

    await index(
      'lab_consumption_log',
      'CREATE INDEX IF NOT EXISTS idx_consumption_log_sample_test ON lab_consumption_log(sample_test_id)',
    );
    await index(
      'lab_consumption_log',
      'CREATE INDEX IF NOT EXISTS idx_consumption_log_inventory ON lab_consumption_log(inventory_id, reversal_of_log_id)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_created_at_desc ON inspections(created_at DESC, id DESC)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_date_created_desc ON inspections(inspection_date, created_at DESC, id DESC)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_inspection_date ON inspections(inspection_date)',
    );
    // Covers the `deleted_at IS NULL` working-set filter used by every list.
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_alive ON inspections(deleted_at, inspection_date DESC, id DESC)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_material_code_date ON inspections(material_code, inspection_date)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_material_id ON inspections(material_id)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_status ON inspections(decision_status)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_supplier ON inspections(supplier)',
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_entry_code ON inspections(entry_code)',
    );
    await index(
      'inspections',
      "CREATE INDEX IF NOT EXISTS idx_inspections_kind ON inspections(inspection_kind, deleted_at, inspection_date DESC, id DESC)",
    );
    await index(
      'inspections',
      'CREATE INDEX IF NOT EXISTS idx_inspections_product ON inspections(product_id)',
    );
    await index(
      'lab_sample_tests',
      'CREATE INDEX IF NOT EXISTS idx_sample_tests_worksheet_analysis ON lab_sample_tests(worksheet_row_id, analysis_id)',
    );
    await index(
      'lab_sample_tests',
      'CREATE INDEX IF NOT EXISTS idx_sample_tests_worksheet_entry_code ON lab_sample_tests(entry_code)',
    );
    await index(
      'lab_sample_tests',
      'CREATE INDEX IF NOT EXISTS idx_sample_tests_worksheet_row ON lab_sample_tests(worksheet_row_id)',
    );
    // listSampleTests / findTestsForAnalysisAndSource filters.
    await index(
      'lab_sample_tests',
      'CREATE INDEX IF NOT EXISTS idx_sample_tests_source ON lab_sample_tests(source_type, source_ref_id, tested_at DESC)',
    );
    await index(
      'lab_sample_tests',
      'CREATE INDEX IF NOT EXISTS idx_sample_tests_analysis ON lab_sample_tests(analysis_id)',
    );
    await index(
      'inspection_status_history',
      'CREATE INDEX IF NOT EXISTS idx_status_history_inspection_version ON inspection_status_history(inspection_id, version DESC, id DESC)',
    );
    await index(
      'lab_stock_adjustments',
      'CREATE INDEX IF NOT EXISTS idx_stock_adjustments_adj_at ON lab_stock_adjustments(adjusted_at DESC, id DESC)',
    );
    await index(
      'lab_stock_adjustments',
      'CREATE INDEX IF NOT EXISTS idx_stock_adjustments_inventory ON lab_stock_adjustments(inventory_id)',
    );
    // Lookup / ordering helpers (all previously full-scans).
    await index(
      'lab_worksheet',
      'CREATE INDEX IF NOT EXISTS idx_worksheet_status ON lab_worksheet(status, entry_code)',
    );
    await index(
      'lab_analysis_items',
      'CREATE INDEX IF NOT EXISTS idx_analysis_items_analysis ON lab_analysis_items(analysis_id)',
    );
    await index(
      'lab_field_chemical_links',
      'CREATE INDEX IF NOT EXISTS idx_field_links_analysis ON lab_field_chemical_links(analysis_id)',
    );
    await index(
      'lab_product_analyses',
      'CREATE INDEX IF NOT EXISTS idx_product_analyses_product ON lab_product_analyses(product_id)',
    );
    await index(
      'lab_material_analyses',
      'CREATE INDEX IF NOT EXISTS idx_material_analyses_material ON lab_material_analyses(material_id)',
    );
    await index(
      'material_parameter_bounds',
      'CREATE INDEX IF NOT EXISTS idx_bounds_param ON material_parameter_bounds(parameter_id)',
    );
    await index(
      'material_parameter_bounds',
      'CREATE INDEX IF NOT EXISTS idx_bounds_material ON material_parameter_bounds(material_id)',
    );
    await index(
      'lab_inventory',
      'CREATE INDEX IF NOT EXISTS idx_inventory_name ON lab_inventory(name COLLATE NOCASE)',
    );
    await index(
      'lab_products',
      'CREATE INDEX IF NOT EXISTS idx_products_name ON lab_products(name COLLATE NOCASE)',
    );
    await index(
      'lab_analyses',
      'CREATE INDEX IF NOT EXISTS idx_analyses_name ON lab_analyses(name COLLATE NOCASE)',
    );
    await index(
      'users',
      'CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)',
    );
    await index(
      'reference_materials',
      'CREATE INDEX IF NOT EXISTS idx_reference_active ON reference_materials(active)',
    );

    // QC Manager indexes live in `_createQcIndexes`, alongside the tables they
    // cover, so that a single call guarantees both. They are created after the
    // tables by `_runLegacyGuarantees` rather than from here.
  }

  /// Indexes for the QC Manager tables.
  ///
  /// Split from [_createIndexes] on purpose. SQLite resolves an index's columns
  /// when the index is created, so a QC index can only be created once its table
  /// exists - and because the schema version is pinned at 1, the QC tables have
  /// to be guaranteed on *every* open, not just `onCreate`. Keeping the tables
  /// and their indexes in one method makes it impossible to create one without
  /// the other, which is how `idx_qc_insps_date` came to reference an `id`
  /// column that `qc_inspections` does not have.
  ///
  /// Every statement is `IF NOT EXISTS`, so re-running this on each open costs
  /// a schema lookup and nothing else.
  Future<void> _createQcIndexes(Database db) async {
    // SOP
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sops_code ON qc_sops(code)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sops_status ON qc_sops(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sops_dept ON qc_sops(dept)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sops_active ON qc_sops(is_active)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sops_deleted ON qc_sops(deleted_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sop_revs_sop_rev ON qc_sop_revisions(sop_id, rev_no DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sop_reads_sop_rev ON qc_sop_reads(sop_id, rev_no)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sop_reads_user ON qc_sop_reads(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sop_audits_sop ON qc_sop_audits(sop_id, id)',
    );
    // Templates
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_templates_pub ON qc_templates(is_published, is_archived, deleted_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_templates_dept ON qc_templates(dept)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_sections_tpl ON qc_sections(template_id, order_index)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_items_tpl ON qc_items(template_id, order_index)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_items_sec ON qc_items(section_id, order_index)',
    );
    // Inspections - the reference index is what makes the NCR report's
    // lot/batch drilldown cheap, so it is deliberately (lot_no, batch_no).
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_insps_tpl ON qc_inspections(template_id, status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_insps_status ON qc_inspections(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_insps_date ON qc_inspections(inspection_date DESC, inspection_id DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_insps_ref ON qc_inspections(ref_type, ref_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_insps_inspector ON qc_inspections(inspector_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_insps_lot ON qc_inspections(lot_no, batch_no)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_insps_deleted ON qc_inspections(deleted_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_resps_insp ON qc_responses(inspection_id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_qc_resps_insp_item ON qc_responses(inspection_id, item_id)',
    );
    // NC / CAPA - (status, severity) and (assigned_to, status) are the two
    // columns the NCR dashboard groups and filters on.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_findings_insp ON qc_findings_nc(inspection_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_findings_status_sev ON qc_findings_nc(status, severity)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_findings_due ON qc_findings_nc(due_date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_findings_assigned ON qc_findings_nc(assigned_to, status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_findings_deleted ON qc_findings_nc(deleted_at)',
    );
    // The NCR report's default view filters on `created_at` and orders by
    // `finding_id`, so the range scan the dashboard does on every load is
    // covered here rather than by the `(status, severity)` index.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_findings_created ON qc_findings_nc(created_at DESC, finding_id DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_capa_finding ON qc_capa(finding_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_capa_status ON qc_capa(status, due_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_capa_assigned ON qc_capa(assigned_to, status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_capa_due ON qc_capa(due_at)',
    );
    // Audit - the chain is walked in id order, hence the trailing `id`.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_audits_entity ON qc_audits(entity_type, entity_id, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_audits_at ON qc_audits(at DESC, id DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_audits_actor ON qc_audits(by_user_id, at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_defcodes_active ON qc_defect_codes(is_active, category)',
    );
    // Goals
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goals_status ON qc_goals(status, due_date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goals_dept ON qc_goals(dept)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goals_owner ON qc_goals(owner_id, status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goals_due ON qc_goals(due_date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goals_deleted ON qc_goals(deleted_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goal_assign_goal ON qc_goal_assignments(goal_id, status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goal_assign_user ON qc_goal_assignments(assignee_id, status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goal_actions_goal ON qc_goal_actions(goal_id, status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goal_kpis_goal ON qc_goal_kpis(goal_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goal_links_goal ON qc_goal_links(goal_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_qc_goal_links_ref ON qc_goal_links(link_type, ref_id)',
    );
  }

  /// Makes the QC audit tables append-only at the storage layer.
  ///
  /// The repository already refuses to update or delete these rows, and the
  /// domain contract does not even declare a mutator - but a repository is Dart
  /// code, and Dart code has bugs, back doors and one-shot maintenance scripts.
  /// A `BEFORE UPDATE`/`BEFORE DELETE` trigger moves the guarantee down into
  /// SQLite itself, so the only way to rewrite history is to drop the trigger,
  /// which is a visible, deliberate act rather than a stray `db.update`.
  ///
  /// `RAISE(ABORT, ...)` rolls the statement back and surfaces the message;
  /// `RAISE(IGNORE)` would silently succeed and be far more dangerous.
  ///
  /// None of the QC tables that reference these use `ON DELETE CASCADE` (deletes
  /// are soft, via `deleted_at`), so blocking the delete cannot break a cascade.
  Future<void> _createQcAuditGuards(Database db) async {
    for (final table in const ['qc_audits', 'qc_sop_audits']) {
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_block_update
        BEFORE UPDATE ON $table
        BEGIN
          SELECT RAISE(ABORT, '$table is append-only: rows cannot be modified');
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_block_delete
        BEFORE DELETE ON $table
        BEGIN
          SELECT RAISE(ABORT, '$table is append-only: rows cannot be deleted');
        END
      ''');
    }
  }

  /// Idempotent legacy-guard migrations matching sqlite_db.py pragmas/rules.
  Future<void> _runLegacyGuarantees(Database db) async {
    await _rebuildFieldChemicalLinks(db);

    // NOTE: perf indexes are created at the END of this method, not here.
    // SQLite resolves an index's columns when the index is created, so an
    // index over a column that only the `_ensureColumn` guarantees below add
    // (e.g. `inspections.deleted_at`) kills a fresh open with "no such
    // column" if it runs first.

    // QC Manager (plan V6 §5.2): tables, then the indexes over them.
    //
    // This runs on *every* open, and that is the point. The schema version is
    // pinned at 1, so `onUpgrade` never fires and a `CREATE TABLE` added here
    // alone would only ever reach a brand-new database - every user who already
    // installed the app would keep a file with no `qc_goals`, and the first QC
    // query would fail with "no such table". Putting the tables under the
    // existing every-open guarantee is what makes the addition safe to ship
    // without a version bump.
    await _createQcTables(db);
    await _createQcIndexes(db);
    await _createQcAuditGuards(db);

    // `qc_sop_revisions` was created without these two. `_createQcTables` uses
    // `CREATE TABLE IF NOT EXISTS`, so it cannot add a column to a database that
    // already has the table, and an existing install would keep the old shape.
    // `publishSopRevision` writes `superseded_at` and the revision model carries
    // `edited_by_name`, so without this the first publish on an upgraded install
    // dies with "no such column".
    await _ensureColumn(
      db,
      'qc_sop_revisions',
      'superseded_at',
      'superseded_at TEXT',
    );
    await _ensureColumn(
      db,
      'qc_sop_revisions',
      'edited_by_name',
      "edited_by_name TEXT NOT NULL DEFAULT ''",
    );

    // The same story for three more columns P3 writes but P1 never declared:
    // `published_at` when an SOP is published, `deleted_at` on the two checklist
    // child tables so a template edit can retire its old sections and items
    // instead of destroying rows that a past inspection still points at, and
    // `qc_goals.version` so a goal edit can be made the same way an SOP edit
    // is: optimistic-concurrency checked instead of last-writer-wins.
    await _ensureColumn(db, 'qc_sops', 'published_at', 'published_at TEXT');
    await _ensureColumn(db, 'qc_sections', 'deleted_at', 'deleted_at TEXT');
    await _ensureColumn(db, 'qc_items', 'deleted_at', 'deleted_at TEXT');
    // Plan §3: periodic task lists — safe ALTER, existing rows stay 'once'.
    await _ensureColumn(
      db,
      'qc_templates',
      'recurrence',
      "recurrence TEXT NOT NULL DEFAULT 'once'",
    );
    await _ensureColumn(
      db,
      'qc_goals',
      'version',
      'version INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      db,
      'qc_goal_kpis',
      'higher_is_better',
      'higher_is_better INTEGER NOT NULL DEFAULT 1',
    );

    await _ensureColumn(db, 'inspections', 'expiry_date', 'expiry_date TEXT');
    await _ensureColumn(
      db,
      'inspections',
      'specialist_name',
      "specialist_name TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      'inspections',
      'decision_version',
      'decision_version INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      db,
      'lab_analyses',
      'formula_json',
      "formula_json TEXT NOT NULL DEFAULT '{}'",
    );
    await _ensureColumn(db, 'lab_constants', 'unit_dim', 'unit_dim TEXT');
    await _ensureColumn(
      db,
      'lab_sample_tests',
      'entry_code',
      'entry_code TEXT',
    );
    await _ensureColumn(
      db,
      'lab_sample_tests',
      'worksheet_row_id',
      'worksheet_row_id INTEGER',
    );
    await _ensureColumn(db, 'lab_worksheet', 'entry_code', 'entry_code TEXT');
    await _ensureColumn(
      db,
      'lab_worksheet',
      'status',
      "status TEXT NOT NULL DEFAULT 'ACTIVE'",
    );
    await _ensureColumn(
      db,
      'lab_consumption_log',
      'requested_qty',
      'requested_qty REAL',
    );
    await _ensureColumn(
      db,
      'lab_consumption_log',
      'applied_qty',
      'applied_qty REAL',
    );
    await _ensureColumn(
      db,
      'lab_consumption_log',
      'shortfall_qty',
      'shortfall_qty REAL NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      'lab_consumption_log',
      'event_type',
      "event_type TEXT NOT NULL DEFAULT 'CONSUMPTION'",
    );
    await _ensureColumn(
      db,
      'lab_consumption_log',
      'reversal_of_log_id',
      'reversal_of_log_id INTEGER',
    );
    await _ensureColumn(
      db,
      'reference_materials',
      'active',
      'active INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      db,
      'lab_products',
      'active',
      'active INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      db,
      'lab_analyses',
      'active',
      'active INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      db,
      'lab_analyses',
      'parameter_id',
      'parameter_id INTEGER REFERENCES parameters(id)',
    );
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
        is_required INTEGER NOT NULL DEFAULT 0,
        UNIQUE(material_id, parameter_id)
      )
    ''');
    await _ensureColumn(
      db,
      'lab_inventory',
      'category',
      "category TEXT CHECK(category IN ('liquid', 'powder', 'count'))",
    );
    // Old installs carry CHECK(category IN ('liquid','powder')) on the
    // column, which SQLite cannot ALTER: rebuild the table once so the
    // `count` category (pieces only) can be stored. Existing rows are
    // liquid/powder, so no data changes — only the constraint widens.
    await _migrateInventoryCategoryCheck(db);
    // مطلوب flag per field: which physical/chemical params must have a value
    // at inspection time. JSON-embedded for materials (no backfill needed),
    // column-backed for product ranges + material bounds.
    await _ensureColumn(
      db,
      'lab_product_analyses',
      'is_required',
      'is_required INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      'material_parameter_bounds',
      'is_required',
      'is_required INTEGER NOT NULL DEFAULT 0',
    );
    // Lab equipment registry (device-local, like inventory): master table +
    // event log. Idempotent so existing installs gain them on next open.
    await _createLabEquipmentTables(db);
    // Lab products carry the same physical/chemical reference maps as
    // materials now (the product editor mirrors the material editor).
    await _ensureColumn(
      db,
      'lab_products',
      'physical_reference_json',
      "physical_reference_json TEXT NOT NULL DEFAULT '{}'",
    );
    await _ensureColumn(
      db,
      'lab_products',
      'chemical_reference_json',
      "chemical_reference_json TEXT NOT NULL DEFAULT '{}'",
    );
    await _ensureColumn(
      db,
      'lab_field_chemical_links',
      'kind',
      "kind TEXT NOT NULL DEFAULT 'link'",
    );
    await _ensureColumn(
      db,
      'lab_field_chemical_links',
      'fixed_value',
      'fixed_value REAL',
    );
    await _ensureColumn(
      db,
      'lab_field_chemical_links',
      'list_values',
      'list_values TEXT',
    );

    // V2: identity + sync bookkeeping.
    await _migrateUsersTable(db);
    await _createSyncTables(db);
    for (final table in syncedTables) {
      // The per-row sync version mirrored from the Firestore envelope
      // (`remoteToLocalRow` writes it on every pull). `users` and
      // `inspection_status_history` already declared it; `decision_version`
      // on `inspections` is the *business* approval counter and stays
      // separate, so a normal edit does not look like a version bump.
      await _ensureColumn(
        db,
        table,
        'version',
        'version INTEGER NOT NULL DEFAULT 1',
      );
      await _ensureColumn(
        db,
        table,
        'remote_version',
        'remote_version INTEGER NOT NULL DEFAULT 0',
      );
      await _ensureColumn(
        db,
        table,
        'remote_synced_at',
        'remote_synced_at TEXT',
      );
      await _ensureColumn(
        db,
        table,
        'sync_state',
        "sync_state TEXT NOT NULL DEFAULT 'local'",
      );
      await _ensureColumn(db, table, 'deleted_at', 'deleted_at TEXT');
    }
    // Product inspections (same `inspections` table, `inspection_kind='product'`):
    // the kind/product/formula/batch columns for existing installs. The
    // sentinel material row that product rows point at (`material_id` is
    // NOT NULL + FK-enforced, and a lab product is not a reference material)
    // is created lazily by `ensureProductSentinelMaterialId` on the first
    // product save — never at open — so it can never steal `id = 1` from a
    // fresh database's first real material.
    await _ensureColumn(
      db,
      'inspections',
      'inspection_kind',
      "inspection_kind TEXT NOT NULL DEFAULT 'raw'",
    );
    await _ensureColumn(
      db,
      'inspections',
      'product_id',
      'product_id INTEGER REFERENCES lab_products(id)',
    );
    await _ensureColumn(
      db,
      'inspections',
      'formula_number',
      'formula_number TEXT',
    );
    await _ensureColumn(
      db,
      'inspections',
      'batch_number',
      'batch_number TEXT',
    );
    // Units registry: every unit string used anywhere in the program must
    // appear in `lab_units` so all pickers inherit from one table.
    await _backfillLabUnits(db);
    await _ensureUnknownUserRow(db);
    // Perf indexes are IF NOT EXISTS: running here (every open) migrates
    // existing installs that were created before the index existed, and fresh
    // databases get them too. This MUST stay last: SQLite resolves an index's
    // columns at creation time, so any index over an ensured column
    // (`inspections.deleted_at`, ...) has to run after the guarantees above.
    await _createIndexes(db);
  }

  /// Registers every unit symbol used across the database into `lab_units`.
  ///
  /// Idempotent (`INSERT OR IGNORE` on the UNIQUE symbol): runs on every open
  /// so a unit typed anywhere — parameters, analyses, inventory, constants,
  /// QC checklists/goals — shows up in the Units table and becomes pickable
  /// everywhere else. Each source is guarded so a missing table/column on an
  /// old install skips instead of failing the open.
  static const List<(String, String)> _unitSources = [
    ('parameters', 'unit'),
    ('lab_analyses', 'unit'),
    ('lab_analysis_items', 'unit'),
    ('lab_inventory', 'unit'),
    ('lab_constants', 'unit'),
    ('lab_product_analyses', 'unit'),
    ('lab_field_chemical_links', 'unit'),
    ('material_parameter_bounds', 'unit'),
    ('qc_items', 'unit'),
    ('qc_inspections', 'qty_unit'),
    ('qc_findings_nc', 'qty_unit'),
    ('qc_goals', 'target_unit'),
    ('qc_goal_kpis', 'unit'),
  ];

  /// Fallback symbols that must exist even on an empty database (the old
  /// hardcoded `inventoryUnits` plus the lab default `%`).
  static const List<String> _defaultUnits = [
    '%',
    'L',
    'mL',
    'kg',
    'g',
    'pc',
  ];

  Future<void> _backfillLabUnits(Database db) async {
    final stamp = DateTime.now().toIso8601String();
    for (final symbol in _defaultUnits) {
      try {
        await db.rawInsert(
          'INSERT OR IGNORE INTO lab_units (symbol, is_active, created_at) '
          'VALUES (?, 1, ?)',
          [symbol, stamp],
        );
      } catch (_) {
        // `lab_units` itself missing would already have failed earlier DDL.
      }
    }
    final existing =
        (await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        )).map((r) => '${r['name']}').toSet();
    for (final (table, column) in _unitSources) {
      if (!existing.contains(table)) continue;
      try {
        await db.rawInsert(
          'INSERT OR IGNORE INTO lab_units (symbol, is_active, created_at) '
          'SELECT DISTINCT TRIM("$column"), 1, ? FROM "$table" '
          'WHERE TRIM(COALESCE("$column", \'\')) <> \'\'',
          [stamp],
        );
      } catch (_) {
        // Missing column on an old install: skip, the column guarantee
        // above will add it and the next open picks the values up.
      }
    }
  }

  /// Current definition of `lab_field_chemical_links`.
  static const String _fclTableV2 = '''
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
  ''';

  /// Columns the pre-V2 table shares with [_fclTableV2]. `inventory_id` was
  /// `NOT NULL` before value/list configs needed a NULL, so a legacy row can
  /// legitimately be dropped here only if that constraint is being lifted.
  static const List<String> _fclCarriedColumns = [
    'id',
    'analysis_id',
    'dynamic_field',
    'inventory_id',
    'unit',
    'created_at',
  ];

  /// Rebuilds the pre-V2 `lab_field_chemical_links` table exactly once.
  ///
  /// The table gained `kind`/`fixed_value`/`list_values` and a nullable
  /// `inventory_id`, which SQLite cannot add to a NOT NULL foreign key in place,
  /// so the upgrade is a rename → create → copy → drop cycle.
  ///
  /// That cycle used to run outside a transaction, on *every* open (the schema
  /// version is pinned at 1, so `onUpgrade` never fires). A process death
  /// between the rename and the drop left the live table missing while its rows
  /// sat in `..._old`; the next open then saw an empty `PRAGMA table_info`,
  /// decided there was nothing to rebuild, and fell through to
  /// `_ensureColumn('lab_field_chemical_links', 'kind', ...)` — an `ALTER TABLE`
  /// against a table that no longer exists. The open threw and the database was
  /// permanently unopenable, with no path back.
  ///
  /// Two changes close that: the whole cycle is now one transaction, so an
  /// interrupted upgrade rolls back instead of leaving a half-migrated schema;
  /// and a database already stuck in that half-state is detected and finished
  /// rather than abandoned.
  Future<void> _rebuildFieldChemicalLinks(Database db) async {
    final cols = await db.rawQuery(
      'PRAGMA table_info(lab_field_chemical_links)',
    );
    if (cols.isNotEmpty && cols.any((c) => c['name'] == 'kind')) return;

    // Nothing to carry over on a database that was never created.
    if (cols.isEmpty) {
      final orphan = await db.rawQuery(
        'PRAGMA table_info(lab_field_chemical_links_old)',
      );
      if (orphan.isEmpty) return;
    }

    await db.transaction((txn) async {
      if (await _tableExists(txn, 'lab_field_chemical_links')) {
        await txn.execute(
          'ALTER TABLE lab_field_chemical_links '
          'RENAME TO lab_field_chemical_links_old',
        );
      }
      await txn.execute(_fclTableV2);

      final legacy = await txn.rawQuery(
        'PRAGMA table_info(lab_field_chemical_links_old)',
      );
      if (legacy.isNotEmpty) {
        final present = legacy.map((c) => '${c['name']}').toSet();
        final carried = _fclCarriedColumns
            .where(present.contains)
            .toList(growable: false);
        if (carried.isNotEmpty) {
          final columns = carried.join(', ');
          await txn.execute(
            'INSERT INTO lab_field_chemical_links ($columns) '
            'SELECT $columns FROM lab_field_chemical_links_old',
          );
        }
      }
      await txn.execute('DROP TABLE IF EXISTS lab_field_chemical_links_old');
    });
  }

  Future<bool> _tableExists(DatabaseExecutor db, String table) async =>
      (await db.rawQuery('PRAGMA table_info($table)')).isNotEmpty;

  /// Reserved `users` row with `id = 0` (plan §6.6, D2).
  ///
  /// `inspections.created_by` and `inspection_status_history.changed_by` stay
  /// `INTEGER NOT NULL REFERENCES users(id)`, but a document pulled from
  /// another device carries the *Firebase uid* of the author, not a local id.
  /// When that member has not been mirrored on this device yet, the pull
  /// stores `0` - so the row has to exist, otherwise every pull of a sample
  /// written elsewhere dies on the foreign key.
  /// Sentinel reference material that product-inspection rows point at.
  ///
  /// `inspections.material_id` is `NOT NULL REFERENCES reference_materials(id)`
  /// with FK enforcement ON, but a production batch references a *lab product*,
  /// not a reference material (its real link is `inspections.product_id`). The
  /// sentinel absorbs the FK the same way the `users.id = 0` row does for
  /// author columns. It is `active = 0` plus a reserved name, so the material
  /// pickers (`active = 1`) never show it; `listAllMaterials` filters it by
  /// name as well.
  static const String productSentinelMaterialName = '__PRODUCT_SENTINEL__';

  Future<int> ensureProductSentinelMaterialId(DatabaseExecutor db) async {
    final rows = await db.query(
      'reference_materials',
      columns: ['id'],
      where: 'material_name = ?',
      whereArgs: [productSentinelMaterialName],
      limit: 1,
    );
    if (rows.isNotEmpty) return (rows.first['id'] as num).toInt();
    return db.insert('reference_materials', {
      'material_name': productSentinelMaterialName,
      'material_code': 'PRD',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': DateTime.now().toIso8601String(),
      'active': 0,
    });
  }

  /// Widens `lab_inventory.category` CHECK to include `count`.
  ///
  /// Runs only when the stored table SQL still names the old two-value
  /// check; fresh databases already create the wide one. Follows the same
  /// guarded rebuild as [_migrateUsersTable]: FKs off, rename, recreate,
  /// copy with ids preserved, drop, integrity check, FKs back on.
  Future<void> _migrateInventoryCategoryCheck(Database db) async {
    final schema = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'lab_inventory'",
    );
    if (schema.isEmpty) return;
    final sql = '${schema.first['sql'] ?? ''}';
    if (sql.contains("'count'")) return;
    await db.rawQuery('PRAGMA foreign_keys=OFF');
    await db.rawQuery('PRAGMA legacy_alter_table=ON');
    try {
      await db.transaction((txn) async {
        await txn.execute('ALTER TABLE lab_inventory RENAME TO lab_inventory_legacy_v1');
        await txn.execute('''
          CREATE TABLE lab_inventory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            category TEXT CHECK(category IN ('liquid', 'powder', 'count')),
            unit TEXT,
            current_qty REAL NOT NULL DEFAULT 0,
            min_qty REAL NOT NULL DEFAULT 0,
            description TEXT,
            created_by INTEGER,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await txn.execute('''
          INSERT INTO lab_inventory
            (id, name, category, unit, current_qty, min_qty, description,
             created_by, created_at, updated_at)
          SELECT id, name, category, unit, current_qty, min_qty, description,
             created_by, created_at, updated_at
          FROM lab_inventory_legacy_v1
        ''');
        // Rows counted in pieces (tablets and the like) were stored under
        // liquid/powder before the `count` category existed; pieces can only
        // be `count` now, so normalize them instead of stranding the rows
        // behind a validation their own editor can no longer satisfy.
        await txn.execute('''
          UPDATE lab_inventory SET category = 'count'
          WHERE LOWER(TRIM(unit)) = 'pc' AND category != 'count'
        ''');
        await txn.execute('DROP TABLE lab_inventory_legacy_v1');
        await txn.execute(
          'UPDATE sqlite_sequence SET seq = (SELECT MAX(id) FROM lab_inventory) '
          "WHERE name = 'lab_inventory'",
        );
      });
      final check = await db.rawQuery('PRAGMA integrity_check');
      final ok =
          check.isNotEmpty && '${check.first.values.first}'.trim() == 'ok';
      if (!ok) {
        throw StateError('integrity_check failed after inventory migration');
      }
    } finally {
      await db.rawQuery('PRAGMA legacy_alter_table=OFF');
      await db.rawQuery('PRAGMA foreign_keys=ON');
    }
  }

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

    await db.rawQuery('PRAGMA foreign_keys=OFF');
    // Without legacy_alter_table, RENAME rewrites the REFERENCES clauses of
    // other tables (inspections.created_by → users_legacy_v1).
    await db.rawQuery('PRAGMA legacy_alter_table=ON');
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
      final ok =
          check.isNotEmpty && '${check.first.values.first}'.trim() == 'ok';
      if (!ok) {
        throw StateError('integrity_check failed after users migration');
      }
    } finally {
      await db.rawQuery('PRAGMA legacy_alter_table=OFF');
      await db.rawQuery('PRAGMA foreign_keys=ON');
    }
  }

  /// Lab equipment registry (device-local, like inventory): one master row
  /// per device plus its calibration/maintenance/repair log.
  ///
  /// Idempotent (`IF NOT EXISTS`): called from both `_createSchema` (fresh
  /// installs) and `_runLegacyGuarantees` (every open, so existing installs
  /// gain the tables without a version bump).
  Future<void> _createLabEquipmentTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_equipment (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        code TEXT NOT NULL UNIQUE,
        manufacturer TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        last_calibration_date TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_equipment_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        equipment_id INTEGER NOT NULL REFERENCES lab_equipment(id) ON DELETE CASCADE,
        event_type TEXT NOT NULL DEFAULT 'calibration',
        event_date TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_equipment_events_equipment
        ON lab_equipment_events(equipment_id, event_date DESC, id DESC)
    ''');
  }

  Future<void> _ensureColumn(
    Database db,
    String table,
    String column,
    String spec,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.isEmpty) {
      // A table that is not there cannot gain a column, and `ALTER TABLE` on a
      // missing table throws - which would abort the open and leave the user
      // with no way into their data at all. Report it and move on: an absent
      // table is a degraded database, an unopenable one is a lost one.
      debugPrint(
        '[DatabaseHelper] cannot add "$column": table "$table" does not exist.',
      );
      return;
    }
    final has = cols.any((c) => c['name'] == column);
    if (!has) {
      await db.execute('ALTER TABLE $table ADD COLUMN $spec');
    }
  }

  /// QC Manager schema (plan V6 §5.2 + V6_ENHANCED §12.1).
  ///
  /// Split out of [_createSchema] purely for readability - same idempotent
  /// `IF NOT EXISTS` contract, same call site, and `_runLegacyGuarantees` still
  /// runs after it on every open.
  ///
  /// Three conventions differ from the rest of this file, and deliberately:
  ///
  /// * **Person columns are `TEXT` holding a Firebase uid**, not
  ///   `INTEGER REFERENCES users(id)`. `inspections.created_by` needs the
  ///   `INTEGER` form because the reserved `users.id = 0` row exists to absorb a
  ///   foreign key arriving on a pull; nothing here is pulled from another
  ///   device, and a uid is the only identifier a QC row written offline can be
  ///   sure of.
  /// * **Soft delete is `deleted_at TEXT`**, matching `InspectionRepo.aliveFilter`
  ///   (`deleted_at IS NULL`) rather than the older `is_deleted` columns.
  /// * **`qc_audits` / `qc_sop_audits` are append-only.** Nothing in this file can
  ///   enforce that - it is a repository contract (V6_ENHANCED §21) - but they
  ///   carry `immutable` plus the `prev_hash`/`hash` chain so that a tamper is
  ///   detectable after the fact.
  Future<void> _createQcTables(Database db) async {
    // ── SOP Management ─────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_sops (
        sop_id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        category TEXT,
        dept TEXT,
        site TEXT,
        status TEXT NOT NULL CHECK(status IN ('Draft','Pending','Approved','Published','Obsolete','Archived')) DEFAULT 'Draft',
        content_type TEXT CHECK(content_type IN ('text','file')) DEFAULT 'text',
        content_text TEXT,
        file_url TEXT,
        file_name TEXT,
        mime_type TEXT,
        rev_no INTEGER NOT NULL DEFAULT 0,
        effective_date TEXT,
        published_at TEXT,
        expiry_date TEXT,
        is_active INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        owner_id TEXT,
        approver_id TEXT,
        approved_at TEXT,
        reviewed_at TEXT,
        rejection_reason TEXT,
        tags TEXT,
        criticality TEXT CHECK(criticality IN ('Low','Medium','High','Critical')) DEFAULT 'Medium',
        view_roles TEXT,
        edit_roles TEXT,
        approve_roles TEXT,
        publish_roles TEXT,
        requires_read_ack INTEGER NOT NULL DEFAULT 1,
        read_ack_mandatory INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        version_hash TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_sop_revisions (
        rev_id INTEGER PRIMARY KEY AUTOINCREMENT,
        sop_id INTEGER NOT NULL,
        rev_no INTEGER NOT NULL,
        content_text TEXT,
        file_url TEXT,
        file_name TEXT,
        mime_type TEXT,
        change_reason TEXT NOT NULL,
        edited_by TEXT,
        edited_at TEXT NOT NULL,
        diff_summary TEXT,
        prev_rev_id_ref TEXT,
        content_hash TEXT,
        is_published_rev INTEGER NOT NULL DEFAULT 0,
        edited_by_name TEXT NOT NULL DEFAULT '',
        superseded_at TEXT,
        FOREIGN KEY(sop_id) REFERENCES qc_sops(sop_id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_sop_reads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sop_id INTEGER NOT NULL,
        rev_no INTEGER NOT NULL,
        user_id TEXT NOT NULL,
        user_name TEXT,
        read_at TEXT NOT NULL,
        signature_base64 TEXT,
        device_id TEXT,
        ip_address TEXT,
        geo TEXT,
        ack_method TEXT CHECK(ack_method IN ('manual','signature','biometric')) DEFAULT 'manual',
        FOREIGN KEY(sop_id) REFERENCES qc_sops(sop_id) ON DELETE CASCADE,
        UNIQUE(sop_id, rev_no, user_id)
      )
    ''');
    // Append-only, hash-chained (V6_ENHANCED §21).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_sop_audits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sop_id INTEGER,
        rev_no INTEGER,
        action TEXT NOT NULL,
        entity TEXT CHECK(entity IN ('SOP','SOP_REV','SOP_READ','APPROVAL')) DEFAULT 'SOP',
        by_user_id TEXT,
        by_user_name TEXT,
        at TEXT NOT NULL,
        meta_json TEXT,
        prev_hash TEXT,
        hash TEXT,
        immutable INTEGER NOT NULL DEFAULT 1
      )
    ''');

    // ── Checklist Templates ────────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_templates (
        template_id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        code TEXT UNIQUE,
        type TEXT CHECK(type IN ('Incoming','InProcess','Final','Packing','Process','RawMaterial','FinishedGoods','Calibration','Other')) DEFAULT 'Other',
        dept TEXT,
        site TEXT,
        category TEXT,
        description TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        is_published INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        requires_approval_on_submit INTEGER NOT NULL DEFAULT 0,
        allow_na INTEGER NOT NULL DEFAULT 1,
        enforce_evidence_on_fail INTEGER NOT NULL DEFAULT 1,
        block_submit_if_critical_fail INTEGER NOT NULL DEFAULT 1,
        owner_id TEXT,
        published_by TEXT,
        published_at TEXT,
        effective_date TEXT,
        expiry_date TEXT,
        tags TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        revision_note TEXT,
        recurrence TEXT NOT NULL DEFAULT 'once'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_sections (
        section_id INTEGER PRIMARY KEY AUTOINCREMENT,
        template_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        description TEXT,
        order_index INTEGER NOT NULL DEFAULT 0,
        is_collapsible INTEGER NOT NULL DEFAULT 1,
        required_all INTEGER NOT NULL DEFAULT 0,
        conditional_rule_json TEXT,
        deleted_at TEXT,
        FOREIGN KEY(template_id) REFERENCES qc_templates(template_id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_items (
        item_id INTEGER PRIMARY KEY AUTOINCREMENT,
        section_id INTEGER NOT NULL,
        template_id INTEGER NOT NULL,
        label TEXT NOT NULL,
        item_type TEXT CHECK(item_type IN ('bool','passfail','na','text','number','date','dropdown','multiselect','photo','signature')) DEFAULT 'passfail',
        order_index INTEGER NOT NULL DEFAULT 0,
        required INTEGER NOT NULL DEFAULT 1,
        allow_na INTEGER NOT NULL DEFAULT 1,
        is_critical INTEGER NOT NULL DEFAULT 0,
        require_evidence_if_fail INTEGER NOT NULL DEFAULT 1,
        require_evidence_if_value INTEGER NOT NULL DEFAULT 0,
        default_value TEXT,
        options_json TEXT,
        unit TEXT,
        min_value REAL,
        max_value REAL,
        tolerance REAL,
        tolerance_type TEXT CHECK(tolerance_type IN ('abs','pct')) DEFAULT 'abs',
        validation_rule_json TEXT,
        conditional_show_json TEXT,
        fail_trigger_json TEXT,
        help_text TEXT,
        defect_code TEXT,
        deleted_at TEXT,
        FOREIGN KEY(section_id) REFERENCES qc_sections(section_id) ON DELETE CASCADE,
        FOREIGN KEY(template_id) REFERENCES qc_templates(template_id) ON DELETE CASCADE
      )
    ''');

    // ── Inspection Execution ───────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_inspections (
        inspection_id INTEGER PRIMARY KEY AUTOINCREMENT,
        template_id INTEGER NOT NULL,
        template_version INTEGER NOT NULL DEFAULT 1,
        ref_type TEXT CHECK(ref_type IN ('Job','Batch','Lot','PO','GRN','Material','WIP','FG','Order','Other')) DEFAULT 'Other',
        ref_id TEXT,
        lot_no TEXT,
        batch_no TEXT,
        po_no TEXT,
        grn_no TEXT,
        qty_inspected REAL,
        qty_unit TEXT,
        dept TEXT,
        site TEXT,
        location TEXT,
        line TEXT,
        work_center TEXT,
        status TEXT CHECK(status IN ('InProgress','Submitted','Reviewed','Approved','Rejected','Closed')) DEFAULT 'InProgress',
        result_overall TEXT CHECK(result_overall IN ('Pass','Conditional','Fail','Pending')) DEFAULT 'Pending',
        score_pct REAL,
        has_nc INTEGER NOT NULL DEFAULT 0,
        nc_count INTEGER NOT NULL DEFAULT 0,
        critical_nc_count INTEGER NOT NULL DEFAULT 0,
        major_nc_count INTEGER NOT NULL DEFAULT 0,
        minor_nc_count INTEGER NOT NULL DEFAULT 0,
        inspector_id TEXT,
        inspector_name TEXT,
        reviewer_id TEXT,
        reviewer_name TEXT,
        approved_by TEXT,
        approved_by_name TEXT,
        submitted_at TEXT,
        reviewed_at TEXT,
        approved_at TEXT,
        rejected_at TEXT,
        closed_at TEXT,
        inspection_date TEXT NOT NULL,
        start_at TEXT,
        end_at TEXT,
        shift TEXT,
        remarks TEXT,
        review_comments TEXT,
        rejection_reason TEXT,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_responses (
        resp_id INTEGER PRIMARY KEY AUTOINCREMENT,
        inspection_id INTEGER NOT NULL,
        item_id INTEGER NOT NULL,
        section_id INTEGER,
        result TEXT CHECK(result IN ('Pass','Fail','NA')) NOT NULL,
        value TEXT,
        value_type TEXT,
        notes TEXT,
        photos_json TEXT,
        signature_base64 TEXT,
        measured_at TEXT,
        measured_value REAL,
        defect_code TEXT,
        is_critical_failure INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(inspection_id) REFERENCES qc_inspections(inspection_id) ON DELETE CASCADE,
        FOREIGN KEY(item_id) REFERENCES qc_items(item_id)
      )
    ''');

    // ── Non-Conformance & CAPA ─────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_findings_nc (
        finding_id INTEGER PRIMARY KEY AUTOINCREMENT,
        inspection_id INTEGER NOT NULL,
        item_id INTEGER,
        resp_id INTEGER,
        code TEXT,
        severity TEXT CHECK(severity IN ('Minor','Major','Critical')) NOT NULL,
        category TEXT,
        description TEXT NOT NULL,
        status TEXT CHECK(status IN ('Open','Assigned','InProgress','Verified','Closed','Rejected')) DEFAULT 'Open',
        type TEXT CHECK(type IN ('NonConformance','Observation','Deviation')) DEFAULT 'NonConformance',
        due_date TEXT,
        assigned_to TEXT,
        assigned_to_name TEXT,
        assigned_at TEXT,
        root_cause TEXT,
        action_plan TEXT,
        proposed_action TEXT,
        qty_affected REAL,
        qty_unit TEXT,
        disposition TEXT CHECK(disposition IN ('Rework','Scrap','UseAsIs','Return','Concession','Pending')) DEFAULT 'Pending',
        verified_by TEXT,
        verified_by_name TEXT,
        verified_at TEXT,
        closed_at TEXT,
        closed_by TEXT,
        rejected_at TEXT,
        rejection_reason TEXT,
        evidence_json TEXT,
        capa_id INTEGER,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        FOREIGN KEY(inspection_id) REFERENCES qc_inspections(inspection_id) ON DELETE CASCADE,
        FOREIGN KEY(resp_id) REFERENCES qc_responses(resp_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_capa (
        capa_id INTEGER PRIMARY KEY AUTOINCREMENT,
        finding_id INTEGER NOT NULL,
        capa_no TEXT UNIQUE,
        type TEXT CHECK(type IN ('Corrective','Preventive','CorrectivePreventive')) DEFAULT 'Corrective',
        title TEXT,
        description TEXT,
        root_cause TEXT,
        root_cause_method TEXT CHECK(root_cause_method IN ('5Why','Fishbone','Ishikawa','Other')) DEFAULT 'Other',
        action_plan TEXT NOT NULL,
        action_steps_json TEXT,
        assigned_to TEXT,
        assigned_to_name TEXT,
        dept TEXT,
        status TEXT CHECK(status IN ('Open','InProgress','ActionComplete','VerificationPending','VerifiedEffective','VerifiedIneffective','Closed','Rejected')) DEFAULT 'Open',
        priority TEXT CHECK(priority IN ('Low','Medium','High','Critical')) DEFAULT 'Medium',
        due_at TEXT,
        target_completion_at TEXT,
        action_completed_at TEXT,
        action_completed_by TEXT,
        action_completion_notes TEXT,
        verified_by TEXT,
        verified_by_name TEXT,
        verified_at TEXT,
        verification_notes TEXT,
        is_effective INTEGER NOT NULL DEFAULT 0,
        effectiveness_checked_at TEXT,
        effectiveness_notes TEXT,
        closure_notes TEXT,
        closed_at TEXT,
        closed_by TEXT,
        rejected_at TEXT,
        rejection_reason TEXT,
        evidence_json TEXT,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        FOREIGN KEY(finding_id) REFERENCES qc_findings_nc(finding_id) ON DELETE CASCADE
      )
    ''');

    // ── Global Audit (append-only) ─────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_audits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL CHECK(entity_type IN ('SOP','SOP_REV','SOP_READ','TEMPLATE','SECTION','ITEM','INSPECTION','RESPONSE','FINDING','CAPA','GOAL','GOAL_ASSIGNMENT','GOAL_ACTION','NCR','APPROVAL')),
        entity_id TEXT,
        action TEXT NOT NULL,
        by_user_id TEXT,
        by_user_name TEXT,
        at TEXT NOT NULL,
        before_json TEXT,
        after_json TEXT,
        meta_json TEXT,
        prev_hash TEXT,
        hash TEXT,
        immutable INTEGER NOT NULL DEFAULT 1,
        ip_address TEXT,
        device_id TEXT
      )
    ''');

    // ── Master Data ────────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_defect_codes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        description TEXT,
        category TEXT,
        severity TEXT CHECK(severity IN ('Minor','Major','Critical')) DEFAULT 'Minor',
        default_type TEXT CHECK(default_type IN ('NonConformance','Observation','Deviation')) DEFAULT 'NonConformance',
        suggested_capa TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        dept TEXT
      )
    ''');

    // ── Goal Tracking (V6_ENHANCED §12.1) ──────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_goals (
        goal_id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        description TEXT,
        goal_type TEXT CHECK(goal_type IN ('SOP','Training','NC','CAPA','Audit','KPI','Compliance','Other')) DEFAULT 'Other',
        dept TEXT,
        site TEXT,
        priority TEXT CHECK(priority IN ('Low','Medium','High','Critical')) DEFAULT 'Medium',
        status TEXT NOT NULL CHECK(status IN ('Draft','Active','OnHold','Completed','Cancelled','Archived')) DEFAULT 'Draft',
        target_value REAL,
        target_unit TEXT,
        baseline_value REAL,
        current_value REAL,
        start_date TEXT NOT NULL,
        due_date TEXT,
        completed_at TEXT,
        completed_by TEXT,
        completed_by_name TEXT,
        completion_notes TEXT,
        completion_evidence_json TEXT,
        owner_id TEXT,
        owner_name TEXT,
        approver_id TEXT,
        approver_name TEXT,
        approved_at TEXT,
        tags TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    // One row per person per goal: who is accountable, and once finished, who
    // finished it (`completed_by` / `completed_by_name` / `completed_at`).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_goal_assignments (
        assign_id INTEGER PRIMARY KEY AUTOINCREMENT,
        goal_id INTEGER NOT NULL,
        assignee_id TEXT NOT NULL,
        assignee_name TEXT,
        role TEXT CHECK(role IN ('Owner','Lead','Member','Reviewer')) DEFAULT 'Member',
        assigned_at TEXT NOT NULL,
        assigned_by TEXT,
        assigned_by_name TEXT,
        due_date TEXT,
        status TEXT CHECK(status IN ('Pending','InProgress','Completed','Rejected','Cancelled')) DEFAULT 'Pending',
        completed_at TEXT,
        completed_by TEXT,
        completed_by_name TEXT,
        completion_notes TEXT,
        completion_evidence_json TEXT,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE,
        UNIQUE(goal_id, assignee_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_goal_actions (
        action_id INTEGER PRIMARY KEY AUTOINCREMENT,
        goal_id INTEGER NOT NULL,
        assign_id INTEGER,
        action_text TEXT NOT NULL,
        status TEXT CHECK(status IN ('Todo','InProgress','Done','Blocked','Cancelled')) DEFAULT 'Todo',
        priority TEXT CHECK(priority IN ('Low','Medium','High')) DEFAULT 'Medium',
        due_date TEXT,
        done_at TEXT,
        done_by TEXT,
        done_by_name TEXT,
        blocked_reason TEXT,
        evidence_json TEXT,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE,
        FOREIGN KEY(assign_id) REFERENCES qc_goal_assignments(assign_id) ON DELETE SET NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_goal_kpis (
        kpi_id INTEGER PRIMARY KEY AUTOINCREMENT,
        goal_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        target REAL NOT NULL,
        actual REAL,
        unit TEXT,
        measure_date TEXT,
        measured_by TEXT,
        measured_by_name TEXT,
        notes TEXT,
        higher_is_better INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE
      )
    ''');
    // Goal → SOP / inspection / finding / CAPA / template, so a goal can be
    // closed out against the records that evidence it.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS qc_goal_links (
        link_id INTEGER PRIMARY KEY AUTOINCREMENT,
        goal_id INTEGER NOT NULL,
        link_type TEXT NOT NULL CHECK(link_type IN ('SOP','INSPECTION','FINDING','CAPA','TEMPLATE','AUDIT','OTHER')),
        ref_id TEXT NOT NULL,
        ref_table TEXT,
        notes TEXT,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        created_by TEXT,
        FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE
      )
    ''');
  }
}
