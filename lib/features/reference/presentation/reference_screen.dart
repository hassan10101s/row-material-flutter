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
import '../../../design_system/widgets/app_skeleton.dart';
import 'cubit/reference_cubit.dart';

/// Reference materials manager (port of Web ReferenceAppView / MaterialsEditor).
class ReferenceScreen extends StatefulWidget {
  const ReferenceScreen({super.key});

  @override
  State<ReferenceScreen> createState() => _ReferenceScreenState();
}

class _ReferenceScreenState extends State<ReferenceScreen> {
  Future<void> _edit(Map<String, dynamic> material) async {
    final cubit = context.read<ReferenceCubit>();
    final id = (material['id'] as num).toInt();
    final result = await showDialog<({String name, String code})>(
      context: context,
      builder: (c) => _EditMaterialDialog(
        initialName: '${material['material_name'] ?? ''}',
        initialCode: '${material['material_code'] ?? ''}',
      ),
    );
    if (result == null || !mounted) return;
    try {
      await cubit.update(id, name: result.name, code: result.code);
      if (mounted) AppFeedback.success(context, AppText.t('تم الحفظ', 'Saved'));
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReferenceCubit>().state;
    final cubit = context.read<ReferenceCubit>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.reference,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          if (state.loading)
            const AppSkeletonList(rows: 5)
          else if (state.error != null)
            AppEmptyState(
              icon: Icons.error_outline,
              title: AppText.t('تعذر التحميل', 'Failed to load'),
              subtitle: state.error,
              action: TextButton(onPressed: cubit.load, child: const Text('إعادة المحاولة')),
            )
          else if (state.materials.isEmpty)
            AppEmptyState(
              icon: Icons.book_outlined,
              title: AppText.t('لا توجد خامات', 'No materials yet'),
              subtitle: 'تُستورد المواد تلقائياً من Reference.xlsx عند التشغيل الأول.',
            )
          else
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final r in state.materials)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.science_outlined,
                          size: 18, color: AppColors.primary),
                      title: Text('${r['material_name'] ?? ''}'),
                      subtitle: Text('${r['material_code'] ?? ''}'),
                      trailing: IconButton(
                        tooltip: AppText.t('تعديل', 'Edit'),
                        icon: Icon(Icons.edit_outlined, size: 18.r),
                        onPressed: () => _edit(r),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EditMaterialDialog extends StatefulWidget {
  final String initialName;
  final String initialCode;
  const _EditMaterialDialog({
    required this.initialName,
    required this.initialCode,
  });

  @override
  State<_EditMaterialDialog> createState() => _EditMaterialDialogState();
}

class _EditMaterialDialogState extends State<_EditMaterialDialog> {
  late final TextEditingController _name;
  late final TextEditingController _code;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _code = TextEditingController(text: widget.initialCode);
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(AppText.t('تعديل الخامة', 'Edit material'),
          style: const TextStyle(fontSize: 18)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppField(label: AppText.t('اسم الخامة', 'Material name'), controller: _name),
          const SizedBox(height: AppSpacing.md),
          AppField(label: AppText.t('رمز الخامة', 'Material code'), controller: _code),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        AppButton(
          label: AppText.t('حفظ', 'Save'),
          onPressed: () => Navigator.of(context)
              .pop((name: _name.text.trim(), code: _code.text.trim())),
        ),
      ],
    );
  }
}