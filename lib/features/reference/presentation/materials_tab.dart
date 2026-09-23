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
import '../../../design_system/widgets/app_field.dart';
import 'cubit/reference_cubit.dart';
import 'material_editor.dart';

/// Reference materials list (search + add/edit/delete) — port of the
/// MaterialsView list section (42_materials_editor.js).
class MaterialsTab extends StatefulWidget {
  const MaterialsTab({super.key});

  @override
  State<MaterialsTab> createState() => _MaterialsTabState();
}

class _MaterialsTabState extends State<MaterialsTab> {
  final _searchCtrl = TextEditingController();
  int? _confirmDeleteId;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openEditor([int? materialId]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => MaterialEditor(materialId: materialId),
    );
    if (saved != true || !mounted) return;
    await context.read<ReferenceCubit>().load();
    if (mounted) {
      AppFeedback.success(
        context,
        AppText.t('تم الحفظ', 'Saved'),
      );
    }
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> material) async {
    final id = (material['id'] as num).toInt();
    setState(() => _confirmDeleteId = null);
    try {
      await context.read<ReferenceCubit>().delete(id);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.error(context, '$e');
    }
  }

  List<Map<String, dynamic>> _filtered(List<Map<String, dynamic>> all) {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final m in all)
        if ('${m['material_name'] ?? ''}'.toLowerCase().contains(q) ||
            '${m['material_code'] ?? ''}'.toLowerCase().contains(q))
          m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReferenceCubit>().state;
    final rows = _filtered(state.materials);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(AppText.t('المواد المرجعية', 'Reference Materials'),
                style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            AppButton(
              small: true,
              icon: Icon(Icons.add, size: 16.r),
              label: AppText.t('إضافة مادة', 'Add New Material'),
              onPressed: () => _openEditor(),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: 320.w,
          child: AppField(
            label: AppText.t('بحث بالاسم أو الكود', 'Search by name or code...'),
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (state.loading)
          const Center(child: CircularProgressIndicator())
        else if (state.error != null)
          Text(state.error!, style: TextStyle(color: AppColors.danger))
        else if (rows.isEmpty)
          AppEmptyState(
            icon: Icons.book_outlined,
            title: state.materials.isEmpty
                ? AppText.t('لا توجد مواد', 'No materials found.')
                : AppText.t('لا توجد نتائج مطابقة', 'No matching materials.'),
            subtitle: state.materials.isEmpty
                ? AppText.t('أضف مادة جديدة أو استوردها من Reference.xlsx.',
                    'Add a new material or import from Reference.xlsx.')
                : AppText.t('جرّب مسح البحث.', 'Try clearing the search.'),
          )
        else
          Flexible(
            child: AppCard(
              padding: EdgeInsets.zero,
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: rows.length,
                itemBuilder: (context, i) => _tile(context, rows[i]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tile(BuildContext context, Map<String, dynamic> m) {
    final name = '${m['material_name'] ?? ''}';
    final inactive = (m['active'] as num?)?.toInt() == 0;
    final isConfirming = _confirmDeleteId == (m['id'] as num).toInt();
    return ListTile(
      dense: true,
      leading: Icon(Icons.science_outlined, size: 18, color: AppColors.primary),
      title: Text(
        name,
        style: TextStyle(color: inactive ? AppColors.textMuted : null),
      ),
      subtitle: Text('${m['material_code'] ?? ''}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inactive)
            Text(
              '(${AppText.t('محذوف', 'Deleted')})',
              style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
            )
          else ...[
            IconButton(
              tooltip: AppStrings.edit,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.edit_outlined, size: 18.r),
              onPressed: () => _openEditor((m['id'] as num).toInt()),
            ),
            const SizedBox(width: 4),
            if (isConfirming)
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                onPressed: () => _delete(context, m),
                child: Text(AppText.t('تأكيد؟', 'Confirm?'),
                    style: const TextStyle(fontSize: 12)),
              )
            else
              IconButton(
                tooltip: AppStrings.delete,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline, size: 18.r, color: AppColors.danger),
                onPressed: () =>
                    setState(() => _confirmDeleteId = (m['id'] as num).toInt()),
              ),
            if (isConfirming)
              TextButton(
                onPressed: () => setState(() => _confirmDeleteId = null),
                child: Text(AppText.t('إلغاء', 'Cancel'),
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
        ],
      ),
    );
  }
}