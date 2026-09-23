/// Pure kernel for the Test History panel (port of lab/testHistoryLogic.js):
/// search / filter / sort / pagination / chips / summary. Kept framework-free
/// so the semantics match the Web reference exactly.
library;

const int thPageSize = 50;

String thNormalizeText(Object? value) {
  return '${value ?? ''}'
      .replaceAll(RegExp(r'[\u064B-\u0652\u0640]'), '')
      .replaceAll(RegExp(r'[\u0623\u0622\u0625]'), '\u0627')
      .replaceAll('\u0629', '\u0647')
      .replaceAll('\u0649', '\u064A')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
}

String thRangeLabel(String state) {
  if (state == 'out') return 'خارج النطاق';
  if (state == 'in') return 'ضمن النطاق';
  return 'بدون نطاق';
}

String thSourceLabel(String sourceType) {
  return sourceType == 'product' ? 'منتج' : 'خام';
}

int thCoerceRecordLimit(Object? raw) {
  final parsed = int.tryParse('${raw ?? '100'}');
  if (parsed == null || parsed < 1) return 100;
  return parsed > 10000 ? 10000 : parsed;
}

DateTime? thParseTestedAt(Object? value) {
  final s = '${value ?? ''}'.trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

DateTime? thParseDay(Object? value) {
  final s = '${value ?? ''}'.trim();
  if (s.length < 10) return null;
  return DateTime.tryParse('${s.substring(0, 10)}T00:00:00');
}

/// Port of fmtDateTime from labUtils (dd/MM/yyyy HH:mm).
String thFmtDateTime(Object? iso) {
  final d = thParseTestedAt(iso);
  if (d == null) return '${iso ?? '-'}';
  final dd = d.day.toString().padLeft(2, '0');
  final mm = (d.month).toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final mi = d.minute.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year} $hh:$mi';
}

String thTodayISO([DateTime? now]) {
  final n = now ?? DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

List<Map<String, dynamic>> thFilterModeRows(
  List<Map<String, dynamic>> rows,
  String mode,
  String specificDate, {
  DateTime? now,
}) {
  if (mode == 'last24h') {
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final cutoff = nowMs - 24 * 60 * 60 * 1000;
    return [
      for (final r in rows)
        if (thParseTestedAt(r['tested_at']) case final d?)
          if (d.millisecondsSinceEpoch >= cutoff) r
    ];
  }
  if (mode == 'specific-date' && specificDate.isNotEmpty) {
    return [
      for (final r in rows)
        if ('${r['tested_at'] ?? ''}'.startsWith(specificDate)) r
    ];
  }
  return rows;
}

String thSearchHaystack(Map<String, dynamic> row) {
  return thNormalizeText([
    row['sample_name'],
    row['source_name'],
    row['entry_code'],
    row['analysis_name'],
    row['analysis_unit'],
    row['result_text'],
    row['value'],
    row['min'],
    row['max'],
    row['range_unit'],
    row['tested_by_name'],
    row['id'],
    thRangeLabel('${row['range_state'] ?? ''}'),
    thSourceLabel('${row['source_type'] ?? ''}'),
    '${row['tested_at'] ?? ''}',
  ].where((v) => v != null).join(' '));
}

List<Map<String, dynamic>> thApplyRowFilters(
  List<Map<String, dynamic>> rows, {
  required Object? analysisId,
  required Object? sourceType,
  required Object? chemicalId,
  required Object? rangeState,
  required String query,
  required Map<String, Set<String>> chemTestMap,
}) {
  var result = rows;
  final analysisWant = '$analysisId';
  if (analysisWant.isNotEmpty) {
    result = [
      for (final r in result)
        if ('${r['analysis_id'] ?? ''}' == analysisWant) r
    ];
  }
  final sourceWant = '$sourceType';
  if (sourceWant.isNotEmpty) {
    result = [
      for (final r in result)
        if ('${r['source_type'] ?? ''}' == sourceWant) r
    ];
  }
  final chemWant = '$chemicalId';
  if (chemWant.isNotEmpty) {
    result = [
      for (final r in result)
        if (chemTestMap['${r['id']}']?.contains(chemWant) ?? false) r
    ];
  }
  final rangeWant = '$rangeState';
  if (rangeWant.isNotEmpty) {
    result = [
      for (final r in result)
        if ('${r['range_state'] ?? 'none'}' == rangeWant) r
    ];
  }
  final q = thNormalizeText(query);
  if (q.isNotEmpty) {
    final terms = [
      for (final t in q.split('&'))
        if (thNormalizeText(t).isNotEmpty) thNormalizeText(t)
    ];
    result = [
      for (final r in result)
        if (terms.any((t) => thSearchHaystack(r).contains(t))) r
    ];
  }
  return result;
}

List<Map<String, dynamic>> thSlice(List<Map<String, dynamic>> rows, int limit) {
  if (rows.length <= limit) return rows;
  return rows.sublist(0, limit);
}

({String key, int dir}) thNextSort(String key, String currentKey, int currentDir) {
  if (currentKey == key) {
    return (key: key, dir: currentDir * -1);
  }
  return (key: key, dir: 1);
}

List<Map<String, dynamic>> thSortRows(
    List<Map<String, dynamic>> rows, String key, int dir) {
  final list = rows.sublist(0);
  if (key.isEmpty) return list;
  list.sort((a, b) {
    final av = a[key];
    final bv = b[key];
    if (key == 'tested_at') {
      final da = thParseTestedAt(av)?.millisecondsSinceEpoch ?? 0;
      final db = thParseTestedAt(bv)?.millisecondsSinceEpoch ?? 0;
      return (da - db) * dir;
    }
    final an = double.tryParse('$av');
    final bn = double.tryParse('$bv');
    if (av != null &&
        bv != null &&
        '$av'.isNotEmpty &&
        '$bv'.isNotEmpty &&
        an != null &&
        bn != null) {
      return ((an - bn) * dir).sign.toInt();
    }
    final sa = '$av'.toLowerCase();
    final sb = '$bv'.toLowerCase();
    return sa.compareTo(sb) * dir;
  });
  return list;
}

({int pageCount, int start, List<Map<String, dynamic>> slice, int pageSize})
    thPagination(List<Map<String, dynamic>> rows, int page, [int pageSize = thPageSize]) {
  final count = rows.isEmpty ? 1 : ((rows.length / pageSize).ceil());
  final start = (page - 1) * pageSize;
  final slice = start >= rows.length || rows.isEmpty
      ? <Map<String, dynamic>>[]
      : rows.sublist(start, (start + pageSize) > rows.length ? rows.length : start + pageSize);
  return (pageCount: count, start: start, slice: slice, pageSize: pageSize);
}

Map<String, int> thBuildSummary(List<Map<String, dynamic>> rows) {
  var out = 0, inn = 0, none = 0;
  for (final r in rows) {
    switch ('${r['range_state'] ?? ''}') {
      case 'out':
        out++;
      case 'in':
        inn++;
      default:
        none++;
    }
  }
  return {'total': rows.length, 'out': out, 'in': inn, 'none': none};
}

/// Map `sample_test_id` -> Set of `inventory_id` from the consumption log.
Map<String, Set<String>> thBuildChemTestMap(List<Map<String, dynamic>> log) {
  final map = <String, Set<String>>{};
  for (final e in log) {
    if (e['sample_test_id'] == null) continue;
    map.putIfAbsent('${e['sample_test_id']}', () => <String>{})
        .add('${e['inventory_id']}');
  }
  return map;
}

List<({String value, String label})> thBuildChemicalOptions(
    List<Map<String, dynamic>> log) {
  final seen = <String>{};
  final opts = <({String value, String label})>[];
  for (final e in log) {
    if (e['inventory_id'] == null) continue;
    final k = '${e['inventory_id']}';
    if (seen.add(k)) {
      opts.add((
        value: k,
        label: '${e['inventory_name'] ?? '#$k'}',
      ));
    }
  }
  opts.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return opts;
}

({String filterMode, String specificDate, String analysisId, String sourceType,
        String chemicalId, String rangeState, String query})
    thClearChip({
  required String filterMode,
  required String specificDate,
  required String analysisId,
  required String sourceType,
  required String chemicalId,
  required String rangeState,
  required String query,
  required String key,
}) {
  var m = filterMode, d = specificDate, a = analysisId;
  var s = sourceType, c = chemicalId, r = rangeState;
  switch (key) {
    case 'mode':
      m = 'all';
      d = '';
    case 'analysis':
      a = '';
    case 'source':
      s = '';
    case 'chemical':
      c = '';
    case 'range':
      r = '';
  }
  return (
    filterMode: m,
    specificDate: d,
    analysisId: a,
    sourceType: s,
    chemicalId: c,
    rangeState: r,
    query: query,
  );
}

List<({String key, String label})> thBuildChips({
  required String filterMode,
  required String specificDate,
  required String analysisId,
  required String sourceType,
  required String chemicalId,
  required String rangeState,
  required List<Map<String, dynamic>> analyses,
  required List<({String value, String label})> chemicalOptions,
}) {
  final chips = <({String key, String label})>[];
  switch (filterMode) {
    case 'last24h':
      chips.add((key: 'mode', label: 'آخر 24 ساعة'));
    case 'specific-date':
      chips.add((key: 'mode', label: 'بتاريخ: ${specificDate.isEmpty ? '—' : specificDate}'));
    default:
      chips.add((key: 'mode', label: 'كل السجلات'));
  }
  if (analysisId.isNotEmpty) {
    final a = analyses.cast<Map<String, dynamic>?>().firstWhere(
          (x) => '${x?['id'] ?? ''}' == analysisId,
          orElse: () => null,
        );
    chips.add((key: 'analysis', label: a == null ? 'تحليل #$analysisId' : '${a['name']}'));
  }
  if (sourceType.isNotEmpty) {
    chips.add((key: 'source', label: thSourceLabel(sourceType)));
  }
  if (chemicalId.isNotEmpty) {
    final opt = chemicalOptions.cast<({String value, String label})?>().firstWhere(
          (o) => o!.value == chemicalId,
          orElse: () => null,
        );
    chips.add((key: 'chemical', label: opt?.label ?? 'مادة #$chemicalId'));
  }
  if (rangeState.isNotEmpty) {
    chips.add((key: 'range', label: thRangeLabel(rangeState)));
  }
  return chips;
}