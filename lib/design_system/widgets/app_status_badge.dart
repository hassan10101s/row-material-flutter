import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';

/// Decision / status pill badge.
class AppStatusBadge extends StatelessWidget {
  final String status;
  final bool outline;

  const AppStatusBadge(this.status, {super.key, this.outline = false});

  @override
  Widget build(BuildContext context) {
    final color = statusColorsPut(status);
    final bg = color.withValues(alpha: 0.12);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 5.h),
      decoration: BoxDecoration(
        color: outline ? Colors.transparent : bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: outline ? 1 : 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7.r,
            height: 7.r,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          SizedBox(width: 6.w),
          Flexible(
            child: Text(
              statusLabel(status),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                color: color,
                fontSize: 12.spMax,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color statusColorsPut(String status) {
  switch (status) {
    case 'APPROVED':
    case 'CONDITIONAL_APPROVAL':
      return AppColors.success;
    case 'PARTIAL_REJECTION':
      return AppColors.partial;
    case 'FULL_REJECTION':
      return AppColors.danger;
    default:
      return AppColors.info;
  }
}

String statusLabel(String status) {
  switch (status) {
    case 'APPROVED':
      return AppText.t('قبول نهائي', 'Approved');
    case 'CONDITIONAL_APPROVAL':
      return AppText.t('قبول مشروط', 'Conditional');
    case 'PARTIAL_REJECTION':
      return AppText.t('رفض جزئي', 'Partial');
    case 'FULL_REJECTION':
      return AppText.t('رفض كامل', 'Rejected');
    default:
      return AppText.t('قيد الانتظار', 'Pending');
  }
}