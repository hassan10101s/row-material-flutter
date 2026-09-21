import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import 'cubit/reference_cubit.dart';

/// Reference materials manager (port of Web ReferenceAppView / MaterialsEditor).
class ReferenceScreen extends StatelessWidget {
  const ReferenceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReferenceCubit>().state;
    final cubit = context.read<ReferenceCubit>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppText.t('????????', 'Reference'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          if (state.loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (state.error != null)
            AppEmptyState(
              icon: Icons.error_outline,
              title: 'تعذر التحميل | Failed to load',
              subtitle: state.error,
              action: TextButton(onPressed: cubit.load, child: const Text('إعادة المحاولة')),
            )
          else if (state.materials.isEmpty)
            const AppEmptyState(
              icon: Icons.book_outlined,
              title: 'لا توجد خامات | No materials yet',
              subtitle: 'تُستورد المواد تلقائياً من Reference.xlsx عند التشغيل الأول.',
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
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
                          tooltip: 'تعديل | Edit',
                          icon: Icon(Icons.edit_outlined, size: 18.r),
                          onPressed: () {},
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}