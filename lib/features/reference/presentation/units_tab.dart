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
import 'cubit/units_cubit.dart';

/// Units settings tab — port of the Reference app Units Settings tab
/// (57_reference_app.js): symbol / name / dimension CRUD on `lab_units`.
class UnitsTab extends StatelessWidget {
  const UnitsTab({super.key});

  Future<void> _openEditor(
      BuildContext context, [Map<String, dynamic>? unit]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _UnitDialog(unit: unit),
    );
    if (saved != true || !context.mounted) return;
    await context.read<UnitsCubit>().load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> unit) async {
    final cubit = context.read<UnitsCubit>();
    final symbol = '${unit['symbol'] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppText.t('حذف الوحدة', 'Delete unit')),
        content: Text('${AppText.t('حذف', 'Delete')} "$symbol"?'),
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
      await cubit.delete(symbol);
      if (context.mounted) AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UnitsCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(AppText.t('إعدادات الوحدات', 'Units Settings'),
                style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            AppButton(
              small: true,
              icon: Icon(Icons.add, size: 16.r),
              label: AppText.t('وحدة جديدة', 'New Unit'),
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
            icon: Icons.straighten_outlined,
            title: AppText.t('لا توجد وحدات.', 'No units found.'),
            subtitle: AppText.t(
              'أضف وحدات مثل % و mg/kg و ppm.',
              'Add units like %, mg/kg, ppm.',
            ),
          )
        else
          Flexible(
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
                        DataColumn(label: Text(AppText.t('الرمز', 'Symbol'))),
                        DataColumn(label: Text(AppText.t('الاسم', 'Name'))),
                        DataColumn(label: Text(AppText.t('البعد', 'Dimension'))),
                        DataColumn(label: Text('')),
                      ],
                      rows: [
                        for (final u in state.rows)
                          DataRow(
                            cells: [
                              DataCell(Text('${u['symbol'] ?? ''}',
                                  style: const TextStyle(fontWeight: FontWeight.w600))),
                              DataCell(Text('${u['name'] ?? '-'}')),
                              DataCell(Text('${u['dimension'] ?? '-'}')),
                              DataCell(Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: AppStrings.edit,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _openEditor(context, u),
                                    icon: Icon(Icons.edit_outlined, size: 18.r),
                                  ),
                                  IconButton(
                                    tooltip: AppStrings.delete,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _delete(context, u),
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
      ],
    );
  }
}

class _UnitDialog extends StatefulWidget {
  final Map<String, dynamic>? unit;
  const _UnitDialog({this.unit});

  @override
  State<_UnitDialog> createState() => _UnitDialogState();
}

class _UnitDialogState extends State<_UnitDialog> {
  late final TextEditingController _symbol =
      TextEditingController(text: '${widget.unit?['symbol'] ?? ''}');
  late final TextEditingController _name =
      TextEditingController(text: '${widget.unit?['name'] ?? ''}');
  late final TextEditingController _dimension =
      TextEditingController(text: '${widget.unit?['dimension'] ?? ''}');
  bool _saving = false;
  String? _symbolError;

  @override
  void dispose() {
    _symbol.dispose();
    _name.dispose();
    _dimension.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final symbol = _symbol.text.trim();
    if (symbol.isEmpty) {
      setState(() => _symbolError = AppText.t('الرمز مطلوب', 'Symbol is required.'));
      return;
    }
    setState(() => _saving = true);
    try {
      await context.read<UnitsCubit>().upsert(
            symbol,
            name: _name.text.trim(),
            dimension: _dimension.text.trim(),
          );
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
    return AlertDialog(
      title: Text(
        widget.unit == null
            ? AppText.t('وحدة جديدة', 'New Unit')
            : AppText.t('تعديل الوحدة', 'Edit Unit'),
      ),
      content: SizedBox(
        width: 420.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _symbol,
              onChanged: (_) => setState(() => _symbolError = null),
              decoration: InputDecoration(
                labelText: AppText.t('الرمز', 'Symbol'),
                isDense: true,
                hintText: 'mg/kg',
                errorText: _symbolError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name | الاسم',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _dimension,
              decoration: const InputDecoration(
                labelText: 'Dimension | البعد',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
    );
  }
}