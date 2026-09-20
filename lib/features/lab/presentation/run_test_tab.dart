import 'package:flutter/material.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../di/service_locator.dart';
import '../data/lab_repo.dart';

/// Run a sample test against an analysis (raw material or product).
class RunTestTab extends StatefulWidget {
  final VoidCallback onTestRun;
  const RunTestTab({super.key, required this.onTestRun});

  @override
  State<RunTestTab> createState() => _RunTestTabState();
}

class _RunTestTabState extends State<RunTestTab> {
  final _repo = getIt<LabRepo>();

  List<Map<String, dynamic>> _analyses = [];
  List<Map<String, dynamic>> _products = [];
  int? _analysisId;
  String _sourceType = 'raw_material';
  String _sourceName = '';
  int? _productId;
  final _entryCode = TextEditingController();
  final _sampleName = TextEditingController(text: 'Sample 1');
  final _resultText = TextEditingController();
  bool _loading = true;
  bool _running = false;
  String? _error;

  Map<String, dynamic>? get _currentUserMap {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return null;
    return {'id': user.id, 'username': user.username, 'full_name': user.fullName};
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _entryCode.dispose();
    _sampleName.dispose();
    _resultText.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final analyses = await _repo.listAnalyses();
      final products = await _repo.listProducts();
      if (!mounted) return;
      setState(() {
        _analyses = analyses;
        _products = products;
        if (_analysisId == null && analyses.isNotEmpty) {
          _analysisId = (analyses.first['id'] as num).toInt();
        }
        _loading = false;
      });
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _lookupEntry() async {
    final code = _entryCode.text.trim();
    if (code.isEmpty) return;
    final inspection = await _repo.resolveInspection(code);
    if (!mounted) return;
    if (inspection == null) {
      AppFeedback.error(context, 'كود الدخول غير موجود | Entry code not found.');
      return;
    }
    setState(() => _sourceName = '${inspection['material_name'] ?? ''}');
  }

  List<String> get _dynamicFields {
    final selected = _analyses.where((a) => a['id'] == _analysisId).toList();
    if (selected.isEmpty) return const [];
    return [
      for (final f in (selected.first['dynamic_fields'] as List?) ?? const <dynamic>[])
        if ('$f'.trim().isNotEmpty && '$f'.trim().toLowerCase() != 'sample name') '$f',
    ];
  }

  Future<void> _run() async {
    if (_analysisId == null) {
      AppFeedback.error(context, 'اختر التحليل | Select an analysis.');
      return;
    }
    if (_sampleName.text.trim().isEmpty) {
      AppFeedback.error(context, 'اسم العينة مطلوب | Sample name is required.');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final result = await _repo.runSampleTest(
        analysisId: _analysisId!,
        sourceType: _sourceType,
        sourceRefId: _sourceType == 'product' ? _productId : null,
        sourceName: _sourceType == 'product'
            ? '${_products.firstWhere((p) => p['id'] == _productId)['name'] ?? ''}'
            : _sourceName,
        sampleName: _sampleName.text.trim(),
        resultText: _resultText.text.trim(),
        dynamicValues: _dynamicValues,
        user: _currentUserMap,
        entryCode: _sourceType == 'raw_material' ? _entryCode.text.trim() : '',
      );
      if (!mounted) return;
      widget.onTestRun();
      await showDialog<void>(
        context: context,
        builder: (_) => _ResultDialog(result: result),
      );
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  final Map<String, TextEditingController> _dynamicControllers = {};

  TextEditingController _controllerFor(String field) {
    return _dynamicControllers.putIfAbsent(field, () => TextEditingController());
  }

  Map<String, dynamic> get _dynamicValues => {
        for (final field in _dynamicControllers.keys)
          if (_dynamicControllers[field]!.text.trim().isNotEmpty)
            field: _dynamicControllers[field]!.text.trim(),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('تشغيل اختبار | Run a test', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppSpacing.md),
        if (_loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (_error != null) ...[
          Text(_error!, style: TextStyle(color: AppColors.danger)),
        ] else
          AppCard(
            padding: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<int>(
                    initialValue: _analysisId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'التحليل | Analysis',
                      isDense: true,
                    ),
                    items: [
                      for (final a in _analyses)
                        DropdownMenuItem<int>(
                          value: (a['id'] as num).toInt(),
                          child: Text('${a['name']} (${a['unit'] ?? '%'})',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _analysisId = v);
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: _sourceType,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'المصدر | Source',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: 'raw_material', child: Text('مادة خام | Raw material')),
                      DropdownMenuItem(value: 'product', child: Text('منتج | Product')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _sourceType = v);
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_sourceType == 'raw_material') ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _entryCode,
                            decoration: const InputDecoration(
                              labelText: 'رقم القيد | Entry code',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        OutlinedButton(
                          onPressed: _lookupEntry,
                          child: const Text('بحث | Lookup'),
                        ),
                      ],
                    ),
                    if (_sourceName.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text('المادة | Material: $_sourceName'),
                    ],
                  ] else ...[
                    DropdownButtonFormField<int>(
                      initialValue: _productId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'المنتج | Product',
                        isDense: true,
                      ),
                      items: [
                        for (final p in _products)
                          DropdownMenuItem<int>(
                            value: (p['id'] as num).toInt(),
                            child: Text('${p['name']}', overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _productId = v);
                      },
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.lg,
                    runSpacing: AppSpacing.md,
                    children: [
                      SizedBox(
                        width: 260,
                        child: TextField(
                          controller: _sampleName,
                          decoration: const InputDecoration(
                            labelText: 'اسم العينة | Sample name',
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: TextField(
                          controller: _resultText,
                          decoration: const InputDecoration(
                            labelText: 'النتيجة اليدوية | Manual result (optional)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_dynamicFields.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    for (final field in _dynamicFields)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: TextField(
                          controller: _controllerFor(field),
                          decoration: InputDecoration(
                            labelText: '$field | Dynamic value',
                            isDense: true,
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  AppButton(
                    label: AppStrings.runTest,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    loading: _running,
                    onPressed: _running ? null : _run,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ResultDialog extends StatelessWidget {
  final Map<String, dynamic> result;
  const _ResultDialog({required this.result});

  @override
  Widget build(BuildContext context) {
    final test = Map<String, dynamic>.from(result['test'] as Map? ?? const {});
    final analysisUnit = '${result['analysis_unit'] ?? '%'}';
    final rangeCheck = result['range_check'];
    final consumption = (result['consumption'] as List?) ?? const [];
    final lowStock = (result['low_stock'] as List?) ?? const [];
    final computed = result['computed'];

    return AlertDialog(
      title: const Text('نتيجة الاختبار | Test result'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('${test['result_text'] ?? '-'} $analysisUnit',
                      style: Theme.of(context).textTheme.headlineMedium),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('العينة | Sample: ${test['sample_name'] ?? ''} — ${test['source_name'] ?? ''}',
                  style: TextStyle(color: AppColors.textMuted)),
              if (computed is Map) ...[
                const SizedBox(height: AppSpacing.md),
                Text('المعادلة | Formula: ${computed['expression'] ?? ''}'),
              ],
              if (rangeCheck != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Text('الحدود | Range: '
                        '${rangeCheck['min'] ?? '...'} - ${rangeCheck['max'] ?? '...'} '
                        '${rangeCheck['unit'] ?? ''}'),
                    const SizedBox(width: AppSpacing.md),
                    Text(
                      (rangeCheck['out_of_range'] == true)
                          ? 'خارج الحدود | Out of range'
                          : 'ضمن الحدود | In range',
                      style: TextStyle(
                        color: (rangeCheck['out_of_range'] == true)
                            ? AppColors.danger
                            : AppColors.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
              if (consumption.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text('الاستهلاك | Consumption',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                for (final c in consumption.cast<Map>())
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Builder(builder: (context) {
                      final unit = '${c['unit'] ?? ''}';
                      final shortfall = (c['shortfall_qty'] as num?)?.toDouble() ?? 0;
                      return Text(
                        '${c['inventory_name']}: -${c['qty_used']} $unit'
                        '${shortfall > 0 ? ' (نقص $shortfall)' : ''}',
                      );
                    }),
                  ),
              ],
              if (lowStock.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text('تنبيه مخزون | Low stock',
                    style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)),
                for (final l in lowStock.cast<Map>())
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                        '${l['inventory_name']}: ${l['current_qty']} / حد أدنى ${l['min_qty']}'),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إغلاق | Close'),
        ),
      ],
    );
  }
}