import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../lab/domain/lab_result_repository.dart';
import '../../domain/reference_repository.dart';
import '../cubit/reference_cubit.dart';
import '../cubit/reference_state.dart';
import 'material_editor.dart';

/// Mobile reference materials list.
///
/// The inline "Confirm?" row the desktop list uses in the trailing slot does not
/// fit beside a title on a 400dp grid, so a delete goes through the shared
/// confirmation dialog instead — one prompt, and the row keeps its shape whether
/// it is asking or acting.
class MobileMaterialsTab extends StatefulWidget {
  const MobileMaterialsTab({
    super.key,
    required this.refRepo,
    required this.labConfig,
  });

  final ReferenceRepository refRepo;
  final LabConfigurationRepository labConfig;

  @override
  State<MobileMaterialsTab> createState() => _MobileMaterialsTabState();
}

class _MobileMaterialsTabState extends State<MobileMaterialsTab> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openEditor([int? materialId]) async {
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => MobileMaterialEditor(
          refRepo: widget.refRepo,
          labConfig: widget.labConfig,
          materialId: materialId,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await context.read<ReferenceCubit>().load();
    if (mounted) {
      AppFeedback.success(context, AppText.t('تم الحفظ', 'Saved'));
    }
  }

  Future<void> _delete(
    BuildContext context,
    Map<String, dynamic> material,
  ) async {
    final id = (material['id'] as num).toInt();
    final name = '${material['material_name'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف المادة', 'Delete material'),
      name: name,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await context.read<ReferenceCubit>().delete(id);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
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
    return AppErrorFeedback<ReferenceCubit, ReferenceState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('المواد المرجعية', 'Reference Materials'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: () => _openEditor(),
            icon: Icon(Icons.add, size: 20.r),
            label: Text(AppText.t('إضافة مادة', 'Add New Material')),
          ),
          const SizedBox(height: AppSpacing.md),
          AppField(
            label: AppText.t(
              'بحث بالاسم أو الكود',
              'Search by name or code...',
            ),
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.materials.isEmpty)
            const AppSkeletonList(rows: 6, lines: 3, height: 380)
          else if (rows.isEmpty)
            Expanded(
              child: AppEmptyState(
                icon: Icons.book_outlined,
                title: state.materials.isEmpty
                    ? AppText.t('لا توجد مواد', 'No materials found.')
                    : AppText.t(
                        'لا توجد نتائج مطابقة',
                        'No matching materials.',
                      ),
                subtitle: state.materials.isEmpty
                    ? AppText.t(
                        'أضف مادة جديدة أو استوردها من Reference.xlsx.',
                        'Add a new material or import from Reference.xlsx.',
                      )
                    : AppText.t('جرّب مسح البحث.', 'Try clearing the search.'),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, i) => _tile(rows[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(Map<String, dynamic> m) {
    final name = '${m['material_name'] ?? ''}';
    final code = '${m['material_code'] ?? ''}';
    final inactive = (m['active'] as num?)?.toInt() == 0;
    final id = (m['id'] as num).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Icon(Icons.science_outlined, size: 20.r, color: AppColors.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 14.spMax,
                      fontWeight: FontWeight.w700,
                      color: inactive
                          ? AppColors.textMuted
                          : AppColors.textStrong,
                    ),
                  ),
                  if (code.isNotEmpty)
                    Text(
                      code,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  if (inactive)
                    Text(
                      '(${AppText.t('محذوف', 'Deleted')})',
                      style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 12.spMax,
                      ),
                    ),
                ],
              ),
            ),
            // Inactive rows stay read-only, as they do on desktop.
            if (!inactive) ...[
              IconButton(
                tooltip: AppStrings.edit,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _openEditor(id),
                icon: Icon(Icons.edit_outlined, size: 20.r),
              ),
              IconButton(
                tooltip: AppStrings.delete,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _delete(context, m),
                icon: Icon(
                  Icons.delete_outline,
                  size: 20.r,
                  color: AppColors.danger,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
