import 'package:sqflite/sqflite.dart';

/// The reference catalog: materials, their parameters and the lab units.
///
/// ## Why a contract
///
/// `ReferenceRepo` is the 325-line concrete data class, and three separate
/// presentation surfaces reach for it: the Reference host's own cubits, the
/// material editor, and the inspection form (which needs a material's reference
/// values to build the sample's snapshot). Before the split each of those
/// imported `data/reference_repo.dart` directly, which is exactly what the
/// architecture ratchet forbids. The contract lets the desktop and mobile
/// variants depend on the *shape* they use without the data layer.
///
/// Every method here is one a presentation file actually calls; anything used
/// only inside the data layer (or by other repositories) stays off the contract.
///
/// The optional [DatabaseExecutor] parameters on the concrete implementation
/// exist only so a caller already inside a transaction can join it. Presentation
/// never passes one, so the contract omits them - a wider method still satisfies
/// the interface.
abstract interface class ReferenceRepository {
  // ── Materials ──────────────────────────────────────────────────

  /// Active materials only, newest name-sorted first. Drives the inspection
  /// form's material picker.
  Future<List<Map<String, dynamic>>> listMaterials();

  /// Every material, including soft-deleted ones, for the Reference catalog.
  Future<List<Map<String, dynamic>>> listAllMaterials();

  /// The raw row, or null when the id is unknown. Editor-only.
  Future<Map<String, dynamic>?> getMaterialRaw(int id);

  /// The enriched material (parsed and unit-annotated reference values) plus the
  /// next free entry code for [inspectionDate]. Throws when the id is unknown.
  Future<Map<String, dynamic>> getMaterial(
    int id, {
    String? inspectionDate,
  });

  Future<int> createMaterial({
    required String materialName,
    required String materialCode,
    Map<String, dynamic> physicalReference = const {},
    Map<String, dynamic> chemicalReference = const {},
    Map<String, dynamic> units = const {},
  });

  Future<void> updateMaterial(
    int id, {
    required String materialName,
    required String materialCode,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
    Map<String, dynamic> units = const {},
  });

  /// Soft-deletes a material (`active = 0`), matching `materials_delete`.
  Future<void> deleteMaterial(int id);

  // ── Entry code ─────────────────────────────────────────────────

  /// `<code>-<yyyymmdd>-<seq>` where `seq` continues the highest already issued
  /// for that material and day.
  Future<String> generateEntryCode(String materialCode, String inspectionDate);

  // ── Parameters ─────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listParameters({String? parameterType});

  Future<void> upsertParameter(
    String name,
    String unit, {
    String parameterType = 'chemical',
  });

  /// Removes a parameter and the bounds/analysis links that inherited its name.
  Future<void> deleteParameter(String name);

  // ── Lab units ──────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listUnits();

  Future<void> upsertUnit(
    String symbol, {
    String name = '',
    String dimension = '',
  });

  Future<void> deleteUnit(String symbol);
}
