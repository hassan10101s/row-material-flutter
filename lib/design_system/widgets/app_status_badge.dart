import 'package:flutter/material.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: outline ? Colors.transparent : bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: outline ? 1 : 0.4)),
      ),
      child: Text(
        statusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
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
      return 'قبول نهائي | Approved';
    case 'CONDITIONAL_APPROVAL':
      return 'قبول مشروط | Conditional';
    case 'PARTIAL_REJECTION':
      return 'رفض جزئي | Partial';
    case 'FULL_REJECTION':
      return 'رفض كامل | Rejected';
    default:
      return 'قيد الانتظار | Pending';
  }
}