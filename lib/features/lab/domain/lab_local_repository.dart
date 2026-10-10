import 'package:sqflite/sqflite.dart';

/// The lab concerns that stay **on the device**.
///
/// ## Why a third contract
///
/// [LabResultRepository] and [LabConfigurationRepository] cover the two tables
/// that replicate (`lab_sample_tests` and the products/analyses/links). The rest
/// of the lab module is deliberately local: inventory levels, global constants,
/// consumption logs and the activity feed are *consequences* of running a test
/// on this machine. Replicating them would let two devices fight over a stock
/// quantity that only one of them can measure, so plan §6.3 keeps them out of
/// the sync queue entirely.
///
/// That is exactly the property that makes them a separate contract. They do not
/// need the `user`/queue/audit machinery the replicating repositories carry, and
/// presentation should be able to depend on them without dragging `LabRepo` -
/// which is the 2400-line concrete class - along for the ride.
///
/// The optional [DatabaseExecutor] parameters exist only so a caller already
/// inside a transaction (a test run) can join it. Presentation never passes one.
abstract interface class LabLocalRepository {
  // ── Inventory ──────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listInventory({String? category});

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
  Future<List<Map<String, dynamic>>> listProductInspectionRecords(int productId);

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
    String description = '',
    String lastCalibrationDate = '',
    DatabaseExecutor? executor,
  });

  Future<Map<String, dynamic>> updateEquipment(
    int equipmentId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]);

  Future<void> deleteEquipment(
    int equipmentId, [
    DatabaseExecutor? executor,
  ]);

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

  Future<void> deleteEquipmentEvent(
    int eventId, [
    DatabaseExecutor? executor,
  ]);
}
