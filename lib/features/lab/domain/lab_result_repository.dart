import 'package:sqflite/sqflite.dart';

/// Laboratory results: `lab_sample_tests` rows sync to
/// `organizations/{orgId}/labResults/{lt_<id>}` (plan §6.3, D7).
///
/// The contract covers the write side plus the reads those writes need. The
/// read-only reporting helpers stay on [LabRepo]: they never replicate, so they
/// never need the queue.
abstract interface class LabResultRepository {
  /// Runs an analysis against a sample: writes the `lab_sample_tests` row,
  /// consumes the chemicals from the inventory and appends the consumption log
  /// - one local transaction, replicated as one `labResult` document.
  Future<Map<String, dynamic>> runSampleTest({
    required int analysisId,
    required String sourceType,
    int? sourceRefId,
    required String sourceName,
    required String sampleName,
    String resultText = '',
    Map<String, dynamic>? dynamicValues,
    Map<String, dynamic>? user,
    String entryCode = '',
    bool manualResult = false,
  });

  Future<Map<String, dynamic>> getSampleTest(int testId);

  Future<List<Map<String, dynamic>>> listSampleTests({
    String? sourceType,
    int? sourceRefId,
  });

  /// Files a batch of worksheet rows.
  Future<Map<String, dynamic>> saveWorksheet(
    List<Map<String, dynamic>> rows,
    Map<String, dynamic>? user,
  );

  Future<List<Map<String, dynamic>>> getWorksheet();

  Future<Map<String, dynamic>> deleteWorksheetRow({
    required int rowId,
    Map<String, dynamic>? user,
    String reason = '',
  });

  /// Inventory movement behind a test/worksheet run. Runs inside the caller's
  /// transaction on purpose - the consumption and the result must not diverge.
  Future<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)>
      applyConsumptionDelta(
    DatabaseExecutor txn,
    int sampleTestId,
    Map<int, double> oldMap,
    Map<int, double> newMap,
    Map<String, dynamic>? user,
    Map<int, Map<String, dynamic>>? inventoryMap,
  );

  Future<Map<String, dynamic>> adjustStock({
    required int itemId,
    double? newQty,
    String reason = '',
    Map<String, dynamic>? user,
    double? deltaQty,
  });

  /// Batch load used while building a result; honours the caller's transaction.
  Future<Map<int, Map<String, dynamic>>> batchLoadAnalyses(
    DatabaseExecutor? txn,
    Set<int> analysisIds,
  );

  Future<Map<String, dynamic>> inventoryForConsumption(
    int inventoryId,
    Map<int, Map<String, dynamic>>? inventoryMap,
  );
}

/// Lab configuration: products, analyses and chemical links sync to
/// `organizations/{orgId}/labConfig/{lc_<table>_<id>}`. Inventory, consumption
/// logs, worksheets and settings stay device-local on purpose (plan §6.3, D7).
abstract interface class LabConfigurationRepository {
  Future<List<Map<String, dynamic>>> listAnalyses();

  Future<Map<String, dynamic>> getAnalysis(int analysisId);

  Future<List<Map<String, dynamic>>> getAnalysisItems(int analysisId);

  Future<Map<String, dynamic>> createAnalysis({
    required String name,
    String description = '',
    List<String>? dynamicFields,
    List<Map<String, dynamic>>? items,
    String unit = '%',
    Object? formula,
    List<Map<String, dynamic>>? fieldChemicalLinks,
  });

  Future<Map<String, dynamic>> updateAnalysis({
    required int analysisId,
    String? description,
    List<String>? dynamicFields,
    List<Map<String, dynamic>>? items,
    String? unit,
    Object? formula,
    List<Map<String, dynamic>>? fieldChemicalLinks,
  });

  Future<Map<String, dynamic>> deleteAnalysis(int analysisId);

  Future<List<Map<String, dynamic>>> getFieldChemicalLinks(int analysisId);

  Future<void> saveFieldChemicalLinks(
    int analysisId,
    List<Map<String, dynamic>>? links,
  );

  Future<List<Map<String, dynamic>>> listProducts();

  Future<Map<String, dynamic>> getProduct(int productId);

  Future<Map<String, dynamic>> createProduct({
    required String name,
    String category = '',
    String description = '',
    List<Map<String, dynamic>>? ranges,
    Map<String, dynamic>? user,
  });

  Future<Map<String, dynamic>> updateProduct(
    int productId,
    Map<String, dynamic> fields,
  );

  Future<Map<String, dynamic>> deleteProduct(int productId);

  Future<List<Map<String, dynamic>>> getProductRanges(int productId);

  Future<List<Map<String, dynamic>>> getProductRangesAll();

  Future<List<Map<String, dynamic>>> listMaterialRanges();

  Future<Map<String, dynamic>> saveMaterialRanges(
    int materialId,
    List<Map<String, dynamic>>? ranges,
  );
}
