import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../di/service_locator.dart';
import '../../lab/data/lab_repo.dart';
import 'cubit/products_cubit.dart';

/// Products tab — port of the Reference app Products section
/// (57_reference_app.js): product CRUD with analysis ranges.
class ProductsTab extends StatelessWidget {
  const ProductsTab({super.key});

  Future<void> _openEditor(BuildContext context,
      [Map<String, dynamic>? product]) async {
    final state = context.read<ProductsCubit>().state;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProductDialog(product: product, analyses: state.analyses),
    );
    if (saved != true || !context.mounted) return;
    await context.read<ProductsCubit>().load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> product) async {
    final cubit = context.read<ProductsCubit>();
    final name = '${product['name'] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppText.t('حذف المنتج', 'Delete product')),
        content: Text('${AppText.t('حذف', 'Delete')} "$name"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await getIt<LabRepo>().deleteProduct((product['id'] as num).toInt());
      if (context.mounted) AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.error(context, '$e');
    }
  }

  Widget _rangesChips(List<dynamic> ranges) {
    if (ranges.isEmpty) return const Text('—');
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final r in ranges)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.surfaceSoft,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.borderMuted),
            ),
            child: Text(
              '${r['analysis_name'] ?? ''}: '
              '${r['min_value'] ?? '-'} - ${r['max_value'] ?? '-'} '
              '${r['unit'] ?? ''}',
              style: TextStyle(fontSize: 12.spMax),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProductsCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(AppText.t('المنتجات', 'Products'),
                style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            AppButton(
              small: true,
              icon: Icon(Icons.add, size: 16.r),
              label: AppText.t('منتج جديد', 'New Product'),
              onPressed: () => _openEditor(context),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (state.loading)
          const Center(child: CircularProgressIndicator())
        else if (state.error != null)
          Text(state.error!, style: TextStyle(color: AppColors.danger))
        else if (state.rows.isEmpty)
          AppEmptyState(
            icon: Icons.inventory_2_outlined,
            title: AppText.t('لا توجد منتجات.', 'No products.'),
          )
        else
          Flexible(
            flex: 5,
            child: AppCard(
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: [
                        DataColumn(label: Text(AppText.t('المنتج', 'Product'))),
                        DataColumn(label: Text(AppText.t('النوع', 'Category'))),
                        DataColumn(label: Text(AppText.t('الوصف', 'Description'))),
                        DataColumn(label: Text(AppText.t('الإجراءات', 'Actions'))),
                      ],
                      rows: [
                        for (final p in state.rows)
                          DataRow(
                            cells: [
                              DataCell(Text('${p['name'] ?? ''}',
                                  style: const TextStyle(fontWeight: FontWeight.w600))),
                              DataCell(Text('${p['category'] ?? '-'}')),
                              DataCell(Text('${p['description'] ?? '-'}')),
                              DataCell(Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: AppStrings.edit,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _openEditor(context, p),
                                    icon: Icon(Icons.edit_outlined, size: 18.r),
                                  ),
                                  IconButton(
                                    tooltip: AppStrings.delete,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _delete(context, p),
                                    icon: Icon(Icons.delete_outline,
                                        size: 18.r, color: AppColors.danger),
                                  ),
                                ],
                              )),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        if (state.rows.isNotEmpty)
          Flexible(
            flex: 3,
            child: AppCard(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppText.t('النطاقات', 'Ranges'),
                        style: TextStyle(
                            fontSize: 14.spMax, fontWeight: FontWeight.w700)),
                    const SizedBox(height: AppSpacing.sm),
                    for (final p in state.rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p['name'] ?? ''}',
                                style: TextStyle(
                                    fontSize: 13.spMax,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary)),
                            const SizedBox(height: 4),
                            _rangesChips(p['ranges'] as List? ?? []),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RangeRow {
  int? analysisId;
  final TextEditingController minCtrl;
  final TextEditingController maxCtrl;
  final TextEditingController unitCtrl;
  _RangeRow({
    this.analysisId,
    String min = '',
    String max = '',
    String unit = '%',
  })  : minCtrl = TextEditingController(text: min),
        maxCtrl = TextEditingController(text: max),
        unitCtrl = TextEditingController(text: unit);
  void dispose() {
    minCtrl.dispose();
    maxCtrl.dispose();
    unitCtrl.dispose();
  }
}

class _ProductDialog extends StatefulWidget {
  final Map<String, dynamic>? product;
  final List<Map<String, dynamic>> analyses;
  const _ProductDialog({this.product, required this.analyses});

  @override
  State<_ProductDialog> createState() => _ProductDialogState();
}

class _ProductDialogState extends State<_ProductDialog> {
  final _repo = getIt<LabRepo>();
  late final TextEditingController _name =
      TextEditingController(text: '${widget.product?['name'] ?? ''}');
  late final TextEditingController _category =
      TextEditingController(text: '${widget.product?['category'] ?? ''}');
  late final TextEditingController _description =
      TextEditingController(text: '${widget.product?['description'] ?? ''}');
  late final List<_RangeRow> _ranges;
  bool _saving = false;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _ranges = [
      for (final r in (widget.product?['ranges'] as List? ?? []))
        _RangeRow(
          analysisId: int.tryParse('${r['analysis_id'] ?? ''}'),
          min: r['min_value'] != null ? '${r['min_value']}' : '',
          max: r['max_value'] != null ? '${r['max_value']}' : '',
          unit: '${r['unit'] ?? ''}'.trim().isNotEmpty ? '${r['unit']}' : '%',
        ),
    ];
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _description.dispose();
    for (final r in _ranges) {
      r.dispose();
    }
    super.dispose();
  }

  void _addRange() => setState(() => _ranges.add(_RangeRow()));

  void _removeRange(int index) {
    final row = _ranges.removeAt(index);
    row.dispose();
    setState(() {});
  }

  Set<String> _usedAnalysisIds(int excludeIndex) => {
        for (var i = 0; i < _ranges.length; i++)
          if (i != excludeIndex && _ranges[i].analysisId != null)
            '${_ranges[i].analysisId}',
      };

  void _onAnalysisChange(_RangeRow row) {
    final a = row.analysisId == null
        ? null
        : widget.analyses
            .where((x) => '${x['id']}' == '${row.analysisId}')
            .firstOrNull;
    setState(() {
      if (a == null) return;
      row.unitCtrl.text = '${a['unit'] ?? ''}'.trim().isNotEmpty
          ? '${a['unit']}'
          : (row.unitCtrl.text.trim().isNotEmpty ? row.unitCtrl.text.trim() : '%');
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = AppText.t('الاسم مطلوب', 'Name is required.'));
      return;
    }
    setState(() => _saving = true);
    final ranges = <Map<String, dynamic>>[
      for (final r in _ranges)
        if (r.analysisId != null)
          {
            'analysis_id': r.analysisId,
            'min_value': r.minCtrl.text.trim(),
            'max_value': r.maxCtrl.text.trim(),
            'unit': r.unitCtrl.text.trim().isNotEmpty ? r.unitCtrl.text.trim() : '%',
          },
    ];
    try {
      if (widget.product == null) {
        await _repo.createProduct(
          name: name,
          category: _category.text.trim(),
          description: _description.text.trim(),
          ranges: ranges,
        );
      } else {
        await _repo.updateProduct(
          (widget.product!['id'] as num).toInt(),
          {
            'name': name,
            'category': _category.text.trim(),
            'description': _description.text.trim(),
            'ranges': ranges,
          },
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      backgroundColor: AppColors.surface,
      child: SizedBox(
        width: 760.w,
        height: 620.h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
              child: Text(
                widget.product == null
                    ? AppText.t('منتج جديد', 'New Product')
                    : AppText.t('تعديل المنتج', 'Edit Product'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _name,
                      onChanged: (_) => setState(() => _nameError = null),
                      decoration: InputDecoration(
                        labelText: AppText.t('الاسم', 'Name'),
                        isDense: true,
                        errorText: _nameError,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                            child: _labeled(
                          AppText.t('النوع', 'Category'),
                          TextField(
                            controller: _category,
                            enabled: !_saving,
                            decoration:
                                const InputDecoration(isDense: true, border: OutlineInputBorder()),
                          ),
                        )),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                            child: _labeled(
                          AppText.t('الوصف', 'Description'),
                          TextField(
                            controller: _description,
                            enabled: !_saving,
                            decoration:
                                const InputDecoration(isDense: true, border: OutlineInputBorder()),
                          ),
                        )),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(AppText.t('نطاقات التحليل', 'Analysis Ranges'),
                        style: TextStyle(
                            fontSize: 16.spMax, fontWeight: FontWeight.w700)),
                    const SizedBox(height: AppSpacing.sm),
                    if (widget.analyses.isEmpty)
                      Text(AppText.t('لا توجد تحاليل.', 'No analyses available.'),
                          style:
                              TextStyle(color: AppColors.textMuted, fontSize: 13.spMax))
                    else
                      AppCard(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          children: [
                            for (var i = 0; i < _ranges.length; i++)
                              _rangeRow(i),
                            const SizedBox(height: AppSpacing.sm),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: AppButton(
                                small: true,
                                style: AppButtonStyle.secondary,
                                icon: Icon(Icons.add, size: 16.r),
                                label: AppText.t('إضافة تحليل', 'Add Analysis'),
                                onPressed: _saving ? null : _addRange,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppButton(
                    style: AppButtonStyle.secondary,
                    label: AppStrings.cancel,
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  AppButton(
                    loading: _saving,
                    label: AppStrings.save,
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax)),
          const SizedBox(height: AppSpacing.xs),
          child,
        ],
      );

  Widget _rangeRow(int index) {
    final row = _ranges[index];
    final used = _usedAnalysisIds(index);
    final enabled = row.analysisId != null && !_saving;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<int?>(
              initialValue: row.analysisId,
              isDense: true,
              isExpanded: true,
              decoration:
                  const InputDecoration(isDense: true, border: OutlineInputBorder()),
              hint: Text(
                AppText.t('اختر تحليلاً…', 'Choose an analysis…'),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                softWrap: false,
              ),
              selectedItemBuilder: (_) => [
                Text(
                  AppText.t('اختر تحليلاً…', 'Choose an analysis…'),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false,
                ),
                for (final a in widget.analyses)
                  Text(
                    '${a['name']}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    softWrap: false,
                  ),
              ],
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  enabled: false,
                  child: Text(
                    AppText.t('اختر تحليلاً…', 'Choose an analysis…'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (final a in widget.analyses)
                  DropdownMenuItem<int?>(
                    value: int.tryParse('${a['id']}'),
                    enabled: !used.contains('${a['id']}'),
                    child: Text('${a['name']}', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (v) {
                      row.analysisId = v;
                      _onAnalysisChange(row);
                    },
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 90.w,
            child: TextField(
              controller: row.minCtrl,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                labelText: AppText.t('الحد الأدنى', 'Min'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 90.w,
            child: TextField(
              controller: row.maxCtrl,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                labelText: AppText.t('الحد الأقصى', 'Max'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 110.w,
            child: TextField(
              controller: row.unitCtrl,
              enabled: enabled,
              decoration: InputDecoration(
                isDense: true,
                labelText: AppText.t('الوحدة', 'Unit'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            tooltip: AppStrings.delete,
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : () => _removeRange(index),
            icon: Icon(Icons.remove_circle_outline, size: 18.r, color: AppColors.danger),
          ),
        ],
      ),
    );
  }
}