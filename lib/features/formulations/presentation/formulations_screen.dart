import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/animations/app_animations.dart';
import '../../../design_system/charts/app_chart_palette.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../di/service_locator.dart';
import '../../../app/auth_gate.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../design_system/widgets/app_page_header.dart';
import '../../../design_system/widgets/app_search_field.dart';
import '../../../design_system/widgets/app_skeleton.dart';
import '../../../design_system/widgets/app_summary_card.dart';
import '../../../design_system/widgets/app_text_field.dart';
import '../../../design_system/widgets/app_select_field.dart';
import '../../../design_system/widgets/app_window.dart';
import '../domain/formulation_calculator.dart';
import '../domain/formulation_repository.dart';

class FormulationsScreen extends StatefulWidget {
  const FormulationsScreen({
    super.key,
    this.initialId,
    this.initialProductId,
    this.initialFrom,
    this.initialTo,
  });

  final int? initialId;
  final int? initialProductId;
  final String? initialFrom;
  final String? initialTo;

  @override
  State<FormulationsScreen> createState() => _FormulationsScreenState();
}

class _FormulationsScreenState extends State<FormulationsScreen> {
  late final FormulationRepository _repo = getIt<FormulationRepository>();
  late Future<List<Map<String, dynamic>>> _rows = _repo.list();
  bool get _canWrite =>
      getIt<AuthGate>().canWrite(Permission.formulationsCreate);
  bool _archived = false;
  bool _openedInitial = false;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Map<String, dynamic> _decode(Object? raw, Map<String, dynamic> fallback) {
    if (raw is! String || raw.isEmpty) return fallback;
    try {
      final value = jsonDecode(raw);
      return value is Map ? Map<String, dynamic>.from(value) : fallback;
    } on FormatException {
      return fallback;
    }
  }

  List<Map<String, dynamic>> _decodeList(Object? raw) {
    if (raw is! String || raw.isEmpty) return [];
    try {
      final value = jsonDecode(raw);
      return value is List
          ? [
              for (final row in value.whereType<Map>())
                Map<String, dynamic>.from(row),
            ]
          : [];
    } on FormatException {
      return [];
    }
  }

  Future<void> _reload() async {
    setState(() => _rows = _repo.list(archived: _archived));
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final materials = await _repo.materials();
    final products = await _repo.products();
    final parameters = await _repo.parameters();
    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      useSafeArea: true,
      builder: (_) => _FormulationEditor(
        repo: _repo,
        materials: materials,
        products: products,
        parameters: parameters,
        initial: row,
        productId: widget.initialProductId,
        initialFrom: widget.initialFrom,
        initialTo: widget.initialTo,
        writable: _canWrite,
      ),
    );
    if (result != true || !mounted) return;
    try {
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppText.t('تم حفظ التركيبة', 'Formulation saved')),
          ),
        );
      }
    } on AppError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppText.t('تعذر حفظ التركيبة: $error', 'Could not save: $error'),
            ),
          ),
        );
      }
    }
  }

  Future<void> _archive(Map<String, dynamic> row) async {
    try {
      await _repo.archive((row['id'] as num).toInt());
      await _reload();
    } on AppError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_openedInitial && widget.initialId != null) {
      _openedInitial = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final groups = await Future.wait([
          _repo.list(),
          _repo.list(archived: true),
        ]);
        final rows = groups.expand((items) => items);
        final found = rows
            .where((row) => row['id'] == widget.initialId)
            .firstOrNull;
        if (mounted && found != null) await _edit(found);
      });
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppEntrance(
            child: AppPageHeader(
              title: AppText.t('التركيبات', 'Formulations'),
              actions: [
                if (_canWrite)
                  AppButton(
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add),
                    label: AppText.t('تركيبة جديدة', 'New formulation'),
                  ),
              ],
              bottom: AppFilterBar(
                searchHint: AppText.t('بحث بالاسم', 'Search by name...'),
                onSearch: (query) {
                  if (mounted) setState(() => _query = query.trim());
                },
                filters: [
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: false,
                        label: Text(AppText.t('النشطة', 'Active')),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text(AppText.t('المؤرشفة', 'Archived')),
                      ),
                    ],
                    selected: {_archived},
                    onSelectionChanged: (value) {
                      setState(() {
                        _archived = value.first;
                        _rows = _repo.list(archived: _archived);
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _rows,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const AppSkeletonList(rows: 5, lines: 2, height: 420);
                }
                if (snapshot.hasError) {
                  return AppErrorState(
                    title: AppText.t(
                      'تعذر تحميل التركيبات',
                      'Could not load formulations',
                    ),
                    subtitle: AppError.friendly(snapshot.error!),
                    onRetry: () => _reload(),
                  );
                }
                final all = snapshot.data ?? [];
                final query = _query.toLowerCase();
                final items = query.isEmpty
                    ? all
                    : [
                        for (final row in all)
                          if ('${row['name'] ?? ''}'
                              .toLowerCase()
                              .contains(query))
                          row,
                      ];
                if (items.isEmpty) {
                  if (query.isNotEmpty) {
                    return AppEmptyState(
                      icon: Icons.search_off,
                      title: AppText.t(
                        'لا توجد نتائج مطابقة',
                        'No matching formulations',
                      ),
                      subtitle: AppText.t(
                        'جرّب مسح البحث.',
                        'Try clearing the search.',
                      ),
                      action: AppButton(
                        style: AppButtonStyle.secondary,
                        label: AppText.t('مسح البحث', 'Clear search'),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                    );
                  }
                  return AppEmptyState(
                    icon: _archived
                        ? Icons.archive_outlined
                        : Icons.science_outlined,
                    title: _archived
                        ? AppText.t(
                            'لا توجد تركيبات مؤرشفة',
                            'No archived formulations',
                          )
                        : AppText.t(
                            'لا توجد تركيبات محفوظة بعد',
                            'No saved formulations yet',
                          ),
                    subtitle: _canWrite && !_archived
                        ? AppText.t(
                            'أنشئ أول تركيبة وحدد خاماتها وأوزانها.',
                            'Create your first formulation with its materials and weights.',
                          )
                        : null,
                    action: _canWrite && !_archived
                        ? AppButton(
                            onPressed: () => _edit(),
                            icon: const Icon(Icons.add),
                            label: AppText.t(
                              'تركيبة جديدة',
                              'New formulation',
                            ),
                          )
                        : null,
                  );
                }
                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _formulationCard(context, items[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _formulationCard(BuildContext context, Map<String, dynamic> row) {
    final data = _decode(row['calculation_json'], {});
    final kg = (data['total_kg'] as num?)?.toDouble();
    final cost = (data['cost_per_kg'] as num?)?.toDouble();
    final ingredients = _decodeList(row['items_json']);
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () => _edit(row),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 12,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${row['name'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.spMax,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textStrong,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _formulationPill('${ingredients.length} ${AppText.t('خامة', 'ingredients')}'),
                      if (kg != null)
                        _formulationPill('${kg.toStringAsFixed(1)} kg'),
                      if (cost != null)
                        _formulationPill(
                          '${cost.toStringAsFixed(3)} / kg',
                          color: AppColors.success,
                        ),
                      if (row['updated_at'] != null)
                        Text(
                          '${row['updated_at']}',
                          style: TextStyle(
                            fontSize: 11.spMax,
                            color: AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              onSelected: (value) async {
                if (value == 'copy') {
                  final copy = Map<String, dynamic>.from(row)
                    ..remove('id')
                    ..remove('remote_id')
                    ..['name'] = 'نسخة من ${row['name']}'
                    ..['copied_from_id'] = row['id'];
                  final itemList = _decodeList(row['items_json']);
                  await _edit({
                    ...copy,
                    'items_json': jsonEncode(itemList),
                    'graph_parameters_json': row['graph_parameters_json'],
                    'parameters_json': row['parameters_json'],
                    'calculation_json': '{}',
                    'source_snapshot_json': '[]',
                  });
                } else if (value == 'archive') {
                  await _archive(row);
                }
              },
              itemBuilder: (_) => [
                if (_canWrite)
                  PopupMenuItem(
                    value: 'copy',
                    child: Text(AppText.t('تكرار', 'Duplicate')),
                  ),
                if (_canWrite && !_archived)
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(AppText.t('أرشفة', 'Archive')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Ingredient picker: debounced search beside two quick filters — materials
/// that have a محضر (receipt/inspection) versus all materials.
class _MaterialPicker extends StatefulWidget {
  const _MaterialPicker({required this.materials, required this.withReceipts});
  final List<Map<String, dynamic>> materials;
  final Set<int> withReceipts;

  @override
  State<_MaterialPicker> createState() => _MaterialPickerState();
}

class _MaterialPickerState extends State<_MaterialPicker> {
  late bool _receiptOnly = true;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered => [
    for (final material in widget.materials)
      if (widget.withReceipts.contains((material['id'] as num).toInt()) ||
          !_receiptOnly)
        if ('${material['material_name'] ?? ''}'
            .toLowerCase()
            .contains(_query.toLowerCase()))
        material,
  ];

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    return SizedBox(
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DebouncedSearchField(
                  controller: _search,
                  hint: AppText.t('بحث باسم الخامة', 'Search material...'),
                  onChanged: (value) => setState(() => _query = value.trim()),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                small: true,
                style: _receiptOnly
                    ? AppButtonStyle.primary
                    : AppButtonStyle.secondary,
                label: AppText.t('لها محضر', 'With receipt'),
                onPressed: () => setState(() => _receiptOnly = true),
              ),
              const SizedBox(width: 6),
              AppButton(
                small: true,
                style: !_receiptOnly
                    ? AppButtonStyle.primary
                    : AppButtonStyle.secondary,
                label: AppText.t('الكل', 'All'),
                onPressed: () => setState(() => _receiptOnly = false),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      AppText.t(
                        'لا توجد خامات مطابقة',
                        'No matching materials',
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (dialogContext, index) => ListTile(
                      onTap: () =>
                          Navigator.pop(dialogContext, rows[index]),
                      title: Text('${rows[index]['material_name']}'),
                      trailing: widget.withReceipts.contains(
                        (rows[index]['id'] as num).toInt(),
                      )
                          ? Tooltip(
                              message: AppText.t('لها محضر', 'Has receipt'),
                              child: Icon(
                                Icons.receipt_long_outlined,
                                size: 18,
                                color: AppColors.success,
                              ),
                            )
                          : null,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Small tinted pill shared by the list cards and the editor tiles.
Widget _formulationPill(String text, {Color? color, IconData? icon}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (color ?? AppColors.primary).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (color ?? AppColors.primary).withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color ?? AppColors.primary),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11.spMax,
              fontWeight: FontWeight.w600,
              color: color ?? AppColors.primary,
            ),
          ),
        ],
      ),
    );

/// Per-point labels carry the values, so the grouped touch tooltip is muted.
enum _PeriodMode { day, month, year, range }

class _FormulationEditor extends StatefulWidget {
  const _FormulationEditor({
    required this.repo,
    required this.materials,
    required this.products,
    required this.parameters,
    required this.initial,
    required this.productId,
    required this.initialFrom,
    required this.initialTo,
    required this.writable,
  });
  final FormulationRepository repo;
  final List<Map<String, dynamic>> materials;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> parameters;
  final Map<String, dynamic>? initial;
  final int? productId;
  final String? initialFrom;
  final String? initialTo;
  final bool writable;

  @override
  State<_FormulationEditor> createState() => _FormulationEditorState();
}

class _FormulationEditorState extends State<_FormulationEditor> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.initial?['name'] ?? ''}',
  );
  late final List<Map<String, dynamic>> _items = _readItems();
  late int? _productId =
      (widget.initial?['product_id'] as num?)?.toInt() ?? widget.productId;
  late final Set<String> _graphParameters = _readGraphParameters();
  Map<String, dynamic> _savedSettings() {
    final raw = widget.initial?['parameters_json'];
    if (raw is! String) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  late final Map<String, dynamic> _settings = _savedSettings();
  late _PeriodMode _mode = _PeriodMode.values.firstWhere(
    (value) => value.name == _settings['period'],
    orElse: () => _PeriodMode.month,
  );
  late FormulationAggregation _aggregation =
      FormulationAggregation.values.firstWhere(
        (value) => value.name == _settings['aggregation'],
        orElse: () => FormulationAggregation.average,
      );
  late DateTime _selected =
      DateTime.tryParse(widget.initialFrom ?? '${_settings['from'] ?? ''}') ??
      DateTime.now();
  late DateTime _from =
      DateTime.tryParse(widget.initialFrom ?? '${_settings['from'] ?? ''}') ??
      DateTime(_selected.year, _selected.month, 1);
  late DateTime _to =
      DateTime.tryParse(widget.initialTo ?? '${_settings['to'] ?? ''}') ??
      _selected;
  bool _busy = false;
  bool _sourcesReady = false;
  String? _error;
  FormulationResult? _calculation;
  List<Map<String, dynamic>> _sourceHints = [];
  List<MaterialReceipt> _receipts = [];
  Future<List<MaterialReceipt>>? _receiptRequest;
  Map<String, List<FlSpot>> _spotsByParameter = {};
  List<String> _axisLabels = [];
  int _refreshGeneration = 0;

  /// Chart hover state: series bar index -> spot index. Stored as plain
  /// indices and re-validated against the live series on every build — a
  /// data refresh (aggregation switch, series toggled off) used to leave
  /// stale spot references that crashed fl_chart's paint pass.
  final Map<int, int> _chartHover = {};

  List<Map<String, dynamic>> _readItems() {
    final raw = widget.initial?['items_json'];
    if (raw is! String) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List
          ? [
              for (final e in decoded.whereType<Map>())
                Map<String, dynamic>.from(e),
            ]
          : [];
    } on FormatException {
      return [];
    }
  }

  Set<String> _readGraphParameters() {
    final raw = widget.initial?['graph_parameters_json'];
    if (raw is! String) return {'protein', 'fat'};
    try {
      final value = jsonDecode(raw);
      return value is List
          ? value.map((e) => '$e').toSet()
          : {'protein', 'fat'};
    } on FormatException {
      return {'protein', 'fat'};
    }
  }

  DateTime get _periodStart => switch (_mode) {
    _PeriodMode.day => DateTime(_selected.year, _selected.month, _selected.day),
    _PeriodMode.month => DateTime(_selected.year, _selected.month, 1),
    _PeriodMode.year => DateTime(_selected.year, 1, 1),
    _PeriodMode.range => DateTime(_from.year, _from.month, _from.day),
  };
  DateTime get _periodEnd => switch (_mode) {
    _PeriodMode.day => DateTime(_selected.year, _selected.month, _selected.day),
    _PeriodMode.month => DateTime(_selected.year, _selected.month + 1, 0),
    _PeriodMode.year => DateTime(_selected.year, 12, 31),
    _PeriodMode.range => DateTime(_to.year, _to.month, _to.day),
  };

  List<FormulationIngredient> get _ingredients => [
    for (final row in _items)
      FormulationIngredient(
        materialId: (row['material_id'] as num).toInt(),
        name: '${row['material_name'] ?? ''}',
        quantityKg: FormulationCalculator.number(row['quantity_kg']) ?? 0,
        pricePerKg: FormulationCalculator.number(row['price_per_kg']),
      ),
  ];

  Future<void> _refresh({bool loadSources = true}) async {
    final generation = ++_refreshGeneration;
    final ids = _items
        .map((row) => (row['material_id'] as num).toInt())
        .toSet()
        .toList();
    if (ids.isEmpty) {
      _receiptRequest = null;
      setState(() {
        _busy = false;
        _sourcesReady = true;
        _calculation = FormulationCalculator.calculate(
          ingredients: [],
          averages: {},
        );
        _spotsByParameter = {};
        _sourceHints = [];
      });
      return;
    }
    setState(() {
      _busy = true;
      _sourcesReady = false;
    });
    try {
      if (loadSources || _receiptRequest == null) {
        _receiptRequest = widget.repo.receipts(
          ids,
          DateTime(1900, 1, 1),
          _periodEnd,
        );
      }
      final receipts = await _receiptRequest!;
      if (!mounted || generation != _refreshGeneration) return;
      final averages = FormulationCalculator.averages(
        materialIds: ids,
        receipts: receipts,
        from: _periodStart,
        to: _periodEnd,
        aggregation: _aggregation,
      );
      final current = FormulationCalculator.calculate(
        ingredients: _ingredients,
        averages: averages,
      );
      final chart = _chartBuckets();
      final excludedPhysical = {
        for (final receipt in receipts) ...receipt.physicalKeys,
      };
      final spots = <String, List<FlSpot>>{};
      final labels = <String>[];
      for (var i = 0; i < chart.length; i++) {
        final bucket = chart[i];
        final bucketAverages = FormulationCalculator.averages(
          materialIds: ids,
          receipts: receipts,
          from: bucket.$1,
          to: bucket.$2,
          aggregation: _aggregation,
        );
        final result = FormulationCalculator.calculate(
          ingredients: _ingredients,
          averages: bucketAverages,
        );
        for (final parameter in _graphParameters) {
          if (excludedPhysical.contains(parameter)) continue;
          final value = result.parameters[parameter];
          spots
              .putIfAbsent(parameter, () => [])
              .add(
                value == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), value),
              );
        }
        labels.add(bucket.$3);
      }
      final hints = [
        for (final row in current.ingredients)
          {
            'material_id': row.ingredient.materialId,
            'name': row.ingredient.name,
            'parameters': {
              for (final entry in row.parameters.entries)
                entry.key: {
                  'source': entry.value.source,
                  'receipts': entry.value.receipts,
                  'code': entry.value.receiptCode,
                  'date': entry.value.receiptDate.toIso8601String(),
                  'fallback': entry.value.usedFallback,
                  'value': entry.value.value,
                },
            },
          },
      ];
      if (mounted) {
        setState(() {
          _receipts = receipts;
          _calculation = current;
          _sourcesReady = true;
          _sourceHints = hints;
          _spotsByParameter = spots;
          _axisLabels = labels;
          _busy = false;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _refreshGeneration) {
        _receiptRequest = null;
        setState(() {
          _busy = false;
          _error = AppError.friendly(error);
        });
      }
    }
  }

  List<(DateTime, DateTime, String)> _chartBuckets() {
    final start = _periodStart;
    final end = _periodEnd;
    if (_mode == _PeriodMode.day) return [(start, end, '${start.day}')];
    final daily =
        _mode == _PeriodMode.month ||
        (_mode == _PeriodMode.range && end.difference(start).inDays < 31);
    final buckets = <(DateTime, DateTime, String)>[];
    if (daily) {
      for (
        var day = start;
        !day.isAfter(end);
        day = day.add(const Duration(days: 1))
      ) {
        buckets.add((day, day, '${day.day}'));
      }
    } else {
      var month = DateTime(start.year, start.month);
      while (!month.isAfter(end)) {
        final last = DateTime(month.year, month.month + 1, 0);
        final from = month.isBefore(start) ? start : month;
        final to = last.isAfter(end) ? end : last;
        buckets.add((from, to, '${month.month}'));
        month = DateTime(month.year, month.month + 1);
      }
    }
    return buckets;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _name.dispose();
    for (final row in _items) {
      (row['_quantity'] as TextEditingController?)?.dispose();
      (row['_price'] as TextEditingController?)?.dispose();
    }
    super.dispose();
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _selected = picked);
    await _refresh();
  }

  Future<void> _selectRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(
        start: _from,
        end: _to.isBefore(_from) ? _from : _to,
      ),
    );
    if (picked == null) return;
    setState(() {
      _from = picked.start;
      _to = picked.end;
    });
    await _refresh();
  }

  String _periodLabel() => switch (_mode) {
    _PeriodMode.day => _selected.toIso8601String().substring(0, 10),
    _PeriodMode.month =>
      '${_selected.year}-${_selected.month.toString().padLeft(2, '0')}',
    _PeriodMode.year => '${_selected.year}',
    _PeriodMode.range =>
      '${_from.toIso8601String().substring(0, 10)} – ${_to.toIso8601String().substring(0, 10)}',
  };

  /// Physical-only receipt keys (density, separation, visual checks…).
  /// Nutrition formulations analyse chemistry: these must never become chart
  /// series, KPI tiles or source pills.
  Set<String> get _physicalKeys => {
    for (final receipt in _receipts) ...receipt.physicalKeys,
  };

  /// Manual chart hover bookkeeping (built-in touches are off). On exit or
  /// any non-interested event the hover is dropped.
  void _handleChartTouch(FlTouchEvent event, LineTouchResponse? response) {
    final spots = response?.lineBarSpots;
    if (!event.isInterestedForInteractions ||
        spots == null ||
        spots.isEmpty) {
      if (_chartHover.isNotEmpty) {
        setState(_chartHover.clear);
      }
      return;
    }
    final next = {for (final spot in spots) spot.barIndex: spot.spotIndex};
    final changed =
        _chartHover.length != next.length ||
        next.keys.any((bar) => _chartHover[bar] != next[bar]);
    if (!changed) return;
    setState(() {
      _chartHover
        ..clear()
        ..addAll(next);
    });
  }

  Widget _graph() {
    final values = _calculation?.parameters ?? const <String, double?>{};
    final excluded = _physicalKeys;
    final eligible = <String, String>{
      ...FormulationCalculator.names,
      for (final row in widget.parameters)
        formulationParameterKey('${row['parameter_name']}'):
            '${row['parameter_name']}',
    };
    final available = eligible.keys
        .where(
          (key) =>
              !excluded.contains(key) &&
              (values.containsKey(key) ||
                  _receipts.any((receipt) => receipt.values.containsKey(key))),
        )
        .toList();
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    AppText.t('تغيّر التحليل عبر الفترة', 'Analysis trend'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textStrong,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: AppText.t('اختيار التحاليل', 'Choose parameters'),
                  icon: const Icon(Icons.tune, size: 19),
                  onSelected: (key) {
                    setState(() {
                      if (_graphParameters.contains(key)) {
                        _graphParameters.remove(key);
                      } else {
                        _graphParameters.add(key);
                      }
                    });
                    unawaited(_refresh(loadSources: false));
                  },
                  itemBuilder: (context) => [
                    for (final key in available)
                      CheckedPopupMenuItem(
                        value: key,
                        checked: _graphParameters.contains(key),
                        child: Text(eligible[key] ?? key),
                      ),
                  ],
                ),
              ],
            ),
            Text(
              _periodLabel(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            // Aggregation mode: متوسط (mean) / أدنى (worst case) / أعلى
            // (best case) — applies to the trend chart and the KPI cards.
            SegmentedButton<FormulationAggregation>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: [
                ButtonSegment(
                  value: FormulationAggregation.average,
                  label: Text(
                    AppText.t('متوسط', 'Average'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                ButtonSegment(
                  value: FormulationAggregation.minimum,
                  label: Text(
                    AppText.t('أدنى', 'Minimum'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                ButtonSegment(
                  value: FormulationAggregation.maximum,
                  label: Text(
                    AppText.t('أعلى', 'Maximum'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
              selected: {_aggregation},
              onSelectionChanged: (value) {
                setState(() => _aggregation = value.first);
                unawaited(_refresh(loadSources: false));
              },
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: _spotsByParameter.isEmpty || _graphParameters.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.show_chart,
                            size: 32,
                            color: AppColors.textMuted.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            AppText.t(
                              'لا توجد نقاط مكتملة للعرض',
                              'No complete data points',
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    )
                  : () {
                      final rtl = Directionality.of(context) == TextDirection.rtl;
                      // fl_chart crashes on a series whose spots are all
                      // null (mostRightSpot never initialized), and such a
                      // series has nothing to show anyway — skip it.
                      final seriesEntries = <(String, Color)>[];
                      final lineBars = <LineChartBarData>[];
                      for (final entry in _seriesOrder()) {
                        final spots = _spotsByParameter[entry.$1]!;
                        if (!spots.any((spot) => !spot.isNull())) continue;
                        final barIndex = lineBars.length;
                        final hovered = _chartHover[barIndex];
                        seriesEntries.add(entry);
                        lineBars.add(
                          LineChartBarData(
                            spots: spots,
                            isCurved: true,
                            preventCurveOverShooting: true,
                            barWidth: 2.5,
                            dotData: FlDotData(show: spots.length < 20),
                            color: entry.$2,
                            // Hover highlight rebuilt from live data only.
                            showingIndicators: [
                              if (hovered != null &&
                                  hovered >= 0 &&
                                  hovered < spots.length &&
                                  !spots[hovered].isNull())
                                hovered,
                            ],
                          ),
                        );
                      }
                      // Tooltip spots are constructed from the live series,
                      // never from fl_chart's retained touch state.
                      final hoverSpots = <LineBarSpot>[];
                      for (final hovered in _chartHover.entries) {
                        if (hovered.key >= lineBars.length) continue;
                        final spots = lineBars[hovered.key].spots;
                        final index = hovered.value;
                        if (index < 0 || index >= spots.length) continue;
                        if (spots[index].isNull()) continue;
                        hoverSpots.add(
                          LineBarSpot(lineBars[hovered.key], hovered.key, spots[index]),
                        );
                      }
                      hoverSpots.sort((a, b) => b.y.compareTo(a.y));
                      return LineChart(
                        LineChartData(
                          minX: 0,
                          maxX:
                              (_axisLabels.length > 1
                                      ? _axisLabels.length - 1
                                      : 1)
                                  .toDouble(),
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: AppColors.borderMuted,
                              strokeWidth: 1,
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                          showingTooltipIndicators: [
                            if (hoverSpots.isNotEmpty)
                              ShowingTooltipIndicators(hoverSpots),
                          ],
                          lineTouchData: LineTouchData(
                            // Hover is tracked here so every tooltip and
                            // indicator is rebuilt from the current data;
                            // fl_chart's retained touch state used to carry
                            // stale indices after a refresh and crash paint.
                            handleBuiltInTouches: false,
                            touchCallback: _handleChartTouch,
                            touchTooltipData: LineTouchTooltipData(
                              tooltipRoundedRadius: 8,
                              tooltipPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              maxContentWidth: 220,
                              fitInsideHorizontally: true,
                              fitInsideVertically: true,
                              getTooltipItems: (touchedSpots) => [
                                for (final spot in touchedSpots)
                                  if (spot.barIndex < seriesEntries.length)
                                    LineTooltipItem(
                                      '${_parameterName(seriesEntries[spot.barIndex].$1)}: ${_formatPointValue(spot.y)}',
                                      TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: seriesEntries[spot.barIndex].$2,
                                      ),
                                      textDirection: rtl
                                          ? TextDirection.rtl
                                          : TextDirection.ltr,
                                    )
                                  else
                                    null,
                              ],
                            ),
                            getTouchedSpotIndicator: (barData, indicators) => [
                              // Defensive: never index beyond the live spots
                              // (the built-in default does and crashes paint).
                              for (final index in indicators)
                                index >= 0 &&
                                        index < barData.spots.length &&
                                        !barData.spots[index].isNull()
                                    ? TouchedSpotIndicatorData(
                                        FlLine(
                                          color:
                                              barData.gradient?.colors.first ??
                                              barData.color ??
                                              AppColors.info,
                                          strokeWidth: 4,
                                        ),
                                        FlDotData(
                                          getDotPainter:
                                              (spot, percent, bar, index) =>
                                                  FlDotCirclePainter(
                                                    radius: 6,
                                                    color:
                                                        bar.gradient?.colors
                                                            .first ??
                                                        bar.color ??
                                                        AppColors.info,
                                                  ),
                                        ),
                                      )
                                    : null,
                            ],
                          ),
                          titlesData: FlTitlesData(
                            topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            leftTitles: const AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 42,
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: (_axisLabels.length / 6)
                                    .ceilToDouble()
                                    .clamp(1, 999),
                                getTitlesWidget: (value, meta) {
                                  final index = value.toInt();
                                  if (index < 0 ||
                                      index >= _axisLabels.length) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      _axisLabels[index],
                                      style: appChartAxisStyle(),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          lineBarsData: lineBars,
                        ),
                      );
                    }(),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in _seriesOrder())
                  if (eligible.containsKey(entry.$1))
                    _legendPill(entry.$2, eligible[entry.$1]!),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addIngredient() async {
    final already = _items
        .map((e) => (e['material_id'] as num).toInt())
        .toSet();
    final choice = widget.materials
        .where((m) => !already.contains(m['id']))
        .toList();
    if (choice.isEmpty) return;
    // Which materials have at least one محضر (inspection receipt) in the
    // period? Needed for the "خامات لها محضر" quick filter in the picker.
    final allIds = [
      for (final material in widget.materials) (material['id'] as num).toInt(),
    ];
    final withReceipts = {
      for (final receipt in await widget.repo.receipts(
        allIds,
        DateTime(1900, 1, 1),
        _periodEnd,
      ))
        receipt.materialId,
    };
    if (!mounted) return;
    final selected = await showAppWindow<Map<String, dynamic>>(
      context,
      title: AppText.t('اختيار خامة', 'Choose raw material'),
      child: _MaterialPicker(
        materials: choice,
        withReceipts: withReceipts,
      ),
    );
    if (selected == null) return;
    setState(
      () => _items.add({
        'material_id': selected['id'],
        'material_name': selected['material_name'],
        'quantity_kg': 0,
        'price_per_kg': null,
      }),
    );
    await _refresh();
  }

  Future<void> _save(Map<String, dynamic> record) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repo.save(
        record,
        id: (widget.initial?['id'] as num?)?.toInt(),
      );
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = AppError.friendly(error);
        });
      }
    }
  }

  Map<String, dynamic> _snapshot() => {
    'period_from': _periodStart.toIso8601String(),
    'period_to': _periodEnd.toIso8601String(),
    'total_kg': _calculation?.totalKg ?? 0,
    'total_cost': _calculation?.totalCost,
    'cost_per_kg': _calculation?.costPerKg,
    'parameters': _calculation?.parameters ?? {},
  };

  @override
  Widget build(BuildContext context) {
    final result = _calculation;
    return AppWindow(
      title: widget.initial == null
          ? AppText.t('تركيبة جديدة', 'New formulation')
          : AppText.t('تعديل التركيبة', 'Edit formulation'),
      size: AppWindowSize.lg,
      height: 680,
      scrollBody: false,
      actions: [
        if (_busy)
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(),
            ),
          ),
        if (widget.writable)
          AppButton(
            style: AppButtonStyle.ghost,
            onPressed: _busy || !_sourcesReady
                ? null
                : () => _save({
                    'name': _name.text,
                    'product_id': _productId,
                    'items': [
                      for (final item in _items)
                        {
                          'material_id': item['material_id'],
                          'material_name': item['material_name'],
                          'quantity_kg':
                              FormulationCalculator.number(
                                item['quantity_kg'],
                              ) ??
                              0,
                          'price_per_kg': FormulationCalculator.number(
                            item['price_per_kg'],
                          ),
                        },
                    ],
                    'parameters': {
                      'period': _mode.name,
                      'aggregation': _aggregation.name,
                      'from': _periodStart.toIso8601String(),
                      'to': _periodEnd.toIso8601String(),
                    },
                    'graph_parameters': _graphParameters.toList(),
                    'calculation': _snapshot(),
                    'sources': _sourceHints,
                    'copied_from_id': widget.initial?['copied_from_id'],
                  }),
            icon: const Icon(Icons.save_outlined),
            label: AppText.t('حفظ', 'Save'),
          ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        children: [
          AppTextField(
            controller: _name,
            readOnly: !widget.writable,
            decoration: InputDecoration(
              labelText: AppText.t('اسم التركيبة', 'Formulation name'),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 190,
                child: AppSelectField<_PeriodMode>(
                  initialValue: _mode,
                  decoration: InputDecoration(
                    labelText: AppText.t('الفترة', 'Period'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: _PeriodMode.day,
                      child: Text(AppText.t('يومي', 'Day')),
                    ),
                    DropdownMenuItem(
                      value: _PeriodMode.month,
                      child: Text(AppText.t('شهري', 'Month')),
                    ),
                    DropdownMenuItem(
                      value: _PeriodMode.year,
                      child: Text(AppText.t('سنوي', 'Year')),
                    ),
                    DropdownMenuItem(
                      value: _PeriodMode.range,
                      child: Text(AppText.t('من–إلى', 'Custom range')),
                    ),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => _mode = value);
                    if (value == _PeriodMode.range) {
                      await _selectRange();
                    } else {
                      await _selectDate();
                    }
                  },
                ),
              ),
              AppButton(
                style: AppButtonStyle.secondary,
                onPressed: _mode == _PeriodMode.range
                    ? _selectRange
                    : _selectDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: _periodLabel(),
              ),
              SizedBox(
                width: 240,
                child: AppSelectField<int?>(
                  initialValue: _productId,
                  decoration: InputDecoration(
                    labelText: AppText.t(
                      'المنتج (اختياري)',
                      'Product (optional)',
                    ),
                  ),
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(AppText.t('بدون ربط', 'Not linked')),
                    ),
                    for (final row in widget.products)
                      DropdownMenuItem<int?>(
                        value: (row['id'] as num).toInt(),
                        child: Text('${row['name']}'),
                      ),
                  ],
                  onChanged: (value) => setState(() => _productId = value),
                ),
              ),
              if (_productId != null)
                AppButton(
                  style: AppButtonStyle.ghost,
                  onPressed: () => context.go(
                    '/inspections?products=1&product=$_productId&from=${_periodStart.toIso8601String().substring(0, 10)}&to=${_periodEnd.toIso8601String().substring(0, 10)}',
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: AppText.t('فحوصات المنتج', 'Product inspections'),
                ),
            ],
          ),
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          _graph(),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                _kpi(
                  context,
                  icon: Icons.scale_outlined,
                  color: AppColors.primary,
                  label: AppText.t('الوزن', 'Weight'),
                  value: '${result?.totalKg.toStringAsFixed(1) ?? '0'} kg',
                ),
                for (final entry
                    in result?.parameters.entries ??
                        const <MapEntry<String, double?>>[])
                  // Only the parameters enabled on the trend chart appear as
                  // cards, plus cost per kilo — the row stays focused on what
                  // the user is actually tracking.
                  if (_graphParameters.contains(entry.key) &&
                      !_physicalKeys.contains(entry.key))
                    _kpi(
                      context,
                      icon: Icons.insights,
                      color: _parameterColor(entry.key),
                      label: _parameterName(entry.key),
                      value: entry.value?.toStringAsFixed(2) ?? '—',
                    ),
                _kpi(
                  context,
                  icon: Icons.payments_outlined,
                  color: AppColors.success,
                  label: AppText.t('التكلفة', 'Total cost'),
                  value: result?.totalCost?.toStringAsFixed(2) ?? '—',
                ),
                _kpi(
                  context,
                  icon: Icons.sell_outlined,
                  color: AppColors.warning,
                  label: AppText.t('سعر الكيلو', 'Cost per kg'),
                  value: result?.costPerKg?.toStringAsFixed(3) ?? '—',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  AppText.t('الخامات', 'Ingredients'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (widget.writable)
                IconButton(
                  onPressed: _addIngredient,
                  icon: const Icon(Icons.add_circle_outline),
                ),
            ],
          ),
          for (var index = 0; index < _items.length; index++)
            _ingredientTile(index),
        ],
      ),
    );
  }

  Widget _ingredientTile(int index) {
    final item = _items[index];
    final hint = _sourceHints
        .where((row) => row['material_id'] == item['material_id'])
        .firstOrNull;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${item['material_name']}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Tooltip(
                  waitDuration: const Duration(milliseconds: 350),
                  message: _sourceTooltip(hint),
                  child: IconButton(
                    tooltip: AppText.t('مصادر التحليل', 'Analysis sources'),
                    onPressed: () => context.go(
                      '/inspections?material=${item['material_id']}'
                      '&from=${_periodStart.toIso8601String().substring(0, 10)}'
                      '&to=${_periodEnd.toIso8601String().substring(0, 10)}',
                    ),
                    icon: const Icon(Icons.help_outline, size: 18),
                  ),
                ),
                if (widget.writable)
                  IconButton(
                    tooltip: AppText.t('إزالة', 'Remove'),
                    onPressed: () async {
                      setState(() => _items.removeAt(index));
                      await _refresh();
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _sourcePills(hint),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: AppField(
                    key: ValueKey('q-$index-${item['material_id']}'),
                    initialValue: '${item['quantity_kg'] ?? 0}',
                    enabled: widget.writable,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    label: AppText.t('الكمية (كجم)', 'Quantity (kg)'),
                    onChanged: (value) {
                      item['quantity_kg'] =
                          FormulationCalculator.number(value) ?? 0;
                      _refresh(loadSources: false);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppField(
                    key: ValueKey('p-$index-${item['material_id']}'),
                    initialValue: '${item['price_per_kg'] ?? ''}',
                    enabled: widget.writable,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    label: AppText.t('سعر الكيلو', 'Price per kg'),
                    onChanged: (value) {
                      item['price_per_kg'] = FormulationCalculator.number(
                        value,
                      );
                      _refresh(loadSources: false);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Per-ingredient analysis pills: one per sourced parameter (value +
  /// fallback tone), or a muted "no analysis" pill when the period has none.
  Widget _sourcePills(Map<String, dynamic>? hint) {
    final excluded = _physicalKeys;
    final parameters = hint?['parameters'] as Map<String, dynamic>? ?? {};
    final pills = <Widget>[
      for (final entry in parameters.entries)
        if (entry.value is Map && !excluded.contains(entry.key))
          () {
            final value = Map<String, dynamic>.from(entry.value as Map);
            final fallback = value['fallback'] == true;
            final source = '${value['source']}';
            // Lab-sourced values carry a flask badge so the user can see at a
            // glance which numbers came from the lab and which from the
            // inspection sheet.
            final labSourced = source == 'lab' || source == 'mixed';
            final raw = value['value'];
            final number = raw is num ? raw.toStringAsFixed(2) : '$raw';
            return _formulationPill(
              '${_parameterName(entry.key)}: $number${fallback ? ' · ${AppText.t('سابق', 'fallback')}' : ''}',
              color: fallback
                  ? AppColors.warning
                  : labSourced
                  ? AppColors.accent
                  : AppColors.info,
              icon: labSourced ? Icons.science_outlined : null,
            );
          }(),
    ];
    if (pills.isEmpty) {
      return _formulationPill(
        AppText.t('لا يوجد تحليل صالح في هذه الفترة', 'No valid analysis in this period'),
        color: AppColors.textMuted,
      );
    }
    return Wrap(spacing: 6, runSpacing: 4, children: pills);
  }

  String _sourceTooltip(Map<String, dynamic>? hint) {
    if (hint == null) {
      return AppText.t(
        'لا يوجد تحليل صالح في هذه الفترة',
        'No valid analysis in this period',
      );
    }
    final parameters = hint['parameters'] as Map<String, dynamic>? ?? {};
    if (parameters.isEmpty) {
      return AppText.t(
        'لا يوجد تحليل صالح في هذه الفترة',
        'No valid analysis in this period',
      );
    }
    final excluded = _physicalKeys;
    return [
      for (final entry in parameters.entries)
        if (entry.value is Map && !excluded.contains(entry.key))
          () {
            final value = Map<String, dynamic>.from(entry.value as Map);
            final date = DateTime.tryParse('${value['date'] ?? ''}');
            final source = switch ('${value['source']}') {
              'lab' => 'المعمل',
              'mixed' => 'مصادر متعددة',
              _ => 'الفحص',
            };
            final detail = value['fallback'] == true
                ? 'آخر تحليل سابق'
                : 'متوسط ${value['receipts']} محاضر · آخر محضر ${value['code']}';
            return '${_parameterName(entry.key)}: ${value['value']}'
                ' ($source · $detail'
                '${date == null ? '' : ' · ${date.toIso8601String().substring(0, 10)}'})';
          }(),
    ].join('\n');
  }

  /// Displayed series in stable palette order: (parameter key, series color).
  /// Colors come from the design-system chart palette so light/dark and the
  /// rest of the app's charts stay consistent.
  List<(String, Color)> _seriesOrder() {
    final keys = [
      for (final key in _spotsByParameter.keys)
        if (_graphParameters.contains(key)) key,
    ];
    return [
      for (var i = 0; i < keys.length; i++)
        (keys[i], AppChartPalette.forIndex(i)),
    ];
  }

  String _formatPointValue(double value) =>
      value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);

  Color _parameterColor(String key) {
    for (final entry in _seriesOrder()) {
      if (entry.$1 == key) return entry.$2;
    }
    return AppColors.primary;
  }

  Widget _legendPill(Color color, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.spMax,
            fontWeight: FontWeight.w600,
            color: AppColors.textStrong,
          ),
        ),
      ],
    ),
  );

  String _parameterName(String key) {
    if (FormulationCalculator.names.containsKey(key)) {
      return switch (key) {
        'protein' => AppText.t('بروتين', 'Protein'),
        'fat' => AppText.t('دهون', 'Fat'),
        'moisture' => AppText.t('رطوبة', 'Moisture'),
        _ => FormulationCalculator.names[key]!,
      };
    }
    return widget.parameters
            .where(
              (row) =>
                  formulationParameterKey('${row['parameter_name']}') == key,
            )
            .map((row) => '${row['parameter_name']}')
            .firstOrNull ??
        key;
  }

  Widget _kpi(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) => SizedBox(
    width: 210,
    child: AppSummaryCard(label: label, value: value, icon: icon, color: color),
  );
}
