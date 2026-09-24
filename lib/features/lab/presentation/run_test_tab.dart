import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
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
  final _entryCode = TextEditingController();
  final _sampleName = TextEditingController(text: 'Sample 1');
  final _resultText = TextEditingController();
  bool _formulaAuto = true;

  Map<String, dynamic>? get _currentUserMap {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return null;
    return {'id': user.id, 'username': user.username, 'full_name': user.fullName};
  }

  @override
  void dispose() {
    _entryCode.dispose();
    _sampleName.dispose();
    _resultText.dispose();
    for (final c in _dynamicControllers.values) {
      c.dispose();
    }
    _dynamicControllers.clear();
    super.dispose();
  }

  Future<void> _lookupEntry() async {
    final found = await context.read<RunTestCubit>().lookupEntry(_entryCode.text);
    if (!mounted) return;
    if (!found) AppFeedback.error(context, AppText.t('كود الدخول غير موجود', 'Entry code not found.'));
  }

  Future<void> _run() async {
    final state = context.read<RunTestCubit>().state;
    if (state.analysisId == null) {
      AppFeedback.error(context, AppText.t('اختر التحليل', 'Select an analysis.'));
      return;
    }
    if (_sampleName.text.trim().isEmpty) {
      AppFeedback.error(context, AppText.t('اسم العينة مطلوب', 'Sample name is required.'));
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
        AppFeedback.error(context, AppText.t(
          'أدخل النتيجة يدوياً — لا يمكن حسابها من المعادلة.',
          'Enter the result manually — the formula cannot be computed.',
        ));
        return;
      }
    }
    try {
      final result = await context.read<RunTestCubit>().run(
            sampleName: _sampleName.text.trim(),
            resultText: resultText,
            dynamicValues: dynamicValues,
            entryCode: _entryCode.text.trim(),
            manualResult: formulaEnabled && !autoOk,
            user: _currentUserMap,
          );
      if (!mounted) return;
      widget.onTestRun();
      final messenger = ScaffoldMessenger.of(context);
      final nav = Navigator.of(context);
      nav.pop();
      messenger.showSnackBar(_resultSnackBar(result));
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  SnackBar _resultSnackBar(Map<String, dynamic> result) {
    final test = Map<String, dynamic>.from(result['test'] as Map? ?? const {});
    final unit = '${result['analysis_unit'] ?? '%'}';
    final consumption = (result['consumption'] as List?) ?? const [];
    final lowStock = (result['low_stock'] as List?) ?? const [];
    final items = <Widget>[
      Text(
        '${AppText.t('تم حفظ الاختبار', 'Test saved')} — '
        '${test['result_text'] ?? '-'} $unit',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(
        '${AppText.t('العينة', 'Sample')}: ${test['sample_name'] ?? ''}'
        ' — ${test['source_name'] ?? ''}',
      ),
      if (consumption.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text('${AppText.t('الاستهلاك', 'Consumption')}: '
            '${consumption.length} ${AppText.t('منتج/خامة', 'item(s)')}'),
      ],
      if (lowStock.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          '${AppText.t('تنبيه مخزون منخفض', 'Low stock')}: '
          '${lowStock.length}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ];
    return SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 7),
      backgroundColor: lowStock.isNotEmpty
          ? AppColors.warning
          : AppColors.success,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items,
      ),
    );
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
      values['${m['inventory_name'] ?? ''}'.trim()] = safeFormulaFloat(m['qty_per_sample']);
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
        'error': missing.isEmpty ? null : 'دلائل المعادلة ناقصة: ${missing.join(', ')}',
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
    return _dynamicControllers.putIfAbsent(field, () => TextEditingController());
  }

  Map<String, dynamic> _fieldCfgOf(Map<String, dynamic> analysis, String field) {
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
        return [
          for (final f in (a['dynamic_fields'] as List?) ?? const <dynamic>[])
            if ('$f'.trim().isNotEmpty && '$f'.trim().toLowerCase() != 'sample name') '$f',
        ];
      }
    }
    return const [];
  }

  Widget _dynamicFieldWidget(RunTestState state, String field) {
    final analysis = _selectedAnalysis(state);
    final cfg = analysis == null ? const <String, dynamic>{} : _fieldCfgOf(analysis, field);
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
          ? AppText.t('قيمة ثابتة من إعداد التحليل — لا تُكتب هنا.',
              'Fixed value from analysis setup — not typed here.')
          : AppText.t('قيمة ثابتة = $v تُستخدم تلقائياً في المعادلة.',
              'Fixed value = $v used automatically in the formula.');
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
          ? AppText.t('لم تُعرف قيم لهذه القائمة. عدّل التحليل.',
              'No values defined for this list. Edit the analysis.')
          : (selected == null
              ? AppText.t('اختر قيمة من القائمة — تُستخدم في المعادلة.',
                  'Pick a value from the list — used in the formula.')
              : AppText.t('القيمة المختارة ستُستخدم في المعادلة.',
                  'The chosen value will be used in the formula.'));
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
      final isLinked =
          (int.tryParse('${cfg['inventory_id'] ?? 0}') ?? 0) > 0;
      final name = '${cfg['inventory_name'] ?? ''}';
      hint = isLinked
          ? AppText.t(
              'مرتبط بمادة «$name» — تُستهلك من المخزون بقيمة هذه الخانة.',
              'Linked to «$name» — consumed from stock by this value.')
          : AppText.t('أدخل القيمة يدوياً.',
              'Enter the value manually.');
      input = TextField(
        controller: _controllerFor(field),
        onChanged: (_) => setState(() {}),
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
                      horizontal: 6, vertical: 2),
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
                Text(hint,
                    style: TextStyle(
                        fontSize: 11.spMax, color: AppColors.textMuted)),
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
                  fontSize: 12.spMax),
            ),
          ),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ],
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
            : AppText.t('النتيجة لا تُحسب من المعادلة', 'Result cannot be computed from the formula'))
        : null;
    final unit = '${analysis?['unit'] ?? '%'}';

    return Column(
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
        if (state.loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (state.error != null) ...[
          Text(state.error!, style: TextStyle(color: AppColors.danger)),
        ] else ...[
          _sectionTitle('1', AppText.t('إعدادات العينة', 'Sample setup')),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: state.analysisId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: AppText.t('التحليل', 'Analysis'),
                    isDense: true,
                  ),
                  items: [
                    for (final a in state.analyses)
                      DropdownMenuItem<int>(
                        value: (a['id'] as num).toInt(),
                        child: Text('${a['name']} (${a['unit'] ?? '%'})',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() {
                        _formulaAuto = true;
                        _listSelections.clear();
                      });
                      cubit.selectAnalysis(v);
                    }
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
                              child: Text(AppText.t('مادة خام', 'Raw material'))),
                          DropdownMenuItem(
                              value: 'product',
                              child: Text(AppText.t('منتج', 'Product'))),
                        ],
                        onChanged: (v) {
                          if (v != null) cubit.setSourceType(v);
                        },
                      ),
                    ),
                    if (state.sourceType == 'raw_material') ...[
                      SizedBox(
                        width: 280.w,
                        child: TextField(
                          controller: _entryCode,
                          decoration: InputDecoration(
                            labelText: AppText.t('رقم القيد', 'Entry code'),
                            isDense: true,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _lookupEntry,
                        child: Text(AppText.t('بحث', 'Lookup')),
                      ),
                      if (state.sourceName.isNotEmpty)
                        Text(
                          '${AppText.t('المادة', 'Material')}: ${state.sourceName}',
                          style: TextStyle(
                              color: AppColors.success,
                              fontSize: 12.spMax),
                        ),
                    ] else ...[
                      SizedBox(
                        width: 280.w,
                        child: DropdownButtonFormField<int>(
                          initialValue: state.productId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: AppText.t('المنتج', 'Product'),
                            isDense: true,
                          ),
                          items: [
                            for (final p in state.products)
                              DropdownMenuItem<int>(
                                value: (p['id'] as num).toInt(),
                                child: Text('${p['name']}',
                                    overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) cubit.selectProduct(v);
                          },
                        ),
                      ),
                    ],
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
                    AppText.t('لا حقول ديناميكية لهذا التحليل.',
                        'No dynamic fields for this analysis.'),
                    style: TextStyle(color: AppColors.textMuted))
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
                    title: Text(AppText.t(
                        'حساب النتيجة تلقائياً من المعادلة',
                        'Compute result from formula')),
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
                          color: AppColors.success.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          AppText.t('النتيجة من المعادلة',
                              'Result from formula'),
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
    );
  }
}