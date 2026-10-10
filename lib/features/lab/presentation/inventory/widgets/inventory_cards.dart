import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../core/formula_engine.dart';

/// Small card widgets for the mobile inventory list.
///
/// Composed by `MobileInventoryTab`; status text/color stay beside the row
/// here so desktop and mobile can never disagree on thresholds.

String inventoryStatusText(Map<String, dynamic> r) {
  final qty = (r['current_qty'] as num?)?.toDouble() ?? 0;
  final min = (r['min_qty'] as num?)?.toDouble() ?? 0;
  if (qty <= 0) return AppText.t('نفد', 'Empty');
  if (qty < min) return AppText.t('منخفض', 'Low');
  return AppText.t('متوفر', 'OK');
}

Color inventoryStatusColor(Map<String, dynamic> r) {
  final qty = (r['current_qty'] as num?)?.toDouble() ?? 0;
  final min = (r['min_qty'] as num?)?.toDouble() ?? 0;
  if (qty <= 0) return AppColors.danger;
  if (qty < min) return AppColors.partial;
  return AppColors.success;
}

class InventoryCards extends StatelessWidget {
  const InventoryCards({
    super.key,
    required this.rows,
    required this.onEdit,
    required this.onAdjust,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onAdjust;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: rows.length,
      // md between cards — sm keeps them visually glued together.
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (context, index) {
        final r = rows[index];
        return InventoryCard(
          name: '${r['name']}',
          category: inventoryCategoryLabel(r['category']),
          qty: '${r['current_qty'] ?? 0} ${r['unit'] ?? ''}',
          status: inventoryStatusText(r),
          statusColor: inventoryStatusColor(r),
          onEdit: () => onEdit(r),
          onAdjust: () => onAdjust(r),
        );
      },
    );
  }
}

class InventoryCard extends StatelessWidget {
  const InventoryCard({
    super.key,
    required this.name,
    required this.category,
    required this.qty,
    required this.status,
    required this.statusColor,
    required this.onEdit,
    required this.onAdjust,
  });

  final String name;
  final String category;
  final String qty;
  final String status;
  final Color statusColor;
  final VoidCallback onEdit;
  final VoidCallback onAdjust;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.spMax,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textStrong,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: AppText.t('تسوية الكمية', 'Adjust'),
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                onPressed: onAdjust,
                icon: Icon(Icons.swap_vert, size: 20.r),
              ),
              IconButton(
                tooltip: AppStrings.edit,
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                onPressed: onEdit,
                icon: Icon(Icons.edit_outlined, size: 20.r),
              ),
            ],
          ),
          const Divider(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: Text(
                  qty,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.spMax,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
