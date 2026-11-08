import 'formula_engine.dart';

bool isNumericMeasurementField(Map<String, dynamic> analysis, String field) {
  final formula = analysis['formula'];
  final expression = formula is Map ? '${formula['expression'] ?? ''}' : '';
  if (expression.isNotEmpty && formulaVariables(expression).contains(field)) {
    return true;
  }
  if (RegExp(
    r'weight|mass|volume|quantity|qty|وزن|وزنة|كمي|حجم',
    caseSensitive: false,
  ).hasMatch(field)) {
    return true;
  }
  return (analysis['field_chemical_links'] as List? ?? const []).any(
    (raw) =>
        raw is Map &&
        raw['dynamic_field'] == field &&
        (raw['kind'] ?? 'link') == 'link' &&
        (int.tryParse('${raw['inventory_id']}') ?? 0) > 0,
  );
}
