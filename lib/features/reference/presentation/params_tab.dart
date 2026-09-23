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
import 'cubit/params_cubit.dart';

/// Parameter management tab — port of the Reference app Chemical/Physical
/// Aspects tabs (57_reference_app.js). `parameterType` is 'chemical' or
/// 'physical'; physical rows are unit-less by design.
class ParamsTab extends StatelessWidget {
  final String parameterType;
  const ParamsTab({super.key, required this.parameterType});

  bool get _isChemical => parameterType == 'chemical';

  Future<void> _openEditor(
      BuildContext context, [Map<String, dynamic>? param]) async {
    final cubit = context.read<ParamsCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ParamDialog(
        parameterType: parameterType,
        param: param,
        unitOptions: _isChemical ? cubit.state.units : null,
      ),
    );
    if (saved != true || !context.mounted) return;
    await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> param) async {
    final cubit = context.read<ParamsCubit>();
    final name = '${param['parameter_name'] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppText.t('حذف البارامتر', 'Delete parameter')),
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
      await cubit.delete(name);
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
    final state = context.watch<ParamsCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _isChemical
                  ? AppText.t('التحليل الكيميائي', 'Parameter Chemical Analysis')
                  : AppText.t('الفحص الظاهري', 'Physical Aspects'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Spacer(),
            AppButton(
              small: true,
              icon: Icon(Icons.add, size: 16.r),
              label: AppText.t('بارامتر جديد', 'New Parameter'),
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
            icon: Icons.tag_outlined,
            title: _isChemical
                ? AppText.t('لا توجد بارامترات كيميائية.', 'No chemical parameters.')
                : AppText.t('لا توجد بارامترات ظاهرية.', 'No physical parameters.'),
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
                        DataColumn(label: Text(AppText.t('البارامتر', 'Parameter'))),
                        if (_isChemical)
                          DataColumn(label: Text(AppText.t('الوحدة', 'Unit'))),
                        DataColumn(label: Text('')),
                      ],
                      rows: [
                        for (final p in state.rows)
                          DataRow(
                            cells: [
                              DataCell(Text('${p['parameter_name'] ?? ''}')),
                              if (_isChemical)
                                DataCell(Text('${p['unit'] ?? '%'}')),
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
      ],
    );
  }
}

class _ParamDialog extends StatefulWidget {
  final String parameterType;
  final Map<String, dynamic>? param;
  final List<Map<String, dynamic>>? unitOptions;
  const _ParamDialog({
    required this.parameterType,
    this.param,
    this.unitOptions,
  });

  @override
  State<_ParamDialog> createState() => _ParamDialogState();
}

class _ParamDialogState extends State<_ParamDialog> {
  late final TextEditingController _name = TextEditingController(
      text: '${widget.param?['parameter_name'] ?? ''}');
  late final TextEditingController _unit = TextEditingController(
      text: '${widget.param?['unit'] ?? '%'}');
  bool _saving = false;
  String? _nameError;

  bool get _isChemical => widget.parameterType == 'chemical';

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    super.dispose();
  }

  List<String> get _unitSuggestions {
    final seen = <String>{};
    final out = <String>[];
    for (final u in widget.unitOptions ?? []) {
      final s = '${u['symbol'] ?? ''}'.trim();
      if (s.isNotEmpty && seen.add(s.toLowerCase())) out.add(s);
    }
    return out;
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = AppText.t('الاسم مطلوب', 'Name is required.'));
      return;
    }
    setState(() => _saving = true);
    try {
      await context.read<ParamsCubit>().upsert(
            name,
            _isChemical ? _unit.text.trim() : '',
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
        widget.param == null
            ? (_isChemical
                ? AppText.t('بارامتر كيميائي', 'Chemical Parameter')
                : AppText.t('بارامتر ظاهري', 'Physical Aspect'))
            : AppText.t('تعديل البارامتر', 'Edit Parameter'),
      ),
      content: SizedBox(
        width: 420.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              onChanged: (_) => setState(() => _nameError = null),
              decoration: InputDecoration(
                labelText: AppText.t('الاسم', 'Name'),
                isDense: true,
                errorText: _nameError,
              ),
            ),
            if (_isChemical) ...[
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _unit,
                decoration: InputDecoration(
                  labelText: AppText.t('الوحدة', 'Unit'),
                  isDense: true,
                  hintText: '%',
                  border: const OutlineInputBorder(),
                  suffixIcon: _unitSuggestions.isEmpty
                      ? null
                      : PopupMenuButton<String>(
                          tooltip: AppText.t('اقتراحات الوحدات', 'Unit suggestions'),
                          onSelected: (v) => setState(() => _unit.text = v),
                          itemBuilder: (_) => [
                            for (final u in _unitSuggestions)
                              PopupMenuItem(value: u, child: Text(u)),
                          ],
                          icon: Icon(Icons.arrow_drop_down, size: 18.r),
                        ),
                ),
              ),
            ],
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