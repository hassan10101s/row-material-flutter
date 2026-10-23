import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Compact bordered export-table button that sits beside a search field on
/// phone rows: same visual weight as the field, 48dp touch target, disabled
/// state when there is nothing to export.
class AppExportIconButton extends StatelessWidget {
  const AppExportIconButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: AppText.t('تصدير جدول', 'Export table'),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12.r),
        child: Container(
          width: 52.r,
          height: 52.r,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.primary.withValues(alpha: 0.08)
                : AppColors.borderMuted.withValues(alpha: 0.4),
            border: Border.all(
              color: enabled
                  ? AppColors.primary.withValues(alpha: 0.35)
                  : AppColors.borderMuted,
            ),
            borderRadius: BorderRadius.circular(12.r),
          ),
          child: Icon(
            Icons.table_view_outlined,
            size: 22.r,
            color: enabled ? AppColors.primary : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Horizontal breathing room shared by phone search rows.
class AppSearchRow extends StatelessWidget {
  const AppSearchRow({
    super.key,
    required this.search,
    required this.export,
  });

  final Widget search;
  final Widget export;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: search),
        const SizedBox(width: AppSpacing.sm),
        export,
      ],
    );
  }
}
