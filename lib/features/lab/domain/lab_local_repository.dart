import 'package:sqflite/sqflite.dart';
import 'chemical_consumption_report.dart';

/// Canonical values used by the equipment event log. Kept in the domain
/// contract so presentation does not depend on the concrete SQL repository.
abstract final class EquipmentEventType {
  static const calibration = 'calibration';
  static const maintenance = 'maintenance';
  static const repair = 'repair';

  static const values = <String>[calibration, maintenance, repair];

  static String normalize(Object? value) {
    final text = '$value'.trim().toLowerCase();
    if (text == maintenance || text == 'صيانة') return maintenance;
    if (text == repair || text == 'إصلاح' || text == 'اصلاح') return repair;
    return calibration;
  }
}

/// Inventory, constants and equipment operations in the shared laboratory.
/// Production implementations use the same server-confirmed authoring gateway
/// as laboratory results. SQLite is an approved read cache; these methods do
/// not authorize local-only writes or automatic submission.
/// Executors are an internal transaction-composition seam, never a UI handle.
abstract interface class LabLocalRepository {
  // ── Inventory ──────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listInventory({String? category});

  /// Paged inventory for mobile infinite lists (server-side search).
  Future<List<Map<String, dynamic>>> listInventoryPaged({
    String query = '',
    String? category,
    int limit = 25,
    int offset = 0,
  });

  Future<int> countInventory({String query = '', String? category});

  Future<Map<String, dynamic>> getInventoryItem(int itemId);

  Future<Map<String, dynamic>> addInventoryItem({
    required String name,
    required String category,
    required String unit,
    required double qty,
    required double minQty,
    String description = '',
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
    String expiryDate = '',
  });

  /// Receives a quantity as a new lot (expiry mandatory). Returns the lot row.
  Future<Map<String, dynamic>> receiveLot({
    required int inventoryId,
    required double qty,
    required String expiryDate,
    String supplier = '',
    String note = '',
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
  });

  /// Lots of one item, FEFO order. Empty lots excluded unless asked.
  Future<List<Map<String, dynamic>>> listInventoryLots(
    int inventoryId, {
    bool includeEmpty = false,
    DatabaseExecutor? executor,
  });

  /// Zeroes every expired lot with remaining quantity. Returns the disposed
  /// quantity.
  Future<double> disposeExpiredLots(
    int inventoryId, {
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
  });

  /// Unified per-item log: lots, receipts, consumptions, adjustments and
  /// disposals, newest first — what the log button shows.
  Future<List<Map<String, dynamic>>> itemStockLog(
    int inventoryId, {
    int limit = 200,
    DatabaseExecutor? executor,
  });

  Future<Map<String, dynamic>> updateInventoryItem(
    int itemId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]);

  /// Registry symbols from `lab_units` for every unit picker in the lab
  /// surfaces (inventory, analyses, constants, products).
  Future<List<String>> listUnitSymbols();

  // ── Global constants ───────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listGlobalConstants();

  Future<Map<String, dynamic>> upsertGlobalConstant(
    Map<String, dynamic> payload, [
    DatabaseExecutor? executor,
  ]);

  Future<Map<String, dynamic>> deleteGlobalConstant(
    int constantId, [
    DatabaseExecutor? executor,
  ]);

  // ── Logs ───────────────────────────────────────────────────────

  /// Stock movements and consumption, merged into one newest-first feed.
  Future<List<Map<String, dynamic>>> activityLog({int limit = 300});

  Future<List<Map<String, dynamic>>> listConsumptionLog();

  /// Actual consumption and returns in an inclusive local-calendar period.
  /// Detailed consumption lines are counted once; stock ledger mirrors,
  /// receipts, opening balances and adjustments are excluded.
  Future<ChemicalConsumptionReport> chemicalConsumptionReport({
    required ConsumptionPeriod period,
    int? inventoryId,
  });

  /// The sample behind a scanned `entry_code`, or null when it is unknown.
  Future<Map<String, dynamic>?> resolveInspection(String entryCode);

  /// Active raw materials that have inspection records, with their inspection
  /// count for the run-test material picker.
  Future<List<Map<String, dynamic>>> listInspectionMaterials();

  /// Inspection records for one raw material, including supplier, vehicle and
  /// the inspection's sample labels.
  Future<List<Map<String, dynamic>>> listInspectionRecords(int materialId);

  /// Products that have product-inspection records (`inspection_kind =
  /// 'product'`), with their record count for the run-test product picker.
  Future<List<Map<String, dynamic>>> listProductInspectionMaterials();

  /// Product-inspection records for one product, including formula/batch
  /// numbers and the record's sample labels.
  Future<List<Map<String, dynamic>>> listProductInspectionRecords(
    int productId,
  );

  // ── Equipment (device-local registry + event log) ────────────────────

  /// All registered lab devices, newest first. Each row carries
  /// `events_count` (log size) for the list.
  Future<List<Map<String, dynamic>>> listEquipment();

  Future<Map<String, dynamic>> getEquipment(int equipmentId);

  /// Registers a device. The [code] is minted automatically (`EQ-0001`…)
  /// and returned on the created row.
  Future<Map<String, dynamic>> createEquipment({
    required String name,
    String manufacturer = '',
    String serialNumber = '',
    String description = '',
    String lastCalibrationDate = '',
    String nextCalibrationDate = '',
    DatabaseExecutor? executor,
  });

  Future<Map<String, dynamic>> updateEquipment(
    int equipmentId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]);

  Future<void> deleteEquipment(int equipmentId, [DatabaseExecutor? executor]);

  /// The event log of one device, newest first.
  Future<List<Map<String, dynamic>>> listEquipmentEvents(int equipmentId);

  /// Appends a calibration / maintenance / repair event. A `calibration`
  /// event also refreshes the device's last-calibration date.
  Future<Map<String, dynamic>> addEquipmentEvent({
    required int equipmentId,
    required String eventType,
    required String eventDate,
    String notes = '',
    DatabaseExecutor? executor,
  });

  Future<Map<String, dynamic>> updateEquipmentEvent(
    int eventId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]);

  Future<void> deleteEquipmentEvent(int eventId, [DatabaseExecutor? executor]);
}
