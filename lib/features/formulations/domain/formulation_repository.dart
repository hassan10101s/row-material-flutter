import 'formulation_calculator.dart';

abstract interface class FormulationRepository {
  Future<List<Map<String, dynamic>>> list({bool archived = false});
  Future<List<Map<String, dynamic>>> materials();
  Future<List<Map<String, dynamic>>> products();
  Future<List<Map<String, dynamic>>> parameters();
  Future<List<MaterialReceipt>> receipts(
    List<int> materialIds,
    DateTime from,
    DateTime to,
  );
  Future<int> save(Map<String, dynamic> record, {int? id});
  Future<void> archive(int id);
}
