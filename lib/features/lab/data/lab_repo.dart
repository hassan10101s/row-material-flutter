import 'package:sqflite/sqflite.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import '../core/formula_engine.dart';

/// Lab repository: inventory, products, analyses, global constants, sample
/// tests, consumption log and the shared worksheet (port of LabService).
class LabRepo {
  final DatabaseHelper dbHelper;

  LabRepo({required this.dbHelper});

  Future<Database> get _db => dbHelper.database;

  // ── Low-level helpers ──────────────────────────────────────────────

  Future<Map<String, dynamic>?> fetchOne(
      DatabaseExecutor? executor, String sql, [List<Object?>? args]) async {
    final rows = await (executor ?? await _db).rawQuery(sql, args);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  Future<List<Map<String, dynamic>>> fetchAll(
      DatabaseExecutor? executor, String sql, [List<Object?>? args]) async {
    final rows = await (executor ?? await _db).rawQuery(sql, args);
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  Future<void> execute(DatabaseExecutor? executor, String sql,
      [List<Object?>? args]) async {
    await (executor ?? await _db).rawInsert(sql, args);
  }

  Future<int> executeReturnId(DatabaseExecutor? executor, String sql,
      [List<Object?>? args]) async {
    return (executor ?? await _db).rawInsert(sql, args);
  }

  // ── Inspection resolution ─────────────────────────────────────────

  Future<Map<String, dynamic>?> resolveInspection(String entryCode) async {
    final code = entryCode.trim();
    if (code.isEmpty) return null;
    return fetchOne(
        null,
        'SELECT id, material_id, material_name, material_code, inspection_date '
        'FROM inspections WHERE entry_code = ?',
        [code]);
  }

  // ── Inventory ─────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listInventory({String? category}) async {
    final params = <Object?>[];
    var query = 'SELECT * FROM lab_inventory';
    if (inventoryCategories.contains(category)) {
      query += ' WHERE category = ?';
      params.add(category);
    }
    query += ' ORDER BY name ASC';
    return fetchAll(null, query, params);
  }

  Future<Map<String, dynamic>> getInventoryItem(int itemId) async {
    final row = await fetchOne(
        null, 'SELECT * FROM lab_inventory WHERE id = ?', [itemId]);
    if (row == null) throw const NotFoundError('Inventory item was not found.');
    return row;
  }

  Future<Map<String, dynamic>> addInventoryItem({
    required String name,
    required String category,
    required String unit,
    required double qty,
    required double minQty,
    String description = '',
    Map<String, dynamic>? user,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw const ValidationError('اسم المادة مطلوب.');
    if (!inventoryCategories.contains(category)) {
      throw const ValidationError('نوع المادة يجب أن يكون liquid أو powder.');
    }
    if (!inventoryUnits.contains(unit)) {
      throw const ValidationError('الوحدة غير مدعومة.');
    }
    final existing =
        await fetchOne(null, 'SELECT id FROM lab_inventory WHERE name = ?', [cleanName]);
    if (existing != null) {
      throw const ValidationError('يوجد مادة بنفس الاسم بالفعل.');
    }
    final finalQty = (safeFloat(qty) ?? 0.0).clamp(0.0, double.infinity);
    final finalMinQty = (safeFloat(minQty) ?? 0.0).clamp(0.0, double.infinity);
    final timestamp = nowIso();
    final id = await executeReturnId(null, '''
        INSERT INTO lab_inventory (
            name, category, unit, current_qty, min_qty, description, created_by, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', [
      cleanName,
      category,
      unit,
      finalQty,
      finalMinQty,
      description.trim(),
      user == null ? null : int.parse('${user['id']}'),
      timestamp,
      timestamp,
    ]);
    return getInventoryItem(id);
  }

  Future<Map<String, dynamic>> updateInventoryItem(
      int itemId, Map<String, dynamic> fields) async {
    final existing = await getInventoryItem(itemId);
    final allowed = ['name', 'category', 'unit', 'min_qty', 'description'];
    final updates = <String, Object?>{};
    for (final key in allowed) {
      if (fields.containsKey(key)) updates[key] = fields[key];
    }
    if (updates.containsKey('name')) {
      final newName = '${updates['name'] ?? ''}'.trim();
      if (newName.isEmpty) throw const ValidationError('اسم المادة مطلوب.');
      final dup = await fetchOne(null,
          'SELECT id FROM lab_inventory WHERE name = ? AND id != ?', [newName, itemId]);
      if (dup != null) throw const ValidationError('يوجد مادة بنفس الاسم بالفعل.');
      updates['name'] = newName;
    }
    if (updates.containsKey('category') &&
        !inventoryCategories.contains(updates['category'])) {
      throw const ValidationError('نوع المادة يجب أن يكون liquid أو powder.');
    }
    if (updates.containsKey('unit') && !inventoryUnits.contains(updates['unit'])) {
      throw const ValidationError('الوحدة غير مدعومة.');
    }
    if (updates.containsKey('min_qty')) {
      updates['min_qty'] =
          (safeFloat(updates['min_qty']) ?? 0.0).clamp(0.0, double.infinity);
    }
    if (updates.isEmpty) return existing;
    final sets = updates.keys.map((key) => '$key = ?').join(', ');
    final params = <Object?>[...updates.values, nowIso(), itemId];
    await execute(null, 'UPDATE lab_inventory SET $sets, updated_at = ? WHERE id = ?', params);
    return getInventoryItem(itemId);
  }

  Future<Map<String, dynamic>> adjustStock({
    required int itemId,
    double? newQty,
    String reason = '',
    Map<String, dynamic>? user,
    double? deltaQty,
  }) async {
    final existing = await getInventoryItem(itemId);
    if (deltaQty != null) {
      newQty = (safeFloat(existing['current_qty']) ?? 0.0) +
          (safeFloat(deltaQty) ?? 0.0);
    }
    final finalQty = (safeFloat(newQty) ?? 0.0).clamp(0.0, double.infinity);
    final cleanReason = reason.trim();
    final trimmedReason =
        cleanReason.isEmpty ? '' : cleanReason.substring(0, cleanReason.length > 300 ? 300 : cleanReason.length);
    await execute(
        null,
        'UPDATE lab_inventory SET current_qty = ?, updated_at = ? WHERE id = ?',
        [finalQty, nowIso(), itemId]);
    await execute(null, '''
            INSERT INTO lab_stock_adjustments (
                inventory_id, old_qty, new_qty, reason, adjusted_by, adjusted_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ''', [
      itemId,
      existing['current_qty'],
      finalQty,
      trimmedReason,
      user == null ? null : int.parse('${user['id']}'),
      nowIso(),
    ]);
    return getInventoryItem(itemId);
  }

  Future<List<Map<String, dynamic>>> getLowStockItems() async {
    return fetchAll(null, '''
        SELECT * FROM lab_inventory
        WHERE current_qty < min_qty
        ORDER BY name ASC
        ''');
  }

  // ── Products ─────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listProducts() async {
    final rows = await fetchAll(
        null, 'SELECT * FROM lab_products WHERE active = 1 ORDER BY name ASC');
    final products = <Map<String, dynamic>>[];
    for (final row in rows) {
      final product = Map<String, dynamic>.from(row);
      product['ranges'] = await getProductRanges(int.parse('${product['id']}'));
      products.add(product);
    }
    return products;
  }

  Future<Map<String, dynamic>> getProduct(int productId) async {
    final row =
        await fetchOne(null, 'SELECT * FROM lab_products WHERE id = ?', [productId]);
    if (row == null) throw const NotFoundError('Product was not found.');
    final product = Map<String, dynamic>.from(row);
    product['ranges'] = await getProductRanges(productId);
    return product;
  }

  Future<List<Map<String, dynamic>>> getProductRanges(int productId) async {
    return fetchAll(null, '''
            SELECT 
                lpa.id, lpa.product_id, lpa.analysis_id, lpa.min_value, lpa.max_value, lpa.unit,
                a.name AS analysis_name
            FROM lab_product_analyses lpa
            JOIN lab_analyses a ON a.id = lpa.analysis_id
            WHERE lpa.product_id = ?
            ORDER BY a.name ASC
            ''', [productId]);
  }

  Future<List<Map<String, dynamic>>> getProductRangesAll() async {
    return fetchAll(null, '''
            SELECT 
                lpa.id, lpa.product_id, lpa.analysis_id, lpa.min_value, lpa.max_value, lpa.unit,
                a.name AS analysis_name
            FROM lab_product_analyses lpa
            JOIN lab_analyses a ON a.id = lpa.analysis_id
            ORDER BY lpa.product_id ASC, a.name ASC
            ''');
  }

  // ── Material analysis ranges ─────────────────────────────────────

  Future<List<Map<String, dynamic>>> listMaterialRanges() async {
    return fetchAll(null, '''
            SELECT 
                lma.id, lma.material_id, lma.analysis_id, lma.min_value, lma.max_value, lma.unit,
                a.name AS analysis_name
            FROM lab_material_analyses lma
            JOIN lab_analyses a ON a.id = lma.analysis_id
            ORDER BY lma.material_id ASC, a.name ASC
            ''');
  }

  Future<Map<String, dynamic>> saveMaterialRanges(
      int materialId, List<Map<String, dynamic>>? ranges) async {
    await execute(null, 'DELETE FROM lab_material_analyses WHERE material_id = ?', [materialId]);
    var saved = 0;
    final seen = <int>{};
    for (final item in ranges ?? []) {
      final analysisId = int.tryParse('${item['analysis_id'] ?? 0}') ?? 0;
      if (analysisId <= 0 || seen.contains(analysisId)) continue;
      seen.add(analysisId);
      final rawMin = item['min_value'];
      final rawMax = item['max_value'];
      final minValue = (rawMin != null && '$rawMin' != '')
          ? safeFloat(rawMin)
          : null;
      final maxValue = (rawMax != null && '$rawMax' != '')
          ? safeFloat(rawMax)
          : null;
      if (minValue == null && maxValue == null) continue;
      final unit = '${item['unit'] ?? ''}'.trim().isEmpty
          ? '%'
          : '${item['unit']}'.trim();
      await execute(null, '''
                INSERT INTO lab_material_analyses
                    (material_id, analysis_id, min_value, max_value, unit)
                VALUES (?, ?, ?, ?, ?)
                ''', [materialId, analysisId, minValue, maxValue, unit]);
      saved++;
    }
    return {'material_id': materialId, 'saved': saved};
  }

  Future<Map<String, dynamic>> createProduct({
    required String name,
    String category = '',
    String description = '',
    List<Map<String, dynamic>>? ranges,
    Map<String, dynamic>? user,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw const ValidationError('اسم المنتج مطلوب.');
    final dup = await fetchOne(null, 'SELECT id FROM lab_products WHERE name = ?', [cleanName]);
    if (dup != null) throw const ValidationError('يوجد منتج بنفس الاسم بالفعل.');
    final productId = await executeReturnId(null, '''
            INSERT INTO lab_products (name, category, description, created_by, created_at)
            VALUES (?, ?, ?, ?, ?)
            ''', [
      cleanName,
      category.trim(),
      description.trim(),
      user == null ? null : int.parse('${user['id']}'),
      nowIso(),
    ]);
    for (final item in ranges ?? []) {
      final analysisId = int.tryParse('${item['analysis_id'] ?? 0}') ?? 0;
      if (analysisId <= 0) {
        throw const ValidationError('معرف التحليل مطلوب داخل النطاقات.');
      }
      final minValue = item['min_value'];
      final maxValue = item['max_value'];
      final unit = '${item['unit'] ?? '%'}'.trim();
      await execute(null, '''
                INSERT INTO lab_product_analyses (
                    product_id, analysis_id, min_value, max_value, unit
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(product_id, analysis_id) DO UPDATE SET
                    min_value = excluded.min_value,
                    max_value = excluded.max_value,
                    unit = excluded.unit
                ''', [
        productId,
        analysisId,
        (minValue != null && '$minValue' != '') ? safeFloat(minValue) : null,
        (maxValue != null && '$maxValue' != '') ? safeFloat(maxValue) : null,
        unit,
      ]);
    }
    return getProduct(productId);
  }

  Future<Map<String, dynamic>> updateProduct(
      int productId, Map<String, dynamic> fields) async {
    await getProduct(productId);
    final updates = <String, Object?>{};
    for (final key in ['name', 'category', 'description']) {
      if (fields.containsKey(key)) {
        updates[key] = '${fields[key] ?? ''}'.trim();
      }
    }
    if (updates.containsKey('name')) {
      if (updates['name'] == '') throw const ValidationError('اسم المنتج مطلوب.');
      final dup = await fetchOne(null,
          'SELECT id FROM lab_products WHERE name = ? AND id != ?',
          [updates['name'], productId]);
      if (dup != null) throw const ValidationError('يوجد منتج بنفس الاسم بالفعل.');
    }
    if (updates.isNotEmpty) {
      final sets = updates.keys.map((key) => '$key = ?').join(', ');
      final params = <Object?>[...updates.values, productId];
      await execute(null, 'UPDATE lab_products SET $sets WHERE id = ?', params);
    }
    if (fields.containsKey('ranges')) {
      await execute(null, 'DELETE FROM lab_product_analyses WHERE product_id = ?', [productId]);
      for (final item in (fields['ranges'] as List? ?? [])) {
        final m = item as Map<String, dynamic>;
        final analysisId = int.tryParse('${m['analysis_id'] ?? 0}') ?? 0;
        if (analysisId <= 0) continue;
        final minValue = m['min_value'];
        final maxValue = m['max_value'];
        final unit = '${m['unit'] ?? '%'}'.trim();
        await execute(null, '''
                    INSERT INTO lab_product_analyses (
                        product_id, analysis_id, min_value, max_value, unit
                    ) VALUES (?, ?, ?, ?, ?)
                    ''', [
          productId,
          analysisId,
          (minValue != null && '$minValue' != '') ? safeFloat(minValue) : null,
          (maxValue != null && '$maxValue' != '') ? safeFloat(maxValue) : null,
          unit,
        ]);
      }
    }
    return getProduct(productId);
  }

  Future<Map<String, dynamic>> deleteProduct(int productId) async {
    await getProduct(productId);
    await execute(null, 'UPDATE lab_products SET active = 0 WHERE id = ?', [productId]);
    return {'archived': true};
  }

  // ── Analyses ────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listAnalyses() async {
    final rows = await fetchAll(
        null, 'SELECT * FROM lab_analyses WHERE active = 1 ORDER BY name ASC');
    final analyses = <Map<String, dynamic>>[];
    for (final row in rows) {
      analyses.add(await _decorateAnalysis(row));
    }
    return analyses;
  }

  Future<Map<String, dynamic>> getAnalysis(int analysisId) async {
    final row =
        await fetchOne(null, 'SELECT * FROM lab_analyses WHERE id = ?', [analysisId]);
    if (row == null) throw const NotFoundError('Analysis was not found.');
    return _decorateAnalysis(row);
  }

  Future<Map<String, dynamic>> _decorateAnalysis(Map<String, dynamic> row) async {
    final analysis = Map<String, dynamic>.from(row);
    final id = int.parse('${analysis['id']}');
    analysis['items'] = await getAnalysisItems(id);
    analysis['dynamic_fields'] = jsonLoadsList(
        '${analysis.remove('dynamic_fields_json') ?? ''}', const ['Sample Name']);
    analysis['formula'] = loadFormula('${analysis.remove('formula_json') ?? '{}'}');
    analysis['field_chemical_links'] = await getFieldChemicalLinks(id);
    return analysis;
  }

  Future<List<Map<String, dynamic>>> getFieldChemicalLinks(int analysisId) async {
    return fetchAll(null, '''
            SELECT lc.*, inv.name AS inventory_name, inv.unit AS inventory_unit
            FROM lab_field_chemical_links lc
            JOIN lab_inventory inv ON inv.id = lc.inventory_id
            WHERE lc.analysis_id = ?
            ORDER BY lc.dynamic_field ASC
            ''', [analysisId]);
  }

  Future<void> saveFieldChemicalLinks(
      int analysisId, List<Map<String, dynamic>>? links) async {
    await execute(
        null, 'DELETE FROM lab_field_chemical_links WHERE analysis_id = ?', [analysisId]);
    final seen = <String>{};
    for (final link in links ?? []) {
      final dynamicField = '${link['dynamic_field'] ?? ''}'.trim();
      final inventoryId = int.tryParse('${link['inventory_id'] ?? 0}') ?? 0;
      if (dynamicField.isEmpty || inventoryId == 0) continue;
      final key = '$analysisId|$dynamicField';
      if (seen.contains(key)) continue;
      seen.add(key);
      final unit = '${link['unit'] ?? ''}'.trim().isEmpty
          ? 'mL'
          : '${link['unit']}'.trim();
      await execute(null, '''
                INSERT INTO lab_field_chemical_links
                    (analysis_id, dynamic_field, inventory_id, unit, created_at)
                VALUES (?, ?, ?, ?, ?)
                ''', [analysisId, dynamicField, inventoryId, unit, nowIso()]);
    }
  }

  Future<List<Map<String, dynamic>>> getAnalysisItems(int analysisId) async {
    return fetchAll(null, '''
            SELECT 
                li.id AS item_id, li.analysis_id, li.inventory_id, li.qty_per_sample, li.unit,
                inv.name AS inventory_name, inv.category AS inventory_category, inv.current_qty
            FROM lab_analysis_items li
            JOIN lab_inventory inv ON inv.id = li.inventory_id
            WHERE li.analysis_id = ?
            ORDER BY inv.name ASC
            ''', [analysisId]);
  }

  Future<Map<String, dynamic>> createAnalysis({
    required String name,
    String description = '',
    List<String>? dynamicFields,
    List<Map<String, dynamic>>? items,
    String unit = '%',
    Object? formula,
    List<Map<String, dynamic>>? fieldChemicalLinks,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw const ValidationError('اسم التحليل مطلوب.');
    final dup = await fetchOne(null, 'SELECT id FROM lab_analyses WHERE name = ?', [cleanName]);
    if (dup != null) throw const ValidationError('يوجد تحليل بنفس الاسم بالفعل.');
    final cleanUnit = unit.trim();
    final finalUnit = cleanUnit.isEmpty ? '%' : cleanUnit;
    final fields = [
      for (final f in dynamicFields ?? [])
        if (f.trim().isNotEmpty) f.trim()
    ];
    final formulaData = normalizeFormulaValue(formula);
    if ('${formulaData['expression'] ?? ''}'.trim().isNotEmpty) {
      validateFormula('${formulaData['expression']}');
      resolveConstants(
        _mapOf(formulaData['constants']),
        targetUnit: finalUnit,
      );
    }
    final analysisId = await executeReturnId(null, '''
            INSERT INTO lab_analyses (name, unit, description, dynamic_fields_json, formula_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ''', [
      cleanName,
      finalUnit,
      description.trim(),
      jsonDumps(fields),
      jsonDumps(formulaData),
      nowIso(),
    ]);
    for (final item in items ?? []) {
      final inventoryId = int.tryParse('${item['inventory_id'] ?? 0}') ?? 0;
      if (inventoryId == 0) continue;
      final qtyPerSample = safeFloat(item['qty_per_sample']);
      final itemUnit = '${item['unit'] ?? ''}'.trim();
      final exists = await fetchOne(null,
          'SELECT id FROM lab_analysis_items WHERE analysis_id = ? AND inventory_id = ?',
          [analysisId, inventoryId]);
      if (exists != null) continue;
      await execute(null, '''
                INSERT INTO lab_analysis_items (analysis_id, inventory_id, qty_per_sample, unit)
                VALUES (?, ?, ?, ?)
                ''', [analysisId, inventoryId, qtyPerSample, itemUnit]);
    }
    await saveFieldChemicalLinks(analysisId, fieldChemicalLinks);
    return getAnalysis(analysisId);
  }

  Future<Map<String, dynamic>> updateAnalysis({
    required int analysisId,
    String? description,
    List<String>? dynamicFields,
    List<Map<String, dynamic>>? items,
    String? unit,
    Object? formula,
    List<Map<String, dynamic>>? fieldChemicalLinks,
  }) async {
    await getAnalysis(analysisId);
    if (description != null) {
      await execute(null, 'UPDATE lab_analyses SET description = ? WHERE id = ?',
          [description.trim(), analysisId]);
    }
    if (unit != null) {
      final clean = unit.trim();
      await execute(null, 'UPDATE lab_analyses SET unit = ? WHERE id = ?',
          [clean.isEmpty ? '%' : clean, analysisId]);
    }
    if (dynamicFields != null) {
      final fields = [
        for (final f in dynamicFields)
          if (f.trim().isNotEmpty) f.trim()
      ];
      await execute(null, 'UPDATE lab_analyses SET dynamic_fields_json = ? WHERE id = ?',
          [jsonDumps(fields), analysisId]);
    }
    if (formula != null) {
      final formulaData = normalizeFormulaValue(formula);
      if ('${formulaData['expression'] ?? ''}'.trim().isNotEmpty) {
        validateFormula('${formulaData['expression']}');
        resolveConstants(
          _mapOf(formulaData['constants']),
          targetUnit: unit is String ? unit : '',
        );
      }
      await execute(null, 'UPDATE lab_analyses SET formula_json = ? WHERE id = ?',
          [jsonDumps(formulaData), analysisId]);
    }
    if (items != null) {
      await execute(null, 'DELETE FROM lab_analysis_items WHERE analysis_id = ?', [analysisId]);
      for (final item in items) {
        final inventoryId = int.tryParse('${item['inventory_id'] ?? 0}') ?? 0;
        if (inventoryId == 0) continue;
        final qtyPerSample = safeFloat(item['qty_per_sample']);
        final itemUnit = '${item['unit'] ?? ''}'.trim();
        await execute(null, '''
                    INSERT INTO lab_analysis_items (analysis_id, inventory_id, qty_per_sample, unit)
                    VALUES (?, ?, ?, ?)
                    ''', [analysisId, inventoryId, qtyPerSample, itemUnit]);
      }
    }
    if (fieldChemicalLinks != null) {
      await saveFieldChemicalLinks(analysisId, fieldChemicalLinks);
    }
    return getAnalysis(analysisId);
  }

  Future<Map<String, dynamic>> deleteAnalysis(int analysisId) async {
    await getAnalysis(analysisId);
    await execute(null, 'UPDATE lab_analyses SET active = 0 WHERE id = ?', [analysisId]);
    return {'archived': true};
  }

  // ── Global constants ─────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listGlobalConstants() async {
    return fetchAll(
        null, 'SELECT * FROM lab_constants WHERE is_global = 1 ORDER BY name ASC');
  }

  static const _symbolRe = r'^[A-Za-z_][A-Za-z0-9_]*$';

  Future<Map<String, dynamic>> upsertGlobalConstant(
      Map<String, dynamic> payload) async {
    final cid = payload['id'];
    final name = '${payload['name'] ?? ''}'.trim();
    if (name.isEmpty) throw const ValidationError('اسم الثابت مطلوب.');
    final symbol = '${payload['symbol'] ?? name}'.trim();
    if (symbol.isEmpty || !RegExp(_symbolRe).hasMatch(symbol)) {
      throw const ValidationError('رمز الثابت يجب أن يبدأ بحرف (A-Z, a-z أو _).');
    }
    final valueText = '${payload['value_text'] ?? ''}';
    final unit = '${payload['unit'] ?? ''}'.trim();
    final unitDim = '${payload['unit_dim'] ?? unitDimOf(unit)}'.trim();
    final isExpression = (payload['is_expression'] ?? false) ? 1 : 0;
    final expression = '${payload['expression'] ?? ''}'.trim();
    final minValue = _optFloat(payload['min_value']);
    final maxValue = _optFloat(payload['max_value']);
    final precision = _optInt(payload['precision']);
    if (precision != null && !(precision >= 0 && precision <= 12)) {
      throw const ValidationError('الدقة يجب أن تكون بين 0 و 12.');
    }
    if (isExpression == 1) {
      if (expression.isEmpty) throw const ValidationError('الثابت المشتق يتطلب تعبيراً.');
      try {
        parseFormula(expression);
      } on ValidationError catch (exc) {
        throw ValidationError('تعبير الثابت غير صالح: ${exc.message}');
      }
    } else if (valueText.isEmpty || parseNumber(valueText) == null) {
      throw const ValidationError('قيمة الثابت يجب أن تكون رقماً.');
    }
    final now = nowIso();
    Map<String, dynamic>? row;
    if (cid != null && '$cid'.trim().isNotEmpty) {
      await execute(null, '''
                UPDATE lab_constants
                SET name = ?, symbol = ?, value_text = ?, unit = ?, unit_dim = ?,
                    is_expression = ?, expression = ?, min_value = ?, max_value = ?,
                    precision = ?, description = ?, updated_at = ?
                WHERE id = ? AND is_global = 1
                ''', [
        name, symbol, valueText, unit, unitDim,
        isExpression, expression, minValue, maxValue,
        precision, '${payload['description'] ?? ''}'.trim(), now, int.parse('$cid'),
      ]);
      row = await fetchOne(null,
          'SELECT * FROM lab_constants WHERE id = ? AND is_global = 1', [int.parse('$cid')]);
    } else {
      final dup = await fetchOne(null, 'SELECT id FROM lab_constants WHERE name = ?', [name]);
      if (dup != null) throw const ValidationError('يوجد ثابت بنفس الاسم بالفعل.');
      final id = await executeReturnId(null, '''
                INSERT INTO lab_constants
                    (name, symbol, value_text, unit, unit_dim, is_expression, expression,
                     min_value, max_value, precision, description, is_global, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                ''', [
        name, symbol, valueText, unit, unitDim, isExpression, expression,
        minValue, maxValue, precision, '${payload['description'] ?? ''}'.trim(), now, now,
      ]);
      row = await fetchOne(null, 'SELECT * FROM lab_constants WHERE id = ?', [id]);
    }
    if (row == null) throw const NotFoundError('Global constant was not found.');
    return row;
  }

  Future<Map<String, dynamic>> deleteGlobalConstant(int constantId) async {
    final row = await fetchOne(
        null, 'SELECT id FROM lab_constants WHERE id = ? AND is_global = 1', [constantId]);
    if (row == null) throw const NotFoundError('Global constant was not found.');
    await execute(null, 'DELETE FROM lab_constants WHERE id = ?', [constantId]);
    return {'deleted': true};
  }

  double? _optFloat(Object? v) {
    if (v == null || '$v' == '') return null;
    return safeFloat(v);
  }

  int? _optInt(Object? v) {
    final f = _optFloat(v);
    return f?.toInt();
  }

  Map<String, dynamic> _mapOf(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  // ── Setup / default analyses ─────────────────────────────────────

  Future<bool> needsSetup() async {
    final row =
        await fetchOne(null, 'SELECT COUNT(*) AS count FROM lab_analyses');
    return row == null || (int.parse('${row['count']}') == 0);
  }

  static String inventoryCategoryForUnit(String unit) {
    final u = unit.trim();
    return (u == 'L' || u == 'mL') ? 'liquid' : 'powder';
  }

  Future<int> resolveInventoryId(
      String name, String unit, Map<String, int> inventoryMap) async {
    final key = name.trim().toLowerCase();
    if (!inventoryMap.containsKey(key)) {
      await addInventoryItem(
          name: name, category: inventoryCategoryForUnit(unit), unit: unit, qty: 0.0, minQty: 0.0);
      final row = await fetchOne(null, 'SELECT id FROM lab_inventory WHERE name = ?', [name]);
      if (row == null) {
        throw const ValidationError('Failed to create inventory item.');
      }
      inventoryMap[key] = int.parse('${row['id']}');
    }
    return inventoryMap[key]!;
  }

  Future<void> ensureDefaultAnalyses() async {
    final inventoryMap = <String, int>{};
    final invRows = await fetchAll(null, 'SELECT id, name FROM lab_inventory');
    for (final row in invRows) {
      inventoryMap['${row['name']}'.trim().toLowerCase()] = int.parse('${row['id']}');
    }
    for (final template in defaultAnalyses) {
      final name = '${template['name']}';
      final analysis =
          await fetchOne(null, 'SELECT id FROM lab_analyses WHERE name = ?', [name]);
      if (analysis != null) {
        final analysisId = int.parse('${analysis['id']}');
        final linked = <String>{
          for (final item in await getAnalysisItems(analysisId))
            '${item['inventory_name']}'.trim().toLowerCase(),
        };
        for (final item in (template['items'] as List).cast<Map>()) {
          final itemName = '${item['name']}';
          final qty = (item['qty'] as num).toDouble();
          final unit = '${item['unit']}';
          if (linked.contains(itemName.trim().toLowerCase())) continue;
          final inventoryId = await resolveInventoryId(itemName, unit, inventoryMap);
          await execute(null, '''
                    INSERT INTO lab_analysis_items (analysis_id, inventory_id, qty_per_sample, unit)
                    VALUES (?, ?, ?, ?)
                    ''', [analysisId, inventoryId, qty, unit]);
        }
        continue;
      }
      final items = <Map<String, dynamic>>[];
      for (final item in (template['items'] as List).cast<Map>()) {
        final itemName = '${item['name']}';
        final qty = (item['qty'] as num).toDouble();
        final unit = '${item['unit']}';
        final inventoryId = await resolveInventoryId(itemName, unit, inventoryMap);
        items.add({
          'inventory_id': inventoryId,
          'qty_per_sample': qty,
          'unit': unit,
        });
      }
      await createAnalysis(
        name: name,
        description: '${template['description']}',
        dynamicFields: [
          for (final f in (template['dynamic_fields'] as List).cast<String>()) f
        ],
        items: items,
        unit: '${template['unit'] ?? '%'}',
      );
    }
  }

  // ── Sample tests ─────────────────────────────────────────────────

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
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final analysis = await _decorateAnalysisTx(txn, analysisId);
      if (!sourceTypes.contains(sourceType)) {
        throw const ValidationError('نوع المصدر يجب أن يكون raw_material أو product.');
      }
      var cleanSampleName = sampleName.trim();
      var cleanSourceName = sourceName.trim();
      var cleanEntryCode = entryCode.trim();
      var resolvedSourceRefId = sourceRefId;
      if (sourceType == 'raw_material' && cleanEntryCode.isNotEmpty) {
        final inspection = await fetchOne(
            txn, 'SELECT id, material_id, material_name, material_code, inspection_date FROM inspections WHERE entry_code = ?',
            [cleanEntryCode]);
        if (inspection == null) {
          throw ValidationError('كود الدخول غير موجود في سجل الدخول: $cleanEntryCode');
        }
        resolvedSourceRefId = inspection['material_id'] != null
            ? int.parse('${inspection['material_id']}')
            : sourceRefId;
        cleanSourceName =
            ('${inspection['material_name'] ?? ''}'.trim().isNotEmpty
                ? '${inspection['material_name']}'
                : cleanSourceName)
                .trim();
      }
      if (cleanSampleName.isEmpty || cleanSourceName.isEmpty) {
        throw const ValidationError('اسم العينة واسم المصدر مطلوبان.');
      }

      final safeDynamics = dynamicValues ?? {};
      final formulaData = _mapOf(analysis['formula']);
      final formulaExpr = '${formulaData['expression'] ?? ''}'.trim();
      Map<String, dynamic>? computed;
      if (formulaExpr.isNotEmpty) {
        final values = <String, Object?>{};
        for (final item in analysis['items'] as List? ?? []) {
          final m = item as Map<String, dynamic>;
          values['${m['inventory_name'] ?? ''}'.trim()] =
              safeFloat(m['qty_per_sample']);
        }
        for (final e in safeDynamics.entries) {
          if (e.key.trim().isNotEmpty) values[e.key.trim()] = e.value;
        }
        try {
          final resultValue = evaluateFormula(
            formulaExpr,
            values: values,
            constants: _mapOf(formulaData['constants']),
            targetUnit: '${analysis['unit'] ?? ''}',
          );
          resultText = '$resultValue';
          computed = {
            'expression': formulaExpr,
            'value': resultValue,
            'used_values': values,
          };
        } on ValidationError catch (error) {
          throw ValidationError('Formula error: ${error.message}');
        }
      }

      final testId = await executeReturnId(txn, '''
                INSERT INTO lab_sample_tests (
                    analysis_id, source_type, source_ref_id, source_name, sample_name,
                    result_text, dynamic_values_json, entry_code, tested_by, tested_at, created_by, updated_by, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', [
        analysisId, sourceType,
        resolvedSourceRefId, cleanSourceName, cleanSampleName,
        resultText.trim(), jsonDumps(safeDynamics), cleanEntryCode,
        user == null ? null : int.parse('${user['id']}'),
        nowIso(),
        user == null ? null : int.parse('${user['id']}'),
        null, null,
      ]);
      final requested = <int, Map<String, Object?>>{};
      for (final item in analysis['items'] as List? ?? []) {
        final m = item as Map<String, dynamic>;
        final inventory = await getInventoryItemTx(txn, int.parse('${m['inventory_id']}'));
        final qty = convertQuantity(
            safeFloat(m['qty_per_sample']) ?? 0.0, '${m['unit']}', '${inventory['unit']}');
        final entry = requested.putIfAbsent(
            int.parse('${m['inventory_id']}'),
            () => {'inventory': inventory, 'qty': 0.0});
        entry['qty'] = (entry['qty'] as double) + qty;
      }
      for (final link in analysis['field_chemical_links'] as List? ?? []) {
        final lm = link as Map<String, dynamic>;
        final field = '${lm['dynamic_field'] ?? ''}'.trim();
        final qtyInput = safeFloat(safeDynamics[field]);
        final inventoryId = int.tryParse('${lm['inventory_id'] ?? 0}') ?? 0;
        if (field.isEmpty || inventoryId == 0 || qtyInput == null || qtyInput <= 0) {
          continue;
        }
        final inventory = await getInventoryItemTx(txn, inventoryId);
        final qty = convertQuantity(
            qtyInput, '${lm['unit'] ?? ''}', '${inventory['unit']}');
        final entry = requested.putIfAbsent(inventoryId, () => {'inventory': inventory, 'qty': 0.0});
        entry['qty'] = (entry['qty'] as double) + qty;
      }

      final consumption = <Map<String, dynamic>>[];
      final lowStock = <Map<String, dynamic>>[];
      final timestamp = nowIso();
      for (final item in requested.entries) {
        final state = item.value;
        final inventory = state['inventory'] as Map<String, dynamic>;
        final requestedQty = state['qty'] as double;
        if (requestedQty <= 0) continue;
        final availableQty =
            (safeFloat(inventory['current_qty']) ?? 0.0).clamp(0.0, double.infinity).toDouble();
        final appliedQty = availableQty < requestedQty ? availableQty : requestedQty;
        final shortfallQty = requestedQty - appliedQty > 0 ? requestedQty - appliedQty : 0.0;
        final newQty = availableQty - appliedQty;
        await execute(txn,
            'UPDATE lab_inventory SET current_qty = ?, updated_at = ? WHERE id = ?',
            [newQty, timestamp, item.key]);
        await execute(txn, '''
                    INSERT INTO lab_consumption_log (
                        sample_test_id, inventory_id, qty_used, requested_qty, applied_qty,
                        shortfall_qty, event_type, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, 'CONSUMPTION', ?)
                    ''', [
          testId, item.key, appliedQty, requestedQty, appliedQty, shortfallQty, timestamp,
        ]);
        consumption.add({
          'inventory_id': item.key,
          'inventory_name': inventory['name'],
          'unit': inventory['unit'],
          'qty_used': appliedQty,
          'requested_qty': requestedQty,
          'applied_qty': appliedQty,
          'shortfall_qty': shortfallQty,
          'new_qty': newQty,
        });
        if (newQty < (safeFloat(inventory['min_qty']) ?? 0.0) || shortfallQty > 0) {
          lowStock.add({
            'inventory_id': item.key,
            'inventory_name': inventory['name'],
            'current_qty': newQty,
            'min_qty': inventory['min_qty'],
            'shortfall_qty': shortfallQty,
          });
        }
      }

      Map<String, dynamic>? rangeCheck;
      if (sourceType == 'product' && resolvedSourceRefId != null) {
        final ranges = await fetchAll(txn,
            'SELECT lpa.* FROM lab_product_analyses lpa WHERE lpa.product_id = ?',
            [resolvedSourceRefId]);
        for (final row in ranges) {
          if (int.parse('${row['analysis_id']}') == analysisId) {
            rangeCheck = {
              'analysis_id': analysisId,
              'analysis_name': analysis['name'],
              'min': row['min_value'],
              'max': row['max_value'],
              'unit': '${row['unit'] ?? '%'}',
              'out_of_range': isOutOfRange(resultText, _numOf(row['min_value']), _numOf(row['max_value'])),
            };
            break;
          }
        }
      } else if (sourceType == 'raw_material' && resolvedSourceRefId != null) {
        final materialRange = await fetchOne(txn,
            'SELECT min_value, max_value, unit FROM lab_material_analyses WHERE material_id = ? AND analysis_id = ?',
            [resolvedSourceRefId, analysisId]);
        if (materialRange != null) {
          rangeCheck = {
            'analysis_id': analysisId,
            'analysis_name': analysis['name'],
            'min': materialRange['min_value'],
            'max': materialRange['max_value'],
            'unit': '${materialRange['unit'] ?? '%'}',
            'out_of_range': isOutOfRange(resultText, _numOf(materialRange['min_value']), _numOf(materialRange['max_value'])),
          };
        }
      }
      final test = await getSampleTestTx(txn, testId);
      return {
        'test': test,
        'analysis_unit': '${analysis['unit'] ?? '%'}',
        'consumption': consumption,
        'low_stock': lowStock,
        'range_check': rangeCheck,
        'computed': computed,
      };
    });
  }

  num? _numOf(Object? v) {
    if (v == null) return null;
    if (v is num) return v;
    return double.tryParse('$v'.trim());
  }

  Future<Map<String, dynamic>> _decorateAnalysisTx(DatabaseExecutor txn, int analysisId) async {
    final row = await fetchOne(txn, 'SELECT * FROM lab_analyses WHERE id = ?', [analysisId]);
    if (row == null) throw const NotFoundError('Analysis was not found.');
    final analysis = Map<String, dynamic>.from(row);
    analysis['items'] = await fetchAll(txn, '''
            SELECT 
                li.id AS item_id, li.analysis_id, li.inventory_id, li.qty_per_sample, li.unit,
                inv.name AS inventory_name, inv.category AS inventory_category, inv.current_qty
            FROM lab_analysis_items li
            JOIN lab_inventory inv ON inv.id = li.inventory_id
            WHERE li.analysis_id = ?
            ORDER BY inv.name ASC
            ''', [analysisId]);
    analysis['dynamic_fields'] = jsonLoadsList(
        '${analysis.remove('dynamic_fields_json') ?? ''}', const ['Sample Name']);
    analysis['formula'] = loadFormula('${analysis.remove('formula_json') ?? '{}'}');
    analysis['field_chemical_links'] = await fetchAll(txn, '''
            SELECT lc.*, inv.name AS inventory_name, inv.unit AS inventory_unit
            FROM lab_field_chemical_links lc
            JOIN lab_inventory inv ON inv.id = lc.inventory_id
            WHERE lc.analysis_id = ?
            ORDER BY lc.dynamic_field ASC
            ''', [analysisId]);
    return analysis;
  }

  Future<Map<String, dynamic>> getInventoryItemTx(DatabaseExecutor txn, int itemId) async {
    final row = await fetchOne(txn, 'SELECT * FROM lab_inventory WHERE id = ?', [itemId]);
    if (row == null) throw const NotFoundError('Inventory item was not found.');
    return row;
  }

  Future<Map<String, dynamic>> getSampleTest(int testId) async {
    final row = await fetchOne(null, '''
            SELECT 
                t.*, a.name AS analysis_name, a.unit AS analysis_unit
            FROM lab_sample_tests t
            JOIN lab_analyses a ON a.id = t.analysis_id
            WHERE t.id = ?
            ''', [testId]);
    if (row == null) throw const NotFoundError('Test was not found.');
    final result = Map<String, dynamic>.from(row);
    result['dynamic_values'] =
        jsonLoads('${result.remove('dynamic_values_json') ?? ''}');
    return result;
  }

  Future<Map<String, dynamic>> getSampleTestTx(DatabaseExecutor txn, int testId) async {
    final row = await fetchOne(txn, '''
            SELECT 
                t.*, a.name AS analysis_name, a.unit AS analysis_unit
            FROM lab_sample_tests t
            JOIN lab_analyses a ON a.id = t.analysis_id
            WHERE t.id = ?
            ''', [testId]);
    if (row == null) throw const NotFoundError('Test was not found.');
    final result = Map<String, dynamic>.from(row);
    result['dynamic_values'] =
        jsonLoads('${result.remove('dynamic_values_json') ?? ''}');
    return result;
  }

  Future<List<Map<String, dynamic>>> listSampleTests({
    String? sourceType,
    int? sourceRefId,
  }) async {
    var query = '''
            SELECT 
                t.*, a.name AS analysis_name, a.description AS analysis_description,
                a.unit AS analysis_unit,
                u.full_name AS tested_by_name
            FROM lab_sample_tests t
            JOIN lab_analyses a ON a.id = t.analysis_id
            LEFT JOIN users u ON u.id = t.tested_by
            WHERE 1 = 1
        ''';
    final params = <Object?>[];
    if (sourceTypes.contains(sourceType)) {
      query += ' AND t.source_type = ?';
      params.add(sourceType);
      if (sourceRefId != null) {
        query += ' AND t.source_ref_id = ?';
        params.add(sourceRefId);
      }
    }
    query += ' ORDER BY t.tested_at DESC, t.id DESC';
    final rows = await fetchAll(null, query, params);
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final item = Map<String, dynamic>.from(row);
      item['dynamic_values'] = jsonLoads('${item['dynamic_values_json'] ?? ''}');
      result.add(await enrichTest(item));
    }
    return result;
  }

  // ── Test range / out-of-range enrichment ─────────────────────────

  Map<int, Map<int, Map<String, Object?>>>? _productRangeCache;
  Map<int, Map<int, Map<String, Object?>>>? _materialRangeCache;

  Future<Map<String, dynamic>> enrichTest(Map<String, dynamic> test) async {
    final resultText = '${test['result_text'] ?? ''}'.trim();
    final raw = resultText.replaceAll('%', '').trim();
    double? value;
    if (raw.isNotEmpty) value = double.tryParse(raw);
    test['value'] = value;
    final rng = await testRangeForEnriched(test);
    if (rng != null) {
      final minimum = _numOf(rng['min']);
      final maximum = _numOf(rng['max']);
      String rangeState;
      if (minimum == null && maximum == null) {
        rangeState = 'none';
      } else {
        rangeState = isOutOfRange(resultText, minimum, maximum) ? 'out' : 'in';
      }
      test['min'] = minimum;
      test['max'] = maximum;
      test['range_unit'] = '${rng['unit'] ?? test['analysis_unit'] ?? '%'}';
      test['range_state'] = rangeState;
    } else {
      test['min'] = null;
      test['max'] = null;
      test['range_unit'] = '${test['analysis_unit'] ?? '%'}';
      test['range_state'] = 'none';
    }
    return test;
  }

  Future<Map<String, Object?>?> testRangeForEnriched(
      Map<String, dynamic> test) async {
    if (_productRangeCache == null || _materialRangeCache == null) {
      await buildRangesCache();
    }
    final sourceType = '${test['source_type'] ?? ''}';
    final analysisId = int.tryParse('${test['analysis_id'] ?? 0}') ?? 0;
    final sourceRefRaw = test['source_ref_id'];
    final sourceRef = sourceRefRaw == null || '$sourceRefRaw' == ''
        ? 0
        : (int.tryParse('$sourceRefRaw') ?? 0);
    if (sourceRef <= 0 || analysisId <= 0) return null;
    Map<int, Map<String, Object?>>? byAnalysis;
    if (sourceType == 'product') {
      byAnalysis = _productRangeCache?[sourceRef];
    } else if (sourceType == 'raw_material') {
      byAnalysis = _materialRangeCache?[sourceRef];
    }
    if (byAnalysis == null) return null;
    return byAnalysis[analysisId];
  }

  Future<void> buildRangesCache() async {
    final productMap = <int, Map<int, Map<String, Object?>>>{};
    for (final r in await getProductRangesAll()) {
      final pid = int.parse('${r['product_id']}');
      productMap.putIfAbsent(pid, () => <int, Map<String, Object?>>{})[
          int.parse('${r['analysis_id']}')] = {
        'min': r['min_value'],
        'max': r['max_value'],
        'unit': '${r['unit'] ?? '%'}',
      };
    }
    final materialMap = <int, Map<int, Map<String, Object?>>>{};
    final rawRows = await fetchAll(null, '''
            SELECT material_id, analysis_id, min_value, max_value, unit
            FROM lab_material_analyses
            ''');
    for (final r in rawRows) {
      final mid = int.parse('${r['material_id']}');
      materialMap.putIfAbsent(mid, () => <int, Map<String, Object?>>{})[
          int.parse('${r['analysis_id']}')] = {
        'min': r['min_value'],
        'max': r['max_value'],
        'unit': '${r['unit'] ?? '%'}',
      };
    }
    _productRangeCache = productMap;
    _materialRangeCache = materialMap;
  }

  // ── Lab test report data ─────────────────────────────────────────

  Future<Map<String, dynamic>> buildLabTestReportData({
    required String reportType,
    String? dateStr,
    int? month,
    int? year,
    int? analysisId,
    String? sourceType,
    int? sourceRefId,
  }) async {
    if (!['daily', 'monthly', 'yearly'].contains(reportType)) {
      throw const ValidationError('Report type must be daily, monthly or yearly.');
    }
    final params = <Object?>[];
    final where = <String>[];
    String periodLabel;
    if (reportType == 'daily') {
      if (dateStr == null || dateStr.trim().isEmpty) {
        throw const ValidationError('التاريخ مطلوب للتقرير اليومي.');
      }
      where.add("date(t.tested_at) = ?");
      final d = dateStr.trim();
      params.add(d.substring(0, d.length > 10 ? 10 : d.length));
      periodLabel = 'التقرير اليومي - $dateStr';
    } else if (reportType == 'monthly') {
      if (month == null || month == 0 || year == null || year == 0) {
        throw const ValidationError('الشهر والسنة مطلوبان للتقرير الشهري.');
      }
      where.add("strftime('%Y-%m', t.tested_at) = ?");
      params.add('${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}');
      periodLabel = 'التقرير الشهري - $month/$year';
    } else {
      if (year == null || year == 0) {
        throw const ValidationError('السنة مطلوبة للتقرير السنوي.');
      }
      where.add("strftime('%Y', t.tested_at) = ?");
      params.add(year);
      periodLabel = 'التقرير السنوي - $year';
    }
    if (analysisId != null && analysisId > 0) {
      where.add('t.analysis_id = ?');
      params.add(analysisId);
    }
    if (sourceTypes.contains(sourceType)) {
      where.add('t.source_type = ?');
      params.add(sourceType);
      if (sourceRefId != null && sourceRefId > 0) {
        where.add('t.source_ref_id = ?');
        params.add(sourceRefId);
      }
    }
    final query = '''
            SELECT 
                t.*, a.name AS analysis_name, a.description AS analysis_description,
                a.unit AS analysis_unit,
                u.full_name AS tested_by_name
            FROM lab_sample_tests t
            JOIN lab_analyses a ON a.id = t.analysis_id
            LEFT JOIN users u ON u.id = t.tested_by
            WHERE ${where.join(' AND ')}
            ORDER BY t.tested_at ASC, t.id ASC
        ''';
    final rows = await fetchAll(null, query, params);
    final tests = <Map<String, dynamic>>[];
    for (final row in rows) {
      final item = Map<String, dynamic>.from(row);
      item['dynamic_values'] = jsonLoads('${item['dynamic_values_json'] ?? ''}');
      tests.add(await enrichTest(item));
    }
    return {
      'title': periodLabel,
      'period_label': periodLabel,
      'tests': tests,
    };
  }

  // ── Consumption log / adjustments / activity ─────────────────────

  Future<List<Map<String, dynamic>>> listConsumptionLog() async {
    return fetchAll(null, '''
            SELECT 
                lc.*, inv.name AS inventory_name, inv.unit AS inventory_unit,
                t.sample_name, t.source_name, t.source_type, t.result_text,
                t.tested_by, t.tested_at,
                a.name AS analysis_name,
                u.full_name AS tested_by_name
            FROM lab_consumption_log lc
            JOIN lab_inventory inv ON inv.id = lc.inventory_id
            JOIN lab_sample_tests t ON t.id = lc.sample_test_id
            JOIN lab_analyses a ON a.id = t.analysis_id
            LEFT JOIN users u ON u.id = t.tested_by
            ORDER BY lc.created_at DESC, lc.id DESC
            ''');
  }

  Future<List<Map<String, dynamic>>> listStockAdjustments({int limit = 500}) async {
    final rows = await fetchAll(null, '''
            SELECT 
                sa.*, inv.name AS inventory_name, inv.unit AS inventory_unit,
                u.full_name AS adjusted_by_name
            FROM lab_stock_adjustments sa
            JOIN lab_inventory inv ON inv.id = sa.inventory_id
            LEFT JOIN users u ON u.id = sa.adjusted_by
            ORDER BY sa.adjusted_at DESC, sa.id DESC
            LIMIT ?
            ''', [limit]);
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final entry = Map<String, dynamic>.from(row);
      entry['diff'] =
          (safeFloat(entry['new_qty']) ?? 0.0) - (safeFloat(entry['old_qty']) ?? 0.0);
      result.add(entry);
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> listItemStockAdjustments(
      int inventoryId, {int limit = 200}) async {
    final rows = await fetchAll(null, '''
            SELECT 
                sa.*, inv.name AS inventory_name, inv.unit AS inventory_unit,
                u.full_name AS adjusted_by_name
            FROM lab_stock_adjustments sa
            JOIN lab_inventory inv ON inv.id = sa.inventory_id
            LEFT JOIN users u ON u.id = sa.adjusted_by
            WHERE sa.inventory_id = ?
            ORDER BY sa.adjusted_at DESC, sa.id DESC
            LIMIT ?
            ''', [inventoryId, limit]);
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final entry = Map<String, dynamic>.from(row);
      entry['diff'] =
          (safeFloat(entry['new_qty']) ?? 0.0) - (safeFloat(entry['old_qty']) ?? 0.0);
      result.add(entry);
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> activityLog({int limit = 300}) async {
    final entries = <Map<String, dynamic>>[];
    for (final adj in await listStockAdjustments(limit: limit)) {
      entries.add({
        'entry_id': 'adj-${adj['id']}',
        'type': 'adjust',
        'inventory_name': adj['inventory_name'],
        'quantity_text':
            '${adj['old_qty']} → ${adj['new_qty']} ${adj['inventory_unit']}',
        'diff': adj['diff'],
        'unit': adj['inventory_unit'],
        'user_name': adj['adjusted_by_name'] ?? '-',
        'reason': adj['reason'] ?? '',
        'at': adj['adjusted_at'] ?? '',
      });
    }
    for (final cons in await listConsumptionLog()) {
      entries.add({
        'entry_id': 'cons-${cons['id']}',
        'type': 'consume',
        'inventory_name': cons['inventory_name'],
        'quantity_text': '-${cons['qty_used']} ${cons['inventory_unit']}',
        'diff': -(safeFloat(cons['qty_used']) ?? 0.0),
        'unit': cons['inventory_unit'],
        'user_name': cons['tested_by_name'] ?? '-',
        'reason':
            '${cons['analysis_name']} · ${cons['source_name']} · ${cons['sample_name']}',
        'at': '${cons['tested_at'] ?? cons['created_at'] ?? ''}',
      });
    }
    entries.sort((a, b) => '${b['at']}'.compareTo('${a['at']}'));
    return entries.take(limit).toList();
  }

  // ── Dashboard summary ────────────────────────────────────────────

  List<String> _lastMonthKeys(DateTime now) {
    final keys = <String>[];
    var y = now.year;
    var m = now.month;
    for (var i = 0; i < 6; i++) {
      keys.add('${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}');
      m--;
      if (m == 0) {
        m = 12;
        y--;
      }
    }
    return keys.reversed.toList();
  }

  Future<Map<String, dynamic>> dashboardSummary({String period = 'all'}) async {
    final cleanPeriod = period.trim().toLowerCase();
    DateTime? cutoff;
    final now = DateTime.now().toUtc();
    if (cleanPeriod == '7d') {
      cutoff = now.subtract(const Duration(days: 7));
    } else if (cleanPeriod == '30d') {
      cutoff = now.subtract(const Duration(days: 30));
    } else if (cleanPeriod == '90d') {
      cutoff = now.subtract(const Duration(days: 90));
    } else if (cleanPeriod == '365d') {
      cutoff = now.subtract(const Duration(days: 365));
    }
    String? cutoffKey;
    if (cutoff != null) {
      cutoffKey =
          '${cutoff.year.toString().padLeft(4, '0')}-${cutoff.month.toString().padLeft(2, '0')}-${cutoff.day.toString().padLeft(2, '0')}';
    }

    final tests = <Map<String, dynamic>>[];
    for (final test in await listSampleTests()) {
      final dateKey = '${test['tested_at'] ?? ''}';
      if (cutoffKey == null || dateKey.length >= 10 && dateKey.substring(0, 10).compareTo(cutoffKey) >= 0) {
        tests.add(test);
      }
    }
    final inRange = [for (final t in tests) if (t['range_state'] == 'in') t];
    final outRange = [for (final t in tests) if (t['range_state'] == 'out') t];
    final judged = [...inRange, ...outRange];
    final passRate = judged.isEmpty ? 0.0 : (inRange.length / judged.length * 100);

    final monthKeys = <String>[..._lastMonthKeys(now)];
    final monthMap = <String, Map<String, Object?>>{
      for (final key in monthKeys)
        key: {'label': monthLabel(key), 'total': 0, 'in_range': 0, 'out_of_range': 0},
    };
    for (final test in tests) {
      final key = '${test['tested_at'] ?? ''}';
      final bucketKey = key.length >= 7 ? key.substring(0, 7) : '';
      final bucket = monthMap[bucketKey];
      if (bucket == null) continue;
      bucket['total'] = (bucket['total'] as int) + 1;
      if (test['range_state'] == 'in') {
        bucket['in_range'] = (bucket['in_range'] as int) + 1;
      } else if (test['range_state'] == 'out') {
        bucket['out_of_range'] = (bucket['out_of_range'] as int) + 1;
      }
    }
    for (final bucket in monthMap.values) {
      final judgedM = (bucket['in_range'] as int) + (bucket['out_of_range'] as int);
      bucket['in_range_pct'] =
          judgedM == 0 ? 0.0 : ((bucket['in_range'] as int) / judgedM * 100);
    }

    final lowStock = await getLowStockItems();
    return {
      'period': cleanPeriod,
      'kpis': {
        'total_tests': tests.length,
        'tests_evaluated': judged.length,
        'in_range': inRange.length,
        'out_of_range': outRange.length,
        'pass_rate': ((passRate * 10).round() / 10.0),
        'low_stock_count': lowStock.length,
      },
      'monthly_trend': [for (final k in monthKeys) monthMap[k]],
      'low_stock': lowStock,
    };
  }

  // ── Test lookup / injection ──────────────────────────────────────

  Future<List<Map<String, dynamic>>> findTestsForAnalysisAndSource(
      int analysisId, String sourceType, int sourceRefId) async {
    return fetchAll(null, '''
            SELECT 
                t.*, a.name AS analysis_name, a.unit AS analysis_unit
            FROM lab_sample_tests t
            JOIN lab_analyses a ON a.id = t.analysis_id
            WHERE t.analysis_id = ? AND t.source_type = ? AND t.source_ref_id = ?
            ORDER BY t.tested_at DESC, t.id DESC
            ''', [analysisId, sourceType, sourceRefId]);
  }

  Future<Map<String, dynamic>> injectLabTests(
      Map<String, dynamic> inspection) async {
    final entryCode = '${inspection['entry_code'] ?? ''}'.trim();
    final materialName = '${inspection['material_name'] ?? ''}'.trim();
    final inspectionDate = '${inspection['inspection_date'] ?? ''}'.trim();
    if (entryCode.isNotEmpty) {
      final rows = await fetchAll(null, '''
                SELECT
                    t.*, a.name AS analysis_name, a.unit AS analysis_unit
                FROM lab_sample_tests t
                JOIN lab_analyses a ON a.id = t.analysis_id
                WHERE t.source_type = 'raw_material'
                  AND t.entry_code = ?
                ORDER BY t.tested_at DESC, t.id DESC
                ''', [entryCode]);
      final tests = [for (final r in rows) Map<String, dynamic>.from(r)];
      if (tests.isNotEmpty) {
        inspection['lab_tests'] = tests;
        return inspection;
      }
    }
    if (materialName.isEmpty) {
      inspection['lab_tests'] = <Map<String, dynamic>>[];
      return inspection;
    }
    final params = <Object?>[materialName];
    var query = '''
            SELECT
                t.*, a.name AS analysis_name, a.unit AS analysis_unit
            FROM lab_sample_tests t
            JOIN lab_analyses a ON a.id = t.analysis_id
            WHERE t.source_type = 'raw_material'
              AND t.source_name = ?
        ''';
    if (inspectionDate.isNotEmpty) {
      query += ' AND date(t.tested_at) = ?';
      params.add(inspectionDate.substring(0, inspectionDate.length > 10 ? 10 : inspectionDate.length));
    }
    query += ' ORDER BY t.tested_at DESC, t.id DESC';
    final rows = await fetchAll(null, query, params);
    inspection['lab_tests'] = [for (final r in rows) Map<String, dynamic>.from(r)];
    return inspection;
  }

  // ── Shared worksheet ─────────────────────────────────────────────

  Future<Map<int, double>> worksheetConsumptionMap(
    Map<String, dynamic> analysis,
    Map<String, dynamic>? dynamicValues,
    Map<int, Map<String, dynamic>>? inventoryMap,
  ) async {
    final consumed = <int, double>{};
    for (final item in analysis['items'] as List? ?? []) {
      final m = item as Map<String, dynamic>;
      final inventoryId = int.parse('${m['inventory_id']}');
      final inventory = await inventoryForConsumption(inventoryId, inventoryMap);
      final qty = convertQuantity(
          safeFloat(m['qty_per_sample']) ?? 0.0, '${m['unit']}', '${inventory['unit']}');
      consumed[inventoryId] = (consumed[inventoryId] ?? 0.0) + qty;
    }
    final dyn = dynamicValues ?? {};
    for (final link in analysis['field_chemical_links'] as List? ?? []) {
      final lm = link as Map<String, dynamic>;
      final dynamicField = '${lm['dynamic_field'] ?? ''}'.trim();
      final inventoryId = int.tryParse('${lm['inventory_id'] ?? 0}') ?? 0;
      if (dynamicField.isEmpty || inventoryId == 0) continue;
      final fieldVal = safeFloat(dyn[dynamicField]);
      final linkUnit = '${lm['unit'] ?? ''}'.trim();
      if (fieldVal == null || fieldVal <= 0) continue;
      final inventory = await inventoryForConsumption(inventoryId, inventoryMap);
      final qty = convertQuantity(fieldVal, linkUnit, '${inventory['unit']}');
      consumed[inventoryId] = (consumed[inventoryId] ?? 0.0) + qty;
    }
    return consumed;
  }

  Future<Map<String, dynamic>> inventoryForConsumption(
      int inventoryId, Map<int, Map<String, dynamic>>? inventoryMap) async {
    if (inventoryMap != null && inventoryMap.containsKey(inventoryId)) {
      return inventoryMap[inventoryId]!;
    }
    return getInventoryItem(inventoryId);
  }

  Future<String> worksheetTryCompute(
      Map<String, dynamic> analysis, Map<String, dynamic> dynamicValues) async {
    final formulaData = _mapOf(analysis['formula']);
    final formulaExpr = '${formulaData['expression'] ?? ''}'.trim();
    if (formulaExpr.isEmpty) return '';
    final combined = <String, Object?>{};
    for (final item in analysis['items'] as List? ?? []) {
      final m = item as Map<String, dynamic>;
      combined['${m['inventory_name'] ?? ''}'.trim()] = safeFloat(m['qty_per_sample']);
    }
    for (final e in dynamicValues.entries) {
      if (e.key.trim().isNotEmpty) {
        combined[e.key.trim()] = e.value;
      }
    }
    try {
      final value = evaluateFormula(
        formulaExpr,
        values: combined,
        constants: _mapOf(formulaData['constants']),
        targetUnit: '${analysis['unit'] ?? ''}',
      );
      return '$value';
    } on ValidationError {
      return '';
    } on FormatException {
      return '';
    }
  }

  Future<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)> applyConsumptionDelta(
    DatabaseExecutor txn,
    int sampleTestId,
    Map<int, double> oldMap,
    Map<int, double> newMap,
    Map<String, dynamic>? user,
    Map<int, Map<String, dynamic>>? inventoryMap,
  ) async {
    final inventoryIds = <int>{...oldMap.keys, ...newMap.keys};
    final consumption = <Map<String, dynamic>>[];
    final lowStock = <Map<String, dynamic>>[];
    final timestamp = nowIso();
    for (final inventoryId in inventoryIds) {
      final delta = (newMap[inventoryId] ?? 0.0) - (oldMap[inventoryId] ?? 0.0);
      if (delta.abs() < 1e-9) continue;
      final inventory = await getInventoryItemTx(txn, inventoryId);
      final currentQty =
        (safeFloat(inventory['current_qty']) ?? 0.0).clamp(0.0, double.infinity).toDouble();
      final requestedQty = delta.abs();
      final isReversal = delta < 0;
      final appliedQty =
          isReversal ? requestedQty : (currentQty < requestedQty ? currentQty : requestedQty);
      final shortfallQty =
          isReversal ? 0.0 : (requestedQty - appliedQty > 0 ? requestedQty - appliedQty : 0.0);
      final newQty = isReversal ? currentQty + appliedQty : currentQty - appliedQty;
      await execute(txn,
          'UPDATE lab_inventory SET current_qty = ?, updated_at = ? WHERE id = ?',
          [newQty, timestamp, inventoryId]);
      await execute(txn, '''
                INSERT INTO lab_consumption_log (
                    sample_test_id, inventory_id, qty_used, requested_qty, applied_qty,
                    shortfall_qty, event_type, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ''', [
        sampleTestId, inventoryId,
        isReversal ? -appliedQty : appliedQty,
        requestedQty, appliedQty, shortfallQty,
        isReversal ? 'REVERSAL' : 'CONSUMPTION', timestamp,
      ]);
      if (inventoryMap != null) {
        inventoryMap[inventoryId] = {...inventory, 'current_qty': newQty};
      }
      consumption.add({
        'inventory_id': inventoryId,
        'inventory_name': inventory['name'],
        'unit': inventory['unit'],
        'qty_used': isReversal ? -appliedQty : appliedQty,
        'requested_qty': requestedQty,
        'applied_qty': appliedQty,
        'shortfall_qty': shortfallQty,
        'new_qty': newQty,
      });
      if (newQty < (safeFloat(inventory['min_qty']) ?? 0.0) || shortfallQty > 0) {
        lowStock.add({
          'inventory_id': inventoryId,
          'inventory_name': inventory['name'],
          'current_qty': newQty,
          'min_qty': inventory['min_qty'],
        });
      }
    }
    return (consumption, lowStock);
  }

  Future<Map<int, Map<String, dynamic>>> batchLoadAnalyses(DatabaseExecutor? txn, Set<int> analysisIds) async {
    final ids = analysisIds.toSet().toList()..sort();
    if (ids.isEmpty) return {};
    final qmarks = List.filled(ids.length, '?').join(',');
    final exec = txn ?? await _db;
    final analysisRows =
        await exec.rawQuery('SELECT * FROM lab_analyses WHERE id IN ($qmarks)', ids);
    if (analysisRows.length != ids.length) {
      throw const NotFoundError('Analysis was not found.');
    }
    final analyses = <int, Map<String, dynamic>>{
      for (final r in analysisRows) int.parse('${r['id']}'): Map<String, dynamic>.from(r),
    };
    for (final a in analyses.values) {
      a['dynamic_fields'] = jsonLoadsList('${a.remove('dynamic_fields_json') ?? ''}', const ['Sample Name']);
      a['formula'] = loadFormula('${a.remove('formula_json') ?? '{}'}');
    }
    final itemRows = await exec.rawQuery('''
            SELECT li.id AS item_id, li.analysis_id, li.inventory_id, li.qty_per_sample, li.unit,
                inv.name AS inventory_name, inv.category AS inventory_category, inv.current_qty
            FROM lab_analysis_items li
            JOIN lab_inventory inv ON inv.id = li.inventory_id
            WHERE li.analysis_id IN ($qmarks)
            ORDER BY inv.name ASC
            ''', ids);
    final linkRows = await exec.rawQuery('''
            SELECT lc.*, inv.name AS inventory_name, inv.unit AS inventory_unit
            FROM lab_field_chemical_links lc
            JOIN lab_inventory inv ON inv.id = lc.inventory_id
            WHERE lc.analysis_id IN ($qmarks)
            ORDER BY lc.dynamic_field ASC
            ''', ids);
    final itemsByAnalysis = <int, List<Map<String, dynamic>>>{};
    for (final r in itemRows) {
      itemsByAnalysis.putIfAbsent(int.parse('${r['analysis_id']}'), () => []).add(Map<String, dynamic>.from(r));
    }
    final linksByAnalysis = <int, List<Map<String, dynamic>>>{};
    for (final r in linkRows) {
      linksByAnalysis.putIfAbsent(int.parse('${r['analysis_id']}'), () => []).add(Map<String, dynamic>.from(r));
    }
    for (final id in ids) {
      analyses[id]!['items'] = itemsByAnalysis[id] ?? <Map<String, dynamic>>[];
      analyses[id]!['field_chemical_links'] = linksByAnalysis[id] ?? <Map<String, dynamic>>[];
    }
    return analyses;
  }

  Future<Map<int, Map<String, dynamic>>> loadInventoryMap(Set<int> inventoryIds) async {
    final ids = inventoryIds.toSet().toList()..sort();
    if (ids.isEmpty) return {};
    final qmarks = List.filled(ids.length, '?').join(',');
    final rows =
        await (await _db).rawQuery('SELECT * FROM lab_inventory WHERE id IN ($qmarks)', ids);
    final found = <int, Map<String, dynamic>>{
      for (final r in rows) int.parse('${r['id']}'): Map<String, dynamic>.from(r),
    };
    final missing = ids.where((id) => !found.containsKey(id)).toList();
    if (missing.isNotEmpty) {
      throw const NotFoundError('Inventory item was not found.');
    }
    return found;
  }

  Future<List<Map<String, dynamic>>> _serializeWorksheet(DatabaseExecutor? txn) async {
    final exec = txn ?? await _db;
    final rows = await exec.rawQuery(
        "SELECT * FROM lab_worksheet WHERE status = 'ACTIVE' ORDER BY id ASC");
    if (rows.isEmpty) return [];
    final rowIds = [for (final r in rows) int.parse('${r['id']}')];
    final qmarks = List.filled(rowIds.length, '?').join(',');
    final testRows = await exec.rawQuery('''
            SELECT * FROM lab_sample_tests
            WHERE worksheet_row_id IN ($qmarks)
            ORDER BY worksheet_row_id ASC, analysis_id ASC
            ''', rowIds);
    final testsByRow = <int, List<Map<String, dynamic>>>{};
    for (final r in testRows) {
      testsByRow.putIfAbsent(int.parse('${r['worksheet_row_id']}'), () => []).add(Map<String, dynamic>.from(r));
    }
    final userIds = <int>{};
    for (final row in rows) {
      if (row['created_by'] != null) userIds.add(int.parse('${row['created_by']}'));
      if (row['updated_by'] != null) userIds.add(int.parse('${row['updated_by']}'));
    }
    final userNames = <int, String>{};
    if (userIds.isNotEmpty) {
      final uidMarks = List.filled(userIds.length, '?').join(',');
      final nameRows =
          await exec.rawQuery('SELECT id, full_name FROM users WHERE id IN ($uidMarks)', userIds.toList());
      for (final r in nameRows) {
        userNames[int.parse('${r['id']}')] = '${r['full_name']}';
      }
    }
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final item = Map<String, dynamic>.from(row);
      final createdBy = item['created_by'];
      final updatedBy = item['updated_by'];
      item['created_by_name'] =
          createdBy != null ? (userNames[int.parse('$createdBy')] ?? '') : '';
      item['updated_by_name'] =
          updatedBy != null ? (userNames[int.parse('$updatedBy')] ?? '') : '';
      item['tests'] = <String, Map<String, dynamic>>{};
      for (final testRow in testsByRow[int.parse('${row['id']}')] ?? []) {
        final test = Map<String, dynamic>.from(testRow);
        test['dynamic_values'] = jsonLoads('${test.remove('dynamic_values_json') ?? ''}');
        (item['tests'] as Map<String, dynamic>)[
            '${int.parse('${test['analysis_id']}')}'] = test;
      }
      result.add(item);
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> getWorksheet() {
    return _serializeWorksheet(null);
  }

  Future<Map<String, dynamic>> saveWorksheet(
      List<Map<String, dynamic>> rows, Map<String, dynamic>? user) async {
    final db = await _db;
    return db.transaction((txn) async {
      final userId = user == null ? null : int.parse('${user['id']}');
      final timestamp = nowIso();

      final analysisIds = <int>{};
      for (final payloadRow in rows) {
        for (final key in ((payloadRow['tests'] as Map?) ?? {}).keys) {
          final analysisId = int.tryParse('$key') ?? 0;
          if (analysisId > 0) analysisIds.add(analysisId);
        }
      }
      final analyses = await batchLoadAnalyses(txn, analysisIds);

      final consumptionInventoryIds = <int>{};
      for (final analysis in analyses.values) {
        for (final item in analysis['items'] as List? ?? []) {
          consumptionInventoryIds.add(int.parse('${(item as Map)['inventory_id']}'));
        }
        for (final link in analysis['field_chemical_links'] as List? ?? []) {
          final lm = link as Map<String, dynamic>;
          if (lm['dynamic_field'] != null && lm['inventory_id'] != null) {
            consumptionInventoryIds.add(int.parse('${lm['inventory_id']}'));
          }
        }
      }
      final inventoryMap = await loadInventoryMap(consumptionInventoryIds);

      final consResult = <Map<String, dynamic>>[];
      final lowResult = <Map<String, dynamic>>[];
      var created = 0;
      var updated = 0;

      for (final payloadRow in rows) {
        var sourceType = '${payloadRow['source_type'] ?? 'raw_material'}'.trim();
        if (!sourceTypes.contains(sourceType)) sourceType = 'raw_material';
        int? sourceRefId;
        final rawRef = payloadRow['source_ref_id'];
        if (rawRef is String) {
          sourceRefId = rawRef.trim().isEmpty ? null : int.tryParse(rawRef.trim());
        } else if (rawRef != null) {
          sourceRefId = int.tryParse('$rawRef');
        }
        var sourceName = '${payloadRow['source_name'] ?? ''}'.trim();
        final sampleNumber = '${payloadRow['sample_number'] ?? ''}'.trim();
        final entryCode = '${payloadRow['entry_code'] ?? ''}'.trim();
        if (sourceType == 'raw_material' && entryCode.isNotEmpty) {
          final inspection = await fetchOne(txn,
              'SELECT id, material_id, material_name, material_code, inspection_date FROM inspections WHERE entry_code = ?',
              [entryCode]);
          if (inspection == null) {
            throw ValidationError('كود الدخول غير موجود في سجل الدخول: $entryCode');
          }
          if (inspection['material_id'] != null) {
            sourceRefId = int.parse('${inspection['material_id']}');
          }
          if ('${inspection['material_name'] ?? ''}'.trim().isNotEmpty) {
            sourceName = '${inspection['material_name']}'.trim();
          }
        }

        final rawRowId = payloadRow['row_id'];
        final int wsId;
        if (rawRowId != null && '$rawRowId'.trim().isNotEmpty) {
          final existing = await fetchOne(
              txn, 'SELECT id FROM lab_worksheet WHERE id = ?', [int.parse('$rawRowId')]);
          if (existing == null) throw const NotFoundError('Worksheet row not found.');
          await execute(txn, '''
                            UPDATE lab_worksheet SET source_type = ?, source_ref_id = ?,
                                source_name = ?, sample_number = ?, entry_code = ?, updated_by = ?, updated_at = ?
                            WHERE id = ?
                            ''', [
            sourceType, sourceRefId, sourceName, sampleNumber, entryCode, userId, timestamp,
            int.parse('$rawRowId'),
          ]);
          wsId = int.parse('$rawRowId');
        } else {
          wsId = await executeReturnId(txn, '''
                            INSERT INTO lab_worksheet (source_type, source_ref_id, source_name,
                                sample_number, entry_code, created_by, created_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            ''', [
            sourceType, sourceRefId, sourceName, sampleNumber, entryCode, userId, timestamp,
          ]);
        }

        for (final entry in ((payloadRow['tests'] as Map?) ?? {}).entries) {
          final analysisId = int.tryParse('${entry.key}') ?? 0;
          if (analysisId <= 0) continue;
          final analysis = analyses[analysisId]!;
          final data = entry.value is Map ? Map<String, dynamic>.from(entry.value as Map) : <String, dynamic>{};
          final dynamicValuesRaw = data['dynamic_values'];
          final dynamicValues = dynamicValuesRaw is Map
              ? Map<String, dynamic>.from(dynamicValuesRaw)
              : <String, dynamic>{};
          var resultText = '${data['result_text'] ?? ''}'.trim();
          if (resultText.isEmpty) {
            resultText = await worksheetTryCompute(analysis, dynamicValues);
          }
          final newMap = await worksheetConsumptionMap(analysis, dynamicValues, inventoryMap);

          final existingTest = await fetchOne(txn, '''
                            SELECT * FROM lab_sample_tests
                            WHERE worksheet_row_id = ? AND analysis_id = ?
                            ''', [wsId, analysisId]);
          if (existingTest != null) {
            final oldDyn = jsonLoads('${existingTest['dynamic_values_json'] ?? ''}');
            final oldMap = await worksheetConsumptionMap(analysis, oldDyn, inventoryMap);
            await execute(txn, '''
                            UPDATE lab_sample_tests SET source_type = ?, source_ref_id = ?,
                                source_name = ?, sample_name = ?, result_text = ?,
                                dynamic_values_json = ?, entry_code = ?, updated_by = ?, updated_at = ?
                            WHERE id = ?
                            ''', [
              sourceType, sourceRefId, sourceName,
              sampleNumber.isEmpty ? sourceName : sampleNumber,
              resultText, jsonDumps(dynamicValues), entryCode,
              userId, timestamp, int.parse('${existingTest['id']}'),
            ]);
            final (consumed, lowStock) = await applyConsumptionDelta(
                txn, int.parse('${existingTest['id']}'), oldMap, newMap, user, inventoryMap);
            consResult.addAll(consumed);
            lowResult.addAll(lowStock);
            updated++;
          } else {
            final testId = await executeReturnId(txn, '''
                            INSERT INTO lab_sample_tests (
                                analysis_id, source_type, source_ref_id, source_name, sample_name,
                                result_text, dynamic_values_json, entry_code, worksheet_row_id,
                                tested_by, tested_at, created_by, updated_by, updated_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ''', [
              analysisId, sourceType, sourceRefId, sourceName,
              sampleNumber.isEmpty ? sourceName : sampleNumber,
              resultText, jsonDumps(dynamicValues), entryCode,
              wsId, userId, timestamp, userId, null, null,
            ]);
            final (consumed, lowStock) =
                await applyConsumptionDelta(txn, testId, {}, newMap, user, inventoryMap);
            consResult.addAll(consumed);
            lowResult.addAll(lowStock);
            created++;
          }
        }
      }
      return {
        'created': created,
        'updated': updated,
        'consumption': consResult,
        'low_stock': lowResult,
        'rows': await _serializeWorksheet(txn),
      };
    });
  }

  Future<Map<String, dynamic>> deleteWorksheetRow({
    required int rowId,
    Map<String, dynamic>? user,
    String reason = '',
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final row = await fetchOne(
          txn, 'SELECT * FROM lab_worksheet WHERE id = ?', [rowId]);
      if (row == null) throw const NotFoundError('Worksheet row was not found.');
      if ('${row['status'] ?? 'ACTIVE'}' == 'VOIDED') {
        throw const ValidationError('تم إلغاء هذا الصف بالفعل.');
      }
      final cleanReason = reason.trim();
      if (cleanReason.isEmpty) {
        throw const ValidationError('سبب الإلغاء مطلوب للحفاظ على سجل التدقيق.');
      }
      final timestamp = nowIso();
      final userId = user == null ? null : int.parse('${user['id']}');
      var reversedCount = 0;
      final tests = await fetchAll(txn,
          'SELECT id FROM lab_sample_tests WHERE worksheet_row_id = ?', [rowId]);
      for (final t in tests) {
        final testId = int.parse('${t['id']}');
        final logs = await fetchAll(txn, '''
                    SELECT * FROM lab_consumption_log
                    WHERE sample_test_id = ? AND event_type = 'CONSUMPTION'
                    ''', [testId]);
        for (final log in logs) {
          final alreadyReversed = await fetchOne(txn,
              'SELECT id FROM lab_consumption_log WHERE reversal_of_log_id = ?',
              [int.parse('${log['id']}')]);
          if (alreadyReversed != null) continue;
          final appliedRaw = log['applied_qty'] ?? log['qty_used'];
          final appliedQty =
              (safeFloat(appliedRaw) ?? 0.0).clamp(0.0, double.infinity).toDouble();
          if (appliedQty <= 0) continue;
          final inventoryId = int.parse('${log['inventory_id']}');
          final inventory = await getInventoryItemTx(txn, inventoryId);
          final newQty = (safeFloat(inventory['current_qty']) ?? 0.0) + appliedQty;
          await execute(txn,
              'UPDATE lab_inventory SET current_qty = ?, updated_at = ? WHERE id = ?',
              [newQty, timestamp, inventoryId]);
          await execute(txn, '''
                    INSERT INTO lab_consumption_log (
                        sample_test_id, inventory_id, qty_used, requested_qty, applied_qty,
                        shortfall_qty, event_type, reversal_of_log_id, created_at
                    ) VALUES (?, ?, ?, ?, ?, 0, 'REVERSAL', ?, ?)
                    ''', [
            testId, inventoryId, -appliedQty, appliedQty, appliedQty,
            int.parse('${log['id']}'), timestamp,
          ]);
          reversedCount++;
        }
      }
      await execute(txn, '''
                UPDATE lab_worksheet SET status = 'VOIDED', void_reason = ?,
                   voided_by = ?, voided_at = ?, updated_by = ?, updated_at = ? WHERE id = ?
                ''', [cleanReason, userId, timestamp, userId, timestamp, rowId]);
      return {'voided': true, 'reversed_entries': reversedCount};
    });
  }

  // ── Formula serialization helpers ───────────────────────────────

  Map<String, dynamic> loadFormula(String raw) => normalizeFormulaValue(jsonLoads(raw, {}));
}