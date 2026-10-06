import 'package:flutter/material.dart';
import '../../../design_system/widgets/app_skeleton.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_error_feedback.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_entity_autocomplete.dart';
import '../../../di/service_locator.dart';
import '../core/formula_engine.dart';
import 'cubit/run_test_cubit.dart';
import 'cubit/run_test_state.dart';

/// Run a sample test against an analysis (raw material or product).
class RunTestTab extends StatefulWidget {
  final VoidCallback onTestRun;
  const RunTestTab({super.key, required this.onTestRun});

  @override
  State<RunTestTab> createState() => _RunTestTabState();
}

class _RunTestTabState extends State<RunTestTab> {
  final _sampleName = TextEditingController(text: 'Sample 1');
  final _resultText = TextEditingController();
  bool _formulaAuto = true;

  Map<String, dynamic>? get _currentUserMap {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return null;
    return {
      'id': user.id,
      'username': user.username,
      'full_name': user.fullName,
    };
  }

  @override
  void dispose() {
    _sampleName.dispose();
    _resultText.dispose();
    for (final c in _dynamicControllers.values) {
      c.dispose();
    }
    _dynamicControllers.clear();
    super.dispose();
  }

  Future<void> _run() async {
    final state = context.read<RunTestCubit>().state;
    if (state.analysisId == null) {
      AppFeedback.error(
        context,
        AppText.t('اختر التحليل', 'Select an analysis.'),
      );
      return;
    }
    if (state.sourceType == 'product' && _sampleName.text.trim().isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('اسم العينة مطلوب', 'Sample name is required.'),
      );
      return;
    }
    if (state.sourceType == 'raw_material' &&
        (state.rawMaterialId == null ||
            state.selectedInspection['id'] == null ||
            state.selectedSampleName.isEmpty)) {
      AppFeedback.error(
        context,
        AppText.t(
          'اختر الخام ومحضر الفحص والعينة أولاً',
          'Select a raw material, inspection record and sample first.',
        ),
      );
      return;
    }
    final comp = _computedResult(state);
    final formulaEnabled = comp['enabled'] == true;
    final autoOk = formulaEnabled && _formulaAuto && comp['ok'] == true;
    String resultText;
    final dynamicValues = _effectiveValues(state);
    if (autoOk) {
      resultText = _computedDisplay(comp['value']);
    } else {
      resultText = _resultText.text.trim();
      if (resultText.isEmpty) {
        AppFeedback.error(
          context,
          AppText.t(
            'أدخل النتيجة يدوياً — لا يمكن حسابها من المعادلة.',
            'Enter the result manually — the formula cannot be computed.',
          ),
        );
        return;
      }
    }
    try {
      final result = await context.read<RunTestCubit>().run(
        sampleName: _sampleName.text.trim(),
        resultText: resultText,
        dynamicValues: dynamicValues,
        manualResult: formulaEnabled && !autoOk,
        user: _currentUserMap,
      );
      if (!mounted) return;
      widget.onTestRun();
      // Raise the banner while this context is still alive, then close the
      // dialog; it lives in the root overlay so it outlives the dialog anyway.
      _reportResult(result);
      Navigator.of(context).pop();
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  void _reportResult(Map<String, dynamic> result) {
    final test = Map<String, dynamic>.from(result['test'] as Map? ?? const {});
    final unit = '${result['analysis_unit'] ?? '%'}';
    final consumption = (result['consumption'] as List?) ?? const [];
    final lowStock = (result['low_stock'] as List?) ?? const [];

    final lines = <String>[
      '${AppText.t('تم حفظ الاختبار', 'Test saved')} — '
          '${test['result_text'] ?? '-'} $unit',
      '${AppText.t('العينة', 'Sample')}: ${test['sample_name'] ?? ''}'
          ' — ${test['source_name'] ?? ''}',
      if (consumption.isNotEmpty)
        '${AppText.t('الاستهلاك', 'Consumption')}: '
            '${consumption.length} ${AppText.t('منتج/خامة', 'item(s)')}',
      if (lowStock.isNotEmpty)
        '${AppText.t('تنبيه مخزون منخفض', 'Low stock')}: ${lowStock.length}',
    ];

    if (lowStock.isNotEmpty) {
      AppFeedback.show(
        context,
        lines.join('\n'),
        isError: false,
        type: AppFeedbackType.neutral,
      );
    } else {
      AppFeedback.success(context, lines.join('\n'));
    }
  }

  Map<String, dynamic>? _selectedAnalysis(RunTestState state) {
    if (state.analysisId == null) return null;
    for (final a in state.analyses) {
      if (a['id'] == state.analysisId) return a;
    }
    return null;
  }

  Map<String, dynamic> _computedResult(RunTestState state) {
    final analysis = _selectedAnalysis(state);
    if (analysis == null) return {'enabled': false, 'ok': true};
    final formula = normalizeFormulaValue(analysis['formula']);
    final expr = '${formula['expression'] ?? ''}'.trim();
    if (expr.isEmpty) return {'enabled': false, 'ok': true};
    final values = <String, Object?>{};
    for (final item in analysis['items'] as List? ?? const []) {
      final m = item as Map<String, dynamic>;
      values['${m['inventory_name'] ?? ''}'.trim()] = safeFormulaFloat(
        m['qty_per_sample'],
      );
    }
    values.addAll(_effectiveValues(state));
    final missing = [
      for (final v in formulaVariables(expr))
        if (values[v] == null || '${values[v]}'.trim().isEmpty) v,
    ];
    try {
      final value = evaluateFormula(
        expr,
        values: values,
        constants: formula['constants'],
        targetUnit: '${analysis['unit'] ?? ''}',
      );
      return {
        'enabled': true,
        'ok': missing.isEmpty,
        'value': value,
        'missing': missing,
        'error': missing.isEmpty
            ? null
            : 'دلائل المعادلة ناقصة: ${missing.join(', ')}',
      };
    } on ValidationError catch (e) {
      return {
        'enabled': true,
        'ok': false,
        'value': null,
        'missing': missing,
        'error': e.message,
      };
    }
  }

  String _computedDisplay(Object? value) {
    final n = safeFormulaFloat(value);
    if (n == null) return '';
    return '${(n * 10000).round() / 10000}';
  }

  final Map<String, TextEditingController> _dynamicControllers = {};
  final Map<String, String> _listSelections = {};

  TextEditingController _controllerFor(String field) {
    // Prune controllers for fields that no longer exist (analysis switch):
    // otherwise stale values + undisposed controllers leak across analyses.
    return _dynamicControllers.putIfAbsent(
      field,
      () => TextEditingController(),
    );
  }

  void _pruneDynamicControllers(List<String> liveFields) {
    final live = liveFields.toSet();
    final stale = [
      for (final key in _dynamicControllers.keys)
        if (!live.contains(key)) key,
    ];
    for (final key in stale) {
      _dynamicControllers.remove(key)?.dispose();
    }
  }

  Map<String, dynamic> _fieldCfgOf(
    Map<String, dynamic> analysis,
    String field,
  ) {
    for (final l in analysis['field_chemical_links'] as List? ?? const []) {
      final m = l as Map<String, dynamic>;
      if ('${m['dynamic_field'] ?? ''}'.trim() == field) return m;
    }
    return const {};
  }

  List<String> _listOptionsOf(Map<String, dynamic> cfg) => [
    for (final o in (cfg['list_values'] as List?) ?? const [])
      if ('$o'.trim().isNotEmpty) '$o'.trim(),
  ];

  String? _listSelectionOrFirst(String field, List<String> options) {
    final saved = _listSelections[field];
    if (saved != null && options.contains(saved)) return saved;
    if (options.isNotEmpty) return options.first;
    return null;
  }

  Map<String, dynamic> _effectiveValues(RunTestState state) {
    final values = <String, dynamic>{
      for (final field in _dynamicControllers.keys)
        if (_dynamicControllers[field]!.text.trim().isNotEmpty)
          field: _dynamicControllers[field]!.text.trim(),
    };
    final analysis = _selectedAnalysis(state);
    if (analysis != null) {
      for (final l in analysis['field_chemical_links'] as List? ?? const []) {
        final m = l as Map<String, dynamic>;
        final field = '${m['dynamic_field'] ?? ''}'.trim();
        if (field.isEmpty) continue;
        if ('${m['kind'] ?? 'link'}' == 'value') {
          final v = safeFormulaFloat(m['fixed_value']);
          if (v != null) values[field] = v;
        } else if ('${m['kind'] ?? 'link'}' == 'list') {
          final sel = _listSelectionOrFirst(field, _listOptionsOf(m));
          if (sel != null) values[field] = sel;
        }
      }
    }
    return values;
  }

  List<String> _dynamicFieldsOf(RunTestState state) {
    for (final a in state.analyses) {
      if (a['id'] == state.analysisId) {
        final fields = [
          for (final f in (a['dynamic_fields'] as List?) ?? const <dynamic>[])
            if ('$f'.trim().isNotEmpty &&
                '$f'.trim().toLowerCase() != 'sample name')
              '$f',
        ];
        _pruneDynamicControllers(fields);
        return fields;
      }
    }
    return const [];
  }

  Widget _dynamicFieldWidget(RunTestState state, String field) {
    final analysis = _selectedAnalysis(state);
    final cfg = analysis == null
        ? const <String, dynamic>{}
        : _fieldCfgOf(analysis, field);
    final kind = '${cfg['kind'] ?? 'link'}';

    final (IconData icon, Color color, String kindLabel) = switch (kind) {
      'value' => (
        Icons.pin_outlined,
        AppColors.info,
        AppText.t('قيمة ثابتة', 'Fixed value'),
      ),
      'list' => (
        Icons.view_list_outlined,
        AppColors.accent,
        AppText.t('قائمة', 'List'),
      ),
      _ => (
        Icons.link_outlined,
        AppColors.success,
        AppText.t('مرتبط', 'Linked'),
      ),
    };

    Widget input;
    String hint;
    if (kind == 'value') {
      final v = safeFormulaFloat(cfg['fixed_value']);
      hint = v == null
          ? AppText.t(
              'قيمة ثابتة من إعداد التحليل — لا تُكتب هنا.',
              'Fixed value from analysis setup — not typed here.',
            )
          : AppText.t(
              'قيمة ثابتة = $v تُستخدم تلقائياً في المعادلة.',
              'Fixed value = $v used automatically in the formula.',
            );
      input = InputDecorator(
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            v == null ? '-' : '${(v * 10000).round() / 10000}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
      );
    } else if (kind == 'list') {
      final options = _listOptionsOf(cfg);
      final selected = _listSelectionOrFirst(field, options);
      hint = options.isEmpty
          ? AppText.t(
              'لم تُعرف قيم لهذه القائمة. عدّل التحليل.',
              'No values defined for this list. Edit the analysis.',
            )
          : (selected == null
                ? AppText.t(
                    'اختر قيمة من القائمة — تُستخدم في المعادلة.',
                    'Pick a value from the list — used in the formula.',
                  )
                : AppText.t(
                    'القيمة المختارة ستُستخدم في المعادلة.',
                    'The chosen value will be used in the formula.',
                  ));
      input = DropdownButtonFormField<String>(
        key: ValueKey('list-${state.analysisId}-$field'),
        initialValue: selected,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppText.t('اختر من القائمة', 'Choose from list'),
          isDense: true,
        ),
        items: [
          for (final o in options)
            DropdownMenuItem<String>(
              value: o,
              child: Text(o, textDirection: TextDirection.ltr),
            ),
        ],
        onChanged: (v) => setState(() => _listSelections[field] = v ?? ''),
      );
    } else {
      final isLinked = (int.tryParse('${cfg['inventory_id'] ?? 0}') ?? 0) > 0;
      final name = '${cfg['inventory_name'] ?? ''}';
      hint = isLinked
          ? AppText.t(
              'مرتبط بمادة «$name» — تُستهلك من المخزون بقيمة هذه الخانة.',
              'Linked to «$name» — consumed from stock by this value.',
            )
          : AppText.t('أدخل القيمة يدوياً.', 'Enter the value manually.');
      input = TextField(
        controller: _controllerFor(field),
        onChanged: (_) => setState(() {}),
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: AppText.t(field, 'Dynamic value: $field'),
          isDense: true,
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 168.w,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 15.r, color: color),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        field,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    kindLabel,
                    style: TextStyle(
                      fontSize: 11.spMax,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              input,
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  hint,
                  style: TextStyle(
                    fontSize: 11.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String step, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              step,
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
                fontSize: 12.spMax,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _inspectionTraceCard(Map<String, dynamic> inspection) {
    Widget detail(IconData icon, String label, Object? value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15.r, color: AppColors.primary),
        const SizedBox(width: 5),
        Text(
          '$label: ${'${value ?? ''}'.trim().isEmpty ? '—' : value}',
          style: TextStyle(fontSize: 12.spMax),
        ),
      ],
    );

    return SizedBox(
      width: double.infinity,
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.xs,
          children: [
            detail(
              Icons.qr_code_2,
              AppText.t('رقم المحضر', 'Record'),
              inspection['entry_code'],
            ),
            detail(
              Icons.local_shipping_outlined,
              AppText.t('المورد', 'Supplier'),
              inspection['supplier'],
            ),
            detail(
              Icons.directions_car_outlined,
              AppText.t('السيارة', 'Vehicle'),
              inspection['truck_number'],
            ),
            detail(
              Icons.calendar_today_outlined,
              AppText.t('التاريخ', 'Date'),
              inspection['inspection_date'],
            ),
            detail(
              Icons.fact_check_outlined,
              AppText.t('القرار', 'Decision'),
              inspection['decision_status'],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RunTestCubit>().state;
    final cubit = context.read<RunTestCubit>();
    final dynamicFields = _dynamicFieldsOf(state);
    final analysis = _selectedAnalysis(state);
    final comp = _computedResult(state);
    final formulaEnabled = comp['enabled'] == true;
    final autoOk = formulaEnabled && _formulaAuto && comp['ok'] == true;
    final missingHint = formulaEnabled && _formulaAuto && comp['ok'] != true
        ? ('${comp['error'] ?? ''}'.isNotEmpty
              ? '${comp['error']}'
              : AppText.t(
                  'النتيجة لا تُحسب من المعادلة',
                  'Result cannot be computed from the formula',
                ))
        : null;
    final unit = '${analysis?['unit'] ?? '%'}';

    return AppErrorFeedback<RunTestCubit, RunTestState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('تشغيل اختبار', 'Run a test'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${AppText.t('سجّل تحليلاً جديداً وفق إعدادات التحليل.', 'Record a new test following the analysis setup.')}'
            '${analysis == null ? '' : ' — ${analysis['name']} (${analysis['unit'] ?? '%'})'}',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.analyses.isNotEmpty) const AppRefreshBar(),
          if (state.loading && state.analyses.isEmpty) ...[
            const AppSkeletonList(rows: 6, lines: 3, height: 380),
          ] else ...[
            _sectionTitle('1', AppText.t('إعدادات العينة', 'Sample setup')),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppEntityAutocomplete(
                    options: state.analyses,
                    selectedId: state.analysisId,
                    label: AppText.t('التحليل', 'Analysis'),
                    hint: AppText.t(
                      'ابحث باسم التحليل…',
                      'Search analyses…',
                    ),
                    prefixIcon: Icons.science_outlined,
                    displayOf: (a) =>
                        '${a['name']} (${a['unit'] ?? '%'})',
                    filter: (a, q) => entityMatches(a, q, [
                      (r) => '${r['name'] ?? ''}',
                      (r) => '${r['unit'] ?? ''}',
                    ]),
                    onSelected: (v) {
                      setState(() {
                        _formulaAuto = true;
                        _listSelections.clear();
                        for (final c in _dynamicControllers.values) {
                          c.dispose();
                        }
                        _dynamicControllers.clear();
                      });
                      cubit.selectAnalysis((v as num).toInt());
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 220.w,
                        child: DropdownButtonFormField<String>(
                          initialValue: state.sourceType,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: AppText.t('المصدر', 'Source'),
                            isDense: true,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'raw_material',
                              child: Text(
                                AppText.t('مادة خام', 'Raw material'),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'product',
                              child: Text(AppText.t('منتج', 'Product')),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) cubit.setSourceType(v);
                          },
                        ),
                      ),
                      if (state.sourceType == 'raw_material') ...[
                        SizedBox(
                          width: 300.w,
                          child: AppEntityAutocomplete(
                            options: state.rawMaterials,
                            selectedId: state.rawMaterialId,
                            label: AppText.t('الخامة', 'Raw material'),
                            hint: AppText.t(
                              'ابحث باسم الخامة أو الكود…',
                              'Search materials…',
                            ),
                            prefixIcon: Icons.inventory_2_outlined,
                            displayOf: (m) =>
                                '${m['material_name']} (${m['material_code']})',
                            filter: (m, q) => entityMatches(m, q, [
                              (r) => '${r['material_name'] ?? ''}',
                              (r) => '${r['material_code'] ?? ''}',
                            ]),
                            onSelected: (id) {
                              if (id != null) {
                                cubit.selectRawMaterial((id as num).toInt());
                              }
                            },
                            onCleared: null,
                          ),
                        ),
                        SizedBox(
                          width: 350.w,
                          child: AppEntityAutocomplete(
                            options: state.inspections,
                            selectedId: state.selectedInspection['id'],
                            label: AppText.t(
                              'رقم محضر الفحص',
                              'Inspection record',
                            ),
                            hint: AppText.t(
                              'ابحث برقم القيد أو المورد…',
                              'Search records…',
                            ),
                            prefixIcon: Icons.receipt_long_outlined,
                            helperText: state.loadingInspections
                                ? AppText.t(
                                    'جارٍ تحميل المحاضر…',
                                    'Loading inspection records…',
                                  )
                                : null,
                            enabled: !state.loadingInspections,
                            displayOf: (r) =>
                                '${r['entry_code']} · ${r['inspection_date']}',
                            subtitleOf: (r) =>
                                '${AppText.t('المورد', 'Supplier')}: '
                                '${r['supplier'] ?? '—'} · '
                                '${AppText.t('السيارة', 'Vehicle')}: '
                                '${r['truck_number'] ?? '—'}',
                            filter: (r, q) => entityMatches(r, q, [
                              (x) => '${x['entry_code'] ?? ''}',
                              (x) => '${x['supplier'] ?? ''}',
                              (x) => '${x['truck_number'] ?? ''}',
                              (x) => '${x['inspection_date'] ?? ''}',
                            ]),
                            onSelected: (id) {
                              if (id != null) {
                                cubit.selectInspection((id as num).toInt());
                              }
                            },
                          ),
                        ),
                        if (state.rawMaterialId != null &&
                            !state.loadingInspections &&
                            state.inspections.isEmpty)
                          Text(
                            AppText.t(
                              'لا توجد محاضر فحص لهذه الخامة.',
                              'No inspection records exist for this raw material.',
                            ),
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12.spMax,
                            ),
                          ),
                        if (state.selectedInspection.isNotEmpty) ...[
                          _inspectionTraceCard(state.selectedInspection),
                          if (state.selectedSampleName.isEmpty)
                            Text(
                              AppText.t(
                                'لا يحتوي المحضر على عينات مسجلة؛ أضف عينة إلى المحضر قبل تسجيل التحليل.',
                                'This record has no registered samples. Add a sample to the inspection before recording an analysis.',
                              ),
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12.spMax,
                              ),
                            )
                          else
                            SizedBox(
                              width: 220.w,
                              child: AppEntityAutocomplete(
                                options: [
                                  for (final name
                                      in (state.selectedInspection[
                                                  'sample_names']
                                              as List? ??
                                          const []))
                                    if ('$name'.trim().isNotEmpty)
                                      {'id': '$name'.trim(), 'name': '$name'.trim()},
                                ],
                                selectedId: state.selectedSampleName,
                                label: AppText.t(
                                  'العينة في المحضر',
                                  'Inspection sample',
                                ),
                                hint: AppText.t(
                                  'ابحث باسم العينة…',
                                  'Search samples…',
                                ),
                                displayOf: (r) => '${r['name']}',
                                filter: (r, q) => entityMatches(r, q, [
                                  (x) => '${x['name'] ?? ''}',
                                ]),
                                onSelected: (name) {
                                  cubit.selectInspectionSample('$name');
                                },
                              ),
                            ),
                        ],
                      ] else ...[
                        SizedBox(
                          width: 280.w,
                          child: AppEntityAutocomplete(
                            options: state.products,
                            selectedId: state.productId,
                            label: AppText.t('المنتج', 'Product'),
                            hint: AppText.t(
                              'ابحث باسم المنتج…',
                              'Search products…',
                            ),
                            prefixIcon: Icons.category_outlined,
                            displayOf: (p) => '${p['name']}',
                            filter: (p, q) => entityMatches(p, q, [
                              (r) => '${r['name'] ?? ''}',
                            ]),
                            onSelected: (v) {
                              if (v != null) {
                                cubit.selectProduct((v as num).toInt());
                              }
                            },
                          ),
                        ),
                      ],
                      if (state.sourceType == 'product')
                        SizedBox(
                          width: 220.w,
                          child: TextField(
                            controller: _sampleName,
                            decoration: InputDecoration(
                              labelText: AppText.t('اسم العينة', 'Sample name'),
                              isDense: true,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _sectionTitle('2', AppText.t('قيم الحقول', 'Field values')),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: dynamicFields.isEmpty
                  ? Text(
                      AppText.t(
                        'لا حقول ديناميكية لهذا التحليل.',
                        'No dynamic fields for this analysis.',
                      ),
                      style: TextStyle(color: AppColors.textMuted),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < dynamicFields.length; i++) ...[
                          _dynamicFieldWidget(state, dynamicFields[i]),
                          if (i < dynamicFields.length - 1)
                            const Divider(height: 24),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _sectionTitle('3', AppText.t('النتيجة', 'Result')),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (formulaEnabled) ...[
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        AppText.t(
                          'حساب النتيجة تلقائياً من المعادلة',
                          'Compute result from formula',
                        ),
                      ),
                      value: _formulaAuto,
                      onChanged: (v) => setState(() => _formulaAuto = v),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (autoOk)
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppColors.success.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            AppText.t(
                              'النتيجة من المعادلة',
                              'Result from formula',
                            ),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${_computedDisplay(comp['value'])} $unit',
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                              fontSize: 22.spMax,
                              fontWeight: FontWeight.w800,
                              color: AppColors.success,
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    TextField(
                      controller: _resultText,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _run(),
                      decoration: InputDecoration(
                        labelText: formulaEnabled
                            ? AppText.t('النتيجة اليدوية', 'Manual result')
                            : AppText.t('النتيجة', 'Result'),
                        helperText: missingHint,
                        helperMaxLines: 3,
                        isDense: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  AppButton(
                    expanded: true,
                    label: AppStrings.runTest,
                    icon: Icon(Icons.play_arrow, size: 18.r),
                    loading: state.running,
                    onPressed: state.running ? null : _run,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
