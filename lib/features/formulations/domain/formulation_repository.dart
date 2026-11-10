import 'formulation_calculator.dart';

abstract interface class FormulationRepository {
  Future<List<Map<String, dynamic>>> list({bool archived = false});
  Future<List<Map<String, dynamic>>> materials();
  Future<List<Map<String, dynamic>>> products();
  Future<List<Map<String, dynamic>>> parameters();

  /// Accepted, live raw-material receipts through [to], including historical
  /// fallback. Does not load or calculate laboratory results.
  Future<Set<int>> materialIdsWithReceipts(DateTime to);
  Future<List<MaterialReceipt>> receipts(
    List<int> materialIds,
    DateTime from,
    DateTime to,
  );
  Future<int> save(Map<String, dynamic> record, {int? id});
  Future<void> archive(int id);
  Future<void> delete(int id);
}
